package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.*

internal object SynologyPhotoSharedMembersCodec {
    enum class Kind { MEMBERS, ALL_FOLDERS, FOLDERS }
    data class Step(val kind: Kind, val editIndex: Int = -1, val method: String, val fields: Map<String, JsonElement>) {
        val api: String get() = if (kind == Kind.MEMBERS) "Setting.TeamSpace" else "Sharing.FolderBatchPermission"
        val space: SynologyPhotoSpace? get() = if (kind == Kind.MEMBERS) null else SynologyPhotoSpace.SHARED
    }
    fun valid(id: SynologyPhotoShareMemberId): Boolean = id.type in setOf("user", "group") && SynologyPhotoSharingCodec.validId(id.value)
    fun member(raw: JsonObject): SynologyPhotoSharedMember {
        val recipient = SynologyPhotoSharingCodec.recipient(raw)
        return SynologyPhotoSharedMember(recipient, SynologyPhotoSharedMemberGrant(recipient.id,
            raw.text("permission").takeIf { it.isNotEmpty() } ?: invalid(), raw.boolean("auto_backup"),
            recipient.id.type == "group" && recipient.name == "administrators"))
    }
    fun folder(raw: JsonObject, root: Long, parent: Long, depth: Int, member: SynologyPhotoShareMemberId): SynologyPhotoMemberFolder {
        val id = raw.positive("id"); val path = raw.text("name")
        if (id == root || id == parent || raw.positive("parent") != parent || depth !in 0..1 ||
            !SynologyPhotoFolderCodec.validPath(path) || path.count { it == '/' } != depth + 1) invalid()
        val info = raw.obj("additional").obj("sharing_info")
        val privacy = info.text("privacy_type").takeIf { it.isNotEmpty() } ?: invalid()
        val permissions = info["permission"] as? JsonArray ?: invalid()
        val roles = mutableMapOf<SynologyPhotoShareMemberId, String>()
        for (entry in permissions) {
            val value = entry.obj(); val type = value.text("type")
            if (type == "public") continue
            val key = SynologyPhotoShareMemberId(type, value["id"] as? JsonPrimitive ?: invalid())
            val role = value.text("role").takeIf { it.isNotEmpty() } ?: invalid()
            if (!valid(key) || roles.put(key, role) != null) invalid()
        }
        val identity = SynologyPhotoSharingCodec.digest(buildJsonObject { put("id", id); put("parent", parent); put("name", path) })
        val revision = SynologyPhotoSharingCodec.digest(buildJsonObject {
            put("identity", identity); put("privacy", privacy)
            put("permissions", JsonArray(roles.map { (key, role) -> buildJsonObject {
                put("id", key.value); put("type", key.type); put("role", role)
            } }.sortedBy { it.toString() }))
        })
        return SynologyPhotoMemberFolder(SynologyPhotoMemberFolderSnapshot(id, parent, root, depth, identity, privacy, roles[member], revision), path)
    }
    private fun identity(id: SynologyPhotoShareMemberId) = buildJsonObject { put("id", id.value); put("type", id.type) }
    fun steps(value: SynologyPhotoSharedMembersCheckpoint): List<Step> {
        val before = value.original.members.associateBy { it.id }; val after = value.desired.associateBy { it.id }
        val changes = value.original.members.filter { it.id !in after }.map { it to "delete" } +
            value.desired.filter { it != before[it.id] }.map { it to "update" }
        val result = mutableListOf<Step>()
        if (changes.isNotEmpty()) result += Step(Kind.MEMBERS, method = "update_permission", fields = mapOf("list" to JsonArray(changes.map { (grant, action) ->
            JsonObject(identity(grant.id) + mapOf("action" to JsonPrimitive(action), "permission" to JsonPrimitive(grant.role), "auto_backup" to JsonPrimitive(grant.autoBackup)))
        })))
        value.folders.forEachIndexed { index, edit ->
            edit.batch?.let { batch -> result += Step(Kind.ALL_FOLDERS, index, "update_all_by_member", mapOf("permission" to buildJsonObject {
                put("member", identity(edit.member)); put("role", batch.role.value); put("action", batch.action)
            })) }
            if (edit.changes.isNotEmpty()) result += Step(Kind.FOLDERS, index, "update_by_member", mapOf("permission" to JsonObject(identity(edit.member) +
                mapOf("list" to JsonArray(edit.changes.map { change -> buildJsonObject {
                    put("folder_id", change.folderId); put("action", if (change.role == null) "delete" else "update")
                    change.role?.let { put("role", it.value) }
                } })))))
        }
        return result
    }
    fun validate(value: SynologyPhotoSharedMembersCheckpoint) {
        val original = value.original
        if (original.profileId.isBlank() || original.administratorId <= 0 || !original.enabled) invalid()
        fun grants(values: List<SynologyPhotoSharedMemberGrant>) {
            if (values.map { it.id }.distinct().size != values.size || values.any { !valid(it.id) || it.role.isEmpty() || it.protected && it.id.type != "group" }) invalid()
        }
        grants(original.members); grants(value.desired)
        val before = original.members.associateBy { it.id }; val after = value.desired.associateBy { it.id }
        if (original.members.any { !it.canEdit && after[it.id] != it }) invalid()
        if (value.desired.any { grant -> before[grant.id]?.let { it.protected != grant.protected } == true ||
            before[grant.id] != grant && (!grant.canEdit || grant.role == "management" && !grant.autoBackup) }) invalid()
        if (value.folders.map { it.member }.distinct().size != value.folders.size) invalid()
        value.folders.forEach { edit ->
            if (!valid(edit.member) || !edit.canSave || after[edit.member]?.let { it.canEdit && it.role == "entry" } != true) invalid()
            val all = edit.original.associateBy { it.id }
            if (edit.original.map { it.rootId }.distinct().size != 1 || edit.original.any { folder ->
                folder.id <= 0 || folder.parentId <= 0 || folder.rootId <= 0 || folder.id == folder.parentId || folder.id == folder.rootId ||
                    folder.depth !in 0..1 || !folder.identity.matches(Regex("[0-9a-f]{64}")) || !folder.revision.matches(Regex("[0-9a-f]{64}")) ||
                    folder.privacy.isEmpty() || folder.directRole?.isEmpty() == true ||
                    if (folder.depth == 0) folder.parentId != folder.rootId else all[folder.parentId]?.depth != 0
            }) invalid()
        }
        val steps = steps(value); val indices = steps.indices.toSet()
        if (steps.isEmpty() || !indices.containsAll(value.attempted) || !value.attempted.containsAll(value.acknowledged) ||
            !value.attempted.containsAll(value.rejected) || !value.attempted.containsAll(value.completed) ||
            value.acknowledged.intersect(value.rejected).isNotEmpty() ||
            value.attempted.any { index -> (0 until index).any { it !in value.acknowledged } }) invalid()
    }
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.sharedMembers ?: invalid(); validate(value)
        if (row.album != null || row.name != null || row.targets.isNotEmpty() || value.original.profileId != row.profileId || value.original.administratorId != row.userId ||
            !row.submitted && value.attempted.isNotEmpty() ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && value.completed != steps(value).indices.toSet() ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && !value.attempted.all { it in value.completed || it in value.rejected }) invalid()
    }
}
