package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Security
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.ResourceList

@Composable
internal fun NasSecuritySettingsScreen(
    settings: NasSecuritySettings?,
    settingsAvailable: Boolean,
    fallback: List<ManagedResource>,
    state: WorkspaceState,
    model: AppViewModel,
) {
    val services = model.nasServices
    val states by services.state.collectAsState()
    val editor = states.getValue(NasServiceKind.SECURITY)
    val baseline = (editor.original as? NasServiceValue.Security)?.settings
    val draft = (editor.draft as? NasServiceValue.Security)?.settings
    var editing by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    LaunchedEffect(services) { services.refresh(NasServiceKind.SECURITY, notify = false) }
    SecuritySettingsContent(
        settings, settingsAvailable, fallback, baseline, draft, editor.saving, editor.result, editor.failure,
        refreshFailure = editor.failure, refreshInProgress = editor.busy && !editor.saving,
        refreshCompleted = false,
        enabled = !state.isPerformingAction && !editor.blocked,
        onEdit = { if (settings != null && services.begin(NasServiceValue.Security(settings))) editing = true },
        onRefresh = { services.refresh(NasServiceKind.SECURITY) },
        onContinueEditing = { services.dismiss(NasServiceKind.SECURITY); editing = true },
        onDismissResult = { services.dismiss(NasServiceKind.SECURITY, discard = true) },
        canContinueEditing = !editor.blocked && draft != null && editor.result?.errorCategory != MutationErrorCategory.CONFLICT,
        canDismiss = !editor.blocked,
    )
    if (editing && baseline != null && draft != null && !editor.blocked) SecuritySettingsDialog(
        initial = baseline, draft = draft, enabled = !state.isPerformingAction,
        onDraftChange = { services.draft(NasServiceKind.SECURITY, NasServiceValue.Security(it)) },
        onContinue = { editing = false; confirming = true; true },
        onDismiss = { editing = false; services.draft(NasServiceKind.SECURITY, null) },
    )
    if (confirming && baseline != null && draft != null && !editor.blocked) SecurityConfirmationDialog(
        baseline, draft,
        onConfirm = { services.save(NasServiceKind.SECURITY).also { if (it) confirming = false } },
        onDismiss = { confirming = false; editing = true },
    )
}

@Composable
internal fun SecuritySettingsContent(
    settings: NasSecuritySettings?,
    settingsAvailable: Boolean,
    fallback: List<ManagedResource>,
    baseline: NasSecuritySettings?,
    draft: NasSecuritySettings?,
    mutationInProgress: Boolean,
    mutationResult: MutationResult?,
    mutationFailure: DsmFailure?,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    enabled: Boolean,
    onEdit: () -> Unit,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismissResult: () -> Unit,
    canContinueEditing: Boolean? = null,
    canDismiss: Boolean? = null,
) {
    Column(Modifier.verticalScroll(rememberScrollState())) {
        TextButton(onClick = onRefresh, enabled = !mutationInProgress && !refreshInProgress, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.refresh_and_check_security_settings))
        }
        if (refreshInProgress) LinearProgressIndicator(Modifier.fillMaxWidth())
        when {
            mutationInProgress -> StructuredSettingsSavingCard(
                R.string.security_saving_title,
                R.string.security_saving_message,
            )
            mutationResult != null -> SettingsMutationFeedbackCard(
                result = mutationResult,
                failure = null,
                refreshFailure = refreshFailure,
                refreshInProgress = refreshInProgress,
                refreshCompleted = refreshCompleted,
                currentMatches = if (draft != null) settings?.let { securitySettingsMatch(it, draft) } else null,
                countsLabel = R.string.security_feedback_counts,
                refreshLabel = R.string.refresh_and_check_security_settings,
                onRefresh = onRefresh,
                onContinueEditing = onContinueEditing,
                onDismiss = onDismissResult,
                canContinueEditing = canContinueEditing,
                canDismiss = canDismiss,
            )
            mutationFailure != null -> SettingsMutationFeedbackCard(
                result = null,
                failure = mutationFailure,
                refreshFailure = refreshFailure,
                refreshInProgress = refreshInProgress,
                refreshCompleted = refreshCompleted,
                currentMatches = if (draft != null) settings?.let { securitySettingsMatch(it, draft) } else null,
                countsLabel = R.string.security_feedback_counts,
                refreshLabel = R.string.refresh_and_check_security_settings,
                onRefresh = onRefresh,
                onContinueEditing = onContinueEditing,
                onDismiss = onDismissResult,
                canContinueEditing = canContinueEditing,
                canDismiss = canDismiss,
            )
        }
        when {
            !settingsAvailable -> Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.security_settings_unavailable), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.security_settings_unavailable_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            settings == null && fallback.isEmpty() -> Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.security_settings_empty), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.security_settings_empty_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            settings == null -> ResourceList(fallback, stringResource(R.string.no_security_status), onSelect = {})
            else -> SecuritySettingsSummary(settings, enabled, onEdit)
        }
    }
}

@Composable
private fun SecuritySettingsSummary(settings: NasSecuritySettings, enabled: Boolean, onEdit: () -> Unit) {
    ListItem(
        headlineContent = { Text(stringResource(R.string.security_protection)) },
        supportingContent = {
            val active = listOfNotNull(
                stringResource(R.string.auto_block).takeIf { settings.isAutoBlockEnabled },
                stringResource(R.string.firewall).takeIf { settings.isFirewallEnabled == true },
                stringResource(R.string.port_scan_protection).takeIf { settings.isPortScanProtectionEnabled == true },
            )
            Text(active.joinToString(" · ").ifBlank { stringResource(R.string.security_protection_off) })
        },
        leadingContent = { Icon(Icons.Outlined.Security, null) },
        trailingContent = {
            TextButton(enabled = enabled, onClick = onEdit, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.edit))
            }
        },
    )
    HorizontalDivider(Modifier.padding(start = 72.dp))
    settings.dosProtection.forEach { adapter ->
        ListItem(
            headlineContent = { Text(adapter.displayName) },
            supportingContent = { Text(stringResource(R.string.dos_protection)) },
            trailingContent = { Text(stringResource(if (adapter.isEnabled) R.string.service_enabled else R.string.service_disabled)) },
        )
    }
}

@Composable
internal fun SecuritySettingsDialog(
    initial: NasSecuritySettings,
    draft: NasSecuritySettings,
    enabled: Boolean,
    onDraftChange: (NasSecuritySettings) -> Unit,
    onContinue: () -> Boolean,
    onDismiss: () -> Unit,
) {
    val valid = draft.failedAttempts in 1..9_999 && draft.withinMinutes in 1..9_999_999 &&
        (draft.expirationDays == null || draft.expirationDays in 1..999)
    AlertDialog(
        onDismissRequest = { if (enabled) onDismiss() },
        title = { Text(stringResource(R.string.security_protection)) },
        text = {
            Column(Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SettingsSwitch(stringResource(R.string.auto_block), draft.isAutoBlockEnabled, enabled) {
                    onDraftChange(draft.copy(isAutoBlockEnabled = it))
                }
                NumberField(draft.failedAttempts, enabled, R.string.failed_attempts, 1..9_999) {
                    onDraftChange(draft.copy(failedAttempts = it))
                }
                NumberField(draft.withinMinutes, enabled, R.string.within_minutes, 1..9_999_999) {
                    onDraftChange(draft.copy(withinMinutes = it))
                }
                SettingsSwitch(stringResource(R.string.expire_blocked_addresses), draft.expirationDays != null, enabled) {
                    onDraftChange(draft.copy(expirationDays = if (it) 1 else null))
                }
                draft.expirationDays?.let { value ->
                    NumberField(value, enabled, R.string.expiration_days, 1..999) {
                        onDraftChange(draft.copy(expirationDays = it))
                    }
                }
                draft.dosProtection.forEachIndexed { index, adapter ->
                    SettingsSwitch(adapter.displayName, adapter.isEnabled, enabled, stringResource(R.string.dos_protection)) { checked ->
                        onDraftChange(draft.copy(dosProtection = draft.dosProtection.mapIndexed { i, value ->
                            if (i == index) value.copy(isEnabled = checked) else value
                        }))
                    }
                }
                draft.isPortScanProtectionEnabled?.let { value ->
                    SettingsSwitch(stringResource(R.string.port_scan_protection), value, enabled) {
                        onDraftChange(draft.copy(isPortScanProtectionEnabled = it))
                    }
                }
                draft.isFirewallEnabled?.let { value ->
                    SettingsSwitch(stringResource(R.string.firewall), value, enabled) {
                        onDraftChange(draft.copy(isFirewallEnabled = it))
                    }
                    draft.firewallProfileName?.takeIf(String::isNotBlank)?.let {
                        Text(stringResource(R.string.firewall_profile_value, it), style = MaterialTheme.typography.bodySmall)
                    }
                }
                Text(stringResource(R.string.security_impact_hint), color = MaterialTheme.colorScheme.error)
            }
        },
        confirmButton = {
            TextButton(enabled = enabled && valid && draft != initial, onClick = { onContinue() }) {
                Text(stringResource(R.string.continue_action))
            }
        },
        dismissButton = { TextButton(enabled = enabled, onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun NumberField(value: Int, enabled: Boolean, @StringRes label: Int, range: IntRange, onValue: (Int) -> Unit) {
    OutlinedTextField(
        value = value.toString(),
        onValueChange = { text -> text.filter(Char::isDigit).toIntOrNull()?.takeIf { it in range }?.let(onValue) },
        enabled = enabled,
        label = { Text(stringResource(label)) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
internal fun SecurityConfirmationDialog(
    baseline: NasSecuritySettings,
    draft: NasSecuritySettings,
    onConfirm: () -> Boolean,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.save_security_settings_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.save_security_settings_message))
                Text(securityChangeSummary(baseline, draft), style = MaterialTheme.typography.bodyMedium)
            }
        },
        confirmButton = { TextButton(onClick = { onConfirm() }) { Text(stringResource(R.string.save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun securityChangeSummary(baseline: NasSecuritySettings, draft: NasSecuritySettings): String {
    val groups = buildList {
        if (baseline.isAutoBlockEnabled != draft.isAutoBlockEnabled || baseline.failedAttempts != draft.failedAttempts ||
            baseline.withinMinutes != draft.withinMinutes || baseline.expirationDays != draft.expirationDays) add(stringResource(R.string.auto_block))
        if (baseline.dosProtection != draft.dosProtection) add(stringResource(R.string.dos_protection))
        if (baseline.isPortScanProtectionEnabled != draft.isPortScanProtectionEnabled) add(stringResource(R.string.port_scan_protection))
        if (baseline.isFirewallEnabled != draft.isFirewallEnabled) add(stringResource(R.string.firewall))
    }
    return stringResource(R.string.settings_change_summary, groups.joinToString(", "))
}

internal data class WritableSecuritySettings(
    val isAutoBlockEnabled: Boolean,
    val failedAttempts: Int,
    val withinMinutes: Int,
    val expirationDays: Int?,
    val dosProtectionById: Map<String, Boolean>,
    val isFirewallEnabled: Boolean?,
    val isPortScanProtectionEnabled: Boolean?,
)

internal fun writableSecuritySettings(value: NasSecuritySettings) = WritableSecuritySettings(
    isAutoBlockEnabled = value.isAutoBlockEnabled,
    failedAttempts = value.failedAttempts,
    withinMinutes = value.withinMinutes,
    expirationDays = value.expirationDays,
    dosProtectionById = value.dosProtection.associate { it.id to it.isEnabled },
    isFirewallEnabled = value.isFirewallEnabled,
    isPortScanProtectionEnabled = value.isPortScanProtectionEnabled,
)

internal fun securitySettingsMatch(current: NasSecuritySettings, draft: NasSecuritySettings): Boolean =
    writableSecuritySettings(current) == writableSecuritySettings(draft)

@Composable
internal fun SettingsSwitch(label: String, checked: Boolean, enabled: Boolean, supporting: String? = null, onChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(
            value = checked,
            enabled = enabled,
            role = Role.Switch,
            onValueChange = onChange,
        ).semantics(mergeDescendants = true) { role = Role.Switch },
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(end = 16.dp)) {
            Text(label)
            supporting?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

internal data class SettingsFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val mustRefresh: Boolean,
    val assertive: Boolean,
)

internal fun settingsFeedbackPolicy(result: MutationResult): SettingsFeedbackPolicy {
    val submitted = result.submitted || result.requiresRefresh || result.errorCategory == MutationErrorCategory.CONFLICT
    val mustRefresh = when (result.status) {
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> true
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CONFIRMED_FAILURE -> submitted || result.requiresRefresh ||
            result.errorCategory == MutationErrorCategory.CONFLICT
        MutationResultStatus.CONFIRMED_SUCCESS,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> false
    }
    val title = when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> R.string.settings_feedback_success_title
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
        MutationResultStatus.CONFIRMED_SUCCESS -> R.string.settings_feedback_success_message
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
    return SettingsFeedbackPolicy(title, message, mustRefresh, result.status != MutationResultStatus.CONFIRMED_SUCCESS)
}

@Composable
internal fun SettingsMutationFeedbackCard(
    result: MutationResult?,
    failure: DsmFailure?,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    currentMatches: Boolean?,
    @StringRes countsLabel: Int,
    @StringRes refreshLabel: Int,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
    canContinueEditing: Boolean? = null,
    canDismiss: Boolean? = null,
) {
    val policy = result?.let(::settingsFeedbackPolicy)
    val mustRefresh = failure != null || refreshFailure != null || policy?.mustRefresh == true
    val canLeave = !mustRefresh || refreshCompleted
    SettingsFeedbackCard(if (failure != null || policy?.assertive == true) LiveRegionMode.Assertive else LiveRegionMode.Polite, failure != null) {
        Text(stringResource(policy?.title ?: R.string.settings_feedback_failed_title), style = MaterialTheme.typography.titleMedium)
        if (failure != null) Text(failure.localize(LocalContext.current).combined) else Text(stringResource(policy!!.message))
        result?.counts?.takeIf { it.succeeded + it.failed + it.unknown > 0 }?.let {
            Text(stringResource(countsLabel, it.succeeded, it.failed, it.unknown), style = MaterialTheme.typography.bodySmall)
        }
        if (refreshCompleted) Text(stringResource(when (currentMatches) {
            true -> R.string.settings_refresh_matches
            false -> R.string.settings_refresh_differs
            null -> R.string.settings_refresh_unavailable
        }))
        refreshFailure?.let { Text(it.localize(LocalContext.current).combined) }
        if (refreshInProgress) {
            Text(stringResource(R.string.settings_refreshing), style = MaterialTheme.typography.bodySmall)
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        if (mustRefresh) {
            TextButton(
                enabled = !refreshInProgress,
                onClick = onRefresh,
                modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(refreshLabel)) }
        }
        if (canContinueEditing != false) TextButton(
            enabled = (canContinueEditing ?: canLeave) && !refreshInProgress,
            onClick = onContinueEditing,
            modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics { role = Role.Button },
        ) {
            Text(stringResource(R.string.continue_editing))
        }
        if (canDismiss != false) TextButton(
            enabled = (canDismiss ?: canLeave) && !refreshInProgress,
            onClick = onDismiss,
            modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics { role = Role.Button },
        ) {
            Text(stringResource(if (result?.status == MutationResultStatus.CONFIRMED_SUCCESS) R.string.done else R.string.discard_changes))
        }
    }
}

@Composable
internal fun StructuredSettingsSavingCard(@StringRes title: Int, @StringRes message: Int) {
    SettingsFeedbackCard(LiveRegionMode.Polite, false) {
        Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(message))
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
private fun SettingsFeedbackCard(mode: LiveRegionMode, error: Boolean, content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = mode },
        colors = if (error) CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
            contentColor = MaterialTheme.colorScheme.onErrorContainer,
        ) else CardDefaults.cardColors(),
    ) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
    }
}
