package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasPackageFixture.Companion.obj
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasPackageRepositoryTest {
    private val fixture = NasPackageFixture()
    private val repository = NasPackageRepository(fixture)
    private val events = mutableListOf<NasPackageCheckpoint>()
    private val observer: NasPackageObserver = { events += it }
    private suspend fun start(): NasPackageProgress {
        val plan = repository.prepare(listOf("Synthetic:stable"))
        return repository.start(plan.id, emptyMap(), true, observer)
    }
    @Test fun `目录官方优先第三方失败保留且仅DSM候选允许更新`() = runBlocking {
        fixture.installed["Synthetic"] = "1.0"; fixture.includeUpgrade = false
        fixture.intercept = { if (it.parameters["blloadothers"] == JsonPrimitive(true)) throw IOException() else null }
        val catalog = repository.catalog()
        assertFalse(catalog.communityAvailable); assertFalse(catalog.entries.single().updateAvailable)
        expect(NasPackageProblem.CHANGED) { repository.prepare(listOf("Synthetic:stable")) }
        fixture.includeUpgrade = true
        assertTrue(repository.catalog().entries.single().updateAvailable); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `第三方证书失败不可吞成来源不可用`() = runBlocking {
        fixture.intercept = { if (it.parameters["blloadothers"] == JsonPrimitive(true)) throw DsmFailure(null, "synthetic", "", kind = DsmErrorKind.TLS_UNTRUSTED) else null }
        try { repository.catalog(); fail() } catch (error: DsmFailure) { assertEquals(DsmErrorKind.TLS_UNTRUSTED, error.kind) }
    }
    @Test fun `完整列表不接受截断重复标识及假空列表`() = runBlocking {
        for (response in listOf("{\"packages\":[],\"total\":1}", "{}", "{\"packages\":[{\"id\":\"Synthetic\",\"version\":\"1\",\"additional\":{}},{\"id\":\"Synthetic\",\"version\":\"1\",\"additional\":{}}]}")) {
            fixture.intercept = { if (it.api == PACKAGE_API && it.method == "list") obj(response) else null }
            expect(NasPackageProblem.INCOMPLETE) { repository.catalog() }
        }
    }
    @Test fun `准备按队列顺序纳入依赖且无写入`() = runBlocking {
        fixture.queue = listOf("Dependency", "Synthetic")
        val plan = repository.prepare(listOf("Synthetic:stable"))
        assertEquals(listOf("Dependency", "Synthetic"), plan.items.map { it.entry.packageId })
        assertTrue(fixture.writes.isEmpty())
        assertEquals(2, fixture.requests.count { it.method == "check" && it.version == 2 })
    }
    @Test fun `冲突与省略所选目标的队列拒绝准备`() = runBlocking {
        fixture.intercept = { if (it.method == "get_queue") obj("""{"queue":[],"non_exist_pkgs":[],"conflicted_pkgs":[{"id":"Synthetic"}]}""") else null }
        expect(NasPackageProblem.DEPENDENCIES) { repository.prepare(listOf("Synthetic:stable")) }
        assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `准备后候选版本改变拒绝旧确认零提交`() = runBlocking {
        val plan = repository.prepare(listOf("Synthetic:stable")); fixture.candidateVersion = "3.0"
        expect(NasPackageProblem.CHANGED) { repository.start(plan.id, emptyMap(), true, observer) }
        assertTrue(fixture.writes.isEmpty()); assertTrue(events.isEmpty())
    }
    @Test fun `快速安装单次提交轮询并确认精确版本`() = runBlocking {
        val current = start(); assertEquals(NasPackageInstallPhase.INSTALLING, current.phase)
        val done = repository.advance(current.id)
        assertEquals(NasPackageInstallPhase.COMPLETED, done.phase)
        assertEquals(1, fixture.writes.size); assertTrue(fixture.writes.single().parameters.getValue("blqinst").jsonPrimitive.boolean)
        assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.ACCEPTED, NasPackageWriteStage.VERIFIED), events.map { it.stage })
        assertEquals(JsonPrimitive("synthetic-task"), fixture.requests.single { it.method == "status" }.parameters["task_id"])
    }
    @Test fun `依赖逐项完成后才提交下一套件`() = runBlocking {
        fixture.queue = listOf("Dependency", "Synthetic")
        val active = start(); assertEquals("Dependency", active.entry.packageId)
        val second = repository.advance(active.id); assertEquals(1, second.completed); assertEquals("Synthetic", second.entry.packageId)
        assertEquals(2, fixture.writes.size)
        assertEquals(NasPackageInstallPhase.COMPLETED, repository.advance(active.id).phase)
    }
    @Test fun `完成记录保存失败不继续后续依赖`() = runBlocking {
        fixture.queue = listOf("Dependency", "Synthetic")
        val plan = repository.prepare(listOf("Synthetic:stable"))
        val current = repository.start(plan.id, emptyMap(), true) { if (it.stage == NasPackageWriteStage.VERIFIED) throw IOException("synthetic storage") }
        try { repository.advance(current.id); fail() } catch (_: IOException) { }
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `写前记录失败或权限失效均零请求`() = runBlocking {
        val plan = repository.prepare(listOf("Synthetic:stable"))
        try { repository.start(plan.id, emptyMap(), true) { throw IOException() }; fail() } catch (_: IOException) { }
        assertTrue(fixture.writes.isEmpty())
        val next = repository.prepare(listOf("Synthetic:stable")); fixture.accessFailure = DsmFailure(105, "synthetic", "", kind = DsmErrorKind.PERMISSION_DENIED)
        try { repository.start(next.id, emptyMap(), true, observer); fail() } catch (_: DsmFailure) { }
        assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `安装回执丢失刷新不重发且版本不符不报完成`() = runBlocking {
        fixture.intercept = { if (it.write) throw IOException("synthetic lost receipt") else null }
        val current = start(); assertEquals(NasPackageInstallPhase.UNKNOWN, current.phase)
        repeat(2) { assertEquals(NasPackageInstallPhase.UNKNOWN, repository.advance(current.id).phase) }
        assertEquals(1, fixture.writes.size)
        fixture.installed["Synthetic"] = "2.0"
        assertEquals(NasPackageInstallPhase.COMPLETED, repository.advance(current.id).phase); assertEquals(1, fixture.writes.size)
    }
    @Test fun `任务明确失败不以旁路版本相同抹成成功`() = runBlocking {
        val current = start(); fixture.installed["Synthetic"] = "2.0"
        fixture.intercept = { if (it.method == "status") obj("{\"finished\":true,\"success\":false}") else null }
        assertEquals(NasPackageInstallPhase.FAILED, repository.advance(current.id).phase)
        assertEquals(NasPackageWriteStage.REJECTED, events.last().stage)
    }
    @Test fun `权限拒绝停止轮询而不回退列表认领`() = runBlocking {
        val current = start(); val before = fixture.requests.size
        fixture.intercept = { if (it.method == "status") throw DsmFailure(105, "synthetic", "", kind = DsmErrorKind.PERMISSION_DENIED) else null }
        try { repository.advance(current.id); fail() } catch (_: DsmFailure) { }
        assertEquals(listOf("status"), fixture.requests.drop(before).map { it.method })
    }
    @Test fun `下载完成进入原生选项最终安装始终检查签名`() = runBlocking {
        fixture.quick = false
        val downloading = start(); assertEquals(NasPackageInstallPhase.DOWNLOADING, downloading.phase)
        val prepared = repository.advance(downloading.id); assertEquals(NasPackageInstallPhase.OPTIONS, prepared.phase)
        val installed = repository.configure(prepared.id, "/volume1", true, false, emptyMap())
        assertEquals(NasPackageInstallPhase.INSTALLING, installed.phase)
        val request = fixture.writes.last(); assertEquals(JsonPrimitive(true), request.parameters["check_codesign"])
        assertEquals(JsonPrimitive(true), request.parameters["force"]); assertEquals(JsonPrimitive("{}"), request.parameters["extra_values"])
        assertEquals(NasPackageInstallPhase.COMPLETED, repository.advance(prepared.id).phase)
        assertEquals(2, fixture.writes.size)
    }
    @Test fun `签名与脚本表单拒绝只清理本次返回目标`() = runBlocking {
        for (signature in listOf(true, false)) {
            val fixture = NasPackageFixture().apply { quick = false; checked = if (signature) JsonObject(checked + ("codesign_error" to JsonPrimitive(1)))
                else JsonObject(checked + ("install_pages" to JsonArray(listOf(obj("""{"items":[{"type":"textfield","subitems":[{"key":"x","validator":{"fn":"synthetic"}}]}]}"""))))) }
            val repository = NasPackageRepository(fixture); val plan = repository.prepare(listOf("Synthetic:stable")); val job = repository.start(plan.id, emptyMap(), true, observer)
            assertEquals(NasPackageInstallPhase.FAILED, repository.advance(job.id).phase)
            assertEquals(listOf("install", "delete"), fixture.writes.map { it.method }); assertEquals(JsonPrimitive("/synthetic/package.spk"), fixture.writes.last().parameters["path"])
        }
    }
    @Test fun `许可必须接受且表单原生类型与约束保持`() = runBlocking {
        fixture.quick = false; fixture.checked = JsonObject(fixture.checked + ("licence" to JsonPrimitive("Synthetic license")))
        val job = start(); repository.advance(job.id)
        expect(NasPackageProblem.OPTIONS_REQUIRED) { repository.configure(job.id, "/volume1", true, false, emptyMap()) }
        assertEquals(1, fixture.writes.size)
        repository.configure(job.id, "/volume1", true, true, emptyMap()); assertEquals(2, fixture.writes.size)
        val fields = packageFields(Json.parseToJsonElement("""[{"items":[{"type":"password","subitems":[{"key":"password","validator":{"allowBlank":false,"minLength":3}}]},{"type":"multiselect","subitems":[{"key":"enabled","defaultValue":true}]}]}]"""))
        val options = NasPackageConfiguration("Synthetic", "1", null, fields, emptyList(), "", false, false)
        expect(NasPackageProblem.OPTIONS_REQUIRED) { options.checkedValues(mapOf("password" to JsonPrimitive("ab"))) }
        val values = options.checkedValues(mapOf("password" to JsonPrimitive("abc")))
        assertTrue(values["enabled"]!!.jsonPrimitive.boolean); assertTrue(values["password"]!!.jsonPrimitive.isString)
    }
    @Test fun `确认选项后安装位置消失零正式安装`() = runBlocking {
        fixture.quick = false; val job = start(); repository.advance(job.id)
        fixture.intercept = { if (it.method == "check" && it.api == PACKAGE_INSTALL) obj("{\"is_occupied\":false,\"volume_list\":[]}") else null }
        expect(NasPackageProblem.VOLUME) { repository.configure(job.id, "/volume1", true, false, emptyMap()) }
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `取消下载到达时已完成只清理不安装且不重复取消`() = runBlocking {
        fixture.quick = false; val job = start()
        repository.cancel(job.id); repository.cancel(job.id)
        assertEquals(NasPackageInstallPhase.CANCELLED, repository.advance(job.id).phase)
        assertEquals(listOf("install", "cancel", "delete"), fixture.writes.map { it.method })
        assertEquals(JsonPrimitive("synthetic-task"), fixture.writes[1].parameters["taskid"])
        assertFalse(fixture.writes[1].parameters.containsKey("task_id"))
    }
    @Test fun `慢速最终安装等待中仍显示安装且不开放取消`() = runBlocking {
        fixture.quick = false; val job = start(); repository.advance(job.id); repository.configure(job.id, "/volume1", true, false, emptyMap())
        assertFalse(repository.job!!.progress.canCancel)
        assertEquals(NasPackageInstallPhase.INSTALLING, repository.job!!.progress.phase)
    }
    @Test fun `同版本手动重装回执丢失不以旧版本认领`() = runBlocking {
        fixture.installed["Synthetic"] = "2.0"
        val job = repository.upload(UploadSource("test.spk", null, 3, { "spk".byteInputStream() }), observer)
        fixture.intercept = { if (it.write && it.method == "upgrade") throw IOException() else null }
        assertEquals(NasPackageInstallPhase.UNKNOWN, repository.configure(job.id, "/volume1", true, false, emptyMap()).phase)
        assertEquals(NasPackageInstallPhase.UNKNOWN, repository.advance(job.id).phase)
        assertEquals(2, fixture.writes.size)
    }
    @Test fun `设置频道读取布尔写字符串默认卷未改不发送`() = runBlocking {
        val original = repository.preferences()
        val changed = repository.savePreferences("settings", original, original.copy(beta = true, email = true), observer)
        assertTrue(changed.beta); assertTrue(changed.email)
        val write = fixture.writes.single(); assertEquals(JsonPrimitive("beta"), write.parameters["update_channel"]); assertFalse(write.parameters.containsKey("default_vol"))
        assertEquals(NasPackageWriteStage.VERIFIED, events.last().stage)
    }
    @Test fun `未知逐套件策略不能被当成手动覆盖`() = runBlocking {
        fixture.preferenceRows = JsonArray(listOf(obj("""{"id":"Synthetic","name":"Synthetic","additional":{"silent_upgrade":true,"autoupdate":false}}""")))
        val original = repository.preferences(); assertNull(original.packages.single().policy)
        expect(NasPackageProblem.CHANGED) { repository.savePreferences("settings", original, original.copy(policy = NasPackageUpdatePolicy.SELECTED), observer) }
        assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `设置过时基线拒绝提交`() = runBlocking {
        val original = repository.preferences(); fixture.settings = JsonObject(fixture.settings + ("enable_email" to JsonPrimitive(true)))
        expect(NasPackageProblem.CHANGED) { repository.savePreferences("settings", original, original.copy(beta = true), observer) }
        assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `来源JSON文本改名改地址删除都检查结果且拒绝凭据URL`() = runBlocking {
        val first = NasPackageSource("Synthetic", "https://example.invalid/feed")
        assertEquals(listOf(first), repository.saveSource("source1", null, first, observer))
        val request = fixture.writes.single(); assertTrue(request.parameters.getValue("list").jsonPrimitive.isString)
        val second = first.copy(name = "Renamed", url = "https://example.invalid/new")
        assertEquals(listOf(second), repository.saveSource("source2", first, second, observer))
        assertTrue(repository.saveSource("source3", second, null, observer).isEmpty())
        expect(NasPackageProblem.INVALID_SOURCE) { repository.saveSource("source4", null, first.copy(url = "https://synthetic:secret@example.invalid/feed"), observer) }
        assertEquals(3, fixture.writes.size)
    }
    @Test fun `未结束安装与当前启停调用共用互斥边界`() = runBlocking {
        fixture.finished = false; start()
        expect(NasPackageProblem.BUSY) {
            repository.performControl("control", PackageInfo("Synthetic", "Synthetic", "1.0", ResourceState.STOPPED, null, true, false),
                io.github.qwertyuiop1995.dsmnativeclient.PackageMutationOperation.START) { fail("No control while installing") }
        }
        val original = repository.preferences()
        expect(NasPackageProblem.BUSY) { repository.savePreferences("settings", original, original.copy(email = true), observer) }
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `下载状态读取失败仍可取消已知任务且不重放下载`() = runBlocking {
        fixture.quick = false; val job = start()
        fixture.intercept = { if (it.method == "status") throw IOException() else null }
        val unknown = repository.advance(job.id); assertEquals(NasPackageInstallPhase.UNKNOWN, unknown.phase); assertTrue(unknown.canCancel)
        fixture.intercept = null; repository.cancel(job.id)
        assertEquals(NasPackageInstallPhase.CANCELLED, repository.advance(job.id).phase)
        assertEquals(listOf("install", "cancel", "delete"), fixture.writes.map { it.method })
    }
    @Test fun `依赖完成后下一目标变化只终止未提交部分`() = runBlocking {
        fixture.queue = listOf("Dependency", "Synthetic")
        val job = start(); fixture.installed["Synthetic"] = "unexpected"
        assertEquals(NasPackageInstallPhase.FAILED, repository.advance(job.id).phase)
        assertEquals(1, fixture.writes.size)
        assertEquals(NasPackageWriteStage.NOT_SUBMITTED, events.last().stage)
        assertEquals(1, events.last().index)
    }
    private suspend fun expect(problem: NasPackageProblem, block: suspend () -> Any?) {
        try { block(); fail("Expected $problem") } catch (error: NasPackageFailure) { assertEquals(problem, error.problem) }
    }
}
