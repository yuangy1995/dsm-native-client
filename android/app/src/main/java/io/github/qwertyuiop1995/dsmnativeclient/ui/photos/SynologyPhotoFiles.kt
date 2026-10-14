package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

@Composable
internal fun SynologyPhotoFiles(model: SynologyPhotoFileModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    val title = if (state.recordsPage) R.string.sp_files_records else state.draft?.checkpoint?.action?.fileLabel() ?: R.string.sp_files_manage
    ClientPageDialog(stringResource(title), model::dismiss) {
        Column(Modifier.fillMaxSize()) {
            state.error?.let { Text(photoFileError(it), Modifier.fillMaxWidth().padding(16.dp), color = MaterialTheme.colorScheme.error) }
            when {
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                state.recordsPage -> FileRecords(state, model)
                state.draft == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Button(onClick = { model.load() }) { Text(stringResource(R.string.sp_retry)) }
                }
                else -> FileForm(state, model)
            }
        }
    }
}

@Composable
private fun ColumnScope.FileForm(state: SynologyPhotoFileState, model: SynologyPhotoFileModel) {
    val row = state.draft!!.checkpoint; val files = row.files!!
    val deletion = row.action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS
    val busy = state.working || state.recovering
    var selection by remember(row.operationId) { mutableStateOf(false) }
    var overwrite by remember(row.operationId) { mutableStateOf(false) }
    if (!deletion) {
        if (model.destinationSpaces.size > 1) Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            model.destinationSpaces.forEach { space -> FilterChip(state.browseSpace == space,
                onClick = { model.browseRoot(space) }, enabled = !busy && !state.browsing,
                label = { Text(stringResource(if (space == SynologyPhotoSpace.PERSONAL) R.string.sp_source_personal else R.string.sp_source_shared)) }) }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { model.backTo(state.path.lastIndex - 1) }, enabled = state.path.size > 1 && !busy && !state.browsing) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.go_up))
            }
            PhotoFolderPath(state.path, !busy && !state.browsing, Modifier.weight(1f), model::backTo)
        }
    }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_files_form"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            if (deletion) {
                Text(stringResource(R.string.sp_files_selection_count, row.targets.size, files.folders.size), style = MaterialTheme.typography.titleSmall)
                Text(stringResource(R.string.sp_files_delete_warning), Modifier.padding(top = 12.dp), color = MaterialTheme.colorScheme.error)
            } else OutlinedButton(onClick = { selection = true }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.sp_files_selection_count, row.targets.size, files.folders.size))
            }
        }
        if (deletion) {
            items(files.folders, key = { "selected-folder:${it.id}" }) { Text(it.name, style = MaterialTheme.typography.titleSmall) }
            items(row.targets, key = { "selected-photo:${it.id}" }) { Text(it.filename) }
        } else {
            item { SharingChoice(stringResource(R.string.sp_files_duplicates), stringResource(files.duplicate!!.fileLabel()),
                SynologyPhotoTransferDuplicate.entries.map { it to stringResource(it.fileLabel()) }, !busy, "photos_files_duplicate", model::duplicate) }
            items(state.children, key = { it.id }) { folder ->
                OutlinedButton(onClick = { model.enter(folder) }, enabled = !busy && !state.browsing,
                    modifier = Modifier.fillMaxWidth().testTag("photos_files_target_${folder.id}")) {
                    Icon(Icons.Outlined.Folder, null); Text(folder.name, Modifier.weight(1f).padding(start = 8.dp), maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
            if (state.browsing) item { Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
            state.browseError?.let { error -> item {
                Text(photoFileError(error), color = MaterialTheme.colorScheme.error)
                Button(onClick = { model.browse() }, enabled = !state.browsing) { Text(stringResource(R.string.sp_retry)) }
            } }
            if (!state.browsing && state.browseError == null) {
                if (state.children.isEmpty()) item { Text(stringResource(R.string.sp_files_no_children)) }
                if (!model.canSave) item { Text(stringResource(R.string.sp_files_invalid_destination)) }
            }
            if (state.more) item { OutlinedButton(onClick = { model.browse(more = true) }, enabled = !state.browsing && !busy,
                modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.sp_library_more_collections)) } }
        }
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
        Button(onClick = { if (files.duplicate == SynologyPhotoTransferDuplicate.OVERWRITE) overwrite = true else model.save() },
            enabled = model.canSave, modifier = Modifier.testTag("photos_files_save")) { Text(stringResource(row.action.fileLabel())) }
    }
    if (selection) AlertDialog(onDismissRequest = { selection = false }, title = { Text(stringResource(R.string.sp_files_selection)) },
        text = { LazyColumn(Modifier.fillMaxWidth().heightIn(max = 400.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(files.folders, key = { "folder:${it.id}" }) { Text(it.name) }
            items(row.targets, key = { "photo:${it.id}" }) { Text(it.filename) }
        } }, confirmButton = { TextButton(onClick = { selection = false }) { Text(stringResource(R.string.close)) } })
    if (overwrite) AlertDialog(onDismissRequest = { overwrite = false }, title = { Text(stringResource(R.string.sp_files_overwrite_title)) },
        text = { Text(stringResource(R.string.sp_files_overwrite_warning, state.folderAccess?.folder?.path.orEmpty())) },
        confirmButton = { TextButton(onClick = { overwrite = false; model.save(overwriteConfirmed = true) }, modifier = Modifier.testTag("photos_files_confirm_overwrite")) { Text(stringResource(R.string.sp_files_replace)) } },
        dismissButton = { TextButton(onClick = { overwrite = false }) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun FileRecords(state: SynologyPhotoFileState, model: SynologyPhotoFileModel) {
    val busy = state.working || state.recovering
    LazyColumn(Modifier.fillMaxSize().testTag("photos_files_records"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (state.records.isEmpty() && !busy) item { Text(stringResource(R.string.sp_files_no_records)) }
        items(state.records, key = { it.id }) { record ->
            val row = record.checkpoint; val files = row.files!!
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(row.action.fileLabel()), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.sp_files_selection_count, row.targets.size, files.folders.size))
                files.destination?.let { Text(it.path) }
                Text(stringResource(when {
                    row.phase == SynologyPhotoAlbumPhase.PARTIAL -> R.string.sp_files_partial
                    row.finished -> when (row.action) {
                        SynologyPhotoAlbumAction.MOVE_ITEMS -> R.string.sp_files_moved
                        SynologyPhotoAlbumAction.COPY_ITEMS -> R.string.sp_files_copied
                        else -> R.string.sp_files_deleted
                    }
                    !row.submitted -> R.string.sp_request_not_sent
                    files.taskId == null -> R.string.sp_files_unknown
                    else -> R.string.sp_files_pending
                }))
                if (busy && state.activeId == record.id) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (!row.finished && (!row.submitted || files.taskId != null)) Button(onClick = { model.resume(record.id) }, enabled = !busy,
                    modifier = Modifier.testTag("photos_files_resume")) { Text(stringResource(if (row.submitted) R.string.sp_edit_refresh else R.string.sp_request_reopen)) }
                if (row.finished || !row.submitted) TextButton(onClick = { model.discard(record.id) }, enabled = !busy) { Text(stringResource(R.string.sp_edit_clear_record)) }
                HorizontalDivider()
            }
        }
    }
}

internal fun SynologyPhotoAlbumAction.fileLabel() = when (this) {
    SynologyPhotoAlbumAction.MOVE_ITEMS -> R.string.sp_files_move
    SynologyPhotoAlbumAction.COPY_ITEMS -> R.string.sp_files_copy
    SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS -> R.string.sp_files_delete
    else -> R.string.sp_files_manage
}

@Composable
internal fun PhotoFileMenuItems(model: SynologyPhotoFileModel, photos: List<SynologyPhoto>, folders: List<SynologyPhotoCollection>, close: () -> Unit) {
    val actions = buildList {
        if (model.canTransfer) addAll(listOf(SynologyPhotoAlbumAction.MOVE_ITEMS, SynologyPhotoAlbumAction.COPY_ITEMS))
        if (model.canDelete && folders.isNotEmpty()) add(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS)
    }
    actions.forEach { action -> DropdownMenuItem(text = { Text(stringResource(action.fileLabel())) },
        onClick = { close(); model.open(action, photos, folders) }) }
}
private fun SynologyPhotoTransferDuplicate.fileLabel() = if (this == SynologyPhotoTransferDuplicate.SKIP) R.string.sp_files_skip else R.string.sp_files_replace
@Composable
private fun photoFileError(error: Throwable) = stringResource(when {
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.STORAGE -> R.string.sp_album_storage_failed
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.PENDING -> R.string.sp_files_conflict
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.BUSY -> R.string.sp_edit_busy
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.PERMISSION -> R.string.sp_files_permission
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_files_changed
    else -> R.string.sp_files_failed
})
