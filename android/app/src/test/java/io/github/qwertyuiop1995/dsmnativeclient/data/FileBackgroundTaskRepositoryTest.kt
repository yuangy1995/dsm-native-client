package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskState
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FileBackgroundTaskRepositoryTest {
    @Test
    fun `后台任务使用官方V3有界分页和固定过滤器`() = runBlocking {
        val transport = BackgroundTaskInterceptor(success("""{"offset":0,"total":0,"tasks":[]}"""))

        val page = repository(transport).listFileBackgroundTasks(offset = -20, limit = 5_000)

        assertTrue(page.tasks.isEmpty())
        assertFalse(page.hasMore)
        val request = transport.requests.single()
        RequestFixtureAssertions.assertRequest(
            request,
            "file-station/background-task/synthetic-page/request.json",
        )
        assertEquals("3", request.formFields()["version"])
        assertNull(request.formFields()["path"])
        assertTrue(transport.methods().none { it == "clear_finished" })
    }

    @Test
    fun `后台任务仅保留白名单字段且已结束不推断成功`() = runBlocking {
        val body = success(
            """{"offset":0,"total":4,"tasks":[""" +
                """{"api":"SYNO.FileStation.CopyMove","taskid":"copy-1","finished":false,"progress":0.25,"crtime":1700000000,"processed_num":2,"processed_size":1024,"total":4096,"params":{"password":"SYNTHETIC_SECRET"},"path":"<synthetic-private-path>","processing_path":"<synthetic-processing-path>","message":"SYNTHETIC_PRIVATE_MESSAGE"},""" +
                """{"api":"SYNO.FileStation.Delete","taskid":"delete-1","finished":false,"processed_num":"4","processed_size":"8","total":"9"},""" +
                """{"api":"SYNO.FileStation.Compress","taskid":"compress-1","finished":true,"progress":1,"processed_num":3,"processed_size":2048,"total":99},""" +
                """{"api":"SYNO.FileStation.Extract","taskid":"extract-1","finished":"1","progress":0}""" +
                "]}",
        )
        val page = repository(BackgroundTaskInterceptor(body)).listFileBackgroundTasks()

        assertEquals(4, page.tasks.size)
        val copy = page.tasks[0]
        assertEquals(FileBackgroundTaskKind.COPY_OR_MOVE, copy.kind)
        assertEquals(FileBackgroundTaskState.ACTIVE, copy.state)
        assertEquals(0.25, copy.progress!!, 0.0)
        assertEquals(1_700_000_000L, copy.createdAtEpochSeconds)
        assertEquals(1_024L, copy.processedBytes)
        assertEquals(4_096L, copy.totalBytes)
        assertNull(copy.totalItemCount)
        val deletion = page.tasks[1]
        assertEquals(4, deletion.processedItemCount)
        assertEquals(9, deletion.totalItemCount)
        assertNull(deletion.totalBytes)
        val finished = page.tasks[2]
        assertEquals(FileBackgroundTaskState.FINISHED, finished.state)
        assertNull(finished.totalBytes)
        assertNull(finished.totalItemCount)
        assertEquals(FileBackgroundTaskState.FINISHED, page.tasks[3].state)
        assertNull(page.tasks[3].progress)

        val description = page.toString()
        assertFalse(description.contains("SYNTHETIC_SECRET"))
        assertFalse(description.contains("synthetic-private-path"))
        assertFalse(description.contains("synthetic-processing-path"))
        assertFalse(description.contains("SYNTHETIC_PRIVATE_MESSAGE"))
    }

    @Test
    fun `分页按原始行推进并丢弃未知类型坏ID重复ID和未知字段`() = runBlocking {
        val body = success(
            """{"offset":"10","total":"16","tasks":[""" +
                """{"api":"SYNO.FileStation.CopyMove","taskid":"safe-1","finished":false,"future":{"value":1}},""" +
                """{"api":"SYNO.FileStation.Future","taskid":"future-1","finished":false},""" +
                """{"api":"SYNO.FileStation.Delete","taskid":"/synthetic/private/task","finished":false},""" +
                """{"api":"SYNO.FileStation.CopyMove","taskid":"safe-1","finished":true},""" +
                """{"api":"SYNO.FileStation.Delete","taskid":"safe-2","finished":false,"total":3},""" +
                "\"malformed-row\"" +
                "]}",
        )
        val page = repository(BackgroundTaskInterceptor(body))
            .listFileBackgroundTasks(offset = 10, limit = 100)

        assertEquals(listOf("safe-1", "safe-2"), page.tasks.map { it.id })
        assertEquals(10, page.offset)
        assertEquals(16, page.nextOffset)
        assertEquals(16, page.total)
        assertFalse(page.hasMore)
        assertFalse(page.toString().contains("/synthetic/private/task"))
    }

    @Test
    fun `空页停止分页且服务端分页值保持非负整数`() = runBlocking {
        val transport = BackgroundTaskInterceptor(
            success("""{"offset":2000000,"total":3000000,"tasks":[]}"""),
        )

        val page = repository(transport).listFileBackgroundTasks(offset = 20, limit = 0)

        assertEquals(2_000_000, page.offset)
        assertEquals(2_000_000, page.nextOffset)
        assertEquals(3_000_000, page.total)
        assertFalse(page.hasMore)
        assertEquals("1", transport.requests.single().formFields()["limit"])
    }

    @Test
    fun `能力不足零请求且服务端失败保持原始失败语义`() = runBlocking {
        val unsupportedTransport = BackgroundTaskInterceptor()
        val unsupported = runCatching {
            repository(unsupportedTransport, capabilityMaxVersion = 2).listFileBackgroundTasks()
        }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, unsupported.kind)
        assertTrue(unsupportedTransport.requests.isEmpty())

        val deniedTransport = BackgroundTaskInterceptor(
            """{"success":false,"error":{"code":105}}""",
        )
        val denied = runCatching {
            repository(deniedTransport).listFileBackgroundTasks()
        }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.PERMISSION_DENIED, denied.kind)
        assertEquals(1, deniedTransport.requests.size)
    }

    private fun repository(
        interceptor: Interceptor,
        capabilityMaxVersion: Int = 3,
    ) = authorizedRepository(
        profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        session = DsmSession("test", "test-session", "test-token"),
        api = DsmApiClient(
            OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build(),
        ),
        capabilities = listOf(
            ApiCapability(
                "SYNO.FileStation.BackgroundTask",
                "entry.cgi",
                1,
                capabilityMaxVersion,
            ),
        ).associateBy(ApiCapability::name),
    )

    private fun success(data: String) = """{"success":true,"data":$data}"""
}

private class BackgroundTaskInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = pending.removeFirstOrNull() ?: error("缺少合成后台任务响应")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }
}

private fun Request.formFields(): Map<String, String> {
    val form = body as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
