package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun SharedInputSurface(feature: SharedInputModel, connections: List<WorkspaceConnectionItem>) {
    val state by feature.state.collectAsStateWithLifecycle()
    if (!state.visible) {
        if (state.batches.isNotEmpty() || state.notice != null || state.copying) Box(Modifier.fillMaxSize().safeDrawingPadding()) {
            FilledTonalButton(feature::show, Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 84.dp)
                .heightIn(min = 48.dp).testTag("shared_open")) {
                Icon(Icons.Outlined.UploadFile, null)
                Text(stringResource(R.string.shared_files), Modifier.padding(start = 8.dp))
            }
        }
        return
    }
    SharedInputContent(state, connections, feature::hide, feature::selectConnection, feature::filter,
        feature::up, feature::enter, feature::retry, feature::more, { feature.send() }, feature::discard)
    if (state.conflicts != null && !state.busy) AlertDialog(onDismissRequest = feature::dismissConflict,
        title = { Text(stringResource(R.string.replace_upload_conflicts_title)) },
        text = { Text(stringResource(R.string.replace_upload_conflicts_message, state.conflicts!!.size)) },
        confirmButton = { TextButton({ feature.send(replace = true) }, Modifier.heightIn(min = 48.dp).testTag("shared_replace")) { Text(stringResource(R.string.replace_existing)) } },
        dismissButton = { TextButton(feature::dismissConflict, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) } })
}

@Composable
internal fun SharedInputContent(
    state: SharedInputState, connections: List<WorkspaceConnectionItem>, close: () -> Unit,
    select: (String) -> Unit, filter: (String) -> Unit, up: () -> Unit, enter: (FileItem) -> Unit,
    retry: () -> Unit, more: () -> Unit, send: () -> Unit, discard: () -> Unit,
) {
    val enabled = !state.busy && !state.copying
    ClientPageDialog(stringResource(R.string.shared_files), { if (enabled) close() }) {
        Column(Modifier.fillMaxSize().testTag("shared_dialog")) {
            if (state.copying || state.busy || state.loadingMore) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.notice?.let { Text(stringResource(it), Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            state.failure?.let { Text(it.localize(LocalContext.current).combined, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) }
            val batch = state.batch
            if (batch == null) {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    if (state.copying) Text(stringResource(R.string.shared_copying))
                    else EmptyState(stringResource(R.string.shared_empty), stringResource(R.string.shared_empty_hint), Icons.Outlined.UploadFile)
                }
                TextButton(close, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = enabled) { Text(stringResource(R.string.close)) }
            } else {
                Text(pluralStringResource(R.plurals.shared_file_count, batch.files.size, batch.files.size),
                    Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.titleMedium)
                Text(batch.files.joinToString { it.name }, Modifier.padding(horizontal = 16.dp), maxLines = 2, overflow = TextOverflow.Ellipsis)
                var choosingConnection by remember(state.profileId) { mutableStateOf(state.profileId == null) }
                val connection = connections.singleOrNull { it.profile.id == state.profileId }
                if (choosingConnection || connection == null) {
                    Text(stringResource(R.string.shared_choose_connection), Modifier.padding(16.dp), style = MaterialTheme.typography.titleSmall)
                    if (connections.isEmpty()) Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) {
                        Text(stringResource(R.string.shared_sign_in_first), Modifier.padding(24.dp))
                    } else LazyColumn(Modifier.weight(1f).testTag("shared_connections")) {
                        items(connections, key = { it.profile.id }) { item -> ClientGroup {
                            ClientRow(connectionConfirmationName(item.profile, connections), Icons.Outlined.Folder,
                                enabled = enabled) { choosingConnection = false; select(item.profile.id) }
                        } }
                    }
                } else {
                    TextButton({ choosingConnection = true }, Modifier.padding(horizontal = 8.dp).heightIn(min = 48.dp), enabled = enabled) {
                        Text(connectionConfirmationName(connection.profile, connections))
                    }
                    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconButton(up, enabled = enabled && state.path.isNotEmpty() && state.locations !is Loadable.Loading) {
                            Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.go_up))
                        }
                        Text(state.path.ifEmpty { stringResource(R.string.shared_folders) }, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    ClientSearchField(state.filter, filter, stringResource(R.string.file_search_filter_folders), Modifier.padding(horizontal = 12.dp, vertical = 8.dp))
                    val page = (state.locations as? Loadable.Ready)?.value
                    val rows = page?.items?.filter { it.name.contains(state.filter, ignoreCase = true) }.orEmpty()
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        PageStateContent(state.locations.toPageUiState(isEmpty = { it.items.isEmpty() }, isFilteredEmpty = { it.items.isNotEmpty() && rows.isEmpty() }),
                            emptyTitle = stringResource(R.string.file_search_no_folders), emptyMessage = stringResource(R.string.shared_folder_empty_hint), emptyIcon = Icons.Outlined.Folder,
                            filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.Folder,
                            onRetry = retry) {
                            LazyColumn(Modifier.fillMaxSize().testTag("shared_folders")) {
                                items(rows, key = FileItem::path) { folder ->
                                    ListItem(headlineContent = { Text(folder.name) }, leadingContent = { Icon(Icons.Outlined.Folder, null) },
                                        modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(enabled && folder.canRead, role = Role.Button) { enter(folder) })
                                }
                            }
                        }
                    }
                    if (page != null && page.items.size < page.total) TextButton(more, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = enabled && !state.loadingMore) { Text(stringResource(R.string.load_more_files)) }
                    if (state.folder != null && !state.canUpload) Text(stringResource(R.string.shared_folder_read_only), Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Button(send, Modifier.fillMaxWidth().padding(horizontal = 16.dp).heightIn(min = 48.dp).testTag("shared_send"),
                        enabled = enabled && state.canUpload && state.locations is Loadable.Ready && !state.loadingMore) { Text(stringResource(R.string.shared_upload_here)) }
                }
                Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(discard, Modifier.weight(1f).heightIn(min = 48.dp).testTag("shared_discard"), enabled = enabled) { Text(stringResource(R.string.shared_discard)) }
                    OutlinedButton(close, Modifier.weight(1f).heightIn(min = 48.dp), enabled = enabled) { Text(stringResource(R.string.shared_later)) }
                }
            }
        }
    }
}
