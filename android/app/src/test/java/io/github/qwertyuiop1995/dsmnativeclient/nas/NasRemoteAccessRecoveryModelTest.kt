package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class NasRemoteAccessRecoveryModelTest {
    private val fixture = NasServiceProtocolFixture(); private var repository = fixture.repository()
    private val prefs = MemoryPreferences(); private val store = NasServiceActivityStore(prefs)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private val kind = NasServiceKind.REMOTE_ACCESS
    private fun model() = NasServiceSettingsModel(scope, { repository }, { store })
    private suspend fun idle(model: NasServiceSettingsModel) { withTimeout(5_000) { while (model.state.value.getValue(kind).busy) delay(10) } }
    private suspend fun loaded(model: NasServiceSettingsModel) { model.refresh(kind, notify = false); idle(model) }
    private suspend fun edit(model: NasServiceSettingsModel) {
        val original = repository.nasServices.load(kind) as NasServiceValue.RemoteAccess
        assertTrue(model.begin(original)); model.draft(kind, original.copy(settings = original.settings.copy(isRelayEnabled = false, isRouterConfigurationEnabled = true)))
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `FORM和JSON真实单次请求及新旧服务记录兼容`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            val f = NasServiceProtocolFixture(); f.requestFormat = format; val repo = f.repository()
            val original = repo.nasServices.load(kind) as NasServiceValue.RemoteAccess
            val result = repo.nasServices.save(repo.nasServices.plan(original, original.copy(settings = original.settings.copy(isRelayEnabled = false, isRouterConfigurationEnabled = true)))) {}
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(2, f.requests.count { it.body?.isOneShot() == true })
        }
        val owner = repository.owner!!
        store.begin(NasServiceRecord("old-proxy", owner, NasServiceKind.PROXY, listOf(NasServiceStepRecord(NasServiceStep.PROXY, "a".repeat(64)))))
        val model = model(); loaded(model); edit(model); model.save(kind); idle(model)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(kind).result?.status)
        assertEquals(2, store.records(owner).size); assertFalse(store.records(owner).single { it.id == "old-proxy" }.terminal)
    }
    @Test fun `断网冷恢复原账号只读不补发路由器开关`() = runBlocking {
        var model = model(); loaded(model); edit(model)
        fixture.backend.afterWrite = { fixture.backend.before = { if (!it.write) throw IOException("Synthetic offline") } }
        model.save(kind); idle(model); assertTrue(model.state.value.getValue(kind).blocked)
        assertFalse(model.save(kind)); model.dismiss(kind, true); assertNotNull(model.state.value.getValue(kind).record)
        model.clear(); repository = fixture.repository("next"); fixture.backend.before = {}; model = model(); loaded(model)
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, model.state.value.getValue(kind).result?.status)
        assertEquals(1, fixture.backend.writes.size); assertFalse(model.state.value.getValue(kind).blocked); assertNull(model.state.value.getValue(kind).draft)
        assertFalse(prefs.all.values.joinToString().contains("relay_enabled"))
    }
    @Test fun `旧账号表单与首次记录失败都零写入`() = runBlocking {
        val model = model(); loaded(model); edit(model); repository = fixture.repository("new"); assertFalse(model.save(kind))
        loaded(model); edit(model); prefs.commitSucceeds = false; model.save(kind); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.getValue(kind).failure?.kind); assertTrue(fixture.backend.writes.isEmpty())
    }
}
