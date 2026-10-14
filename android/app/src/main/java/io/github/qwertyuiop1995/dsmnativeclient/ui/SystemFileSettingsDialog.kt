package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun SystemFileSettingsDialog(feature: SystemFileSettingsModel) {
    val state by feature.state.collectAsStateWithLifecycle()
    if (!state.visible) return
    SystemFileSettingsContent(state, feature::hide, feature::reload, feature::filter, feature::setEnabled, feature::signIn, feature::requestEditing)
    state.confirmEditing?.let { row -> AlertDialog(onDismissRequest = feature::dismissEditing,
        title = { Text(stringResource(R.string.system_files_allow_editing)) },
        text = { Text(stringResource(R.string.system_files_edit_confirm, row.profile.name)) },
        confirmButton = { TextButton(feature::allowEditing, Modifier.heightIn(min = 48.dp).testTag("system_files_confirm_edit")) { Text(stringResource(R.string.system_files_allow_editing)) } },
        dismissButton = { TextButton(feature::dismissEditing, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) } }) }
}

@Composable
internal fun SystemFileSettingsContent(state: SystemFileSettingsState, close: () -> Unit, retry: () -> Unit,
    filter: (String) -> Unit, enabled: (String, Boolean) -> Unit, signIn: (String) -> Unit, editing: (String, Boolean) -> Unit,
) {
    ClientPageDialog(stringResource(R.string.system_files_title), { if (!state.busy) close() }) {
        Column(Modifier.fillMaxSize().testTag("system_files_settings")) {
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.failure?.let { Text(it.localize(LocalContext.current).combined, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) }
            state.notice?.let { Text(stringResource(it), Modifier.padding(16.dp)) }
            when (val rows = state.rows) {
                Loadable.Idle, Loadable.Loading -> Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) { CircularProgressIndicator() }
                is Loadable.Failed -> Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) {
                    Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(rows.error.localize(LocalContext.current).combined)
                        TextButton(retry, Modifier.heightIn(min = 48.dp), enabled = !state.busy) { Text(stringResource(R.string.retry)) }
                    }
                }
                is Loadable.Ready -> if (rows.value.isEmpty()) Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) {
                    EmptyState(stringResource(R.string.system_files_empty), stringResource(R.string.shared_sign_in_first), Icons.Outlined.Folder)
                } else {
                    if (rows.value.size > 1) OutlinedTextField(state.filter, filter, Modifier.fillMaxWidth().padding(16.dp), singleLine = true,
                        label = { Text(stringResource(R.string.system_files_find_connection)) })
                    val visible = if (rows.value.size == 1) rows.value else rows.value.filter { it.profile.name.contains(state.filter.trim(), true) }
                    if (visible.isEmpty()) Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) {
                        Text(stringResource(R.string.system_files_no_matches), Modifier.padding(24.dp))
                    } else LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(visible, key = { it.profile.id }) { row -> ClientGroup {
                            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(row.profile.name, style = MaterialTheme.typography.titleMedium)
                                val showLabel = stringResource(R.string.system_files_show_name, row.profile.name)
                                val editLabel = stringResource(R.string.system_files_edit_name, row.profile.name)
                                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                    Text(stringResource(R.string.system_files_show), Modifier.weight(1f))
                                    Switch(row.location?.enabled == true, { enabled(row.profile.id, it) },
                                        Modifier.heightIn(min = 48.dp).semantics { contentDescription = showLabel }.testTag("system_files_enable_${row.profile.id}"), enabled = !state.busy && (row.connected || row.location?.enabled == true))
                                }
                                if (!row.connected) TextButton({ signIn(row.profile.id) }, Modifier.heightIn(min = 48.dp), enabled = !state.busy) {
                                    Text(stringResource(R.string.system_files_sign_in))
                                }
                                if (row.location?.enabled == true) {
                                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                        Text(stringResource(R.string.system_files_allow_editing), Modifier.weight(1f))
                                        Switch(row.location.editing, { editing(row.profile.id, it) }, Modifier.heightIn(min = 48.dp).semantics { contentDescription = editLabel }
                                            .testTag("system_files_edit_${row.profile.id}"), enabled = !state.busy && (row.connected || row.location.editing))
                                    }
                                    Text(stringResource(if (row.location.editing) R.string.system_files_edit_hint else R.string.system_files_read_only),
                                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        } }
                    }
                }
            }
            TextButton(close, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = !state.busy) { Text(stringResource(R.string.close)) }
        }
    }
}
