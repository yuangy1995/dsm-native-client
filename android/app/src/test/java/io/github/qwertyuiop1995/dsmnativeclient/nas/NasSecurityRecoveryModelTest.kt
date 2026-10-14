package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasSecurityRecoveryModelTest {
    private val fixture = NasServiceProtocolFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private val store = NasServiceActivityStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val kind = NasServiceKind.SECURITY
    private fun model() = NasServiceSettingsModel(scope, { repository }, { store })
    private suspend fun idle(model: NasServiceSettingsModel) { withTimeout(5_000) { while (model.state.value.values.any { it.busy }) delay(10) }; delay(20) }
    private suspend fun loaded(model: NasServiceSettingsModel) { model.refresh(kind, notify = false); idle(model) }
    private suspend fun edit(model: NasServiceSettingsModel) {
        loaded(model); val original = repository.nasServices.load(kind) as NasServiceValue.Security
        assertTrue(model.begin(original)); model.draft(kind, original.copy(settings = original.settings.copy(isFirewallEnabled = true)))
    }
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) {} }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `中断后保留原任务回执冷启动只读终态和完整配置不重新清理`() = runBlocking {
        var model = model(); edit(model)
        fixture.backend.before = { if (it.method == "status") throw IOException("Synthetic disconnected") }
        assertTrue(model.save(kind)); idle(model)
        assertTrue(model.state.value.getValue(kind).blocked); assertFalse(model.save(kind))
        val saved = store.records(repository.owner!!).single().steps.single()
        assertTrue(saved.requiresTask); assertEquals("synthetic-firewall-task", saved.task?.id); assertNull(saved.task?.outcome)
        assertFalse(preferences.all.values.joinToString().contains("synthetic-profile"))
        model.clear(); repository = fixture.repository("next"); fixture.backend.before = {}; model = model(); loaded(model)
        assertFalse(model.state.value.getValue(kind).blocked); assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(kind).result?.status)
        assertEquals(listOf("start"), fixture.backend.writes.map { it.method })
        val task = store.records(repository.owner!!).single().steps.single().task!!
        assertEquals(true, task.outcome); assertFalse(task.cleanupAttempted)
        assertNull(model.state.value.getValue(kind).draft)
    }
    @Test fun `没有任务回执不能凭开启状态恢复成功或丢弃保护`() = runBlocking {
        var model = model(); edit(model); fixture.backend.taskReceipt = JsonObject(emptyMap())
        fixture.backend.afterWrite = { fixture.backend.rows[NasServiceStep.FIREWALL] = NasServiceSettingsFixture.row("""{"enable_firewall":true,"profile_name":"synthetic-profile"}""") }
        model.save(kind); idle(model); model.clear(); repository = fixture.repository("next"); model = model(); loaded(model)
        assertTrue(model.state.value.getValue(kind).blocked); model.dismiss(kind, true); assertNotNull(model.state.value.getValue(kind).record)
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, model.state.value.getValue(kind).result?.status)
        assertEquals(listOf("start"), fixture.backend.writes.map { it.method }); assertTrue(fixture.backend.requests.none { it.method == "status" })
    }
    @Test fun `已知任务失败冷恢复保留失败即使开关后来相同`() = runBlocking {
        var model = model(); edit(model)
        fixture.backend.before = { if (it.method == "status") throw IOException("Synthetic interrupted") }
        model.save(kind); idle(model); model.clear()
        fixture.backend.before = {}; fixture.backend.taskStatus = NasServiceSettingsFixture.row("""{"success":false}""")
        fixture.backend.rows[NasServiceStep.FIREWALL] = NasServiceSettingsFixture.row("""{"enable_firewall":true,"profile_name":"synthetic-profile"}""")
        repository = fixture.repository("next"); model = model(); loaded(model)
        assertFalse(model.state.value.getValue(kind).blocked); assertEquals(MutationResultStatus.CONFIRMED_FAILURE, model.state.value.getValue(kind).result?.status)
        assertEquals(listOf("start"), fixture.backend.writes.map { it.method }); assertEquals(false, store.records(repository.owner!!).single().steps.single().task?.outcome)
    }
    @Test fun `清理回执丢失保留尝试事实重启只读取不第二次清理`() = runBlocking {
        var model = model(); edit(model)
        fixture.backend.afterWrite = { if (it.method == "stop") throw IOException("Synthetic stop receipt lost") }
        model.save(kind); idle(model); assertTrue(model.state.value.getValue(kind).blocked)
        var task = store.records(repository.owner!!).single().steps.single().task!!
        assertTrue(task.cleanupAttempted); assertFalse(task.cleanupAccepted)
        model.clear(); fixture.backend.afterWrite = {}; repository = fixture.repository("next"); model = model(); loaded(model)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(kind).result?.status)
        assertEquals(listOf("start", "stop"), fixture.backend.writes.map { it.method })
        task = store.records(repository.owner!!).single().steps.single().task!!; assertTrue(task.cleanupAttempted); assertFalse(task.cleanupAccepted)
    }
    @Test fun `换会话旧确认和初次持久失败均零写且账号隔离`() = runBlocking {
        val model = model(); edit(model); repository = fixture.repository("replacement")
        assertFalse(model.save(kind)); assertTrue(fixture.backend.writes.isEmpty())
        edit(model); preferences.commitSucceeds = false; assertTrue(model.save(kind)); idle(model)
        assertTrue(fixture.backend.writes.isEmpty()); assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.getValue(kind).failure?.kind)
    }
    @Test fun `任务记录约束原回执终态和清理事实不能回退或伪造成功`() {
        val owner = repository.owner!!
        val record = NasServiceRecord("security", owner, kind, listOf(NasServiceStepRecord(NasServiceStep.FIREWALL, "a".repeat(64), requiresTask = true)))
        store.begin(record); store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.FIREWALL, NasServiceStage.SUBMITTED))
        rejected { store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.FIREWALL, NasServiceStage.VERIFIED)) }
        var task = NasFirewallTask("synthetic-firewall-task")
        store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.FIREWALL, NasServiceStage.ACCEPTED, task))
        rejected { store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.FIREWALL, NasServiceStage.ACCEPTED, task.copy(id = "another-task"))) }
        task = task.copy(outcome = true, cleanupAttempted = true)
        store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.FIREWALL, NasServiceStage.ACCEPTED, task))
        rejected { store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.FIREWALL, NasServiceStage.ACCEPTED, task.copy(outcome = false))) }
        rejected { store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.FIREWALL, NasServiceStage.ACCEPTED, task.copy(cleanupAttempted = false))) }
        store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.FIREWALL, NasServiceStage.VERIFIED))
        assertEquals(task, store.records(owner).single().steps.single().task)
        assertTrue(store.records(owner.copy(identityRevision = "another-account")).isEmpty())
        assertFalse(task.toString().contains("synthetic-firewall-task"))
    }
}
