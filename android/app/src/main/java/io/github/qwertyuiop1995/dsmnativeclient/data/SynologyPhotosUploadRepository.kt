package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.encode
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalLong
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

internal data class SynologyPhotosMutationAccess(val profileId: String, val userId: Long, val generation: Long, val managesShared: Boolean)
internal typealias SynologyPhotosUploadTransport = suspend (ApiCapability, String, Map<String, String>, UploadSource, (Long, Long) -> Unit) -> JsonObject

/** 既有 Photos 仓储的上传分支；所有请求仍走同一授权、发现与传输层。 */
internal class SynologyPhotosUploadRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val upload: SynologyPhotosUploadTransport?,
) {
    private val mutex = Mutex()
    private val operations = mutableMapOf<String, SynologyPhotoUploadCheckpoint>()

    suspend fun duplicatePolicy(): SynologyPhotoUploadDuplicate {
        val value = read("Setting.User", 1, "get", emptyMap(), null).text("upload_default_action")
        return SynologyPhotoUploadDuplicate.entries.firstOrNull { it.value == value } ?: invalid()
    }

    suspend fun addableAlbums(offset: Int, limit: Int): List<SynologyPhotoCollection> {
        if (offset < 0 || limit !in 1..500 || offset > Int.MAX_VALUE - limit) invalid()
        val rows = read("Browse.NormalAlbum", 1, "list", json("category" to "addable", "offset" to offset,
            "limit" to limit, "sort_by" to "album_name", "sort_direction" to "asc", "additional" to array("sharing_info", "thumbnail")), null).list()
        if (rows.size > limit || rows.map { it.positive("id") }.distinct().size != rows.size || rows.any { it.text("type") == "condition" }) invalid()
        // 不过滤分页项目，避免以客户端过滤后的条数推断已读完；冻结状态在写前检查。
        return rows.map { SynologyPhotosCodec.collection(it) }
    }

    suspend fun prepare(target: SynologyPhotoUploadTarget) { targetParameters(target, identity()) }

    suspend fun perform(input: SynologyPhotoUploadCheckpoint, file: File?, save: (SynologyPhotoUploadCheckpoint) -> Unit,
        progress: (Long, Long) -> Unit): SynologyPhotoUploadCheckpoint = withContext(Dispatchers.IO) {
        mutex.withLock {
            val owner = identity()
            var row = select(input, owner)
            if (row.submitted) return@withLock reviewLocked(row, owner, save)
            val fields: Map<String, JsonElement>
            val source: UploadSource?
            val space: SynologyPhotoSpace?
            when (val action = row.action) {
                is SynologyPhotoUploadAction.Upload -> {
                    if (upload == null) unavailable()
                    space = action.target.sourceSpace()
                    fields = targetParameters(action.target, owner) + json("duplicate" to action.duplicate.value,
                        "name" to action.filename, "mtime" to action.modifiedAtSeconds)
                    source = file?.takeIf { it.isFile }?.let { local -> UploadSource(action.filename, "application/octet-stream", action.size,
                        { local.inputStream() }, requestToken = row.operationId, onContentRead = { digest ->
                            if (digest.bytes != action.size || digest.sha256 != action.sha256) throw java.io.IOException("Photo upload source changed")
                        }) } ?: changed()
                    if (source.contentFingerprint().sha256 != action.sha256) changed()
                }
                is SynologyPhotoUploadAction.CreateFolder -> {
                    space = action.space
                    capability("Browse.Folder", 1, space)
                    requireFolder(action.parentId, space, owner)
                    fields = json("target_id" to action.parentId, "name" to action.name)
                    source = null
                }
            }
            checkAccess(owner, space)
            currentCoroutineContext().ensureActive()
            row = row.copy(phase = SynologyPhotoUploadPhase.SUBMITTING)
            persist(row, save)
            // 保存提交边界后即使取消或回执损坏，也不允许第二次写入。
            row = try {
                checkAccess(owner, space)
                when (val action = row.action) {
                    is SynologyPhotoUploadAction.Upload -> {
                        val method = if (action.target is SynologyPhotoUploadTarget.Folder) "upload_to_folder" else "upload"
                        val reply = upload!!(capability("Upload.Item", 1, space), method, encode(fields), source!!, progress)
                        val id = reply.positive("id")
                        val duplicateAction = reply.optionalText("action")
                        if (duplicateAction == "ignore" && action.duplicate != SynologyPhotoUploadDuplicate.IGNORE) invalid()
                        row.copy(phase = SynologyPhotoUploadPhase.PENDING, itemId = id, uploadAction = duplicateAction)
                    }
                    is SynologyPhotoUploadAction.CreateFolder -> {
                        val reply = write("Browse.Folder", 1, "create", fields, space)
                        row.copy(phase = SynologyPhotoUploadPhase.PENDING, folderId = reply.obj("folder").positive("id"))
                    }
                }
            } catch (_: Exception) { row.copy(phase = SynologyPhotoUploadPhase.PENDING) }
            withContext(NonCancellable) { persist(row, save) }
            // 结果回读可以失败；保留已有编号供同账号下次恢复。
            try { reviewLocked(row, owner, save) } catch (_: Exception) { row }
        }
    }

    suspend fun review(input: SynologyPhotoUploadCheckpoint, save: (SynologyPhotoUploadCheckpoint) -> Unit): SynologyPhotoUploadCheckpoint =
        withContext(Dispatchers.IO) { mutex.withLock { val owner = identity(); reviewLocked(select(input, owner), owner, save) } }

    private suspend fun reviewLocked(row: SynologyPhotoUploadCheckpoint, owner: SynologyPhotosMutationAccess,
        save: (SynologyPhotoUploadCheckpoint) -> Unit): SynologyPhotoUploadCheckpoint {
        if (!row.submitted) invalid()
        if (row.finished) { persist(row, save); return row }
        val next = when (val action = row.action) {
            is SynologyPhotoUploadAction.Upload -> {
                val id = row.itemId ?: return row
                val target = action.target
                val fields = json("id" to array(id), "additional" to array("provider_user_id")) +
                    if (target is SynologyPhotoUploadTarget.Album) json("album_id" to target.id) else emptyMap()
                val values = read("Browse.Item", 5, "get", fields, target.sourceSpace()).list()
                checkAccess(owner, target.sourceSpace())
                if (values.size != 1 || values[0].positive("id") != id) return row
                val item = values[0]
                val ignored = row.uploadAction == "ignore"
                val matches = if (ignored) item.text("filename") == action.filename else item.number("filesize") == action.size
                val folder = item.positive("folder_id")
                if (!matches || target is SynologyPhotoUploadTarget.Folder && folder != target.id) return row
                if (target is SynologyPhotoUploadTarget.Album) {
                    if (item.number("owner_user_id") < 0 || !ignored && item.optionalObject("additional")?.optionalLong("provider_user_id") != owner.userId) return row
                }
                row.copy(phase = if (ignored) SynologyPhotoUploadPhase.SKIPPED else SynologyPhotoUploadPhase.COMPLETED)
            }
            is SynologyPhotoUploadAction.CreateFolder -> {
                val id = row.folderId ?: return row
                val folder = requireFolder(id, action.space, owner)
                if (folder.number("parent") != action.parentId || SynologyPhotosCodec.collection(folder, folder = true).name != action.name) return row
                row.copy(phase = SynologyPhotoUploadPhase.COMPLETED)
            }
        }
        checkAccess(owner, when (val action = row.action) {
            is SynologyPhotoUploadAction.Upload -> action.target.sourceSpace()
            is SynologyPhotoUploadAction.CreateFolder -> action.space
        })
        persist(next, save)
        return next
    }

    private suspend fun targetParameters(target: SynologyPhotoUploadTarget, owner: SynologyPhotosMutationAccess): Map<String, JsonElement> {
        capability("Upload.Item", 1, target.sourceSpace())
        val fields = when (target) {
            is SynologyPhotoUploadTarget.Timeline -> {
                val root = read("Browse.Folder", 2, "get", json("name" to "/", "additional" to array("access_permission")), target.space).obj("folder")
                requireFolder(root.positive("id"), target.space, owner)
                json("folder" to array("PhotoLibrary"), "uploadDestination" to "timeline")
            }
            is SynologyPhotoUploadTarget.Folder -> {
                requireFolder(target.id, target.space, owner)
                json("target_folder_id" to target.id)
            }
            is SynologyPhotoUploadTarget.Album -> {
                if (target.id <= 0) invalid()
                val rows = read("Browse.Album", 4, "get", json("id" to array(target.id), "additional" to array("sharing_info", "thumbnail")), null).list()
                if (rows.size != 1 || rows[0].positive("id") != target.id) changed()
                val album = rows[0]
                if (album.text("type") == "condition" || album.optionalBoolean("freeze_album") == true) denied()
                if (album.positive("owner_user_id") == owner.userId) json("album_id" to target.id, "folder" to array("PhotoLibrary"))
                else {
                    val passphrase = (album.optionalText("passphrase") ?: album.optionalObject("additional")?.optionalObject("sharing_info")?.optionalText("passphrase"))
                        ?.takeIf(String::isNotBlank) ?: denied()
                    val rights = read("Sharing.Passphrase", 1, "get_permission", json("passphrase" to passphrase, "exclude_public" to false), null).obj("permission")
                    if (!rights.permission("upload")) denied()
                    json("passphrase" to passphrase, "folder" to array("PhotoLibrary"))
                }
            }
        }
        checkAccess(owner, target.sourceSpace())
        return fields
    }

    private suspend fun requireFolder(id: Long, space: SynologyPhotoSpace, owner: SynologyPhotosMutationAccess): JsonObject {
        if (id <= 0) invalid()
        val folder = read("Browse.Folder", 2, "get", json("id" to id, "additional" to array("access_permission")), space).obj("folder")
        if (folder.positive("id") != id) changed()
        val rights = folder.optionalObject("additional")?.optionalObject("access_permission")
        if (!(space == SynologyPhotoSpace.SHARED && owner.managesShared) &&
            (rights?.permission("view") != true || !(rights.permission("manage") || space == SynologyPhotoSpace.SHARED && rights.permission("upload")))) denied()
        checkAccess(owner, space)
        return folder
    }

    private fun select(row: SynologyPhotoUploadCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoUploadCheckpoint {
        validatePhotoUploadCheckpoint(row)
        if (row.profileId != owner.profileId || row.userId != owner.userId) denied()
        val existing = operations[row.operationId]
        if (existing != null && !existing.sameOperation(row)) changed()
        if (existing == null && !row.submitted && operations.values.any {
                it.operationId != row.operationId && it.profileId == row.profileId && it.userId == row.userId &&
                    samePendingAction(it.action, row.action) && it.submitted && !it.finished
            }) changed()
        return existing ?: row.also { operations[it.operationId] = it }
    }

    private fun persist(row: SynologyPhotoUploadCheckpoint, save: (SynologyPhotoUploadCheckpoint) -> Unit) {
        operations[row.operationId] = row
        save(row)
    }
    private fun samePendingAction(a: SynologyPhotoUploadAction, b: SynologyPhotoUploadAction): Boolean =
        if (a is SynologyPhotoUploadAction.Upload && b is SynologyPhotoUploadAction.Upload)
            a.target == b.target && a.filename == b.filename && a.size == b.size && a.sha256 == b.sha256 else a == b
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    private fun unavailable(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
}

internal fun validatePhotoUploadCheckpoint(row: SynologyPhotoUploadCheckpoint) {
    fun name(value: String) = value.isNotBlank() && value !in setOf(".", "..") && value.none { it == '/' || it == '\u0000' }
    if (row.version != 1 || row.userId <= 0 || row.profileId.isBlank() ||
        runCatching { UUID.fromString(row.operationId).toString() != row.operationId }.getOrDefault(true)) SynologyPhotosCodec.invalid()
    when (val action = row.action) {
        is SynologyPhotoUploadAction.Upload -> {
            if (!name(action.filename) || action.size <= 0 || action.modifiedAtSeconds < 0 || !action.sha256.matches(Regex("[a-f0-9]{64}")) || row.folderId != null) SynologyPhotosCodec.invalid()
            if (action.target is SynologyPhotoUploadTarget.Folder && action.target.id <= 0 || action.target is SynologyPhotoUploadTarget.Album && action.target.id <= 0) SynologyPhotosCodec.invalid()
            if (row.itemId != null && row.itemId <= 0 || row.finished && row.itemId == null || row.uploadAction == "ignore" && action.duplicate != SynologyPhotoUploadDuplicate.IGNORE) SynologyPhotosCodec.invalid()
            if ((row.phase == SynologyPhotoUploadPhase.SKIPPED) != (row.finished && row.uploadAction == "ignore")) SynologyPhotosCodec.invalid()
        }
        is SynologyPhotoUploadAction.CreateFolder -> {
            if (action.parentId <= 0 || !name(action.name) || row.itemId != null || row.uploadAction != null || row.folderId != null && row.folderId <= 0 ||
                row.finished && row.folderId == null || row.phase == SynologyPhotoUploadPhase.SKIPPED) SynologyPhotosCodec.invalid()
        }
    }
    if (row.phase in setOf(SynologyPhotoUploadPhase.READY, SynologyPhotoUploadPhase.SUBMITTING) &&
        (row.itemId != null || row.folderId != null || row.uploadAction != null)) SynologyPhotosCodec.invalid()
}
