package io.github.qwertyuiop1995.dsmnativeclient.downloads

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class DownloadActionModelTest {
    @Test fun `批量未知停止后项冷恢复只读后显式继续`() = runBlocking {
        val paused = mutableSetOf<String>()
        val writes = AtomicInteger()
        val fixture = DownloadProtocolFixture { fields, _ ->
            if (fields["method"] == "pause") {
                val id = fields.getValue("id"); paused += id
                if (writes.incrementAndGet() == 1) ok("{}") else ok("[{\"id\":\"$id\",\"error\":0}]")
            } else ok("{\"tasks\":[${listOf("one", "two").joinToString(",") { task(it, if (it in paused) "paused" else "downloading") }}]}")
        }
        var repository = fixture.repository()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val store = DownloadActionStore(MemoryPreferences())
        var model = DownloadActionModel(scope, { repository }, { store }, {})
        try {
            assertTrue(model.requestTasks(repository.listDownloads(), DownloadActionKind.PAUSE)); awaitIdle(model)
            val record = model.state.value.records.single()
            assertEquals(listOf(DownloadActionPhase.SUBMITTED, DownloadActionPhase.READY), record.steps.map { it.phase }); assertEquals(1, writes.get())
            model.clear(); repository = fixture.repository(session = "new-session")
            model = DownloadActionModel(scope, { repository }, { store }, {})
            model.restore(); awaitIdle(model)
            assertTrue(model.refresh(record.id)); awaitIdle(model)
            assertEquals(listOf(DownloadActionPhase.COMPLETED, DownloadActionPhase.READY), model.state.value.records.single().steps.map { it.phase })
            assertEquals(1, writes.get())
            assertTrue(model.continuePending(record.id)); awaitIdle(model)
            assertTrue(model.state.value.records.single().terminal); assertEquals(2, writes.get())
        } finally { scope.cancel() }
    }
    @Test fun `失去创建回执刷新和重登均不能认领同名新任务或重发`() = runBlocking {
        val writes = AtomicInteger()
        val fixture = DownloadProtocolFixture { fields, _ ->
            if (fields["method"] == "create") { writes.incrementAndGet(); throw IOException("synthetic lost receipt") }
            else ok("{\"tasks\":[${task("unrelated")}]}")
        }
        var repo = fixture.repository()
        val store = DownloadActionStore(MemoryPreferences()); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var model = DownloadActionModel(scope, { repo }, { store }, {})
        try {
            model.createLink("https://example.invalid/source", null); awaitIdle(model)
            val id = model.state.value.records.single().id
            model.clear(); repo = fixture.repository(session = "new"); model = DownloadActionModel(scope, { repo }, { store }, {})
            model.restore(); awaitIdle(model); model.refresh(id); awaitIdle(model)
            assertEquals(DownloadActionPhase.SUBMITTED, model.state.value.records.single().steps.single().phase)
            model.createLink("https://example.invalid/source", null); awaitIdle(model)
            assertEquals(1, writes.get()); assertNotNull(model.state.value.failure)
        } finally { scope.cancel() }
    }
    @Test fun `移除必须明确确认取消零写入`() = runBlocking {
        val fixture = DownloadProtocolFixture { fields, _ -> assertEquals("list", fields["method"]); ok("{\"tasks\":[${task("one")}]}") }
        val repo = fixture.repository(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val store = DownloadActionStore(MemoryPreferences()); val model = DownloadActionModel(scope, { repo }, { store }, {})
        try {
            model.requestTasks(repo.listDownloads(), DownloadActionKind.REMOVE)
            assertNotNull(model.state.value.confirmation); assertTrue(store.records(requireNotNull(repo.owner)).isEmpty())
            model.cancelConfirmation(); assertNull(model.state.value.confirmation); assertEquals(1, fixture.requests.size)
        } finally { scope.cancel() }
    }
    @Test fun `写前持久失败零控制请求且旧记录不被冲掉`() = runBlocking {
        val fixture = DownloadProtocolFixture { fields, _ -> assertEquals("list", fields["method"]); ok("{\"tasks\":[${task("one")}]}") }
        val repo = fixture.repository(); val preferences = MemoryPreferences(); val store = DownloadActionStore(preferences)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); val model = DownloadActionModel(scope, { repo }, { store }, {})
        try {
            val tasks = repo.listDownloads(); preferences.commitSucceeds = false
            model.requestTasks(tasks, DownloadActionKind.PAUSE); awaitIdle(model)
            assertNotNull(model.state.value.failure); assertEquals(1, fixture.requests.size)
        } finally { scope.cancel() }
    }
    @Test fun `任务文件先复制后明确创建取消和连接切换均不发送`() = runBlocking {
        val fixture = DownloadProtocolFixture { _, _ -> error("不得发送") }; val repo = fixture.repository()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); val store = DownloadActionStore(MemoryPreferences())
        val actions = DownloadActionModel(scope, { repo }, { store }, {})
        var connection: Any? = repo
        val folder = Files.createTempDirectory("download-form-test").toFile()
        val form = DownloadCreationModel(scope, { connection }, { folder }, actions)
        try {
            assertTrue(form.open()); assertTrue(form.chooseFile { UploadSource("synthetic.torrent", null, 3, { "one".byteInputStream() }) })
            withTimeout(5_000) { while (form.state.value.copying) delay(10) }
            assertEquals("synthetic.torrent", form.state.value.filename); assertEquals(1, folder.listFiles()!!.size); assertTrue(fixture.requests.isEmpty())
            form.update(password = " memory-only "); connection = Any()
            assertFalse(form.submit()); form.clear(); assertTrue(folder.listFiles()!!.isEmpty()); assertEquals("", form.state.value.password)
        } finally { form.clear(); scope.cancel(); folder.deleteRecursively() }
    }
    @Test fun `设置多分区未知停止且刷新不会补发未开始分区`() = runBlocking {
        var limit = 10; val writes = AtomicInteger()
        val fixture = DownloadProtocolFixture { fields, _ -> when (fields["method"]) {
            "getinfo" -> ok("{\"is_manager\":true}")
            "getconfig" -> if (fields["api"]!!.endsWith("Schedule")) ok("{\"enabled\":false}") else ok("{\"bt_max_download\":$limit}")
            "setserverconfig" -> { writes.incrementAndGet(); throw IOException("synthetic disconnect") }
            else -> error("计划不得自动发送")
        } }
        val repo = fixture.repository(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val store = DownloadActionStore(MemoryPreferences()); val model = DownloadActionModel(scope, { repo }, { store }, {})
        try {
            val baseline = repo.loadDownloadSettings(); model.requestSettings(baseline, baseline.copy(btDownloadLimitKb = 20, scheduleEnabled = true)); awaitIdle(model)
            val row = model.state.value.records.single(); assertEquals(listOf(DownloadActionPhase.SUBMITTED, DownloadActionPhase.READY), row.steps.map { it.phase })
            limit = 20; model.refresh(row.id); awaitIdle(model)
            assertEquals(listOf(DownloadActionPhase.COMPLETED, DownloadActionPhase.READY), model.state.value.records.single().steps.map { it.phase }); assertEquals(1, writes.get())
        } finally { scope.cancel() }
    }
    @Test fun `旧文件选择回调不能落入新表单`() = runBlocking {
        val fixture = DownloadProtocolFixture { _, _ -> error("不得发送") }; val repo = fixture.repository()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val store = DownloadActionStore(MemoryPreferences()); val actions = DownloadActionModel(scope, { repo }, { store }, {})
        val folder = Files.createTempDirectory("download-picker-test").toFile()
        val form = DownloadCreationModel(scope, { repo }, { folder }, actions)
        try {
            form.open(); val token = form.selectionToken; form.clear(); form.open()
            assertFalse(form.chooseFile(token) { error("旧回调不得打开文件") })
            assertNull(form.state.value.filename); assertTrue(fixture.requests.isEmpty())
        } finally { form.clear(); scope.cancel(); folder.deleteRecursively() }
    }
    @Test fun `同编号订阅更换来源不能把新订阅更新时间认领为原请求`() = runBlocking {
        var url = "https://example.invalid/original"; var updated = 10
        val fixture = DownloadProtocolFixture { fields, _ -> if (fields["method"] == "refresh") ok("{}") else
            ok("""{"total":1,"offset":0,"sites":[{"id":7,"title":"Synthetic RSS","url":"$url","username":"synthetic","is_updating":false,"last_update":$updated}]}""") }
        val repo = fixture.repository(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val store = DownloadActionStore(MemoryPreferences()); val model = DownloadActionModel(scope, { repo }, { store }, {})
        try {
            val site = repo.listDownloadRssSites().single(); model.requestRss(site); awaitIdle(model)
            val record = model.state.value.records.single(); assertEquals(DownloadActionPhase.SUBMITTED, record.steps.single().phase)
            url = "https://example.invalid/replacement"; updated = 20
            model.refresh(record.id); awaitIdle(model)
            assertEquals(DownloadActionPhase.REJECTED, model.state.value.records.single().steps.single().phase)
            assertEquals(1, fixture.fields.count { it["method"] == "refresh" })
        } finally { scope.cancel() }
    }
    private suspend fun awaitIdle(model: DownloadActionModel) { withTimeout(10_000) { while (model.state.value.busy.isNotEmpty() || model.state.value.restoring) delay(10) } }
}
