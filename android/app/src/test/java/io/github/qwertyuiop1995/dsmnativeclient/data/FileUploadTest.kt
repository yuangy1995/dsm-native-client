package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.ByteArrayInputStream
import java.io.IOException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileUploadTest {
    @Test
    fun `Office提交前检查在写权限后执行且失败释放同路径写锁`() = runBlocking {
        val transport = UploadRecordingInterceptor("{\"success\":true}", "{\"success\":true}",
            "{\"success\":true}", uploadedFileResponse(17))
        val repo = repository(transport)
        val rejected = runCatching { repo.uploadOfficeResult(source(SYNTHETIC_BYTES), "/share", {
            assertEquals(listOf("write"), transport.requests.map(::method))
            throw io.github.qwertyuiop1995.dsmnativeclient.data.files.officeChanged()
        }, { _, _ -> }) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.OFFICE_CHANGED, rejected.kind)
        assertTrue(transport.multipartBodies.isEmpty())
        var checked = 0
        val result = repo.uploadOfficeResult(source(SYNTHETIC_BYTES), "/share", { checked++ }, { _, _ -> })
        assertEquals(1, checked); assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf("write", "write", "upload", "getinfo"), transport.requests.map(::method))
    }

    @Test
    fun `上传请求符合公共Fixture且写后大小回读一致`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            "{\"success\":true}",
            "{\"success\":true}",
            "{\"success\":true,\"data\":{\"files\":[" +
                "{\"path\":\"/share/synthetic.bin\",\"name\":\"synthetic.bin\"," +
                "\"isdir\":false,\"size\":17}]}}",
        )
        val progress = mutableListOf<Pair<Long, Long>>()

        repository(transport).upload(
            source = source(SYNTHETIC_BYTES),
            destinationPath = "/share",
            overwrite = true,
            onProgress = { completed, total -> progress += completed to total },
        )

        assertEquals(listOf("write", "upload", "getinfo"), transport.requests.map(::method))
        assertEquals(17L to 17L, progress.last())
        val upload = transport.requests[1]
        val multipart = upload.body as MultipartBody
        val body = transport.multipartBodies.single().readUtf8()
        RequestFixtureAssertions.assertRequest(
            upload,
            "file-station/upload/synthetic-overwrite/request.json",
        )
        assertEquals("2", upload.url.queryParameter("version"))
        assertEquals(setOf("api", "version", "method"), upload.url.queryParameterNames)
        assertFalse(upload.url.toString().contains("test-session"))
        assertFalse(upload.url.toString().contains("test-token"))
        assertEquals("test-session", multipartValue(upload.body as MultipartBody, "_sid"))
        assertEquals("test-token", multipartValue(upload.body as MultipartBody, "SynoToken"))
        assertEquals("id=test-session", upload.header("Cookie"))
        assertEquals("test-token", upload.header("X-SYNO-TOKEN"))
        assertEquals(multipart.contentLength().toString(), upload.header("Content-Length"))
        assertTrue(multipart.contentType().toString().startsWith("multipart/form-data"))

        val filePart = body.indexOf("name=\"file\"")
        assertTrue(filePart > body.indexOf("name=\"overwrite\""))
        assertTrue(body.indexOf("synthetic-content", filePart) > filePart)
        assertFalse(body.substring(filePart + 1).contains("name=\"path\""))
    }

    @Test
    fun `未返回SynoToken时仍仅在Cookie和正文携带会话`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            "{\"success\":true}", "{\"success\":true}", uploadedFileResponse(17),
        )
        repository(transport, synoToken = null).upload(source(SYNTHETIC_BYTES), "/share") { _, _ -> }
        val request = transport.requests.single { method(it) == "upload" }
        val body = transport.multipartBodies.single().readUtf8()
        assertEquals(setOf("api", "version", "method"), request.url.queryParameterNames)
        assertFalse(request.url.toString().contains("test-session"))
        assertEquals("id=test-session", request.header("Cookie"))
        assertTrue(request.header("X-SYNO-TOKEN") == null)
        assertEquals("test-session", multipartValue(request.body as MultipartBody, "_sid"))
        assertFalse(body.contains("name=\"SynoToken\""))
        assertFalse(body.contains("name=\"synotoken\""))
    }

    @Test
    fun `上传权限被拒绝时不会发送文件正文`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            "{\"success\":false,\"error\":{\"code\":105}}",
        )

        val failure = runCatching {
            repository(transport).upload(source(SYNTHETIC_BYTES), "/share") { _, _ -> }
        }.exceptionOrNull() as DsmFailure

        assertEquals(DsmErrorKind.PERMISSION_DENIED, failure.kind)
        assertEquals(1, transport.requests.size)
        assertTrue(transport.multipartBodies.isEmpty())
    }

    @Test
    fun `上传响应成功但回读大小不一致时不报告完成`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            "{\"success\":true}",
            "{\"success\":true}",
            "{\"success\":true,\"data\":{\"files\":[" +
                "{\"path\":\"/share/synthetic.bin\",\"name\":\"synthetic.bin\"," +
                "\"isdir\":false,\"size\":16}]}}",
        )

        val failure = runCatching {
            repository(transport).upload(source(SYNTHETIC_BYTES), "/share") { _, _ -> }
        }.exceptionOrNull() as DsmFailure

        assertEquals(DsmErrorKind.CHANGE_NOT_CONFIRMED, failure.kind)
        assertEquals(3, transport.requests.size)
    }

    @Test
    fun `NAS拒绝正文长度时给出可恢复的上传错误`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            "{\"success\":true}",
            "{\"success\":false,\"error\":{\"code\":1800}}",
        )

        val failure = runCatching {
            repository(transport).upload(source(SYNTHETIC_BYTES), "/share") { _, _ -> }
        }.exceptionOrNull() as DsmFailure

        assertEquals(DsmErrorKind.UPLOAD_LENGTH_MISMATCH, failure.kind)
        assertEquals(2, transport.requests.size)
    }

    @Test
    fun `批量上传同名预检只分页扫描一次目录且忽略大小写`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            """{"success":true,"data":{"offset":0,"total":3,"files":[{"path":"/share/A.txt","name":"A.txt","isdir":false},{"path":"/share/b.txt","name":"b.txt","isdir":false}]}}""",
            """{"success":true,"data":{"offset":2,"total":3,"files":[{"path":"/share/c.txt","name":"c.txt","isdir":false}]}}""",
        )

        val existing = repository(transport).existingChildNames(
            "/share",
            listOf("a.TXT", "C.txt"),
        )

        assertEquals(setOf("a.TXT", "C.txt"), existing)
        assertEquals(listOf("0", "2"), transport.requests.map { request ->
            val body = request.body as okhttp3.FormBody
            (0 until body.size).associate { body.name(it) to body.value(it) }["offset"]
        })
    }

    @Test
    fun `文本覆盖保存后重新读取并逐字核对`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            textBaselineResponse(),
            """{"success":true}""",
            """{"success":true}""",
            """{"success":true,"data":{"files":[{"path":"/share/note.txt","name":"note.txt","isdir":false,"size":6}]}}""",
            "你好",
        )
        val item = FileItem(
            path = "/share/note.txt",
            name = "note.txt",
            isDirectory = false,
            size = 3,
            canWrite = true,
        )

        val saved = repository(transport).saveText(item, "你好")

        assertEquals("你好", saved.value)
        assertFalse(saved.truncated)
        assertEquals(
            listOf("getinfo", "write", "upload", "getinfo", "download"),
            transport.requests.map(::method),
        )
    }

    @Test
    fun `上传断线但完整内容一致时确认成功且不重放`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            """{"success":true}""",
            IOException("synthetic disconnect"),
            uploadedFileResponse(17),
            SYNTHETIC_BYTES.decodeToString(),
        )

        val result = repository(transport).uploadResult(source(SYNTHETIC_BYTES), "/share")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `上传断线后同大小旧内容不能冒充完成`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            """{"success":true}""", IOException("synthetic disconnect"),
            uploadedFileResponse(17), "different-content",
        )
        val result = repository(transport).uploadResult(source(SYNTHETIC_BYTES), "/share", overwrite = true)
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(listOf("write", "upload", "getinfo", "download"), transport.requests.map(::method))
    }

    @Test
    fun `上传后源文件变化不影响原正文摘要且只打开来源一次`() = runBlocking {
        var opens = 0
        var fingerprint: UploadContentFingerprint? = null
        val input = source(SYNTHETIC_BYTES).copy(
            openInputStream = { opens++; ByteArrayInputStream(if (opens == 1) SYNTHETIC_BYTES else "different-content".encodeToByteArray()) },
            onContentRead = { fingerprint = it },
        )
        val transport = UploadRecordingInterceptor(
            """{"success":true}""", IOException("synthetic disconnect"), uploadedFileResponse(17), SYNTHETIC_BYTES.decodeToString(),
        )
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repository(transport).uploadResult(input, "/share").status)
        assertEquals(1, opens)
        assertEquals(source(SYNTHETIC_BYTES).contentFingerprint(), fingerprint)
    }

    @Test
    fun `上传未读完的源不能留下完整摘要`() = runBlocking {
        var fingerprint: UploadContentFingerprint? = null
        val transport = UploadRecordingInterceptor("""{"success":true}""")
        val input = source(SYNTHETIC_BYTES).copy(contentLength = 18, onContentRead = { fingerprint = it })
        val result = repository(transport).uploadResult(input, "/share")
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(null, fingerprint)
        assertEquals(listOf("write", "upload"), transport.requests.map(::method))
    }

    @Test
    fun `断线后读取权限被拒绝不报告完成也不再次上传`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            """{"success":true}""", IOException("synthetic disconnect"),
            """{"success":false,"error":{"code":105}}""",
        )
        val result = repository(transport).uploadResult(source(SYNTHETIC_BYTES), "/share")
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { method(it) == "upload" })
    }

    @Test
    fun `零字节完整内容可以恢复且目标空格不被剥除`() = runBlocking {
        val path = "/share/folder /synthetic.bin"
        val transport = UploadRecordingInterceptor(
            """{"success":true}""", IOException("synthetic disconnect"),
            """{"success":true,"data":{"files":[{"path":"$path","name":"synthetic.bin","isdir":false,"size":0,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}]}}""", "",
        )
        val result = repository(transport).uploadResult(source(byteArrayOf()), "/share/folder ")
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        val multipart = transport.requests[1].body as MultipartBody
        assertEquals("/share/folder ", multipartValue(multipart, "path"))
    }

    @Test
    fun `上传断线且目标未确认时保持未确认`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            """{"success":true}""",
            IOException("synthetic disconnect"),
            """{"success":true,"data":{"files":[]}}""",
        )

        val result = repository(transport).uploadResult(source(SYNTHETIC_BYTES), "/share")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `上传非法输入和能力不足均不访问网络`() = runBlocking {
        val transport = UploadRecordingInterceptor()
        val invalid = repository(transport).uploadResult(source(SYNTHETIC_BYTES), "relative")
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, invalid.status)
        assertEquals(MutationErrorCategory.VALIDATION, invalid.errorCategory)
        assertTrue(transport.requests.isEmpty())

        val unsupported = repository(transport, supportsUpload = false)
            .uploadResult(source(SYNTHETIC_BYTES), "/share")
        assertEquals(MutationResultStatus.UNSUPPORTED, unsupported.status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `上传提交前协程取消时不访问网络`() {
        val transport = UploadRecordingInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).uploadResult(source(SYNTHETIC_BYTES), "/share").status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `上传提交后取消只要求刷新且不重放`() = runBlocking {
        val transport = BlockingUploadInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.uploadResult(source(SYNTHETIC_BYTES), "/share").status
        }
        assertTrue(transport.uploadStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowUpload.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `同一目标上传进行中时拒绝重复提交`() = runBlocking {
        val transport = BlockingUploadInterceptor(targetAppears = true)
        val repo = repository(transport)
        val first = async(Dispatchers.IO) {
            repo.uploadResult(source(SYNTHETIC_BYTES), "/share")
        }
        assertTrue(transport.uploadStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.uploadResult(source(SYNTHETIC_BYTES), "/share")
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)

        transport.allowUpload.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.requests.count { it.body is MultipartBody })
    }

    @Test
    fun `上传进行中时拒绝删除同一目标`() = runBlocking {
        val transport = BlockingUploadInterceptor(targetAppears = true)
        val repo = repository(transport)
        val upload = async(Dispatchers.IO) {
            repo.uploadResult(source(SYNTHETIC_BYTES), "/share")
        }
        assertTrue(transport.uploadStarted.await(2, TimeUnit.SECONDS))

        val deletion = repo.deleteResult(listOf("/share/synthetic.bin"))
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, deletion.status)
        assertEquals(MutationErrorCategory.CONFLICT, deletion.errorCategory)
        assertFalse(deletion.submitted)

        transport.allowUpload.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, upload.await().status)
        assertFalse(transport.requests.map(::method).contains("delete"))
    }

    @Test
    fun `文本大小一致但内容不同不会报告保存成功`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            textBaselineResponse(),
            """{"success":true}""",
            """{"success":true}""",
            uploadedTextResponse(),
            "再见",
        )
        val item = writableTextItem()

        val outcome = repository(transport).saveTextResult(item, "你好")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, outcome.result.status)
        assertEquals(MutationErrorCategory.CONFLICT, outcome.result.errorCategory)
        assertTrue(outcome.content == null)
    }

    @Test
    fun `文本上传后读取失败保持未确认`() = runBlocking {
        val transport = UploadRecordingInterceptor(
            textBaselineResponse(),
            """{"success":true}""",
            """{"success":true}""",
            uploadedTextResponse(),
            IOException("synthetic readback failure"),
        )

        val outcome = repository(transport).saveTextResult(writableTextItem(), "你好")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, outcome.result.status)
        assertTrue(outcome.result.requiresRefresh)
        assertTrue(outcome.content == null)
    }

    @Test
    fun `文本基线漂移时不发送权限探针和正文`() = runBlocking {
        val transport = UploadRecordingInterceptor(textBaselineResponse(size = 4))

        val outcome = repository(transport).saveTextResult(writableTextItem(), "你好")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, outcome.result.status)
        assertEquals(MutationErrorCategory.CONFLICT, outcome.result.errorCategory)
        assertFalse(outcome.result.submitted)
        assertEquals(listOf("getinfo"), transport.requests.map(::method))
        assertTrue(transport.multipartBodies.isEmpty())
    }

    private fun multipartValue(body: MultipartBody, name: String): String? = body.parts
        .singleOrNull { it.headers?.get("Content-Disposition") == "form-data; name=\"$name\"" }
        ?.let { part -> Buffer().also(part.body::writeTo).readUtf8() }

    private fun source(bytes: ByteArray) = UploadSource(
        displayName = "synthetic.bin",
        contentType = "application/octet-stream",
        contentLength = bytes.size.toLong(),
        openInputStream = { ByteArrayInputStream(bytes) },
    )

    private fun writableTextItem() = FileItem(
        path = "/share/note.txt",
        name = "note.txt",
        isDirectory = false,
        size = 3,
        canWrite = true,
    )

    private fun uploadedFileResponse(size: Long) =
        """{"success":true,"data":{"files":[{"path":"/share/synthetic.bin","name":"synthetic.bin","isdir":false,"size":$size,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}]}}"""

    private fun uploadedTextResponse() =
        """{"success":true,"data":{"files":[{"path":"/share/note.txt","name":"note.txt","isdir":false,"size":6}]}}"""

    private fun textBaselineResponse(size: Long = 3) =
        """{"success":true,"data":{"files":[{"path":"/share/note.txt","name":"note.txt","isdir":false,"size":$size,"additional":{"perm":{"read":true,"write":true,"delete":false}}}]}}"""

    private fun repository(
        interceptor: Interceptor,
        supportsUpload: Boolean = true,
        synoToken: String? = "test-token",
    ): DsmRepository {
        val client = DsmApiClient(
            OkHttpClient.Builder()
                .retryOnConnectionFailure(false)
                .addInterceptor(interceptor)
                .build(),
        )
        val capabilities = buildList {
            if (supportsUpload) {
                add(ApiCapability("SYNO.FileStation.Upload", "entry.cgi", 1, 4))
                add(ApiCapability("SYNO.FileStation.CheckPermission", "entry.cgi", 1, 2))
            }
            add(
            ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
            )
            add(
            ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 2),
            )
            add(ApiCapability("SYNO.FileStation.Delete", "entry.cgi", 1, 2))
        }.associateBy(ApiCapability::name)
        return authorizedRepository(
            profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
            session = DsmSession("test", "test-session", synoToken),
            api = client,
            capabilities = capabilities,
        )
    }

    private fun method(request: Request): String = when (val body = request.body) {
        is okhttp3.FormBody -> (0 until body.size)
            .firstOrNull { body.name(it) == "method" }
            ?.let(body::value)
            .orEmpty()
        else -> request.url.queryParameter("method").orEmpty()
    }

    private companion object {
        val SYNTHETIC_BYTES = "synthetic-content".encodeToByteArray()
    }
}

private class UploadRecordingInterceptor(vararg responses: Any) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()
    val multipartBodies = mutableListOf<Buffer>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        if (request.body is MultipartBody) {
            val buffer = Buffer()
            request.body!!.writeTo(buffer)
            multipartBodies += buffer
        }
        val step = pending.removeFirstOrNull() ?: error("缺少合成响应")
        if (step is IOException) throw step
        val response = step as String
        val requestMethod = request.url.queryParameter("method") ?: (request.body as? okhttp3.FormBody)?.let { form ->
            (0 until form.size).firstOrNull { form.name(it) == "method" }?.let(form::value)
        }
        val responseType = if (requestMethod == "download") {
            "application/octet-stream"
        } else {
            "application/json"
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(if (request.header("Range") != null) 206 else 200)
            .message("OK")
            .apply {
                if (request.header("Range") != null) {
                    val size = response.encodeToByteArray().size
                    header("Content-Range", "bytes 0-${size - 1}/$size")
                }
            }
            .body(response.toResponseBody(responseType.toMediaType()))
            .build()
    }
}

private class BlockingUploadInterceptor(
    private val targetAppears: Boolean = false,
) : Interceptor {
    val uploadStarted = CountDownLatch(1)
    val allowUpload = CountDownLatch(1)
    val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val method = request.url.queryParameter("method") ?: (request.body as? okhttp3.FormBody)?.let { form ->
            (0 until form.size).firstOrNull { form.name(it) == "method" }?.let(form::value)
        }
        val body = when (method) {
            "write" -> """{"success":true}"""
            "upload" -> {
                uploadStarted.countDown()
                check(allowUpload.await(2, TimeUnit.SECONDS)) { "等待上传响应超时" }
                """{"success":true}"""
            }
            "list", "getinfo" -> if (targetAppears && uploadStarted.count == 0L) {
                """{"success":true,"data":{"files":[{"path":"/share/synthetic.bin","name":"synthetic.bin","isdir":false,"size":17}]}}"""
            } else {
                """{"success":true,"data":{"files":[]}}"""
            }
            else -> error("未处理的上传方法：$method")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}
