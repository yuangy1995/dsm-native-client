package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileArchiveBrowserDialog(feature: FileArchiveFeatureModel, state: FileArchiveState) {
    ClientPageDialog(stringResource(R.string.archive_browse_contents), feature::closeBrowser) {
        val focus = LocalFocusManager.current
        val keyboard = LocalSoftwareKeyboardController.current
        val finishInput = { focus.clearFocus(); keyboard?.hide(); Unit }
        Column(Modifier.fillMaxSize().testTag("archive_browser")) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton({ finishInput(); feature.up() }, enabled = state.parents.isNotEmpty() && state.page !is Loadable.Loading && !state.loadingMore) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.go_up))
                }
                Text(state.parents.lastOrNull()?.path ?: state.source?.name.orEmpty(), Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            ClientSearchField(state.filter, feature::filter, stringResource(R.string.archive_filter_displayed), Modifier.padding(12.dp).testTag("archive_filter"))
            val page = (state.page as? Loadable.Ready)?.value
            val visible = page?.items?.filter { it.name.contains(state.filter, ignoreCase = true) }.orEmpty()
            Box(Modifier.weight(1f).fillMaxWidth()) {
                PageStateContent(state.page.toPageUiState(isEmpty = { it.items.isEmpty() }, isFilteredEmpty = { it.items.isNotEmpty() && visible.isEmpty() }),
                    emptyTitle = stringResource(R.string.archive_contents_empty), emptyMessage = stringResource(R.string.archive_contents_empty_hint), emptyIcon = Icons.Outlined.Folder,
                    filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.Folder,
                    onRetry = { finishInput(); feature.retry() }) {
                    LazyColumn(Modifier.fillMaxSize().testTag("archive_entries")) {
                        items(visible, key = ArchiveItem::id) { item ->
                            Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).testTag("archive_entry_${item.id}")
                                .toggleable(item.id in state.selected, role = Role.Checkbox, onValueChange = { feature.toggle(item) }).padding(horizontal = 12.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(item.id in state.selected, onCheckedChange = null)
                                Icon(if (item.isDirectory) Icons.Outlined.Folder else Icons.Outlined.Description, null)
                                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                                    Text(item.name)
                                    item.size?.takeUnless { item.isDirectory }?.let { Text(formatBytes(it), style = MaterialTheme.typography.bodySmall) }
                                }
                                if (item.isDirectory) IconButton({ finishInput(); feature.enter(item) }, enabled = !state.loadingMore) {
                                    Icon(Icons.Outlined.FolderOpen, stringResource(R.string.archive_open_folder, item.name))
                                }
                            }
                        }
                    }
                }
            }
            state.moreFailure?.let { Text(it.localize(LocalContext.current).combined, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
            if (page?.hasMore == true) {
                if (state.loadingMore) LinearProgressIndicator(Modifier.fillMaxWidth())
                else TextButton({ finishInput(); feature.more() }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("archive_more")) { Text(stringResource(R.string.archive_more_contents)) }
            }
            Button(feature::closeBrowser, Modifier.fillMaxWidth().padding(12.dp).heightIn(min = 48.dp).testTag("archive_use_selection")) {
                Text(if (state.extractAll) stringResource(R.string.close) else pluralStringResource(R.plurals.archive_use_selection, state.selected.size, state.selected.size))
            }
        }
    }
}

@Composable
internal fun FileArchiveDestinationDialog(feature: FileArchiveFeatureModel, state: FileArchiveState) {
    ClientPageDialog(stringResource(R.string.archive_choose_destination), feature::closeLocations) {
        val focus = LocalFocusManager.current
        val keyboard = LocalSoftwareKeyboardController.current
        val finishInput = { focus.clearFocus(); keyboard?.hide(); Unit }
        Column(Modifier.fillMaxSize().testTag("archive_locations")) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton({ finishInput(); feature.locationUp() }, enabled = state.locationPath.isNotEmpty()) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.go_up)) }
                Text(state.locationPath.ifEmpty { stringResource(R.string.shared_folders) }, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            ClientSearchField(state.locationFilter, feature::filterLocations, stringResource(R.string.file_search_filter_folders), Modifier.padding(12.dp))
            val visible = (state.locations as? Loadable.Ready)?.value?.filter { it.name.contains(state.locationFilter, ignoreCase = true) }.orEmpty()
            Box(Modifier.weight(1f).fillMaxWidth()) {
                PageStateContent(state.locations.toPageUiState(isEmpty = { it.isEmpty() }, isFilteredEmpty = { it.isNotEmpty() && visible.isEmpty() }),
                    emptyTitle = stringResource(R.string.file_search_no_folders), emptyMessage = stringResource(R.string.archive_destination_empty_hint), emptyIcon = Icons.Outlined.Folder,
                    filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.Folder,
                    onRetry = { finishInput(); feature.retryLocations() }) {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(visible, key = FileItem::path) { item ->
                            ListItem(headlineContent = { Text(item.name) }, leadingContent = { Icon(Icons.Outlined.Folder, null) },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(enabled = item.canRead, role = Role.Button) { finishInput(); feature.enterLocation(item) })
                        }
                    }
                }
            }
            if (state.location?.canWrite == false) Text(stringResource(R.string.archive_choose_writable_destination), Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error)
            Button({ finishInput(); feature.chooseLocation() }, Modifier.fillMaxWidth().padding(12.dp).heightIn(min = 48.dp).testTag("archive_choose_location"),
                enabled = state.location?.canWrite == true && state.locations is Loadable.Ready) { Text(stringResource(R.string.file_search_use_folder)) }
        }
    }
}
