package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
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

class PhotoShareRepositoryTest {
    @Test
    fun `旧路径入口在读取权限缺失或拒绝时也不创建分享`() = runBlocking {
        for (permission in listOf("{}", """{"acl":{"read":false,"write":true,"del":true}}""")) {
            val methods = mutableListOf<String?>()
            val transport = Interceptor { chain ->
                val request = chain.request(); methods += request.shareFields()["method"]
                shareResponse(request, """{"success":true,"data":{"files":[{"path":"/home/Photos/a.jpg","name":"a.jpg","isdir":false,"additional":{"perm":$permission}}]}}""")
            }
            val result = repository(transport).createShareLinkResult("/home/Photos/a.jpg").result
            assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
            assertFalse(result.submitted)
            assertEquals(listOf("getinfo"), methods)
        }
    }

    @Test
    fun `创建公开共享链接后必须通过列表回读确认`() = runBlocking {
        val transport = ShareInterceptor(
            """{"success":true,"data":{"links":[{"id":"link-1","error":0,"has_password":false,"date_available":0,"date_expired":0,"name":"a.jpg","path":"/home/Photos/a.jpg","url":"https://share.example.invalid/x"}]}}""",
            """{"success":true,"data":{"total":1,"links":[{"id":"link-1","error":0,"has_password":false,"date_available":0,"date_expired":0,"name":"a.jpg","path":"/home/Photos/a.jpg","url":"https://share.example.invalid/x"}]}}""",
        )

        val outcome = repository(transport).createShareLinkResult("/home/Photos/a.jpg")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, outcome.result.status)
        assertEquals("link-1", outcome.link?.id)
        assertEquals("https://share.example.invalid/x", outcome.link?.url)
        assertEquals(listOf("getinfo", "list", "create", "list"), transport.requests.map { it.shareFields()["method"] })
        assertEquals("[\"/home/Photos/a.jpg\"]", transport.requests.single { it.shareFields()["method"] == "create" }.shareFields()["path"])
    }

    @Test
    fun `回读未找到新共享链接时不报告成功`() = runBlocking {
        val transport = ShareInterceptor(
            """{"success":true,"data":{"id":"link-1","url":"https://share.example.invalid/x"}}""",
            """{"success":true,"data":{"total":0,"links":[]}}""",
        )

        val outcome = repository(transport).createShareLinkResult("/home/Photos/a.jpg")

        assertEquals(4, transport.requests.size)
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, outcome.result.status)
        assertTrue(outcome.result.submitted)
        assertTrue(outcome.result.requiresRefresh)
        assertEquals(null, outcome.link)
    }

    @Test
    fun `共享链接输入或能力无效时零请求拒绝`() = runBlocking {
        val invalidTransport = ShareInterceptor()
        val invalid = repository(invalidTransport).createShareLinkResult("/")
        val unsupportedTransport = ShareInterceptor()
        val unsupported = repository(unsupportedTransport, supportsSharing = false)
            .createShareLinkResult("/home/Photos/a.jpg")

        assertEquals(MutationErrorCategory.VALIDATION, invalid.result.errorCategory)
        assertEquals(MutationResultStatus.UNSUPPORTED, unsupported.result.status)
        assertTrue(invalidTransport.requests.isEmpty())
        assertTrue(unsupportedTransport.requests.isEmpty())
    }

    @Test
    fun `共享链接提交断线保持未确认且不自动重放`() = runBlocking {
        val transport = FailingShareInterceptor()

        val outcome = repository(transport).createShareLinkResult("/home/Photos/a.jpg")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, outcome.result.status)
        assertEquals(MutationErrorCategory.NETWORK, outcome.result.errorCategory)
        assertEquals(3, transport.requests.size)
    }

    @Test
    fun `共享链接明确权限拒绝不会自动重放`() = runBlocking {
        val transport = ShareInterceptor("""{"success":false,"error":{"code":105}}""")

        val outcome = repository(transport).createShareLinkResult("/home/Photos/a.jpg")

        assertEquals(MutationResultStatus.PERMISSION_DENIED, outcome.result.status)
        assertTrue(outcome.result.submitted)
        assertEquals(3, transport.requests.size)
    }

    @Test
    fun `共享链接回读断线保持未确认`() = runBlocking {
        val transport = FailingShareInterceptor(
            """{"success":true,"data":{"links":[{"id":"link-1","error":0,"has_password":false,"date_available":0,"date_expired":0,"name":"a.jpg","path":"/home/Photos/a.jpg","url":"https://share.example.invalid/x"}]}}""",
        )

        val outcome = repository(transport).createShareLinkResult("/home/Photos/a.jpg")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, outcome.result.status)
        assertTrue(outcome.result.requiresRefresh)
        assertEquals(4, transport.requests.size)
    }

    @Test
    fun `相同路径共享链接进行中时拒绝第二次提交`() = runBlocking {
        val transport = BlockingShareInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.createShareLinkResult("/home/Photos/a.jpg") }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.createShareLinkResult("/home/Photos/a.jpg")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.result.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.result.errorCategory)
        assertFalse(duplicate.result.submitted)
        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().result.status)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `共享链接创建中时拒绝删除同一项目`() = runBlocking {
        val transport = BlockingShareInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.createShareLinkResult("/home/Photos/a.jpg") }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val deletion = repo.deleteResult(listOf("/home/Photos/a.jpg"))

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, deletion.status)
        assertEquals(MutationErrorCategory.CONFLICT, deletion.errorCategory)
        assertFalse(deletion.submitted)
        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().result.status)
        assertFalse(transport.methods().contains("start"))
    }

    @Test
    fun `共享链接提交前协程取消时不访问网络`() {
        val transport = ShareInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).createShareLinkResult("/home/Photos/a.jpg").result.status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `共享链接提交后的取消只要求核对且不重放`() = runBlocking {
        val transport = BlockingShareInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.createShareLinkResult("/home/Photos/a.jpg").result.status
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowSubmission.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    private fun repository(interceptor: Interceptor, supportsSharing: Boolean = true) = authorizedRepository(
        profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        session = DsmSession("test", "test-session", "test-token"),
        api = DsmApiClient(
            OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build(),
        ),
        capabilities = buildList {
            add(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2))
            add(ApiCapability("SYNO.FileStation.Delete", "entry.cgi", 1, 2))
            if (supportsSharing) {
                add(ApiCapability(
                    "SYNO.FileStation.Sharing",
                    "entry.cgi",
                    1,
                    3,
                ))
            }
        }.associateBy(ApiCapability::name),
    )
}

private class FailingShareInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(listOf("""{"success":true,"data":{"files":[{"path":"/home/Photos/a.jpg","name":"a.jpg","isdir":false,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}]}}""", """{"success":true,"data":{"links":[],"total":0}}""") + responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = pending.removeFirstOrNull() ?: throw IOException("synthetic share disconnect")
        return shareResponse(request, body)
    }
}

private class BlockingShareInterceptor : Interceptor {
    val submissionStarted = CountDownLatch(1)
    val allowSubmission = CountDownLatch(1)
    private val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val index = synchronized(requests) {
            requests += request
            requests.size
        }
        val body = when (index) {
            1 -> """{"success":true,"data":{"files":[{"path":"/home/Photos/a.jpg","name":"a.jpg","isdir":false,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}]}}"""
            2 -> """{"success":true,"data":{"links":[],"total":0}}"""
            3 -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待合成共享请求放行超时" }
                """{"success":true,"data":{"links":[{"id":"link-1","error":0,"has_password":false,"date_available":0,"date_expired":0,"name":"a.jpg","path":"/home/Photos/a.jpg","url":"https://share.example.invalid/x"}]}}"""
            }
            else -> """{"success":true,"data":{"total":1,"links":[{"id":"link-1","error":0,"has_password":false,"date_available":0,"date_expired":0,"name":"a.jpg","path":"/home/Photos/a.jpg","url":"https://share.example.invalid/x"}]}}"""
        }
        return shareResponse(request, body)
    }

    fun methods(): List<String?> = synchronized(requests) {
        requests.map { it.shareFields()["method"] }
    }
}

private class ShareInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(listOf("""{"success":true,"data":{"files":[{"path":"/home/Photos/a.jpg","name":"a.jpg","isdir":false,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}]}}""", """{"success":true,"data":{"links":[],"total":0}}""") + responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                (pending.removeFirstOrNull() ?: error("缺少合成共享响应"))
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private fun Request.shareFields(): Map<String, String> {
    val form = body as FormBody
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}

private fun shareResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()
