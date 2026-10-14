package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosFolderRepositoryTest {
    private data class Call(val method: String, val version: Int, val fields: Map<String, JsonElement>, val space: SynologyPhotoSpace?)
    private class Fixture {
        var owner = SynologyPhotosMutationAccess("folder-profile", 41, 1, false)
        val folders = mutableMapOf(1L to folder(1, "/", 0), 9L to folder(9, "/Synthetic", 1), 10L to folder(10, "/Synthetic/Child", 9))
        val writes = mutableListOf<Call>(); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        var apply = true; var loseReceipt = false; var missingId = false; var pendingPhoto = false; var readableImage = true; var images = 0
        var currentPhoto = photo(); var defaults = SynologyPhotoSort()
        var beforeRead: () -> Unit = {}; var afterWrite: () -> Unit = {}
        fun repository() = SynologyPhotosAlbumRepository(identity = { owner },
            checkAccess = { expected, _ -> if (expected != owner) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION) },
            capability = { suffix, version, _ -> ApiCapability(suffix, "entry.cgi", version, version) },
            read = { api, version, method, fields, _ ->
                assertEquals("Browse.Folder", api); assertEquals(2, version); assertEquals("get", method); beforeRead()
                JsonObject(mapOf("folder" to folders.getValue(fields.getValue("id").jsonPrimitive.long)))
            }, write = { api, version, method, fields, space ->
                assertEquals("Browse.Folder", api); assertEquals(SynologyPhotoAlbumPhase.SUBMITTING, saved.last().phase)
                writes += Call(method, version, fields, space)
                val id = fields["id"]?.jsonPrimitive?.long ?: 9
                val raw = folders.getValue(id)
                if (apply) when (method) {
                    "create" -> {
                        val parent = fields.getValue("target_id").jsonPrimitive.long
                        folders[11] = folder(11, SynologyPhotoFolderCodec.childPath(folders.getValue(parent).getValue("name").jsonPrimitive.content,
                            fields.getValue("name").jsonPrimitive.content), parent)
                    }
                    "rename" -> folders[id] = JsonObject(raw + ("name" to JsonPrimitive(raw.getValue("name").jsonPrimitive.content.substringBeforeLast('/') + "/" + fields.getValue("name").jsonPrimitive.content)))
                    "set_order" -> folders[id] = JsonObject(raw + fields.filterKeys { it in setOf("sort_by", "sort_direction") })
                    "set_cover" -> folders[id] = JsonObject(raw + ("additional" to JsonObject(raw.getValue("additional").jsonObject +
                        ("thumbnail" to Json.parseToJsonElement("""[{"folder_cover_seq":0,"cache_key":"new"}]""")))))
                    else -> error("Unexpected synthetic write")
                }
                afterWrite()
                if (loseReceipt) throw IOException("Synthetic lost receipt")
                if (method == "create" && !missingId) obj("""{"folder":{"id":11}}""") else obj("{}")
            }, details = { currentPhoto }, photos = { _, _, _, _ -> error("No album membership reads") },
            photoPending = { pendingPhoto }, defaultFolderSort = { defaults }, verifyFolderCover = { folder, cover ->
                assertEquals(9L, folder.id); assertEquals(0L, cover.sequence); images++
                if (!readableImage) throw IOException("Synthetic undecodable cover")
            })
        fun row(action: SynologyPhotoAlbumAction, space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL): SynologyPhotoAlbumCheckpoint {
            val target = SynologyPhotoFolderSnapshot(9, 1, "Synthetic", "/Synthetic", space)
            return SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = owner.userId, action = action,
                folder = SynologyPhotoFolderCheckpoint(target,
                    name = "New".takeIf { action in setOf(SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoAlbumAction.RENAME_FOLDER) },
                    sort = SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME, SynologyPhotoSort.Direction.DESCENDING).takeIf { action == SynologyPhotoAlbumAction.SORT_FOLDER },
                    coverPhoto = SynologyPhotoEditTarget(currentPhoto).takeIf { action == SynologyPhotoAlbumAction.COVER_FOLDER }))
        }
        fun save(row: SynologyPhotoAlbumCheckpoint) { saved += row; validatePhotoAlbumCheckpoint(row) }
    }

    @Test fun `新建先保存意图只认回执编号同父完整路径与共享上传资格`() = runBlocking {
        val f = Fixture(); f.folders[9] = folder(9, "/Synthetic", 1, manage = false, upload = true)
        val repo = f.repository()
        reject { repo.prepare(f.row(SynologyPhotoAlbumAction.CREATE_FOLDER)) }
        val done = repo.perform(f.row(SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoSpace.SHARED), save = f::save)
        assertTrue(done.finished); assertEquals(11L, done.folder!!.createdFolderId)
        assertEquals(SynologyPhotoSpace.SHARED, f.writes.single().space); assertEquals(1, f.writes.single().version)
        assertEquals(mapOf("target_id" to JsonPrimitive(9), "name" to JsonPrimitive("New")), f.writes.single().fields)
        assertTrue(f.saved.any { it.folder?.createdFolderId == 11L && it.phase == SynologyPhotoAlbumPhase.PENDING })
    }
    @Test fun `丢失或缺少创建编号即使同名存在也不认领冷热恢复不重发`() = runBlocking {
        for (lost in listOf(false, true)) {
            val f = Fixture(); f.loseReceipt = lost; f.missingId = !lost; val repo = f.repository()
            val row = repo.perform(f.row(SynologyPhotoAlbumAction.CREATE_FOLDER), save = f::save)
            assertFalse(row.finished); assertNull(row.folder!!.createdFolderId); assertNotNull(f.folders[11])
            repo.perform(row, save = f::save); f.repository().review(Json.decodeFromString(Json.encodeToString(row)), f::save)
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `创建回读不接受其他父级完整路径或被撤销的权限`() = runBlocking {
        for (case in 0..2) {
            val f = Fixture(); f.afterWrite = { f.folders[11] = when (case) {
                0 -> folder(11, "/Synthetic/New", 10)
                1 -> folder(11, "/Elsewhere/New", 9)
                else -> folder(11, "/Synthetic/New", 9, manage = false)
            } }
            val row = f.repository().perform(f.row(SynologyPhotoAlbumAction.CREATE_FOLDER), save = f::save)
            assertFalse(row.finished); assertEquals(11L, row.folder!!.createdFolderId)
        }
    }
    @Test fun `重命名丢失回执仍按同编号父级完整新路径完成但不重发`() = runBlocking {
        val f = Fixture(); f.loseReceipt = true; val repo = f.repository()
        val row = repo.perform(f.row(SynologyPhotoAlbumAction.RENAME_FOLDER), save = f::save)
        assertTrue(row.finished); assertEquals("/New", f.folders.getValue(9)["name"]!!.jsonPrimitive.content)
        f.repository().review(row, f::save); assertEquals(1, f.writes.size)
        assertEquals(mapOf("id" to JsonPrimitive(9), "name" to JsonPrimitive("New")), f.writes.single().fields)
    }
    @Test fun `重命名前原路径父级或权限改变拒绝写后不同父级保留未知`() = runBlocking {
        for (case in 0..2) {
            val f = Fixture(); val row = f.row(SynologyPhotoAlbumAction.RENAME_FOLDER)
            f.folders[9] = when (case) { 0 -> folder(9, "/Changed", 1); 1 -> folder(9, "/Synthetic", 2); else -> folder(9, "/Synthetic", 1, manage = false) }
            reject { f.repository().perform(row, save = f::save) }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); f.afterWrite = { f.folders[9] = folder(9, "/New", 2) }
        assertFalse(f.repository().perform(f.row(SynologyPhotoAlbumAction.RENAME_FOLDER), save = f::save).finished)
    }
    @Test fun `根目录名称禁止项和UTF16长度在发出请求前拒绝`() = runBlocking {
        val f = Fixture(); val row = f.row(SynologyPhotoAlbumAction.RENAME_FOLDER)
        for (name in listOf("", "  ", ".hidden", "end.", "@database", "@eaDir", "@tmp", "@sharebin", "#recycle", "#snapshot", "a/b", "a\\b", "a:b", "a\u0000b", "😀".repeat(128))) {
            reject { f.repository().perform(row.copy(folder = row.folder!!.copy(name = name)), save = f::save) }
        }
        assertTrue(SynologyPhotoFolderCodec.validName("😀".repeat(127) + "a"))
        for (action in listOf(SynologyPhotoAlbumAction.RENAME_FOLDER, SynologyPhotoAlbumAction.COVER_FOLDER)) {
            val root = f.row(action).let { it.copy(folder = it.folder!!.copy(target = SynologyPhotoFolderSnapshot(1, 0, "/", "/", SynologyPhotoSpace.PERSONAL))) }
            reject { f.repository().perform(root, save = f::save) }
        }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `排序只要求查看且每个读取字段独立回退但确认不使用默认值`() = runBlocking {
        val f = Fixture(); f.defaults = SynologyPhotoSort(SynologyPhotoSort.Field.FILESIZE, SynologyPhotoSort.Direction.DESCENDING)
        f.folders[9] = JsonObject(folder(9, "/Synthetic", 1, manage = false) + mapOf("sort_by" to JsonPrimitive("filename"), "sort_direction" to JsonPrimitive("future")))
        val repo = f.repository(); val value = repo.folderAccess(SynologyPhotoSpace.PERSONAL, 9)
        assertEquals(SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME, SynologyPhotoSort.Direction.DESCENDING), value.sort); assertNull(value.explicitSort)
        f.apply = false
        val row = repo.perform(f.row(SynologyPhotoAlbumAction.SORT_FOLDER), save = f::save)
        assertFalse(row.finished)
        f.folders[9] = JsonObject(f.folders.getValue(9) + ("sort_direction" to JsonPrimitive("desc")))
        assertTrue(repo.review(row, f::save).finished); assertEquals(1, f.writes.size)
    }
    @Test fun `排序四字段双方向和根目录可用且不要求管理下载`() = runBlocking {
        for (field in SynologyPhotoSort.Field.entries) for (direction in SynologyPhotoSort.Direction.entries) {
            val f = Fixture(); f.folders[1] = folder(1, "/", 0, manage = false)
            val row = f.row(SynologyPhotoAlbumAction.SORT_FOLDER).let { it.copy(folder = it.folder!!.copy(
                target = SynologyPhotoFolderSnapshot(1, 0, "/", "/", SynologyPhotoSpace.PERSONAL), sort = SynologyPhotoSort(field, direction))) }
            assertTrue(f.repository().perform(row, save = f::save).finished)
            assertEquals(JsonPrimitive(field.value), f.writes.single().fields["sort_by"])
            assertEquals(JsonPrimitive(direction.value), f.writes.single().fields["sort_direction"])
        }
    }
    @Test fun `封面固定目标允许可查看不可下载子目录并使用单元素数组`() = runBlocking {
        val f = Fixture(); f.folders[10] = folder(10, "/Synthetic/Child", 9, manage = false)
        val row = f.repository().perform(f.row(SynologyPhotoAlbumAction.COVER_FOLDER), save = f::save)
        assertTrue(row.finished); assertTrue(row.folder!!.coverAcknowledged); assertEquals(1, f.images)
        assertEquals(mapOf("id" to JsonPrimitive(9), "id_item" to JsonArray(listOf(JsonPrimitive(21)))), f.writes.single().fields)
        assertEquals(2, f.writes.single().version)
    }
    @Test fun `封面丢失回执即使自定义图已变化冷热恢复也不能完成或重发`() = runBlocking {
        val f = Fixture(); f.loseReceipt = true; val repo = f.repository()
        val row = repo.perform(f.row(SynologyPhotoAlbumAction.COVER_FOLDER), save = f::save)
        assertFalse(row.finished); assertFalse(row.folder!!.coverAcknowledged)
        assertFalse(repo.perform(row, save = f::save).finished)
        assertFalse(f.repository().review(Json.decodeFromString(Json.encodeToString(row)), f::save).finished)
        assertEquals(0, f.images); assertEquals(1, f.writes.size)
    }
    @Test fun `封面缺序号零或无法解码时保留未知后续只读取恢复`() = runBlocking {
        for (case in 0..1) {
            val f = Fixture(); val repo = f.repository()
            if (case == 0) f.apply = false else f.readableImage = false
            val row = repo.perform(f.row(SynologyPhotoAlbumAction.COVER_FOLDER), save = f::save)
            assertFalse(row.finished); assertTrue(row.folder!!.coverAcknowledged)
            f.readableImage = true
            f.folders[9] = JsonObject(f.folders.getValue(9) + ("additional" to obj("""{"access_permission":{"view":true,"manage":true},"thumbnail":[{"folder_cover_seq":0,"cache_key":"new"}]}""")))
            assertTrue(repo.review(row, f::save).finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `封面兄弟前缀另一来源相册来源删除中和改变照片身份全部拒绝`() = runBlocking {
        for (case in 0..5) {
            val f = Fixture(); var row = f.row(SynologyPhotoAlbumAction.COVER_FOLDER)
            when (case) {
                0 -> f.folders[10] = folder(10, "/Synthetic-other", 1)
                1 -> row = row.copy(folder = row.folder!!.copy(coverPhoto = row.folder.coverPhoto!!.copy(id = row.folder.coverPhoto.id.copy(space = SynologyPhotoSpace.SHARED))))
                2 -> row = row.copy(folder = row.folder!!.copy(coverPhoto = row.folder.coverPhoto!!.copy(albumContext = SynologyPhotoAlbumContext(71, 41))))
                3 -> f.pendingPhoto = true
                4 -> f.currentPhoto = f.currentPhoto.copy(sizeBytes = 99)
                5 -> f.folders[10] = folder(10, "/Synthetic/Child", 9, view = false)
            }
            reject { f.repository().perform(row, save = f::save) }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `共享管理者可管理但账号代次改变在写前拒绝`() = runBlocking {
        val f = Fixture(); f.folders[9] = folder(9, "/Synthetic", 1, view = false, manage = false)
        f.owner = f.owner.copy(managesShared = true)
        assertTrue(f.repository().perform(f.row(SynologyPhotoAlbumAction.RENAME_FOLDER, SynologyPhotoSpace.SHARED), save = f::save).finished)
        val changed = Fixture(); changed.beforeRead = { changed.owner = changed.owner.copy(generation = 2) }
        reject { changed.repository().perform(changed.row(SynologyPhotoAlbumAction.RENAME_FOLDER), save = changed::save) }
        assertTrue(changed.writes.isEmpty())
    }
    @Test fun `提交阶段保存失败不发写入也不通过重复调用重新执行`() = runBlocking {
        val f = Fixture(); val repo = f.repository(); val row = f.row(SynologyPhotoAlbumAction.CREATE_FOLDER)
        try { repo.perform(row) { throw IOException("Synthetic disk") }; fail() } catch (_: IOException) { }
        assertTrue(f.writes.isEmpty()); assertFalse(repo.perform(row, save = f::save).finished); assertTrue(f.writes.isEmpty())
    }
    @Test fun `恢复拒绝混入其他动作字段无回执完成及非法路径`() {
        val f = Fixture(); val row = f.row(SynologyPhotoAlbumAction.CREATE_FOLDER)
        for (invalid in listOf(row.copy(createdAlbumId = 71), row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED),
            row.copy(folder = row.folder!!.copy(coverAcknowledged = true)), row.copy(folder = row.folder!!.copy(target = row.folder.target.copy(path = "/../Synthetic"))))) {
            try { validatePhotoAlbumCheckpoint(invalid); fail() } catch (_: SynologyPhotoFailure) { }
        }
    }
    @Test fun `读取封面最多四张序号优先负序号使用照片单元错误封面不阻断目录`() {
        val values = obj("""{"additional":{"thumbnail":[{"cache_key":"a","folder_cover_seq":0,"unit_id":21},{"cache_key":"b","folder_cover_seq":-1,"unit_id":22},{"cache_key":"c","unit_id":23},{"cache_key":"d","folder_cover_seq":3},{"cache_key":"e","folder_cover_seq":4}]}}""")
        val covers = SynologyPhotoFolderCodec.covers(values)
        assertEquals(4, covers.size); assertEquals(0L, covers[0].sequence); assertNull(covers[0].unitId); assertEquals(22L, covers[1].unitId)
        assertTrue(SynologyPhotoFolderCodec.covers(obj("""{"additional":{"thumbnail":{"future":true}}}""")).isEmpty())
    }
    private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("不应接受变更") } catch (_: SynologyPhotoFailure) { } }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun folder(id: Long, path: String, parent: Long, view: Boolean = true, manage: Boolean = true, upload: Boolean = false) =
            obj("""{"id":$id,"name":${JsonPrimitive(path)},"parent":$parent,"additional":{"access_permission":{"view":$view,"manage":$manage,"upload":$upload,"download":false}}}""")
        private fun photo() = SynologyPhoto(SynologyPhotoId("folder-profile", SynologyPhotoSpace.PERSONAL, 21), "Synthetic.jpg", 4, 1.0, 2.0, 10, "photo")
    }
}
