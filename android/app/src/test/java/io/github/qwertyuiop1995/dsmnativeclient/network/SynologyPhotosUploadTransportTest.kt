package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.ByteArrayInputStream
import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosUploadTransportTest {
    @Test fun `multipart业务字段保留JSON编码而会话仅在头中且固定文件名`() = runBlocking {
        val requests = mutableListOf<Request>()
        var text = ""
        val api = api { request ->
            requests += request
            val sink = Buffer(); request.body!!.writeTo(sink); text = sink.readUtf8()
            response(request)
        }
        val fields = mapOf("name" to "\"test\\r\\n\\\".jpg\"", "duplicate" to "\"ignore\"", "mtime" to "1234",
            "folder" to "[\"PhotoLibrary\"]", "passphrase" to "\"synthetic-album\"")
        api.uploadPhoto(profile, session, capability, "upload", fields, source()) { _, _ -> }
        val request = requests.single()
        assertTrue(request.body!!.isOneShot())
        assertEquals("/webapi/entry.cgi", request.url.encodedPath)
        assertNull(request.url.query)
        assertEquals("id=synthetic-session", request.header("Cookie"))
        assertEquals("synthetic-token", request.header("X-SYNO-TOKEN"))
        assertTrue(text.contains("name=\"file\"; filename=\"upload\""))
        assertFalse(text.contains("synthetic-session")); assertFalse(text.contains("synthetic-token"))
        fields.forEach { (key, value) ->
            assertTrue("应保留字段 $key 的 JSON 正文", Regex("name=\"$key\"\\r\\n(?:[^\\r\\n]*\\r\\n)*\\r\\n${Regex.escape(value)}\\r\\n").containsMatchIn(text))
        }
        assertFalse(text.contains("filename=\"test"))
    }

    @Test fun `发送进度和完整摘要基于原件字节而非multipart大小`() = runBlocking {
        val bytes = ByteArray(100_000) { (it % 97).toByte() }
        var read = 0L
        var fingerprint = 0L
        val api = api { request -> request.body!!.writeTo(Buffer()); response(request) }
        api.uploadPhoto(profile, session, capability.copy(name = "SYNO.FotoTeam.Upload.Item"), "upload_to_folder",
            mapOf("target_folder_id" to "9"), UploadSource("synthetic.mov", null, bytes.size.toLong(), { ByteArrayInputStream(bytes) },
                onContentRead = { fingerprint = it.bytes })) { done, total -> assertEquals(bytes.size.toLong(), total); read = done }
        assertEquals(bytes.size.toLong(), read)
        assertEquals(read, fingerprint)
    }

    @Test fun `授权拒绝或外部能力路径不得读取原件或发送请求`() = runBlocking {
        var calls = 0
        var reads = 0
        val input = UploadSource("synthetic.jpg", null, 4, { reads++; ByteArrayInputStream(ByteArray(4)) })
        val api = api { request -> calls++; response(request) }
        try {
            api.authorized({ throw IOException("synthetic denial") }).uploadPhoto(profile, session, capability, "upload", emptyMap(), input) { _, _ -> }
            fail()
        } catch (_: IOException) { }
        for (invalid in listOf(capability.copy(path = "https://external.example.invalid/entry.cgi"), capability.copy(path = "entry.cgi?_sid=x"),
            capability.copy(name = "SYNO.FileStation.Upload"), capability.copy(minVersion = 2))) {
            try { api.uploadPhoto(profile, session, invalid, "upload", emptyMap(), input) { _, _ -> }; fail() } catch (_: IllegalArgumentException) { }
        }
        assertEquals(0, calls); assertEquals(0, reads)
    }

    @Test fun `畸形回执HTTP错误和重定向不会冒充成功或重发`() = runBlocking {
        for ((status, json) in listOf(200 to "<html>error</html>", 200 to "{}", 200 to "{\"success\":true,\"error\":{\"code\":100}}",
            200 to "{\"success\":false,\"error\":{\"code\":105}}", 302 to "", 500 to "")) {
            var calls = 0
            val api = api { request -> calls++; response(request, status, json) }
            try { api.uploadPhoto(profile, session, capability, "upload", emptyMap(), source()) { _, _ -> }; fail() }
            catch (_: DsmFailure) { }
            assertEquals(1, calls)
        }
    }

    @Test fun `长度变化停止请求正文且不确认完整内容`() = runBlocking {
        var completed = false
        val api = api { request -> request.body!!.writeTo(Buffer()); response(request) }
        try {
            api.uploadPhoto(profile, session, capability, "upload", emptyMap(), source().copy(contentLength = 2,
                onContentRead = { completed = true })) { _, _ -> }
            fail()
        } catch (_: DsmFailure) { }
        assertFalse(completed)
    }

    private fun source() = UploadSource("synthetic.jpg", null, 4, { ByteArrayInputStream(byteArrayOf(1, 2, 3, 4)) })
    private fun api(handler: (Request) -> Response) = DsmApiClient(OkHttpClient.Builder().followRedirects(false)
        .followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { handler(it.request()) }.build())
    private fun response(request: Request, status: Int = 200, json: String = "{\"success\":true,\"data\":{\"id\":91}}") =
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("synthetic")
            .header("Content-Type", "application/json").body(json.toResponseBody("application/json".toMediaType())).build()
    private companion object {
        val profile = NasProfile("profile-a", "Synthetic", "https://nas.example.invalid", "tester")
        val session = DsmSession("profile-a", "synthetic-session", "synthetic-token")
        val capability = ApiCapability("SYNO.Foto.Upload.Item", "entry.cgi", 1, 1, "JSON")
    }
}
