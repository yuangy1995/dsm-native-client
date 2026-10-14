package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

/** 成员和目录均先编辑草稿；最终确认中保留这次实际修改的摘要。 */
@Composable
internal fun SynologyPhotoSharedMembers(model: SynologyPhotoSharedMembersModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    val title = when {
        state.directory != null -> R.string.sp_members_folders
        state.recordsPage -> R.string.sp_members_records
        state.adding -> R.string.sp_sharing_add_member
        else -> R.string.sp_members_title
    }
    ClientPageDialog(stringResource(title), { if (state.adding && state.directory == null) model.cancelAdd() else model.dismiss() }) {
        Column(Modifier.fillMaxSize()) {
            state.error?.let { Text(memberError(it), Modifier.fillMaxWidth().padding(16.dp), color = MaterialTheme.colorScheme.error) }
            when {
                state.directory != null -> MemberDirectories(state, model)
                state.recordsPage -> MemberRecords(state, model)
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                state.original == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Button(onClick = { model.load() }) { Text(stringResource(R.string.sp_retry)) }
                }
                !state.original!!.enabled -> Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) { Text(stringResource(R.string.sp_members_disabled)) }
                state.adding -> MemberCandidates(state, model)
                else -> MembersForm(state, model)
            }
        }
    }
    state.confirmation?.let { value -> AlertDialog(onDismissRequest = model::cancelConfirmation,
        title = { Text(stringResource(R.string.sp_members_confirm)) },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.sp_members_risk))
            val original = value.original.members.associateBy { it.id }
            val desired = value.desired.associateBy { it.id }
            (original.keys + desired.keys).filter { original[it] != desired[it] || value.folders.any { edit -> edit.member == it } }.forEach { id ->
                val member = desired[id]
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(state.names[id].orEmpty(), style = MaterialTheme.typography.titleSmall)
                    if (member == null) Text(stringResource(R.string.sp_members_removed))
                    else {
                        Text(stringResource(member.role.memberRoleLabel()))
                        Text(stringResource(if (member.autoBackup) R.string.sp_members_backup_on else R.string.sp_members_backup_off))
                        if (value.folders.any { it.member == id }) Text(stringResource(R.string.sp_members_directories_changed))
                    }
                }
            }
        } },
        confirmButton = { TextButton(onClick = { model.confirm() }, modifier = Modifier.testTag("photos_members_confirm")) { Text(stringResource(R.string.save_changes)) } },
        dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } }) }
}

@Composable
private fun ColumnScope.MembersForm(state: SynologyPhotoSharedMembersState, model: SynologyPhotoSharedMembersModel) {
    val focus = LocalFocusManager.current
    val members = state.members.filter { it.recipient.name.contains(state.keyword.trim(), ignoreCase = true) }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_members_form"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { OutlinedTextField(state.keyword, model::keyword, Modifier.fillMaxWidth().testTag("photos_members_search"),
            label = { Text(stringResource(R.string.sp_members_search)) }, singleLine = true) }
        item {
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { focus.clearFocus(); model.add() }, enabled = state.canEdit, modifier = Modifier.testTag("photos_members_add")) {
                    Text(stringResource(R.string.sp_sharing_add_member))
                }
                MemberBackupMenu(state, model)
            }
        }
        if (members.isEmpty()) item { Text(stringResource(if (state.members.isEmpty()) R.string.sp_members_empty else R.string.sp_sharing_no_search_results)) }
        items(members, key = { "${it.grant.id.type}:${it.grant.id.value}" }) { member ->
            val grant = member.grant; val tag = "${grant.id.type}_${grant.id.value}"
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    MemberName(member.recipient, Modifier.weight(1f))
                    if (grant.canEdit) IconButton(onClick = { model.remove(grant.id) }, enabled = state.canEdit, modifier = Modifier.testTag("photos_members_remove_$tag")) {
                        Icon(Icons.Outlined.Close, stringResource(R.string.sp_sharing_remove_member, member.recipient.name))
                    }
                }
                if (grant.canEdit) {
                    SharingChoice(stringResource(R.string.sp_sharing_role), stringResource(grant.role.memberRoleLabel()), memberRoles(),
                        state.canEdit, "photos_members_role_$tag") { model.role(grant.id, it) }
                    SettingsSwitch(stringResource(R.string.sp_members_backup), grant.autoBackup, state.canEdit && grant.role == "entry", "photos_members_backup_$tag") { model.backup(grant.id, it) }
                    if (grant.role == "entry") OutlinedButton(onClick = { focus.clearFocus(); model.editFolders(grant.id) }, enabled = state.canEdit,
                        modifier = Modifier.fillMaxWidth().testTag("photos_members_folders_$tag")) { Text(stringResource(R.string.sp_members_folders)) }
                } else {
                    Text(stringResource(grant.role.memberRoleLabel()))
                    Text(stringResource(if (grant.protected) R.string.sp_members_protected else R.string.sp_members_unknown), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                HorizontalDivider()
            }
        }
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
        Button(onClick = { focus.clearFocus(); model.save() }, enabled = model.canSave, modifier = Modifier.testTag("photos_members_save")) { Text(stringResource(R.string.save_changes)) }
    }
}

@Composable
private fun MemberBackupMenu(state: SynologyPhotoSharedMembersState, model: SynologyPhotoSharedMembersModel) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { expanded = true }, enabled = state.canEdit && state.members.any { it.grant.canEdit && it.grant.role == "entry" },
            modifier = Modifier.testTag("photos_members_backup_all")) { Text(stringResource(R.string.sp_members_backup)); Icon(Icons.Outlined.ExpandMore, null) }
        DropdownMenu(expanded, { expanded = false }) {
            listOf(true, false).forEach { enabled -> DropdownMenuItem(text = { Text(stringResource(if (enabled) R.string.sp_members_backup_all else R.string.sp_members_backup_none)) },
                onClick = { expanded = false; model.backup(null, enabled) }) }
        }
    }
}

@Composable
private fun MemberCandidates(state: SynologyPhotoSharedMembersState, model: SynologyPhotoSharedMembersModel) {
    var role by remember { mutableStateOf("entry") }
    val focus = LocalFocusManager.current
    val existing = state.members.mapTo(mutableSetOf()) { it.grant.id }
    val candidates = state.candidates.filter { it.id !in existing && !(it.id.type == "group" && it.name == "administrators") && it.name.contains(state.keyword.trim(), ignoreCase = true) }
    LazyColumn(Modifier.fillMaxSize().testTag("photos_members_candidates"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { TextButton(onClick = { focus.clearFocus(); model.cancelAdd() }) { Text(stringResource(R.string.sp_members_back)) } }
        item { OutlinedTextField(state.keyword, model::keyword, Modifier.fillMaxWidth().testTag("photos_members_candidate_search"), label = { Text(stringResource(R.string.sp_members_search)) }, singleLine = true) }
        item { SharingChoice(stringResource(R.string.sp_sharing_role), stringResource(role.memberRoleLabel()), memberRoles(), state.canEdit, "photos_members_new_role") { role = it } }
        when {
            state.candidatesLoading -> item { CircularProgressIndicator() }
            state.candidatesError != null -> item {
                Text(memberError(state.candidatesError), color = MaterialTheme.colorScheme.error)
                Button(onClick = { model.loadCandidates() }) { Text(stringResource(R.string.sp_retry)) }
            }
            candidates.isEmpty() -> item { Text(stringResource(if (state.keyword.isBlank()) R.string.sp_sharing_no_candidates else R.string.sp_sharing_no_search_results)) }
            else -> items(candidates, key = { "${it.id.type}:${it.id.value}" }) { candidate ->
                OutlinedButton(onClick = { focus.clearFocus(); model.choose(candidate, role) }, enabled = state.canEdit,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("photos_members_choose_${candidate.id.type}_${candidate.id.value}")) {
                    MemberName(candidate, Modifier.weight(1f)); Text(stringResource(R.string.sp_sharing_add))
                }
            }
        }
    }
}

@Composable
private fun MemberName(value: SynologyPhotoShareRecipient, modifier: Modifier = Modifier) {
    Column(modifier) {
        Text(value.name, style = MaterialTheme.typography.titleSmall)
        Text(stringResource(if (value.id.type == "group") R.string.sp_sharing_group else R.string.sp_sharing_user), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun MemberRecords(state: SynologyPhotoSharedMembersState, model: SynologyPhotoSharedMembersModel) {
    LazyColumn(Modifier.fillMaxSize().testTag("photos_members_records"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { OutlinedButton(onClick = model::open, enabled = !state.working, modifier = Modifier.testTag("photos_members_reopen")) { Text(stringResource(R.string.sp_members_back)) } }
        if (state.records.isEmpty() && !state.working) item { Text(stringResource(R.string.sp_members_no_records)) }
        items(state.records, key = { it.id }) { record ->
            val row = record.checkpoint
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(when (row.phase) {
                    SynologyPhotoAlbumPhase.COMPLETED -> R.string.sp_members_saved
                    SynologyPhotoAlbumPhase.PARTIAL -> R.string.sp_members_partial
                    SynologyPhotoAlbumPhase.READY -> R.string.sp_request_not_sent
                    else -> R.string.sp_settings_pending
                }))
                if (state.working && state.activeId == record.id) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (!row.finished) Button(onClick = { model.resume(record.id) }, enabled = !state.working, modifier = Modifier.testTag("photos_members_resume")) {
                    Text(stringResource(if (row.submitted) R.string.sp_edit_refresh else R.string.sp_request_reopen))
                }
                if (row.finished || !row.submitted) TextButton(onClick = { model.discard(record.id) }, enabled = !state.working) { Text(stringResource(R.string.sp_edit_clear_record)) }
                HorizontalDivider()
            }
        }
    }
}

@Composable
private fun memberRoles() = listOf("entry", "management").map { it to stringResource(it.memberRoleLabel()) }
private fun String.memberRoleLabel() = when (this) { "entry" -> R.string.sp_members_entry; "management" -> R.string.sp_members_management; else -> R.string.sp_sharing_role_existing }
@Composable
internal fun memberError(error: Throwable): String = stringResource(when {
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.STORAGE -> R.string.sp_folder_storage_failed
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.BUSY -> R.string.sp_edit_busy
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.PENDING -> R.string.sp_settings_conflict
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_members_changed
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.PERMISSION -> R.string.sp_members_permission
    else -> R.string.sp_members_failed
})
