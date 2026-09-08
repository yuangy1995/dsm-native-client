package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.ClientDestination
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.ClientEntryAction
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.ClientTaskStatus
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.matches

@Composable
internal fun ClientHomeScreen(state: WorkspaceState, recent: List<String>, onOpenDirectory: (String) -> Unit,
    onOpen: (ClientDestination) -> Unit, onAction: (ClientEntryAction) -> Unit) {
    val active = state.transfers.filter { ClientTaskStatus.ACTIVE.matches(it) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { ClientSectionTitle(stringResource(R.string.client_recent_access)) }
        item {
            if (recent.isEmpty()) ClientRow(stringResource(R.string.client_files), Icons.Outlined.FolderOpen,
                stringResource(R.string.client_recent_empty)) { onOpen(ClientDestination.FILES) }
            else SavedLocationTiles(recent.take(6), onOpenDirectory)
        }
        item {
            ClientGroup {
                Row(Modifier.fillMaxWidth()) {
                    HomeQuickAction(stringResource(R.string.upload_file), Icons.Outlined.UploadFile,
                        Modifier.weight(1f)) { onAction(ClientEntryAction.UPLOAD) }
                    HomeQuickAction(stringResource(R.string.client_photo_backup), Icons.Outlined.PhotoLibrary,
                        Modifier.weight(1f)) { onAction(ClientEntryAction.PHOTO_BACKUP) }
                    HomeQuickAction(stringResource(R.string.add_download), Icons.Outlined.Download,
                        Modifier.weight(1f)) { onAction(ClientEntryAction.DOWNLOAD_CREATE) }
                }
            }
        }
        item { ClientSectionTitle(stringResource(R.string.client_phone_transfers), stringResource(R.string.client_tasks)) { onOpen(ClientDestination.TASKS) } }
        item {
            if (active.isEmpty()) Text(stringResource(R.string.client_no_active_tasks), style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            else Surface(onClick = { onOpen(ClientDestination.TASKS) }, color = MaterialTheme.colorScheme.primaryContainer,
                shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(stringResource(R.string.client_active_task_count, active.size), style = MaterialTheme.typography.titleSmall)
                    Text(active.first().title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodyMedium)
                    active.first().progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
                }
            }
        }
        item { ClientSectionTitle(stringResource(R.string.client_common_locations)) }
        item {
            ClientGroup {
                if (state.supportsFavorites) ClientRow(stringResource(R.string.open_favorites), Icons.Outlined.StarOutline) { onAction(ClientEntryAction.FAVORITES) }
                ClientRow(stringResource(R.string.open_recent_locations), Icons.Outlined.History) { onAction(ClientEntryAction.RECENT) }
                if (state.supportsSharing) ClientRow(stringResource(R.string.manage_share_links), Icons.Outlined.Link) { onAction(ClientEntryAction.SHARE_LINKS) }
            }
        }
    }
}

@Composable
internal fun SavedLocationTiles(paths: List<String>, onOpen: (String) -> Unit) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        items(paths, key = { it }) { path ->
            Surface(onClick = { onOpen(path) }, modifier = Modifier.width(168.dp),
                shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surface,
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
                Row(Modifier.heightIn(min = 88.dp).padding(14.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Icon(Icons.Outlined.Folder, null, Modifier.size(32.dp), tint = MaterialTheme.colorScheme.tertiary)
                    Text(path.substringAfterLast('/').ifBlank { path }, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.titleSmall)
                }
            }
        }
    }
}

@Composable
private fun HomeQuickAction(title: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Surface(onClick = onClick, modifier = modifier, color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().heightIn(min = 92.dp).padding(horizontal = 8.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(28.dp))
            Text(title, style = MaterialTheme.typography.labelMedium, textAlign = TextAlign.Center)
        }
    }
}
