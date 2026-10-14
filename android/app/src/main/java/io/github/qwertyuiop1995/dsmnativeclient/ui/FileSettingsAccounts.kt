package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.People
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun ColumnScope.FileSettingsAccountList(feature: FileSettingsFeatureModel, state: FileSettingsState) {
    Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (state.screen == FileSettingsScreen.BANDWIDTH) FileSettingsChoice(stringResource(R.string.file_settings_account_type), state.bandwidthType,
            FileBandwidthOwner.entries, { stringResource(it.label()) }, feature::bandwidthType, !state.busy, "settings_bandwidth_type")
        else {
            if (state.screen == FileSettingsScreen.MOUNT_ACCOUNTS) {
                when (val directories = state.directories) {
                    is Loadable.Ready -> {
                        if (directories.value.items.size > 1) FileSettingsChoice(stringResource(R.string.file_settings_directory), state.source,
                            directories.value.items.map { it.source }, { source -> when (source.kind) {
                                FileMountSourceKind.LOCAL -> stringResource(R.string.file_settings_local_directory)
                                FileMountSourceKind.LDAP -> stringResource(R.string.file_settings_ldap_directory)
                                FileMountSourceKind.DOMAIN -> directories.value.items.singleOrNull { it.source == source }?.name.orEmpty()
                            } }, feature::source, !state.busy, "settings_source")
                        if (directories.value.hasUnavailableSources) Text(stringResource(R.string.file_settings_sources_unavailable), style = MaterialTheme.typography.bodySmall)
                    }
                    is Loadable.Failed -> Text(directories.error.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error)
                    else -> LinearProgressIndicator(Modifier.fillMaxWidth())
                }
            }
            FileSettingsChoice(stringResource(R.string.file_settings_account_type), state.accountKind, FileSharePrincipalKind.entries,
                { stringResource(if (it == FileSharePrincipalKind.USER) R.string.file_settings_users else R.string.file_settings_groups) },
                feature::accountKind, !state.busy, "settings_account_kind")
        }
        ClientSearchField(state.query, feature::query, stringResource(if (state.screen == FileSettingsScreen.BANDWIDTH) R.string.file_settings_filter_loaded else R.string.file_settings_search_accounts),
            Modifier.testTag("settings_account_search"), feature::search)
    }
    Box(Modifier.weight(1f).fillMaxWidth()) {
        when (state.screen) {
            FileSettingsScreen.POLICY_ACCOUNTS -> SettingsAccountRows(state.policyAccounts, state.appliedQuery.isNotEmpty(), { it.id.kind.name + ":" + it.id.value }, { true }, feature::reload) { row ->
                val selected = if (state.requestAccounts) state.generalDraft?.requestAccounts.orEmpty() else state.generalDraft?.sharingAccounts.orEmpty()
                ClientGroup {
                    FileSettingsToggle(row.name, row.id in selected, { feature.togglePolicyAccount(row) }, feature.canChoosePolicyAccounts() && !row.administrator, "settings_policy_${row.id.kind}_${row.id.value}")
                    if (row.administrator) Text(stringResource(R.string.file_settings_admin_access), Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp), style = MaterialTheme.typography.bodySmall)
                }
            }
            FileSettingsScreen.MOUNT_ACCOUNTS -> SettingsAccountRows(state.mountAccounts, state.appliedQuery.isNotEmpty(), { it.id.kind.name + ":" + it.id.value }, { true }, feature::reload) { row ->
                ClientGroup { ClientRow(row.name, Icons.Outlined.People, stringResource(if (row.enabled) R.string.file_settings_access_allowed else R.string.file_settings_access_denied), enabled = !state.busy) { feature.editMountAccount(row) } }
            }
            FileSettingsScreen.BANDWIDTH -> SettingsAccountRows(state.bandwidth, state.query.isNotEmpty(), { it.name }, { it.name.contains(state.query, true) }, feature::reload) { row ->
                ClientGroup { ClientRow(row.name, Icons.Outlined.People, stringResource(row.policy.label(row.ownerType.isGroup)), enabled = !state.busy) { feature.editBandwidth(row) } }
            }
            else -> Unit
        }
    }
    Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FileSettingsFeedback(state)
        state.nextPageFailure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
        val hasMore = when (state.screen) {
            FileSettingsScreen.POLICY_ACCOUNTS -> (state.policyAccounts as? Loadable.Ready)?.value?.let { it.nextOffset < it.total }
            FileSettingsScreen.MOUNT_ACCOUNTS -> (state.mountAccounts as? Loadable.Ready)?.value?.let { it.nextOffset < it.total }
            FileSettingsScreen.BANDWIDTH -> (state.bandwidth as? Loadable.Ready)?.value?.let { it.nextOffset < it.total }
            else -> false
        } == true
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(feature::reload, Modifier.heightIn(min = 48.dp).testTag("settings_refresh_accounts"), enabled = !state.busy && !state.loadingMore) { Text(stringResource(R.string.refresh)) }
            if (hasMore) OutlinedButton(feature::more, Modifier.heightIn(min = 48.dp).testTag("settings_more"), enabled = !state.busy && !state.loadingMore) { Text(stringResource(R.string.file_settings_more)) }
            if (state.screen == FileSettingsScreen.POLICY_ACCOUNTS) OutlinedButton(feature::back, Modifier.heightIn(min = 48.dp).testTag("settings_accounts_done"), enabled = !state.busy) { Text(stringResource(R.string.file_settings_accounts_done)) }
        }
        if (state.loadingMore) LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
private fun <T> SettingsAccountRows(value: Loadable<FileSettingsPage<T>>, hasQuery: Boolean, key: (T) -> Any,
                                   matches: (T) -> Boolean, retry: () -> Unit, row: @Composable (T) -> Unit) {
    PageStateContent(value.toPageUiState(isEmpty = { it.items.isEmpty() && !hasQuery }, isFilteredEmpty = { hasQuery && it.items.none(matches) }),
        emptyTitle = stringResource(R.string.file_settings_accounts_empty), emptyMessage = stringResource(R.string.file_settings_accounts_empty_hint), emptyIcon = Icons.Outlined.People,
        filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.People, onRetry = retry) { page ->
        LazyColumn(Modifier.fillMaxSize().testTag("settings_account_rows"), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(page.items.filter(matches), key = key) { row(it) }
        }
    }
}
