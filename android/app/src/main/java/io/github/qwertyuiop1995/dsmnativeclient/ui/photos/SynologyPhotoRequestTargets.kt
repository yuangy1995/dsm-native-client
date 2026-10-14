package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.photos.*

@Composable
internal fun ColumnScope.PhotoRequestFolders(state: SynologyPhotoRequestState, model: SynologyPhotoRequestModel) {
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_request_folder_list"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (state.folderError != null) item {
            Text(photoRequestError(state.folderError), color = MaterialTheme.colorScheme.error)
            Button(onClick = { model.folders(state.folderPath) }, enabled = !state.foldersLoading) { Text(stringResource(R.string.sp_retry)) }
        }
        if (state.folders.isEmpty() && !state.foldersLoading && state.folderError == null) item { Text(stringResource(R.string.sp_request_no_folders)) }
        items(state.folders, key = { it.id }) { folder ->
            OutlinedButton(onClick = { model.folders(state.folderPath + folder) }, enabled = !state.working && !state.foldersLoading,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(folder.name, Modifier.fillMaxWidth()) }
        }
        if (state.foldersLoading) item { CircularProgressIndicator() }
        else if (state.moreFolders && state.folderError == null) item { TextButton(onClick = { model.folders(state.folderPath, more = true) }) { Text(stringResource(R.string.sp_library_more_collections)) } }
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        LazyRow(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            items(state.folderPath.size) { index ->
                val folder = state.folderPath[index]
                OutlinedButton(onClick = { model.folders(state.folderPath.take(index + 1)) }, enabled = !state.foldersLoading,
                    modifier = Modifier.heightIn(min = 48.dp)) { Text(folder.name) }
            }
        }
        Button(onClick = { model.chooseFolder() }, enabled = !state.foldersLoading && state.folderError == null && state.folderPath.isNotEmpty(),
            modifier = Modifier.widthIn(max = 160.dp).heightIn(min = 48.dp).testTag("photos_request_use_folder")) { Text(stringResource(R.string.sp_request_use_folder)) }
    }
}

@Composable
internal fun ColumnScope.PhotoRequestAlbums(state: SynologyPhotoRequestState, model: SynologyPhotoRequestModel) {
    val draft = state.draft ?: return
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    val choices = state.albums.filter { it.name.contains(state.albumSearch.trim(), ignoreCase = true) }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_request_album_list"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { OutlinedTextField(state.albumSearch, model::albumSearch, Modifier.fillMaxWidth().testTag("photos_request_album_search"),
            label = { Text(stringResource(R.string.sp_request_album_search)) }, singleLine = true, enabled = !state.working,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() })) }
        item {
            val selected = draft.settings.albumId == null && draft.settings.albumPassphrase == null
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(selected, enabled = !state.working, role = Role.RadioButton, onClick = { model.selectAlbum(null) }), verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected, null); Text(stringResource(R.string.sp_request_no_album), Modifier.padding(start = 8.dp))
            }
        }
        if (state.albumsLoading) item { CircularProgressIndicator() }
        else if (state.albumError != null) item {
            Text(photoRequestError(state.albumError), color = MaterialTheme.colorScheme.error)
            Button(onClick = { model.selectAlbums() }, enabled = !state.working) { Text(stringResource(R.string.sp_retry)) }
        } else if (choices.isEmpty()) item { Text(stringResource(if (state.albumSearch.isBlank()) R.string.sp_album_none_addable else R.string.sp_sharing_no_search_results)) }
        items(choices) { album ->
            val selected = draft.settings.albumId == album.albumId && draft.settings.albumPassphrase == album.passphrase
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(selected, enabled = !state.working, role = Role.RadioButton,
                onClick = { focus.clearFocus(); keyboard?.hide(); model.selectAlbum(album) }), verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected, null)
                Column(Modifier.weight(1f).padding(start = 8.dp)) {
                    Text(album.name)
                    if (!album.shared) Text(stringResource(R.string.sp_request_private_album), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        if (model.canCreateAlbum) {
            item { HorizontalDivider(); Text(stringResource(R.string.sp_album_create), style = MaterialTheme.typography.titleSmall) }
            item { OutlinedTextField(state.newAlbumName, model::albumName, Modifier.fillMaxWidth().testTag("photos_request_new_album"),
                label = { Text(stringResource(R.string.sp_album_name)) }, enabled = !state.working && state.pendingAlbum == null, singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() })) }
            item {
                if (state.pendingAlbum == null) OutlinedButton(onClick = { focus.clearFocus(); keyboard?.hide(); model.createAlbum() },
                    enabled = !state.working && state.newAlbumName.isNotBlank(), modifier = Modifier.fillMaxWidth().testTag("photos_request_create_album")) { Text(stringResource(R.string.sp_album_create)) }
                else {
                    Text(stringResource(if (state.pendingAlbum.checkpoint.submitted) R.string.sp_album_pending else R.string.sp_edit_not_saved))
                    Button(onClick = { model.reviewAlbum() }, enabled = !state.working) {
                        Text(stringResource(if (state.pendingAlbum.checkpoint.submitted) R.string.sp_edit_refresh else R.string.sp_album_create))
                    }
                }
                if (state.working) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        }
    }
}
