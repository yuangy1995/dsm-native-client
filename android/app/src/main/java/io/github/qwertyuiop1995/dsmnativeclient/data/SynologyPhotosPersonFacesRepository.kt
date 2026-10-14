package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalLong
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.json.*

/** 人物内的人脸关联与封面；与人物改名共用预检、提交事实和只读恢复。 */
internal class SynologyPhotosPersonFacesRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val check: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace) -> Unit,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val details: suspend (SynologyPhoto) -> SynologyPhoto,
    private val folderAccess: suspend (SynologyPhotoSpace, Long) -> SynologyPhotoFolderAccess,
    private val photoPending: (SynologyPhotoId) -> Boolean,
    private val loadThumbnail: suspend (SynologyPhotoPersonFace) -> ByteArray,
    private val people: suspend (SynologyPhotoSpace, Boolean, SynologyPhotosMutationAccess) -> List<SynologyPhotoCollection>,
) {
    private data class Authorized(val generation: Long, val face: SynologyPhotoPersonFace)
    private val authorized = ConcurrentHashMap<Pair<SynologyPhotoSpace, Long>, Authorized>()
    fun clear() = authorized.clear()
    suspend fun faces(personId: Long, photos: List<SynologyPhoto>): List<SynologyPhotoPersonFace> = faces(personId, photos, identity())
    private suspend fun faces(personId: Long, photos: List<SynologyPhoto>, owner: SynologyPhotosMutationAccess): List<SynologyPhotoPersonFace> {
        val space = photos.firstOrNull()?.id?.space ?: invalid()
        if (personId <= 0 || photos.size !in 1..100 || photos.map { it.id }.distinct().size != photos.size ||
            photos.any { it.id.profileId != owner.profileId || it.id.space != space || it.id.itemId <= 0 || it.albumContext != null }) invalid()
        val result = mutableListOf<SynologyPhotoPersonFace>(); val seen = mutableSetOf<Long>()
        for (photo in photos) {
            check(owner, space)
            val rows = read("Browse.Person", 1, "list_face", json("person_id" to personId, "item_id" to array(photo.id.itemId)), space).list()
            check(owner, space)
            for (row in rows) {
                val id = row.positive("id"); if (!seen.add(id)) invalid()
                result += SynologyPhotoPersonFace(id, personId, photo.id,
                    row.optionalObject("additional")?.optionalObject("thumbnail")?.text("cache_key"))
            }
        }
        check(owner, space)
        // 重新读取同一人物/照片时撤销旧列表授权，避免移出后仍沿用旧人脸缓存。
        val photoIds = photos.map { it.id }.toSet()
        authorized.entries.removeIf { (_, entry) -> entry.face.personId == personId && entry.face.photoId in photoIds }
        result.forEach { authorized[space to it.id] = Authorized(owner.generation, it) }
        return result
    }
    suspend fun thumbnail(face: SynologyPhotoPersonFace): ByteArray {
        val owner = identity(); check(owner, face.photoId.space)
        if (face.photoId.profileId != owner.profileId || face.revision == null ||
            authorized[face.photoId.space to face.id] != Authorized(owner.generation, face)) denied()
        return loadThumbnail(face).also { check(owner, face.photoId.space) }
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val value = row.people!!; verifyPhotos(row, owner, true)
        val current = faces(value.originals.first().id, row.targets.map { it.photo() }, owner)
        if (row.action == SynologyPhotoAlbumAction.COVER_PERSON) {
            if (current.isEmpty()) changed()
        } else if (!current.map { it.snapshot() }.containsAll(value.faces!!.selected)) changed()
        check(owner, value.space)
    }
    private suspend fun verifyPhotos(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess, management: Boolean) {
        val folders = mutableSetOf<Long>()
        for (target in row.targets) {
            check(owner, target.id.space)
            if (management && photoPending(target.id)) changed()
            if (!target.matches(details(target.photo()), includeTime = true)) changed()
            if (management && folders.add(target.folderId) && !folderAccess(target.id.space, target.folderId).canManage) denied()
        }
        check(owner, row.people!!.space)
    }
    suspend fun execute(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val value = row.people!!; val faces = value.faces!!; val original = value.originals.first()
        check(owner, value.space)
        val ids = JsonArray(faces.selected.map { JsonPrimitive(it.id) })
        val receipt = when (row.action) {
            SynologyPhotoAlbumAction.REMOVE_PERSON_FACES -> write("Browse.Person", 1, "delete_face", json("person_id" to original.id, "face_id" to ids), value.space)
            SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES -> write("Browse.Person", 1, "separate", json("name" to value.name!!,
                "target_id" to (value.originals.getOrNull(1)?.id ?: 0), "face_id" to ids), value.space)
            SynologyPhotoAlbumAction.COVER_PERSON -> write("Browse.Person", 1, "set_cover", json("id" to original.id, "photo_id" to row.targets.single().id.itemId), value.space)
            else -> invalid()
        }
        val next = when (row.action) {
            SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES -> {
                val id = receipt.positive("id")
                if (id == original.id || value.originals.getOrNull(1)?.id?.let { it != id } == true || receipt.text("name") != value.name) invalid()
                faces.copy(targetReceipt = id)
            }
            SynologyPhotoAlbumAction.COVER_PERSON -> {
                if (receipt.positive("id") != original.id) invalid()
                faces.copy(coverReceipt = receipt.positive("cover"))
            }
            else -> faces
        }
        check(owner, value.space)
        return row.copy(people = value.copy(acknowledged = true, faces = next))
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val value = row.people!!; val faces = value.faces!!; val original = value.originals.first()
        var removedPhotos = emptySet<Long>(); var removedPeople = emptySet<Long>()
        verifyPhotos(row, owner, false)
        if (row.action == SynologyPhotoAlbumAction.COVER_PERSON) {
            val cover = faces.coverReceipt ?: return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
            if (person(original.id, value.space, owner).optionalLong("cover") != cover) return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
        } else {
            val photos = row.targets.map { it.photo() }
            val current = faces(original.id, photos, owner)
            if (current.any { face -> faces.selected.any { it.id == face.id } }) return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
            if (row.action == SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES) {
                val destination = value.originals.getOrNull(1)?.id ?: faces.targetReceipt ?: return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
                if (!faces(destination, photos, owner).map { it.snapshot() }.containsAll(faces.selected) ||
                    person(destination, value.space, owner).text("name") != value.name) return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
            }
            removedPhotos = row.targets.map { it.id.itemId }.toSet() - current.map { it.photoId.itemId }.toSet()
        }
        val all = people(value.space, false, owner)
        if (all.none { it.id == original.id }) {
            if (row.action == SynologyPhotoAlbumAction.COVER_PERSON) return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
            removedPeople = setOf(original.id)
        }
        check(owner, value.space)
        return row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, people = value.copy(
            completedIds = value.originals.map { it.id }.toSet(), removedIds = removedPeople,
            faces = faces.copy(removedPhotoIds = removedPhotos)))
    }
    private suspend fun person(id: Long, space: SynologyPhotoSpace, owner: SynologyPhotosMutationAccess): JsonObject {
        check(owner, space)
        val rows = read("Browse.Person", 1, "get", json("id" to array(id)), space).list()
        if (rows.size != 1 || rows.single().positive("id") != id) changed()
        check(owner, space); return rows.single()
    }
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
}
