package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import java.util.UUID

internal fun photoEditTimestamp(edit: SynologyPhotoEdit, target: SynologyPhotoEditTarget): Long {
    val value = when (edit) {
        is SynologyPhotoEdit.TakenAt -> edit.seconds
        is SynologyPhotoEdit.ShiftDates -> {
            if (!target.takenAt.isFinite() || target.takenAt < 0 || target.takenAt > (Long.MAX_VALUE / 2).toDouble()) invalid()
            try { Math.addExact(target.takenAt.toLong(), edit.seconds) } catch (_: ArithmeticException) { invalid() }
        }
        else -> invalid()
    }
    if (value < 0 || value > Long.MAX_VALUE / 2) invalid()
    return value
}

internal fun validatePhotoEditCheckpoint(row: SynologyPhotoEditCheckpoint) {
    if (row.version != 1 || row.profileId.isBlank() || row.userId <= 0 ||
        runCatching { UUID.fromString(row.operationId).toString() != row.operationId }.getOrDefault(true) ||
        row.targets.size > 100 || row.targets.map { it.id }.distinct().size != row.targets.size ||
        row.targets.isEmpty() && row.edit !is SynologyPhotoEdit.CreateTag) invalid()
    row.targets.forEach { target ->
        if (target.id.profileId != row.profileId || target.id.itemId <= 0 || target.folderId <= 0 ||
            target.filename.isBlank() || target.sizeBytes < 0 || !target.takenAt.isFinite() || !target.indexedAt.isFinite() ||
            target.mediaType.isBlank() || !row.permitsMixedSpaces && target.id.space != row.space) invalid()
        target.albumContext?.let { context ->
            if (context.albumId <= 0 || context.ownerUserId < 0 || context.providerUserId?.let { it < 0 } == true ||
                target.id.space != if (context.ownerUserId == 0L) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL) invalid()
        }
    }
    when (val edit = row.edit) {
        is SynologyPhotoEdit.Rotation -> {
            val target = row.targets.singleOrNull() ?: invalid()
            if (!target.photo().copy(orientation = edit.orientation).supportsRotation ||
                edit.width?.let { it <= 0 } == true || edit.height?.let { it <= 0 } == true ||
                row.completed.any { it in row.reportedFailures }) invalid()
        }
        is SynologyPhotoEdit.Rating -> if (edit.value !in 0..5) invalid()
        is SynologyPhotoEdit.Description -> Unit
        is SynologyPhotoEdit.TakenAt, is SynologyPhotoEdit.ShiftDates -> {
            if (edit is SynologyPhotoEdit.ShiftDates && edit.seconds == 0L) invalid()
            row.targets.forEach { photoEditTimestamp(edit, it) }
        }
        is SynologyPhotoEdit.CreateTag -> if (edit.name.isBlank() || row.createdTag?.let { it.id <= 0 || it.name != edit.name } == true) invalid()
        is SynologyPhotoEdit.AddTags, is SynologyPhotoEdit.RemoveTags -> {
            val ids = if (edit is SynologyPhotoEdit.AddTags) edit.ids else (edit as SynologyPhotoEdit.RemoveTags).ids
            if (ids.isEmpty() || ids.any { it <= 0 } || ids.distinct().size != ids.size) invalid()
        }
    }
    if (row.edit !is SynologyPhotoEdit.CreateTag && row.createdTag != null ||
        row.attempted.any { it !in row.targets.indices } || !row.attempted.containsAll(row.completed) ||
        !row.attempted.containsAll(row.reportedFailures) ||
        row.edit is SynologyPhotoEdit.CreateTag && row.attempted.isNotEmpty() && row.createdTag == null) invalid()
    if (!row.submitted && (row.attempted.isNotEmpty() || row.createdTag != null) ||
        row.submitted && row.edit !is SynologyPhotoEdit.CreateTag && row.attempted.isEmpty() ||
        row.phase == SynologyPhotoEditPhase.COMPLETED && (row.completed.size != row.targets.size ||
            row.edit is SynologyPhotoEdit.CreateTag && row.createdTag == null) ||
        row.phase == SynologyPhotoEditPhase.PARTIAL && (row.completed.size == row.targets.size ||
            row.attempted.any { it !in row.completed && it !in row.reportedFailures } ||
            row.edit is SynologyPhotoEdit.CreateTag && row.createdTag == null)) invalid()
}

internal fun photoEditsConflict(previous: SynologyPhotoEditCheckpoint, next: SynologyPhotoEditCheckpoint): Boolean =
    previous.operationId != next.operationId && previous.profileId == next.profileId && previous.userId == next.userId &&
        previous.submitted && !previous.finished && (previous.targets.any { a -> next.targets.any { b -> a.id == b.id } } ||
        previous.edit is SynologyPhotoEdit.CreateTag && next.edit == previous.edit && next.space == previous.space)
