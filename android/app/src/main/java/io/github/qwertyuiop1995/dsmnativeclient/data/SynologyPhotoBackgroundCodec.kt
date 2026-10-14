package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.decimal
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.JsonObject

internal object SynologyPhotoBackgroundCodec {
    fun tasks(raw: JsonObject, profileId: String, userId: Long): List<SynologyPhotoBackgroundTask> {
        val result = raw.list().map { row ->
            val target = row.optionalObject("target_folder")
            val status = row.text("status")
            val snapshot = SynologyPhotoBackgroundSnapshot(row.positive("id"), row.text("operation"),
                SynologyPhotoBackgroundStatus.entries.firstOrNull { it.value == status } ?: SynologyPhotoBackgroundStatus.UNKNOWN,
                row.number("total"), row.decimal("create_time"), target?.positive("id"), target?.number("owner_user_id"))
            validate(snapshot)
            SynologyPhotoBackgroundTask(profileId, userId, snapshot, row.number("completion"), row.number("error"),
                row.number("skip"), row.number("overwrite")).also {
                if (it.completion !in 0..snapshot.total || it.errors !in 0..it.completion ||
                    it.skipped !in 0..snapshot.total || it.overwritten !in 0..snapshot.total) invalid()
            }
        }
        if (result.map { it.id }.distinct().size != result.size) invalid()
        return result
    }

    fun errors(raw: JsonObject): List<SynologyPhotoBackgroundError> {
        val result = raw.list().map { row ->
            val type = row.text("type"); val reason = row.text("reason")
            SynologyPhotoBackgroundError(SynologyPhotoBackgroundError.Kind.entries.firstOrNull { it.value == type } ?: SynologyPhotoBackgroundError.Kind.UNKNOWN,
                row.positive("id"), SynologyPhotoBackgroundError.Reason.entries.firstOrNull { it.value == reason } ?: SynologyPhotoBackgroundError.Reason.UNKNOWN)
        }
        if (result.map { it.key }.distinct().size != result.size) invalid()
        return result
    }

    fun validate(snapshot: SynologyPhotoBackgroundSnapshot) {
        if (snapshot.id <= 0 || snapshot.total < 0 || snapshot.operation.isBlank() || !snapshot.createdAt.isFinite() || snapshot.createdAt < 0 ||
            (snapshot.targetFolderId == null) != (snapshot.targetOwnerId == null) || snapshot.targetFolderId?.let { it <= 0 } == true ||
            snapshot.targetOwnerId?.let { it < 0 } == true) invalid()
    }

    fun validate(value: SynologyPhotoBackgroundCheckpoint, clearing: Boolean, phase: SynologyPhotoAlbumPhase) {
        val ids = value.tasks.map { it.id }.toSet()
        value.tasks.forEach(::validate)
        if (ids.isEmpty() || ids.size != value.tasks.size ||
            (if (clearing) value.tasks.any { !it.canClear } else value.tasks.size != 1 || !value.tasks.single().canStop) ||
            !ids.containsAll(value.attempted) || !value.attempted.containsAll(value.rejected) || !value.attempted.containsAll(value.completed) ||
            value.completed.intersect(value.rejected).isNotEmpty() ||
            phase == SynologyPhotoAlbumPhase.READY && (value.attempted.isNotEmpty() || value.rejected.isNotEmpty() || value.completed.isNotEmpty()) ||
            phase == SynologyPhotoAlbumPhase.COMPLETED && value.completed != ids ||
            phase == SynologyPhotoAlbumPhase.PARTIAL && (value.completed == ids || (value.attempted - value.rejected - value.completed).isNotEmpty())) invalid()
    }
}
