package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmAssetKind
import androidx.activity.compose.BackHandler
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.virtualMachineMutationBlocksWorkspaceExit

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.importStageLabelResource
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.VirtualMachineLocalImageImportUiState
import io.github.qwertyuiop1995.dsmnativeclient.VirtualMachineTab
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedVirtualMachineImageImportStage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerRegistryImage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerSection
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerSectionCount
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.isEligibleForVirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineSection
import io.github.qwertyuiop1995.dsmnativeclient.domain.toSummary
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.ActionRow
import io.github.qwertyuiop1995.dsmnativeclient.ui.EmptyState
import io.github.qwertyuiop1995.dsmnativeclient.ui.LoadableContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.ResourceList
import io.github.qwertyuiop1995.dsmnativeclient.ui.displayName
import java.text.DateFormat
import java.util.Date

@Composable
internal fun VirtualMachinesScreen(state: WorkspaceState, model: AppViewModel) {
    DisposableEffect(model) { onDispose { model.vmmConsole.clear() } }
    val console by model.vmmConsole.state.collectAsStateWithLifecycle()
    if (console.target != null) {
        VmmConsoleContent(console, model.vmmConsole::clear, { model.vmmConsole.reconnect() })
        return
    }
    val tab = state.virtualMachineMutationState.selectedTab.ordinal
    var sectionOpen by rememberSaveable { mutableStateOf(tab != 0) }
    LaunchedEffect(tab) { if (tab != 0) sectionOpen = true }
    BackHandler(enabled = sectionOpen && state.virtualMachineMutationState.guestDetailsTargetId == null) {
        if (!virtualMachineMutationBlocksWorkspaceExit(state.virtualMachineMutationState)) {
            sectionOpen = false; model.selectVirtualMachineTab(VirtualMachineTab.MACHINES)
        }
    }
    var protectionTab by rememberSaveable { mutableIntStateOf(0) }
    var selected by remember { mutableStateOf<ManagedResource?>(null) }
    var localImportsVisible by remember { mutableStateOf(false) }
    var taskActivitiesVisible by remember { mutableStateOf(false) }
    val taskState by model.vmmTasks.state.collectAsStateWithLifecycle()
    val localImports by model.virtualMachineLocalImageImports.collectAsStateWithLifecycle()
    val localFilePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) {
        uri -> if (uri != null) model.selectVirtualMachineLocalImage(uri)
    }
    LaunchedEffect(state.profile.id) { model.refreshVirtualMachineLocalImageImports() }
    val controlState by model.vmmControls.state.collectAsStateWithLifecycle()
    val assetState by model.vmmAssets.state.collectAsStateWithLifecycle()
    val settingsState by model.vmmSettings.state.collectAsStateWithLifecycle()
    val creationState by model.vmmCreation.state.collectAsStateWithLifecycle()
    LaunchedEffect(state.profile.id) { model.vmmControls.refresh(); model.vmmSettings.refresh(); model.vmmCreation.refresh(); model.vmmTasks.refresh() }
    val mutation = state.virtualMachineMutationState
    val controlBlocked = controlState.busy || controlState.confirmation != null || controlState.record?.pending == true || controlState.failure != null
    val assetBlocked = assetState.busy || assetState.confirmation != null || assetState.records.any { it.pending } || assetState.failure != null
    val creationBusy = creationState.busy || creationState.editor || creationState.reviewId != null
    val creationPending = creationState.records.any { it.pending }
    val writeBlocked = taskState.active || creationBusy || creationPending || creationState.failure != null || settingsState.busy || settingsState.editor || settingsState.records.any { it.pending } || settingsState.failure != null || assetBlocked || controlBlocked || state.isPerformingAction || mutation.imageImportEditorVisible
    val titles = listOf(
        stringResource(R.string.virtual_machines),
        stringResource(R.string.hosts),
        stringResource(R.string.storage),
        stringResource(R.string.networks),
        stringResource(R.string.images),
        stringResource(R.string.protection),
        stringResource(R.string.logs),
        stringResource(R.string.virtual_machine_tasks),
    )
    Column(Modifier.fillMaxSize()) {
        if (sectionOpen) ClientToolbar(titles[tab], onBack = {
            if (!virtualMachineMutationBlocksWorkspaceExit(state.virtualMachineMutationState)) {
                sectionOpen = false; model.selectVirtualMachineTab(VirtualMachineTab.MACHINES)
            }
        }) else if (state.virtualMachines is io.github.qwertyuiop1995.dsmnativeclient.Loadable.Ready) ClientServiceSections(titles) { sectionOpen = true; model.selectVirtualMachineTab(VirtualMachineTab.entries[it]) }
        if (taskState.active || taskState.imports.isNotEmpty() || taskState.cleanups.isNotEmpty() || taskState.failure != null) {
            TextButton(onClick = { taskActivitiesVisible = true }, modifier = Modifier.heightIn(min = 48.dp).align(Alignment.End)) { Text(stringResource(R.string.vm_task_activity)) }
        }
        Box(Modifier.fillMaxWidth().weight(1f)) {
            LoadableContent(
                value = state.virtualMachines,
                emptyTitle = stringResource(R.string.no_items),
                emptyMessage = stringResource(R.string.no_category_items),
                onRetry = { model.load(Module.VIRTUAL_MACHINES) },
            ) { overview ->
            val unavailable = when (tab) {
                1 -> VirtualMachineSection.HOSTS
                2 -> VirtualMachineSection.STORAGES
                3 -> VirtualMachineSection.NETWORKS
                4 -> VirtualMachineSection.IMAGES
                5 -> VirtualMachineSection.PROTECTION
                6 -> VirtualMachineSection.LOGS
                7 -> VirtualMachineSection.TASKS
                else -> null
            } in overview.unavailableSections
            if (unavailable && tab != 7) {
                ServiceSectionUnavailable { model.load(Module.VIRTUAL_MACHINES) }
                return@LoadableContent
            }
                when (tab) {
                0 -> VmmControlsScreen(model.vmmControls,
                    blocked = taskState.active || creationBusy || settingsState.busy || settingsState.editor || assetState.busy || assetState.confirmation != null || state.isPerformingAction || mutation.imageImportEditorVisible,
                    protectedIds = assetState.records.flatMap { it.items }.filter { it.pending }.flatMap { it.guests }.toSet() + settingsState.protectedIds + creationState.protectedIds +
                        controlState.targets.filter { target -> creationState.records.any { it.pending && it.snapshot.plan.configuration.name.equals(target.name, ignoreCase = true) } }.map { io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(it.id) },
                    header = {
                        VmmCreationRecords(creationState, model.vmmCreation::refresh, { model.vmmCreation.review(it) }, model.vmmCreation::dismiss)
                        VmmSettingsRecords(settingsState, controlState.targets, model.vmmSettings::refresh, model.vmmSettings::dismiss)
                        if (creationState.sources.isNotEmpty()) FilledTonalButton(
                            onClick = { model.vmmCreation.open() }, enabled = !taskState.active && !creationBusy && !settingsState.busy && !settingsState.editor && !controlState.busy && controlState.confirmation == null && !assetState.busy && assetState.confirmation == null && !state.isPerformingAction && !mutation.imageImportEditorVisible,
                            modifier = Modifier.heightIn(min = 48.dp),
                        ) { Icon(Icons.Outlined.Add, contentDescription = null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.create_virtual_machine)) }
                    }, details = { target, close ->
                        if (model.vmmConsole.supported) TextButton(onClick = { if (model.vmmConsole.open(target)) close() },
                            enabled = !taskState.active && target.status == "running" && !creationBusy && !settingsState.busy && !settingsState.editor && !assetState.busy && assetState.confirmation == null && !controlState.busy && controlState.confirmation == null &&
                                !state.isPerformingAction && !mutation.imageImportEditorVisible &&
                                io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(target.id) !in (settingsState.protectedIds + controlState.protectedIds + creationState.protectedIds + assetState.records.flatMap { it.items }.filter { it.pending }.flatMap { it.guests }.toSet()) &&
                                creationState.records.none { it.pending && it.snapshot.plan.configuration.name.equals(target.name, ignoreCase = true) },
                            modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.vm_console_open)) }
                        if (state.supportsOfficialVirtualMachineSettings) {
                            TextButton(onClick = { if (model.openVirtualMachineGuestDetails(target.id)) close() }) { Text(stringResource(R.string.view_virtual_machine_details)) }
                        }
                        TextButton(onClick = { if (model.vmmSettings.open(target.id)) close() },
                            enabled = !taskState.active && !creationBusy && !creationPending && !settingsState.busy && !settingsState.editor && !assetState.busy && assetState.confirmation == null && !controlState.busy && controlState.confirmation == null &&
                                io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(target.id) !in (settingsState.protectedIds + controlState.protectedIds + assetState.records.flatMap { it.items }.filter { it.pending }.flatMap { it.guests }.toSet())) {
                            Text(stringResource(R.string.edit_virtual_machine))
                        }
                    })
                3, 4 -> VmmAssetsScreen(model.vmmAssets, if (tab == 3) VmmAssetKind.NETWORK else VmmAssetKind.IMAGE,
                    blocked = taskState.active || creationBusy || settingsState.busy || settingsState.editor || controlState.busy || controlState.confirmation != null || state.isPerformingAction || mutation.imageImportEditorVisible,
                    protectedGuests = controlState.protectedIds + settingsState.protectedIds + creationState.protectedIds,
                    protectedAssets = creationState.protectedAssets(if (tab == 3) VmmAssetKind.NETWORK else VmmAssetKind.IMAGE) +
                        (if (tab == 4) assetState.images?.images.orEmpty().filter { image -> taskState.imports.any { record -> record.pending && (record.progress.image == io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(image.id) || image.name?.let { io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(it.lowercase(java.util.Locale.ROOT)) } == record.snapshot.nameKey) } }.map { io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(it.id) }.toSet() else emptySet()), header = {
                        if (tab == 4 && state.supportsOfficialVirtualMachineImageImport) {
                            FilledTonalButton(onClick = { model.openVirtualMachineImageImportEditor() }, enabled = !writeBlocked && overview.storages.any { it.isEligibleForVirtualMachineImageImport() }, modifier = Modifier.heightIn(min = 48.dp)) {
                                Icon(Icons.Outlined.Add, contentDescription = null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.virtual_machine_import_image))
                            }
                            if (localImports.isNotEmpty()) TextButton(onClick = { localImportsVisible = true }, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.virtual_machine_local_image_imports)) }
                        }
                    })
                5 -> ProtectionContent(overview, protectionTab) { protectionTab = it }
                6 -> LogList(
                    logs = overview.logs,
                    isAvailable = true,
                    onRetry = { model.load(Module.VIRTUAL_MACHINES) },
                )
                7 -> VirtualMachineTaskCenterContent(
                    tasks = overview.tasks,
                    state = overview.taskCenterState,
                    onRetry = { model.load(Module.VIRTUAL_MACHINES) },
                    cleanupEnabled = !writeBlocked && !model.vmmLocalImportsPending(),
                    onClearFinished = { model.vmmTasks.requestCleanup().also { if (it) taskActivitiesVisible = true } },
                    refreshing = mutation.taskPolling.refreshing,
                    refreshFailure = mutation.taskPolling.failure,
                    onRetryPolling = model::retryVirtualMachineTaskPolling,
                )
                else -> ResourceList(overview.forTab(tab), stringResource(R.string.no_named_items, titles[tab]), onSelect = { selected = it })
                }
            }
        }
    }
    selected?.let { resource ->
        ClientSheet(resource.name, onDismiss = { selected = null }) {
            Text(resource.state.displayName())
            if (resource.detail.isNotBlank()) Text(resource.detail)
        }
    }
    val overview = (state.virtualMachines as? Loadable.Ready)?.value
    VmmCreationSheet(creationState, model.vmmCreation::change, { model.vmmCreation.create() }, model.vmmCreation::retryEditor, model.vmmCreation::close, { model.vmmCreation.continueCreation() })
    if (mutation.imageImportEditorVisible && mutation.imageImportDraft != null && overview != null) {
        VirtualMachineImageImportDialog(
            draft = mutation.imageImportDraft,
            storages = overview.storages.filter {
                it.isEligibleForVirtualMachineImageImport()
            },
            submitting = taskState.busy,
            onDraftChange = model::updateVirtualMachineImageImportDraft,
            onOpenFolder = model::enterVirtualMachineImageImportFolder,
            onBackFolder = model::goBackVirtualMachineImageImportFolder,
            onSelectFile = model::selectVirtualMachineImageImportFile,
            onRetry = model::retryVirtualMachineImageImportBrowser,
            onConfirm = { model.confirmVirtualMachineImageImport().also { if (it) taskActivitiesVisible = true } },
            onDismiss = model::closeVirtualMachineImageImportEditor,
            onRequestLocalFile = { localFilePicker.launch(arrayOf("*/*")); true },
            onSelectStagingDirectory = model::selectVirtualMachineImageImportStagingDirectory,
            onConfirmLocal = model::confirmVirtualMachineLocalImageImport,
        )
    }
    VmmSettingsSheet(settingsState, model.vmmSettings::change, { model.vmmSettings.save() }, model.vmmSettings::retryEditor, model.vmmSettings::close)
    taskState.confirmation?.let { targets ->
        VirtualMachineTaskCleanupConfirmationDialog(
            taskCount = targets.size,
            onConfirm = { model.vmmTasks.confirmCleanup(targets).also { if (it) taskActivitiesVisible = true } },
            onDismiss = { model.vmmTasks.cancelCleanup(); true },
        )
    }
    if (taskActivitiesVisible && taskState.confirmation == null) VmmTaskRecords(taskState, model.vmmTasks::refresh, model.vmmTasks::dismiss) { taskActivitiesVisible = false }
    if (localImportsVisible) {
        VirtualMachineLocalImageImportsDialog(
            imports = localImports,
            onRefresh = model::refreshVirtualMachineLocalImageImports,
            onRetry = model::retryVirtualMachineLocalImageImport,
            onRemove = model::removeVirtualMachineLocalImageImport,
            onDismiss = { localImportsVisible = false },
        )
    }
}

@Composable
private fun VirtualMachineLocalImageImportsDialog(
    imports: List<VirtualMachineLocalImageImportUiState>,
    onRefresh: () -> Boolean,
    onRetry: (String) -> Boolean,
    onRemove: (String) -> Boolean,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.virtual_machine_local_image_imports)) },
        text = {
            LazyColumn(
                modifier = Modifier.fillMaxWidth().heightIn(max = 520.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (imports.isEmpty()) item {
                    Text(stringResource(R.string.virtual_machine_local_image_imports_empty))
                }
                items(imports, key = VirtualMachineLocalImageImportUiState::id) { item ->
                    ListItem(
                        headlineContent = { Text(item.imageName) },
                        supportingContent = {
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(stringResource(item.stage.importStageLabelResource()))
                                if (item.needsReview) {
                                    Text(
                                        stringResource(
                                            R.string.virtual_machine_local_image_import_needs_review,
                                        ),
                                        modifier = Modifier.semantics {
                                            liveRegion = LiveRegionMode.Polite
                                        },
                                    )
                                }
                            }
                        },
                        trailingContent = {
                            when {
                                item.canRetry -> TextButton(
                                    onClick = { onRetry(item.id) },
                                    modifier = Modifier.heightIn(min = 48.dp),
                                ) {
                                    Text(
                                        stringResource(
                                            R.string.virtual_machine_local_image_import_retry,
                                        ),
                                    )
                                }
                                item.canRemove -> TextButton(
                                    onClick = { onRemove(item.id) },
                                    modifier = Modifier.heightIn(min = 48.dp),
                                ) {
                                    Text(
                                        stringResource(
                                            R.string.virtual_machine_local_image_import_remove,
                                        ),
                                    )
                                }
                            }
                        },
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onRefresh() },
                modifier = Modifier.heightIn(min = 48.dp),
            ) { Text(stringResource(R.string.virtual_machine_local_image_import_refresh)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.close))
            }
        },
    )
}


@Composable
internal fun VirtualMachineEmptyContent(
    supportsCreation: Boolean,
    hasStorage: Boolean,
    enabled: Boolean,
    onCreate: () -> Boolean,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.Info, contentDescription = null)
        Text(
            stringResource(R.string.virtual_machine_empty_title),
            modifier = Modifier.padding(top = 12.dp),
        )
        Text(
            stringResource(
                when {
                    supportsCreation && !hasStorage -> R.string.virtual_machine_no_storage
                    supportsCreation -> R.string.virtual_machine_empty_create_message
                    else -> R.string.virtual_machine_empty_external_message
                },
            ),
            modifier = Modifier.padding(top = 8.dp),
        )
        if (supportsCreation) {
            FilledTonalButton(
                onClick = { onCreate() },
                enabled = enabled && hasStorage,
                modifier = Modifier.padding(top = 16.dp).heightIn(min = 48.dp),
            ) {
                Icon(Icons.Outlined.Add, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.create_virtual_machine))
            }
        }
    }
}

internal fun virtualMachineTabSupportsDeletion(tab: Int): Boolean = tab == 0 || tab == 4

internal fun virtualMachineLifecycleCommands(state: ResourceState): Set<String> = when (state) {
    ResourceState.STOPPED -> setOf("poweron")
    ResourceState.RUNNING -> setOf("shutdown", "poweroff")
    else -> emptySet()
}

@Composable
private fun ProtectionContent(
    overview: VirtualMachineOverview,
    selected: Int,
    onSelected: (Int) -> Unit,
) {
    val titles = listOf(
        stringResource(R.string.protection_plans),
        stringResource(R.string.schedule_policies),
        stringResource(R.string.retention_policies),
    )
    val resources = when (selected) {
        0 -> overview.protectionPlans
        1 -> overview.protectionSchedules
        else -> overview.retentionPolicies
    }
    Column {
        ScrollableTabRow(selectedTabIndex = selected, edgePadding = 12.dp, divider = {}) {
            titles.forEachIndexed { index, title ->
                Tab(
                    selected = index == selected,
                    onClick = { onSelected(index) },
                    text = { Text(title) },
                )
            }
        }
        ResourceList(
            resources,
            stringResource(R.string.no_named_items, titles[selected]),
            onSelect = {},
        )
    }
}

private fun VirtualMachineOverview.forTab(tab: Int): List<ManagedResource> = when (tab) {
    0 -> machines
    1 -> hosts
    2 -> storages
    3 -> networks
    4 -> images
    else -> emptyList()
}
