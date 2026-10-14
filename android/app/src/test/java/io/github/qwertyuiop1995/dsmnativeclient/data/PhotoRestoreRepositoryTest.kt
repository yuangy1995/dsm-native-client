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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoRestoreRepositoryTest {
    @Test
    fun `恢复前检查原目录权限和冲突并在移动后复查`() = runBlocking {
        val transport = RestoreInterceptor(
            fileResponse("/photos/旅行", "旅行", true, true),
            listResponse("/photos/旅行", 0, ""),
            """{"success":true,"data":{"taskid":"restore-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            listResponse("/photos/#recycle/旅行", 0, ""),
            listResponse(
                "/photos/旅行",
                1,
                """{"name":"海边.jpg","path":"/photos/旅行/海边.jpg","isdir":false}""",
            ),
        )

        val result = repository(transport).restoreFromRecycleResult("/photos/#recycle/旅行/海边.jpg")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals("fileRestore", result.operation)
        assertEquals(
            listOf("getinfo", "list", "start", "status", "list", "list"),
            transport.requests.map { request ->
                val body = request.body as okhttp3.FormBody
                (0 until body.size).associate { body.name(it) to body.value(it) }["method"]
            },
        )
    }

    @Test
    fun `原位置存在同名项目时不提交恢复`() = runBlocking {
        val transport = RestoreInterceptor(
            fileResponse("/photos/旅行", "旅行", true, true),
            listResponse(
                "/photos/旅行",
                1,
                """{"name":"海边.jpg","path":"/photos/旅行/海边.jpg","isdir":false}""",
            ),
        )

        val result = repository(transport)
            .restoreFromRecycleResult("/photos/#recycle/旅行/海边.jpg")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertTrue(!result.submitted)
        assertEquals(2, transport.requests.size)
    }

    @Test
    fun `原目录只读时提交前返回权限不足`() = runBlocking {
        val transport = RestoreInterceptor(fileResponse("/photos/旅行", "旅行", true, false))

        val result = repository(transport)
            .restoreFromRecycleResult("/photos/#recycle/旅行/海边.jpg")

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertTrue(!result.submitted)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `恢复提交断线保持未确认且不自动重放`() = runBlocking {
        val transport = FailingRestoreInterceptor(
            fileResponse("/photos/旅行", "旅行", true, true),
            listResponse("/photos/旅行", 0, ""),
        )

        val result = repository(transport)
            .restoreFromRecycleResult("/photos/#recycle/旅行/海边.jpg")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
        assertTrue(result.submitted)
        assertEquals(1, transport.requests.count { request ->
            val body = request.body as okhttp3.FormBody
            (0 until body.size).any { body.name(it) == "method" && body.value(it) == "start" }
        })
    }

    @Test
    fun `恢复任务完成但回读失败时保持未确认且不重放`() = runBlocking {
        val transport = RestoreInterceptor(
            fileResponse("/photos/旅行", "旅行", true, true),
            listResponse("/photos/旅行", 0, ""),
            """{"success":true,"data":{"taskid":"restore-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            """{"success":false,"error":{"code":100}}""",
        )

        val result = repository(transport)
            .restoreFromRecycleResult("/photos/#recycle/旅行/海边.jpg")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.restoreMethod() == "start" })
    }

    @Test
    fun `恢复提交后的取消只停止任务且不重放`() = runBlocking {
        val transport = BlockingRestoreStatusInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.restoreFromRecycleResult("/photos/#recycle/旅行/海边.jpg").status
        }
        assertTrue(transport.statusStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowStatus.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "start" })
        assertEquals(1, transport.methods().count { it == "stop" })
    }

    @Test
    fun `恢复路径或能力无效时零请求拒绝`() = runBlocking {
        val invalidTransport = RestoreInterceptor()
        val invalid = repository(invalidTransport).restoreFromRecycleResult("/photos/海边.jpg")
        val unsupportedTransport = RestoreInterceptor()
        val unsupported = repository(unsupportedTransport, supportsCopyMove = false)
            .restoreFromRecycleResult("/photos/#recycle/旅行/海边.jpg")

        assertEquals(MutationErrorCategory.VALIDATION, invalid.errorCategory)
        assertEquals(MutationResultStatus.UNSUPPORTED, unsupported.status)
        assertTrue(invalidTransport.requests.isEmpty())
        assertTrue(unsupportedTransport.requests.isEmpty())
    }

    @Test
    fun `恢复提交前协程取消时不访问网络`() {
        val transport = RestoreInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport)
                    .restoreFromRecycleResult("/photos/#recycle/旅行/海边.jpg")
                    .status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    private fun repository(interceptor: Interceptor, supportsCopyMove: Boolean = true) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build()),
        buildList {
            if (supportsCopyMove) add(ApiCapability("SYNO.FileStation.CopyMove", "entry.cgi", 1, 3))
            add(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2))
        }.associateBy(ApiCapability::name),
    )

    private fun fileResponse(path: String, name: String, directory: Boolean, writable: Boolean) =
        """{"success":true,"data":{"files":[{"name":"$name","path":"$path","isdir":$directory,"additional":{"perm":{"write":$writable}}}]}}"""

    private fun listResponse(path: String, total: Int, files: String) =
        """{"success":true,"data":{"offset":0,"total":$total,"files":[$files],"folder_path":"$path"}}"""
}

private class FailingRestoreInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = pending.removeFirstOrNull() ?: throw IOException("synthetic restore disconnect")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}

private class RestoreInterceptor(vararg responses: String) : Interceptor {
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
                (pending.removeFirstOrNull() ?: error("缺少合成恢复响应"))
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private class BlockingRestoreStatusInterceptor : Interceptor {
    val statusStarted = CountDownLatch(1)
    val allowStatus = CountDownLatch(1)
    private val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val method = request.restoreMethod()
        val body = when (method) {
            "getinfo" -> """{"success":true,"data":{"files":[{"name":"旅行","path":"/photos/旅行","isdir":true,"additional":{"perm":{"write":true}}}]}}"""
            "list" -> """{"success":true,"data":{"offset":0,"total":0,"files":[]}}"""
            "start" -> """{"success":true,"data":{"taskid":"restore-task"}}"""
            "status" -> {
                statusStarted.countDown()
                check(allowStatus.await(2, TimeUnit.SECONDS)) { "等待恢复状态响应超时" }
                """{"success":true,"data":{"finished":false}}"""
            }
            "stop" -> """{"success":true,"data":{}}"""
            else -> error("未处理的恢复方法：$method")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods(): List<String?> = requests.map(Request::restoreMethod)
}

private fun Request.restoreMethod(): String? {
    val form = body as? okhttp3.FormBody ?: return null
    return (0 until form.size).firstNotNullOfOrNull { index ->
        form.value(index).takeIf { form.name(index) == "method" }
    }
}
