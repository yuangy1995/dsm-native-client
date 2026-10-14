package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.containers.*
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable internal fun ContainerNetworksScreen(model: ContainerNetworkModel) {
    val state by model.state.collectAsStateWithLifecycle()
    LaunchedEffect(model) { model.refresh() }
    ContainerNetworksContent(state, model::refresh, model::openCreate, model::requestDelete, model::dismiss)
    if (state.draft != null && state.confirmation == null) ContainerNetworkEditor(state.draft!!, state.busy, model::edit, model::closeEditor, model::requestCreate, state.failure)
    ContainerNetworkConfirmationSheet(state.confirmation, state.busy, model::cancel, model::confirm)
}
@Composable internal fun ContainerNetworksContent(state: ContainerNetworkState, onRefresh: () -> Unit, onCreate: () -> Boolean,
    onDelete: (List<ContainerNetworkEntry>) -> Boolean, onDismiss: (String) -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }; var selection by remember { mutableStateOf(setOf<String>()) }
    var details by remember { mutableStateOf<ContainerNetworkEntry?>(null) }
    LaunchedEffect(state.networks, state.busy) {
        selection = selection.intersect(state.networks.map { it.id }.toSet())
        if (state.busy) { selection = emptySet(); details = null }
    }
    val filtered = state.networks.filter { it.name.contains(query, ignoreCase = true) }
    val selected = state.networks.filter { it.id in selection }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            ClientSearchField(query, { query = it }, stringResource(R.string.cm_network_search), modifier = Modifier.weight(1f))
            IconButton(onClick = onRefresh, enabled = !state.busy) { Icon(Icons.Outlined.Refresh, stringResource(R.string.refresh)) }
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { onCreate() }, enabled = state.loaded && !state.busy) { Text(stringResource(R.string.cm_network_create)) }
            if (selected.isNotEmpty()) OutlinedButton(onClick = { onDelete(selected) }, enabled = !state.busy && selected.all { it.canDelete }) { Text(stringResource(R.string.cm_network_delete)) }
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            state.failure?.let { error -> item { Text(containerErrorText(error), color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) } }
            if (state.busy) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            items(state.activities, key = { "activity:${it.id}" }) { activity ->
                ContainerNetworkActivityCard(activity, state.networks, state.busy, onRefresh) { onDismiss(activity.id) }
            }
            if (state.loaded && filtered.isEmpty()) item { Text(stringResource(if (state.networks.isEmpty()) R.string.cm_network_empty else R.string.cm_network_no_matches), Modifier.padding(vertical = 24.dp)) }
            items(filtered, key = { it.id }) { entry ->
                ClientGroup { ListItem(headlineContent = { Text(entry.name) }, supportingContent = {
                    Column { Text(entry.driver); Text(pluralStringResource(R.plurals.cm_network_container_count, entry.containerCount, entry.containerCount)) }
                }, leadingContent = { Checkbox(checked = entry.id in selection, enabled = !state.busy && entry.canDelete,
                    onCheckedChange = { selection = if (it) selection + entry.id else selection - entry.id }, modifier = Modifier.semantics { contentDescription = entry.name }) },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { details = entry }) }
            }
        }
    }
    details?.let { original ->
        val entry = state.networks.singleOrNull { it.id == original.id && it.name == original.name }
        ClientSheet(original.name, onDismiss = { details = null }) {
            if (entry == null) Text(stringResource(R.string.cm_network_changed)) else {
                ContainerNetworkDetails(entry)
                if (!entry.canDelete) Text(stringResource(if (entry.containerCount > 0) R.string.cm_network_in_use else R.string.cm_network_protected))
                Button(onClick = { if (onDelete(listOf(entry))) details = null }, enabled = !state.busy && entry.canDelete) { Text(stringResource(R.string.cm_network_delete)) }
            }
        }
    }
}
@Composable private fun ContainerNetworkDetails(entry: ContainerNetworkEntry) {
    Text(stringResource(R.string.cm_network_driver, entry.driver))
    listOf(R.string.cm_network_subnet to entry.subnet, R.string.cm_network_range to entry.range, R.string.cm_network_gateway to entry.gateway).forEach { (label, value) ->
        if (!value.isNullOrEmpty()) { ClientSectionTitle(stringResource(label)); Text(value) }
    }
    Text(stringResource(when (entry.ipv6) { true -> R.string.cm_network_ipv6_on; false -> R.string.cm_network_ipv6_off; null -> R.string.cm_network_ipv6_unknown }))
    Text(pluralStringResource(R.plurals.cm_network_container_count, entry.containerCount, entry.containerCount))
    entry.containers?.forEach { Text(it) }
}
@Composable private fun ContainerNetworkActivityCard(activity: ContainerNetworkActivity, networks: List<ContainerNetworkEntry>, busy: Boolean,
    onRefresh: () -> Unit, onDismiss: () -> Unit) {
    ClientGroup { Column(Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(if (activity.operation == ContainerNetworkOperation.CREATE) R.string.cm_network_create else R.string.cm_network_delete), style = MaterialTheme.typography.titleSmall)
        activity.items.forEachIndexed { index, item ->
            val name = networks.singleOrNull { containerDigest(it.name) == item.target.name }?.name ?: stringResource(R.string.cm_network_number, index + 1)
            Text(stringResource(R.string.cm_item_status, name, stringResource(when (item.stage) {
                ContainerStage.PREPARED, ContainerStage.CANCELLED -> R.string.cm_not_sent
                ContainerStage.SUBMITTED -> R.string.cm_result_unavailable
                ContainerStage.ACCEPTED -> R.string.cm_processing
                ContainerStage.REJECTED -> R.string.cm_rejected
                ContainerStage.VERIFIED -> if (activity.operation == ContainerNetworkOperation.DELETE) R.string.cm_network_removed
                    else if (item.accepted) R.string.cm_network_created else R.string.cm_network_existing
            })))
        }
        if (activity.pending) Text(stringResource(R.string.cm_network_pending))
        TextButton(onClick = if (activity.pending) onRefresh else onDismiss, enabled = !busy) { Text(stringResource(if (activity.pending) R.string.refresh else R.string.close)) }
    } }
}
@Composable internal fun ContainerNetworkEditor(draft: ContainerNetworkDraft, busy: Boolean, onChange: (ContainerNetworkDraft) -> Unit,
    onClose: () -> Unit, onContinue: () -> Boolean, failure: Exception? = null) {
    ClientSheet(stringResource(R.string.cm_network_create), onDismiss = onClose, dismissEnabled = !busy) {
        fun field(value: String, label: Int, change: (String) -> ContainerNetworkDraft): @Composable () -> Unit = {
            OutlinedTextField(value, { onChange(change(it)) }, label = { Text(stringResource(label)) }, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth())
        }
        field(draft.name, R.string.cm_network_name) { draft.copy(name = it) }()
        NetworkSwitch(R.string.cm_network_manual_ipv4, draft.manualIpv4, !busy) { onChange(draft.copy(manualIpv4 = it)) }
        if (draft.manualIpv4) {
            field(draft.subnet, R.string.cm_network_subnet) { draft.copy(subnet = it) }()
            field(draft.range, R.string.cm_network_range) { draft.copy(range = it) }()
            field(draft.gateway, R.string.cm_network_gateway) { draft.copy(gateway = it) }()
        }
        NetworkSwitch(R.string.cm_network_ipv6, draft.ipv6, !busy) { onChange(draft.copy(ipv6 = it)) }
        if (draft.ipv6) {
            field(draft.ipv6Subnet, R.string.cm_network_ipv6_subnet) { draft.copy(ipv6Subnet = it) }()
            field(draft.ipv6Range, R.string.cm_network_ipv6_range) { draft.copy(ipv6Range = it) }()
            field(draft.ipv6Gateway, R.string.cm_network_ipv6_gateway) { draft.copy(ipv6Gateway = it) }()
        }
        NetworkSwitch(R.string.cm_network_disable_masquerade, draft.disableMasquerade, !busy) { onChange(draft.copy(disableMasquerade = it)) }
        draft.issue?.let { issue -> val message = stringResource(when (issue) {
            ContainerNetworkIssue.NAME -> R.string.cm_network_name_error
            ContainerNetworkIssue.IPV4 -> R.string.cm_network_ipv4_error
            ContainerNetworkIssue.IPV6 -> R.string.cm_network_ipv6_error
            ContainerNetworkIssue.OUTSIDE_SUBNET -> R.string.cm_network_subnet_error
        })
            Text(message, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { error(message); liveRegion = LiveRegionMode.Polite })
        }
        failure?.let { Text(containerErrorText(it), color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        Button(onClick = { onContinue() }, enabled = !busy && draft.issue == null, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.continue_action)) }
    }
}
@Composable private fun NetworkSwitch(label: Int, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = onChange), verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(label), modifier = Modifier.weight(1f))
        Switch(checked, onCheckedChange = null, enabled = enabled)
    }
}
@Composable internal fun ContainerNetworkConfirmationSheet(confirmation: ContainerNetworkConfirmation?, busy: Boolean,
    onCancel: () -> Unit, onConfirm: (ContainerNetworkConfirmation) -> Boolean) {
    confirmation ?: return
    val title = if (confirmation is ContainerNetworkConfirmation.Create) R.string.cm_network_create else R.string.cm_network_delete
    ClientSheet(stringResource(title), onDismiss = onCancel, dismissEnabled = !busy) {
        when (confirmation) {
            is ContainerNetworkConfirmation.Create -> {
                val draft = confirmation.draft; Text(draft.name)
                if (draft.manualIpv4) { Text(draft.subnet); if (draft.range.isNotEmpty()) Text(draft.range); Text(draft.gateway) }
                if (draft.ipv6) { Text(draft.ipv6Subnet); if (draft.ipv6Range.isNotEmpty()) Text(draft.ipv6Range); Text(draft.ipv6Gateway) }
                Text(stringResource(R.string.cm_network_create_risk))
                if (draft.disableMasquerade) Text(stringResource(R.string.cm_network_masquerade_risk))
            }
            is ContainerNetworkConfirmation.Delete -> { confirmation.targets.forEach { Text(it.name) }; Text(stringResource(R.string.cm_network_delete_risk)) }
        }
        Button(onClick = { onConfirm(confirmation) }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(title)) }
        TextButton(onClick = onCancel, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
    }
}
