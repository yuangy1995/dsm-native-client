package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.CancellationException
import java.io.InputStream
import java.util.UUID

/**
 * 由系统文件选择器提供的只读上传来源，不保存本地真实路径。
 * `requestToken` 只用于当前进程内的重复提交保护，不包含 URI、路径或文件内容。
 */
data class UploadSource(
    val displayName: String,
    val contentType: String?,
    val contentLength: Long,
    val openInputStream: () -> InputStream,
    val requestToken: String = UUID.randomUUID().toString(),
    val onContentRead: (UploadContentFingerprint) -> Unit = {},
)

internal fun requireConfirmedUploadMutation(result: MutationResult) {
    if (result.errorCategory == MutationErrorCategory.VALIDATION) {
        throw IllegalArgumentException("Invalid upload request")
    }
    when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> return
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> throw CancellationException("upload cancelled")
        else -> throw DsmFailure(
            null,
            "The NAS did not confirm the uploaded file",
            "Refresh the folder before uploading again.",
            kind = when (result.status) {
                MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                else -> if (result.diagnosticTag == "file-station.upload.length-mismatch") {
                    DsmErrorKind.UPLOAD_LENGTH_MISMATCH
                } else {
                    DsmErrorKind.CHANGE_NOT_CONFIRMED
                }
            },
        )
    }
}
