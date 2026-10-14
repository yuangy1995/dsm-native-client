package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
enum class SynologyPhotoTransferDuplicate(val value: String) { SKIP("skip"), OVERWRITE("overwrite") }

/** 后台任务只保存固定意图、可靠编号和计数，不保存服务端原始响应。 */
@Serializable
data class SynologyPhotoFileCheckpoint(
    val space: SynologyPhotoSpace,
    val folders: List<SynologyPhotoFolderSnapshot> = emptyList(),
    val destination: SynologyPhotoFolderSnapshot? = null,
    val duplicate: SynologyPhotoTransferDuplicate? = null,
    val taskId: Long? = null,
    val total: Long? = null,
    val targetVerified: Boolean = false,
    val result: SynologyPhotoFileResult? = null,
) {
    override fun toString() = "PhotoFileCheckpoint"
}

@Serializable
data class SynologyPhotoFileResult(val completion: Long, val errors: Long, val skipped: Long, val overwritten: Long)
