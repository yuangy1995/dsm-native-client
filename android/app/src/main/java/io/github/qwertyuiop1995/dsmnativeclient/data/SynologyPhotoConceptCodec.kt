package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalInt
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.JsonObject

internal object SynologyPhotoConceptCodec {
    fun page(raw: JsonObject, space: SynologyPhotoSpace, limit: Int, requireVisibility: Boolean): List<SynologyPhotoCollection> {
        val values = raw.list().map { entry ->
            val visible = entry.optionalBoolean("visibility")
            if (requireVisibility && visible == null) invalid()
            SynologyPhotoCollection(entry.positive("id"), entry.text("name"), space = space, conceptVisible = visible,
                count = entry.optionalInt("item_count")?.also { if (it < 0) invalid() },
                conceptDisplayThreshold = entry.optionalInt("display_threshold")?.also { if (it < 0) invalid() },
                thumbnail = SynologyPhotosCodec.thumbnail(entry.optionalObject("additional")?.optionalObject("thumbnail")))
        }
        if (values.size > limit || values.map { it.id }.distinct().size != values.size) invalid()
        return values
    }

    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.concept ?: invalid(); val ids = value.originals.map { it.id }.toSet()
        if (!row.action.isConcept || value.originals.size !in 1..100 || ids.size != value.originals.size ||
            value.originals.any { it.id <= 0 || it.space != value.space || it.visible == null ||
                it.count?.let { n -> n < 0 } == true || it.displayThreshold?.let { n -> n < 0 } == true ||
                (it.coverUnitId == null) != (it.coverRevision == null) || it.coverUnitId?.let { n -> n <= 0 } == true } ||
            row.album != null || row.name != null || row.completed.isNotEmpty() ||
            row.targets.any { it.id.space != value.space || it.albumContext != null }) invalid()
        when (row.action) {
            SynologyPhotoAlbumAction.SHOW_CONCEPTS -> if (value.visible == null || row.targets.isNotEmpty() ||
                value.originals.any { it.visible == value.visible } || value.removedPhotoIds.isNotEmpty()) invalid()
            SynologyPhotoAlbumAction.COVER_CONCEPT -> if (value.originals.size != 1 || value.visible != null ||
                row.targets.size != 1 || value.removedPhotoIds.isNotEmpty()) invalid()
            SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS -> if (value.originals.size != 1 || value.visible != null || row.targets.isEmpty() ||
                value.originals.single().count?.let { it >= row.targets.size } != true || value.originals.single().displayThreshold == null) invalid()
            else -> invalid()
        }
        val photoIds = row.targets.map { it.id.itemId }.toSet()
        val removes = row.action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS
        val updatedIds = value.updated.map { it.id }.toSet()
        if (updatedIds.size != value.updated.size || !ids.containsAll(updatedIds) ||
            value.updated.any { it.space != value.space || it.visible == null || it.count?.let { n -> n < 0 } == true ||
                it.displayThreshold?.let { n -> n < 0 } == true || (it.coverUnitId == null) != (it.coverRevision == null) || it.coverUnitId?.let { n -> n <= 0 } == true } ||
            value.updated.isNotEmpty() && (!value.attempted || value.rejected || !row.finished) ||
            row.finished && (value.completedIds.isNotEmpty() || value.removedPhotoIds.isNotEmpty()) &&
                updatedIds != (if (removes) ids else value.completedIds)) invalid()
        if (value.updated.any { when (row.action) {
                SynologyPhotoAlbumAction.SHOW_CONCEPTS -> it.visible != value.visible
                SynologyPhotoAlbumAction.COVER_CONCEPT -> it.coverUnitId != row.targets.single().id.itemId
                SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS -> it.count == null || it.displayThreshold == null
                else -> true
            } }) invalid()
        if (!row.submitted && (value.attempted || value.acknowledged || value.rejected || value.completedIds.isNotEmpty() || value.removedPhotoIds.isNotEmpty()) ||
            value.acknowledged && (!value.attempted || value.rejected) || value.rejected && (!value.attempted || value.completedIds.isNotEmpty() || value.removedPhotoIds.isNotEmpty()) ||
            (value.completedIds.isNotEmpty() || value.removedPhotoIds.isNotEmpty()) && !value.attempted ||
            !ids.containsAll(value.completedIds) || !photoIds.containsAll(value.removedPhotoIds) ||
            removes && ((value.completedIds == ids) != (value.removedPhotoIds == photoIds)) ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && value.completedIds != ids ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && value.attempted && !value.rejected &&
                (!value.acknowledged || value.completedIds == ids || if (removes) value.removedPhotoIds.isEmpty() else value.completedIds.isEmpty())) invalid()
    }

    fun advances(old: SynologyPhotoConceptCheckpoint, next: SynologyPhotoConceptCheckpoint): Boolean = old.sameIntent(next) &&
        (!old.attempted || next.attempted) && (!old.acknowledged || next.acknowledged) && (!old.rejected || next.rejected) &&
        next.completedIds.containsAll(old.completedIds) && next.removedPhotoIds.containsAll(old.removedPhotoIds) &&
        (old.updated.isEmpty() || old.updated == next.updated)
}
