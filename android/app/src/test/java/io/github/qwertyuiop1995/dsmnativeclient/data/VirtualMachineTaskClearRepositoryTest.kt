package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.After
import org.junit.Test

/** 原批量清理断言迁到正式任务模型，逐项阶段来自正式持久化记录。 */
class VirtualMachineTaskClearRepositoryTest {
    private val scenario = VmmTaskFixture()
    private val fixture get() = scenario.fixture
    private val repo by lazy { scenario.repository() }
    private val store = VmmTaskStore(MemoryPreferences())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private fun model() = VmmTaskModel(scope, { repo }, { store }, { true }, pollAttempts = 1)
    private suspend fun idle(model: VmmTaskModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun prepare(model: VmmTaskModel): List<VmmTaskTarget> {
        assertTrue(model.requestCleanup()); idle(model)
        return requireNotNull(model.state.value.confirmation)
    }
    private suspend fun confirm(model: VmmTaskModel, expected: List<VmmTaskTarget>) {
        assertTrue(model.confirmCleanup(expected)); idle(model)
    }
    private fun stages(model: VmmTaskModel) = model.state.value.cleanups.single().items.map { it.stage }
    private fun tokens() = fixture.writes.map { it.fields.getValue("task_id").toString().trim('"') }
    private fun tasks(vararg entries: Pair<String, Boolean>) { scenario.tasks = linkedMapOf(*entries.map { it.first to VmmTaskFixture.task(it.second) }.toTypedArray()) }
    @After fun cleanup() { scope.cancel() }

    @Test
    fun `完整复核后只清除基线中的已完成任务并严格回读`() = runBlocking {
        tasks("running" to false, "finished-a" to true, "finished-b" to true)
        val model = model(); val expected = prepare(model); assertEquals(2, expected.size)
        confirm(model, expected)
        assertNull(model.state.value.failure)
        assertEquals(listOf(VmmStage.VERIFIED, VmmStage.VERIFIED), stages(model))
        assertEquals(listOf("finished-a", "finished-b"), tokens())
        assertTrue(fixture.writes.all { it.api == TASK_INFO && it.version == 1 && it.method == "clear" && it.oneShot })
        assertEquals(setOf("running"), scenario.tasks.keys)
    }

    @Test
    fun `能力缺失空基线和无已完成任务均零 clear`() = runBlocking {
        fixture.versions = mapOf(TASK_INFO to (2..2))
        val unsupported = model(); assertTrue(unsupported.requestCleanup()); idle(unsupported)
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (unsupported.state.value.failure as DsmFailure).kind)
        assertNull(unsupported.state.value.confirmation); assertTrue(fixture.writes.isEmpty())
        // 能力在 Repository 创建时锁定；独立实例覆盖空表和仅运行中任务。
        val f = VmmTaskFixture(); val r = f.repository(); val s = VmmTaskStore(MemoryPreferences())
        val empty = VmmTaskModel(scope, { r }, { s }, { true })
        assertTrue(empty.requestCleanup()); idle(empty); assertTrue(empty.state.value.nothingToClear)
        assertFalse(empty.confirmCleanup(emptyList()))
        f.tasks["running"] = VmmTaskFixture.task(false)
        assertTrue(empty.requestCleanup()); idle(empty); assertTrue(empty.state.value.nothingToClear)
        assertNull(empty.state.value.confirmation); assertTrue(f.fixture.writes.isEmpty())
    }

    @Test
    fun `基线任务或状态变化时零 clear`() = runBlocking {
        for (removed in listOf(false, true)) {
            tasks("task-a" to true)
            val model = model(); val expected = prepare(model)
            if (removed) scenario.tasks.clear() else scenario.tasks["task-a"] = VmmTaskFixture.task(false)
            confirm(model, expected)
            assertEquals(listOf(VmmStage.CANCELLED), model.state.value.cleanups.first().items.map { it.stage })
            assertTrue(model.state.value.failure is VmmFailure); assertTrue(fixture.writes.isEmpty())
            model.clear()
        }
    }

    @Test
    fun `任务列表顺序变化但完整集合一致时仍可清除`() = runBlocking {
        tasks("running" to false, "finished" to true)
        val model = model(); val expected = prepare(model)
        tasks("finished" to true, "running" to false)
        confirm(model, expected)
        assertEquals(listOf(VmmStage.VERIFIED), stages(model)); assertEquals(listOf("finished"), tokens())
        assertEquals(setOf("running"), scenario.tasks.keys)
    }

    @Test
    fun `无关任务新增不阻断清理而目标快照变化阻止误清`() = runBlocking {
        tasks("finished" to true)
        val model = model(); val expected = prepare(model)
        scenario.tasks["unrelated"] = VmmTaskFixture.task(false)
        confirm(model, expected)
        assertEquals(listOf(VmmStage.VERIFIED), stages(model)); assertEquals(listOf("finished"), tokens())
        scenario.tasks["changed"] = VmmTaskFixture.task()
        val next = prepare(model)
        scenario.tasks["changed"] = VmmTaskFixture.task(progress = JsonPrimitive(90))
        confirm(model, next)
        assertEquals(listOf(VmmStage.CANCELLED), model.state.value.cleanups.first().items.map { it.stage })
        assertEquals(listOf("finished"), tokens())
    }

    @Test
    fun `清除提交异常后不继续后项不重放且只读恢复不追认`() = runBlocking {
        tasks("task-a" to true, "task-b" to true)
        val model = model(); val expected = prepare(model)
        fixture.after = { if (it.method == "clear") throw IOException("synthetic lost receipt") }
        confirm(model, expected)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), stages(model))
        assertEquals(listOf("task-a"), tokens()); assertEquals(setOf("task-b"), scenario.tasks.keys)
        fixture.after = {}; model.clear(); val restored = model(); restored.refresh(); idle(restored)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), stages(restored)); assertEquals(listOf("task-a"), tokens())
    }

    @Test
    fun `未提交任务并发消失不计入本批成功且计数不重叠`() = runBlocking {
        tasks("task-a" to true, "task-b" to true)
        val model = model(); val expected = prepare(model)
        fixture.after = { if (it.method == "clear") { scenario.tasks.remove("task-b"); throw IOException("synthetic lost receipt") } }
        confirm(model, expected)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), stages(model))
        assertEquals(listOf("task-a"), tokens()); assertTrue(scenario.tasks.isEmpty())
        fixture.after = {}; model.clear(); val restored = model(); restored.refresh(); idle(restored)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), stages(restored)); assertEquals(listOf("task-a"), tokens())
    }

    @Test
    fun `提交后取消保留提交且不清除后续任务`() = runBlocking {
        tasks("task-a" to true, "task-b" to true)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val model = model(); val expected = prepare(model)
        fixture.before = { if (it.method == "clear") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        assertTrue(model.confirmCleanup(expected)); assertTrue(entered.await(5, TimeUnit.SECONDS))
        model.clear(); release.countDown()
        val restored = model(); restored.refresh(); idle(restored)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), stages(restored)); assertEquals(listOf("task-a"), tokens())
        assertEquals(setOf("task-b"), scenario.tasks.keys)
    }

    @Test
    fun `clear 成功响应但任务仍存在时保持接受未完成`() = runBlocking {
        tasks("task-a" to true, "task-b" to true)
        val model = model(); val expected = prepare(model); fixture.applyWrite = false
        confirm(model, expected)
        assertEquals(listOf(VmmStage.ACCEPTED, VmmStage.CANCELLED), stages(model)); assertEquals(listOf("task-a"), tokens())
        model.refresh(); idle(model)
        assertEquals(listOf(VmmStage.ACCEPTED, VmmStage.CANCELLED), stages(model)); assertEquals(listOf("task-a"), tokens())
    }

    @Test
    fun `同一批清除并发调用只有一个能够提交`() = runBlocking {
        tasks("task-a" to true)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val model = model(); val expected = prepare(model)
        fixture.before = { if (it.method == "clear") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        assertTrue(model.confirmCleanup(expected)); assertTrue(entered.await(5, TimeUnit.SECONDS))
        assertFalse(model.confirmCleanup(expected)); assertFalse(model.requestCleanup())
        // 仓储互斥也保护绕过同一 UI 实例的并发调用。
        val duplicate = runCatching { repo.virtualMachineManagement.clearTask(expected.single()) {} }.exceptionOrNull()
        assertEquals(VmmProblem.CHANGED, (duplicate as VmmFailure).problem)
        release.countDown(); idle(model)
        assertEquals(listOf(VmmStage.VERIFIED), stages(model)); assertEquals(listOf("task-a"), tokens())
    }

    private companion object { const val TASK_INFO = "SYNO.Virtualization.API.Task.Info" }
}
