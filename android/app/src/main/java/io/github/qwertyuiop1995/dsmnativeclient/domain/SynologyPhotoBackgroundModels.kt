package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
enum class SynologyPhotoBackgroundStatus(val value: String) {
    WAITING("waiting"), PROCESSING("processing"), ABORTING("aborting"), DONE("done"), UNKNOWN("unknown"),
}

/** 任务身份不包含进度；同编号换了创建时间、操作或目标时不能继续控制。 */
@Serializable
data class SynologyPhotoBackgroundSnapshot(
    val id: Long, val operation: String, val status: SynologyPhotoBackgroundStatus,
    val total: Long, val createdAt: Double, val targetFolderId: Long?, val targetOwnerId: Long?,
) {
    val isTransfer: Boolean get() = operation == "copy" || operation == "move"
    val canStop: Boolean get() = isTransfer && status in setOf(SynologyPhotoBackgroundStatus.WAITING, SynologyPhotoBackgroundStatus.PROCESSING)
    val canClear: Boolean get() = isTransfer && status == SynologyPhotoBackgroundStatus.DONE
    fun sameIdentity(other: SynologyPhotoBackgroundSnapshot) = copy(status = other.status) == other
    fun targetSpace(userId: Long): SynologyPhotoSpace? = when (targetOwnerId) {
        0L -> SynologyPhotoSpace.SHARED
        userId -> SynologyPhotoSpace.PERSONAL
        else -> null
    }
    override fun toString() = "PhotoBackgroundSnapshot(status=$status)"
}

data class SynologyPhotoBackgroundTask(
    val profileId: String, val userId: Long, val snapshot: SynologyPhotoBackgroundSnapshot,
    val completion: Long, val errors: Long, val skipped: Long, val overwritten: Long,
) {
    val id: Long get() = snapshot.id
    val successful: Long get() = completion - errors
    val stopped: Boolean get() = snapshot.status == SynologyPhotoBackgroundStatus.DONE && completion < snapshot.total
    val targetSpace: SynologyPhotoSpace? get() = snapshot.targetSpace(userId)
    val canOpenTarget: Boolean get() = snapshot.isTransfer && snapshot.status == SynologyPhotoBackgroundStatus.DONE &&
        (stopped || errors == 0L || successful > 0) && targetSpace != null && snapshot.targetFolderId != null
    fun sameIdentity(other: SynologyPhotoBackgroundTask) = profileId == other.profileId && userId == other.userId && snapshot.sameIdentity(other.snapshot)
    override fun toString() = "PhotoBackgroundTask(status=${snapshot.status})"
}

data class SynologyPhotoBackgroundError(
    val kind: Kind, val itemId: Long, val reason: Reason, val name: String? = null, val folderPath: String? = null,
) {
    enum class Kind(val value: String) { ITEM("item"), FOLDER("folder"), UNKNOWN("unknown") }
    enum class Reason(val value: String) {
        QUOTA("quota_full"), SPACE("space_full"), SUBFOLDER("skipped"), MISSING("not_existed"),
        TARGET_MISSING("target_not_existed"), EXCLUDED("excluded_extension"), UNKNOWN("unknown"),
    }
    val key: String get() = "${kind.name}:$itemId"
    override fun toString() = "PhotoBackgroundError(kind=$kind, reason=$reason)"
}

/** 与原搬移分开的操作记录；只保存确认范围与逐项结果，不保存名称、路径或响应。 */
@Serializable
data class SynologyPhotoBackgroundCheckpoint(
    val tasks: List<SynologyPhotoBackgroundSnapshot>,
    val attempted: Set<Long> = emptySet(), val rejected: Set<Long> = emptySet(), val completed: Set<Long> = emptySet(),
) {
    override fun toString() = "PhotoBackgroundCheckpoint"
}
