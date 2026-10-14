package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.File
import kotlinx.coroutines.runBlocking
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

class FilePreviewRepositoryTest {
    @Test
    fun `缩略图使用公开Thumb接口与小尺寸参数`() = runBlocking {
        val transport = PreviewRepositoryInterceptor(
            PreviewRepositoryResponse(200, "image".encodeToByteArray(), "image/jpeg"),
        )

        val bytes = repository(transport).thumbnail("/share/photo.jpg")

        assertEquals("image", bytes.decodeToString())
        val request = transport.requests.single()
        assertEquals("SYNO.FileStation.Thumb", request.url.queryParameter("api"))
        assertEquals("get", request.url.queryParameter("method"))
        assertEquals("small", request.url.queryParameter("size"))
        assertEquals("0", request.url.queryParameter("rotate"))
        assertEquals("/share/photo.jpg", request.url.queryParameter("path"))
    }

    @Test
    fun `文本预览只请求前段并标记截断`() = runBlocking {
        val previewBytes = ByteArray(512 * 1024) { 'a'.code.toByte() }
        val transport = PreviewRepositoryInterceptor(
            PreviewRepositoryResponse(
                206,
                previewBytes,
                "text/plain",
                "bytes 0-524287/524290",
            ),
        )

        val (text, truncated) = repository(transport).readTextPreview(
            FileItem("/share/readme.txt", "readme.txt", isDirectory = false, size = 524_290),
        )

        assertEquals(previewBytes.size, text.length)
        assertTrue(text.all { it == 'a' })
        assertTrue(truncated)
        val request = transport.requests.single()
        assertEquals("SYNO.FileStation.Download", request.url.queryParameter("api"))
        assertEquals("download", request.url.queryParameter("method"))
        assertEquals("bytes=0-524287", request.header("Range"))
        assertEquals("[\"/share/readme.txt\"]", request.url.queryParameter("path"))
    }

    @Test
    fun `视频预览使用公开下载接口写入受限临时文件`() = runBlocking {
        val bytes = "synthetic-video".encodeToByteArray()
        val transport = PreviewRepositoryInterceptor(
            PreviewRepositoryResponse(200, bytes, "video/mp4"),
        )
        val destination = File.createTempFile("video-preview-", ".mp4")
        try {
            repository(transport).downloadPreview(
                FileItem(
                    "/share/clip.mp4",
                    "clip.mp4",
                    isDirectory = false,
                    size = bytes.size.toLong(),
                ),
                destination,
            )

            assertTrue(bytes.contentEquals(destination.readBytes()))
            val request = transport.requests.single()
            assertEquals("SYNO.FileStation.Download", request.url.queryParameter("api"))
            assertEquals("download", request.url.queryParameter("method"))
        } finally {
            destination.delete()
        }
    }

    @Test
    fun `已知大小音视频按位置读取并严格使用Range响应`() {
        val transport = PreviewRepositoryInterceptor(
            PreviewRepositoryResponse(
                206,
                "hetic".encodeToByteArray(),
                "video/mp4",
                "bytes 4-8/15",
            ),
        )
        val source = repository(transport).streamingMediaSource(
            FileItem("/share/clip.mp4", "clip.mp4", isDirectory = false, size = 15),
        )
        val buffer = ByteArray(8)

        val count = source.readAt(position = 4, buffer = buffer, offset = 1, length = 5)

        assertEquals(5, count)
        assertEquals("hetic", buffer.copyOfRange(1, 6).decodeToString())
        assertEquals(-1, source.readAt(position = 15, buffer = buffer, offset = 0, length = 1))
        val request = transport.requests.single()
        assertEquals("bytes=4-8", request.header("Range"))
        assertEquals("SYNO.FileStation.Download", request.url.queryParameter("api"))
        assertEquals("[\"/share/clip.mp4\"]", request.url.queryParameter("path"))
        source.close()
    }

    @Test
    fun `超出视频预览上限时不会发出下载请求`() = runBlocking {
        val transport = PreviewRepositoryInterceptor()
        val destination = File.createTempFile("video-preview-large-", ".mp4")
        val failure = try {
            runCatching {
                repository(transport).downloadPreview(
                    FileItem(
                        "/share/large.mp4",
                        "large.mp4",
                        isDirectory = false,
                        size = 256L * 1024L * 1024L + 1,
                    ),
                    destination,
                )
            }.exceptionOrNull() as DsmFailure
        } finally {
            destination.delete()
        }

        assertEquals(DsmErrorKind.PREVIEW_TOO_LARGE, failure.kind)
        assertTrue(transport.requests.isEmpty())
    }

    private fun repository(interceptor: Interceptor): DsmRepository {
        val capabilities = listOf(
            ApiCapability("SYNO.FileStation.Thumb", "entry.cgi", 1, 2),
            ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 2),
        ).associateBy(ApiCapability::name)
        return authorizedRepository(
            profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
            session = DsmSession("test", "test-session", "test-token"),
            api = DsmApiClient(
                OkHttpClient.Builder()
                    .retryOnConnectionFailure(false)
                    .addInterceptor(interceptor)
                    .build(),
            ),
            capabilities = capabilities,
        )
    }
}

private data class PreviewRepositoryResponse(
    val code: Int,
    val body: ByteArray,
    val contentType: String,
    val contentRange: String? = null,
)

private class PreviewRepositoryInterceptor(vararg responses: PreviewRepositoryResponse) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val response = pending.removeFirstOrNull() ?: error("缺少合成响应")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(response.code)
            .message("OK")
            .apply { response.contentRange?.let { header("Content-Range", it) } }
            .body(response.body.toResponseBody(response.contentType.toMediaType()))
            .build()
    }
}
