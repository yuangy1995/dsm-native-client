package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.*

internal object SynologyPhotoFolderSharingCodec {
    fun eligible(folder: SynologyPhotoFolderSnapshot): Boolean = folder.space == SynologyPhotoSpace.SHARED &&
        SynologyPhotoFolderCodec.validPath(folder.path) && folder.path != "/" && folder.path.count { it == '/' } in 1..2

    fun decode(profileId: String, folder: SynologyPhotoFolderSnapshot, shared: Boolean, info: JsonObject,
        parentShared: Boolean, apply: Boolean, url: String): SynologyPhotoFolderSharing {
        val access = if (!shared) SynologyPhotoFolderLinkAccess.MANAGEMENT else
            SynologyPhotoFolderLinkAccess.entries.firstOrNull { it.value == info.optionalText("privacy_type") && it != SynologyPhotoFolderLinkAccess.MANAGEMENT } ?: invalid()
        val members = runCatching {
            val values = (info["permission"] as? JsonArray ?: invalid()).map { it.obj() }
            val recipients = values.map(SynologyPhotoSharingCodec::recipient)
            if (recipients.map { it.id }.distinct().size != recipients.size) invalid()
            recipients to values.mapIndexed { index, value ->
                SynologyPhotoShareGrant(recipients[index].id, value.text("role").takeIf { it.isNotEmpty() } ?: invalid())
            }
        }.getOrNull()
        val revision = SynologyPhotoSharingCodec.digest(buildJsonObject {
            put("profile", profileId); put("id", folder.id); put("path", folder.path); put("parent", folder.parentId!!)
            put("shared", shared); put("sharing", info); put("parentShared", parentShared); put("apply", apply)
        })
        return SynologyPhotoFolderSharing(SynologyPhotoFolderSharingSnapshot(folder, revision, access, members?.second,
            info.optionalBoolean("enable_password"), parentShared, apply), members?.first.orEmpty(), url)
    }

    fun validate(change: SynologyPhotoFolderSharingChange) {
        val original = change.original
        SynologyPhotoFolderCodec.validate(original.folder)
        if (!eligible(original.folder) || original.folder.parentId == null || original.folder.parentId <= 0 ||
            !original.revision.matches(Regex("[0-9a-f]{64}")) || original.inheritsManagementOnly ||
            original.depth == 2 && change.appliesToSubfolders != original.appliesToSubfolders) invalid()
        fun valid(members: List<SynologyPhotoShareGrant>) {
            if (members.map { it.id }.distinct().size != members.size || members.any {
                it.id.type !in setOf("user", "group") || !SynologyPhotoSharingCodec.validId(it.id.value) || it.role.isEmpty()
            }) invalid()
        }
        original.members?.let(::valid)
        change.members?.let { desired ->
            valid(desired)
            val before = SynologyPhotoSharingCodec.roles(original.members ?: invalid())
            if (desired.any { before[it.id] != it.role && it.role !in setOf("view", "download", "upload", "manage") }) invalid()
        }
    }

    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val checkpoint = row.folderSharing ?: invalid(); validate(checkpoint.change)
        if (row.album != null || row.name != null || row.targets.isNotEmpty() ||
            !row.submitted && (checkpoint.updateAttempted || checkpoint.updateAcknowledged || checkpoint.configAttempted || checkpoint.rejected) ||
            checkpoint.updateAcknowledged && !checkpoint.updateAttempted || checkpoint.rejected && (checkpoint.updateAcknowledged || checkpoint.configAttempted) ||
            checkpoint.configAttempted && (!checkpoint.updateAcknowledged || checkpoint.change.appliesToSubfolders == checkpoint.change.original.appliesToSubfolders) ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && (!checkpoint.updateAttempted || checkpoint.rejected ||
                (checkpoint.change.password == SynologyPhotoSharingPassword.SET || checkpoint.change.appliesToSubfolders) && !checkpoint.updateAcknowledged) ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && !checkpoint.rejected && !checkpoint.updateAttempted) invalid()
    }

    /** 目录契约使用扁平成员；名单变化时保留项也必须发送，删除携带原角色。 */
    fun memberChanges(change: SynologyPhotoFolderSharingChange): List<JsonObject> {
        val desired = change.members ?: return emptyList()
        val original = change.original.members ?: invalid()
        if (SynologyPhotoSharingCodec.roles(original) == SynologyPhotoSharingCodec.roles(desired)) return emptyList()
        val after = desired.mapTo(mutableSetOf()) { it.id }
        fun entry(grant: SynologyPhotoShareGrant, remove: Boolean) = buildJsonObject {
            put("id", grant.id.value); put("type", grant.id.type); put("role", grant.role)
            put("action", if (remove) "delete" else "update")
        }
        return original.filter { it.id !in after }.map { entry(it, true) } + desired.map { entry(it, false) }
    }
}
