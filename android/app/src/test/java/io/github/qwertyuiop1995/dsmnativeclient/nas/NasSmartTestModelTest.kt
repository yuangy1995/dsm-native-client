package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasSmartTestModelTest {
    private val fixture = NasSmartFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = NasSmartActivityStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = NasSmartTestModel(scope, { repository }, { store }, { canStart })
    private suspend fun idle(model: NasSmartTestModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) }; delay(20) }
    private suspend fun load(model: NasSmartTestModel) { model.refresh(); idle(model); assertNull(model.state.value.failure) }
    private fun disk(model: NasSmartTestModel) = model.state.value.disks.single()
    private suspend fun ready(model: NasSmartTestModel) { load(model); model.load(disk(model)); idle(model); assertNull(model.state.value.failure) }
    private fun confirmation(model: NasSmartTestModel) = model.state.value.confirmation!!
    private fun cold(old: NasSmartTestModel, identity: String = "identity"): NasSmartTestModel {
        old.clear(); repository = fixture.repository(generation = "new-generation", identity = identity); store = NasSmartActivityStore(preferences); return model()
    }
    private suspend fun seed(stage: NasSmartStage = NasSmartStage.ACCEPTED, action: NasSmartAction = NasSmartAction.QUICK): NasSmartActivity {
        val activity = NasSmartActivity("synthetic-activity", repository.owner!!, smartIdentity(repository.nasSmart.disks().single()), action)
        store.begin(activity)
        if (stage != NasSmartStage.PREPARED) store.checkpoint(activity.owner, activity.id, NasSmartStage.SUBMITTED)
        if (stage == NasSmartStage.ACCEPTED) store.checkpoint(activity.owner, activity.id, stage)
        return store.records(activity.owner).single()
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `加载当前状态才可操作外部忙碌取消旧确认与双击零重发`() = runBlocking {
        val model = model(); load(model); val disk = disk(model); assertFalse(model.request(disk, NasDiskTestType.QUICK))
        model.load(disk); idle(model); assertTrue(model.request(disk, NasDiskTestType.QUICK)); val old = confirmation(model)
        assertFalse(model.confirm(old.copy(action = NasSmartAction.EXTENDED))); model.cancel(); assertFalse(model.confirm(old)); assertTrue(fixture.writes.isEmpty())
        canStart = false; assertFalse(model.request(disk, NasDiskTestType.QUICK)); canStart = true; assertTrue(model.request(disk, NasDiskTestType.QUICK))
        canStart = false; assertFalse(model.confirm(confirmation(model))); canStart = true; fixture.afterWrite = NasSmartFixture.status("quick")
        assertTrue(model.confirm(confirmation(model))); assertFalse(model.confirm(old)); idle(model)
        assertEquals(NasSmartStage.VERIFIED, model.state.value.record?.stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `未知跨重启保留原动作类型错误换盘消失均不能关闭之后精确状态只读恢复`() = runBlocking {
        val activity = seed(NasSmartStage.SUBMITTED); var model = cold(model()); load(model)
        assertEquals(activity, model.state.value.record); model.dismiss(); assertEquals(activity, model.state.value.record)
        assertFalse(model.request(disk(model), NasDiskTestType.QUICK)); assertTrue(model.state.value.blocked)
        fixture.status = NasSmartFixture.status("extend"); load(model); assertEquals(NasSmartStage.SUBMITTED, model.state.value.record?.stage)
        for (directory in listOf(NasSmartFixture.directory(NasSmartFixture.row("replacement")), NasSmartFixture.directory())) {
            fixture.directory = directory; model.refresh(); idle(model); assertNotNull(model.state.value.failure); assertEquals(NasSmartStage.SUBMITTED, model.state.value.record?.stage)
        }
        fixture.directory = NasSmartFixture.directory(fixture.row); fixture.status = NasSmartFixture.status("quick"); load(model)
        assertEquals(NasSmartStage.VERIFIED, model.state.value.record?.stage); assertTrue(fixture.writes.isEmpty()); model.dismiss(); assertNull(model.state.value.record)
    }
    @Test fun `真实提交丢回执保留未知后续刷新不重发且记录不含设备正文`() = runBlocking {
        var model = model(); ready(model); fixture.before = { if (it.oneShot) throw IOException("Synthetic lost receipt") }
        assertTrue(model.request(disk(model), NasDiskTestType.EXTENDED)); assertTrue(model.confirm(confirmation(model))); idle(model)
        assertEquals(NasSmartStage.SUBMITTED, model.state.value.record?.stage); assertEquals(1, fixture.writes.size)
        val raw = preferences.all.values.joinToString()
        for (sensitive in listOf("synthetic-device", "synthetic-disk", "Synthetic drive", "Synthetic model", "synthetic-sid", "synthetic-token", "synthetic.invalid")) assertFalse(raw.contains(sensitive))
        fixture.before = {}; model = cold(model); fixture.status = NasSmartFixture.status("extend"); load(model)
        assertEquals(NasSmartStage.VERIFIED, model.state.value.record?.stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `恢复仍须当前权限与可读状态但不匹配固件版本`() = runBlocking {
        seed(); val model = cold(model()); fixture.status = NasSmartFixture.status("quick")
        for (condition in listOf(0, 2)) {
            fixture.admin = condition != 0; fixture.known = false
            fixture.before = { if (condition == 2 && it.method == "get_smart_test_log") throw IOException("Synthetic offline") }
            model.refresh(); idle(model); assertNotNull(model.state.value.failure); assertEquals(NasSmartStage.ACCEPTED, model.state.value.record?.stage)
        }
        fixture.before = {}; load(model); assertEquals(NasSmartStage.VERIFIED, model.state.value.record?.stage); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `写前保存失败和记录损坏零写接受保存失败保留提交阶段供冷恢复`() = runBlocking {
        var model = model(); ready(model); preferences.commitSucceeds = false
        assertTrue(model.request(disk(model), NasDiskTestType.QUICK)); assertTrue(model.confirm(confirmation(model))); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.failure?.kind); assertTrue(fixture.writes.isEmpty())
        preferences.commitSucceeds = true; preferences.edit().clear().putString("smart:bad", "{}").commit(); model = cold(model)
        model.refresh(); idle(model); assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.failure?.kind); assertTrue(fixture.writes.isEmpty())
        preferences.edit().clear().commit(); model = cold(model); ready(model)
        fixture.before = { if (it.oneShot) preferences.commitSucceeds = false }; fixture.afterWrite = NasSmartFixture.status("quick")
        assertTrue(model.request(disk(model), NasDiskTestType.QUICK)); assertTrue(model.confirm(confirmation(model))); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.failure?.kind); assertEquals("do_smart_test", fixture.calls.last().method)
        preferences.commitSucceeds = true; fixture.before = {}; model = cold(model); load(model)
        assertEquals(NasSmartStage.VERIFIED, model.state.value.record?.stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `未发送恢复取消明确拒绝不得升级运行成功记录严格禁止反向阶段和串号`() = runBlocking {
        val prepared = seed(NasSmartStage.PREPARED); var model = cold(model()); load(model); assertEquals(NasSmartStage.CANCELLED, model.state.value.record?.stage)
        model.dismiss(); ready(model); fixture.rejection = 105
        assertTrue(model.request(disk(model), NasDiskTestType.QUICK)); assertTrue(model.confirm(confirmation(model))); idle(model)
        assertEquals(NasSmartStage.REJECTED, model.state.value.record?.stage)
        fixture.status = NasSmartFixture.status("quick"); model = cold(model); load(model); assertEquals(NasSmartStage.REJECTED, model.state.value.record?.stage)
        val rejected = model.state.value.record!!
        try { store.checkpoint(repository.owner!!, rejected.id, NasSmartStage.VERIFIED); fail() } catch (_: DsmFailure) {}
        model = cold(model, "different-account"); load(model); assertNull(model.state.value.record)
        assertEquals(NasSmartStage.REJECTED, store.records(prepared.owner).single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `前台轮询仅已查看运行硬盘结束读取历史历史失败保留真实状态换盘清缓存`() = runBlocking {
        val model = model(); load(model); var count = fixture.calls.size; model.pollRunning(); idle(model); assertEquals(count, fixture.calls.size)
        fixture.status = NasSmartFixture.status("quick"); model.load(disk(model)); idle(model)
        fixture.status = NasSmartFixture.status(); fixture.history = JsonObject(emptyMap()); count = fixture.calls.count { it.method == "disk_test_log_get" }
        model.pollRunning(); idle(model); val status = (model.state.value.statuses[disk(model).id] as Loadable.Ready).value
        assertFalse(status.isRunning); assertFalse(status.isHistoryAvailable); assertTrue(disk(model).id in model.state.value.historyFailures)
        assertEquals(count + 1, fixture.calls.count { it.method == "disk_test_log_get" }); assertNull(model.state.value.failure)
        fixture.directory = NasSmartFixture.directory(NasSmartFixture.row("replacement")); load(model)
        assertTrue(model.state.value.statuses.isEmpty()); assertTrue(model.state.value.historyFailures.isEmpty()); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `两模型共享锁阻止并发与切换后的迟到结果不污染新账号`() = runBlocking {
        val first = model(); val second = model(); ready(first); ready(second)
        assertTrue(first.request(disk(first), NasDiskTestType.QUICK)); assertTrue(second.request(disk(second), NasDiskTestType.QUICK))
        val entered = CountDownLatch(1); val release = CountDownLatch(1); fixture.afterWrite = NasSmartFixture.status("quick")
        fixture.before = { if (it.oneShot) { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) } }
        assertTrue(first.confirm(confirmation(first))); assertTrue(entered.await(3, TimeUnit.SECONDS))
        assertTrue(second.confirm(confirmation(second))); idle(second); assertEquals(1, fixture.writes.size)
        val original = repository.owner!!; repository = fixture.repository("other-generation", "different-account"); first.clear(); release.countDown()
        withTimeout(5_000) { scope.coroutineContext[Job]!!.children.toList().joinAll() }
        fixture.before = {}; val next = model(); load(next); assertNull(next.state.value.record); assertTrue(next.state.value.statuses.isEmpty())
        assertTrue(store.records(original).single().pending); assertEquals(1, fixture.writes.size)
    }
}
