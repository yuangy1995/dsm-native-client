package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class WorkspaceAccessFeatureModelTest {
    @Test fun `重复手动刷新合并撤销立即清内容并只重载最新允许的页面`() = runTest {
        val fixture = Fixture(backgroundScope)
        fixture.connect()
        val release = CompletableDeferred<Unit>()
        fixture.read = { release.await(); false }
        fixture.model.refresh(Module.FILES)
        runCurrent()
        fixture.model.refresh(Module.SETTINGS)
        assertTrue(fixture.state.value!!.access.refreshing)
        release.complete(Unit)
        runCurrent()
        assertEquals(2, fixture.reads)
        assertEquals(setOf(Module.FILES), fixture.revoked)
        assertEquals(Loadable.Idle, fixture.state.value!!.files)
        assertEquals(listOf(Module.SETTINGS), fixture.reloaded)
        assertFalse(fixture.state.value!!.access.refreshing)
    }

    @Test fun `返回前台读取权限而首次显示与重复通知不多读`() = runTest {
        val fixture = Fixture(backgroundScope)
        fixture.connect()
        fixture.model.setForeground(true)
        fixture.model.setForeground(true)
        runCurrent()
        assertEquals(1, fixture.reads)
        fixture.model.setForeground(false)
        fixture.model.setForeground(true)
        runCurrent()
        assertEquals(2, fixture.reads)
        assertEquals(1, fixture.backgrounds)
        assertEquals(listOf(Module.FILES), fixture.reloaded)
    }

    @Test fun `读取权限途中退到后台不重新启动页面订阅`() = runTest {
        val fixture = Fixture(backgroundScope)
        fixture.connect()
        fixture.model.setForeground(true)
        val release = CompletableDeferred<Unit>()
        fixture.read = { release.await(); true }
        fixture.model.refresh(Module.FILES); runCurrent()
        fixture.model.setForeground(false)
        release.complete(Unit); runCurrent()
        assertTrue(fixture.reloaded.isEmpty())
        assertFalse(fixture.state.value!!.access.refreshing)
    }

    @Test fun `切换仓储后迟到结果不能改变新工作区`() = runTest {
        val fixture = Fixture(backgroundScope)
        fixture.connect()
        val release = CompletableDeferred<Unit>()
        fixture.read = { release.await(); false }
        fixture.model.refresh(Module.FILES)
        runCurrent()
        val second = Fixture(backgroundScope)
        second.connect()
        fixture.owner = second.owner
        fixture.state.value = second.state.value!!.copy(message = "synthetic-new")
        release.complete(Unit)
        runCurrent()
        assertEquals("synthetic-new", fixture.state.value?.message)
        assertTrue(fixture.state.value!!.availability.allows(Module.FILES))
        assertTrue(fixture.revoked.isEmpty())
        assertTrue(fixture.reloaded.isEmpty())
    }

    @Test fun `会话过期显示重新登录但不关闭本机任务入口`() = runTest {
        val fixture = Fixture(backgroundScope)
        fixture.connect()
        fixture.read = { throw DsmFailure(119, "Synthetic", "Synthetic", true, DsmErrorKind.SESSION_EXPIRED) }
        fixture.model.refresh(Module.FILES)
        runCurrent()
        val state = fixture.state.value!!
        assertEquals(DsmErrorKind.SESSION_EXPIRED, state.access.failure?.kind)
        assertEquals(ModuleAccessState.AUTHENTICATION_REQUIRED, state.availability.first { it.module == Module.FILES }.access)
        assertTrue(state.availability.allows(Module.TRANSFERS))
        assertEquals(Loadable.Idle, state.files)
        assertTrue(fixture.reloaded.isEmpty())
    }

    @Test fun `权限恢复允许重新加载但不显示先前内容`() = runTest {
        val fixture = Fixture(backgroundScope)
        fixture.connect()
        fixture.read = { false }
        fixture.model.refresh(Module.FILES); runCurrent()
        fixture.read = { true }
        fixture.model.refresh(Module.FILES); runCurrent()
        assertTrue(fixture.state.value!!.availability.allows(Module.FILES))
        assertEquals(Loadable.Idle, fixture.state.value?.files)
        assertEquals(listOf(Module.FILES), fixture.reloaded)
    }

    @Test fun `对象拒绝刷新摘要但不撤销模块也不重试原请求`() = runTest {
        val fixture = Fixture(backgroundScope)
        fixture.connect()
        fixture.model.reset()
        val failure = runCatching { fixture.owner!!.listShares() }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.PERMISSION_DENIED, failure.kind)
        runCurrent()
        assertEquals(2, fixture.reads)
        assertEquals(1, fixture.requests)
        assertTrue(fixture.state.value!!.availability.allows(Module.FILES))
        assertTrue(fixture.revoked.isEmpty())
        assertTrue(fixture.reloaded.isEmpty())
    }

    @Test fun `其他工作区改账号后立即停止原订阅并清除缓存而不联网刷新`() = runTest {
        val fixture = Fixture(backgroundScope)
        fixture.connect()
        val store = io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore(
            io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences())
        val profile = fixture.profile
        val owner = store.commitConnection(store.connectionAttempt(profile.id), profile,
            DsmSession(profile.id, "synthetic"), null, false)
        fixture.owner!!.bindOwner(owner) { store.requireCurrentOwner(owner) }
        fixture.model.reset(); runCurrent()
        store.clearSession(profile.id); runCurrent()
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED, fixture.state.value?.access?.failure?.kind)
        assertEquals(Loadable.Idle, fixture.state.value?.files)
        assertTrue(Module.FILES in fixture.revoked && Module.CHAT in fixture.revoked)
        assertTrue(fixture.reloaded.isEmpty())
        assertEquals(1, fixture.reads); assertEquals(0, fixture.requests)
    }

    private class Fixture(scope: CoroutineScope) {
        var reads = 0
        var requests = 0
        var backgrounds = 0
        var read: suspend () -> Boolean = { true }
        var owner: DsmRepository? = null
        val revoked = mutableSetOf<Module>()
        val reloaded = mutableListOf<Module>()
        val profile = NasProfile("synthetic", "Synthetic", "https://nas.example.invalid", "synthetic")
        val state = WorkspaceStateStore(availability = { owner?.availability() })
        val model = WorkspaceAccessFeatureModel(scope, state, { owner }, { modules, _ -> revoked.addAll(modules) }, { reloaded.add(it) }, { backgrounds++ })
        suspend fun connect() {
            val capabilities = listOf(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2)).associateBy { it.name }
            val reader = WorkspaceAccessReader(capabilities,
                readPrivileges = { reads++; DesktopAppPrivileges(mapOf(DesktopApplication.FILES to read()), false) },
                readFileSession = { error("不应使用文件兜底") }, readPhotoAccess = { error("不应使用照片兜底") })
            val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
                .addInterceptor { chain ->
                    requests++
                    Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                        .body("""{"success":false,"error":{"code":105}}""".toResponseBody("application/json".toMediaType())).build()
                }.build()
            owner = DsmRepository(profile, DsmSession(profile.id, "synthetic"), DsmApiClient(http), capabilities, reader)
            owner!!.refreshAccess()
            state.value = WorkspaceState(profile, availability = owner!!.availability(), files = Loadable.Ready(FilePage(emptyList(), 0, 0)))
        }
    }
}
