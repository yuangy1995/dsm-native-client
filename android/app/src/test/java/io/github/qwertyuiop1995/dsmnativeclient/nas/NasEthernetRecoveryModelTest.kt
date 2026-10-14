package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class NasEthernetRecoveryModelTest {
    private val f = NasServiceProtocolFixture(); private var repository = f.repository()
    private val prefs = MemoryPreferences(); private val store = NasServiceActivityStore(prefs)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private val kind = NasServiceKind.ETHERNET
    private fun model() = NasServiceSettingsModel(scope, { repository }, { store })
    private suspend fun idle(m: NasServiceSettingsModel) { withTimeout(5_000) { while (m.state.value.getValue(kind).busy) delay(10) } }
    private suspend fun load(m: NasServiceSettingsModel) { m.refresh(kind, notify = false); idle(m) }
    private suspend fun edit(m: NasServiceSettingsModel) {
        val before = repository.nasServices.load(kind, "eth0") as NasServiceValue.Ethernet
        assertTrue(m.begin(before)); m.draft(kind, before.copy(settings = before.settings.copy(mtu = 1600)))
    }
    private suspend fun pending(m: NasServiceSettingsModel) {
        load(m); edit(m)
        f.backend.afterWrite = { f.backend.before = { if (!it.write) throw IOException("Synthetic offline") } }
        assertTrue(m.save(kind)); idle(m); assertTrue(m.state.value.getValue(kind).blocked)
        assertFalse(m.save(kind)); m.dismiss(kind, true); assertNotNull(m.state.value.getValue(kind).record)
        f.backend.before = {}; f.backend.afterWrite = {}
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `相同连接重新登录冷恢复只读取原网卡并保留配置摘要`() = runBlocking {
        var m = model(); pending(m); m.clear(); repository = f.repository("next"); m = model(); load(m)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, m.state.value.getValue(kind).result?.status)
        assertFalse(m.state.value.getValue(kind).blocked); assertEquals(1, f.backend.writes.size)
        val raw = prefs.all.values.joinToString(); assertFalse(raw.contains("mtu")); assertFalse(raw.contains("synthetic.invalid")); assertFalse(raw.contains("Current"))
    }
    @Test fun `新地址明确关联前零恢复读取关联后只读且保留原身份`() = runBlocking {
        var m = model(); val ethernet = repository.nasServices.load(kind, "eth0"); pending(m); val old = m.state.value.getValue(kind).record!!; m.clear()
        repository = f.repository("next", "new-address", address = "https://synthetic-new.invalid"); m = model()
        val reads = f.backend.requests.size; load(m)
        assertEquals(reads, f.backend.requests.size); assertTrue(m.state.value.getValue(kind).needsAssociation)
        assertTrue(m.state.value.getValue(kind).canAssociate); assertFalse(m.begin(ethernet))
        assertFalse(m.save(kind)); m.dismiss(kind, true); assertNotNull(m.state.value.getValue(kind).record)
        assertTrue(m.associateEthernet(old)); idle(m)
        val saved = m.state.value.getValue(kind).record!!
        assertEquals(old.owner, saved.owner); assertEquals(repository.owner, saved.recoveryOwner)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, m.state.value.getValue(kind).result?.status)
        assertFalse(m.state.value.getValue(kind).needsAssociation); assertEquals(1, f.backend.writes.size)
    }
    @Test fun `换账号无法关联不同连接不看见记录且旧确认在会话改变后无效`() = runBlocking {
        var m = model(); pending(m); val old = m.state.value.getValue(kind).record!!; m.clear()
        repository = f.repository("next", "other-account", username = "Other"); m = model(); load(m)
        assertTrue(m.state.value.getValue(kind).needsAssociation); assertFalse(m.state.value.getValue(kind).canAssociate)
        assertFalse(m.associateEthernet(old)); assertTrue(store.records(WorkspaceOwner("other-profile", "id", "session")).isEmpty())
        repository = f.repository("original-next", "new-address"); load(m); assertTrue(m.state.value.getValue(kind).canAssociate)
        repository = f.repository("changed-again", "new-address"); assertFalse(m.associateEthernet(old)); assertEquals(1, f.backend.writes.size)
    }
    @Test fun `关联成功后读取失败仍可刷新且不可重发或丢弃`() = runBlocking {
        var m = model(); pending(m); val old = m.state.value.getValue(kind).record!!; m.clear()
        repository = f.repository("next", "new-address"); m = model(); load(m)
        f.backend.before = { throw IOException("Synthetic offline") }; assertTrue(m.associateEthernet(old)); idle(m)
        assertFalse(m.state.value.getValue(kind).needsAssociation); assertTrue(m.state.value.getValue(kind).blocked)
        assertFalse(m.save(kind)); f.backend.before = {}; load(m)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, m.state.value.getValue(kind).result?.status); assertEquals(1, f.backend.writes.size)
    }
    @Test fun `首次持久化失败零写且准备记录恢复仅取消`() = runBlocking {
        val m = model(); load(m); edit(m); prefs.commitSucceeds = false; assertTrue(m.save(kind)); idle(m)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, m.state.value.getValue(kind).failure?.kind); assertTrue(f.backend.writes.isEmpty())
        val other = NasServiceActivityStore(MemoryPreferences()); val owner = repository.owner!!
        other.begin(NasServiceRecord("prepared", owner, kind, listOf(NasServiceStepRecord(NasServiceStep.ETHERNET, "a".repeat(64))), targetId = "eth0", accountDigest = repository.nasAccountDigest))
        val recovered = NasServiceSettingsModel(scope, { repository }, { other }); val count = f.backend.requests.size; load(recovered)
        assertEquals(NasServiceStage.CANCELLED, recovered.state.value.getValue(kind).record!!.steps.single().stage)
        assertEquals(count, f.backend.requests.size)
    }
    @Test fun `未关联记录不可直接写检查点不可重复开始同连接网卡修改`() {
        val owner = repository.owner!!; val current = owner.copy(identityRevision = "different", sessionGeneration = "new")
        val record = NasServiceRecord("pending", owner, kind, listOf(NasServiceStepRecord(NasServiceStep.ETHERNET, "a".repeat(64))), targetId = "eth0", accountDigest = repository.nasAccountDigest)
        store.begin(record); store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.ETHERNET, NasServiceStage.SUBMITTED))
        assertTrue(runCatching { store.checkpoint(current, record.id, NasServiceCheckpoint(NasServiceStep.ETHERNET, NasServiceStage.VERIFIED)) }.isFailure)
        assertTrue(runCatching { store.begin(record.copy(id = "second", owner = current, targetId = "eth1")) }.isFailure)
        assertTrue(runCatching { store.discard(current, record.id) }.isFailure)
        assertTrue(runCatching { store.associateEthernet(current, packageDigest("Other"), record.id) }.isFailure)
        assertEquals(owner, store.records(current).single().owner)
    }
}
