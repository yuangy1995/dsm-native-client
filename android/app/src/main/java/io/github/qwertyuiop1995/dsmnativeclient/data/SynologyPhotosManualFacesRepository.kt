package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 手工人脸与相册管理共用串行提交、加密记录和只读恢复，不存储裁剪图。 */
internal class SynologyPhotosManualFacesRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val check: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace) -> Unit,
    private val freshAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val details: suspend (SynologyPhoto) -> SynologyPhoto,
    private val folderAccess: suspend (SynologyPhotoSpace, Long) -> SynologyPhotoFolderAccess,
    private val pending: (SynologyPhotoId) -> Boolean,
    private val upload: suspend (ApiCapability, Long, ByteArray) -> Boolean,
    private val thumbnail: suspend (SynologyPhotoPersonFace) -> ByteArray,
) {
    suspend fun faces(photo: SynologyPhoto): List<SynologyPhotoFaceRegion> {
        val owner = identity(); freshAccess(owner, photo.id.space)
        val target = SynologyPhotoEditTarget(photo); verifyPhoto(target, owner, true)
        return readFaces(target, owner)
    }
    suspend fun checkpoint(photo: SynologyPhoto, originals: List<SynologyPhotoFaceSnapshot>,
        changes: List<SynologyPhotoFaceChange>): SynologyPhotoAlbumCheckpoint {
        val owner = identity()
        val row = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = owner.userId,
            action = SynologyPhotoAlbumAction.EDIT_PHOTO_FACES, targets = listOf(SynologyPhotoEditTarget(photo)),
            manualFaces = SynologyPhotoManualFacesCheckpoint(originals, changes))
        validatePhotoAlbumCheckpoint(row); prepare(row, owner)
        return row
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        SynologyPhotoManualFacesCodec.validate(row)
        val target = row.targets.single(); val value = row.manualFaces!!; val space = target.id.space
        freshAccess(owner, space)
        capability("Browse.Item", 6, space); capability("Browse.Folder", 2, space)
        capability("Browse.Person", 3, space); capability("Upload.Face", 1, space)
        verifyPhoto(target, owner, true)
        val current = readFaces(target, owner).map { it.face }
        if (current.size != value.originals.size || value.originals.any { old -> current.none(old::matches) }) changed()
        value.changes.forEach { change -> person(change)?.let { verifyPerson(it, owner) } }
        check(owner, space)
    }

    fun requireImages(row: SynologyPhotoAlbumCheckpoint, images: Map<String, ByteArray>) {
        val additions = row.manualFaces!!.changes.filterIsInstance<SynologyPhotoFaceChange.Add>()
        if (images.keys != additions.map { it.temporaryId }.toSet() || additions.any { face ->
            val bytes = images.getValue(face.temporaryId)
            !SynologyPhotoManualFacesCodec.jpeg(bytes) || SynologyPhotoManualFacesCodec.digest(bytes) != face.jpegDigest
        }) invalid()
    }

    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        images: Map<String, ByteArray>, persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        var row = input
        val target = row.targets.single(); val space = target.id.space
        fun save(value: SynologyPhotoManualFacesCheckpoint) { row = row.copy(manualFaces = value); persist(row) }
        val additions = row.manualFaces!!.changes.filterIsInstance<SynologyPhotoFaceChange.Add>()
        if (additions.isNotEmpty()) {
            beforeStep(target, owner); additions.forEach { it.person?.let { person -> verifyPerson(person, owner) } }
            save(row.manualFaces!!.copy(addAttempted = true)); check(owner, space)
            val receipt = try {
                write("Browse.Person", 3, "add_face", json("id_item" to target.id.itemId,
                    "face" to JsonArray(additions.map(SynologyPhotoManualFacesCodec::parameters))), space)
            } catch (error: Exception) {
                if (rejected(error)) save(row.manualFaces!!.copy(addRejected = true))
                throw error
            }
            val requested = additions.map { it.temporaryId }.toSet()
            val entries = receipt.list().map { it.text("face_id_temp") to it.positive("face_id") }
            if (entries.map { it.first }.distinct().size != entries.size || entries.map { it.second }.distinct().size != entries.size ||
                entries.any { it.first !in requested || row.manualFaces!!.originals.any { old -> old.id == it.second } }) invalid()
            check(owner, space)
            save(row.manualFaces!!.copy(addAcknowledged = true, newIds = entries.toMap()))
            for (face in additions) {
                val id = row.manualFaces!!.newIds[face.temporaryId] ?: continue
                beforeStep(target, owner); face.person?.let { verifyPerson(it, owner) }
                save(row.manualFaces!!.copy(uploadAttempted = row.manualFaces!!.uploadAttempted + id)); check(owner, space)
                val accepted = try { upload(capability("Upload.Face", 1, space), id, images.getValue(face.temporaryId)) }
                catch (error: Exception) {
                    if (rejected(error)) save(row.manualFaces!!.copy(rejected = row.manualFaces!!.rejected + face.key))
                    throw error
                }
                check(owner, space)
                if (!accepted) {
                    save(row.manualFaces!!.copy(rejected = row.manualFaces!!.rejected + face.key))
                    return row
                }
                save(row.manualFaces!!.copy(uploaded = row.manualFaces!!.uploaded + id))
            }
            // 不完整的新增或上传不允许移除旧标记，冷恢复也不补发后续步骤。
            if (additions.any { row.manualFaces!!.newIds[it.temporaryId] !in row.manualFaces!!.uploaded }) return row
        }
        for (change in row.manualFaces!!.changes) {
            if (change is SynologyPhotoFaceChange.Add) continue
            beforeStep(target, owner); person(change)?.let { verifyPerson(it, owner) }
            val original = when (change) {
                is SynologyPhotoFaceChange.Remove -> change.original
                is SynologyPhotoFaceChange.Reassign -> change.original
                else -> invalid()
            }
            if (readFaces(target, owner).none { original.matches(it.face) }) changed()
            save(row.manualFaces!!.copy(attempted = row.manualFaces!!.attempted + change.key)); check(owner, space)
            val receipt = try {
                when (change) {
                    is SynologyPhotoFaceChange.Remove -> write("Browse.Person", 1, "delete_face",
                        json("person_id" to original.personId, "face_id" to array(original.id)), space)
                    is SynologyPhotoFaceChange.Reassign -> write("Browse.Person", 1, "separate",
                        json("face_id" to array(original.id), "name" to change.name) +
                            (change.person?.let { json("target_id" to it.id) } ?: emptyMap()), space)
                    else -> invalid()
                }
            } catch (error: Exception) {
                if (rejected(error)) save(row.manualFaces!!.copy(rejected = row.manualFaces!!.rejected + change.key))
                throw error
            }
            check(owner, space)
            var value = row.manualFaces!!
            if (change is SynologyPhotoFaceChange.Reassign) {
                val id = receipt.positive("id")
                if (receipt.text("name") != change.name || change.person?.id?.let { it != id } == true) invalid()
                value = value.copy(personReceipts = value.personReceipts + (change.key to id))
            }
            save(value.copy(acknowledged = value.acknowledged + change.key))
        }
        return row
    }

    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val target = row.targets.single(); val value = row.manualFaces!!
        freshAccess(owner, target.id.space); verifyPhoto(target, owner, false)
        val faces = readFaces(target, owner)
        val completed = value.completed.toMutableSet(); val failed = value.failed.toMutableSet()
        for (change in value.changes) {
            if (change.key in completed || change.key in failed) continue
            if (change.key in value.rejected) { failed += change.key; continue }
            when (change) {
                is SynologyPhotoFaceChange.Add -> {
                    val id = value.newIds[change.temporaryId]
                    if (!value.addAttempted || value.addRejected || value.addAcknowledged && id == null ||
                        id != null && id !in value.uploadAttempted) { failed += change.key; continue }
                    val face = faces.singleOrNull { it.face.id == id } ?: continue
                    if (face.face.personId <= 0 || face.face.name != change.name || !face.face.bounds.matches(change.bounds) ||
                        change.person?.id?.let { it != face.face.personId } == true || face.revision == null) continue
                    if (id in value.uploaded || SynologyPhotoManualFacesCodec.digest(thumbnail(
                            SynologyPhotoPersonFace(face.face.id, face.face.personId, target.id, face.revision))) == change.jpegDigest) completed += change.key
                }
                is SynologyPhotoFaceChange.Remove -> {
                    if (change.key !in value.attempted) failed += change.key
                    else if (faces.none { it.face.id == change.original.id }) completed += change.key
                }
                is SynologyPhotoFaceChange.Reassign -> {
                    if (change.key !in value.attempted) { failed += change.key; continue }
                    val id = change.person?.id ?: value.personReceipts[change.key] ?: continue
                    if (faces.any { it.face.id == change.original.id && it.face.personId == id && it.face.name == change.name &&
                        it.face.bounds.matches(change.original.bounds) }) completed += change.key
                }
            }
        }
        check(owner, target.id.space)
        val phase = when {
            completed.size == value.changes.size -> SynologyPhotoAlbumPhase.COMPLETED
            completed.size + failed.size == value.changes.size -> SynologyPhotoAlbumPhase.PARTIAL
            else -> SynologyPhotoAlbumPhase.PENDING
        }
        return row.copy(phase = phase, manualFaces = value.copy(completed = completed, failed = failed))
    }

    private suspend fun beforeStep(target: SynologyPhotoEditTarget, owner: SynologyPhotosMutationAccess) {
        currentCoroutineContext().ensureActive(); freshAccess(owner, target.id.space); verifyPhoto(target, owner, true)
    }
    private suspend fun readFaces(target: SynologyPhotoEditTarget, owner: SynologyPhotosMutationAccess): List<SynologyPhotoFaceRegion> {
        check(owner, target.id.space)
        return SynologyPhotoManualFacesCodec.faces(read("Browse.Item", 6, "list_face",
            json("id_item" to target.id.itemId, "additional" to array("thumbnail")), target.id.space)).also { check(owner, target.id.space) }
    }
    private suspend fun verifyPhoto(target: SynologyPhotoEditTarget, owner: SynologyPhotosMutationAccess, management: Boolean) {
        check(owner, target.id.space)
        if (target.id.profileId != owner.profileId || target.mediaType == "video") denied()
        if (management && pending(target.id)) changed()
        val current = details(target.photo())
        if (!target.matches(current, includeTime = true)) changed()
        if (management) {
            val context = current.albumContext
            if (context == null) {
                if (!folderAccess(target.id.space, target.folderId).canManage) denied()
            } else if (target.id.space == SynologyPhotoSpace.SHARED) {
                if (!owner.managesShared) denied()
            } else if (context.providerUserId != owner.userId) {
                if (context.ownerUserId != owner.userId) denied()
                val album = read("Browse.Album", 4, "get", json("id" to array(context.albumId)), null).list().singleOrNull() ?: changed()
                if (album.positive("id") != context.albumId || album.number("owner_user_id") != owner.userId ||
                    album.text("type") != "condition" && album.optionalBoolean("freeze_album") != true) denied()
            }
        }
        check(owner, target.id.space)
    }
    private fun person(change: SynologyPhotoFaceChange): SynologyPhotoPersonSnapshot? = when (change) {
        is SynologyPhotoFaceChange.Add -> change.person
        is SynologyPhotoFaceChange.Reassign -> change.person
        is SynologyPhotoFaceChange.Remove -> null
    }
    private suspend fun verifyPerson(person: SynologyPhotoPersonSnapshot, owner: SynologyPhotosMutationAccess) {
        check(owner, person.space)
        val current = read("Browse.Person", 1, "get", json("id" to array(person.id)), person.space).list().singleOrNull() ?: changed()
        if (current.positive("id") != person.id || current.text("name") != person.name) changed()
        check(owner, person.space)
    }
    private fun rejected(error: Exception) = error is DsmFailure && error.code != null &&
        error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.INVALID_RESPONSE)
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
