package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.widget.Toast
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

@Composable
internal fun SynologyPhotoFolderSharing(model: SynologyPhotoFolderSharingModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    ClientPageDialog(stringResource(if (state.recordsPage) R.string.sp_folder_sharing_records else R.string.sp_folder_sharing_title), model::dismiss) {
        Column(Modifier.fillMaxSize()) {
            state.error?.let { Text(folderSharingError(it), Modifier.fillMaxWidth().padding(16.dp), color = MaterialTheme.colorScheme.error) }
            when {
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                state.recordsPage -> FolderSharingRecords(state, model)
                state.original == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Button(onClick = { model.load() }) { Text(stringResource(R.string.sp_retry)) }
                }
                state.selectingMembers -> FolderSharingMembers(state, model)
                else -> FolderSharingForm(state, model)
            }
        }
    }
    state.confirmation?.let { change ->
        AlertDialog(onDismissRequest = model::cancelConfirmation,
            title = { Text(stringResource(R.string.sp_folder_sharing_confirm_title)) },
            text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(change.original.folder.name)
                if (change.access != change.original.access) Text(stringResource(R.string.sp_folder_sharing_access_risk, stringResource(change.access.folderSharingLabel())))
                if (change.members?.associate { it.id to it.role } != change.original.members?.associate { it.id to it.role }) Text(stringResource(R.string.sp_folder_sharing_member_risk))
                if (change.password == SynologyPhotoSharingPassword.REMOVE) Text(stringResource(R.string.sp_folder_sharing_password_risk))
                if (change.appliesToSubfolders) Text(stringResource(R.string.sp_folder_sharing_children_risk))
            } },
            confirmButton = { TextButton(onClick = { model.confirm() }, modifier = Modifier.testTag("photos_folder_sharing_confirm")) { Text(stringResource(R.string.save_changes)) } },
            dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun ColumnScope.FolderSharingForm(state: SynologyPhotoFolderSharingState, model: SynologyPhotoFolderSharingModel) {
    val original = state.original ?: return
    val enabled = state.canEdit
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    val clipboard = LocalClipboardManager.current; val context = LocalContext.current
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_folder_sharing_form"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text(original.snapshot.folder.path, style = MaterialTheme.typography.titleMedium) }
        if (original.snapshot.inheritsManagementOnly) item { Text(stringResource(R.string.sp_folder_sharing_inherited), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        item { SharingChoice(stringResource(R.string.sp_sharing_access), stringResource(state.access.folderSharingLabel()),
            SynologyPhotoFolderLinkAccess.entries.map { it to stringResource(it.folderSharingLabel()) }, enabled, "photos_folder_sharing_access", model::access) }
        if (state.access in setOf(SynologyPhotoFolderLinkAccess.VIEW, SynologyPhotoFolderLinkAccess.DOWNLOAD)) item {
            Text(stringResource(if (state.access == SynologyPhotoFolderLinkAccess.VIEW) R.string.sp_folder_sharing_public_view else R.string.sp_folder_sharing_public_download),
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        item { Text(stringResource(R.string.sp_sharing_members), style = MaterialTheme.typography.titleSmall) }
        if (state.members == null) item { Text(stringResource(R.string.sp_sharing_members_unreadable), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        else {
            if (state.members.isEmpty()) item { Text(stringResource(R.string.sp_sharing_no_members), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            items(state.members, key = { "${it.id.type}:${it.id.value}" }) { grant ->
                val name = state.names[grant.id] ?: stringResource(R.string.sp_folder_sharing_unnamed_member)
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(name, style = MaterialTheme.typography.titleSmall)
                            Text(stringResource(if (grant.id.type == "group") R.string.sp_sharing_group else R.string.sp_sharing_user),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        IconButton(onClick = { model.remove(grant.id) }, enabled = enabled) { Icon(Icons.Outlined.Close, stringResource(R.string.sp_sharing_remove_member, name)) }
                    }
                    SharingChoice(stringResource(R.string.sp_sharing_role), stringResource(grant.role.folderRoleLabel()),
                        SynologyPhotoFolderSharingModel.roles.map { it to stringResource(it.folderRoleLabel()) }, enabled,
                        "photos_folder_sharing_role_${grant.id.type}_${grant.id.value}") { model.role(grant.id, it) }
                }
            }
            item { OutlinedButton(onClick = { model.selectMembers() }, enabled = enabled,
                modifier = Modifier.fillMaxWidth().testTag("photos_folder_sharing_add_member")) { Text(stringResource(R.string.sp_sharing_add_member)) } }
        }
        item { SharingChoice(stringResource(R.string.password), stringResource(state.passwordMode.label()),
            SynologyPhotoSharingPassword.entries.map { it to stringResource(it.label()) }, enabled, "photos_folder_sharing_password_mode", model::passwordMode) }
        if (state.passwordMode == SynologyPhotoSharingPassword.UNCHANGED) item {
            Text(stringResource(when (original.snapshot.hasPassword) { true -> R.string.sp_sharing_password_on; false -> R.string.sp_sharing_password_off; null -> R.string.sp_sharing_password_unknown }),
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (state.passwordMode == SynologyPhotoSharingPassword.SET) item {
            OutlinedTextField(state.password, model::password, Modifier.fillMaxWidth().testTag("photos_folder_sharing_password"),
                label = { Text(stringResource(R.string.sp_sharing_new_password)) }, singleLine = true, enabled = enabled,
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() }))
        }
        if (original.snapshot.depth == 1) item {
            val label = stringResource(R.string.sp_folder_sharing_children)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(label, Modifier.weight(1f))
                Switch(state.appliesToSubfolders, model::applyToSubfolders, enabled = enabled,
                    modifier = Modifier.testTag("photos_folder_sharing_children").semantics { contentDescription = label })
            }
        }
        val change = state.change!!
        if (change.access == change.original.access && change.members?.associate { it.id to it.role } == change.original.members?.associate { it.id to it.role } &&
            change.password == SynologyPhotoSharingPassword.UNCHANGED) item {
            OutlinedButton(onClick = {
                clipboard.setText(AnnotatedString(original.url)); Toast.makeText(context, R.string.share_link_existing_copied, Toast.LENGTH_SHORT).show()
            }, enabled = !state.working, modifier = Modifier.fillMaxWidth().testTag("photos_folder_sharing_copy")) { Text(stringResource(R.string.sp_copy_link)) }
        }
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
        Button(onClick = { focus.clearFocus(); keyboard?.hide(); model.save() }, enabled = model.canSave,
            modifier = Modifier.testTag("photos_folder_sharing_save")) { Text(stringResource(R.string.save_changes)) }
    }
}

@Composable
private fun ColumnScope.FolderSharingMembers(state: SynologyPhotoFolderSharingState, model: SynologyPhotoFolderSharingModel) {
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    val existing = state.members.orEmpty().mapTo(mutableSetOf()) { it.id }
    val candidates = state.candidates.orEmpty().filter { it.id !in existing && it.name.contains(state.search.trim(), ignoreCase = true) }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_folder_sharing_candidates"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { TextButton(onClick = { focus.clearFocus(); keyboard?.hide(); model.closeMembers() }) { Text(stringResource(R.string.sp_sharing_back)) } }
        item { OutlinedTextField(state.search, model::search, Modifier.fillMaxWidth().testTag("photos_folder_sharing_search"),
            label = { Text(stringResource(R.string.sp_sharing_search)) }, singleLine = true, enabled = state.canEdit) }
        when {
            state.membersLoading -> item { CircularProgressIndicator() }
            state.membersError != null -> item {
                Text(folderSharingError(state.membersError), color = MaterialTheme.colorScheme.error)
                Button(onClick = { model.selectMembers() }, enabled = state.canEdit) { Text(stringResource(R.string.sp_retry)) }
            }
            candidates.isEmpty() -> item { Text(stringResource(if (state.search.isBlank()) R.string.sp_sharing_no_candidates else R.string.sp_sharing_no_search_results)) }
            else -> items(candidates, key = { "${it.id.type}:${it.id.value}" }) { recipient ->
                OutlinedButton(onClick = { model.add(recipient) }, enabled = state.canEdit, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(recipient.name)
                        Text(stringResource(if (recipient.id.type == "group") R.string.sp_sharing_group else R.string.sp_sharing_user), style = MaterialTheme.typography.bodySmall)
                    }
                    Text(stringResource(R.string.sp_sharing_add))
                }
            }
        }
    }
}

@Composable
private fun FolderSharingRecords(state: SynologyPhotoFolderSharingState, model: SynologyPhotoFolderSharingModel) {
    LazyColumn(Modifier.fillMaxSize().testTag("photos_folder_sharing_records"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (state.records.isEmpty() && !state.working) item { Text(stringResource(R.string.sp_folder_sharing_no_records)) }
        items(state.records, key = { it.id }) { record ->
            val row = record.checkpoint; val sharing = row.folderSharing!!
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(sharing.change.original.folder.name, style = MaterialTheme.typography.titleMedium)
                Text(stringResource(when {
                    sharing.rejected -> R.string.sp_folder_sharing_rejected
                    row.phase == SynologyPhotoAlbumPhase.COMPLETED -> R.string.sp_folder_sharing_done
                    row.phase == SynologyPhotoAlbumPhase.PARTIAL -> R.string.sp_folder_sharing_partial
                    row.submitted -> R.string.sp_folder_sharing_pending
                    else -> R.string.sp_request_not_sent
                }))
                if (state.working && state.activeId == record.id) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (!row.finished) Button(onClick = { model.resume(record.id) }, enabled = !state.working, modifier = Modifier.testTag("photos_folder_sharing_resume")) {
                    Text(stringResource(if (row.submitted) R.string.sp_edit_refresh else R.string.sp_request_reopen))
                }
                if (row.finished || !row.submitted) TextButton(onClick = { model.discard(record.id) }, enabled = !state.working) { Text(stringResource(R.string.sp_edit_clear_record)) }
                HorizontalDivider()
            }
        }
    }
}

private fun SynologyPhotoFolderLinkAccess.folderSharingLabel() = when (this) {
    SynologyPhotoFolderLinkAccess.MANAGEMENT -> R.string.sp_folder_sharing_management
    SynologyPhotoFolderLinkAccess.INVITED -> R.string.sp_sharing_invited
    SynologyPhotoFolderLinkAccess.VIEW -> R.string.sp_sharing_view
    SynologyPhotoFolderLinkAccess.DOWNLOAD -> R.string.sp_sharing_download
}
private fun String.folderRoleLabel() = when (this) {
    "view" -> R.string.sp_sharing_role_view
    "download" -> R.string.sp_sharing_role_download
    "upload" -> R.string.sp_sharing_role_upload
    "manage" -> R.string.sp_folder_sharing_role_manage
    else -> R.string.sp_sharing_role_existing
}
@Composable
private fun folderSharingError(error: Throwable): String = stringResource(when {
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.STORAGE -> R.string.sp_folder_storage_failed
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.BUSY -> R.string.sp_edit_busy
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.PENDING -> R.string.sp_folder_conflict
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.PERMISSION -> R.string.sp_folder_sharing_permission
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_folder_sharing_changed
    else -> R.string.sp_folder_sharing_failed
})
