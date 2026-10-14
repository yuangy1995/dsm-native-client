package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoPreviewFact.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.JsonObject

internal object SynologyPhotoPreviewRegenerationCodec {
    data class Queued(val id: Long, val filename: String, val type: String) {
        fun matches(target: SynologyPhotoEditTarget) = id == target.id.itemId && filename == target.filename && type == target.mediaType
        override fun toString() = "PhotoPreviewQueued"
    }
    fun queue(value: JsonObject): List<Queued> = value.list().map { row ->
        Queued(row.positive("unit_id"), row.text("filename").takeIf { it.isNotEmpty() } ?: invalid(),
            row.text("type").takeIf { it in setOf("photo", "video", "live") } ?: invalid())
    }.also { if (it.map { row -> row.id }.distinct().size != it.size) invalid() }

    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.previews ?: invalid()
        if (row.album != null || row.name != null || row.targets.isEmpty() || row.targets.size > 100 ||
            row.targets.map { it.id }.distinct().size != row.targets.size || value.progress.size != row.targets.size) invalid()
        row.targets.forEach { target ->
            if (target.id.profileId != row.profileId || target.id.itemId <= 0 || target.folderId <= 0 || target.filename.isBlank() ||
                target.sizeBytes < 0 || !target.takenAt.isFinite() || !target.indexedAt.isFinite() || target.mediaType.isBlank()) invalid()
            target.albumContext?.let { context ->
                if (context.albumId <= 0 || context.ownerUserId < 0 || context.providerUserId?.let { it < 0 } == true ||
                    (context.ownerUserId == 0L) != (target.id.space == SynologyPhotoSpace.SHARED)) invalid()
            }
        }
        value.progress.forEach { state ->
            if ((state.baselineUnitId == null) != (state.baselineRevision == null) || state.baselineUnitId?.let { it <= 0 } == true ||
                !row.submitted && state.facts.isNotEmpty() ||
                MARKED in state && !value.resuming && MARK_ATTEMPTED !in state ||
                value.resuming && (MARK_ATTEMPTED in state || MARK_REJECTED in state) ||
                MARK_REJECTED in state && (MARK_ATTEMPTED !in state || MARKED in state) ||
                state.submitted && MARKED !in state || LOCAL_REJECTED in state && LOCAL_ATTEMPTED !in state ||
                (NAS_REJECTED in state || NAS_FAILED in state) && NAS_ATTEMPTED !in state || NAS_REJECTED in state && NAS_FAILED in state ||
                LOCAL_ATTEMPTED in state && NAS_ATTEMPTED in state && LOCAL_REJECTED !in state && NAS_REJECTED !in state && NAS_FAILED !in state ||
                RESTORE_ATTEMPTED in state && (!state.submitted || state.unknownSubmission || state.generated) ||
                RESTORED in state && RESTORE_ATTEMPTED !in state || state.generated && (!state.submitted || state.failed) ||
                state.generated && (LOCAL_ATTEMPTED !in state || LOCAL_REJECTED in state) &&
                    (NAS_ATTEMPTED !in state || NAS_REJECTED in state || NAS_FAILED in state) ||
                RECOVERED in state && (!state.generated || state.baselineUnitId == null || state.baselineRevision.isNullOrEmpty()) ||
                state.failed && (state.unknownSubmission || RESTORE_ATTEMPTED in state && RESTORED !in state ||
                    MARK_ATTEMPTED in state && MARKED !in state && MARK_REJECTED !in state)) invalid()
        }
        if (row.completed.any { it !in row.targets.indices || !value.progress[it].generated } ||
            !row.submitted && row.completed.isNotEmpty()) invalid()
        val resolved = value.progress.indices.all { it in row.completed || value.progress[it].failed }
        if (row.phase == SynologyPhotoAlbumPhase.COMPLETED && row.completed.size != row.targets.size ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && (!resolved || value.progress.none { it.failed })) invalid()
    }

    fun advances(old: SynologyPhotoPreviewRegeneration, fresh: SynologyPhotoPreviewRegeneration) = old.sameIntent(fresh) &&
        old.progress.zip(fresh.progress).all { (a, b) -> b.facts.containsAll(a.facts) }
}
