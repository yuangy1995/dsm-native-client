package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageImportVerification
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageType
import io.github.qwertyuiop1995.dsmnativeclient.domain.isEligibleForVirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
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

class VirtualMachineImageImportRepositoryTest {
    @Test
    fun `后台分段helper只使用公开上传后导入所需端点`() = runBlocking {
        val transport = ImageImportInterceptor(
            fileInfo(), storageList(), imageList(), taskStarted(),
            taskFinished(), imageList(image()),
            """{"success":true,"data":{"task_ids":["task-1"]}}""",
            emptySuccess(),
        )
        val repository = repository(transport)
        val target = target()

        val taskId = repository.startVirtualMachineImageImportTask(
            target.sourceFile,
            target.imageName,
            target.imageType,
            target.storage.id,
            target.storage.name,
            "online",
        )
        val task = repository.readVirtualMachineImageImportTask(taskId)
        val matched = repository.virtualMachineImageMatches(
            checkNotNull(task.imageId),
            target.imageName,
            target.imageType,
        )
        val exists = repository.virtualMachineTaskExists(taskId)
        repository.clearVirtualMachineImageImportTask(taskId)

        assertTrue(task.finished)
        assertEquals(DsmRepository.VirtualMachineImageMatch.MATCH, matched)
        assertTrue(exists)
        assertEquals(
            listOf("getinfo", "list", "list", "create", "get", "list", "list", "clear"),
            transport.requests.map { it.fields()["method"] },
        )
        assertEquals(1, transport.requests.count { it.fields()["method"] == "create" })
        assertEquals(1, transport.requests.count { it.fields()["method"] == "clear" })
    }

    @Test
    fun `官方映像创建只提交一次并以任务映像标识严格回读`() = runBlocking {
        val transport = ImageImportInterceptor(
            fileInfo(), storageList(), imageList(),
            taskStarted(), taskFinished(), imageList(image()),
        )
        val repo = repository(transport)
        val result = repo.probeImport()
        assertEquals(null, result.failure)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED), result.steps.map { it.stage })
        assertEquals("task-1", result.steps.last().task)
        val verified = repo.virtualMachineManagement.recoverImport(requireNotNull(result.snapshot), result.steps.last())
        assertEquals(VmmStage.VERIFIED, verified.stage)
        assertEquals(vmmDigest("image-1"), verified.image)
        assertEquals(1, transport.requests.count { it.fields()["method"] == "create" })
        assertEquals(
            listOf("getinfo", "list", "list", "create", "get", "list"),
            transport.requests.map { it.fields()["method"] },
        )
        val create = transport.requests[3].fields()
        assertEquals("1", create["version"])
        assertEquals("false", create["auto_clean_task"])
        assertEquals("[\"storage-1\"]", create["storage_ids"])
        assertEquals("disk", create["type"])
        assertEquals("/share/synthetic.img", create["ds_file_path"])
        assertEquals("Synthetic image", create["image_name"])
        RequestFixtureAssertions.assertRequest(
            transport.requests[3],
            "vmm/create-image/synthetic-image/request.json",
        )
        assertFalse(transport.requests.any { it.fields()["method"] == "clear" })
    }

    @Test
    fun `创建请求断线后保持未确认且不重放`() = runBlocking {
        val transport = ImageImportInterceptor(
            fileInfo(), storageList(), imageList(), IOException("synthetic disconnect"),
        )

        val result = repository(transport).probeImport()

        assertEquals(listOf(VmmStage.SUBMITTED), result.steps.map { it.stage })
        assertTrue(result.failure != null)
        assertEquals(1, transport.requests.count { it.fields()["method"] == "create" })
    }

    @Test
    fun `创建请求在途取消后保持提交边界且不重放`() = runBlocking {
        val transport = ImageImportInterceptor(
            fileInfo(), storageList(), imageList(), CANCEL_RESPONSE,
        )
        val captured = CompletableDeferred<ImportProbe>()
        val worker = launch(Dispatchers.IO) {
            captured.complete(repository(transport).probeImport())
        }
        assertTrue(transport.cancellationRequestEntered.await(5, TimeUnit.SECONDS))

        worker.cancel()
        transport.releaseCancellationRequest.countDown()
        worker.join()
        val result = captured.await()

        assertEquals(listOf(VmmStage.SUBMITTED), result.steps.map { it.stage })
        assertTrue(result.failure is kotlinx.coroutines.CancellationException)
        assertEquals(1, transport.requests.count { it.fields()["method"] == "create" })
    }

    @Test
    fun `源文件完整基线漂移时零创建`() = runBlocking {
        val transport = ImageImportInterceptor(
            fileInfo(size = 2049), storageList(), imageList(),
        )

        val result = repository(transport).probeImport()

        assertTrue(result.failure is VmmFailure)
        assertEquals(null, result.snapshot)
        assertTrue(result.steps.isEmpty())
        assertFalse(transport.requests.any { it.fields()["method"] == "create" })
    }

    @Test
    fun `任务终态缺少映像标识时保持未确认且不清理`() = runBlocking {
        val transport = ImageImportInterceptor(
            fileInfo(), storageList(), imageList(), taskStarted(),
            """{"success":true,"data":{"finish":true,"task_info":{}}}""",
        )

        val repo = repository(transport)
        val result = repo.probeImport()
        assertEquals(null, result.failure)
        val pending = repo.virtualMachineManagement.recoverImport(requireNotNull(result.snapshot), result.steps.last())
        assertEquals(VmmStage.ACCEPTED, pending.stage)
        assertEquals(null, pending.image)
        assertEquals("task-1", pending.task)
        assertEquals(1, transport.requests.count { it.fields()["method"] == "create" })
        assertFalse(transport.requests.any { it.fields()["method"] == "clear" })
    }

    @Test
    fun `保存的任务标识可继续核对进行中和严格匹配终态`() = runBlocking {
        val pendingTransport = ImageImportInterceptor(
            """{"success":true,"data":{"finish":false}}""",
        )
        val pending = repository(pendingTransport).verifyVirtualMachineImageImportTask(
            "task-1", "Synthetic image", VirtualMachineImageType.DISK,
        )
        val matchedTransport = ImageImportInterceptor(taskFinished(), imageList(image()), emptySuccess())
        var cleared: String? = null
        val matched = repository(matchedTransport).verifyVirtualMachineImageImportTask(
            "task-1", "Synthetic image", VirtualMachineImageType.DISK,
            onTaskCleared = { cleared = it },
        )

        assertEquals(VirtualMachineImageImportVerification.PENDING, pending)
        assertEquals(VirtualMachineImageImportVerification.MATCHES, matched)
        assertFalse(pendingTransport.requests.any { it.fields()["method"] == "clear" })
        assertEquals(listOf("get", "list", "clear"), matchedTransport.requests.map { it.fields()["method"] })
        assertEquals("task-1", cleared)
    }

    @Test
    fun `任务清理失败不执行回调并保留恢复证据`() = runBlocking {
        val transport = ImageImportInterceptor(taskFinished(), imageList(image()), "not-json")
        var cleared = false

        val outcome = runCatching {
            repository(transport).verifyVirtualMachineImageImportTask(
                "task-1", "Synthetic image", VirtualMachineImageType.DISK,
                onTaskCleared = { cleared = true },
            )
        }

        assertTrue(outcome.isFailure)
        assertFalse(cleared)
        assertEquals(listOf("get", "list", "clear"), transport.requests.map { it.fields()["method"] })
        assertEquals(1, transport.requests.count { it.fields()["method"] == "clear" })
    }

    @Test
    fun `任务终态映像列表尚未可见时继续等待且不清理`() = runBlocking {
        val transport = ImageImportInterceptor(taskFinished(), imageList())

        val verification = repository(transport).verifyVirtualMachineImageImportTask(
            "task-1", "Synthetic image", VirtualMachineImageType.DISK,
        )

        assertEquals(VirtualMachineImageImportVerification.PENDING, verification)
        assertFalse(transport.requests.any { it.fields()["method"] == "clear" })
    }

    @Test
    fun `任务终态缺少映像标识时清理后报告不一致`() = runBlocking {
        val transport = ImageImportInterceptor(
            """{"success":true,"data":{"finish":true,"task_info":{}}}""",
            emptySuccess(),
        )
        var cleared: String? = null

        val verification = repository(transport).verifyVirtualMachineImageImportTask(
            "task-1", "Synthetic image", VirtualMachineImageType.DISK,
            onTaskCleared = { cleared = it },
        )

        assertEquals(VirtualMachineImageImportVerification.DIFFERS, verification)
        assertEquals("task-1", cleared)
        assertEquals(1, transport.requests.count { it.fields()["method"] == "clear" })
    }

    @Test
    fun `映像导入存储状态只拒绝官方不可服务状态`() {
        fun storage(status: String) = ManagedResource(
            id = "storage-1", name = "Storage", detail = status,
            state = ResourceState.UNKNOWN, metadata = mapOf("status" to status),
        )
        listOf("online", "degraded", "provision_warning").forEach {
            assertTrue(it, storage(it).isEligibleForVirtualMachineImageImport())
        }
        listOf("missing", "unavailable", "crashed", "full").forEach {
            assertFalse(it, storage(it).isEligibleForVirtualMachineImageImport())
        }
    }

    private data class ImportProbe(val snapshot: VmmImportSnapshot?, val steps: List<VmmImportProgress>, val failure: Throwable?)
    private suspend fun DsmRepository.probeImport(): ImportProbe {
        var snapshot: VmmImportSnapshot? = null
        val steps = mutableListOf<VmmImportProgress>()
        val outcome = runCatching { importNasVmmImage(target(), { snapshot = it }, steps::add) }
        return ImportProbe(snapshot, steps.toList(), outcome.exceptionOrNull())
    }

    private fun repository(interceptor: Interceptor) = authorizedRepository(
        NasProfile("profile-a", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("profile-a", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        listOf(
            ApiCapability("SYNO.FileStation.List", "entry.cgi", 2, 2),
            ApiCapability("SYNO.Virtualization.API.Storage", "entry.cgi", 1, 1),
            ApiCapability("SYNO.Virtualization.API.Guest.Image", "entry.cgi", 1, 1),
            ApiCapability("SYNO.Virtualization.API.Task.Info", "entry.cgi", 1, 1),
        ).associateBy(ApiCapability::name),
    )

    private fun target() = VirtualMachineImageImport(
        imageName = "Synthetic image",
        imageType = VirtualMachineImageType.DISK,
        sourceFile = FileItem(
            path = "/share/synthetic.img",
            name = "synthetic.img",
            isDirectory = false,
            size = 2048,
            modifiedAtEpochSeconds = 100,
            canRead = true,
        ),
        storage = ManagedResource(
            id = "storage-1",
            name = "Synthetic storage",
            detail = "online",
            state = ResourceState.RUNNING,
            metadata = mapOf(
                "storage_id" to "storage-1",
                "storage_name" to "Synthetic storage",
                "status" to "online",
            ),
        ),
    )

    private fun fileInfo(size: Long = 2048) =
        """{"success":true,"data":{"files":[{"path":"/share/synthetic.img","name":"synthetic.img","isdir":false,"additional":{"size":$size,"time":{"mtime":100},"perm":{"read":true,"write":false,"delete":false}}}],"total":1,"offset":0}}"""

    private fun storageList() =
        """{"success":true,"data":{"storages":[{"storage_id":"storage-1","storage_name":"Synthetic storage","status":"online"}]}}"""

    private fun image() =
        """{"image_id":"image-1","image_name":"Synthetic image","type":"disk"}"""

    private fun imageList(vararg images: String) =
        """{"success":true,"data":{"images":[${images.joinToString(",")}]}}"""

    private fun taskStarted() =
        """{"success":true,"data":{"task_id":"task-1"}}"""

    private fun taskFinished() =
        """{"success":true,"data":{"finish":true,"task_info":{"image_id":"image-1","progress":100,"status":"create"}}}"""

    private fun emptySuccess() = """{"success":true,"data":{}}"""
}

private class ImageImportInterceptor(vararg responses: Any) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()
    val cancellationRequestEntered = CountDownLatch(1)
    val releaseCancellationRequest = CountDownLatch(1)

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val scripted = pending.removeFirstOrNull() ?: error("缺少合成 VMM 映像导入响应")
        if (scripted is IOException) throw scripted
        if (scripted == CANCEL_RESPONSE) {
            cancellationRequestEntered.countDown()
            check(releaseCancellationRequest.await(5, TimeUnit.SECONDS)) { "合成取消请求未释放" }
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                (if (scripted == CANCEL_RESPONSE) taskStarted() else scripted as String)
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private const val CANCEL_RESPONSE = "__synthetic_image_import_cancellation__"

private fun taskStarted() = """{"success":true,"data":{"task_id":"task-1"}}"""

private fun Request.fields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
