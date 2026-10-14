package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalInt
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalLong
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.JsonObject

internal object SynologyPhotoPeopleCodec {
    fun page(raw: JsonObject, space: SynologyPhotoSpace, limit: Int, requireVisibility: Boolean): List<SynologyPhotoCollection> {
        val people = raw.list().map { entry ->
            val id = entry.positive("id")
            val cover = entry.optionalObject("additional")?.optionalObject("thumbnail")?.let {
                val unit = it.optionalLong("unit_id")?.also { value -> if (value <= 0) invalid() }
                SynologyPhotoPersonCover(unit ?: id, it.text("cache_key"),
                    if (unit == null) SynologyPhotoPersonCover.Type.PERSON else SynologyPhotoPersonCover.Type.UNIT)
            }
            val shown = entry.optionalBoolean("show")
            if (requireVisibility && shown == null) invalid()
            SynologyPhotoCollection(id, entry.text("name"), count = entry.optionalInt("item_count")?.also { if (it < 0) invalid() },
                space = space, personVisible = shown, personCover = cover)
        }
        if (people.size > limit || people.map { it.id }.distinct().size != people.size) invalid()
        return people
    }

    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.people ?: invalid(); val originals = value.originals; val ids = originals.map { it.id }.toSet()
        if (!row.action.isPeople || originals.size !in 1..100 || ids.size != originals.size ||
            originals.any { it.id <= 0 || it.count?.let { count -> count < 0 } == true || it.space != value.space } ||
            row.album != null || row.name != null || (!row.action.isPersonFaces && row.targets.isNotEmpty()) || row.completed.isNotEmpty()) invalid()
        if (row.action.isPersonFaces) SynologyPhotoPersonFacesCodec.validate(row) else if (value.faces != null) invalid()
        when (row.action) {
            SynologyPhotoAlbumAction.RENAME_PERSON -> if (originals.size != 1 || value.name == null || value.name == originals.single().name ||
                value.visible != null || value.memberIds != null) invalid()
            SynologyPhotoAlbumAction.MERGE_PEOPLE -> if (originals.size < 2 || value.name == null || value.visible != null ||
                value.memberIds == null || value.memberIds.any { it <= 0 }) invalid()
            SynologyPhotoAlbumAction.SHOW_PEOPLE -> if (value.visible == null || value.name != null || value.memberIds != null ||
                originals.any { it.visible == null || it.visible == value.visible }) invalid()
            SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, SynologyPhotoAlbumAction.COVER_PERSON -> Unit
            else -> invalid()
        }
        if (!row.submitted && (value.attempted || value.acknowledged || value.rejected || value.nameReceipt || value.completedIds.isNotEmpty() || value.removedIds.isNotEmpty()) ||
            value.acknowledged && (!value.attempted || value.rejected) || value.rejected && (!value.attempted || value.completedIds.isNotEmpty()) ||
            value.nameReceipt && (!value.acknowledged || row.action != SynologyPhotoAlbumAction.RENAME_PERSON) ||
            row.action == SynologyPhotoAlbumAction.RENAME_PERSON && value.acknowledged != value.nameReceipt ||
            !ids.containsAll(value.completedIds) || !value.completedIds.containsAll(value.removedIds) ||
            value.completedIds.isNotEmpty() && !value.attempted ||
            row.action != SynologyPhotoAlbumAction.SHOW_PEOPLE && value.completedIds.isNotEmpty() && value.completedIds != ids ||
            row.action == SynologyPhotoAlbumAction.SHOW_PEOPLE && value.removedIds.isNotEmpty() ||
            row.action == SynologyPhotoAlbumAction.MERGE_PEOPLE && originals.first().id in value.removedIds ||
            row.action == SynologyPhotoAlbumAction.RENAME_PERSON && value.removedIds.isNotEmpty() &&
                (value.name != "" || originals.single().count?.let { it < 2 } != true || !value.nameReceipt) ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && value.completedIds != ids ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && value.attempted && !value.rejected &&
                (row.action != SynologyPhotoAlbumAction.SHOW_PEOPLE || !value.acknowledged || value.completedIds.isEmpty() || value.completedIds == ids)) invalid()
    }

    fun advances(old: SynologyPhotoPeopleCheckpoint, next: SynologyPhotoPeopleCheckpoint): Boolean = old.sameIntent(next) &&
        (!old.attempted || next.attempted) && (!old.acknowledged || next.acknowledged) && (!old.rejected || next.rejected) &&
        (!old.nameReceipt || next.nameReceipt) && next.completedIds.containsAll(old.completedIds) && next.removedIds.containsAll(old.removedIds) &&
        (old.faces?.let { before -> next.faces?.let { after ->
            (before.targetReceipt == null || before.targetReceipt == after.targetReceipt) &&
            (before.coverReceipt == null || before.coverReceipt == after.coverReceipt) && after.removedPhotoIds.containsAll(before.removedPhotoIds)
        } == true } ?: (next.faces == null))
}
