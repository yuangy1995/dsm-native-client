package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
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
internal fun FilePermissionMembersDialog(feature: FilePermissionFeatureModel, state: FilePermissionState) {
    ClientPageDialog(stringResource(R.string.file_permissions_choose_member), feature::closeMembers) {
        val focus = LocalFocusManager.current
        val keyboard = LocalSoftwareKeyboardController.current
        val finishInput = { focus.clearFocus(); keyboard?.hide(); Unit }
        val acl = (state.snapshot as? Loadable.Ready)?.value?.isACL == true
        val page = (state.members as? Loadable.Ready)?.value
        val items = page?.items?.filter {
            when (state.memberPurpose) {
                FilePermissionMemberPurpose.GROUP -> it.kind == FileSharePrincipalKind.GROUP
                FilePermissionMemberPurpose.OWNER -> acl || it.kind == FileSharePrincipalKind.USER
                else -> true
            }
        }.orEmpty()
        Column(Modifier.fillMaxSize().testTag("permission_members")) {
            ClientSearchField(state.memberQuery, feature::updateMemberQuery, stringResource(R.string.file_share_member_search),
                Modifier.padding(12.dp).testTag("permission_member_query"), onSearch = feature::searchMembers)
            Box(Modifier.weight(1f).fillMaxWidth()) {
                PageStateContent(state.members.toPageUiState(isEmpty = { it.items.isEmpty() && state.memberResultQuery.isEmpty() },
                    isFilteredEmpty = { items.isEmpty() && (it.items.isNotEmpty() || state.memberResultQuery.isNotEmpty()) }),
                    emptyTitle = stringResource(R.string.file_share_member_empty), emptyMessage = stringResource(R.string.file_permissions_no_members_hint), emptyIcon = Icons.Outlined.Person,
                    filteredEmptyTitle = stringResource(R.string.file_share_member_empty), filteredEmptyMessage = stringResource(R.string.file_share_member_empty_hint), filteredEmptyIcon = Icons.Outlined.Person,
                    onRetry = { finishInput(); feature.searchMembers() }) {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(items, key = { "${it.kind}:${it.name}" }) { member -> ListItem(
                            headlineContent = { Text(member.name) },
                            supportingContent = { Text(stringResource(if (member.kind == FileSharePrincipalKind.USER) R.string.file_share_member_user else R.string.file_share_member_group)) },
                            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button) { finishInput(); feature.selectMember(member) }) }
                    }
                }
            }
            state.membersMoreFailure?.let { Text(it.localize(LocalContext.current).combined, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
            if (page != null && page.nextOffset < page.total) {
                if (state.membersLoadingMore) LinearProgressIndicator(Modifier.fillMaxWidth())
                else TextButton({ finishInput(); feature.moreMembers() }, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.file_share_more_members)) }
            }
        }
    }
}
