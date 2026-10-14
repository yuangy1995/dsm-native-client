package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
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

class ShareLinkDeletionTest {
    @Test
    fun `删除共享链接只提交一次并在列表回读消失后确认`() = runBlocking {
        val transport = ScriptedShareDeleteInterceptor(
            links("link-1"),
            success(),
            links(),
        )

        val result = repository(transport).deleteShareLinksResult(listOf("link-1"))

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(listOf("list", "delete", "list"), transport.methods())
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "file-station/delete-share-link/synthetic-link/request.json",
        )
    }

    @Test
    fun `非法目标不支持能力和已消失目标均在提交前关闭`() = runBlocking {
        val invalidTransport = ScriptedShareDeleteInterceptor()
        val invalid = repository(invalidTransport).deleteShareLinksResult(listOf(""))
        assertEquals(MutationErrorCategory.VALIDATION, invalid.errorCategory)
        assertFalse(invalid.submitted)
        assertTrue(invalidTransport.requests.isEmpty())

        val unsupportedTransport = ScriptedShareDeleteInterceptor()
        val unsupported = repository(unsupportedTransport, supportsSharing = false)
            .deleteShareLinksResult(listOf("link-1"))
        assertEquals(MutationResultStatus.UNSUPPORTED, unsupported.status)
        assertTrue(unsupportedTransport.requests.isEmpty())

        val missingTransport = ScriptedShareDeleteInterceptor(links())
        val missing = repository(missingTransport).deleteShareLinksResult(listOf("link-1"))
        assertEquals(MutationErrorCategory.CONFLICT, missing.errorCategory)
        assertFalse(missing.submitted)
        assertEquals(listOf("list"), missingTransport.methods())
    }

    @Test
    fun `批量删除只移除部分链接时返回部分成功`() = runBlocking {
        val transport = ScriptedShareDeleteInterceptor(
            links("link-1", "link-2"),
            success(),
            links("link-2"),
        )

        val result = repository(transport).deleteShareLinksResult(listOf("link-1", "link-2"))

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.failed)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `提交断线但回读链接已消失时确认成功且不重放`() = runBlocking {
        val transport = ScriptedShareDeleteInterceptor(
            links("link-1"),
            IOException("synthetic disconnect"),
            links(),
        )

        val result = repository(transport).deleteShareLinksResult(listOf("link-1"))

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `提交断线且链接仍存在时保持未确认且不重放`() = runBlocking {
        val transport = ScriptedShareDeleteInterceptor(
            links("link-1"),
            IOException("synthetic disconnect"),
            links("link-1"),
        )

        val result = repository(transport).deleteShareLinksResult(listOf("link-1"))

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `权限拒绝后回读链接仍存在时明确报告权限不足`() = runBlocking {
        val transport = ScriptedShareDeleteInterceptor(
            links("link-1"),
            failure(105),
            links("link-1"),
        )

        val result = repository(transport).deleteShareLinksResult(listOf("link-1"))

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `提交成功但回读失败时保持未确认`() = runBlocking {
        val transport = ScriptedShareDeleteInterceptor(
            links("link-1"),
            success(),
            IOException("synthetic readback failure"),
        )

        val result = repository(transport).deleteShareLinksResult(listOf("link-1"))

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
    }

    @Test
    fun `提交前协程取消时不访问网络`() {
        val transport = ScriptedShareDeleteInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).deleteShareLinksResult(listOf("link-1")).status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `同一共享链接删除进行中拒绝重复提交`() = runBlocking {
        val transport = BlockingShareDeleteInterceptor(markDeleted = true)
        val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.deleteShareLinksResult(listOf("link-1")) }
        assertTrue(transport.deleteStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.deleteShareLinksResult(listOf("link-1"))
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)

        transport.allowDelete.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.deleteRequests.get())
    }

    @Test
    fun `共享链接删除进行中阻止同一路径文件删除`() = runBlocking {
        val transport = BlockingShareDeleteInterceptor(markDeleted = true)
        val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.deleteShareLinksResult(listOf("link-1")) }
        assertTrue(transport.deleteStarted.await(2, TimeUnit.SECONDS))

        val fileDeletion = repo.deleteResult(listOf("/share/file-1.txt"))
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, fileDeletion.status)
        assertEquals(MutationErrorCategory.CONFLICT, fileDeletion.errorCategory)
        assertFalse(fileDeletion.submitted)

        transport.allowDelete.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.deleteRequests.get())
    }

    @Test
    fun `删除提交后取消只回读并要求核对且不重放`() = runBlocking {
        val transport = BlockingShareDeleteInterceptor(markDeleted = false)
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.deleteShareLinksResult(listOf("link-1")).status
        }
        assertTrue(transport.deleteStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowDelete.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.deleteRequests.get())
    }

    private fun repository(
        interceptor: Interceptor,
        supportsSharing: Boolean = true,
    ) = authorizedRepository(
        profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        session = DsmSession("test", "test-session", "test-token"),
        api = DsmApiClient(
            OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build(),
        ),
        capabilities = buildList {
            add(ApiCapability("SYNO.FileStation.Delete", "entry.cgi", 1, 2))
            if (supportsSharing) add(ApiCapability("SYNO.FileStation.Sharing", "entry.cgi", 1, 3))
        }.associateBy(ApiCapability::name),
    )
}

private class ScriptedShareDeleteInterceptor(vararg steps: Any) : Interceptor {
    private val pending = ArrayDeque(steps.toList())
    val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val step = pending.removeFirstOrNull() ?: error("缺少合成共享链接删除响应")
        if (step is IOException) throw step
        return shareDeleteResponse(request, step as String)
    }

    fun methods(): List<String?> = requests.map { it.shareDeleteFields()["method"] }
}

private class BlockingShareDeleteInterceptor(
    private val markDeleted: Boolean,
) : Interceptor {
    val deleteStarted = CountDownLatch(1)
    val allowDelete = CountDownLatch(1)
    val deleteRequests = AtomicInteger()
    private val deleted = AtomicBoolean(false)

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val method = request.shareDeleteFields()["method"]
        val body = if (method == "delete") {
            deleteRequests.incrementAndGet()
            deleteStarted.countDown()
            check(allowDelete.await(2, TimeUnit.SECONDS)) { "等待共享链接删除请求超时" }
            if (markDeleted) deleted.set(true)
            success()
        } else {
            if (deleted.get()) links() else links("link-1")
        }
        return shareDeleteResponse(request, body)
    }
}

private fun Request.shareDeleteFields(): Map<String, String> {
    val form = body as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}

private fun shareDeleteResponse(request: Request, body: String) = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun links(vararg ids: String): String {
    val entries = ids.joinToString(",") { id ->
        val suffix = id.substringAfterLast('-')
        """{"id":"$id","name":"file-$suffix.txt","path":"/share/file-$suffix.txt","url":"https://share.example.invalid/$suffix"}"""
    }
    return """{"success":true,"data":{"total":${ids.size},"links":[$entries]}}"""
}

private fun success() = """{"success":true,"data":{}}"""

private fun failure(code: Int) = """{"success":false,"error":{"code":$code}}"""
