package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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

class EthernetMutationResultTest {
    @Test
    fun `DHCP 设置与共享 Fixture 一致并使用固定版本回读`() = runBlocking {
        val transport = EthernetInterceptor(STATIC_DETAIL, SUCCESS, DHCP_DETAIL, DHCP_DETAIL)

        val result = repository(transport).saveEthernet(staticUpdate(), dhcpUpdate())

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf("get", "set", "get", "get"), transport.methods())
        assertEquals(listOf("1", "1", "1", "1"), transport.versions())
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "network/set-ethernet/synthetic-interface/request.json",
        )
        val config = transport.requests[1].ethernetFields().getValue("configs")
        assertEquals(1, Json.parseToJsonElement(config).jsonArray.size)
    }

    @Test
    fun `静态地址与 VLAN 只写入目标网卡完整字段`() = runBlocking {
        val transport = EthernetInterceptor(DHCP_DETAIL, SUCCESS, STATIC_DETAIL, STATIC_DETAIL)

        val result = repository(transport).saveEthernet(dhcpUpdate(), staticUpdate())

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        val config = Json.parseToJsonElement(
            transport.requests[1].ethernetFields().getValue("configs"),
        ).jsonArray.single().jsonObject
        assertEquals("eth0", config["ifname"]?.jsonPrimitive?.content)
        assertEquals("192.0.2.20", config["ip"]?.jsonPrimitive?.content)
        assertEquals("255.255.255.0", config["mask"]?.jsonPrimitive?.content)
        assertEquals("20", config["vlan_id"]?.jsonPrimitive?.content)
        assertEquals(10, config.size)
    }

    @Test
    fun `列表数据直接返回数组时完整详情仍可读取并作为保存基线`() = runBlocking {
        val arrayList = """{"success":true,"data":[{"ifname":"eth0","title":"Synthetic LAN","status":"connected"}]}"""
        val transport = EthernetInterceptor(arrayList, STATIC_DETAIL, STATIC_DETAIL, SUCCESS, DHCP_DETAIL, DHCP_DETAIL)
        val repo = repository(transport)
        val original = repo.activeEthernetInterfaces().single()
        val result = repo.saveEthernet(original, dhcpUpdate())
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf("list", "get", "get", "set", "get", "get"), transport.methods())
    }

    @Test
    fun `能力不包含列表 v2 时关闭写入口且不访问网络`() = runBlocking {
        val transport = EthernetInterceptor()

        assertRejected(DsmErrorKind.FEATURE_UNSUPPORTED) { repository(transport, maxVersion = 1)
            .saveEthernet(staticUpdate(), dhcpUpdate())
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `非法标识地址 MTU 与 VLAN 在网络请求前拒绝`() = runBlocking {
        val invalidValues = listOf(
            dhcpUpdate().copy(id = "bond0"),
            dhcpUpdate().copy(mtu = 575),
            staticUpdate().copy(address = "192.0.2.999"),
            staticUpdate().copy(vlanId = 4_095),
        )
        invalidValues.forEach { value ->
            val transport = EthernetInterceptor()
            assertRejected(if (value.id != "eth0") DsmErrorKind.NAS_SERVICE_CHANGED else DsmErrorKind.NAS_SERVICE_INVALID) { repository(transport).saveEthernet(staticUpdate(), value)
            }
            assertTrue(transport.requests.isEmpty())
        }
    }

    @Test
    fun `配置没有变化时计划阶段拒绝且不访问网络`() = runBlocking {
        val transport = EthernetInterceptor()
        assertRejected(DsmErrorKind.NAS_SERVICE_CHANGED) { repository(transport).saveEthernet(dhcpUpdate(), dhcpUpdate()) }
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `设置请求明确权限拒绝时不自动重放`() = runBlocking {
        val transport = EthernetInterceptor(STATIC_DETAIL, PERMISSION_DENIED, STATIC_DETAIL)

        val result = repository(transport).saveEthernet(staticUpdate(), dhcpUpdate())

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertTrue(result.submitted)
        assertEquals(1, transport.methods().count { it == "set" })
    }

    @Test
    fun `设置响应丢失后只回读且一致时确认成功`() = runBlocking {
        val transport = AmbiguousEthernetInterceptor()

        val result = repository(transport).saveEthernet(staticUpdate(), dhcpUpdate())

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf("get", "set", "get", "get"), transport.methods())
    }

    @Test
    fun `设置成功但回读断线时要求重新连接且不重放`() = runBlocking {
        val transport = EthernetStepInterceptor(
            listOf(
                EthernetStep.Json(STATIC_DETAIL),
                EthernetStep.Json(SUCCESS),
                EthernetStep.Failure(IOException("synthetic readback disconnect")),
                EthernetStep.Failure(IOException("synthetic final read disconnect")),
            ),
        )

        val result = repository(transport).saveEthernet(staticUpdate(), dhcpUpdate())

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "set" })
    }

    @Test
    fun `同一网卡已有设置请求时第二次调用不访问网络`() = runBlocking {
        val transport = BlockingEthernetInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) {
            repo.saveEthernet(staticUpdate(), dhcpUpdate())
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        assertRejected(DsmErrorKind.NAS_SERVICE_CHANGED) { repo.saveEthernet(staticUpdate(), dhcpUpdate()) }

        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(listOf("get", "set", "get", "get"), transport.methods())
    }

    @Test
    fun `能力范围缺少详情设置v1时零请求关闭`() = runBlocking {
        val transport = EthernetInterceptor()

        assertRejected(DsmErrorKind.FEATURE_UNSUPPORTED) { repository(transport, minVersion = 2, maxVersion = 2)
            .saveEthernet(staticUpdate(), dhcpUpdate())
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `畸形列表与非法或重复身份不会被解释为可信空列表`() = runBlocking {
        val malformedLists = listOf(
            """{"success":true,"data":{}}""",
            """{"success":true,"data":{"interfaces":{}}}""",
            """{"success":true,"data":{"interfaces":["invalid"]}}""",
            """{"success":true,"data":{"interfaces":[{"ifname":"bond0"}]}}""",
            """{"success":true,"data":{"interfaces":[{"ifname":"eth0"},{"ifname":"eth0"}]}}""",
        )

        malformedLists.forEach { response ->
            val transport = EthernetInterceptor(response)
            val result = runCatching { repository(transport).activeEthernetInterfaces() }
            assertTrue("畸形网卡列表必须保留失败语义", result.isFailure)
            assertEquals(listOf("list"), transport.methods())
        }
    }

    @Test
    fun `明确空数组保留可信空列表语义`() = runBlocking {
        val transport = EthernetInterceptor(
            """{"success":true,"data":{"interfaces":[]}}""",
        )

        val interfaces = repository(transport).activeEthernetInterfaces()

        assertTrue(interfaces.isEmpty())
        assertEquals(listOf("list"), transport.methods())
    }

    @Test
    fun `详情缺失或返回其他网卡身份时预检零写`() = runBlocking {
        val invalidDetails = listOf(
            STATIC_DETAIL.replace("\"ifname\":\"eth0\",", ""),
            STATIC_DETAIL.replace("\"ifname\":\"eth0\"", "\"ifname\":\"eth1\""),
            STATIC_DETAIL.replace("\"mtu\":1500,", ""),
            STATIC_DETAIL.replace("\"is_default_gateway\":false,", ""),
            STATIC_DETAIL.replace("\"enable_vlan\":true,", ""),
        )

        invalidDetails.forEach { detail ->
            val transport = EthernetInterceptor(detail)
            val result = repository(transport)
                .saveEthernet(staticUpdate(), dhcpUpdate())
            assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
            assertFalse(result.submitted)
            assertEquals(0, transport.methods().count { it == "set" })
        }
    }

    @Test
    fun `写后详情缺少核对字段时保持未确认且不重放`() = runBlocking {
        val incompleteReadback = DHCP_DETAIL.replace("\"mtu\":1500,", "")
        val transport = EthernetInterceptor(STATIC_DETAIL, SUCCESS, incompleteReadback, incompleteReadback)

        val result = repository(transport)
            .saveEthernet(staticUpdate(), dhcpUpdate())

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "set" })
    }

    @Test
    fun `编辑基线已经漂移时不覆盖当前网卡配置`() = runBlocking {
        val staleOriginal = staticUpdate().copy(mtu = 1_400)
        val transport = EthernetInterceptor(STATIC_DETAIL)

        val result = repository(transport)
            .saveEthernet(staleOriginal, dhcpUpdate())

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(0, transport.methods().count { it == "set" })
    }

    @Test
    fun `非连续掩码与未经确认的DNS格式在网络前拒绝`() = runBlocking {
        val invalidValues = listOf(
            staticUpdate().copy(subnetMask = "255.0.255.0"),
            staticUpdate().copy(dnsServers = "192.0.2.1,198.51.100.1"),
            staticUpdate().copy(dnsServers = "dns.example.invalid"),
        )
        invalidValues.forEach { desired ->
            val transport = EthernetInterceptor()
            assertRejected(DsmErrorKind.NAS_SERVICE_INVALID) { repository(transport)
                .saveEthernet(staticUpdate(), desired)
            }
            assertTrue(transport.requests.isEmpty())
        }
    }

    @Test
    fun `预检取消零写且设置在途取消停止回读和重放`() = runBlocking {
        val preflightTransport = CancellableEthernetInterceptor(
            blockAt = 1,
            bodies = listOf(STATIC_DETAIL),
        )
        var preflightResult: io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult? = null
        val preflightJob = launch(Dispatchers.Default) {
            preflightResult = repository(preflightTransport)
                .saveEthernet(staticUpdate(), dhcpUpdate())
        }
        assertTrue(preflightTransport.entered.await(5, TimeUnit.SECONDS))
        preflightJob.cancel()
        preflightTransport.release.countDown()
        preflightJob.join()
        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, preflightResult?.status)
        assertEquals(0, preflightTransport.methods().count { it == "set" })

        val submitTransport = CancellableEthernetInterceptor(
            blockAt = 2,
            bodies = listOf(STATIC_DETAIL, SUCCESS),
        )
        var submitResult: io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult? = null
        val submitJob = launch(Dispatchers.Default) {
            submitResult = repository(submitTransport)
                .saveEthernet(staticUpdate(), dhcpUpdate())
        }
        assertTrue(submitTransport.entered.await(5, TimeUnit.SECONDS))
        submitJob.cancel()
        submitTransport.release.countDown()
        submitJob.join()
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, submitResult?.status)
        assertTrue(submitResult?.submitted == true)
        assertTrue(submitResult?.requiresRefresh == true)
        assertEquals(1, submitTransport.methods().count { it == "set" })
        assertEquals(listOf("get", "set"), submitTransport.methods())
    }

    private fun repository(
        interceptor: Interceptor,
        minVersion: Int = 1,
        maxVersion: Int = 2,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            if (chain.request().ethernetFields()["api"] == "SYNO.Core.System") ethernetResponse(chain.request(),
                """{"success":true,"data":{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}}""")
            else chain.proceed(chain.request())
        }.addInterceptor(interceptor).build()),
        mapOf(API to ApiCapability(API, "entry.cgi", minVersion, maxVersion),
            "SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 1)),
    )

    private suspend fun DsmRepository.saveEthernet(original: NasEthernetInterface, desired: NasEthernetInterface): MutationResult =
        nasServices.save(nasServices.plan(NasServiceValue.Ethernet(original), NasServiceValue.Ethernet(desired))) { }
    private suspend fun assertRejected(kind: DsmErrorKind, action: suspend () -> Unit) {
        val failure = try { action(); error("Expected rejection") } catch (error: DsmFailure) { error }
        assertEquals(kind, failure.kind)
    }

    companion object {
        const val API = "SYNO.Core.Network.Ethernet"
        const val SUCCESS = """{"success":true,"data":{}}"""
        const val PERMISSION_DENIED = """{"success":false,"error":{"code":105}}"""
        const val LIST =
            """{"success":true,"data":{"interfaces":[{"ifname":"eth0","title":"Synthetic LAN","status":"connected"}]}}"""
        const val DHCP_DETAIL =
            """{"success":true,"data":{"ifname":"eth0","title":"Synthetic LAN","status":"connected","use_dhcp":true,"ip":"192.0.2.10","mask":"255.255.255.0","gateway":"192.0.2.1","dns":"192.0.2.1","is_default_gateway":false,"mtu":1500,"enable_vlan":false,"vlan_id":0}}"""
        const val STATIC_DETAIL =
            """{"success":true,"data":{"ifname":"eth0","title":"Synthetic LAN","status":"connected","use_dhcp":false,"ip":"192.0.2.20","mask":"255.255.255.0","gateway":"192.0.2.1","dns":"192.0.2.1","is_default_gateway":false,"mtu":1500,"enable_vlan":true,"vlan_id":20}}"""

        fun dhcpUpdate() = NasEthernetInterface(
            id = "eth0",
            displayName = "Synthetic LAN",
            status = "connected",
            usesDhcp = true,
            address = "192.0.2.10",
            subnetMask = "255.255.255.0",
            gateway = "192.0.2.1",
            dnsServers = "192.0.2.1",
            isDefaultGateway = false,
            mtu = 1_500,
            isVlanEnabled = false,
            vlanId = null,
        )

        fun staticUpdate() = NasEthernetInterface(
            id = "eth0",
            displayName = "Synthetic LAN",
            status = "connected",
            usesDhcp = false,
            address = "192.0.2.20",
            subnetMask = "255.255.255.0",
            gateway = "192.0.2.1",
            dnsServers = "192.0.2.1",
            isDefaultGateway = false,
            mtu = 1_500,
            isVlanEnabled = true,
            vlanId = 20,
        )
    }
}

private class EthernetInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return ethernetResponse(request, pending.removeFirstOrNull() ?: error("缺少合成网卡响应"))
    }
    fun methods() = requests.map { it.ethernetFields()["method"] }
    fun versions() = requests.map { it.ethernetFields()["version"] }
}

private class AmbiguousEthernetInterceptor : Interceptor {
    val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        if (requests.size == 2) throw IOException("synthetic ambiguous ethernet update")
        val body = when (requests.size) {
            1 -> EthernetMutationResultTest.STATIC_DETAIL
            else -> EthernetMutationResultTest.DHCP_DETAIL
        }
        return ethernetResponse(request, body)
    }
    fun methods() = requests.map { it.ethernetFields()["method"] }
}

private sealed interface EthernetStep {
    data class Json(val body: String) : EthernetStep
    data class Failure(val error: IOException) : EthernetStep
}

private class EthernetStepInterceptor(steps: List<EthernetStep>) : Interceptor {
    private val pending = ArrayDeque(steps)
    val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return when (val step = pending.removeFirst()) {
            is EthernetStep.Json -> ethernetResponse(request, step.body)
            is EthernetStep.Failure -> throw step.error
        }
    }
    fun methods() = requests.map { it.ethernetFields()["method"] }
}

private class BlockingEthernetInterceptor : Interceptor {
    val submissionStarted = CountDownLatch(1)
    val allowSubmission = CountDownLatch(1)
    private val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val index = synchronized(requests) { requests += request; requests.size }
        val body = when (index) {
            1 -> EthernetMutationResultTest.STATIC_DETAIL
            2 -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待合成网卡设置请求放行超时" }
                EthernetMutationResultTest.SUCCESS
            }
            else -> EthernetMutationResultTest.DHCP_DETAIL
        }
        return ethernetResponse(request, body)
    }
    fun methods() = synchronized(requests) { requests.map { it.ethernetFields()["method"] } }
}

private class CancellableEthernetInterceptor(
    private val blockAt: Int,
    bodies: List<String>,
) : Interceptor {
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    private val pending = ArrayDeque(bodies)
    private val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val index = synchronized(requests) {
            requests += request
            requests.size
        }
        if (index == blockAt) {
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS)) { "等待合成网卡请求放行超时" }
        }
        val body = synchronized(pending) {
            pending.removeFirstOrNull()
        } ?: error("缺少合成网卡响应")
        return ethernetResponse(request, body)
    }

    fun methods() = synchronized(requests) { requests.map { it.ethernetFields()["method"] } }
}

private fun ethernetResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.ethernetFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
