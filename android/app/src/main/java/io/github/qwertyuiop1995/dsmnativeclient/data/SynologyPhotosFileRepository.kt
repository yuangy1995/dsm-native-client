package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalLong
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

/** 文件任务复用管理互斥；取得编号立即持久化，之后任何恢复都只能读取该任务。 */
internal class SynologyPhotosFileRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val folderAccess: suspend (SynologyPhotoSpace, Long) -> SynologyPhotoFolderAccess,
    private val photoPending: (SynologyPhotoId) -> Boolean,
    private val deletionEnabled: () -> Boolean,
) {
    suspend fun duplicate(): SynologyPhotoTransferDuplicate {
        val owner = identity(); checkAccess(owner, null)
        val value = read("Setting.User", 1, "get", emptyMap(), null).text("copy_move_default_action")
        checkAccess(owner, null)
        return SynologyPhotoTransferDuplicate.entries.firstOrNull { it.value == value } ?: invalid()
    }

    private suspend fun folder(target: SynologyPhotoFolderSnapshot, owner: SynologyPhotosMutationAccess): SynologyPhotoFolderAccess {
        checkAccess(owner, target.space)
        val current = folderAccess(target.space, target.id)
        if (current.folder.path != target.path || target.parentId != null && current.folder.parentId != target.parentId) changed()
        checkAccess(owner, target.space)
        return current
    }

    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val files = row.files ?: invalid()
        if (row.action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS && !deletionEnabled()) denied()
        capability("BackgroundTask.File", 1, files.space); capability("BackgroundTask.Info", 1, null)
        capability("Browse.Folder", 2, files.space); capability("Browse.Item", 5, files.space)
        checkAccess(owner, files.space)
        val copiesShared = row.action == SynologyPhotoAlbumAction.COPY_ITEMS && files.space == SynologyPhotoSpace.SHARED
        for (photo in row.targets) {
            if (photoPending(photo.id) || photo.albumContext != null && files.space == SynologyPhotoSpace.PERSONAL && photo.albumContext.ownerUserId != owner.userId) denied()
            val current = original(photo, owner) ?: changed()
            // 原件身份读取不依赖 EXIF、地址或相册贡献者资料。
            if (!photo.copy(albumContext = null).matches(current, includeTime = true)) changed()
            val source = folderAccess(files.space, photo.folderId)
            if (copiesShared) { if (!source.canDownload) denied() } else if (!source.canManage) denied()
            checkAccess(owner, files.space)
        }
        if (files.folders.isNotEmpty()) {
            folder(SynologyPhotoFileValidation.parent(files.folders), owner)
            for (target in files.folders) {
                val current = folder(target, owner)
                if (copiesShared) { if (!current.canDownload) denied() } else if (!current.canManage) denied()
            }
        }
        files.destination?.let {
            if (!SynologyPhotoFileValidation.accepts(row, it) || !folder(it, owner).canUpload) denied()
        }
        checkAccess(owner, files.space)
    }

    suspend fun execute(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        val files = row.files ?: invalid()
        checkAccess(owner, files.space); files.destination?.let { checkAccess(owner, it.space) }
        val fields = json("item_id" to JsonArray(row.targets.map { JsonPrimitive(it.id.itemId) }),
            "folder_id" to JsonArray(files.folders.map { JsonPrimitive(it.id) })).toMutableMap()
        val method = when (row.action) {
            SynologyPhotoAlbumAction.MOVE_ITEMS -> "move"
            SynologyPhotoAlbumAction.COPY_ITEMS -> "copy"
            SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS -> "delete"
            else -> invalid()
        }
        files.destination?.let { fields.putAll(json("target_folder_id" to it.id, "action" to files.duplicate!!.value)) }
        if (row.action == SynologyPhotoAlbumAction.MOVE_ITEMS) {
            val info = json("version" to 2, "source_library" to if (files.space == SynologyPhotoSpace.PERSONAL) "personal_space" else "shared_space").toMutableMap()
            if (files.folders.isNotEmpty()) info["source_folder_ids"] = array(SynologyPhotoFileValidation.parent(files.folders).id)
            fields["extra_info"] = JsonPrimitive(JsonObject(info).toString())
        }
        val receipt = write("BackgroundTask.File", 1, method, fields, files.space).obj("task_info")
        var next = row.copy(phase = SynologyPhotoAlbumPhase.PENDING, files = files.copy(taskId = receipt.positive("id")))
        withContext(NonCancellable) { save(next) }
        // 即使其他回执字段损坏，也保留已经取得的编号，不能重放写入。
        next = if (files.destination == null) {
            val total = receipt.optionalLong("total")?.also { if (it < 0) invalid() }
            next.copy(files = next.files!!.copy(total = total))
        } else if (SynologyPhotoFileValidation.requiresTarget(row)) withTarget(next, receipt, owner)
        else next.copy(files = next.files!!.copy(total = row.targets.size.toLong()))
        withContext(NonCancellable) { save(next) }
        return next
    }

    private fun withTarget(row: SynologyPhotoAlbumCheckpoint, task: JsonObject, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val files = row.files!!; val destination = files.destination ?: invalid()
        val target = task.optionalObject("target_folder") ?: return row
        val total = task.optionalLong("total") ?: return row
        val expectedOwner = if (destination.space == SynologyPhotoSpace.SHARED) 0 else owner.userId
        if (target.positive("id") != destination.id || target.number("owner_user_id") != expectedOwner ||
            (if (files.folders.isEmpty()) total != row.targets.size.toLong() else total < row.targets.size)) return row
        return row.copy(files = files.copy(total = total, targetVerified = true))
    }

    suspend fun review(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        var row = input; var files = row.files ?: invalid()
        checkAccess(owner, files.space); files.destination?.let { checkAccess(owner, it.space) }
        val id = files.taskId ?: return row
        if (files.destination != null && SynologyPhotoFileValidation.requiresTarget(row) && !files.targetVerified) {
            val matching = read("BackgroundTask.Info", 1, "list_user_task", emptyMap(), null).list().filter { it.positive("id") == id }
            if (matching.size != 1) return row
            row = withTarget(row, matching.single(), owner); files = row.files!!
            if (!files.targetVerified) return row
            checkAccess(owner, files.space); checkAccess(owner, files.destination!!.space)
            save(row)
        }
        if (files.destination != null && files.total == null) { row = row.copy(files = files.copy(total = row.targets.size.toLong())); files = row.files!!; save(row) }
        val tasks = read("BackgroundTask.Info", 1, "get_status", json("id" to array(id)), null).list()
        val task = tasks.singleOrNull()?.takeIf { it.positive("id") == id } ?: invalid()
        val result = SynologyPhotoFileResult(task.number("completion"), task.number("error"), task.number("skip"), task.number("overwrite"))
        SynologyPhotoFileValidation.validateResult(result, files.total, files.duplicate)
        if (task.text("status") != "done") return row
        val partial = result.errors > 0 || result.skipped > 0 || files.destination != null && result.completion < files.total!!
        if (files.destination != null && !folder(files.destination, owner).canUpload) denied()
        if (!partial) {
            if (files.destination == null) { if (!deleted(row, owner)) return row }
            else if (row.action == SynologyPhotoAlbumAction.MOVE_ITEMS && files.space == files.destination.space) {
                for (photo in row.targets) {
                    val moved = original(photo, owner) ?: changed()
                    if (moved.id != photo.id || moved.folderId != files.destination.id || moved.filename != photo.filename || moved.sizeBytes != photo.sizeBytes) changed()
                }
                for (source in files.folders) {
                    val moved = folderAccess(source.space, source.id).folder
                    if (moved.parentId != files.destination.id || moved.name != source.name ||
                        moved.path != "${files.destination.path.trimEnd('/')}/${source.name}") changed()
                }
            }
        }
        checkAccess(owner, files.space); files.destination?.let { checkAccess(owner, it.space) }
        return row.copy(phase = if (partial) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.COMPLETED,
            files = files.copy(result = result)).also(save)
    }

    private suspend fun deleted(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): Boolean {
        val files = row.files!!; val parent = SynologyPhotoFileValidation.parent(files.folders)
        folder(parent, owner)
        val present = mutableSetOf<Long>(); var offset = 0
        while (true) {
            checkAccess(owner, files.space)
            val page = read("Browse.Folder", 2, "list", json("id" to parent.id, "offset" to offset, "limit" to 100,
                "sort_by" to "filename", "sort_direction" to "asc"), files.space).list()
            if (page.size > 100 || offset > Int.MAX_VALUE - page.size) invalid()
            for (child in page) {
                if (child.number("parent") != parent.id || !present.add(child.positive("id"))) invalid()
            }
            offset += page.size
            if (page.size < 100) break
        }
        var complete = files.folders.none { it.id in present }
        for (photo in row.targets) {
            val current = original(photo, owner)
            if (current != null) {
                if (!photo.copy(albumContext = null).matches(current, includeTime = true)) changed()
                complete = false
            }
        }
        checkAccess(owner, files.space)
        return complete
    }

    private suspend fun original(photo: SynologyPhotoEditTarget, owner: SynologyPhotosMutationAccess): SynologyPhoto? {
        checkAccess(owner, photo.id.space)
        val values = read("Browse.Item", 5, "get", json("id" to array(photo.id.itemId)), photo.id.space).list()
        if (values.size > 1) invalid()
        val current = values.singleOrNull()?.let { SynologyPhotosCodec.photo(it, owner.profileId, photo.id.space) }
        if (current != null && current.id != photo.id) changed()
        checkAccess(owner, photo.id.space)
        return current
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
