package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.MediaType.Companion.toMediaType
import okio.Buffer
import okio.ForwardingSink
import okio.blackholeSink
import okio.buffer
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosAutomaticPreviewTransportTest {
    private val cap = ApiCapability("SYNO.Foto.Upload.ConvertedFile", "entry.cgi", 1, 3, "JSON")
    private fun media(respond: (Request) -> Response) = SynologyPhotosMediaTransport(
        NasProfile("p", "Synthetic", "nas.example.invalid", "Synthetic"), DsmSession("p", "synthetic-session", "synthetic-token"),
        "https://nas.example.invalid", OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .addInterceptor { respond(it.request()) }.build())
    private fun response(request: Request, bytes: ByteArray = "{\"success\":true}".toByteArray(), type: String = "application/json", code: Int = 200) =
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(code).message("Synthetic")
            .header("Content-Type", type).body(bytes.toResponseBody(type.toMediaType())).build()

    @Test fun `八MiB视频请求有界写出且外层标记不可重放并隐藏源路径`() = runBlocking {
        val cache = Files.createTempDirectory("automatic-preview-transport-").toFile()
        try {
            val file = File(cache, "private-original-name.mp4").also { f -> f.outputStream().use { out -> repeat(128) { out.write(ByteArray(65_536) { 17 }) } } }
            var calls = 0
            val transport = media { request -> calls++
                assertTrue(request.body!!.isOneShot()); assertNull(request.url.query)
                assertEquals("id=synthetic-session", request.header("Cookie")); assertEquals("synthetic-token", request.header("X-SYNO-TOKEN"))
                var count = 0L; var maximum = 0L; val prefix = Buffer()
                val sink = object : ForwardingSink(blackholeSink()) {
                    override fun write(source: Buffer, byteCount: Long) {
                        maximum = maxOf(maximum, byteCount); count += byteCount
                        if (prefix.size < 1024) source.copyTo(prefix, 0, minOf(byteCount, 1024 - prefix.size))
                        super.write(source, byteCount)
                    }
                }.buffer()
                request.body!!.writeTo(sink); sink.close()
                assertEquals(request.body!!.contentLength(), count); assertTrue(count > file.length()); assertTrue(maximum <= 65_536)
                val text = prefix.readUtf8(); assertTrue(text.contains("film_h264\"; filename=\"preview.mp4\""))
                assertFalse(text.contains("private-original-name")); assertFalse(text.contains("thumb_xl"))
                response(request)
            }
            assertTrue(transport.uploadAutomaticPreview(cap, 151, null, file)); assertEquals(1, calls)
        } finally { assertTrue(cache.deleteRecursively()) }
    }
    @Test fun `空文件缺失文件空上传和空JPEG在网络前拒绝`() = runBlocking {
        val cache = Files.createTempDirectory("automatic-preview-invalid-").toFile()
        try {
            var calls = 0; val transport = media { calls++; response(it) }; val empty = File(cache, "empty").apply { createNewFile() }
            for (video in listOf(null, empty, File(cache, "missing"), cache)) failure { transport.uploadAutomaticPreview(cap, 151, null, video) }
            failure { transport.uploadAutomaticPreview(cap, 151, SynologyPhotoConvertedPreview(byteArrayOf(), byteArrayOf(1), byteArrayOf(2)), null) }
            assertEquals(0, calls)
        } finally { assertTrue(cache.deleteRecursively()) }
    }
    @Test fun `视频复查错误页重定向及空内容不落盘且已有目标不可覆盖`() = runBlocking {
        val cache = Files.createTempDirectory("automatic-preview-review-").toFile()
        val stream = cap.copy(name = "SYNO.Foto.Streaming")
        try {
            val target = File(cache, "review.mov")
            for ((type, content, status) in listOf(Triple("application/json", "{}".toByteArray(), 200),
                Triple("text/html", "login".toByteArray(), 200), Triple("video/mp4", byteArrayOf(), 200),
                Triple("video/mp4", byteArrayOf(1, 2), 302))) {
                var commit = false
                failure { media { response(it, content, type, status) }.downloadConvertedPreview(stream, 151, target) { commit = true } }
                assertFalse(commit); assertFalse(target.exists()); assertTrue(cache.list()!!.isEmpty())
            }
            target.writeText("keep"); var requests = 0
            failure { media { requests++; response(it) }.downloadConvertedPreview(stream, 151, target) {} }
            assertEquals(0, requests); assertEquals("keep", target.readText())
        } finally { assertTrue(cache.deleteRecursively()) }
    }
    private suspend fun failure(block: suspend () -> Unit) {
        var failed = false; try { block() } catch (_: Exception) { failed = true }; assertTrue("应拒绝无效媒体", failed)
    }
}
