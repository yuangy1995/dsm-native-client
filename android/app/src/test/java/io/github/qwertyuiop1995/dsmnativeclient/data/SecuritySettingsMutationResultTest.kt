package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDoSProtectionSetting
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecuritySettingsMutationResultTest {
    @Test
    fun `正式保存携带完整基线并在整体回读后确认`() = runBlocking {
        val transport = SecurityQueueInterceptor(AUTO_OFF, SUCCESS, AUTO_ON, AUTO_ON)
        val original = security(false)
        val desired = security(true)

        val result = repository(transport, AUTO_BLOCK to 1)
            .saveSecurity(original, desired)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(listOf("get", "set", "get", "get"), transport.methods())
    }

    @Test
    fun `完整基线漂移时零写入并报告冲突`() = runBlocking {
        val transport = SecurityQueueInterceptor(AUTO_CHANGED)

        val result = repository(transport, AUTO_BLOCK to 1).saveSecurity(
            security(false), security(true),
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(listOf("get"), transport.methods())
    }

    @Test
    fun `DoS 缺少固定 Ethernet v2 时能力门禁零请求`() = runBlocking {
        val transport = SecurityQueueInterceptor()
        val original = security(false).copy(
            dosProtection = listOf(NasDoSProtectionSetting("eth-synthetic", "LAN", false)),
        )
        val desired = original.copy(
            dosProtection = listOf(NasDoSProtectionSetting("eth-synthetic", "LAN", true)),
        )

        rejected(DsmErrorKind.FEATURE_UNSUPPORTED) {
            repository(transport, AUTO_BLOCK to 1, ETHERNET to 1, DOS to 2).saveSecurity(original, desired)
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `已支持自动封锁响应缺字段时拒绝为畸形而非不支持`() = runBlocking {
        val transport = SecurityQueueInterceptor(AUTO_MISSING_EXPIRATION)

        val error = runCatching {
            repository(transport, AUTO_BLOCK to 1).activeSecuritySettings()
        }.exceptionOrNull()

        assertTrue("缺少必需字段时应拒绝响应", error != null)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `DoS 读取和写入固定使用 v2 且不重放`() = runBlocking {
        val transport = SecurityQueueInterceptor(
            AUTO_OFF, ETHERNET_ROW, DOS_OFF, SUCCESS,
            AUTO_OFF, ETHERNET_ROW, DOS_ON, AUTO_OFF, ETHERNET_ROW, DOS_ON,
        )
        val original = security(false).copy(
            dosProtection = listOf(NasDoSProtectionSetting("eth-synthetic", "LAN", false)),
        )
        val desired = original.copy(
            dosProtection = listOf(NasDoSProtectionSetting("eth-synthetic", "LAN", true)),
        )

        val result = repository(
            transport, AUTO_BLOCK to 1, ETHERNET to 2, DOS to 2,
        ).saveSecurity(original, desired)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf("1", "2", "2", "2", "1", "2", "2", "1", "2", "2"), transport.versions())
        assertEquals(1, transport.methods().count { it == "set" })
    }

    @Test
    fun `正式入口多步骤预检失败报告完整计数`() = runBlocking {
        val transport = SecurityQueueInterceptor(AUTO_MISSING_EXPIRATION)
        val original = security(false).copy(isPortScanProtectionEnabled = false)
        val desired = security(true).copy(isPortScanProtectionEnabled = true)

        val result = repository(
            transport, AUTO_BLOCK to 1, FIREWALL_CONF to 1,
        ).saveSecurity(original, desired)

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(2, result.counts.failed)
        assertFalse(result.submitted)
        assertEquals(listOf("get"), transport.methods())
    }

    @Test
    fun `正式入口第二组取消保留第一组成功且停止后续读取`() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val transport = SecurityCancellationInterceptor(entered, release)
        val original = security(false).copy(isPortScanProtectionEnabled = false)
        val desired = security(true).copy(isPortScanProtectionEnabled = true)
        var result: MutationResult? = null

        val job = launch(Dispatchers.Default) {
            result = repository(
                transport, AUTO_BLOCK to 1, FIREWALL_CONF to 1,
            ).saveSecurity(original, desired)
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        job.cancel()
        release.countDown()
        job.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, result?.status)
        assertEquals(1, result?.counts?.succeeded)
        assertEquals(1, result?.counts?.unknown)
        assertTrue(result?.errorCategory != MutationErrorCategory.CONFLICT)
        assertEquals(2, transport.methods().count { it == "set" })
        assertEquals(listOf("get", "get", "set", "get", "get", "get", "get", "set"), transport.methods())
    }

    private suspend fun DsmRepository.saveSecurity(original: NasSecuritySettings, desired: NasSecuritySettings): MutationResult =
        nasServices.save(nasServices.plan(NasServiceValue.Security(original), NasServiceValue.Security(desired))) { }
    private suspend fun rejected(kind: DsmErrorKind, action: suspend () -> Unit) {
        val error = try { action(); error("Expected rejection") } catch (failure: DsmFailure) { failure }; assertEquals(kind, error.kind)
    }

    private fun security(enabled: Boolean) = NasSecuritySettings(
        enabled, if (enabled) 5 else 10, if (enabled) 10 else 5,
        if (enabled) 7 else null, emptyList(), null, null, null,
    )

    private fun repository(
        interceptor: Interceptor,
        vararg versions: Pair<String, Int>,
    ) = authorizedRepository(
        NasProfile("synthetic", "Synthetic", "https://nas.example.invalid", "operator"),
        DsmSession("synthetic", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            if (chain.request().securityFields()["api"] == "SYNO.Core.System") Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .body("""{"success":true,"data":{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}}""".toResponseBody("application/json".toMediaType())).build()
            else chain.proceed(chain.request())
        }.addInterceptor(interceptor).build()),
        versions.associate { (name, max) -> name to ApiCapability(name, "entry.cgi", 1, max) } +
            ("SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 1)),
    )

    private companion object {
        const val AUTO_BLOCK = "SYNO.Core.Security.AutoBlock"
        const val ETHERNET = "SYNO.Core.Network.Ethernet"
        const val DOS = "SYNO.Core.Security.DoS"
        const val FIREWALL_CONF = "SYNO.Core.Security.Firewall.Conf"
        const val PORT_OFF = """{"success":true,"data":{"enable_port_check":false}}"""
        const val SUCCESS = """{"success":true,"data":{}}"""
        const val AUTO_OFF =
            """{"success":true,"data":{"enable":false,"attempts":10,"within_mins":5,"expire_day":0}}"""
        const val AUTO_ON =
            """{"success":true,"data":{"enable":true,"attempts":5,"within_mins":10,"expire_day":7}}"""
        const val AUTO_CHANGED =
            """{"success":true,"data":{"enable":false,"attempts":11,"within_mins":5,"expire_day":0}}"""
        const val AUTO_MISSING_EXPIRATION =
            """{"success":true,"data":{"enable":false,"attempts":10,"within_mins":5}}"""
        const val ETHERNET_ROW =
            """{"success":true,"data":{"interfaces":[{"ifname":"eth-synthetic","display":"LAN"}]}}"""
        const val DOS_OFF =
            """{"success":true,"data":[{"adapter":"eth-synthetic","dos_protect_enable":false}]}"""
        const val DOS_ON =
            """{"success":true,"data":[{"adapter":"eth-synthetic","dos_protect_enable":true}]}"""
    }
}

private class SecurityCancellationInterceptor(
    private val entered: CountDownLatch,
    private val release: CountDownLatch,
) : Interceptor {
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val index = synchronized(requests) {
            requests += request
            requests.lastIndex
        }
        val body = when (index) {
            0 -> """{"success":true,"data":{"enable":false,"attempts":10,"within_mins":5,"expire_day":0}}"""
            1 -> """{"success":true,"data":{"enable_port_check":false}}"""
            2 -> """{"success":true,"data":{}}"""
            7 -> {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS)) { "合成安全设置请求等待取消超时" }
                """{"success":true,"data":{}}"""
            }
            3, 5 -> """{"success":true,"data":{"enable":true,"attempts":5,"within_mins":10,"expire_day":7}}"""
            4, 6 -> """{"success":true,"data":{"enable_port_check":false}}"""
            else -> error("缺少合成取消响应")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods() = requests.map { it.securityFields()["method"].orEmpty() }
}

private class SecurityQueueInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = pending.removeFirstOrNull() ?: error("缺少合成安全设置响应")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods() = requests.map { it.securityFields()["method"].orEmpty() }
    fun versions() = requests.map { it.securityFields()["version"].orEmpty() }
}

private fun Request.securityFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
