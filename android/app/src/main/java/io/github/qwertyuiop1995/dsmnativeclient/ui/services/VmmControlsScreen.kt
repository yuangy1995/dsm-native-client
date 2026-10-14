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
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.displayName

@Composable internal fun VmmControlsScreen(model: VmmControlModel, blocked: Boolean = false, protectedIds: Set<String> = emptySet(),
    header: @Composable () -> Unit = {}, details: @Composable (VmmControlTarget, () -> Unit) -> Unit = { _, _ -> }) {
    val state by model.state.collectAsStateWithLifecycle()
    LaunchedEffect(model) { model.refresh() }
    VmmControlsContent(state, model::refresh, model::request, model::confirm, model::cancel, model::dismiss, blocked, protectedIds, header, details)
}

@Composable internal fun VmmControlsContent(state: VmmControlState, onRefresh: () -> Unit,
    onRequest: (List<VmmControlTarget>, VmmAction) -> Boolean, onConfirm: (VmmControlConfirmation) -> Boolean,
    onCancel: () -> Unit, onDismiss: () -> Unit, blocked: Boolean = false, protectedIds: Set<String> = emptySet(),
    header: @Composable () -> Unit = {}, detailsContent: @Composable (VmmControlTarget, () -> Unit) -> Unit = { _, _ -> }) {
    var query by rememberSaveable { mutableStateOf("") }
    var selection by remember { mutableStateOf(setOf<String>()) }
    var details by remember { mutableStateOf<VmmControlTarget?>(null) }
    LaunchedEffect(state.targets, state.busy) {
        selection = selection.intersect(state.targets.map { it.id }.toSet())
        if (state.busy) { selection = emptySet(); details = null }
    }
    val filtered = state.targets.filter { it.name.contains(query, ignoreCase = true) }
    val selected = state.targets.filter { it.id in selection }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            ClientSearchField(query, { query = it }, stringResource(R.string.vm_search), modifier = Modifier.weight(1f))
            IconButton(onClick = onRefresh, enabled = !state.busy) { Icon(Icons.Outlined.Refresh, stringResource(R.string.refresh)) }
        }
        if (selection.isNotEmpty()) VmmActionButtons(selected, (state.blocked || blocked) || selected.any { vmmDigest(it.id) in (state.protectedIds + protectedIds) }, onRequest)
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item { header() }
            state.records.forEach { record -> item {
                VmmActivityCard(record, state.targets, state.busy, onRefresh, onDismiss)
            } }
            state.failure?.let { error -> item {
                ClientGroup { Column(Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }) {
                    Text(vmmErrorText(error), color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = onRefresh, enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
                } }
            } }
            if (state.busy) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (state.loaded && filtered.isEmpty()) item {
                Text(stringResource(if (state.targets.isEmpty()) R.string.vm_empty else R.string.vm_no_matches), Modifier.padding(vertical = 24.dp))
            }
            items(filtered, key = { it.id }) { target ->
                ClientGroup {
                    ListItem(headlineContent = { Text(target.name) }, supportingContent = { Text(target.state.displayName()) },
                        leadingContent = { Checkbox(checked = target.id in selection, enabled = !(state.blocked || blocked) && vmmDigest(target.id) !in (state.protectedIds + protectedIds), onCheckedChange = {
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
            if (target == null) Text(stringResource(R.string.vm_changed)) else {
                Text(target.state.displayName())
                detailsContent(target) { details = null }
                if (VmmAction.entries.none(target::supports)) Text(stringResource(R.string.vm_actions_unavailable))
                VmmActionButtons(listOf(target), (state.blocked || blocked) || vmmDigest(target.id) in (state.protectedIds + protectedIds)) { rows, action ->
                    onRequest(rows, action).also { if (it) details = null }
                }
            }
        }
    }
    state.confirmation?.let { confirmation ->
        ClientSheet(stringResource(vmmActionTitle(confirmation.action)), onDismiss = onCancel, dismissEnabled = !state.busy) {
            confirmation.targets.forEach { Text(it.name) }
            Text(stringResource(when (confirmation.action) {
                VmmAction.START -> R.string.vm_start_risk
                VmmAction.SHUTDOWN -> R.string.vm_stop_risk
                VmmAction.POWER_OFF -> R.string.vm_poweroff_risk
                VmmAction.RESTART -> R.string.vm_restart_risk
                VmmAction.DELETE -> R.string.vm_delete_risk
            }))
            Button(onClick = { onConfirm(confirmation) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text(stringResource(vmmActionTitle(confirmation.action)))
            }
            TextButton(onClick = onCancel, enabled = !state.busy, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) }
        }
    }
}

@Composable private fun VmmActionButtons(targets: List<VmmControlTarget>, blocked: Boolean,
    onRequest: (List<VmmControlTarget>, VmmAction) -> Boolean) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        VmmAction.entries.forEach { action ->
            OutlinedButton(onClick = { onRequest(targets, action) }, enabled = !blocked && targets.isNotEmpty() && targets.all { it.supports(action) }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(vmmActionTitle(action)))
            }
        }
    }
}

@Composable private fun VmmActivityCard(record: VmmControlActivity, targets: List<VmmControlTarget>, busy: Boolean,
    onRefresh: () -> Unit, onDismiss: () -> Unit) {
    ClientGroup {
        Column(Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(vmmActionTitle(record.action)), style = MaterialTheme.typography.titleSmall)
            record.items.forEachIndexed { index, item ->
                val name = targets.singleOrNull { vmmIdentity(it) == item.identity }?.name ?: stringResource(R.string.vm_item_number, index + 1)
                Text(stringResource(R.string.vm_item_status, name, stringResource(when (item.stage) {
                    VmmStage.PREPARED, VmmStage.CANCELLED -> R.string.vm_not_sent
                    VmmStage.SUBMITTED -> R.string.vm_result_unavailable
                    VmmStage.ACCEPTED -> if (record.action == VmmAction.RESTART) R.string.vm_restart_sent else R.string.vm_processing
                    VmmStage.REJECTED -> R.string.vm_rejected
                    VmmStage.VERIFIED -> when (record.action) {
                        VmmAction.START -> R.string.vm_running
                        VmmAction.SHUTDOWN, VmmAction.POWER_OFF -> R.string.vm_stopped
                        VmmAction.RESTART -> R.string.vm_restarted
                        VmmAction.DELETE -> R.string.vm_removed
                    }
                })))
            }
            if (record.pending) Text(stringResource(R.string.vm_pending_hint))
            TextButton(onClick = if (record.pending) onRefresh else onDismiss, enabled = !busy) {
                Text(stringResource(if (record.pending) R.string.refresh else R.string.close))
            }
        }
    }
}

internal fun vmmActionTitle(action: VmmAction) = when (action) {
    VmmAction.START -> R.string.vm_start
    VmmAction.SHUTDOWN -> R.string.vm_stop
    VmmAction.POWER_OFF -> R.string.vm_poweroff
    VmmAction.RESTART -> R.string.vm_restart
    VmmAction.DELETE -> R.string.vm_delete
}
@Composable internal fun vmmErrorText(error: Exception, changedMessage: Int = R.string.vm_changed): String = when (error) {
    is VmmFailure -> stringResource(when (error.problem) {
        VmmProblem.CHANGED -> changedMessage
        VmmProblem.STORAGE -> R.string.vm_storage
    })
    is DsmFailure -> error.localize(LocalContext.current).combined
    else -> stringResource(R.string.vm_read_failed)
}
