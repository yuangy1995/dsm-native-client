package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasPowerSettingsModelTest {
    private val fixture = NasServiceProtocolFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private val store = NasServiceActivityStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val memory = NasServiceKind.MEMORY_COMPRESSION; private val power = NasServiceKind.POWER_SCHEDULE
    private val on = NasServiceStep.ZRAM; private val mark = NasServiceStep.REBOOT_REQUIRED; private val schedules = NasServiceStep.POWER_SCHEDULE
    private fun model() = NasServiceSettingsModel(scope, { repository }, { store })
    private suspend fun idle(model: NasServiceSettingsModel) { withTimeout(5_000) { while (model.state.value.values.any { it.busy }) delay(10) }; delay(30) }
    private suspend fun load(model: NasServiceSettingsModel, kind: NasServiceKind) { model.refresh(kind, notify = false); idle(model) }
    private suspend fun edit(model: NasServiceSettingsModel, kind: NasServiceKind = memory) {
        load(model, kind); val current = model.state.value.getValue(kind).current!!; assertTrue(model.begin(current))
        model.draft(kind, when (current) {
            is NasServiceValue.MemoryCompression -> current.copy(settings = current.settings.copy(enabled = !current.settings.enabled!!))
            is NasServiceValue.PowerSchedule -> current.copy(settings = current.settings.copy(total = 1, entries = listOf(NasPowerScheduleEntry(NasPowerScheduleAction.SHUTDOWN, false, setOf(0, 6), 22, 5))))
            else -> error("Unexpected kind")
        })
    }
    private suspend fun cold(old: NasServiceSettingsModel, kind: NasServiceKind): NasServiceSettingsModel {
        old.clear(); repository = fixture.repository("new-session"); fixture.backend.before = {}; fixture.backend.afterWrite = {}; fixture.writeRejectionCode = null
        return model().also { load(it, kind) }
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `独立读取空计划可信压缩与失败三态不混淆`() = runBlocking {
        val model = model(); assertFalse(model.state.value.getValue(memory).loaded)
        load(model, memory); val memoryState = model.state.value.getValue(memory); assertTrue(memoryState.loaded); assertNotNull(memoryState.current); assertNull(memoryState.failure)
        load(model, power); assertTrue((model.state.value.getValue(power).current as NasServiceValue.PowerSchedule).settings.entries.isEmpty())
        fixture.backend.before = { if (it.step == schedules) throw IOException("Synthetic offline") }; load(model, power)
        assertNotNull(model.state.value.getValue(power).failure); assertNotNull(model.state.value.getValue(power).current)
        assertNull(model.state.value.getValue(memory).failure)
    }
    @Test fun `压缩首步丢回执不能因冷读取相同就放开编辑或补标记`() = runBlocking {
        var model = model(); edit(model); fixture.backend.afterWrite = { if (it.step == on) throw IOException("Synthetic lost receipt") }
        model.save(memory); idle(model); model = cold(model, memory)
        val state = model.state.value.getValue(memory); assertTrue(state.blocked); assertNull(state.record!!.continuationStep)
        assertFalse(model.continuePendingStep(state.record)); assertFalse(model.begin(state.current!!))
        model.dismiss(memory, discard = true); assertNotNull(model.state.value.getValue(memory).record)
        assertEquals(listOf(on), fixture.backend.writes.map { it.step })
    }
    @Test fun `首步已接受但未提交标记冷恢复后用户继续只提交标记`() = runBlocking {
        var model = model(); edit(model)
        fixture.backend.afterWrite = { if (it.step == on) fixture.backend.before = { request -> if (!request.write) throw IOException("Synthetic offline") } }
        model.save(memory); idle(model); model = cold(model, memory)
        val record = model.state.value.getValue(memory).record!!; assertEquals(mark, record.continuationStep); assertFalse(model.state.value.getValue(memory).blocked)
        assertEquals(listOf(on), fixture.backend.writes.map { it.step }); assertTrue(model.continuePendingStep(record)); assertFalse(model.continuePendingStep(record)); idle(model)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(memory).result?.status)
        assertEquals(listOf(on, mark), fixture.backend.writes.map { it.step }); assertFalse(model.continuePendingStep(record))
        assertEquals(true, (model.state.value.getValue(memory).current as NasServiceValue.MemoryCompression).settings.rebootRequired)
    }
    @Test fun `标记丢回执即使读取为真也不允许继续或解除保护`() = runBlocking {
        var model = model(); edit(model); fixture.backend.afterWrite = { if (it.step == mark) throw IOException("Synthetic lost receipt") }
        model.save(memory); idle(model); model = cold(model, memory)
        val state = model.state.value.getValue(memory); assertTrue(state.blocked); assertNull(state.record!!.continuationStep)
        assertTrue(state.record.steps.first().accepted); assertFalse(state.record.steps.last().accepted)
        assertFalse(model.continuePendingStep(state.record)); assertEquals(2, fixture.backend.writes.size)
    }
    @Test fun `标记已接受读取失败冷恢复只读完成`() = runBlocking {
        var model = model(); edit(model)
        fixture.backend.afterWrite = { if (it.step == mark) fixture.backend.before = { request -> if (!request.write) throw IOException("Synthetic offline") } }
        model.save(memory); idle(model); assertTrue(model.state.value.getValue(memory).blocked); model = cold(model, memory)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(memory).result?.status)
        assertEquals(2, fixture.backend.writes.size); assertNull(model.state.value.getValue(memory).record!!.continuationStep)
    }
    @Test fun `标记明确拒绝可以主动继续但开关漂移旧会话及存储失败不能发送`() = runBlocking {
        val model = model(); edit(model); fixture.backend.afterWrite = { if (it.step == mark) fixture.writeRejectionCode = 105 }
        model.save(memory); idle(model); val record = model.state.value.getValue(memory).record!!; assertEquals(mark, record.continuationStep)
        fixture.writeRejectionCode = null; fixture.backend.afterWrite = {}
        fixture.backend.rows[on] = NasServiceSettingsFixture.row("""{"enable_zram":false}""")
        assertTrue(model.continuePendingStep(record)); idle(model); assertEquals(DsmErrorKind.NAS_SERVICE_CHANGED, model.state.value.getValue(memory).failure?.kind)
        fixture.backend.rows[on] = NasServiceSettingsFixture.row("""{"enable_zram":true}""")
        repository = fixture.repository("next"); assertFalse(model.continuePendingStep(record)); load(model, memory)
        preferences.commitSucceeds = false; assertTrue(model.continuePendingStep(model.state.value.getValue(memory).record!!)); idle(model)
        assertEquals(2, fixture.backend.writes.size); assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.getValue(memory).failure?.kind)
    }
    @Test fun `电源保存与草稿删除只在显式保存后写且不保存时间正文`() = runBlocking {
        val model = model(); edit(model, power); assertTrue(fixture.backend.writes.isEmpty())
        assertTrue(model.save(power)); assertFalse(model.save(power)); idle(model)
        assertEquals(1, fixture.backend.writes.size); assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(power).result?.status)
        val serialized = preferences.all.values.joinToString(); assertFalse(serialized.contains("UTC")); assertFalse(serialized.contains("weekdays")); assertFalse(serialized.contains("poweroff_tasks"))
        val current = model.state.value.getValue(power).current as NasServiceValue.PowerSchedule; assertTrue(model.begin(current))
        model.draft(power, current.copy(settings = current.settings.copy(entries = emptyList(), total = 0)))
        assertEquals(1, fixture.backend.writes.size); model.save(power); idle(model); assertEquals(2, fixture.backend.writes.size)
        assertTrue((model.state.value.getValue(power).current as NasServiceValue.PowerSchedule).settings.entries.isEmpty())
    }
    @Test fun `电源已提交离线冷恢复只读取完整清单且时区漂移保持阻塞`() = runBlocking {
        for (zoneDrift in listOf(false, true)) {
            var model = model(); edit(model, power)
            fixture.backend.afterWrite = { if (it.step == schedules) fixture.backend.before = { request -> if (!request.write) throw IOException("Synthetic offline") } }
            model.save(power); idle(model); assertTrue(model.state.value.getValue(power).blocked)
            if (zoneDrift) fixture.backend.rows[schedules] = JsonObject(fixture.backend.rows.getValue(schedules) + ("timezone" to JsonPrimitive("Asia/Shanghai")))
            model = cold(model, power); assertEquals(zoneDrift, model.state.value.getValue(power).blocked)
            if (!zoneDrift) {
                assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(power).result?.status)
                model.dismiss(power, discard = true)
                fixture.backend.rows[schedules] = NasServiceSettingsFixture.row("""{"poweron_tasks":[],"poweroff_tasks":[],"timezone":"UTC"}""")
            }
            model.clear()
        }
        assertEquals(2, fixture.backend.writes.size)
    }
    @Test fun `写前存储失败账号切换和迟到旧页面请求均零写入`() = runBlocking {
        val model = model(); edit(model, power); repository = fixture.repository(identity = "another")
        assertFalse(model.save(power)); load(model, power); edit(model, power)
        preferences.commitSucceeds = false; assertTrue(model.save(power)); idle(model)
        assertTrue(fixture.backend.writes.isEmpty()); assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.getValue(power).failure?.kind)
        model.clear(); assertNull(model.state.value.getValue(power).current)
    }
    @Test fun `恢复记录不允许从未提交步骤成功或无回执重开未知标记`() {
        val owner = repository.owner!!; val record = NasServiceRecord("memory", owner, memory,
            listOf(NasServiceStepRecord(on, "a".repeat(64)), NasServiceStepRecord(mark, "b".repeat(64))))
        store.begin(record)
        fun reject(block: () -> Unit) { try { block(); fail() } catch (_: DsmFailure) {} }
        reject { store.checkpoint(owner, record.id, NasServiceCheckpoint(mark, NasServiceStage.VERIFIED)) }
        store.checkpoint(owner, record.id, NasServiceCheckpoint(on, NasServiceStage.SUBMITTED))
        reject { store.checkpoint(owner, record.id, NasServiceCheckpoint(on, NasServiceStage.VERIFIED)) }
        store.checkpoint(owner, record.id, NasServiceCheckpoint(on, NasServiceStage.ACCEPTED)); store.checkpoint(owner, record.id, NasServiceCheckpoint(on, NasServiceStage.VERIFIED))
        store.checkpoint(owner, record.id, NasServiceCheckpoint(mark, NasServiceStage.SUBMITTED)); reject { store.prepareContinuation(owner, record.id) }
        store.checkpoint(owner, record.id, NasServiceCheckpoint(mark, NasServiceStage.REJECTED)); store.prepareContinuation(owner, record.id)
        assertEquals(NasServiceStage.PREPARED, store.records(owner).single().steps.last().stage)
    }
}
