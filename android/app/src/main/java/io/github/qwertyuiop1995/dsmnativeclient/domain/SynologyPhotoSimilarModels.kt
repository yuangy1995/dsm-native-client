package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

/** 相似分组使用真实成员编号；不按照片名称或当前页推断组内容。 */
@Serializable
data class SynologyPhotoSimilarGroup(
    val profileId: String, val space: SynologyPhotoSpace, val id: Long,
    val photoIds: List<Long>, val topPickId: Long,
) {
    fun sameMembers(other: SynologyPhotoSimilarGroup): Boolean = profileId == other.profileId && space == other.space &&
        id == other.id && photoIds.toSet() == other.photoIds.toSet() && topPickId == other.topPickId
    override fun toString() = "PhotoSimilarGroup"
}

data class SynologyPhotoSimilarDetail(val group: SynologyPhotoSimilarGroup, val photos: List<SynologyPhoto>)
data class SynologyPhotoSimilarStatus(val waitingCount: Int, val stage: String, val migrationComplete: Boolean) {
    val visible: Boolean get() = waitingCount > 0 || !migrationComplete
    val running: Boolean get() = waitingCount > 0 && stage == "running"
}

@Serializable
enum class SynologyPhotoSimilarEdit { TOP_PICK, REMOVE, UNGROUP, UNDO }

/** 撤销依据来自已确认的原操作；恢复仍需重新读取完整原件和当前归组。 */
@Serializable
data class SynologyPhotoSimilarUndo(
    val operationId: String, val edit: SynologyPhotoSimilarEdit, val selectedIds: List<Long>,
    val resultingGroup: SynologyPhotoSimilarGroup?,
)

@Serializable
data class SynologyPhotoSimilarCheckpoint(
    val group: SynologyPhotoSimilarGroup, val edit: SynologyPhotoSimilarEdit,
    val selectedIds: List<Long> = emptyList(), val undo: SynologyPhotoSimilarUndo? = null,
    val batchOrder: List<String> = emptyList(),
    val attempted: Boolean = false, val rejected: Boolean = false, val confirmed: Boolean = false,
    val resultingGroup: SynologyPhotoSimilarGroup? = null,
) {
    val canUndo: Boolean get() = confirmed && edit in setOf(SynologyPhotoSimilarEdit.REMOVE, SynologyPhotoSimilarEdit.UNGROUP)
    fun sameIntent(other: SynologyPhotoSimilarCheckpoint) = copy(attempted = other.attempted, rejected = other.rejected,
        confirmed = other.confirmed, resultingGroup = other.resultingGroup) == other
    override fun toString() = "PhotoSimilarCheckpoint"
}
