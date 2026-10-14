package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable
import java.util.UUID

/** 上传目标在批次创建时固定；相册贡献不推导原照片空间权限。 */
@Serializable
sealed interface SynologyPhotoUploadTarget {
    @Serializable data class Timeline(val space: SynologyPhotoSpace) : SynologyPhotoUploadTarget
    @Serializable data class Folder(val space: SynologyPhotoSpace, val id: Long) : SynologyPhotoUploadTarget
    @Serializable data class Album(val id: Long) : SynologyPhotoUploadTarget
}

@Serializable
enum class SynologyPhotoUploadDuplicate(val value: String) { RENAME("rename"), IGNORE("ignore") }

@Serializable
sealed interface SynologyPhotoUploadAction {
    @Serializable data class Upload(
        val target: SynologyPhotoUploadTarget,
        val filename: String,
        val size: Long,
        val modifiedAtSeconds: Long,
        val sha256: String,
        val duplicate: SynologyPhotoUploadDuplicate,
    ) : SynologyPhotoUploadAction {
        override fun toString() = "PhotoUpload(size=$size)"
    }
    @Serializable data class CreateFolder(val space: SynologyPhotoSpace, val parentId: Long, val name: String) : SynologyPhotoUploadAction {
        override fun toString() = "PhotoUploadFolder"
    }
}

@Serializable
enum class SynologyPhotoUploadPhase { READY, SUBMITTING, PENDING, COMPLETED, SKIPPED }

/** 只保存恢复所需编号与快照，不含会话、分享口令和外部 URI。已提交状态只允许回读。 */
@Serializable
data class SynologyPhotoUploadCheckpoint(
    val version: Int = 1,
    val profileId: String,
    val userId: Long,
    val operationId: String = UUID.randomUUID().toString(),
    val action: SynologyPhotoUploadAction,
    val phase: SynologyPhotoUploadPhase = SynologyPhotoUploadPhase.READY,
    val itemId: Long? = null,
    val folderId: Long? = null,
    val uploadAction: String? = null,
) {
    val finished: Boolean get() = phase in setOf(SynologyPhotoUploadPhase.COMPLETED, SynologyPhotoUploadPhase.SKIPPED)
    val submitted: Boolean get() = phase != SynologyPhotoUploadPhase.READY
    fun sameOperation(other: SynologyPhotoUploadCheckpoint): Boolean =
        copy(phase = other.phase, itemId = other.itemId, folderId = other.folderId, uploadAction = other.uploadAction) == other
    override fun toString() = "PhotoUploadCheckpoint(phase=$phase)"
}

internal fun SynologyPhotoUploadTarget.sourceSpace(): SynologyPhotoSpace? = when (this) {
    is SynologyPhotoUploadTarget.Timeline -> space
    is SynologyPhotoUploadTarget.Folder -> space
    is SynologyPhotoUploadTarget.Album -> null
}
