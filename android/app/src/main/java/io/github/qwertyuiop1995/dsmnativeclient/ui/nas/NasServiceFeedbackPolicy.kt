package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.annotation.StringRes
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus

internal fun shouldReopenFileServiceEditor(
    saveRequested: Boolean,
    mutationInProgress: Boolean,
    mutationResult: MutationResult?,
    mutationFailure: DsmFailure?,
): Boolean = saveRequested && !mutationInProgress && mutationResult == null && mutationFailure == null

internal fun shouldReopenTerminalEditor(
    saveRequested: Boolean,
    mutationInProgress: Boolean,
    mutationResult: MutationResult?,
    mutationFailure: DsmFailure?,
): Boolean = saveRequested && !mutationInProgress && mutationResult == null && mutationFailure == null

internal fun shouldReopenProxyEditor(
    saveRequested: Boolean,
    mutationInProgress: Boolean,
    mutationResult: MutationResult?,
    mutationFailure: DsmFailure?,
): Boolean = saveRequested && !mutationInProgress && mutationResult == null && mutationFailure == null

internal data class FileServiceFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val canRefresh: Boolean,
    val mustRefreshBeforeEditing: Boolean,
    val isAssertive: Boolean,
)

internal fun fileServiceFeedbackPolicy(result: MutationResult): FileServiceFeedbackPolicy {
    require(result.operation == "fileServiceSettingsUpdate") { "file-services.unexpected-operation" }
    val canRefresh = result.submitted || result.requiresRefresh ||
        result.errorCategory == MutationErrorCategory.CONFLICT
    return when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> FileServiceFeedbackPolicy(
            R.string.file_service_feedback_saved_title,
            R.string.file_service_settings_saved,
            canRefresh = false,
            mustRefreshBeforeEditing = false,
            isAssertive = false,
        )
        MutationResultStatus.PARTIAL_SUCCESS -> FileServiceFeedbackPolicy(
            R.string.file_service_feedback_partial_title,
            R.string.file_service_feedback_partial_message,
            canRefresh = true,
            mustRefreshBeforeEditing = true,
            isAssertive = true,
        )
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED -> FileServiceFeedbackPolicy(
            R.string.file_service_feedback_check_title,
            R.string.file_service_feedback_unverified_message,
            canRefresh = true,
            mustRefreshBeforeEditing = true,
            isAssertive = true,
        )
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> FileServiceFeedbackPolicy(
            R.string.file_service_feedback_check_title,
            R.string.file_service_cancel_after_submission,
            canRefresh = true,
            mustRefreshBeforeEditing = true,
            isAssertive = true,
        )
        MutationResultStatus.PERMISSION_DENIED -> FileServiceFeedbackPolicy(
            R.string.file_service_feedback_permission_title,
            R.string.file_service_feedback_permission_message,
            canRefresh = canRefresh,
            mustRefreshBeforeEditing = canRefresh,
            isAssertive = true,
        )
        MutationResultStatus.UNSUPPORTED -> FileServiceFeedbackPolicy(
            R.string.file_service_feedback_unavailable_title,
            R.string.file_service_feedback_unsupported_message,
            canRefresh = canRefresh,
            mustRefreshBeforeEditing = canRefresh,
            isAssertive = true,
        )
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> FileServiceFeedbackPolicy(
            R.string.file_service_feedback_cancelled_title,
            R.string.file_service_feedback_cancelled_message,
            canRefresh = false,
            mustRefreshBeforeEditing = false,
            isAssertive = false,
        )
        MutationResultStatus.CONFIRMED_FAILURE -> FileServiceFeedbackPolicy(
            if (result.errorCategory == MutationErrorCategory.CONFLICT) {
                R.string.file_service_feedback_conflict_title
            } else {
                R.string.file_service_feedback_failed_title
            },
            if (result.errorCategory == MutationErrorCategory.CONFLICT) {
                R.string.file_service_feedback_conflict_message
            } else {
                R.string.file_service_feedback_failed_message
            },
            canRefresh = canRefresh,
            mustRefreshBeforeEditing = canRefresh,
            isAssertive = true,
        )
    }
}

internal data class TerminalFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val canRefresh: Boolean,
    val mustRefreshBeforeEditing: Boolean,
    val isAssertive: Boolean,
)

internal fun terminalFeedbackPolicy(result: MutationResult): TerminalFeedbackPolicy {
    require(result.operation == "terminalSettingsUpdate") { "terminal.unexpected-operation" }
    val canRefresh = result.submitted || result.requiresRefresh ||
        result.errorCategory == MutationErrorCategory.CONFLICT
    return when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> TerminalFeedbackPolicy(
            R.string.file_service_feedback_saved_title,
            R.string.terminal_settings_saved,
            canRefresh = false,
            mustRefreshBeforeEditing = false,
            isAssertive = false,
        )
        MutationResultStatus.PARTIAL_SUCCESS -> TerminalFeedbackPolicy(
            R.string.file_service_feedback_partial_title,
            R.string.terminal_feedback_partial_message,
            canRefresh = true,
            mustRefreshBeforeEditing = true,
            isAssertive = true,
        )
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED -> TerminalFeedbackPolicy(
            R.string.file_service_feedback_check_title,
            R.string.terminal_feedback_unverified_message,
            canRefresh = true,
            mustRefreshBeforeEditing = true,
            isAssertive = true,
        )
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> TerminalFeedbackPolicy(
            R.string.file_service_feedback_check_title,
            R.string.terminal_cancel_after_submission,
            canRefresh = true,
            mustRefreshBeforeEditing = true,
            isAssertive = true,
        )
        MutationResultStatus.PERMISSION_DENIED -> TerminalFeedbackPolicy(
            R.string.file_service_feedback_permission_title,
            R.string.terminal_feedback_permission_message,
            canRefresh = canRefresh,
            mustRefreshBeforeEditing = canRefresh,
            isAssertive = true,
        )
        MutationResultStatus.UNSUPPORTED -> TerminalFeedbackPolicy(
            R.string.file_service_feedback_unavailable_title,
            R.string.terminal_feedback_unsupported_message,
            canRefresh = canRefresh,
            mustRefreshBeforeEditing = canRefresh,
            isAssertive = true,
        )
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> TerminalFeedbackPolicy(
            R.string.file_service_feedback_cancelled_title,
            R.string.terminal_feedback_cancelled_message,
            canRefresh = false,
            mustRefreshBeforeEditing = false,
            isAssertive = false,
        )
        MutationResultStatus.CONFIRMED_FAILURE -> TerminalFeedbackPolicy(
            if (result.errorCategory == MutationErrorCategory.CONFLICT) {
                R.string.file_service_feedback_conflict_title
            } else {
                R.string.file_service_feedback_failed_title
            },
            if (result.errorCategory == MutationErrorCategory.CONFLICT) {
                R.string.terminal_feedback_conflict_message
            } else {
                R.string.terminal_feedback_failed_message
            },
            canRefresh = canRefresh,
            mustRefreshBeforeEditing = canRefresh,
            isAssertive = true,
        )
    }
}

internal data class ProxyFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val canRefresh: Boolean,
    val mustRefreshBeforeEditing: Boolean,
    val isAssertive: Boolean,
)

internal fun proxyFeedbackPolicy(result: MutationResult): ProxyFeedbackPolicy {
    require(result.operation == "proxySettingsUpdate") { "proxy.unexpected-operation" }
    val canRefresh = result.submitted || result.requiresRefresh ||
        result.errorCategory == MutationErrorCategory.CONFLICT
    return when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> ProxyFeedbackPolicy(
            R.string.file_service_feedback_saved_title,
            R.string.proxy_settings_saved,
            canRefresh = false,
            mustRefreshBeforeEditing = false,
            isAssertive = false,
        )
        MutationResultStatus.PARTIAL_SUCCESS -> ProxyFeedbackPolicy(
            R.string.file_service_feedback_partial_title,
            R.string.proxy_feedback_partial_message,
            canRefresh = true,
            mustRefreshBeforeEditing = true,
            isAssertive = true,
        )
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED -> ProxyFeedbackPolicy(
            R.string.file_service_feedback_check_title,
            R.string.proxy_feedback_unverified_message,
            canRefresh = true,
            mustRefreshBeforeEditing = true,
            isAssertive = true,
        )
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> ProxyFeedbackPolicy(
            R.string.file_service_feedback_check_title,
            R.string.proxy_cancel_after_submission,
            canRefresh = true,
            mustRefreshBeforeEditing = true,
            isAssertive = true,
        )
        MutationResultStatus.PERMISSION_DENIED -> ProxyFeedbackPolicy(
            R.string.file_service_feedback_permission_title,
            R.string.proxy_feedback_permission_message,
            canRefresh = canRefresh,
            mustRefreshBeforeEditing = canRefresh,
            isAssertive = true,
        )
        MutationResultStatus.UNSUPPORTED -> ProxyFeedbackPolicy(
            R.string.file_service_feedback_unavailable_title,
            R.string.proxy_feedback_unsupported_message,
            canRefresh = canRefresh,
            mustRefreshBeforeEditing = canRefresh,
            isAssertive = true,
        )
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> ProxyFeedbackPolicy(
            R.string.file_service_feedback_cancelled_title,
            R.string.proxy_feedback_cancelled_message,
            canRefresh = false,
            mustRefreshBeforeEditing = false,
            isAssertive = false,
        )
        MutationResultStatus.CONFIRMED_FAILURE -> ProxyFeedbackPolicy(
            if (result.errorCategory == MutationErrorCategory.CONFLICT) {
                R.string.file_service_feedback_conflict_title
            } else {
                R.string.file_service_feedback_failed_title
            },
            if (result.errorCategory == MutationErrorCategory.CONFLICT) {
                R.string.proxy_feedback_conflict_message
            } else {
                R.string.proxy_feedback_failed_message
            },
            canRefresh = canRefresh,
            mustRefreshBeforeEditing = canRefresh,
            isAssertive = true,
        )
    }
}
