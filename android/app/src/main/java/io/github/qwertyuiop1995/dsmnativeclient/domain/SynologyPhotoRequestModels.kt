package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

/** 收集口令与目标相册口令只存在于当前会话；此组草稿不参与持久化。 */
data class SynologyPhotoRequestSettings(
    val subject: String = "", val description: String = "",
    val space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL,
    val folderPath: String = "", val folderId: Long? = null,
    val albumId: Long? = null, val albumPassphrase: String? = null,
    val expiration: Long = 0, val sizeLimit: Long = 0,
) {
    override fun toString() = "PhotoRequestSettings"
    companion object {
        fun defaultFolderPath(subject: String): String {
            val name = subject.trim().replace(Regex("^\\s*$|^\\.|\\.$|^@(?:database|eaDir|tmp|sharebin)$|^#(?:recycle|snapshot)$|[/\\\\:]"), "_")
            return if (subject.trim().isEmpty()) "/PhotoRequest" else "/PhotoRequest/$name"
        }
    }
}
data class SynologyPhotoRequest(
    val id: String, val profileId: String, val settings: SynologyPhotoRequestSettings,
    val isFolderValid: Boolean, val albumName: String? = null, val url: String? = null,
) { override fun toString() = "PhotoRequest" }
data class SynologyPhotoRequestAlbum(val albumId: Long? = null, val passphrase: String? = null, val name: String, val shared: Boolean, val sourceAlbumId: Long? = albumId) {
    override fun toString() = "PhotoRequestAlbum"
}
data class SynologyPhotoRequestChange(val original: SynologyPhotoRequest? = null, val settings: SynologyPhotoRequestSettings? = null) {
    override fun toString() = "PhotoRequestChange"
}

/** 只保存不可逆摘要；恢复必须重新枚举自有请求，不能把摘要当作请求口令。 */
@Serializable
data class SynologyPhotoRequestCheckpoint(
    val space: SynologyPhotoSpace, val targetDigest: String?, val settingsDigest: String?,
    val includesFolderId: Boolean, val originalDigest: String? = null,
)
