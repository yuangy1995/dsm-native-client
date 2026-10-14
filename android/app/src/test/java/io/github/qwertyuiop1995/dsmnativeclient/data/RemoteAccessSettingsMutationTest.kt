package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasServiceProtocolFixture
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasServiceSettingsFixture
import kotlinx.coroutines.launch
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRemoteAccessSettings
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteAccessSettingsMutationTest {
    @Test
    fun `读取使用实际接口版本严格布尔和管理权限不读取固件`() = runBlocking {
        val transport = RemoteAccessInterceptor(
            ok(relay(true)), ok(router(false)), ok(recordedSystem()),
        )

        val settings = repository(transport, quickConnectMax = 5, upnpMax = 5)
            .remoteAccessSettings()

        assertEquals(NasRemoteAccessSettings(true, false, false, true), settings)
        assertEquals(listOf("3", "1"), transport.versions())
    }

    @Test
    fun `字符串数字对象数组和缺失值都不是可信布尔`() = runBlocking {
        val malformedValues = listOf("\"true\"", "1", "{}", "[]", null)
        malformedValues.forEach { value ->
            val relayData = value?.let { """{"relay_enabled":$it}""" } ?: "{}"
            val routerData = value?.let { """{"enabled":$it}""" } ?: "{}"
            val transport = RemoteAccessInterceptor(ok(relayData), ok(routerData))
            var failure: Throwable? = null
            try {
                repository(transport).remoteAccessSettings()
            } catch (error: Throwable) {
                failure = error
            }
            assertTrue("非布尔值 $value 不应被接受", failure != null)
            assertEquals(2, transport.requests.size)
        }
    }

    @Test
    fun `单项读取失败保留另一项且不伪装关闭`() = runBlocking {
        val transport = RemoteAccessInterceptor(
            fail(IOException("synthetic relay failure")), ok(router(true)), ok(recordedSystem()),
        )

        val settings = repository(transport).remoteAccessSettings()

        assertNull(settings.isRelayEnabled)
        assertEquals(true, settings.isRouterConfigurationEnabled)
        assertTrue(settings.canManage)
    }

    @Test
    fun `非记录环境仍允许实际授权的远程设置写入`() = runBlocking {
        val fixture = NasServiceProtocolFixture().also { it.knownEnvironment = false }
        val repo = fixture.repository()
        val original = repo.remoteAccessSettings()
        assertTrue(original.canManage)
        repo.saveRemote(original, original.copy(isRouterConfigurationEnabled = true))
        assertEquals(1, fixture.backend.writes.size)
    }

    @Test
    fun `可信中继连接禁止关闭中继且直连域不被误判`() = runBlocking {
        val blocked = NasServiceProtocolFixture()
        assertRejected(DsmErrorKind.NAS_RELAY_PROTECTED) {
            blocked.repository(address = "https://synthetic.r1.quickconnect.to").saveRemote(settings(trustedRelay = true), settings(relay = false, trustedRelay = true))
        }
        assertTrue(blocked.requests.isEmpty())
        val direct = NasServiceProtocolFixture()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS,
            direct.repository(address = "https://synthetic.direct.quickconnect.to").saveRemote(settings(), settings(relay = false)).status)
    }

    @Test
    fun `无变化基线漂移和能力缺口均零写入`() = runBlocking {
        val noChange = NasServiceProtocolFixture()
        assertRejected(DsmErrorKind.NAS_SERVICE_CHANGED) { noChange.repository().saveRemote(settings(), settings()) }
        assertTrue(noChange.requests.isEmpty())
        val drift = NasServiceProtocolFixture().also { it.backend.rows[NasServiceStep.RELAY] = NasServiceSettingsFixture.row(relay(false)) }
        assertEquals(MutationErrorCategory.CONFLICT, drift.repository().saveRemote(settings(), settings(router = true)).errorCategory)
        assertTrue(drift.backend.writes.isEmpty())
        val missing = NasServiceProtocolFixture().also { it.backend.versions[NasServiceStep.ROUTER] = 2..2 }
        assertRejected(DsmErrorKind.FEATURE_UNSUPPORTED) { missing.repository().saveRemote(settings(), settings(relay = false, router = true)) }
        assertTrue(missing.requests.isEmpty())
    }

    @Test
    fun `两项写入按固定顺序逐项回读并最终完整确认`() = runBlocking {
        val fixture = NasServiceProtocolFixture().also { it.requestFormat = "FORM" }
        val result = fixture.repository().saveRemote(settings(), settings(relay = false, router = true))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(2, result.counts.succeeded)
        assertEquals(listOf(NasServiceStep.RELAY, NasServiceStep.ROUTER), fixture.backend.writes.map { it.step })
        assertEquals(listOf(3, 1), fixture.backend.writes.map { it.version })
        assertEquals(listOf("set_misc_config", "set"), fixture.backend.writes.map { it.method })
        assertEquals(listOf("false", "true"), fixture.requests.filter { it.body?.isOneShot() == true }.map {
            it.remoteAccessFields().let { fields -> fields["relay_enabled"] ?: fields["enabled"] }
        })
        assertEquals(listOf("get_misc_config", "get", "set_misc_config", "get_misc_config", "get",
            "get_misc_config", "get", "set", "get_misc_config", "get", "get_misc_config", "get"), fixture.backend.requests.map { it.method })
    }

    @Test
    fun `第二步权限失败报告部分成功且不重放`() = runBlocking {
        val fixture = NasServiceProtocolFixture()
        fixture.backend.before = { if (it.write && it.step == NasServiceStep.ROUTER) fixture.writeRejectionCode = 105 }
        fixture.backend.afterWrite = { if (it.step == NasServiceStep.ROUTER) fixture.backend.rows[it.step] = NasServiceSettingsFixture.row(router(false)) }
        val result = fixture.repository().saveRemote(settings(), settings(relay = false, router = true))
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded); assertEquals(1, result.counts.failed)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertEquals(listOf(NasServiceStep.RELAY, NasServiceStep.ROUTER), fixture.backend.writes.map { it.step })
    }

    @Test
    fun `提交断线后只回读确认不重放`() = runBlocking {
        val fixture = NasServiceProtocolFixture()
        fixture.backend.afterWrite = { throw IOException("synthetic disconnect") }
        val result = fixture.repository().saveRemote(settings(), settings(relay = false))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, fixture.backend.writes.size)
    }

    @Test
    fun `回读单字段失败必须要求刷新而不是确认成功`() = runBlocking {
        val fixture = NasServiceProtocolFixture()
        fixture.backend.before = { if (!it.write && it.step == NasServiceStep.RELAY && fixture.backend.writes.isNotEmpty()) throw IOException("synthetic readback failure") }
        val result = fixture.repository().saveRemote(settings(), settings(relay = false))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh); assertEquals(1, result.counts.unknown)
    }

    @Test
    fun `预检取消零写入并释放互斥锁供重试`() = runBlocking {
        val fixture = NasServiceProtocolFixture(); val repo = fixture.repository()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.backend.before = { if (it.step == NasServiceStep.RELAY && !it.write) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        var cancelled: MutationResult? = null
        val job = launch(Dispatchers.Default) { cancelled = repo.saveRemote(settings(), settings(relay = false)) }
        assertTrue(entered.await(5, TimeUnit.SECONDS)); job.cancel(); release.countDown(); job.join()
        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, cancelled?.status)
        assertTrue(fixture.backend.writes.isEmpty())
        fixture.backend.before = {}
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.saveRemote(settings(), settings(relay = false)).status)
        assertEquals(1, fixture.backend.writes.size)
    }

    @Test
    fun `提交阶段取消后停止回读且独立读取不重发设置`() = runBlocking {
        val fixture = NasServiceProtocolFixture(); val repo = fixture.repository()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.backend.before = { if (it.write) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        var cancelled: MutationResult? = null
        val job = launch(Dispatchers.Default) { cancelled = repo.saveRemote(settings(), settings(relay = false)) }
        assertTrue(entered.await(5, TimeUnit.SECONDS)); job.cancel(); release.countDown(); job.join()
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, cancelled?.status)
        assertTrue(cancelled?.submitted == true); assertTrue(cancelled?.requiresRefresh == true)
        assertTrue(fixture.backend.requests.last().write)
        fixture.backend.before = {}; repo.remoteAccessSettings()
        assertEquals(1, fixture.backend.writes.size)
    }

    @Test
    fun `并发保存由全局互斥拒绝重复写入`() = runBlocking {
        val transport = BlockingRemoteAccessInterceptor(); val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.saveRemote(settings(), settings(relay = false)) }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))
        assertRejected(DsmErrorKind.NAS_SERVICE_CHANGED) { repo.saveRemote(settings(), settings(router = true)) }
        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.methods().count { it == "set_misc_config" })
    }

    private suspend fun DsmRepository.saveRemote(original: NasRemoteAccessSettings, desired: NasRemoteAccessSettings): MutationResult =
        nasServices.save(nasServices.plan(NasServiceValue.RemoteAccess(original), NasServiceValue.RemoteAccess(desired))) { }
    private suspend fun assertRejected(kind: DsmErrorKind, action: suspend () -> Unit) {
        val failure = try { action(); error("Expected rejection") } catch (error: DsmFailure) { error }
        assertEquals(kind, failure.kind)
    }

    private fun repository(
        interceptor: Interceptor,
        quickConnectMax: Int = 5,
        upnpMax: Int = 5,
        includeUpnp: Boolean = true,
        address: String = "https://nas.example.invalid",
    ): DsmRepository {
        val capabilities = mutableMapOf(
            "SYNO.Core.QuickConnect" to ApiCapability(
                "SYNO.Core.QuickConnect", "entry.cgi", 1, quickConnectMax,
            ),
            "SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 3),
        )
        if (includeUpnp) capabilities["SYNO.Core.QuickConnect.Upnp"] = ApiCapability(
            "SYNO.Core.QuickConnect.Upnp", "entry.cgi", 1, upnpMax,
        )
        return authorizedRepository(
            NasProfile("test", "Test", address, "operator"),
            DsmSession("test", "test-session", "test-token"),
            DsmApiClient(
                OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build(),
            ),
            capabilities,
        )
    }

    private fun settings(
        relay: Boolean = true,
        router: Boolean = false,
        trustedRelay: Boolean = false,
    ) = NasRemoteAccessSettings(relay, router, trustedRelay, true)

    private fun relay(enabled: Boolean) = """{"relay_enabled":$enabled}"""
    private fun router(enabled: Boolean) = """{"enabled":$enabled}"""
    private fun recordedSystem(update: Int = 12) =
        """{"firmware_ver":"DSM 7.2.1-69057 Update $update","buildnumber":"69057","smallfixnumber":"$update"}"""
    private fun ok(data: String = "{}") = RemoteAccessStep.Body("""{"success":true,"data":$data}""")
    private fun fail(error: IOException) = RemoteAccessStep.Failure(error)
}

private sealed interface RemoteAccessStep {
    data class Body(val value: String) : RemoteAccessStep
    data class Failure(val error: IOException) : RemoteAccessStep
}

private class RemoteAccessInterceptor(vararg steps: RemoteAccessStep) : Interceptor {
    private val queue = ArrayDeque(steps.toList())
    val requests = CopyOnWriteArrayList<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return when (val step = queue.removeFirstOrNull() ?: error("未预期的请求：${request.url}")) {
            is RemoteAccessStep.Failure -> throw step.error
            is RemoteAccessStep.Body -> response(
                request,
                step.value.toResponseBody("application/json".toMediaType()),
            )
        }
    }

    fun fields(): List<Map<String, String>> = requests.map(Request::remoteAccessFields)
    fun methods(): List<String> = fields().map { it["method"].orEmpty() }
    fun versions(): List<String> = fields().map { it["version"].orEmpty() }
}

private class BlockingRemoteAccessInterceptor : Interceptor {
    val submissionStarted = CountDownLatch(1)
    val allowSubmission = CountDownLatch(1)
    private val requests = CopyOnWriteArrayList<Request>()
    private var relayEnabled = true

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val fields = request.remoteAccessFields()
        val data = when (fields["api"] to fields["method"]) {
            "SYNO.Core.QuickConnect" to "get_misc_config" -> """{"relay_enabled":$relayEnabled}"""
            "SYNO.Core.QuickConnect.Upnp" to "get" -> """{"enabled":false}"""
            "SYNO.Core.System" to "info" ->
                """{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":"69057","smallfixnumber":"12"}"""
            "SYNO.Core.QuickConnect" to "set_misc_config" -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待远程访问合成写请求放行超时" }
                relayEnabled = false
                "{}"
            }
            else -> error("未预期的请求：$fields")
        }
        return response(
            request,
            """{"success":true,"data":$data}""".toResponseBody("application/json".toMediaType()),
        )
    }

    fun methods() = requests.map { it.remoteAccessFields()["method"].orEmpty() }
}

private fun Request.remoteAccessFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return buildMap { repeat(form.size) { put(form.name(it), form.value(it)) } }
}

private fun response(request: Request, body: ResponseBody): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body)
    .build()
