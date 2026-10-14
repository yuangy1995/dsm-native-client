package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoPreviewFact.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosPreviewRepositoryTest {
    internal class Fixture {
        var owner = SynologyPhotosMutationAccess("preview", 41, 0, false)
        var enabledSpaces = SynologyPhotoSpace.entries.toSet()
        val photos = mutableMapOf<SynologyPhotoId, SynologyPhoto>()
        val queue = mutableSetOf<SynologyPhotoId>()
        val calls = mutableListOf<String>()
        val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        var manage = true; var download = true; var view = true
        var albumType = "normal"; var frozen = false
        var missing: String? = null; var markReplyWrong = false
        var failureMethod: String? = null; var failure: Exception = IOException("synthetic unknown")
        var factoryFailure = false; var subscriptionFailure = false; var eventFailure = false
        var nasSuccess = true; var uploadSuccess = true; var uploadFailure = false
        var convertFailure = false; var readFailure = false; var finishReadsFail = false
        var keepQueue = false; var noVersionChange = false; var queueReads = 0
        var queueHook: () -> Unit = {}; var convertHook: () -> Unit = {}; var beforeWrite: suspend (String) -> Unit = {}
        val cache = Files.createTempDirectory("photo-preview-fixture-").toFile()
        val preview = SynologyPhotoConvertedPreview(byteArrayOf(1), byteArrayOf(2), byteArrayOf(3))
        fun photo(id: Long = 51, name: String = "Synthetic.jpg", space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL,
            context: SynologyPhotoAlbumContext? = null) = SynologyPhoto(SynologyPhotoId(owner.profileId, space, id), name,
            4, 1.0, 2.0, 9, "photo", SynologyPhotoThumbnail(id + 100, "old"), albumContext = context).also { photos[it.id] = it }
        fun repository() = SynologyPhotosAlbumRepository(
            identity = { owner }, checkAccess = { expected, space ->
                currentCoroutineContext().ensureActive()
                if (owner != expected || space != null && space !in enabledSpaces) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
            }, capability = { suffix, version, space ->
                if (suffix == missing) throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
                ApiCapability("${if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam" else "SYNO.Foto"}.$suffix", "entry.cgi", version, version, "JSON")
            }, read = { suffix, _, method, fields, space ->
                calls += "$suffix.$method"
                when (suffix) {
                    "RegeneratePreview" -> { queueReads++; queueHook(); queueReply(space!!) }
                    "Browse.Item" -> {
                        if (readFailure) throw IOException("synthetic unavailable read")
                        val id = fields.getValue("id").jsonArray.single().jsonPrimitive.long
                        val source = if (fields["album_id"] != null) photos.values.single { it.id.itemId == id } else photos.getValue(SynologyPhotoId(owner.profileId, space!!, id))
                        obj("list" to JsonArray(listOf(photoJson(source))))
                    }
                    "Browse.Folder" -> obj("folder" to buildJsonObject { put("id", 9); put("additional", buildJsonObject {
                        put("access_permission", buildJsonObject { put("view", view); put("manage", manage); put("download", download) })
                    }) })
                    "Browse.Album" -> obj("list" to JsonArray(listOf(buildJsonObject {
                        put("id", 71); put("name", "Synthetic album"); put("owner_user_id", 41); put("type", albumType); put("freeze_album", frozen)
                    })))
                    else -> error("Unexpected synthetic read: $suffix.$method")
                }
            }, write = { suffix, _, method, fields, space ->
                calls += method; beforeWrite(method)
                val id = (fields["unit_id"] ?: fields.getValue("item_id")).let { if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long }
                val target = SynologyPhotoId(owner.profileId, space!!, id)
                if (method == "set_regenerating") queue += target
                if (method == failureMethod) throw failure
                when (method) {
                    "set_regenerating" -> if (markReplyWrong) obj("list" to JsonArray(listOf(buildJsonObject {
                        put("unit_id", id + 1); put("filename", photos.getValue(target).filename); put("type", "photo")
                    }))) else queueReply(space, setOf(target))
                    "restore_from_regenerating" -> { if (!keepQueue) queue -= target; obj() }
                    "regenerate_preview_by_nas" -> { assertEquals("RegeneratePreview", suffix); obj() }
                    else -> error("Unexpected synthetic write")
                }
            }, details = { photos.getValue(it.id) }, photos = { _, _, _, _ -> error("No timeline read") }, photoPending = { false },
            previewDownload = { photo, file, _ -> calls += "download"; assertFalse(file.exists()); file.writeBytes(ByteArray(photo.sizeBytes.toInt()) { 1 }) },
            previewConvert = { _, _ -> calls += "convert"; convertHook(); if (convertFailure) throw IOException("synthetic decode failure"); preview },
            previewUpload = { cap, id, _ ->
                calls += "upload"; beforeWrite("upload")
                assertEquals(3, cap.maxVersion)
                if (uploadFailure) throw IOException("synthetic upload unknown")
                if (uploadSuccess) finish(SynologyPhotoId(owner.profileId, if (cap.name.startsWith("SYNO.FotoTeam")) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL, id))
                uploadSuccess
            }, previewEvents = {
                if (factoryFailure) throw IOException("synthetic no connection")
                object : SynologyPhotoPreviewEvents {
                    var id = 0L
                    override suspend fun subscribe(unitId: Long) { calls += "subscribe"; id = unitId; if (subscriptionFailure) throw IOException("synthetic no subscription") }
                    override suspend fun completion(): Boolean {
                        calls += "completion"; if (eventFailure) throw IOException("synthetic event unknown")
                        if (nasSuccess) finish(photos.keys.single { it.itemId == id })
                        return nasSuccess
                    }
                    override fun close() { calls += "close" }
                }
            })
        fun finish(id: SynologyPhotoId) {
            if (!keepQueue) queue -= id
            if (!noVersionChange) photos[id] = photos.getValue(id).let { it.copy(thumbnail = it.thumbnail?.copy(revision = "new")) }
            if (finishReadsFail) readFailure = true
        }
        fun queueReply(space: SynologyPhotoSpace, ids: Set<SynologyPhotoId> = queue) = obj("list" to JsonArray(ids.filter { it.space == space }.map { id ->
            buildJsonObject { put("unit_id", id.itemId); put("filename", photos.getValue(id).filename); put("type", photos.getValue(id).mediaType) }
        }))
        fun photoJson(photo: SynologyPhoto) = buildJsonObject {
            put("id", photo.id.itemId); put("filename", photo.filename); put("filesize", photo.sizeBytes); put("time", photo.takenAt)
            put("indexed_time", photo.indexedAt); put("folder_id", photo.folderId); put("type", photo.mediaType)
            photo.albumContext?.let { put("owner_user_id", it.ownerUserId) }
            put("additional", buildJsonObject {
                photo.thumbnail?.let { put("thumbnail", buildJsonObject { put("unit_id", it.unitId); put("cache_key", it.revision) }) }
                photo.albumContext?.providerUserId?.let { put("provider_user_id", it) }
            })
        }
        fun save(row: SynologyPhotoAlbumCheckpoint) { validatePhotoAlbumCheckpoint(row); saved += row }
        val writes get() = calls.filter { it in setOf("set_regenerating", "regenerate_preview_by_nas", "restore_from_regenerating", "upload") }
    }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) { val f = Fixture(); try { block(f) } finally { assertTrue(f.cache.deleteRecursively()) } }

    @Test fun `NAS先订阅再标记再生成事件后回读且重复操作只读`() = runBlocking { fixture { f ->
        val photo = f.photo(); val repo = f.repository(); val row = repo.preparePreviews(listOf(photo), false)
        f.beforeWrite = { method ->
            val facts = f.saved.last().previews!!.progress.single()
            assertTrue(if (method == "set_regenerating") MARK_ATTEMPTED in facts else NAS_ATTEMPTED in facts)
        }
        val result = repo.perform(row, previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertEquals(setOf(0), result.completed)
        assertTrue(f.calls.indexOf("subscribe") < f.calls.indexOf("set_regenerating"))
        assertEquals(listOf("set_regenerating", "regenerate_preview_by_nas"), f.writes)
        repo.perform(row, previewCache = f.cache, save = f::save); assertEquals(2, f.writes.size)
        assertTrue(f.cache.list()!!.isEmpty())
    } }
    @Test fun `PNG先本机转换再标记上传原件临时文件全部清理`() = runBlocking { fixture { f ->
        val repo = f.repository(); val row = repo.preparePreviews(listOf(f.photo(name = "Synthetic.PNG")), false)
        f.beforeWrite = { if (it == "upload") assertTrue(LOCAL_ATTEMPTED in f.saved.last().previews!!.progress.single()) }
        val result = repo.perform(row, previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
        assertTrue(f.calls.indexOf("convert") < f.calls.indexOf("set_regenerating"))
        assertEquals(listOf("set_regenerating", "upload"), f.writes); assertFalse(f.calls.contains("subscribe")); assertTrue(f.cache.list()!!.isEmpty())
    } }
    @Test fun `本机上传明确拒绝后NAS成功不重复标记`() = runBlocking { fixture { f ->
        f.uploadSuccess = false; val repo = f.repository(); val row = repo.preparePreviews(listOf(f.photo(name = "Synthetic.png")), false)
        val result = repo.perform(row, previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
        assertEquals(listOf("set_regenerating", "upload", "regenerate_preview_by_nas"), f.writes)
        assertTrue(LOCAL_REJECTED in result.previews!!.progress.single())
    } }
    @Test fun `NAS明确失败后本机上传成功不会误还原`() = runBlocking { fixture { f ->
        f.nasSuccess = false; val repo = f.repository(); val row = repo.preparePreviews(listOf(f.photo()), false)
        val result = repo.perform(row, previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
        assertEquals(listOf("set_regenerating", "regenerate_preview_by_nas", "upload"), f.writes)
        assertTrue(NAS_FAILED in result.previews!!.progress.single())
    } }
    @Test fun `所有转换明确失败后还原并读取队列缺席只记失败`() = runBlocking { fixture { f ->
        f.nasSuccess = false; f.uploadSuccess = false
        val repo = f.repository(); val row = repo.preparePreviews(listOf(f.photo()), false)
        val result = repo.perform(row, previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(result.completed.isEmpty())
        assertTrue(result.previews!!.progress.single().facts.containsAll(setOf(RESTORE_ATTEMPTED, RESTORED, FAILED)))
        assertEquals("restore_from_regenerating", f.writes.last())
    } }
    @Test fun `事件工厂或订阅未建立时可以独立本机转换`() = runBlocking {
        for (factory in listOf(false, true)) fixture { f ->
            f.factoryFailure = factory; f.subscriptionFailure = !factory
            val repo = f.repository(); val result = repo.perform(repo.preparePreviews(listOf(f.photo()), false), previewCache = f.cache, save = f::save)
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertEquals(listOf("set_regenerating", "upload"), f.writes)
        }
    }
    @Test fun `NAS事件未知不本机补发不还原且冷恢复只读`() = runBlocking { fixture { f ->
        f.eventFailure = true; val repo = f.repository(); val row = repo.preparePreviews(listOf(f.photo()), false)
        val pending = repo.perform(row, previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase); assertFalse(f.calls.contains("convert"))
        val writes = f.writes.toList(); val restored = f.repository().perform(pending, previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, restored.phase); assertEquals(writes, f.writes)
    } }
    @Test fun `本机上传未知不切NAS也不还原且保留原始事实`() = runBlocking { fixture { f ->
        f.uploadFailure = true; val repo = f.repository(); val row = repo.preparePreviews(listOf(f.photo(name = "Synthetic.png")), false)
        val result = repo.perform(row, previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertEquals(listOf("set_regenerating", "upload"), f.writes)
        assertFalse(f.calls.contains("subscribe")); assertTrue(f.cache.list()!!.isEmpty())
    } }
    @Test fun `标记响应未知有确切队列后终止本次且新队列操作无需重标`() = runBlocking { fixture { f ->
        f.failureMethod = "set_regenerating"; val photo = f.photo(); val repo = f.repository(); val row = repo.preparePreviews(listOf(photo), false)
        val result = repo.perform(row, previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(result.previews!!.progress.single().failed)
        assertEquals(listOf("set_regenerating"), f.writes)
        f.failureMethod = null
        val fresh = f.repository(); val queued = fresh.pendingPreviews(photo.id.space)
        val resumed = fresh.perform(fresh.preparePreviews(queued, true), previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, resumed.phase)
        assertEquals(listOf("set_regenerating", "regenerate_preview_by_nas"), f.writes)
    } }
    @Test fun `标记回执身份不符不能继续生成`() = runBlocking { fixture { f ->
        f.markReplyWrong = true; val repo = f.repository(); val row = repo.preparePreviews(listOf(f.photo()), false)
        val result = repo.perform(row, previewCache = f.cache, save = f::save)
        assertEquals(listOf("set_regenerating"), f.writes); assertTrue(result.completed.isEmpty())
    } }
    @Test fun `丢失完成通知需同原件同单元新非空版本及两次队列缺席`() = runBlocking { fixture { f ->
        f.eventFailure = true; val photo = f.photo(); val repo = f.repository()
        val pending = repo.perform(repo.preparePreviews(listOf(photo), false), previewCache = f.cache, save = f::save)
        f.queue.clear(); val cold = f.repository(); var result = cold.review(pending, f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
        f.photos[photo.id] = photo.copy(thumbnail = SynologyPhotoThumbnail(999, "new"))
        result = cold.review(result, f::save); assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
        f.photos[photo.id] = photo.copy(thumbnail = photo.thumbnail!!.copy(revision = "new"))
        val count = f.queueReads; result = cold.review(result, f::save)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertEquals(2, f.queueReads - count)
        assertTrue(RECOVERED in result.previews!!.progress.single()); assertEquals(2, f.writes.size)
    } }
    @Test fun `版本变了但第二次队列重现仍保留未知`() = runBlocking { fixture { f ->
        f.eventFailure = true; val photo = f.photo(); val repo = f.repository()
        val pending = repo.perform(repo.preparePreviews(listOf(photo), false), previewCache = f.cache, save = f::save)
        f.finish(photo.id); f.queueReads = 0; f.queueHook = { if (f.queueReads == 2) f.queue += photo.id }
        val result = f.repository().review(pending, f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertTrue(result.completed.isEmpty())
    } }
    @Test fun `原件身份变化或读取失败不能认领未知结果`() = runBlocking { fixture { f ->
        f.eventFailure = true; val photo = f.photo(); val repo = f.repository()
        val pending = repo.perform(repo.preparePreviews(listOf(photo), false), previewCache = f.cache, save = f::save)
        f.finish(photo.id); f.photos[photo.id] = f.photos.getValue(photo.id).copy(filename = "Replaced.jpg")
        assertEquals(SynologyPhotoAlbumPhase.PENDING, f.repository().review(pending, f::save).phase)
        f.photos[photo.id] = photo.copy(thumbnail = photo.thumbnail!!.copy(revision = "new")); f.readFailure = true
        assertEquals(SynologyPhotoAlbumPhase.PENDING, f.repository().review(pending, f::save).phase)
    } }
    @Test fun `还原回执未知后队列消失即使版本变化也只能失败`() = runBlocking { fixture { f ->
        f.nasSuccess = false; f.uploadSuccess = false; f.failureMethod = "restore_from_regenerating"
        val photo = f.photo(); val repo = f.repository(); val pending = repo.perform(repo.preparePreviews(listOf(photo), false), previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
        f.finish(photo.id); val result = f.repository().review(pending, f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(result.completed.isEmpty())
        assertTrue(result.previews!!.progress.single().failed)
    } }
    @Test fun `明确生成完成而详情暂时失败保留事实随后只读完成`() = runBlocking { fixture { f ->
        f.finishReadsFail = true; val repo = f.repository(); val pending = repo.perform(repo.preparePreviews(listOf(f.photo()), false), previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase); assertTrue(pending.previews!!.progress.single().generated)
        f.readFailure = false
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, f.repository().review(pending, f::save).phase); assertEquals(2, f.writes.size)
    } }
    @Test fun `本机转换期间原件变化会在任何标记或上传前拒绝`() = runBlocking { fixture { f ->
        val photo = f.photo(name = "Synthetic.png"); f.convertHook = { f.photos[photo.id] = photo.copy(sizeBytes = 99) }
        val repo = f.repository(); val result = repo.perform(repo.preparePreviews(listOf(photo), false), previewCache = f.cache, save = f::save)
        assertTrue(f.writes.isEmpty()); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(f.cache.list()!!.isEmpty())
    } }
    @Test fun `个人目录需管理共享目录可用查看下载权且混合需共享管理`() = runBlocking { fixture { f ->
        f.manage = false; val personal = f.photo(); val shared = f.photo(52, space = SynologyPhotoSpace.SHARED); val repo = f.repository()
        assertTrue(failure { repo.preparePreviews(listOf(personal), false) } is SynologyPhotoFailure)
        repo.preparePreviews(listOf(shared), false)
        f.view = false; assertTrue(failure { repo.preparePreviews(listOf(shared), false) } is SynologyPhotoFailure)
        f.view = true; f.manage = true
        assertTrue(failure { repo.preparePreviews(listOf(personal, shared), false) } is SynologyPhotoFailure)
        f.owner = f.owner.copy(managesShared = true); repo.preparePreviews(listOf(personal, shared), false)
        assertTrue(f.writes.isEmpty())
    } }
    @Test fun `相册贡献者和条件原件管理独立于普通相册下载资格`() = runBlocking { fixture { f ->
        val repo = f.repository(); val own = f.photo(context = SynologyPhotoAlbumContext(71, 41, 41))
        f.manage = false; repo.preparePreviews(listOf(own), false)
        val other = f.photo(context = SynologyPhotoAlbumContext(71, 41, 99))
        f.manage = true; assertTrue(failure { repo.preparePreviews(listOf(other), false) } is SynologyPhotoFailure)
        f.albumType = "condition"; repo.preparePreviews(listOf(other), false)
        f.manage = false; assertTrue(failure { repo.preparePreviews(listOf(other), false) } is SynologyPhotoFailure)
        f.enabledSpaces = emptySet(); assertTrue(failure { repo.preparePreviews(listOf(own), false) } is SynologyPhotoFailure)
        assertTrue(f.writes.isEmpty())
    } }
    @Test fun `准备后身份或缩略图基线变化不能使用旧确认`() = runBlocking { fixture { f ->
        val repo = f.repository(); val photo = f.photo(); val row = repo.preparePreviews(listOf(photo), false)
        f.photos[photo.id] = photo.copy(thumbnail = photo.thumbnail!!.copy(revision = "changed"))
        assertTrue(failure { repo.perform(row, previewCache = f.cache, save = f::save) } is SynologyPhotoFailure)
        assertTrue(f.writes.isEmpty()); assertTrue(f.saved.isEmpty())
    } }
    @Test fun `多项未知会停止后续写入并为未发送项保留失败结果`() = runBlocking { fixture { f ->
        val first = f.photo(); val second = f.photo(52); f.eventFailure = true
        val repo = f.repository(); val result = repo.perform(repo.preparePreviews(listOf(first, second), false), previewCache = f.cache, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertEquals(2, f.writes.size)
        assertFalse(result.previews!!.progress[0].failed); assertTrue(result.previews.progress[1].failed)
    } }
    @Test fun `恢复队列身份不符或缺能力拒绝且不会猜测照片编号`() = runBlocking { fixture { f ->
        val photo = f.photo(); val repo = f.repository()
        assertTrue(failure { repo.preparePreviews(listOf(photo), true) } is SynologyPhotoFailure)
        f.queue += photo.id; f.photos[photo.id] = photo.copy(filename = "Changed.jpg")
        assertTrue(failure { repo.preparePreviews(listOf(photo), true) } is SynologyPhotoFailure)
        f.missing = "RegeneratePreview"; assertTrue(failure { repo.pendingPreviews(photo.id.space) } is SynologyPhotoFailure)
        assertTrue(f.writes.isEmpty())
    } }
    @Test fun `队列结构必须完整唯一且未知结果不能用空基线认领`() = runBlocking {
        for (raw in listOf("{}", "{\"list\":[{\"unit_id\":1,\"filename\":\"Synthetic.jpg\"}]}",
            "{\"list\":[{\"unit_id\":1,\"filename\":\"Synthetic.jpg\",\"type\":\"unknown\"}]}",
            "{\"list\":[{\"unit_id\":1,\"filename\":\"a\",\"type\":\"photo\"},{\"unit_id\":1,\"filename\":\"b\",\"type\":\"photo\"}]}")) {
            assertThrows(SynologyPhotoFailure::class.java) { SynologyPhotoPreviewRegenerationCodec.queue(Json.parseToJsonElement(raw).jsonObject) }
        }
        for (baseline in listOf(null, SynologyPhotoThumbnail(151, ""))) fixture { f ->
            val photo = f.photo().copy(thumbnail = baseline).also { f.photos[it.id] = it }; f.eventFailure = true
            val repo = f.repository(); val pending = repo.perform(repo.preparePreviews(listOf(photo), false), previewCache = f.cache, save = f::save)
            f.queue.clear(); f.photos[photo.id] = photo.copy(thumbnail = SynologyPhotoThumbnail(151, "new"))
            assertEquals(SynologyPhotoAlbumPhase.PENDING, f.repository().review(pending, f::save).phase)
        }
    }
    @Test fun `非法相册提供者不能通过共享管理或条件目录资格绕过`() = runBlocking { fixture { f ->
        f.owner = f.owner.copy(managesShared = true)
        val photo = f.photo(space = SynologyPhotoSpace.SHARED, context = SynologyPhotoAlbumContext(71, 0, -1))
        assertTrue(failure { f.repository().preparePreviews(listOf(photo), false) } is SynologyPhotoFailure)
        assertTrue(f.writes.isEmpty())
    } }

    private suspend fun failure(block: suspend () -> Unit): Throwable {
        try { block() } catch (error: Throwable) { return error }
        throw AssertionError("应失败")
    }
    companion object { private fun obj(vararg values: Pair<String, JsonElement>) = JsonObject(mapOf(*values)) }
}
