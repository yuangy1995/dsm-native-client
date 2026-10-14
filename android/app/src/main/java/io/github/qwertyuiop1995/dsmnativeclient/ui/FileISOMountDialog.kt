package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Album
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileISOMountDialog(feature: FileISOMountFeatureModel) {
    val state by feature.state.collectAsStateWithLifecycle()
    val screen = state.screen ?: return
    if (state.locationsVisible) { FileISOMountDestinationDialog(feature, state); return }
    if (screen == ISOMountScreen.MANAGER) { FileISOMountManagerDialog(feature, state); return }
    val connecting = screen == ISOMountScreen.CONNECT
    ClientSheet(stringResource(if (connecting) R.string.iso_mount_action else R.string.iso_unmount_action), feature::close,
        Modifier.testTag("iso_editor"), dismissEnabled = !state.busy, canDismiss = { !feature.state.value.busy }) {
        Box(Modifier.fillMaxWidth().heightIn(min = 220.dp)) {
            PageStateContent(state.inventory.toPageUiState(isEmpty = { false }),
                emptyTitle = stringResource(R.string.iso_mounts_empty), emptyMessage = stringResource(R.string.iso_mounts_empty_hint), emptyIcon = Icons.Outlined.Album,
                filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.Album,
                onRetry = feature::reload) {
                Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text(state.source?.path ?: state.selected?.source.orEmpty())
                    if (connecting) {
                        ClientGroup {
                            ClientRow(stringResource(R.string.iso_destination), Icons.Outlined.FolderOpen,
                                detail = state.destination?.path ?: stringResource(R.string.iso_choose_destination),
                                enabled = !state.busy && !state.submitted && feature.currentPending() == null,
                                onClick = feature::openLocations)
                        }
                        Text(stringResource(R.string.iso_empty_folder_hint), style = MaterialTheme.typography.bodySmall)
                        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("iso_automatic")
                            .toggleable(state.automatic, enabled = !state.busy && !state.submitted,
                                role = Role.Checkbox, onValueChange = feature::automatic), verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(state.automatic, onCheckedChange = null)
                            Text(stringResource(R.string.iso_automatic), Modifier.weight(1f).padding(start = 8.dp))
                        }
                    } else {
                        Text(state.selected?.mountPoint.orEmpty())
                        Text(stringResource(R.string.iso_unmount_impact))
                    }
                    if (!feature.canManage()) Text(stringResource(R.string.iso_management_unavailable), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    ISOMountFeedback(state)
                    val pending = feature.currentPending()
                    if (pending != null) {
                        Text(stringResource(R.string.iso_result_for, pending.connection.mountPoint))
                        Text(stringResource(R.string.iso_pending_hint))
                        Button({ feature.review(pending) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("iso_refresh_result"), enabled = !state.busy) {
                            Text(stringResource(R.string.iso_refresh_status))
                        }
                    } else if (state.result?.status == MutationResultStatus.CONFIRMED_SUCCESS) {
                        Button({ feature.openManager() }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("iso_show_mounts")) { Text(stringResource(R.string.iso_mounts_title)) }
                    } else {
                        Button({ feature.submit() }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("iso_submit"), enabled = feature.canSubmit()) {
                            Text(stringResource(if (connecting) R.string.iso_mount_action else R.string.iso_unmount_action))
                        }
                        if (state.submitted) TextButton(feature::reload,
                            Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("iso_reload"), enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
                    }
                }
            }
        }
    }
    if (state.confirmation) AlertDialog(onDismissRequest = feature::dismissConfirmation,
        title = { Text(stringResource(R.string.iso_automatic_confirm_title)) },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(state.source?.path.orEmpty()); Text(state.destination?.path.orEmpty())
            Text(stringResource(R.string.iso_automatic_impact)); Text(stringResource(R.string.iso_operation_account, state.account))
        } },
        confirmButton = { TextButton({ feature.submit(confirmed = true) }, Modifier.testTag("iso_confirm_automatic")) { Text(stringResource(R.string.iso_mount_automatically)) } },
        dismissButton = { TextButton(feature::dismissConfirmation) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun FileISOMountManagerDialog(feature: FileISOMountFeatureModel, state: FileISOMountState) {
    ClientPageDialog(stringResource(R.string.iso_mounts_title), feature::close) {
        Column(Modifier.fillMaxSize().testTag("iso_manager")) {
            ClientSearchField(state.filter, feature::filter, stringResource(R.string.iso_filter), Modifier.padding(12.dp).testTag("iso_filter"))
            val inventory = (state.inventory as? Loadable.Ready)?.value
            val connections = inventory?.isoConnections.orEmpty()
            fun matches(source: String, point: String) = source.contains(state.filter, true) || point.contains(state.filter, true)
            val visible = connections.filter { matches(it.source, it.mountPoint) }
            val pending = state.pending.filter { matches(it.connection.source, it.connection.mountPoint) }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                PageStateContent(state.inventory.toPageUiState(isEmpty = { connections.isEmpty() && state.pending.isEmpty() },
                    isFilteredEmpty = { visible.isEmpty() && pending.isEmpty() && (connections.isNotEmpty() || state.pending.isNotEmpty()) }),
                    emptyTitle = stringResource(R.string.iso_mounts_empty), emptyMessage = stringResource(R.string.iso_mounts_empty_hint), emptyIcon = Icons.Outlined.Album,
                    filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.Album,
                    onRetry = feature::reload) {
                    LazyColumn(Modifier.fillMaxSize().testTag("iso_mount_list"), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(pending, key = { "pending_" + it.id }) { record ->
                            ClientGroup {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(record.connection.source, style = MaterialTheme.typography.titleSmall)
                                    Text(record.connection.mountPoint)
                                    Text(stringResource(R.string.iso_pending_hint))
                                    Button({ feature.review(record) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("iso_pending_refresh"), enabled = !state.busy) {
                                        Text(stringResource(R.string.iso_refresh_status))
                                    }
                                }
                            }
                        }
                        items(visible, key = { it.mountPoint }) { connection ->
                            ClientGroup {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(connection.source, style = MaterialTheme.typography.titleSmall)
                                    Text(connection.mountPoint)
                                    connection.automatic?.let { Text(stringResource(if (it) R.string.iso_automatic_on else R.string.iso_automatic_off), style = MaterialTheme.typography.bodySmall) }
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        TextButton({ feature.browse(connection) }, Modifier.heightIn(min = 48.dp).testTag("iso_browse"), enabled = !state.busy) { Text(stringResource(R.string.open)) }
                                        TextButton({ feature.openUnmount(connection) }, Modifier.heightIn(min = 48.dp).testTag("iso_unmount"), enabled = !state.busy && feature.canManage() &&
                                            state.pending.none { io.github.qwertyuiop1995.dsmnativeclient.data.files.mountPathsOverlap(it.connection.mountPoint, connection.mountPoint) }) { Text(stringResource(R.string.iso_unmount_action)) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Column(Modifier.padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) { ISOMountFeedback(state) }
            TextButton(feature::reload, Modifier.fillMaxWidth().padding(12.dp).heightIn(min = 48.dp).testTag("iso_refresh"),
                enabled = !state.busy && state.inventory !is Loadable.Loading) { Text(stringResource(R.string.refresh)) }
        }
    }
}

@Composable
private fun ISOMountFeedback(state: FileISOMountState) {
    if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
    state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
    state.result?.let { result ->
        state.resultPath?.let { Text(stringResource(R.string.iso_result_for, it)) }
        Text(stringResource(when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> R.string.iso_operation_completed
            MutationResultStatus.PERMISSION_DENIED -> R.string.iso_operation_denied
            else -> R.string.iso_pending_hint
        }), Modifier.testTag("iso_result"))
    }
}
