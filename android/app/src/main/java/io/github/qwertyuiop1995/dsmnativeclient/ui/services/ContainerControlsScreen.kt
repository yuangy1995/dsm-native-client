package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.containers.*
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.displayName

@Composable internal fun ContainerControlsScreen(model: ContainerControlModel) {
    val state by model.state.collectAsStateWithLifecycle()
    LaunchedEffect(model) { model.refresh() }
    ContainerControlsContent(state, model::refresh, model::request, model::confirm, model::cancel, model::dismiss)
}

@Composable internal fun ContainerControlsContent(state: ContainerControlState, onRefresh: () -> Unit,
    onRequest: (List<ContainerControlTarget>, ContainerAction) -> Boolean, onConfirm: (ContainerControlConfirmation) -> Boolean,
    onCancel: () -> Unit, onDismiss: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    var selection by remember { mutableStateOf(setOf<String>()) }
    var details by remember { mutableStateOf<ContainerControlTarget?>(null) }
    LaunchedEffect(state.targets, state.busy) {
        selection = selection.intersect(state.targets.map { it.id }.toSet())
        if (state.busy) { selection = emptySet(); details = null }
    }
    val filtered = state.targets.filter { it.name.contains(query, ignoreCase = true) }
    val selected = state.targets.filter { it.id in selection }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            ClientSearchField(query, { query = it }, stringResource(R.string.cm_search), modifier = Modifier.weight(1f))
            IconButton(onClick = onRefresh, enabled = !state.busy) { Icon(Icons.Outlined.Refresh, stringResource(R.string.refresh)) }
        }
        if (selection.isNotEmpty()) ContainerActionButtons(selected, state.blocked, onRequest)
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            state.record?.let { record -> item {
                ContainerActivityCard(record, state.targets, state.busy, onRefresh, onDismiss)
            } }
            state.failure?.let { error -> item {
                ClientGroup { Column(Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }) {
                    Text(containerErrorText(error), color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = onRefresh, enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
                } }
            } }
            if (state.busy) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (state.loaded && filtered.isEmpty()) item {
                Text(stringResource(if (state.targets.isEmpty()) R.string.cm_empty else R.string.cm_no_matches), Modifier.padding(vertical = 24.dp))
            }
            items(filtered, key = { it.id }) { target ->
                ClientGroup {
                    ListItem(headlineContent = { Text(target.name) }, supportingContent = { Text(target.resource.state.displayName()) },
                        leadingContent = { Checkbox(checked = target.id in selection, enabled = !state.blocked, onCheckedChange = {
                            selection = if (it) selection + target.id else selection - target.id
                        }, modifier = Modifier.semantics { contentDescription = target.name }) },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { details = target })
                }
            }
        }
    }
    details?.let { original ->
        val target = state.targets.singleOrNull { it.id == original.id && it.name == original.name }
        ClientSheet(original.name, onDismiss = { details = null }) {
            if (target == null) Text(stringResource(R.string.cm_changed)) else {
                Text(target.resource.state.displayName())
                if (target.managed == true) Text(stringResource(R.string.cm_managed))
                else if (ContainerAction.entries.none(target::supports)) Text(stringResource(R.string.cm_actions_unavailable))
                ContainerActionButtons(listOf(target), state.blocked) { rows, action ->
                    onRequest(rows, action).also { if (it) details = null }
                }
            }
        }
    }
    state.confirmation?.let { confirmation ->
        ClientSheet(stringResource(containerActionTitle(confirmation.action)), onDismiss = onCancel, dismissEnabled = !state.busy) {
            confirmation.targets.forEach { Text(it.name) }
            Text(stringResource(when (confirmation.action) {
                ContainerAction.START -> R.string.cm_start_risk
                ContainerAction.STOP -> R.string.cm_stop_risk
                ContainerAction.RESTART -> R.string.cm_restart_risk
                ContainerAction.DELETE -> R.string.cm_delete_risk
            }))
            Button(onClick = { onConfirm(confirmation) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(containerActionTitle(confirmation.action)))
            }
            TextButton(onClick = onCancel, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
        }
    }
}

@Composable private fun ContainerActionButtons(targets: List<ContainerControlTarget>, blocked: Boolean,
    onRequest: (List<ContainerControlTarget>, ContainerAction) -> Boolean) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ContainerAction.entries.forEach { action ->
            OutlinedButton(onClick = { onRequest(targets, action) }, enabled = !blocked && targets.isNotEmpty() && targets.all { it.supports(action) }) {
                Text(stringResource(containerActionTitle(action)))
            }
        }
    }
}

@Composable private fun ContainerActivityCard(record: ContainerControlActivity, targets: List<ContainerControlTarget>, busy: Boolean,
    onRefresh: () -> Unit, onDismiss: () -> Unit) {
    ClientGroup {
        Column(Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(containerActionTitle(record.action)), style = MaterialTheme.typography.titleSmall)
            record.items.forEachIndexed { index, item ->
                val name = targets.singleOrNull { containerIdentity(it) == item.identity }?.name ?: stringResource(R.string.cm_item_number, index + 1)
                Text(stringResource(R.string.cm_item_status, name, stringResource(when (item.stage) {
                    ContainerStage.PREPARED, ContainerStage.CANCELLED -> R.string.cm_not_sent
                    ContainerStage.SUBMITTED -> R.string.cm_result_unavailable
                    ContainerStage.ACCEPTED -> R.string.cm_processing
                    ContainerStage.REJECTED -> R.string.cm_rejected
                    ContainerStage.VERIFIED -> when (record.action) {
                        ContainerAction.START -> R.string.cm_running
                        ContainerAction.STOP -> R.string.cm_stopped
                        ContainerAction.RESTART -> R.string.cm_restarted
                        ContainerAction.DELETE -> R.string.cm_removed
                    }
                })))
            }
            if (record.pending) Text(stringResource(R.string.cm_pending_hint))
            TextButton(onClick = if (record.pending) onRefresh else onDismiss, enabled = !busy) {
                Text(stringResource(if (record.pending) R.string.refresh else R.string.close))
            }
        }
    }
}

internal fun containerActionTitle(action: ContainerAction) = when (action) {
    ContainerAction.START -> R.string.cm_start
    ContainerAction.STOP -> R.string.cm_stop
    ContainerAction.RESTART -> R.string.cm_restart
    ContainerAction.DELETE -> R.string.cm_delete
}
@Composable internal fun containerErrorText(error: Exception): String = when (error) {
    is ContainerFailure -> stringResource(when (error.problem) {
        ContainerProblem.CHANGED -> R.string.cm_changed
        ContainerProblem.STORAGE -> R.string.cm_storage
    })
    is DsmFailure -> error.localize(LocalContext.current).combined
    else -> stringResource(R.string.cm_read_failed)
}
