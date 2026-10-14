package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class WorkspaceAuthorizedTransportTest {
    @Test fun `授权拒绝覆盖表单上传二进制与实时连接且不读取来源`() = runBlocking {
        val denied = DsmFailure(null, "synthetic", "synthetic", kind = DsmErrorKind.PERMISSION_DENIED)
        var checks = 0
        val api = DsmApiClient(client { error("拒绝后不得发请求") }).authorized(check = { checks++; throw denied })
        val capability = ApiCapability("SYNO.FileStation.Upload", "entry.cgi", 1, 3)
        suspend fun rejected(block: suspend () -> Unit) { assertSame(denied, runCatching { block() }.exceptionOrNull()) }
        rejected { api.call(profile, session, capability, "test") }
        rejected { api.call(profile, session, capability.name, 1, "test") }
        rejected { api.get(profile, session, capability, "test", emptyMap()) }
        rejected { api.upload(profile, session, capability, "/synthetic", "synthetic.txt", null, 1, false,
            { error("不得读取来源") }, { _, _ -> }) }
        rejected { api.uploadDownloadTaskFile(profile, session, capability, "synthetic.torrent", null, 1, null, null,
            { error("不得读取来源") }) }
        rejected { api.uploadChatAttachment(profile, session, capability, "synthetic-conversation", "", "synthetic.txt", null, 1,
            { error("不得读取来源") }, onProgress = { _, _ -> }) }
        rejected { api.readBinary(profile, session, capability, 1, "test", emptyMap(), 1) }
        rejected { api.downloadBinaryToOutput(profile, session, capability, 1, "test", emptyMap(), ByteArrayOutputStream(), 1) }
        val directory = java.nio.file.Files.createTempDirectory("lanstash-access-test").toFile()
        try {
            val destination = File(directory, "not-created.txt")
            rejected { api.downloadBinaryToFile(profile, session, capability, 1, "test", emptyMap(), destination, 1, 1) }
            assertFalse(destination.exists())
        } finally { directory.deleteRecursively() }
        rejected { api.openWebSocket(Request.Builder().url("https://nas.example.invalid/synthetic").build(), object : WebSocketListener() {}) }
        rejected { api.photosMedia(profile, session).thumbnail(SynologyPhotoThumbnail(1, "synthetic"), false) }
        assertEquals(11, checks)
    }

    @Test fun `照片授权撤销后播放器不能读取旧缓存或新范围`() = runBlocking {
        var allowed = true
        var requests = 0
        val http = client { request ->
            requests++
            val probe = request.header("Range") == "bytes=0-0"
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(206).message("synthetic")
                .header("Content-Range", if (probe) "bytes 0-0/4" else "bytes 0-3/4")
                .body((if (probe) "d" else "data").toResponseBody("video/mp4".toMediaType())).build()
        }
        val denied = DsmFailure(null, "synthetic", "synthetic", kind = DsmErrorKind.PERMISSION_DENIED)
        val api = DsmApiClient(http).authorized(check = { if (!allowed) throw denied })
        val source = api.photosMedia(profile, session).video(ApiCapability("SYNO.Foto.Streaming", "entry.cgi", 1, 2, "JSON"),
            "streaming", mapOf("id" to "1"))
        try {
            val bytes = ByteArray(2)
            assertEquals(2, source.readAt(0, bytes, 0, 2))
            assertEquals("da", bytes.decodeToString())
            allowed = false
            assertSame(denied, runCatching { source.readAt(1, bytes, 0, 2) }.exceptionOrNull())
            assertEquals(2, requests)
        } finally { source.close() }
    }

    private val profile = NasProfile("synthetic", "Synthetic", "https://nas.example.invalid", "synthetic")
    private val session = DsmSession(profile.id, "synthetic-session")
    private fun client(response: (Request) -> Response) = OkHttpClient.Builder().followRedirects(false)
        .followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain -> response(chain.request()) }.build()
}
