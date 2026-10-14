package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerSection
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContainerMutationResultTest {
    @Test
    fun `概览固定使用容器列表契约且附加分区失败不遮挡主列表`() = runBlocking {
        val transport = ContainerOverviewInterceptor()
        val overview = repository(
            transport,
            "SYNO.Docker.Container",
            "SYNO.Docker.Image",
            "SYNO.Docker.Network",
            "SYNO.Docker.Project",
            "SYNO.Docker.Log",
        ).containerOverview()

        assertEquals(listOf("Container 1"), overview.containers.map { it.name })
        assertEquals(listOf("Network 1"), overview.networks.map { it.name })
        assertTrue(ContainerSection.IMAGES in overview.unavailableSections)
        assertFalse(ContainerSection.NETWORKS in overview.unavailableSections)
        val mainRequest = transport.requests.first()
        assertEquals("SYNO.Docker.Container", mainRequest.formFields()["api"])
        assertEquals("1", mainRequest.formFields()["version"])
        assertEquals("0", mainRequest.formFields()["offset"])
        assertEquals("-1", mainRequest.formFields()["limit"])
        assertEquals("all", mainRequest.formFields()["type"])
    }

    @Test
    fun `旧未绑定确认快照的容器写门面稳定拒绝且零请求`() = runBlocking {
        val transport = ContainerMutationInterceptor()
        val repository = repository(
            transport,
            "SYNO.Docker.Container",
            "SYNO.Docker.Image",
            "SYNO.Docker.Network",
        )

        assertFalse(repository.supportsVerifiedContainerWrites())
        val results = listOf(
            repository.controlContainerResult("container-1", "start"),
            repository.controlContainerResult("container-1", "stop"),
            repository.controlContainerResult("container-1", "restart"),
            repository.deleteContainerResult("container-1"),
            repository.deleteContainerImageResult("image-1"),
            repository.createContainerNetworkResult("network-1", "bridge"),
            repository.deleteContainerNetworkResult("network-1"),
        )

        results.forEach { result ->
            assertEquals(MutationResultStatus.UNSUPPORTED, result.status)
            assertEquals(MutationErrorCategory.UNSUPPORTED, result.errorCategory)
            assertFalse(result.submitted)
            assertFalse(result.requiresRefresh)
            assertEquals(0, result.counts.succeeded)
            assertEquals(1, result.counts.failed)
            assertEquals(0, result.counts.unknown)
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `主容器结构异常进入失败而不是空总览`() = runBlocking {
        val result = runCatching {
            repository(MalformedContainerOverviewInterceptor("SYNO.Docker.Container"))
                .containerOverview()
        }

        val failure = result.exceptionOrNull() as io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
        assertEquals(DsmErrorKind.INVALID_RESPONSE, failure.kind)
    }

    @Test
    fun `附属分区结构异常标记不可用而不是零数量`() = runBlocking {
        val overview = repository(
            MalformedContainerOverviewInterceptor("SYNO.Docker.Image"),
            "SYNO.Docker.Container",
            "SYNO.Docker.Image",
        ).containerOverview()

        assertEquals(1, overview.containers.size)
        assertTrue(ContainerSection.IMAGES in overview.unavailableSections)
    }

    private fun repository(
        interceptor: Interceptor,
        vararg capabilityNames: String = arrayOf("SYNO.Docker.Container"),
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        capabilityNames.associateWith { name ->
            ApiCapability(
                name,
                "entry.cgi",
                1,
                1,
            )
        },
    )

}

private class MalformedContainerOverviewInterceptor(
    private val malformedApi: String,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val api = request.formFields()["api"]
        val body = when {
            api == malformedApi -> """{"success":true,"data":{"unexpected":[]}}"""
            api == "SYNO.Docker.Container" ->
                """{"success":true,"data":{"containers":[{"id":"c1","name":"Container 1","status":"running"}]}}"""
            else -> error("未处理的合成 Container Manager API")
        }
        return syntheticResponse(request, body)
    }
}

private class ContainerOverviewInterceptor : Interceptor {
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = when (request.formFields()["api"]) {
            "SYNO.Docker.Container" ->
                """{"success":true,"data":{"containers":[{"id":"c1","name":"Container 1","status":"running"}]}}"""
            "SYNO.Docker.Image" -> """{"success":false,"error":{"code":105}}"""
            "SYNO.Docker.Network" ->
                """{"success":true,"data":{"networks":[{"id":"n1","name":"Network 1","driver":"bridge","containers":[],"enable_ipv6":false}]}}"""
            "SYNO.Docker.Project" -> """{"success":true,"data":{}}"""
            "SYNO.Docker.Log" -> """{"success":true,"data":{"logs":[]}}"""
            else -> error("未处理的合成 Container Manager API")
        }
        return syntheticResponse(request, body)
    }
}

private class ContainerMutationInterceptor : Interceptor {
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        error("行为未验证的 Container Manager 写操作不应发出请求")
    }
}

private fun syntheticResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.formFields(): Map<String, String> {
    val form = body as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
