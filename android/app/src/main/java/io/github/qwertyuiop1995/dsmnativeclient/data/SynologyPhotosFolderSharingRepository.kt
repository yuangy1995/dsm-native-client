package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 共用管理通道互斥与加密恢复；目录权限始终通过 FotoTeam，成员候选通过 Foto。 */
internal class SynologyPhotosFolderSharingRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val uid: () -> JsonPrimitive?,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
) {
    private val space = SynologyPhotoSpace.SHARED
    private suspend fun requireAccess(owner: SynologyPhotosMutationAccess) {
        checkAccess(owner, space)
        if (!owner.managesShared) denied()
        capability("Browse.Folder", 2, space); capability("Sharing.FolderPermission", 1, space)
    }
    suspend fun state(folder: SynologyPhotoFolderSnapshot): SynologyPhotoFolderSharing = state(folder, identity())
    private suspend fun state(expected: SynologyPhotoFolderSnapshot, owner: SynologyPhotosMutationAccess): SynologyPhotoFolderSharing {
        requireAccess(owner); SynologyPhotoFolderCodec.validate(expected)
        if (!SynologyPhotoFolderSharingCodec.eligible(expected)) denied()
        val raw = read("Browse.Folder", 2, "get", json("id" to expected.id,
            "additional" to array("sharing_info", "access_permission")), space).obj("folder")
        val parent = raw.positive("parent")
        if (raw.positive("id") != expected.id || raw.text("name") != expected.path ||
            expected.parentId != null && parent != expected.parentId) changed()
        val shared = raw.optionalBoolean("shared") ?: invalid()
        val info = raw.obj("additional").obj("sharing_info")
        var url = info.optionalText("sharing_link")
        if (url.isNullOrEmpty()) {
            if (shared) invalid()
            url = read("Sharing.FolderPermission", 1, "get_folder_link", json("folder_id" to expected.id), space).text("folder_link")
        }
        if (!SynologyPhotoSharingCodec.safeUrl(url)) invalid()
        val apply = read("Sharing.FolderPermission", 1, "get_config", emptyMap(), space).optionalBoolean("set_to_subfolder") ?: invalid()
        val parentRaw = read("Browse.Folder", 2, "get", json("id" to parent), space).obj("folder")
        if (parentRaw.positive("id") != parent || parentRaw.text("name") != expected.path.substringBeforeLast('/').ifEmpty { "/" }) changed()
        val parentShared = parentRaw.optionalBoolean("shared") ?: invalid()
        currentCoroutineContext().ensureActive(); requireAccess(owner)
        return SynologyPhotoFolderSharingCodec.decode(owner.profileId, expected.copy(parentId = parent), shared, info, parentShared, apply, url)
    }
    suspend fun recipients(): List<SynologyPhotoShareRecipient> = recipients(identity())
    private suspend fun recipients(owner: SynologyPhotosMutationAccess): List<SynologyPhotoShareRecipient> {
        requireAccess(owner)
        val me = uid()?.takeIf(SynologyPhotoSharingCodec::validId) ?: invalid()
        val values = read("Sharing.Misc", 1, "list_user_group", json("team_space_sharable_list" to true), null)
            .list().map(SynologyPhotoSharingCodec::recipient)
        if (values.map { it.id }.distinct().size != values.size) invalid()
        requireAccess(owner)
        return values.filter { it.id.type != "user" || it.id.value != me }
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val change = row.folderSharing?.change ?: invalid()
        SynologyPhotoFolderSharingCodec.validate(change)
        if (state(change.original.folder, owner).snapshot != change.original) changed()
        change.members?.let { desired ->
            val before = SynologyPhotoSharingCodec.roles(change.original.members ?: invalid())
            val changedUsers = desired.filter { before[it.id] != it.role && it.id.type == "user" }
            if (changedUsers.isNotEmpty()) {
                val me = uid()?.takeIf(SynologyPhotoSharingCodec::validId) ?: invalid()
                if (changedUsers.any { it.id.value == me }) denied()
            }
            val added = desired.filter { it.id !in before }
            if (added.isNotEmpty()) {
                val available = recipients(owner).mapTo(mutableSetOf()) { it.id }
                if (added.any { it.id !in available }) denied()
            }
        }
        requireAccess(owner)
    }
    fun requirePassword(row: SynologyPhotoAlbumCheckpoint, password: String?) {
        when (row.folderSharing?.change?.password ?: invalid()) {
            SynologyPhotoSharingPassword.SET -> if (password.isNullOrEmpty()) invalid()
            SynologyPhotoSharingPassword.REMOVE -> if (!password.isNullOrEmpty()) invalid()
            SynologyPhotoSharingPassword.UNCHANGED -> if (password != null) invalid()
        }
    }
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, password: String?, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        var row = input
        val change = row.folderSharing!!.change
        fun save(checkpoint: SynologyPhotoFolderSharingCheckpoint) { val next = row.copy(folderSharing = checkpoint); persist(next); row = next }
        // 再次读取完整快照，候选查询期间的并发修改也不能被旧表单覆盖。
        if (state(change.original.folder, owner).snapshot != change.original) changed()
        val fields = json("folder_id" to change.original.folder.id, "privacy_type" to change.access.value,
            "set_to_subfolder" to change.appliesToSubfolders).toMutableMap()
        val members = SynologyPhotoFolderSharingCodec.memberChanges(change)
        if (members.isNotEmpty()) fields["permission"] = JsonArray(members)
        when (change.password) {
            SynologyPhotoSharingPassword.SET -> fields["password"] = JsonPrimitive(password ?: invalid())
            SynologyPhotoSharingPassword.REMOVE -> fields["password"] = JsonPrimitive("")
            SynologyPhotoSharingPassword.UNCHANGED -> Unit
        }
        currentCoroutineContext().ensureActive(); requireAccess(owner)
        save(row.folderSharing!!.copy(updateAttempted = true))
        try { write("Sharing.FolderPermission", 1, "update", fields, space) }
        catch (error: DsmFailure) {
            if (error.code in setOf(105, 106, 107, 119)) save(row.folderSharing!!.copy(rejected = true))
            throw error
        }
        // 回执先落盘；后续失去权限或保存失败都不能继续第二次写入。
        save(row.folderSharing!!.copy(updateAcknowledged = true))
        if (change.appliesToSubfolders != change.original.appliesToSubfolders) {
            currentCoroutineContext().ensureActive(); requireAccess(owner)
            save(row.folderSharing!!.copy(configAttempted = true))
            write("Sharing.FolderPermission", 1, "set_config", json("set_to_subfolder" to change.appliesToSubfolders), space)
        }
        return row
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val checkpoint = row.folderSharing!!; val change = checkpoint.change
        requireAccess(owner)
        if (checkpoint.rejected || !checkpoint.updateAttempted) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL,
            folderSharing = checkpoint.copy(rejected = true))
        val current = state(change.original.folder, owner).snapshot
        val expectedMembers = change.members ?: change.original.members
        val membersMatch = expectedMembers == null || current.members?.let {
            SynologyPhotoSharingCodec.roles(it) == SynologyPhotoSharingCodec.roles(expectedMembers)
        } == true
        val passwordMatch = when (change.password) {
            SynologyPhotoSharingPassword.SET -> checkpoint.updateAcknowledged && current.hasPassword == true
            SynologyPhotoSharingPassword.REMOVE -> current.hasPassword == false
            SynologyPhotoSharingPassword.UNCHANGED -> current.hasPassword == change.original.hasPassword
        }
        val matched = current.access == change.access && membersMatch && passwordMatch &&
            current.parentIsShared == change.original.parentIsShared && (!change.appliesToSubfolders || checkpoint.updateAcknowledged)
        return row.copy(phase = if (!matched) SynologyPhotoAlbumPhase.PENDING else if (current.appliesToSubfolders == change.appliesToSubfolders)
            SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PARTIAL)
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
