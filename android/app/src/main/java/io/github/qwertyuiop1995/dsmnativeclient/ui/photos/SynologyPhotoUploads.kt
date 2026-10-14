package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun SynologyPhotoUploads(library: SynologyPhotosState, model: SynologyPhotoUploadModel) {
    val state by model.state.collectAsState()
    val context = LocalContext.current.applicationContext
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) model.receiveSelection { photoUploadSources(context, uris) }
    }
    val folder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) model.receiveSelection { photoUploadFolderSources(context, uri) }
    }
    if (!state.visible) return
    ClientPageDialog(stringResource(R.string.sp_upload_title), model::dismiss) {
        Column(Modifier.fillMaxSize().testTag("photos_upload_dialog")) {
            if (state.loading || state.albumsLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.error?.let { error ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text(photoUploadError(error), color = MaterialTheme.colorScheme.error)
                    if (state.draft?.duplicate == null) TextButton(onClick = { model.loadSettings() }) { Text(stringResource(R.string.sp_retry)) }
                }
            }
            when {
                state.importing -> PhotoImportProgress(state, model::pause)
                state.draft != null -> PhotoUploadForm(library, state, model,
                    onFiles = { if (model.preparePicker()) files.launch(arrayOf("image/*", "video/*")) },
                    onFolder = { if (model.preparePicker()) folder.launch(null) })
                state.selected != null -> PhotoUploadBatch(state.selected!!, state, model)
                else -> PhotoUploadQueue(state, model) { model.open(library.navigation, library.access) }
            }
        }
    }
}

@Composable
private fun ColumnScope.PhotoUploadForm(library: SynologyPhotosState, state: SynologyPhotoUploadState, model: SynologyPhotoUploadModel,
    onFiles: () -> Unit, onFolder: () -> Unit) {
    val draft = state.draft ?: return
    var showAlbums by remember(draft.id) { mutableStateOf(false) }
    LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text(stringResource(R.string.sp_upload_destination), style = MaterialTheme.typography.titleSmall) }
        val choices = buildList {
            val folder = library.navigation.folders.lastOrNull()
            if (folder != null && library.navigation.section == SynologyPhotosSection.FOLDERS)
                add(SynologyPhotoUploadTarget.Folder(library.navigation.space, folder.id) to folder.name)
            library.access?.spaces.orEmpty().forEach { add(SynologyPhotoUploadTarget.Timeline(it) to "") }
            library.navigation.album?.takeIf { !it.isConditional && !it.isFrozen }?.let { add(SynologyPhotoUploadTarget.Album(it.id) to it.name) }
        }.distinctBy { it.first }
        val showChoices = choices.size > 1 || choices.singleOrNull()?.first != draft.target
        if (!showChoices || choices.none { it.first == draft.target }) draft.target?.let { target -> item {
            Text(photoUploadTarget(target, draft.targetName), style = MaterialTheme.typography.titleLarge, modifier = Modifier.testTag("photos_upload_target"))
        } }
        if (showChoices) items(choices) { (target, name) ->
            PhotoUploadChoice(photoUploadTarget(target, name), draft.target == target) { model.selectTarget(target, name) }
        }
        item {
            TextButton(onClick = { showAlbums = !showAlbums; if (showAlbums && state.albums.isEmpty()) model.loadAlbums() }) {
                Text(stringResource(R.string.sp_upload_choose_album))
            }
        }
        if (showAlbums) {
            items(state.albums, key = { "album-${it.id}" }) { album ->
                PhotoUploadChoice(album.name, draft.target == SynologyPhotoUploadTarget.Album(album.id)) {
                    model.selectTarget(SynologyPhotoUploadTarget.Album(album.id), album.name)
                }
            }
            if (!state.albumsLoading && state.albums.isEmpty() && !state.moreAlbums) item {
                Text(stringResource(R.string.sp_upload_no_albums), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (state.moreAlbums && !state.albumsLoading) item {
                TextButton(onClick = { model.loadAlbums() }) {
                    Text(stringResource(if (state.error != null) R.string.sp_retry else R.string.sp_library_more_collections))
                }
            }
        }
        item { HorizontalDivider(); Text(stringResource(R.string.sp_upload_duplicates), Modifier.padding(top = 12.dp), style = MaterialTheme.typography.titleSmall) }
        items(SynologyPhotoUploadDuplicate.entries) { duplicate ->
            PhotoUploadChoice(stringResource(if (duplicate == SynologyPhotoUploadDuplicate.RENAME) R.string.sp_upload_keep_both else R.string.sp_upload_skip),
                draft.duplicate == duplicate) { model.selectDuplicate(duplicate) }
        }
        if (draft.target !is SynologyPhotoUploadTarget.Album) item {
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(draft.keepFolders, role = Role.Checkbox, onValueChange = model::keepFolders), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(draft.keepFolders, null)
                Text(stringResource(R.string.sp_upload_keep_folders), Modifier.weight(1f).padding(start = 8.dp))
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onFiles, enabled = draft.target != null && draft.duplicate != null, modifier = Modifier.fillMaxWidth().testTag("photos_upload_select_files")) {
                    Icon(Icons.Outlined.PhotoLibrary, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.sp_upload_select_files))
                }
                OutlinedButton(onClick = onFolder, enabled = draft.target != null && draft.duplicate != null, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Outlined.FolderOpen, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.sp_upload_select_folder))
                }
            }
        }
        if (state.records.isNotEmpty()) item {
            TextButton(onClick = model::showQueue, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.sp_upload_queue_count, state.records.size)) }
        }
    }
}

@Composable
private fun PhotoUploadChoice(text: String, selected: Boolean, onSelect: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(selected, role = Role.RadioButton, onClick = onSelect), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, null); Text(text, Modifier.weight(1f).padding(start = 8.dp, end = 4.dp))
    }
}

@Composable
private fun ColumnScope.PhotoImportProgress(state: SynologyPhotoUploadState, onCancel: () -> Unit) {
    Column(Modifier.weight(1f).fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator()
        Text(if (state.importCount == 0) stringResource(R.string.sp_upload_inspecting)
            else stringResource(R.string.sp_upload_preparing, state.importedFiles, state.importCount), Modifier.padding(vertical = 16.dp))
        TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) }
    }
}

@Composable
private fun ColumnScope.PhotoUploadQueue(state: SynologyPhotoUploadState, model: SynologyPhotoUploadModel, onNew: () -> Unit) {
    if (state.records.isEmpty()) Column(Modifier.weight(1f).fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text(stringResource(R.string.sp_upload_queue_empty))
        TextButton(onClick = onNew) { Text(stringResource(R.string.sp_upload_new)) }
    } else LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
        item { TextButton(onClick = onNew, enabled = !state.working) { Text(stringResource(R.string.sp_upload_new)) } }
        items(state.records, key = { it.id }) { row ->
            ListItem(headlineContent = { Text(photoUploadTarget(row.target, row.targetName)) },
                supportingContent = { Text(stringResource(R.string.sp_upload_summary, row.completedCount, row.skippedCount, row.entries.size)) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp).clickable { model.selectBatch(row.id) })
        }
    }
}

@Composable
private fun ColumnScope.PhotoUploadBatch(row: SynologyPhotoUploadBatch, state: SynologyPhotoUploadState, model: SynologyPhotoUploadModel) {
    var discard by remember(row.id) { mutableStateOf(false) }
    val context = LocalContext.current
    LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text(photoUploadTarget(row.target, row.targetName), style = MaterialTheme.typography.titleLarge) }
        item { Text(stringResource(R.string.sp_upload_summary, row.completedCount, row.skippedCount, row.entries.size)) }
        if (row.requiresReview && !state.working) item { Text(stringResource(R.string.sp_upload_pending), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        if (state.working) item {
            state.activeName?.let { Text(it) }
            if (state.totalBytes > 0) {
                LinearProgressIndicator(progress = { (state.bytes.toDouble() / state.totalBytes).toFloat().coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp))
                Text(stringResource(R.string.sp_upload_progress, android.text.format.Formatter.formatShortFileSize(context, state.bytes),
                    android.text.format.Formatter.formatShortFileSize(context, state.totalBytes)))
            } else LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 8.dp))
        }
        items(row.entries, key = { it.id }) { entry ->
            ListItem(headlineContent = { Text(if (entry.relativeFolder.isEmpty()) entry.filename else "${entry.relativeFolder}/${entry.filename}") }, supportingContent = {
                Text(stringResource(when (entry.checkpoint?.phase) {
                    SynologyPhotoUploadPhase.COMPLETED -> R.string.transfer_completed
                    SynologyPhotoUploadPhase.SKIPPED -> R.string.sp_upload_skipped
                    SynologyPhotoUploadPhase.SUBMITTING -> R.string.transfer_uploading
                    SynologyPhotoUploadPhase.PENDING -> R.string.sp_upload_interrupted
                    else -> R.string.transfer_waiting
                }))
            })
        }
    }
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when {
            state.working -> OutlinedButton(onClick = model::pause, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.sp_upload_pause)) }
            row.requiresReview -> Button(onClick = { model.start(row.id, reviewOnly = true) }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.sp_upload_refresh)) }
            !row.finished -> Button(onClick = { model.start(row.id) }, modifier = Modifier.fillMaxWidth().testTag("photos_upload_start")) { Text(stringResource(R.string.sp_upload_start)) }
        }
        if (!state.working) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = model::showQueue) { Text(stringResource(R.string.sp_upload_queue)) }
            if (!row.requiresReview) TextButton(onClick = { discard = true }) {
                Text(stringResource(if (row.finished) R.string.sp_upload_clear else R.string.sp_upload_cancel_batch))
            }
        }
    }
    if (discard) AlertDialog(onDismissRequest = { discard = false },
        title = { Text(stringResource(R.string.sp_upload_clear_title)) }, text = { Text(stringResource(R.string.sp_upload_clear_message)) },
        confirmButton = { TextButton(onClick = { discard = false; model.discard(row.id) }) { Text(stringResource(R.string.sp_upload_clear)) } },
        dismissButton = { TextButton(onClick = { discard = false }) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun photoUploadTarget(target: SynologyPhotoUploadTarget, name: String): String = when (target) {
    is SynologyPhotoUploadTarget.Timeline -> stringResource(if (target.space == SynologyPhotoSpace.PERSONAL) R.string.sp_source_personal else R.string.sp_source_shared)
    is SynologyPhotoUploadTarget.Folder -> {
        val source = stringResource(if (target.space == SynologyPhotoSpace.PERSONAL) R.string.sp_source_personal else R.string.sp_source_shared)
        if (name.isBlank() || name == "/") source else stringResource(R.string.sp_upload_folder_target, source, name)
    }
    is SynologyPhotoUploadTarget.Album -> name
}

@Composable
private fun photoUploadError(error: Throwable): String = (error as? SynologyPhotoUploadFailure)?.let {
    stringResource(when (it.problem) {
        SynologyPhotoUploadProblem.LOCAL_FILE -> R.string.sp_upload_local_error
        SynologyPhotoUploadProblem.STORAGE -> R.string.sp_upload_storage_error
        SynologyPhotoUploadProblem.EMPTY -> R.string.sp_upload_empty_error
        SynologyPhotoUploadProblem.LIMIT -> R.string.sp_upload_limit_error
        SynologyPhotoUploadProblem.BUSY -> R.string.sp_upload_busy_error
        SynologyPhotoUploadProblem.PENDING -> R.string.sp_upload_pending
    })
} ?: when {
    error is DsmFailure -> error.localize(LocalContext.current).combined
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED -> stringResource(R.string.sp_upload_changed_error)
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.PERMISSION -> stringResource(R.string.sp_upload_permission_error)
    error is java.io.IOException || error is SecurityException -> stringResource(R.string.sp_upload_local_error)
    else -> photoError(error)
}
