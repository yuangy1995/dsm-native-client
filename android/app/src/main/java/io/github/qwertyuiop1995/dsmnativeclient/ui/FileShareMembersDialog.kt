package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileShareMembersDialog(feature: FileSharingFeatureModel, state: FileSharingState) {
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val search = { focus.clearFocus(); keyboard?.hide(); feature.searchMembers() }
    ClientPageDialog(stringResource(R.string.file_share_named_members), feature::closeMembers) {
        Column(Modifier.fillMaxSize().testTag("file_share_members")) {
            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                ClientSearchField(state.memberQuery, feature::updateMemberQuery, stringResource(R.string.file_share_member_search), Modifier.weight(1f),
                    onSearch = search)
                IconButton(search) { Icon(Icons.Outlined.Search, stringResource(R.string.file_share_member_search)) }
            }
            when (val result = state.members) {
                Loadable.Idle, Loadable.Loading -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                is Loadable.Failed -> FileShareEmpty(Modifier.weight(1f), stringResource(R.string.file_share_member_failed), result.error.localize(LocalContext.current).combined,
                    stringResource(R.string.retry), { feature.searchMembers() })
                is Loadable.Ready -> if (result.value.items.isEmpty()) FileShareEmpty(Modifier.weight(1f), stringResource(R.string.file_share_member_empty),
                    stringResource(R.string.file_share_member_empty_hint), stringResource(R.string.file_share_clear_filter), { feature.searchMembers("") })
                else LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(12.dp)) {
                    items(result.value.items, key = { "${it.kind}:${it.name}" }) { member ->
                        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).toggleable(member in state.selectedMembers, role = Role.Checkbox,
                            onValueChange = { feature.selectMember(member) }).padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(member in state.selectedMembers, onCheckedChange = null)
                            Column(Modifier.weight(1f).padding(start = 8.dp)) {
                                Text(member.name)
                                Text(stringResource(if (member.kind == FileSharePrincipalKind.USER) R.string.file_share_member_user else R.string.file_share_member_group), style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                    if (result.value.nextOffset < result.value.total) item {
                        if (state.membersLoadingMore) LinearProgressIndicator(Modifier.fillMaxWidth())
                        else TextButton(feature::moreMembers, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.file_share_more_members)) }
                    }
                }
            }
            state.membersMoreFailure?.let { Text(it.localize(LocalContext.current).combined, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
            Button(feature::useMembers, Modifier.fillMaxWidth().padding(12.dp).heightIn(min = 48.dp), enabled = state.selectedMembers.isNotEmpty()) {
                Text(stringResource(R.string.file_share_use_members, state.selectedMembers.size))
            }
        }
    }
}
