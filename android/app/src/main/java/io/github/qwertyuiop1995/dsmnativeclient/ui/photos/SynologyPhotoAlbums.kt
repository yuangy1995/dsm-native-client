package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.validatePhotoAlbumCheckpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

@Composable
internal fun SynologyPhotoAlbums(model: SynologyPhotoAlbumModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    val title = when (state.page) {
        SynologyPhotoAlbumPage.MANAGE -> R.string.sp_album_manage
        SynologyPhotoAlbumPage.FORM -> state.draft?.action?.label() ?: R.string.sp_album_manage
        SynologyPhotoAlbumPage.RECORDS -> R.string.sp_album_records
    }
    ClientPageDialog(stringResource(title), model::dismiss) {
        Column(Modifier.fillMaxSize()) {
            state.error?.let { Text(photoAlbumError(it), Modifier.fillMaxWidth().padding(16.dp), color = MaterialTheme.colorScheme.error) }
            when {
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                state.page == SynologyPhotoAlbumPage.MANAGE -> {
                    val access = state.access
                    LazyColumn(Modifier.fillMaxSize().testTag("photos_album_manage"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        if (access == null) item { Button(onClick = model::retryAccess) { Text(stringResource(R.string.sp_retry)) } }
                        else {
                            item { Text(access.album.name, style = MaterialTheme.typography.titleLarge) }
                            if (access.isOwner && access.album.temporaryShare) {
                                if (model.canManageSharing) item { OutlinedButton(onClick = { model.open(SynologyPhotoAlbumAction.SHARE, albumId = access.album.id) }, modifier = Modifier.fillMaxWidth()) {
                                    Text(stringResource(R.string.sp_sharing_title))
                                } }
                                item { OutlinedButton(onClick = { model.open(SynologyPhotoAlbumAction.STOP_TEMPORARY, albumId = access.album.id) }, modifier = Modifier.fillMaxWidth()) {
                                    Text(stringResource(R.string.sp_temporary_stop))
                                } }
                            } else if (access.canManage) {
                                if (access.album.recoverable) {
                                    item { Text(stringResource(R.string.sp_frozen_notice)) }
                                    if (state.frozen != null) {
                                        item { OutlinedButton(onClick = { model.open(SynologyPhotoAlbumAction.UNFREEZE, albumId = access.album.id) }, modifier = Modifier.fillMaxWidth()) {
                                            Text(stringResource(R.string.sp_frozen_save))
                                        } }
                                        if (state.frozen!!.canRebuild && model.canManageConditions) item {
                                            OutlinedButton(onClick = { model.open(SynologyPhotoAlbumAction.REBUILD_FROZEN, albumId = access.album.id) }, modifier = Modifier.fillMaxWidth()) {
                                                Text(stringResource(R.string.sp_frozen_rebuild))
                                            }
                                        }
                                    } else item { TextButton(onClick = model::retryAccess) { Text(stringResource(R.string.sp_retry)) } }
                                }
                                if (access.album.conditional && model.canManageConditions) item {
                                    OutlinedButton(onClick = { model.open(SynologyPhotoAlbumAction.SET_CONDITION, albumId = access.album.id) }, modifier = Modifier.fillMaxWidth()) {
                                        Text(stringResource(R.string.sp_condition_edit))
                                    }
                                }
                                if (!access.album.recoverable || state.sharedContext) item { OutlinedButton(onClick = { model.open(SynologyPhotoAlbumAction.RENAME, albumId = access.album.id) }, modifier = Modifier.fillMaxWidth()) {
                                    Text(stringResource(R.string.sp_album_rename))
                                } }
                                if (model.canManageSharing && (!access.album.recoverable || state.sharedContext)) item {
                                    OutlinedButton(onClick = { model.open(SynologyPhotoAlbumAction.SHARE, albumId = access.album.id) }, modifier = Modifier.fillMaxWidth().testTag("photos_album_sharing")) {
                                        Text(stringResource(R.string.sp_sharing_title))
                                    }
                                }
                                item { OutlinedButton(onClick = { model.open(SynologyPhotoAlbumAction.DELETE, albumId = access.album.id) }, modifier = Modifier.fillMaxWidth()) {
                                    Text(stringResource(R.string.sp_album_delete))
                                } }
                            } else item { Text(stringResource(R.string.sp_album_owner_only)) }
                            if (access.canContribute) item { Text(stringResource(R.string.sp_album_select_hint), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                    }
                }
                state.page == SynologyPhotoAlbumPage.FORM -> AlbumForm(state, model)
                else -> AlbumRecords(state, model)
            }
        }
    }
}

@Composable
private fun ColumnScope.AlbumForm(state: SynologyPhotoAlbumState, model: SynologyPhotoAlbumModel) {
    val draft = state.draft ?: return
    if (draft.action.editsCondition) { PhotoConditionForm(state, model); return }
    if (draft.action == SynologyPhotoAlbumAction.SHARE) { PhotoSharingForm(state, model); return }
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val permission = when (draft.action) {
        SynologyPhotoAlbumAction.CREATE -> true
        SynologyPhotoAlbumAction.CREATE_TEMPORARY -> model.canManageSharing
        SynologyPhotoAlbumAction.STOP_TEMPORARY -> state.access?.let { it.isOwner && it.album.temporaryShare } == true
        SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE -> state.access?.canContribute == true
        else -> state.access?.canManage == true
    }
    val valid = permission && runCatching { validatePhotoAlbumCheckpoint(SynologyPhotoAlbumCheckpoint(
        profileId = draft.photos.firstOrNull()?.id?.profileId ?: "form", userId = 1, operationId = draft.id,
        action = draft.action, album = draft.album, targets = draft.photos.map(::SynologyPhotoEditTarget),
        temporary = draft.temporary?.let { SynologyPhotoTemporaryChange(it, draft.keepCopy, draft.preservedCopyId) },
        frozenSnapshot = draft.frozen?.snapshot.takeIf { draft.action.restoresFrozen },
        name = draft.name.takeIf { draft.action in setOf(SynologyPhotoAlbumAction.CREATE, SynologyPhotoAlbumAction.CREATE_TEMPORARY, SynologyPhotoAlbumAction.RENAME) })) }.isSuccess
    LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (draft.action == SynologyPhotoAlbumAction.ADD && (state.moreAlbums || state.albums.isNotEmpty() || draft.albumId == null)) {
            item { Text(stringResource(R.string.sp_album_choose), style = MaterialTheme.typography.titleMedium) }
            items(state.albums, key = { it.id }) { album ->
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(album.id == draft.albumId, enabled = !state.working,
                    role = Role.RadioButton, onClick = { model.selectAlbum(album.id) }), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(album.id == draft.albumId, null)
                    Text(album.name, Modifier.weight(1f).padding(start = 8.dp))
                }
            }
            if (state.albumsLoading) item { CircularProgressIndicator(Modifier.size(24.dp)) }
            else if (state.moreAlbums) item { TextButton(onClick = { model.loadAlbums() }) { Text(stringResource(if (state.error == null) R.string.sp_library_more_collections else R.string.sp_retry)) } }
            else if (state.albums.isEmpty()) item { Text(stringResource(R.string.sp_album_none_addable)) }
        } else draft.album?.let { album -> item { Text(album.name, style = MaterialTheme.typography.titleMedium) } }
        if (draft.action in setOf(SynologyPhotoAlbumAction.CREATE, SynologyPhotoAlbumAction.CREATE_TEMPORARY, SynologyPhotoAlbumAction.RENAME)) item {
            OutlinedTextField(draft.name, model::setName, Modifier.fillMaxWidth().testTag("photos_album_name"),
                label = { Text(stringResource(R.string.sp_album_name)) }, singleLine = true, enabled = !state.working,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() }))
        }
        if (draft.albumId != null && state.access == null) item { TextButton(onClick = model::retryAccess) { Text(stringResource(R.string.sp_retry)) } }
        else if (!permission && state.access != null) item { Text(stringResource(R.string.sp_album_permission), color = MaterialTheme.colorScheme.error) }
        if (draft.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY) item { Text(stringResource(R.string.sp_temporary_create_note)) }
        if (draft.action == SynologyPhotoAlbumAction.STOP_TEMPORARY) {
            item { Text(stringResource(R.string.sp_temporary_stop_note)) }
            if (draft.preservedCopyId != null) item { Text(stringResource(R.string.sp_temporary_copy_ready)) }
            else item {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(draft.keepCopy, enabled = !state.working, role = Role.Checkbox,
                    onValueChange = model::setKeepCopy), verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(draft.keepCopy, null); Text(stringResource(R.string.sp_temporary_keep_copy), Modifier.weight(1f).padding(start = 8.dp))
                }
            }
        }
        if (draft.action == SynologyPhotoAlbumAction.DELETE) item { Text(stringResource(R.string.sp_album_delete_note)) }
        if (draft.action == SynologyPhotoAlbumAction.UNFREEZE) item { Text(stringResource(R.string.sp_frozen_save_note)) }
        if (draft.action == SynologyPhotoAlbumAction.REMOVE) item { Text(stringResource(R.string.sp_album_remove_note)) }
        if (draft.photos.isNotEmpty()) {
            item { Text(stringResource(R.string.items_selected_count, draft.photos.size), style = MaterialTheme.typography.titleSmall) }
            items(draft.photos, key = { "photo:${it.id}" }) { photo -> Text(photo.filename) }
        }
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
        Button(onClick = { model.save() }, enabled = valid && !state.working,
            modifier = Modifier.testTag("photos_album_save")) {
            Text(stringResource(if (draft.action == SynologyPhotoAlbumAction.RENAME) R.string.save_changes else draft.action.label()))
        }
    }
}

@Composable
private fun ColumnScope.AlbumRecords(state: SynologyPhotoAlbumState, model: SynologyPhotoAlbumModel) {
    LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (state.records.isEmpty() && !state.working) item { Text(stringResource(R.string.sp_album_no_records)) }
        items(state.records, key = { it.id }) { record ->
            val row = record.checkpoint
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(row.name ?: row.album?.name.orEmpty(), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(row.action.label()), color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(stringResource(when (row.phase) {
                    SynologyPhotoAlbumPhase.COMPLETED -> if (row.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY) R.string.sp_temporary_prepared else R.string.sp_album_done
                    SynologyPhotoAlbumPhase.PARTIAL -> when (row.action) {
                        SynologyPhotoAlbumAction.REBUILD_FROZEN -> R.string.sp_frozen_partial
                        SynologyPhotoAlbumAction.SHARE -> R.string.sp_sharing_partial
                        SynologyPhotoAlbumAction.STOP_TEMPORARY -> R.string.sp_temporary_partial
                        else -> R.string.sp_album_partial
                    }
                    SynologyPhotoAlbumPhase.PENDING, SynologyPhotoAlbumPhase.SUBMITTING -> R.string.sp_album_pending
                    SynologyPhotoAlbumPhase.READY -> R.string.sp_edit_not_saved
                }))
                if (row.targets.isNotEmpty() && (row.finished || row.completed.isNotEmpty()))
                    Text(stringResource(R.string.sp_album_progress, row.completed.size, row.targets.size))
                if (state.working && state.activeId == row.operationId) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (row.phase == SynologyPhotoAlbumPhase.PARTIAL && row.targets.isNotEmpty()) Button(onClick = { model.continueRemaining(row.operationId) }, enabled = !state.working) {
                    Text(stringResource(R.string.sp_edit_continue))
                } else if (!row.finished) Button(onClick = { model.resume(row.operationId) }, enabled = !state.working,
                    modifier = Modifier.testTag("photos_album_resume")) {
                    Text(stringResource(if (row.submitted) R.string.sp_edit_refresh else if (row.sharing?.password == SynologyPhotoSharingPassword.SET) R.string.sp_sharing_reopen
                        else if (row.action == SynologyPhotoAlbumAction.RENAME) R.string.save_changes else row.action.label()))
                }
                if (!row.submitted && row.sharing?.password == SynologyPhotoSharingPassword.SET) Text(stringResource(R.string.sp_sharing_password_not_saved), color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (row.finished && row.action == SynologyPhotoAlbumAction.SHARE) OutlinedButton(onClick = { model.open(SynologyPhotoAlbumAction.SHARE, albumId = row.albumId) }, enabled = !state.working) {
                    Text(stringResource(R.string.sp_sharing_title))
                }
                if (state.working && state.temporaryCreationId == row.operationId) OutlinedButton(onClick = model::cancelTemporaryCreation, enabled = !state.temporaryCancelRequested) {
                    Text(stringResource(if (state.temporaryCancelRequested) R.string.sp_temporary_cancelling else R.string.sp_temporary_cancel))
                }
                if (row.finished && row.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY) {
                    OutlinedButton(onClick = { model.configureTemporary(row.operationId) }, enabled = !state.working) { Text(stringResource(R.string.sp_sharing_title)) }
                    OutlinedButton(onClick = { model.stopTemporaryRecord(row.operationId) }, enabled = !state.working) { Text(stringResource(R.string.sp_temporary_stop)) }
                }
                if (row.phase == SynologyPhotoAlbumPhase.PARTIAL && row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY) OutlinedButton(onClick = { model.stopTemporaryRecord(row.operationId) }, enabled = !state.working) {
                    Text(stringResource(R.string.sp_temporary_continue_stop))
                }
                if (row.finished || !row.submitted) TextButton(onClick = { model.discard(row.operationId) }, enabled = !state.working) {
                    Text(stringResource(R.string.sp_edit_clear_record))
                }
                HorizontalDivider()
            }
        }
    }
}

private fun SynologyPhotoAlbumAction.label(): Int = when (this) {
    SynologyPhotoAlbumAction.EDIT_SIMILAR -> R.string.sp_category_similar
    SynologyPhotoAlbumAction.SHOW_CONCEPTS -> R.string.sp_concepts_visibility
    SynologyPhotoAlbumAction.COVER_CONCEPT -> R.string.sp_concept_cover
    SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS -> R.string.sp_concept_remove
    SynologyPhotoAlbumAction.EDIT_PHOTO_FACES -> R.string.sp_manual_faces_title
    SynologyPhotoAlbumAction.RENAME_PERSON -> R.string.sp_person_rename
    SynologyPhotoAlbumAction.MERGE_PEOPLE -> R.string.sp_people_merge
    SynologyPhotoAlbumAction.SHOW_PEOPLE -> R.string.sp_people_visibility
    SynologyPhotoAlbumAction.REMOVE_PERSON_FACES -> R.string.sp_person_faces_remove
    SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES -> R.string.sp_person_faces_reassign
    SynologyPhotoAlbumAction.COVER_PERSON -> R.string.sp_person_cover
    SynologyPhotoAlbumAction.STOP_TASK -> R.string.sp_tasks_stop
    SynologyPhotoAlbumAction.CLEAR_TASKS -> R.string.sp_tasks_clear
    SynologyPhotoAlbumAction.MOVE_ITEMS -> R.string.sp_files_move
    SynologyPhotoAlbumAction.COPY_ITEMS -> R.string.sp_files_copy
    SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS -> R.string.sp_files_delete
    SynologyPhotoAlbumAction.SHARED_MEMBERS -> R.string.sp_members_title
    SynologyPhotoAlbumAction.CODEC_PROMPT -> R.string.sp_codec_title
    SynologyPhotoAlbumAction.REGENERATE_PREVIEWS -> R.string.sp_preview_regeneration_title
    SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW -> R.string.sp_automatic_preview_title
    SynologyPhotoAlbumAction.MAINTAIN_LIBRARY -> R.string.sp_maintenance_title
    SynologyPhotoAlbumAction.SETTINGS -> R.string.sp_settings_title
    SynologyPhotoAlbumAction.SHARE_FOLDER -> R.string.sp_folder_sharing_title
    SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoAlbumAction.RENAME_FOLDER, SynologyPhotoAlbumAction.SORT_FOLDER, SynologyPhotoAlbumAction.COVER_FOLDER -> folderLabel()
    SynologyPhotoAlbumAction.CREATE_REQUEST -> R.string.sp_request_create
    SynologyPhotoAlbumAction.UPDATE_REQUEST -> R.string.sp_request_edit
    SynologyPhotoAlbumAction.DELETE_REQUEST -> R.string.sp_request_delete
    SynologyPhotoAlbumAction.CREATE_TEMPORARY -> R.string.sp_temporary_create
    SynologyPhotoAlbumAction.STOP_TEMPORARY -> R.string.sp_temporary_stop
    SynologyPhotoAlbumAction.SHARE -> R.string.sp_sharing_title
    SynologyPhotoAlbumAction.UNFREEZE -> R.string.sp_frozen_save
    SynologyPhotoAlbumAction.REBUILD_FROZEN -> R.string.sp_frozen_rebuild
    SynologyPhotoAlbumAction.CREATE_CONDITION -> R.string.sp_condition_create
    SynologyPhotoAlbumAction.SET_CONDITION -> R.string.sp_condition_edit
    SynologyPhotoAlbumAction.CREATE -> R.string.sp_album_create
    SynologyPhotoAlbumAction.RENAME -> R.string.sp_album_rename
    SynologyPhotoAlbumAction.DELETE -> R.string.sp_album_delete
    SynologyPhotoAlbumAction.ADD -> R.string.sp_album_add
    SynologyPhotoAlbumAction.REMOVE -> R.string.sp_album_remove
    SynologyPhotoAlbumAction.COVER -> R.string.sp_album_cover
}

@Composable
internal fun PhotoFrozenRebuildNotice(frozen: SynologyPhotoFrozenAlbum?) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.sp_frozen_rebuild_note))
        if (frozen?.snapshot?.shared == true) Text(stringResource(R.string.sp_frozen_sharing_note), color = MaterialTheme.colorScheme.error)
        if (!frozen?.unsupportedKeys.isNullOrEmpty()) {
            Text(stringResource(R.string.sp_frozen_removed_rules), style = MaterialTheme.typography.titleSmall)
            frozen!!.unsupportedKeys.map { key ->
                when (key) {
                    "recently_add" -> R.string.sp_frozen_recently_added
                    "recently_comment" -> R.string.sp_frozen_recently_commented
                    "update_time" -> R.string.sp_frozen_updated
                    "people" -> R.string.sp_condition_person
                    else -> SynologyPhotoConditionField.entries.firstOrNull { it.key == key }?.title() ?: R.string.sp_frozen_other_rules
                }
            }.distinct().forEach { Text(stringResource(it), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

@Composable
internal fun photoAlbumError(error: Throwable): String = when (error) {
    is SynologyPhotoAlbumFailure -> stringResource(when (error.problem) {
        SynologyPhotoAlbumProblem.STORAGE -> R.string.sp_album_storage_failed
        SynologyPhotoAlbumProblem.BUSY -> R.string.sp_edit_busy
        SynologyPhotoAlbumProblem.PENDING -> R.string.sp_album_conflict
    })
    is SynologyPhotoEditFailure -> photoEditError(error)
    is SynologyPhotoFailure -> stringResource(when (error.kind) {
        SynologyPhotoFailureKind.PERMISSION -> R.string.sp_album_permission
        SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_album_changed
        else -> R.string.sp_album_failed
    })
    else -> stringResource(R.string.sp_album_failed)
}
