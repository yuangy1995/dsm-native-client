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
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Lan
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
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasServiceRecord
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.DdnsMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.ConfirmDialog

@Composable
internal fun EthernetAndDdnsList(
    snapshot: NasSettingsSnapshot,
    state: WorkspaceState,
    model: AppViewModel,
) {
    NasDdnsManagement(snapshot, state.isPerformingAction, model)
}

@Composable
internal fun EthernetManagement(interfaces: List<NasEthernetInterface>, available: Boolean,
    isPerformingAction: Boolean, model: AppViewModel) {
    val services = model.nasServices; val kind = NasServiceKind.ETHERNET
    val values by services.state.collectAsState(); val state = values.getValue(kind)
    val original = (state.original as? NasServiceValue.Ethernet)?.settings
    val draft = (state.draft as? NasServiceValue.Ethernet)?.settings
    var editing by rememberSaveable { mutableStateOf(false) }
    var confirming by rememberSaveable { mutableStateOf(false) }
    var association by remember { mutableStateOf<NasServiceRecord?>(null) }
    LaunchedEffect(services) { services.refresh(kind, notify = false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.physical_network_interfaces), style = MaterialTheme.typography.titleMedium)
        if (state.saving && draft != null) EthernetSavingCard(draft)
        else if (state.needsAssociation) {
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.ethernet_reconnect_title), style = MaterialTheme.typography.titleSmall)
                Text(stringResource(if (state.canAssociate) R.string.ethernet_reconnect_same_nas else R.string.ethernet_reconnect_original_account))
                state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
                if (state.canAssociate) TextButton(onClick = { association = state.record }, enabled = !state.busy) {
                    Text(stringResource(R.string.ethernet_reconnect_action))
                }
            } }
        } else if (state.result != null || state.failure != null) SettingsMutationFeedbackCard(
            result = state.result, failure = state.failure, refreshFailure = null,
            refreshInProgress = state.busy, refreshCompleted = false, currentMatches = null,
            countsLabel = R.string.ethernet_feedback_counts, refreshLabel = R.string.refresh_network_interfaces,
            onRefresh = { services.refresh(kind) },
            onContinueEditing = { services.dismiss(kind); editing = true },
            onDismiss = { services.dismiss(kind, discard = true) },
            canContinueEditing = !state.blocked && draft != null, canDismiss = !state.blocked)
        else if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (state.record?.terminal == false && !state.needsAssociation) Text(
            stringResource(R.string.ethernet_reconnect_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (!available || interfaces.isEmpty()) EthernetEmptyState(available, !state.busy) { services.refresh(kind) }
        else interfaces.forEach { ethernet ->
            EthernetListItem(ethernet, !isPerformingAction && !state.blocked && original == null) {
                editing = services.begin(NasServiceValue.Ethernet(ethernet))
            }
            HorizontalDivider(Modifier.padding(start = 56.dp))
        }
    }
    if (editing && original != null && draft != null) EthernetEditDialog(original, draft, !isPerformingAction && !state.blocked,
        onDraftChange = { services.draft(kind, NasServiceValue.Ethernet(it)) },
        onContinue = { editing = false; confirming = true; true },
        onDismiss = { services.draft(kind, null); editing = false })
    if (confirming && original != null && draft != null) EthernetConfirmationDialog(original, draft,
        onConfirm = { services.save(kind).also { if (it) confirming = false } },
        onDismiss = { confirming = false; editing = true })
    association?.let { record -> ConfirmDialog(
        title = stringResource(R.string.ethernet_reconnect_title), message = stringResource(R.string.ethernet_reconnect_confirmation),
        confirm = stringResource(R.string.ethernet_reconnect_action), destructive = false,
        onConfirm = { services.associateEthernet(record); association = null }, onDismiss = { association = null }) }
}

@Composable
internal fun EthernetSettingsContent(
    interfaces: List<NasEthernetInterface>,
    interfacesAvailable: Boolean,
    baseline: NasEthernetInterface?,
    draft: NasEthernetInterface?,
    mutationResult: MutationResult?,
    mutationFailure: DsmFailure?,
    refreshFailure: DsmFailure?,
    mutationInProgress: Boolean,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    isPerformingAction: Boolean,
    currentTarget: NasEthernetInterface?,
    onEdit: (NasEthernetInterface) -> Unit,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismissResult: () -> Unit,
    onRefreshList: () -> Unit,
) {
    Column {
        Text(
            stringResource(R.string.physical_network_interfaces),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 8.dp),
        )
        when {
            mutationInProgress && draft != null -> EthernetSavingCard(draft)
            mutationResult != null && baseline != null && draft != null -> EthernetMutationFeedbackCard(
                baseline = baseline,
                draft = draft,
                currentTarget = currentTarget,
                result = mutationResult,
                refreshFailure = refreshFailure,
                refreshInProgress = refreshInProgress,
                refreshCompleted = refreshCompleted,
                onRefresh = onRefresh,
                onContinueEditing = onContinueEditing,
                onDismiss = onDismissResult,
            )
            mutationFailure != null && draft != null -> EthernetMutationFailureCard(
                draft = draft,
                currentTarget = currentTarget,
                failure = mutationFailure,
                refreshFailure = refreshFailure,
                refreshInProgress = refreshInProgress,
                refreshCompleted = refreshCompleted,
                onRefresh = onRefresh,
                onContinueEditing = onContinueEditing,
                onDismiss = onDismissResult,
            )
        }
        if (!interfacesAvailable || interfaces.isEmpty()) {
            EthernetEmptyState(
                available = interfacesAvailable,
                enabled = !isPerformingAction,
                onRefresh = onRefreshList,
            )
        } else {
            interfaces.forEach { ethernet ->
                EthernetListItem(
                    ethernet = ethernet,
                    enabled = !isPerformingAction && baseline == null && mutationResult == null &&
                        mutationFailure == null,
                    onEdit = { onEdit(ethernet) },
                )
                HorizontalDivider(Modifier.padding(start = 72.dp))
            }
        }
    }
}

@Composable
internal fun EthernetListItem(
    ethernet: NasEthernetInterface,
    enabled: Boolean,
    onEdit: () -> Unit,
) {
    val mode = stringResource(
        if (ethernet.usesDhcp) R.string.network_mode_automatic else R.string.network_mode_manual,
    )
    val status = ethernetStatusText(ethernet.status)
    val editDescription = stringResource(R.string.edit_network_interface_accessibility, ethernet.displayName)
    ListItem(
        headlineContent = { Text(ethernet.displayName) },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(listOfNotNull(mode, ethernet.address.takeIf(String::isNotBlank), status).joinToString(" · "))
                Text(
                    stringResource(
                        R.string.network_interface_summary,
                        ethernet.mtu,
                        if (ethernet.isDefaultGateway) stringResource(R.string.default_route) else stringResource(R.string.not_default_route),
                        if (ethernet.isVlanEnabled) stringResource(R.string.vlan_value, ethernet.vlanId ?: 0)
                        else stringResource(R.string.vlan_disabled),
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        },
        leadingContent = { Icon(Icons.Outlined.Lan, null) },
        trailingContent = {
            TextButton(
                onClick = onEdit,
                enabled = enabled,
                modifier = Modifier.heightIn(min = 48.dp).semantics {
                    role = Role.Button
                    contentDescription = editDescription
                },
            ) {
                Icon(Icons.Outlined.Edit, null)
                Text(stringResource(R.string.edit_network_interface))
            }
        },
    )
}

@Composable
private fun EthernetEmptyState(available: Boolean, enabled: Boolean, onRefresh: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            stringResource(
                if (available) R.string.no_physical_network_interfaces else R.string.network_interfaces_unavailable,
            ),
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            stringResource(
                if (available) R.string.no_physical_network_interfaces_hint
                else R.string.network_interfaces_unavailable_hint,
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        TextButton(onClick = onRefresh, enabled = enabled) {
            Text(stringResource(R.string.refresh_network_interfaces))
        }
    }
}

@Composable
internal fun EthernetEditDialog(
    initial: NasEthernetInterface,
    draft: NasEthernetInterface,
    enabled: Boolean,
    onDraftChange: (NasEthernetInterface) -> Unit,
    onContinue: () -> Boolean,
    onDismiss: () -> Unit,
) {
    val validation = ethernetValidation(draft)
    AlertDialog(
        onDismissRequest = { if (enabled) onDismiss() },
        title = { Text(stringResource(R.string.edit_network_interface_title, initial.displayName)) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                LabeledSwitch(
                    label = stringResource(R.string.obtain_ipv4_automatically),
                    checked = draft.usesDhcp,
                    enabled = enabled,
                    onCheckedChange = { onDraftChange(draft.copy(usesDhcp = it)) },
                )
                if (!draft.usesDhcp) {
                    NetworkTextField(R.string.ip_address, draft.address, enabled = enabled) {
                        onDraftChange(draft.copy(address = it))
                    }
                    NetworkTextField(R.string.subnet_mask, draft.subnetMask, enabled = enabled) {
                        onDraftChange(draft.copy(subnetMask = it))
                    }
                    NetworkTextField(R.string.default_gateway, draft.gateway, enabled = enabled) {
                        onDraftChange(draft.copy(gateway = it))
                    }
                    NetworkTextField(R.string.dns_servers, draft.dnsServers, enabled = enabled) {
                        onDraftChange(draft.copy(dnsServers = it))
                    }
                }
                NetworkTextField(
                    label = R.string.mtu,
                    value = draft.mtu.toString(),
                    numeric = true,
                    enabled = enabled,
                ) { text -> onDraftChange(draft.copy(mtu = text.toIntOrNull() ?: 0)) }
                LabeledSwitch(
                    label = stringResource(R.string.use_as_default_gateway),
                    checked = draft.isDefaultGateway,
                    enabled = enabled,
                    onCheckedChange = { onDraftChange(draft.copy(isDefaultGateway = it)) },
                )
                LabeledSwitch(
                    label = stringResource(R.string.enable_vlan),
                    checked = draft.isVlanEnabled,
                    enabled = enabled,
                    onCheckedChange = {
                        onDraftChange(draft.copy(isVlanEnabled = it, vlanId = draft.vlanId ?: 1))
                    },
                )
                if (draft.isVlanEnabled) {
                    NetworkTextField(
                        label = R.string.vlan_id,
                        value = draft.vlanId?.toString().orEmpty(),
                        numeric = true,
                        enabled = enabled,
                    ) { text -> onDraftChange(draft.copy(vlanId = text.toIntOrNull())) }
                }
                validation?.let { error ->
                    Text(
                        stringResource(error),
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
                    )
                }
                Text(
                    stringResource(
                        if (initial.isDefaultGateway || draft.isDefaultGateway) {
                            R.string.network_settings_default_route_recovery_hint
                        } else {
                            R.string.network_settings_recovery_hint
                        },
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = enabled && validation == null && draft != initial,
                onClick = { onContinue() },
            ) { Text(stringResource(R.string.continue_action)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = enabled) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
internal fun EthernetConfirmationDialog(
    baseline: NasEthernetInterface,
    draft: NasEthernetInterface,
    onConfirm: () -> Boolean,
    onDismiss: () -> Unit,
) {
    val highRisk = ethernetHasConnectionRisk(baseline, draft)
    ConfirmDialog(
        title = stringResource(R.string.save_network_interface_title, draft.displayName),
        message = stringResource(
            R.string.save_network_interface_confirmation,
            ethernetChangeSummary(baseline, draft),
            stringResource(
                if (highRisk) R.string.save_network_interface_high_risk_message
                else R.string.save_network_interface_message,
            ),
        ),
        confirm = stringResource(R.string.save_network_settings),
        destructive = true,
        onConfirm = { onConfirm() },
        onDismiss = onDismiss,
    )
}

@Composable
private fun LabeledSwitch(
    label: String,
    checked: Boolean,
    enabled: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange)
            .semantics(mergeDescendants = true) { },
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, modifier = Modifier.weight(1f).padding(end = 16.dp))
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

@Composable
private fun NetworkTextField(
    @StringRes label: Int,
    value: String,
    numeric: Boolean = false,
    enabled: Boolean,
    onValueChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        enabled = enabled,
        label = { Text(stringResource(label)) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(
            keyboardType = if (numeric) KeyboardType.Number else KeyboardType.Ascii,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}

internal data class EthernetFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val canRefresh: Boolean,
    val mustRefreshBeforeDismiss: Boolean,
    val isAssertive: Boolean,
)

internal fun ethernetFeedbackPolicy(result: MutationResult): EthernetFeedbackPolicy {
    require(result.operation == "ethernetUpdate") { "ethernet.unexpected-operation" }
    val submittedOrConflict = result.submitted || result.requiresRefresh ||
        result.errorCategory == MutationErrorCategory.CONFLICT
    return when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> EthernetFeedbackPolicy(
            R.string.ethernet_feedback_saved_title,
            R.string.ethernet_feedback_saved_message,
            false,
            false,
            false,
        )
        MutationResultStatus.PARTIAL_SUCCESS -> EthernetFeedbackPolicy(
            R.string.ethernet_feedback_check_title,
            R.string.ethernet_feedback_partial_message,
            true,
            true,
            true,
        )
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED -> EthernetFeedbackPolicy(
            R.string.ethernet_feedback_check_title,
            R.string.ethernet_feedback_unverified_message,
            true,
            true,
            true,
        )
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> EthernetFeedbackPolicy(
            R.string.ethernet_feedback_check_title,
            R.string.ethernet_feedback_cancel_after_submission,
            true,
            true,
            true,
        )
        MutationResultStatus.PERMISSION_DENIED -> EthernetFeedbackPolicy(
            R.string.ethernet_feedback_permission_title,
            R.string.ethernet_feedback_permission_message,
            submittedOrConflict,
            submittedOrConflict,
            true,
        )
        MutationResultStatus.UNSUPPORTED -> EthernetFeedbackPolicy(
            R.string.ethernet_feedback_unavailable_title,
            R.string.ethernet_feedback_unsupported_message,
            submittedOrConflict,
            submittedOrConflict,
            true,
        )
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> EthernetFeedbackPolicy(
            R.string.ethernet_feedback_cancelled_title,
            R.string.ethernet_feedback_cancelled_message,
            false,
            false,
            false,
        )
        MutationResultStatus.CONFIRMED_FAILURE -> EthernetFeedbackPolicy(
            if (result.errorCategory == MutationErrorCategory.CONFLICT) {
                R.string.ethernet_feedback_conflict_title
            } else {
                R.string.ethernet_feedback_failed_title
            },
            if (result.errorCategory == MutationErrorCategory.CONFLICT) {
                R.string.ethernet_feedback_conflict_message
            } else {
                R.string.ethernet_feedback_failed_message
            },
            submittedOrConflict,
            submittedOrConflict,
            true,
        )
    }
}

@Composable
internal fun EthernetSavingCard(draft: NasEthernetInterface) {
    EthernetFeedbackCard(liveRegion = LiveRegionMode.Polite, isError = false) {
        Text(stringResource(R.string.ethernet_saving_title), style = MaterialTheme.typography.titleMedium)
        Text(ethernetTargetSummary(draft))
        Text(stringResource(R.string.ethernet_saving_message))
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
internal fun EthernetMutationFeedbackCard(
    baseline: NasEthernetInterface,
    draft: NasEthernetInterface,
    currentTarget: NasEthernetInterface?,
    result: MutationResult,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    val policy = ethernetFeedbackPolicy(result)
    val canLeave = !policy.mustRefreshBeforeDismiss || refreshCompleted
    EthernetFeedbackCard(
        liveRegion = if (policy.isAssertive) LiveRegionMode.Assertive else LiveRegionMode.Polite,
        isError = result.status == MutationResultStatus.PERMISSION_DENIED ||
            result.status == MutationResultStatus.CONFIRMED_FAILURE,
    ) {
        Text(stringResource(policy.title), style = MaterialTheme.typography.titleMedium)
        Text(ethernetTargetSummary(draft))
        Text(stringResource(policy.message))
        Text(ethernetChangeSummary(baseline, draft), style = MaterialTheme.typography.bodySmall)
        val counts = result.counts
        if (counts.succeeded + counts.failed + counts.unknown > 0) {
            Text(
                stringResource(
                    R.string.ethernet_feedback_counts,
                    counts.succeeded,
                    counts.failed,
                    counts.unknown,
                ),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        EthernetRefreshState(refreshCompleted, currentTarget, draft, refreshFailure, refreshInProgress)
        if (policy.canRefresh || refreshFailure != null) {
            TextButton(onClick = onRefresh, enabled = !refreshInProgress, modifier = Modifier.align(Alignment.End)) {
                Text(stringResource(R.string.refresh_and_check_network_interface))
            }
        }
        if (result.status != MutationResultStatus.CONFIRMED_SUCCESS) {
            TextButton(
                onClick = onContinueEditing,
                enabled = !refreshInProgress && canLeave && currentTarget != null,
                modifier = Modifier.align(Alignment.End),
            ) { Text(stringResource(R.string.continue_editing)) }
        }
        TextButton(
            onClick = onDismiss,
            enabled = !refreshInProgress && canLeave,
            modifier = Modifier.align(Alignment.End),
        ) {
            Text(
                stringResource(
                    if (result.status == MutationResultStatus.CONFIRMED_SUCCESS) R.string.done
                    else R.string.discard_changes,
                ),
            )
        }
    }
}

@Composable
internal fun EthernetMutationFailureCard(
    draft: NasEthernetInterface,
    currentTarget: NasEthernetInterface?,
    failure: DsmFailure,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    EthernetFeedbackCard(liveRegion = LiveRegionMode.Assertive, isError = true) {
        Text(stringResource(R.string.ethernet_feedback_failed_title), style = MaterialTheme.typography.titleMedium)
        Text(ethernetTargetSummary(draft))
        Text(failure.localize(LocalContext.current).combined)
        EthernetRefreshState(
            refreshCompleted = refreshCompleted,
            currentTarget = currentTarget,
            draft = draft,
            refreshFailure = refreshFailure,
            refreshInProgress = refreshInProgress,
        )
        TextButton(onClick = onRefresh, enabled = !refreshInProgress, modifier = Modifier.align(Alignment.End)) {
            Text(stringResource(R.string.refresh_and_check_network_interface))
        }
        TextButton(
            onClick = onContinueEditing,
            enabled = refreshCompleted && !refreshInProgress && currentTarget != null,
            modifier = Modifier.align(Alignment.End),
        ) { Text(stringResource(R.string.continue_editing)) }
        TextButton(
            onClick = onDismiss,
            enabled = refreshCompleted && !refreshInProgress,
            modifier = Modifier.align(Alignment.End),
        ) { Text(stringResource(R.string.discard_changes)) }
    }
}

@Composable
private fun ColumnScope.EthernetRefreshState(
    refreshCompleted: Boolean,
    currentTarget: NasEthernetInterface?,
    draft: NasEthernetInterface,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
) {
    if (refreshCompleted) {
        Text(
            stringResource(
                when {
                    currentTarget == null -> R.string.ethernet_refresh_target_missing
                    ethernetMatchesDraft(currentTarget, draft) -> R.string.ethernet_refresh_matches
                    else -> R.string.ethernet_refresh_differs
                },
            ),
            style = MaterialTheme.typography.bodySmall,
        )
    }
    refreshFailure?.let { Text(it.localize(LocalContext.current).combined) }
    if (refreshInProgress) {
        Text(stringResource(R.string.refreshing_network_interface), style = MaterialTheme.typography.bodySmall)
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
private fun EthernetFeedbackCard(
    liveRegion: LiveRegionMode,
    isError: Boolean,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth().padding(16.dp).semantics { this.liveRegion = liveRegion },
        colors = CardDefaults.cardColors(
            containerColor = if (isError) MaterialTheme.colorScheme.errorContainer
            else MaterialTheme.colorScheme.secondaryContainer,
        ),
    ) {
        Column(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            content = content,
        )
    }
}

@Composable
private fun ethernetTargetSummary(value: NasEthernetInterface): String = stringResource(
    R.string.ethernet_target_summary,
    value.displayName,
    if (value.usesDhcp) stringResource(R.string.network_mode_automatic)
    else stringResource(R.string.network_mode_manual),
)

@Composable
internal fun ethernetChangeSummary(
    baseline: NasEthernetInterface,
    draft: NasEthernetInterface,
): String {
    val lines = mutableListOf<String>()
    fun addChangeValue(value: String?) {
        if (value != null) lines += value
    }
    addChangeValue(
        ethernetChangeLine(
            R.string.ipv4_configuration,
            stringResource(if (baseline.usesDhcp) R.string.network_mode_automatic else R.string.network_mode_manual),
            stringResource(if (draft.usesDhcp) R.string.network_mode_automatic else R.string.network_mode_manual),
        ),
    )
    if (!draft.usesDhcp) {
        addChangeValue(ethernetChangeLine(R.string.ip_address, baseline.address, draft.address))
        addChangeValue(ethernetChangeLine(R.string.subnet_mask, baseline.subnetMask, draft.subnetMask))
        addChangeValue(ethernetChangeLine(R.string.default_gateway, displayValue(baseline.gateway), displayValue(draft.gateway)))
        addChangeValue(ethernetChangeLine(R.string.dns_servers, displayValue(baseline.dnsServers), displayValue(draft.dnsServers)))
    }
    addChangeValue(ethernetChangeLine(R.string.mtu, baseline.mtu.toString(), draft.mtu.toString()))
    addChangeValue(
        ethernetChangeLine(
            R.string.use_as_default_gateway,
            stringResource(if (baseline.isDefaultGateway) R.string.enabled else R.string.disabled),
            stringResource(if (draft.isDefaultGateway) R.string.enabled else R.string.disabled),
        ),
    )
    addChangeValue(
        ethernetChangeLine(
            R.string.vlan_id,
            vlanSummary(baseline),
            vlanSummary(draft),
        ),
    )
    return lines.ifEmpty { listOf(stringResource(R.string.no_network_changes)) }.joinToString("\n")
}

@Composable
private fun ethernetChangeLine(@StringRes label: Int, before: String, after: String): String? =
    if (before == after) null
    else stringResource(R.string.ethernet_change_line, stringResource(label), before, after)

@Composable
private fun displayValue(value: String): String = value.ifBlank { stringResource(R.string.not_configured) }

@Composable
private fun vlanSummary(value: NasEthernetInterface): String = if (value.isVlanEnabled) {
    stringResource(R.string.vlan_value, value.vlanId ?: 0)
} else {
    stringResource(R.string.vlan_disabled)
}

@Composable
private fun ethernetStatusText(status: String?): String? = when (status?.lowercase()) {
    "connected", "up" -> stringResource(R.string.network_interface_connected)
    "disconnected", "down" -> stringResource(R.string.network_interface_disconnected)
    null, "" -> null
    else -> stringResource(R.string.network_interface_status_unknown)
}

internal fun ethernetMatchesDraft(actual: NasEthernetInterface, expected: NasEthernetInterface): Boolean =
    actual.id == expected.id && actual.usesDhcp == expected.usesDhcp &&
        (expected.usesDhcp || actual.address.trim() == expected.address.trim()) &&
        (expected.usesDhcp || actual.subnetMask.trim() == expected.subnetMask.trim()) &&
        (expected.usesDhcp || actual.gateway.trim() == expected.gateway.trim()) &&
        (expected.usesDhcp || actual.dnsServers.trim() == expected.dnsServers.trim()) &&
        actual.isDefaultGateway == expected.isDefaultGateway && actual.mtu == expected.mtu &&
        actual.isVlanEnabled == expected.isVlanEnabled &&
        (!expected.isVlanEnabled || actual.vlanId == expected.vlanId)

internal fun ethernetHasConnectionRisk(
    baseline: NasEthernetInterface,
    draft: NasEthernetInterface,
): Boolean = baseline.isDefaultGateway || draft.isDefaultGateway ||
    baseline.usesDhcp != draft.usesDhcp || baseline.address.trim() != draft.address.trim() ||
    baseline.gateway.trim() != draft.gateway.trim() || baseline.isVlanEnabled != draft.isVlanEnabled ||
    baseline.vlanId != draft.vlanId

internal fun NasDdnsRecord.toDraft() = NasDdnsDraft(
    originalProviderId = providerId,
    providerId = providerId,
    hostname = hostname,
    username = username,
    isEnabled = isEnabled,
    networkType = networkType,
    ipv4 = ipv4,
    ipv6 = ipv6,
    interfaceV4 = interfaceV4,
    interfaceV6 = interfaceV6,
    heartbeat = heartbeat,
)

internal fun ethernetValidation(value: NasEthernetInterface): Int? = when {
    value.mtu !in 576..9_000 -> R.string.invalid_mtu
    value.isVlanEnabled && value.vlanId?.let { it in 1..4_094 } != true -> R.string.invalid_vlan_id
    !value.usesDhcp && (
        !validIpv4(value.address) || !validIpv4(value.subnetMask) ||
            (value.gateway.isNotBlank() && !validIpv4(value.gateway))
        ) -> R.string.invalid_ipv4_settings
    value.dnsServers.length > 512 || value.dnsServers.any { it == '\n' || it == '\r' } ->
        R.string.invalid_dns_servers
    else -> null
}

private fun validIpv4(value: String): Boolean {
    val parts = value.trim().split('.', limit = 5)
    return parts.size == 4 && parts.all { part ->
        part.isNotEmpty() && part.length <= 3 && part.all(Char::isDigit) &&
            part.toIntOrNull()?.let { it in 0..255 } == true &&
            (part == "0" || !part.startsWith('0'))
    }
}
