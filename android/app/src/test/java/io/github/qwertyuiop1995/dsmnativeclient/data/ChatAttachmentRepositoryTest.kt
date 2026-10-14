package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.ChatProtocolFixture

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.runBlocking
import okio.Buffer
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatAttachmentRepositoryTest {
    @Test
    fun `附件上传固定v5且客户端请求ID不出站`() = runBlocking {
        val bytes = "synthetic attachment".toByteArray()
        val f = ChatProtocolFixture("synthetic-channel")
        f.posts = "[${f.post("Synthetic caption", attachment = true, size = bytes.size.toLong())}]"
        var progress = 0L
        val action = f.prepare(ChatActionDraft(ChatActionKind.ATTACHMENT, f.channelId,
            text = " Synthetic caption ", attachment = f.source(bytes = bytes)))
        val result = f.execute(action) { completed, _ -> progress = completed }
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        val message = requireNotNull(result.message)
        assertEquals("post-1", message.id)
        assertEquals("sample.txt", message.attachments.single().name)
        assertEquals(bytes.size.toLong(), progress)
        val request = f.writes.single()
        RequestFixtureAssertions.assertRequest(request, "chat/send-attachment/synthetic-file/request.json")
        assertEquals("5", request.url.queryParameter("version"))
        assertEquals("create", request.url.queryParameter("method"))
        assertTrue(request.url.queryParameter("_sid") == null)
        val fields = request.multipartTextFields()
        assertEquals("SYNO.Chat.Post", fields["api"])
        assertEquals("5", fields["version"])
        assertEquals("synthetic-channel", fields["channel_id"])
        assertEquals("file", fields["type"])
        assertEquals("Synthetic caption", fields["message"])
        assertEquals("false", fields["is_thread"])
        assertTrue(fields.keys.none { it.contains("request", ignoreCase = true) })
    }

    @Test
    fun `附件能力不覆盖v5时零请求拒绝`() = runBlocking {
        val f = ChatProtocolFixture(maximumVersion = 4)
        assertThrows { f.prepare(ChatActionDraft(ChatActionKind.ATTACHMENT, f.channelId, attachment = f.source())) }
        assertTrue(f.requests.isEmpty())
    }

    @Test
    fun `附件提交断线不会自动重放`() = runBlocking {
        val f = ChatProtocolFixture(); f.write = { throw IOException("synthetic disconnect") }
        val action = f.prepare(ChatActionDraft(ChatActionKind.ATTACHMENT, f.channelId, attachment = f.source()))
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.size); assertTrue(f.postReads.isEmpty())
    }

    @Test
    fun `缩略图保存和视频预览固定v2且认证不进入URL`() = runBlocking {
        val thumbnail = byteArrayOf(0x01, 0x02, 0x03)
        val attachment = "saved attachment".toByteArray()
        val video = "synthetic video".toByteArray()
        val transport = ChatAttachmentInterceptor(
            binary(thumbnail, "image/png"),
            binary(attachment, "application/octet-stream"),
            binary(video, "video/mp4"),
        )
        val repo = repository(transport)

        val loaded = repo.chatAttachmentThumbnail("synthetic-post")
        val output = ByteArrayOutputStream()
        val saved = repo.downloadChatAttachment("synthetic-post", attachment.size.toLong(), output) { _, _ -> }
        val videoOutput = ByteArrayOutputStream()
        val previewed = repo.downloadChatVideoPreview(
            "post-2", video.size.toLong(), videoOutput,
        ) { _, _ -> }

        assertArrayEquals(thumbnail, loaded)
        assertArrayEquals(attachment, output.toByteArray())
        assertEquals(attachment.size.toLong(), saved)
        assertArrayEquals(video, videoOutput.toByteArray())
        assertEquals(video.size.toLong(), previewed)
        val thumbnailRequest = transport.requests[0]
        RequestFixtureAssertions.assertRequest(
            thumbnailRequest,
            "chat/read-attachment-thumbnail/synthetic-post/request.json",
        )
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "chat/save-attachment/synthetic-post/request.json",
        )
        assertEquals("2", thumbnailRequest.url.queryParameter("version"))
        assertEquals("thumbnail", thumbnailRequest.url.queryParameter("method"))
        assertEquals("sm", thumbnailRequest.url.queryParameter("type"))
        assertEquals("get", transport.requests[1].url.queryParameter("method"))
        assertEquals("post-2", transport.requests[2].url.queryParameter("post_id"))
        transport.requests.forEach { request ->
            assertFalse(request.url.queryParameterNames.any { it.equals("_sid", true) || it.contains("token", true) })
            assertTrue(request.header("Cookie")?.isNotBlank() == true)
            assertTrue(request.header("X-SYNO-TOKEN")?.isNotBlank() == true)
        }
    }

    @Test
    fun `视频预览超过上限时零请求拒绝`() = runBlocking {
        val transport = ChatAttachmentInterceptor()

        assertThrows {
            repository(transport).downloadChatVideoPreview(
                "post-1",
                512L * 1024 * 1024 + 1,
                ByteArrayOutputStream(),
            ) { _, _ -> }
        }

        assertTrue(transport.requests.isEmpty())
    }

    private fun repository(
        interceptor: ChatAttachmentInterceptor,
        postMaximumVersion: Int = 5,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build()),
        mapOf(
            "SYNO.Chat.Post" to ApiCapability("SYNO.Chat.Post", "entry.cgi", 1, postMaximumVersion),
            "SYNO.Chat.Post.File" to ApiCapability("SYNO.Chat.Post.File", "entry.cgi", 1, 2),
        ),
    )

    private fun binary(value: ByteArray, type: String) = ChatAttachmentStep.Body(value, type)

    private suspend fun assertThrows(block: suspend () -> Unit) {
        var thrown = false
        try {
            block()
        } catch (_: Throwable) {
            thrown = true
        }
        assertTrue(thrown)
    }
}

private sealed interface ChatAttachmentStep {
    data class Body(val value: ByteArray, val contentType: String) : ChatAttachmentStep
}

private class ChatAttachmentInterceptor(vararg steps: ChatAttachmentStep) : Interceptor {
    private val queue = ArrayDeque(steps.toList())
    val requests = CopyOnWriteArrayList<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        if (request.body?.contentType()?.type == "multipart") request.body?.writeTo(Buffer())
        return when (val step = queue.removeFirstOrNull() ?: error("Unexpected request")) {
            is ChatAttachmentStep.Body -> Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .addHeader("Content-Type", step.contentType)
                .body(step.value.toResponseBody(step.contentType.toMediaType()))
                .build()
        }
    }
}

private fun Request.multipartTextFields(): Map<String, String> {
    val multipart = ((body as? io.github.qwertyuiop1995.dsmnativeclient.network.OneShotRequestBody)?.delegate ?: body) as MultipartBody
    return buildMap {
        multipart.parts.forEach { part ->
            val disposition = part.headers?.get("Content-Disposition").orEmpty()
            val name = Regex("name=\"([^\"]+)\"").find(disposition)?.groupValues?.get(1) ?: return@forEach
            if (Regex("filename=\"").containsMatchIn(disposition)) return@forEach
            val buffer = Buffer()
            part.body.writeTo(buffer)
            put(name, buffer.readUtf8())
        }
    }
}
