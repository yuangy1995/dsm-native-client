package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

/** 真实Repository组合根与媒体请求编码，只在网络边界注入合成资料。 */
class SynologyPhotosAutomaticPreviewRepositoryTest {
    private data class Call(val api: ApiCapability, val method: String, val fields: Map<String, String>)
    private class Fixture(val space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL) : AutoCloseable {
        val directory = Files.createTempDirectory("automatic-preview-fixture-").toFile()
        var photo = SynologyPhoto(SynologyPhotoId("automatic", space, 51), "Synthetic.jpg", 999, 1.0, 2.0, 9,
            "photo", SynologyPhotoThumbnail(151, "old"))
        var owner: JsonElement? = JsonPrimitive(if (space == SynologyPhotoSpace.SHARED) 0 else 41)
        var home = true; var management = false; var view = true; var download = true; var folderId = 9L
        var enabled: JsonElement? = JsonPrimitive(true)
        var large: JsonElement? = JsonPrimitive("ame_defect"); var small: JsonElement? = JsonPrimitive("ready")
        var videoStatus: JsonElement? = JsonPrimitive("ame_defect"); var codec: JsonElement? = JsonPrimitive("h264")
        var units: JsonObject = obj("""{"list":[{"id_item":51,"unit":[
            {"id":151,"filename":"Synthetic.heic","live_type":"photo","additional":{"thumbnail":{"unit_id":151,"xl":"ame_defect","sm":"ready"}}},
            {"id":252,"filename":"Synthetic.mov","live_type":"video","additional":{"thumbnail":{"unit_id":252,"xl":"ready","sm":"ready"},"video_meta":{"video_codec":"hevc"},"video_convert_status":"ame_defect"}}
        ]}]}""")
        var list: JsonObject = obj("""{"list":[{"unit_id":451,"filename":"Background.mov","type":3,"need_thumbnail":true,"need_video":1}]}""")
        var itemTransform: (JsonObject) -> JsonObject = { it }
        var afterRead: suspend (Call) -> Unit = {}
        var mediaHook: () -> Unit = {}
        var bytes = byteArrayOf(1, 2, 3, 4)
        var declared: Long? = null; var mediaType = "image/jpeg"; var code = 200
        val calls = mutableListOf<Call>(); val mediaRequests = mutableListOf<Request>()
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Item", "Browse.Unit", "Browse.Folder", "Upload.ConvertedFile", "Download")
                .map { ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.associateBy { it.name }.toMutableMap()
        val media = SynologyPhotosMediaTransport(NasProfile("automatic", "Synthetic", "nas.example.invalid", "tester"),
            DsmSession("automatic", "synthetic-session", "synthetic-token"), "https://nas.example.invalid",
            OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); mediaRequests += request; mediaHook()
                val body = bytes.toResponseBody(mediaType.toMediaType())
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(code).message("Synthetic")
                    .header("Content-Type", mediaType).body(object : ResponseBody() {
                        override fun contentType() = body.contentType()
                        override fun contentLength() = declared ?: bytes.size.toLong()
                        override fun source() = body.source()
                    }).build()
            }.build())
        val repository by lazy { SynologyPhotosRepository("automatic", caps, { api, method, fields ->
            val call = Call(api, method, fields); calls += call
            val result = when (api.name.substringAfter("SYNO.Foto").removePrefix("Team").removePrefix(".")) {
                "UserInfo" -> obj("""{"enabled":true,"id":41}""")
                "Setting.User" -> buildJsonObject {
                    put("enable_home_service", home); put("team_space_permission", if (management) "management" else "entry")
                    enabled?.let { put("auto_generate_thumbnail", it) }
                }
                "Setting.Admin" -> obj("""{"package_version":"synthetic"}""")
                "Setting.TeamSpace" -> obj("""{"enabled":true}""")
                "Browse.Item" -> buildJsonObject { put("list", JsonArray(listOf(itemTransform(item())))) }
                "Browse.Unit" -> units
                "Browse.Folder" -> obj("""{"folder":{"id":$folderId,"additional":{"access_permission":{"view":$view,"download":$download,"manage":true}}}}""")
                "Upload.ConvertedFile" -> { assertEquals("list_convert_needed", method); list }
                else -> error("Unexpected synthetic call")
            }
            afterRead(call); result
        }, media) }
        fun item() = buildJsonObject {
            put("id", photo.id.itemId); put("filename", photo.filename); put("filesize", photo.sizeBytes)
            put("time", photo.takenAt); put("indexed_time", photo.indexedAt); put("folder_id", photo.folderId); put("type", photo.mediaType)
            owner?.let { put("owner_user_id", it) }
            put("additional", buildJsonObject {
                photo.thumbnail?.let { thumb -> put("thumbnail", buildJsonObject {
                    put("unit_id", thumb.unitId); put("cache_key", thumb.revision)
                    large?.let { put("xl", it) }; small?.let { put("sm", it) }; put("m", "ame_defect")
                }) }
                codec?.let { put("video_meta", buildJsonObject { put("video_codec", it) }) }
                videoStatus?.let { put("video_convert_status", it) }
            })
        }
        suspend fun ready() { repository.access(); calls.clear() }
        suspend fun visible(support: SynologyPhotoPreviewConversionSupport = all) = repository.automaticPreviewTasks(photo, support)
        suspend fun background(support: SynologyPhotoPreviewConversionSupport = all) = repository.automaticPreviewTasks(space, support)
        val target get() = File(directory, "source")
        override fun close() { assertTrue(directory.deleteRecursively()) }
    }

    @Test fun `按实际能力使用既有三种preset无能力不扫描`() = runBlocking {
        Fixture().use { f -> f.ready()
            for (hevc in listOf(false, true)) for (video in listOf(false, true)) for (vc1 in listOf(false, true)) {
                f.calls.clear(); val result = f.background(SynologyPhotoPreviewConversionSupport(hevc, video, vc1))
                if (!hevc && !video) { assertTrue(result.isEmpty()); assertTrue(f.calls.isEmpty()); continue }
                val call = f.calls.single(); assertEquals(3, call.api.maxVersion); assertEquals("list_convert_needed", call.method)
                assertEquals(mapOf("type" to if (hevc) "[\"photo\",\"video\",\"live_video\"]" else "[\"video\"]",
                    "preset" to "\"${if (vc1) if (hevc) "windows" else "windows2" else "macos"}\""), call.fields)
                assertEquals(451L, result.single().unitId); assertEquals(3, result.single().typeCode)
                assertEquals(SynologyPhotoAutomaticPreviewPriority.BACKGROUND, result.single().priority)
            }
            assertTrue(f.mediaRequests.isEmpty())
        }
    }
    @Test fun `后台共享扫描要求管理权限不能借目录下载权`() = runBlocking {
        Fixture(SynologyPhotoSpace.SHARED).use { f -> f.ready()
            failure(SynologyPhotoFailureKind.PERMISSION) { f.background() }; assertTrue(f.calls.isEmpty())
            f.management = true; f.ready(); f.background()
            assertEquals("SYNO.FotoTeam.Upload.ConvertedFile", f.calls.single().api.name)
        }
    }
    @Test fun `后台需求只接受布尔和零一且缺字段重复单元整批失败`() = runBlocking {
        Fixture().use { f -> f.ready()
            for (flag in listOf("true", "false", "0", "1")) {
                f.list = obj("""{"list":[{"unit_id":7,"filename":"Synthetic.mp4","type":8,"need_thumbnail":$flag,"need_video":$flag}]}""")
                assertEquals(flag in setOf("true", "1"), f.background().single().needsVideo)
            }
            val valid = obj("""{"unit_id":7,"filename":"Synthetic.mp4","type":8,"need_thumbnail":true,"need_video":false}""")
            val invalid = listOf(JsonObject(valid - "need_video"), JsonObject(valid + ("need_thumbnail" to JsonPrimitive("true"))),
                JsonObject(valid + ("need_video" to JsonPrimitive(2))), JsonObject(valid + ("unit_id" to JsonPrimitive(0))),
                JsonObject(valid + ("type" to JsonPrimitive(-1))), JsonObject(valid + ("type" to JsonPrimitive("0"))),
                JsonObject(valid + ("filename" to JsonPrimitive(""))))
            for (entry in invalid) { f.list = buildJsonObject { put("list", JsonArray(listOf(valid, entry))) }; failure { f.background() } }
            f.list = buildJsonObject { put("list", JsonArray(listOf(valid, valid))) }; failure { f.background() }
            f.list = obj("{}"); failure { f.background() }
            f.list = obj("""{"list":[]}"""); assertTrue(f.background().isEmpty())
        }
    }
    @Test fun `可见候选按实际thumbnail单元与缺陷字段判定不扫描后台`() = runBlocking {
        Fixture().use { f -> f.ready(); val task = f.visible().single()
            assertEquals(151L, task.unitId); assertEquals(51L, task.source!!.id.itemId); assertEquals(151L, task.sourceThumbnailUnitId)
            assertTrue(task.needsThumbnail); assertFalse(task.needsVideo); assertEquals(SynologyPhotoAutomaticPreviewPriority.STANDARD, task.priority)
            assertEquals("SYNO.Foto.Browse.Item", f.calls.single().api.name)
            assertEquals(mapOf("id" to "[51]", "additional" to "[\"thumbnail\",\"video_meta\",\"video_convert\"]"), f.calls.single().fields)
            f.large = null; f.small = null; assertTrue(f.visible().isEmpty())
            f.small = JsonPrimitive("ame_defect"); assertEquals(1, f.visible().size)
            f.large = JsonPrimitive(3); failure { f.visible() }
            assertTrue(f.mediaRequests.isEmpty())
        }
    }
    @Test fun `HEIC和各视频编码受真实转换能力过滤并保留成本优先级`() = runBlocking {
        Fixture().use { f -> f.ready()
            for (name in listOf("A.HEIC", "A.heif", "A.hif")) {
                f.photo = f.photo.copy(filename = name); assertTrue(f.visible(all.copy(hevc = false)).isEmpty()); assertEquals(1, f.visible().size)
            }
            f.photo = f.photo.copy(filename = "A.mov", mediaType = "video")
            for (codec in listOf("h264", "hevc", "vc1", "wmv3")) {
                f.codec = JsonPrimitive(codec)
                val task = f.visible().single(); assertTrue(task.video && task.needsVideo)
                assertEquals(when (codec) { "hevc" -> SynologyPhotoAutomaticPreviewPriority.HEVC_OR_LIVE_VIDEO
                    "vc1", "wmv3" -> SynologyPhotoAutomaticPreviewPriority.VC1
                    else -> SynologyPhotoAutomaticPreviewPriority.STANDARD }, task.priority)
                assertTrue(f.visible(all.copy(video = false)).isEmpty())
                if (codec == "hevc") assertTrue(f.visible(all.copy(hevc = false)).isEmpty())
                if (codec in setOf("vc1", "wmv3")) assertTrue(f.visible(all.copy(vc1 = false)).isEmpty())
            }
            f.photo = f.photo.copy(mediaType = "video360"); assertTrue(f.visible().single().video)
        }
    }
    @Test fun `实况按照片与视频真实unit返回并单独过滤不把Item当视频单元`() = runBlocking {
        Fixture().use { f -> f.photo = f.photo.copy(mediaType = "live"); f.ready()
            val tasks = f.visible(); assertEquals(listOf(151L, 252L), tasks.map { it.unitId }); assertEquals(listOf(false, true), tasks.map { it.video })
            assertEquals(listOf(true, false), tasks.map { it.needsThumbnail }); assertEquals(listOf(false, true), tasks.map { it.needsVideo })
            assertEquals(SynologyPhotoAutomaticPreviewPriority.HEVC_OR_LIVE_VIDEO, tasks.last().priority)
            val call = f.calls.last(); assertEquals("SYNO.Foto.Browse.Unit", call.api.name); assertEquals(1, call.api.maxVersion)
            assertEquals("[51]", call.fields["id_item"]); assertFalse(call.fields.containsKey("id"))
            assertEquals(listOf(151L), f.visible(all.copy(video = false)).map { it.unitId })
            assertTrue(f.visible(all.copy(hevc = false)).isEmpty())
        }
    }
    @Test fun `实况错误归属缺单元重复单元缩略图错配均拒绝`() = runBlocking {
        Fixture().use { f -> f.photo = f.photo.copy(mediaType = "live"); f.ready()
            val good = f.units.getValue("list").jsonArray.single().jsonObject
            val units = good.getValue("unit").jsonArray
            val video = units.last().jsonObject
            val badUnits = listOf(JsonArray(emptyList()), JsonArray(listOf(video, video)), JsonArray(listOf(JsonObject(video - "filename"))),
                JsonArray(listOf(JsonObject(video + ("live_type" to JsonPrimitive("live"))))),
                JsonArray(listOf(JsonObject(video + ("id" to JsonPrimitive(999))))))
            for (values in badUnits) { f.units = buildJsonObject { put("list", JsonArray(listOf(JsonObject(good + ("unit" to values))))) }; failure { f.visible() } }
            f.units = buildJsonObject { put("list", JsonArray(listOf(JsonObject(good + ("id_item" to JsonPrimitive(999)))))) }
            failure(SynologyPhotoFailureKind.TARGET_CHANGED) { f.visible() }
            f.units = buildJsonObject { put("list", JsonArray(listOf(good, good))) }; failure { f.visible() }
        }
    }
    @Test fun `物理来源归属必须是本人或共享零所有者相册下载权不能扩大`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) Fixture(space).use { f -> f.ready()
            f.photo = f.photo.copy(albumContext = SynologyPhotoAlbumContext(71, if (space == SynologyPhotoSpace.SHARED) 0 else 41, 41))
            assertEquals(1, f.visible().size); assertTrue(f.calls.none { "album_id" in it.fields || "Sharing" in it.api.name })
            f.owner = JsonPrimitive(if (space == SynologyPhotoSpace.SHARED) 41 else 99)
            failure(SynologyPhotoFailureKind.PERMISSION) { f.visible() }
            f.owner = null; failure { f.visible() }; f.owner = JsonNull; failure { f.visible() }
        }
    }
    @Test fun `共享entry可见目录要真实view与download且目录身份不能变化`() = runBlocking {
        Fixture(SynologyPhotoSpace.SHARED).use { f -> f.ready(); assertEquals(1, f.visible().size)
            f.download = false; failure(SynologyPhotoFailureKind.PERMISSION) { f.visible() }
            f.download = true; f.view = false; failure(SynologyPhotoFailureKind.PERMISSION) { f.visible() }
            f.view = true; f.folderId = 10; failure(SynologyPhotoFailureKind.TARGET_CHANGED) { f.visible() }
            f.management = true; f.ready(); assertEquals(1, f.visible().size); assertEquals(1, f.calls.size)
        }
    }
    @Test fun `文件身份和缩略图单元变化不能继续旧可见任务`() = runBlocking {
        Fixture().use { f -> f.ready(); val old = f.photo
            for (next in listOf(old.copy(filename = "Other.jpg"), old.copy(id = old.id.copy(itemId = 52)), old.copy(sizeBytes = 1000),
                old.copy(indexedAt = 3.0), old.copy(folderId = 10), old.copy(mediaType = "video"), old.copy(thumbnail = SynologyPhotoThumbnail(999, "old")))) {
                f.photo = next; failure(SynologyPhotoFailureKind.TARGET_CHANGED) { f.repository.automaticPreviewTasks(old, all) }
            }
            f.photo = old; failure(SynologyPhotoFailureKind.PERMISSION) { f.repository.automaticPreviewTasks(old.copy(id = old.id.copy(profileId = "other")), all) }
            assertTrue(f.mediaRequests.isEmpty())
        }
    }
    @Test fun `设置读取是真实布尔缺失或迟到代次均不能默认开启`() = runBlocking {
        Fixture().use { f -> f.ready(); assertTrue(f.repository.automaticPreviewEnabled())
            f.enabled = JsonPrimitive(false); assertFalse(f.repository.automaticPreviewEnabled())
            for (value in listOf(null, JsonNull, JsonPrimitive(1), JsonPrimitive("true"))) {
                f.enabled = value; failure { f.repository.automaticPreviewEnabled() }
            }
            f.enabled = JsonPrimitive(true)
            f.afterRead = { if (it.api.name == "SYNO.Foto.Setting.User") { f.afterRead = {}; f.repository.access() } }
            cancellation { f.repository.automaticPreviewEnabled() }
        }
    }
    @Test fun `候选读取期间重新登录或取消丢弃迟到结果`() = runBlocking {
        Fixture().use { f -> f.ready()
            f.afterRead = { if (it.api.name.endsWith(".Browse.Item")) { f.afterRead = {}; f.repository.access() } }
            cancellation { f.visible() }
            f.afterRead = { if (it.api.name.endsWith(".Upload.ConvertedFile")) throw CancellationException() }
            cancellation { f.background() }; assertTrue(f.mediaRequests.isEmpty())
        }
    }
    @Test fun `可見原件两来源按unit下载并在完整文件后重新校对`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) Fixture(space).use { f -> f.ready()
            val task = f.visible().single(); f.calls.clear()
            f.repository.downloadAutomaticPreviewSource(task, all, f.target)
            assertArrayEquals(f.bytes, f.target.readBytes()); assertEquals(4L, f.target.length())
            val request = f.mediaRequests.single(); assertEquals("GET", request.method)
            assertEquals("[151]", request.url.queryParameter("unit_id")); assertNull(request.url.queryParameter("item_id"))
            assertEquals("2", request.url.queryParameter("version")); assertNull(request.url.queryParameter("download_type"))
            assertEquals(if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam.Download" else "SYNO.Foto.Download", request.url.queryParameter("api"))
            assertEquals(2, f.calls.count { it.api.name.endsWith(".Browse.Item") }); assertEquals(1, f.directory.list()!!.size)
        }
    }
    @Test fun `后台单元下载重新读取同源批次而不猜Item编号`() = runBlocking {
        Fixture(SynologyPhotoSpace.SHARED).use { f -> f.management = true; f.ready()
            val task = f.background().single(); f.calls.clear(); f.repository.downloadAutomaticPreviewSource(task, all, f.target)
            assertEquals(listOf("list_convert_needed", "list_convert_needed"), f.calls.map { it.method })
            assertEquals("[451]", f.mediaRequests.single().url.queryParameter("unit_id"))
        }
    }
    @Test fun `下载前需求已完成或任务参数变更零媒体请求`() = runBlocking {
        Fixture().use { f -> f.ready(); val task = f.visible().single(); f.large = JsonPrimitive("ready")
            failure(SynologyPhotoFailureKind.TARGET_CHANGED) { f.repository.downloadAutomaticPreviewSource(task, all, f.target) }
            f.large = JsonPrimitive("ame_defect")
            failure(SynologyPhotoFailureKind.TARGET_CHANGED) { f.repository.downloadAutomaticPreviewSource(task.copy(unitId = 999), all, f.target) }
            failure(SynologyPhotoFailureKind.PERMISSION) { f.repository.downloadAutomaticPreviewSource(task.copy(space = SynologyPhotoSpace.SHARED), all, f.target) }
            failure { f.repository.downloadAutomaticPreviewSource(task.copy(needsVideo = true), all, f.target) }
            assertTrue(f.mediaRequests.isEmpty()); assertTrue(f.directory.list()!!.isEmpty())
        }
    }
    @Test fun `下载期间目标需求或目录权限变化不提升文件`() = runBlocking {
        Fixture(SynologyPhotoSpace.SHARED).use { f -> f.ready(); val task = f.visible().single()
            f.mediaHook = { f.download = false }; failure(SynologyPhotoFailureKind.PERMISSION) { f.repository.downloadAutomaticPreviewSource(task, all, f.target) }
            assertTrue(f.directory.list()!!.isEmpty()); f.download = true
            f.mediaHook = { f.large = JsonPrimitive("ready") }; failure(SynologyPhotoFailureKind.TARGET_CHANGED) { f.repository.downloadAutomaticPreviewSource(task, all, f.target) }
            assertTrue(f.directory.list()!!.isEmpty())
        }
    }
    @Test fun `错误页压缩包空内容长度与HTTP异常全部清理临时原件`() = runBlocking {
        Fixture().use { f -> f.ready(); val task = f.visible().single()
            for ((type, bytes) in listOf("application/json" to "{}".toByteArray(), "text/html" to "login".toByteArray(),
                "application/zip" to byteArrayOf(1), "application/octet-stream" to "{\"error\":true}".toByteArray(),
                "image/jpeg" to byteArrayOf(0x50, 0x4b, 5, 6), "image/jpeg" to byteArrayOf())) {
                f.mediaType = type; f.bytes = bytes; failure(SynologyPhotoFailureKind.MEDIA) { f.repository.downloadAutomaticPreviewSource(task, all, f.target) }
                assertTrue(f.directory.list()!!.isEmpty())
            }
            f.mediaType = "image/jpeg"; f.bytes = byteArrayOf(1, 2, 3, 4)
            for (length in listOf(2L, 7L)) { f.declared = length; failure(SynologyPhotoFailureKind.LENGTH_MISMATCH) { f.repository.downloadAutomaticPreviewSource(task, all, f.target) }; assertTrue(f.directory.list()!!.isEmpty()) }
            f.declared = null; f.code = 302; failure(SynologyPhotoFailureKind.MEDIA) { f.repository.downloadAutomaticPreviewSource(task, all, f.target) }; assertTrue(f.directory.list()!!.isEmpty())
            f.code = 200; f.declared = -1; f.repository.downloadAutomaticPreviewSource(task, all, f.target); assertArrayEquals(f.bytes, f.target.readBytes())
        }
    }
    @Test fun `下载不覆盖既有文件且提升前取消保留用户数据`() = runBlocking {
        Fixture().use { f -> f.ready(); val task = f.visible().single(); f.target.writeText("keep")
            try { f.repository.downloadAutomaticPreviewSource(task, all, f.target); fail() } catch (_: java.nio.file.FileAlreadyExistsException) {}
            assertEquals("keep", f.target.readText()); assertTrue(f.mediaRequests.isEmpty()); f.target.delete()
            var reads = 0
            f.afterRead = { if (it.api.name.endsWith(".Browse.Item") && ++reads == 2) throw CancellationException() }
            cancellation { f.repository.downloadAutomaticPreviewSource(task, all, f.target) }
            assertTrue(f.directory.list()!!.isEmpty())
        }
    }
    @Test fun `能力版本格式与来源缺失不误报支持且不能下载`() = runBlocking {
        Fixture().use { f -> assertFalse(f.repository.canGenerateAutomaticPreviews(f.space)); f.ready(); assertTrue(f.repository.canGenerateAutomaticPreviews(f.space))
        }
        for (missing in listOf("absent", "version", "format")) Fixture().use { f ->
            val name = "SYNO.Foto.Upload.ConvertedFile"; val cap = f.caps.getValue(name)
            when (missing) {
                "absent" -> f.caps.remove(name)
                "version" -> f.caps[name] = cap.copy(maxVersion = 2)
                else -> f.caps[name] = cap.copy(requestFormat = "FORM")
            }
            f.ready(); val task = f.visible().single(); assertFalse(f.repository.canGenerateAutomaticPreviews(f.space))
            failure(SynologyPhotoFailureKind.UNAVAILABLE) { f.repository.downloadAutomaticPreviewSource(task, all, f.target) }
            assertTrue(f.mediaRequests.isEmpty())
        }
    }
    @Test fun `同单元来源或非零类型不同仍去重但不同需求不可合并`() {
        val task = SynologyPhotoAutomaticPreviewTask("synthetic", SynologyPhotoSpace.PERSONAL, 7, "private-name.mov", 1, true, true)
        assertTrue(task.sameMedia(task.copy(typeCode = 3, priority = SynologyPhotoAutomaticPreviewPriority.HEVC_OR_LIVE_VIDEO)))
        assertFalse(task.sameMedia(task.copy(needsVideo = false))); assertFalse(task.sameMedia(task.copy(space = SynologyPhotoSpace.SHARED)))
        assertFalse(task.sameMedia(task.copy(profileId = "other"))); assertFalse(task.sameMedia(task.copy(typeCode = 0)))
        assertFalse(task.toString().contains("private-name"))
    }
    companion object {
        private val all = SynologyPhotoPreviewConversionSupport(true, true, true)
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private suspend fun failure(kind: SynologyPhotoFailureKind = SynologyPhotoFailureKind.INVALID_RESPONSE, block: suspend () -> Any?) {
            try { block(); fail("应拒绝不正确的自动预览来源") } catch (error: SynologyPhotoFailure) { assertEquals(kind, error.kind) }
        }
        private suspend fun cancellation(block: suspend () -> Any?) {
            try { block(); fail("应停止迟到自动预览") } catch (_: CancellationException) {}
        }
    }
}
