package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.DdnsMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDirectory
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize

@Composable
internal fun NasDdnsManagement(snapshot: NasSettingsSnapshot, isPerformingAction: Boolean, model: AppViewModel) {
    val ddns = model.nasDdns; val state by ddns.state.collectAsState()
    var editing by remember { mutableStateOf(false) }
    LaunchedEffect(ddns) { ddns.refresh() }
    DisposableEffect(ddns) { onDispose { ddns.leave() } }
    DdnsManagementContent(state.current, state.current != null,
        enabled = !state.blocked && !isPerformingAction && !editing && state.confirmation == null,
        leadingContent = {
            item { NasRemoteAccessManagement(snapshot.remoteAccessSettings, snapshot.remoteAccessSettingsAvailable, isPerformingAction, model) }
            item { EthernetManagement(snapshot.networkInterfaces, snapshot.networkInterfacesAvailable, isPerformingAction, model) }
        },
        mutationStatusContent = {
            if (state.saving && state.operation != null) DdnsSavingCard(requireNotNull(state.operation), state.draft, null, emptyList(), state.current)
            else if (state.result != null && state.operation != null) DdnsMutationFeedbackCard(
                operation = requireNotNull(state.operation), draft = state.draft, deleteTarget = null, addressTargets = emptyList(),
                providers = state.current?.providers.orEmpty(), currentRecord = null, result = requireNotNull(state.result),
                refreshFailure = state.failure, refreshInProgress = state.busy, refreshCompleted = false,
                onRefresh = ddns::refresh, onContinueEditing = { ddns.dismiss(); editing = true }, onDismiss = { ddns.dismiss(discard = true) },
                canContinueEditing = !state.blocked && state.draft != null && state.current != null && state.result?.errorCategory != MutationErrorCategory.CONFLICT, canDismiss = !state.blocked)
            else if (state.failure != null) Column(Modifier.padding(16.dp)) {
                Text(requireNotNull(state.failure).localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error)
                TextButton(onClick = ddns::refresh, enabled = !state.busy) { Text(stringResource(R.string.refresh_and_check_ddns)) }
            } else if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (state.record?.requiresAcceptance == true && state.record?.blocks == true && state.record?.accepted == false)
                Text(stringResource(R.string.ddns_credentials_unknown_hint), Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        },
        onAdd = { editing = ddns.begin(it) }, onEdit = { editing = ddns.begin(it.toDraft()) },
        onDelete = { ddns.prepare(DdnsMutationOperation.DELETE, it) }, onRefreshAddress = { ddns.prepare(DdnsMutationOperation.ADDRESS_REFRESH) },
        onReload = ddns::refresh, reloadEnabled = !state.busy && !editing && state.confirmation == null)
    val draft = state.draft
    if (editing && draft != null && state.confirmation == null) DdnsEditorDialog(
        initial = state.original?.records?.singleOrNull { it.providerId == draft.originalProviderId }?.toDraft() ?: NasDdnsDraft(providerId = draft.providerId, hostname = "", username = ""),
        draft = draft, providers = state.current?.providers.orEmpty(), enabled = !state.blocked && !isPerformingAction,
        onDraftChange = ddns::draft,
        onTest = { ddns.prepare(DdnsMutationOperation.TEST).also { if (it) editing = false } },
        onSave = { ddns.prepare(DdnsMutationOperation.SAVE).also { if (it) editing = false } },
        onDismiss = { ddns.leave(); editing = false })
    state.confirmation?.let { plan -> DdnsConfirmationDialog(plan.operation, plan.draft, plan.target,
        plan.original.records.takeIf { plan.operation == DdnsMutationOperation.ADDRESS_REFRESH }.orEmpty(), plan.original.providers,
        onConfirm = { ddns.confirm(plan) }, onDismiss = {
            ddns.cancelConfirmation(); editing = plan.operation in setOf(DdnsMutationOperation.SAVE, DdnsMutationOperation.TEST)
        }) }
}

@Composable
internal fun DdnsManagementContent(
    directory: NasDdnsDirectory?,
    directoryAvailable: Boolean,
    enabled: Boolean,
    leadingContent: LazyListScope.() -> Unit = {},
    mutationStatusContent: @Composable () -> Unit = {},
    onAdd: (NasDdnsDraft) -> Unit,
    onRefreshAddress: () -> Unit,
    onEdit: (NasDdnsRecord) -> Unit,
    onDelete: (NasDdnsRecord) -> Unit,
    onReload: (() -> Unit)? = null,
    reloadEnabled: Boolean = enabled,
) {
    LazyColumn {
        leadingContent()
        item {
            DdnsToolbar(
                directory = directory,
                directoryAvailable = directoryAvailable,
                enabled = enabled,
                onAdd = onAdd,
                onRefresh = onRefreshAddress,
                onReload = onReload, reloadEnabled = reloadEnabled,
            )
        }
        item { mutationStatusContent() }
        if (!directoryAvailable || directory?.records.isNullOrEmpty()) {
            item {
                DdnsEmptyState(
                    directoryAvailable = directoryAvailable,
                    canAdd = directory?.providers?.isNotEmpty() == true,
                )
            }
        }
        items(directory?.records.orEmpty(), key = { "ddns:${it.providerId}" }) { record ->
            DdnsRecordRow(
                record = record,
                enabled = enabled,
                onEdit = { onEdit(record) },
                onDelete = { onDelete(record) },
            )
        }
    }
}

@Composable
internal fun DdnsToolbar(
    directory: NasDdnsDirectory?,
    directoryAvailable: Boolean,
    enabled: Boolean,
    onAdd: (NasDdnsDraft) -> Unit,
    onRefresh: () -> Unit,
    onReload: (() -> Unit)? = null,
    reloadEnabled: Boolean = enabled,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
        Text(stringResource(R.string.dynamic_domain_name), style = MaterialTheme.typography.titleMedium)
        FlowRow(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            TextButton(
                enabled = enabled && directoryAvailable && directory?.providers?.isNotEmpty() == true,
                onClick = {
                    val provider = directory?.providers?.firstOrNull() ?: return@TextButton
                    onAdd(NasDdnsDraft(providerId = provider.id, username = "", hostname = ""))
                },
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Icon(Icons.Outlined.Add, null)
                Text(stringResource(R.string.add_ddns_record))
            }
            TextButton(
                enabled = enabled && directoryAvailable && directory?.records?.isNotEmpty() == true,
                onClick = onRefresh,
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Icon(Icons.Outlined.Refresh, null)
                Text(stringResource(R.string.update_address))
            }
            if (onReload != null) TextButton(onClick = onReload, enabled = reloadEnabled, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.refresh))
            }
        }
    }
}

@Composable
internal fun DdnsEmptyState(directoryAvailable: Boolean, canAdd: Boolean) {
    val title = if (directoryAvailable) R.string.ddns_empty_title else R.string.ddns_unavailable_title
    val message = if (directoryAvailable) {
        if (canAdd) R.string.ddns_empty_message else R.string.ddns_no_providers_message
    } else {
        R.string.ddns_unavailable_hint
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(stringResource(title), style = MaterialTheme.typography.titleSmall)
        Text(
            stringResource(message),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun DdnsRecordRow(
    record: NasDdnsRecord,
    enabled: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val editDescription = stringResource(
        R.string.edit_ddns_record_description,
        record.providerName,
        record.hostname,
    )
    val deleteDescription = stringResource(
        R.string.delete_ddns_record_description,
        record.providerName,
        record.hostname,
    )
    ListItem(
        headlineContent = { Text(record.hostname) },
        supportingContent = {
            Text(
                listOfNotNull(
                    record.providerName,
                    record.address?.takeIf(String::isNotBlank),
                    ddnsStatusText(record.status),
                ).joinToString(" · "),
            )
        },
        leadingContent = { Icon(Icons.Outlined.Dns, null) },
        trailingContent = {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(
                    onClick = onEdit,
                    enabled = enabled,
                    modifier = Modifier.heightIn(min = 48.dp).semantics {
                        contentDescription = editDescription
                        role = Role.Button
                    },
                ) {
                    Icon(Icons.Outlined.Edit, null)
                    Text(stringResource(R.string.edit))
                }
                TextButton(
                    onClick = onDelete,
                    enabled = enabled,
                    modifier = Modifier.heightIn(min = 48.dp).semantics {
                        contentDescription = deleteDescription
                        role = Role.Button
                    },
                ) {
                    Icon(Icons.Outlined.Delete, null)
                    Text(stringResource(R.string.delete))
                }
            }
        },
    )
    HorizontalDivider(Modifier.padding(start = 72.dp))
}

@Composable
private fun ddnsStatusText(status: String?): String = when (status?.trim()?.lowercase()) {
    "normal", "success", "ok", "updated" -> stringResource(R.string.ddns_status_working)
    "disabled", "inactive" -> stringResource(R.string.ddns_status_disabled)
    "error", "failed", "failure" -> stringResource(R.string.ddns_status_needs_attention)
    else -> stringResource(R.string.ddns_status_unavailable)
}

@Composable
internal fun DdnsEditorDialog(
    initial: NasDdnsDraft,
    draft: NasDdnsDraft,
    providers: List<NasDdnsProvider>,
    enabled: Boolean,
    onDraftChange: (NasDdnsDraft) -> Unit,
    onTest: () -> Boolean,
    onSave: () -> Boolean,
    onDismiss: () -> Unit,
) {
    var providerMenu by remember { mutableStateOf(false) }
    var passwordVisible by remember { mutableStateOf(false) }
    val validation = ddnsValidation(draft)
    val selectedProvider = providers.firstOrNull { it.id == draft.providerId }
    AlertDialog(
        onDismissRequest = { if (enabled) onDismiss() },
        title = {
            Text(
                stringResource(
                    if (initial.originalProviderId == null) R.string.add_ddns_record
                    else R.string.edit_ddns_record,
                ),
            )
        },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column {
                    Text(stringResource(R.string.ddns_provider), style = MaterialTheme.typography.labelLarge)
                    OutlinedButton(
                        enabled = enabled && initial.originalProviderId == null,
                        onClick = { providerMenu = true },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    ) {
                        Text(selectedProvider?.displayName ?: stringResource(R.string.ddns_provider_unavailable))
                    }
                    DropdownMenu(expanded = providerMenu, onDismissRequest = { providerMenu = false }) {
                        providers.forEach { provider ->
                            DropdownMenuItem(
                                text = { Text(provider.displayName) },
                                onClick = {
                                    onDraftChange(draft.copy(providerId = provider.id))
                                    providerMenu = false
                                },
                            )
                        }
                    }
                }
                OutlinedTextField(
                    value = draft.hostname,
                    onValueChange = { onDraftChange(draft.copy(hostname = it)) },
                    enabled = enabled,
                    label = { Text(stringResource(R.string.ddns_hostname)) },
                    isError = validation == DdnsValidation.HOSTNAME,
                    supportingText = if (validation == DdnsValidation.HOSTNAME) {
                        { Text(stringResource(R.string.invalid_ddns_hostname)) }
                    } else null,
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = draft.username,
                    onValueChange = { onDraftChange(draft.copy(username = it)) },
                    enabled = enabled,
                    label = { Text(stringResource(R.string.ddns_account)) },
                    isError = validation == DdnsValidation.USERNAME,
                    supportingText = if (validation == DdnsValidation.USERNAME) {
                        { Text(stringResource(R.string.ddns_account_required)) }
                    } else null,
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = draft.password,
                    onValueChange = { onDraftChange(draft.copy(password = it)) },
                    enabled = enabled,
                    label = { Text(stringResource(R.string.ddns_password_or_key)) },
                    supportingText = {
                        Text(
                            stringResource(
                                if (initial.originalProviderId == null) R.string.ddns_password_new_hint
                                else R.string.ddns_password_edit_hint,
                            ),
                        )
                    },
                    isError = validation == DdnsValidation.PASSWORD,
                    singleLine = true,
                    visualTransformation = if (passwordVisible) {
                        VisualTransformation.None
                    } else {
                        PasswordVisualTransformation()
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    trailingIcon = {
                        val description = stringResource(
                            if (passwordVisible) R.string.hide_ddns_password else R.string.show_ddns_password,
                        )
                        IconButton(
                            enabled = enabled,
                            onClick = { passwordVisible = !passwordVisible },
                            modifier = Modifier.semantics { contentDescription = description },
                        ) {
                            Icon(
                                if (passwordVisible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                                contentDescription = null,
                            )
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                DdnsSwitch(
                    label = stringResource(R.string.enable_ddns_record),
                    checked = draft.isEnabled,
                    enabled = enabled,
                    onCheckedChange = { onDraftChange(draft.copy(isEnabled = it)) },
                )
                DdnsSwitch(
                    label = stringResource(R.string.enable_ddns_heartbeat),
                    checked = draft.heartbeat,
                    enabled = enabled,
                    onCheckedChange = { onDraftChange(draft.copy(heartbeat = it)) },
                )
                Text(
                    stringResource(R.string.ddns_credential_privacy_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = enabled && validation == null &&
                    (draft.originalProviderId == null || draft != initial),
                onClick = { onSave() },
            ) { Text(stringResource(R.string.continue_action)) }
        },
        dismissButton = {
            Row {
                TextButton(enabled = enabled && validation == null, onClick = { onTest() }) {
                    Text(stringResource(R.string.test_connection))
                }
                TextButton(enabled = enabled, onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
            }
        },
    )
}

@Composable
private fun DdnsSwitch(
    label: String,
    checked: Boolean,
    enabled: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .toggleable(
                value = checked,
                enabled = enabled,
                role = Role.Switch,
                onValueChange = onCheckedChange,
            )
            .semantics(mergeDescendants = true) {
                role = Role.Switch
            },
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, modifier = Modifier.weight(1f).padding(end = 16.dp))
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

@Composable
internal fun DdnsConfirmationDialog(
    operation: DdnsMutationOperation,
    draft: NasDdnsDraft?,
    deleteTarget: NasDdnsRecord?,
    addressTargets: List<NasDdnsRecord>,
    providers: List<NasDdnsProvider>,
    onConfirm: () -> Boolean,
    onDismiss: () -> Unit,
) {
    val title = stringResource(ddnsConfirmationTitle(operation))
    val message = stringResource(ddnsConfirmationMessage(operation))
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(message)
                DdnsTargetSummary(
                    operation = operation,
                    draft = draft,
                    record = deleteTarget,
                    addressTargets = addressTargets,
                    providers = providers,
                )
                if (operation == DdnsMutationOperation.SAVE && draft?.password.isNullOrEmpty()) {
                    Text(
                        stringResource(R.string.ddns_password_not_reentered),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm() }) {
                Text(stringResource(ddnsConfirmationAction(operation)))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
internal fun DdnsMutationStatusContent(
    operation: DdnsMutationOperation?,
    draft: NasDdnsDraft?,
    deleteTarget: NasDdnsRecord?,
    addressTargetIds: Set<String>,
    addressTargets: List<NasDdnsRecord>,
    targetProviderId: String?,
    directory: NasDdnsDirectory?,
    mutationInProgress: Boolean,
    result: MutationResult?,
    failure: DsmFailure?,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    val actualOperation = operation ?: return
    val currentRecord = targetProviderId?.let { id -> directory?.records?.firstOrNull { it.providerId == id } }
    when {
        mutationInProgress -> DdnsSavingCard(actualOperation, draft, deleteTarget, addressTargets, directory)
        result != null -> DdnsMutationFeedbackCard(
            operation = actualOperation,
            draft = draft,
            deleteTarget = deleteTarget,
            addressTargets = addressTargets,
            addressTargetIds = addressTargetIds,
            currentAddressRecordIds = directory?.records?.map(NasDdnsRecord::providerId)?.toSet().orEmpty(),
            providers = directory?.providers.orEmpty(),
            currentRecord = currentRecord,
            result = result,
            refreshFailure = refreshFailure,
            refreshInProgress = refreshInProgress,
            refreshCompleted = refreshCompleted,
            onRefresh = onRefresh,
            onContinueEditing = onContinueEditing,
            onDismiss = onDismiss,
        )
        failure != null -> DdnsMutationFailureCard(
            operation = actualOperation,
            draft = draft,
            deleteTarget = deleteTarget,
            addressTargets = addressTargets,
            addressTargetIds = addressTargetIds,
            currentAddressRecordIds = directory?.records?.map(NasDdnsRecord::providerId)?.toSet().orEmpty(),
            providers = directory?.providers.orEmpty(),
            currentRecord = currentRecord,
            failure = failure,
            refreshFailure = refreshFailure,
            refreshInProgress = refreshInProgress,
            refreshCompleted = refreshCompleted,
            onRefresh = onRefresh,
            onContinueEditing = onContinueEditing,
            onDismiss = onDismiss,
        )
    }
}

internal data class DdnsFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val canRefresh: Boolean,
    val mustRefreshBeforeDismiss: Boolean,
    val isAssertive: Boolean,
)

internal fun ddnsFeedbackPolicy(
    operation: DdnsMutationOperation,
    result: MutationResult,
): DdnsFeedbackPolicy {
    require(result.operation == ddnsOperationKey(operation)) { "ddns.unexpected-operation" }
    val submittedOrConflict = result.submitted || result.requiresRefresh ||
        result.errorCategory == MutationErrorCategory.CONFLICT
    val mustRefresh = operation != DdnsMutationOperation.TEST && when (result.status) {
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> true
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CONFIRMED_FAILURE,
        -> submittedOrConflict
        MutationResultStatus.CONFIRMED_SUCCESS,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        -> false
    }
    val title = when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> ddnsSuccessTitle(operation)
        MutationResultStatus.PARTIAL_SUCCESS -> R.string.ddns_feedback_partial_title
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> R.string.ddns_feedback_check_title
        MutationResultStatus.PERMISSION_DENIED -> R.string.ddns_feedback_permission_title
        MutationResultStatus.UNSUPPORTED -> R.string.ddns_feedback_unavailable_title
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.ddns_feedback_cancelled_title
        MutationResultStatus.CONFIRMED_FAILURE -> if (
            result.errorCategory == MutationErrorCategory.CONFLICT
        ) R.string.ddns_feedback_conflict_title else R.string.ddns_feedback_failed_title
    }
    val message = when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> ddnsSuccessMessage(operation)
        MutationResultStatus.PARTIAL_SUCCESS -> R.string.service_action_partial
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> if (operation in setOf(DdnsMutationOperation.TEST, DdnsMutationOperation.ADDRESS_REFRESH)) R.string.ddns_transient_unknown_hint else R.string.service_action_unverified
        MutationResultStatus.PERMISSION_DENIED -> R.string.service_action_permission_denied
        MutationResultStatus.UNSUPPORTED -> R.string.service_action_unsupported
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.service_action_cancelled
        MutationResultStatus.CONFIRMED_FAILURE -> if (
            result.errorCategory == MutationErrorCategory.CONFLICT
        ) R.string.service_action_conflict else R.string.service_action_failed
    }
    return DdnsFeedbackPolicy(
        title = title,
        message = message,
        canRefresh = operation != DdnsMutationOperation.TEST && mustRefresh,
        mustRefreshBeforeDismiss = mustRefresh,
        isAssertive = result.status != MutationResultStatus.CONFIRMED_SUCCESS,
    )
}

@Composable
private fun DdnsSavingCard(
    operation: DdnsMutationOperation,
    draft: NasDdnsDraft?,
    deleteTarget: NasDdnsRecord?,
    addressTargets: List<NasDdnsRecord>,
    directory: NasDdnsDirectory?,
) {
    DdnsFeedbackCard(LiveRegionMode.Polite, false) {
        Text(stringResource(ddnsSavingTitle(operation)), style = MaterialTheme.typography.titleMedium)
        DdnsTargetSummary(operation, draft, deleteTarget, addressTargets, directory?.providers.orEmpty())
        Text(stringResource(ddnsSavingMessage(operation)))
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
internal fun DdnsMutationFeedbackCard(
    operation: DdnsMutationOperation,
    draft: NasDdnsDraft?,
    deleteTarget: NasDdnsRecord?,
    addressTargets: List<NasDdnsRecord>,
    addressTargetIds: Set<String> = emptySet(),
    currentAddressRecordIds: Set<String> = emptySet(),
    providers: List<NasDdnsProvider>,
    currentRecord: NasDdnsRecord?,
    result: MutationResult,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
    canContinueEditing: Boolean? = null,
    canDismiss: Boolean? = null,
) {
    val policy = ddnsFeedbackPolicy(operation, result)
    val canLeave = canDismiss ?: (!policy.mustRefreshBeforeDismiss || refreshCompleted)
    val canContinue = canContinueEditing ?: (operation == DdnsMutationOperation.TEST ||
        operation == DdnsMutationOperation.SAVE && (!refreshCompleted || currentRecord != null))
    DdnsFeedbackCard(
        liveRegionMode = if (policy.isAssertive) LiveRegionMode.Assertive else LiveRegionMode.Polite,
        isError = result.status in setOf(
            MutationResultStatus.PERMISSION_DENIED,
            MutationResultStatus.CONFIRMED_FAILURE,
        ),
    ) {
        Text(stringResource(policy.title), style = MaterialTheme.typography.titleMedium)
        DdnsTargetSummary(operation, draft, deleteTarget, addressTargets, providers)
        Text(stringResource(policy.message))
        val counts = result.counts
        if (counts.succeeded + counts.failed + counts.unknown > 0) {
            Text(
                stringResource(R.string.ddns_feedback_counts, counts.succeeded, counts.failed, counts.unknown),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        DdnsRefreshState(
            operation, refreshCompleted, currentRecord, draft, addressTargetIds,
            currentAddressRecordIds = currentAddressRecordIds,
            refreshFailure = refreshFailure, refreshInProgress = refreshInProgress,
        )
        if (policy.canRefresh || refreshFailure != null) {
            TextButton(onClick = onRefresh, enabled = !refreshInProgress, modifier = Modifier.align(Alignment.End)) {
                Text(stringResource(R.string.refresh_and_check_ddns))
            }
        }
        if (canContinue) {
            TextButton(
                onClick = onContinueEditing,
                enabled = !refreshInProgress && canLeave,
                modifier = Modifier.align(Alignment.End),
            ) { Text(stringResource(R.string.continue_editing)) }
        }
        if (canDismiss != false) TextButton(
            onClick = onDismiss,
            enabled = !refreshInProgress && canLeave,
            modifier = Modifier.align(Alignment.End),
        ) {
            Text(
                stringResource(
                    if (result.status == MutationResultStatus.CONFIRMED_SUCCESS) R.string.done
                    else R.string.close,
                ),
            )
        }
    }
}

@Composable
internal fun DdnsMutationFailureCard(
    operation: DdnsMutationOperation,
    draft: NasDdnsDraft?,
    deleteTarget: NasDdnsRecord?,
    addressTargets: List<NasDdnsRecord>,
    addressTargetIds: Set<String> = emptySet(),
    currentAddressRecordIds: Set<String> = emptySet(),
    providers: List<NasDdnsProvider>,
    currentRecord: NasDdnsRecord?,
    failure: DsmFailure,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    val canContinue = operation == DdnsMutationOperation.TEST ||
        operation == DdnsMutationOperation.SAVE && (!refreshCompleted || currentRecord != null)
    DdnsFeedbackCard(LiveRegionMode.Assertive, true) {
        Text(stringResource(R.string.ddns_feedback_failed_title), style = MaterialTheme.typography.titleMedium)
        DdnsTargetSummary(operation, draft, deleteTarget, addressTargets, providers)
        Text(failure.localize(LocalContext.current).combined)
        DdnsRefreshState(
            operation, refreshCompleted, currentRecord, draft, addressTargetIds,
            currentAddressRecordIds = currentAddressRecordIds,
            refreshFailure = refreshFailure, refreshInProgress = refreshInProgress,
        )
        if (operation != DdnsMutationOperation.TEST) {
            TextButton(onClick = onRefresh, enabled = !refreshInProgress, modifier = Modifier.align(Alignment.End)) {
                Text(stringResource(R.string.refresh_and_check_ddns))
            }
        }
        if (canContinue) {
            TextButton(
                onClick = onContinueEditing,
                enabled = operation == DdnsMutationOperation.TEST || refreshCompleted && !refreshInProgress,
                modifier = Modifier.align(Alignment.End),
            ) { Text(stringResource(R.string.continue_editing)) }
        }
        TextButton(
            onClick = onDismiss,
            enabled = operation == DdnsMutationOperation.TEST || refreshCompleted && !refreshInProgress,
            modifier = Modifier.align(Alignment.End),
        ) { Text(stringResource(R.string.discard_changes)) }
    }
}

@Composable
private fun ColumnScope.DdnsRefreshState(
    operation: DdnsMutationOperation,
    refreshCompleted: Boolean,
    currentRecord: NasDdnsRecord?,
    draft: NasDdnsDraft?,
    addressTargetIds: Set<String>,
    currentAddressRecordIds: Set<String>,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
) {
    if (refreshCompleted && operation != DdnsMutationOperation.TEST) {
        Text(
            stringResource(
                when (operation) {
                    DdnsMutationOperation.SAVE -> when {
                        currentRecord == null -> R.string.ddns_refresh_target_missing
                        draft != null && ddnsRecordMatchesDraft(currentRecord, draft) -> R.string.ddns_refresh_matches
                        else -> R.string.ddns_refresh_differs
                    }
                    DdnsMutationOperation.DELETE -> if (currentRecord == null) {
                        R.string.ddns_refresh_delete_matches
                    } else {
                        R.string.ddns_refresh_delete_differs
                    }
                    DdnsMutationOperation.ADDRESS_REFRESH -> {
                        when {
                            addressTargetIds.isNotEmpty() &&
                                currentAddressRecordIds.containsAll(addressTargetIds) ->
                                R.string.ddns_refresh_address_checked
                            addressTargetIds.intersect(currentAddressRecordIds).isEmpty() ->
                                R.string.ddns_refresh_address_targets_missing
                            else -> R.string.ddns_refresh_address_targets_changed
                        }
                    }
                    DdnsMutationOperation.TEST -> R.string.ddns_test_succeeded
                },
            ),
            style = MaterialTheme.typography.bodySmall,
        )
    }
    refreshFailure?.let { Text(it.localize(LocalContext.current).combined) }
    if (refreshInProgress) {
        Text(stringResource(R.string.refreshing_ddns), style = MaterialTheme.typography.bodySmall)
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

internal fun ddnsRecordMatchesDraft(record: NasDdnsRecord, draft: NasDdnsDraft): Boolean =
    record.providerId == draft.providerId && record.hostname.trim() == draft.hostname.trim() &&
        record.username.trim() == draft.username.trim() && record.isEnabled == draft.isEnabled &&
        record.heartbeat == draft.heartbeat

@Composable
private fun DdnsFeedbackCard(
    liveRegionMode: LiveRegionMode,
    isError: Boolean,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).semantics {
            liveRegion = liveRegionMode
        },
        colors = if (isError) {
            CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer,
            )
        } else {
            CardDefaults.cardColors()
        },
    ) {
        Column(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            content = content,
        )
    }
}

@Composable
private fun DdnsTargetSummary(
    operation: DdnsMutationOperation,
    draft: NasDdnsDraft?,
    record: NasDdnsRecord?,
    addressTargets: List<NasDdnsRecord>,
    providers: List<NasDdnsProvider>,
) {
    when (operation) {
        DdnsMutationOperation.TEST,
        DdnsMutationOperation.SAVE,
        -> {
            val providerName = providers.firstOrNull { it.id == draft?.providerId }?.displayName
                ?: record?.providerName
                ?: stringResource(R.string.ddns_provider_unavailable)
            Text(
                stringResource(
                    R.string.ddns_target_summary,
                    providerName,
                    draft?.hostname.orEmpty(),
                ),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        DdnsMutationOperation.DELETE -> Text(
            stringResource(
                R.string.ddns_target_summary,
                record?.providerName ?: stringResource(R.string.ddns_provider_unavailable),
                record?.hostname.orEmpty(),
            ),
            style = MaterialTheme.typography.bodySmall,
        )
        DdnsMutationOperation.ADDRESS_REFRESH -> {
            if (addressTargets.isEmpty()) {
                Text(stringResource(R.string.ddns_address_targets_unavailable), style = MaterialTheme.typography.bodySmall)
            } else {
                addressTargets.forEach { target ->
                    Text(
                        stringResource(R.string.ddns_target_summary, target.providerName, target.hostname),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
}

@StringRes
private fun ddnsConfirmationTitle(operation: DdnsMutationOperation) = when (operation) {
    DdnsMutationOperation.TEST -> R.string.test_ddns_record_title
    DdnsMutationOperation.SAVE -> R.string.save_ddns_record_confirm_title
    DdnsMutationOperation.DELETE -> R.string.delete_ddns_record_confirm_title
    DdnsMutationOperation.ADDRESS_REFRESH -> R.string.update_ddns_address_title
}

@StringRes
private fun ddnsConfirmationMessage(operation: DdnsMutationOperation) = when (operation) {
    DdnsMutationOperation.TEST -> R.string.test_ddns_record_message
    DdnsMutationOperation.SAVE -> R.string.save_ddns_record_message
    DdnsMutationOperation.DELETE -> R.string.delete_ddns_record_confirm_message
    DdnsMutationOperation.ADDRESS_REFRESH -> R.string.update_ddns_address_message
}

@StringRes
private fun ddnsConfirmationAction(operation: DdnsMutationOperation) = when (operation) {
    DdnsMutationOperation.TEST -> R.string.test_connection
    DdnsMutationOperation.SAVE -> R.string.save
    DdnsMutationOperation.DELETE -> R.string.delete
    DdnsMutationOperation.ADDRESS_REFRESH -> R.string.update_now
}

@StringRes
private fun ddnsSavingTitle(operation: DdnsMutationOperation) = when (operation) {
    DdnsMutationOperation.TEST -> R.string.ddns_testing_title
    DdnsMutationOperation.SAVE -> R.string.ddns_saving_title
    DdnsMutationOperation.DELETE -> R.string.ddns_deleting_title
    DdnsMutationOperation.ADDRESS_REFRESH -> R.string.ddns_updating_title
}

@StringRes
private fun ddnsSavingMessage(operation: DdnsMutationOperation) = when (operation) {
    DdnsMutationOperation.TEST -> R.string.ddns_testing_message
    DdnsMutationOperation.SAVE -> R.string.ddns_saving_message
    DdnsMutationOperation.DELETE -> R.string.ddns_deleting_message
    DdnsMutationOperation.ADDRESS_REFRESH -> R.string.ddns_updating_message
}

@StringRes
private fun ddnsSuccessTitle(operation: DdnsMutationOperation) = when (operation) {
    DdnsMutationOperation.TEST -> R.string.ddns_test_succeeded_title
    DdnsMutationOperation.SAVE -> R.string.ddns_record_saved_title
    DdnsMutationOperation.DELETE -> R.string.ddns_record_deleted_title
    DdnsMutationOperation.ADDRESS_REFRESH -> R.string.ddns_address_update_requested_title
}

@StringRes
private fun ddnsSuccessMessage(operation: DdnsMutationOperation) = when (operation) {
    DdnsMutationOperation.TEST -> R.string.ddns_test_succeeded
    DdnsMutationOperation.SAVE -> R.string.ddns_record_saved
    DdnsMutationOperation.DELETE -> R.string.ddns_record_deleted
    DdnsMutationOperation.ADDRESS_REFRESH -> R.string.ddns_address_update_requested
}

internal fun ddnsOperationKey(operation: DdnsMutationOperation): String = when (operation) {
    DdnsMutationOperation.TEST -> "ddnsProviderTest"
    DdnsMutationOperation.SAVE -> "ddnsRecordSave"
    DdnsMutationOperation.DELETE -> "ddnsRecordDelete"
    DdnsMutationOperation.ADDRESS_REFRESH -> "ddnsAddressRefresh"
}

private enum class DdnsValidation { HOSTNAME, USERNAME, PASSWORD }

private fun ddnsValidation(value: NasDdnsDraft): DdnsValidation? = when {
    !isValidDdnsHostname(value.hostname.trim()) -> DdnsValidation.HOSTNAME
    value.username.isBlank() -> DdnsValidation.USERNAME
    value.originalProviderId == null && value.providerId != "Synology" && value.password.isEmpty() ->
        DdnsValidation.PASSWORD
    else -> null
}

private fun isValidDdnsHostname(value: String): Boolean {
    if (value.isBlank() || value.length > 253 || value.startsWith('.') || value.endsWith('.') ||
        ".." in value || value.any { it.isWhitespace() || !(it.isLetterOrDigit() || it == '.' || it == '-') }
    ) return false
    return value.split('.').all { it.isNotEmpty() && it.length <= 63 && !it.startsWith('-') && !it.endsWith('-') }
}
