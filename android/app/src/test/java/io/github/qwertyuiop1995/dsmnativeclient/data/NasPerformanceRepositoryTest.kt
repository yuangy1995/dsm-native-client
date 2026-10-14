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

class NasPerformanceRepositoryTest {
    @Test
    fun `性能采样固定使用v1并解析实际嵌套结构`() = runBlocking {
        val transport = PerformanceInterceptor(
            """{"success":true,"data":{
                "time":100,
                "cpu":{"user_load":12,"system_load":5,"other_load":3},
                "memory":{"real_usage":46,"swap_usage":2},
                "network":[{"device":"eth0","rx":1,"tx":2},{"device":"total","rx":1024,"tx":2048}],
                "disk":{"total":{"read_byte":4096,"write_byte":8192,"utilization":15}},
                "space":{"total":{"read_byte":3000,"write_byte":4000}}
            }}""",
        )

        val sample = repository(transport).performanceSample()

        assertEquals(100L, sample.timeEpochSeconds)
        assertEquals(20.0, sample.cpuPercent!!, 0.001)
        assertEquals(46.0, sample.memoryPercent!!, 0.001)
        assertEquals(1_024L, sample.networkReceiveBytesPerSecond)
        assertEquals(2_048L, sample.networkSendBytesPerSecond)
        assertEquals(4_096L, sample.diskReadBytesPerSecond)
        assertEquals(8_192L, sample.diskWriteBytesPerSecond)
        assertEquals(3_000L, sample.volumeReadBytesPerSecond)
        assertEquals(4_000L, sample.volumeWriteBytesPerSecond)
        assertEquals(15.0, sample.diskUtilizationPercent!!, 0.001)
        val fields = transport.request!!.formFields()
        assertEquals("SYNO.Core.System.Utilization", fields["api"])
        assertEquals("get", fields["method"])
        assertEquals("1", fields["version"])
        assertEquals("all", fields["resource"])
        assertEquals("current", fields["type"])
        assertEquals("synthetic-session", fields["_sid"])
        assertEquals("synthetic-token", fields["SynoToken"])
        assertTrue(transport.request!!.url.query.isNullOrBlank())
        RequestFixtureAssertions.assertRequest(
            transport.request!!,
            "system-performance/read-current/synthetic-nas/request.json",
        )
    }

    @Test
    fun `性能比例和速率在异常响应下安全收敛且缺失总网络不伪造数值`() = runBlocking {
        val transport = PerformanceInterceptor(
            """{"success":true,"data":{
                "time":1700000000000,
                "cpu":{"user_load":80,"system_load":50,"other_load":30},
                "memory":{"real_usage":-4,"swap_usage":130},
                "network":[{"device":"eth0","rx":99,"tx":88}],
                "disk":{"total":{"read_byte":-1,"write_byte":7,"utilization":150}}
            }}""",
        )

        val sample = repository(transport).performanceSample()

        assertEquals(1_700_000_000L, sample.timeEpochSeconds)
        assertEquals(100.0, sample.cpuPercent!!, 0.001)
        assertEquals(0.0, sample.memoryPercent!!, 0.001)
        assertEquals(100.0, sample.swapPercent!!, 0.001)
        assertNull(sample.networkReceiveBytesPerSecond)
        assertNull(sample.networkSendBytesPerSecond)
        assertEquals(0L, sample.diskReadBytesPerSecond)
        assertEquals(7L, sample.diskWriteBytesPerSecond)
        assertEquals(100.0, sample.diskUtilizationPercent!!, 0.001)
    }

    @Test
    fun `运行时未发现性能v1时零请求并明确不支持`() = runBlocking {
        val transport = PerformanceInterceptor("""{"success":true,"data":{}}""")
        val repository = repository(transport, includeCapability = false)

        assertFalse(repository.supportsPerformance())
        val failure = runCatching { repository.performanceSample() }.exceptionOrNull()

        assertTrue(failure is DsmFailure)
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (failure as DsmFailure).kind)
        assertNull(transport.request)
    }

    @Test
    fun `性能固定页能力门禁只接受已发现的Utilization v1`() {
        assertTrue(repository(PerformanceInterceptor("{}"), includeCapability = true).supportsPerformance())
        assertFalse(repository(PerformanceInterceptor("{}"), includeCapability = false).supportsPerformance())
    }

    private fun repository(
        interceptor: Interceptor,
        includeCapability: Boolean = true,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        if (includeCapability) {
            mapOf(
                "SYNO.Core.System.Utilization" to ApiCapability(
                    "SYNO.Core.System.Utilization",
                    "entry.cgi",
                    1,
                    1,
                ),
            )
        } else {
            emptyMap()
        },
    )
}

private class PerformanceInterceptor(private val response: String) : Interceptor {
    var request: Request? = null

    override fun intercept(chain: Interceptor.Chain): Response {
        request = chain.request()
        return Response.Builder()
            .request(chain.request())
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(response.toResponseBody("application/json".toMediaType()))
            .build()
    }
}

private fun Request.formFields(): Map<String, String> {
    val form = body as FormBody
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
