package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasServiceSettingsModelTest {
    private val fixture = NasServiceProtocolFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private val store = NasServiceActivityStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private fun model() = NasServiceSettingsModel(scope, { repository }, { store })
    private suspend fun idle(model: NasServiceSettingsModel) { withTimeout(5_000) { while (model.state.value.values.any { it.busy }) delay(10) }; delay(20) }
    private suspend fun loaded(model: NasServiceSettingsModel) { model.load(); idle(model) }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `FORM和JSON真实单次传输完整终端字段与保存反馈`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            val f = NasServiceProtocolFixture(); f.requestFormat = format; val repo = f.repository()
            val value = repo.nasServices.load(NasServiceKind.TERMINAL) as NasServiceValue.Terminal
            val result = repo.nasServices.save(repo.nasServices.plan(value, value.copy(settings = value.settings.copy(isSshEnabled = true, sshPort = 2222)))) {}
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
            val request = f.backend.writes.single(); assertEquals(3, request.version)
            assertEquals(JsonPrimitive(true), request.fields["enable_ssh"]); assertEquals(JsonPrimitive(false), request.fields["enable_telnet"])
            assertEquals(JsonPrimitive(2222), request.fields["ssh_port"]); assertEquals(1, f.requests.count { it.body?.isOneShot() == true })
        }
        val model = model(); loaded(model); val original = repository.nasServices.load(NasServiceKind.TERMINAL) as NasServiceValue.Terminal
        assertTrue(model.begin(original)); model.draft(original.kind, original.copy(settings = original.settings.copy(isSshEnabled = true)))
        assertTrue(model.save(original.kind)); idle(model); assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(original.kind).result?.status)
        assertNull(model.state.value.getValue(original.kind).draft); assertTrue(store.records(repository.owner!!).single().terminal)
    }
    @Test fun `断线后冷恢复只读原配置摘要不保存地址不重复发送`() = runBlocking {
        var model = model(); loaded(model)
        val original = repository.nasServices.load(NasServiceKind.PROXY) as NasServiceValue.Proxy
        model.begin(original); model.draft(original.kind, original.copy(settings = original.settings.copy(isEnabled = true)))
        fixture.backend.afterWrite = { fixture.backend.before = { if (!it.write) throw IOException("Synthetic offline") } }
        model.save(original.kind); idle(model); assertTrue(model.state.value.getValue(original.kind).blocked)
        assertFalse(model.save(original.kind)); assertFalse(preferences.all.values.joinToString().contains("private.example.invalid"))
        model.clear(); repository = fixture.repository("next"); fixture.backend.before = {}; model = model(); loaded(model)
        assertFalse(model.state.value.getValue(original.kind).blocked); assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.state.value.getValue(original.kind).result?.status)
        assertEquals(1, fixture.backend.writes.size); assertNull(model.state.value.getValue(original.kind).draft)
    }
    @Test fun `仅部分终端字段生效保持整组保护直到全部匹配`() = runBlocking {
        val model = model(); loaded(model); val original = repository.nasServices.load(NasServiceKind.TERMINAL) as NasServiceValue.Terminal
        model.begin(original); model.draft(original.kind, original.copy(settings = original.settings.copy(isSshEnabled = true, sshPort = 2222)))
        fixture.backend.afterWrite = { fixture.backend.rows[NasServiceStep.TERMINAL] = JsonObject(fixture.backend.rows.getValue(NasServiceStep.TERMINAL) + ("ssh_port" to JsonPrimitive(22))) }
        model.save(original.kind); idle(model); assertTrue(model.state.value.getValue(original.kind).blocked)
        model.dismiss(original.kind, true); assertNotNull(model.state.value.getValue(original.kind).record)
        model.refresh(original.kind); idle(model); assertTrue(model.state.value.getValue(original.kind).blocked)
        fixture.backend.rows[NasServiceStep.TERMINAL] = JsonObject(fixture.backend.rows.getValue(NasServiceStep.TERMINAL) + ("ssh_port" to JsonPrimitive(2222)))
        model.refresh(original.kind); idle(model); assertFalse(model.state.value.getValue(original.kind).blocked); assertEquals(1, fixture.backend.writes.size)
    }
    @Test fun `旧表单换会话或存储失败零写入但未知DSM可保存`() = runBlocking {
        val model = model(); loaded(model); val original = repository.nasServices.load(NasServiceKind.TERMINAL) as NasServiceValue.Terminal
        model.begin(original); model.draft(original.kind, original.copy(settings = original.settings.copy(isSshEnabled = true)))
        repository = fixture.repository("replacement"); assertFalse(model.save(original.kind)); assertTrue(fixture.backend.writes.isEmpty())
        loaded(model); model.begin(original); model.draft(original.kind, original.copy(settings = original.settings.copy(isSshEnabled = true)))
        preferences.commitSucceeds = false; model.save(original.kind); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, model.state.value.getValue(original.kind).failure?.kind); assertTrue(fixture.backend.writes.isEmpty())
        val unknown = NasServiceProtocolFixture(); unknown.knownEnvironment = false; val repo = unknown.repository()
        val value = repo.nasServices.load(NasServiceKind.TERMINAL) as NasServiceValue.Terminal
        val result = repo.nasServices.save(repo.nasServices.plan(value, value.copy(settings = value.settings.copy(isSshEnabled = true)))) {}
        assertTrue(result.submitted); assertEquals(1, unknown.backend.writes.size)
    }
}
