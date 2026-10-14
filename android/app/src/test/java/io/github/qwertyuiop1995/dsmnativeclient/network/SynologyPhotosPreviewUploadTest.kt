package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.MediaType.Companion.toMediaType
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosPreviewUploadTest {
    private val preview = SynologyPhotoConvertedPreview(byteArrayOf(1, 2, 3), byteArrayOf(4, 5), byteArrayOf(6))
    private val capability = ApiCapability("SYNO.Foto.Upload.ConvertedFile", "entry.cgi", 1, 3, "JSON")
    private fun transport(onDenied: () -> Unit = {}, authorize: () -> Unit = {}, respond: (Request) -> Response) = SynologyPhotosMediaTransport(
        NasProfile(id = "p", name = "synthetic", address = "nas.example.invalid", username = "synthetic"),
        DsmSession("p", "synthetic-session", "synthetic-token"), "https://nas.example.invalid",
        OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .addInterceptor { respond(it.request()) }.build(), authorizeRequest = authorize, onAccessFailure = onDenied)
    private fun response(request: Request, value: String, code: Int = 200) = Response.Builder().request(request)
        .protocol(Protocol.HTTP_1_1).code(code).message("synthetic").body(value.toResponseBody("application/json".toMediaType())).build()

    @Test fun `三档JPEG与统一元数据仅在multipart并且不可重放`() = runBlocking {
        val requests = mutableListOf<Request>()
        val media = transport { request -> requests += request; response(request, "{\"success\":true}") }
        for (name in listOf("SYNO.Foto.Upload.ConvertedFile", "SYNO.FotoTeam.Upload.ConvertedFile")) {
            assertTrue(media.uploadPreview(capability.copy(name = name), 91, preview))
            val request = requests.last(); val buffer = Buffer(); request.body!!.writeTo(buffer)
            val body = buffer.readUtf8()
            assertEquals("POST", request.method); assertEquals("/webapi/entry.cgi", request.url.encodedPath)
            assertNull(request.url.query); assertTrue(request.body!!.isOneShot())
            assertEquals("id=synthetic-session", request.header("Cookie")); assertEquals("synthetic-token", request.header("X-SYNO-TOKEN"))
            fun scalar(key: String) = body.substringAfter("name=\"$key\"").substringAfter("\r\n\r\n").substringBefore("\r\n")
            assertEquals(name, scalar("api")); assertEquals("3", scalar("version"))
            assertEquals("upload", scalar("method")); assertEquals("91", scalar("unit_id"))
            for (part in listOf("thumb_xl", "thumb_sm", "thumb_m")) assertTrue(body.contains("name=\"$part\"; filename=\"$part.jpg\""))
            assertFalse(body.contains("film_h264")); assertFalse(body.contains("synthetic-token")); assertFalse(body.contains("synthetic-session"))
        }
        assertEquals(2, requests.size)
    }

    @Test fun `仅明确API失败可返回拒绝而非成功`() = runBlocking {
        assertFalse(transport { response(it, "{\"success\":false,\"error\":{\"code\":100}}") }.uploadPreview(capability, 91, preview))
    }

    @Test fun `缺字段矛盾类型畸形及过大回执均保留未知`() = runBlocking {
        for (json in listOf("{}", "{\"success\":\"true\"}", "{\"success\":true,\"error\":null}",
            "{\"success\":true,\"error\":{\"code\":100}}", "{\"success\":false}",
            "{\"success\":false,\"error\":{\"code\":\"100\"}}", "[]", "invalid", " ".repeat(65_537))) {
            var calls = 0
            val error = failure { transport { calls++; response(it, json) }.uploadPreview(capability, 91, preview) }
            assertEquals(SynologyPhotoFailureKind.INVALID_RESPONSE, (error as SynologyPhotoFailure).kind); assertEquals(1, calls)
        }
    }

    @Test fun `非成功HTTP与网络失败不转明确拒绝不自动重试`() = runBlocking {
        for (status in listOf(302, 404, 500)) {
            var calls = 0
            assertTrue(failure { transport { calls++; response(it, "{\"success\":false,\"error\":{\"code\":100}}", status) }.uploadPreview(capability, 91, preview) } is SynologyPhotoFailure)
            assertEquals(1, calls)
        }
        var calls = 0
        assertTrue(failure { transport { calls++; throw IOException("synthetic disconnect") }.uploadPreview(capability, 91, preview) } is SynologyPhotoFailure)
        assertEquals(1, calls)
    }

    @Test fun `权限失败与会话失效撤回授权不返回普通转换失败`() = runBlocking {
        for ((status, body) in listOf(401 to "", 403 to "", 200 to "{\"success\":false,\"error\":{\"code\":105}}", 200 to "{\"success\":false,\"error\":{\"code\":106}}")) {
            var denied = 0
            val error = failure { transport(onDenied = { denied++ }) { response(it, body, status) }.uploadPreview(capability, 91, preview) }
            assertTrue(error is SynologyPhotoFailure || error is DsmFailure); assertEquals(1, denied)
        }
    }

    @Test fun `无权限无版本或非本机路径在发送前拒绝`() = runBlocking {
        var calls = 0
        val media = transport { calls++; response(it, "{\"success\":true}") }
        for (cap in listOf(capability.copy(maxVersion = 2), capability.copy(name = "SYNO.Foto.Upload.Item"), capability.copy(path = "https://elsewhere.invalid/entry.cgi"), capability.copy(path = "../entry.cgi"))) {
            assertTrue(failure { media.uploadPreview(cap, 91, preview) } is IllegalArgumentException)
        }
        failure { transport(authorize = { throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION) }) { calls++; response(it, "{\"success\":true}") }.uploadPreview(capability, 91, preview) }
        assertEquals(0, calls)
    }

    private suspend fun failure(block: suspend () -> Unit): Throwable {
        try { block() } catch (error: Throwable) { return error }
        throw AssertionError("应失败")
    }
}
