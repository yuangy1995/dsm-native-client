package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.intNumber
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import java.util.UUID
import kotlinx.serialization.json.*

internal object SynologyPhotoSimilarCodec {
    fun group(raw: JsonObject, profileId: String, space: SynologyPhotoSpace, allowDissolved: Boolean = false): SynologyPhotoSimilarGroup? {
        val id = raw.positive("id"); val count = raw.intNumber("count"); val top = raw.number("top_pick")
        val ids = (raw["item_id"] as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> !p.isString }?.longOrNull ?: invalid() } ?: invalid()
        if (count < 0 || count != ids.size || ids.distinct().size != ids.size || ids.any { it <= 0 }) invalid()
        if (count < 2) { if (allowDissolved) return null else invalid() }
        if (top !in ids) invalid()
        return SynologyPhotoSimilarGroup(profileId, space, id, ids, top)
    }
    fun valid(group: SynologyPhotoSimilarGroup) = group.profileId.isNotBlank() && group.id > 0 && group.photoIds.size >= 2 &&
        group.photoIds.all { it > 0 } && group.photoIds.distinct().size == group.photoIds.size && group.topPickId in group.photoIds

    fun matchesResult(original: SynologyPhotoSimilarGroup, edit: SynologyPhotoSimilarEdit, selected: List<Long>, result: SynologyPhotoSimilarGroup?): Boolean {
        if (result != null && (!valid(result) || result.profileId != original.profileId || result.space != original.space || result.id != original.id)) return false
        return when (edit) {
            SynologyPhotoSimilarEdit.TOP_PICK -> result != null && result.photoIds.toSet() == original.photoIds.toSet() && result.topPickId == selected.singleOrNull()
            SynologyPhotoSimilarEdit.REMOVE -> (original.photoIds.toSet() - selected.toSet()).let { remaining ->
                if (remaining.size < 2) result == null else result != null && result.photoIds.toSet() == remaining }
            SynologyPhotoSimilarEdit.UNGROUP -> result == null
            SynologyPhotoSimilarEdit.UNDO -> result?.sameMembers(original) == true
        }
    }
    private fun validateEdit(group: SynologyPhotoSimilarGroup, edit: SynologyPhotoSimilarEdit, selected: List<Long>) {
        if (selected.distinct().size != selected.size || !group.photoIds.containsAll(selected)) invalid()
        when (edit) {
            SynologyPhotoSimilarEdit.TOP_PICK -> if (selected.size != 1 || selected.single() == group.topPickId) invalid()
            SynologyPhotoSimilarEdit.REMOVE -> if (selected.isEmpty()) invalid()
            SynologyPhotoSimilarEdit.UNGROUP, SynologyPhotoSimilarEdit.UNDO -> if (selected.isNotEmpty()) invalid()
        }
    }
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.similar ?: invalid(); val group = value.group
        if (row.action != SynologyPhotoAlbumAction.EDIT_SIMILAR || !valid(group) || group.profileId != row.profileId ||
            row.album != null || row.name != null || row.completed.isNotEmpty() || row.targets.size != group.photoIds.size ||
            row.targets.map { it.id.itemId }.toSet() != group.photoIds.toSet() || row.targets.any { it.id.space != group.space || it.albumContext != null }) invalid()
        if (value.batchOrder.isNotEmpty() && (value.batchOrder.size !in 2..100 || value.batchOrder.distinct().size != value.batchOrder.size ||
            row.operationId !in value.batchOrder || value.batchOrder.any { runCatching { UUID.fromString(it).toString() != it }.getOrDefault(true) } ||
            value.edit !in setOf(SynologyPhotoSimilarEdit.UNGROUP, SynologyPhotoSimilarEdit.UNDO))) invalid()
        validatePhotoAlbumTargets(row.targets, row.profileId)
        validateEdit(group, value.edit, value.selectedIds)
        if ((value.edit == SynologyPhotoSimilarEdit.UNDO) != (value.undo != null)) invalid()
        value.undo?.let { undo ->
            if (runCatching { UUID.fromString(undo.operationId).toString() != undo.operationId }.getOrDefault(true) || undo.operationId == row.operationId ||
                undo.edit !in setOf(SynologyPhotoSimilarEdit.REMOVE, SynologyPhotoSimilarEdit.UNGROUP)) invalid()
            validateEdit(group, undo.edit, undo.selectedIds)
            if (!matchesResult(group, undo.edit, undo.selectedIds, undo.resultingGroup)) invalid()
        }
        if (!row.submitted && (value.attempted || value.rejected || value.confirmed) || value.rejected && (!value.attempted || value.confirmed) ||
            value.confirmed && (!value.attempted || !matchesResult(group, value.edit, value.selectedIds, value.resultingGroup)) ||
            !value.confirmed && value.resultingGroup != null ||
            (row.phase == SynologyPhotoAlbumPhase.COMPLETED) != value.confirmed ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && value.attempted && !value.rejected) invalid()
    }
    fun advances(old: SynologyPhotoSimilarCheckpoint, next: SynologyPhotoSimilarCheckpoint) = old.sameIntent(next) &&
        (!old.attempted || next.attempted) && (!old.rejected || next.rejected) &&
        (!old.confirmed || next.confirmed && old.resultingGroup == next.resultingGroup)
}
