package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasDirectoryModelTest {
    private val fixture = NasDirectoryProtocolFixture()
    private var repository = fixture.repository()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val preferences = MemoryPreferences()
    private val store = NasDirectoryActivityStore(preferences)
    private fun model() = NasDirectoryModel(scope, { repository }, { store })
    private suspend fun loaded(model: NasDirectoryModel) { model.load(); eventually { !model.state.value.loading && model.state.value.accounts != null } }
    private suspend fun eventually(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(10) }; delay(20) }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `真实传输保存删除共用账本且页面保留实际变化`() = runBlocking {
        val model = model(); loaded(model); model.edit(model.state.value.accounts!!.single())
        model.save(model.state.value.editor!!.copy(description = "Updated")); eventually { model.state.value.records.singleOrNull()?.terminal == true && !model.state.value.busy }
        assertEquals("Updated", model.state.value.accounts!!.single().description); assertNull(model.state.value.editor)
        assertTrue(fixture.requests.single { it.body?.isOneShot() == true }.body!!.isOneShot())
        model.delete(model.state.value.accounts!!.single()); model.confirmDelete(); eventually { model.state.value.records.size == 2 && model.state.value.records.all { it.terminal } && !model.state.value.busy }
        assertTrue(model.state.value.accounts!!.isEmpty()); assertEquals(2, fixture.backend.requests.count { it.write })
    }
    @Test fun `创建改密回执丢失重登录只读不能重发`() = runBlocking {
        var model = model(); loaded(model); model.create(NasDirectoryKind.ACCOUNT)
        fixture.backend.responseFailure = IOException("synthetic lost response")
        model.save(model.state.value.editor!!.copy(name = "NewSynthetic", password = "synthetic-password", passwordConfirmation = "synthetic-password"))
        eventually { model.state.value.records.singleOrNull()?.terminal == false && !model.state.value.busy }
        val id = model.state.value.records.single().id; assertFalse(model.state.value.writable)
        model.clear(); repository = fixture.repository("next"); model = model(); loaded(model)
        model.review(id); eventually { !model.state.value.busy }; assertFalse(model.state.value.records.single().terminal)
        model.create(NasDirectoryKind.ACCOUNT); assertNull(model.state.value.editor); assertEquals(1, fixture.backend.requests.count { it.write })
    }
    @Test fun `接受后读取失败可以原身份恢复且同名换编号保持未知`() = runBlocking {
        val model = model(); loaded(model); model.edit(model.state.value.accounts!!.single()); val oldId = model.state.value.accounts!!.single().id!!
        fixture.backend.afterWrite = { fixture.backend.readFailure = IOException("synthetic offline") }
        model.save(model.state.value.editor!!.copy(description = "Updated")); eventually { model.state.value.records.singleOrNull()?.accepted == true && !model.state.value.busy }
        val id = model.state.value.records.single().id
        fixture.backend.readFailure = null
        fixture.backend.users = fixture.backend.users.map { JsonObject(it + ("uid" to JsonPrimitive(oldId + 1))) }
        model.review(id); eventually { !model.state.value.busy }; assertFalse(model.state.value.records.single().terminal)
        fixture.backend.users = fixture.backend.users.map { JsonObject(it + ("uid" to JsonPrimitive(oldId))) }
        model.review(id); eventually { model.state.value.records.single().terminal }; assertEquals(1, fixture.backend.requests.count { it.write })
    }
    @Test fun `写前保存失败零写入而未登记系统版本仍按权限编辑`() = runBlocking {
        val model = model(); loaded(model); model.edit(model.state.value.accounts!!.single())
        preferences.commitSucceeds = false; model.save(model.state.value.editor!!.copy(description = "Updated")); eventually { model.state.value.failure != null && !model.state.value.busy }
        assertTrue(fixture.backend.requests.none { it.write })
        val unknown = NasDirectoryProtocolFixture(); unknown.knownEnvironment = false; val repo = unknown.repository(); val old = repo.directory.accounts().single()
        repo.directory.change(NasDirectoryChange(NasDirectoryKind.ACCOUNT, NasDirectoryAction.EDIT, old.name, "Updated", old.email.orEmpty(), account = old)) {}
        assertEquals(1, unknown.backend.requests.count { it.write })
    }
    @Test fun `不支持v1零请求且原会话失效关闭提交`() = runBlocking {
        val unsupported = NasDirectoryProtocolFixture(); unsupported.minVersion = 2
        try { unsupported.repository().directory.accounts(); fail() } catch (_: DsmFailure) { }
        assertTrue(unsupported.requests.isEmpty())
        val old = repository.directory.accounts().single(); fixture.ownerValid = false
        try { repository.directory.change(NasDirectoryChange(NasDirectoryKind.ACCOUNT, NasDirectoryAction.EDIT, old.name, "Updated", old.email.orEmpty(), account = old)) { fail() }; fail() } catch (_: DsmFailure) { }
        assertTrue(fixture.backend.requests.none { it.write })
    }
    @Test fun `连接已替换但旧表单回调到达不能写入新连接`() = runBlocking {
        val model = model(); loaded(model); model.edit(model.state.value.accounts!!.single())
        val original = model.state.value.editor!!
        repository = fixture.repository("replacement")
        model.save(original.copy(description = "Old form")); delay(50)
        assertNull(model.state.value.editor); assertTrue(fixture.backend.requests.none { it.write })
        loaded(model); model.edit(model.state.value.accounts!!.single()); model.leavePage(); assertNull(model.state.value.editor)
    }
    @Test fun `重建模型隔离旧表单迟到结果且损坏记录不开放入口`() = runBlocking {
        val model = model(); loaded(model); model.edit(model.state.value.accounts!!.single()); assertNotNull(model.state.value.editor)
        model.clear(); repository = fixture.repository("next"); loaded(model); assertNull(model.state.value.editor)
        preferences.edit().putString("directory:broken", "{broken").commit(); model.load(); eventually { model.state.value.failure != null && !model.state.value.loading }
        assertFalse(model.state.value.writable); model.edit(model.state.value.accounts!!.single()); assertNull(model.state.value.editor)
        assertTrue(fixture.backend.requests.none { it.write })
    }
}
