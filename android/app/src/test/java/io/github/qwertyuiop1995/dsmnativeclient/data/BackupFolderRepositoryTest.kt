package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
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
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupFolderRepositoryTest {
    @Test
    fun `来源目录的末尾空格不会被改成普通同名目录`() = runBlocking {
        val transport = BackupFolderInterceptor(
            listResponse("Trips", "/share/Trips"), infoResponse("share", "/share"),
            listResponse("Trips", "/share/Trips"), successResponse, infoResponse("Trips ", "/share/Trips "),
        )
        val result = repository(transport).ensureSubdirectoryResult("/share", "/share/Trips ")
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals("Trips ", transport.requests.single { it.backupFields()["method"] == "create" }.backupFields()["name"])
        assertEquals("[\"/share/Trips \"]", transport.requests.last().backupFields()["path"])
    }

    @Test
    fun `目录计划中的点路径和重复分隔符在网络访问前拒绝`() = runBlocking {
        for (path in listOf("/share/../other", "/share/./child", "/share//child")) {
            val transport = BackupFolderInterceptor()
            assertTrue(runCatching { repository(transport).ensureSubdirectoryResult("/share", path) }.exceptionOrNull() is IllegalArgumentException)
            assertTrue(transport.requests.isEmpty())
        }
    }

    @Test
    fun `自动备份只在配置根目录下逐层创建子目录`() = runBlocking {
        val transport = BackupFolderInterceptor(
            """{"success":true,"data":{"offset":0,"total":0,"files":[]}}""",
            """{"success":true,"data":{"files":[{"name":"移动备份","path":"/photo/移动备份","isdir":true,"additional":{"perm":{"write":true}}}]}}""",
            """{"success":true,"data":{"offset":0,"total":0,"files":[]}}""",
            """{"success":true,"data":{}}""",
            """{"success":true,"data":{"files":[{"name":"旅行","path":"/photo/移动备份/旅行","isdir":true,"additional":{"perm":{"write":true}}}]}}""",
        )

        val result = repository(transport).ensureSubdirectoryResult(
            "/photo/移动备份",
            "/photo/移动备份/旅行",
        )

        assertEquals(
            listOf("list", "getinfo", "list", "create", "getinfo"),
            transport.requests.map { it.backupFields()["method"] },
        )
        assertEquals("/photo/移动备份", transport.requests[3].backupFields()["folder_path"])
        assertEquals("旅行", transport.requests[3].backupFields()["name"])
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertTrue(result.submitted)
    }

    @Test
    fun `拒绝在配置根目录之外创建备份目录`() = runBlocking {
        val transport = BackupFolderInterceptor()

        val failure = runCatching {
            repository(transport).ensureSubdirectoryResult("/photo/移动备份", "/photo/其他")
        }.exceptionOrNull()

        assertTrue(failure is IllegalArgumentException)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `后续层级失败时保留已创建层级和部分成功语义`() = runBlocking {
        val transport = BackupFolderInterceptor(
            emptyListResponse,
            infoResponse("移动备份", "/photo/移动备份"),
            emptyListResponse,
            successResponse,
            infoResponse("旅行", "/photo/移动备份/旅行"),
            emptyListResponse,
            infoResponse("旅行", "/photo/移动备份/旅行"),
            emptyListResponse,
            successResponse,
            emptyListResponse,
            emptyListResponse,
        )

        val result = repository(transport).ensureSubdirectoryResult(
            "/photo/移动备份",
            "/photo/移动备份/旅行/夏天",
        )

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.failed)
        assertEquals(0, result.counts.unknown)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
        assertEquals(2, transport.requests.count { it.backupFields()["method"] == "create" })
    }

    @Test
    fun `提交后无法读回时保留未知且不重放创建`() = runBlocking {
        val transport = BackupFolderInterceptor(
            emptyListResponse,
            infoResponse("移动备份", "/photo/移动备份"),
            emptyListResponse,
            successResponse,
            "{",
            "{",
        )

        val result = repository(transport).ensureSubdirectoryResult(
            "/photo/移动备份",
            "/photo/移动备份/旅行",
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.backupFields()["method"] == "create" })
    }

    @Test
    fun `目录创建提交断线后只读回读且不重放`() = runBlocking {
        val transport = BackupFolderInterceptor(
            emptyListResponse,
            infoResponse("移动备份", "/photo/移动备份"),
            emptyListResponse,
            disconnectResponse,
            emptyListResponse,
        )

        val result = repository(transport).ensureSubdirectoryResult(
            "/photo/移动备份",
            "/photo/移动备份/旅行",
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
        assertEquals(1, result.counts.unknown)
        assertEquals(1, transport.requests.count { it.backupFields()["method"] == "create" })
    }

    @Test
    fun `并发创建只有读回确认为目录后才算成功`() = runBlocking {
        val transport = BackupFolderInterceptor(
            emptyListResponse,
            infoResponse("移动备份", "/photo/移动备份"),
            listResponse("旅行", "/photo/移动备份/旅行"),
            infoResponse("旅行", "/photo/移动备份/旅行"),
        )

        val result = repository(transport).ensureSubdirectoryResult(
            "/photo/移动备份",
            "/photo/移动备份/旅行",
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(0, transport.requests.count { it.backupFields()["method"] == "create" })
        assertEquals("getinfo", transport.requests.last().backupFields()["method"])
    }

    @Test
    fun `取消发生在提交前后时返回不同状态`() {
        val repository = repository(BackupFolderInterceptor())
        val beforeResult = repository.backupFolderEnsureCancellationResult(0, false, 0)
        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, beforeResult.status)
        assertTrue(!beforeResult.submitted)

        val afterResult = repository.backupFolderEnsureCancellationResult(1, true, 1)
        assertEquals(
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            afterResult.status,
        )
        assertTrue(afterResult.submitted)
        assertTrue(afterResult.requiresRefresh)
        assertEquals(1, afterResult.counts.succeeded)
        assertEquals(1, afterResult.counts.unknown)
    }

    private fun repository(interceptor: Interceptor) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build()),
        listOf(
            ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
            ApiCapability("SYNO.FileStation.CreateFolder", "entry.cgi", 1, 2),
        ).associateBy(ApiCapability::name),
    )

    private companion object {
        const val emptyListResponse = """{"success":true,"data":{"offset":0,"total":0,"files":[]}}"""
        const val successResponse = """{"success":true,"data":{}}"""
        const val disconnectResponse = "__disconnect__"

        fun infoResponse(name: String, path: String) =
            """{"success":true,"data":{"files":[{"name":"$name","path":"$path","isdir":true,"additional":{"perm":{"write":true}}}]}}"""

        fun listResponse(name: String, path: String) =
            """{"success":true,"data":{"offset":0,"total":1,"files":[{"name":"$name","path":"$path","isdir":true,"additional":{"perm":{"write":true}}}]}}"""
    }
}

private class BackupFolderInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = pending.removeFirstOrNull() ?: error("缺少合成备份目录响应")
        if (body == "__disconnect__") throw IOException("synthetic disconnect")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                body.toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private fun Request.backupFields(): Map<String, String> {
    val form = body as FormBody
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
