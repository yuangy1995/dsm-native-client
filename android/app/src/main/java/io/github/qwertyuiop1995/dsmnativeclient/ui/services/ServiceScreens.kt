package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.compose.ui.platform.LocalConfiguration
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
                if (tab == 1) {
                    ContainerControlsScreen(model.containerControls)
                    return@LoadableContent
                }
                if (tab == 2) {
                    ContainerImagesScreen(model.containerImages, state.supportsContainerRegistry, model::showContainerRegistry)
                    return@LoadableContent
                }
                if (tab == 3) {
                    ContainerNetworksScreen(model.containerNetworks)
                    return@LoadableContent
                }
                if (tab == 5) {
                    ContainerEventsScreen(model)
                    return@LoadableContent
                }
                ResourceList(
                    resources = overview.projects,
                    emptyTitle = stringResource(R.string.no_named_items, titles[tab]),
                    onSelect = { selected = it },
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
                    (state.containers as? Loadable.Ready)?.value?.projectDetails?.singleOrNull { it.id == resource.id }?.containerCount?.let {
                        Text(pluralStringResource(R.plurals.cm_network_container_count, it, it))
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { selected = null }) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
    ContainerImageDialogs(model.containerImages)
    if (state.containerRegistryVisible) {
        ContainerRegistryDialog(state, model) { repository, tag ->
            if (model.containerImages.requestPull(repository, tag)) {
                model.closeContainerRegistry(); tab = 2; sectionOpen = true
            }
        }
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
private fun ContainerRegistryDialog(state: WorkspaceState, model: AppViewModel, onDownload: (String, String) -> Unit) {
    val operation by model.containerImages.state.collectAsStateWithLifecycle()
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
                operation.failure?.let { error -> item { Text(containerErrorText(error), color = MaterialTheme.colorScheme.error) } }
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
                                    onDownload = { onDownload(image.name, it) },
                                )
                            }
                        }
                    }
                }
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
    onDownload: (String) -> Unit,
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
                ListItem(headlineContent = { Text(tag) }, trailingContent = {
                    TextButton(onClick = { onDownload(tag) }) { Text(stringResource(R.string.cm_image_download)) }
                })
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
                                        log.localTime?.format(java.time.format.DateTimeFormatter.ofLocalizedDateTime(java.time.format.FormatStyle.MEDIUM)
                                            .withLocale(LocalConfiguration.current.locales[0]))
                                            ?: log.timeEpochSeconds?.let(::formatDate),
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
