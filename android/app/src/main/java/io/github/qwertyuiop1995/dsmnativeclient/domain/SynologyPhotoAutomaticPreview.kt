package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

/** 来自当前设备的实际转换能力；不按系统名称推定HEVC或VC1可用。 */
@Serializable
data class SynologyPhotoPreviewConversionSupport(val hevc: Boolean, val video: Boolean, val vc1: Boolean) {
    val available: Boolean get() = hevc || video
}

@Serializable
enum class SynologyPhotoAutomaticPreviewPriority { STANDARD, HEVC_OR_LIVE_VIDEO, VC1, BACKGROUND }

/** Unit是媒体单元，source是可选的原件身份，二者编号不能互相代替。 */
@Serializable
data class SynologyPhotoAutomaticPreviewTask(
    val profileId: String, val space: SynologyPhotoSpace, val unitId: Long,
    val filename: String, val typeCode: Int, val needsThumbnail: Boolean, val needsVideo: Boolean,
    val source: SynologyPhotoEditTarget? = null, val sourceThumbnailUnitId: Long? = null,
    val priority: SynologyPhotoAutomaticPreviewPriority = SynologyPhotoAutomaticPreviewPriority.BACKGROUND,
) {
    val video: Boolean get() = typeCode != 0

    /** 可见项与后台批次的来源/视频类型码可以不同，同单元同需求只执行一次。 */
    fun sameMedia(other: SynologyPhotoAutomaticPreviewTask): Boolean = profileId == other.profileId && space == other.space &&
        unitId == other.unitId && filename == other.filename && video == other.video &&
        needsThumbnail == other.needsThumbnail && needsVideo == other.needsVideo
    override fun toString() = "PhotoAutomaticPreviewTask(video=$video)"
}

@Serializable
enum class SynologyPhotoAutomaticPreviewFailure { PHOTO, VIDEO }

/** 摘要与写入事实只追加；文件、凭据和临时路径不进入管理记录。 */
@Serializable
data class SynologyPhotoAutomaticPreviewCheckpoint(
    val task: SynologyPhotoAutomaticPreviewTask, val support: SynologyPhotoPreviewConversionSupport,
    val thumbnailDigests: Map<String, String> = emptyMap(),
    val videoSignature: SynologyPhotoPreviewVideoSignature? = null,
    val uploadAttempted: Boolean = false, val uploadAcknowledged: Boolean = false, val uploadRejected: Boolean = false,
    val failureKind: SynologyPhotoAutomaticPreviewFailure? = null,
    val failureRecorded: Boolean = false, val failureRejected: Boolean = false,
) {
    fun sameIntent(other: SynologyPhotoAutomaticPreviewCheckpoint) = task == other.task && support == other.support
    override fun toString() = "PhotoAutomaticPreviewCheckpoint(uploadAttempted=$uploadAttempted, failureKind=$failureKind)"
}
