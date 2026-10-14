package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*

class SystemFileSettingsModelTest {
    private val fixture = SystemFileFixture()
    private val store = SystemDocumentStore(MemoryPreferences())
    private val profiles = SecureProfileStore(MemoryPreferences())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var repo: DsmRepository
    private lateinit var owner: WorkspaceOwner
    private lateinit var model: SystemFileSettingsModel
    private var connected = true
    private var selected: String? = null
    @Before fun prepare() {
        owner = profiles.commitConnection(profiles.connectionAttempt(fixture.profile.id), fixture.profile, fixture.session, null, false, persistSession = true)
        repo = fixture.repository(owner) { profiles.requireCurrentOwner(owner) }
        model = SystemFileSettingsModel(scope, store, profiles, { repo.takeIf { connected && runCatching { it.requireCurrentOwner() }.isSuccess } },
            { selected = it; true }, {})
    }
    @After fun close() { scope.cancel() }
    private suspend fun ready() { withTimeout(5_000) { while (model.state.value.busy || model.state.value.rows !is Loadable.Ready) delay(5) } }
    private suspend fun enabled() { model.show(); ready(); model.setEnabled(fixture.profile.id, true); ready() }
    @Test fun `初次打开没有系统暴露启用后原账号绑定且默认只读`() = runBlocking {
        model.show(); ready(); assertTrue(store.locations().isEmpty()); assertTrue(fixture.calls.isEmpty())
        model.setEnabled(fixture.profile.id, true); ready()
        val location = store.locations().single(); assertTrue(location.enabled); assertFalse(location.editing)
        assertEquals(owner, profiles.recordOwner(WorkspaceRecordKind.DOCUMENT_PROVIDER, location.id))
    }
    @Test fun `单独编辑授权取消零变化确认后启用关闭位置清除编辑权`() = runBlocking {
        enabled(); model.requestEditing(fixture.profile.id, true); assertNotNull(model.state.value.confirmEditing)
        model.dismissEditing(); model.allowEditing(); assertFalse(store.locations().single().editing)
        model.requestEditing(fixture.profile.id, true); model.allowEditing(); ready(); assertTrue(store.locations().single().editing)
        model.setEnabled(fixture.profile.id, false); ready(); assertFalse(store.locations().single().enabled); assertFalse(store.locations().single().editing)
        model.setEnabled(fixture.profile.id, true); ready(); assertFalse(store.locations().single().editing)
    }
    @Test fun `模块撤权不允许启用或接受旧编辑确认`() = runBlocking {
        model.show(); ready(); fixture.allowed = false; model.setEnabled(fixture.profile.id, true); ready()
        assertNotNull(model.state.value.failure); assertTrue(store.locations().isEmpty())
        fixture.allowed = true; model.setEnabled(fixture.profile.id, true); ready(); model.requestEditing(fixture.profile.id, true)
        fixture.allowed = false; model.allowEditing(); ready(); assertFalse(store.locations().single().editing)
    }
    @Test fun `未连接需用户登录且不能自动启用`() = runBlocking {
        connected = false; model.show(); ready(); model.setEnabled(fixture.profile.id, true)
        assertEquals(R.string.system_files_sign_in, model.state.value.notice); assertTrue(store.locations().isEmpty())
        model.signIn(fixture.profile.id); assertEquals(fixture.profile.id, selected); assertFalse(model.state.value.visible)
    }
    @Test fun `没有持久会话不能开启系统后台入口`() = runBlocking {
        owner = profiles.commitConnection(profiles.connectionAttempt(fixture.profile.id), fixture.profile, fixture.session, null, false, persistSession = false)
        repo = fixture.repository(owner) { profiles.requireCurrentOwner(owner) }
        enabled(); assertNotNull(model.state.value.failure); assertTrue(store.locations().isEmpty())
    }
    @Test fun `登录失效仍可关闭原入口但不能允许新编辑`() = runBlocking {
        enabled(); profiles.signOut(owner); model.connectionChanged(); ready()
        model.requestEditing(fixture.profile.id, true); model.allowEditing(); assertFalse(store.locations().single().editing)
        model.setEnabled(fixture.profile.id, false); ready(); assertFalse(store.locations().single().enabled)
    }
}
