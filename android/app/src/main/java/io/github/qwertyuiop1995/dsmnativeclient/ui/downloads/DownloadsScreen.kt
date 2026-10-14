package io.github.qwertyuiop1995.dsmnativeclient.ui.downloads

import androidx.compose.runtime.collectAsState
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.downloads.DownloadActionKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import androidx.compose.ui.semantics.contentDescription
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.ClientTaskStatus
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.matches
import androidx.compose.material3.FilterChip
import androidx.compose.material.icons.outlined.Close
import androidx.compose.runtime.LaunchedEffect

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.DownloadControlOperation
import io.github.qwertyuiop1995.dsmnativeclient.DownloadCreationSourceKind
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.canStartDownloadCreation
import io.github.qwertyuiop1995.dsmnativeclient.downloadCreationRequiresRefreshBeforeDismiss
import io.github.qwertyuiop1995.dsmnativeclient.downloadControlRequiresRefreshBeforeDismiss
import io.github.qwertyuiop1995.dsmnativeclient.downloadDestinationEditRequiresRefreshBeforeDismiss
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadStationActivity
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.ui.AdaptiveLayoutPolicy
import io.github.qwertyuiop1995.dsmnativeclient.ui.DownloadDestinationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.DownloadSettingsDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.EmptyState
import io.github.qwertyuiop1995.dsmnativeclient.ui.LoadableContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.StatusIcon
import io.github.qwertyuiop1995.dsmnativeclient.ui.displayName
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatBytes

@Composable
internal fun DownloadsScreen(state: WorkspaceState, model: AppViewModel) {
    val creationForm by model.downloadCreation.state.collectAsState()
    var selecting by remember(state.profile.id) { mutableStateOf(false) }
    var selection by remember(state.profile.id) { mutableStateOf(emptySet<String>()) }
    val tasks = (state.downloads as? Loadable.Ready)?.value.orEmpty()
    LaunchedEffect(state.downloadDetailsTask?.id, state.downloadDetails) {
        if (state.downloadDetails == Loadable.Idle) state.downloadDetailsTask?.let(model::openDownloadTaskDetails)
    }
    fun toggle(task: DownloadTask) { selection = if (task.id in selection) selection - task.id else selection + task.id }
    var query by rememberSaveable(state.profile.id) { mutableStateOf("") }
    var searchVisible by rememberSaveable { mutableStateOf(false) }
    var status by rememberSaveable { mutableStateOf(ClientTaskStatus.ACTIVE) }
    var optionsVisible by remember { mutableStateOf(false) }
    val entry = LocalClientEntry.current
    LaunchedEffect(entry?.revision) {
        when (entry?.action) {
            ClientEntryAction.DOWNLOAD_CREATE -> model.openDownloadCreationEditor()
            ClientEntryAction.SEARCH -> searchVisible = true
            else -> Unit
        }
        entry?.consume()
    }
    var selected by remember { mutableStateOf<DownloadTask?>(null) }
    var settingsUnavailable by rememberSaveable { mutableStateOf(false) }
    var fileSelectionToken by remember { mutableStateOf<Long?>(null) }
    val taskFileLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri ->
        uri?.let {
            fileSelectionToken?.let { token -> model.createDownloadFromFile(it, token) }
            fileSelectionToken = null
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val expandedLayout = AdaptiveLayoutPolicy.usesDownloadListDetail(maxWidth.value)
        val downloadControl = state.downloadControlState
        val downloadCreation = state.downloadCreationState
        val destinationEdit = state.downloadDestinationEditState
        val settingsState = state.downloadSettingsState
        val settingsIdle = !settingsState.editorVisible && !settingsState.mutationInProgress &&
            !settingsState.mutationRefreshInProgress && settingsState.mutationResult == null &&
            settingsState.mutationFailure == null
        val rssRefreshIdle = state.downloadRssRefreshState.target == null
        val destinationEditIdle = destinationEdit.selectionTaskBaseline == null &&
            destinationEdit.target == null && !destinationEdit.mutationInProgress &&
            !destinationEdit.mutationRefreshInProgress
        val downloadActionsEnabled = !state.isPerformingAction && downloadControl.target == null &&
            downloadCreation.target == null && settingsIdle && rssRefreshIdle && destinationEditIdle
        val creationActionsEnabled = downloadControl.target == null &&
            canStartDownloadCreation(state.isPerformingAction, downloadCreation) &&
            downloadCreation.pendingDiscoveryUri == null && settingsIdle && rssRefreshIdle
            && destinationEditIdle
        val settingsActionsEnabled = creationActionsEnabled
        val createLabel = stringResource(R.string.add_download)
    Scaffold(
        contentWindowInsets = WindowInsets(0),
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { if (creationActionsEnabled) model.openDownloadCreationEditor() },
                icon = { Icon(Icons.Outlined.Add, null) },
                text = { Text(createLabel) },
                modifier = Modifier
                    .semantics { contentDescription = createLabel }
                    .alpha(if (creationActionsEnabled) 1f else 0.38f)
                    .then(if (creationActionsEnabled) Modifier else Modifier.semantics { disabled() }),
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(status == ClientTaskStatus.ACTIVE, onClick = { status = ClientTaskStatus.ACTIVE },
                        label = { Text(stringResource(R.string.client_active_tasks)) })
                    FilterChip(status == ClientTaskStatus.FINISHED, onClick = { status = ClientTaskStatus.FINISHED },
                        label = { Text(stringResource(R.string.client_finished_tasks)) })
                }
                IconButton(onClick = { searchVisible = !searchVisible; if (!searchVisible) query = "" }) {
                    Icon(Icons.Outlined.Search, stringResource(R.string.client_search))
                }
                IconButton(onClick = { optionsVisible = true }) {
                    Icon(Icons.Outlined.Tune, stringResource(R.string.download_settings_title))
                }
            }
            if (searchVisible) ClientSearchField(query, { query = it }, stringResource(R.string.client_search_downloads),
                Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            if (selecting) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.download_batch_selected, selection.size))
                val chosen = tasks.filter { it.id in selection }
                TextButton(onClick = { model.downloadActions.requestTasks(chosen, DownloadActionKind.PAUSE); selecting = false; selection = emptySet() },
                    enabled = chosen.isNotEmpty() && chosen.all { it.status in setOf(ResourceState.RUNNING, ResourceState.WAITING) }) { Text(stringResource(R.string.pause)) }
                TextButton(onClick = { model.downloadActions.requestTasks(chosen, DownloadActionKind.RESUME); selecting = false; selection = emptySet() },
                    enabled = chosen.isNotEmpty() && chosen.all { it.status == ResourceState.PAUSED }) { Text(stringResource(R.string.resume)) }
                TextButton(onClick = { model.downloadActions.requestTasks(chosen, DownloadActionKind.REMOVE); selecting = false; selection = emptySet() }, enabled = chosen.isNotEmpty()) { Text(stringResource(R.string.remove_task)) }
                TextButton(onClick = { model.downloadActions.requestTasks(chosen, DownloadActionKind.END_AND_MOVE); selecting = false; selection = emptySet() }, enabled = chosen.isNotEmpty()) { Text(stringResource(R.string.remove_task_and_files)) }
                TextButton(onClick = { if (model.beginDownloadTasksDestinationSelection(selection)) { selecting = false; selection = emptySet() } }, enabled = chosen.isNotEmpty() && state.supportsDownloadTaskDestinationEditing) { Text(stringResource(R.string.change_download_destination)) }
                TextButton(onClick = { selecting = false; selection = emptySet() }) { Text(stringResource(R.string.cancel)) }
            }
            if (optionsVisible) ClientSheet(stringResource(R.string.client_downloads), { optionsVisible = false }) {
                ClientRow(stringResource(R.string.download_actions_title), Icons.Outlined.History) { optionsVisible = false; model.downloadActions.show() }
                ClientRow(stringResource(R.string.download_batch_select), Icons.Outlined.Checklist, enabled = tasks.isNotEmpty()) { optionsVisible = false; selecting = true }
                if (state.supportsDownloadRss || state.supportsDownloadBtSearch) ClientRow(
                    stringResource(R.string.download_discovery), Icons.Outlined.Search, enabled = creationActionsEnabled) {
                    optionsVisible = false; model.openDownloadDiscovery()
                }
                ClientRow(stringResource(R.string.download_settings_title), Icons.Outlined.Tune, enabled = settingsActionsEnabled) {
                    optionsVisible = false
                    if (state.supportsDownloadSettings) model.openDownloadSettings() else settingsUnavailable = true
                }
            }
            if (state.downloadAdvancedRead.supportsActivity) {
                DownloadActivitySummary(
                    activity = state.downloadAdvancedRead.activity,
                    onRetry = model::loadDownloadActivity,
                )
            }
            if (state.downloadListRefreshing) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.downloadListFailure?.let { failure -> Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(failure.localize(LocalContext.current).combined, Modifier.weight(1f), color = MaterialTheme.colorScheme.error)
                TextButton(onClick = { model.load(Module.DOWNLOADS) }) { Text(stringResource(R.string.retry)) }
            } }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (expandedLayout) {
                    Row(Modifier.fillMaxSize()) {
                        DownloadTaskList(
                            state = state,
                            model = model,
                            expanded = true,
                            selectedTaskId = state.downloadDetailsTask?.id,
                            actionsEnabled = downloadActionsEnabled,
                            onTaskActions = { selected = it },
                            selection = selection, selecting = selecting, onToggle = ::toggle,
                            onLongPress = { selecting = true; toggle(it) },
                            query = query, status = status,
                            modifier = Modifier.weight(0.42f).fillMaxSize(),
                        )
                        VerticalDivider()
                        val detail = state.downloadDetailsTask
                        if (detail == null) {
                            Box(Modifier.weight(0.58f).fillMaxSize()) {
                                EmptyState(
                                    title = stringResource(R.string.download_select_task),
                                    message = stringResource(R.string.download_select_task_description),
                                    icon = Icons.Outlined.Download,
                                )
                            }
                        } else {
                            DownloadLoadedDetails(
                                state = state, model = model, phone = false,
                                modifier = Modifier
                                    .weight(0.58f)
                                    .fillMaxSize()
                                    .padding(bottom = 88.dp),
                            )
                        }
                    }
                } else {
                    DownloadTaskList(
                        state = state,
                        model = model,
                        expanded = false,
                        selectedTaskId = null,
                        actionsEnabled = downloadActionsEnabled,
                        onTaskActions = { selected = it },
                        selection = selection, selecting = selecting, onToggle = ::toggle,
                        onLongPress = { selecting = true; toggle(it) },
                        query = query, status = status,
                    )
                }
            }
        }
    }
    if (creationForm.visible) DownloadDialog(state, model, onChooseFile = {
        fileSelectionToken = model.downloadCreation.selectionToken
        taskFileLauncher.launch(arrayOf("application/x-bittorrent", "application/x-nzb", "text/plain", "application/octet-stream"))
    }, onDismiss = { model.closeDownloadCreationEditor(); model.cancelDownloadDestinationSelection() })
    if (state.downloadSettingsState.editorVisible) {
        DownloadSettingsDialog(
            state = state,
            onRetry = model::loadDownloadSettings,
            onDraftChange = model::updateDownloadSettingsDraft,
            onSave = model::saveDownloadSettings,
            onRefreshMutation = model::refreshDownloadSettingsMutation,
            onDismissMutation = model::dismissDownloadSettingsMutation,
            onDismiss = model::closeDownloadSettings,
            onChooseDestination = model::beginDownloadDestinationSelection,
        )
    }
    if (state.downloadSettingsState.editorVisible && state.downloadDestinationPicker != null) DownloadDestinationDialog(state, model,
        onSelected = { path -> state.downloadSettingsState.draft?.let { model.updateDownloadSettingsDraft(it.copy(destination = path.removePrefix("/"))) }; model.cancelDownloadDestinationSelection() },
        onDismiss = model::cancelDownloadDestinationSelection)
    if (state.downloadAdvancedRead.discoveryVisible) {
        DownloadDiscoveryDialog(
            state = state,
            model = model,
            canCreateTask = creationActionsEnabled,
            onCreateTask = { title, uri, sourceKind ->
                model.beginDiscoveryDownloadCreation(title, uri, sourceKind)
            },
            onDismiss = { model.closeDownloadDiscovery() },
        )
    }
    if (settingsUnavailable) {
        AlertDialog(
            onDismissRequest = { settingsUnavailable = false },
            title = { Text(stringResource(R.string.download_settings_unavailable_title)) },
            text = { Text(stringResource(R.string.download_settings_unavailable_message)) },
            confirmButton = {
                TextButton(onClick = { settingsUnavailable = false }) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
    selected?.let { task ->
        DownloadTaskActionsDialog(
            taskTitle = task.title.ifBlank { stringResource(R.string.unnamed_download) },
            taskState = task.status,
            enabled = downloadActionsEnabled,
            canEditDestination = state.supportsDownloadTaskDestinationEditing,
            onDetails = {
                model.openDownloadTaskDetails(task)
                selected = null
            },
            onPause = { if (model.requestDownloadPause(task.id)) selected = null },
            onResume = { if (model.requestDownloadResume(task.id)) selected = null },
            onEditDestination = {
                if (model.beginDownloadTaskDestinationSelection(task.id)) selected = null
            },
            onRemove = { if (model.requestDownloadDeletion(task.id, false)) selected = null },
            onRemoveWithFiles = {
                if (model.requestDownloadDeletion(task.id, true)) selected = null
            },
            onDismiss = { selected = null },
        )
    }
    val showDetailsDialog = state.downloadDetailsTask != null && !expandedLayout
    if (showDetailsDialog) state.downloadDetailsTask?.let { task ->
        DownloadLoadedDetails(state, model, phone = true)
    }
    if (destinationEdit.selectionTaskBaseline != null && state.downloadDestinationPicker != null) {
        val sameDestination = state.downloadDestinationPicker.location.path.trim() ==
            destinationEdit.selectionTaskBaseline.destination?.trim()
        DownloadDestinationDialog(
            state = state,
            model = model,
            onSelected = { model.requestDownloadDestinationEdit() },
            onDismiss = model::cancelDownloadDestinationSelection,
            description = R.string.change_download_destination_picker_description,
            selectionEnabled = !sameDestination,
            selectionUnavailableMessage = if (sameDestination) {
                R.string.change_download_destination_same_location
            } else null,
        )
    }
    }
    DownloadActionsPanel(model.downloadActions, tasks)

}

@Composable
private fun DownloadActivitySummary(
    activity: Loadable<DownloadStationActivity>,
    onRetry: () -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Text(
                stringResource(R.string.download_activity_title),
                style = MaterialTheme.typography.titleMedium,
            )
            when (activity) {
                Loadable.Idle -> Text(stringResource(R.string.download_activity_unavailable))
                Loadable.Loading -> {
                    Text(stringResource(R.string.download_activity_loading))
                    LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 8.dp))
                }
                is Loadable.Failed -> Column(
                    Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
                ) {
                    Text(stringResource(R.string.download_activity_failed))
                    TextButton(
                        onClick = onRetry,
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) { Text(stringResource(R.string.retry)) }
                }
                is Loadable.Ready -> {
                    val value = activity.value
                    if (value.downloadBytesPerSecond == 0L && value.uploadBytesPerSecond == 0L &&
                        value.emuleDownloadBytesPerSecond == 0L &&
                        value.emuleUploadBytesPerSecond == 0L
                    ) {
                        Text(stringResource(R.string.download_activity_empty))
                    } else {
                        Text(
                            stringResource(
                                R.string.download_activity_standard,
                                formatBytes(value.downloadBytesPerSecond),
                                formatBytes(value.uploadBytesPerSecond),
                            ),
                        )
                        Text(
                            stringResource(
                                R.string.download_activity_emule,
                                formatBytes(value.emuleDownloadBytesPerSecond),
                                formatBytes(value.emuleUploadBytesPerSecond),
                            ),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DownloadTaskList(
    state: WorkspaceState,
    model: AppViewModel,
    expanded: Boolean,
    selectedTaskId: String?,
    actionsEnabled: Boolean,
    onTaskActions: (DownloadTask) -> Unit,
    query: String,
    status: ClientTaskStatus,
    selection: Set<String>, selecting: Boolean, onToggle: (DownloadTask) -> Unit, onLongPress: (DownloadTask) -> Unit,
    modifier: Modifier = Modifier.fillMaxSize(),
) {
    Box(modifier) {
        LoadableContent(
            value = state.downloads,
            emptyTitle = stringResource(R.string.no_download_tasks),
            emptyMessage = stringResource(R.string.add_download_description),
            onRetry = { model.load(Module.DOWNLOADS) },
        ) { tasks ->
            val visible = tasks.filter { status.matches(it.status) && it.title.contains(query.trim(), ignoreCase = true) }
            if (visible.isEmpty()) {
                EmptyState(stringResource(R.string.client_no_matching_downloads), stringResource(R.string.client_download_filter_recovery), Icons.Outlined.Search)
                return@LoadableContent
            }
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = 96.dp),
            ) {
                items(visible, key = DownloadTask::id) { task ->
                    val isSelected = if (selecting) task.id in selection else expanded && selectedTaskId == task.id
                    val rowModifier = Modifier.fillMaxWidth().heightIn(min = 76.dp)
                        .background(if (isSelected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface)
                        .combinedClickable(onClick = { if (selecting) onToggle(task) else model.openDownloadTaskDetails(task) }, onLongClick = { onLongPress(task) })
                        .semantics { selected = isSelected }
                    ListItem(
                        headlineContent = {
                            Text(
                                task.title.ifBlank { stringResource(R.string.unnamed_download) },
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        supportingContent = {
                            Column {
                                Text(task.displayStatus())
                                val total = task.size
                                val transferred = task.transferred
                                if (total != null && total > 0 && transferred != null) {
                                    LinearProgressIndicator(
                                        progress = {
                                            (transferred.toFloat() / total.toFloat()).coerceIn(0f, 1f)
                                        },
                                        modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                                    )
                                }
                            }
                        },
                        leadingContent = { if (selecting) Checkbox(task.id in selection, onCheckedChange = { onToggle(task) }) else StatusIcon(task.status) },
                        trailingContent = {
                            val taskTitle = task.title.ifBlank {
                                stringResource(R.string.unnamed_download)
                            }
                            IconButton(
                                enabled = actionsEnabled,
                                onClick = { onTaskActions(task) },
                            ) {
                                Icon(
                                    Icons.Outlined.MoreVert,
                                    contentDescription = stringResource(
                                        R.string.download_task_action_description,
                                        stringResource(R.string.task_actions),
                                        taskTitle,
                                    ),
                                )
                            }
                        },
                        colors = androidx.compose.material3.ListItemDefaults.colors(
                            containerColor = androidx.compose.ui.graphics.Color.Transparent,
                        ),
                        modifier = rowModifier,
                    )
                    HorizontalDivider(Modifier.padding(start = 72.dp))
                }
            }
        }
    }
}

@Composable
private fun DownloadDialog(
    state: WorkspaceState,
    model: AppViewModel,
    onChooseFile: () -> Unit,
    onDismiss: () -> Unit,
) {
    val creation by model.downloadCreation.state.collectAsState()
    val uri = creation.uri
    val destination = creation.destination
    ClientPageDialog(stringResource(R.string.add_download_task), onDismiss) {
        Column(Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .imePadding()
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (creation.copying) LinearProgressIndicator(Modifier.fillMaxWidth())
                creation.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
                creation.title?.let { Text(it, style = MaterialTheme.typography.titleMedium) }
                if (creation.filename != null) {
                    Text(creation.filename.orEmpty(), style = MaterialTheme.typography.titleMedium)
                    TextButton(onClick = { model.downloadCreation.useLink() }, enabled = !creation.copying) { Text(stringResource(R.string.download_creation_use_link)) }
                    OutlinedTextField(creation.password, { model.downloadCreation.update(password = it) }, label = { Text(stringResource(R.string.download_creation_password)) },
                        visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        enabled = !creation.copying, singleLine = true, modifier = Modifier.fillMaxWidth())
                } else OutlinedTextField(
                    value = uri,
                    onValueChange = { model.updateDownloadCreationDraft(it, destination) },
                    label = { Text(stringResource(R.string.url_or_magnet)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    minLines = 2,
                    shape = MaterialTheme.shapes.small,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = destination,
                    onValueChange = { model.updateDownloadCreationDraft(uri, it) },
                    label = { Text(stringResource(R.string.save_to_optional)) },
                    singleLine = true,
                    shape = MaterialTheme.shapes.small,
                    modifier = Modifier.fillMaxWidth(),
                )
                FilledTonalButton(
                    onClick = model::beginDownloadDestinationSelection,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Outlined.FolderOpen, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.browse_nas_folders))
                }
                if (destination.isNotEmpty()) TextButton(onClick = { model.downloadCreation.update(destination = "") }) { Text(stringResource(R.string.download_creation_default)) }
                Button(onClick = onChooseFile, enabled = !creation.copying, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Outlined.UploadFile, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.choose_download_task_file))
                }
                Text(
                    stringResource(R.string.download_task_file_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Button(onClick = { model.downloadCreation.submit() },
                enabled = (uri.isNotBlank() || creation.filename != null) && !creation.copying,
                modifier = Modifier.fillMaxWidth().padding(20.dp).heightIn(min = 52.dp)) {
                Text(stringResource(R.string.create_task))
            }
        }
    }
    if (state.downloadDestinationPicker != null) {
        DownloadDestinationDialog(
            state = state,
            model = model,
            onSelected = { selected ->
                model.updateDownloadCreationDraft(uri, selected)
                model.cancelDownloadDestinationSelection()
            },
        )
    }
}

@Composable
private fun DownloadLoadedDetails(state: WorkspaceState, model: AppViewModel, phone: Boolean, modifier: Modifier = Modifier) {
    val selected = state.downloadDetailsTask ?: return
    @Composable fun content() {
        when (val details = state.downloadDetails) {
            is Loadable.Ready -> if (phone) DownloadTaskDetailsContent(details.value, Modifier.fillMaxSize())
                else DownloadTaskDetailsPane(details.value, model::closeDownloadTaskDetails, Modifier.fillMaxSize())
            is Loadable.Failed -> Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(details.error.localize(LocalContext.current).combined)
                TextButton(onClick = { model.openDownloadTaskDetails(selected) }) { Text(stringResource(R.string.retry)) }
            }
            else -> Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                LinearProgressIndicator(Modifier.fillMaxWidth()); Text(stringResource(R.string.download_details_loading))
            }
        }
    }
    if (phone) ClientPageDialog(selected.title, model::closeDownloadTaskDetails) { content() }
    else Box(modifier) { content() }
}
