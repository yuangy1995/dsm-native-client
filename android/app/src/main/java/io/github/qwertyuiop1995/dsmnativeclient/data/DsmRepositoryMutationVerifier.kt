package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus

/**
 * 写操作的稳定结果映射。
 *
 * 调用方继续负责预检、重复提交保护、提交后回读与取消语义；本类只构造既有的
 * [MutationResult]，避免各领域重新解释状态或计数。
 */
internal class DsmRepositoryMutationVerifier {
    fun settingsResult(
        operation: String,
        status: MutationResultStatus,
        submitted: Boolean,
        total: Int,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        requiresRefresh: Boolean = false,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
    ): MutationResult = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = operation,
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = MutationResultCounts(succeeded, failed, unknown),
        errorCategory = errorCategory,
        localizationKey = "mutation.service.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    ).also { check(total >= succeeded + failed + unknown) }

    fun serviceResult(
        operation: String,
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
        affectedCount: Int = 1,
    ): MutationResult {
        val succeeded = if (status == MutationResultStatus.CONFIRMED_SUCCESS) affectedCount else 0
        val unknown = if (
            status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED ||
            status == MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
        ) {
            affectedCount
        } else {
            0
        }
        val failed = if (
            status in setOf(
                MutationResultStatus.CONFIRMED_FAILURE,
                MutationResultStatus.PERMISSION_DENIED,
                MutationResultStatus.UNSUPPORTED,
            )
        ) {
            affectedCount
        } else {
            0
        }
        return MutationResult(
            schemaVersion = 1,
            status = status,
            operation = operation,
            submitted = submitted,
            requiresRefresh = requiresRefresh,
            counts = MutationResultCounts(succeeded, failed, unknown),
            errorCategory = errorCategory,
            localizationKey = "mutation.service.${status.name.lowercase()}",
            diagnosticTag = diagnosticTag,
        )
    }

    fun asRepositoryFailure(error: Throwable): DsmFailure = error as? DsmFailure ?: DsmFailure(
        code = null,
        message = error.message ?: "Service request failed",
        recovery = "Refresh the list and check the current state.",
        kind = DsmErrorKind.UNKNOWN,
    )

    fun mutationErrorCategory(failure: DsmFailure): MutationErrorCategory = when (failure.kind) {
        DsmErrorKind.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
        DsmErrorKind.SESSION_EXPIRED,
        DsmErrorKind.AUTHENTICATION_FAILED,
        -> MutationErrorCategory.AUTHENTICATION
        DsmErrorKind.FEATURE_UNSUPPORTED,
        DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
        -> MutationErrorCategory.UNSUPPORTED
        DsmErrorKind.CONNECTION_FAILED,
        DsmErrorKind.INVALID_RESPONSE,
        -> MutationErrorCategory.NETWORK
        DsmErrorKind.CHANGE_NOT_CONFIRMED -> MutationErrorCategory.CONFLICT
        DsmErrorKind.UNKNOWN -> MutationErrorCategory.UNKNOWN
        else -> MutationErrorCategory.SERVER
    }
}
