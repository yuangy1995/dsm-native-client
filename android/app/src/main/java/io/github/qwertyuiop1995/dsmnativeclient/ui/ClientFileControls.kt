package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.automirrored.outlined.Sort
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.FileCopyMoveOperation
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun ClientFileSelectionBar(state: WorkspaceState, model: AppViewModel, items: List<FileItem>, blocked: Boolean, onCompress: () -> Unit) {
    val writable = !blocked && !state.isPerformingAction && items.isNotEmpty()
    Surface(color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = model::clearFileSelection) { Icon(Icons.Outlined.Close, stringResource(R.string.clear_selection)) }
                Text(stringResource(R.string.items_selected_count, state.fileBrowser.selectedPaths.size), style = MaterialTheme.typography.titleSmall)
            }
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { model.beginFileCopyMove(items, FileCopyMoveOperation.COPY) },
                    enabled = writable && state.supportsCopyMove && items.all(FileItem::canRead)) {
                    Icon(Icons.Outlined.FileCopy, null); Text(stringResource(R.string.copy_selected_items), Modifier.padding(start = 6.dp))
                }
                TextButton(onClick = { model.beginFileCopyMove(items, FileCopyMoveOperation.MOVE) },
                    enabled = writable && state.supportsCopyMove && items.all(FileItem::canDelete)) {
                    Icon(Icons.AutoMirrored.Outlined.DriveFileMove, null); Text(stringResource(R.string.move_selected_items), Modifier.padding(start = 6.dp))
                }
                TextButton(onClick = onCompress, enabled = writable && state.supportsCompression && items.all(FileItem::canRead)) {
                    Icon(Icons.AutoMirrored.Outlined.InsertDriveFile, null); Text(stringResource(R.string.create_archive), Modifier.padding(start = 6.dp))
                }
                TextButton(onClick = { model.addFavorites(items) },
                    enabled = writable && state.supportsFavorites && items.all { it.isDirectory && !it.isFavorite }) {
                    Icon(Icons.Outlined.StarOutline, null); Text(stringResource(R.string.add_to_favorites), Modifier.padding(start = 6.dp))
                }
                TextButton(onClick = { model.deleteFiles(items) }, enabled = writable && items.all(FileItem::canDelete)) {
                    Icon(Icons.Outlined.DeleteOutline, null, tint = MaterialTheme.colorScheme.error)
                    Text(stringResource(R.string.delete_selected_items), Modifier.padding(start = 6.dp), color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

@Composable
internal fun ClientFileOptionsSheet(state: WorkspaceState, model: AppViewModel, onShareLinks: () -> Unit, onDismiss: () -> Unit) {
    ClientSheet(stringResource(R.string.client_file_options), onDismiss) {
        ClientSectionTitle(stringResource(R.string.sort_files))
        ClientGroup {
            FileSortOption.entries.forEach { option ->
                ClientRow(stringResource(when (option) {
                    FileSortOption.NAME -> R.string.sort_by_name
                    FileSortOption.MODIFIED_TIME -> R.string.sort_by_modified
                    FileSortOption.SIZE -> R.string.sort_by_size
                }), if (state.fileBrowser.sortOption == option) {
                    if (state.fileBrowser.sortAscending) Icons.Outlined.KeyboardArrowUp else Icons.Outlined.KeyboardArrowDown
                } else Icons.AutoMirrored.Outlined.Sort) { model.changeFileSort(option) }
            }
        }
        ClientSectionTitle(stringResource(R.string.filter_files))
        ClientGroup {
            FileTypeFilter.entries.forEach { filter ->
                ClientRow(stringResource(when (filter) {
                    FileTypeFilter.ALL -> R.string.show_all_items
                    FileTypeFilter.FOLDERS -> R.string.show_folders_only
                    FileTypeFilter.FILES -> R.string.show_files_only
                }), if (state.fileBrowser.typeFilter == filter) Icons.Outlined.Check else Icons.Outlined.FilterList) { model.changeFileFilter(filter) }
            }
        }
        ClientRow(stringResource(if (state.fileBrowser.viewMode == FileViewMode.LIST) R.string.switch_to_grid else R.string.switch_to_list),
            Icons.Outlined.GridView) {
            model.changeFileViewMode(if (state.fileBrowser.viewMode == FileViewMode.LIST) FileViewMode.GRID else FileViewMode.LIST)
            onDismiss()
        }
        ClientSectionTitle(stringResource(R.string.client_file_locations))
        ClientGroup {
            state.fileBrowser.pathHistory.asReversed().forEach { path ->
                ClientRow(if (path.isBlank()) stringResource(R.string.shared_folders) else path.substringAfterLast('/'),
                    Icons.Outlined.FolderOpen) { onDismiss(); model.navigateToFilePath(path) }
            }
            if (state.supportsFavorites) ClientRow(stringResource(R.string.open_favorites), Icons.Outlined.StarOutline) { onDismiss(); model.loadFileFavorites() }
            ClientRow(stringResource(R.string.open_recent_locations), Icons.Outlined.History) { onDismiss(); model.loadFileRecentLocations() }
            if (state.supportsRemoteLocations) ClientRow(stringResource(R.string.open_remote_locations), Icons.Outlined.FolderOpen) { onDismiss(); model.loadFileRemoteLocations() }
            if (state.supportsSharing) ClientRow(stringResource(R.string.manage_share_links), Icons.Outlined.Link, onClick = onShareLinks)
        }
    }
}
