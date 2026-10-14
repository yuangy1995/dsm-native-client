package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AdminPanelSettings
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Security
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.DirectoryEntryKind
import io.github.qwertyuiop1995.dsmnativeclient.DirectoryEntryMutationTarget
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import java.util.Locale

@Composable
internal fun NasDirectoryManagementScreen(
    snapshot: NasSettingsSnapshot,
    state: WorkspaceState,
    model: AppViewModel,
) {
    NasAccountDirectoryScreen(state.profile.username, model.nasDirectory)
}

@Composable
internal fun DirectoryManagementContent(
    accounts: List<NasAccount>,
    groups: List<NasGroup>,
    accountsAvailable: Boolean,
    groupsAvailable: Boolean,
    currentUsername: String,
    target: DirectoryEntryMutationTarget?,
    mutationInProgress: Boolean,
    result: MutationResult?,
    failure: DsmFailure?,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    enabled: Boolean,
    onDeleteAccount: (NasAccount) -> Unit,
    onDeleteGroup: (NasGroup) -> Unit,
    onRefresh: () -> Unit,
    onContinue: () -> Unit,
    onCloseResult: () -> Unit,
) {
    val targetState = target?.let {
        directoryTargetState(it, accounts, groups, accountsAvailable, groupsAvailable, refreshCompleted)
    }
    LazyColumn {
        item {
            when {
                mutationInProgress && target != null -> ManagementSavingCard(
                    title = R.string.directory_deletion_in_progress,
                    targetName = target.displayName,
                    message = R.string.directory_deletion_in_progress_message,
                )
                (result != null || failure != null) && target != null -> ManagementMutationFeedbackCard(
                    targetName = target.displayName,
                    result = result,
                    failure = failure,
                    refreshFailure = refreshFailure,
                    refreshInProgress = refreshInProgress,
                    refreshCompleted = refreshCompleted,
                    targetState = targetState ?: ManagementTargetState.UNAVAILABLE,
                    countsLabel = R.string.directory_feedback_counts,
                    refreshLabel = R.string.refresh_and_check_directory,
                    onRefresh = onRefresh,
                    onContinue = onContinue,
                    onCloseResult = onCloseResult,
                )
            }
        }
        if (!accountsAvailable && !groupsAvailable) {
            item { ManagementEmptyState(R.string.directory_unavailable, R.string.directory_unavailable_hint) }
        } else if (accountsAvailable && groupsAvailable && accounts.isEmpty() && groups.isEmpty()) {
            item { ManagementEmptyState(R.string.directory_management_empty, R.string.directory_empty_hint) }
        } else {
            if (!accountsAvailable) item {
                ManagementEmptyState(R.string.accounts_unavailable, R.string.accounts_unavailable_hint)
            }
            if (accountsAvailable) {
                item { ManagementSectionTitle(R.string.nas_accounts) }
                items(accounts, key = { "account:${it.name.lowercase(Locale.ROOT)}" }) { account ->
                    val protected = account.name.equals(currentUsername, ignoreCase = true) ||
                        account.name.lowercase(Locale.ROOT) in setOf("admin", "guest")
                    DirectoryAccountRow(account, enabled && account.canDelete && !protected) {
                        onDeleteAccount(account)
                    }
                }
            }
            if (!groupsAvailable) item {
                ManagementEmptyState(R.string.groups_unavailable, R.string.groups_unavailable_hint)
            }
            if (groupsAvailable) {
                item { ManagementSectionTitle(R.string.user_groups) }
                items(groups, key = { "group:${it.name.lowercase(Locale.ROOT)}" }) { group ->
                    val protected = group.name.lowercase(Locale.ROOT) in setOf("administrators", "users", "http")
                    DirectoryGroupRow(group, enabled && group.canDelete && !protected) { onDeleteGroup(group) }
                }
            }
        }
    }
}

@Composable
internal fun DirectoryAccountRow(account: NasAccount, canDelete: Boolean, onDelete: () -> Unit) {
    DirectoryEntryRow(
        name = account.name,
        detail = account.description ?: account.email ?: stringResource(R.string.nas_account),
        canDelete = canDelete,
        icon = { Icon(Icons.Outlined.AdminPanelSettings, null) },
        deleteDescription = stringResource(R.string.delete_account_description, account.name),
        onDelete = onDelete,
    )
}

@Composable
internal fun DirectoryGroupRow(group: NasGroup, canDelete: Boolean, onDelete: () -> Unit) {
    DirectoryEntryRow(
        name = group.name,
        detail = group.description ?: stringResource(R.string.user_group),
        canDelete = canDelete,
        icon = { Icon(Icons.Outlined.Security, null) },
        deleteDescription = stringResource(R.string.delete_group_description, group.name),
        onDelete = onDelete,
    )
}

@Composable
private fun DirectoryEntryRow(
    name: String,
    detail: String,
    canDelete: Boolean,
    icon: @Composable () -> Unit,
    deleteDescription: String,
    onDelete: () -> Unit,
) {
    ListItem(
        headlineContent = { Text(name) },
        supportingContent = { Text(detail) },
        leadingContent = icon,
        trailingContent = {
            TextButton(
                enabled = canDelete,
                onClick = onDelete,
                modifier = Modifier.heightIn(min = 48.dp).semantics {
                    contentDescription = deleteDescription
                    role = Role.Button
                },
            ) {
                Icon(Icons.Outlined.DeleteOutline, null)
                Text(stringResource(R.string.delete))
            }
        },
    )
    HorizontalDivider(Modifier.padding(start = 72.dp))
}

@Composable
internal fun DirectoryDeletionConfirmationDialog(
    target: DirectoryEntryMutationTarget,
    onConfirm: () -> Boolean,
    onDismiss: () -> Unit,
) {
    val isGroup = target.kind == DirectoryEntryKind.GROUP
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(if (isGroup) R.string.delete_group_title else R.string.delete_account_title, target.displayName)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(if (isGroup) R.string.delete_group_message else R.string.delete_account_message))
                Text(stringResource(R.string.directory_target_summary, target.displayName))
                Text(stringResource(R.string.directory_deletion_irreversible), color = MaterialTheme.colorScheme.error)
            }
        },
        confirmButton = { TextButton(onClick = { onConfirm() }) {
            Text(stringResource(if (isGroup) R.string.delete_group else R.string.delete_account))
        } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

internal val DirectoryEntryMutationTarget.displayName: String
    get() = account?.name ?: group?.name.orEmpty()

internal enum class ManagementTargetState { MATCHES, DIFFERS, MISSING, UNAVAILABLE }

internal fun directoryTargetState(
    target: DirectoryEntryMutationTarget,
    accounts: List<NasAccount>,
    groups: List<NasGroup>,
    accountsAvailable: Boolean,
    groupsAvailable: Boolean,
    refreshCompleted: Boolean,
): ManagementTargetState {
    if (!refreshCompleted) return ManagementTargetState.UNAVAILABLE
    val available = if (target.kind == DirectoryEntryKind.ACCOUNT) accountsAvailable else groupsAvailable
    if (!available) return ManagementTargetState.UNAVAILABLE
    val exists = if (target.kind == DirectoryEntryKind.ACCOUNT) {
        accounts.any { it.name.equals(target.displayName, ignoreCase = true) }
    } else groups.any { it.name.equals(target.displayName, ignoreCase = true) }
    return if (exists) ManagementTargetState.DIFFERS else ManagementTargetState.MATCHES
}

internal data class ManagementFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val mustRefresh: Boolean,
    val assertive: Boolean,
)

internal fun managementFeedbackPolicy(result: MutationResult): ManagementFeedbackPolicy {
    val submitted = result.submitted || result.requiresRefresh || result.errorCategory == MutationErrorCategory.CONFLICT
    val mustRefresh = when (result.status) {
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> true
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CONFIRMED_FAILURE -> submitted
        MutationResultStatus.CONFIRMED_SUCCESS,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> false
    }
    val title = when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> R.string.management_feedback_success_title
        MutationResultStatus.PARTIAL_SUCCESS -> R.string.settings_feedback_partial_title
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> R.string.settings_feedback_check_title
        MutationResultStatus.PERMISSION_DENIED -> R.string.settings_feedback_permission_title
        MutationResultStatus.UNSUPPORTED -> R.string.settings_feedback_unavailable_title
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.settings_feedback_cancelled_title
        MutationResultStatus.CONFIRMED_FAILURE -> if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            R.string.settings_feedback_conflict_title
        } else R.string.settings_feedback_failed_title
    }
    val message = when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> R.string.management_feedback_success_message
        MutationResultStatus.PARTIAL_SUCCESS -> R.string.service_action_partial
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> R.string.service_action_unverified
        MutationResultStatus.PERMISSION_DENIED -> R.string.service_action_permission_denied
        MutationResultStatus.UNSUPPORTED -> R.string.service_action_unsupported
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.service_action_cancelled
        MutationResultStatus.CONFIRMED_FAILURE -> if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            R.string.service_action_conflict
        } else R.string.service_action_failed
    }
    return ManagementFeedbackPolicy(title, message, mustRefresh, result.status != MutationResultStatus.CONFIRMED_SUCCESS)
}

@Composable
internal fun ManagementMutationFeedbackCard(
    targetName: String,
    result: MutationResult?,
    failure: DsmFailure?,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    targetState: ManagementTargetState,
    @StringRes countsLabel: Int,
    @StringRes refreshLabel: Int,
    onRefresh: () -> Unit,
    onContinue: () -> Unit,
    onCloseResult: () -> Unit,
) {
    val policy = result?.let(::managementFeedbackPolicy)
    val mustRefresh = failure != null || policy?.mustRefresh == true
    val canLeave = !mustRefresh || refreshCompleted
    ManagementFeedbackCard(
        mode = if (failure != null || policy?.assertive == true) LiveRegionMode.Assertive else LiveRegionMode.Polite,
        isError = failure != null || result?.status in setOf(MutationResultStatus.PERMISSION_DENIED, MutationResultStatus.CONFIRMED_FAILURE),
    ) {
        Text(stringResource(policy?.title ?: R.string.settings_feedback_failed_title), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(R.string.management_target_summary, targetName))
        if (failure != null) Text(failure.localize(LocalContext.current).combined) else Text(stringResource(policy!!.message))
        result?.counts?.takeIf { it.succeeded + it.failed + it.unknown > 0 }?.let {
            Text(stringResource(countsLabel, it.succeeded, it.failed, it.unknown), style = MaterialTheme.typography.bodySmall)
        }
        if (refreshCompleted) Text(stringResource(when (targetState) {
            ManagementTargetState.MATCHES -> R.string.management_refresh_matches
            ManagementTargetState.DIFFERS -> R.string.management_refresh_differs
            ManagementTargetState.MISSING -> R.string.management_refresh_target_missing
            ManagementTargetState.UNAVAILABLE -> R.string.management_refresh_unavailable
        }))
        refreshFailure?.let { Text(it.localize(LocalContext.current).combined) }
        if (refreshInProgress) {
            Text(stringResource(R.string.management_refreshing))
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        if (mustRefresh || refreshFailure != null) {
            TextButton(enabled = !refreshInProgress, onClick = onRefresh, modifier = Modifier.align(Alignment.End)) {
                Text(stringResource(refreshLabel))
            }
        }
        TextButton(enabled = canLeave && !refreshInProgress, onClick = onContinue, modifier = Modifier.align(Alignment.End)) {
            Text(stringResource(R.string.continue_managing))
        }
        TextButton(enabled = canLeave && !refreshInProgress, onClick = onCloseResult, modifier = Modifier.align(Alignment.End)) {
            Text(stringResource(R.string.close_result))
        }
    }
}

@Composable
internal fun ManagementSavingCard(@StringRes title: Int, targetName: String, @StringRes message: Int) {
    ManagementFeedbackCard(LiveRegionMode.Polite, false) {
        Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(R.string.management_target_summary, targetName))
        Text(stringResource(message))
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
private fun ManagementFeedbackCard(mode: LiveRegionMode, isError: Boolean, content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = mode },
        colors = if (isError) CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
            contentColor = MaterialTheme.colorScheme.onErrorContainer,
        ) else CardDefaults.cardColors(),
    ) { Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content) }
}

@Composable
private fun ManagementEmptyState(@StringRes title: Int, @StringRes message: Int) {
    Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(message), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ManagementSectionTitle(@StringRes title: Int) {
    Text(stringResource(title), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(16.dp))
}
