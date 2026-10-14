package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.time.ZoneOffset
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** Concept 内部接口：只修改分类关联，断线及冷启动后只读取原操作的结果。 */
internal class SynologyPhotosConceptRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val categoryAccess: (SynologyPhotoSpace) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val photos: suspend (SynologyPhotoSpace, SynologyPhotoQuery, Int, Int) -> SynologyPhotoPage,
    private val details: suspend (SynologyPhoto) -> SynologyPhoto,
    private val folderAccess: suspend (SynologyPhotoSpace, Long) -> SynologyPhotoFolderAccess,
    private val photoPending: (SynologyPhotoId) -> Boolean,
    private val thumbnail: suspend (SynologyPhotoThumbnail, SynologyPhotoSpace) -> ByteArray,
) {
    private data class Cover(val generation: Long, val value: SynologyPhotoThumbnail?)
    private val covers = ConcurrentHashMap<Pair<SynologyPhotoSpace, Long>, Cover>()
    fun clear() = covers.clear()
    private fun cache(values: List<SynologyPhotoCollection>, owner: SynologyPhotosMutationAccess) {
        values.forEach { covers[it.space to it.id] = Cover(owner.generation, it.thumbnail) }
    }
    suspend fun thumbnail(concept: SynologyPhotoCollection): ByteArray {
        val owner = identity(); check(owner, concept.space)
        val cover = concept.thumbnail ?: invalid(); val cached = covers[concept.space to concept.id]
        if (cached?.generation != owner.generation || cached.value != cover) denied()
        return thumbnail(cover, concept.space).also { check(owner, concept.space) }
    }
    suspend fun page(space: SynologyPhotoSpace, offset: Int, limit: Int): List<SynologyPhotoCollection> = page(space, offset, limit, false, identity())
    private suspend fun page(space: SynologyPhotoSpace, offset: Int, limit: Int, hidden: Boolean,
        owner: SynologyPhotosMutationAccess): List<SynologyPhotoCollection> {
        if (offset < 0 || limit !in 1..500 || offset > Int.MAX_VALUE - limit) invalid()
        check(owner, space)
        val fields = json("offset" to offset, "limit" to limit, "additional" to array("thumbnail")) +
            if (hidden) json("show_hidden" to true) else emptyMap()
        val result = SynologyPhotoConceptCodec.page(read("Browse.Concept", 2, "list", fields, space), space, limit, hidden)
        check(owner, space); cache(result, owner)
        return result
    }
    suspend fun all(space: SynologyPhotoSpace): List<SynologyPhotoCollection> {
        val owner = identity(); freshAccess(owner, space)
        val result = mutableListOf<SynologyPhotoCollection>(); val seen = mutableSetOf<Long>()
        while (true) {
            val page = page(space, result.size, 500, true, owner)
            if (page.any { !seen.add(it.id) }) invalid()
            result += page
            if (page.size < 500) return result
        }
    }
    suspend fun get(id: Long, space: SynologyPhotoSpace): SynologyPhotoCollection {
        if (id <= 0) invalid()
        val owner = identity(); freshAccess(owner, space)
        return get(listOf(id), space, owner).single()
    }
    private suspend fun get(ids: List<Long>, space: SynologyPhotoSpace, owner: SynologyPhotosMutationAccess): List<SynologyPhotoCollection> {
        check(owner, space)
        val result = SynologyPhotoConceptCodec.page(read("Browse.Concept", 2, "get",
            json("id" to JsonArray(ids.map(::JsonPrimitive)), "additional" to array("thumbnail")), space), space, ids.size, true)
        if (result.map { it.id }.toSet() != ids.toSet() || result.size != ids.size) changed()
        check(owner, space); cache(result, owner)
        return result
    }
    suspend fun checkpoint(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoConceptSnapshot>,
        photos: List<SynologyPhoto>, visible: Boolean?): SynologyPhotoAlbumCheckpoint {
        val owner = identity()
        val row = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = owner.userId, action = action,
            targets = photos.map(::SynologyPhotoEditTarget), concept = SynologyPhotoConceptCheckpoint(originals, visible))
        validatePhotoAlbumCheckpoint(row); prepare(row, owner)
        return row
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        SynologyPhotoConceptCodec.validate(row)
        val value = row.concept!!
        freshAccess(owner, value.space); capability("Browse.Concept", 2, value.space); matching(row, owner)
        if (row.action != SynologyPhotoAlbumAction.SHOW_CONCEPTS) {
            capability("Browse.Item", 5, value.space); capability("Browse.Folder", 2, value.space); capability("Browse.Timeline", 5, value.space)
            val members = members(value.originals.single().id, value.space, owner)
            if (value.originals.single().count?.let { it != members.size } == true) changed()
            val folders = mutableSetOf<Long>()
            for (target in row.targets) {
                if (photoPending(target.id)) changed()
                if (!target.matches(members.singleOrNull { it.id == target.id } ?: changed(), includeTime = true) ||
                    !target.matches(details(target.photo()), includeTime = true)) changed()
                if (folders.add(target.folderId) && !folderAccess(value.space, target.folderId).canManage) denied()
            }
        }
        matching(row, owner); freshAccess(owner, value.space)
    }
    private suspend fun matching(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val value = row.concept!!
        val current = get(value.originals.map { it.id }, value.space, owner).associateBy { it.id }
        value.originals.forEach { original ->
            val actual = SynologyPhotoConceptSnapshot(current[original.id] ?: changed())
            if (row.action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) {
                if (actual.name != original.name || actual.visible != original.visible) changed()
            } else if (actual != original) changed()
        }
    }
    private suspend fun members(id: Long, space: SynologyPhotoSpace, owner: SynologyPhotosMutationAccess): List<SynologyPhoto> {
        check(owner, space)
        val days = SynologyPhotosCodec.days(read("Browse.Timeline", 5, "get", json("timeline_group_unit" to "day", "concept_id" to id), space))
        check(owner, space)
        if (days.isEmpty()) return emptyList()
        val start = maxOf(0, days.minOf { it.date }.atStartOfDay().toEpochSecond(ZoneOffset.UTC) - 86_400)
        val end = days.maxOf { it.date }.atStartOfDay().toEpochSecond(ZoneOffset.UTC) + 172_800
        val query = SynologyPhotoQuery.Category(SynologyPhotoCategory.SUBJECTS, id, start, end)
        val result = mutableListOf<SynologyPhoto>(); val seen = mutableSetOf<SynologyPhotoId>(); var offset = 0
        while (true) {
            check(owner, space)
            val page = photos(space, query, offset, 500)
            if (page.offset != offset || page.nextOffset != offset + page.items.size || page.items.size > 500 ||
                page.hasMore && page.items.isEmpty() || page.items.any { it.id.profileId != owner.profileId || it.id.space != space ||
                    it.albumContext != null || !seen.add(it.id) }) invalid()
            check(owner, space); result += page.items
            if (!page.hasMore) return result
            offset = page.nextOffset
        }
    }
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        val value = input.concept!!; val row = input.copy(concept = value.copy(attempted = true))
        check(owner, value.space); persist(row); check(owner, value.space)
        try {
            when (row.action) {
                SynologyPhotoAlbumAction.SHOW_CONCEPTS -> write("Browse.Concept", 2, "set_visibility",
                    json("id" to JsonArray(value.originals.map { JsonPrimitive(it.id) }), "visibility" to value.visible!!), value.space)
                SynologyPhotoAlbumAction.COVER_CONCEPT -> write("Browse.Concept", 1, "set_cover",
                    json("id" to value.originals.single().id, "photo_id" to row.targets.single().id.itemId), value.space)
                SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS -> write("Browse.Concept", 1, "hide_item",
                    json("id" to value.originals.single().id, "item_id" to JsonArray(row.targets.map { JsonPrimitive(it.id.itemId) })), value.space)
                else -> invalid()
            }
        } catch (error: DsmFailure) {
            if (error.code != null && error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.INVALID_RESPONSE))
                persist(row.copy(concept = row.concept!!.copy(rejected = true)))
            throw error
        }
        return row.copy(concept = row.concept!!.copy(acknowledged = true)).also(persist)
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val value = row.concept!!
        if (!value.attempted || value.rejected) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
        freshAccess(owner, value.space)
        val ids = value.originals.map { it.id }.toSet()
        val current = get(ids.toList(), value.space, owner)
        var completed = value.completedIds; var removed = value.removedPhotoIds
        when (row.action) {
            SynologyPhotoAlbumAction.SHOW_CONCEPTS -> {
                val matching = current.filter { it.conceptVisible == value.visible }.map { it.id }.toSet()
                if (matching == ids || value.acknowledged && matching.isNotEmpty()) completed += matching
            }
            SynologyPhotoAlbumAction.COVER_CONCEPT -> {
                val target = row.targets.single()
                if (current.single().thumbnail?.unitId == target.id.itemId && target.matches(details(target.photo()), includeTime = true)) completed = ids
            }
            SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS -> {
                val theme = current.single()
                if (theme.count == null || theme.conceptDisplayThreshold == null) invalid()
                val remaining = members(theme.id, value.space, owner)
                if (theme.count != remaining.size) changed()
                val remainingIds = remaining.map { it.id.itemId }.toSet()
                val absent = row.targets.filter { it.id.itemId !in remainingIds }
                for (target in absent) if (!target.matches(details(target.photo()), includeTime = true)) changed()
                if (absent.size == row.targets.size || value.acknowledged && absent.isNotEmpty()) removed += absent.map { it.id.itemId }
                if (removed.size == row.targets.size) completed = ids
            }
            else -> invalid()
        }
        check(owner, value.space)
        val phase = when {
            completed == ids -> SynologyPhotoAlbumPhase.COMPLETED
            value.acknowledged && (completed.isNotEmpty() || removed.isNotEmpty()) -> SynologyPhotoAlbumPhase.PARTIAL
            else -> SynologyPhotoAlbumPhase.PENDING
        }
        val updated = if (phase in setOf(SynologyPhotoAlbumPhase.COMPLETED, SynologyPhotoAlbumPhase.PARTIAL))
            current.filter { it.id in completed || row.action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS && removed.isNotEmpty() }
                .map(::SynologyPhotoConceptSnapshot) else emptyList()
        return row.copy(phase = phase, concept = value.copy(completedIds = completed, removedPhotoIds = removed, updated = updated))
    }
    private suspend fun check(owner: SynologyPhotosMutationAccess, space: SynologyPhotoSpace) {
        currentCoroutineContext().ensureActive(); checkAccess(owner, space); categoryAccess(space)
    }
    private suspend fun freshAccess(owner: SynologyPhotosMutationAccess, space: SynologyPhotoSpace) {
        check(owner, space)
        val me = read("UserInfo", 1, "me", emptyMap(), null)
        if (!me.boolean("enabled") || me.positive("id") != owner.userId) denied()
        val user = read("Setting.User", 1, "get", emptyMap(), null)
        val admin = read("Setting.Admin", 1, "get", emptyMap(), null)
        if (admin.optionalBoolean("enable_concept") == false) denied()
        if (space == SynologyPhotoSpace.PERSONAL) {
            if (!user.boolean("enable_home_service") || user.optionalBoolean("enable_concept") == false) denied()
        } else {
            val team = read("Setting.TeamSpace", 1, "get", emptyMap(), null)
            if (!owner.managesShared || user.text("team_space_permission") != "management" || !team.boolean("enabled") || team.optionalBoolean("enable_concept") != true) denied()
        }
        check(owner, space)
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
