package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileISOMountDestinationDialog(feature: FileISOMountFeatureModel, state: FileISOMountState) {
    FileMountDestinationDialog(FileMountDestinationState(state.locationPath, state.location, state.locations, state.locationFilter),
        prefix = "iso", canChoose = feature.canChooseLocation(), close = feature::closeLocations, up = feature::locationUp,
        filter = feature::filterLocations, retry = feature::retryLocations, enter = feature::enterLocation, choose = feature::chooseLocation)
}

@Composable
internal fun FileMountDestinationDialog(state: FileMountDestinationState, prefix: String, canChoose: Boolean,
    close: () -> Unit, up: () -> Unit, filter: (String) -> Unit, retry: () -> Unit, enter: (FileItem) -> Unit, choose: () -> Unit) {
    ClientPageDialog(stringResource(R.string.iso_choose_destination), close) {
        val focus = LocalFocusManager.current
        val keyboard = LocalSoftwareKeyboardController.current
        val finishInput = { focus.clearFocus(); keyboard?.hide(); Unit }
        Column(Modifier.fillMaxSize().testTag("${prefix}_locations")) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton({ finishInput(); up() }, enabled = state.path.isNotEmpty()) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.go_up)) }
                Text(state.path.ifEmpty { stringResource(R.string.shared_folders) }, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            ClientSearchField(state.filter, filter, stringResource(R.string.file_search_filter_folders), Modifier.padding(12.dp).testTag("${prefix}_location_filter"))
            val visible = (state.items as? Loadable.Ready)?.value?.filter { it.name.contains(state.filter, true) }.orEmpty()
            Box(Modifier.weight(1f).fillMaxWidth()) {
                PageStateContent(state.items.toPageUiState(isEmpty = { it.isEmpty() }, isFilteredEmpty = { it.isNotEmpty() && visible.isEmpty() }),
                    emptyTitle = stringResource(R.string.file_search_no_folders), emptyMessage = stringResource(R.string.iso_choose_empty_hint), emptyIcon = Icons.Outlined.Folder,
                    filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.Folder,
                    onRetry = { finishInput(); retry() }) {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(visible, key = FileItem::path) { item ->
                            ListItem(headlineContent = { Text(item.name) }, leadingContent = { Icon(Icons.Outlined.Folder, null) },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).testTag("${prefix}_location_${item.name}")
                                    .clickable(enabled = item.canRead, role = Role.Button) { finishInput(); enter(item) })
                        }
                    }
                }
            }
            if (state.item?.canWrite == false) Text(stringResource(R.string.archive_choose_writable_destination), Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error)
            Button({ finishInput(); choose() }, Modifier.fillMaxWidth().padding(12.dp).heightIn(min = 48.dp).testTag("${prefix}_choose_location"),
                enabled = canChoose) { Text(stringResource(R.string.file_search_use_folder)) }
        }
    }
}
