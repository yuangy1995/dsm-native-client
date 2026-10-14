package io.github.qwertyuiop1995.dsmnativeclient.nas

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

class NasConnectionModelTest {
    private val fixture = NasConnectionFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = NasConnectionActivityStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = NasConnectionModel(scope, { repository }, { store }, { canStart })
    private suspend fun idle(model: NasConnectionModel) { withTimeout(5_000) { while (model.state.value.busy) delay(10) }; delay(20) }
    private suspend fun load(model: NasConnectionModel) { model.refresh(); idle(model); assertNull(model.state.value.failure) }
    private fun target(model: NasConnectionModel) = model.state.value.directory!!.rows.single()
    private suspend fun send(model: NasConnectionModel) {
        load(model); val target = target(model); assertTrue(model.request(target)); assertTrue(model.confirm(target)); idle(model)
    }
    private fun cold(old: NasConnectionModel, identity: String = "identity"): NasConnectionModel {
        old.clear(); repository = fixture.repository(generation = "new-generation", identity = identity); store = NasConnectionActivityStore(preferences)
        return model()
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `加载前和外部忙碌不能发送取消和旧确认零写重复确认仅一次`() = runBlocking {
        val model = model(); val synthetic = decodeConnections(fixture.directory).rows.single()
        assertFalse(model.request(synthetic)); load(model); val target = target(model)
        assertTrue(model.request(target)); assertFalse(model.confirm(target.copy(client = "changed")))
        model.cancel(); assertFalse(model.confirm(target)); assertTrue(fixture.writes.isEmpty())
        canStart = false; assertFalse(model.request(target)); canStart = true; assertTrue(model.request(target))
        canStart = false; assertFalse(model.confirm(target)); canStart = true
        assertTrue(model.confirm(target)); assertFalse(model.confirm(target)); idle(model); assertEquals(1, fixture.writes.size)
    }
    @Test fun `接受跨重启保留目标仍在不能关闭或重发最后消失只读解锁`() = runBlocking {
        var model = model(); send(model); val original = model.state.value.record!!
        assertEquals(NasConnectionStage.ACCEPTED, original.stage); model.dismiss(); assertEquals(original, model.state.value.record)
        model = cold(model); load(model); assertEquals(original, model.state.value.record); assertTrue(model.state.value.blocked)
        assertFalse(model.request(target(model))); val raw = preferences.all.values.joinToString()
        for (sensitive in listOf("synthetic-device", "synthetic-account", "synthetic-source", "synthetic-client", "synthetic-sid", "synthetic-token", "synthetic.invalid")) assertFalse(raw.contains(sensitive))
        fixture.directory = NasConnectionFixture.directory(); load(model); assertEquals(NasConnectionStage.VERIFIED, model.state.value.record!!.stage)
        assertFalse(model.state.value.blocked); assertEquals(1, fixture.writes.size); model.dismiss(); assertNull(model.state.value.record)
    }
    @Test fun `无回执冷恢复相似缺身份和部分目录不算完成之后消失可恢复`() = runBlocking {
        var model = model(); fixture.before = { if (it.oneShot) throw IOException("Synthetic lost receipt") }; send(model)
        assertEquals(NasConnectionStage.SUBMITTED, model.state.value.record!!.stage); fixture.before = {}; model = cold(model)
        fixture.directory = NasConnectionFixture.directory(JsonObject(fixture.row - "did")); load(model)
        assertEquals(NasConnectionStage.SUBMITTED, model.state.value.record!!.stage)
        fixture.directory = JsonObject(NasConnectionFixture.directory() + ("total" to JsonPrimitive(1))); load(model)
        assertEquals(NasConnectionStage.SUBMITTED, model.state.value.record!!.stage)
        fixture.directory = NasConnectionFixture.directory(); load(model); assertEquals(NasConnectionStage.VERIFIED, model.state.value.record!!.stage)
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `恢复需当前管理权限读取失败保留未知而不同版本可恢复`() = runBlocking {
        var model = model(); send(model); model = cold(model); fixture.directory = NasConnectionFixture.directory()
        for (condition in listOf(0, 2)) {
            fixture.admin = condition != 0; fixture.known = false
            fixture.before = { if (condition == 2 && it.method == "list") throw IOException("Synthetic offline") }
            model.refresh(); idle(model); assertNotNull(model.state.value.failure)
            assertEquals(NasConnectionStage.ACCEPTED, model.state.value.record!!.stage); assertTrue(model.state.value.blocked)
        }
        fixture.before = {}; load(model); assertEquals(NasConnectionStage.VERIFIED, model.state.value.record!!.stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `预写持久失败与损坏记录禁止发送接受落盘失败冷恢复仍未知`() = runBlocking {
        var model = model(); load(model); val target = target(model); preferences.commitSucceeds = false
        assertTrue(model.request(target)); assertTrue(model.confirm(target)); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.failure?.kind); assertTrue(fixture.writes.isEmpty())
        preferences.commitSucceeds = true; preferences.edit().clear().putString("connection:bad", "{}").commit(); model = cold(model)
        model.refresh(); idle(model); assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.failure?.kind); assertTrue(fixture.writes.isEmpty())
        preferences.edit().clear().commit(); model = cold(model); var durable = emptyMap<String, String>()
        fixture.before = { if (it.oneShot) {
            durable = preferences.all.mapValues { entry -> entry.value as String }; preferences.commitSucceeds = false
        } }
        send(model); assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.failure?.kind); assertEquals("kick_connection", fixture.calls.last().method)
        preferences.commitSucceeds = true; fixture.before = {}
        preferences.edit().clear().also { edit -> durable.forEach { (key, value) -> edit.putString(key, value) } }.commit()
        model = cold(model); load(model); assertEquals(NasConnectionStage.SUBMITTED, model.state.value.record!!.stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `未提交冷恢复取消拒绝不能被空目录认领成功`() = runBlocking {
        val owner = repository.owner!!; val identity = connectionIdentity(decodeConnections(fixture.directory).rows.single())
        store.begin(NasConnectionActivity("prepared", owner, identity)); var model = model(); load(model)
        assertEquals(NasConnectionStage.CANCELLED, model.state.value.record!!.stage); assertTrue(fixture.writes.isEmpty()); model.dismiss()
        fixture.rejection = 105; send(model); assertEquals(NasConnectionStage.REJECTED, model.state.value.record!!.stage)
        fixture.directory = NasConnectionFixture.directory(); model = cold(model); load(model)
        assertEquals(NasConnectionStage.REJECTED, model.state.value.record!!.stage); model.dismiss(); assertNull(model.state.value.record)
    }
    @Test fun `两模型跨实例互斥且切换账号迟到回执只保存原账号`() = runBlocking {
        val first = model(); val second = model(); load(first); load(second)
        val target = target(first); assertTrue(first.request(target)); assertTrue(second.request(target))
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.oneShot) { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) } }
        val originalOwner = repository.owner!!; assertTrue(first.confirm(target)); assertTrue(entered.await(2, TimeUnit.SECONDS))
        assertTrue(second.confirm(target)); idle(second); assertEquals(1, fixture.writes.size)
        repository = fixture.repository(identity = "other-identity"); release.countDown()
        withTimeout(5_000) { while (store.records(originalOwner).single().stage != NasConnectionStage.ACCEPTED) delay(10) }
        assertTrue(store.records(repository.owner!!).isEmpty()); assertEquals(NasConnectionStage.PREPARED, first.state.value.record!!.stage)
        withTimeout(5_000) { scope.coroutineContext[Job]!!.children.toList().joinAll() }
        load(first); assertNull(first.state.value.record); assertEquals(1, fixture.writes.size)
    }
    @Test fun `清理取消发送后冷恢复不丢失已发送事实旧目标不能在新仓储确认`() = runBlocking {
        var model = model(); load(model); val target = target(model); assertTrue(model.request(target))
        repository = fixture.repository(generation = "replaced"); assertFalse(model.confirm(target)); assertTrue(fixture.writes.isEmpty())
        load(model); assertTrue(model.request(target))
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.oneShot) { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) } }
        assertTrue(model.confirm(target)); assertTrue(entered.await(2, TimeUnit.SECONDS)); model.clear(); release.countDown()
        delay(150); fixture.before = {}; model = cold(model); load(model)
        assertTrue(model.state.value.record!!.pending); assertEquals(1, fixture.writes.size)
        assertFalse(model.request(target)); assertFalse(model.confirm(target))
    }
    @Test fun `记录不允许未知丢弃反向阶段新会话伪造回执或跨账号读出`() = runBlocking {
        val owner = repository.owner!!; val identity = connectionIdentity(decodeConnections(fixture.directory).rows.single())
        store.begin(NasConnectionActivity("record", owner, identity)); store.checkpoint(owner, "record", NasConnectionStage.SUBMITTED)
        assertTrue(runCatching { store.dismiss(owner, "record") }.isFailure)
        assertTrue(runCatching { store.checkpoint(owner, "record", NasConnectionStage.CANCELLED) }.isFailure)
        assertTrue(runCatching { store.begin(NasConnectionActivity("another", owner, identity)) }.isFailure)
        val fresh = owner.copy(sessionGeneration = "fresh")
        assertTrue(runCatching { store.checkpoint(fresh, "record", NasConnectionStage.ACCEPTED) }.isFailure)
        assertTrue(store.records(owner.copy(identityRevision = "different")).isEmpty())
        store.checkpoint(fresh, "record", NasConnectionStage.VERIFIED); store.dismiss(fresh, "record"); assertTrue(store.records(owner).isEmpty())
    }
}
