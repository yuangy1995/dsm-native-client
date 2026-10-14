package io.github.qwertyuiop1995.dsmnativeclient.domain

import java.time.LocalDate
import java.time.ZoneId
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonPrimitive

@Serializable
enum class SynologyPhotoLinkAccess { DISABLED, INVITED, VIEW, DOWNLOAD }
@Serializable
enum class SynologyPhotoSharingPassword { UNCHANGED, SET, REMOVE }

/** user/group 与数字/字符串编号均属于身份，不转换后合并。 */
@Serializable
data class SynologyPhotoShareMemberId(val type: String, val value: JsonPrimitive) {
    override fun toString() = "PhotoShareMemberId"
}
@Serializable
data class SynologyPhotoShareGrant(val id: SynologyPhotoShareMemberId, val role: String) {
    override fun toString() = "PhotoShareGrant"
}
data class SynologyPhotoShareRecipient(val id: SynologyPhotoShareMemberId, val name: String) {
    override fun toString() = "PhotoShareRecipient"
}

/** 恢复只保存成员身份、角色与保护摘要，不含名称、链接、分享口令或密码。 */
@Serializable
data class SynologyPhotoSharingSnapshot(
    val revision: String, val access: SynologyPhotoLinkAccess,
    val members: List<SynologyPhotoShareGrant>?, val hasPassword: Boolean?,
    val expiration: Long?, val expirationDigest: String,
) {
    override fun toString() = "PhotoSharingSnapshot"
}
@Serializable
data class SynologyPhotoSharingChange(
    val original: SynologyPhotoSharingSnapshot, val access: SynologyPhotoLinkAccess,
    val members: List<SynologyPhotoShareGrant>? = null, val expiration: Long? = null,
    val password: SynologyPhotoSharingPassword = SynologyPhotoSharingPassword.UNCHANGED,
) {
    override fun toString() = "PhotoSharingChange"
}
data class SynologyPhotoAlbumSharing(
    val album: SynologyPhotoAlbumSnapshot, val snapshot: SynologyPhotoSharingSnapshot,
    val recipients: List<SynologyPhotoShareRecipient>, val url: String?,
    val linkPolicy: SynologyPhotoLinkAccess?,
) {
    override fun toString() = "PhotoAlbumSharing"
}

/** 使用所选本地日的结束秒数，自动处理夏令时的短日和长日。 */
fun photoSharingExpiration(date: LocalDate, zone: ZoneId): Long = date.plusDays(1).atStartOfDay(zone).toEpochSecond() - 1
