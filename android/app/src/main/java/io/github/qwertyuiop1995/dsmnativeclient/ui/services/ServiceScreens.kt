package io.github.qwertyuiop1995.dsmnativeclient.ui.services

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
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.VirtualMachineLifecycleOperation
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

internal const val CONTAINER_REGISTRY_SCROLL_TEST_TAG = "container_registry_scroll"
@Composable
internal fun ContainersScreen(state: WorkspaceState, model: AppViewModel) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var sectionOpen by rememberSaveable { mutableStateOf(false) }
    BackHandler(enabled = sectionOpen && !state.containerRegistryVisible) { sectionOpen = false; tab = 0 }
    var selected by remember { mutableStateOf<ManagedResource?>(null) }
    val titles = listOf(
        stringResource(R.string.overview),
        stringResource(R.string.containers),
        stringResource(R.string.images),
        stringResource(R.string.networks),
        stringResource(R.string.projects),
        stringResource(R.string.events),
    )
    Column(Modifier.fillMaxSize()) {
        if (sectionOpen) ClientToolbar(titles[tab], onBack = { sectionOpen = false; tab = 0 })
        else if (state.containers is io.github.qwertyuiop1995.dsmnativeclient.Loadable.Ready) ClientServiceSections(titles.drop(1)) { tab = it + 1; sectionOpen = true }
        ListItem(
            headlineContent = { Text(stringResource(R.string.container_management_read_only)) },
            leadingContent = {
                Icon(
                    Icons.Outlined.Info,
                    contentDescription = null,
                )
            },
        )
        HorizontalDivider()
        Box(Modifier.fillMaxWidth().weight(1f)) {
            LoadableContent(
                value = state.containers,
                emptyTitle = stringResource(R.string.no_items),
                emptyMessage = stringResource(R.string.no_category_items),
                onRetry = { model.load(Module.CONTAINERS) },
            ) { overview ->
                val unavailable = when (tab) {
                    2 -> ContainerSection.IMAGES
                    3 -> ContainerSection.NETWORKS
                    4 -> ContainerSection.PROJECTS
                    5 -> ContainerSection.EVENTS
                    else -> null
                } in overview.unavailableSections
                if (unavailable) {
                    ServiceSectionUnavailable { model.load(Module.CONTAINERS) }
                    return@LoadableContent
                }
                if (tab == 0) {
                    ContainerOverviewSummaryContent(overview)
                    return@LoadableContent
                }
                if (tab == 5) {
                    LogList(
                        logs = overview.events,
                        isAvailable = true,
                        onRetry = { model.load(Module.CONTAINERS) },
                    )
                    return@LoadableContent
                }
                val resources = when (tab) {
                    1 -> overview.containers
                    2 -> overview.images
                    3 -> overview.networks
                    else -> overview.projects
                }
                ResourceList(
                    resources = resources.map { resource -> resource.copy(detail = "") },
                    emptyTitle = stringResource(R.string.no_named_items, titles[tab]),
                    onSelect = { selected = it },
                    headerAction = when {
                        tab == 2 && state.supportsContainerRegistry -> {
                            {
                                FilledTonalButton(onClick = model::showContainerRegistry) {
                                    Icon(Icons.Outlined.Search, contentDescription = null)
                                    Spacer(Modifier.width(8.dp))
                                    Text(stringResource(R.string.search_images))
                                }
                            }
                        }
                        else -> null
                    },
                )
            }
        }
    }
    selected?.let { resource ->
        AlertDialog(
            onDismissRequest = { selected = null },
            title = { Text(resource.name) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(resource.state.displayName())
                    Text(stringResource(R.string.container_management_read_only))
                }
            },
            confirmButton = {
                TextButton(onClick = { selected = null }) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
    if (state.containerRegistryVisible) {
        ContainerRegistryDialog(state, model)
    }
}

@Composable
private fun ContainerOverviewSummaryContent(
    overview: io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerOverview,
) {
    val summary = overview.toSummary()
    val running = pluralStringResource(
        R.plurals.container_overview_running_count,
        summary.runningContainers,
        summary.runningContainers,
    )
    val stopped = pluralStringResource(
        R.plurals.container_overview_stopped_count,
        summary.stoppedContainers,
        summary.stoppedContainers,
    )
    val other = pluralStringResource(
        R.plurals.container_overview_other_count,
        summary.otherContainers,
        summary.otherContainers,
    )
    LazyColumn(Modifier.fillMaxSize()) {
        item { Text(stringResource(R.string.overview), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(16.dp)) }
        item {
            ListItem(
                headlineContent = {
                    Text(
                        pluralStringResource(
                            R.plurals.container_overview_total,
                            summary.totalContainers,
                            summary.totalContainers,
                        ),
                    )
                },
                supportingContent = {
                    Text(
                        stringResource(
                            R.string.container_overview_state_counts,
                            running,
                            stopped,
                            other,
                        ),
                    )
                },
            )
        }
        item { ContainerOverviewSectionCount(R.string.images, summary.images) }
        item { ContainerOverviewSectionCount(R.string.networks, summary.networks) }
        item { ContainerOverviewSectionCount(R.string.projects, summary.projects) }
    }
}

@Composable
private fun ContainerOverviewSectionCount(
    @androidx.annotation.StringRes title: Int,
    count: ContainerSectionCount,
) {
    val sectionTitle = stringResource(title)
    ListItem(
        headlineContent = {
            Text(
                when (count) {
                    is ContainerSectionCount.Available -> pluralStringResource(
                        R.plurals.container_overview_section_count,
                        count.count,
                        sectionTitle,
                        count.count,
                    )
                    ContainerSectionCount.Unavailable -> stringResource(
                        R.string.container_overview_section_unavailable,
                        sectionTitle,
                    )
                },
            )
        },
    )
}

@Composable
private fun ContainerRegistryDialog(state: WorkspaceState, model: AppViewModel) {
    val canSearch = state.containerRegistryQuery.isNotBlank() &&
        state.containerRegistryResults !is Loadable.Loading
    AlertDialog(
        onDismissRequest = model::closeContainerRegistry,
        title = { Text(stringResource(R.string.container_registry)) },
        text = {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 560.dp)
                    .testTag(CONTAINER_REGISTRY_SCROLL_TEST_TAG),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = PaddingValues(bottom = 8.dp),
            ) {
                item {
                    OutlinedTextField(
                        value = state.containerRegistryQuery,
                        onValueChange = model::updateContainerRegistryQuery,
                        label = { Text(stringResource(R.string.image_name)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(
                            onSearch = { if (canSearch) model.searchContainerRegistry() },
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                item {
                    FilledTonalButton(
                        onClick = model::searchContainerRegistry,
                        enabled = canSearch,
                    ) {
                        Icon(Icons.Outlined.Search, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.search_images))
                    }
                }
                when (val results = state.containerRegistryResults) {
                    Loadable.Idle -> item {
                        Text(stringResource(R.string.container_registry_search_hint))
                    }
                    Loadable.Loading -> item {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .semantics { liveRegion = LiveRegionMode.Polite },
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            CircularProgressIndicator(Modifier.padding(16.dp))
                            Text(stringResource(R.string.container_registry_searching))
                        }
                    }
                    is Loadable.Failed -> item {
                        Text(
                            results.error.localize(
                                androidx.compose.ui.platform.LocalContext.current,
                            ).combined,
                            modifier = Modifier.semantics {
                                liveRegion = LiveRegionMode.Polite
                            },
                        )
                    }
                    is Loadable.Ready -> if (results.value.isEmpty()) {
                        item { Text(stringResource(R.string.no_container_registry_results)) }
                    } else {
                        results.value.forEach { image ->
                            item(key = "image:${image.id}") {
                                ListItem(
                                    headlineContent = {
                                        Column {
                                            Text(image.name)
                                            if (image.isOfficial) {
                                                ContainerRegistryOfficialSourceLabel()
                                            }
                                        }
                                    },
                                    supportingContent = {
                                        Text(
                                            listOfNotNull(
                                                image.registry,
                                                image.description,
                                                stringResource(
                                                    R.string.container_registry_stars,
                                                    image.starCount,
                                                ),
                                            ).joinToString(" · "),
                                        )
                                    },
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(min = 48.dp)
                                        .selectable(
                                            selected = state.selectedContainerRegistryImage?.id == image.id,
                                            onClick = { model.selectContainerRegistryImage(image) },
                                        ),
                                )
                            }
                            if (state.selectedContainerRegistryImage?.id == image.id) {
                                containerRegistryTags(
                                    image = image,
                                    tags = state.containerRegistryTags,
                                    onRetry = { model.selectContainerRegistryImage(image) },
                                )
                            }
                        }
                    }
                }
                item { Text(stringResource(R.string.container_registry_read_only_hint)) }
            }
        },
        confirmButton = {
            TextButton(onClick = model::closeContainerRegistry) {
                Text(stringResource(R.string.close))
            }
        },
    )
}

private fun LazyListScope.containerRegistryTags(
    image: ContainerRegistryImage,
    tags: Loadable<List<String>>,
    onRetry: () -> Unit,
) {
    item(key = "tags-heading:${image.id}") {
        Text(
            stringResource(R.string.container_registry_tags_for, image.name),
            modifier = Modifier.semantics { heading() },
        )
    }
    if (image.isOfficial) {
        item(key = "official-source:${image.id}") {
            ContainerRegistryOfficialSourceLabel()
        }
    }
    when (tags) {
        Loadable.Idle -> Unit
        Loadable.Loading -> item(key = "tags-loading:${image.id}") {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { liveRegion = LiveRegionMode.Polite },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                CircularProgressIndicator(Modifier.padding(8.dp))
                Text(
                    stringResource(
                        R.string.container_registry_loading_tags_for,
                        image.name,
                    ),
                )
            }
        }
        is Loadable.Failed -> item(key = "tags-failed:${image.id}") {
            Column(
                Modifier
                    .fillMaxWidth()
                    .semantics { liveRegion = LiveRegionMode.Polite },
            ) {
                Text(
                    tags.error.localize(
                        androidx.compose.ui.platform.LocalContext.current,
                    ).combined,
                )
                TextButton(onClick = onRetry) {
                    Text(stringResource(R.string.retry_container_registry_tags))
                }
            }
        }
        is Loadable.Ready -> if (tags.value.isEmpty()) {
            item(key = "tags-empty:${image.id}") {
                Text(stringResource(R.string.no_container_registry_tags))
            }
        } else {
            item(key = "tags-count:${image.id}") {
                Text(
                    pluralStringResource(
                        R.plurals.container_registry_tag_count,
                        tags.value.size,
                        tags.value.size,
                    ),
                )
            }
            itemsIndexed(
                items = tags.value,
                key = { index, tag -> "tag:${image.id}:$index\u0000$tag" },
            ) { _, tag ->
                ListItem(headlineContent = { Text(tag) })
            }
        }
    }
}

@Composable
private fun ContainerRegistryOfficialSourceLabel() {
    val label = stringResource(R.string.container_registry_official)
    Text(
        text = label,
        style = MaterialTheme.typography.labelMedium,
        modifier = Modifier.semantics { contentDescription = label },
    )
}

@Composable
internal fun VirtualMachinesScreen(state: WorkspaceState, model: AppViewModel) {
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
    val localImports by model.virtualMachineLocalImageImports.collectAsStateWithLifecycle()
    val localFilePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) {
        uri -> if (uri != null) model.selectVirtualMachineLocalImage(uri)
    }
    LaunchedEffect(state.profile.id) { model.refreshVirtualMachineLocalImageImports() }
    val mutation = state.virtualMachineMutationState
    val writeBlocked = state.isPerformingAction || mutation.creationEditorVisible ||
        mutation.imageImportEditorVisible || mutation.settingsEditorVisible ||
        mutation.lifecycleConfirmationRequested ||
        mutation.taskCleanupConfirmationRequested ||
        mutation.target != null || mutation.mutationInProgress || mutation.mutationRefreshInProgress ||
        mutation.mutationResult != null || mutation.mutationFailure != null
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
                    cleanupEnabled = !writeBlocked,
                    onClearFinished = model::requestVirtualMachineTaskCleanupConfirmation,
                    refreshing = mutation.taskPolling.refreshing,
                    refreshFailure = mutation.taskPolling.failure,
                    onRetryPolling = model::retryVirtualMachineTaskPolling,
                )
                else -> {
                    val resources = overview.forTab(tab)
                    if (tab == 0 && resources.isEmpty()) {
                        VirtualMachineEmptyContent(
                            supportsCreation = state.supportsOfficialVirtualMachineCreation,
                            hasStorage = overview.storages.isNotEmpty(),
                            enabled = !writeBlocked,
                            onCreate = model::openVirtualMachineCreationEditor,
                        )
                    } else {
                        ResourceList(
                            resources,
                            stringResource(R.string.no_named_items, titles[tab]),
                            onSelect = { selected = it },
                            headerAction = when {
                                tab == 0 && state.supportsOfficialVirtualMachineCreation -> {{
                                    FilledTonalButton(
                                        onClick = { model.openVirtualMachineCreationEditor() },
                                        enabled = !writeBlocked && overview.storages.isNotEmpty(),
                                        modifier = Modifier.heightIn(min = 48.dp),
                                    ) {
                                        Icon(Icons.Outlined.Add, contentDescription = null)
                                        Spacer(Modifier.width(8.dp))
                                        Text(stringResource(R.string.create_virtual_machine))
                                    }
                                }}
                                tab == 4 && state.supportsOfficialVirtualMachineImageImport -> {{
                                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                        FilledTonalButton(
                                            onClick = { model.openVirtualMachineImageImportEditor() },
                                            enabled = !writeBlocked && overview.storages.any {
                                                it.isEligibleForVirtualMachineImageImport()
                                            },
                                            modifier = Modifier.heightIn(min = 48.dp),
                                        ) {
                                            Icon(Icons.Outlined.Add, contentDescription = null)
                                            Spacer(Modifier.width(8.dp))
                                            Text(stringResource(R.string.virtual_machine_import_image))
                                        }
                                        if (localImports.isNotEmpty()) {
                                            TextButton(
                                                onClick = { localImportsVisible = true },
                                                modifier = Modifier.heightIn(min = 48.dp),
                                            ) {
                                                Text(stringResource(R.string.virtual_machine_local_image_imports))
                                            }
                                        }
                                    }
                                }}
                                else -> null
                            },
                        )
                    }
                }
                }
            }
        }
    }
    selected?.let { resource ->
        AlertDialog(
            onDismissRequest = { selected = null },
            title = { Text(resource.name) },
            text = {
                val actions: @Composable () -> Unit = {
                    if (tab == 0 && state.supportsOfficialVirtualMachineSettings) {
                        ActionRow(
                            Icons.Outlined.Info,
                            stringResource(R.string.view_virtual_machine_details),
                        ) {
                            if (model.openVirtualMachineGuestDetails(resource.id)) {
                                selected = null
                            }
                        }
                    }
                    if (writeBlocked) {
                        Text(stringResource(R.string.virtual_machine_action_in_progress))
                    } else {
                        if (tab == 0) {
                            val lifecycleCommands = virtualMachineLifecycleCommands(resource.state)
                            if ("poweron" in lifecycleCommands) {
                                ActionRow(Icons.Outlined.PlayArrow, stringResource(R.string.start)) {
                                    if (model.requestVirtualMachineLifecycleConfirmation(
                                            resource.id,
                                            VirtualMachineLifecycleOperation.CONTROL,
                                            "poweron",
                                        )
                                    ) selected = null
                                }
                            }
                            if (state.supportsOfficialVirtualMachineSettings) {
                                ActionRow(
                                    Icons.Outlined.Edit,
                                    stringResource(R.string.edit_virtual_machine),
                                ) {
                                    if (model.openVirtualMachineSettingsEditor(resource.id)) selected = null
                                }
                            }
                            if ("shutdown" in lifecycleCommands) {
                                ActionRow(Icons.Outlined.Pause, stringResource(R.string.normal_shutdown)) {
                                    if (model.requestVirtualMachineLifecycleConfirmation(
                                            resource.id,
                                            VirtualMachineLifecycleOperation.CONTROL,
                                            "shutdown",
                                        )
                                    ) selected = null
                                }
                            }
                            if ("poweroff" in lifecycleCommands) {
                                ActionRow(
                                    Icons.Outlined.WarningAmber,
                                    stringResource(R.string.force_shutdown),
                                    destructive = true,
                                ) {
                                    if (model.requestVirtualMachineLifecycleConfirmation(
                                            resource.id,
                                            VirtualMachineLifecycleOperation.CONTROL,
                                            "poweroff",
                                        )
                                    ) selected = null
                                }
                            }
                        }
                        if (virtualMachineTabSupportsDeletion(tab)) {
                            ActionRow(
                                Icons.Outlined.DeleteOutline,
                                stringResource(R.string.delete),
                                destructive = true,
                            ) {
                                val operation = when (tab) {
                                    0 -> VirtualMachineLifecycleOperation.DELETE_MACHINE
                                    else -> VirtualMachineLifecycleOperation.DELETE_IMAGE
                                }
                                if (model.requestVirtualMachineLifecycleConfirmation(
                                        resource.id,
                                        operation,
                                    )
                                ) selected = null
                            }
                        }
                    }
                }
                if (tab == 0) {
                    val overview = (state.virtualMachines as? Loadable.Ready)?.value
                    VirtualMachineReadOnlyDetailContent(
                        stateLabel = resource.state.displayName(),
                        hardware = overview?.machineHardware?.firstOrNull {
                            it.machineId == resource.id
                        },
                        hardwareAvailable = overview != null &&
                            VirtualMachineSection.HARDWARE !in overview.unavailableSections,
                        onRetry = { model.load(Module.VIRTUAL_MACHINES) },
                        actions = actions,
                    )
                } else {
                    Column { actions() }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = { selected = null },
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
    if (mutation.target != null) {
        VirtualMachineMutationFeedbackDialog(
            state = mutation,
            onRefresh = model::refreshVirtualMachineMutation,
            onContinueEditing = model::continueEditingVirtualMachineMutation,
            onDismiss = model::dismissVirtualMachineMutation,
        )
    } else {
        val overview = (state.virtualMachines as? Loadable.Ready)?.value
        if (mutation.creationEditorVisible && mutation.creationDraft != null && overview != null) {
            VirtualMachineCreationDialog(
                overview = overview,
                draft = mutation.creationDraft,
                submitting = mutation.mutationInProgress || mutation.mutationRefreshInProgress,
                onDraftChange = model::updateVirtualMachineCreationDraft,
                onConfirm = model::confirmVirtualMachineCreation,
                onDismiss = model::closeVirtualMachineCreationEditor,
            )
        }
        if (mutation.imageImportEditorVisible && mutation.imageImportDraft != null && overview != null) {
            VirtualMachineImageImportDialog(
                draft = mutation.imageImportDraft,
                storages = overview.storages.filter {
                    it.isEligibleForVirtualMachineImageImport()
                },
                submitting = mutation.mutationInProgress || mutation.mutationRefreshInProgress,
                onDraftChange = model::updateVirtualMachineImageImportDraft,
                onOpenFolder = model::enterVirtualMachineImageImportFolder,
                onBackFolder = model::goBackVirtualMachineImageImportFolder,
                onSelectFile = model::selectVirtualMachineImageImportFile,
                onRetry = model::retryVirtualMachineImageImportBrowser,
                onConfirm = model::confirmVirtualMachineImageImport,
                onDismiss = model::closeVirtualMachineImageImportEditor,
                onRequestLocalFile = { localFilePicker.launch(arrayOf("*/*")); true },
                onSelectStagingDirectory = model::selectVirtualMachineImageImportStagingDirectory,
                onConfirmLocal = model::confirmVirtualMachineLocalImageImport,
            )
        }
        if (
            mutation.settingsEditorVisible && mutation.settingsDraft != null &&
            mutation.settingsBaseline != null
        ) {
            VirtualMachineSettingsDialog(
                draft = mutation.settingsDraft,
                baseline = mutation.settingsBaseline,
                submitting = mutation.mutationInProgress || mutation.mutationRefreshInProgress,
                onDraftChange = model::updateVirtualMachineSettingsDraft,
                onConfirm = model::confirmVirtualMachineSettings,
                onDismiss = model::closeVirtualMachineSettingsEditor,
            )
        }
        if (mutation.lifecycleConfirmationRequested && mutation.lifecycleConfirmationTarget != null) {
            val target = mutation.lifecycleConfirmationTarget
            val resourceName = overview?.resourceName(target.operation, target.resourceId)
                ?: stringResource(R.string.virtual_machine_selection_unavailable)
            VirtualMachineLifecycleConfirmationDialog(
                target = target,
                resourceName = resourceName,
                onConfirm = model::confirmVirtualMachineLifecycle,
                onDismiss = model::cancelVirtualMachineLifecycleConfirmation,
            )
        }
        if (mutation.taskCleanupConfirmationRequested && mutation.taskCleanupBaseline.isNotEmpty()) {
            VirtualMachineTaskCleanupConfirmationDialog(
                taskCount = mutation.taskCleanupBaseline.count { it.isFinished },
                onConfirm = model::confirmVirtualMachineTaskCleanup,
                onDismiss = model::cancelVirtualMachineTaskCleanupConfirmation,
            )
        }
    }
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
                                Text(stringResource(item.stage.labelResource()))
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

private fun PersistedVirtualMachineImageImportStage.labelResource(): Int = when (this) {
    PersistedVirtualMachineImageImportStage.PREPARING ->
        R.string.virtual_machine_local_image_import_stage_preparing
    PersistedVirtualMachineImageImportStage.UPLOAD_SUBMITTING ->
        R.string.virtual_machine_local_image_import_stage_uploading
    PersistedVirtualMachineImageImportStage.UPLOADED,
    PersistedVirtualMachineImageImportStage.CREATE_SUBMITTING,
    PersistedVirtualMachineImageImportStage.TASK_TRACKING,
    PersistedVirtualMachineImageImportStage.IMAGE_READBACK,
    PersistedVirtualMachineImageImportStage.TASK_CLEARING,
    -> R.string.virtual_machine_local_image_import_stage_creating
    PersistedVirtualMachineImageImportStage.TEMP_CLEANUP,
    PersistedVirtualMachineImageImportStage.CLEANUP_PENDING,
    -> R.string.virtual_machine_local_image_import_stage_cleaning
    PersistedVirtualMachineImageImportStage.SUCCEEDED ->
        R.string.virtual_machine_local_image_import_stage_succeeded
    PersistedVirtualMachineImageImportStage.NEEDS_REVIEW,
    PersistedVirtualMachineImageImportStage.FAILED,
    PersistedVirtualMachineImageImportStage.CANCELLED,
    -> R.string.virtual_machine_local_image_import_stage_failed
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

private fun VirtualMachineOverview.resourceName(
    operation: VirtualMachineLifecycleOperation,
    id: String,
): String? = when (operation) {
    VirtualMachineLifecycleOperation.DELETE_IMAGE -> images
    VirtualMachineLifecycleOperation.DELETE_NETWORK,
    VirtualMachineLifecycleOperation.RENAME_NETWORK,
    -> networks
    else -> machines
}.firstOrNull { it.id == id }?.name

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

@Composable
internal fun LogList(
    logs: List<LogEntry>,
    isAvailable: Boolean,
    onRetry: () -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var level by rememberSaveable { mutableStateOf<LogLevel?>(null) }
    val filtered = logs.filter { log ->
        (level == null || log.level == level) &&
            (query.isBlank() || log.event.contains(query, true) || log.user.contains(query, true))
    }
    Column {
        if (!isAvailable) {
            ServiceSectionUnavailable(onRetry)
        } else if (logs.isEmpty()) {
            Box(
                Modifier.fillMaxSize().semantics { liveRegion = LiveRegionMode.Polite },
            ) {
                EmptyState(
                    stringResource(R.string.no_log_entries),
                    stringResource(R.string.no_log_entries_description),
                    Icons.AutoMirrored.Outlined.ListAlt,
                )
            }
        } else {
            LazyRow(
                contentPadding = PaddingValues(12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item {
                    FilterChip(
                        selected = level == null,
                        onClick = { level = null },
                        label = { Text(stringResource(R.string.all)) },
                    )
                }
                items(LogLevel.entries) { value ->
                    FilterChip(
                        selected = level == value,
                        onClick = { level = value },
                        label = { Text(value.displayName()) },
                    )
                }
            }
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text(stringResource(R.string.search_logs)) },
                leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            )
            if (filtered.isEmpty()) {
                Box(
                    Modifier.fillMaxSize().semantics { liveRegion = LiveRegionMode.Polite },
                ) {
                    EmptyState(
                        stringResource(R.string.no_matching_log_entries),
                        stringResource(R.string.no_matching_log_entries_description),
                        Icons.AutoMirrored.Outlined.ListAlt,
                    )
                }
            } else {
                LazyColumn {
                    items(filtered, key = LogEntry::id) { log ->
                        ListItem(
                            headlineContent = { Text(log.event) },
                            supportingContent = {
                                Text(
                                    listOfNotNull(
                                        log.user,
                                        log.timeEpochSeconds?.let(::formatDate),
                                    ).joinToString(" · "),
                                )
                            },
                            leadingContent = {
                                Icon(log.level.icon(), contentDescription = log.level.displayName())
                            },
                        )
                        HorizontalDivider(Modifier.padding(start = 72.dp))
                    }
                }
            }
        }
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

@Composable
private fun LogLevel.displayName(): String = when (this) {
    LogLevel.INFO -> stringResource(R.string.info)
    LogLevel.WARNING -> stringResource(R.string.warning)
    LogLevel.ERROR -> stringResource(R.string.error)
    LogLevel.UNKNOWN -> stringResource(R.string.other)
}

private fun LogLevel.icon(): ImageVector = when (this) {
    LogLevel.INFO -> Icons.Outlined.Info
    LogLevel.WARNING -> Icons.Outlined.WarningAmber
    LogLevel.ERROR -> Icons.Outlined.ErrorOutline
    LogLevel.UNKNOWN -> Icons.AutoMirrored.Outlined.ListAlt
}

private fun formatDate(epochSeconds: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
        .format(Date(epochSeconds * 1_000))
