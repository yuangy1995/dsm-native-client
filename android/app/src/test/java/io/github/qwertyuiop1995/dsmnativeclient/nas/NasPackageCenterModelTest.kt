package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasPackageCenterModelTest {
    private val fixture = PackageProtocolFixture()
    private var repository = fixture.repository()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val preferences = MemoryPreferences()
    private val store = PackageActivityStore(preferences)
    private val directory = Files.createTempDirectory("synthetic-package").toFile()
    private fun model() = NasPackageCenterModel(scope, { repository }, { store }, { directory }, {}, pollMillis = 10)
    private suspend fun eventually(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(10) }; delay(20) }
    @org.junit.After fun cleanup() { scope.cancel(); directory.deleteRecursively() }
    @Test fun `完整安装从目录确认到记录完成走真实传输`() = runBlocking {
        val model = model(); model.catalog(); eventually { model.state.value.catalog != null }
        model.prepare(model.state.value.catalog!!.entries); eventually { model.state.value.plan != null && !model.state.value.busy }
        assertTrue(fixture.backend.writes.isEmpty())
        model.start(emptyMap(), true); eventually { model.state.value.activities.singleOrNull()?.terminal == true }
        assertEquals(NasPackageInstallPhase.COMPLETED, model.state.value.progress?.phase)
        assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `已安装更新入口重读DSM明确候选再进入同一计划`() = runBlocking {
        fixture.backend.installed["Synthetic"] = "1.0"
        val model = model(); model.updateInstalled("Synthetic"); eventually { model.state.value.plan != null && !model.state.value.busy }
        assertEquals("1.0", model.state.value.plan!!.items.single().entry.installedVersion)
        assertTrue(fixture.backend.writes.isEmpty())
        model.start(emptyMap(), true); eventually { model.state.value.activities.singleOrNull()?.terminal == true }
        assertEquals("upgrade", fixture.backend.writes.single().method)
    }
    @Test fun `未知跨实例恢复只查版本不重发并保留同版本限制`() = runBlocking {
        var model = model(); model.catalog(); eventually { model.state.value.catalog != null }
        model.prepare(model.state.value.catalog!!.entries); eventually { model.state.value.plan != null && !model.state.value.busy }
        fixture.backend.intercept = { if (it.write) throw IOException() else null }
        model.start(emptyMap(), true); eventually { model.state.value.progress?.phase == NasPackageInstallPhase.UNKNOWN && !model.state.value.busy }
        val record = model.state.value.activities.single()
        model.clear(); repository = fixture.repository("new-session"); model = model(); model.restore(); eventually { model.state.value.activities.isNotEmpty() }
        fixture.backend.installed["Synthetic"] = "2.0"
        model.review(record); eventually { model.state.value.activities.single().terminal }
        assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `写前本机失败不提交而未知DSM按真实条件安装`() = runBlocking {
        val model = model(); model.catalog(); eventually { model.state.value.catalog != null }
        model.prepare(model.state.value.catalog!!.entries); eventually { model.state.value.plan != null && !model.state.value.busy }
        preferences.commitSucceeds = false; model.start(emptyMap(), true); eventually { model.state.value.failure != null && !model.state.value.busy }
        assertTrue(fixture.backend.writes.isEmpty())
        val other = PackageProtocolFixture(); other.knownEnvironment = false
        val repo = other.repository(); val plan = repo.packageCenter.prepare(listOf("Synthetic:stable"))
        repo.packageCenter.start(plan.id, emptyMap(), true) {}
        assertEquals(1, other.backend.writes.size)
    }
    @Test fun `设置与来源提交真实JSON编码后刷新记录完成`() = runBlocking {
        val model = model(); model.preferences(); eventually { model.state.value.preferences != null }
        model.savePreferences(model.state.value.preferences!!.copy(beta = true)); eventually { model.state.value.activities.singleOrNull()?.terminal == true }
        assertEquals(JsonPrimitive("beta"), fixture.backend.writes.single().parameters["update_channel"])
        model.sources(); eventually { model.state.value.sources != null }
        model.saveSource(null, NasPackageSource("Synthetic", "https://example.invalid/feed")); eventually { model.state.value.activities.size == 2 && model.state.value.activities.all { it.terminal } }
        assertTrue(fixture.backend.writes.last().parameters.getValue("list").jsonPrimitive.isString)
    }
    @Test fun `设置断线跨实例恢复只读且内容不符继续禁止保存`() = runBlocking {
        var model = model(); model.preferences(); eventually { model.state.value.preferences != null }
        val desired = model.state.value.preferences!!.copy(email = true)
        fixture.backend.intercept = { if (it.write) throw IOException("synthetic receipt lost") else null }
        model.savePreferences(desired); eventually { model.state.value.failure != null && !model.state.value.busy }
        val record = model.state.value.activities.single()
        assertEquals(PackageActivityPhase.SUBMITTED, record.items.single().phase); assertFalse(record.items.single().accepted)
        model.clear(); repository = fixture.repository("restored-settings"); model = model()
        model.restore(); eventually { model.state.value.activities.isNotEmpty() }
        fixture.backend.intercept = null
        model.review(record); eventually { !model.state.value.busy }; assertFalse(store.get(repository.owner!!, record.id).terminal)
        model.preferences(); eventually { model.state.value.preferences != null }
        model.savePreferences(desired); eventually { model.state.value.failure != null && !model.state.value.busy }
        assertEquals(NasPackageProblem.BUSY, (model.state.value.failure as NasPackageFailure).problem)
        fixture.backend.settings = JsonObject(fixture.backend.settings + ("enable_email" to JsonPrimitive(true)))
        model.review(record); eventually { model.state.value.activities.single().terminal && !model.state.value.busy }
        assertEquals(PackageActivityPhase.COMPLETED, model.state.value.activities.single().items.single().phase)
        assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `来源改址接受后回读失败冷恢复要求新来源匹配且旧地址消失`() = runBlocking {
        val original = NasPackageSource("Synthetic", "https://example.invalid/feed")
        val desired = original.copy(name = "Updated", url = "https://example.invalid/new")
        fun row(value: NasPackageSource) = buildJsonObject { put("name", value.name); put("feed", value.url) }
        fixture.backend.feeds = JsonArray(listOf(row(original)))
        var model = model(); model.sources(); eventually { model.state.value.sources != null }
        var sent = false
        fixture.backend.intercept = { if (it.write) { sent = true; null } else if (sent) throw IOException("synthetic read failed") else null }
        model.saveSource(original, desired); eventually { model.state.value.failure != null && !model.state.value.busy }
        val record = model.state.value.activities.single()
        assertEquals(PackageActivityPhase.SUBMITTED, record.items.single().phase); assertTrue(record.items.single().accepted)
        model.clear(); repository = fixture.repository("restored-source"); model = model()
        model.restore(); eventually { model.state.value.activities.isNotEmpty() }
        fixture.backend.intercept = null; fixture.backend.feeds = JsonArray(listOf(row(original), row(desired)))
        model.review(record); eventually { !model.state.value.busy }; assertFalse(store.get(repository.owner!!, record.id).terminal)
        model.saveSource(original, desired); eventually { model.state.value.failure != null && !model.state.value.busy }
        assertEquals(NasPackageProblem.BUSY, (model.state.value.failure as NasPackageFailure).problem)
        fixture.backend.feeds = JsonArray(listOf(row(desired)))
        model.review(record); eventually { model.state.value.activities.single().terminal && !model.state.value.busy }
        assertEquals(PackageActivityPhase.COMPLETED, model.state.value.activities.single().items.single().phase)
        assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `选择SPK只复制明确上传才发送且清理临时副本`() = runBlocking {
        val model = model(); model.restore(); eventually { model.selectionToken > 0 }
        assertTrue(model.chooseFile(model.selectionToken) { UploadSource("synthetic.spk", null, 3, { "spk".byteInputStream() }) })
        eventually { model.state.value.fileName != null }; assertTrue(fixture.backend.writes.isEmpty()); assertEquals(1, directory.listFiles()!!.size)
        model.upload(); eventually { model.state.value.progress?.phase == NasPackageInstallPhase.OPTIONS && !model.state.value.busy }
        assertTrue(directory.listFiles()!!.isEmpty()); assertEquals("upload", fixture.backend.writes.single().method)
        model.configure("/volume1", true, false, emptyMap()); eventually { model.state.value.activities.single().terminal }
        assertEquals(JsonPrimitive(false), fixture.backend.writes.last().parameters["force"])
    }
    @Test fun `SPK取消选择或写前落盘失败均零上传`() = runBlocking {
        val model = model(); model.restore(); eventually { model.selectionToken > 0 }
        fun source() = UploadSource("synthetic.spk", null, 3, { "spk".byteInputStream() })
        model.chooseFile(model.selectionToken) { source() }; eventually { model.state.value.fileName != null }
        model.clearFile(); model.upload(); assertTrue(directory.listFiles()!!.isEmpty()); assertTrue(fixture.backend.writes.isEmpty())
        model.chooseFile(model.selectionToken) { source() }; eventually { model.state.value.fileName != null }
        preferences.commitSucceeds = false
        model.upload(); eventually { model.state.value.failure != null && !model.state.value.busy }
        assertTrue(fixture.backend.writes.isEmpty()); assertTrue(directory.listFiles()!!.isEmpty())
    }
    @Test fun `SPK回执丢失阻止重复上传冷恢复仅标中断不认领安装或清理`() = runBlocking {
        var model = model(); model.restore(); eventually { model.selectionToken > 0 }
        model.chooseFile(model.selectionToken) { UploadSource("synthetic.spk", null, 3, { "spk".byteInputStream() }) }
        eventually { model.state.value.fileName != null }
        fixture.backend.intercept = { if (it.write) throw IOException("synthetic upload receipt lost") else null }
        model.upload(); eventually { model.state.value.failure != null && !model.state.value.busy }
        val record = model.state.value.activities.single(); assertFalse(record.terminal)
        assertTrue(directory.listFiles()!!.isEmpty()); assertNull(model.state.value.fileName)
        model.chooseFile(model.selectionToken) { UploadSource("synthetic.spk", null, 3, { "spk".byteInputStream() }) }
        eventually { model.state.value.fileName != null }
        model.upload(); eventually { model.state.value.failure != null && !model.state.value.busy }
        assertEquals(NasPackageProblem.BUSY, (model.state.value.failure as NasPackageFailure).problem)
        model.clear(); repository = fixture.repository("restored-upload"); model = model()
        model.restore(); eventually { model.state.value.activities.isNotEmpty() }
        assertEquals(PackageActivityPhase.INTERRUPTED, model.state.value.activities.single().items.single().phase)
        fixture.backend.intercept = null; fixture.backend.installed["Synthetic"] = "2.0"
        model.review(record); eventually { !model.state.value.busy }
        assertEquals(PackageActivityPhase.INTERRUPTED, model.state.value.activities.single().items.single().phase)
        assertNull(model.state.value.progress); assertTrue(directory.listFiles()!!.isEmpty())
        assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `下载取消只清理本次暂存并保存最终状态`() = runBlocking {
        fixture.backend.quick = false; fixture.backend.finished = false
        val model = model(); model.catalog(); eventually { model.state.value.catalog != null }
        model.prepare(model.state.value.catalog!!.entries); eventually { model.state.value.plan != null && !model.state.value.busy }
        model.start(emptyMap(), true); eventually { model.state.value.progress?.phase == NasPackageInstallPhase.DOWNLOADING && !model.state.value.busy }
        model.cancel(); eventually { fixture.backend.writes.any { it.method == "cancel" } && !model.state.value.busy }
        fixture.backend.finished = true
        eventually { model.state.value.activities.single().terminal }
        assertEquals(listOf("install", "cancel", "delete"), fixture.backend.writes.map { it.method })
    }
    @Test fun `准备中的连接替换不能接收迟到结果或上传文件`() = runBlocking {
        val model = model(); model.restore(); eventually { model.selectionToken > 0 }
        val token = model.selectionToken; repository = fixture.repository("other-session")
        assertFalse(model.chooseFile(token) { error("Must not open old selection") }); assertTrue(fixture.backend.writes.isEmpty())
    }
    @Test fun `恢复未知记录阻止当前启停入口绕过安装互斥`() = runBlocking {
        var model = model(); model.catalog(); eventually { model.state.value.catalog != null }
        model.prepare(model.state.value.catalog!!.entries); eventually { model.state.value.plan != null && !model.state.value.busy }
        fixture.backend.intercept = { if (it.write) throw IOException() else null }
        model.start(emptyMap(), true); eventually { model.state.value.progress?.phase == NasPackageInstallPhase.UNKNOWN && !model.state.value.busy }
        model.clear(); repository = fixture.repository("next"); model = model(); model.restore(); eventually { model.state.value.activities.isNotEmpty() }
        try {
            repository.packageCenter.performControl("control", PackageInfo("Synthetic", "Synthetic", "1.0", ResourceState.STOPPED, null, true, false),
                io.github.qwertyuiop1995.dsmnativeclient.PackageMutationOperation.START) { fail("No control during recovery") }
            fail()
        } catch (error: NasPackageFailure) { assertEquals(NasPackageProblem.BUSY, error.problem) }
        assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `503以及multipart外层都保持单次发送`() = runBlocking {
        fixture.statusCode = 503
        val repo = fixture.repository()
        try { repo.packageCenter.gateway.upload(UploadSource("private-name.spk", null, 3, { "spk".byteInputStream() })); fail() } catch (_: DsmFailure) { }
        assertEquals(1, fixture.requests.size); assertTrue(fixture.requests.single().body!!.isOneShot())
        assertFalse(fixture.requests.single().url.toString().contains("synthetic-sid"))
    }
}
