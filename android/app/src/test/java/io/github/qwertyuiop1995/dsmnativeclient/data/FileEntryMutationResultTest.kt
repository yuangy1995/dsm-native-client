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

class FileEntryMutationResultTest {
    @Test
    fun `新建文件夹精确提交公开参数并回读确认`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(parentResponse()),
            JsonStep(emptyListResponse()),
            JsonStep(successResponse()),
            JsonStep(fileResponse("/share/New", "New", directory = true)),
        )

        val result = repository(transport).createFolderResult("/share/", " New ")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        val request = transport.requests.first { it.fileEntryFormFields()["method"] == "create" }
            .fileEntryFormFields()
        assertEquals("SYNO.FileStation.CreateFolder", request["api"])
        assertEquals("/share", request["folder_path"])
        assertEquals("New", request["name"])
        assertEquals("false", request["force_parent"])
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `新建文件夹输入或能力无效时零请求拒绝`() = runBlocking {
        val invalidTransport = FileEntryInterceptor()
        val invalid = repository(invalidTransport).createFolderResult("/share", "../bad")
        val unsupportedTransport = FileEntryInterceptor()
        val unsupported = repository(unsupportedTransport, create = false)
            .createFolderResult("/share", "New")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, invalid.status)
        assertEquals(MutationErrorCategory.VALIDATION, invalid.errorCategory)
        assertEquals(MutationResultStatus.UNSUPPORTED, unsupported.status)
        assertTrue(invalidTransport.requests.isEmpty())
        assertTrue(unsupportedTransport.requests.isEmpty())
    }

    @Test
    fun `新建文件夹在只读父目录提交前返回权限不足`() = runBlocking {
        val transport = FileEntryInterceptor(JsonStep(parentResponse(writable = false)))

        val result = repository(transport).createFolderResult("/share", "New")

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo"), transport.methods())
    }

    @Test
    fun `新建文件夹同名冲突时不发送创建请求`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(parentResponse()),
            JsonStep(listResponse("/share/New", "New", directory = true)),
        )

        val result = repository(transport).createFolderResult("/share", "New")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertFalse(transport.methods().contains("create"))
    }

    @Test
    fun `新建文件夹提交断线后保持未确认且不自动重放`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(parentResponse()),
            JsonStep(emptyListResponse()),
            FailureStep(IOException("synthetic create disconnect")),
        )

        val result = repository(transport).createFolderResult("/share", "New")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `新建文件夹明确权限拒绝不会自动重放`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(parentResponse()),
            JsonStep(emptyListResponse()),
            JsonStep("""{"success":false,"error":{"code":105}}"""),
        )

        val result = repository(transport).createFolderResult("/share", "New")

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertTrue(result.submitted)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `新建文件夹写后回读失败保持未确认`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(parentResponse()),
            JsonStep(emptyListResponse()),
            JsonStep(successResponse()),
            JsonStep("""{"success":false,"error":{"code":100}}"""),
        )

        val result = repository(transport).createFolderResult("/share", "New")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
    }

    @Test
    fun `重命名精确提交路径和名称并复查源目标`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(fileResponse("/share/Old.txt", "Old.txt", directory = false)),
            JsonStep(parentResponse()),
            JsonStep(emptyListResponse()),
            JsonStep(successResponse()),
            JsonStep(emptyListResponse()),
            JsonStep(fileResponse("/share/New.txt", "New.txt", directory = false)),
        )

        val result = repository(transport).renameResult("/share/Old.txt", " New.txt ")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        val request = transport.requests.first { it.fileEntryFormFields()["method"] == "rename" }
            .fileEntryFormFields()
        assertEquals("SYNO.FileStation.Rename", request["api"])
        assertEquals("/share/Old.txt", request["path"])
        assertEquals("New.txt", request["name"])
        assertEquals(listOf("list", "getinfo"), transport.methods().takeLast(2))
    }

    @Test
    fun `重命名目标已存在时提交前返回冲突`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(fileResponse("/share/Old.txt", "Old.txt", directory = false)),
            JsonStep(parentResponse()),
            JsonStep(listResponse("/share/New.txt", "New.txt", directory = false)),
        )

        val result = repository(transport).renameResult("/share/Old.txt", "New.txt")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertFalse(transport.methods().contains("rename"))
    }

    @Test
    fun `重命名输入或能力无效时零请求拒绝`() = runBlocking {
        val invalidTransport = FileEntryInterceptor()
        val invalid = repository(invalidTransport).renameResult("/share/Old", "../New")
        val unsupportedTransport = FileEntryInterceptor()
        val unsupported = repository(unsupportedTransport, rename = false)
            .renameResult("/share/Old", "New")

        assertEquals(MutationErrorCategory.VALIDATION, invalid.errorCategory)
        assertEquals(MutationResultStatus.UNSUPPORTED, unsupported.status)
        assertTrue(invalidTransport.requests.isEmpty())
        assertTrue(unsupportedTransport.requests.isEmpty())
    }

    @Test
    fun `重命名提交断线后保持未确认且不自动重放`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(fileResponse("/share/Old.txt", "Old.txt", directory = false)),
            JsonStep(parentResponse()),
            JsonStep(emptyListResponse()),
            FailureStep(IOException("synthetic rename disconnect")),
        )

        val result = repository(transport).renameResult("/share/Old.txt", "New.txt")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
        assertTrue(result.submitted)
        assertEquals(1, transport.methods().count { it == "rename" })
    }

    @Test
    fun `重命名明确权限拒绝不会自动重放`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(fileResponse("/share/Old.txt", "Old.txt", directory = false)),
            JsonStep(parentResponse()),
            JsonStep(emptyListResponse()),
            JsonStep("""{"success":false,"error":{"code":105}}"""),
        )

        val result = repository(transport).renameResult("/share/Old.txt", "New.txt")

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertTrue(result.submitted)
        assertEquals(1, transport.methods().count { it == "rename" })
    }

    @Test
    fun `重命名写后回读失败保持未确认`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(fileResponse("/share/Old.txt", "Old.txt", directory = false)),
            JsonStep(parentResponse()),
            JsonStep(emptyListResponse()),
            JsonStep(successResponse()),
            JsonStep("""{"success":false,"error":{"code":100}}"""),
        )

        val result = repository(transport).renameResult("/share/Old.txt", "New.txt")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
    }

    @Test
    fun `重命名提交成功但源仍存在时报告明确失败`() = runBlocking {
        val transport = FileEntryInterceptor(
            JsonStep(fileResponse("/share/Old.txt", "Old.txt", directory = false)),
            JsonStep(parentResponse()),
            JsonStep(emptyListResponse()),
            JsonStep(successResponse()),
            JsonStep(listResponse("/share/Old.txt", "Old.txt", directory = false)),
            JsonStep(fileResponse("/share/New.txt", "New.txt", directory = false)),
        )

        val result = repository(transport).renameResult("/share/Old.txt", "New.txt")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
    }

    @Test
    fun `相同目标创建进行中时拒绝第二次提交`() = runBlocking {
        val transport = BlockingFileEntryInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.createFolderResult("/share", "New") }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.createFolderResult("/share", "New")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)
        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `创建进行中时拒绝删除其子路径`() = runBlocking {
        val transport = BlockingFileEntryInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.createFolderResult("/share", "New") }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val overlappingDelete = repo.deleteResult(listOf("/share/New/child.txt"))

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, overlappingDelete.status)
        assertEquals(MutationErrorCategory.CONFLICT, overlappingDelete.errorCategory)
        assertFalse(overlappingDelete.submitted)
        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertFalse(transport.methods().contains("start"))
    }

    @Test
    fun `提交前协程取消时不访问网络`() {
        val transport = FileEntryInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).renameResult("/share/Old", "New").status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `新建文件夹提交后的取消只要求刷新而不重放`() = runBlocking {
        val transport = CancellingFileEntryInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.createFolderResult("/share", "New").status
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowSubmission.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "create" })
    }

    @Test
    fun `重命名提交后的取消只要求刷新而不重放`() = runBlocking {
        val transport = CancellingRenameInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.renameResult("/share/Old.txt", "New.txt").status
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowSubmission.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "rename" })
    }

    private fun repository(
        interceptor: Interceptor,
        create: Boolean = true,
        rename: Boolean = true,
    ) = authorizedRepository(
        profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        session = DsmSession("test", "test-session", "test-token"),
        api = DsmApiClient(
            OkHttpClient.Builder()
                .retryOnConnectionFailure(false)
                .addInterceptor(interceptor)
                .build(),
        ),
        capabilities = buildList {
            add(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2))
            add(ApiCapability("SYNO.FileStation.Delete", "entry.cgi", 1, 2))
            if (create) add(ApiCapability("SYNO.FileStation.CreateFolder", "entry.cgi", 1, 2))
            if (rename) add(ApiCapability("SYNO.FileStation.Rename", "entry.cgi", 1, 2))
        }.associateBy(ApiCapability::name),
    )
}

private sealed interface FileEntryStep
private data class JsonStep(val body: String) : FileEntryStep
private data class FailureStep(val error: IOException) : FileEntryStep

private class FileEntryInterceptor(vararg steps: FileEntryStep) : Interceptor {
    private val pending = ArrayDeque(steps.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return when (val step = pending.removeFirstOrNull() ?: error("缺少合成文件操作响应")) {
            is FailureStep -> throw step.error
            is JsonStep -> fileEntryResponse(request, step.body)
        }
    }

    fun methods(): List<String?> = requests.map { it.fileEntryFormFields()["method"] }
}

private class BlockingFileEntryInterceptor : Interceptor {
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
            1 -> parentResponse()
            2 -> emptyListResponse()
            3 -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待合成创建请求放行超时" }
                successResponse()
            }
            else -> fileResponse("/share/New", "New", directory = true)
        }
        return fileEntryResponse(request, body)
    }

    fun methods(): List<String?> = synchronized(requests) {
        requests.map { it.fileEntryFormFields()["method"] }
    }
}

private class CancellingFileEntryInterceptor : Interceptor {
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
            1 -> parentResponse()
            2 -> emptyListResponse()
            3 -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待合成取消请求放行超时" }
                successResponse()
            }
            else -> fileResponse("/share/New", "New", directory = true)
        }
        return fileEntryResponse(request, body)
    }

    fun methods(): List<String?> = synchronized(requests) {
        requests.map { it.fileEntryFormFields()["method"] }
    }
}

private class CancellingRenameInterceptor : Interceptor {
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
            1 -> fileResponse("/share/Old.txt", "Old.txt", directory = false)
            2 -> parentResponse()
            3 -> emptyListResponse()
            4 -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待合成重命名请求放行超时" }
                successResponse()
            }
            else -> emptyListResponse()
        }
        return fileEntryResponse(request, body)
    }

    fun methods(): List<String?> = synchronized(requests) {
        requests.map { it.fileEntryFormFields()["method"] }
    }
}

private fun parentResponse(writable: Boolean = true) =
    """{"success":true,"data":{"files":[{"name":"share","path":"/share","isdir":true,"additional":{"perm":{"write":$writable}}}]}}"""

private fun fileResponse(path: String, name: String, directory: Boolean) =
    """{"success":true,"data":{"files":[{"name":"$name","path":"$path","isdir":$directory,"additional":{"perm":{"write":true}}}]}}"""

private fun listResponse(path: String, name: String, directory: Boolean) =
    """{"success":true,"data":{"offset":0,"total":1,"files":[{"name":"$name","path":"$path","isdir":$directory}]}}"""

private fun emptyListResponse() =
    """{"success":true,"data":{"offset":0,"total":0,"files":[]}}"""

private fun successResponse() = """{"success":true,"data":{}}"""

private fun fileEntryResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.fileEntryFormFields(): Map<String, String> {
    val form = body as FormBody
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
