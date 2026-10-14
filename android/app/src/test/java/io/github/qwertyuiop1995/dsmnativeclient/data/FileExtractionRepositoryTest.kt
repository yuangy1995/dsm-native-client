package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class FileExtractionRepositoryTest {
    private val source = FileItem("/synthetic/archive.zip", "archive.zip", false, size = 100, canRead = true)
    private val destination = FileItem("/synthetic/destination", "destination", true, canRead = true, canWrite = true)
    private val folder = ArchiveItem(7, "Folder", "Folder", true)
    private val child = ArchiveItem(3, "a.txt", "Folder/a.txt", false, 12)
    private val other = ArchiveItem(8, "b.txt", "b.txt", false, 0)

    @Test fun `选择解压使用原编号与完整输出清单并对齐正式请求样本`() = runBlocking {
        val transport = Fixture()
        transport.onStart = { transport.addOutputs(); task() }
        var outputs = emptyList<FileServerMutationExpectedOutput>()
        val result = transport.repository.extractResult(request(selected = listOf(child, other), codepage = "chs"), onExpectedOutputs = { outputs = it })
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf("${destination.path}/b.txt", "${destination.path}/Folder/a.txt"), outputs.map { it.path })
        assertEquals(listOf(0L, 12L), outputs.map { it.expectedBytes })
        val start = transport.requests.single { it.fields()["method"] == "start" }
        RequestFixtureAssertions.assertRequest(start, "file-station/extract/synthetic-selected/request.json")
        assertEquals("3,8", start.fields()["item_id"])
        assertEquals(1, transport.count("start"))
    }

    @Test fun `公开子目录分页请求对齐固定样本`() = runBlocking {
        val transport = Fixture()
        transport.onList = { buildJsonObject { putJsonArray("items") {}; put("total", 200) } }
        transport.repository.listArchivePage(source.path, 7, 200, 200, "chs")
        RequestFixtureAssertions.assertRequest(transport.requests.single(), "file-station/archive-list/synthetic-child-page/request.json")
    }

    @Test fun `源读取权限与目标写权限缺失均零提交且旧路径入口同样受限`() = runBlocking {
        for (denySource in listOf(true, false)) {
            val transport = Fixture()
            if (denySource) transport.files[source.path] = source.copy(canRead = false)
            else transport.files[destination.path] = destination.copy(canWrite = false)
            val result = transport.repository.extractResult(source.path, destination.path)
            assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
            assertFalse(result.submitted)
            assertEquals(0, transport.count("start"))
        }
    }

    @Test fun `空选择或条目改变不得转为全部解压`() = runBlocking {
        for (items in listOf(emptyList(), listOf(child.copy(id = 99)))) {
            val transport = Fixture()
            val result = transport.repository.extractResult(request(items))
            assertFalse(result.submitted)
            assertEquals(MutationErrorCategory.VALIDATION, result.errorCategory)
            assertEquals(0, transport.count("start"))
        }
    }

    @Test fun `无覆盖意图或已有文件只读时不发送写请求`() = runBlocking {
        for (overwrite in listOf(false, true)) {
            val transport = Fixture()
            transport.files["${destination.path}/b.txt"] = FileItem("${destination.path}/b.txt", "b.txt", false, canRead = true, canWrite = false)
            val result = transport.repository.extractResult(request(listOf(other), overwrite = overwrite))
            assertEquals(if (overwrite) MutationErrorCategory.PERMISSION else MutationErrorCategory.CONFLICT, result.errorCategory)
            assertFalse(result.submitted); assertEquals(0, transport.count("start"))
        }
    }

    @Test fun `覆盖写启动断线不能把已有同尺寸文件认作成功`() = runBlocking {
        val transport = Fixture()
        transport.addOutputs()
        transport.onStart = { throw IOException("synthetic disconnect") }
        val result = transport.repository.extractResult(request(listOf(child), overwrite = true))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.count("start"))
        assertEquals("start", transport.requests.last().fields()["method"])
    }

    @Test fun `覆盖任务结束后仍检查输出尺寸`() = runBlocking {
        for (bytes in listOf(12L, 11L)) {
            val transport = Fixture()
            transport.addOutputs()
            transport.onStart = { transport.files["${destination.path}/Folder/a.txt"] = transport.files.getValue("${destination.path}/Folder/a.txt").copy(size = bytes); task() }
            val result = transport.repository.extractResult(request(listOf(child), overwrite = true))
            assertEquals(if (bytes == 12L) MutationResultStatus.CONFIRMED_SUCCESS else MutationResultStatus.CONFIRMED_FAILURE, result.status)
            assertEquals(1, transport.count("start"))
        }
    }

    @Test fun `缺少任务编号时覆盖操作保持未知且不会重发`() = runBlocking {
        val transport = Fixture(); transport.addOutputs(); transport.onStart = { buildJsonObject {} }
        val result = transport.repository.extractResult(request(listOf(other), overwrite = true))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, transport.count("start")); assertEquals(0, transport.count("status"))
    }

    @Test fun `完整输出清单保存失败时零启动请求`() = runBlocking {
        val transport = Fixture()
        val error = runCatching { transport.repository.extractResult(request(listOf(other)), onExpectedOutputs = { throw IllegalStateException("synthetic save failure") }) }.exceptionOrNull()
        assertTrue(error is IllegalStateException)
        assertEquals(0, transport.count("start"))
    }

    @Test fun `恢复覆盖任务只读原编号且读取失败不靠旧文件确认成功`() = runBlocking {
        val outputs = listOf(FileServerMutationExpectedOutput("${destination.path}/b.txt", false, expectedBytes = 0, requiresTaskCompletion = true))
        val transport = Fixture(); transport.addOutputs()
        transport.onStatus = { throw IOException("synthetic offline") }
        val unknown = transport.repository.resumeArchiveMutationResult(FileServerMutationOperation.EXTRACT, "existing-task", outputs)
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, unknown.status)
        assertEquals(listOf("status"), transport.requests.map { it.fields()["method"] })
        transport.onStatus = { buildJsonObject { put("finished", true) } }
        val resolved = transport.repository.resumeArchiveMutationResult(FileServerMutationOperation.EXTRACT, "existing-task", outputs)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, resolved.status)
        assertEquals(0, transport.count("start"))
        assertTrue(transport.requests.filter { it.fields()["method"] == "status" }.all { it.fields()["taskid"] == "existing-task" })
    }

    @Test fun `覆盖任务取消只请求停止一次并保留未知结果`() = runBlocking {
        val transport = Fixture(); transport.addOutputs()
        val started = CountDownLatch(1); val release = CountDownLatch(1)
        transport.onStatus = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); buildJsonObject { put("finished", false) } }
        var result: MutationResult? = null
        val job = launch(Dispatchers.IO) { result = transport.repository.extractResult(request(listOf(child), overwrite = true)) }
        assertTrue(started.await(5, TimeUnit.SECONDS))
        job.cancel(); release.countDown(); job.join()
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, result?.status)
        assertEquals(true, result?.requiresRefresh)
        assertEquals(1, transport.count("start")); assertEquals(1, transport.count("stop"))
    }

    private fun request(selected: List<ArchiveItem>, overwrite: Boolean = false, codepage: String? = null) =
        FileExtractionRequest(source, destination, FileExtractionOptions(FileArchiveSelection.Items(selected), overwrite = overwrite, codepage = codepage))
    private fun task() = buildJsonObject { put("taskid", "extract-task") }
    private inner class Fixture : Interceptor {
        val requests = mutableListOf<Request>()
        val files = mutableMapOf(source.path to source, destination.path to destination)
        var onStart: () -> JsonObject = { task() }
        var onStatus: () -> JsonObject = { buildJsonObject { put("finished", true) } }
        var onList: ((Map<String, String>) -> JsonObject)? = null
        val repository = authorizedRepository(NasProfile("fixture", "NAS", "https://synthetic.example.invalid", "synthetic"), DsmSession("fixture", "fixture-session", "fixture-token"),
            DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(this).build()),
            listOf(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2), ApiCapability("SYNO.FileStation.Extract", "entry.cgi", 2, 2)).associateBy(ApiCapability::name))
        fun count(method: String) = requests.count { it.fields()["method"] == method }
        fun addOutputs() {
            files["${destination.path}/Folder/a.txt"] = FileItem("${destination.path}/Folder/a.txt", "a.txt", false, size = 12, canRead = true, canWrite = true)
            files["${destination.path}/b.txt"] = FileItem("${destination.path}/b.txt", "b.txt", false, size = 0, canRead = true, canWrite = true)
        }
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request(); requests += request
            val fields = request.fields()
            val data = when (fields["method"]) {
                "getinfo" -> buildJsonObject { putJsonArray("files") { Json.parseToJsonElement(fields.getValue("path")).jsonArray.forEach { path -> files[path.jsonPrimitive.content]?.let { add(file(it)) } } } }
                "list" -> onList?.invoke(fields) ?: buildJsonObject { putJsonArray("items") {
                    (if (fields["item_id"] == "-1") listOf(folder, other) else listOf(child)).forEach { entry -> add(buildJsonObject {
                        put("item_id", entry.id); put("name", entry.name); put("path", entry.path); put("is_dir", entry.isDirectory); entry.size?.let { put("size", it) }
                    }) }
                } }
                "start" -> onStart()
                "status" -> onStatus()
                "stop" -> buildJsonObject {}
                else -> error("Unexpected synthetic archive method")
            }
            return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
        }
        private fun file(item: FileItem) = buildJsonObject {
            put("path", item.path); put("name", item.name); put("isdir", item.isDirectory); put("size", item.size)
            putJsonObject("additional") { putJsonObject("perm") { put("is_acl_mode", false); putJsonObject("acl") { put("read", item.canRead); put("write", item.canWrite); put("del", item.canDelete) } } }
        }
    }
}

private fun Request.fields(): Map<String, String> = (body as FormBody).let { form -> (0 until form.size).associate { form.name(it) to form.value(it) } }
