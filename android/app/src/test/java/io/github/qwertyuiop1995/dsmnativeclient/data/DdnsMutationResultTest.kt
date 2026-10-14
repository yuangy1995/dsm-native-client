package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.DdnsMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDirectory
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsProvider
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
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
import okio.BufferedSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DdnsMutationResultTest {
    @Test
    fun `连接测试只调用 test 且不会保存更新或回读`() = runBlocking {
        val transport = QueueDdnsInterceptor(PROVIDERS, EMPTY_RECORDS, SUCCESS)

        val result = repository(transport).testDdns(newDraft())

        assertConfirmed(result)
        assertEquals(listOf("list", "list", "test"), transport.methods())
        assertFalse(transport.methods().any { it in setOf("create", "set", "update_ip_address", "delete") })
        RequestFixtureAssertions.assertRequest(
            transport.requests.last(),
            "ddns/test-provider/synthetic-record/request.json",
        )
    }

    @Test
    fun `新建只提交一次并严格回读全部可观察字段`() = runBlocking {
        val transport = QueueDdnsInterceptor(PROVIDERS, EMPTY_RECORDS, SUCCESS, PROVIDERS, SAVED_RECORDS)

        val result = repository(transport).saveDdns(null, newDraft())

        assertConfirmed(result)
        assertEquals(listOf("list", "list", "create", "list", "list"), transport.methods())
        assertEquals(1, transport.methods().count { it == "create" })
        RequestFixtureAssertions.assertRequest(
            transport.requests[2],
            "ddns/create-record/synthetic-record/request.json",
        )
    }

    @Test
    fun `编辑留空密码不提交 passwd 且基线一致时成功`() = runBlocking {
        val transport = QueueDdnsInterceptor(PROVIDERS, SAVED_RECORDS, SUCCESS, PROVIDERS, UPDATED_RECORDS)
        val desired = newDraft().copy(
            originalProviderId = "Example",
            password = "",
            hostname = "updated.example.invalid",
        )

        val result = repository(transport).saveDdns(savedRecord(), desired)

        assertConfirmed(result)
        assertEquals("set", transport.methods()[2])
        assertFalse("passwd" in transport.requests[2].fields())
    }

    @Test
    fun `编辑基线陈旧时零写入拒绝覆盖`() = runBlocking {
        val transport = QueueDdnsInterceptor(PROVIDERS, UPDATED_RECORDS)
        val desired = newDraft().copy(originalProviderId = "Example", password = "", heartbeat = true)

        val result = repository(transport).saveDdns(savedRecord(), desired)

        assertConflictBeforeSubmission(result)
        assertFalse(transport.methods().any { it in setOf("create", "set") })
    }

    @Test
    fun `删除基线陈旧时零写入拒绝误删`() = runBlocking {
        val transport = QueueDdnsInterceptor(PROVIDERS, UPDATED_RECORDS)

        val result = repository(transport).deleteDdns(savedRecord())

        assertConflictBeforeSubmission(result)
        assertFalse(transport.methods().contains("delete"))
    }

    @Test
    fun `删除按服务商数组只提交一次并确认消失`() = runBlocking {
        val transport = QueueDdnsInterceptor(PROVIDERS, SAVED_RECORDS, SUCCESS, PROVIDERS, EMPTY_RECORDS)

        val result = repository(transport).deleteDdns(savedRecord())

        assertConfirmed(result)
        assertEquals("[\"Example\"]", transport.requests[2].fields()["id"])
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `立即更新目标集合一致时独立提交并只证明请求接受`() = runBlocking {
        val transport = QueueDdnsInterceptor(PROVIDERS, SAVED_RECORDS, SUCCESS, PROVIDERS, SAVED_RECORDS)

        val result = repository(transport).refreshDdns(setOf("Example"))

        assertConfirmed(result)
        assertEquals(listOf("list", "list", "update_ip_address", "list", "list"), transport.methods())
        RequestFixtureAssertions.assertRequest(
            transport.requests[2],
            "ddns/update-address/synthetic-record/request.json",
        )
    }

    @Test
    fun `立即更新目标集合变化时零写入冲突`() = runBlocking {
        val transport = QueueDdnsInterceptor(PROVIDERS, SAVED_RECORDS)

        val result = repository(transport).refreshDdns(setOf("Other"))

        assertConflictBeforeSubmission(result)
        assertFalse(transport.methods().contains("update_ip_address"))
    }

    @Test
    fun `Provider 或 Record 不含 v1 时四入口均零网络`() = runBlocking {
        listOf(PROVIDER_API to 2, RECORD_API to 2).forEach { (changedApi, minVersion) ->
            val transport = QueueDdnsInterceptor()
            val repo = repository(transport, versionOverrides = mapOf(changedApi to minVersion))
            val failures = listOf(
                runCatching { repo.testDdns(newDraft()) },
                runCatching { repo.saveDdns(null, newDraft()) },
                runCatching { repo.deleteDdns(savedRecord()) },
                runCatching { repo.refreshDdns(setOf("Example")) },
            )
            failures.forEach { assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (it.exceptionOrNull() as DsmFailure).kind) }
            assertTrue(transport.requests.isEmpty())
        }
    }

    @Test
    fun `Provider 结构失败先拒绝且不再读取 Record`() = runBlocking {
        listOf(
            """{"success":true,"data":{}}""",
            """{"success":true,"data":{"providers":{},"items":[]}}""",
            """{"success":true,"data":{"providers":["bad"]}}""",
            """{"success":true,"data":{"providers":[{"id":"Example"},{"id":"Example"}]}}""",
        ).forEach { malformed ->
            val transport = QueueDdnsInterceptor(malformed)
            assertInvalidDirectory(repository(transport))
            assertEquals(listOf(PROVIDER_API), transport.apis())
        }
    }

    @Test
    fun `Record 缺根错类型畸形项或重复身份均不是可信空目录`() = runBlocking {
        listOf(
            """{"success":true,"data":{}}""",
            """{"success":true,"data":{"records":{},"items":[]}}""",
            """{"success":true,"data":{"records":["bad"]}}""",
            """{"success":true,"data":{"records":[${recordJson()},${recordJson()}]}}""",
            """{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid"}]}}""",
        ).forEach { malformed ->
            val transport = QueueDdnsInterceptor(PROVIDERS, malformed)
            assertInvalidDirectory(repository(transport))
            assertEquals(listOf(PROVIDER_API, RECORD_API), transport.apis())
        }
    }

    @Test
    fun `显式空数组是可信空目录`() = runBlocking {
        val directory = repository(QueueDdnsInterceptor(EMPTY_PROVIDERS, EMPTY_RECORDS)).activeDdnsDirectory()

        assertTrue(directory.providers.isEmpty())
        assertTrue(directory.records.isEmpty())
    }

    @Test
    fun `只含核心五字段的 Record 是合法目录`() = runBlocking {
        val directory = repository(QueueDdnsInterceptor(PROVIDERS, MINIMAL_RECORDS)).activeDdnsDirectory()

        assertEquals(1, directory.records.size)
        assertEquals("Example", directory.records.single().providerId)
        assertEquals("auto", directory.records.single().networkType)
    }

    @Test
    fun `最小 Record 仍可确认保存的单次模糊回读`() = runBlocking {
        val transport = AmbiguousMutationInterceptor("create", MINIMAL_RECORDS)

        val result = repository(transport).saveDdns(null, newDraft())

        assertConfirmed(result)
        assertEquals(1, transport.methods().count { it == "create" })
        assertEquals(4, transport.methods().count { it == "list" })
    }

    @Test
    fun `最小 Record 可作为删除预检基线`() = runBlocking {
        val transport = QueueDdnsInterceptor(PROVIDERS, MINIMAL_RECORDS, SUCCESS, PROVIDERS, EMPTY_RECORDS)

        val result = repository(transport).deleteDdns(savedRecord().copy(knownNetworkFields = emptySet()))

        assertConfirmed(result)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `非法控制字符和地址字段均零请求拒绝`() = runBlocking {
        listOf(
            newDraft().copy(username = "bad\nuser"),
            newDraft().copy(networkType = "auto\r"),
            newDraft().copy(ipv4 = "999.1.1.1"),
            newDraft().copy(ipv6 = "not-ipv6"),
            newDraft().copy(interfaceV4 = "eth0\u0000"),
            newDraft().copy(password = "secret\tvalue"),
        ).forEach { draft ->
            val transport = QueueDdnsInterceptor()
            val failure = runCatching { repository(transport).saveDdns(null, draft) }.exceptionOrNull()
            assertEquals(DsmErrorKind.NAS_DDNS_INVALID, (failure as DsmFailure).kind)
            assertTrue(transport.requests.isEmpty())
        }
    }

    @Test
    fun `新建响应丢失后只读取一次目录且不重放`() = runBlocking {
        val transport = AmbiguousMutationInterceptor("create", SAVED_RECORDS)

        val result = repository(transport).saveDdns(null, newDraft())

        assertConfirmed(result)
        assertEquals(1, transport.methods().count { it == "create" })
        assertEquals(4, transport.methods().count { it == "list" })
    }

    @Test
    fun `删除响应丢失后只读取一次目录且不重放`() = runBlocking {
        val transport = AmbiguousMutationInterceptor("delete", EMPTY_RECORDS, initialRecords = SAVED_RECORDS)

        val result = repository(transport).deleteDdns(savedRecord())

        assertConfirmed(result)
        assertEquals(1, transport.methods().count { it == "delete" })
        assertEquals(4, transport.methods().count { it == "list" })
    }

    @Test
    fun `模糊保存单次回读失败保持未确认且不重放`() = runBlocking {
        val transport = AmbiguousMutationInterceptor("create", EMPTY_RECORDS)

        val result = repository(transport).saveDdns(null, newDraft())

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
        assertTrue(result.requiresRefresh)
        assertEquals(1, result.counts.unknown)
        assertEquals(1, transport.methods().count { it == "create" })
        assertEquals(4, transport.methods().count { it == "list" })
    }

    @Test
    fun `立即更新响应丢失不以可读目录升级成功且不重放`() = runBlocking {
        val transport = AmbiguousMutationInterceptor("update_ip_address", SAVED_RECORDS, initialRecords = SAVED_RECORDS)

        val result = repository(transport).refreshDdns(setOf("Example"))

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
        assertTrue(result.requiresRefresh)
        assertEquals(1, result.counts.unknown)
        assertEquals(4, transport.methods().count { it == "list" })
        assertEquals(1, transport.methods().count { it == "update_ip_address" })
    }

    @Test
    fun `服务商测试与其他服务商和全局操作共享互斥`() = runBlocking {
        val transport = BlockingTestInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.testDdns(newDraft()) }
        assertTrue(transport.testEntered.await(2, TimeUnit.SECONDS))

        val other = runCatching { repo.testDdns(newDraft(provider = "Other")) }.exceptionOrNull()
        assertEquals(DsmErrorKind.NAS_SERVICE_CHANGED, (other as DsmFailure).kind)
        val global = runCatching { repo.refreshDdns(setOf("Example")) }.exceptionOrNull()
        assertEquals(DsmErrorKind.NAS_SERVICE_CHANGED, (global as DsmFailure).kind)
        assertEquals(0, transport.methods().count { it == "update_ip_address" })

        transport.releaseTest.countDown()
        assertConfirmed(first.await())
    }

    @Test
    fun `global 操作进行时拒绝任一 provider 操作`() = runBlocking {
        val transport = BlockingRefreshInterceptor()
        val repo = repository(transport)
        val refresh = async(Dispatchers.IO) { repo.refreshDdns(setOf("Example")) }
        assertTrue(transport.refreshEntered.await(2, TimeUnit.SECONDS))

        val provider = runCatching { repo.testDdns(newDraft()) }.exceptionOrNull()
        assertEquals(DsmErrorKind.NAS_SERVICE_CHANGED, (provider as DsmFailure).kind)
        assertEquals(0, transport.methods().count { it == "test" })
        transport.releaseRefresh.countDown()
        assertConfirmed(refresh.await())
    }

    @Test
    fun `test 预检取消后报告提交前取消并释放 provider 锁`() = runBlocking {
        val transport = CancelOnceInterceptor(cancelMethod = "list")
        val repo = repository(transport)

        val cancelled = repo.testDdns(newDraft())

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, cancelled.status)
        assertFalse(cancelled.submitted)
        assertEquals(0, cancelled.counts.unknown)
        assertConfirmed(repo.testDdns(newDraft()))
    }

    @Test
    fun `test 在途取消后报告提交后取消并释放 provider 锁`() = runBlocking {
        val transport = CancelOnceInterceptor(cancelMethod = "test")
        val repo = repository(transport)

        val cancelled = repo.testDdns(newDraft())

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, cancelled.status)
        assertTrue(cancelled.submitted)
        assertEquals(1, cancelled.counts.unknown)
        assertConfirmed(repo.testDdns(newDraft()))
    }

    @Test
    fun `DDNS 四个写入口在途取消都不重放写请求`() = runBlocking {
        val testTransport = CancelOnceInterceptor(cancelMethod = "test")
        val test = repository(testTransport).testDdns(newDraft())
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, test.status)
        assertTrue(test.submitted)
        assertEquals(1, testTransport.methods().count { it == "test" })

        val saveTransport = CancelOnceInterceptor(
            cancelMethod = "create",
            recordResponses = listOf(EMPTY_RECORDS, EMPTY_RECORDS),
        )
        val save = repository(saveTransport).saveDdns(null, newDraft())
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, save.status)
        assertTrue(save.submitted)
        assertEquals(1, saveTransport.methods().count { it == "create" })

        val deleteTransport = CancelOnceInterceptor(
            cancelMethod = "delete",
            recordResponses = listOf(SAVED_RECORDS, SAVED_RECORDS),
        )
        val delete = repository(deleteTransport).deleteDdns(savedRecord())
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, delete.status)
        assertTrue(delete.submitted)
        assertEquals(1, deleteTransport.methods().count { it == "delete" })

        val refreshTransport = CancelOnceInterceptor(
            cancelMethod = "update_ip_address",
            recordResponses = listOf(SAVED_RECORDS),
        )
        val refresh = repository(refreshTransport).refreshDdns(setOf("Example"))
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, refresh.status)
        assertTrue(refresh.submitted)
        assertEquals(1, refreshTransport.methods().count { it == "update_ip_address" })
    }

    // 基线为用户打开编辑器时已见的合成目录；结果直接取正式执行器，不重建旧结果映射。
    private fun directory(records: List<NasDdnsRecord>) = NasDdnsDirectory(
        listOf(NasDdnsProvider("Example", "Synthetic Provider"), NasDdnsProvider("Other", "Other Provider")), records)
    private suspend fun DsmRepository.testDdns(draft: NasDdnsDraft) =
        nasDdns.perform(nasDdns.plan(DdnsMutationOperation.TEST, directory(emptyList()), draft)) {}.result
    private suspend fun DsmRepository.saveDdns(original: NasDdnsRecord?, draft: NasDdnsDraft) =
        nasDdns.perform(nasDdns.plan(DdnsMutationOperation.SAVE, directory(listOfNotNull(original)), draft)) {}.result
    private suspend fun DsmRepository.deleteDdns(original: NasDdnsRecord) =
        nasDdns.perform(nasDdns.plan(DdnsMutationOperation.DELETE, directory(listOf(original)), target = original)) {}.result
    private suspend fun DsmRepository.refreshDdns(ids: Set<String>) =
        nasDdns.perform(nasDdns.plan(DdnsMutationOperation.ADDRESS_REFRESH, directory(ids.map(::savedRecord)))) {}.result

    private fun repository(
        interceptor: Interceptor,
        versionOverrides: Map<String, Int> = emptyMap(),
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            if (chain.request().fields()["api"] == "SYNO.Core.System")
                ddnsResponse(chain.request(), """{"success":true,"data":{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}}""")
            else chain.proceed(chain.request())
        }.addInterceptor(interceptor).build()),
        mapOf(
            "SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 1),
            PROVIDER_API to ApiCapability(
                PROVIDER_API,
                "entry.cgi",
                versionOverrides[PROVIDER_API] ?: 1,
                2,
            ),
            RECORD_API to ApiCapability(
                RECORD_API,
                "entry.cgi",
                versionOverrides[RECORD_API] ?: 1,
                2,
            ),
        ),
    )

    private fun newDraft(provider: String = "Example") = NasDdnsDraft(
        providerId = provider,
        hostname = "nas.example.invalid",
        username = "synthetic-user",
        password = "synthetic-secret",
        interfaceV4 = "eth0",
        interfaceV6 = "eth0",
    )

    private fun savedRecord(provider: String = "Example") = NasDdnsRecord(
        providerId = provider,
        providerName = "Synthetic Provider",
        hostname = "nas.example.invalid",
        address = null,
        status = null,
        lastUpdated = null,
        isEnabled = true,
        username = "synthetic-user",
        networkType = "auto",
        ipv4 = "0.0.0.0",
        ipv6 = "0:0:0:0:0:0:0:0",
        interfaceV4 = "eth0",
        interfaceV6 = "eth0",
        heartbeat = false,
    )

    private fun assertConfirmed(result: io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult) {
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertTrue(result.submitted)
        assertFalse(result.requiresRefresh)
        assertEquals(1, result.counts.succeeded)
        assertEquals(0, result.counts.failed)
        assertEquals(0, result.counts.unknown)
    }

    private fun assertConflictBeforeSubmission(
        result: io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult,
    ) {
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(1, result.counts.failed)
    }

    private fun assertInvalidDirectory(repo: DsmRepository) = runBlocking {
        try {
            repo.activeDdnsDirectory()
            fail("畸形 DDNS 目录必须失败")
        } catch (error: DsmFailure) {
            assertNotNull(error)
        }
    }

    companion object {
        const val PROVIDER_API = "SYNO.Core.DDNS.Provider"
        const val RECORD_API = "SYNO.Core.DDNS.Record"
        const val SUCCESS = """{"success":true,"data":{}}"""
        const val PROVIDERS =
            """{"success":true,"data":{"providers":[{"id":"Example","display":"Synthetic Provider"},{"id":"Other","display":"Other Provider"}]}}"""
        const val EMPTY_PROVIDERS = """{"success":true,"data":{"providers":[]}}"""
        const val EMPTY_RECORDS = """{"success":true,"data":{"records":[]}}"""
        val SAVED_RECORDS = """{"success":true,"data":{"records":[${recordJson()}]}}"""
        const val MINIMAL_RECORDS =
            """{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-user","enable":true,"heartbeat":false}]}}"""
        val UPDATED_RECORDS =
            """{"success":true,"data":{"records":[${recordJson(hostname = "updated.example.invalid")}]}}"""

        fun recordJson(
            provider: String = "Example",
            hostname: String = "nas.example.invalid",
        ) = """{"provider":"$provider","hostname":"$hostname","username":"synthetic-user","enable":true,"heartbeat":false,"net":"auto","ip":"0.0.0.0","ipv6":"0:0:0:0:0:0:0:0","interface_v4":"eth0","interface_v6":"eth0"}"""
    }
}

private class QueueDdnsInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        synchronized(requests) { requests += request }
        return ddnsResponse(request, pending.removeFirstOrNull() ?: error("缺少合成 DDNS 响应"))
    }
    fun methods() = requests.map { it.fields()["method"] }
    fun apis() = requests.map { it.fields()["api"] }
}

private class AmbiguousMutationInterceptor(
    private val ambiguousMethod: String,
    private val readbackRecords: String,
    private val initialRecords: String = DdnsMutationResultTest.EMPTY_RECORDS,
) : Interceptor {
    val requests = mutableListOf<Request>()
    private var recordListCount = 0
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val fields = request.fields()
        if (fields["method"] == ambiguousMethod) throw IOException("synthetic ambiguous DDNS mutation")
        val body = when (fields["api"]) {
            DdnsMutationResultTest.PROVIDER_API -> DdnsMutationResultTest.PROVIDERS
            DdnsMutationResultTest.RECORD_API -> if (recordListCount++ == 0) initialRecords else readbackRecords
            else -> DdnsMutationResultTest.SUCCESS
        }
        return ddnsResponse(request, body)
    }
    fun methods() = requests.map { it.fields()["method"] }
}

private class BlockingTestInterceptor(
    private val blockEveryExampleTest: Boolean = true,
) : Interceptor {
    val testEntered = CountDownLatch(1)
    val releaseTest = CountDownLatch(1)
    private var exampleTestCount = 0
    private val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        synchronized(requests) { requests += request }
        val fields = request.fields()
        if (fields["method"] == "test" && fields["provider"] == "Example") {
            exampleTestCount += 1
            if (blockEveryExampleTest || exampleTestCount == 1) {
                testEntered.countDown()
                releaseTest.await(2, TimeUnit.SECONDS)
            }
        }
        val body = when {
            fields["method"] == "list" && fields["api"] == DdnsMutationResultTest.PROVIDER_API ->
                DdnsMutationResultTest.PROVIDERS
            fields["method"] == "list" && fields["api"] == DdnsMutationResultTest.RECORD_API ->
                DdnsMutationResultTest.EMPTY_RECORDS
            else -> DdnsMutationResultTest.SUCCESS
        }
        return ddnsResponse(request, body)
    }
    fun methods() = synchronized(requests) { requests.map { it.fields()["method"] } }
}

private class CancelOnceInterceptor(
    private val cancelMethod: String,
    recordResponses: List<String> = listOf(DdnsMutationResultTest.EMPTY_RECORDS),
) : Interceptor {
    private var cancelled = false
    private val records = ArrayDeque(recordResponses)
    private val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val fields = request.fields()
        if (!cancelled && fields["method"] == cancelMethod) {
            cancelled = true
            return Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(CancellationResponseBody())
                .build()
        }
        val body = when {
            fields["method"] == "list" && fields["api"] == DdnsMutationResultTest.PROVIDER_API ->
                DdnsMutationResultTest.PROVIDERS
            fields["method"] == "list" && fields["api"] == DdnsMutationResultTest.RECORD_API ->
                records.removeFirstOrNull() ?: DdnsMutationResultTest.EMPTY_RECORDS
            else -> DdnsMutationResultTest.SUCCESS
        }
        return ddnsResponse(request, body)
    }

    fun methods() = requests.map { it.fields()["method"] }
}

private class CancellationResponseBody : ResponseBody() {
    override fun contentType() = "application/json".toMediaType()
    override fun contentLength() = -1L
    override fun source(): BufferedSource =
        throw kotlinx.coroutines.CancellationException("synthetic DDNS cancellation")
}

private class BlockingRefreshInterceptor : Interceptor {
    val refreshEntered = CountDownLatch(1)
    val releaseRefresh = CountDownLatch(1)
    private val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        synchronized(requests) { requests += request }
        val fields = request.fields()
        if (fields["method"] == "update_ip_address") {
            refreshEntered.countDown()
            releaseRefresh.await(2, TimeUnit.SECONDS)
        }
        val body = when {
            fields["method"] == "list" && fields["api"] == DdnsMutationResultTest.PROVIDER_API ->
                DdnsMutationResultTest.PROVIDERS
            fields["method"] == "list" && fields["api"] == DdnsMutationResultTest.RECORD_API ->
                DdnsMutationResultTest.SAVED_RECORDS
            else -> DdnsMutationResultTest.SUCCESS
        }
        return ddnsResponse(request, body)
    }
    fun methods() = synchronized(requests) { requests.map { it.fields()["method"] } }
}

private fun ddnsResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.fields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
