package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.files.FileSettingsOutcomeStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileSettingsDialog(feature: FileSettingsFeatureModel) {
    val state by feature.state.collectAsStateWithLifecycle()
    val screen = state.screen ?: return
    val picker by feature.themePicker.state.collectAsStateWithLifecycle()
    if (picker.kind != null) { FileThemePickerDialog(feature.themePicker, picker); return }
    val title = when (screen) {
        FileSettingsScreen.ROOT -> R.string.file_settings_title
        FileSettingsScreen.GENERAL -> R.string.file_settings_general
        FileSettingsScreen.POLICY_ACCOUNTS -> if (state.requestAccounts) R.string.file_settings_request_accounts else R.string.file_settings_share_accounts
        FileSettingsScreen.MOUNT_SCOPE -> R.string.file_settings_remote_access
        FileSettingsScreen.MOUNT_ACCOUNTS, FileSettingsScreen.MOUNT_ACCOUNT -> R.string.file_settings_manage_accounts
        FileSettingsScreen.BANDWIDTH, FileSettingsScreen.BANDWIDTH_EDITOR -> R.string.file_settings_bandwidth
        FileSettingsScreen.THEME -> R.string.file_theme_title
    }
    ClientPageDialog(stringResource(title), feature::back) {
        Column(Modifier.fillMaxSize().testTag("file_settings_page")) {
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            when (screen) {
                FileSettingsScreen.ROOT -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    ClientGroup {
                        if (feature.supportsGeneral()) ClientRow(stringResource(R.string.file_settings_general), Icons.Outlined.Settings) { feature.show(FileSettingsScreen.GENERAL) }
                        if (feature.supportsMountAccess()) ClientRow(stringResource(R.string.file_settings_remote_access), Icons.Outlined.People) { feature.show(FileSettingsScreen.MOUNT_SCOPE) }
                        if (feature.supportsBandwidth()) ClientRow(stringResource(R.string.file_settings_bandwidth), Icons.Outlined.Speed) { feature.show(FileSettingsScreen.BANDWIDTH) }
                        if (feature.supportsTheme()) ClientRow(stringResource(R.string.file_theme_title), Icons.Outlined.Palette) { feature.show(FileSettingsScreen.THEME) }
                    }
                    FileSettingsFeedback(state)
                    if (state.failure != null) OutlinedButton(feature::reload, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.retry)) }
                }
                FileSettingsScreen.POLICY_ACCOUNTS, FileSettingsScreen.MOUNT_ACCOUNTS, FileSettingsScreen.BANDWIDTH ->
                    FileSettingsAccountList(feature, state)
                else -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    when (screen) {
                        FileSettingsScreen.GENERAL -> FileSettingsLoad(state.general, feature::reload) { FileSettingsGeneralForm(feature, state) }
                        FileSettingsScreen.MOUNT_SCOPE -> FileSettingsLoad(state.mountScope, feature::reload) {
                            state.mountDraft?.let { value -> FileSettingsChoice(stringResource(R.string.file_settings_remote_access), value,
                                FileMountScope.entries, { stringResource(it.label()) }, feature::mountScope, feature.canEdit(), "settings_mount_scope") }
                            OutlinedButton(feature::openMountAccounts, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("settings_mount_accounts"), enabled = !state.busy) {
                                Text(stringResource(R.string.file_settings_manage_accounts))
                            }
                        }
                        FileSettingsScreen.MOUNT_ACCOUNT -> state.mountAccount?.let { row ->
                            Text(row.name, style = MaterialTheme.typography.titleMedium)
                            FileSettingsToggle(stringResource(R.string.file_settings_account_allowed), state.accountEnabled, feature::accountEnabled,
                                feature.canEdit() && row.canModify, "settings_account_enabled")
                            if (!row.canModify) Text(stringResource(R.string.file_settings_account_locked), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        FileSettingsScreen.BANDWIDTH_EDITOR -> FileSettingsBandwidthForm(feature, state)
                        FileSettingsScreen.THEME -> FileSettingsLoad(state.theme, feature::reload) { FileThemeForm(feature, state) }
                        else -> Unit
                    }
                    FileSettingsFeedback(state)
                    if (feature.pendingCurrent()) {
                        Text(stringResource(R.string.file_settings_pending))
                        Button(feature::review, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("settings_review"), enabled = !state.busy) {
                            Text(stringResource(R.string.refresh))
                        }
                    } else if (feature.currentChange(true) != null) {
                        feature.currentChange()?.let { FileSettingsChangesSummary(it) }
                        Button(feature::prepareSave, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("settings_save"), enabled = feature.canSave()) {
                            Text(stringResource(R.string.file_settings_save))
                        }
                        if (screen in setOf(FileSettingsScreen.GENERAL, FileSettingsScreen.MOUNT_SCOPE, FileSettingsScreen.THEME)) OutlinedButton(feature::reload,
                            Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("settings_refresh"), enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
                    }
                }
            }
        }
    }
    state.confirmation?.let { change ->
        AlertDialog(onDismissRequest = feature::dismissConfirmation, title = { Text(stringResource(R.string.file_settings_confirm_access)) },
            text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                change.risks().forEach { risk -> Text(stringResource(when (risk) {
                    FileSettingsRisk.SHARING -> R.string.file_settings_risk_sharing
                    FileSettingsRisk.FILE_REQUESTS -> R.string.file_settings_risk_requests
                    FileSettingsRisk.REMOTE_MOUNTS -> R.string.file_settings_risk_remote
                    FileSettingsRisk.ISO_MOUNTS -> R.string.file_settings_risk_iso
                    FileSettingsRisk.ACCOUNT_NAMES -> R.string.file_settings_risk_accounts
                })) }
                FileSettingsChangesSummary(change)
            } }, confirmButton = { TextButton(feature::submit, Modifier.testTag("settings_confirm_save")) { Text(stringResource(R.string.file_settings_save)) } },
            dismissButton = { TextButton(feature::dismissConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
internal fun <T> FileSettingsLoad(value: Loadable<T>, retry: () -> Unit, content: @Composable (T) -> Unit) {
    when (value) {
        is Loadable.Ready -> content(value.value)
        is Loadable.Failed -> Column(Modifier.fillMaxWidth().heightIn(min = 240.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(value.error.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error)
            OutlinedButton(retry, Modifier.heightIn(min = 48.dp).testTag("settings_retry")) { Text(stringResource(R.string.retry)) }
        }
        else -> Box(Modifier.fillMaxWidth().heightIn(min = 240.dp), contentAlignment = androidx.compose.ui.Alignment.Center) { CircularProgressIndicator() }
    }
}
@Composable
internal fun FileSettingsFeedback(state: FileSettingsState) {
    state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
    state.outcome?.let { result ->
        Text(if (result.failure != null) result.failure.localize(LocalContext.current).combined else stringResource(when (result.status) {
            FileSettingsOutcomeStatus.COMPLETED -> R.string.file_settings_saved
            FileSettingsOutcomeStatus.UNKNOWN -> R.string.file_settings_pending
            FileSettingsOutcomeStatus.REJECTED -> R.string.file_settings_save_failed
        }), Modifier.testTag("settings_feedback"))
    }
}
