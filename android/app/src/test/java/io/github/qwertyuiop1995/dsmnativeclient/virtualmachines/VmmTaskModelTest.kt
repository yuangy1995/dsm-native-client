package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class VmmTaskModelTest {
    private val scenario = VmmTaskFixture(); private val fixture get() = scenario.fixture
    private var repository = scenario.repository(); private val preferences = MemoryPreferences(); private var store = VmmTaskStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = VmmTaskModel(scope, { repository }, { store }, { canStart }, pollAttempts = 1)
    private suspend fun idle(model: VmmTaskModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun send(model: VmmTaskModel, name: String = "Imported image") { assertTrue(model.startImport(scenario.target(name))); assertFalse(model.startImport(scenario.target(name))); idle(model) }
    private suspend fun cold(old: VmmTaskModel, identity: String = "identity"): VmmTaskModel {
        old.clear(); repository = scenario.repository("next-generation", identity); store = VmmTaskStore(preferences)
        return model().also { it.refresh(); idle(it) }
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `一次导入完成可移除记录且不会自动清理NAS任务`() = runBlocking {
        val model = model(); send(model); assertNull(model.state.value.failure)
        val record = model.state.value.imports.single(); assertEquals(VmmStage.VERIFIED, record.progress.stage)
        assertEquals(1, fixture.writes.size); assertEquals(1, scenario.tasks.size)
        model.dismiss(record.id, VmmTaskAction.IMPORT); assertTrue(model.state.value.imports.isEmpty())
    }
    @Test fun `导入冷启动只读跟踪原任务缺回执同名保持禁止`() = runBlocking {
        scenario.finished = false; val model = model(); send(model)
        assertEquals(VmmStage.ACCEPTED, model.state.value.imports.single().progress.stage)
        scenario.tasks[scenario.taskId] = VmmTaskFixture.task(true, scenario.imageId)
        val next = cold(model); assertEquals(VmmStage.VERIFIED, next.state.value.imports.single().progress.stage); assertEquals(1, fixture.writes.size)
        scenario.missingReceipt = true; scenario.taskId = "second-task"; scenario.imageId = "second-image"; send(next, "Another image")
        val unknown = cold(next); assertEquals(VmmStage.SUBMITTED, unknown.state.value.imports.first().progress.stage)
        assertFalse(unknown.startImport(scenario.target("ANOTHER IMAGE"))); assertEquals(2, fixture.writes.size)
        unknown.dismiss(unknown.state.value.imports.first().id, VmmTaskAction.IMPORT); assertTrue(unknown.state.value.imports.first().pending)
    }
    @Test fun `任务清理取消零写确认后双击被挡逐项完成`() = runBlocking {
        scenario.tasks["one"] = VmmTaskFixture.task(); scenario.tasks["two"] = VmmTaskFixture.task(); scenario.tasks["running"] = VmmTaskFixture.task(false)
        val model = model(); assertTrue(model.requestCleanup()); idle(model); model.cancelCleanup(); assertTrue(fixture.writes.isEmpty())
        assertTrue(model.requestCleanup()); idle(model); val expected = model.state.value.confirmation!!; assertEquals(2, expected.size)
        assertTrue(model.confirmCleanup(expected)); assertFalse(model.confirmCleanup(expected)); idle(model)
        assertEquals(listOf(VmmStage.VERIFIED, VmmStage.VERIFIED), model.state.value.cleanups.single().items.map { it.stage })
        assertEquals(setOf("running"), scenario.tasks.keys); assertEquals(2, fixture.writes.size)
    }
    @Test fun `清理首项回执丢失不继续批次且冷恢复不追认消失`() = runBlocking {
        scenario.tasks["one"] = VmmTaskFixture.task(); scenario.tasks["two"] = VmmTaskFixture.task()
        fixture.after = { if (it.method == "clear") throw IOException("lost synthetic receipt") }
        val model = model(); model.requestCleanup(); idle(model); model.confirmCleanup(model.state.value.confirmation!!); idle(model)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), model.state.value.cleanups.single().items.map { it.stage })
        fixture.after = {}; val next = cold(model)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), next.state.value.cleanups.single().items.map { it.stage }); assertEquals(1, fixture.writes.size)
        assertEquals(setOf("two"), scenario.tasks.keys)
    }
    @Test fun `有清理回执但回读失败允许冷恢复仅标记已接受项`() = runBlocking {
        scenario.tasks["one"] = VmmTaskFixture.task(); val model = model(); model.requestCleanup(); idle(model)
        var sent = false; fixture.after = { if (it.method == "clear") sent = true }
        fixture.before = { if (sent && it.method == "list") throw IOException("read failed") }
        model.confirmCleanup(model.state.value.confirmation!!); idle(model)
        assertEquals(VmmStage.ACCEPTED, model.state.value.cleanups.single().items.single().stage)
        fixture.before = {}; fixture.after = {}; val next = cold(model)
        assertEquals(VmmStage.VERIFIED, next.state.value.cleanups.single().items.single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `恢复中的导入原任务与同名映像不能被清理或删除`() = runBlocking {
        scenario.finished = false; val model = model(); send(model)
        scenario.tasks[scenario.taskId] = VmmTaskFixture.task(true, scenario.imageId)
        scenario.tasks["unrelated"] = VmmTaskFixture.task()
        assertTrue(model.protectsImage(scenario.imageId, "Imported image")); assertFalse(model.protectsImage("other", "Other"))
        assertTrue(model.requestCleanup()); idle(model)
        assertEquals(listOf("unrelated"), model.state.value.confirmation!!.map { it.token })
        model.confirmCleanup(model.state.value.confirmation!!); idle(model); assertTrue(scenario.tasks.containsKey(scenario.taskId))
    }
    @Test fun `写前持久化失败外部互锁变化和账号隔离均阻止误写`() = runBlocking {
        val model = model(); canStart = false; assertFalse(model.startImport(scenario.target())); assertFalse(model.requestCleanup()); canStart = true
        preferences.commitSucceeds = false; send(model); assertTrue(fixture.writes.isEmpty()); assertNotNull(model.state.value.failure)
        preferences.commitSucceeds = true; store = VmmTaskStore(preferences); model.refresh(); idle(model)
        assertEquals(VmmStage.CANCELLED, model.state.value.imports.single().progress.stage)
        scenario.finished = false; send(model)
        val next = cold(model, "other"); assertTrue(next.state.value.imports.isEmpty()); assertEquals(1, fixture.writes.size)
    }
    @Test fun `单项导入读取失败不妨碍其他原任务恢复`() = runBlocking {
        scenario.finished = false; val model = model(); send(model)
        scenario.taskId = "second-task"; scenario.imageId = "second-image"; send(model, "Second image")
        scenario.tasks["import-task"] = VmmTaskFixture.task(true, "new-image")
        fixture.before = { if (it.method == "get" && it.fields["task_id"].toString() == "\"second-task\"") throw IOException("synthetic read failure") }
        val next = cold(model); assertNotNull(next.state.value.failure)
        assertEquals(VmmStage.VERIFIED, next.state.value.imports.single { it.progress.task == "import-task" }.progress.stage)
        assertEquals(VmmStage.ACCEPTED, next.state.value.imports.single { it.progress.task == "second-task" }.progress.stage); assertEquals(2, fixture.writes.size)
    }
    @Test fun `切换账号的迟到导入回执不能填入新工作区`() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.method == "create") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        val model = model(); assertTrue(model.startImport(scenario.target())); assertTrue(entered.await(5, TimeUnit.SECONDS))
        model.clear(); repository = scenario.repository("next", "other"); release.countDown(); delay(150)
        model.refresh(); idle(model); assertTrue(model.state.value.imports.isEmpty()); assertEquals(1, fixture.writes.size)
    }
}
