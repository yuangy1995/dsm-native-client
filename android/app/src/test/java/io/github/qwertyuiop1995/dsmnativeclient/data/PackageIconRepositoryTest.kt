package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.PackageInfo
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PackageIconRepositoryTest {
    @Test
    fun `能力存在时按 v1 精确读取图片且凭据不进入 URL`() = runBlocking {
        val transport = BinaryInterceptor(PNG_HEADER)

        val result = repository(transport, supportsIcon = true).packageIcon(packageInfo())

        assertTrue(result.contentEquals(PNG_HEADER))
        val request = transport.requests.single()
        assertEquals("SYNO.Core.Package.Thumb", request.url.queryParameter("api"))
        assertEquals("get", request.url.queryParameter("method"))
        assertEquals("1", request.url.queryParameter("version"))
        assertEquals("synthetic-package", request.url.queryParameter("name"))
        assertEquals("1.0", request.url.queryParameter("ver"))
        assertEquals("128", request.url.queryParameter("size"))
        assertFalse(request.url.toString().contains("test-session"))
        assertFalse(request.url.toString().contains("test-token"))
    }

    @Test
    fun `能力缺失时零请求失败关闭`() = runBlocking {
        val transport = BinaryInterceptor(PNG_HEADER)

        val failure = runCatching { repository(transport, supportsIcon = false).packageIcon(packageInfo()) }

        assertTrue(failure.isFailure)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `非图片响应被拒绝且常见位图签名被识别`() = runBlocking {
        val transport = BinaryInterceptor("<html>not an image</html>".encodeToByteArray())

        assertTrue(runCatching { repository(transport, true).packageIcon(packageInfo()) }.isFailure)
        assertTrue(hasKnownPackageIconSignature(PNG_HEADER))
        assertTrue(hasKnownPackageIconSignature(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte())))
        assertTrue(hasKnownPackageIconSignature("GIF89a".encodeToByteArray()))
        assertTrue(hasKnownPackageIconSignature("RIFF0000WEBP".encodeToByteArray()))
        assertFalse(hasKnownPackageIconSignature("<svg/>".encodeToByteArray()))
    }

    private fun repository(transport: Interceptor, supportsIcon: Boolean) = authorizedRepository(
        profile = NasProfile("nas-a", "NAS", "https://nas.example.invalid", "tester"),
        session = DsmSession("nas-a", "test-session", "test-token"),
        api = DsmApiClient(OkHttpClient.Builder().addInterceptor(transport).build()),
        capabilities = if (supportsIcon) mapOf(
            "SYNO.Core.Package.Thumb" to ApiCapability(
                "SYNO.Core.Package.Thumb", "entry.cgi", 1, 1,
            ),
        ) else emptyMap(),
    )

    private fun packageInfo() = PackageInfo(
        id = "synthetic-package",
        name = "Synthetic Package",
        version = "1.0",
        status = ResourceState.RUNNING,
        description = null,
        canStart = false,
        canStop = true,
    )

    private companion object {
        val PNG_HEADER = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    }
}

private class BinaryInterceptor(private val bytes: ByteArray) : Interceptor {
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(bytes.toResponseBody())
            .build()
    }
}
