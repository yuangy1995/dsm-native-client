package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasRegionSettingsModelTest {
    private val fixture = NasRegionProtocolFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private val store = NasRegionActivityStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private fun model() = NasRegionSettingsModel(scope, { repository }, { store })
    private suspend fun idle(model: NasRegionSettingsModel) { withTimeout(5_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun loaded(model: NasRegionSettingsModel) { model.refresh(); idle(model) }
    private fun editNetwork(model: NasRegionSettingsModel) {
        assertTrue(model.begin()); model.draft(model.state.value.draft!!.copy(isNetworkTimeEnabled = true, timeServers = listOf("time.example.invalid")))
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `FORM和JSON真实配置与校时请求都为单次传输`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            val f = NasRegionProtocolFixture(); f.requestFormat = format; val repo = f.repository(); val original = repo.regionSettings()
            val result = repo.nasRegion.save(repo.nasRegion.plan(original, original.copy(isNetworkTimeEnabled = true, timeServers = listOf("time.example.invalid")))) {}
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(listOf("set", "sync"), f.backend.writes.map { it.method })
            assertEquals(2, f.requests.count { it.body?.isOneShot() == true }); assertEquals(JsonPrimitive("ntp"), f.backend.writes[0].fields["enable_ntp"])
            assertEquals(JsonArray(listOf(JsonPrimitive("time.example.invalid"))), f.backend.writes[1].fields["servers"])
        }
        val model = model(); loaded(model); editNetwork(model); assertTrue(model.save()); idle(model)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.result?.status); assertNull(model.state.value.draft)
    }
    @Test fun `保存后断线冷恢复仅配置完成不重发未执行校时`() = runBlocking {
        var model = model(); loaded(model); editNetwork(model)
        fixture.backend.afterWrite = { fixture.backend.before = { if (!it.write) throw IOException("Synthetic offline") } }
        assertTrue(model.save()); idle(model); assertTrue(model.state.value.blocked); assertFalse(model.save())
        assertFalse(preferences.all.values.joinToString().contains("time.example.invalid")); model.clear()
        repository = fixture.repository("next"); fixture.backend.before = {}; fixture.backend.afterWrite = {}; model = model(); loaded(model)
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, model.state.value.result?.status); assertEquals(1, fixture.backend.writes.size)
        assertTrue(model.state.value.canSynchronize)
        assertTrue(model.save(synchronizeOnly = true, confirmed = model.state.value.current)); idle(model)
        assertEquals(listOf("set", "sync"), fixture.backend.writes.map { it.method }); assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.result?.status)
    }
    @Test fun `手动改时丢回执即使读数相近也不能完成或再提交`() = runBlocking {
        var model = model(); loaded(model); assertTrue(model.begin())
        model.draft(model.state.value.draft!!.copy(manualDateTime = model.state.value.current!!.manualDateTime!!.copy(minute = 31)))
        fixture.backend.afterWrite = { throw IOException("Synthetic lost receipt") }
        model.save(); idle(model); assertTrue(model.state.value.blocked); assertEquals(0, model.state.value.result?.counts?.succeeded)
        model.clear(); repository = fixture.repository("next"); model = model(); loaded(model)
        assertTrue(model.state.value.blocked); model.dismiss(true); assertNotNull(model.state.value.record)
        assertFalse(model.begin()); assertFalse(model.save()); assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `已接受手动改时可冷恢复但必须读数和完整配置匹配`() = runBlocking {
        var model = model(); loaded(model); model.begin()
        model.draft(model.state.value.draft!!.copy(manualDateTime = model.state.value.current!!.manualDateTime!!.copy(minute = 31)))
        fixture.backend.afterWrite = { fixture.backend.before = { if (!it.write) throw IOException("Synthetic offline") } }
        model.save(); idle(model); assertTrue(store.records(repository.owner!!).single().steps.single().accepted)
        model.clear(); repository = fixture.repository("next"); fixture.backend.before = {}; fixture.backend.field("minute", JsonPrimitive(50)); model = model(); loaded(model)
        assertTrue(model.state.value.blocked)
        fixture.backend.field("minute", JsonPrimitive(31)); model.refresh(); idle(model)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.result?.status); assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `未知校时仅用户新确认可再发且历史仍保留未知`() = runBlocking {
        fixture.backend.field("enable_ntp", JsonPrimitive("ntp")); fixture.backend.field("server", JsonPrimitive("time.example.invalid"))
        val model = model(); loaded(model); fixture.backend.afterWrite = { throw IOException("Synthetic lost receipt") }
        assertTrue(model.save(true, model.state.value.current)); idle(model); assertTrue(model.state.value.blocked)
        val first = model.state.value.record!!.id; model.refresh(); idle(model); assertEquals(1, fixture.backend.writes.size)
        assertTrue(model.state.value.canSynchronize); fixture.backend.afterWrite = {}
        assertTrue(model.save(true, model.state.value.current)); idle(model)
        val old = store.records(repository.owner!!).single { it.id == first }
        assertEquals(NasServiceStage.SUBMITTED, old.steps.single().stage); assertEquals(model.state.value.record!!.id, old.supersededBy)
        assertEquals(2, fixture.backend.writes.size); assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.result?.status)
    }
    @Test fun `独立校时确认绑定原页面快照不能跨刷新或跨账号使用`() = runBlocking {
        fixture.backend.field("enable_ntp", JsonPrimitive("ntp")); fixture.backend.field("server", JsonPrimitive("time.example.invalid"))
        val model = model(); loaded(model); val confirmed = model.state.value.current
        model.refresh(); idle(model); assertFalse(model.save(true, confirmed)); assertTrue(fixture.backend.writes.isEmpty())
        val another = model.state.value.current; repository = fixture.repository("another-session"); loaded(model)
        assertFalse(model.save(true, another)); assertTrue(fixture.backend.writes.isEmpty())
        assertTrue(model.save(true, model.state.value.current)); idle(model); assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `旧账号表单或落盘失败不写但未知DSM可保存`() = runBlocking {
        val model = model(); loaded(model); editNetwork(model); repository = fixture.repository("new"); assertFalse(model.save()); assertTrue(fixture.backend.writes.isEmpty())
        loaded(model); editNetwork(model); preferences.commitSucceeds = false; model.save(); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.failure?.kind); assertTrue(fixture.backend.writes.isEmpty())
        val unknown = NasRegionProtocolFixture(); unknown.knownEnvironment = false; val repo = unknown.repository(); val original = repo.nasRegion.load()
        val result = repo.nasRegion.save(repo.nasRegion.plan(original, original.copy(dateFormat = "Y/m/d", manualDateTime = null))) {}
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertTrue(result.submitted); assertEquals(1, unknown.backend.writes.size)
    }
}
