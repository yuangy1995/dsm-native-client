package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.security.MessageDigest
import kotlinx.serialization.json.*

internal object SynologyPhotoManualFacesCodec {
    fun faces(raw: JsonObject): List<SynologyPhotoFaceRegion> = raw.list().map { row ->
        val box = row.obj("face_bounding_box"); val start = box.obj("top_left"); val end = box.obj("bottom_right")
        fun coordinate(point: JsonObject, key: String) = (point[key] as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull ?: invalid()
        val x = coordinate(start, "x"); val y = coordinate(start, "y")
        val bounds = SynologyPhotoFaceBounds(x, y, coordinate(end, "x") - x, coordinate(end, "y") - y)
        val snapshot = SynologyPhotoFaceSnapshot(row.positive("face_id"), row.number("person_id"), row.text("name"), bounds)
        validateFace(snapshot)
        SynologyPhotoFaceRegion(snapshot, row.optionalObject("additional")?.optionalObject("thumbnail")?.text("cache_key"))
    }.also { if (it.map { face -> face.face.id }.distinct().size != it.size) invalid() }

    fun parameters(face: SynologyPhotoFaceChange.Add): JsonObject = JsonObject(json("face_id_temp" to face.temporaryId,
        "face_bounding_box" to JsonObject(json("top_left" to JsonObject(json("x" to face.bounds.x, "y" to face.bounds.y)),
            "bottom_right" to JsonObject(json("x" to face.bounds.x + face.bounds.width, "y" to face.bounds.y + face.bounds.height))))) +
        (face.person?.let { json("person_id" to it.id) } ?: json("name" to face.name)))

    fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    fun jpeg(bytes: ByteArray): Boolean = bytes.size >= 3 && bytes[0] == 0xff.toByte() && bytes[1] == 0xd8.toByte() && bytes[2] == 0xff.toByte()
    private fun validateFace(face: SynologyPhotoFaceSnapshot) {
        if (face.id <= 0 || face.personId < 0 || !face.bounds.valid) invalid()
    }
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.manualFaces ?: invalid(); val target = row.targets.singleOrNull() ?: invalid()
        if (row.action != SynologyPhotoAlbumAction.EDIT_PHOTO_FACES || row.album != null || row.name != null ||
            row.completed.isNotEmpty() || target.mediaType == "video" || value.changes.size !in 1..100 ||
            value.originals.map { it.id }.distinct().size != value.originals.size) invalid()
        value.originals.forEach(::validateFace)
        val keys = value.changes.map { it.key }.toSet()
        val additions = value.changes.filterIsInstance<SynologyPhotoFaceChange.Add>()
        val temps = additions.map { it.temporaryId }.toSet()
        val oldKeys = (value.changes - additions.toSet()).map { it.key }.toSet()
        val reassigned = value.changes.filterIsInstance<SynologyPhotoFaceChange.Reassign>().associateBy { it.key }
        if (keys.size != value.changes.size) invalid()
        fun person(person: SynologyPhotoPersonSnapshot?, name: String) {
            if (person == null && (name.isBlank() || name != name.trim()) || person?.let {
                it.id <= 0 || it.name != name || it.space != target.id.space || it.count?.let { count -> count < 0 } == true
            } == true) invalid()
        }
        for (change in value.changes) when (change) {
            is SynologyPhotoFaceChange.Add -> {
                if (change.temporaryId.isBlank() || !change.bounds.valid || !change.jpegDigest.matches(Regex("[0-9a-f]{64}"))) invalid()
                person(change.person, change.name)
            }
            is SynologyPhotoFaceChange.Remove -> {
                validateFace(change.original)
                if (value.originals.none(change.original::matches)) invalid()
            }
            is SynologyPhotoFaceChange.Reassign -> {
                validateFace(change.original)
                if (value.originals.none(change.original::matches) || change.person?.id == change.original.personId) invalid()
                person(change.person, change.name)
            }
        }
        if (value.addAttempted && additions.isEmpty() || value.addAcknowledged && (!value.addAttempted || value.addRejected) ||
            value.addRejected && (!value.addAttempted || value.newIds.isNotEmpty()) ||
            value.newIds.isNotEmpty() && !value.addAcknowledged || !temps.containsAll(value.newIds.keys) ||
            value.newIds.values.toSet().size != value.newIds.size || value.newIds.values.any { it <= 0 || value.originals.any { original -> original.id == it } } ||
            !value.newIds.values.containsAll(value.uploadAttempted) || !value.uploadAttempted.containsAll(value.uploaded) ||
            !oldKeys.containsAll(value.attempted) || !oldKeys.containsAll(value.acknowledged) ||
            !value.attempted.containsAll(value.acknowledged) || !keys.containsAll(value.rejected) ||
            value.rejected.any { key -> if (key in oldKeys) key !in value.attempted else
                additions.single { it.key == key }.temporaryId.let { value.newIds[it] !in value.uploadAttempted } } ||
            value.rejected.any { it in value.acknowledged } || value.uploaded.any { id ->
                additions.any { value.newIds[it.temporaryId] == id && it.key in value.rejected } } ||
            !reassigned.keys.containsAll(value.personReceipts.keys) || value.personReceipts.any { (key, id) ->
                key !in value.acknowledged || id <= 0 || reassigned.getValue(key).person?.id?.let { it != id } == true
            } || value.acknowledged.any { it in reassigned && it !in value.personReceipts } ||
            !keys.containsAll(value.completed) || !keys.containsAll(value.failed) || value.completed.intersect(value.failed).isNotEmpty() ||
            value.failed.any { key -> !knownFailure(value.changes.single { it.key == key }, value) } ||
            value.completed.intersect(value.rejected).isNotEmpty() || value.completed.any { key ->
                if (key in oldKeys) key !in value.attempted else value.newIds[additions.single { it.key == key }.temporaryId] !in value.uploadAttempted
            } || row.phase == SynologyPhotoAlbumPhase.COMPLETED && value.completed != keys ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && (value.failed.isEmpty() || value.completed + value.failed != keys)) invalid()
        if (!row.submitted && value != SynologyPhotoManualFacesCheckpoint(value.originals, value.changes)) invalid()
        if (value.attempted.isNotEmpty() && additions.any { value.newIds[it.temporaryId] !in value.uploaded }) invalid()
    }

    fun knownFailure(change: SynologyPhotoFaceChange, value: SynologyPhotoManualFacesCheckpoint): Boolean = change.key in value.rejected ||
        when (change) {
            is SynologyPhotoFaceChange.Add -> !value.addAttempted || value.addRejected ||
                value.addAcknowledged && value.newIds[change.temporaryId] == null ||
                value.newIds[change.temporaryId]?.let { it !in value.uploadAttempted } == true
            else -> change.key !in value.attempted
        }

    fun advances(old: SynologyPhotoManualFacesCheckpoint, next: SynologyPhotoManualFacesCheckpoint): Boolean = old.sameIntent(next) &&
        (!old.addAttempted || next.addAttempted) && (!old.addAcknowledged || next.addAcknowledged) && (!old.addRejected || next.addRejected) &&
        old.newIds.all { next.newIds[it.key] == it.value } && old.personReceipts.all { next.personReceipts[it.key] == it.value } &&
        next.uploadAttempted.containsAll(old.uploadAttempted) && next.uploaded.containsAll(old.uploaded) &&
        next.attempted.containsAll(old.attempted) && next.acknowledged.containsAll(old.acknowledged) && next.rejected.containsAll(old.rejected) &&
        next.completed.containsAll(old.completed) && next.failed.containsAll(old.failed)
}
