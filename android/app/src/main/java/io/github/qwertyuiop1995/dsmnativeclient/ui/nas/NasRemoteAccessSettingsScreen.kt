package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRemoteAccessSettings

@Composable
internal fun NasRemoteAccessManagement(settings: NasRemoteAccessSettings?, available: Boolean,
    isPerformingAction: Boolean, model: AppViewModel) {
    val services = model.nasServices
    val values by services.state.collectAsState()
    val state = values.getValue(NasServiceKind.REMOTE_ACCESS)
    val original = (state.original as? NasServiceValue.RemoteAccess)?.settings
    val draft = (state.draft as? NasServiceValue.RemoteAccess)?.settings
    var editing by rememberSaveable { mutableStateOf(false) }
    var confirming by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(services) { services.refresh(NasServiceKind.REMOTE_ACCESS, notify = false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.remote_access), style = MaterialTheme.typography.titleMedium)
        if (state.saving) RemoteAccessStateCard(R.string.remote_access_saving_title, R.string.remote_access_saving_message, LiveRegionMode.Polite, true)
        else {
            if (state.result != null || state.failure != null) SettingsMutationFeedbackCard(
                result = state.result, failure = state.failure, refreshFailure = null,
                refreshInProgress = state.busy, refreshCompleted = false, currentMatches = null,
                countsLabel = R.string.remote_access_feedback_counts, refreshLabel = R.string.refresh_and_check_remote_access,
                onRefresh = { services.refresh(NasServiceKind.REMOTE_ACCESS) },
                onContinueEditing = { services.dismiss(NasServiceKind.REMOTE_ACCESS); editing = true },
                onDismiss = { services.dismiss(NasServiceKind.REMOTE_ACCESS, discard = true) },
                canContinueEditing = !state.blocked && draft != null,
                canDismiss = !state.blocked)
            else if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        if (!available || settings == null) RemoteAccessUnavailableCard(R.string.remote_access_read_failed_title,
            R.string.remote_access_read_failed_message, !state.busy, onRefresh = { services.refresh(NasServiceKind.REMOTE_ACCESS) })
        else RemoteAccessSettingsCard(settings, !isPerformingAction && !state.blocked && original == null) {
            editing = services.begin(NasServiceValue.RemoteAccess(settings))
        }
    }
    if (editing && original != null && draft != null) RemoteAccessEditDialog(original, draft,
        enabled = !isPerformingAction && !state.blocked,
        onDraftChange = { services.draft(NasServiceKind.REMOTE_ACCESS, NasServiceValue.RemoteAccess(it)) },
        onContinue = { editing = false; confirming = true },
        onDismiss = { services.draft(NasServiceKind.REMOTE_ACCESS, null); editing = false })
    if (confirming && original != null && draft != null) RemoteAccessConfirmationDialog(original, draft,
        onConfirm = { services.save(NasServiceKind.REMOTE_ACCESS).also { if (it) confirming = false } },
        onDismiss = { confirming = false; editing = true })
}

@Composable
internal fun RemoteAccessSettingsContent(
    settings: NasRemoteAccessSettings?,
    settingsAvailable: Boolean,
    baseline: NasRemoteAccessSettings?,
    draft: NasRemoteAccessSettings?,
    mutationInProgress: Boolean,
    mutationResult: MutationResult?,
    mutationFailure: DsmFailure?,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    isPerformingAction: Boolean,
    onEdit: (NasRemoteAccessSettings) -> Unit,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismissResult: () -> Unit,
    onRefreshSettings: () -> Unit,
) {
    val trustedRefreshCompleted = refreshCompleted && refreshFailure == null
    val currentMatches = remoteAccessCurrentMatches(
        expected = draft,
        current = settings,
        settingsAvailable = settingsAvailable,
        refreshCompleted = trustedRefreshCompleted,
    )
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(stringResource(R.string.remote_access), style = MaterialTheme.typography.titleMedium)
        Text(
            stringResource(R.string.remote_access_description),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        when {
            mutationInProgress -> RemoteAccessStateCard(
                title = R.string.remote_access_saving_title,
                message = R.string.remote_access_saving_message,
                liveRegion = LiveRegionMode.Polite,
                showProgress = true,
            )
            mutationResult != null || mutationFailure != null -> SettingsMutationFeedbackCard(
                result = mutationResult,
                failure = mutationFailure,
                refreshFailure = refreshFailure,
                refreshInProgress = refreshInProgress,
                refreshCompleted = trustedRefreshCompleted,
                currentMatches = currentMatches,
                countsLabel = R.string.remote_access_feedback_counts,
                refreshLabel = R.string.refresh_and_check_remote_access,
                onRefresh = onRefresh,
                onContinueEditing = onContinueEditing,
                onDismiss = onDismissResult,
            )
        }
        when {
            !settingsAvailable || settings == null -> RemoteAccessUnavailableCard(
                title = R.string.remote_access_read_failed_title,
                message = R.string.remote_access_read_failed_message,
                enabled = baseline == null && mutationResult == null && mutationFailure == null &&
                    !isPerformingAction && !refreshInProgress,
                onRefresh = onRefreshSettings,
            )
            settings.isRelayEnabled == null && settings.isRouterConfigurationEnabled == null ->
                RemoteAccessUnavailableCard(
                    title = R.string.remote_access_both_unavailable_title,
                    message = R.string.remote_access_both_unavailable_message,
                    enabled = baseline == null && mutationResult == null && mutationFailure == null &&
                        !isPerformingAction && !refreshInProgress,
                    onRefresh = onRefreshSettings,
                )
            else -> RemoteAccessSettingsCard(
                settings = settings,
                actionsEnabled = baseline == null && mutationResult == null && mutationFailure == null &&
                    !mutationInProgress && !refreshInProgress && !isPerformingAction,
                onEdit = { onEdit(settings) },
            )
        }
    }
}

@Composable
private fun RemoteAccessSettingsCard(
    settings: NasRemoteAccessSettings,
    actionsEnabled: Boolean,
    onEdit: () -> Unit,
) {
    val editDescription = stringResource(R.string.edit_remote_access_description)
    Card(Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            RemoteAccessValueRow(
                label = stringResource(R.string.quickconnect_relay),
                description = stringResource(R.string.quickconnect_relay_description),
                value = settings.isRelayEnabled,
            )
            RemoteAccessValueRow(
                label = stringResource(R.string.router_configuration),
                description = stringResource(R.string.router_configuration_description),
                value = settings.isRouterConfigurationEnabled,
            )
            if (settings.isConnectedThroughTrustedRelay) {
                RemoteAccessNotice(
                    R.string.remote_access_trusted_relay_title,
                    R.string.remote_access_trusted_relay_message,
                    LiveRegionMode.Polite,
                )
            }
            if (!settings.canManage) {
                RemoteAccessNotice(
                    R.string.remote_access_read_only_title,
                    R.string.remote_access_read_only_message,
                    LiveRegionMode.Polite,
                )
            } else {
                OutlinedButton(
                    enabled = actionsEnabled,
                    onClick = onEdit,
                    modifier = Modifier.heightIn(min = 48.dp).semantics {
                        contentDescription = editDescription
                        role = Role.Button
                    },
                ) { Text(stringResource(R.string.edit_remote_access)) }
            }
        }
    }
}

@Composable
private fun RemoteAccessValueRow(label: String, description: String, value: Boolean?) {
    val valueText = stringResource(when (value) {
        true -> R.string.remote_access_enabled
        false -> R.string.remote_access_disabled
        null -> R.string.remote_access_value_unavailable
    })
    val accessibilityDescription = stringResource(R.string.remote_access_value_description, label, valueText)
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).semantics(mergeDescendants = true) {
            contentDescription = accessibilityDescription
        },
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(label)
            Text(description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(valueText)
    }
}

@Composable
internal fun RemoteAccessEditDialog(
    baseline: NasRemoteAccessSettings,
    draft: NasRemoteAccessSettings,
    enabled: Boolean,
    onDraftChange: (NasRemoteAccessSettings) -> Unit,
    onContinue: () -> Unit,
    onDismiss: () -> Unit,
) {
    val relayProtected = baseline.isConnectedThroughTrustedRelay
    val changed = remoteAccessWritableValues(draft) != remoteAccessWritableValues(baseline)
    val relaySupporting = if (relayProtected) {
        stringResource(R.string.remote_access_relay_protected_editor)
    } else stringResource(R.string.quickconnect_relay_description)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.edit_remote_access_title)) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                RemoteAccessSwitchRow(
                    label = stringResource(R.string.quickconnect_relay),
                    supporting = relaySupporting,
                    value = draft.isRelayEnabled,
                    enabled = enabled && draft.canManage && !relayProtected,
                    accessibilityDescription = if (relayProtected) stringResource(
                        R.string.remote_access_protected_switch_description,
                        stringResource(R.string.quickconnect_relay),
                        relaySupporting,
                    ) else null,
                    onChange = { value -> onDraftChange(draft.copy(isRelayEnabled = value)) },
                )
                RemoteAccessSwitchRow(
                    label = stringResource(R.string.router_configuration),
                    supporting = stringResource(R.string.router_configuration_description),
                    value = draft.isRouterConfigurationEnabled,
                    enabled = enabled && draft.canManage,
                    onChange = { value -> onDraftChange(draft.copy(isRouterConfigurationEnabled = value)) },
                )
                if (!changed) Text(
                    stringResource(R.string.remote_access_no_changes),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            Button(
                enabled = enabled && draft.canManage && changed,
                onClick = onContinue,
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.continue_action)) }
        },
        dismissButton = {
            OutlinedButton(
                enabled = enabled,
                onClick = onDismiss,
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
internal fun RemoteAccessConfirmationDialog(
    baseline: NasRemoteAccessSettings,
    draft: NasRemoteAccessSettings,
    onConfirm: () -> Boolean,
    onDismiss: () -> Unit,
) {
    var confirmationFailureVisible by remember(baseline, draft) { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.save_remote_access_title)) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (baseline.isRelayEnabled != draft.isRelayEnabled) Text(stringResource(
                    if (draft.isRelayEnabled == false) R.string.disable_relay_impact else R.string.enable_relay_impact,
                ))
                if (baseline.isRouterConfigurationEnabled != draft.isRouterConfigurationEnabled) Text(stringResource(
                    if (draft.isRouterConfigurationEnabled == true) {
                        R.string.enable_router_configuration_impact
                    } else R.string.disable_router_configuration_impact,
                ))
                if (confirmationFailureVisible) Text(
                    stringResource(R.string.remote_access_confirmation_changed_message),
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { if (!onConfirm()) confirmationFailureVisible = true },
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.save_remote_access)) }
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
private fun RemoteAccessSwitchRow(
    label: String,
    supporting: String,
    value: Boolean?,
    enabled: Boolean,
    accessibilityDescription: String? = null,
    onChange: (Boolean) -> Unit,
) {
    if (value == null) {
        RemoteAccessValueRow(label, supporting, null)
        return
    }
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(
            value = value,
            enabled = enabled,
            role = Role.Switch,
            onValueChange = onChange,
        ).semantics(mergeDescendants = true) {
            contentDescription = accessibilityDescription ?: label
            role = Role.Switch
        },
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(label)
            Text(supporting, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = value, onCheckedChange = null, enabled = enabled)
    }
}

@Composable
private fun RemoteAccessUnavailableCard(
    @androidx.annotation.StringRes title: Int,
    @androidx.annotation.StringRes message: Int,
    enabled: Boolean,
    onRefresh: () -> Unit,
) {
    val refreshDescription = stringResource(R.string.refresh_remote_access_description)
    Card(Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite }) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(message))
            OutlinedButton(
                enabled = enabled,
                onClick = onRefresh,
                modifier = Modifier.heightIn(min = 48.dp).semantics {
                    contentDescription = refreshDescription
                    role = Role.Button
                },
            ) { Text(stringResource(R.string.refresh)) }
        }
    }
}

@Composable
private fun RemoteAccessStateCard(
    @androidx.annotation.StringRes title: Int,
    @androidx.annotation.StringRes message: Int,
    liveRegion: LiveRegionMode,
    showProgress: Boolean = false,
) {
    Card(Modifier.fillMaxWidth().semantics { this.liveRegion = liveRegion }) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(message))
            if (showProgress) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun RemoteAccessNotice(
    @androidx.annotation.StringRes title: Int,
    @androidx.annotation.StringRes message: Int,
    mode: LiveRegionMode,
) {
    Column(Modifier.semantics { liveRegion = mode }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(title), style = MaterialTheme.typography.titleSmall)
        Text(stringResource(message), style = MaterialTheme.typography.bodySmall)
    }
}

internal fun remoteAccessCurrentMatches(
    expected: NasRemoteAccessSettings?,
    current: NasRemoteAccessSettings?,
    settingsAvailable: Boolean,
    refreshCompleted: Boolean,
): Boolean? {
    if (!refreshCompleted || !settingsAvailable || expected == null || current == null) return null
    if (expected.isRelayEnabled != null && current.isRelayEnabled == null) return null
    if (
        expected.isRouterConfigurationEnabled != null &&
        current.isRouterConfigurationEnabled == null
    ) return null
    return (expected.isRelayEnabled == null || expected.isRelayEnabled == current.isRelayEnabled) &&
        (expected.isRouterConfigurationEnabled == null ||
            expected.isRouterConfigurationEnabled == current.isRouterConfigurationEnabled)
}

private fun remoteAccessWritableValues(settings: NasRemoteAccessSettings): Pair<Boolean?, Boolean?> =
    settings.isRelayEnabled to settings.isRouterConfigurationEnabled
