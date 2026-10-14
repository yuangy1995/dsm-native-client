package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
enum class SynologyPhotoFolderLinkAccess(val value: String) {
    MANAGEMENT("management"), INVITED("private"), VIEW("public-view"), DOWNLOAD("public-download")
}

/** 分享响应只保留不可逆修订及恢复所需状态；姓名、链接与密码不进入存储。 */
@Serializable
data class SynologyPhotoFolderSharingSnapshot(
    val folder: SynologyPhotoFolderSnapshot, val revision: String,
    val access: SynologyPhotoFolderLinkAccess, val members: List<SynologyPhotoShareGrant>?,
    val hasPassword: Boolean?, val parentIsShared: Boolean, val appliesToSubfolders: Boolean,
) {
    val depth: Int get() = folder.path.count { it == '/' }
    val inheritsManagementOnly: Boolean get() = depth == 2 && !parentIsShared
    override fun toString() = "PhotoFolderSharingSnapshot"
}

data class SynologyPhotoFolderSharing(
    val snapshot: SynologyPhotoFolderSharingSnapshot, val recipients: List<SynologyPhotoShareRecipient>, val url: String,
) {
    override fun toString() = "PhotoFolderSharing"
}

@Serializable
data class SynologyPhotoFolderSharingChange(
    val original: SynologyPhotoFolderSharingSnapshot, val access: SynologyPhotoFolderLinkAccess,
    val members: List<SynologyPhotoShareGrant>? = null,
    val password: SynologyPhotoSharingPassword = SynologyPhotoSharingPassword.UNCHANGED,
    val appliesToSubfolders: Boolean = original.appliesToSubfolders,
) {
    val needsConfirmation: Boolean get() = access != original.access ||
        members?.associate { it.id to it.role }?.let { it != original.members?.associate { grant -> grant.id to grant.role } } == true ||
        password == SynologyPhotoSharingPassword.REMOVE || appliesToSubfolders
    val hasChanges: Boolean get() = needsConfirmation || password != SynologyPhotoSharingPassword.UNCHANGED ||
        appliesToSubfolders != original.appliesToSubfolders
    override fun toString() = "PhotoFolderSharingChange"
}

@Serializable
data class SynologyPhotoFolderSharingCheckpoint(
    val change: SynologyPhotoFolderSharingChange,
    val updateAttempted: Boolean = false, val updateAcknowledged: Boolean = false,
    val configAttempted: Boolean = false, val rejected: Boolean = false,
) {
    override fun toString() = "PhotoFolderSharingCheckpoint"
}
