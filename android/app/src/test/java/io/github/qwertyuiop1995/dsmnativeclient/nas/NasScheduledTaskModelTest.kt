package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasScheduledTaskModelTest {
    private val fixture = NasTaskProtocolFixture()
    private var repository = fixture.repository()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val preferences = MemoryPreferences()
    private val store = NasTaskActivityStore(preferences)
    private fun model() = NasScheduledTaskModel(scope, { repository }, { store })
    private suspend fun loaded(model: NasScheduledTaskModel) { model.load(); eventually { !model.state.value.loading && model.state.value.tasks != null } }
    private suspend fun inspect(model: NasScheduledTaskModel) { model.inspect(model.state.value.tasks!!.first()); eventually { !model.state.value.detailLoading && model.state.value.detail != null } }
    private suspend fun eventually(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(10) }; delay(20) }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `真实协议创建保存运行删除单次请求与账本一致`() = runBlocking {
        val model = model(); loaded(model); inspect(model); model.edit()
        model.save(model.state.value.editor!!.copy(script = "echo changed")); assertEquals(0, fixture.backend.requests.count { it.write })
        model.confirm(); eventually { model.state.value.records.singleOrNull()?.terminal == true && !model.state.value.busy }
        inspect(model); assertEquals("echo changed", model.state.value.detail!!.script)
        model.request(NasTaskAction.RUN); model.confirm(); eventually { model.state.value.records.size == 2 && !model.state.value.busy }
        inspect(model); model.request(NasTaskAction.DELETE); model.confirm(); eventually { model.state.value.tasks?.isEmpty() == true && !model.state.value.busy }
        model.create(); model.save(model.state.value.editor!!.copy(name = "Created", script = "echo created")); model.confirm()
        eventually { model.state.value.records.size == 4 && !model.state.value.busy }
        assertTrue(model.state.value.records.all { it.terminal && it.accepted }); assertEquals("Created", model.state.value.tasks!!.single().name)
        assertEquals(4, fixture.backend.requests.count { it.write }); assertEquals(4, fixture.requests.count { it.body?.isOneShot() == true })
        assertFalse(preferences.all.values.joinToString().contains("echo"))
    }
    @Test fun `未知运行冷启动只读恢复不能被已有历史解除`() = runBlocking {
        var model = model(); loaded(model); inspect(model); fixture.backend.responseFailure = IOException("Synthetic lost receipt")
        model.request(NasTaskAction.RUN); model.confirm(); eventually { model.state.value.records.singleOrNull()?.terminal == false && !model.state.value.busy }
        val id = model.state.value.records.single().id; model.clear(); repository = fixture.repository("next"); model = model(); loaded(model)
        model.review(id); eventually { !model.state.value.busy }; assertFalse(model.state.value.writable); assertFalse(model.state.value.records.single().accepted)
        model.create(); assertNull(model.state.value.editor); assertEquals(1, fixture.backend.requests.count { it.write })
        assertTrue(fixture.backend.requests.none { it.method == "result_list" })
    }
    @Test fun `接受后读取失败只按原id与全部字段恢复不重发`() = runBlocking {
        val model = model(); loaded(model); inspect(model); model.edit()
        fixture.backend.afterWrite = { fixture.backend.readFailure = IOException("Synthetic offline") }
        model.save(model.state.value.editor!!.copy(script = "echo changed")); model.confirm()
        eventually { model.state.value.records.singleOrNull()?.accepted == true && !model.state.value.busy }; val id = model.state.value.records.single().id
        assertFalse(model.state.value.records.single().terminal); fixture.backend.readFailure = null
        val original = fixture.backend.rows.single(); fixture.backend.rows = listOf(JsonObject(original + ("real_owner" to JsonPrimitive("Other"))))
        model.review(id); eventually { !model.state.value.busy }; assertFalse(model.state.value.records.single().terminal)
        fixture.backend.rows = listOf(original); model.review(id); eventually { model.state.value.records.single().terminal && !model.state.value.busy }
        assertEquals(1, fixture.backend.requests.count { it.write })
    }
    @Test fun `详情历史输出按需读取关闭页面清空敏感数据`() = runBlocking {
        val model = model(); loaded(model); assertTrue(fixture.backend.requests.none { it.method == "get" })
        inspect(model); assertNull(model.state.value.results); model.results(); eventually { model.state.value.results != null && !model.state.value.resultsLoading }
        assertTrue(fixture.backend.requests.none { it.method == "result_get_file" }); model.output(model.state.value.results!!.single())
        eventually { model.state.value.output != null }; assertEquals("synthetic output", model.state.value.output!!.output)
        model.closeOutput(); assertNull(model.state.value.output); assertNull(model.state.value.selectedResult)
        model.edit(); model.leavePage(); assertNull(model.state.value.detail); assertNull(model.state.value.editor); assertNull(model.state.value.results)
    }
    @Test fun `写前存储失败和连接替换零写入但未知环境允许操作`() = runBlocking {
        val model = model(); loaded(model); inspect(model); model.request(NasTaskAction.RUN)
        repository = fixture.repository("replacement"); model.confirm(); delay(50); assertTrue(fixture.backend.requests.none { it.write })
        loaded(model); inspect(model); model.request(NasTaskAction.DELETE); preferences.commitSucceeds = false; model.confirm()
        eventually { model.state.value.failure != null && !model.state.value.busy }; assertFalse(model.state.value.writable); assertTrue(fixture.backend.requests.none { it.write })
        val unknown = NasTaskProtocolFixture(); unknown.knownEnvironment = false; val repo = unknown.repository(); val task = repo.scheduledTasks.tasks().single()
        repo.scheduledTasks.change(NasTaskChange(NasTaskAction.DELETE, task)) {}
        assertEquals(1, unknown.backend.requests.count { it.write })
    }
    @Test fun `FORM与JSON均保持嵌套对象数字布尔和真实选择器`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            val transport = NasTaskProtocolFixture(); transport.requestFormat = format; val repo = transport.repository()
            val task = repo.scheduledTasks.tasks().single(); val original = repo.scheduledTasks.inspect(task)!!
            assertTrue(repo.scheduledTasks.change(NasTaskChange(NasTaskAction.SAVE, task, original, original.copy(script = "echo synthetic & data"))) { })
            val sent = transport.backend.requests.single { it.write }
            assertEquals(4, sent.version); assertEquals(JsonPrimitive(10L), sent.fields["id"])
            assertEquals(JsonPrimitive("Synthetic selector"), sent.fields["real_owner"]); assertEquals(JsonPrimitive(true), sent.fields["enable"])
            assertEquals(JsonPrimitive("echo synthetic & data"), sent.fields.getValue("extra").jsonObject["script"])
        }
    }
    @Test fun `版本不足不发创建请求确认失败保留草稿`() = runBlocking {
        val limited = NasTaskProtocolFixture(); limited.maxVersion = 3; val repo = limited.repository(); assertFalse(repo.scheduledTasks.canCreate)
        try { repo.scheduledTasks.newDraft(); fail() } catch (_: DsmFailure) { }; assertTrue(limited.requests.isEmpty())
        val model = model(); loaded(model); inspect(model); model.edit(); model.save(model.state.value.editor!!.copy(script = "echo changed"))
        fixture.backend.rows = listOf(JsonObject(fixture.backend.rows.single() + ("can_edit" to JsonPrimitive(false))))
        model.confirm(); eventually { model.state.value.failure != null && !model.state.value.busy }
        assertNull(model.state.value.confirmation); assertNotNull(model.state.value.editor); assertTrue(model.state.value.records.isEmpty())
        assertTrue(fixture.backend.requests.none { it.write })
    }
    @Test fun `切换任务清除旧读取状态并拒绝迟到历史`() = runBlocking {
        val entered = java.util.concurrent.CountDownLatch(1); val release = java.util.concurrent.CountDownLatch(1)
        fixture.backend.rows += JsonObject(fixture.backend.rows.single() + mapOf("id" to JsonPrimitive(11L), "name" to JsonPrimitive("Next task")))
        fixture.backend.details[11] = JsonObject(fixture.backend.details.getValue(10) + mapOf("id" to JsonPrimitive(11L), "name" to JsonPrimitive("Next task")))
        val model = model(); loaded(model); inspect(model)
        fixture.backend.beforeRead = { if (it == "result_list") { entered.countDown(); check(release.await(5, java.util.concurrent.TimeUnit.SECONDS)) } }
        try {
            model.results(); assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS)); assertTrue(model.state.value.resultsLoading)
            model.inspect(model.state.value.tasks!!.last()); eventually { model.state.value.detail?.id == 11L }
            assertFalse(model.state.value.resultsLoading); assertFalse(model.state.value.outputLoading); release.countDown(); delay(50)
            assertNull(model.state.value.results); assertNull(model.state.value.resultsFailure)
        } finally { release.countDown() }
    }
}
