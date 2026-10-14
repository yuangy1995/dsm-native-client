package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasPowerStage
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class NasPowerActionModelTest {
    private val fixture = NasPowerActionFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = NasPowerActivityStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = NasPowerActionModel(scope, { repository }, { store }, { canStart })
    private suspend fun idle(model: NasPowerActionModel) { withTimeout(5_000) { while (model.state.value.busy) delay(10) }; delay(20) }
    private suspend fun load(model: NasPowerActionModel) { model.refresh(); idle(model); assertNull(model.state.value.failure) }
    private suspend fun send(model: NasPowerActionModel) {
        load(model); assertTrue(model.request(NasPowerAction.REBOOT)); assertTrue(model.confirm(NasPowerAction.REBOOT)); idle(model)
    }
    private suspend fun cold(old: NasPowerActionModel, sid: String = "synthetic-sid", identity: String = "identity"): NasPowerActionModel {
        old.clear(); repository = fixture.repository(sid = sid, generation = "new-generation", identity = identity)
        store = NasPowerActivityStore(preferences)
        return model().also { load(it) }
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `加载前禁止操作且准备取消与重复确认没有额外写入`() = runBlocking {
        val model = model(); assertFalse(model.request(NasPowerAction.REBOOT)); load(model)
        assertTrue(fixture.calls.isEmpty()); assertTrue(model.request(NasPowerAction.REBOOT))
        assertFalse(model.request(NasPowerAction.SHUTDOWN)); assertFalse(model.confirm(NasPowerAction.SHUTDOWN))
        model.cancel(); assertFalse(model.confirm(NasPowerAction.REBOOT)); assertTrue(fixture.calls.isEmpty())
        canStart = false; assertFalse(model.request(NasPowerAction.REBOOT)); canStart = true
        assertTrue(model.request(NasPowerAction.REBOOT)); canStart = false; assertFalse(model.confirm(NasPowerAction.REBOOT)); canStart = true
        assertTrue(model.confirm(NasPowerAction.REBOOT)); assertFalse(model.confirm(NasPowerAction.REBOOT)); idle(model)
        assertEquals(1, fixture.writes.size); assertTrue(model.state.value.blocked)
    }
    @Test fun `已接受跨重启保留且同一真实会话更换代次仍不能解锁`() = runBlocking {
        var model = model(); send(model); val original = model.state.value.record!!
        assertEquals(NasPowerStage.ACCEPTED, original.stage); model.dismiss(); assertNotNull(model.state.value.record)
        val count = fixture.calls.size; model = cold(model)
        assertEquals(count, fixture.calls.size); assertEquals(original, model.state.value.record)
        assertFalse(model.state.value.canRestore); assertFalse(model.restore(original)); assertFalse(model.request(NasPowerAction.SHUTDOWN))
        assertEquals(1, fixture.writes.size)
        val raw = preferences.all.values.joinToString(); assertFalse(raw.contains("synthetic-sid")); assertFalse(raw.contains("synthetic-token"))
        assertFalse(raw.contains("synthetic.invalid")); assertFalse(raw.contains("Synthetic user"))
    }
    @Test fun `接受及未知均需新登录加显式恢复且只读连接不改原结果`() = runBlocking {
        for (unknown in listOf(false, true)) {
            var model = model()
            if (unknown) fixture.before = { if (it.oneShot) throw IOException("Synthetic lost receipt") }
            send(model); val stage = if (unknown) NasPowerStage.SUBMITTED else NasPowerStage.ACCEPTED
            assertEquals(stage, model.state.value.record!!.stage); fixture.before = {}
            val previousCount = fixture.calls.size; model = cold(model, sid = "new-sid-$unknown")
            assertEquals(previousCount, fixture.calls.size); val original = model.state.value.record!!
            assertTrue(model.state.value.canRestore); assertTrue(model.state.value.blocked)
            assertTrue(model.restore(original)); assertFalse(model.restore(original)); idle(model)
            val restored = model.state.value.record!!; assertTrue(restored.restored); assertEquals(stage, restored.stage)
            assertFalse(model.state.value.blocked); assertEquals(listOf("info"), fixture.calls.drop(previousCount).map { it.method })
            model.dismiss(); assertNull(model.state.value.record); model.clear()
        }
        assertEquals(2, fixture.writes.size)
    }
    @Test fun `新会话恢复时权限连接和存储失败均保持原阻止且不写`() = runBlocking {
        var model = model(); send(model); model = cold(model, sid = "new-sid")
        val record = model.state.value.record!!
        for (condition in listOf(0, 2, 3)) {
            fixture.admin = condition != 0; fixture.known = false
            fixture.before = { if (condition == 2 && it.method == "info") throw IOException("Synthetic offline") }
            if (condition == 3) preferences.commitSucceeds = false
            assertTrue(model.restore(record)); idle(model); assertTrue(model.state.value.blocked)
            assertEquals(record, model.state.value.record); assertNotNull(model.state.value.failure)
        }
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `接受回执持久失败冷恢复仍未知并阻止重新发送`() = runBlocking {
        val model = model(); var durable = emptyMap<String, String>()
        fixture.before = { if (it.oneShot) {
            durable = preferences.all.mapValues { entry -> entry.value as String }
            preferences.commitSucceeds = false
        } }
        send(model); assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.failure?.kind)
        assertTrue(model.state.value.blocked); preferences.commitSucceeds = true; fixture.before = {}
        // SharedPreferences 可能先更新内存再报告磁盘失败；冷启动使用写回执前已落盘的快照。
        preferences.edit().clear().also { edit -> durable.forEach { (key, value) -> edit.putString(key, value) } }.commit()
        val resumed = cold(model); assertEquals(NasPowerStage.SUBMITTED, resumed.state.value.record!!.stage)
        assertFalse(resumed.request(NasPowerAction.REBOOT)); assertEquals(1, fixture.writes.size)
    }
    @Test fun `写前存储失败不会调用NAS且记录损坏不视为无待办`() = runBlocking {
        val model = model(); load(model); preferences.commitSucceeds = false
        assertTrue(model.request(NasPowerAction.REBOOT)); assertTrue(model.confirm(NasPowerAction.REBOOT)); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.failure?.kind); assertTrue(fixture.calls.isEmpty())
        model.clear(); preferences.commitSucceeds = true
        preferences.edit().putString("power:corrupt", "{}").commit(); store = NasPowerActivityStore(preferences)
        val resumed = model(); resumed.refresh(); idle(resumed)
        assertTrue(resumed.state.value.blocked); assertFalse(resumed.request(NasPowerAction.REBOOT)); assertTrue(fixture.calls.isEmpty())
    }
    @Test fun `未提交记录冷恢复取消明确拒绝可关闭而新操作不显示旧结果`() = runBlocking {
        val owner = repository.owner!!; store.begin(NasPowerActivity("prepared", owner, NasPowerAction.REBOOT, repository.nasPowerSessionDigest))
        var model = model(); load(model); assertEquals(NasPowerStage.CANCELLED, model.state.value.record!!.stage)
        assertTrue(fixture.calls.isEmpty()); fixture.rejection = 105
        send(model); assertEquals(NasPowerStage.REJECTED, model.state.value.record!!.stage); assertFalse(model.state.value.blocked)
        model = cold(model); assertEquals(NasPowerStage.REJECTED, model.state.value.record!!.stage)
        model.dismiss(); assertNull(model.state.value.record); assertTrue(model.request(NasPowerAction.SHUTDOWN))
    }
    @Test fun `账号切换迟到确认及旧恢复对象不作用于新账号`() = runBlocking {
        val model = model(); load(model); model.request(NasPowerAction.REBOOT)
        repository = fixture.repository(identity = "another-account"); assertFalse(model.confirm(NasPowerAction.REBOOT))
        assertTrue(fixture.calls.isEmpty()); send(model); val record = model.state.value.record!!
        val other = cold(model, sid = "new-sid", identity = "identity"); assertNull(other.state.value.record)
        assertFalse(other.restore(record)); assertEquals(1, fixture.writes.size)
    }
    @Test fun `撤权清理模型与重建仓储不会删除已发送事实`() = runBlocking {
        var model = model(); send(model); val record = model.state.value.record!!; model.clear(); fixture.admin = false
        repository = fixture.repository(sid = "new-sid"); model = model(); load(model)
        assertEquals(record, model.state.value.record); assertTrue(model.state.value.blocked)
        assertTrue(model.restore(record)); idle(model); assertTrue(model.state.value.blocked)
        assertEquals(record, store.records(repository.owner!!).single()); assertEquals(1, fixture.writes.size)
    }
    @Test fun `两个模型共享持久互斥且切换后迟到回执只保存原归属`() = runBlocking {
        val first = model(); val second = model(); load(first); load(second)
        assertTrue(first.request(NasPowerAction.REBOOT)); assertTrue(second.request(NasPowerAction.SHUTDOWN))
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.oneShot) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        assertTrue(first.confirm(NasPowerAction.REBOOT)); assertTrue(entered.await(5, TimeUnit.SECONDS))
        assertTrue(second.confirm(NasPowerAction.SHUTDOWN)); idle(second); assertNotNull(second.state.value.failure)
        val owner = repository.owner!!; repository = fixture.repository(identity = "other")
        release.countDown(); withTimeout(5_000) { while (store.records(owner).single().stage == NasPowerStage.SUBMITTED) delay(10) }
        assertEquals(NasPowerStage.ACCEPTED, store.records(owner).single().stage)
        assertEquals(NasPowerStage.PREPARED, first.state.value.record!!.stage)
        first.clear()
        assertNull(first.state.value.record); assertEquals(1, fixture.writes.size)
    }
    @Test fun `写请求途中退出模型仍保留未知且冷启动不能重发`() = runBlocking {
        val model = model(); load(model); val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.oneShot) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        model.request(NasPowerAction.REBOOT); model.confirm(NasPowerAction.REBOOT)
        assertTrue(entered.await(5, TimeUnit.SECONDS)); model.clear(); release.countDown()
        delay(100); fixture.before = {}; val resumed = cold(model)
        assertEquals(NasPowerStage.SUBMITTED, resumed.state.value.record!!.stage)
        assertTrue(resumed.state.value.blocked); assertFalse(resumed.request(NasPowerAction.SHUTDOWN))
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `恢复记录拒绝跳阶段直接关闭未知或同会话解锁`() {
        val owner = repository.owner!!; val record = NasPowerActivity("record", owner, NasPowerAction.SHUTDOWN, repository.nasPowerSessionDigest)
        store.begin(record)
        fun denied(block: () -> Unit) { assertTrue(runCatching(block).isFailure) }
        denied { store.checkpoint(owner, record.id, NasPowerStage.ACCEPTED) }; denied { store.dismiss(owner, record.id) }
        store.checkpoint(owner, record.id, NasPowerStage.SUBMITTED)
        denied { store.dismiss(owner, record.id) }; denied { store.restore(owner, record.id, record.sessionDigest) }
        denied { store.cancelPrepared(owner, record.id) }; denied { store.begin(record.copy(id = "another")) }
        store.restore(owner, record.id, "a".repeat(64)); val restored = store.records(owner).single()
        assertEquals(NasPowerStage.SUBMITTED, restored.stage); assertTrue(restored.restored)
        store.dismiss(owner, record.id); assertTrue(store.records(owner).single().dismissed)
    }
}
