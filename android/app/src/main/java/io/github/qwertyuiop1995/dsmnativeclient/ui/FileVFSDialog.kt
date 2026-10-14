package io.github.qwertyuiop1995.dsmnativeclient.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.files.FileVFSPending
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileVFSDialog(feature: FileVFSFeatureModel, onDownload: (FileVFSDownloadSource) -> Unit) {
    val state by feature.state.collectAsStateWithLifecycle()
    val screen = state.screen ?: return
    when (screen) {
        FileVFSScreen.MANAGER -> { FileVFSManager(feature, state); return }
        FileVFSScreen.BROWSER -> { FileVFSBrowser(feature, state, onDownload); return }
        else -> Unit
    }
    // 不保存密码；退出表单、切换协议或提交后销毁。
    var password by remember(screen, state.baseline, state.setup.protocolId) { mutableStateOf("") }
    var replacePassword by remember(screen, state.baseline) { mutableStateOf(false) }
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    fun save(accepted: Boolean) {
        focus.clearFocus(); keyboard?.hide()
        if (feature.save(if (state.baseline == null || replacePassword) password else null, accepted)) password = ""
    }
    val title = when (screen) {
        FileVFSScreen.EDITOR -> if (state.baseline == null) R.string.vfs_add_server else R.string.vfs_edit
        FileVFSScreen.CLOUD -> if (state.baseline == null) R.string.vfs_sign_in else R.string.vfs_sign_in_again
        FileVFSScreen.RECOVERY -> R.string.vfs_pending_title
        else -> vfsActionLabel(state.action)
    }
    ClientSheet(stringResource(title), feature::close, Modifier.testTag("vfs_editor"),
        dismissEnabled = !state.busy, canDismiss = { !feature.state.value.busy }) {
        if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        when (screen) {
            FileVFSScreen.EDITOR -> {
                when (val detail = state.detail) {
                    Loadable.Loading -> Box(Modifier.fillMaxWidth().heightIn(min = 200.dp)) { CircularProgressIndicator() }
                    is Loadable.Failed -> {
                        Text(detail.error.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error)
                        OutlinedButton({ feature.openEditor(state.baseline) }, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.retry)) }
                    }
                    else -> {
                        FileVFSFields(feature, state, password, { password = it }, replacePassword,
                            { replacePassword = it; password = "" })
                        if (state.outcome?.status != FileVFSOutcomeStatus.COMPLETED) Button({ save(false) },
                            Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("vfs_save"), enabled = feature.canSave(state.baseline == null || replacePassword)) {
                            Text(stringResource(R.string.vfs_save_connect))
                        }
                    }
                }
            }
            FileVFSScreen.CLOUD -> FileVFSCloudFields(feature, state)
            FileVFSScreen.ACTION -> {
                state.baseline?.let { Text(it.alias, style = MaterialTheme.typography.titleSmall); Text(it.protocolName); it.hostname?.let { address -> Text(address) } }
                when (state.action) {
                    is FileVFSChange.Disconnect -> Text(stringResource(R.string.vfs_disconnect_impact))
                    is FileVFSChange.RemoveSaved -> Text(stringResource(R.string.vfs_remove_impact))
                    else -> Unit
                }
                if (state.outcome?.status != FileVFSOutcomeStatus.COMPLETED) Button(feature::submitAction,
                    Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("vfs_confirm_action"), enabled = feature.canManage() && !state.submitted) {
                    Text(stringResource(vfsActionLabel(state.action)))
                }
            }
            FileVFSScreen.RECOVERY -> {
                state.pending.singleOrNull { it.id == state.recoveryId }?.let { record ->
                    Text(record.label(), style = MaterialTheme.typography.titleSmall)
                    Text(stringResource(R.string.vfs_pending))
                    Button(feature::review, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("vfs_review"), enabled = !state.busy) {
                        Text(stringResource(R.string.iso_refresh_status))
                    }
                }
            }
            else -> Unit
        }
        FileVFSFeedback(state)
        TextButton(feature::backToManager, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("vfs_back"), enabled = !state.busy) {
            Text(stringResource(R.string.vfs_back_to_connections))
        }
    }
    if (state.cleartextConfirmation) AlertDialog(onDismissRequest = feature::dismissCleartext,
        title = { Text(stringResource(R.string.vfs_cleartext_title)) }, text = { Text(stringResource(R.string.vfs_cleartext_impact)) },
        confirmButton = { TextButton({ save(true) }, Modifier.testTag("vfs_accept_cleartext")) { Text(stringResource(R.string.vfs_cleartext_accept)) } },
        dismissButton = { TextButton(feature::dismissCleartext) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun FileVFSManager(feature: FileVFSFeatureModel, state: FileVFSState) {
    var cloudMenu by remember { mutableStateOf(false) }
    ClientPageDialog(stringResource(R.string.vfs_title), feature::close) {
        Column(Modifier.fillMaxSize().testTag("vfs_manager")) {
            ClientSearchField(state.filter, feature::filter, stringResource(R.string.vfs_filter), Modifier.padding(12.dp).testTag("vfs_filter"))
            val all = (state.inventory as? Loadable.Ready)?.value?.profiles.orEmpty()
            val visible = all.filter { it.alias.contains(state.filter, true) || it.protocolName.contains(state.filter, true) || it.hostname?.contains(state.filter, true) == true }
            val pending = state.pending.filter { it.label().contains(state.filter, true) }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                PageStateContent(state.inventory.toPageUiState(isEmpty = { all.isEmpty() && state.pending.isEmpty() },
                    isFilteredEmpty = { visible.isEmpty() && pending.isEmpty() && (all.isNotEmpty() || state.pending.isNotEmpty()) }),
                    emptyTitle = stringResource(R.string.vfs_empty), emptyMessage = stringResource(R.string.vfs_empty_hint), emptyIcon = Icons.Outlined.FolderOpen,
                    filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint),
                    filteredEmptyIcon = Icons.Outlined.FolderOpen, onRetry = feature::reload) {
                    LazyColumn(Modifier.fillMaxSize().testTag("vfs_connections"), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(pending, key = { "pending_" + it.id }) { record ->
                            ClientGroup {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(record.label(), style = MaterialTheme.typography.titleSmall)
                                    Text(stringResource(R.string.vfs_pending_title))
                                    TextButton({ feature.openRecovery(record) }, Modifier.heightIn(min = 48.dp).testTag("vfs_open_recovery")) { Text(stringResource(R.string.iso_refresh_status)) }
                                }
                            }
                        }
                        items(visible, key = FileVFSProfile::id) { profile ->
                            ClientGroup {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(profile.alias, style = MaterialTheme.typography.titleSmall)
                                    Text(profile.protocolName); profile.hostname?.takeIf(String::isNotEmpty)?.let { Text(it) }
                                    Text(stringResource(when (profile.state) {
                                        FileVFSConnectionState.CONNECTED -> R.string.vfs_connected
                                        FileVFSConnectionState.DISCONNECTED -> R.string.vfs_disconnected
                                        else -> R.string.vfs_state_unavailable
                                    }), style = MaterialTheme.typography.bodySmall)
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        if (profile.state == FileVFSConnectionState.CONNECTED) {
                                            TextButton({ feature.browse(profile) }, Modifier.heightIn(min = 48.dp).testTag("vfs_browse")) { Text(stringResource(R.string.open)) }
                                            TextButton({ feature.openAction(FileVFSChange.Disconnect(profile)) }, Modifier.heightIn(min = 48.dp).testTag("vfs_disconnect"),
                                                enabled = feature.canManage()) { Text(stringResource(R.string.vfs_disconnect)) }
                                        } else if (profile.state == FileVFSConnectionState.DISCONNECTED) {
                                            TextButton({ feature.openAction(FileVFSChange.Connect(profile)) }, Modifier.heightIn(min = 48.dp).testTag("vfs_connect"),
                                                enabled = feature.canManage()) { Text(stringResource(R.string.vfs_connect)) }
                                            TextButton({ feature.openAction(FileVFSChange.RemoveSaved(profile)) }, Modifier.heightIn(min = 48.dp).testTag("vfs_remove"),
                                                enabled = feature.canManage()) { Text(stringResource(R.string.vfs_remove)) }
                                        }
                                        val option = feature.options().singleOrNull { it.id == profile.protocolId }
                                        if (option?.supportsServerSetup == true && profile.state != FileVFSConnectionState.UNKNOWN)
                                            TextButton({ feature.openEditor(profile) }, Modifier.heightIn(min = 48.dp).testTag("vfs_edit"), enabled = feature.canManage()) { Text(stringResource(R.string.edit)) }
                                        if (option?.supportsCloudAuthorization == true)
                                            TextButton({ feature.openCloud(profile.protocolId, profile) }, Modifier.heightIn(min = 48.dp).testTag("vfs_reauthorize"), enabled = feature.canManage()) {
                                                Text(stringResource(R.string.vfs_sign_in_again))
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!feature.canManage() && state.inventory is Loadable.Ready && state.pending.isEmpty())
                    Text(stringResource(R.string.vfs_management_unavailable), style = MaterialTheme.typography.bodySmall)
                val options = feature.options()
                if (state.inventory is Loadable.Ready && options.none { it.supportsServerSetup || it.supportsCloudAuthorization })
                    Text(stringResource(R.string.vfs_no_supported_types), style = MaterialTheme.typography.bodySmall)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(feature::reload, Modifier.heightIn(min = 48.dp).testTag("vfs_refresh"), enabled = state.inventory !is Loadable.Loading) { Text(stringResource(R.string.refresh)) }
                    if (options.any { it.supportsServerSetup }) OutlinedButton({ feature.openEditor() }, Modifier.heightIn(min = 48.dp).testTag("vfs_add_server"), enabled = feature.canManage()) {
                        Text(stringResource(R.string.vfs_add_server))
                    }
                    if (options.any { it.supportsCloudAuthorization }) Box {
                        OutlinedButton({ cloudMenu = true }, Modifier.heightIn(min = 48.dp).testTag("vfs_add_cloud"), enabled = feature.canManage()) { Text(stringResource(R.string.vfs_add_cloud)) }
                        DropdownMenu(cloudMenu, { cloudMenu = false }) {
                            options.filter(FileVFSProtocol::supportsCloudAuthorization).forEach { option ->
                                DropdownMenuItem(text = { Text(option.name) }, onClick = { cloudMenu = false; feature.openCloud(option.id) })
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FileVFSCloudFields(feature: FileVFSFeatureModel, state: FileVFSState) {
    val context = LocalContext.current
    val success = stringResource(R.string.vfs_callback_success); val failure = stringResource(R.string.vfs_callback_failure)
    fun openBrowser(url: String) { if (runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }.isFailure) feature.browserFailed() }
    LaunchedEffect(state.browserUrl) { state.browserUrl?.let(::openBrowser) }
    Text(feature.options().singleOrNull { it.id == state.setup.protocolId }?.name.orEmpty(), style = MaterialTheme.typography.titleSmall)
    if (state.cloudLoading) CircularProgressIndicator()
    else if (state.authorizedAccount != null) {
        Text(stringResource(R.string.vfs_account), style = MaterialTheme.typography.labelLarge); Text(state.authorizedAccount)
        if (state.baseline != null) Text(state.cloudAlias)
        else OutlinedTextField(state.cloudAlias, feature::cloudAlias, Modifier.fillMaxWidth().testTag("vfs_cloud_alias"),
            label = { Text(stringResource(R.string.vfs_alias)) }, singleLine = true, enabled = !state.busy && !state.submitted)
        Button(feature::saveCloud, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("vfs_cloud_save"), enabled = feature.canSaveCloud()) {
            Text(stringResource(R.string.vfs_save_connect))
        }
    } else if (state.cloudWaiting) {
        Text(stringResource(R.string.vfs_sign_in_waiting))
        OutlinedButton({ state.browserUrl?.let(::openBrowser) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("vfs_open_browser")) {
            Text(stringResource(R.string.vfs_open_browser))
        }
        TextButton(feature::cancelAuthorization, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("vfs_cancel_authorization")) { Text(stringResource(R.string.vfs_cancel_sign_in)) }
    } else if (!state.submitted) {
        Text(stringResource(R.string.vfs_sign_in_hint))
        Button({ feature.startAuthorization(success, failure) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("vfs_authorize"), enabled = feature.canManage()) {
            Text(stringResource(R.string.vfs_sign_in))
        }
    }
}

@Composable
private fun FileVFSFeedback(state: FileVFSState) {
    state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
    state.outcome?.takeUnless { state.screen == FileVFSScreen.RECOVERY && state.pending.any { it.id == state.recoveryId } }?.let {
        Text(stringResource(when (it.status) {
            FileVFSOutcomeStatus.COMPLETED -> R.string.vfs_completed
            FileVFSOutcomeStatus.UNKNOWN -> R.string.vfs_pending
            FileVFSOutcomeStatus.REJECTED -> R.string.vfs_rejected
        }), Modifier.testTag("vfs_result"))
    }
}

private fun FileVFSPending.label() = when (val value = change) {
    is FileVFSChange.Create -> value.setup.alias
    is FileVFSChange.CreateCloud -> value.identity.alias
    else -> value.baselineProfile?.alias.orEmpty()
}
private fun vfsActionLabel(change: FileVFSChange?) = when (change) {
    is FileVFSChange.Disconnect -> R.string.vfs_disconnect
    is FileVFSChange.RemoveSaved -> R.string.vfs_remove
    else -> R.string.vfs_connect
}
