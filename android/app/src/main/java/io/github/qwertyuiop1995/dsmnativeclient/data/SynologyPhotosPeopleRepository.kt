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

/** Person 的名称、分组合并和显示管理；未知结果仅回读，不重发写请求。 */
internal class SynologyPhotosPeopleRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val categoryAccess: (SynologyPhotoSpace) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val photos: suspend (SynologyPhotoSpace, SynologyPhotoQuery, Int, Int) -> SynologyPhotoPage,
    private val folderAccess: suspend (SynologyPhotoSpace, Long) -> SynologyPhotoFolderAccess,
    private val photoPending: (SynologyPhotoId) -> Boolean,
    private val thumbnail: suspend (SynologyPhotoPersonCover, SynologyPhotoSpace) -> ByteArray,
    details: suspend (SynologyPhoto) -> SynologyPhoto,
    faceThumbnail: suspend (SynologyPhotoPersonFace) -> ByteArray,

) {
    private data class Cover(val generation: Long, val value: SynologyPhotoPersonCover?)
    private val covers = ConcurrentHashMap<Pair<SynologyPhotoSpace, Long>, Cover>()
    private val faces = SynologyPhotosPersonFacesRepository(identity, ::check, read, write, details,
        folderAccess, photoPending, faceThumbnail, ::all)
    fun clearCovers() { covers.clear(); faces.clear() }
    suspend fun faces(personId: Long, photos: List<SynologyPhoto>) = faces.faces(personId, photos)
    suspend fun faceThumbnail(face: SynologyPhotoPersonFace) = faces.thumbnail(face)
    suspend fun faceCheckpoint(action: SynologyPhotoAlbumAction, original: SynologyPhotoPersonSnapshot,
        photos: List<SynologyPhoto>, selected: List<SynologyPhotoPersonFace>, target: SynologyPhotoPersonSnapshot?, name: String?): SynologyPhotoAlbumCheckpoint {
        val owner = identity()
        if (!action.isPersonFaces || selected.any { it.personId != original.id }) invalid()
        val row = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = owner.userId, action = action,
            targets = photos.map(::SynologyPhotoEditTarget), people = SynologyPhotoPeopleCheckpoint(
                listOfNotNull(original, target), name = name, faces = SynologyPhotoPersonFacesCheckpoint(selected.map { it.snapshot() })))
        validatePhotoAlbumCheckpoint(row); prepare(row, owner)
        return row
    }

    suspend fun page(space: SynologyPhotoSpace, offset: Int, limit: Int, includingHidden: Boolean = false): List<SynologyPhotoCollection> =
        page(space, offset, limit, includingHidden, identity())
    private suspend fun page(space: SynologyPhotoSpace, offset: Int, limit: Int, includingHidden: Boolean,
        owner: SynologyPhotosMutationAccess): List<SynologyPhotoCollection> {
        if (offset < 0 || limit !in 1..500 || offset > Int.MAX_VALUE - limit) invalid()
        check(owner, space)
        val fields = json("offset" to offset, "limit" to limit, "additional" to array("thumbnail")) +
            if (includingHidden) json("show_more" to true, "show_hidden" to true) else emptyMap()
        val result = SynologyPhotoPeopleCodec.page(read("Browse.Person", 1, "list", fields, space), space, limit, includingHidden)
        check(owner, space); cache(result, owner)
        return result
    }
    suspend fun people(space: SynologyPhotoSpace, includingHidden: Boolean): List<SynologyPhotoCollection> {
        val owner = identity(); freshAccess(owner, space)
        return all(space, includingHidden, owner)
    }
    private suspend fun all(space: SynologyPhotoSpace, includingHidden: Boolean, owner: SynologyPhotosMutationAccess): List<SynologyPhotoCollection> {
        val result = mutableListOf<SynologyPhotoCollection>(); val seen = mutableSetOf<Long>()
        while (true) {
            val page = page(space, result.size, 500, includingHidden, owner)
            if (page.any { !seen.add(it.id) }) invalid()
            result += page
            if (page.size < 500) return result
        }
    }
    private suspend fun visibility(ids: List<Long>, space: SynologyPhotoSpace, owner: SynologyPhotosMutationAccess): List<SynologyPhotoCollection> {
        check(owner, space)
        val result = SynologyPhotoPeopleCodec.page(read("Browse.Person", 1, "get",
            json("id" to JsonArray(ids.map(::JsonPrimitive)), "additional" to array("thumbnail")), space), space, ids.size, true)
        if (result.map { it.id }.toSet() != ids.toSet() || result.size != ids.size) changed()
        check(owner, space); cache(result, owner)
        return result
    }
    private fun cache(people: List<SynologyPhotoCollection>, owner: SynologyPhotosMutationAccess) {
        people.forEach { covers[it.space to it.id] = Cover(owner.generation, it.personCover) }
    }
    suspend fun thumbnail(person: SynologyPhotoCollection): ByteArray {
        val owner = identity(); check(owner, person.space)
        val cached = covers[person.space to person.id]
        val cover = person.personCover ?: invalid()
        if (cached?.generation != owner.generation || cached.value != cover) denied()
        return thumbnail(cover, person.space).also { check(owner, person.space) }
    }

    suspend fun checkpoint(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoPersonSnapshot>, name: String?, visible: Boolean?): SynologyPhotoAlbumCheckpoint {
        val owner = identity()
        var row = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = owner.userId, action = action,
            people = SynologyPhotoPeopleCheckpoint(originals, name, visible, emptySet<Long>().takeIf { action == SynologyPhotoAlbumAction.MERGE_PEOPLE }))
        validatePhotoAlbumCheckpoint(row)
        freshAccess(owner, row.people!!.space); requireCapabilities(row)
        matching(row, owner)
        if (action == SynologyPhotoAlbumAction.MERGE_PEOPLE) row = row.copy(people = row.people!!.copy(memberIds = union(row.people!!, owner, true)))
        matching(row, owner); freshAccess(owner, row.people!!.space)
        return row
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        SynologyPhotoPeopleCodec.validate(row)
        val value = row.people!!
        freshAccess(owner, value.space); requireCapabilities(row); matching(row, owner)
        if (row.action == SynologyPhotoAlbumAction.MERGE_PEOPLE && union(value, owner, true) != value.memberIds) changed()
        if (row.action.isPersonFaces) faces.prepare(row, owner)
        matching(row, owner); freshAccess(owner, value.space)
    }
    private fun requireCapabilities(row: SynologyPhotoAlbumCheckpoint) {
        val space = row.people!!.space
        capability("Browse.Person", if (row.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) 2 else 1, space)
        if (row.action.isPersonFaces) { capability("Browse.Item", 5, space); capability("Browse.Folder", 2, space) }
        if (row.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) {
            capability("Browse.Timeline", 5, space); capability("Browse.Item", 4, space); capability("Browse.Folder", 2, space)
        }
    }
    private suspend fun matching(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val value = row.people!!
        val current = if (row.action == SynologyPhotoAlbumAction.SHOW_PEOPLE) visibility(value.originals.map { it.id }, value.space, owner)
            else all(value.space, false, owner)
        for (original in value.originals) {
            val person = current.singleOrNull { it.id == original.id } ?: changed()
            if (person.name != original.name || original.count != null && person.count != original.count ||
                original.visible != null && person.personVisible != original.visible) changed()
        }
    }
    private suspend fun union(value: SynologyPhotoPeopleCheckpoint, owner: SynologyPhotosMutationAccess, requireManagement: Boolean): Set<Long> {
        val ids = mutableSetOf<Long>(); val folders = mutableSetOf<Long>()
        for (person in value.originals) {
            val members = members(person.id, value.space, owner)
            if (person.count != null && person.count != members.size) changed()
            for (photo in members) {
                if (requireManagement && photoPending(photo.id)) changed()
                if (requireManagement && folders.add(photo.folderId) && !folderAccess(value.space, photo.folderId).canManage) denied()
                ids += photo.id.itemId
            }
        }
        check(owner, value.space)
        return ids
    }
    private suspend fun members(id: Long, space: SynologyPhotoSpace, owner: SynologyPhotosMutationAccess): List<SynologyPhoto> {
        check(owner, space)
        val days = SynologyPhotosCodec.days(read("Browse.Timeline", 5, "get", json("timeline_group_unit" to "day", "person_id" to id), space))
        if (days.isEmpty()) return emptyList()
        val start = maxOf(0, days.minOf { it.date }.atStartOfDay().toEpochSecond(ZoneOffset.UTC) - 86_400)
        val end = days.maxOf { it.date }.atStartOfDay().toEpochSecond(ZoneOffset.UTC) + 172_800
        val query = SynologyPhotoQuery.Category(SynologyPhotoCategory.PEOPLE, id, start, end)
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
        val value = input.people!!
        val row = input.copy(people = value.copy(attempted = true))
        check(owner, value.space); persist(row); check(owner, value.space)
        val ids = JsonArray(value.originals.map { JsonPrimitive(it.id) })
        val receipt = try {
            if (row.action.isPersonFaces) return faces.execute(row, owner).also(persist)
            when (row.action) {
                SynologyPhotoAlbumAction.RENAME_PERSON -> write("Browse.Person", 1, "set", json("id" to value.originals.single().id, "name" to value.name!!), value.space)
                SynologyPhotoAlbumAction.MERGE_PEOPLE -> write("Browse.Person", 2, "merge", json("target_id" to value.originals.first().id,
                    "merged_id" to JsonArray(value.originals.drop(1).map { JsonPrimitive(it.id) }), "name" to value.name!!), value.space)
                SynologyPhotoAlbumAction.SHOW_PEOPLE -> write("Browse.Person", 1, "show", json("id" to ids, "show" to value.visible!!), value.space)
                else -> invalid()
            }
        } catch (error: DsmFailure) {
            if (error.code != null && error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.INVALID_RESPONSE))
                persist(row.copy(people = row.people!!.copy(rejected = true)))
            throw error
        }
        val named = row.action == SynologyPhotoAlbumAction.RENAME_PERSON
        if (named && (receipt.positive("id") != value.originals.single().id || receipt.text("name") != value.name)) invalid()
        return row.copy(people = row.people!!.copy(acknowledged = true, nameReceipt = named)).also(persist)
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val value = row.people!!
        if (!value.attempted || value.rejected) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
        freshAccess(owner, value.space)
        if (row.action.isPersonFaces) return faces.review(row, owner)
        val ids = value.originals.map { it.id }.toSet()
        var completed = value.completedIds; var removed = value.removedIds
        if (row.action == SynologyPhotoAlbumAction.SHOW_PEOPLE) {
            val matching = visibility(ids.toList(), value.space, owner).filter { it.personVisible == value.visible }.map { it.id }.toSet()
            // 部分回读只在明确收到写回执时结束；缺项/缺show在解码阶段拒绝。
            if (matching == ids || value.acknowledged && matching.isNotEmpty()) completed += matching
        } else {
            val people = all(value.space, false, owner); val target = value.originals.first()
            val actual = people.singleOrNull { it.id == target.id }
            if (row.action == SynologyPhotoAlbumAction.RENAME_PERSON) {
                if (actual?.name == value.name) completed = ids
                else if (actual == null && value.name == "" && target.count?.let { it < 2 } == true && value.nameReceipt) {
                    completed = ids; removed = ids
                }
            } else if (actual?.name == value.name && value.originals.drop(1).none { source -> people.any { it.id == source.id } } &&
                members(target.id, value.space, owner).map { it.id.itemId }.toSet() == value.memberIds) {
                completed = ids; removed = ids - target.id
            }
        }
        check(owner, value.space)
        val phase = when {
            completed == ids -> SynologyPhotoAlbumPhase.COMPLETED
            value.acknowledged && completed.isNotEmpty() -> SynologyPhotoAlbumPhase.PARTIAL
            else -> SynologyPhotoAlbumPhase.PENDING
        }
        return row.copy(phase = phase, people = value.copy(completedIds = completed, removedIds = removed))
    }
    private suspend fun check(owner: SynologyPhotosMutationAccess, space: SynologyPhotoSpace) {
        currentCoroutineContext().ensureActive(); checkAccess(owner, space); categoryAccess(space)
    }
    suspend fun freshAccess(owner: SynologyPhotosMutationAccess, space: SynologyPhotoSpace) {
        check(owner, space)
        val me = read("UserInfo", 1, "me", emptyMap(), null)
        if (!me.boolean("enabled") || me.positive("id") != owner.userId) denied()
        val user = read("Setting.User", 1, "get", emptyMap(), null)
        val admin = read("Setting.Admin", 1, "get", emptyMap(), null)
        if (admin.optionalBoolean("enable_person") == false) denied()
        if (space == SynologyPhotoSpace.PERSONAL) {
            if (!user.boolean("enable_home_service") || user.optionalBoolean("enable_person") == false) denied()
        } else {
            val team = read("Setting.TeamSpace", 1, "get", emptyMap(), null)
            if (!owner.managesShared || user.text("team_space_permission") != "management" || !team.boolean("enabled") || team.optionalBoolean("enable_person") != true) denied()
        }
        check(owner, space)
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
