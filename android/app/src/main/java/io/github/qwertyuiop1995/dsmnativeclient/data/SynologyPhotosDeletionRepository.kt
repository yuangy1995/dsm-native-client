package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.decimal
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** 单张与批量共用逐项删除器；已提交记录跨进程只读恢复，不依赖任务回执编号。 */
internal class SynologyPhotosDeletionRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val photoPending: (SynologyPhotoId) -> Boolean,
    private val enabled: () -> Boolean,
) {
    private val mutex = Mutex()
    private val operations = mutableMapOf<String, SynologyPhotoDeletionCheckpoint>()
    private val rejections = mutableMapOf<String, DsmFailure>()
    fun pending(id: SynologyPhotoId): Boolean = operations.values.any {
        it.target.id == id && it.phase == SynologyPhotoDeletionPhase.SUBMITTED
    }

    suspend fun prepare(photo: SynologyPhoto) {
        val owner = identity()
        val row = SynologyPhotoDeletionCheckpoint(userId = owner.userId, target = SynologyPhotoDeletionTarget(photo))
        requireCheckpoint(row, owner)
        if (!enabled()) throw SynologyPhotoFailure(SynologyPhotoFailureKind.DELETION_UNVERIFIED)
        if (photoPending(photo.id)) changed()
        capability("BackgroundTask.File", 1, photo.id.space)
        capability("Browse.Item", 5, photo.id.space); capability("Browse.Folder", 2, photo.id.space)
        val current = original(row.target, owner) ?: changed()
        if (!row.target.matches(current)) changed()
        val folder = read("Browse.Folder", 2, "get", json("id" to photo.folderId,
            "additional" to array("access_permission")), photo.id.space).obj("folder")
        val access = folder.optionalObject("additional")?.optionalObject("access_permission")
        val sharedManager = photo.id.space == SynologyPhotoSpace.SHARED && owner.managesShared
        if (folder.number("id") != photo.folderId || !sharedManager &&
            (access?.permission("view") != true || access?.permission("manage") != true))
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.DELETE_DENIED)
        checkAccess(owner, photo.id.space)
    }

    suspend fun target(row: SynologyPhotoDeletionCheckpoint): SynologyPhoto {
        val owner = identity(); requireCheckpoint(row, owner)
        if (row.phase != SynologyPhotoDeletionPhase.PREPARED) changed()
        val photo = original(row.target, owner) ?: changed()
        if (!row.target.matches(photo)) changed()
        return photo
    }

    suspend fun perform(photo: SynologyPhoto, input: SynologyPhotoDeletionCheckpoint,
        save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint = mutex.withLock {
        val owner = identity(); requireCheckpoint(input, owner)
        if (!input.target.matches(photo)) changed()
        val cached = operations[input.operationId]
        if (cached != null && !cached.sameOperation(input)) changed()
        var row = cached ?: input
        rejections[row.operationId]?.let { save(row); throw it }
        if (row.phase == SynologyPhotoDeletionPhase.CONFIRMED) return@withLock row.also(save)
        if (row.phase == SynologyPhotoDeletionPhase.SUBMITTED) return@withLock reviewLocked(row, owner, save)
        if (row.phase != SynologyPhotoDeletionPhase.PREPARED || pending(photo.id)) changed()
        prepare(photo)
        checkAccess(owner, photo.id.space)
        row = row.copy(phase = SynologyPhotoDeletionPhase.SUBMITTED)
        // 存储失败直接抛出，不允许删除请求先于持久边界发生。
        save(row); operations[row.operationId] = row
        checkAccess(owner, photo.id.space)
        try {
            write("BackgroundTask.File", 1, "delete", json("item_id" to array(photo.id.itemId), "folder_id" to array()), photo.id.space)
        } catch (error: Exception) {
            if (error is DsmFailure && error.code in setOf(105, 106, 107, 119)) {
                val rejected = row.copy(phase = SynologyPhotoDeletionPhase.REJECTED)
                withContext(NonCancellable) { save(rejected) }
                operations[row.operationId] = rejected; rejections[row.operationId] = error
                throw error
            }
            // 未知响应、断网和取消不证明未执行；只能保留提交事实。
            return@withLock row
        }
        val result = try { readResult(row, owner) } catch (_: Exception) { return@withLock row }
        persist(result, save)
    }

    suspend fun review(row: SynologyPhotoDeletionCheckpoint,
        save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint = mutex.withLock {
        val owner = identity(); requireCheckpoint(row, owner)
        val cached = operations[row.operationId]
        if (cached != null && !cached.sameOperation(row)) changed()
        reviewLocked(cached ?: row, owner, save)
    }

    private suspend fun reviewLocked(row: SynologyPhotoDeletionCheckpoint, owner: SynologyPhotosMutationAccess,
        save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint {
        if (row.phase == SynologyPhotoDeletionPhase.CONFIRMED) return row.also(save)
        if (row.phase != SynologyPhotoDeletionPhase.SUBMITTED) changed()
        operations[row.operationId] = row
        return persist(readResult(row, owner), save)
    }
    private suspend fun readResult(row: SynologyPhotoDeletionCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoDeletionCheckpoint {
        val present = original(row.target, owner)
        if (present != null && !row.target.matches(present)) changed()
        checkAccess(owner, row.target.id.space)
        return if (present == null) row.copy(phase = SynologyPhotoDeletionPhase.CONFIRMED) else row
    }
    private suspend fun persist(row: SynologyPhotoDeletionCheckpoint, save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint {
        withContext(NonCancellable) { save(row) }
        operations[row.operationId] = row
        return row
    }
    private suspend fun requireCheckpoint(row: SynologyPhotoDeletionCheckpoint, owner: SynologyPhotosMutationAccess) {
        row.validate()
        val target = row.target
        if (target.id.profileId != owner.profileId || row.userId != owner.userId ||
            target.id.space == SynologyPhotoSpace.PERSONAL && target.albumContext?.ownerUserId?.let { it != owner.userId } == true)
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        checkAccess(owner, target.id.space)
    }
    private suspend fun original(target: SynologyPhotoDeletionTarget, owner: SynologyPhotosMutationAccess): SynologyPhoto? {
        checkAccess(owner, target.id.space)
        val values = read("Browse.Item", 5, "get", json("id" to array(target.id.itemId)), target.id.space).list()
        if (values.size > 1) invalid()
        val current = values.singleOrNull()?.let { value ->
            // 只解码删除身份字段；无关的 EXIF、地址或缩略图损坏不能阻断原件身份核查。
            SynologyPhoto(SynologyPhotoId(owner.profileId, target.id.space, value.positive("id")),
                value.text("filename"), value.number("filesize").also { if (it < 0) invalid() },
                value.decimal("time"), value.decimal("indexed_time"), value.positive("folder_id"), value.text("type"),
                albumContext = target.albumContext)
        }
        if (current != null && current.id != target.id) changed()
        checkAccess(owner, target.id.space)
        return current
    }
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
