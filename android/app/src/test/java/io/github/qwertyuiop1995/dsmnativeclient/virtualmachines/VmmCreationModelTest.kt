package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class VmmCreationModelTest {
    private val scenario = VmmCreationFixture(); private val fixture get() = scenario.fixture
    private var repository = scenario.repository(); private val preferences = MemoryPreferences(); private var store = VmmCreationStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = VmmCreationModel(scope, { repository }, { store }, { canStart }, pollAttempts = 1)
    private suspend fun idle(model: VmmCreationModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun open(model: VmmCreationModel, name: String = "Synthetic created") {
        assertTrue(model.open()); idle(model); assertNull(model.state.value.failure)
        model.change(model.state.value.draft!!.copy(name = name))
    }
    private suspend fun send(model: VmmCreationModel) { assertTrue(model.create()); assertFalse(model.create()); idle(model) }
    private suspend fun cold(old: VmmCreationModel, identity: String = "identity"): VmmCreationModel {
        old.clear(); repository = fixture.repository("next-generation", identity); store = VmmCreationStore(preferences)
        return model().also { it.refresh(); idle(it) }
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `取消无写创建防双击并清除编辑草稿`() = runBlocking {
        val model = model(); assertFalse(model.create()); open(model); model.close(); assertTrue(fixture.writes.isEmpty())
        open(model); send(model); assertEquals(listOf("create", "set"), fixture.writes.map { it.method })
        assertEquals(VmmCreationStage.COMPLETE, model.state.value.records.single().progress.stage)
        assertNull(model.state.value.draft); assertFalse(model.state.value.editor)
        model.dismiss(model.state.value.records.single().id); assertTrue(model.state.value.records.isEmpty())
    }
    @Test fun `冷启动只读完成原创建后必须审阅原配置再续写`() = runBlocking {
        scenario.finished = false; val model = model(); open(model); send(model)
        assertEquals(VmmCreationStage.CREATING, model.state.value.records.single().progress.stage)
        scenario.finished = true; val next = cold(model)
        assertEquals(VmmCreationStage.CREATED, next.state.value.records.single().progress.stage); assertEquals(1, fixture.writes.size)
        assertFalse(next.continueCreation()); assertTrue(next.review(next.state.value.records.single().id)); assertTrue(next.continueCreation()); assertFalse(next.continueCreation()); idle(next)
        assertEquals(VmmCreationStage.COMPLETE, next.state.value.records.single().progress.stage); assertEquals(2, fixture.writes.size)
    }
    @Test fun `设置接受但回读失败冷恢复后不自动开机`() = runBlocking {
        val model = model(); open(model); model.change(model.state.value.draft!!.copy(powerOn = true))
        var set = false
        fixture.after = { if (it.method == "set") set = true }
        fixture.before = { if (set && it.method == "get") throw IOException("read failed") }
        send(model); assertEquals(VmmCreationStage.CONFIGURING, model.state.value.records.single().progress.stage)
        fixture.before = {}; fixture.after = {}; val next = cold(model)
        assertEquals(VmmCreationStage.CONFIGURED, next.state.value.records.single().progress.stage); assertEquals(2, fixture.writes.size)
        assertTrue(next.review(next.state.value.records.single().id)); assertTrue(next.continueCreation()); idle(next)
        assertEquals(VmmCreationStage.COMPLETE, next.state.value.records.single().progress.stage); assertEquals(3, fixture.writes.size)
    }
    @Test fun `缺设置回执保留未知记录并且同名不能重新创建`() = runBlocking {
        fixture.after = { if (it.method == "set") throw IOException("lost receipt") }
        val model = model(); open(model); send(model); assertEquals(VmmCreationStage.CONFIGURE_SENT, model.state.value.records.single().progress.stage)
        fixture.after = {}; val next = cold(model); val record = next.state.value.records.single()
        next.dismiss(record.id); assertTrue(next.hasPending()); assertFalse(next.review(record.id)); assertFalse(next.continueCreation())
        open(next); send(next); assertEquals(2, fixture.writes.size); assertEquals(VmmCreationStage.CONFIGURE_SENT, next.state.value.records.single().progress.stage)
    }
    @Test fun `持久化失败零写且外部互锁变化阻止创建`() = runBlocking {
        val model = model(); canStart = false; assertFalse(model.open()); canStart = true; open(model)
        canStart = false; assertFalse(model.create()); assertTrue(model.state.value.editor); canStart = true
        preferences.commitSucceeds = false; send(model); assertTrue(fixture.writes.isEmpty()); assertTrue(model.state.value.failure is VmmFailure)
    }
    @Test fun `跨账号不能读取创建配置同身份新登录保留原选择`() = runBlocking {
        scenario.finished = false; val model = model(); open(model); send(model)
        val other = cold(model, "other"); assertTrue(other.state.value.records.isEmpty())
        val original = cold(other); assertEquals("Synthetic created", original.state.value.records.single().snapshot.plan.configuration.name)
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `切账号的迟到创建回执不能写入新工作区`() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.method == "create") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        val model = model(); open(model); assertTrue(model.create()); assertTrue(entered.await(5, TimeUnit.SECONDS))
        model.clear(); repository = fixture.repository("next", "other"); release.countDown(); delay(150)
        assertFalse(model.state.value.editor); assertFalse(model.state.value.loaded); model.refresh(); idle(model)
        assertTrue(model.state.value.records.isEmpty()); assertEquals(1, fixture.writes.size)
    }
    @Test fun `切换模板重读资源而不夹带映像盘和多网卡`() = runBlocking {
        val model = model(); open(model)
        model.change(model.state.value.draft!!.copy(disks = listOf(VmmCreationDiskDraft(image = "image-1"), VmmCreationDiskDraft()), networks = listOf(null, "network-1")))
        model.change(model.state.value.draft!!.copy(preset = VmmCreationPreset.LINUX)); idle(model)
        val draft = model.state.value.draft!!; assertEquals(1, draft.disks.size); assertNull(draft.disks.single().image); assertEquals(listOf<String?>(null), draft.networks)
        assertEquals(VmmSource.INTERNAL, model.state.value.resources!!.source)
        send(model); assertEquals(VmmCreationStage.COMPLETE, model.state.value.records.single().progress.stage)
        assertEquals(1, fixture.writes.size); assertEquals(VmmSource.INTERNAL.guestApi, fixture.writes.single().api)
    }
    @Test fun `单个创建任务读取失败不阻塞其他任务只读恢复`() = runBlocking {
        scenario.finished = false; val model = model(); open(model); send(model)
        scenario.taskId = "second-task"; scenario.createdId = "second-guest"
        open(model, "Second synthetic"); send(model)
        scenario.finished = true; scenario.createdId = "created-guest"
        fixture.before = { if (it.api == "SYNO.Virtualization.API.Task.Info" && it.fields["task_id"]?.toString() == "\"second-task\"") throw IOException("synthetic read failure") }
        val next = cold(model)
        assertNotNull(next.state.value.failure); assertTrue(next.state.value.sources.isNotEmpty())
        assertEquals(VmmCreationStage.CREATED, next.state.value.records.single { it.snapshot.plan.configuration.name == "Synthetic created" }.progress.stage)
        assertEquals(VmmCreationStage.CREATING, next.state.value.records.single { it.snapshot.plan.configuration.name == "Second synthetic" }.progress.stage)
        assertEquals(2, fixture.writes.size)
    }
}
