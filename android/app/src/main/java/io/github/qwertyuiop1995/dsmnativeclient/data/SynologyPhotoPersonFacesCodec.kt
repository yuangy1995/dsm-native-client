package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid

/** 人脸整理复用人物记录，只允许来源、目标和原件之间已固定的对应关系。 */
internal object SynologyPhotoPersonFacesCodec {
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val people = row.people ?: invalid(); val faces = people.faces ?: invalid()
        val original = people.originals.first(); val targets = row.targets.map { it.id }.toSet()
        val moving = row.action == SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES
        val covering = row.action == SynologyPhotoAlbumAction.COVER_PERSON
        if (row.targets.isEmpty() || row.targets.any { it.id.space != original.space || it.albumContext != null } ||
            people.visible != null || people.memberIds != null || people.nameReceipt ||
            people.originals.size !in 1..(if (moving) 2 else 1) ||
            moving && people.originals.getOrNull(1)?.name?.let { it != people.name } == true || (moving != (people.name != null)) ||
            faces.selected.map { it.id }.distinct().size != faces.selected.size ||
            faces.selected.any { it.id <= 0 || it.photoId !in targets } ||
            covering && (row.targets.size != 1 || faces.selected.isNotEmpty()) ||
            !covering && (faces.selected.isEmpty() || faces.selected.map { it.photoId }.toSet() != targets) ||
            faces.targetReceipt?.let { !moving || !people.acknowledged || it <= 0 || it == original.id ||
                people.originals.getOrNull(1)?.id?.let { target -> target != it } == true } == true ||
            faces.coverReceipt?.let { !covering || !people.acknowledged || it <= 0 } == true ||
            moving && people.acknowledged && faces.targetReceipt == null ||
            covering && people.acknowledged && faces.coverReceipt == null ||
            !row.targets.map { it.id.itemId }.toSet().containsAll(faces.removedPhotoIds) ||
            faces.removedPhotoIds.isNotEmpty() && (covering || people.completedIds.isEmpty()) ||
            people.removedIds.any { it != original.id } || covering && people.removedIds.isNotEmpty() ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED &&
                (covering && faces.coverReceipt == null || moving && people.originals.size == 1 && faces.targetReceipt == null)) invalid()
    }
}
