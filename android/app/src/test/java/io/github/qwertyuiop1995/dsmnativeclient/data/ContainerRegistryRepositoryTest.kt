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
import org.junit.Assert.assertTrue
import org.junit.Test

class ContainerRegistryRepositoryTest {
    @Test
    fun `搜索镜像提交固定分页契约并解析仓库信息`() = runBlocking {
        val transport = RegistryInterceptor(
            """{"success":true,"data":{"data":[{"name":"nginx","registry":"docker.io","description":"Web server","star_count":100,"is_official":true}]}}""",
        )

        val images = repository(transport).searchContainerRegistry(" nginx ")

        assertEquals(listOf("nginx"), images.map { it.name })
        assertEquals(100, images.single().starCount)
        assertTrue(images.single().isOfficial)
        val fields = transport.requests.single().registryFormFields()
        assertEquals("search", fields["method"])
        assertEquals("1", fields["version"])
        assertEquals("0", fields["offset"])
        assertEquals("50", fields["limit"])
        assertEquals("50", fields["page_size"])
        assertEquals("nginx", fields["q"])
    }

    @Test
    fun `读取标签使用repo参数并保持首个顺序去重`() = runBlocking {
        val transport = RegistryInterceptor(
            """{"success":true,"data":[{"tag":"latest"},{"tag":"stable"},{"tag":"latest"}]}""",
        )

        val tags = repository(transport).containerRegistryTags("library/nginx")

        assertEquals(listOf("latest", "stable"), tags)
        val fields = transport.requests.single().registryFormFields()
        assertEquals("tags", fields["method"])
        assertEquals("library/nginx", fields["repo"])
    }

    @Test
    fun `能力未发现时关闭镜像仓库读取且不发送请求`() = runBlocking {
        val transport = RegistryInterceptor()
        val repo = repository(transport, includeCapability = false)

        val failure = runCatching { repo.searchContainerRegistry("nginx") }.exceptionOrNull()

        assertTrue(failure is DsmFailure)
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (failure as DsmFailure).kind)
        assertTrue(transport.requests.isEmpty())
    }

    private fun repository(
        interceptor: Interceptor,
        includeCapability: Boolean = true,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        if (includeCapability) mapOf(
            REGISTRY_API to ApiCapability(REGISTRY_API, "Docker/registry.cgi", 1, 1),
        ) else emptyMap(),
    )

    private companion object {
        const val REGISTRY_API = "SYNO.Docker.Registry"
    }
}

private class RegistryInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = pending.removeFirstOrNull() ?: error("缺少合成 Registry 响应")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}

private fun Request.registryFormFields(): Map<String, String> {
    val form = body as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
