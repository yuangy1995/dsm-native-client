package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.DdnsMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class NasDdnsRecoveryModelTest {
    private val f = NasDdnsProtocolFixture(); private var repository = f.repository()
    private val prefs = MemoryPreferences(); private val store = NasDdnsActivityStore(prefs)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private fun model() = NasDdnsModel(scope, { repository }, { store })
    private suspend fun idle(m: NasDdnsModel) { withTimeout(5_000) { while (m.state.value.busy) delay(10) } }
    private suspend fun load(m: NasDdnsModel) { m.refresh(); idle(m) }
    private fun newDraft(m: NasDdnsModel) { assertTrue(m.begin(f.draft())); m.draft(f.draft()) }
    private fun edit(m: NasDdnsModel, onlyPassword: Boolean = false) {
        val old = m.state.value.current!!.records.single()
        val draft = NasDdnsDraft(originalProviderId = old.providerId, providerId = old.providerId, hostname = old.hostname, username = old.username)
        assertTrue(m.begin(draft)); m.draft(if (onlyPassword) draft.copy(password = "synthetic-new-secret") else draft.copy(heartbeat = true))
    }
    private suspend fun submit(m: NasDdnsModel, operation: DdnsMutationOperation) {
        assertTrue(m.prepare(operation)); assertTrue(m.confirm(m.state.value.confirmation!!)); idle(m)
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `保存未知跨重启只读恢复且不保存域名账号与密码`() = runBlocking {
        var m = model(); load(m); newDraft(m)
        f.afterWrite = { f.before = { if (!it.oneShot) throw IOException("Synthetic offline") } }
        submit(m, DdnsMutationOperation.SAVE); assertTrue(m.state.value.blocked); assertNull(m.state.value.draft)
        m.dismiss(true); assertNotNull(m.state.value.record); assertFalse(m.prepare(DdnsMutationOperation.SAVE))
        m.clear(); f.before = {}; f.afterWrite = {}; repository = f.repository("next"); m = model(); load(m)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, m.state.value.result?.status); assertFalse(m.state.value.blocked); assertEquals(1, f.writes.size)
        val raw = prefs.all.values.joinToString(); assertFalse(raw.contains("synthetic-only-secret")); assertFalse(raw.contains("example.invalid")); assertFalse(raw.contains("synthetic-user")); assertFalse(raw.contains("Example"))
    }
    @Test fun `仅密码无接受回执跨重启仍未知不因列表相同解除`() = runBlocking {
        f.saved(); var m = model(); load(m); edit(m, true); f.afterWrite = { throw IOException("Synthetic lost receipt") }
        submit(m, DdnsMutationOperation.SAVE); assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, m.state.value.result?.status)
        m.clear(); repository = f.repository("next"); f.afterWrite = {}; m = model(); load(m)
        assertTrue(m.state.value.blocked); assertFalse(m.state.value.record!!.accepted); m.dismiss(true); assertNotNull(m.state.value.record)
        assertEquals(1, f.writes.size)
    }
    @Test fun `接受密码保存但读取中断可冷恢复`() = runBlocking {
        f.saved(); var m = model(); load(m); edit(m, true)
        f.afterWrite = { f.before = { if (!it.oneShot) throw IOException("Synthetic offline") } }
        submit(m, DdnsMutationOperation.SAVE); assertTrue(m.state.value.record!!.accepted)
        m.clear(); f.before = {}; f.afterWrite = {}; repository = f.repository("next"); m = model(); load(m)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, m.state.value.result?.status); assertEquals(1, f.writes.size)
    }
    @Test fun `瞬时测试和更新未知保留历史且允许新的明确操作`() = runBlocking {
        for (operation in listOf(DdnsMutationOperation.TEST, DdnsMutationOperation.ADDRESS_REFRESH)) {
            if (operation == DdnsMutationOperation.ADDRESS_REFRESH) f.saved()
            val m = model(); load(m); if (operation == DdnsMutationOperation.TEST) newDraft(m)
            f.afterWrite = { throw IOException("Synthetic lost receipt") }; submit(m, operation)
            val id = m.state.value.record!!.id; assertFalse(m.state.value.blocked)
            load(m); assertEquals(NasServiceStage.SUBMITTED, m.state.value.record?.stage)
            m.dismiss(true); assertTrue(store.records(repository.owner!!).single { it.id == id }.dismissed)
            assertEquals(NasServiceStage.SUBMITTED, store.records(repository.owner!!).single { it.id == id }.stage)
            f.afterWrite = {}; if (operation == DdnsMutationOperation.TEST) newDraft(m)
            val writes = f.writes.size; submit(m, operation); assertEquals(writes + 1, f.writes.size)
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, m.state.value.result?.status); m.dismiss(true); m.clear()
        }
    }
    @Test fun `离页及换会话清密码和旧确认且记录按原身份隔离`() = runBlocking {
        val m = model(); load(m); newDraft(m); assertTrue(m.prepare(DdnsMutationOperation.SAVE)); val old = m.state.value.confirmation!!
        m.leave(); assertNull(m.state.value.draft); assertFalse(m.confirm(old))
        newDraft(m); assertTrue(m.prepare(DdnsMutationOperation.SAVE)); val next = m.state.value.confirmation!!
        repository = f.repository("new", "different-account"); assertFalse(m.confirm(next)); assertNull(m.state.value.draft); assertTrue(f.writes.isEmpty())
    }
    @Test fun `记录首次保存失败零写且提交密码立即从编辑状态清除`() = runBlocking {
        val m = model(); load(m); newDraft(m); assertTrue(m.prepare(DdnsMutationOperation.SAVE)); val plan = m.state.value.confirmation!!
        prefs.commitSucceeds = false; assertTrue(m.confirm(plan)); assertEquals("", m.state.value.draft?.password); idle(m)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, m.state.value.failure?.kind); assertTrue(f.writes.isEmpty()); assertFalse(m.confirm(plan))
    }
    @Test fun `连接测试完成保留无密码草稿用户仍须另行保存`() = runBlocking {
        val m = model(); load(m); newDraft(m); submit(m, DdnsMutationOperation.TEST)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, m.state.value.result?.status); assertTrue(f.rows.isEmpty())
        assertEquals("", m.state.value.draft?.password); m.dismiss(); assertNotNull(m.state.value.draft)
        m.draft(requireNotNull(m.state.value.draft).copy(password = "synthetic-new-secret")); submit(m, DdnsMutationOperation.SAVE)
        assertEquals(listOf("test", "create"), f.writes.map { it.method }); assertNull(m.state.value.draft)
    }
    @Test fun `开始下一次编辑不沿用已结束动作结果且刷新后重新建立原基线`() = runBlocking {
        f.saved(); val m = model(); load(m); edit(m); submit(m, DdnsMutationOperation.SAVE)
        assertNotNull(m.state.value.result); assertTrue(m.begin(NasDdnsDraft(originalProviderId = "Example", providerId = "Example", hostname = "saved.example.invalid", username = "synthetic-user", heartbeat = true)))
        assertNull(m.state.value.record); assertNull(m.state.value.result)
        m.draft(requireNotNull(m.state.value.draft).copy(heartbeat = false)); assertTrue(m.prepare(DdnsMutationOperation.SAVE))
        f.fields("hostname" to kotlinx.serialization.json.JsonPrimitive("changed.example.invalid"))
        assertTrue(m.confirm(m.state.value.confirmation!!)); idle(m)
        assertEquals(MutationErrorCategory.CONFLICT, m.state.value.result?.errorCategory)
        m.dismiss(true); load(m); assertEquals("changed.example.invalid", m.state.value.current?.records?.single()?.hostname)
        assertEquals(1, f.writes.size)
    }

}
