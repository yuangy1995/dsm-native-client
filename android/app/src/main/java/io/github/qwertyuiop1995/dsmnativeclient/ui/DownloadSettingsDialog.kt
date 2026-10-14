package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.selection.toggleable

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import io.github.qwertyuiop1995.dsmnativeclient.DownloadSettingsDraftState
import io.github.qwertyuiop1995.dsmnativeclient.DownloadSettingsWorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize

internal typealias DownloadSettingsDraft = DownloadSettingsDraftState

internal data class DownloadSettingsFeedbackPolicy(
    @StringRes val title: Int,
    @StringRes val message: Int,
    val assertive: Boolean,
)

internal fun downloadSettingsFeedbackPolicy(result: MutationResult): DownloadSettingsFeedbackPolicy = when (
    result.status
) {
    MutationResultStatus.CONFIRMED_SUCCESS -> DownloadSettingsFeedbackPolicy(
        R.string.download_settings_feedback_confirmed_title,
        R.string.download_settings_saved,
        false,
    )
    MutationResultStatus.PARTIAL_SUCCESS -> DownloadSettingsFeedbackPolicy(
        R.string.download_settings_feedback_partial_title,
        R.string.download_settings_partial,
        true,
    )
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED -> DownloadSettingsFeedbackPolicy(
        R.string.download_settings_feedback_check_title,
        R.string.download_settings_unverified,
        true,
    )
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION -> DownloadSettingsFeedbackPolicy(
        R.string.download_settings_feedback_check_title,
        R.string.download_settings_cancel_after_submission,
        true,
    )
    MutationResultStatus.PERMISSION_DENIED -> DownloadSettingsFeedbackPolicy(
        R.string.download_settings_feedback_permission_title,
        R.string.download_settings_permission_denied,
        true,
    )
    MutationResultStatus.UNSUPPORTED -> DownloadSettingsFeedbackPolicy(
        R.string.download_settings_feedback_unavailable_title,
        R.string.download_settings_unsupported,
        true,
    )
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> DownloadSettingsFeedbackPolicy(
        R.string.download_settings_feedback_cancelled_title,
        R.string.download_settings_cancelled,
        true,
    )
    MutationResultStatus.CONFIRMED_FAILURE -> DownloadSettingsFeedbackPolicy(
        if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            R.string.download_settings_feedback_conflict_title
        } else R.string.download_settings_feedback_failed_title,
        if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            R.string.download_settings_conflict
        } else R.string.download_settings_failed,
        true,
    )
}

@Composable
internal fun DownloadSettingsDialog(
    state: WorkspaceState,
    onRetry: () -> Unit,
    onDraftChange: (DownloadSettingsDraftState) -> Unit,
    onSave: (DownloadSettings) -> Boolean,
    onRefreshMutation: () -> Unit,
    onDismissMutation: () -> Boolean,
    onDismiss: () -> Boolean,
    onChooseDestination: (() -> Unit)? = null,
) {
    val settingsState = state.downloadSettingsState
    Dialog(
        onDismissRequest = { onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(
                Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding(),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(
                        onClick = { onDismiss() },
                        enabled = !settingsState.mutationInProgress &&
                            !settingsState.mutationRefreshInProgress &&
                            settingsState.mutationResult == null && settingsState.mutationFailure == null,
                        modifier = Modifier.size(48.dp),
                    ) { Icon(Icons.Outlined.Close, stringResource(R.string.close)) }
                    Column(Modifier.weight(1f).padding(horizontal = 8.dp)) {
                        Text(
                            stringResource(R.string.download_settings_title),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            stringResource(R.string.download_settings_description),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                HorizontalDivider()
                Column(Modifier.weight(1f).fillMaxWidth()) {
                    if (
                        settingsState.mutationInProgress || settingsState.mutationResult != null ||
                        settingsState.mutationFailure != null
                    ) {
                        DownloadSettingsMutationFeedbackCard(
                            state = settingsState,
                            onRefresh = onRefreshMutation,
                            onDismiss = onDismissMutation,
                        )
                    }
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        when (val settings = state.downloadSettings) {
                            Loadable.Idle, Loadable.Loading ->
                                CircularProgressIndicator(Modifier.align(Alignment.Center))
                            is Loadable.Failed -> DownloadSettingsFailure(settings.error, onRetry)
                            is Loadable.Ready -> {
                                val baseline = settingsState.baseline
                                val draft = settingsState.draft
                                if (baseline == null || draft == null) {
                                    CircularProgressIndicator(Modifier.align(Alignment.Center))
                                } else {
                                    DownloadSettingsForm(
                                        initial = baseline,
                                        draft = draft,
                                        supportsSchedule = state.supportsDownloadSchedule,
                                        saving = settingsState.mutationInProgress ||
                                            settingsState.mutationRefreshInProgress ||
                                            settingsState.mutationResult != null ||
                                            settingsState.mutationFailure != null,
                                        onDraftChange = onDraftChange,
                                        onSave = onSave,
                                        onChooseDestination = onChooseDestination,
                                        onRetry = onRetry,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DownloadSettingsForm(
    initial: DownloadSettings, draft: DownloadSettingsDraftState, supportsSchedule: Boolean, saving: Boolean,
    onDraftChange: (DownloadSettingsDraftState) -> Unit, onSave: (DownloadSettings) -> Boolean,
    onChooseDestination: (() -> Unit)?, onRetry: () -> Unit,
) {
    val parsed = draft.toSettingsOrNull(supportsSchedule, initial)
    val enabled = !saving && initial.canManage
    fun available(key: String) = key in initial.availableFields
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (!initial.canManage) Text(stringResource(R.string.download_settings_read_only))
        if (initial.basicFailure != null || initial.scheduleFailure != null) {
            Text(stringResource(R.string.download_settings_partial))
            TextButton(onClick = onRetry) { Text(stringResource(R.string.refresh)) }
        }
        Text(stringResource(R.string.download_settings_general), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        if (available("default_destination")) {
            OutlinedTextField(draft.destination, { onDraftChange(draft.copy(destination = it)) }, label = { Text(stringResource(R.string.download_default_folder)) },
                singleLine = true, enabled = enabled, modifier = Modifier.fillMaxWidth())
            if (onChooseDestination != null) TextButton(onClick = onChooseDestination, enabled = enabled) { Text(stringResource(R.string.browse_nas_folders)) }
        }
        if (available("unzip_service_enabled")) SettingsSwitchRow(stringResource(R.string.download_auto_extract), draft.autoExtract, enabled) { onDraftChange(draft.copy(autoExtract = it)) }
        if (available("emule_enabled")) SettingsSwitchRow(stringResource(R.string.download_enable_emule), draft.emuleEnabled, enabled) { onDraftChange(draft.copy(emuleEnabled = it)) }
        HorizontalDivider(Modifier.padding(vertical = 4.dp))
        Text(stringResource(R.string.download_speed_limits), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        Text(stringResource(R.string.download_speed_limits_note), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (available("bt_max_download")) LimitField(R.string.download_bt_limit, draft.btDownload, !enabled) { onDraftChange(draft.copy(btDownload = it)) }
        if (available("bt_max_upload")) LimitField(R.string.download_bt_upload_limit, draft.btUpload, !enabled) { onDraftChange(draft.copy(btUpload = it)) }
        if (available("http_max_download") && available("ftp_max_download")) LimitField(R.string.download_http_ftp_limit, draft.httpDownload, !enabled, R.string.download_http_ftp_limit_hint) { onDraftChange(draft.copy(httpDownload = it, ftpDownload = it)) }
        if (available("nzb_max_download")) LimitField(R.string.download_nzb_limit, draft.nzbDownload, !enabled) { onDraftChange(draft.copy(nzbDownload = it)) }
        if (available("emule_max_download")) LimitField(R.string.download_emule_limit, draft.emuleDownload, !enabled) { onDraftChange(draft.copy(emuleDownload = it)) }
        if (available("emule_max_upload")) LimitField(R.string.download_emule_upload_limit, draft.emuleUpload, !enabled) { onDraftChange(draft.copy(emuleUpload = it)) }
        HorizontalDivider(Modifier.padding(vertical = 4.dp))
        Text(stringResource(R.string.download_schedule_title), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        if (available("enabled")) SettingsSwitchRow(stringResource(R.string.download_schedule_enabled), draft.scheduleEnabled, enabled) { onDraftChange(draft.copy(scheduleEnabled = it)) }
        if (available("schedule_emule_enabled")) SettingsSwitchRow(stringResource(R.string.download_emule_schedule_enabled), draft.emuleScheduleEnabled, enabled) { onDraftChange(draft.copy(emuleScheduleEnabled = it)) }
        if (!supportsSchedule) Text(stringResource(R.string.download_schedule_unavailable), color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (parsed == null) Text(stringResource(R.string.download_settings_invalid), color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive })
        Button(onClick = { parsed?.let(onSave) }, enabled = parsed != null && parsed != initial && enabled,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.save_changes)) }
    }
}

@Composable
private fun SettingsSwitchRow(
    title: String,
    checked: Boolean,
    enabled: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange).padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

@Composable
private fun LimitField(
    @StringRes label: Int,
    value: String,
    saving: Boolean,
    @StringRes supportingText: Int? = null,
    onValueChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = { candidate ->
            if (candidate.length <= 7 && candidate.all(Char::isDigit)) onValueChange(candidate)
        },
        label = { Text(stringResource(label)) },
        supportingText = supportingText?.let { resource -> { Text(stringResource(resource)) } },
        suffix = { Text(stringResource(R.string.kilobytes_per_second)) },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        singleLine = true,
        enabled = !saving,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun DownloadSettingsFailure(failure: DsmFailure, onRetry: () -> Unit) {
    val localized = failure.localize(LocalContext.current)
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp).semantics {
            liveRegion = LiveRegionMode.Assertive
        },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Outlined.ErrorOutline,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.error,
        )
        Text(localized.message, modifier = Modifier.padding(top = 16.dp))
        Text(
            localized.recovery,
            modifier = Modifier.padding(top = 8.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onRetry, modifier = Modifier.padding(top = 20.dp).heightIn(min = 48.dp)) {
            Text(stringResource(R.string.retry))
        }
    }
}

@Composable
internal fun DownloadSettingsMutationFeedbackCard(
    state: DownloadSettingsWorkspaceState,
    onRefresh: () -> Unit,
    onDismiss: () -> Boolean,
) {
    val policy = state.mutationResult?.let(::downloadSettingsFeedbackPolicy)
    val mustRefresh = state.mutationFailure != null || state.mutationResult?.let { result ->
        result.requiresRefresh || result.counts.unknown > 0 || result.status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
    } == true
    val trustedRefresh = state.mutationRefreshCompleted && state.mutationRefreshFailure == null
    val canContinueEditing = !state.mutationInProgress && !state.mutationRefreshInProgress &&
        (state.mutationFailure != null || state.mutationResult?.submitted == false) &&
        (!mustRefresh || trustedRefresh)
    Card(
        modifier = Modifier.fillMaxWidth().semantics {
            liveRegion = if (
                state.mutationFailure != null || state.mutationRefreshFailure != null ||
                policy?.assertive == true
            ) LiveRegionMode.Assertive else LiveRegionMode.Polite
        },
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp)
                .verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                when {
                    state.mutationInProgress -> stringResource(R.string.download_settings_saving_title)
                    state.mutationFailure != null -> stringResource(R.string.download_settings_feedback_failed_title)
                    else -> stringResource(checkNotNull(policy).title)
                },
                style = MaterialTheme.typography.titleMedium,
            )
            when {
                state.mutationInProgress -> {
                    Text(stringResource(R.string.download_settings_saving_message))
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                state.mutationFailure != null -> Text(
                    state.mutationFailure.localize(LocalContext.current).combined,
                )
                policy != null -> Text(stringResource(policy.message))
            }
            state.mutationResult?.counts?.let { counts ->
                Text(
                    stringResource(
                        R.string.download_settings_feedback_counts,
                        counts.succeeded,
                        counts.failed,
                        counts.unknown,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (trustedRefresh) Text(stringResource(R.string.download_settings_refresh_completed))
            state.mutationRefreshFailure?.let {
                Text(it.localize(LocalContext.current).combined)
            }
            if (state.mutationRefreshInProgress) {
                Text(stringResource(R.string.download_settings_refreshing))
                LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            if ((mustRefresh && !trustedRefresh) || state.mutationRefreshFailure != null) {
                TextButton(
                    onClick = onRefresh,
                    enabled = !state.mutationInProgress && !state.mutationRefreshInProgress,
                    modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics {
                        role = Role.Button
                    },
                ) { Text(stringResource(R.string.refresh_and_check_download_settings)) }
            }
            if (canContinueEditing) {
                OutlinedButton(
                    onClick = { onDismiss() },
                    modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics {
                        role = Role.Button
                    },
                ) { Text(stringResource(R.string.continue_editing_download_settings)) }
            } else if (!state.mutationInProgress) {
                TextButton(
                    onClick = { onDismiss() },
                    enabled = !state.mutationRefreshInProgress && (!mustRefresh || trustedRefresh),
                    modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp).semantics {
                        role = Role.Button
                    },
                ) {
                    Text(
                        stringResource(
                            if (mustRefresh) R.string.close_checked_download_settings else R.string.close,
                        ),
                    )
                }
            }
        }
    }
}
