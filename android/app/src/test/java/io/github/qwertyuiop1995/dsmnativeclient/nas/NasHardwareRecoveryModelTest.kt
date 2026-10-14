package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasHardwareRecoveryModelTest {
    private val fixture = NasServiceProtocolFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private val store = NasServiceActivityStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private val kind = NasServiceKind.HARDWARE
    private fun model() = NasServiceSettingsModel(scope, { repository }, { store })
    private suspend fun idle(model: NasServiceSettingsModel) { withTimeout(5_000) { while (model.state.value.values.any { it.busy }) delay(10) }; delay(20) }
    private suspend fun loaded(model: NasServiceSettingsModel) { model.refresh(kind, notify = false); idle(model) }
    private suspend fun edit(model: NasServiceSettingsModel) {
        loaded(model); val original = repository.nasServices.load(kind) as NasServiceValue.Hardware
        assertTrue(model.begin(original)); model.draft(kind, original.copy(settings = original.settings.copy(ledBrightness = 4)))
    }
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) {} }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `亮度写回执缺失冷恢复仍未知且没有继续应用入口`() = runBlocking {
        var model = model(); edit(model)
        fixture.backend.afterWrite = { if (it.method == "set_current_brightness") throw IOException("Synthetic lost receipt") }
        model.save(kind); idle(model); model.clear(); repository = fixture.repository("next"); fixture.backend.afterWrite = {}; model = model(); loaded(model)
        val state = model.state.value.getValue(kind); assertTrue(state.blocked); assertFalse(state.record!!.canContinueLed)
        assertFalse(model.continuePendingStep(state.record)); model.dismiss(kind, true); assertNotNull(model.state.value.getValue(kind).record)
        assertEquals(listOf("set_current_brightness"), fixture.backend.writes.map { it.method })
    }
    @Test fun `已接受亮度但未发送应用冷恢复后只在主动继续时发送一次应用`() = runBlocking {
        var model = model(); edit(model)
        fixture.backend.afterWrite = { if (it.method == "set_current_brightness") fixture.backend.before = { request -> if (!request.write) throw IOException("Synthetic offline") } }
        model.save(kind); idle(model); assertTrue(model.state.value.getValue(kind).blocked)
        model.clear(); repository = fixture.repository("next"); fixture.backend.before = {}; fixture.backend.afterWrite = {}; model = model(); loaded(model)
        val record = model.state.value.getValue(kind).record!!
        assertTrue(record.canContinueLed); assertFalse(model.state.value.getValue(kind).blocked)
        assertEquals(listOf("set_current_brightness"), fixture.backend.writes.map { it.method })
        assertTrue(model.continuePendingStep(record)); assertFalse(model.continuePendingStep(record)); idle(model)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(kind).result?.status)
        assertFalse(model.state.value.getValue(kind).record!!.canContinueLed)
        assertEquals(listOf("set_current_brightness", "update"), fixture.backend.writes.map { it.method })
        assertFalse(model.continuePendingStep(record)); assertTrue(store.records(repository.owner!!).single().steps.all { it.accepted })
    }
    @Test fun `应用已接受但读失败冷恢复可完成而不重复应用`() = runBlocking {
        var model = model(); edit(model)
        fixture.backend.afterWrite = { if (it.method == "update") fixture.backend.before = { request -> if (!request.write) throw IOException("Synthetic offline") } }
        model.save(kind); idle(model); assertTrue(model.state.value.getValue(kind).blocked)
        model.clear(); repository = fixture.repository("next"); fixture.backend.before = {}; fixture.backend.afterWrite = {}; model = model(); loaded(model)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(kind).result?.status)
        assertEquals(listOf("set_current_brightness", "update"), fixture.backend.writes.map { it.method })
        assertFalse(model.state.value.getValue(kind).record!!.canContinueLed)
    }
    @Test fun `应用回执丢失不能冷恢复认领或再次发送`() = runBlocking {
        var model = model(); edit(model)
        fixture.backend.afterWrite = { if (it.method == "update") throw IOException("Synthetic lost receipt") }
        model.save(kind); idle(model); model.clear(); repository = fixture.repository("next"); fixture.backend.afterWrite = {}; model = model(); loaded(model)
        val record = model.state.value.getValue(kind).record!!
        assertTrue(model.state.value.getValue(kind).blocked); assertFalse(record.canContinueLed); assertFalse(model.continuePendingStep(record))
        assertEquals(listOf("set_current_brightness", "update"), fixture.backend.writes.map { it.method })
        assertTrue(record.steps.first().accepted); assertFalse(record.steps.last().accepted)
    }
    @Test fun `继续前亮度漂移旧会话或存储失败均不补交应用`() = runBlocking {
        val model = model(); edit(model)
        fixture.backend.afterWrite = { if (it.method == "update") fixture.writeRejectionCode = 105 }
        model.save(kind); idle(model); val record = model.state.value.getValue(kind).record!!; assertTrue(record.canContinueLed)
        fixture.writeRejectionCode = null; fixture.backend.afterWrite = {}
        fixture.backend.rows[NasServiceStep.LED_BRIGHTNESS] = NasServiceSettingsFixture.row("""{"led_brightness":2}""")
        assertTrue(model.continuePendingStep(record)); idle(model); assertEquals(DsmErrorKind.NAS_SERVICE_CHANGED, model.state.value.getValue(kind).failure?.kind)
        assertEquals(2, fixture.backend.writes.size)
        repository = fixture.repository("changed-session"); assertFalse(model.continuePendingStep(record)); assertEquals(2, fixture.backend.writes.size)
        loaded(model); fixture.backend.rows[NasServiceStep.LED_BRIGHTNESS] = NasServiceSettingsFixture.row("""{"led_brightness":4}""")
        preferences.commitSucceeds = false; assertTrue(model.continuePendingStep(model.state.value.getValue(kind).record!!)); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.getValue(kind).failure?.kind); assertEquals(2, fixture.backend.writes.size)
    }
    @Test fun `首个持久失败换账号及旧表单不写硬件且记录不保存地址`() = runBlocking {
        val model = model(); edit(model); repository = fixture.repository(identity = "another-account")
        assertFalse(model.save(kind)); assertTrue(fixture.backend.writes.isEmpty()); loaded(model)
        val original = repository.nasServices.load(kind) as NasServiceValue.Hardware; assertTrue(model.begin(original))
        model.draft(kind, original.copy(settings = original.settings.copy(ups = original.settings.ups!!.copy(networkServerAddress = "synthetic-ups-secret.invalid"))))
        preferences.commitSucceeds = false; assertTrue(model.save(kind)); idle(model)
        assertTrue(fixture.backend.writes.isEmpty()); assertFalse(preferences.all.values.joinToString().contains("synthetic-ups-secret.invalid"))
    }
    @Test fun `持久LED步骤不允许无接受回执成功也不能重开未知应用`() {
        val owner = repository.owner!!
        val record = NasServiceRecord("led", owner, kind, listOf(NasServiceStepRecord(NasServiceStep.LED_BRIGHTNESS, "a".repeat(64)), NasServiceStepRecord(NasServiceStep.LED_UPDATE, "b".repeat(64))))
        store.begin(record); store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.LED_BRIGHTNESS, NasServiceStage.SUBMITTED))
        rejected { store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.LED_BRIGHTNESS, NasServiceStage.VERIFIED)) }
        store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.LED_BRIGHTNESS, NasServiceStage.ACCEPTED))
        store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.LED_BRIGHTNESS, NasServiceStage.VERIFIED))
        store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.LED_UPDATE, NasServiceStage.SUBMITTED))
        rejected { store.prepareContinuation(owner, record.id) }
        store.checkpoint(owner, record.id, NasServiceCheckpoint(NasServiceStep.LED_UPDATE, NasServiceStage.REJECTED))
        store.prepareContinuation(owner, record.id)
        assertEquals(NasServiceStage.PREPARED, store.records(owner).single().steps.last().stage)
        assertTrue(store.records(owner).single().steps.first().accepted)
    }
}
