package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoFolderCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

@Composable
internal fun SynologyPhotoFolders(model: SynologyPhotoFolderModel, library: SynologyPhotosModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    val title = if (state.recordsPage) R.string.sp_folder_records else state.draft?.action?.folderLabel() ?: R.string.sp_folder_manage
    ClientPageDialog(stringResource(title), model::dismiss) {
        Column(Modifier.fillMaxSize()) {
            state.error?.let { Text(photoFolderError(it), Modifier.fillMaxWidth().padding(16.dp), color = MaterialTheme.colorScheme.error) }
            when {
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                state.recordsPage -> FolderRecords(state, model)
                state.draft == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Button(onClick = { model.load() }) { Text(stringResource(R.string.sp_retry)) }
                }
                else -> FolderForm(state, model, library)
            }
        }
    }
}

@Composable
private fun ColumnScope.FolderForm(state: SynologyPhotoFolderState, model: SynologyPhotoFolderModel, library: SynologyPhotosModel) {
    val draft = state.draft ?: return
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    val coverColumns = ((LocalConfiguration.current.screenWidthDp - 24) / 168).coerceAtLeast(2)
    if (draft.action == SynologyPhotoAlbumAction.COVER_FOLDER) {
        Text(stringResource(R.string.sp_folder_cover_target, draft.access.folder.name), Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            style = MaterialTheme.typography.titleSmall)
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { model.backTo(state.path.lastIndex - 1) }, enabled = state.path.size > 1 && !state.browsing && !state.working) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.go_up))
            }
            PhotoFolderPath(state.path, !state.working && !state.browsing, Modifier.weight(1f), model::backTo)
        }
    }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_folder_form"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (draft.action in setOf(SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoAlbumAction.RENAME_FOLDER)) {
            item { Text(draft.access.folder.path) }
            item { OutlinedTextField(draft.name, model::name, Modifier.fillMaxWidth().testTag("photos_folder_name"),
                label = { Text(stringResource(R.string.sp_folder_name)) }, singleLine = true, enabled = !state.working,
                isError = draft.name.isNotEmpty() && !SynologyPhotoFolderCodec.validName(draft.name.trim()),
                supportingText = if (draft.name.isNotEmpty() && !SynologyPhotoFolderCodec.validName(draft.name.trim())) ({ Text(stringResource(R.string.sp_folder_invalid_name)) }) else null,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() })) }
        } else if (draft.action == SynologyPhotoAlbumAction.SORT_FOLDER) {
            item { Text(draft.access.folder.path) }
            item { SharingChoice(stringResource(R.string.sp_folder_sort_field), stringResource(draft.sort.field.folderLabel()),
                SynologyPhotoSort.Field.entries.map { it to stringResource(it.folderLabel()) }, !state.working, "photos_folder_sort_field") { model.sort(draft.sort.copy(field = it)) } }
            item { SharingChoice(stringResource(R.string.sp_folder_sort_direction), stringResource(draft.sort.direction.folderLabel()),
                SynologyPhotoSort.Direction.entries.map { it to stringResource(it.folderLabel()) }, !state.working, "photos_folder_sort_direction") { model.sort(draft.sort.copy(direction = it)) } }
        } else {
            items(state.children, key = { "folder:${it.id}" }) { folder ->
                OutlinedButton(onClick = { model.enter(folder) }, enabled = !state.browsing && !state.working,
                    modifier = Modifier.fillMaxWidth().testTag("photos_folder_child_${folder.id}")) {
                    Icon(Icons.Outlined.Folder, null); Text(folder.name, Modifier.weight(1f).padding(start = 8.dp), maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
            items(state.photos.chunked(coverColumns), key = { "photos:${it.first().id}" }) { pair ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    pair.forEach { photo -> Column(Modifier.weight(1f).testTag("photos_folder_cover_${photo.id.itemId}")) {
                        SynologyPhotoTile(photo, library, onClick = { model.select(photo) }, selected = draft.photo?.id == photo.id,
                            onSelect = { model.select(photo) }, singleChoice = true)
                        Text(photo.filename, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall)
                    } }
                    repeat(coverColumns - pair.size) { Spacer(Modifier.weight(1f)) }
                }
            }
            if (state.browsing) item { Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
            state.browseError?.let { error -> item {
                Text(photoFolderError(error), color = MaterialTheme.colorScheme.error)
                Button(onClick = { model.browse() }, enabled = !state.browsing) { Text(stringResource(R.string.sp_retry)) }
            } }
            if (!state.browsing && state.browseError == null && state.children.isEmpty() && state.photos.isEmpty()) item { Text(stringResource(R.string.sp_folder_cover_empty)) }
            if (state.moreFolders || state.morePhotos) item { OutlinedButton(onClick = { model.browse(more = true) }, enabled = !state.browsing && !state.working,
                modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.sp_library_more)) } }
        }
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
        Button(onClick = { focus.clearFocus(); keyboard?.hide(); model.save() }, enabled = model.canSave,
            modifier = Modifier.testTag("photos_folder_save")) { Text(stringResource(if (draft.action == SynologyPhotoAlbumAction.CREATE_FOLDER) R.string.sp_folder_create else R.string.save_changes)) }
    }
}

@Composable
private fun FolderRecords(state: SynologyPhotoFolderState, model: SynologyPhotoFolderModel) {
    LazyColumn(Modifier.fillMaxSize().testTag("photos_folder_records"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (state.records.isEmpty() && !state.working) item { Text(stringResource(R.string.sp_folder_no_records)) }
        items(state.records, key = { it.id }) { record ->
            val row = record.checkpoint; val operation = row.folder!!
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(row.action.folderLabel()), style = MaterialTheme.typography.titleMedium)
                Text(operation.name ?: operation.target.name)
                Text(stringResource(if (row.finished) R.string.sp_folder_done else if (row.submitted) R.string.sp_folder_pending else R.string.sp_request_not_sent))
                if (state.working && state.activeId == record.id) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (!row.finished) Button(onClick = { model.resume(record.id) }, enabled = !state.working, modifier = Modifier.testTag("photos_folder_resume")) {
                    Text(stringResource(if (row.submitted) R.string.sp_edit_refresh else R.string.sp_request_reopen))
                }
                if (row.finished || !row.submitted) TextButton(onClick = { model.discard(record.id) }, enabled = !state.working) { Text(stringResource(R.string.sp_edit_clear_record)) }
                HorizontalDivider()
            }
        }
    }
}

@Composable
internal fun PhotoFolderPath(path: List<SynologyPhotoCollection>, enabled: Boolean, modifier: Modifier = Modifier, backTo: (Int) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        TextButton(onClick = { expanded = true }, enabled = enabled && path.isNotEmpty(), modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("photos_folder_path")) {
            Text(path.lastOrNull()?.takeUnless { it.path == "/" }?.name ?: stringResource(R.string.sp_folder_root), Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            Icon(Icons.Outlined.ArrowDropDown, null)
        }
        DropdownMenu(expanded, { expanded = false }) {
            path.forEachIndexed { index, folder -> DropdownMenuItem(text = { Text(if (folder.path == "/") stringResource(R.string.sp_folder_root) else folder.name) },
                onClick = { expanded = false; backTo(index) }, enabled = index < path.lastIndex) }
        }
    }
}

internal fun SynologyPhotoAlbumAction.folderLabel(): Int = when (this) {
    SynologyPhotoAlbumAction.CREATE_FOLDER -> R.string.sp_folder_create
    SynologyPhotoAlbumAction.RENAME_FOLDER -> R.string.sp_folder_rename
    SynologyPhotoAlbumAction.SORT_FOLDER -> R.string.sp_folder_sort
    SynologyPhotoAlbumAction.COVER_FOLDER -> R.string.sp_folder_cover
    else -> R.string.sp_folder_manage
}
internal fun SynologyPhotoSort.Field.folderLabel(): Int = when (this) {
    SynologyPhotoSort.Field.FILENAME -> R.string.sp_folder_sort_name
    SynologyPhotoSort.Field.FILESIZE -> R.string.sp_folder_sort_size
    SynologyPhotoSort.Field.ITEM_TYPE -> R.string.sp_folder_sort_type
    SynologyPhotoSort.Field.TAKEN_TIME -> R.string.sp_folder_sort_time
}
internal fun SynologyPhotoSort.Direction.folderLabel(): Int = if (this == SynologyPhotoSort.Direction.ASCENDING) R.string.sp_folder_sort_ascending else R.string.sp_folder_sort_descending
@Composable
private fun photoFolderError(error: Throwable): String = stringResource(when {
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.STORAGE -> R.string.sp_folder_storage_failed
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.BUSY -> R.string.sp_edit_busy
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.PENDING -> R.string.sp_folder_conflict
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.PERMISSION -> R.string.sp_folder_permission
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_folder_changed
    else -> R.string.sp_folder_failed
})
