package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

/** 已有内部资料/标签契约的仓储分支；写入意图先落盘，已提交操作只回读。 */
internal class SynologyPhotosEditRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val details: suspend (SynologyPhoto) -> SynologyPhoto,
    private val deletionPending: (SynologyPhotoId) -> Boolean,
) {
    private val mutex = Mutex()
    private val operations = mutableMapOf<String, SynologyPhotoEditCheckpoint>()
    private val acknowledgedRotations = mutableSetOf<String>()

    fun pending(photo: SynologyPhotoId): Boolean = operations.values.any { row ->
        row.submitted && !row.finished && row.targets.any { it.id == photo }
    }

    suspend fun tags(space: SynologyPhotoSpace, offset: Int, limit: Int): List<SynologyPhotoChoice> {
        if (offset < 0 || limit !in 1..500 || offset > Int.MAX_VALUE - limit) invalid()
        val page = read("Browse.GeneralTag", 1, "list", json("offset" to offset, "limit" to limit,
            "additional" to array("thumbnail")), space).list().map { SynologyPhotoChoice(it.positive("id"), it.text("name")) }
        if (page.size > limit || page.map { it.id }.distinct().size != page.size) invalid()
        return page
    }

    suspend fun prepare(row: SynologyPhotoEditCheckpoint) = prepare(row, identity())

    private suspend fun prepare(row: SynologyPhotoEditCheckpoint, owner: SynologyPhotosMutationAccess) {
        validatePhotoEditCheckpoint(row)
        requireOwner(row, owner)
        val spaces = row.targets.mapTo(mutableSetOf(row.space)) { it.id.space }
        if (spaces.size > 1 && (!row.permitsMixedSpaces || !owner.managesShared)) denied()
        for (space in spaces) {
            checkAccess(owner, space)
            capability("Browse.Item", 5, space); capability("Browse.Folder", 2, space)
            capability("Browse.Item", if (row.edit is SynologyPhotoEdit.AddTags || row.edit is SynologyPhotoEdit.RemoveTags ||
                row.edit is SynologyPhotoEdit.CreateTag) 1 else 2, space)
            if (row.edit is SynologyPhotoEdit.CreateTag) capability("Browse.GeneralTag", 1, space)
        }
        val albumPhotos = mutableListOf<SynologyPhoto>()
        for (target in row.targets) {
            if (deletionPending(target.id)) denied()
            val current = details(target.photo())
            if (!target.matches(current, includeTime = true)) changed()
            (row.edit as? SynologyPhotoEdit.Rotation)?.let {
                if (!current.supportsRotation || current.orientation != it.orientation || current.width != it.width || current.height != it.height) changed()
            }
            val context = target.albumContext
            if (context == null) {
                val folder = read("Browse.Folder", 2, "get", json("id" to target.folderId,
                    "additional" to array("access_permission")), target.id.space).obj("folder")
                if (folder.positive("id") != target.folderId) changed()
                val rights = folder.optionalObject("additional")?.optionalObject("access_permission")
                if (!(target.id.space == SynologyPhotoSpace.SHARED && owner.managesShared) &&
                    (rights?.permission("view") != true || !rights.permission("manage"))) denied()
            } else {
                albumPhotos += current
                if (target.id.space == SynologyPhotoSpace.SHARED) { if (!owner.managesShared) denied() }
                else if (current.albumContext?.providerUserId != owner.userId) {
                    if (context.ownerUserId != owner.userId) denied()
                    val album = album(context.albumId)
                    if (album.number("owner_user_id") != owner.userId ||
                        album.text("type") != "condition" && album.optionalBoolean("freeze_album") != true) denied()
                }
            }
            checkAccess(owner, target.id.space)
        }
        if (spaces.size > 1) for (albumId in albumPhotos.mapNotNull { it.albumContext?.albumId }.distinct()) {
            val album = album(albumId)
            if (album.number("owner_user_id") != owner.userId && albumPhotos.filter { it.albumContext?.albumId == albumId }
                    .any { it.albumContext?.providerUserId != owner.userId }) denied()
        }
        checkAccess(owner, row.space)
    }

    suspend fun perform(input: SynologyPhotoEditCheckpoint, save: (SynologyPhotoEditCheckpoint) -> Unit): SynologyPhotoEditCheckpoint =
        withContext(Dispatchers.IO) { mutex.withLock {
            val owner = identity()
            var row = select(input, owner)
            if (row.submitted) return@withLock reviewLocked(row, owner, save)
            prepare(row, owner)
            currentCoroutineContext().ensureActive()
            if (row.edit is SynologyPhotoEdit.CreateTag) {
                row = row.copy(phase = SynologyPhotoEditPhase.SUBMITTING)
                persist(row, save)
                row = try {
                    checkAccess(owner, row.space)
                    val name = (row.edit as SynologyPhotoEdit.CreateTag).name
                    val tag = write("Browse.GeneralTag", 1, "create", json("name" to name), row.space).obj("tag")
                    val created = SynologyPhotoChoice(tag.positive("id"), tag.text("name"))
                    if (created.name != name) invalid()
                    row.copy(createdTag = created)
                } catch (_: Exception) { row.copy(phase = SynologyPhotoEditPhase.PENDING) }
                withContext(NonCancellable) { persist(row, save) }
                if (row.createdTag == null) return@withLock row
            }
            val groups = if (row.edit is SynologyPhotoEdit.ShiftDates) row.targets.indices.map { listOf(it) }
                else SynologyPhotoSpace.entries.map { space -> row.targets.indices.filter { row.targets[it].id.space == space } }.filter { it.isNotEmpty() }
            for (indices in groups) {
                val space = row.targets[indices.first()].id.space
                // 取消或写前持久化失败后，已完成的前组继续保留；剩余组不自行重试。
                checkAccess(owner, space)
                row = row.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = row.attempted + indices)
                persist(row, save)
                val result = try {
                    checkAccess(owner, space)
                    val (version, method, fields) = parameters(row, indices)
                    val receipt = write("Browse.Item", version, method, fields, space)
                    val errors = receipt["error_list"]
                    if (errors != null && errors != JsonNull && (errors !is JsonArray || errors.size > indices.size)) invalid()
                    if (row.edit is SynologyPhotoEdit.Rotation && (errors == null || errors == JsonNull || errors is JsonArray && errors.isEmpty()))
                        acknowledgedRotations += row.operationId
                    row.copy(phase = SynologyPhotoEditPhase.SUBMITTING,
                        reportedFailures = if (errors is JsonArray && errors.isNotEmpty()) row.reportedFailures + indices else row.reportedFailures)
                } catch (error: Exception) {
                    if (row.edit is SynologyPhotoEdit.Rotation && error is DsmFailure && error.code in setOf(105, 106, 107, 119))
                        row.copy(reportedFailures = row.reportedFailures + indices) else null
                }
                row = result ?: row.copy(phase = SynologyPhotoEditPhase.PENDING)
                withContext(NonCancellable) { persist(row, save) }
                if (result == null) break
            }
            try { reviewLocked(row, owner, save) } catch (_: Exception) { row }
        } }

    suspend fun review(input: SynologyPhotoEditCheckpoint, save: (SynologyPhotoEditCheckpoint) -> Unit): SynologyPhotoEditCheckpoint =
        withContext(Dispatchers.IO) { mutex.withLock { val owner = identity(); reviewLocked(select(input, owner), owner, save) } }

    private suspend fun reviewLocked(row: SynologyPhotoEditCheckpoint, owner: SynologyPhotosMutationAccess,
        save: (SynologyPhotoEditCheckpoint) -> Unit): SynologyPhotoEditCheckpoint {
        if (!row.submitted) invalid()
        requireOwner(row, owner)
        if (row.finished) { persist(row, save); return row }
        for (space in row.targets.mapTo(mutableSetOf(row.space)) { it.id.space }) checkAccess(owner, space)
        if (row.edit is SynologyPhotoEdit.CreateTag) {
            val created = row.createdTag ?: return row
            if (findTag(created.id, row.space) != created) return row
        }
        val completed = row.completed.toMutableSet()
        for (index in row.attempted) {
            if (row.edit is SynologyPhotoEdit.Rotation && index in row.reportedFailures) continue
            val target = row.targets[index]
            val photo = details(target.photo())
            if (!target.matches(photo, includeTime = row.edit is SynologyPhotoEdit.Rotation)) changed()
            if (matchesValue(row, target, photo)) completed += index
        }
        checkAccess(owner, row.space)
        val next = row.copy(completed = completed, phase = when {
            completed.size == row.targets.size -> SynologyPhotoEditPhase.COMPLETED
            row.attempted.all { it in completed || it in row.reportedFailures } -> SynologyPhotoEditPhase.PARTIAL
            else -> SynologyPhotoEditPhase.PENDING
        })
        persist(next, save)
        return next
    }

    private fun parameters(row: SynologyPhotoEditCheckpoint, indices: List<Int>): Triple<Int, String, Map<String, JsonElement>> {
        val ids = JsonArray(indices.map { JsonPrimitive(row.targets[it].id.itemId) })
        val edit = row.edit
        val field = when (edit) {
            is SynologyPhotoEdit.Rotation -> json("rotate_action" to "counter_clockwise")
            is SynologyPhotoEdit.Rating -> json("rating" to edit.value)
            is SynologyPhotoEdit.Description -> json("description" to edit.value)
            is SynologyPhotoEdit.TakenAt, is SynologyPhotoEdit.ShiftDates -> json("time" to photoEditTimestamp(edit, row.targets[indices.singleOrNull() ?: indices.first()]))
            is SynologyPhotoEdit.AddTags -> json("tag" to JsonArray(edit.ids.map(::JsonPrimitive)))
            is SynologyPhotoEdit.RemoveTags -> json("tag" to JsonArray(edit.ids.map(::JsonPrimitive)))
            is SynologyPhotoEdit.CreateTag -> json("tag" to array(row.createdTag?.id ?: invalid()))
        }
        val method = when (edit) {
            is SynologyPhotoEdit.AddTags, is SynologyPhotoEdit.CreateTag -> "add_tag"
            is SynologyPhotoEdit.RemoveTags -> "remove_tag"
            else -> "set"
        }
        return Triple(if (method == "set") 2 else 1, method, json("id" to ids) + field)
    }

    private fun matchesValue(row: SynologyPhotoEditCheckpoint, target: SynologyPhotoEditTarget, photo: SynologyPhoto): Boolean = when (val edit = row.edit) {
        is SynologyPhotoEdit.Rotation -> photo.orientation == edit.expectedOrientation && (
            (edit.width == null || photo.height == edit.width) && (edit.height == null || photo.width == edit.height) ||
                row.operationId in acknowledgedRotations && photo.width == edit.width && photo.height == edit.height)
        is SynologyPhotoEdit.Rating -> photo.rating == edit.value
        is SynologyPhotoEdit.Description -> photo.description == edit.value
        is SynologyPhotoEdit.TakenAt, is SynologyPhotoEdit.ShiftDates -> photo.takenAt.isFinite() && photo.takenAt >= 0 &&
            photo.takenAt <= Long.MAX_VALUE / 2.0 && photo.takenAt.toLong() == photoEditTimestamp(edit, target)
        is SynologyPhotoEdit.AddTags -> photo.tags?.map { it.id }?.containsAll(edit.ids) == true
        is SynologyPhotoEdit.RemoveTags -> photo.tags?.none { it.id in edit.ids } == true
        is SynologyPhotoEdit.CreateTag -> photo.tags?.any { it.id == row.createdTag?.id } == true
    }

    private suspend fun findTag(id: Long, space: SynologyPhotoSpace): SynologyPhotoChoice? {
        var offset = 0
        val seen = mutableSetOf<Long>()
        while (true) {
            currentCoroutineContext().ensureActive()
            val page = tags(space, offset, 500)
            if (page.any { !seen.add(it.id) }) invalid()
            page.firstOrNull { it.id == id }?.let { return it }
            if (page.size < 500) return null
            offset = Math.addExact(offset, page.size)
        }
    }

    private suspend fun album(id: Long): JsonObject = read("Browse.Album", 4, "get", json("id" to array(id),
        "additional" to array("sharing_info", "thumbnail")), null).list().singleOrNull()?.also {
        if (it.positive("id") != id) changed()
    } ?: changed()

    private fun select(row: SynologyPhotoEditCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoEditCheckpoint {
        validatePhotoEditCheckpoint(row); requireOwner(row, owner)
        val previous = operations[row.operationId]
        if (previous != null && !previous.sameOperation(row)) changed()
        if (previous == null && !row.submitted && operations.values.any { photoEditsConflict(it, row) }) changed()
        return previous ?: row.also { operations[it.operationId] = it }
    }
    private fun requireOwner(row: SynologyPhotoEditCheckpoint, owner: SynologyPhotosMutationAccess) {
        if (row.profileId != owner.profileId || row.userId != owner.userId) denied()
    }
    private fun persist(row: SynologyPhotoEditCheckpoint, save: (SynologyPhotoEditCheckpoint) -> Unit) {
        operations[row.operationId] = row
        save(row)
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
