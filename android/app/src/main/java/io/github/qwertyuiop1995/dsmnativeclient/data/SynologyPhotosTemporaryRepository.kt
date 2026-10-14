package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.security.MessageDigest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 临时容器的组合步骤，共用相册互斥和恢复文件；恢复查询不继续任何写入。 */
internal class SynologyPhotosTemporaryRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val album: suspend (Long) -> Pair<JsonObject, SynologyPhotoAlbumSnapshot>?,
    private val members: suspend (Long) -> List<SynologyPhoto>,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
) {
    suspend fun state(id: Long): SynologyPhotoTemporaryAlbum {
        val owner = identity()
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        val (raw, value) = owned(id, owner)
        val sharing = SynologyPhotoSharingCodec.decode(raw, value).snapshot
        val all = members(id)
        val again = owned(id, owner)
        if (again.second != value || SynologyPhotoSharingCodec.decode(again.first, value).snapshot != sharing) changed()
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        return SynologyPhotoTemporaryAlbum(value, SynologyPhotoTemporarySnapshot(sharing, digest(all, owner), all.size))
    }

    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val current = state(row.album!!.id)
        if (current.album != row.album || current.snapshot != row.temporary!!.original) changed()
        row.temporary.preservedCopyId?.let { if (!copyMatches(it, row, owner)) changed() }
    }

    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        var row = input
        fun save(next: SynologyPhotoAlbumCheckpoint) { persist(next); row = next }
        suspend fun currentOriginal() {
            val current = state(row.album!!.id)
            if (current.album != row.album || current.snapshot != row.temporary!!.original) changed()
            currentCoroutineContext().ensureActive(); checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        }
        currentOriginal()
        if (row.temporary!!.keepCopy && row.temporary!!.preservedCopyId == null) {
            val receipt = write("Browse.NormalAlbum", 1, "copy", json("name" to row.album!!.name, "source_album_id" to row.album!!.id), null)
            val id = receipt.obj("album").positive("id")
            if (id == row.album!!.id) invalid()
            save(row.copy(createdAlbumId = id))
        }
        val copyId = row.createdAlbumId ?: row.temporary!!.preservedCopyId
        if (row.temporary!!.keepCopy && (copyId == null || !copyMatches(copyId, row, owner))) return row
        // 复制期间来源发生变化就保留双方；新副本不能成为清理旧来源的通行证。
        currentOriginal()
        if (row.temporary!!.original.sharing.access != SynologyPhotoLinkAccess.DISABLED) {
            save(row.copy(temporaryCloseAttempted = true))
            checkAccess(owner, SynologyPhotoSpace.PERSONAL)
            write("Sharing.Passphrase", 1, "set_shared", json("policy" to "album", "album_id" to row.album!!.id, "enabled" to false), null)
        }
        val closed = state(row.album!!.id)
        if (closed.album != row.album || !closedMatches(closed.snapshot, row.temporary!!.original)) return row
        save(row.copy(temporaryClosedRevision = closed.snapshot.sharing.revision))
        if (copyId != null && !copyMatches(copyId, row, owner)) return row
        val beforeDelete = state(row.album!!.id)
        if (beforeDelete.album != row.album || beforeDelete.snapshot != closed.snapshot) return row
        currentCoroutineContext().ensureActive(); checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        save(row.copy(temporaryDeleteAttempted = true))
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        write("Browse.Album", 1, "delete", json("id" to array(row.album!!.id)), null)
        return row
    }

    suspend fun reviewCreate(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoTemporarySnapshot? {
        val id = row.createdAlbumId ?: return null
        val actual = state(id)
        return actual.snapshot.takeIf { actual.album.name == row.name && actual.album.ownerUserId == owner.userId &&
            actual.snapshot.itemCount == row.targets.size && actual.snapshot.membersDigest == digest(row.targets.map { it.photo() }, owner) }
    }

    suspend fun reviewStop(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumPhase {
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        val change = row.temporary!!
        val copyId = row.createdAlbumId ?: change.preservedCopyId
        if (change.keepCopy && (copyId == null || !copyMatches(copyId, row, owner))) return SynologyPhotoAlbumPhase.PENDING
        val old = album(row.album!!.id)
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        if (old == null) return if (row.temporaryDeleteAttempted) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PARTIAL
        if (old.second != row.album) return if (!row.temporaryCloseAttempted && !row.temporaryDeleteAttempted)
            SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.PENDING
        // 只读恢复止于当前阶段。已停止但未删除时，用户可再次明确选择清理。
        val closed = SynologyPhotoSharingCodec.decode(old.first, old.second).snapshot.access == SynologyPhotoLinkAccess.DISABLED
        return when {
            row.temporaryDeleteAttempted -> SynologyPhotoAlbumPhase.PENDING
            !row.temporaryCloseAttempted || closed -> SynologyPhotoAlbumPhase.PARTIAL
            else -> SynologyPhotoAlbumPhase.PENDING
        }
    }

    private suspend fun owned(id: Long, owner: SynologyPhotosMutationAccess): Pair<JsonObject, SynologyPhotoAlbumSnapshot> {
        val value = album(id) ?: changed()
        if (value.second.ownerUserId != owner.userId || !value.second.temporaryShare) denied()
        return value
    }
    private suspend fun copyMatches(id: Long, row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): Boolean {
        if (id == row.album!!.id) invalid()
        val (raw, value) = album(id) ?: return false
        if (value.ownerUserId != owner.userId || !value.ordinary || value.temporary != false ||
            raw.optionalBoolean("shared") != false || value.name != row.album.name) return false
        val all = members(id)
        val reread = album(id) ?: return false
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        return reread.second == value && reread.first.optionalBoolean("shared") == false &&
            all.size == row.temporary!!.original.itemCount && digest(all, owner) == row.temporary.original.membersDigest
    }
    private fun closedMatches(current: SynologyPhotoTemporarySnapshot, before: SynologyPhotoTemporarySnapshot): Boolean =
        current.membersDigest == before.membersDigest && current.itemCount == before.itemCount &&
            current.sharing.access == SynologyPhotoLinkAccess.DISABLED && current.sharing.copy(
                revision = before.sharing.revision, access = before.sharing.access) == before.sharing

    private fun digest(photos: List<SynologyPhoto>, owner: SynologyPhotosMutationAccess): String {
        val ids = mutableSetOf<SynologyPhotoId>()
        val values = photos.sortedWith(compareBy({ it.id.space.name }, { it.id.itemId })).map { photo ->
            if (photo.id.profileId != owner.profileId || photo.id.itemId <= 0 || !ids.add(photo.id) || photo.filename.isBlank() ||
                photo.sizeBytes < 0 || photo.folderId <= 0 || !photo.indexedAt.isFinite()) invalid()
            val sourceOwner = photo.albumContext?.ownerUserId ?: if (photo.id.space == SynologyPhotoSpace.SHARED) 0 else owner.userId
            buildJsonObject {
                put("space", photo.id.space.name); put("item", photo.id.itemId); put("owner", sourceOwner)
                put("filename", photo.filename); put("size", photo.sizeBytes); put("folder", photo.folderId)
                put("indexed", photo.indexedAt)
            }
        }
        return MessageDigest.getInstance("SHA-256").digest(JsonArray(values).toString().toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
