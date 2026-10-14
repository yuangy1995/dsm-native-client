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
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** 手动重建资格独立于原件编辑；相册下载权不能代替贡献者或原目录资格。 */
internal class SynologyPhotosPreviewAccess(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val album: suspend (Long) -> SynologyPhotoAlbumSnapshot,
    private val pending: (SynologyPhotoId) -> Boolean,
) {
    suspend fun queue(space: SynologyPhotoSpace, owner: SynologyPhotosMutationAccess): List<SynologyPhotoPreviewRegenerationCodec.Queued> {
        checkAccess(owner, space); capability("RegeneratePreview", 1, space)
        return SynologyPhotoPreviewRegenerationCodec.queue(read("RegeneratePreview", 1, "list_regenerating", emptyMap(), space))
            .also { checkAccess(owner, space) }
    }

    suspend fun pending(space: SynologyPhotoSpace): List<SynologyPhoto> {
        val owner = identity()
        return queue(space, owner).map { entry ->
            val raw = read("Browse.Item", 5, "get", json("id" to array(entry.id), "additional" to array("thumbnail", "resolution", "orientation")), space)
                .list().singleOrNull() ?: invalid()
            val photo = SynologyPhotosCodec.photo(raw, owner.profileId, space)
            if (!entry.matches(SynologyPhotoEditTarget(photo))) changed()
            validateTarget(SynologyPhotoEditTarget(photo), owner)
        }
    }

    suspend fun checkpoint(photos: List<SynologyPhoto>, resuming: Boolean): SynologyPhotoAlbumCheckpoint {
        val owner = identity()
        if (photos.isEmpty() || photos.size > 100 || photos.map { it.id }.distinct().size != photos.size ||
            photos.map { it.id.space }.distinct().size > 1 && !owner.managesShared) invalid()
        val targets = photos.map(::SynologyPhotoEditTarget)
        val queues = if (resuming) targets.map { it.id.space }.distinct().associateWith { queue(it, owner) } else emptyMap()
        val states = targets.map { target ->
            capability("RegeneratePreview", 1, target.id.space)
            if (resuming && queues[target.id.space]?.any { it.matches(target) } != true) changed()
            val photo = validateTarget(target, owner)
            SynologyPhotoPreviewProgress(photo.thumbnail?.unitId, photo.thumbnail?.revision)
        }
        return SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = owner.userId, action = SynologyPhotoAlbumAction.REGENERATE_PREVIEWS,
            targets = targets, previews = SynologyPhotoPreviewRegeneration(resuming, states)).also(::validatePhotoAlbumCheckpoint)
    }

    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        SynologyPhotoPreviewRegenerationCodec.validate(row)
        if (row.targets.map { it.id.space }.distinct().size > 1 && !owner.managesShared) denied()
        val value = row.previews!!
        val queues = if (value.resuming) row.targets.map { it.id.space }.distinct().associateWith { queue(it, owner) } else emptyMap()
        for ((index, target) in row.targets.withIndex()) {
            capability("RegeneratePreview", 1, target.id.space)
            val current = validateTarget(target, owner)
            if (!row.submitted && (current.thumbnail?.unitId != value.progress[index].baselineUnitId ||
                    current.thumbnail?.revision != value.progress[index].baselineRevision)) changed()
            if (value.resuming && queues[target.id.space]?.any { it.matches(target) } != true) changed()
        }
    }

    suspend fun readTarget(target: SynologyPhotoEditTarget, owner: SynologyPhotosMutationAccess): SynologyPhoto {
        checkAccess(owner, target.id.space)
        if (target.id.profileId != owner.profileId || target.id.itemId <= 0 || pending(target.id)) denied()
        val context = target.albumContext
        val params = json("id" to array(target.id.itemId), "additional" to array("thumbnail", "resolution", "orientation", "provider_user_id")) +
            (context?.let { json("album_id" to it.albumId) } ?: emptyMap())
        val raw = read("Browse.Item", 5, "get", params, target.id.space.takeIf { context == null }).list().singleOrNull() ?: invalid()
        val currentContext = context?.let {
            if (raw.number("owner_user_id") != it.ownerUserId) changed()
            it.copy(providerUserId = raw.optionalObject("additional")?.optionalLong("provider_user_id")?.also { id -> if (id < 0) invalid() })
        }
        val photo = SynologyPhotosCodec.photo(raw, owner.profileId, target.id.space, currentContext)
        if (!target.matches(photo, includeTime = true)) changed()
        checkAccess(owner, target.id.space)
        return photo
    }

    suspend fun validateTarget(target: SynologyPhotoEditTarget, owner: SynologyPhotosMutationAccess): SynologyPhoto {
        val current = readTarget(target, owner)
        val context = current.albumContext
        if (context == null) requireFolder(target, owner, manageOnly = false)
        else {
            val value = album(context.albumId)
            if (context.providerUserId != owner.userId) {
                if (target.id.space == SynologyPhotoSpace.PERSONAL &&
                    (value.type != "condition" && value.frozen != true || context.ownerUserId != owner.userId)) denied()
                requireFolder(target, owner, manageOnly = true)
            }
        }
        checkAccess(owner, target.id.space)
        return current
    }

    private suspend fun requireFolder(target: SynologyPhotoEditTarget, owner: SynologyPhotosMutationAccess, manageOnly: Boolean) {
        val folder = read("Browse.Folder", 2, "get", json("id" to target.folderId, "additional" to array("access_permission")), target.id.space).obj("folder")
        if (folder.number("id") != target.folderId) changed()
        val rights = folder.optionalObject("additional")?.optionalObject("access_permission")
        if (target.id.space == SynologyPhotoSpace.SHARED && owner.managesShared) return
        if (rights?.permission("view") != true || !(rights.permission("manage") ||
                target.id.space == SynologyPhotoSpace.SHARED && !manageOnly && rights.permission("download"))) denied()
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
