package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

/** 恢复只保存稳定身份、权限和受保护标记；成员显示名只在表单内存中使用。 */
@Serializable
data class SynologyPhotoSharedMemberGrant(
    val id: SynologyPhotoShareMemberId, val role: String, val autoBackup: Boolean, val protected: Boolean = false,
) {
    val canEdit: Boolean get() = !protected && role in setOf("entry", "management")
    fun changingRole(value: String): SynologyPhotoSharedMemberGrant =
        if (!canEdit || value !in setOf("entry", "management")) this
        else copy(role = value, autoBackup = if (value == "management") true else autoBackup)
    override fun toString() = "PhotoSharedMemberGrant"
}

data class SynologyPhotoSharedMember(val recipient: SynologyPhotoShareRecipient, val grant: SynologyPhotoSharedMemberGrant) {
    override fun toString() = "PhotoSharedMember"
}

@Serializable
data class SynologyPhotoSharedMembersSnapshot(
    val profileId: String, val administratorId: Long, val enabled: Boolean, val members: List<SynologyPhotoSharedMemberGrant>,
) {
    fun sameMembers(other: SynologyPhotoSharedMembersSnapshot): Boolean =
        profileId == other.profileId && administratorId == other.administratorId && enabled == other.enabled &&
            members.associateBy { it.id } == other.members.associateBy { it.id }
    override fun toString() = "PhotoSharedMembersSnapshot"
}

data class SynologyPhotoSharedMembers(val snapshot: SynologyPhotoSharedMembersSnapshot, val members: List<SynologyPhotoSharedMember>) {
    override fun toString() = "PhotoSharedMembers"
}

@Serializable
enum class SynologyPhotoFolderMemberRole(val value: String) {
    VIEW("view"), DOWNLOAD("download"), UPLOAD("upload"), MANAGE("manage");
    companion object { fun from(value: String?) = entries.firstOrNull { it.value == value } }
}

/** 目录名称参与不可逆身份摘要，但不写入成员恢复记录。 */
@Serializable
data class SynologyPhotoMemberFolderSnapshot(
    val id: Long, val parentId: Long, val rootId: Long, val depth: Int, val identity: String,
    val privacy: String, val directRole: String?, val revision: String,
) {
    val publicRole: SynologyPhotoFolderMemberRole? get() = when (privacy) {
        "public-view" -> SynologyPhotoFolderMemberRole.VIEW
        "public-download" -> SynologyPhotoFolderMemberRole.DOWNLOAD
        else -> null
    }
    val known: Boolean get() = privacy in setOf("private", "public-view", "public-download") &&
        (directRole == null || SynologyPhotoFolderMemberRole.from(directRole) != null)
    fun effectiveLevel(role: String? = directRole): Int = maxOf(SynologyPhotoFolderMemberRole.from(role)?.ordinal ?: -1, publicRole?.ordinal ?: -1)
    override fun toString() = "PhotoMemberFolderSnapshot"
}

data class SynologyPhotoMemberFolder(val snapshot: SynologyPhotoMemberFolderSnapshot, val path: String) {
    override fun toString() = "PhotoMemberFolder"
}

@Serializable
data class SynologyPhotoMemberFolderBatch(val role: SynologyPhotoFolderMemberRole, val grant: Boolean) {
    val action: String get() = if (grant) "check_all" else "uncheck_all"
    fun applying(value: String?): String? {
        val level = SynologyPhotoFolderMemberRole.from(value)?.ordinal ?: -1
        return if (grant) { if (level <= role.ordinal) role.value else value }
        else if (level >= role.ordinal) SynologyPhotoFolderMemberRole.entries.getOrNull(role.ordinal - 1)?.value else value
    }
}

@Serializable
data class SynologyPhotoMemberFolderChange(val folderId: Long, val role: SynologyPhotoFolderMemberRole?)

@Serializable
data class SynologyPhotoMemberFolderEdit(
    val member: SynologyPhotoShareMemberId, val original: List<SynologyPhotoMemberFolderSnapshot>,
    val batch: SynologyPhotoMemberFolderBatch? = null, val changes: List<SynologyPhotoMemberFolderChange> = emptyList(),
) {
    fun expectedRole(folder: SynologyPhotoMemberFolderSnapshot, includingChanges: Boolean = true): String? {
        fun own(item: SynologyPhotoMemberFolderSnapshot): String? {
            if (includingChanges) changes.firstOrNull { it.folderId == item.id }?.let { return it.role?.value }
            return batch?.applying(item.directRole) ?: if (batch == null) item.directRole else null
        }
        if (includingChanges && folder.depth == 1) original.firstOrNull { it.id == folder.parentId }?.let { parent ->
            if (parent.privacy == "private" && parent.directRole != null && own(parent) == null) return null
        }
        return own(folder)
    }
    fun canEdit(folder: SynologyPhotoMemberFolderSnapshot): Boolean {
        if (!folder.known) return false
        if (folder.depth == 0) return true
        val parent = original.firstOrNull { it.id == folder.parentId } ?: return false
        return parent.known && (parent.publicRole != null || expectedRole(parent) != null)
    }
    val canSave: Boolean get() = original.isNotEmpty() && original.map { it.id }.distinct().size == original.size &&
        changes.map { it.folderId }.distinct().size == changes.size && (batch == null || original.all { it.known }) &&
        changes.all { change -> original.firstOrNull { it.id == change.folderId }?.let(::canEdit) == true } &&
        original.any { it.known && it.effectiveLevel(expectedRole(it)) != it.effectiveLevel() }
    fun withRole(folder: SynologyPhotoMemberFolderSnapshot, role: SynologyPhotoFolderMemberRole?): SynologyPhotoMemberFolderEdit {
        if (!canEdit(folder)) return this
        val removed = if (folder.depth == 0 && folder.privacy == "private" && role == null)
            original.filter { it.parentId == folder.id }.mapTo(mutableSetOf()) { it.id } else emptySet()
        return copy(changes = changes.filter { it.folderId != folder.id && it.folderId !in removed } + SynologyPhotoMemberFolderChange(folder.id, role))
    }
    fun withBatch(next: SynologyPhotoMemberFolderBatch): SynologyPhotoMemberFolderEdit {
        if (original.any { !it.known }) return this
        val desired = original.associate { it.id to next.applying(expectedRole(it)) }
        val updates = original.mapNotNull { folder ->
            if (desired[folder.id] == next.applying(folder.directRole)) null
            else SynologyPhotoMemberFolderChange(folder.id, SynologyPhotoFolderMemberRole.from(desired[folder.id]))
        }
        val draft = copy(batch = next, changes = updates)
        return draft.copy(changes = updates.filter { change -> draft.canEdit(original.first { it.id == change.folderId }) })
    }
    override fun toString() = "PhotoMemberFolderEdit"
}

/** 每个写步骤先落盘再发送；中断后的恢复仅读取已尝试步骤。 */
@Serializable
data class SynologyPhotoSharedMembersCheckpoint(
    val original: SynologyPhotoSharedMembersSnapshot, val desired: List<SynologyPhotoSharedMemberGrant>,
    val folders: List<SynologyPhotoMemberFolderEdit> = emptyList(),
    val attempted: Set<Int> = emptySet(), val acknowledged: Set<Int> = emptySet(),
    val rejected: Set<Int> = emptySet(), val completed: Set<Int> = emptySet(),
) {
    override fun toString() = "PhotoSharedMembersCheckpoint"
}
