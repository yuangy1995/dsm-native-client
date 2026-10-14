package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import kotlinx.serialization.json.*

/** 目录沿现有管理通道固定目标；已提交操作只能回读，封面不按图片变化推测回执。 */
internal class SynologyPhotosFolderRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val details: suspend (SynologyPhoto) -> SynologyPhoto,
    private val photoPending: (SynologyPhotoId) -> Boolean,
    private val defaultSort: () -> SynologyPhotoSort,
    private val verifyCover: suspend (SynologyPhotoFolderSnapshot, SynologyPhotoFolderCover) -> Unit,
) {
    suspend fun access(space: SynologyPhotoSpace, id: Long): SynologyPhotoFolderAccess = access(space, id, identity())

    private suspend fun access(space: SynologyPhotoSpace, id: Long, owner: SynologyPhotosMutationAccess): SynologyPhotoFolderAccess {
        if (id <= 0) invalid()
        checkAccess(owner, space)
        val raw = read("Browse.Folder", 2, "get", json("id" to id, "additional" to array("access_permission", "thumbnail")), space).obj("folder")
        val result = SynologyPhotoFolderCodec.decode(raw, space, owner.managesShared, defaultSort())
        if (result.folder.id != id) changed()
        checkAccess(owner, space)
        return result
    }
    private suspend fun matching(target: SynologyPhotoFolderSnapshot, owner: SynologyPhotosMutationAccess): SynologyPhotoFolderAccess =
        access(target.space, target.id, owner).also {
            if (it.folder.path != target.path || target.parentId != null && it.folder.parentId != target.parentId) changed()
        }

    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val operation = row.folder ?: invalid(); val target = operation.target
        capability("Browse.Folder", if (row.action == SynologyPhotoAlbumAction.COVER_FOLDER) 2 else 1, target.space)
        val current = matching(target, owner)
        when (row.action) {
            SynologyPhotoAlbumAction.CREATE_FOLDER -> if (!current.canCreate) denied()
            SynologyPhotoAlbumAction.RENAME_FOLDER -> if (!current.canManage) denied()
            SynologyPhotoAlbumAction.SORT_FOLDER -> Unit
            SynologyPhotoAlbumAction.COVER_FOLDER -> {
                if (!current.canManage) denied()
                val photo = operation.coverPhoto ?: invalid()
                if (photoPending(photo.id)) changed()
                val actual = details(photo.photo())
                if (!photo.matches(actual, includeTime = true) || actual.albumContext != null) changed()
                val source = access(photo.id.space, photo.folderId, owner)
                if (!SynologyPhotoFolderCodec.contains(target.path, source.folder.path)) denied()
            }
            else -> invalid()
        }
        checkAccess(owner, target.space)
    }
    suspend fun execute(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val operation = row.folder ?: invalid(); val target = operation.target
        checkAccess(owner, target.space)
        val updated = when (row.action) {
            SynologyPhotoAlbumAction.CREATE_FOLDER -> {
                val result = write("Browse.Folder", 1, "create", json("target_id" to target.id, "name" to operation.name!!), target.space)
                val id = result.obj("folder").positive("id"); if (id == target.id) invalid()
                operation.copy(createdFolderId = id)
            }
            SynologyPhotoAlbumAction.RENAME_FOLDER -> {
                write("Browse.Folder", 1, "rename", json("id" to target.id, "name" to operation.name!!), target.space); operation
            }
            SynologyPhotoAlbumAction.SORT_FOLDER -> {
                val sort = operation.sort!!
                write("Browse.Folder", 1, "set_order", json("id" to target.id, "sort_by" to sort.field.value, "sort_direction" to sort.direction.value), target.space); operation
            }
            SynologyPhotoAlbumAction.COVER_FOLDER -> {
                write("Browse.Folder", 2, "set_cover", json("id" to target.id, "id_item" to array(operation.coverPhoto!!.id.itemId)), target.space)
                operation.copy(coverAcknowledged = true)
            }
            else -> invalid()
        }
        return row.copy(folder = updated)
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): Boolean {
        val operation = row.folder ?: invalid(); val target = operation.target
        checkAccess(owner, target.space)
        val confirmed = when (row.action) {
            SynologyPhotoAlbumAction.CREATE_FOLDER -> {
                val id = operation.createdFolderId ?: return false
                val current = access(target.space, id, owner)
                current.folder.parentId == target.id && current.folder.path == SynologyPhotoFolderCodec.childPath(target.path, operation.name!!) && current.canCreate
            }
            SynologyPhotoAlbumAction.RENAME_FOLDER -> matching(target.copy(name = operation.name!!,
                path = SynologyPhotoFolderCodec.renamedPath(target, operation.name)), owner).canManage
            SynologyPhotoAlbumAction.SORT_FOLDER -> matching(target, owner).explicitSort == operation.sort
            SynologyPhotoAlbumAction.COVER_FOLDER -> {
                if (!operation.coverAcknowledged) return false
                val current = matching(target, owner)
                val cover = current.covers.firstOrNull { it.sequence == 0L } ?: return false
                verifyCover(current.folder, cover); true
            }
            else -> invalid()
        }
        checkAccess(owner, target.space)
        return confirmed
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
