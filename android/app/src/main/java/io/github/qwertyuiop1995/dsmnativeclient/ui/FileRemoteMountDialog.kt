package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileRemoteMountDialog(feature: FileRemoteMountFeatureModel) {
    val state by feature.state.collectAsStateWithLifecycle()
    val screen = state.screen ?: return
    // 不使用可保存状态；退出当前表单、切换协议或进入下一步骤后清理密码。
    var password by remember(screen, state.baseline, state.recoveryId, state.setup.kind) { mutableStateOf("") }
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    val submit = { confirmed: Boolean ->
        focus.clearFocus(); keyboard?.hide()
        if (feature.submit(password, confirmed)) password = ""
    }
    if (state.locationsVisible) {
        FileMountDestinationDialog(state.locations, "remote", feature.canChooseLocation(), feature::closeLocations, feature::locationUp,
            feature::filterLocations, feature::retryLocations, feature::enterLocation, feature::chooseLocation)
        return
    }
    if (screen == RemoteMountScreen.MANAGER) { RemoteMountManager(feature, state); return }
    val title = when (screen) {
        RemoteMountScreen.EDITOR -> if (state.baseline == null) R.string.remote_mount_connect else R.string.remote_mount_edit
        RemoteMountScreen.DISCONNECT -> R.string.remote_mount_disconnect
        else -> R.string.remote_mount_continue_title
    }
    ClientSheet(stringResource(title), feature::close, Modifier.testTag("remote_editor"),
        dismissEnabled = !state.busy, canDismiss = { !feature.state.value.busy }) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            when (screen) {
                RemoteMountScreen.EDITOR -> RemoteMountFields(feature, state, password, { password = it })
                RemoteMountScreen.DISCONNECT -> {
                    Text(state.baseline?.source.orEmpty()); Text(state.baseline?.mountPoint.orEmpty())
                    Text(stringResource(R.string.remote_mount_disconnect_impact))
                }
                RemoteMountScreen.RECOVERY -> feature.record()?.let { record ->
                    Text(record.setup?.source ?: record.baseline?.source.orEmpty())
                    Text(record.mountPoint)
                    Text(stringResource(remoteStageText(record.stage)))
                    if (record.stage == RemoteMountStage.READY_TO_CONNECT && record.setup?.kind == FileMountKind.CIFS)
                        RemoteMountPassword(password, { password = it }, !state.busy)
                    if (record.stage.canContinue) {
                        Button({ focus.clearFocus(); keyboard?.hide(); if (feature.continueOperation(password)) password = "" },
                            Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("remote_continue"),
                            enabled = !state.busy && feature.canManage(record.baseline, record.setup?.automatic == true)) {
                            Text(stringResource(if (record.stage == RemoteMountStage.READY_TO_CONNECT) R.string.remote_mount_connect else R.string.remote_mount_disconnect_previous))
                        }
                        TextButton({ feature.endRemaining() }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("remote_end_remaining"), enabled = !state.busy) {
                            Text(stringResource(R.string.remote_mount_end_remaining))
                        }
                    } else Button({ feature.review(record) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("remote_review"), enabled = !state.busy) {
                        Text(stringResource(R.string.iso_refresh_status))
                    }
                }
                else -> Unit
            }
            RemoteMountFeedback(state)
            if (screen != RemoteMountScreen.RECOVERY && state.outcome?.status != RemoteMountOutcomeStatus.COMPLETED) {
                if (!feature.canManage()) Text(stringResource(R.string.remote_mount_management_unavailable), color = MaterialTheme.colorScheme.onSurfaceVariant)
                Button({ submit(false) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("remote_submit"), enabled = feature.canSubmit()) {
                    Text(stringResource(if (screen == RemoteMountScreen.DISCONNECT) R.string.remote_mount_disconnect
                        else if (state.baseline != null) R.string.remote_mount_save else R.string.remote_mount_connect))
                }
                if (state.submitted) TextButton(feature::reload, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
            }
            TextButton(feature::backToManager, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("remote_back_to_list"), enabled = !state.busy) {
                Text(stringResource(R.string.remote_mount_title))
            }
        }
    }
    state.confirmation?.let { confirmation ->
        val record = feature.record()
        AlertDialog(onDismissRequest = feature::dismissConfirmation, title = { Text(stringResource(when (confirmation) {
            RemoteMountConfirmation.AUTOMATIC -> R.string.remote_mount_automatic_confirm_title
            RemoteMountConfirmation.CHANGE -> R.string.remote_mount_edit
            RemoteMountConfirmation.END_REMAINING -> R.string.remote_mount_end_remaining
        })) }, text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                state.baseline?.let { Text(it.source); Text(it.mountPoint) }
                if (confirmation != RemoteMountConfirmation.END_REMAINING) { Text(state.setup.source); Text(state.setup.mountPoint) }
                Text(stringResource(when (confirmation) {
                    RemoteMountConfirmation.AUTOMATIC -> R.string.remote_mount_automatic_impact
                    RemoteMountConfirmation.CHANGE -> if (state.baseline?.mountPoint == state.setup.mountPoint) R.string.remote_mount_change_same_impact else R.string.remote_mount_change_move_impact
                    RemoteMountConfirmation.END_REMAINING -> if (record?.stage == RemoteMountStage.READY_TO_CONNECT) R.string.remote_mount_end_disconnected_impact else R.string.remote_mount_end_both_impact
                }))
                if (confirmation == RemoteMountConfirmation.CHANGE && state.setup.automatic) Text(stringResource(R.string.remote_mount_automatic_impact))
                Text(stringResource(R.string.iso_operation_account, state.account))
            }
        }, confirmButton = { TextButton({
            if (confirmation == RemoteMountConfirmation.END_REMAINING) { password = ""; feature.endRemaining(true) } else submit(true)
        }, Modifier.testTag("remote_confirm")) { Text(stringResource(if (confirmation == RemoteMountConfirmation.END_REMAINING)
                R.string.remote_mount_end_remaining else if (confirmation == RemoteMountConfirmation.CHANGE) R.string.remote_mount_save else R.string.remote_mount_connect)) } },
            dismissButton = { TextButton(feature::dismissConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun RemoteMountManager(feature: FileRemoteMountFeatureModel, state: FileRemoteMountState) {
    ClientPageDialog(stringResource(R.string.remote_mount_title), feature::close) {
        Column(Modifier.fillMaxSize().testTag("remote_manager")) {
            ClientSearchField(state.filter, feature::filter, stringResource(R.string.remote_mount_filter), Modifier.padding(12.dp).testTag("remote_filter"))
            val connections = (state.inventory as? Loadable.Ready)?.value?.remoteConnections.orEmpty()
            fun matches(source: String, point: String) = source.contains(state.filter, true) || point.contains(state.filter, true)
            val visible = connections.filter { matches(it.source, it.mountPoint) }
            val records = state.pending.filter { matches(it.setup?.source ?: it.baseline?.source.orEmpty(), it.mountPoint) }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                PageStateContent(state.inventory.toPageUiState(isEmpty = { connections.isEmpty() && state.pending.isEmpty() },
                    isFilteredEmpty = { visible.isEmpty() && records.isEmpty() && (connections.isNotEmpty() || state.pending.isNotEmpty()) }),
                    emptyTitle = stringResource(R.string.remote_mount_empty), emptyMessage = stringResource(R.string.remote_mount_empty_hint), emptyIcon = Icons.Outlined.FolderOpen,
                    filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.FolderOpen,
                    onRetry = feature::reload) {
                    LazyColumn(Modifier.fillMaxSize().testTag("remote_mount_list"), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(records, key = { "pending_" + it.id }) { record ->
                            ClientGroup {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(record.setup?.source ?: record.baseline?.source.orEmpty(), style = MaterialTheme.typography.titleSmall)
                                    Text(record.mountPoint); Text(stringResource(remoteStageText(record.stage)))
                                    TextButton({ feature.openRecovery(record) }, Modifier.heightIn(min = 48.dp).testTag("remote_open_recovery"), enabled = !state.busy) {
                                        Text(stringResource(if (record.stage.canContinue) R.string.remote_mount_continue_title else R.string.iso_refresh_status))
                                    }
                                }
                            }
                        }
                        items(visible, key = FileMountConnection::mountPoint) { connection ->
                            ClientGroup {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(connection.source, style = MaterialTheme.typography.titleSmall); Text(connection.mountPoint)
                                    Text(stringResource(when (connection.automatic) {
                                        true -> R.string.iso_automatic_on; false -> R.string.iso_automatic_off; null -> R.string.remote_mount_automatic_unknown
                                    }), style = MaterialTheme.typography.bodySmall)
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        TextButton({ feature.browse(connection) }, Modifier.heightIn(min = 48.dp).testTag("remote_browse"), enabled = !state.busy) { Text(stringResource(R.string.open)) }
                                        TextButton({ feature.openEditor(connection) }, Modifier.heightIn(min = 48.dp).testTag("remote_edit"), enabled = feature.canChange(connection)) { Text(stringResource(R.string.edit)) }
                                        TextButton({ feature.openDisconnect(connection) }, Modifier.heightIn(min = 48.dp).testTag("remote_disconnect"), enabled = feature.canChange(connection)) { Text(stringResource(R.string.remote_mount_disconnect)) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                RemoteMountFeedback(state)
                if (!feature.canManage(null, false) && state.inventory is Loadable.Ready)
                    Text(stringResource(R.string.remote_mount_management_unavailable), style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(feature::reload, Modifier.weight(1f).heightIn(min = 48.dp).testTag("remote_refresh"), enabled = !state.busy && state.inventory !is Loadable.Loading) { Text(stringResource(R.string.refresh)) }
                    Button({ feature.openEditor() }, Modifier.weight(1f).heightIn(min = 48.dp).testTag("remote_add"), enabled = !state.busy && feature.canManage(null, false)) { Text(stringResource(R.string.remote_mount_connect)) }
                }
            }
        }
    }
}

@Composable
private fun RemoteMountFeedback(state: FileRemoteMountState) {
    state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
    state.outcome?.takeUnless { state.screen == RemoteMountScreen.RECOVERY && state.pending.any { it.id == state.recoveryId } }?.let { outcome ->
        Text(stringResource(when (outcome.status) {
            RemoteMountOutcomeStatus.COMPLETED -> R.string.remote_mount_completed
            RemoteMountOutcomeStatus.ENDED -> R.string.remote_mount_remaining_ended
            RemoteMountOutcomeStatus.READY -> R.string.remote_mount_step_finished
            RemoteMountOutcomeStatus.UNKNOWN -> R.string.remote_mount_pending
            RemoteMountOutcomeStatus.REJECTED -> R.string.remote_mount_rejected
        }), Modifier.testTag("remote_result"))
    }
}

private fun remoteStageText(stage: RemoteMountStage) = when (stage) {
    RemoteMountStage.READY_TO_CONNECT -> R.string.remote_mount_ready_connect
    RemoteMountStage.READY_TO_DISCONNECT -> R.string.remote_mount_ready_disconnect
    else -> R.string.remote_mount_pending
}
