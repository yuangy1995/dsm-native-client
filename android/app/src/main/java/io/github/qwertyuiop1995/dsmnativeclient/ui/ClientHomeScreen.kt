package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.home.HomeLayout
import io.github.qwertyuiop1995.dsmnativeclient.ui.home.HomeSection
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.ClientDestination
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.ClientEntryAction
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.ClientTaskStatus
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.matches

@Composable
internal fun ClientHomeScreen(
    state: WorkspaceState,
    recent: List<String>,
    onOpenDirectory: (String) -> Unit,
    onOpen: (ClientDestination) -> Unit,
    onAction: (ClientEntryAction) -> Unit,
    layout: HomeLayout = HomeLayout(),
    onCustomize: () -> Unit = {},
) {
    val active = state.transfers.filter { ClientTaskStatus.ACTIVE.matches(it) }
    val filesAvailable = state.availability.any { it.module == Module.FILES && it.isAvailable }
    val photosAvailable = state.availability.any { it.module == Module.PHOTOS && it.isAvailable }
    val downloadsAvailable = state.availability.any { it.module == Module.DOWNLOADS && it.isAvailable }
    val hasQuickActions = (filesAvailable && state.supportsUploads) || photosAvailable || downloadsAvailable
    val visible = HomeSection.entries.filter { section ->
        layout.isVisible(section) && when (section) {
            HomeSection.QUICK_ACTIONS -> hasQuickActions
            HomeSection.ACTIVE_TASKS -> true
            HomeSection.COMMON_LOCATIONS, HomeSection.RECENT_ITEMS -> filesAvailable
        }
    }
    LazyColumn(
        Modifier.fillMaxSize().testTag("client_home_list"),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item(key = "heading") {
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.client_home), Modifier.weight(1f), style = MaterialTheme.typography.headlineSmall)
                IconButton(onClick = onCustomize, modifier = Modifier.testTag("customize_home")) {
                    Icon(Icons.Outlined.Tune, stringResource(R.string.client_customize_home))
                }
            }
        }
        if (visible.isEmpty()) item(key = "empty") {
            Column(
                Modifier.fillMaxWidth().padding(vertical = 64.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(Icons.Outlined.DashboardCustomize, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(stringResource(R.string.client_home_hidden_title), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.client_home_hidden_description), color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center)
                Button(onClick = onCustomize, shape = MaterialTheme.shapes.medium) { Text(stringResource(R.string.client_customize_home)) }
            }
        }
        if (HomeSection.QUICK_ACTIONS in visible) item(key = HomeSection.QUICK_ACTIONS.id) {
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).testTag("home_section_quickActions"), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (filesAvailable && state.supportsUploads) HomeQuickAction(stringResource(R.string.upload_file),
                    Icons.Outlined.UploadFile, Modifier.weight(1f)) { onAction(ClientEntryAction.UPLOAD) }
                if (photosAvailable) HomeQuickAction(stringResource(R.string.client_browse_photos),
                    Icons.Outlined.PhotoLibrary, Modifier.weight(1f)) { onOpen(ClientDestination.PHOTOS) }
                if (downloadsAvailable) HomeQuickAction(stringResource(R.string.add_download),
                    Icons.Outlined.Download, Modifier.weight(1f)) { onAction(ClientEntryAction.DOWNLOAD_CREATE) }
            }
        }
        if (HomeSection.ACTIVE_TASKS in visible) item(key = HomeSection.ACTIVE_TASKS.id) {
            Column(Modifier.testTag("home_section_activeTasks"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ClientSectionTitle(stringResource(R.string.client_active_tasks), stringResource(R.string.client_tasks)) {
                    onOpen(ClientDestination.TASKS)
                }
                if (active.isEmpty()) Text(stringResource(R.string.client_no_active_tasks), style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                else Surface(onClick = { onOpen(ClientDestination.TASKS) }, color = MaterialTheme.colorScheme.primaryContainer,
                    shape = MaterialTheme.shapes.large, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(active.first().title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall)
                        Text(state.profile.name, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onPrimaryContainer)
                        active.first().progress?.let {
                            LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth(),
                                gapSize = 0.dp, drawStopIndicator = {})
                        }
                        Text(stringResource(R.string.client_active_task_count, active.size), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
        if (HomeSection.COMMON_LOCATIONS in visible) item(key = HomeSection.COMMON_LOCATIONS.id) {
            Column(Modifier.testTag("home_section_commonLocations"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ClientSectionTitle(stringResource(R.string.client_common_locations))
                if (state.favoritePaths.isNotEmpty()) SavedLocationTiles(state.favoritePaths.sorted().take(4), onOpenDirectory)
                else Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surface) {
                    ClientRow(stringResource(R.string.client_files), Icons.Outlined.FolderOpen) { onOpen(ClientDestination.FILES) }
                }
            }
        }
        if (HomeSection.RECENT_ITEMS in visible) item(key = HomeSection.RECENT_ITEMS.id) {
            Column(Modifier.testTag("home_section_recentItems"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ClientSectionTitle(stringResource(R.string.client_recent_access))
                Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surface) {
                    Column {
                        if (recent.isEmpty()) ClientRow(stringResource(R.string.client_files), Icons.Outlined.FolderOpen,
                            stringResource(R.string.client_recent_empty)) { onOpen(ClientDestination.FILES) }
                        else recent.take(4).forEachIndexed { index, path ->
                            if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                            ClientRow(path.substringAfterLast('/').ifBlank { path }, Icons.Outlined.Folder,
                                state.profile.name) { onOpenDirectory(path) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun SavedLocationTiles(paths: List<String>, onOpen: (String) -> Unit) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        items(paths, key = { it }) { path ->
            Surface(onClick = { onOpen(path) }, modifier = Modifier.width(168.dp),
                shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surface) {
                Column(Modifier.heightIn(min = 112.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Icon(Icons.Outlined.Folder, null, Modifier.size(28.dp), tint = MaterialTheme.colorScheme.tertiary)
                    Text(path.substringAfterLast('/').ifBlank { path }, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.titleSmall)
                }
            }
        }
    }
}

@Composable
private fun HomeQuickAction(title: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Surface(onClick = onClick, modifier = modifier.fillMaxHeight(), shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().heightIn(min = 92.dp).padding(horizontal = 8.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(28.dp))
            Text(title, style = MaterialTheme.typography.labelMedium, textAlign = TextAlign.Center)
        }
    }
}
