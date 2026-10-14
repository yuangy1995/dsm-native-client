package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File
import java.io.IOException
import java.net.ServerSocket
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import okio.buffer

class SynologyPhotosMediaTransportTest {
    @Test fun `人物封面按真实类型与来源读取不附加size或相册参数且仅在头部认证`() = runBlocking {
        val requests = mutableListOf<Request>()
        val transport = transport { request -> requests += request; response(request, byteArrayOf(1, 2, 3), "image/jpeg") }
        for (space in SynologyPhotoSpace.entries) for (type in SynologyPhotoPersonCover.Type.entries) {
            assertArrayEquals(byteArrayOf(1, 2, 3), transport.personThumbnail(SynologyPhotoPersonCover(91, "Synthetic revision", type), space))
            val request = requests.last()
            assertEquals("/synofoto/api/v2/${if (space == SynologyPhotoSpace.SHARED) "t" else "p"}/Thumbnail/get", request.url.encodedPath)
            assertEquals("91", request.url.queryParameter("id")); assertEquals("\"${type.value}\"", request.url.queryParameter("type"))
            assertEquals(setOf("id", "cache_key", "type"), request.url.queryParameterNames)
            assertEquals("id=synthetic-session", request.header("Cookie")); assertEquals("synthetic-token", request.header("X-SYNO-TOKEN"))
        }
    }
    @Test fun `人物封面拒绝错误页重定向空内容与超限响应`() = runBlocking {
        for ((bytes, type, status) in listOf(Triple(byteArrayOf(), "image/png", 200), Triple(byteArrayOf(1), "text/html", 200),
            Triple(byteArrayOf(1), "image/png", 302), Triple(ByteArray(8 * 1024 * 1024 + 1), "image/png", 200))) {
            failure { transport { response(it, bytes, type, status) }.personThumbnail(SynologyPhotoPersonCover(1, "r", SynologyPhotoPersonCover.Type.PERSON), SynologyPhotoSpace.PERSONAL) }
        }
    }
    @Test fun `自定义目录封面使用固定目录序号不带size而普通封面使用独立照片单元`() = runBlocking {
        val requests = mutableListOf<Request>()
        val transport = transport { request -> requests += request; response(request, byteArrayOf(1, 2, 3), "image/png") }
        transport.folderThumbnail(9, SynologyPhotoFolderCover("synthetic revision", sequence = 0), SynologyPhotoSpace.SHARED)
        val folder = requests.last()
        assertEquals("/synofoto/api/v2/t/Thumbnail/get", folder.url.encodedPath)
        assertEquals("9", folder.url.queryParameter("id")); assertEquals("0", folder.url.queryParameter("folder_cover_seq"))
        assertEquals("\"folder\"", folder.url.queryParameter("type")); assertNull(folder.url.queryParameter("size"))
        assertNull(folder.url.queryParameter("album_id")); assertEquals("id=synthetic-session", folder.header("Cookie"))
        transport.folderThumbnail(9, SynologyPhotoFolderCover("revision", unitId = 81), SynologyPhotoSpace.PERSONAL)
        val unit = requests.last(); assertEquals("81", unit.url.queryParameter("id")); assertEquals("\"m\"", unit.url.queryParameter("size"))
        assertEquals("\"unit\"", unit.url.queryParameter("type")); assertNull(unit.url.queryParameter("folder_cover_seq"))
    }

    @Test fun `目录封面继续拒绝错误页重定向空响应和过大响应`() = runBlocking {
        for ((bytes, type, status) in listOf(Triple(byteArrayOf(), "image/png", 200), Triple(byteArrayOf(1), "text/html", 200),
            Triple(byteArrayOf(1), "image/png", 302), Triple(ByteArray(8 * 1024 * 1024 + 1), "image/png", 200))) {
            failure { transport { response(it, bytes, type, status) }.folderThumbnail(9, SynologyPhotoFolderCover("r", sequence = 0), SynologyPhotoSpace.PERSONAL) }
        }
    }
    @Test fun `缩略图使用观测路径和独立单元并仅在头部认证`() = runBlocking {
        val requests = mutableListOf<Request>()
        val transport = transport { request -> requests += request; response(request, byteArrayOf(1, 2, 3), "image/jpeg") }
        assertArrayEquals(byteArrayOf(1, 2, 3), transport.thumbnail(SynologyPhotoThumbnail(93, "a b\"c"), false))
        val request = requests.single()
        assertEquals("/synofoto/api/v2/p/Thumbnail/get", request.url.encodedPath)
        assertEquals("93", request.url.queryParameter("id"))
        assertEquals("\"m\"", request.url.queryParameter("size"))
        assertEquals("\"unit\"", request.url.queryParameter("type"))
        assertEquals("\"a b\\\"c\"", request.url.queryParameter("cache_key"))
        assertEquals("id=synthetic-session", request.header("Cookie"))
        assertEquals("synthetic-token", request.header("X-SYNO-TOKEN"))
        assertTrue(request.url.queryParameterNames.none { it in setOf("api", "version", "method", "_sid", "SynoToken") })
        transport.thumbnail(SynologyPhotoThumbnail(93, "revision"), true)
        assertEquals("\"xl\"", requests.last().url.queryParameter("size"))
    }

    @Test fun `缩略图错误页空内容超限和重定向均失败且不跟随`() = runBlocking {
        for ((bytes, type, status) in listOf(
            Triple(byteArrayOf(1), "text/html", 200), Triple(byteArrayOf(), "image/jpeg", 200),
            Triple(ByteArray(8 * 1024 * 1024 + 1), "image/jpeg", 200), Triple(byteArrayOf(1), "image/jpeg", 302),
        )) {
            var requests = 0
            val transport = transport { request -> requests++; response(request, bytes, type, status) }
            failure { transport.thumbnail(SynologyPhotoThumbnail(1, "r"), false) }
            assertEquals(1, requests)
        }
    }

    @Test fun `原件精确流式保存并拒绝覆盖目标`() = runBlocking {
        val directory = Files.createTempDirectory("photos-original-test-").toFile()
        try {
            val target = File(directory, "original.heic")
            val content = ByteArray(200_000) { (it % 251).toByte() }
            val requests = mutableListOf<Request>()
            val progress = mutableListOf<Long>()
            val transport = transport { request -> requests += request; response(request, content, "image/heic") }
            transport.download(download, originalParameters, target, content.size.toLong()) { done, _ -> progress += done }
            assertArrayEquals(content, target.readBytes())
            assertEquals(content.size.toLong(), progress.last())
            assertEquals(listOf("original.heic"), directory.listFiles()!!.map { it.name })
            assertEquals("[11]", requests.single().url.queryParameter("item_id"))
            assertEquals("\"source\"", requests.single().url.queryParameter("download_type"))
            try { transport.download(download, originalParameters, target, 4) { _, _ -> }; fail("不应覆盖既有文件") }
            catch (_: java.nio.file.FileAlreadyExistsException) { }
            assertArrayEquals(content, target.readBytes())
            assertEquals(1, requests.size)
        } finally { directory.deleteRecursively() }
    }

    @Test fun `错误原件响应不会留下暂存文件或半成品`() = runBlocking {
        val directory = Files.createTempDirectory("photos-invalid-original-").toFile()
        try {
            for ((bytes, type, status) in listOf(Triple(byteArrayOf(1, 2), "image/jpeg", 200),
                Triple(byteArrayOf(1, 2, 3, 4, 5), "image/jpeg", 200), Triple(ByteArray(4), "application/json", 200),
                Triple(ByteArray(4), "application/zip", 200), Triple(ByteArray(4), "text/html", 200), Triple(ByteArray(4), "image/jpeg", 206))) {
                val transport = transport { request -> response(request, bytes, type, status) }
                failure { transport.download(download, originalParameters, File(directory, "original.heic"), 4) { _, _ -> } }
                assertTrue(directory.listFiles()!!.isEmpty())
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun `取消已经收到响应头且正在读原件的请求会中断网络并清理`() = runBlocking {
        val directory = Files.createTempDirectory("photos-cancel-original-").toFile()
        val server = ServerSocket(0, 1, java.net.InetAddress.getLoopbackAddress())
        val release = CountDownLatch(1)
        val worker = thread(isDaemon = true, name = "synthetic-photos-server") {
            try {
                server.accept().use { socket ->
                    val input = socket.getInputStream().bufferedReader()
                    while (!input.readLine().isNullOrEmpty()) { }
                    socket.getOutputStream().apply {
                        write("HTTP/1.1 200 OK\r\nContent-Type: image/heic\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\n".toByteArray())
                        write(ByteArray(4096)); flush()
                    }
                    release.await(5, TimeUnit.SECONDS)
                }
            } catch (_: IOException) { }
        }
        val received = CompletableDeferred<Unit>()
        try {
            val endpoint = "http://127.0.0.1:${server.localPort}"
            val transport = SynologyPhotosMediaTransport(profile.copy(address = endpoint), session, endpoint, client().build())
            val task = launch(Dispatchers.Default) {
                transport.download(download, originalParameters, File(directory, "original.heic"), 1_048_576) { done, _ ->
                    if (done > 0) received.complete(Unit)
                }
            }
            withTimeout(4_000) { received.await() }
            withTimeout(2_000) { task.cancelAndJoin() }
            assertTrue(directory.listFiles()!!.isEmpty())
        } finally { release.countDown(); server.close(); worker.join(1_000); directory.deleteRecursively() }
    }

    @Test fun `未取消的响应体读取异常保持媒体失败且清理暂存文件`() = runBlocking {
        val directory = Files.createTempDirectory("photos-body-failure-").toFile()
        val failure = IOException("synthetic body interruption")
        try {
            val transport = transport { request ->
                val body = object : ResponseBody() {
                    override fun contentType() = "image/heic".toMediaType()
                    override fun contentLength() = 1024L
                    override fun source(): okio.BufferedSource = (object : okio.Source {
                        override fun read(sink: okio.Buffer, byteCount: Long): Long = throw failure
                        override fun timeout() = okio.Timeout.NONE
                        override fun close() = Unit
                    }).buffer()
                }
                response(request, ByteArray(1024), "image/heic").newBuilder().body(body).build()
            }
            val target = File(directory, "original.heic")
            try {
                transport.download(download, originalParameters, target, 1024) { _, _ -> }
                fail("未取消时必须报告正文读取失败")
            } catch (error: SynologyPhotoFailure) {
                assertSame(failure, error.cause)
            }
            currentCoroutineContext().ensureActive()
            assertFalse(target.exists())
            assertTrue(directory.listFiles()!!.isEmpty())
        } finally { directory.deleteRecursively() }
    }

    @Test fun `视频范围严格验证且至多缓存两个块`() = runBlocking {
        val requests = mutableListOf<String>()
        val size = 4 * 1024 * 1024L
        val transport = transport { request ->
            val range = request.header("Range")!!
            requests += range
            val parts = range.removePrefix("bytes=").split('-').map(String::toLong)
            val bytes = ByteArray((parts[1] - parts[0] + 1).toInt()) { ((parts[0] + it) % 251).toByte() }
            response(request, bytes, "video/mp4", 206).newBuilder()
                .header("Content-Range", "bytes ${parts[0]}-${parts[1]}/$size").build()
        }
        val source = transport.video(download, "download", mapOf("item_id" to "[11]"))
        try {
            assertEquals(size, source.size)
            assertEquals(listOf("bytes=0-0"), requests)
            val buffer = ByteArray(16)
            assertEquals(16, source.readAt(0, buffer, 0, 16))
            assertEquals(16, source.readAt(64, buffer, 0, 16))
            assertEquals(2, requests.size)
            source.readAt(1_048_576, buffer, 0, 16)
            source.readAt(2_097_152, buffer, 0, 16)
            source.readAt(0, buffer, 0, 16)
            assertEquals(5, requests.size)
            assertEquals(-1, source.readAt(size, buffer, 0, 16))
            assertEquals(0, source.readAt(size, buffer, 0, 0))
        } finally { source.close() }
        try { source.readAt(0, ByteArray(1), 0, 1); fail("关闭后不能继续读取") } catch (_: IOException) { }
    }

    @Test fun `忽略Range完整响应错误起点和未知总量均不得交给播放器`() = runBlocking {
        for ((status, range) in listOf(200 to "bytes 0-0/8", 206 to "bytes 1-1/8", 206 to "bytes 0-0/*", 206 to "bytes 0-3/8")) {
            val transport = transport { request -> response(request, byteArrayOf(1), "video/mp4", status).newBuilder().header("Content-Range", range).build() }
            failure { transport.video(download, "download", mapOf("item_id" to "[11]")) }
        }
    }

    @Test fun `媒体传输拒绝跨账号重定向客户端和危险能力路径`() = runBlocking {
        try { SynologyPhotosMediaTransport(profile, session.copy(profileId = "other"), profile.address, client().build()); fail("跨账号") }
        catch (_: SynologyPhotoFailure) { }
        try { SynologyPhotosMediaTransport(profile, session, profile.address, OkHttpClient()); fail("允许跳转") }
        catch (_: IllegalArgumentException) { }
        for (path in listOf("//other.example.invalid/get", "https://other.example.invalid", "entry.cgi?x=1", "../get", "%2e%2e/get", "a\\b")) {
            try { photoApiPath(path); fail(path) } catch (_: IllegalArgumentException) { }
        }
        assertEquals("/webapi/entry.cgi", photoApiPath("entry.cgi"))
        assertEquals("/synofoto/api/v2/p/Thumbnail/get", photoApiPath("/synofoto/api/v2/p/Thumbnail/get"))
    }

    @Test fun `原件权限代际检查失败时不提升文件也不覆盖用户目标`() = runBlocking {
        val directory = Files.createTempDirectory("photos-stale-original-").toFile()
        try {
            val transport = transport { request -> response(request, ByteArray(1024), "image/heic") }
            val target = File(directory, "original.heic")
            try {
                transport.download(download, originalParameters, target, 1024,
                    beforeCommit = { throw CancellationException("stale access") }) { _, _ -> }
                fail("权限改变后不能生成可导出的文件")
            } catch (_: CancellationException) { }
            assertFalse(target.exists())
            assertTrue(directory.listFiles()!!.isEmpty())
        } finally { directory.deleteRecursively() }
    }

    @Test fun `图片MIME中的JSON错误页HTML和ZIP原件均被拒绝`() = runBlocking {
        val directory = Files.createTempDirectory("photos-mime-original-").toFile()
        try {
            for (text in listOf("  {\"success\":false}", "<!DOCTYPE html><html>login</html>", "PK\u0003\u0004archive")) {
                val bytes = text.toByteArray()
                val transport = transport { request -> response(request, bytes, "image/jpeg") }
                failure { transport.download(download, originalParameters, File(directory, "original.jpg"), bytes.size.toLong()) { _, _ -> } }
                assertTrue(directory.listFiles()!!.isEmpty())
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun `共享缩略图走t而相册统一p并保留相册编号`() = runBlocking {
        val requests = mutableListOf<Request>()
        val transport = transport { request -> requests += request; response(request, byteArrayOf(1), "image/jpeg") }
        transport.thumbnail(SynologyPhotoThumbnail(93, "r"), false, SynologyPhotoSpace.SHARED)
        transport.thumbnail(SynologyPhotoThumbnail(93, "r"), true, SynologyPhotoSpace.SHARED, 7)
        assertEquals(listOf("/synofoto/api/v2/t/Thumbnail/get", "/synofoto/api/v2/p/Thumbnail/get"), requests.map { it.url.encodedPath })
        assertNull(requests.first().url.queryParameter("album_id"))
        assertEquals("7", requests.last().url.queryParameter("album_id"))
        assertTrue(requests.all { it.url.queryParameterNames.none { key -> key in setOf("sid", "_sid", "SynoToken", "Cookie") } })
    }

    @Test fun `共享原件允许明确FotoTeam下载而相册下载保留album`() = runBlocking {
        val directory = Files.createTempDirectory("photos-source-test-").toFile()
        try {
            val requests = mutableListOf<Request>()
            val transport = transport { request -> requests += request; response(request, byteArrayOf(1, 2, 3, 4), "image/jpeg") }
            transport.download(download.copy(name = "SYNO.FotoTeam.Download"), originalParameters, File(directory, "shared.jpg"), 4) { _, _ -> }
            transport.download(download, originalParameters + ("album_id" to "7"), File(directory, "album.jpg"), 4) { _, _ -> }
            assertEquals(listOf("SYNO.FotoTeam.Download", "SYNO.Foto.Download"), requests.map { it.url.queryParameter("api") })
            assertEquals("7", requests.last().url.queryParameter("album_id"))
            assertArrayEquals(File(directory, "shared.jpg").readBytes(), File(directory, "album.jpg").readBytes())
        } finally { directory.deleteRecursively() }
    }

    private suspend fun failure(action: suspend () -> Any?) {
        try { action(); fail("应该拒绝不合规媒体") } catch (_: SynologyPhotoFailure) { }
    }
    private fun transport(handler: (Request) -> Response): SynologyPhotosMediaTransport =
        SynologyPhotosMediaTransport(profile, session, profile.address, client().addInterceptor { chain -> handler(chain.request()) }.build())
    private fun client() = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
    private fun response(request: Request, bytes: ByteArray, type: String, code: Int = 200) = Response.Builder()
        .request(request).protocol(Protocol.HTTP_1_1).code(code).message("synthetic")
        .header("Content-Type", type).body(bytes.toResponseBody(type.toMediaType())).build()
    private companion object {
        val profile = NasProfile("profile-a", "Synthetic", "https://nas.example.invalid", "tester")
        val session = DsmSession("profile-a", "synthetic-session", "synthetic-token")
        val download = ApiCapability("SYNO.Foto.Download", "entry.cgi", 1, 2, "JSON")
        val originalParameters = mapOf("item_id" to "[11]", "force_download" to "true", "download_type" to "\"source\"")
    }
}
