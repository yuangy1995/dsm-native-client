package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosExportRepositoryTest {
    @Test fun `媒体传输不可用时不得先请求NAS转换`() = runBlocking {
        Fixture(mediaEnabled = false).use { f ->
            f.ready()
            failure { f.repository.download(f.photo, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.target()) }
            assertTrue(f.calls.isEmpty()); assertTrue(f.mediaCalls.isEmpty())
        }
    }
    @Test fun `原件与压缩按个人共享及相册来源请求且先核对身份权限`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) for (album in listOf(false, true)) Fixture().use { f ->
            f.photo = f.photo.copy(id = f.photo.id.copy(space = space), albumContext = if (album) SynologyPhotoAlbumContext(7, if (space == SynologyPhotoSpace.SHARED) 0 else 41, 41) else null)
            f.ready()
            for (format in listOf(SynologyPhotoDownloadFormat.ORIGINAL, SynologyPhotoDownloadFormat.OPTIMIZED_JPEG)) {
                assertEquals(SynologyPhotoDownloadFormat.ORIGINAL, f.repository.download(f.photo, format, f.target(format.name)))
                val request = f.mediaCalls.last()
                assertEquals("GET", request.method)
                assertEquals(if (space == SynologyPhotoSpace.SHARED && !album) "SYNO.FotoTeam.Download" else "SYNO.Foto.Download", request.url.queryParameter("api"))
                assertEquals(if (album) "7" else null, request.url.queryParameter("album_id"))
                assertEquals("[11]", request.url.queryParameter("item_id"))
                assertEquals(JsonPrimitive(format.value).toString(), request.url.queryParameter("download_type"))
            }
            assertEquals(0, f.calls.count { it.method == "convert" })
        }
    }

    @Test fun `原尺寸需要双能力标记与照片格式缺失错误类型均不阻断读取`() = runBlocking {
        for (user in listOf("{}", "{\"has_hevc\":false}", "{\"has_hevc\":true}", "{\"has_hevc\":\"true\"}"))
            for (admin in listOf("false", "true", "null", "\"true\"")) Fixture().use { f ->
                f.ame = user; f.converted = admin
                val enabled = f.repository.access().supportsOriginalSizeJPEG
                assertEquals(user == "{\"has_hevc\":true}" && admin == "true", enabled)
                if (!enabled) failure { f.repository.download(f.photo, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.target()) }
                assertTrue(f.mediaCalls.isEmpty()); assertTrue(f.calls.none { it.method == "convert" })
            }
        Fixture().use { f ->
            f.ready()
            for (photo in listOf(f.photo.copy(filename = "synthetic.jpg"), f.photo.copy(mediaType = "video")))
                failure { f.repository.download(photo, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.target()) }
            assertTrue(f.calls.isEmpty())
        }
        assertTrue(Fixture.photo.copy(filename = "synthetic.Cr3").supportsOriginalSizeJPEG)
        assertTrue(Fixture.photo.copy(filename = "synthetic.TIFF").supportsOriginalSizeJPEG)
        assertTrue(Fixture.photo.copy(mediaType = "live").supportsOriginalSizeJPEG)
    }

    @Test fun `原尺寸先标量转换成功再数组下载协作口令仅POST体`() = runBlocking {
        for (owner in listOf(41L, 99L)) for (space in SynologyPhotoSpace.entries) Fixture().use { f ->
            f.albumOwner = owner; f.photo = f.photo.copy(id = f.photo.id.copy(space = space), albumContext = SynologyPhotoAlbumContext(7, if (space == SynologyPhotoSpace.SHARED) 0 else 41, 41))
            f.bytes = Fixture.jpeg; f.type = "image/jpeg"; f.ready()
            assertEquals(SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.repository.download(f.photo, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.target()))
            val call = f.calls.single { it.method == "convert" }
            assertEquals("SYNO.Foto.Download", call.api); assertEquals("11", call.fields["item_id"])
            assertEquals(if (owner == 41L) "7" else null, call.fields["album_id"])
            assertEquals(if (owner == 41L) null else "\"synthetic-passphrase\"", call.fields["passphrase"])
            val download = f.mediaCalls.single()
            assertEquals("POST", download.method); assertNull(download.url.query)
            assertEquals("[11]", download.fields()["item_id"])
            assertEquals("\"original_size_jpeg\"", download.fields()["download_type"])
            assertEquals(call.fields["passphrase"], download.fields()["passphrase"])
            assertTrue(download.url.toString().contains("passphrase").not())
        }
    }

    @Test fun `本人贡献须新提供者与原空间同时满足不能借上传权导出整册`() = runBlocking {
        Fixture().use { f ->
            f.albumOwner = 99; f.albumDownload = false; f.photo = f.photo.copy(albumContext = SynologyPhotoAlbumContext(7, 41, 41)); f.ready()
            f.repository.downloadOriginal(f.photo, f.target("own"))
            failure { f.repository.downloadArchive(SynologyPhotoArchiveTarget.Album(7), SynologyPhotoDownloadFormat.ORIGINAL, f.target("album")) }
            f.provider = 99
            failure { f.repository.downloadOriginal(f.photo, f.target("other")) }
            f.provider = 41; f.home = false; f.repository.access()
            failure { f.repository.downloadOriginal(f.photo, f.target("home-off")) }
            f.albumDownload = true
            f.repository.downloadOriginal(f.photo, f.target("album-only"))
            assertEquals(2, f.mediaCalls.size)
            assertTrue(f.mediaCalls.all { it.url.queryParameter("album_id") == "7" })
        }
    }

    @Test fun `最新身份及目录下载拒绝在下载或转换前终止`() = runBlocking {
        for (kind in 0..4) Fixture().use { f ->
            f.ready(); val selected = f.photo
            when (kind) { 0 -> f.photo = selected.copy(filename = "changed.heic"); 1 -> f.photo = selected.copy(folderId = 12)
                2 -> f.photo = selected.copy(takenAt = 9.0); 3 -> f.view = false; 4 -> f.download = JsonPrimitive(false) }
            for (format in SynologyPhotoDownloadFormat.entries) failure { f.repository.download(selected, format, f.target()) }
            assertTrue(f.mediaCalls.isEmpty()); assertTrue(f.calls.none { it.method == "convert" }); assertTrue(f.directory.listFiles()!!.isEmpty())
        }
    }

    @Test fun `个人缺省下载允许共享entry要求明确权限共享管理沿现有权限`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) for (manager in listOf(false, true)) Fixture().use { f ->
            f.photo = f.photo.copy(id = f.photo.id.copy(space = space)); f.team = if (manager) "management" else "entry"; f.download = null; f.ready()
            if (space == SynologyPhotoSpace.SHARED && !manager) failure { f.repository.downloadOriginal(f.photo, f.target()) }
            else f.repository.downloadOriginal(f.photo, f.target())
        }
    }

    @Test fun `转换在途去重失败与取消不重放且失效代次不下载`() = runBlocking {
        Fixture().use { f ->
            f.ready(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.onCall = { if (it.method == "convert") { entered.complete(Unit); release.await(); throw IOException("Synthetic lost conversion reply") } }
            val first = async { runCatching { f.repository.download(f.photo, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.target()) } }
            entered.await()
            failure { f.repository.download(f.photo, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.target("second")) }
            release.complete(Unit); assertTrue(first.await().exceptionOrNull() is IOException)
            assertEquals(1, f.calls.count { it.method == "convert" }); assertTrue(f.mediaCalls.isEmpty())
            f.onCall = { if (it.method == "convert") f.repository.access() }
            try { f.repository.download(f.photo, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.target()); fail() } catch (_: CancellationException) { }
            assertEquals(2, f.calls.count { it.method == "convert" }); assertTrue(f.mediaCalls.isEmpty())
            f.onCall = { if (it.method == "convert") awaitCancellation() }
            val task = launch { f.repository.download(f.photo, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.target()) }
            yield(); task.cancelAndJoin(); assertTrue(f.mediaCalls.isEmpty()); assertTrue(f.directory.listFiles()!!.isEmpty())
        }
    }

    @Test fun `完整相册与文件夹归档用实际集合编号及POST不枚举当前加载页`() = runBlocking {
        for (owner in listOf(41L, 99L)) Fixture().use { f ->
            f.albumOwner = owner; f.bytes = Fixture.zip; f.type = "application/zip"; f.home = false; f.ready()
            f.repository.downloadArchive(SynologyPhotoArchiveTarget.Album(7), SynologyPhotoDownloadFormat.OPTIMIZED_JPEG, f.target())
            val call = f.mediaCalls.single(); assertEquals("POST", call.method); assertNull(call.url.query)
            assertEquals("SYNO.Foto.Browse.Album", call.fields()["api"])
            assertEquals(if (owner == 41L) "7" else null, call.fields()["id"])
            assertEquals(if (owner == 41L) null else "\"synthetic-passphrase\"", call.fields()["passphrase"])
            assertTrue(f.calls.none { it.api.endsWith("Browse.Item") })
        }
        for (space in SynologyPhotoSpace.entries) Fixture().use { f ->
            f.bytes = Fixture.zip; f.type = "application/zip"; f.ready()
            f.repository.downloadArchive(SynologyPhotoArchiveTarget.Folder(9, space), SynologyPhotoDownloadFormat.ORIGINAL, f.target())
            assertEquals("[9]", f.mediaCalls.single().fields()["folder_id"])
            assertNull(f.mediaCalls.single().fields()["item_id"])
            assertEquals(if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam.Download" else "SYNO.Foto.Download", f.mediaCalls.single().fields()["api"])
        }
    }

    @Test fun `同级混选核对所有目录与照片身份禁止跨父目录重复照片和相册照片`() = runBlocking {
        Fixture().use { f ->
            f.bytes = Fixture.zip; f.type = "application/zip"; f.ready()
            val folders = listOf(SynologyPhotoCollection(10, "child", 9, space = SynologyPhotoSpace.PERSONAL, path = "/photos/child"))
            val target = SynologyPhotoArchiveTarget.Selection(listOf(f.photo), folders)
            f.repository.downloadArchive(target, SynologyPhotoDownloadFormat.ORIGINAL, f.target())
            assertEquals("[10]", f.mediaCalls.single().fields()["folder_id"]); assertEquals("[11]", f.mediaCalls.single().fields()["item_id"])
            for (bad in listOf(target.copy(photos = listOf(f.photo, f.photo)), target.copy(photos = listOf(f.photo.copy(folderId = 12))),
                target.copy(photos = listOf(f.photo.copy(albumContext = SynologyPhotoAlbumContext(7, 41)))),
                target.copy(folders = folders + folders), target.copy(folders = folders.map { it.copy(path = "/other/child") })))
                failure { f.repository.downloadArchive(bad, SynologyPhotoDownloadFormat.ORIGINAL, f.target("bad")) }
            f.childDownload = false
            failure { f.repository.downloadArchive(target, SynologyPhotoDownloadFormat.ORIGINAL, f.target("denied")) }
            assertEquals(1, f.mediaCalls.size)
            failure { f.repository.downloadArchive(target, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, f.target("format")) }
        }
    }

    private suspend fun failure(block: suspend () -> Any?) { try { block(); fail("应拒绝导出") } catch (_: SynologyPhotoFailure) { } }

    internal class Fixture(mediaEnabled: Boolean = true) : AutoCloseable {
        data class Call(val api: String, val method: String, val fields: Map<String, String>)
        val directory = Files.createTempDirectory("synthetic-photo-export-").toFile()
        var photo = Companion.photo
        var bytes = byteArrayOf(1, 2, 3, 4); var type = "image/heic"
        var home = true; var team = "entry"; var view = true; var download: JsonPrimitive? = JsonPrimitive(true); var childDownload = true
        var albumOwner = 41L; var albumDownload = true; var provider = 41L
        var ame = "{\"has_hevc\":true}"; var converted = "true"
        val calls = CopyOnWriteArrayList<Call>(); val mediaCalls = CopyOnWriteArrayList<Request>()
        var onCall: suspend (Call) -> Unit = {}
        private val profile = NasProfile("export-fixture", "Synthetic", "https://nas.example.invalid", "tester")
        private val transport = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), profile.address,
            OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); mediaCalls += request
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic").header("Content-Type", type).body(bytes.toResponseBody(type.toMediaType())).build()
            }.build(), validateJPEG = { file ->
                // JVM用独立ImageIO校验合成JPEG；Android默认解码器在仪器测试中覆盖。
                check(javax.imageio.ImageIO.read(file) != null)
            })
        val repository = SynologyPhotosRepository(profile.id, capabilities(), { api, method, fields ->
            val call = Call(api.name, method, fields); calls += call; onCall(call)
            when (api.name.substringAfter("SYNO.Foto").removePrefix("Team").removePrefix(".")) {
                "UserInfo" -> obj("""{"enabled":true,"id":41}""")
                "Setting.User" -> obj("""{"enable_home_service":$home,"team_space_permission":"$team","ame_status":$ame}""")
                "Setting.Admin" -> obj("""{"package_version":"synthetic","enable_converted_original_jpeg":$converted}""")
                "Setting.TeamSpace" -> obj("""{"enabled":true}""")
                "Browse.Item" -> JsonObject(mapOf("list" to JsonArray(listOf(item()))))
                "Browse.Folder" -> {
                    val child = fields["id"] == "10"
                    obj("""{"folder":{"id":${if (child) 10 else 9},"parent":${if (child) 9 else 1},"name":"${if (child) "/photos/child" else "/photos"}","additional":{"access_permission":{"view":$view${if (child || download != null) ",\"download\":" + (if (child) childDownload else download) else ""}}}}}""")
                }
                "Browse.Album" -> obj("""{"list":[{"id":7,"name":"Synthetic album","owner_user_id":$albumOwner,"type":"normal","passphrase":"synthetic-passphrase"}]}""")
                "Sharing.Passphrase" -> obj("""{"permission":{"download":$albumDownload,"upload":true}}""")
                "Download" -> obj("{}")
                else -> error("Unexpected synthetic API")
            }
        }, transport.takeIf { mediaEnabled })
        private fun item() = JsonObject(mapOf("id" to JsonPrimitive(photo.id.itemId), "filename" to JsonPrimitive(photo.filename),
            "filesize" to JsonPrimitive(photo.sizeBytes), "time" to JsonPrimitive(photo.takenAt), "indexed_time" to JsonPrimitive(photo.indexedAt),
            "folder_id" to JsonPrimitive(photo.folderId), "type" to JsonPrimitive(photo.mediaType),
            "owner_user_id" to JsonPrimitive(photo.albumContext?.ownerUserId ?: if (photo.id.space == SynologyPhotoSpace.SHARED) 0 else 41),
            "additional" to JsonObject(mapOf("provider_user_id" to JsonPrimitive(provider)))))
        suspend fun ready() { repository.access(); calls.clear() }
        fun target(name: String = "result") = File(directory, name)
        override fun close() { directory.deleteRecursively() }
        companion object {
            val photo = SynologyPhoto(SynologyPhotoId("export-fixture", SynologyPhotoSpace.PERSONAL, 11), "Synthetic.heic", 4, 1.0, 2.0, 9, "photo")
            val jpeg: ByteArray = java.io.ByteArrayOutputStream().also { javax.imageio.ImageIO.write(java.awt.image.BufferedImage(8, 6, java.awt.image.BufferedImage.TYPE_INT_RGB), "jpeg", it) }.toByteArray()
            val zip: ByteArray = java.io.ByteArrayOutputStream().also { java.util.zip.ZipOutputStream(it).use { zip -> zip.putNextEntry(java.util.zip.ZipEntry("Synthetic.txt")); zip.write(byteArrayOf(1, 2, 3)); zip.closeEntry() } }.toByteArray()
            fun capabilities() = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix -> listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Item", "Browse.Folder", "Browse.Album", "Sharing.Passphrase", "Download").map {
                ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON")
            } }.associateBy { it.name }
            fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        }
    }
}

private fun Request.fields(): Map<String, String> = (body as FormBody).let { form -> (0 until form.size).associate { form.name(it) to form.value(it) } }
