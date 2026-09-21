package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.ByteArrayInputStream
import java.io.IOException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadCreationResultTest {
    @Test
    fun `未指定目录的链接固定使用v1且兼容仅有v1的服务`() = runBlocking {
        for (maxVersion in listOf(1, 3)) {
            val transport = ScriptedDownloadCreationInterceptor(
                emptyTaskList(), success("""{"taskid":"task-1"}"""), taskList("task-1"),
            )
            val result = repository(transport, taskMaxVersion = maxVersion)
                .createDownloadResult("https://example.invalid/synthetic.iso", "  ")

            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
            val form = transport.requests.single { it.downloadMethod() == "create" }.body as FormBody
            assertEquals("1", (0 until form.size).first { form.name(it) == "version" }.let(form::value))
            assertFalse((0 until form.size).any { form.name(it) == "destination" })
        }
    }

    @Test
    fun `仅有v1时指定目录的链接在任何请求之前拒绝`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor()
        val result = repository(transport, taskMaxVersion = 1)
            .createDownloadResult("https://example.invalid/synthetic.iso", "/downloads")

        assertEquals(MutationResultStatus.UNSUPPORTED, result.status)
        assertFalse(result.submitted)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `不包含所需版本的链接能力不回退到其他版本`() = runBlocking {
        for (destination in listOf(null, "/downloads")) {
            val transport = ScriptedDownloadCreationInterceptor()
            val result = repository(transport, taskMinVersion = 3)
                .createDownloadResult("https://example.invalid/synthetic.iso", destination)

            assertEquals(MutationResultStatus.UNSUPPORTED, result.status)
            assertFalse(result.submitted)
            assertTrue(transport.requests.isEmpty())
        }
    }

    @Test
    fun `任务文件无目录固定v1并保留指定目录的v2规则`() = runBlocking {
        for (destination in listOf(null, "/downloads")) {
            val steps = buildList {
                if (destination != null) add(writableDestination(destination))
                add(emptyTaskList())
                add(success("""{"taskid":"task-1"}"""))
                add(taskList("task-1"))
            }
            val transport = ScriptedDownloadCreationInterceptor(*steps.toTypedArray())
            val result = repository(transport).createDownloadFromFileResult(
                taskFileSource("synthetic".encodeToByteArray()), destination,
            )

            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
            val request = transport.requests.single { it.body is MultipartBody }
            assertEquals(if (destination == null) "1" else "2", request.url.queryParameter("version"))
            assertEquals(1, transport.methods().count { it == "create" })
        }
    }

    @Test
    fun `任务文件不支持所需版本时不读取文件或发送请求`() = runBlocking {
        for ((minimum, maximum, destination) in listOf(
            Triple(1, 1, "/downloads"), Triple(3, 3, null), Triple(3, 3, "/downloads"),
        )) {
            val transport = ScriptedDownloadCreationInterceptor()
            val source = UploadSource(
                displayName = "synthetic.torrent", contentType = "application/x-bittorrent",
                contentLength = 1, openInputStream = { error("版本不支持时不得打开任务文件") },
            )
            val result = repository(transport, taskMinVersion = minimum, taskMaxVersion = maximum)
                .createDownloadFromFileResult(source, destination)

            assertEquals(MutationResultStatus.UNSUPPORTED, result.status)
            assertFalse(result.submitted)
            assertTrue(transport.requests.isEmpty())
        }
    }

    @Test
    fun `链接任务只在新任务回读后确认且请求符合公共契约`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            writableDestination("/downloads"),
            emptyTaskList(),
            success("""{"taskid":"task-1"}"""),
            taskList("task-1"),
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            "/downloads",
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertFalse(result.requiresRefresh)
        assertEquals(listOf("getinfo", "list", "create", "list"), transport.methods())
        assertEquals(1, transport.methods().count { it == "create" })
        RequestFixtureAssertions.assertRequest(
            transport.requests[2],
            "download-station/create/synthetic-link/request.json",
        )
    }

    @Test
    fun `非法链接和不支持能力均在提交前失败`() = runBlocking {
        val invalidTransport = ScriptedDownloadCreationInterceptor()
        val invalid = repository(invalidTransport).createDownloadResult("file:///private/file", null)
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, invalid.status)
        assertEquals(MutationErrorCategory.VALIDATION, invalid.errorCategory)
        assertFalse(invalid.submitted)
        assertTrue(invalidTransport.requests.isEmpty())

        val unsupportedTransport = ScriptedDownloadCreationInterceptor()
        val unsupported = repository(unsupportedTransport, supportsTask = false)
            .createDownloadResult("magnet:?xt=urn:btih:synthetic", null)
        assertEquals(MutationResultStatus.UNSUPPORTED, unsupported.status)
        assertFalse(unsupported.submitted)
        assertTrue(unsupportedTransport.requests.isEmpty())
    }

    @Test
    fun `链接提交断线后不把其他新任务归属给本请求且不重放`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            IOException("synthetic disconnect"),
            taskList("task-1"),
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            null,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(listOf("list", "create", "list"), transport.methods())
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `成功响应缺少稳定任务ID时严格回读也不猜测归属`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            success("{}"),
            taskList("unrelated-task"),
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            null,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(listOf("list", "create", "list"), transport.methods())
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `服务端返回的任务ID未出现时保持已提交但未确认`() = runBlocking {
        val readbacks = Array(8) { emptyTaskList() }
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            success("""{"taskid":"expected-task"}"""),
            *readbacks,
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            null,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(0, result.counts.failed)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `稳定任务ID去除首尾空白后严格回读可确认`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            success("""{"taskid":"  task-1  "}"""),
            taskList("task-1"),
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            null,
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
    }

    @Test
    fun `任务ID匹配但回读目标目录不同时不确认成功`() = runBlocking {
        val readbacks = Array(8) { taskListWithDestination("task-1", "/other") }
        val transport = ScriptedDownloadCreationInterceptor(
            writableDestination("/downloads"),
            emptyTaskList(),
            success("""{"taskid":"task-1"}"""),
            *readbacks,
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            "/downloads",
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `创建前严格列表响应缺少tasks时失败关闭且不提交`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(success("{}"))

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            null,
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted)
        assertEquals(listOf("list"), transport.methods())
        assertEquals(0, transport.methods().count { it == "create" })
    }

    @Test
    fun `链接提交断线且回读无新任务时保持未确认`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            IOException("synthetic disconnect"),
            emptyTaskList(),
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            null,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `链接创建权限拒绝不重放也不冒充成功`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            """{"success":false,"error":{"code":105}}""",
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            null,
        )

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertEquals(listOf("list", "create"), transport.methods())
    }

    @Test
    fun `只读目标目录在创建请求前拒绝`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            readOnlyDestination("/downloads"),
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            "/downloads",
        )

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo"), transport.methods())
    }

    @Test
    fun `链接创建响应成功但回读失败时保持未确认`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            success("""{"taskid":"task-1"}"""),
            IOException("synthetic readback failure"),
        )

        val result = repository(transport).createDownloadResult(
            "https://example.invalid/synthetic.iso",
            null,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `同一链接创建进行中时拒绝重复提交`() = runBlocking {
        val transport = BlockingDownloadCreationInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) {
            repo.createDownloadResult("https://example.invalid/synthetic.iso", null)
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))
        val activeKeys = DsmRepository::class.java
            .getDeclaredField("activeDownloadCreationKeys")
            .apply { isAccessible = true }
            .get(repo) as Set<*>
        val activeKey = activeKeys.single() as String
        assertEquals(64, activeKey.length)
        assertTrue(activeKey.all { it in '0'..'9' || it in 'a'..'f' })
        assertFalse(activeKey.contains("example.invalid"))
        assertFalse(activeKey.contains("synthetic.iso"))

        val duplicate = repo.createDownloadResult("https://example.invalid/synthetic.iso", null)
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)

        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `链接创建提交前协程取消时不访问网络`() {
        val transport = ScriptedDownloadCreationInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport)
                    .createDownloadResult("https://example.invalid/synthetic.iso", null)
                    .status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `链接创建提交后的取消只要求核对且不重放`() = runBlocking {
        val transport = BlockingDownloadCreationInterceptor(readbackTaskId = null)
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.createDownloadResult("https://example.invalid/synthetic.iso", null).status
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowSubmission.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `任务文件提交断线只回读不猜测归属且不再次上传`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            IOException("synthetic upload disconnect"),
            taskList("task-file-1"),
        )
        val bytes = "d4:infod4:name4:testee".encodeToByteArray()

        val result = repository(transport).createDownloadFromFileResult(
            UploadSource(
                displayName = "synthetic.torrent",
                contentType = "application/x-bittorrent",
                contentLength = bytes.size.toLong(),
                openInputStream = { ByteArrayInputStream(bytes) },
            ),
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(listOf("list", "create", "list"), transport.methods())
        assertEquals(1, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `任务文件只在稳定任务回读后确认成功且只上传一次`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            success("""{"taskid":"task-file-1"}"""),
            taskList("task-file-1"),
        )
        val bytes = "d4:infod4:name4:testee".encodeToByteArray()

        val result = repository(transport).createDownloadFromFileResult(
            taskFileSource(bytes),
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertFalse(result.requiresRefresh)
        assertEquals(listOf("list", "create", "list"), transport.methods())
        assertEquals(1, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `任务文件上传成功但回读失败时保持未确认且不再次上传`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor(
            emptyTaskList(),
            success("""{"taskid":"task-file-1"}"""),
            IOException("synthetic file task readback failure"),
        )
        val bytes = "d4:infod4:name4:testee".encodeToByteArray()

        val result = repository(transport).createDownloadFromFileResult(
            taskFileSource(bytes),
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `任务文件提交后的取消只要求核对且不再次上传`() = runBlocking {
        val transport = BlockingDownloadCreationInterceptor(readbackTaskId = null)
        val repo = repository(transport)
        val bytes = "d4:infod4:name4:testee".encodeToByteArray()
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.createDownloadFromFileResult(taskFileSource(bytes)).status
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowSubmission.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `同名同大小的不同任务文件不会被误判为重复提交`() = runBlocking {
        val transport = ConcurrentFileCreationInterceptor()
        val repo = repository(transport)
        val bytes = "d4:infod4:name4:testee".encodeToByteArray()
        fun source(token: String) = UploadSource(
            displayName = "synthetic.torrent",
            contentType = "application/x-bittorrent",
            contentLength = bytes.size.toLong(),
            openInputStream = { ByteArrayInputStream(bytes) },
            requestToken = token,
        )

        val first = async(Dispatchers.IO) { repo.createDownloadFromFileResult(source("request-a")) }
        val second = async(Dispatchers.IO) { repo.createDownloadFromFileResult(source("request-b")) }
        assertTrue(transport.submissionsStarted.await(2, TimeUnit.SECONDS))
        transport.allowSubmissions.countDown()

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, second.await().status)
        assertEquals(2, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `同一任务文件请求进行中仍由Repository拒绝重复上传`() = runBlocking {
        val transport = BlockingDownloadCreationInterceptor()
        val repo = repository(transport)
        val bytes = "d4:infod4:name4:testee".encodeToByteArray()
        val source = UploadSource(
            displayName = "synthetic.torrent",
            contentType = "application/x-bittorrent",
            contentLength = bytes.size.toLong(),
            openInputStream = { ByteArrayInputStream(bytes) },
            requestToken = "same-request",
        )
        val first = async(Dispatchers.IO) { repo.createDownloadFromFileResult(source) }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.createDownloadFromFileResult(source)
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)

        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `非法任务文件在上传前失败`() = runBlocking {
        val transport = ScriptedDownloadCreationInterceptor()

        val result = repository(transport).createDownloadFromFileResult(
            UploadSource(
                displayName = "synthetic.exe",
                contentType = "application/octet-stream",
                contentLength = 1,
                openInputStream = { ByteArrayInputStream(byteArrayOf(0)) },
            ),
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.VALIDATION, result.errorCategory)
        assertFalse(result.submitted)
        assertTrue(transport.requests.isEmpty())

        val emptyFile = repository(transport).createDownloadFromFileResult(
            UploadSource(
                displayName = "empty.torrent",
                contentType = "application/x-bittorrent",
                contentLength = 0,
                openInputStream = { ByteArrayInputStream(byteArrayOf()) },
            ),
        )
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, emptyFile.status)
        assertEquals(MutationErrorCategory.VALIDATION, emptyFile.errorCategory)
        assertFalse(emptyFile.submitted)
        assertTrue(transport.requests.isEmpty())
    }

    private fun repository(
        interceptor: Interceptor,
        supportsTask: Boolean = true,
        taskMinVersion: Int = 1,
        taskMaxVersion: Int = 3,
    ) = DsmRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(
            OkHttpClient.Builder()
                .retryOnConnectionFailure(false)
                .addInterceptor(interceptor)
                .build(),
        ),
        if (supportsTask) {
            mapOf(
                "SYNO.DownloadStation.Task" to ApiCapability(
                    "SYNO.DownloadStation.Task",
                    "entry.cgi",
                    taskMinVersion,
                    taskMaxVersion,
                ),
                "SYNO.FileStation.List" to ApiCapability(
                    "SYNO.FileStation.List",
                    "entry.cgi",
                    1,
                    2,
                ),
            )
        } else {
            emptyMap()
        },
    )

    private fun taskFileSource(bytes: ByteArray) = UploadSource(
        displayName = "synthetic.torrent",
        contentType = "application/x-bittorrent",
        contentLength = bytes.size.toLong(),
        openInputStream = { ByteArrayInputStream(bytes) },
        requestToken = "matrix-request",
    )
}

private class ScriptedDownloadCreationInterceptor(vararg steps: Any) : Interceptor {
    private val pending = ArrayDeque(steps.toList())
    val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val step = synchronized(pending) {
            pending.removeFirstOrNull() ?: error("缺少合成下载创建响应")
        }
        if (step is IOException) throw step
        return response(request, step as String)
    }

    fun methods(): List<String?> = requests.map(Request::downloadMethod)
}

private class BlockingDownloadCreationInterceptor(
    private val readbackTaskId: String? = "task-1",
) : Interceptor {
    val submissionStarted = CountDownLatch(1)
    val allowSubmission = CountDownLatch(1)
    val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())
    private val requestIndex = AtomicInteger()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = when (requestIndex.getAndIncrement()) {
            0 -> emptyTaskList()
            1 -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待创建请求超时" }
                success("""{"taskid":"task-1"}""")
            }
            else -> readbackTaskId?.let(::taskList) ?: emptyTaskList()
        }
        return response(request, body)
    }

    fun methods(): List<String?> = requests.map(Request::downloadMethod)
}

private class ConcurrentFileCreationInterceptor : Interceptor {
    val submissionsStarted = CountDownLatch(2)
    val allowSubmissions = CountDownLatch(1)
    val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())
    private val created = AtomicInteger()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = if (request.downloadMethod() == "create") {
            val id = created.incrementAndGet()
            submissionsStarted.countDown()
            check(allowSubmissions.await(2, TimeUnit.SECONDS)) { "等待任务文件创建请求超时" }
            success("""{"taskid":"task-$id"}""")
        } else {
            when (created.get()) {
                0 -> emptyTaskList()
                1 -> taskList("task-1")
                else -> taskListOf("task-1", "task-2")
            }
        }
        return response(request, body)
    }
}

private fun Request.downloadMethod(): String? {
    val form = body as? FormBody
    if (form != null) {
        return (0 until form.size).firstNotNullOfOrNull { index ->
            form.value(index).takeIf { form.name(index) == "method" }
        }
    }
    return url.queryParameter("method")
}

private fun response(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun emptyTaskList() = """{"success":true,"data":{"tasks":[]}}"""

private fun writableDestination(path: String) = destination(path, canWrite = true)

private fun readOnlyDestination(path: String) = destination(path, canWrite = false)

private fun destination(path: String, canWrite: Boolean) =
    """{"success":true,"data":{"files":[{"path":"$path","name":"downloads","isdir":true,"additional":{"perm":{"read":true,"write":$canWrite,"delete":false}}}]}}"""

private fun taskList(id: String) = taskListOf(id)

private fun taskListOf(vararg ids: String): String {
    val tasks = ids.joinToString(",") { id ->
        """{"id":"$id","type":"bt","title":"Synthetic","status":"waiting"}"""
    }
    return """{"success":true,"data":{"tasks":[$tasks]}}"""
}

private fun taskListWithDestination(id: String, destination: String) =
    """{"success":true,"data":{"tasks":[{"id":"$id","type":"bt","title":"Synthetic","status":"waiting","additional":{"detail":{"destination":"$destination"}}}]}}"""

private fun success(data: String) = """{"success":true,"data":$data}"""
