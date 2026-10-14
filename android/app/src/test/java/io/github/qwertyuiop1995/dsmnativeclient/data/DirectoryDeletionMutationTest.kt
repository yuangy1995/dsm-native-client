package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
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

class DirectoryDeletionMutationTest {
    @Test
    fun `账号删除使用名称数组并在目录消失后确认成功`() = runBlocking {
        val transport = DirectoryInterceptor(userList(), SUCCESS, emptyUsers())

        val result = repository(transport).deleteAccount(account())

        assertTrue(result.complete)
        assertEquals(NasDirectoryStage.COMPLETED, result.stages.last())
        assertEquals(listOf("list", "delete", "list"), transport.methods())
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "users/delete/synthetic-account/request.json",
        )
        assertEquals(USER_API, transport.requests[1].directoryFields()["api"])
        assertEquals("[\"$ACCOUNT\"]", transport.requests[1].directoryFields()["name"])
        assertTrue(transport.requests.all { it.directoryFields()["version"] == "1" })
    }

    @Test
    fun `群组删除使用专用 API 与名称数组`() = runBlocking {
        val transport = DirectoryInterceptor(groupList(), SUCCESS, emptyGroups())

        val result = repository(transport).deleteGroup(group())

        assertTrue(result.complete)
        assertEquals(NasDirectoryStage.COMPLETED, result.stages.last())
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "groups/delete/synthetic-group/request.json",
        )
        assertEquals(GROUP_API, transport.requests[1].directoryFields()["api"])
        assertEquals("[\"$GROUP\"]", transport.requests[1].directoryFields()["name"])
    }

    @Test
    fun `当前登录账号与系统保留目标读取完整目录后仍禁止删除`() = runBlocking {
        val accountTransport = DirectoryInterceptor(userList().replace(ACCOUNT, "operator"))
        val groupTransport = DirectoryInterceptor(groupList().replace(GROUP, "administrators"))
        val account = repository(accountTransport).deleteAccount(account().copy(name = "operator"))
        val group = repository(groupTransport).deleteGroup(group().copy(name = "administrators"))
        for (probe in listOf(account, group)) {
            assertEquals(NasDirectoryProblem.PERMISSION, (probe.failure as NasDirectoryFailure).problem)
            assertTrue(probe.stages.isEmpty())
        }
        assertEquals(listOf("list"), accountTransport.methods())
        assertEquals(listOf("list"), groupTransport.methods())
    }

    @Test
    fun `目录未明确允许删除时不发送写请求`() = runBlocking {
        val transport = DirectoryInterceptor(userList(canDelete = false))

        val result = repository(transport).deleteAccount(account(canDelete = false))

        assertEquals(NasDirectoryProblem.PERMISSION, (result.failure as NasDirectoryFailure).problem)
        assertTrue(result.stages.isEmpty())
        assertEquals(listOf("list"), transport.methods())
    }

    @Test
    fun `账号完整基线变化时严格冲突且零写入`() = runBlocking {
        val transport = DirectoryInterceptor(userList(description = "changed"))

        val result = repository(transport).deleteAccount(account())

        assertEquals(NasDirectoryProblem.CHANGED, (result.failure as NasDirectoryFailure).problem)
        assertTrue(result.stages.isEmpty())
        assertEquals(listOf("list"), transport.methods())
    }

    @Test
    fun `账号删除后回读根缺失不得冒充目标消失`() = runBlocking {
        val transport = DirectoryInterceptor(userList(), SUCCESS, SUCCESS)

        val result = repository(transport).deleteAccount(account())

        assertFalse(result.complete)
        assertEquals(listOf(NasDirectoryStage.SUBMITTED, NasDirectoryStage.ACCEPTED), result.stages)
        assertTrue(NasDirectoryStage.SUBMITTED in result.stages)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `账号 API 最低版本高于已验证版本时零请求返回不支持`() = runBlocking {
        val transport = DirectoryInterceptor()

        val result = repository(transport, userMinVersion = 2).deleteAccount(account())

        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (result.failure as DsmFailure).kind)
        assertTrue(result.stages.isEmpty())
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `账号删除明确权限拒绝时不自动重放`() = runBlocking {
        val transport = DirectoryInterceptor(userList(), PERMISSION_DENIED)

        val result = repository(transport).deleteAccount(account())

        assertEquals(DsmErrorKind.PERMISSION_DENIED, (result.failure as DsmFailure).kind)
        assertEquals(listOf(NasDirectoryStage.SUBMITTED, NasDirectoryStage.REJECTED), result.stages)
        assertTrue(NasDirectoryStage.SUBMITTED in result.stages)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `账号删除响应丢失后只回读且目标消失时确认成功`() = runBlocking {
        val transport = AmbiguousDirectoryInterceptor()

        val result = repository(transport).deleteAccount(account())

        assertTrue(result.complete)
        assertEquals(NasDirectoryStage.COMPLETED, result.stages.last())
        assertEquals(listOf("list", "delete", "list"), transport.methods())
    }

    @Test
    fun `群组删除响应丢失后只回读且不重放`() = runBlocking {
        val transport = AmbiguousDirectoryInterceptor(groupList(), emptyGroups())

        val result = repository(transport).deleteGroup(group())

        assertTrue(result.complete)
        assertEquals(NasDirectoryStage.COMPLETED, result.stages.last())
        assertEquals(listOf("list", "delete", "list"), transport.methods())
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `群组删除写后畸形回读保持未确认`() = runBlocking {
        val transport = DirectoryInterceptor(groupList(), SUCCESS, SUCCESS)

        val result = repository(transport).deleteGroup(group())

        assertFalse(result.complete)
        assertEquals(listOf(NasDirectoryStage.SUBMITTED, NasDirectoryStage.ACCEPTED), result.stages)
        assertTrue(NasDirectoryStage.SUBMITTED in result.stages)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `同一账号已有删除请求时第二次调用不访问网络`() = runBlocking {
        val transport = BlockingDirectoryInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.deleteAccount(account()) }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.deleteAccount(account().copy(name = ACCOUNT.uppercase()))
        assertEquals(NasDirectoryProblem.BUSY, (duplicate.failure as NasDirectoryFailure).problem)
        assertTrue(duplicate.stages.isEmpty())

        transport.allowSubmission.countDown()
        assertTrue(first.await().complete)
        assertEquals(listOf("list", "delete", "list"), transport.methods())
    }

    @Test
    fun `账号与群组删除在途取消不自动回读或重放`() = runBlocking {
        for (isGroup in listOf(false, true)) {
            val transport = BlockingDirectoryInterceptor(if (isGroup) groupList() else userList())
            val repo = repository(transport)
            var result: DirectoryProbe? = null
            val job = launch(Dispatchers.IO) {
                result = if (isGroup) repo.deleteGroup(group()) else repo.deleteAccount(account())
            }
            assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))
            job.cancel(); transport.allowSubmission.countDown(); job.join()
            assertTrue(result?.failure is CancellationException)
            assertEquals(listOf(NasDirectoryStage.SUBMITTED), result?.stages)
            assertEquals(listOf("list", "delete"), transport.methods())
        }
    }

    @Test
    fun `Android 请求层可按公共 Fixture 编码账号创建`() = runBlocking {
        val transport = DirectoryInterceptor(SUCCESS)
        val api = DsmApiClient(OkHttpClient.Builder().addInterceptor(transport).build())

        api.call(
            NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
            DsmSession("test", "test-session", "test-token"),
            ApiCapability(USER_API, "entry.cgi", 1, 1),
            "create",
            mapOf(
                "name" to "synthetic-account",
                "password" to "synthetic-secret",
                "password_confirm" to "synthetic-secret",
                "description" to "synthetic-description",
                "email" to "synthetic@example.invalid",
                "expired" to "false",
            ),
        )

        RequestFixtureAssertions.assertRequest(
            transport.requests.single(),
            "users/create/synthetic-account/request.json",
        )
    }

    private fun repository(interceptor: Interceptor, userMinVersion: Int = 1) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            if (chain.request().directoryFields()["api"] == "SYNO.Core.System") directoryResponse(chain.request(),
                """{"success":true,"data":{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}}""")
            else chain.proceed(chain.request())
        }.addInterceptor(interceptor).build()),
        mapOf(
            "SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 1),
            USER_API to ApiCapability(USER_API, "entry.cgi", userMinVersion, 5),
            GROUP_API to ApiCapability(GROUP_API, "entry.cgi", 1, 5),
        ),
    )

    private data class DirectoryProbe(val stages: MutableList<NasDirectoryStage> = mutableListOf(), var complete: Boolean = false, var failure: Exception? = null)
    private suspend fun DsmRepository.deleteAccount(original: NasAccount) = probeDirectory(
        NasDirectoryChange(NasDirectoryKind.ACCOUNT, NasDirectoryAction.DELETE, original.name, account = original))
    private suspend fun DsmRepository.deleteGroup(original: NasGroup) = probeDirectory(
        NasDirectoryChange(NasDirectoryKind.GROUP, NasDirectoryAction.DELETE, original.name, group = original))
    private suspend fun DsmRepository.probeDirectory(change: NasDirectoryChange): DirectoryProbe {
        val probe = DirectoryProbe()
        try { probe.complete = directory.change(change) { probe.stages += it } } catch (error: Exception) { probe.failure = error }
        return probe
    }

    companion object {
        const val USER_API = "SYNO.Core.User"
        const val GROUP_API = "SYNO.Core.Group"
        const val ACCOUNT = "synthetic-account"
        const val GROUP = "synthetic-group"
        const val SUCCESS = """{"success":true,"data":{}}"""
        const val PERMISSION_DENIED = """{"success":false,"error":{"code":105}}"""
        fun userList(canDelete: Boolean = true, description: String? = null): String {
            val descriptionField = description?.let { "\"description\":\"$it\"," }.orEmpty()
            return """{"success":true,"data":{"users":[{$descriptionField"name":"$ACCOUNT","additional":{"can_delete":$canDelete}}]}}"""
        }
        fun groupList() =
            """{"success":true,"data":{"groups":[{"name":"$GROUP","additional":{"can_delete":true}}]}}"""
        fun emptyUsers() = """{"success":true,"data":{"users":[]}}"""
        fun emptyGroups() = """{"success":true,"data":{"groups":[]}}"""
        fun account(canDelete: Boolean = true) =
            NasAccount(null, ACCOUNT, null, null, false, canDelete, disabledKnown = false)
        fun group() = NasGroup(null, GROUP, null, true)
    }
}

private class DirectoryInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return directoryResponse(request, pending.removeFirstOrNull() ?: error("缺少合成目录响应"))
    }
    fun methods() = requests.map { it.directoryFields()["method"] }
}

private class AmbiguousDirectoryInterceptor(
    private val initialList: String = DirectoryDeletionMutationTest.userList(),
    private val finalList: String = DirectoryDeletionMutationTest.emptyUsers(),
) : Interceptor {
    val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        if (requests.size == 2) throw IOException("synthetic ambiguous account delete")
        return directoryResponse(
            request,
            if (requests.size == 1) initialList else finalList,
        )
    }
    fun methods() = requests.map { it.directoryFields()["method"] }
}

private class BlockingDirectoryInterceptor(private val initialList: String = DirectoryDeletionMutationTest.userList()) : Interceptor {
    val submissionStarted = CountDownLatch(1)
    val allowSubmission = CountDownLatch(1)
    private val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val index = synchronized(requests) { requests += request; requests.size }
        val body = when (index) {
            1 -> initialList
            2 -> {
                submissionStarted.countDown()
                check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待合成账号删除请求放行超时" }
                DirectoryDeletionMutationTest.SUCCESS
            }
            else -> DirectoryDeletionMutationTest.emptyUsers()
        }
        return directoryResponse(request, body)
    }
    fun methods() = synchronized(requests) { requests.map { it.directoryFields()["method"] } }
}

private fun directoryResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.directoryFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
