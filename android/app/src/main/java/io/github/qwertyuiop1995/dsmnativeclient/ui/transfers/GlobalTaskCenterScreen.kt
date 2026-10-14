package io.github.qwertyuiop1995.dsmnativeclient.ui.transfers

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind
import io.github.qwertyuiop1995.dsmnativeclient.ui.EmptyState
import io.github.qwertyuiop1995.dsmnativeclient.ui.connectionConfirmationName
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun GlobalTaskHistoryScreen(host: WorkspaceHostModel) {
    BackHandler { host.closeTaskHistory() }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            ClientToolbar(stringResource(R.string.client_tasks), { host.closeTaskHistory() })
            GlobalTaskCenterContent(host, currentProfileId = null)
        }
    }
}

@Composable
internal fun GlobalTaskCenterContent(
    host: WorkspaceHostModel, currentProfileId: String?,
    onSource: ((ClientTaskSource) -> Unit)? = null,
) {
    val state by host.taskCenter.state.collectAsStateWithLifecycle()
    val connections by host.connections.collectAsStateWithLifecycle()
    val focus by host.focusedTaskKey.collectAsStateWithLifecycle()
    var folderDetails by remember { mutableStateOf<FolderUploadFeatureModel?>(null) }
    folderDetails?.let { io.github.qwertyuiop1995.dsmnativeclient.ui.FolderUploadDialog(it) }
    var allDevices by rememberSaveable { mutableStateOf(true) }
    var status by rememberSaveable { mutableStateOf(ClientTaskStatus.ACTIVE) }
    var sourceFilter by rememberSaveable { mutableStateOf(TransferSourceFilter.ALL) }
    var filtersVisible by remember { mutableStateOf(false) }
    val rows = (state as? Loadable.Ready)?.value.orEmpty()
    val listState = rememberLazyListState()
    val visible = rows.filter { (allDevices || it.profileId == currentProfileId) &&
        status.matches(it.task) && sourceFilter.matches(it.task.direction) }
    LaunchedEffect(focus, rows) {
        rows.firstOrNull { it.key == focus }?.let { target ->
            allDevices = true; sourceFilter = TransferSourceFilter.ALL
            status = if (ClientTaskStatus.FINISHED.matches(target.task)) ClientTaskStatus.FINISHED else ClientTaskStatus.ACTIVE
        }
    }
    LaunchedEffect(focus, visible.map { it.key }) {
        val index = visible.indexOfFirst { it.key == focus }
        if (index >= 0) listState.scrollToItem(index)
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            LazyRow(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (currentProfileId != null && (connections.size > 1 || rows.any { it.profileId != currentProfileId })) {
                    item { FilterChip(allDevices, { host.clearTaskFocus(); allDevices = true }, label = { Text(stringResource(R.string.task_all_devices)) }) }
                    item { FilterChip(!allDevices, { host.clearTaskFocus(); allDevices = false }, label = {
                        connections.firstOrNull { it.profile.id == currentProfileId }?.profile?.let { Text(connectionConfirmationName(it, connections)) }
                    }) }
                }
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                ClientModeTabs(listOf(stringResource(R.string.client_active_tasks), stringResource(R.string.client_finished_tasks)), status.ordinal) {
                    host.clearTaskFocus()
                    status = ClientTaskStatus.entries[it]
                }
            }
            IconButton({ filtersVisible = true }) { Icon(Icons.Outlined.Tune, stringResource(R.string.transfer_filter_source)) }
        }
        if (focus != null && state is Loadable.Ready && rows.none { it.key == focus }) Text(
            stringResource(R.string.task_record_missing), Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        when (val value = state) {
            Loadable.Idle, Loadable.Loading -> Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) { CircularProgressIndicator() }
            is Loadable.Failed -> Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(stringResource(R.string.task_history_read_failed))
                Button(host.taskCenter::retry) { Text(stringResource(R.string.retry)) }
            }
            is Loadable.Ready -> if (visible.isEmpty()) EmptyState(
                stringResource(if (rows.isEmpty()) R.string.no_transfer_tasks else R.string.no_filtered_transfer_tasks),
                stringResource(if (rows.isEmpty()) R.string.transfers_description else R.string.no_filtered_transfer_tasks_description), Icons.Outlined.SwapVert,
            ) else LazyColumn(Modifier.weight(1f).testTag("global_task_list"), state = listState, contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(visible, key = { it.key }) { item ->
                    val model = host.taskModel(item)
                    val valid = item.profile != null
                    val canUseFiles = model?.workspace?.value?.availability?.allows(io.github.qwertyuiop1995.dsmnativeclient.domain.Module.FILES) == true
                    val label = item.profile?.let { profile -> val name = connectionConfirmationName(profile, connections); when (item.task.direction) {
                        TransferDirection.DOWNLOAD -> stringResource(R.string.task_nas_to_phone, name)
                        TransferDirection.UPLOAD -> stringResource(R.string.task_phone_to_nas, name)
                        TransferDirection.SERVER -> name
                    } }
                    Box(Modifier.testTag("global_task_${item.key}")) {
                        TransferTaskCard(item.task.copy(canCancel = valid && item.task.canCancel),
                            canPause = valid && item.canPause,
                            canResume = valid && canUseFiles && item.canResume,
                            canRetry = valid && canUseFiles && item.canRetry,
                            onPause = { host.actOnTask(item, GlobalTransferAction.PAUSE) },
                            onResume = { host.actOnTask(item, GlobalTransferAction.RESUME) },
                            onCancel = { host.actOnTask(item, GlobalTransferAction.CANCEL) },
                            onRetry = { host.actOnTask(item, GlobalTransferAction.RETRY) },
                            canRefreshTarget = !item.isCrossNas && valid && model?.canRefreshFileServerTransfer(item.task.id) == true,
                            isRefreshingTarget = item.task.fileServerMutation?.refreshInProgress == true,
                            onOpenAndRefreshTarget = { host.actOnTask(item, GlobalTransferAction.OPEN_TARGET) },
                            connectionLabel = label,
                            footer = if (valid && item.isCrossNas) ({
                                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.End) {
                                    TextButton({ host.actOnTask(item, GlobalTransferAction.OPEN_TARGET) }, Modifier.heightIn(min = 48.dp), enabled = model == null || canUseFiles) {
                                        Text(stringResource(if (model == null) R.string.task_open_connection else R.string.file_background_task_details))
                                    }
                                }
                            }) else if (valid && canUseFiles && item.kind == WorkspaceRecordKind.UPLOAD) ({
                                TransferUploadTargetButton(onDetails = if (model?.folderUploads?.isFolder(item.task.id) == true) ({ folderDetails = model.folderUploads; model.folderUploads.show(item.task.id) }) else null) { host.actOnTask(item, GlobalTransferAction.OPEN_TARGET) }
                            }) else if (valid && (model == null || item.kind == WorkspaceRecordKind.VMM_IMPORT)) ({
                                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.End) {
                                    TextButton({ if (item.kind == WorkspaceRecordKind.VMM_IMPORT && model != null) host.actOnTask(item, GlobalTransferAction.OPEN_TARGET)
                                        else host.openTaskConnection(item) }, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.task_open_connection)) }
                                }
                            }) else null,
                        )
                    }
                }
            }
        }
    }
    if (filtersVisible) ClientSheet(stringResource(R.string.transfer_filter_source), { filtersVisible = false }) {
        LazyRow(contentPadding = PaddingValues(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(TransferSourceFilter.entries) { filter -> FilterChip(sourceFilter == filter, { host.clearTaskFocus(); sourceFilter = filter }, label = { Text(stringResource(filter.labelResource())) }) }
        }
        val scoped = rows.filter { allDevices || it.profileId == currentProfileId }
        if (scoped.any { ClientTaskStatus.FINISHED.matches(it.task) }) {
            TextButton(onClick = { host.clearFinishedTasks(scoped) }, enabled = scoped.isNotEmpty() && scoped.all { it.profile != null && host.taskModel(it) != null },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.clear_finished_transfers)) }
        }
        onSource?.let { change -> ClientTaskSource.entries.filter { it != ClientTaskSource.PHONE }.forEach { source ->
            TextButton({ filtersVisible = false; change(source) }, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(source.title)) }
        } }
    }
}
