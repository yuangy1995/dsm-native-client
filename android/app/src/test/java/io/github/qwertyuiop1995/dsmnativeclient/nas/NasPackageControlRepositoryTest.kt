package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.PackageMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasPackageControlRepositoryTest {
    private val start = PackageMutationOperation.START
    private val stop = PackageMutationOperation.STOP
    private val uninstall = PackageMutationOperation.UNINSTALL
    @Test fun `表单JSON三动作固定版本原应用数组可行性先于单次写入`() = runBlocking {
        for (format in listOf("FORM", "JSON")) for (action in PackageMutationOperation.entries) {
            val f = NasPackageControlFixture().also { it.format = format; it.directory = NasPackageControlFixture.directory(NasPackageControlFixture.row(if (action == stop) "running" else "stopped")) }
            val r = f.repository().packageCenter; val original = r.controlInstalled().single()
            f.afterWrite = if (action == uninstall) NasPackageControlFixture.directory() else NasPackageControlFixture.directory(NasPackageControlFixture.row(if (action == start) "running" else "stopped"))
            val events = mutableListOf<NasPackageCheckpoint>(); r.performControl("record", original, action) { events += it }
            assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.ACCEPTED, NasPackageWriteStage.VERIFIED), events.map { it.stage })
            val write = f.writes.single(); assertTrue(write.oneShot); assertEquals(1, write.version); assertEquals(action.name.lowercase(), write.method)
            assertEquals(if (format == "JSON") "\"synthetic-package\"" else "synthetic-package", write.fields["id"])
            if (action == stop) assertFalse(write.fields.containsKey("dsm_apps")) else assertEquals("[\"synthetic-app\"]", write.fields["dsm_apps"])
            val preflight = f.calls.single { it.method == "feasibility_check" }; assertEquals(1, preflight.version)
            assertEquals(if (format == "JSON") "\"${write.method}_check\"" else "${write.method}_check", preflight.fields["type"])
            assertEquals("[\"synthetic-package\"]", preflight.fields["packages"]); assertTrue(f.calls.indexOf(preflight) < f.calls.indexOf(write))
            assertTrue(f.calls.filter { it.method == "list" }.all { it.version == 2 }); assertEquals(1_700_000_000.0, original.installedAt)
        }
    }
    @Test fun `原安装权限和状态漂移零写而文案变化不影响身份`() = runBlocking {
        val f = NasPackageControlFixture(); val r = f.repository().packageCenter; val original = r.controlInstalled().single()
        val changed = listOf(
            NasPackageControlFixture.row(timestamp = 1_700_000_001), NasPackageControlFixture.row("running"),
            NasPackageControlFixture.changed(key = "version", value = JsonPrimitive("2"), additional = false),
            NasPackageControlFixture.changed(key = "install_type", value = JsonPrimitive("system")),
            NasPackageControlFixture.changed(key = "dsm_apps", value = JsonArray(emptyList())),
            NasPackageControlFixture.changed(key = "ctl_uninstall", value = JsonPrimitive(false)),
            NasPackageControlFixture.changed(key = "startable", value = JsonPrimitive(false)))
        for (row in changed) { f.directory = NasPackageControlFixture.directory(row); rejected { r.performControl("record", original, start) { fail() } } }
        assertTrue(f.writes.isEmpty()); assertFalse(f.calls.any { it.method == "feasibility_check" })
        f.directory = NasPackageControlFixture.directory(NasPackageControlFixture.changed(key = "name", value = JsonPrimitive("Renamed"), additional = false))
        f.afterWrite = NasPackageControlFixture.directory(NasPackageControlFixture.row("running"))
        r.performControl("record", original, start) {}; assertEquals(1, f.writes.size)
    }
    @Test fun `目录必须完整严格且字符串应用和毫秒时间可兼容`() = runBlocking {
        val f = NasPackageControlFixture(); val r = f.repository().packageCenter
        val invalidRows = listOf(
            NasPackageControlFixture.changed(key = "timestamp", value = JsonPrimitive("1700000000"), additional = false),
            NasPackageControlFixture.changed(key = "timestamp", value = JsonPrimitive(-1), additional = false),
            NasPackageControlFixture.changed(key = "id", value = JsonPrimitive("bad\nid"), additional = false),
            NasPackageControlFixture.changed(key = "version", value = JsonPrimitive(1), additional = false),
            NasPackageControlFixture.changed(key = "dsm_apps", value = JsonPrimitive(1)),
            NasPackageControlFixture.changed(key = "dsm_apps", value = JsonArray(listOf(JsonPrimitive("app"), JsonPrimitive(false)))),
            NasPackageControlFixture.changed(key = "dsm_apps", value = JsonNull),
            NasPackageControlFixture.changed(key = "available_operation", value = null),
            NasPackageControlFixture.changed(key = "startable", value = null),
            NasPackageControlFixture.row("offline"), NasPackageControlFixture.row("finished"), NasPackageControlFixture.row("unknown"))
        for (row in invalidRows) { f.directory = NasPackageControlFixture.directory(row); rejected { r.controlInstalled() } }
        val row = NasPackageControlFixture.row()
        for (data in listOf(JsonObject(emptyMap()), NasPackageControlFixture.directory(row, row),
            JsonObject(NasPackageControlFixture.directory() + ("total" to JsonPrimitive(1))),
            JsonObject(NasPackageControlFixture.directory(row) + ("total" to JsonPrimitive("1"))),
            buildJsonObject { put("packages", JsonArray(List(1000) { row })) })) {
            f.directory = data; rejected { r.controlInstalled() }
        }
        f.directory = NasPackageControlFixture.directory(NasPackageControlFixture.changed(NasPackageControlFixture.row(timestamp = 1_700_000_000_000), "dsm_apps", JsonPrimitive("synthetic-app another-app")))
        val value = r.controlInstalled().single(); assertEquals(listOf("synthetic-app", "another-app"), value.dsmApps); assertEquals(1_700_000_000.0, value.installedAt)
        for (type in listOf("system", "system_hidden")) {
            f.directory = NasPackageControlFixture.directory(NasPackageControlFixture.changed(key = "install_type", value = JsonPrimitive(type)))
            assertFalse(r.controlInstalled().single().canUninstall)
        }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `接口版本缺失零请求权限失效和预检拒绝零写`() = runBlocking {
        val original = NasPackageControlFixture().repository().packageCenter.controlInstalled().single()
        for ((api, range) in listOf("SYNO.Core.Package" to 2..3, "SYNO.Core.Package" to 1..1, "SYNO.Core.Package.Control" to 2..3)) {
            val f = NasPackageControlFixture().also { it.versions = mapOf(api to range) }; val r = f.repository().packageCenter; f.calls.clear()
            rejected { r.performControl("record", original, start) { fail() } }; assertTrue(f.calls.isEmpty())
        }
        for (condition in listOf(0, 2, 3)) {
            val f = NasPackageControlFixture(); val r = f.repository().packageCenter
            f.admin = condition != 0; f.known = false; f.ownerValid = condition != 2
            if (condition == 3) { f.rejection = 105; f.rejectMethod = "feasibility_check" }
            rejected { r.performControl("record", original, start) { fail() } }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `明确拒绝不回读未知只回读原安装且检查点失败不能继续`() = runBlocking {
        val f = NasPackageControlFixture(); val r = f.repository().packageCenter; val original = r.controlInstalled().single()
        f.rejection = 105; val events = mutableListOf<NasPackageWriteStage>()
        rejected { r.performControl("reject", original, start) { events += it.stage } }
        assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.REJECTED), events)
        assertEquals("start", f.calls.last().method); assertFalse(r.preferencePending)
        f.rejection = null; f.calls.clear(); events.clear()
        rejected { r.performControl("save", original, start) { throw DsmFailure(null, "Synthetic", "", kind = DsmErrorKind.LOCAL_STORAGE_FAILED) } }
        assertTrue(f.writes.isEmpty())
        f.before = { if (it.oneShot) { f.directory = NasPackageControlFixture.directory(NasPackageControlFixture.row("running")); throw IOException("Lost receipt") } }
        r.performControl("lost", original, start) { events += it.stage }
        assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.VERIFIED), events); assertEquals(1, f.writes.size)
        f.before = {}; f.directory = NasPackageControlFixture.directory(); f.calls.clear()
        assertFalse(packageControlMatches(r.controlInstalled(), original.id, packageInstallationDigest(original), start))
        assertFalse(packageControlMatches(listOf(original.copy(status = ResourceState.RUNNING, installedAt = 1.0)), original.id, packageInstallationDigest(original), start))
    }
    @Test fun `十次三次上限卸载单次与共享安装互斥`() = runBlocking {
        val backend = NasPackageFixture(); var rows = listOf(PackageInfo("synthetic", "Synthetic", "1", ResourceState.STOPPED, null, true, false, true))
        var reads = 0; var pauses = 0
        val r = NasPackageRepository(backend, { _, _ -> true }, { reads++; rows }, { pauses++ })
        backend.intercept = { if (it.write) JsonObject(emptyMap()) else null }
        val original = rows.single(); val events = mutableListOf<NasPackageWriteStage>()
        r.performControl("accepted", original, start) { events += it.stage }; assertEquals(11, reads); assertEquals(9, pauses)
        assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.ACCEPTED), events)
        rejected { r.performControl("blocked", original, start) { fail() } }; r.preferencePending = false; reads = 0; pauses = 0; events.clear()
        backend.intercept = { if (it.write) throw IOException() else null }
        r.performControl("unknown", original, start) { events += it.stage }; assertEquals(4, reads); assertEquals(2, pauses)
        r.preferencePending = false; reads = 0; pauses = 0; events.clear()
        r.performControl("remove", original, uninstall) { events += it.stage }; assertEquals(2, reads); assertEquals(0, pauses)
        assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT), events)
    }
    @Test fun `接受落盘失败立即停止且取消只读一次权限异常不轮询`() = runBlocking {
        val backend = NasPackageFixture()
        val original = PackageInfo("Synthetic", "Synthetic", "1", ResourceState.STOPPED, null, true, false, true)
        var reads = 0; var revoked = false
        val r = NasPackageRepository(backend, { _, _ -> true }, {
            reads++
            if (revoked) throw DsmFailure(105, "Synthetic denied", "", kind = DsmErrorKind.PERMISSION_DENIED)
            listOf(original)
        }, { fail("No extra polling") })
        backend.intercept = { if (it.write) JsonObject(emptyMap()) else null }
        rejected { r.performControl("save", original, start) {
            if (it.stage == NasPackageWriteStage.ACCEPTED) throw DsmFailure(null, "Synthetic", "", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
        } }
        assertEquals(1, reads); assertEquals(1, backend.writes.size)
        r.preferencePending = false; reads = 0
        backend.intercept = { if (it.write) throw CancellationException("Synthetic cancellation") else null }
        try { r.performControl("cancel", original, start) {}; fail() } catch (_: CancellationException) { }
        assertEquals(2, reads); assertEquals(2, backend.writes.size)
        r.preferencePending = false; reads = 0
        backend.intercept = { if (it.write) { revoked = true; JsonObject(emptyMap()) } else null }
        rejected { r.performControl("denied", original, start) {} }; assertEquals(2, reads); assertEquals(3, backend.writes.size)
    }
    @Test fun `取消旧下载读取后接受取消仍可继续读取完成清理`() = runBlocking {
        val backend = NasPackageFixture().also { it.quick = false; it.finished = false }
        val repo = NasPackageRepository(backend)
        val plan = repo.prepare(listOf("Synthetic:stable"))
        val progress = repo.start(plan.id, emptyMap(), false) {}
        backend.intercept = { if (it.method == "status") throw CancellationException("Synthetic cancelled read") else null }
        try { repo.advance(progress.id); fail() } catch (_: CancellationException) { }
        assertEquals(NasPackageInstallPhase.UNKNOWN, repo.job!!.progress.phase)
        backend.intercept = null
        assertEquals(NasPackageInstallPhase.DOWNLOADING, repo.cancel(progress.id).phase)
        backend.finished = true
        assertEquals(NasPackageInstallPhase.CANCELLED, repo.advance(progress.id).phase)
        assertEquals(listOf("install", "cancel", "delete"), backend.writes.map { it.method })
    }
    private suspend fun rejected(block: suspend () -> Any?) { try { block(); fail("Expected rejection") } catch (error: Exception) { assertTrue(error is DsmFailure || error is NasPackageFailure) } }
}
