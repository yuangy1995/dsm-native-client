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

class FileDeleteResultTest {
    @Test
    fun `删除任务完成并逐项回读不存在才确认成功`() = runBlocking {
        val transport = DeleteInterceptor(
            """{"success":true,"data":{"taskid":"delete-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            """{"success":true,"data":{"files":[]}}""",
        )

        val result = repository(transport).deleteResult(listOf("/home/docs/a.txt"))

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertFalse(result.requiresRefresh)
        assertEquals(listOf("start", "status", "getinfo"), transport.methods())
        RequestFixtureAssertions.assertRequest(
            transport.requests.first(),
            "file-station/delete/synthetic-task/request.json",
        )
        val start = transport.requests.first().formFieldsForDelete()
        assertEquals("true", start["accurate_progress"])
    }

    @Test
    fun `删除完成但回读仍存在时明确失败并要求刷新`() = runBlocking {
        val transport = DeleteInterceptor(
            """{"success":true,"data":{"taskid":"delete-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            """{"success":true,"data":{"files":[{"name":"a.txt","path":"/home/docs/a.txt","isdir":false}]}}""",
        )

        val result = repository(transport).deleteResult(listOf("/home/docs/a.txt"))

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(1, result.counts.failed)
        assertEquals(true, result.requiresRefresh)
    }

    @Test
    fun `非法目标在提交前失败且不访问网络`() = runBlocking {
        val transport = DeleteInterceptor()

        val result = repository(transport).deleteResult(listOf("/"))

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.VALIDATION, result.errorCategory)
        assertFalse(result.submitted)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `删除能力不可用时不发送请求`() = runBlocking {
        val transport = DeleteInterceptor()

        val result = repository(transport, supportsDelete = false)
            .deleteResult(listOf("/home/docs/a.txt"))

        assertEquals(MutationResultStatus.UNSUPPORTED, result.status)
        assertFalse(result.submitted)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `删除明确权限拒绝时不自动重放`() = runBlocking {
        val transport = DeleteInterceptor(
            """{"success":false,"error":{"code":105}}""",
        )

        val result = repository(transport).deleteResult(listOf("/home/docs/a.txt"))

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertTrue(result.submitted)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `提交时断线只报告未确认且不自动重放`() = runBlocking {
        val transport = DisconnectingDeleteInterceptor()

        val result = repository(transport).deleteResult(listOf("/home/docs/a.txt"))

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
        assertEquals(listOf("start", "getinfo"), transport.methods())
    }

    @Test
    fun `部分目标删除后逐项回读并报告部分成功`() = runBlocking {
        val transport = DeleteInterceptor(
            """{"success":true,"data":{"taskid":"delete-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            """{"success":true,"data":{"files":[]}}""",
            """{"success":true,"data":{"files":[{"name":"b.txt","path":"/home/docs/b.txt","isdir":false}]}}""",
        )

        val result = repository(transport).deleteResult(
            listOf("/home/docs/a.txt", "/home/docs/b.txt"),
        )

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.failed)
        assertTrue(result.requiresRefresh)
        assertEquals(listOf("start", "status", "getinfo", "getinfo"), transport.methods())
    }

    @Test
    fun `删除完成但回读失败时保持未确认且不再次删除`() = runBlocking {
        val transport = DeleteInterceptor(
            """{"success":true,"data":{"taskid":"delete-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            """{"success":false,"error":{"code":100}}""",
        )

        val result = repository(transport).deleteResult(listOf("/home/docs/a.txt"))

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `任务状态读取失败但目标均消失时确认成功且不重放`() = runBlocking {
        val transport = DeleteInterceptor(
            """{"success":true,"data":{"taskid":"delete-task"}}""",
            """{"success":false,"error":{"code":100}}""",
            """{"success":true,"data":{"files":[]}}""",
        )

        val result = repository(transport).deleteResult(listOf("/home/docs/a.txt"))

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertFalse(result.requiresRefresh)
        assertEquals(listOf("start", "status", "getinfo"), transport.methods())
    }

    @Test
    fun `任务状态读取失败后逐项回读保留部分成功与未知计数`() = runBlocking {
        val transport = DeleteInterceptor(
            """{"success":true,"data":{"taskid":"delete-task"}}""",
            """{"success":false,"error":{"code":100}}""",
            """{"success":true,"data":{"files":[]}}""",
            """{"success":false,"error":{"code":100}}""",
        )

        val result = repository(transport).deleteResult(
            listOf("/home/docs/a.txt", "/home/docs/b.txt"),
        )

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `提交前协程已取消时不发送请求`() {
        val transport = DeleteInterceptor()
        var status: MutationResultStatus? = null
        val job = Job()

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).deleteResult(listOf("/home/docs/a.txt")).status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `提交后的取消只报告需要核对且不重放`() = runBlocking {
        val transport = BlockingStatusDeleteInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.deleteResult(listOf("/home/docs/a.txt")).status
        }
        assertTrue(transport.statusStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowStatusResponse.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `启动请求往返期间取消按提交后处理且不重放`() = runBlocking {
        val transport = BlockingDeleteInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.deleteResult(listOf("/home/docs/a.txt")).status
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowSubmission.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `写后回读期间取消保留提交边界且不重放`() = runBlocking {
        val transport = BlockingReadbackDeleteInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.deleteResult(listOf("/home/docs/a.txt")).status
        }
        assertTrue(transport.readbackStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowReadback.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `父目录删除进行中时拒绝子路径重复提交`() = runBlocking {
        val transport = BlockingDeleteInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) {
            repo.deleteResult(listOf("/home/docs"))
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.deleteResult(listOf("/home/docs/a.txt"))
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)

        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    private fun repository(
        interceptor: Interceptor,
        supportsDelete: Boolean = true,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        buildList {
            if (supportsDelete) add(ApiCapability("SYNO.FileStation.Delete", "entry.cgi", 1, 2))
            add(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2))
        }.associateBy(ApiCapability::name),
    )
}

private class DeleteInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
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
                (pending.removeFirstOrNull() ?: error("缺少合成删除响应"))
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }

    fun methods() = requests.map { it.formFieldsForDelete()["method"] }
}

private class DisconnectingDeleteInterceptor : Interceptor {
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        requests += chain.request()
        throw IOException("synthetic delete disconnect")
    }

    fun methods() = requests.map { it.formFieldsForDelete()["method"] }
}

private class BlockingStatusDeleteInterceptor : Interceptor {
    val statusStarted = CountDownLatch(1)
    val allowStatusResponse = CountDownLatch(1)
    private val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val index = synchronized(requests) {
            requests += request
            requests.size
        }
        val body = when (index) {
            1 -> """{"success":true,"data":{"taskid":"delete-task"}}"""
            2 -> {
                statusStarted.countDown()
                check(allowStatusResponse.await(2, TimeUnit.SECONDS)) {
                    "等待合成删除状态请求放行超时"
                }
                """{"success":true,"data":{"finished":false}}"""
            }
            else -> """{"success":true,"data":{"files":[]}}"""
        }
        return deleteResponse(request, body)
    }

    fun methods(): List<String?> = synchronized(requests) {
        requests.map { it.formFieldsForDelete()["method"] }
    }
}

private class BlockingDeleteInterceptor : Interceptor {
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
            1 -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待合成删除请求放行超时" }
                """{"success":true,"data":{"taskid":"delete-task"}}"""
            }
            2 -> """{"success":true,"data":{"finished":true}}"""
            else -> """{"success":true,"data":{"files":[]}}"""
        }
        return deleteResponse(request, body)
    }

    fun methods(): List<String?> = synchronized(requests) {
        requests.map { it.formFieldsForDelete()["method"] }
    }
}

private class BlockingReadbackDeleteInterceptor : Interceptor {
    val readbackStarted = CountDownLatch(1)
    val allowReadback = CountDownLatch(1)
    private val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val index = synchronized(requests) {
            requests += request
            requests.size
        }
        val body = when (index) {
            1 -> """{"success":true,"data":{"taskid":"delete-task"}}"""
            2 -> """{"success":true,"data":{"finished":true}}"""
            else -> {
                readbackStarted.countDown()
                check(allowReadback.await(2, TimeUnit.SECONDS)) { "等待删除回读放行超时" }
                """{"success":true,"data":{"files":[]}}"""
            }
        }
        return deleteResponse(request, body)
    }

    fun methods(): List<String?> = synchronized(requests) {
        requests.map { it.formFieldsForDelete()["method"] }
    }
}

private fun deleteResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.formFieldsForDelete(): Map<String, String> {
    val form = body as? okhttp3.FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
