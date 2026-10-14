package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.InsertDriveFile
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileVFSBrowser(feature: FileVFSFeatureModel, state: FileVFSState, onDownload: (FileVFSDownloadSource) -> Unit) {
    ClientPageDialog(state.baseline?.alias.orEmpty(), feature::browserBack) {
        Column(Modifier.fillMaxSize().testTag("vfs_browser")) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()).testTag("vfs_breadcrumbs")) {
                    state.locations.forEachIndexed { index, location ->
                        if (index == state.locations.lastIndex) Box(Modifier.heightIn(min = 48.dp).padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
                            Text(location.title, style = MaterialTheme.typography.labelLarge)
                        } else TextButton({ feature.location(index) }, Modifier.heightIn(min = 48.dp).testTag("vfs_location_$index")) { Text(location.title) }
                    }
                }
                TextButton({ feature.loadFolder() }, Modifier.heightIn(min = 48.dp).testTag("vfs_folder_refresh"), enabled = state.files !is Loadable.Loading) {
                    Text(stringResource(R.string.refresh))
                }
            }
            ClientSearchField(state.filter, feature::filter, stringResource(R.string.vfs_file_filter), Modifier.padding(12.dp).testTag("vfs_files_filter"))
            val page = (state.files as? Loadable.Ready)?.value
            val rows = page?.items.orEmpty().filter { it.name.contains(state.filter, true) }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                PageStateContent(state.files.toPageUiState(isEmpty = { it.items.isEmpty() }, isFilteredEmpty = { it.items.isNotEmpty() && rows.isEmpty() }),
                    emptyTitle = stringResource(R.string.vfs_files_empty), emptyMessage = stringResource(R.string.vfs_files_empty_hint), emptyIcon = Icons.Outlined.FolderOpen,
                    filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint),
                    filteredEmptyIcon = Icons.Outlined.FolderOpen, onRetry = { feature.loadFolder() }) {
                    LazyColumn(Modifier.fillMaxSize().testTag("vfs_files"), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(rows, key = FileItem::path) { item ->
                            ClientGroup {
                                if (item.isDirectory) ClientRow(item.name, Icons.Outlined.FolderOpen, enabled = item.canRead, onClick = { feature.enter(item) })
                                else Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Outlined.InsertDriveFile, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text(item.name, Modifier.weight(1f).padding(horizontal = 12.dp))
                                    val description = stringResource(R.string.vfs_download_item, item.name)
                                    IconButton({ feature.downloadSource(item)?.let(onDownload) }, Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                                        .testTag("vfs_download").semantics { contentDescription = description }, enabled = item.canRead) { Icon(Icons.Outlined.Download, null) }
                                }
                            }
                        }
                    }
                }
            }
            if (state.loadingMore) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.nextPageFailure?.takeIf { state.files is Loadable.Ready }?.let {
                Text(it.localize(LocalContext.current).combined, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error)
            }
            if (page != null && page.items.size < page.total) OutlinedButton({ feature.loadFolder(true) }, Modifier.fillMaxWidth().padding(12.dp).heightIn(min = 48.dp)
                .testTag("vfs_more"), enabled = !state.loadingMore) { Text(stringResource(R.string.load_more_files)) }
        }
    }
}
