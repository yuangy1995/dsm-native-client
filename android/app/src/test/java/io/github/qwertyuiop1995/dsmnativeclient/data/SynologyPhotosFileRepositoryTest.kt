package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosFileRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, JsonElement>, val space: SynologyPhotoSpace?)
    private class Fixture {
        var owner = SynologyPhotosMutationAccess("file-profile", 41, 1, false)
        val folders = mutableMapOf<Pair<SynologyPhotoSpace, Long>, JsonObject>()
        val photos = mutableMapOf<Pair<SynologyPhotoSpace, Long>, JsonObject>()
        val reads = mutableListOf<Call>(); val writes = mutableListOf<Call>(); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        var receipt = obj("""{"id":91,"total":3,"target_folder":{"id":20,"owner_user_id":41}}""")
        var tasks = listOf(obj("""{"id":91,"status":"done","completion":3,"error":0,"skip":0,"overwrite":0}"""))
        var listed = listOf(receipt); var apply = true; var loseReceipt = false; var pendingPhoto = false; var deletion = true
        var duplicate = JsonPrimitive("skip"); var listedPages: ((Int) -> List<JsonObject>)? = null
        var beforeRead: (Call) -> Unit = {}; var afterWrite: () -> Unit = {}
        init { for (space in SynologyPhotoSpace.entries) {
            folders[space to 1] = folder(1, "/", 0)
            folders[space to 9] = folder(9, "/Source", 1)
            folders[space to 10] = folder(10, "/Source/Child", 9)
            folders[space to 20] = folder(20, "/Dest", 1)
            photos[space to 21] = photo()
        } }
        fun repository() = SynologyPhotosAlbumRepository(identity = { owner },
            checkAccess = { expected, _ -> if (expected != owner) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION) },
            capability = { suffix, version, _ -> ApiCapability(suffix, "entry.cgi", version, version) },
            read = { api, _, method, fields, space ->
                val call = Call(api, method, fields, space); reads += call; beforeRead(call)
                when (api to method) {
                    "Setting.User" to "get" -> JsonObject(mapOf("copy_move_default_action" to duplicate))
                    "Browse.Folder" to "get" -> JsonObject(mapOf("folder" to folders.getValue(space!! to fields.getValue("id").jsonPrimitive.long)))
                    "Browse.Item" to "get" -> {
                        assertEquals(setOf("id"), fields.keys)
                        list(photos[space!! to fields.getValue("id").jsonArray.single().jsonPrimitive.long]?.let(::listOf) ?: emptyList())
                    }
                    "Browse.Folder" to "list" -> {
                        val offset = fields.getValue("offset").jsonPrimitive.int
                        list(listedPages?.invoke(offset) ?: folders.filter { it.key.first == space && it.value["parent"] == fields["id"] }
                            .values.sortedBy { it.getValue("id").jsonPrimitive.long }.drop(offset).take(100))
                    }
                    "BackgroundTask.Info" to "list_user_task" -> { assertNull(space); list(listed) }
                    "BackgroundTask.Info" to "get_status" -> {
                        assertNull(space); assertEquals(JsonArray(listOf(JsonPrimitive(91))), fields["id"]); list(tasks)
                    }
                    else -> error("Unexpected synthetic read")
                }
            }, write = { api, version, method, fields, space ->
                assertEquals("BackgroundTask.File", api); assertEquals(1, version)
                assertEquals(SynologyPhotoAlbumPhase.SUBMITTING, saved.last().phase)
                writes += Call(api, method, fields, space)
                if (apply && method != "copy") {
                    fields.getValue("item_id").jsonArray.forEach { raw ->
                        val key = space!! to raw.jsonPrimitive.long
                        if (method == "delete") photos.remove(key) else photos[key] = JsonObject(photos.getValue(key) + ("folder_id" to fields.getValue("target_folder_id")))
                    }
                    fields.getValue("folder_id").jsonArray.forEach { raw ->
                        val key = space!! to raw.jsonPrimitive.long
                        if (method == "delete") folders.remove(key) else folders[key] = folder(key.second, "/Dest/Child", 20)
                    }
                }
                afterWrite(); if (loseReceipt) throw IOException("Synthetic lost receipt")
                JsonObject(mapOf("task_info" to receipt))
            }, details = { error("Original identity must not request full media details") }, photos = { _, _, _, _ -> error("No album pages") },
            photoPending = { pendingPhoto }, deletionEnabled = { deletion })
        fun row(action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.MOVE_ITEMS,
            space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL, targetSpace: SynologyPhotoSpace = space,
            withFolders: Boolean = true): SynologyPhotoAlbumCheckpoint = SynologyPhotoAlbumCheckpoint(
            profileId = owner.profileId, userId = owner.userId, action = action,
            targets = listOf(SynologyPhotoEditTarget(SynologyPhotosCodec.photo(photo(), owner.profileId, space))),
            files = SynologyPhotoFileCheckpoint(space,
                folders = if (withFolders) listOf(SynologyPhotoFolderSnapshot(10, 9, "Child", "/Source/Child", space)) else emptyList(),
                destination = SynologyPhotoFolderSnapshot(20, 1, "Dest", "/Dest", targetSpace).takeUnless { action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS },
                duplicate = SynologyPhotoTransferDuplicate.SKIP.takeUnless { action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS }))
        fun save(row: SynologyPhotoAlbumCheckpoint) { validatePhotoAlbumCheckpoint(row); saved += row }
        fun doneCount(count: Long) { tasks = listOf(JsonObject(tasks.single() + ("completion" to JsonPrimitive(count)))) }
    }

    @Test fun `混选移动固定源路由字符串额外信息并在读状态前保存任务编号`() = runBlocking {
        val f = Fixture(); val repo = f.repository()
        f.beforeRead = { if (it.api == "BackgroundTask.Info") assertEquals(91L, f.saved.last().files!!.taskId) }
        val done = repo.perform(f.row(), save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertEquals(3L, done.files!!.total); assertTrue(done.files.targetVerified)
        val call = f.writes.single(); assertEquals(SynologyPhotoSpace.PERSONAL, call.space)
        assertEquals(setOf("target_folder_id", "item_id", "folder_id", "action", "extra_info"), call.fields.keys)
        assertEquals(obj("""{"version":2,"source_library":"personal_space","source_folder_ids":[9]}"""),
            Json.parseToJsonElement(call.fields.getValue("extra_info").jsonPrimitive.content))
        assertTrue(call.fields.getValue("extra_info").jsonPrimitive.isString)
        repo.perform(f.row().copy(operationId = done.operationId), save = f::save)
        assertEquals(1, f.writes.size)
    }
    @Test fun `共享复制只需下载权目标个人上传权不能当成新建管理权`() = runBlocking {
        val f = Fixture(); f.folders[SynologyPhotoSpace.SHARED to 9] = folder(9, "/Source", 1, manage = false, download = true)
        f.folders[SynologyPhotoSpace.SHARED to 10] = folder(10, "/Source/Child", 9, manage = false, download = true)
        f.folders[SynologyPhotoSpace.PERSONAL to 20] = folder(20, "/Dest", 1, manage = false, upload = true)
        val repo = f.repository(); val done = repo.perform(f.row(SynologyPhotoAlbumAction.COPY_ITEMS, SynologyPhotoSpace.SHARED, SynologyPhotoSpace.PERSONAL), save = f::save)
        assertTrue(done.finished); assertEquals(SynologyPhotoSpace.SHARED, f.writes.single().space)
        assertFalse(f.writes.single().fields.containsKey("extra_info"))
        val access = repo.folderAccess(SynologyPhotoSpace.PERSONAL, 20)
        assertTrue(access.canUpload); assertFalse(access.canCreate); assertFalse(access.canManage)
    }
    @Test fun `跨空间允许编号路径重叠但拒绝共享移动到个人`() = runBlocking {
        val f = Fixture(); val row = f.row(targetSpace = SynologyPhotoSpace.SHARED).let { it.copy(files = it.files!!.copy(destination = it.files.folders.single().copy(space = SynologyPhotoSpace.SHARED))) }
        f.receipt = obj("""{"id":91,"total":3,"target_folder":{"id":10,"owner_user_id":0}}""")
        assertTrue(f.repository().perform(row, save = f::save).finished)
        assertEquals(SynologyPhotoSpace.PERSONAL, f.writes.single().space)
        val denied = Fixture(); reject { denied.repository().perform(denied.row(space = SynologyPhotoSpace.SHARED, targetSpace = SynologyPhotoSpace.PERSONAL), save = denied::save) }
        assertTrue(denied.writes.isEmpty())
    }
    @Test fun `个人其他原件拥有者即使本人贡献亦不能移动复制`() = runBlocking {
        for (action in listOf(SynologyPhotoAlbumAction.MOVE_ITEMS, SynologyPhotoAlbumAction.COPY_ITEMS)) {
            val f = Fixture(); val row = f.row(action, withFolders = false).let { it.copy(targets = it.targets.map { photo -> photo.copy(albumContext = SynologyPhotoAlbumContext(71, 42, 41)) }) }
            reject { f.repository().perform(row, save = f::save) }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `纯照片使用固定计数本人相册按原件身份核对无目录来源字段`() = runBlocking {
        val f = Fixture(); f.receipt = obj("""{"id":91}"""); f.doneCount(1)
        val row = f.row(withFolders = false).let { it.copy(targets = it.targets.map { photo -> photo.copy(albumContext = SynologyPhotoAlbumContext(71, 41, 42)) }) }
        val done = f.repository().perform(row, save = f::save)
        assertTrue(done.finished); assertEquals(1L, done.files!!.total)
        val info = Json.parseToJsonElement(f.writes.single().fields.getValue("extra_info").jsonPrimitive.content).jsonObject
        assertFalse(info.containsKey("source_folder_ids"))
    }
    @Test fun `原位置自身后代根目录重复跨父及混合相册上下文全部拒绝`() = runBlocking {
        val f = Fixture(); val base = f.row()
        val invalid = listOf(
            base.copy(files = base.files!!.copy(destination = SynologyPhotoFolderSnapshot(9, 1, "Source", "/Source", base.files.space))),
            base.copy(files = base.files.copy(destination = base.files.folders.single())),
            base.copy(files = base.files.copy(destination = SynologyPhotoFolderSnapshot(11, 10, "Descendant", "/Source/Child/Descendant", base.files.space))),
            base.copy(files = base.files.copy(folders = listOf(SynologyPhotoFolderSnapshot(1, 0, "/", "/", base.files.space)))),
            base.copy(files = base.files.copy(folders = base.files.folders + base.files.folders)),
            base.copy(files = base.files.copy(folders = base.files.folders + base.files.folders.single().copy(id = 11, parentId = 20, path = "/Dest/Child"))),
            base.copy(targets = base.targets.map { it.copy(albumContext = SynologyPhotoAlbumContext(71, 41)) }),
        )
        invalid.forEach { row -> reject { f.repository().perform(row, save = f::save) } }
        assertTrue(f.writes.isEmpty())
        assertTrue(SynologyPhotoFileValidation.accepts(base, SynologyPhotoFolderSnapshot(11, 9, "Child-other", "/Source/Child-other", base.files.space)))
    }
    @Test fun `写前对象路径照片身份源权限目标权限或代次改变都零写入`() = runBlocking {
        for (case in 0..6) {
            val f = Fixture(); val row = f.row()
            when (case) {
                0 -> f.folders[SynologyPhotoSpace.PERSONAL to 10] = folder(10, "/Source/Renamed", 9)
                1 -> f.photos[SynologyPhotoSpace.PERSONAL to 21] = JsonObject(photo() + ("time" to JsonPrimitive(999)))
                2 -> f.folders[SynologyPhotoSpace.PERSONAL to 10] = folder(10, "/Source/Child", 9, manage = false)
                3 -> f.folders[SynologyPhotoSpace.PERSONAL to 20] = folder(20, "/Dest", 1, view = false)
                4 -> f.beforeRead = { f.owner = f.owner.copy(generation = 2) }
                5 -> f.pendingPhoto = true
                6 -> f.folders[SynologyPhotoSpace.PERSONAL to 9] = folder(9, "/Source", 1, manage = false, upload = true)
            }
            reject { f.repository().perform(row, save = f::save) }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `回执丢失不凭目录结果或用户任务列表认领冷热恢复始终不重发`() = runBlocking {
        val f = Fixture(); f.loseReceipt = true; val repo = f.repository()
        val pending = repo.perform(f.row(), save = f::save)
        assertFalse(pending.finished); assertNull(pending.files!!.taskId)
        repo.perform(pending, save = f::save)
        f.repository().review(Json.decodeFromString(Json.encodeToString(pending)), f::save)
        assertEquals(1, f.writes.size); assertTrue(f.reads.none { it.api == "BackgroundTask.Info" })
    }
    @Test fun `回执元数据损坏仍保存编号只按唯一同编号任务恢复`() = runBlocking {
        val f = Fixture(); val good = f.receipt; f.receipt = obj("""{"id":91,"total":"invalid","target_folder":{"id":20,"owner_user_id":41}}""")
        f.listed = emptyList(); val row = f.repository().perform(f.row(), save = f::save)
        assertFalse(row.finished); assertEquals(91L, row.files!!.taskId); assertFalse(row.files.targetVerified)
        f.listed = listOf(good, good)
        assertFalse(f.repository().review(row, f::save).finished)
        f.listed = listOf(good)
        assertTrue(f.repository().review(Json.decodeFromString(Json.encodeToString(row)), f::save).finished)
        assertEquals(1, f.writes.size)
    }
    @Test fun `跨空间回执目标编号拥有者及总数任一错误不能确认`() = runBlocking {
        for (task in listOf("""{"id":91,"total":3,"target_folder":{"id":99,"owner_user_id":0}}""",
            """{"id":91,"total":3,"target_folder":{"id":20,"owner_user_id":41}}""",
            """{"id":91,"total":0,"target_folder":{"id":20,"owner_user_id":0}}""")) {
            val f = Fixture(); f.receipt = obj(task); f.listed = listOf(f.receipt)
            val pending = f.repository().perform(f.row(targetSpace = SynologyPhotoSpace.SHARED), save = f::save)
            assertFalse(pending.finished); assertFalse(pending.files!!.targetVerified)
        }
    }
    @Test fun `状态编号不唯一非法计数及跳过策略报告覆盖全部不能完成`() = runBlocking {
        for (case in 0..7) {
            val f = Fixture(); val status = f.tasks.single()
            f.tasks = when (case) {
                0 -> emptyList(); 1 -> listOf(status, status)
                2 -> listOf(JsonObject(status + ("id" to JsonPrimitive(92))))
                3 -> listOf(JsonObject(status + ("completion" to JsonPrimitive(-1))))
                4 -> listOf(JsonObject(status + ("error" to JsonPrimitive(4))))
                5 -> listOf(JsonObject(status + ("skip" to JsonPrimitive(4))))
                6 -> listOf(JsonObject(status + ("overwrite" to JsonPrimitive(1))))
                else -> listOf(JsonObject(status + ("completion" to JsonPrimitive(4))))
            }
            val pending = f.repository().perform(f.row(), save = f::save)
            assertFalse(pending.finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `替换策略固定写参数允许合法覆盖计数部分结果不猜逐项目成功`() = runBlocking {
        for (partial in listOf(false, true)) {
            val f = Fixture(); f.tasks = listOf(obj(if (partial) """{"id":91,"status":"done","completion":2,"error":1,"skip":0,"overwrite":1}""" else
                """{"id":91,"status":"done","completion":3,"error":0,"skip":0,"overwrite":1}"""))
            val row = f.row().let { it.copy(files = it.files!!.copy(duplicate = SynologyPhotoTransferDuplicate.OVERWRITE)) }
            val result = f.repository().perform(row, save = f::save)
            assertEquals(if (partial) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.COMPLETED, result.phase)
            assertTrue(result.completed.isEmpty()); assertEquals(JsonPrimitive("overwrite"), f.writes.single().fields["action"])
        }
    }
    @Test fun `移动任务完成但照片或目录尚在原位置保留未知后续只读恢复`() = runBlocking {
        for (case in 0..1) {
            val f = Fixture(); f.afterWrite = {
                if (case == 0) f.photos[SynologyPhotoSpace.PERSONAL to 21] = photo()
                else f.folders[SynologyPhotoSpace.PERSONAL to 10] = folder(10, "/Source/Child", 9)
            }
            val row = f.repository().perform(f.row(), save = f::save); assertFalse(row.finished)
            f.photos[SynologyPhotoSpace.PERSONAL to 21] = JsonObject(photo() + ("folder_id" to JsonPrimitive(20)))
            f.folders[SynologyPhotoSpace.PERSONAL to 10] = folder(10, "/Dest/Child", 20)
            assertTrue(f.repository().review(row, f::save).finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `目标权限撤回或读取代次变化不能把完成任务当成功`() = runBlocking {
        for (case in 0..1) {
            val f = Fixture()
            if (case == 0) f.afterWrite = { f.folders[SynologyPhotoSpace.PERSONAL to 20] = folder(20, "/Dest", 1, manage = false) }
            else f.beforeRead = { if (it.api == "BackgroundTask.Info") f.owner = f.owner.copy(generation = 2) }
            assertFalse(f.repository().perform(f.row(), save = f::save).finished)
        }
    }
    @Test fun `混合删除仅发送两种编号等待同任务并完整翻页确认不存在`() = runBlocking {
        val f = Fixture(); f.receipt = obj("""{"id":91}""")
        for (id in 100L..200L) f.folders[SynologyPhotoSpace.PERSONAL to id] = folder(id, "/Source/Extra$id", 9)
        val done = f.repository().perform(f.row(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS), save = f::save)
        assertTrue(done.finished); assertEquals(setOf("item_id", "folder_id"), f.writes.single().fields.keys)
        assertEquals(listOf(JsonPrimitive(0), JsonPrimitive(100)), f.reads.filter { it.api == "Browse.Folder" && it.method == "list" }.map { it.fields["offset"] })
        assertFalse(f.folders.containsKey(SynologyPhotoSpace.PERSONAL to 10))
    }
    @Test fun `删除默认关闭且不接受纯照片批次`() = runBlocking {
        val f = Fixture(); f.deletion = false
        reject { f.repository().perform(f.row(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS), save = f::save) }
        f.deletion = true
        reject { f.repository().perform(f.row(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS, withFolders = false), save = f::save) }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `删除部分失败不猜哪些目录消失并保留明确任务统计`() = runBlocking {
        val f = Fixture(); f.tasks = listOf(obj("""{"id":91,"status":"done","completion":2,"error":1,"skip":0,"overwrite":0}"""))
        val row = f.repository().perform(f.row(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS), save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertTrue(row.completed.isEmpty())
        assertTrue(f.reads.none { it.api == "Browse.Folder" && it.method == "list" })
    }
    @Test fun `删除重复分页错误父级及权限失败不会变成成功`() = runBlocking {
        for (case in 0..2) {
            val f = Fixture()
            when (case) {
                0 -> f.listedPages = { (100L..199L).map { folder(it, "/Source/Extra$it", 9) } }
                1 -> f.listedPages = { listOf(folder(100, "/Other/Child", 20)) }
                2 -> f.afterWrite = { f.folders[SynologyPhotoSpace.PERSONAL to 9] = folder(9, "/Source", 1, view = false) }
            }
            assertFalse(f.repository().perform(f.row(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS), save = f::save).finished)
        }
    }
    @Test fun `删除任务完成但存在任一原件仍未知且共享删除走来源命名空间`() = runBlocking {
        val f = Fixture(); f.apply = false
        val pending = f.repository().perform(f.row(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS, SynologyPhotoSpace.SHARED), save = f::save)
        assertFalse(pending.finished); assertEquals(SynologyPhotoSpace.SHARED, f.writes.single().space)
        f.folders.remove(SynologyPhotoSpace.SHARED to 10)
        assertFalse(f.repository().review(pending, f::save).finished)
        f.photos.remove(SynologyPhotoSpace.SHARED to 21)
        assertTrue(f.repository().review(pending, f::save).finished); assertEquals(1, f.writes.size)
    }
    @Test fun `读取实际重复规则严格拒绝缺失未知和非字符串`() = runBlocking {
        for (duplicate in SynologyPhotoTransferDuplicate.entries) {
            val f = Fixture(); f.duplicate = JsonPrimitive(duplicate.value)
            assertEquals(duplicate, f.repository().transferDuplicate())
        }
        for (value in listOf(JsonPrimitive("future"), JsonPrimitive(true), JsonNull)) {
            val f = Fixture(); f.duplicate = value
            reject { f.repository().transferDuplicate() }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `提交记录保存失败零写入且操作编号固定不能换意图`() = runBlocking {
        val f = Fixture(); val row = f.row(); val repo = f.repository()
        try { repo.perform(row) { throw IOException("Synthetic disk") }; fail() } catch (_: IOException) { }
        assertTrue(f.writes.isEmpty()); assertFalse(repo.perform(row, save = f::save).finished)
        reject { repo.perform(row.copy(action = SynologyPhotoAlbumAction.COPY_ITEMS), save = f::save) }
    }

    companion object {
        private fun obj(text: String) = Json.parseToJsonElement(text).jsonObject
        private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
        private fun folder(id: Long, path: String, parent: Long, view: Boolean = true, manage: Boolean = true,
            upload: Boolean = false, download: Boolean = false) = obj("""{"id":$id,"name":"$path","parent":$parent,"additional":{"access_permission":{"view":$view,"manage":$manage,"upload":$upload,"download":$download}}}""")
        private fun photo() = obj("""{"id":21,"filename":"Synthetic.jpg","filesize":4,"time":20,"indexed_time":30,"folder_id":9,"type":"photo"}""")
        private suspend fun reject(block: suspend () -> Any?) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) { } }
    }
}
