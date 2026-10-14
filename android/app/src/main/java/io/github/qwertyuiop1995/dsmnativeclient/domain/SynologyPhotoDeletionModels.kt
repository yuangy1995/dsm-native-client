package io.github.qwertyuiop1995.dsmnativeclient.domain

import java.security.MessageDigest
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

@Serializable
enum class SynologyPhotoDeletionPhase { PREPARED, SUBMITTED, CONFIRMED, REJECTED, CANCELLED }

/** 原件身份摘要不保存名称、拍摄/索引日期正文，也不能用作重新提交删除的照片。 */
@Serializable
data class SynologyPhotoDeletionTarget(
    val id: SynologyPhotoId,
    val folderId: Long,
    val mediaType: String,
    val identityDigest: String,
    val albumContext: SynologyPhotoAlbumContext? = null,
) {
    constructor(photo: SynologyPhoto) : this(photo.id, photo.folderId, photo.mediaType, digest(photo), photo.albumContext)

    fun matches(photo: SynologyPhoto, includeContext: Boolean = true): Boolean = id == photo.id &&
        folderId == photo.folderId && mediaType == photo.mediaType && identityDigest == digest(photo) &&
        (!includeContext || albumContext == photo.albumContext)

    override fun toString() = "PhotoDeletionTarget(space=${id.space})"

    companion object {
        private fun digest(photo: SynologyPhoto): String {
            if (photo.sizeBytes < 0 || !photo.takenAt.isFinite() || !photo.indexedAt.isFinite()) invalid()
            val data = JsonArray(listOf(JsonPrimitive(photo.filename), JsonPrimitive(photo.sizeBytes),
                JsonPrimitive(photo.takenAt), JsonPrimitive(photo.indexedAt))).toString().toByteArray(Charsets.UTF_8)
            return MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
        }
        private fun invalid(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
    }
}

@Serializable
data class SynologyPhotoDeletionCheckpoint(
    val version: Int = 1,
    val operationId: String = UUID.randomUUID().toString(),
    val userId: Long,
    val target: SynologyPhotoDeletionTarget,
    val phase: SynologyPhotoDeletionPhase = SynologyPhotoDeletionPhase.PREPARED,
) {
    val finished: Boolean get() = phase in setOf(SynologyPhotoDeletionPhase.CONFIRMED,
        SynologyPhotoDeletionPhase.REJECTED, SynologyPhotoDeletionPhase.CANCELLED)
    fun sameOperation(other: SynologyPhotoDeletionCheckpoint): Boolean = copy(phase = other.phase) == other
    fun validate() {
        val context = target.albumContext
        if (version != 1 || runCatching { UUID.fromString(operationId).toString() == operationId }.getOrDefault(false).not() ||
            userId <= 0 || target.id.profileId.isBlank() || target.id.itemId <= 0 || target.folderId <= 0 || target.mediaType.isBlank() ||
            !target.identityDigest.matches(Regex("[0-9a-f]{64}")) || context != null &&
            (context.albumId <= 0 || context.ownerUserId < 0 || context.providerUserId?.let { it <= 0 } == true ||
                target.id.space != if (context.ownerUserId == 0L) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL))
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
    }
    override fun toString() = "PhotoDeletionCheckpoint(phase=$phase)"
}
