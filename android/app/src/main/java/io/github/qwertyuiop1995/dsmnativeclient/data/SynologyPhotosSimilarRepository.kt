package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.intNumber
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** Similar 内部接口；分组变化与全部原件归组必须同时成立，未知提交绝不重放。 */
internal class SynologyPhotosSimilarRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val categoryAccess: (SynologyPhotoSpace) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val folderAccess: suspend (SynologyPhotoSpace, Long) -> SynologyPhotoFolderAccess,
    private val photoPending: (SynologyPhotoId) -> Boolean,
) {
    suspend fun detail(photo: SynologyPhoto): SynologyPhotoSimilarDetail {
        val group = photo.similarGroup ?: changed()
        if (photo.id.profileId != group.profileId || photo.id.space != group.space || photo.albumContext != null || photo.id.itemId !in group.photoIds) changed()
        val result = detail(group) ?: changed()
        if (photo.id.itemId !in result.group.photoIds) changed()
        return result
    }
    suspend fun detail(original: SynologyPhotoSimilarGroup): SynologyPhotoSimilarDetail? {
        val owner = identity(); validate(original, owner); check(owner, original.space)
        val group = current(original, owner) ?: return null
        return SynologyPhotoSimilarDetail(group, originals(group, owner))
    }
    private suspend fun originals(group: SynologyPhotoSimilarGroup, owner: SynologyPhotosMutationAccess): List<SynologyPhoto> {
        val entries = read("Browse.Item", 5, "get", json("id" to ids(group.photoIds),
            "additional" to array("folder", "thumbnail", "resolution", "orientation", "video_convert", "video_meta")), group.space).list()
        val photos = entries.map { SynologyPhotosCodec.photo(it, owner.profileId, group.space).copy(similarGroup = group) }
        if (photos.size != group.photoIds.size || photos.map { it.id.itemId }.toSet() != group.photoIds.toSet()) invalid()
        check(owner, group.space)
        val indexed = photos.associateBy { it.id.itemId }
        return group.photoIds.map { indexed.getValue(it) }
    }
    suspend fun status(space: SynologyPhotoSpace): SynologyPhotoSimilarStatus {
        val owner = identity(); check(owner, space)
        val raw = read("Browse.Similar", 1, "get_status", emptyMap(), space)
        val result = SynologyPhotoSimilarStatus(raw.intNumber("waiting_count"), raw.text("similar_clustering_stage"), raw.boolean("is_similar_hash_migration_done"))
        if (result.waitingCount < 0 || result.stage.isBlank()) invalid()
        check(owner, space)
        return result
    }
    suspend fun checkpoint(detail: SynologyPhotoSimilarDetail, edit: SynologyPhotoSimilarEdit, selected: List<Long>): SynologyPhotoAlbumCheckpoint {
        if (edit == SynologyPhotoSimilarEdit.UNDO) invalid()
        val owner = identity()
        val row = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = owner.userId, action = SynologyPhotoAlbumAction.EDIT_SIMILAR,
            targets = detail.photos.map(::SynologyPhotoEditTarget), similar = SynologyPhotoSimilarCheckpoint(detail.group, edit, selected))
        validatePhotoAlbumCheckpoint(row); prepare(row, owner)
        return row
    }
    suspend fun undo(original: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumCheckpoint {
        validatePhotoAlbumCheckpoint(original)
        val owner = identity(); val previous = original.similar ?: invalid()
        if (!previous.canUndo || original.userId != owner.userId || original.profileId != owner.profileId) changed()
        val row = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = owner.userId, action = SynologyPhotoAlbumAction.EDIT_SIMILAR,
            targets = original.targets, similar = SynologyPhotoSimilarCheckpoint(previous.group, SynologyPhotoSimilarEdit.UNDO,
                undo = SynologyPhotoSimilarUndo(original.operationId, previous.edit, previous.selectedIds, previous.resultingGroup)))
        validatePhotoAlbumCheckpoint(row); prepare(row, owner)
        return row
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        SynologyPhotoSimilarCodec.validate(row)
        val value = row.similar!!; val group = value.group
        validate(group, owner); freshAccess(owner, group.space)
        capability("Browse.Item", 5, group.space); capability("Browse.Folder", 2, group.space)
        val folders = mutableSetOf<Long>(); val originals = originals(group, owner).associateBy { it.id }
        for (target in row.targets) {
            if (photoPending(target.id) || !target.matches(originals[target.id] ?: changed())) changed()
            if (folders.add(target.folderId) && !folderAccess(group.space, target.folderId).canManage) denied()
        }
        val current = current(group, owner); val photos = memberships(row, owner)
        if (value.edit == SynologyPhotoSimilarEdit.UNDO) {
            val undo = value.undo!!
            if (!matches(group, undo.edit, undo.selectedIds, current, photos) ||
                !sameGroup(current, undo.resultingGroup) || photos.any { it.similarGroup?.id?.let { id -> id != group.id } == true }) changed()
        } else if (current?.sameMembers(group) != true || photos.any { it.similarGroup?.sameMembers(group) != true }) changed()
        freshAccess(owner, group.space)
    }
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        val value = input.similar!!; val group = value.group
        val row = input.copy(similar = value.copy(attempted = true))
        check(owner, group.space); persist(row); check(owner, group.space)
        val method: String
        val fields = when (value.edit) {
            SynologyPhotoSimilarEdit.TOP_PICK -> { method = "set_top_pick"; json("id" to group.id, "item_id" to value.selectedIds.single()) }
            SynologyPhotoSimilarEdit.REMOVE -> { method = "remove_item"; json("id" to group.id, "item_id" to ids(value.selectedIds)) }
            SynologyPhotoSimilarEdit.UNGROUP -> { method = "ungroup"; json("id" to ids(listOf(group.id))) }
            SynologyPhotoSimilarEdit.UNDO -> { method = "add_item"; json("id" to group.id, "item_id" to ids(group.photoIds), "top_pick" to group.topPickId) }
        }
        try { write("Browse.Similar", 1, method, fields, group.space) }
        catch (error: DsmFailure) {
            if (error.code != null && error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.INVALID_RESPONSE))
                persist(row.copy(similar = row.similar!!.copy(rejected = true)))
            throw error
        }
        return row
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val value = row.similar!!; val group = value.group
        if (!value.attempted || value.rejected) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
        freshAccess(owner, group.space)
        val current = current(group, owner); val photos = memberships(row, owner)
        val confirmed = matches(group, value.edit, value.selectedIds, current, photos)
        check(owner, group.space)
        return if (confirmed) row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, similar = value.copy(confirmed = true, resultingGroup = current))
            else row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
    }
    private fun matches(group: SynologyPhotoSimilarGroup, edit: SynologyPhotoSimilarEdit, selected: List<Long>,
        current: SynologyPhotoSimilarGroup?, photos: List<SynologyPhoto>): Boolean {
        if (!SynologyPhotoSimilarCodec.matchesResult(group, edit, selected, current)) return false
        return photos.all { photo ->
            if (current != null && photo.id.itemId in current.photoIds) photo.similarGroup?.sameMembers(current) == true
            else photo.similarGroup?.id != group.id
        }
    }
    private suspend fun current(original: SynologyPhotoSimilarGroup, owner: SynologyPhotosMutationAccess): SynologyPhotoSimilarGroup? {
        check(owner, original.space)
        val list = read("Browse.Similar", 1, "get", json("id" to ids(listOf(original.id))), original.space).list()
        if (list.size > 1 || list.any { it.positive("id") != original.id }) invalid()
        val result = list.singleOrNull()?.let { SynologyPhotoSimilarCodec.group(it, owner.profileId, original.space, allowDissolved = true) }
        check(owner, original.space)
        return result
    }
    private suspend fun memberships(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): List<SynologyPhoto> {
        val group = row.similar!!.group; check(owner, group.space)
        val entries = read("Browse.SimilarItem", 1, "get", json("id" to ids(group.photoIds),
            "additional" to array("thumbnail", "resolution", "orientation")), group.space).list()
        val photos = entries.map { item ->
            val photo = SynologyPhotosCodec.photo(item, owner.profileId, group.space)
            val membership = item.optionalObject("similar")?.let { SynologyPhotoSimilarCodec.group(it, owner.profileId, group.space, allowDissolved = true) }
            if (membership != null && photo.id.itemId !in membership.photoIds) invalid()
            photo.copy(similarGroup = membership)
        }
        if (photos.size != group.photoIds.size || photos.map { it.id.itemId }.toSet() != group.photoIds.toSet()) invalid()
        val indexed = photos.associateBy { it.id.itemId }
        val result = row.targets.map { target -> indexed.getValue(target.id.itemId).also { if (!target.matches(it)) changed() } }
        check(owner, group.space)
        return result
    }
    private suspend fun freshAccess(owner: SynologyPhotosMutationAccess, space: SynologyPhotoSpace) {
        check(owner, space)
        val me = read("UserInfo", 1, "me", emptyMap(), null)
        if (!me.boolean("enabled") || me.positive("id") != owner.userId) denied()
        val user = read("Setting.User", 1, "get", emptyMap(), null)
        val admin = read("Setting.Admin", 1, "get", emptyMap(), null)
        if (admin.optionalBoolean("enable_similar") == false) denied()
        if (space == SynologyPhotoSpace.PERSONAL) {
            if (!user.boolean("enable_home_service") || user.optionalBoolean("enable_similar") != true) denied()
        } else {
            val team = read("Setting.TeamSpace", 1, "get", emptyMap(), null)
            if (!owner.managesShared || user.text("team_space_permission") != "management" || !team.boolean("enabled") || team.optionalBoolean("enable_similar") != true) denied()
        }
        check(owner, space)
    }
    private suspend fun check(owner: SynologyPhotosMutationAccess, space: SynologyPhotoSpace) {
        currentCoroutineContext().ensureActive(); checkAccess(owner, space); categoryAccess(space)
    }
    private fun validate(group: SynologyPhotoSimilarGroup, owner: SynologyPhotosMutationAccess) {
        if (!SynologyPhotoSimilarCodec.valid(group) || group.profileId != owner.profileId) changed()
    }
    private fun sameGroup(a: SynologyPhotoSimilarGroup?, b: SynologyPhotoSimilarGroup?) = if (a == null) b == null else b?.let(a::sameMembers) == true
    private fun ids(values: List<Long>) = JsonArray(values.map(::JsonPrimitive))
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
