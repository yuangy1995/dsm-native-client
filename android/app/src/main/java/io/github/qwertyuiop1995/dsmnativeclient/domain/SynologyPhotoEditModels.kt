package io.github.qwertyuiop1995.dsmnativeclient.domain

import java.util.UUID
import kotlinx.serialization.Serializable

/** 恢复只保存原件身份与目标值，不序列化 EXIF、GPS、媒体或会话。 */
@Serializable
data class SynologyPhotoEditTarget(
    val id: SynologyPhotoId,
    val filename: String,
    val sizeBytes: Long,
    val takenAt: Double,
    val indexedAt: Double,
    val folderId: Long,
    val mediaType: String,
    val albumContext: SynologyPhotoAlbumContext? = null,
) {
    constructor(photo: SynologyPhoto) : this(photo.id, photo.filename, photo.sizeBytes, photo.takenAt,
        photo.indexedAt, photo.folderId, photo.mediaType, photo.albumContext)
    fun photo() = SynologyPhoto(id, filename, sizeBytes, takenAt, indexedAt, folderId, mediaType, albumContext = albumContext)
    fun matches(photo: SynologyPhoto, includeTime: Boolean = false): Boolean = id == photo.id &&
        filename == photo.filename && sizeBytes == photo.sizeBytes && indexedAt == photo.indexedAt &&
        folderId == photo.folderId && mediaType == photo.mediaType && (!includeTime || takenAt == photo.takenAt) &&
        albumContext?.albumId == photo.albumContext?.albumId && albumContext?.ownerUserId == photo.albumContext?.ownerUserId
    override fun toString() = "PhotoEditTarget"
}

@Serializable
sealed interface SynologyPhotoEdit {
    /** 非幂等旋转仅保存原方向/尺寸；成功回执只在当前仓储内存中使用。 */
    @Serializable data class Rotation(val orientation: Int, val width: Int?, val height: Int?) : SynologyPhotoEdit {
        val expectedOrientation: Int? get() = if (orientation in 1..8) listOf(8, 5, 6, 7, 4, 1, 2, 3)[orientation - 1] else null
    }
    @Serializable data class Rating(val value: Int) : SynologyPhotoEdit
    @Serializable data class Description(val value: String) : SynologyPhotoEdit { override fun toString() = "PhotoDescription" }
    @Serializable data class TakenAt(val seconds: Long) : SynologyPhotoEdit
    @Serializable data class ShiftDates(val seconds: Long) : SynologyPhotoEdit
    @Serializable data class AddTags(val ids: List<Long>) : SynologyPhotoEdit
    @Serializable data class RemoveTags(val ids: List<Long>) : SynologyPhotoEdit
    @Serializable data class CreateTag(val name: String) : SynologyPhotoEdit { override fun toString() = "PhotoTagCreation" }
}

@Serializable
enum class SynologyPhotoEditPhase { READY, SUBMITTING, PENDING, COMPLETED, PARTIAL }

@Serializable
data class SynologyPhotoEditCheckpoint(
    val version: Int = 1,
    val profileId: String,
    val userId: Long,
    val operationId: String = UUID.randomUUID().toString(),
    val space: SynologyPhotoSpace,
    val targets: List<SynologyPhotoEditTarget>,
    val edit: SynologyPhotoEdit,
    val phase: SynologyPhotoEditPhase = SynologyPhotoEditPhase.READY,
    val attempted: Set<Int> = emptySet(),
    val completed: Set<Int> = emptySet(),
    val reportedFailures: Set<Int> = emptySet(),
    val createdTag: SynologyPhotoChoice? = null,
) {
    val submitted: Boolean get() = phase != SynologyPhotoEditPhase.READY
    val finished: Boolean get() = phase == SynologyPhotoEditPhase.COMPLETED || phase == SynologyPhotoEditPhase.PARTIAL
    val permitsMixedSpaces: Boolean get() = edit is SynologyPhotoEdit.Rating || edit is SynologyPhotoEdit.TakenAt || edit is SynologyPhotoEdit.ShiftDates
    fun sameOperation(other: SynologyPhotoEditCheckpoint) = copy(phase = other.phase, attempted = other.attempted,
        completed = other.completed, reportedFailures = other.reportedFailures, createdTag = other.createdTag) == other
    override fun toString() = "PhotoEditCheckpoint(phase=$phase, count=${targets.size})"
}
