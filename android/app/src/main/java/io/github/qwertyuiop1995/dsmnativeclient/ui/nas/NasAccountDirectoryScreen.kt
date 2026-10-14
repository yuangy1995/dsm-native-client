package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun NasAccountDirectoryScreen(username: String, model: NasDirectoryModel) {
    val state by model.state.collectAsStateWithLifecycle()
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var search by rememberSaveable { mutableStateOf("") }
    LaunchedEffect(model) { model.load() }
    DisposableEffect(model) { onDispose { model.leavePage() } }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(R.string.nas_accounts, R.string.user_groups, R.string.pc_activity).forEachIndexed { index, label ->
                FilterChip(selected = tab == index, onClick = { tab = index }, label = { Text(stringResource(label)) })
            }
        }
        Row(Modifier.padding(horizontal = 12.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(model::load, enabled = !state.busy && !state.loading) { Text(stringResource(R.string.refresh)) }
            if (tab < 2) OutlinedButton({ model.create(if (tab == 0) NasDirectoryKind.ACCOUNT else NasDirectoryKind.GROUP) },
                enabled = state.writable && (if (tab == 0) state.accounts != null else state.groups != null)) { Text(stringResource(if (tab == 0) R.string.nd_create_account else R.string.nd_create_group)) }
        }
        if (state.loading || state.busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(horizontal = 12.dp))
        state.failure?.let { DirectoryFailure(it, model::dismissFailure) }
        if (tab != 2 && state.records.any { !it.terminal }) Column(Modifier.padding(horizontal = 12.dp)) {
            Text(stringResource(R.string.nd_busy))
            TextButton({ tab = 2 }) { Text(stringResource(R.string.pc_activity)) }
        }
        if (tab < 2) OutlinedTextField(search, { search = it }, label = { Text(stringResource(R.string.nd_search)) }, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(12.dp))
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (tab == 2) {
                if (state.records.isEmpty()) item { Text(stringResource(R.string.nd_no_activity)) }
                items(state.records, key = { it.id }) { record ->
                    ClientGroup {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(stringResource(when (record.action) { NasDirectoryAction.CREATE -> if (record.kind == NasDirectoryKind.ACCOUNT) R.string.nd_create_account else R.string.nd_create_group
                                NasDirectoryAction.EDIT -> R.string.nd_save_changes; NasDirectoryAction.DELETE -> R.string.delete }))
                            Text(stringResource(when (record.stage) { NasDirectoryStage.COMPLETED -> R.string.nd_completed; NasDirectoryStage.REJECTED -> R.string.nd_rejected
                                else -> R.string.nd_unknown }))
                            if (record.terminal) TextButton({ model.discard(record.id) }, enabled = !state.busy) { Text(stringResource(R.string.nd_remove_record)) }
                            else OutlinedButton({ model.review(record.id) }, enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
                        }
                    }
                }
            } else if (tab == 0) {
                state.accountsFailure?.let { error -> item { DirectoryFailure(error, model::load, R.string.retry) } }
                val accounts = state.accounts?.filter { it.name.contains(search, true) || it.description.orEmpty().contains(search, true) || it.email.orEmpty().contains(search, true) }
                if (accounts?.isEmpty() == true) item { DirectoryEmpty(search.isNotBlank()) }
                items(accounts.orEmpty(), key = { it.name }) { account ->
                    val protected = account.name.equals(username, true) || account.name.lowercase(java.util.Locale.ROOT) in setOf("admin", "guest")
                    DirectoryItem(account.name, account.description, account.id, account.email, account.groups, if (account.disabledKnown) account.disabled else null,
                        state.writable && account.canEdit, state.writable && account.canDelete && !protected, { model.edit(account) }, { model.delete(account) })
                }
            } else {
                state.groupsFailure?.let { error -> item { DirectoryFailure(error, model::load, R.string.retry) } }
                val groups = state.groups?.filter { it.name.contains(search, true) || it.description.orEmpty().contains(search, true) }
                if (groups?.isEmpty() == true) item { DirectoryEmpty(search.isNotBlank()) }
                items(groups.orEmpty(), key = { it.name }) { group ->
                    val protected = group.name.lowercase(java.util.Locale.ROOT) in setOf("administrators", "users", "http")
                    DirectoryItem(group.name, group.description, group.id, null, null, null, state.writable && group.canEdit,
                        state.writable && group.canDelete && !protected, { model.edit(group) }, { model.delete(group) })
                }
            }
        }
    }
    state.editor?.let { draft -> DirectoryEditor(draft, state.groups, username, state.busy, state.failure, model::dismissEditor, model::save) }
    state.deletion?.let { value ->
        AlertDialog(onDismissRequest = model::dismissEditor, title = { Text(stringResource(R.string.nd_delete_title, value.name)) },
            text = { Text(stringResource(if (value.kind == NasDirectoryKind.ACCOUNT) R.string.nd_delete_account_risk else R.string.nd_delete_group_risk)) },
            confirmButton = { TextButton(model::confirmDelete, enabled = !state.busy) { Text(stringResource(R.string.delete)) } },
            dismissButton = { TextButton(model::dismissEditor, enabled = !state.busy) { Text(stringResource(R.string.cancel)) } })
    }
}
@Composable private fun DirectoryEmpty(filtered: Boolean) {
    Text(stringResource(if (filtered) R.string.nd_no_matches else R.string.directory_management_empty))
    Text(stringResource(if (filtered) R.string.nd_search_hint else R.string.nd_empty_hint))
}
@Composable private fun DirectoryItem(name: String, description: String?, id: Long?, email: String?, groups: List<String>?, disabled: Boolean?, canEdit: Boolean, canDelete: Boolean, edit: () -> Unit, delete: () -> Unit) {
    ClientGroup {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(name, style = MaterialTheme.typography.titleSmall)
            description?.takeIf { it.isNotEmpty() }?.let { Text(it) }
            id?.let { Text(stringResource(R.string.nd_identifier, it)) }
            disabled?.let { Text(stringResource(if (it) R.string.nd_disabled_status else R.string.nd_enabled_status)) }
            email?.takeIf { it.isNotEmpty() }?.let { Text(it) }
            groups?.takeIf { it.isNotEmpty() }?.let { Text(stringResource(R.string.nd_memberships, it.joinToString(", "))) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(edit, enabled = canEdit) { Text(stringResource(R.string.edit)) }
                OutlinedButton(delete, enabled = canDelete) { Text(stringResource(R.string.delete)) }
            }
        }
    }
}
@Composable private fun DirectoryFailure(error: Exception, onDismiss: (() -> Unit)?, actionLabel: Int = R.string.close) {
    Column(Modifier.padding(12.dp)) {
        Text(if (error is NasDirectoryFailure) stringResource(when (error.problem) {
            NasDirectoryProblem.INVALID -> R.string.nd_invalid; NasDirectoryProblem.INCOMPLETE -> R.string.nd_incomplete
            NasDirectoryProblem.CHANGED -> R.string.nd_changed; NasDirectoryProblem.PERMISSION -> R.string.nd_permission
            NasDirectoryProblem.BUSY -> R.string.nd_busy; NasDirectoryProblem.UNKNOWN -> R.string.nd_unknown
        }) else packageErrorText(error), color = MaterialTheme.colorScheme.error)
        if (onDismiss != null) TextButton(onDismiss) { Text(stringResource(actionLabel)) }
    }
}
@Composable private fun DirectoryEditor(initial: NasDirectoryChange, groups: List<NasGroup>?, username: String, busy: Boolean,
    failure: Exception?, onDismiss: () -> Unit, onSave: (NasDirectoryChange) -> Unit) {
    var draft by remember(initial) { mutableStateOf(initial) }
    var changeGroups by remember(initial) { mutableStateOf(false) }
    var selectedGroups by remember(initial) { mutableStateOf(initial.account?.groups.orEmpty()) }
    var confirmed by remember(initial) { mutableStateOf<NasDirectoryChange?>(null) }
    val isAccount = draft.kind == NasDirectoryKind.ACCOUNT
    val creating = draft.action == NasDirectoryAction.CREATE
    val isCurrent = !creating && draft.name.equals(username, true)
    val canChangeGroups = isAccount && !isCurrent && groups != null && (creating || initial.account?.groups != null)
    ClientSheet(stringResource(if (creating) { if (isAccount) R.string.nd_create_account else R.string.nd_create_group } else R.string.nd_edit_entry), onDismiss, dismissEnabled = !busy) {
        OutlinedTextField(draft.name, { draft = draft.copy(name = it) }, enabled = creating && !busy, singleLine = true,
            label = { Text(stringResource(R.string.nd_name)) }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(draft.description, { draft = draft.copy(description = it) }, enabled = !busy,
            label = { Text(stringResource(R.string.nd_description)) }, modifier = Modifier.fillMaxWidth())
        if (isAccount) {
            OutlinedTextField(draft.email, { draft = draft.copy(email = it) }, enabled = !busy, singleLine = true,
                label = { Text(stringResource(R.string.nd_email)) }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(draft.password, { draft = draft.copy(password = it) }, enabled = !busy, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                label = { Text(stringResource(if (creating) R.string.password else R.string.nd_new_password)) }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(draft.passwordConfirmation, { draft = draft.copy(passwordConfirmation = it) }, enabled = !busy, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                label = { Text(stringResource(R.string.nd_password_confirm)) }, modifier = Modifier.fillMaxWidth())
            if (!creating) Text(stringResource(R.string.nd_keep_password))
            PackageToggle(stringResource(R.string.nd_disabled), draft.disabled, !busy && !isCurrent) { draft = draft.copy(disabled = it) }
            if (canChangeGroups) {
                PackageToggle(stringResource(R.string.nd_change_groups), changeGroups, !busy) { changeGroups = it }
                if (changeGroups) groups.orEmpty().forEach { group ->
                    PackageToggle(group.name, group.name in selectedGroups, !busy) { checked -> selectedGroups = if (checked) selectedGroups + group.name else selectedGroups - group.name }
                }
            }
        }
        failure?.let { DirectoryFailure(it, null) }
        Button(onClick = {
            val value = draft.copy(name = if (creating) draft.name.trim() else draft.name,
                groups = if (changeGroups) selectedGroups else null, groupsBaseline = if (changeGroups) groups else null)
            if (creating || value.password.isNotEmpty() || initial.disabled != value.disabled || changeGroups) confirmed = value else onSave(value)
        }, enabled = !busy && draft.name.isNotBlank() && (!isAccount || (draft.password == draft.passwordConfirmation && (!creating || draft.password.isNotEmpty()))),
            modifier = Modifier.fillMaxWidth()) { Text(stringResource(if (creating) R.string.create else R.string.nd_save_changes)) }
    }
    confirmed?.let { value -> AlertDialog(onDismissRequest = { confirmed = null },
        title = { Text(stringResource(R.string.nd_access_title)) }, text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(value.name)
                if (creating) Text(stringResource(if (isAccount) R.string.nd_create_account_risk else R.string.nd_create_group_risk))
                if (!creating && value.password.isNotEmpty()) Text(stringResource(R.string.nd_password_risk))
                if (initial.disabled != value.disabled) Text(stringResource(if (value.disabled) R.string.nd_disable_risk else R.string.nd_enable_risk))
                if (changeGroups) Text(stringResource(R.string.nd_groups_risk))
            }
        }, confirmButton = { TextButton({ confirmed = null; onSave(value) }, enabled = !busy) { Text(stringResource(if (creating) R.string.create else R.string.nd_save_changes)) } },
        dismissButton = { TextButton({ confirmed = null }) { Text(stringResource(R.string.cancel)) } }) }
}
