package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
enum class SynologyPhotoMaintenanceAction(val value: String) { INDEX("basic"), PREVIEWS("thumbnail") }

/** 计数仅表示对应索引阶段，不代表所有识别与后台任务已经结束。 */
@Serializable
data class SynologyPhotoMaintenanceStatus(
    val profileId: String, val userId: Long, val space: SynologyPhotoSpace,
    val indexingCount: Long, val previewCount: Long, val supportsPreviews: Boolean,
) {
    fun count(action: SynologyPhotoMaintenanceAction): Long = if (action == SynologyPhotoMaintenanceAction.INDEX) indexingCount else previewCount
    fun canStart(action: SynologyPhotoMaintenanceAction): Boolean = userId > 0 && indexingCount >= 0 && previewCount >= 0 && count(action) == 0L &&
        (action == SynologyPhotoMaintenanceAction.INDEX || supportsPreviews)
}

/** 没有任务编号，必须分别保存尝试、接收回执与明确拒绝，冷恢复不能重放。 */
@Serializable
data class SynologyPhotoMaintenanceCheckpoint(
    val original: SynologyPhotoMaintenanceStatus, val action: SynologyPhotoMaintenanceAction,
    val attempted: Boolean = false, val acknowledged: Boolean = false, val rejected: Boolean = false,
)
