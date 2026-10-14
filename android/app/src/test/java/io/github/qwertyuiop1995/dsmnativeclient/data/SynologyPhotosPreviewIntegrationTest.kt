package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.MediaType.Companion.toMediaType
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test

/** 正式组合根、下载权限、媒体传输和写入互斥共同运行；只替换网络/编解码设备边界。 */
class SynologyPhotosPreviewIntegrationTest {
    private class Fixture(val space: SynologyPhotoSpace) : AutoCloseable {
        val cache = Files.createTempDirectory("preview-integration-").toFile()
        val requests = mutableListOf<Request>(); val methods = mutableListOf<String>()
        var uploadUnknown = false; var allowDownload = true; var home = true
        var conversion: suspend () -> Unit = {}
        val photo = SynologyPhoto(SynologyPhotoId("preview-root", space, 51), "Synthetic.png", 4, 1.0, 2.0, 9, "photo", SynologyPhotoThumbnail(151, "old"))
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Item", "Browse.Folder", "RegeneratePreview", "Upload.ConvertedFile", "Download")
                .map { ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.associateBy { it.name }
        val media = SynologyPhotosMediaTransport(NasProfile("preview-root", "synthetic", "nas.example.invalid", "synthetic"),
            DsmSession("preview-root", "synthetic-session", "synthetic-token"), "https://nas.example.invalid",
            OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); requests += request
                if (request.method == "POST" && uploadUnknown) throw IOException("synthetic lost upload")
                val body = if (request.method == "GET") byteArrayOf(1, 2, 3, 4).toResponseBody("image/png".toMediaType())
                    else "{\"success\":true}".toResponseBody("application/json".toMediaType())
                Response.Builder().request(request).code(200).protocol(Protocol.HTTP_1_1).message("Synthetic")
                    .header("Content-Type", if (request.method == "GET") "image/png" else "application/json").body(body).build()
            }.build())
        val repository = SynologyPhotosRepository("preview-root", caps, { api, method, fields ->
            methods += method
            when (api.name.substringAfter("SYNO.Foto").removePrefix("Team").removePrefix(".")) {
                "UserInfo" -> obj("""{"enabled":true,"id":41}""")
                "Setting.User" -> obj("""{"enable_home_service":$home,"team_space_permission":"entry"}""")
                "Setting.Admin" -> obj("""{"package_version":"synthetic"}""")
                "Setting.TeamSpace" -> obj("""{"enabled":true}""")
                "Browse.Item" -> obj("""{"list":[{"id":51,"filename":"Synthetic.png","filesize":4,"time":1,"indexed_time":2,"folder_id":9,"type":"photo","additional":{"thumbnail":{"unit_id":151,"cache_key":"old"}}}]}""")
                "Browse.Folder" -> obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":true,"manage":true,"download":$allowDownload}}}}""")
                "RegeneratePreview" -> if (method in setOf("set_regenerating", "list_regenerating")) {
                    if (method == "set_regenerating") assertEquals(mapOf("item_id" to "[51]"), fields)
                    obj("""{"list":[{"unit_id":51,"filename":"Synthetic.png","type":"photo"}]}""")
                } else obj("{}")
                else -> error("Unexpected synthetic API")
            }
        }, media, previewEvents = { object : SynologyPhotoPreviewEvents {
            override suspend fun subscribe(unitId: Long) { methods += "subscribe" }
            override suspend fun completion() = true
            override fun close() {}
        } }, previewConverter = { file, type ->
            assertEquals("photo", type); assertArrayEquals(byteArrayOf(1, 2, 3, 4), file.readBytes()); conversion()
            SynologyPhotoConvertedPreview(byteArrayOf(1), byteArrayOf(2), byteArrayOf(3))
        })
        override fun close() { assertTrue(cache.deleteRecursively()) }
        companion object { fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
    }
    @Test fun `本任务原件下载不会被自己的管理记录阻断且两来源路由准确`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) Fixture(space).use { f ->
            assertFalse(f.repository.canRegeneratePreviews(space)); f.repository.access(); assertTrue(f.repository.canRegeneratePreviews(space))
            val row = f.repository.preparePreviewRegeneration(listOf(f.photo), false)
            val result = f.repository.performPreviewRegeneration(row, f.cache) { validatePhotoAlbumCheckpoint(it) }
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
            assertEquals(listOf("GET", "POST"), f.requests.map { it.method })
            val prefix = if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam" else "SYNO.Foto"
            assertEquals("$prefix.Download", f.requests.first().url.queryParameter("api"))
            assertEquals("[51]", f.requests.first().url.queryParameter("item_id")); assertEquals("\"source\"", f.requests.first().url.queryParameter("download_type"))
            val bytes = Buffer(); f.requests.last().body!!.writeTo(bytes); assertTrue(bytes.readUtf8().contains("$prefix.Upload.ConvertedFile"))
            assertFalse(f.methods.contains("regenerate_preview_by_nas")); assertTrue(f.cache.list()!!.isEmpty())
        }
    }
    @Test fun `未知上传任务仍阻止普通导出与新写请求`() = runBlocking {
        Fixture(SynologyPhotoSpace.PERSONAL).use { f ->
            f.repository.access(); f.uploadUnknown = true
            val pending = f.repository.performPreviewRegeneration(f.repository.preparePreviewRegeneration(listOf(f.photo), false), f.cache) {}
            assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
            assertTrue(failure { f.repository.downloadOriginal(f.photo, File(f.cache, "export")) } is SynologyPhotoFailure)
            val next = f.repository.preparePreviewRegeneration(listOf(f.photo), false)
            assertTrue(failure { f.repository.performPreviewRegeneration(next, f.cache) {} } is SynologyPhotoFailure)
            assertEquals(2, f.requests.size); assertEquals(1, f.methods.count { it == "set_regenerating" }); assertTrue(f.cache.list()!!.isEmpty())
        }
    }
    @Test fun `原件下载独立受限但管理资格有效时改用NAS生成`() = runBlocking {
        Fixture(SynologyPhotoSpace.SHARED).use { f ->
            f.repository.access(); f.allowDownload = false
            val result = f.repository.performPreviewRegeneration(f.repository.preparePreviewRegeneration(listOf(f.photo), false), f.cache) {}
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
            assertTrue(f.requests.isEmpty()); assertTrue(f.methods.contains("subscribe")); assertEquals(1, f.methods.count { it == "regenerate_preview_by_nas" })
            assertTrue(f.cache.list()!!.isEmpty())
        }
    }
    @Test fun `转换期间访问代次变化不会标记上传或留原件`() = runBlocking {
        Fixture(SynologyPhotoSpace.PERSONAL).use { f ->
            f.repository.access(); val row = f.repository.preparePreviewRegeneration(listOf(f.photo), false)
            f.conversion = { f.home = false; f.repository.access() }
            val result = f.repository.performPreviewRegeneration(row, f.cache) {}
            assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
            assertEquals(listOf("GET"), f.requests.map { it.method }); assertFalse(f.methods.contains("set_regenerating")); assertTrue(f.cache.list()!!.isEmpty())
        }
    }
    private suspend fun failure(block: suspend () -> Unit): Throwable {
        try { block() } catch (error: Throwable) { return error }
        throw AssertionError("应失败")
    }
}
