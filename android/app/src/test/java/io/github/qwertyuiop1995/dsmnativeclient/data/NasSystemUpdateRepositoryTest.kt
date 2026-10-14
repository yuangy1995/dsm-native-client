package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
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

class NasSystemUpdateRepositoryTest {
    @Test
    fun `更新检查固定使用v3参数并规范化候选结果`() = runBlocking {
        val transport = SystemUpdateInterceptor(
            """{"success":true,"data":{"firmware_ver":" DSM 7.2.1 "}}""",
            """{"success":true,"data":{"update":{"version":" DSM 7.2.2 ","release_note":" Reliability improvements. "},"promotion":null}}""",
        )

        val info = repository(transport).checkSystemUpdate()

        assertTrue(info.isUpdateAvailable)
        assertEquals("DSM 7.2.1", info.currentVersion)
        assertEquals("DSM 7.2.2", info.latestVersion)
        assertEquals("Reliability improvements.", info.releaseNotes)
        assertEquals(2, transport.requests.size)
        val request = transport.requests[1].updateFields()
        assertEquals("SYNO.Core.Upgrade.Server", request["api"])
        assertEquals("check", request["method"])
        assertEquals("3", request["version"])
        assertEquals("true", request["user_reading"])
        assertEquals("true", request["need_auto_smallupdate"])
        assertEquals("false", request["need_promotion"])
        assertEquals("synthetic-session", request["_sid"])
        assertEquals("synthetic-token", request["SynoToken"])
        assertTrue(transport.requests[1].url.query.isNullOrBlank())
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "system-update/check/synthetic-nas/request.json",
        )
    }

    @Test
    fun `没有候选或候选版本相同时不伪造可用更新`() = runBlocking {
        for (update in listOf("null", "{\"version\":\"DSM 7.2.1\"}")) {
            val transport = SystemUpdateInterceptor(
                """{"success":true,"data":{"firmware_ver":"DSM 7.2.1"}}""",
                """{"success":true,"data":{"update":$update,"promotion":null}}""",
            )

            val info = repository(transport).checkSystemUpdate()

            assertFalse(info.isUpdateAvailable)
            assertEquals("DSM 7.2.1", info.currentVersion)
            if (update == "null") {
                assertNull(info.latestVersion)
                assertNull(info.releaseNotes)
            }
        }
    }

    @Test
    fun `运行时未发现更新v3时零请求并明确不支持`() = runBlocking {
        val transport = SystemUpdateInterceptor()

        val failure = runCatching {
            repository(transport, updateMaxVersion = 2).checkSystemUpdate()
        }.exceptionOrNull()

        assertTrue(failure is DsmFailure)
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (failure as DsmFailure).kind)
        assertTrue(transport.requests.isEmpty())
    }

    private fun repository(
        interceptor: Interceptor,
        updateMaxVersion: Int = 3,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        listOf(
            ApiCapability("SYNO.Core.System", "entry.cgi", 1, 3),
            ApiCapability("SYNO.Core.Upgrade.Server", "entry.cgi", 1, updateMaxVersion),
        ).associateBy(ApiCapability::name),
    )
}

private class SystemUpdateInterceptor(vararg responses: String) : Interceptor {
    private val responses = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        requests += chain.request()
        val body = responses.removeFirstOrNull() ?: """{"success":true,"data":{}}"""
        return Response.Builder()
            .request(chain.request())
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}

private fun Request.updateFields(): Map<String, String> {
    val form = body as FormBody
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
