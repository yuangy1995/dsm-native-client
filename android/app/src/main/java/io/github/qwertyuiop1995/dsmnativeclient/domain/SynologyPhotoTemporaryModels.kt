package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

/** 完整分页成员只留身份摘要；分享秘密和媒体内容不进入恢复记录。 */
@Serializable
data class SynologyPhotoTemporarySnapshot(
    val sharing: SynologyPhotoSharingSnapshot, val membersDigest: String, val itemCount: Int,
) {
    override fun toString() = "PhotoTemporarySnapshot"
}
@Serializable
data class SynologyPhotoTemporaryChange(
    val original: SynologyPhotoTemporarySnapshot, val keepCopy: Boolean,
    val preservedCopyId: Long? = null,
) {
    override fun toString() = "PhotoTemporaryChange"
}
data class SynologyPhotoTemporaryAlbum(val album: SynologyPhotoAlbumSnapshot, val snapshot: SynologyPhotoTemporarySnapshot)
