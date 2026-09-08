package io.github.qwertyuiop1995.dsmnativeclient.ui.downloads

import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

import androidx.annotation.StringRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.DownloadCreationSourceKind
import io.github.qwertyuiop1995.dsmnativeclient.DownloadCreationWorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize

internal data class DownloadControlFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val assertive: Boolean,
)

internal data class DownloadCreationFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val assertive: Boolean,
)

internal fun downloadCreationFeedbackPolicy(result: MutationResult): DownloadCreationFeedbackPolicy = when (
    result.status
) {
    MutationResultStatus.CONFIRMED_SUCCESS -> DownloadCreationFeedbackPolicy(
        R.string.download_creation_confirmed_title,
        R.string.download_task_created,
        false,
    )
    MutationResultStatus.PARTIAL_SUCCESS -> DownloadCreationFeedbackPolicy(
        R.string.download_creation_partial_title,
        R.string.download_create_partial,
        true,
    )
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED -> DownloadCreationFeedbackPolicy(
        R.string.download_creation_check_title,
        R.string.download_create_unverified,
        true,
    )
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> DownloadCreationFeedbackPolicy(
        R.string.download_creation_check_title,
        R.string.download_creation_cancel_after_submission,
        true,
    )
    MutationResultStatus.PERMISSION_DENIED -> DownloadCreationFeedbackPolicy(
        R.string.download_creation_permission_title,
        R.string.download_create_permission_denied,
        true,
    )
    MutationResultStatus.UNSUPPORTED -> DownloadCreationFeedbackPolicy(
        R.string.download_creation_unavailable_title,
        R.string.download_create_unsupported,
        true,
    )
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> DownloadCreationFeedbackPolicy(
        R.string.download_creation_cancelled_title,
        R.string.download_create_cancelled,
        true,
    )
    MutationResultStatus.CONFIRMED_FAILURE -> DownloadCreationFeedbackPolicy(
        if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            R.string.download_creation_conflict_title
        } else R.string.download_creation_failed_title,
        if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            R.string.download_create_conflict
        } else R.string.download_create_failed,
        true,
    )
}

internal fun downloadControlFeedbackPolicy(
    result: MutationResult,
    deleteFiles: Boolean = false,
): DownloadControlFeedbackPolicy = when (
    result.status
) {
    MutationResultStatus.CONFIRMED_SUCCESS -> DownloadControlFeedbackPolicy(
        R.string.download_control_confirmed_title,
        R.string.download_control_confirmed_message,
        false,
    )
    MutationResultStatus.PARTIAL_SUCCESS -> if (deleteFiles) {
        DownloadControlFeedbackPolicy(
            R.string.download_delete_files_partial_title,
            R.string.download_delete_files_partial_message,
            true,
        )
    } else {
        DownloadControlFeedbackPolicy(
            R.string.download_control_partial_title,
            R.string.download_action_partial_persistent,
            true,
        )
    }
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED -> DownloadControlFeedbackPolicy(
        R.string.download_control_check_title,
        R.string.download_action_unverified,
        true,
    )
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> DownloadControlFeedbackPolicy(
        R.string.download_control_check_title,
        R.string.download_control_cancel_after_submission,
        true,
    )
    MutationResultStatus.PERMISSION_DENIED -> DownloadControlFeedbackPolicy(
        R.string.download_control_permission_title,
        R.string.download_action_permission_denied,
        true,
    )
    MutationResultStatus.UNSUPPORTED -> DownloadControlFeedbackPolicy(
        R.string.download_control_unavailable_title,
        R.string.download_action_unsupported,
        true,
    )
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> DownloadControlFeedbackPolicy(
        R.string.download_control_cancelled_title,
        R.string.download_action_cancelled,
        true,
    )
    MutationResultStatus.CONFIRMED_FAILURE -> DownloadControlFeedbackPolicy(
        if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            R.string.download_control_conflict_title
        } else R.string.download_control_failed_title,
        if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            R.string.download_action_conflict
        } else R.string.download_action_failed,
        true,
    )
}

@Composable
internal fun DownloadTaskActionsDialog(
    taskTitle: String,
    taskState: ResourceState,
    enabled: Boolean,
    onDetails: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onRemove: () -> Unit,
    onRemoveWithFiles: () -> Unit,
    onDismiss: () -> Unit,
    canEditDestination: Boolean = false,
    onEditDestination: () -> Unit = {},
) {
    ClientSheet(taskTitle, onDismiss) {
        ClientActionGrid(buildList {
            add(ClientAction(stringResource(R.string.download_task_details), Icons.Outlined.Info, onClick = onDetails))
            if (taskState == ResourceState.RUNNING || taskState == ResourceState.WAITING)
                add(ClientAction(stringResource(R.string.pause), Icons.Outlined.Pause, enabled, onPause))
            if (taskState == ResourceState.PAUSED)
                add(ClientAction(stringResource(R.string.resume), Icons.Outlined.PlayArrow, enabled, onResume))
            if (canEditDestination)
                add(ClientAction(stringResource(R.string.change_download_destination), Icons.Outlined.FolderOpen, enabled, onEditDestination))
        })
        ClientGroup {
            ClientRow(stringResource(R.string.remove_task), Icons.Outlined.DeleteOutline, enabled = enabled,
                destructive = true, onClick = onRemove)
            ClientRow(stringResource(R.string.remove_task_and_files), Icons.Outlined.DeleteOutline, enabled = enabled,
                destructive = true, onClick = onRemoveWithFiles)
        }
    }
}

@Composable
internal fun DownloadDestinationEditConfirmationDialog(
    taskTitle: String,
    currentDestination: String?,
    newDestination: String,
    persistentRejection: Boolean,
    onConfirm: () -> Boolean,
    onDismiss: () -> Unit,
) {
    var confirmationFailureVisible by remember(taskTitle, newDestination) { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.change_download_destination_title)) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(stringResource(R.string.change_download_destination_message, taskTitle))
                currentDestination?.takeIf(String::isNotBlank)?.let {
                    Text(stringResource(R.string.current_download_destination_summary, it))
                }
                Text(stringResource(R.string.new_download_destination_summary, newDestination))
                Text(
                    stringResource(R.string.change_download_destination_effect),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (persistentRejection || confirmationFailureVisible) {
                    Text(
                        stringResource(R.string.change_download_destination_changed),
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
                    )
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { if (!onConfirm()) confirmationFailureVisible = true },
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.confirm_change_download_destination)) }
        },
        dismissButton = {
            OutlinedButton(
                onClick = onDismiss,
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
private fun DownloadTaskActionRow(
    icon: ImageVector,
    title: String,
    taskTitle: String,
    enabled: Boolean,
    destructive: Boolean,
    onClick: () -> Unit,
) {
    val description = stringResource(R.string.download_task_action_description, title, taskTitle)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp)
            .semantics { contentDescription = description },
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        )
        Text(
            title,
            color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
internal fun DownloadDeletionConfirmationDialog(
    taskTitle: String,
    deleteFiles: Boolean,
    persistentRejection: Boolean = false,
    onConfirm: () -> Boolean,
    onDismiss: () -> Unit,
) {
    var confirmationFailureVisible by remember(taskTitle, deleteFiles) { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(stringResource(
                if (deleteFiles) R.string.remove_task_and_files_title else R.string.remove_download_task,
            ))
        },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(stringResource(
                    if (deleteFiles) R.string.remove_task_and_files_message else R.string.remove_task_only_message,
                    taskTitle,
                ))
                if (deleteFiles) Text(
                    stringResource(R.string.download_delete_files_risk_summary),
                    color = MaterialTheme.colorScheme.error,
                )
                if (persistentRejection || confirmationFailureVisible) Text(
                    stringResource(R.string.download_deletion_confirmation_changed),
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { if (!onConfirm()) confirmationFailureVisible = true },
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) {
                Text(stringResource(
                    if (deleteFiles) R.string.confirm_remove_task_and_files else R.string.confirm_remove_task_only,
                ))
            }
        },
        dismissButton = {
            OutlinedButton(
                onClick = onDismiss,
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
internal fun DownloadControlMutationFeedbackCard(
    result: MutationResult?,
    failure: DsmFailure?,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    mustRefresh: Boolean,
    currentMatches: Boolean?,
    deleteFiles: Boolean,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
) {
    val policy = result?.let { downloadControlFeedbackPolicy(it, deleteFiles) }
    val trustedRefreshCompleted = refreshCompleted && refreshFailure == null
    Card(
        modifier = Modifier.fillMaxWidth().semantics {
            liveRegion = if (failure != null || policy?.assertive == true) {
                LiveRegionMode.Assertive
            } else LiveRegionMode.Polite
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 360.dp)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                stringResource(policy?.title ?: R.string.download_control_failed_title),
                style = MaterialTheme.typography.titleMedium,
            )
            if (failure != null) {
                Text(failure.localize(LocalContext.current).combined)
            } else {
                Text(stringResource(checkNotNull(policy).message))
            }
            result?.counts?.let { counts ->
                Text(
                    stringResource(
                        R.string.download_control_feedback_counts,
                        counts.succeeded,
                        counts.failed,
                        counts.unknown,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (deleteFiles) Text(
                stringResource(R.string.download_delete_files_verification_notice),
                style = MaterialTheme.typography.bodySmall,
            )
            if (trustedRefreshCompleted) Text(stringResource(when (currentMatches) {
                true -> if (deleteFiles) {
                    R.string.download_delete_files_refresh_matches
                } else R.string.download_control_refresh_matches
                false -> R.string.download_control_refresh_differs
                null -> R.string.download_control_refresh_unavailable
            }))
            refreshFailure?.let { Text(it.localize(LocalContext.current).combined) }
            if (refreshInProgress) {
                Text(stringResource(R.string.download_control_refreshing))
                LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            if (mustRefresh && !trustedRefreshCompleted || refreshFailure != null) {
                TextButton(
                    enabled = !refreshInProgress,
                    onClick = onRefresh,
                    modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics {
                        role = Role.Button
                    },
                ) { Text(stringResource(R.string.refresh_and_check_download_tasks)) }
            }
            TextButton(
                enabled = !refreshInProgress && (!mustRefresh || trustedRefreshCompleted),
                onClick = onDismiss,
                modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics {
                    role = Role.Button
                },
            ) { Text(stringResource(R.string.close_checked_download_feedback)) }
        }
    }
}

@Composable
internal fun DownloadCreationMutationFeedbackCard(
    state: DownloadCreationWorkspaceState,
    mustRefresh: Boolean,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
    onEdit: () -> Unit,
) {
    val result = state.mutationResult
    val policy = result?.let(::downloadCreationFeedbackPolicy)
    val trustedRefreshCompleted = state.mutationRefreshCompleted && state.mutationRefreshFailure == null
    val canEdit = !state.mutationInProgress && !state.mutationRefreshInProgress &&
        result != null && !result.submitted && state.target?.sourceKind in setOf(
            DownloadCreationSourceKind.LINK,
            DownloadCreationSourceKind.MAGNET,
        ) &&
        (!mustRefresh || trustedRefreshCompleted)
    Card(
        modifier = Modifier.fillMaxWidth().semantics {
            liveRegion = if (
                state.mutationFailure != null || policy?.assertive == true ||
                state.mutationRefreshFailure != null
            ) LiveRegionMode.Assertive else LiveRegionMode.Polite
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 360.dp)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                when {
                    state.mutationInProgress -> stringResource(R.string.download_creation_in_progress_title)
                    state.mutationFailure != null -> stringResource(R.string.download_creation_failed_title)
                    else -> stringResource(checkNotNull(policy).title)
                },
                style = MaterialTheme.typography.titleMedium,
            )
            state.target?.let { target ->
                Text(
                    stringResource(
                        R.string.download_creation_source_summary,
                        stringResource(target.sourceKind.labelResource()),
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
                target.destination?.let { destination ->
                    Text(
                        stringResource(R.string.download_creation_destination_summary, destination),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            when {
                state.mutationInProgress -> {
                    Text(stringResource(R.string.download_creation_in_progress_message))
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                state.mutationFailure != null -> Text(
                    state.mutationFailure.localize(LocalContext.current).combined,
                )
                policy != null -> Text(stringResource(policy.message))
            }
            result?.counts?.let { counts ->
                Text(
                    stringResource(
                        R.string.download_creation_feedback_counts,
                        counts.succeeded,
                        counts.failed,
                        counts.unknown,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (trustedRefreshCompleted) {
                Text(stringResource(R.string.download_creation_refresh_completed))
            }
            state.mutationRefreshFailure?.let { failure ->
                Text(failure.localize(LocalContext.current).combined)
            }
            if (state.mutationRefreshInProgress) {
                Text(stringResource(R.string.download_creation_refreshing))
                LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            if ((mustRefresh && !trustedRefreshCompleted) || state.mutationRefreshFailure != null) {
                TextButton(
                    enabled = !state.mutationInProgress && !state.mutationRefreshInProgress,
                    onClick = onRefresh,
                    modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics {
                        role = Role.Button
                    },
                ) { Text(stringResource(R.string.refresh_and_check_download_creation)) }
            }
            if (canEdit) {
                OutlinedButton(
                    onClick = onEdit,
                    modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics {
                        role = Role.Button
                    },
                ) { Text(stringResource(R.string.edit_download_creation_and_retry)) }
            }
            if (!state.mutationInProgress) {
                TextButton(
                    enabled = !state.mutationRefreshInProgress && (!mustRefresh || trustedRefreshCompleted),
                    onClick = onDismiss,
                    modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics {
                        role = Role.Button
                    },
                ) {
                    Text(
                        stringResource(
                            if (mustRefresh) R.string.close_checked_download_creation
                            else R.string.close,
                        ),
                    )
                }
            }
        }
    }
}

@StringRes
private fun DownloadCreationSourceKind.labelResource(): Int = when (this) {
    DownloadCreationSourceKind.LINK -> R.string.download_creation_source_link
    DownloadCreationSourceKind.MAGNET -> R.string.download_creation_source_magnet
    DownloadCreationSourceKind.TASK_FILE -> R.string.download_creation_source_task_file
    DownloadCreationSourceKind.RSS -> R.string.download_creation_source_rss
    DownloadCreationSourceKind.BT_SEARCH -> R.string.download_creation_source_bt_search
}
