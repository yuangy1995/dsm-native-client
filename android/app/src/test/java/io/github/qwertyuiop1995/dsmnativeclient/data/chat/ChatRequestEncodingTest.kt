package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.net.URLDecoder

class ChatRequestEncodingTest {
    @Test fun `FORM和JSON分别保留字符串数字数组对象且写正文不可自动重放`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            var request: Request? = null
            val repo = repository(format) { value -> request = value; "{}" }
            repo.chatRepository.gateway.call("SYNO.Chat.Post", "set", 8, mapOf(
                "channel_id" to JsonPrimitive("11"), "message" to JsonPrimitive("hello \"quoted\""),
                "in" to JsonArray(listOf(JsonPrimitive(11))), "options" to buildJsonObject { put("multiple", true) }), oneShot = true)
            val actual = requireNotNull(request)
            assertTrue(actual.body!!.isOneShot())
            val fields = fields(actual)
            assertEquals(if (format == "JSON") "\"11\"" else "11", fields["channel_id"])
            assertEquals("[11]", fields["in"]); assertEquals("{\"multiple\":true}", fields["options"])
            assertEquals("8", fields["version"]); assertFalse(actual.url.queryParameterNames.any { it.contains("sid") || it.contains("token", true) })
        }
    }
    @Test fun `附件先保存后传输且JSON业务字符串按能力编码`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            var saved = false; var count = 0
            val repo = repository(format) { request ->
                count++; assertTrue(saved); assertTrue(request.body!!.isOneShot())
                val multipart = (request.body as io.github.qwertyuiop1995.dsmnativeclient.network.OneShotRequestBody).delegate as MultipartBody
                fun value(name: String) = multipart.parts.single { it.headers?.get("Content-Disposition") == "form-data; name=\"$name\"" }
                    .body.let { Buffer().also(it::writeTo).readUtf8() }
                assertEquals(if (format == "JSON") "\"11\"" else "11", value("channel_id"))
                assertEquals(if (format == "JSON") "\"caption\"" else "caption", value("message"))
                assertEquals("false", value("is_thread")); assertFalse(request.url.queryParameterNames.any { it.contains("sid") || it.contains("token", true) })
                "{\"post_id\":\"71\"}"
            }
            val response = repo.chatRepository.gateway.upload("11", "caption", source(), { saved = true }, { _, _ -> })
            assertEquals("71", (response["post_id"] as JsonPrimitive).content); assertEquals(1, count)
        }
    }
    @Test fun `附件保存失败在版本读取之后仍零业务写请求`() = runBlocking {
        var count = 0; val repo = repository("JSON") { count++; "{}" }
        try { repo.chatRepository.gateway.upload("11", "", source(), { error("disk") }, { _, _ -> }); fail("Expected storage failure") } catch (_: IllegalStateException) {}
        assertEquals(0, count)
    }
    private fun source() = UploadSource("synthetic\".txt", "text/plain", 3, { byteArrayOf(1, 2, 3).inputStream() })
    private fun repository(format: String, response: (Request) -> String) = authorizedRepository(
        NasProfile("synthetic", "Synthetic", "https://nas.example.invalid", "tester"), DsmSession("synthetic", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val apiName = if (request.body is FormBody) fields(request)["api"] else null
            val data = when (apiName) {
                "SYNO.Core.System" -> """{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}"""
                "SYNO.Core.Package" -> """{"total":1,"packages":[{"id":"Chat","name":"Chat","version":"2.4.1-22111","status":"running","startable":true,"available_operation":[],"dsm_apps":[]}]}"""
                else -> response(request)
            }
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body("{\"success\":true,\"data\":$data}".toResponseBody("application/json".toMediaType())).build()
        }.build()), mapOf("SYNO.Chat.Post" to ApiCapability("SYNO.Chat.Post", "entry.cgi", 1, 8, format),
            "SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 1),
            "SYNO.Core.Package" to ApiCapability("SYNO.Core.Package", "entry.cgi", 1, 2)))
    private fun fields(request: Request): Map<String, String> = Buffer().also { request.body!!.writeTo(it) }.readUtf8().split('&').associate {
        val pair = it.split('=', limit = 2); URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8")
    }
}
