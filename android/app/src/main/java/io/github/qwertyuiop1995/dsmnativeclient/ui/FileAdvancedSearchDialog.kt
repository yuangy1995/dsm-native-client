package io.github.qwertyuiop1995.dsmnativeclient.ui

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import java.text.DateFormat
import java.util.Calendar

@Composable
internal fun FileSearchControls(state: WorkspaceState, feature: FileSearchFeatureModel, onClose: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        ClientSearchField(state.fileBrowser.searchQuery, feature::updateQuery,
            stringResource(R.string.client_search_files), Modifier.weight(1f).testTag("file_search_query"), onSearch = feature::submitQuery)
        IconButton(feature::open) { Icon(Icons.Outlined.Tune, stringResource(R.string.file_search_advanced)) }
        IconButton({ feature.clearSearch(); onClose() }) { Icon(Icons.Outlined.Close, stringResource(R.string.close)) }
    }
    if (state.fileBrowser.activeSearchQuery != null && state.files is Loadable.Loading) {
        TextButton({ feature.clearSearch(); onClose() }, Modifier.padding(horizontal = 12.dp).heightIn(min = 48.dp)) { Text(stringResource(R.string.file_search_cancel)) }
    }
    if (state.fileSearchCoverage == FileSearchIndexCoverage.INCOMPLETE) {
        Text(stringResource(R.string.file_search_index_incomplete), Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
internal fun FileAdvancedSearchSheet(feature: FileSearchFeatureModel) {
    val state by feature.editor.collectAsStateWithLifecycle()
    if (!state.visible) return
    if (state.locationsVisible) {
        FileSearchLocationsPage(state, feature)
        return
    }
    val draft = state.draft
    val request = draft.request
    val nameError = request.nameError?.let { DsmFailure(null, "", "", kind = it).localize(LocalContext.current).combined }
    ClientSheet(stringResource(R.string.file_search_advanced), feature::close, Modifier.testTag("file_search_editor")) {
        OutlinedTextField(request.name, { value -> feature.edit { it.copy(request = it.request.copy(name = value)) } },
            Modifier.fillMaxWidth().testTag("file_search_keyword"), singleLine = true, label = { Text(stringResource(R.string.file_search_keyword)) },
            isError = nameError != null, supportingText = nameError?.let { message -> { Text(message) } })
        SearchToggle(stringResource(R.string.file_search_contents), request.searchesContents) { value -> feature.edit { it.copy(request = it.request.copy(searchesContents = value)) } }
        ClientSectionTitle(stringResource(R.string.file_search_scope))
        request.folders.forEach { path ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(path, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                IconButton({ feature.removeLocation(path) }) { Icon(Icons.Outlined.Close, stringResource(R.string.file_search_remove_folder, path)) }
            }
        }
        TextButton(feature::openLocations, Modifier.heightIn(min = 48.dp).testTag("file_search_add_location")) {
            Icon(Icons.Outlined.Add, null); Text(stringResource(R.string.file_search_add_folder), Modifier.padding(start = 8.dp))
        }
        SearchToggle(stringResource(R.string.file_search_subfolders), request.recursive) { value -> feature.edit { it.copy(request = it.request.copy(recursive = value)) } }
        ClientSectionTitle(stringResource(R.string.file_search_type))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FileSearchKind.entries.forEach { kind ->
                FilterChip(request.kind == kind, { feature.edit { it.copy(request = it.request.copy(kind = kind)) } }, label = {
                    Text(stringResource(when (kind) { FileSearchKind.ALL -> R.string.show_all_items; FileSearchKind.FILE -> R.string.show_files_only; FileSearchKind.DIRECTORY -> R.string.show_folders_only }))
                })
            }
        }
        OutlinedTextField(request.extension, { value -> feature.edit { it.copy(request = it.request.copy(extension = value.replace('，', ',').replace('、', ','))) } },
            Modifier.fillMaxWidth().testTag("file_search_extension"), singleLine = true, label = { Text(stringResource(R.string.file_search_extension)) })
        ClientSectionTitle(stringResource(R.string.file_search_size))
        SearchPair(
            first = { SearchSizeField(draft.minimumSize, R.string.file_search_minimum, "file_search_minimum") { value -> feature.edit { it.copy(minimumSize = value) } } },
            second = { SearchSizeField(draft.maximumSize, R.string.file_search_maximum, "file_search_maximum") { value -> feature.edit { it.copy(maximumSize = value) } } },
        )
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FileSearchSizeUnit.entries.forEach { unit -> FilterChip(draft.sizeUnit == unit, { feature.edit { it.copy(sizeUnit = unit) } }, label = {
                Text(stringResource(when (unit) { FileSearchSizeUnit.BYTES -> R.string.file_search_bytes; FileSearchSizeUnit.MIB -> R.string.file_search_mib; FileSearchSizeUnit.GIB -> R.string.file_search_gib }))
            }) }
        }
        ClientSectionTitle(stringResource(R.string.file_search_dates))
        SearchDateRange(R.string.file_search_modified, request.modified) { value -> feature.edit { it.copy(request = it.request.copy(modified = value)) } }
        SearchDateRange(R.string.file_search_created, request.created) { value -> feature.edit { it.copy(request = it.request.copy(created = value)) } }
        SearchDateRange(R.string.file_search_accessed, request.accessed) { value -> feature.edit { it.copy(request = it.request.copy(accessed = value)) } }
        SearchPair(
            first = { OutlinedTextField(request.owner, { value -> feature.edit { it.copy(request = it.request.copy(owner = value)) } }, Modifier.fillMaxWidth(), singleLine = true, label = { Text(stringResource(R.string.file_search_owner)) }) },
            second = { OutlinedTextField(request.group, { value -> feature.edit { it.copy(request = it.request.copy(group = value)) } }, Modifier.fillMaxWidth(), singleLine = true, label = { Text(stringResource(R.string.file_search_group)) }) },
        )
        if (draft.resolved() == null && nameError == null) Text(stringResource(R.string.file_search_invalid_recovery), color = MaterialTheme.colorScheme.error)
        state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(feature::reset, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.file_search_reset)) }
            Button(feature::apply, Modifier.heightIn(min = 48.dp).testTag("file_search_apply"), enabled = draft.resolved() != null) { Text(stringResource(R.string.submit_file_search)) }
        }
    }
}

@Composable
private fun SearchToggle(label: String, checked: Boolean, onChanged: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(checked, role = Role.Checkbox, onValueChange = onChanged), verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked, onCheckedChange = null); Text(label, Modifier.weight(1f).padding(start = 8.dp))
    }
}

@Composable
private fun SearchSizeField(value: String, label: Int, tag: String, onChanged: (String) -> Unit) {
    OutlinedTextField(value, onChanged, Modifier.fillMaxWidth().testTag(tag), singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), label = { Text(stringResource(label)) })
}

@Composable
private fun SearchPair(first: @Composable () -> Unit, second: @Composable () -> Unit) {
    val fontScale = LocalDensity.current.fontScale
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        if (maxWidth >= 440.dp && fontScale < 1.5f) Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.weight(1f)) { first() }; Box(Modifier.weight(1f)) { second() }
        } else Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { first(); second() }
    }
}

@Composable
private fun SearchDateRange(label: Int, range: FileSearchTimeRange, onChanged: (FileSearchTimeRange) -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Text(stringResource(label), style = MaterialTheme.typography.titleSmall)
        SearchDateBound(R.string.file_search_after, range.fromEpochSeconds) { onChanged(range.copy(fromEpochSeconds = it)) }
        SearchDateBound(R.string.file_search_before, range.toEpochSeconds) { onChanged(range.copy(toEpochSeconds = it)) }
    }
}

@Composable
private fun SearchDateBound(label: Int, seconds: Long?, onChanged: (Long?) -> Unit) {
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val text = seconds?.let { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, context.resources.configuration.locales[0]).format(java.util.Date(it * 1_000)) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        TextButton({
            focus.clearFocus(); keyboard?.hide()
            val initial = Calendar.getInstance().apply { seconds?.let { timeInMillis = it * 1_000 } }
            DatePickerDialog(context, { _, year, month, day ->
                TimePickerDialog(context, { _, hour, minute ->
                    val value = Calendar.getInstance().apply { set(year, month, day, hour, minute, 0); set(Calendar.MILLISECOND, 0) }
                    onChanged(value.timeInMillis / 1_000)
                }, initial.get(Calendar.HOUR_OF_DAY), initial.get(Calendar.MINUTE), android.text.format.DateFormat.is24HourFormat(context)).show()
            }, initial.get(Calendar.YEAR), initial.get(Calendar.MONTH), initial.get(Calendar.DAY_OF_MONTH)).apply { datePicker.minDate = 0 }.show()
        }, Modifier.weight(1f).heightIn(min = 48.dp)) {
            Text(if (text == null) stringResource(label) else stringResource(R.string.file_search_date_value, stringResource(label), text))
        }
        if (seconds != null) IconButton({ onChanged(null) }) { Icon(Icons.Outlined.Close, stringResource(R.string.file_search_remove_date, stringResource(label))) }
    }
}

@Composable
private fun FileSearchLocationsPage(state: FileSearchEditorState, feature: FileSearchFeatureModel) {
    ClientPageDialog(stringResource(R.string.file_search_add_folder), feature::closeLocations) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(feature::locationUp, enabled = state.locationPath.isNotBlank()) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.go_up)) }
                Text(state.locationPath.ifBlank { stringResource(R.string.shared_folders) }, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            ClientSearchField(state.locationFilter, feature::filterLocations, stringResource(R.string.file_search_filter_folders), Modifier.fillMaxWidth().padding(12.dp))
            val visible = (state.locations as? Loadable.Ready)?.value?.filter { it.name.contains(state.locationFilter, ignoreCase = true) }.orEmpty()
            Box(Modifier.weight(1f).fillMaxWidth()) {
                PageStateContent(
                    state = state.locations.toPageUiState(isEmpty = { it.isEmpty() }, isFilteredEmpty = { it.isNotEmpty() && visible.isEmpty() }),
                    emptyTitle = stringResource(R.string.file_search_no_folders), emptyMessage = stringResource(R.string.file_search_no_folders_hint), emptyIcon = Icons.Outlined.Folder,
                    filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.Folder,
                    onRetry = feature::retryLocations,
                ) {
                    LazyColumn(Modifier.fillMaxSize().testTag("file_search_locations")) {
                        items(visible, key = FileItem::path) { item ->
                            ListItem(headlineContent = { Text(item.name) }, leadingContent = { Icon(Icons.Outlined.Folder, null) },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(enabled = item.canRead, role = Role.Button) { feature.enterLocation(item) })
                        }
                    }
                }
            }
            Button(feature::addLocation, Modifier.fillMaxWidth().padding(16.dp).heightIn(min = 48.dp).testTag("file_search_choose_location"),
                enabled = state.locationPath.isNotBlank() && state.locations is Loadable.Ready) { Text(stringResource(R.string.file_search_use_folder)) }
        }
    }
}
