package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class WorkspaceConnectionServiceTest {
    private val store = SecureProfileStore(MemoryPreferences())
    private val profile = NasProfile("connection-a", "NAS", "https://nas.example.invalid", "account-a")
    private val previousSession = DsmSession(profile.id, "synthetic-old", deviceId = "synthetic-device")
    private val requests = mutableListOf<Request>()
    private var beforeReply: (Request) -> Unit = {}
    private var authError: Int? = null
    private var offline = false
    private var localDenied = false
    private val api = DsmApiClient(OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request()
            synchronized(requests) { requests += request }
            beforeReply(request)
            if (localDenied) throw LocalNetworkPermissionException()
            if (offline) throw java.io.IOException("synthetic offline")
            val body = when (request.field("api")) {
                "SYNO.API.Info" -> success("""{"SYNO.Core.Desktop.Initdata":{"path":"entry.cgi","minVersion":1,"maxVersion":1},"SYNO.FileStation.List":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}""")
                "SYNO.API.Auth" -> authError?.let { """{"success":false,"error":{"code":$it}}""" }
                    ?: success("""{"sid":"synthetic-new","did":"synthetic-new-device"}""")
                "SYNO.Core.Desktop.Initdata" -> success("""{"AppPrivilege":{"SYNO.SDS.App.FileStation3.Instance":true}}""")
                "SYNO.FileStation.List" -> success("""{"shares":[],"total":0,"offset":0}""")
                else -> error("Unexpected synthetic request")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(body.toResponseBody("application/json".toMediaType())).build()
        }.build())
    private val connections = WorkspaceConnectionService(store, api, DsmConnectionResolver(api))
    private fun seed() = store.commitConnection(store.connectionAttempt(profile.id), profile, previousSession, "synthetic-password", true)
    private suspend fun connect(next: NasProfile = profile) =
        connections.connect(next, profile, "synthetic-password", "", true, true) {}

    @Test fun `同账号重新登录发送原设备标识`() = runBlocking {
        seed(); connect()
        assertEquals("synthetic-device", requests.single { it.field("api") == "SYNO.API.Auth" }.field("device_id"))
    }

    @Test fun `修改账号或目标绝不发送原设备标识`() = runBlocking {
        for (next in listOf(profile.copy(username = "account-b"), profile.copy(address = "https://other.example.invalid"), profile.copy(port = 5443))) {
            store.clearAll(); seed(); requests.clear()
            connect(next)
            assertNull(requests.single { it.field("api") == "SYNO.API.Auth" }.field("device_id"))
            assertEquals(next, store.profiles().single())
        }
    }

    @Test fun `验证码失败保留原账号会话且不安装新归属`() = runBlocking {
        val owner = seed(); authError = 403
        val failure = runCatching { connect(profile.copy(username = "account-b")) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.OTP_REQUIRED, failure.kind)
        assertEquals(owner, store.currentOwner(profile.id)); assertEquals(previousSession, store.session(profile.id))
        assertEquals(2, requests.size)
    }

    @Test fun `恢复网络失败保留会话和密码`() = runBlocking {
        val owner = seed(); offline = true
        val failure = runCatching { connections.restore(profile, previousSession) {} }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.CONNECTION_FAILED, failure.kind)
        assertEquals(previousSession, store.session(profile.id)); assertEquals(owner, store.currentOwner(profile.id))
        assertNotNull(store.password(profile.id))
    }

    @Test fun `恢复局域网拒绝保留会话且不重发登录`() = runBlocking {
        val owner = seed(); localDenied = true
        var prompts = 0
        val service = WorkspaceConnectionService(store, api, DsmConnectionResolver(api)) { prompts++; false }
        val failure = runCatching { service.restore(profile, previousSession) {} }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED, failure.kind)
        assertEquals(1, prompts); assertEquals(1, requests.size)
        assertEquals(previousSession, store.session(profile.id)); assertEquals(owner, store.currentOwner(profile.id))
        assertNotNull(store.password(profile.id)); assertTrue(store.isAutoLoginEnabled(profile.id))
    }

    @Test fun `授权后只重试只读发现且只登录一次`() = runBlocking {
        seed(); localDenied = true
        var prompts = 0
        val service = WorkspaceConnectionService(store, api, DsmConnectionResolver(api)) { prompts++; localDenied = false; true }
        service.connect(profile, profile, "synthetic-password", "", true, true) {}
        assertEquals(1, prompts)
        assertEquals(2, requests.count { it.field("api") == "SYNO.API.Info" })
        assertEquals(1, requests.count { it.field("api") == "SYNO.API.Auth" })
    }

    @Test fun `认证等待期间另一连接更新后旧结果不能覆盖`() = runBlocking {
        seed()
        val next = profile.copy(username = "account-b")
        beforeReply = { request -> if (request.field("api") == "SYNO.API.Auth") {
            store.commitConnection(store.connectionAttempt(profile.id), next, previousSession.copy(sid = "synthetic-b"), "synthetic-b", true)
        } }
        val failure = runCatching { connect() }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED, failure.kind)
        assertEquals(next, store.profiles().single())
    }

    @Test fun `旧Repository权限与业务请求都在联网前停止`() = runBlocking {
        seed()
        val repo = connect()
        repo.listShares()
        val count = requests.size
        store.clearSession(profile.id)
        val failure = runCatching { repo.listShares() }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED, failure.kind)
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED, (runCatching { repo.refreshAccess() }.exceptionOrNull() as DsmFailure).kind)
        assertEquals(count, requests.size)
        assertFalse(repo.availability().single { it.module == Module.FILES }.isAvailable)
    }

    private fun success(data: String) = """{"success":true,"data":$data}"""
    private fun Request.field(name: String): String? = url.queryParameter(name) ?: (body as? FormBody)?.let { form ->
        (0 until form.size).firstOrNull { form.name(it) == name }?.let(form::value)
    }
}
