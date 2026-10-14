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

class PhotoMoveRepositoryTest {
    @Test
    fun `移动使用公开任务接口且完成后复查源与目标`() = runBlocking {
        val transport = MoveInterceptor(
            fileResponse("/home/Photos/Trips", "Trips", directory = true, writable = true),
            listResponse(0, ""),
            """{"success":true,"data":{"taskid":"synthetic-task"}}""",
            """{"success":true,"data":{"finished":false}}""",
            """{"success":true,"data":{"finished":true}}""",
            listResponse(0, ""),
            listResponse(
                1,
                """{"name":"a.jpg","path":"/home/Photos/Trips/a.jpg","isdir":false}""",
            ),
        )

        val result = repository(transport).moveResult(
            "/home/Photos/a.jpg",
            "/home/Photos/Trips",
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        val start = transport.requests.first { it.formFields()["method"] == "start" }.formFields()
        assertEquals("SYNO.FileStation.CopyMove", start["api"])
        assertEquals("start", start["method"])
        assertEquals("[\"/home/Photos/a.jpg\"]", start["path"])
        assertEquals("/home/Photos/Trips", start["dest_folder_path"])
        assertEquals("true", start["remove_src"])
        assertEquals("false", start["overwrite"])
        assertEquals(1, transport.requests.count { it.formFields()["method"] == "getinfo" })
        assertEquals(3, transport.requests.count { it.formFields()["method"] == "list" })
        assertEquals(2, transport.requests.count { it.formFields()["method"] == "status" })
        assertEquals(
            listOf("/home/Photos", "/home/Photos/Trips"),
            transport.requests.takeLast(2).map { it.formFields()["folder_path"] },
        )
    }

    @Test
    fun `Android 请求层可按公共 Fixture 编码覆盖移动`() = runBlocking {
        val transport = MoveInterceptor("""{"success":true,"data":{"taskid":"synthetic-task"}}""")
        val profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester")
        val session = DsmSession("test", "test-session", "test-token")
        val api = DsmApiClient(OkHttpClient.Builder().addInterceptor(transport).build())

        api.call(
            profile = profile,
            session = session,
            capability = ApiCapability("SYNO.FileStation.CopyMove", "entry.cgi", 1, 3),
            method = "start",
            parameters = mapOf(
                "path" to "[\"/synthetic/source.jpg\"]",
                "dest_folder_path" to "/synthetic/destination",
                "remove_src" to "true",
                "overwrite" to "true",
                "accurate_progress" to "true",
            ),
        )

        RequestFixtureAssertions.assertRequest(
            transport.requests.single(),
            "file-station/move/synthetic-task/request.json",
        )
    }

    @Test
    fun `批量复制拒绝覆盖并复查每个目标`() = runBlocking {
        val transport = MoveInterceptor(
            fileResponse("/share/target", "target", directory = true, writable = true),
            listResponse(0, ""),
            listResponse(0, ""),
            """{"success":true,"data":{"taskid":"copy-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            listResponse(1, """{"name":"a.txt","path":"/share/target/a.txt","isdir":false}"""),
            listResponse(1, """{"name":"b.txt","path":"/share/target/b.txt","isdir":false}"""),
        )

        val result = repository(transport).copyResult(
            listOf("/share/source/a.txt", "/share/source/b.txt"),
            "/share/target",
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(2, result.counts.succeeded)
        val start = transport.requests.first { it.formFields()["method"] == "start" }.formFields()
        assertEquals("false", start["remove_src"])
        assertEquals("false", start["overwrite"])
        assertEquals("[\"/share/source/a.txt\",\"/share/source/b.txt\"]", start["path"])
        assertEquals(7, transport.requests.size)
    }

    @Test
    fun `批量复制提交断线保持未确认且不自动重放`() = runBlocking {
        val transport = StepMoveInterceptor(
            MoveStep.Json(fileResponse("/share/target", "target", directory = true, writable = true)),
            MoveStep.Json(listResponse(0, "")),
            MoveStep.Json(listResponse(0, "")),
            MoveStep.Failure(IOException("synthetic copy disconnect")),
        )

        val result = repository(transport).copyResult(
            listOf("/share/source/a.txt", "/share/source/b.txt"),
            "/share/target",
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(2, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.formFields()["method"] == "start" })
    }

    @Test
    fun `批量复制任务完成但回读失败时保持未确认`() = runBlocking {
        val transport = StepMoveInterceptor(
            MoveStep.Json(fileResponse("/share/target", "target", directory = true, writable = true)),
            MoveStep.Json(listResponse(0, "")),
            MoveStep.Json(listResponse(0, "")),
            MoveStep.Json("""{"success":true,"data":{"taskid":"copy-task"}}"""),
            MoveStep.Json("""{"success":true,"data":{"finished":true}}"""),
            MoveStep.Failure(IOException("synthetic first copy readback failure")),
            MoveStep.Failure(IOException("synthetic second copy readback failure")),
        )

        val result = repository(transport).copyResult(
            listOf("/share/source/a.txt", "/share/source/b.txt"),
            "/share/target",
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(2, result.counts.unknown)
        assertEquals(1, transport.requests.count { it.formFields()["method"] == "start" })
    }

    @Test
    fun `复制提交后的取消只停止任务且不重放`() = runBlocking {
        val transport = BlockingMoveStatusInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.copyResult(listOf("/home/Photos/a.jpg"), "/home/Photos/Trips").status
        }
        assertTrue(transport.statusStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowStatusResponse.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "start" })
        assertEquals(1, transport.methods().count { it == "stop" })
    }

    @Test
    fun `批量复制逐项回读并报告部分成功`() = runBlocking {
        val transport = MoveInterceptor(
            fileResponse("/share/target", "target", directory = true, writable = true),
            listResponse(0, ""),
            listResponse(0, ""),
            """{"success":true,"data":{"taskid":"copy-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            listResponse(1, """{"name":"a.txt","path":"/share/target/a.txt","isdir":false}"""),
            listResponse(0, ""),
        )

        val result = repository(transport).copyResult(
            listOf("/share/source/a.txt", "/share/source/b.txt"),
            "/share/target",
        )

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.failed)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.formFields()["method"] == "start" })
    }

    @Test
    fun `拒绝移动到原目录且不发送请求`() = runBlocking {
        val transport = MoveInterceptor()

        val failure = runCatching {
            repository(transport).move("/home/Photos/a.jpg", "/home/Photos")
        }.exceptionOrNull()

        assertTrue(failure is IllegalArgumentException)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `只读目标在提交前返回权限不足`() = runBlocking {
        val transport = MoveInterceptor(
            fileResponse("/home/Photos/Trips", "Trips", directory = true, writable = false),
        )

        val result = repository(transport).moveResult(
            "/home/Photos/a.jpg",
            "/home/Photos/Trips",
        )

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo"), transport.requests.map { it.formFields()["method"] })
    }

    @Test
    fun `目标存在同名内容时提交前返回冲突`() = runBlocking {
        val transport = MoveInterceptor(
            fileResponse("/home/Photos/Trips", "Trips", directory = true, writable = true),
            listResponse(
                1,
                """{"name":"a.jpg","path":"/home/Photos/Trips/a.jpg","isdir":false}""",
            ),
        )

        val result = repository(transport).moveResult(
            "/home/Photos/a.jpg",
            "/home/Photos/Trips",
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertTrue(transport.requests.none { it.formFields()["method"] == "start" })
    }

    @Test
    fun `移动提交时断线保持未确认且不自动重放`() = runBlocking {
        val transport = StepMoveInterceptor(
            MoveStep.Json(fileResponse("/home/Photos/Trips", "Trips", directory = true, writable = true)),
            MoveStep.Json(listResponse(0, "")),
            MoveStep.Failure(IOException("synthetic move disconnect")),
        )

        val result = repository(transport).moveResult(
            "/home/Photos/a.jpg",
            "/home/Photos/Trips",
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.formFields()["method"] == "start" })
    }

    @Test
    fun `批量移动逐项回读并报告部分成功`() = runBlocking {
        val transport = MoveInterceptor(
            fileResponse("/share/target", "target", directory = true, writable = true),
            listResponse(0, ""),
            listResponse(0, ""),
            """{"success":true,"data":{"taskid":"move-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            listResponse(0, ""),
            listResponse(1, """{"name":"a.txt","path":"/share/target/a.txt","isdir":false}"""),
            listResponse(1, """{"name":"b.txt","path":"/share/source/b.txt","isdir":false}"""),
            listResponse(1, """{"name":"b.txt","path":"/share/target/b.txt","isdir":false}"""),
        )

        val result = repository(transport).moveResult(
            listOf("/share/source/a.txt", "/share/source/b.txt"),
            "/share/target",
        )

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.failed)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.formFields()["method"] == "start" })
    }

    @Test
    fun `移动提交后的取消只停止任务并要求刷新核对`() = runBlocking {
        val transport = BlockingMoveStatusInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.moveResult(
                "/home/Photos/a.jpg",
                "/home/Photos/Trips",
            ).status
        }
        assertTrue(transport.statusStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowStatusResponse.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "start" })
        assertEquals(1, transport.methods().count { it == "stop" })
    }

    @Test
    fun `相同源目标移动进行中时拒绝第二次提交`() = runBlocking {
        val transport = BlockingMoveStartInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) {
            repo.moveResult("/home/Photos/a.jpg", "/home/Photos/Trips")
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.moveResult("/home/Photos/a.jpg", "/home/Photos/Trips")
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)

        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `移动能力不可用时提交前返回不支持`() = runBlocking {
        val transport = MoveInterceptor()

        val result = repository(transport, supportsCopyMove = false).moveResult(
            "/home/Photos/a.jpg",
            "/home/Photos/Trips",
        )

        assertEquals(MutationResultStatus.UNSUPPORTED, result.status)
        assertFalse(result.submitted)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `移动请求明确权限拒绝时不自动重放`() = runBlocking {
        val transport = MoveInterceptor(
            fileResponse("/home/Photos/Trips", "Trips", directory = true, writable = true),
            listResponse(0, ""),
            """{"success":false,"error":{"code":105}}""",
        )

        val result = repository(transport).moveResult(
            "/home/Photos/a.jpg",
            "/home/Photos/Trips",
        )

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertTrue(result.submitted)
        assertEquals(1, transport.requests.count { it.formFields()["method"] == "start" })
    }

    @Test
    fun `移动任务完成但回读失败时保持未确认`() = runBlocking {
        val transport = MoveInterceptor(
            fileResponse("/home/Photos/Trips", "Trips", directory = true, writable = true),
            listResponse(0, ""),
            """{"success":true,"data":{"taskid":"move-task"}}""",
            """{"success":true,"data":{"finished":true}}""",
            """{"success":false,"error":{"code":100}}""",
        )

        val result = repository(transport).moveResult(
            "/home/Photos/a.jpg",
            "/home/Photos/Trips",
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.formFields()["method"] == "start" })
    }

    @Test
    fun `移动提交前协程已取消时不访问网络`() {
        val transport = MoveInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).moveResult(
                    "/home/Photos/a.jpg",
                    "/home/Photos/Trips",
                ).status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    private fun repository(
        interceptor: Interceptor,
        supportsCopyMove: Boolean = true,
    ): DsmRepository = authorizedRepository(
        profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        session = DsmSession("test", "test-session", "test-token"),
        api = DsmApiClient(
            OkHttpClient.Builder()
                .retryOnConnectionFailure(false)
                .addInterceptor(interceptor)
                .build(),
        ),
        capabilities = buildList {
            if (supportsCopyMove) {
                add(ApiCapability("SYNO.FileStation.CopyMove", "entry.cgi", 1, 3))
            }
            add(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2))
        }.associateBy(ApiCapability::name),
    )

    private fun listResponse(total: Int, files: String): String =
        """{"success":true,"data":{"offset":0,"total":$total,"files":[$files]}}"""

    private fun fileResponse(path: String, name: String, directory: Boolean, writable: Boolean) =
        """{"success":true,"data":{"files":[{"name":"$name","path":"$path","isdir":$directory,"additional":{"perm":{"write":$writable}}}]}}"""
}

private class MoveInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = pending.removeFirstOrNull() ?: error("缺少合成移动响应")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}

private sealed interface MoveStep {
    data class Json(val body: String) : MoveStep
    data class Failure(val error: IOException) : MoveStep
}

private class StepMoveInterceptor(vararg steps: MoveStep) : Interceptor {
    private val pending = ArrayDeque(steps.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return when (val step = pending.removeFirstOrNull() ?: error("缺少合成移动步骤")) {
            is MoveStep.Failure -> throw step.error
            is MoveStep.Json -> Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(step.body.toResponseBody("application/json".toMediaType()))
                .build()
        }
    }
}

private class BlockingMoveStatusInterceptor : Interceptor {
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
            1 -> destinationFolderResponse()
            2 -> emptyFileListResponse()
            3 -> """{"success":true,"data":{"taskid":"move-task"}}"""
            4 -> {
                statusStarted.countDown()
                check(allowStatusResponse.await(2, TimeUnit.SECONDS)) {
                    "等待合成移动状态请求放行超时"
                }
                """{"success":true,"data":{"finished":false}}"""
            }
            else -> """{"success":true,"data":{}}"""
        }
        return moveResponse(request, body)
    }

    fun methods(): List<String?> = synchronized(requests) {
        requests.map { it.formFields()["method"] }
    }
}

private class BlockingMoveStartInterceptor : Interceptor {
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
            1 -> destinationFolderResponse()
            2 -> emptyFileListResponse()
            3 -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) {
                    "等待合成移动请求放行超时"
                }
                """{"success":true,"data":{"taskid":"move-task"}}"""
            }
            4 -> """{"success":true,"data":{"finished":true}}"""
            5 -> emptyFileListResponse()
            else -> """{"success":true,"data":{"offset":0,"total":1,"files":[{"name":"a.jpg","path":"/home/Photos/Trips/a.jpg","isdir":false}]}}"""
        }
        return moveResponse(request, body)
    }

    fun methods(): List<String?> = synchronized(requests) {
        requests.map { it.formFields()["method"] }
    }
}

private fun destinationFolderResponse() =
    """{"success":true,"data":{"files":[{"name":"Trips","path":"/home/Photos/Trips","isdir":true,"additional":{"perm":{"write":true}}}]}}"""

private fun emptyFileListResponse() =
    """{"success":true,"data":{"offset":0,"total":0,"files":[]}}"""

private fun moveResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.formFields(): Map<String, String> {
    val form = body as FormBody
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
