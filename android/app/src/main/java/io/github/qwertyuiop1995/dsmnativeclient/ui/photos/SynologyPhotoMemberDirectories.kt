package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
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

@Composable
internal fun ColumnScope.MemberDirectories(state: SynologyPhotoSharedMembersState, model: SynologyPhotoSharedMembersModel) {
    val draft = state.directory ?: return
    val edit = draft.edit
    val focus = LocalFocusManager.current
    val search = draft.keyword.trim()
    val childrenByParent = remember(draft.folders) { draft.folders.filter { it.snapshot.depth == 1 }.groupBy { it.snapshot.parentId } }
    val visible = remember(draft.folders, draft.expanded, search) { buildList {
        draft.folders.filter { it.snapshot.depth == 0 }.forEach { root ->
            val children = childrenByParent[root.snapshot.id].orEmpty()
            val rootMatches = root.path.contains(search, ignoreCase = true)
            val matchingChildren = children.filter { rootMatches || it.path.contains(search, ignoreCase = true) }
            if (rootMatches || matchingChildren.isNotEmpty()) {
                add(root)
                if (search.isNotEmpty() || root.snapshot.id in draft.expanded) addAll(matchingChildren)
            }
        }
    } }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_members_directories"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { Text(draft.member.recipient.name, style = MaterialTheme.typography.titleMedium) }
        when {
            draft.loading -> item { CircularProgressIndicator() }
            draft.error != null -> item {
                Text(memberError(draft.error), color = MaterialTheme.colorScheme.error)
                Button(onClick = { model.loadFolders() }) { Text(stringResource(R.string.sp_retry)) }
            }
            edit != null -> {
                item { OutlinedTextField(draft.keyword, model::folderKeyword, Modifier.fillMaxWidth().testTag("photos_members_folder_search"),
                    label = { Text(stringResource(R.string.sp_members_folder_search)) }, singleLine = true) }
                item { MemberFolderBatchMenu(edit, state.canEdit, model) }
                if (draft.childrenCleared) item { Text(stringResource(R.string.sp_members_children_cleared), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                if (visible.isEmpty()) item { Text(stringResource(if (draft.folders.isEmpty()) R.string.sp_members_no_folders else R.string.sp_members_no_matches)) }
                items(visible, key = { it.snapshot.id }) { folder ->
                    MemberDirectoryRow(folder, edit, state.canEdit, folder.snapshot.id in draft.expanded,
                        childrenByParent[folder.snapshot.id].isNullOrEmpty().not(), model)
                }
            }
        }
    }
    HorizontalDivider()
    FlowRow(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { focus.clearFocus(); model.cancelFolders() }, modifier = Modifier.testTag("photos_members_folder_cancel")) { Text(stringResource(R.string.cancel)) }
        Button(onClick = { focus.clearFocus(); model.finishFolders() }, enabled = state.canEdit && !draft.loading && draft.error == null && edit != null,
            modifier = Modifier.testTag("photos_members_folder_done")) { Text(stringResource(R.string.done)) }
    }
}

@Composable
private fun MemberDirectoryRow(folder: SynologyPhotoMemberFolder, edit: SynologyPhotoMemberFolderEdit, enabled: Boolean, expanded: Boolean, hasChildren: Boolean, model: SynologyPhotoSharedMembersModel) {
    val item = folder.snapshot
    Column(Modifier.fillMaxWidth().padding(start = if (item.depth == 1) 24.dp else 0.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (item.depth == 0 && hasChildren) IconButton(onClick = { model.expand(item.id) }, modifier = Modifier.testTag("photos_members_expand_${item.id}")) {
                Icon(if (expanded) Icons.Outlined.ExpandMore else Icons.Outlined.ChevronRight, stringResource(if (expanded) R.string.sp_members_collapse else R.string.sp_members_expand))
            }
            Text(folder.path, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
        }
        item.publicRole?.let { role -> Text(stringResource(R.string.sp_members_public_minimum, stringResource(role.memberFolderLabel())),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        if (item.known) {
            val role = SynologyPhotoFolderMemberRole.from(edit.expectedRole(item))
            SharingChoice(stringResource(R.string.sp_members_direct_role), stringResource(role?.memberFolderLabel() ?: R.string.sp_members_no_direct),
                listOf(null to stringResource(R.string.sp_members_no_direct)) + SynologyPhotoFolderMemberRole.entries.map { it to stringResource(it.memberFolderLabel()) },
                enabled && edit.canEdit(item), "photos_members_folder_role_${item.id}") { model.folderRole(item.id, it) }
            if (!edit.canEdit(item)) Text(stringResource(R.string.sp_members_parent_required), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else Text(stringResource(R.string.sp_members_unknown), color = MaterialTheme.colorScheme.onSurfaceVariant)
        HorizontalDivider()
    }
}

@Composable
private fun MemberFolderBatchMenu(edit: SynologyPhotoMemberFolderEdit, enabled: Boolean, model: SynologyPhotoSharedMembersModel) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { expanded = true }, enabled = enabled && edit.original.isNotEmpty() && edit.original.all { it.known },
            modifier = Modifier.fillMaxWidth().testTag("photos_members_folder_all")) { Text(stringResource(R.string.sp_members_all_folders)); Icon(Icons.Outlined.ExpandMore, null) }
        DropdownMenu(expanded, { expanded = false }) {
            SynologyPhotoFolderMemberRole.entries.forEach { role ->
                listOf(true, false).forEach { grant -> DropdownMenuItem(text = { Text(stringResource(if (grant) R.string.sp_members_grant_all else R.string.sp_members_revoke_all, stringResource(role.memberFolderLabel()))) },
                    onClick = { expanded = false; model.batch(role, grant) }, modifier = Modifier.testTag("photos_members_batch_${role.name}_$grant")) }
            }
        }
    }
}

private fun SynologyPhotoFolderMemberRole.memberFolderLabel() = when (this) {
    SynologyPhotoFolderMemberRole.VIEW -> R.string.sp_sharing_role_view
    SynologyPhotoFolderMemberRole.DOWNLOAD -> R.string.sp_sharing_role_download
    SynologyPhotoFolderMemberRole.UPLOAD -> R.string.sp_sharing_role_upload
    SynologyPhotoFolderMemberRole.MANAGE -> R.string.sp_folder_sharing_role_manage
}
