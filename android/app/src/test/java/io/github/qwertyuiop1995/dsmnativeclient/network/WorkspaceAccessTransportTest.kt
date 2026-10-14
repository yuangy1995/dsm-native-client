package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.isExpiredWorkspaceSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class WorkspaceAccessTransportTest {
    @Test fun `摘要固定GET版本一和null字符串且凭据只在请求头`() = runBlocking {
        val transport = Transport { success("""{"AppPrivilege":{},"Session":{"isLogined":true}}""") }
        val repo = repository(transport)
        repo.refreshAccess(requireSessionConfirmation = true)
        val request = transport.requests.single()
        assertEquals("GET", request.method)
        assertEquals("/webapi/entry.cgi", request.url.encodedPath)
        assertEquals(setOf("api", "version", "method", "launch_app"), request.url.queryParameterNames)
        assertEquals("SYNO.Core.Desktop.Initdata", request.url.queryParameter("api"))
        assertEquals("1", request.url.queryParameter("version"))
        assertEquals("get_user_service", request.url.queryParameter("method"))
        assertEquals("null", request.url.queryParameter("launch_app"))
        assertEquals("id=synthetic-session", request.header("Cookie"))
        assertEquals("synthetic-token", request.header("X-SYNO-TOKEN"))
        assertNull(request.body)
        assertFalse(request.url.toString().contains("synthetic-session"))
        assertFalse(request.url.toString().contains("synthetic-token"))
        assertFalse(repo.availability().single { it.module == Module.FILES }.isAvailable)
    }

    @Test fun `摘要失效但文件会话有效时以最小文件读取恢复`() = runBlocking {
        val transport = Transport { request ->
            if (request.method == "GET") success("""{"AppPrivilege":{},"Session":{"isLogined":false}}""")
            else success("""{"shares":[],"total":0,"offset":0}""")
        }
        val repo = repository(transport)
        repo.refreshAccess(requireSessionConfirmation = true)
        assertEquals(2, transport.requests.size)
        val form = transport.requests.last().body as FormBody
        fun field(key: String) = (0 until form.size).firstOrNull { form.name(it) == key }?.let(form::value)
        assertEquals("SYNO.FileStation.List", field("api"))
        assertEquals("list_share", field("method"))
        assertEquals("0", field("offset"))
        assertEquals("1", field("limit"))
        assertTrue(repo.moduleAccessReadFailed)
        assertTrue(repo.availability().single { it.module == Module.FILES }.isAvailable)
        assertFalse(repo.availability().single { it.module == Module.DOWNLOADS }.isAvailable)
    }

    @Test fun `缺少摘要能力不猜路径但仍可确认文件会话`() = runBlocking {
        val transport = Transport { success("""{"shares":[],"total":0,"offset":0}""") }
        val repo = repository(transport, summary = false)
        repo.refreshAccess(requireSessionConfirmation = true)
        assertEquals(1, transport.requests.size)
        assertEquals("POST", transport.requests.single().method)
    }

    @Test fun `刷新整体替换不保留已撤销授权`() = runBlocking {
        var allowed = true
        val transport = Transport { success("""{"AppPrivilege":{"SYNO.SDS.App.FileStation3.Instance":$allowed}}""") }
        val repo = repository(transport)
        repo.refreshAccess()
        assertTrue(repo.availability().single { it.module == Module.FILES }.isAvailable)
        allowed = false
        repo.refreshAccess()
        assertFalse(repo.availability().single { it.module == Module.FILES }.isAvailable)
        assertEquals(ModuleAccessState.DENIED, repo.availability().single { it.module == Module.FILES }.access)
    }

    @Test fun `网络失败保留连接错误不变成过期`() = runBlocking {
        val transport = Transport { throw IOException("synthetic offline") }
        val repo = repository(transport)
        val error = runCatching { repo.refreshAccess(requireSessionConfirmation = true) }.exceptionOrNull()
        assertEquals(DsmErrorKind.CONNECTION_FAILED, (error as DsmFailure).kind)
        assertFalse(isExpiredWorkspaceSession(error!!))
        assertEquals(2, transport.requests.size)
    }

    @Test fun `证书失败不追加文件或照片请求`() = runBlocking {
        val transport = Transport { throw javax.net.ssl.SSLHandshakeException("synthetic certificate") }
        val error = runCatching { repository(transport).refreshAccess(true) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.TLS_UNTRUSTED, error.kind)
        assertFalse(isExpiredWorkspaceSession(error))
        assertEquals(1, transport.requests.size)
    }

    @Test fun `局域网权限拒绝不追加文件或照片请求`() = runBlocking {
        val transport = Transport { throw LocalNetworkPermissionException() }
        val error = runCatching { repository(transport).refreshAccess(true) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED, error.kind)
        assertFalse(isExpiredWorkspaceSession(error))
        assertEquals(1, transport.requests.size)
    }

    @Test fun `认证错误立即停止且清除旧入口授权`() = runBlocking {
        var expired = false
        val transport = Transport {
            if (expired) """{"success":false,"error":{"code":119}}"""
            else success("""{"AppPrivilege":{"SYNO.SDS.App.FileStation3.Instance":true}}""")
        }
        val repo = repository(transport)
        repo.refreshAccess()
        expired = true
        val error = runCatching { repo.refreshAccess(requireSessionConfirmation = true) }.exceptionOrNull()!!
        assertTrue(isExpiredWorkspaceSession(error))
        assertEquals(2, transport.requests.size)
        assertFalse(repo.availability().single { it.module == Module.FILES }.isAvailable)
    }

    @Test fun `一般HTTP403不要求重新登录而401会话过期`() = runBlocking {
        for (status in listOf(401, 403)) {
            val transport = Transport(status) { "{}" }
            val repo = repository(transport)
            val error = runCatching { repo.refreshAccess(requireSessionConfirmation = true) }.exceptionOrNull() as DsmFailure
            assertEquals(if (status == 401) DsmErrorKind.SESSION_EXPIRED else DsmErrorKind.PERMISSION_DENIED, error.kind)
            assertEquals(status == 401, isExpiredWorkspaceSession(error))
            assertEquals(if (status == 401) 1 else 2, transport.requests.size)
        }
    }

    @Test fun `通用会话与能力错误严格按已记录的上下文分类`() {
        for (code in listOf(106, 107, 119)) {
            assertTrue(isExpiredWorkspaceSession(dsmApiFailure(code)))
            assertTrue(dsmApiFailure(code).isAuthenticationFailure)
        }
        for (code in listOf(102, 103, 104, 105, 400, 401, 402, 403, 404, 406, 407)) {
            assertFalse(isExpiredWorkspaceSession(dsmApiFailure(code)))
            assertFalse(dsmApiFailure(code).isAuthenticationFailure)
        }
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, dsmApiFailure(104).kind)
        assertEquals(DsmErrorKind.OTP_REQUIRED, dsmApiFailure(403, authenticationRequest = true).kind)
        assertEquals(DsmErrorKind.AUTHENTICATION_FAILED, dsmApiFailure(400, authenticationRequest = true).kind)
    }

    @Test fun `未读取权限不能发出文件业务请求`() = runBlocking {
        val transport = Transport { error("未读取权限不能请求业务接口") }
        val error = runCatching { repository(transport).listShares() }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.REQUEST_FAILED, error.kind)
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun `授权后可请求撤销后无第二次业务请求`() = runBlocking {
        var allowed = true
        val transport = Transport { request ->
            if (request.method == "GET") success("""{"AppPrivilege":{"SYNO.SDS.App.FileStation3.Instance":$allowed}}""")
            else success("""{"shares":[],"total":0,"offset":0}""")
        }
        val repo = repository(transport)
        repo.refreshAccess()
        repo.listShares()
        allowed = false
        repo.refreshAccess()
        val error = runCatching { repo.listShares() }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.PERMISSION_DENIED, error.kind)
        assertEquals(1, transport.requests.count { it.method == "POST" })
    }

    @Test fun `关闭工作区后旧Repository不能复用已授权会话`() = runBlocking {
        val transport = Transport { success("""{"AppPrivilege":{"SYNO.SDS.App.FileStation3.Instance":true}}""") }
        val repo = repository(transport)
        repo.refreshAccess()
        repo.invalidateAccess()
        assertTrue(runCatching { repo.listShares() }.exceptionOrNull() is DsmFailure)
        assertTrue(runCatching { repo.refreshAccess() }.exceptionOrNull() is kotlinx.coroutines.CancellationException)
        assertEquals(1, transport.requests.size)
    }

    private fun repository(transport: Transport, summary: Boolean = true): DsmRepository {
        val profile = NasProfile("synthetic-profile", "Synthetic", "https://nas.example.invalid", "synthetic-user")
        val api = DsmApiClient(OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false).addInterceptor(transport).build())
        val capabilities = buildList {
            add(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2))
            if (summary) add(ApiCapability("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 3))
        }.associateBy { it.name }
        return DsmRepository(profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), api, capabilities)
    }
    private fun success(data: String) = """{"success":true,"data":$data}"""
    private class Transport(private val status: Int = 200, private val response: (Request) -> String) : Interceptor {
        val requests = mutableListOf<Request>()
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            requests += request
            return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("synthetic")
                .body(response(request).toResponseBody("application/json".toMediaType())).build()
        }
    }
}
