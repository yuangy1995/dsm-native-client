package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid

internal object SynologyPhotoAutomaticPreviewCodec {
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.automaticPreview ?: invalid()
        val task = value.task
        if (row.album != null || row.name != null || task.profileId != row.profileId || task.unitId <= 0 || task.filename.isBlank() ||
            task.typeCode < 0 || !task.needsThumbnail && !task.needsVideo || task.needsVideo && (!task.video || !value.support.video) ||
            !value.support.available || task.sourceThumbnailUnitId?.let { it <= 0 } == true ||
            task.source == null && task.sourceThumbnailUnitId != null || row.targets != listOfNotNull(task.source) ||
            task.source?.let { it.id.profileId != row.profileId || it.id.space != task.space } == true) invalid()
        val digests = value.thumbnailDigests
        if (digests.isNotEmpty() && (!task.needsThumbnail || digests.keys != setOf("xl", "sm", "m") ||
                digests.values.any { !it.matches(Regex("[0-9a-f]{64}")) }) ||
            (digests.isNotEmpty() || value.videoSignature != null) && !value.uploadAttempted ||
            value.videoSignature?.let { !task.needsVideo || !it.valid() } == true ||
            value.uploadAttempted && (task.needsThumbnail && digests.isEmpty() || task.needsVideo && value.videoSignature == null) ||
            (value.uploadAcknowledged || value.uploadRejected) && !value.uploadAttempted || value.uploadAcknowledged && value.uploadRejected ||
            value.failureKind != null && (value.uploadAttempted || digests.isNotEmpty() || value.videoSignature != null) ||
            value.failureKind == SynologyPhotoAutomaticPreviewFailure.PHOTO && !task.needsThumbnail ||
            value.failureKind == SynologyPhotoAutomaticPreviewFailure.VIDEO && !task.needsVideo ||
            (value.failureRecorded || value.failureRejected) && value.failureKind == null || value.failureRecorded && value.failureRejected ||
            !row.submitted && (value != SynologyPhotoAutomaticPreviewCheckpoint(task, value.support) || row.completed.isNotEmpty())) invalid()
        if (row.completed.any { it != 0 } || row.completed.isNotEmpty() && (!value.uploadAttempted || value.uploadRejected) ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && row.completed != setOf(0) ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && (row.completed.isNotEmpty() || value.uploadAcknowledged ||
                value.uploadAttempted && !value.uploadRejected || value.failureKind != null && !value.failureRecorded && !value.failureRejected)) invalid()
    }

    fun advances(old: SynologyPhotoAutomaticPreviewCheckpoint, fresh: SynologyPhotoAutomaticPreviewCheckpoint) =
        old.sameIntent(fresh) && (!old.uploadAttempted || fresh.uploadAttempted) &&
            (!old.uploadAcknowledged || fresh.uploadAcknowledged) && (!old.uploadRejected || fresh.uploadRejected) &&
            (!old.failureRecorded || fresh.failureRecorded) && (!old.failureRejected || fresh.failureRejected) &&
            (old.failureKind == null || old.failureKind == fresh.failureKind) &&
            (old.thumbnailDigests.isEmpty() || old.thumbnailDigests == fresh.thumbnailDigests) &&
            (old.videoSignature == null || old.videoSignature == fresh.videoSignature)
}
