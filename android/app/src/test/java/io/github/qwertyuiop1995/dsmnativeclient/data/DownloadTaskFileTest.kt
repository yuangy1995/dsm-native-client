package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.ByteArrayInputStream
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadTaskFileTest {
    @Test
    fun `任务文件使用官方multipart接口且文件位于正文末尾`() = runBlocking {
        val transport = DownloadTaskFileInterceptor(
            """{"success":true,"data":{"files":[{"path":"/downloads","name":"downloads","isdir":true,"additional":{"perm":{"read":true,"write":true,"delete":false}}}]}}""",
            """{"success":true,"data":{"tasks":[]}}""",
            """{"success":true,"data":{"taskid":"task-1"}}""",
            """{"success":true,"data":{"tasks":[{"id":"task-1","type":"bt","title":"Synthetic","status":"waiting"}]}}""",
        )
        val bytes = "d4:infod4:name4:testee".encodeToByteArray()
        val repository = DsmRepository(
            NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
            DsmSession("test", "REDACTED_SESSION", "REDACTED_TOKEN"),
            DsmApiClient(OkHttpClient.Builder().addInterceptor(transport).build()),
            mapOf(
                "SYNO.DownloadStation.Task" to ApiCapability(
                    "SYNO.DownloadStation.Task",
                    "DownloadStation/task.cgi",
                    1,
                    3,
                ),
                "SYNO.FileStation.List" to ApiCapability(
                    "SYNO.FileStation.List",
                    "entry.cgi",
                    1,
                    2,
                ),
            ),
        )

        repository.createDownloadFromFile(
            UploadSource(
                displayName = "synthetic.torrent",
                contentType = "application/x-bittorrent",
                contentLength = bytes.size.toLong(),
                openInputStream = { ByteArrayInputStream(bytes) },
            ),
            destination = "/downloads",
            unzipPassword = "REDACTED_ARCHIVE_PASSWORD",
        )

        val requestIndex = transport.requests.indexOfFirst { it.url.queryParameter("method") == "create" }
        val request = transport.requests[requestIndex]
        assertEquals("SYNO.DownloadStation.Task", request.url.queryParameter("api"))
        assertEquals("create", request.url.queryParameter("method"))
        assertEquals("2", request.url.queryParameter("version"))
        assertFalse(request.url.toString().contains("REDACTED_SESSION"))
        val body = transport.bodies[requestIndex]
        assertTrue(body.contains("name=\"destination\""))
        assertTrue(body.contains("/downloads"))
        assertTrue(body.contains("name=\"unzip_password\""))
        assertTrue(body.contains("REDACTED_ARCHIVE_PASSWORD"))
        assertTrue(body.contains("name=\"file\"; filename=\"synthetic.torrent\""))
        assertTrue(body.indexOf("name=\"file\"") > body.indexOf("name=\"destination\""))
    }
}

private class DownloadTaskFileInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()
    val bodies = mutableListOf<String>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        request.body?.let { body ->
            val buffer = Buffer()
            body.writeTo(buffer)
            bodies += buffer.readUtf8()
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                (pending.removeFirstOrNull() ?: error("缺少合成下载任务响应"))
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}
