package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.SettingsSuggest
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.KeyboardType
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasPowerAction
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize

@Composable
internal fun NasHardwareSettingsScreen(
    settings: NasHardwareSettings?,
    settingsAvailable: Boolean,
    state: WorkspaceState,
    model: AppViewModel,
) {
    val power by model.nasPower.state.collectAsState()
    val services = model.nasServices
    val states by services.state.collectAsState()
    val editor = states.getValue(NasServiceKind.HARDWARE)
    val powerSettingsBusy = states.getValue(NasServiceKind.MEMORY_COMPRESSION).busy || states.getValue(NasServiceKind.POWER_SCHEDULE).busy
    val baseline = (editor.original as? NasServiceValue.Hardware)?.settings
    val draft = (editor.draft as? NasServiceValue.Hardware)?.settings
    var editing by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    LaunchedEffect(services) { services.refresh(NasServiceKind.HARDWARE, notify = false) }
    HardwareSettingsContent(
        settings, settingsAvailable, baseline, draft, editor.saving, editor.result, editor.failure,
        refreshFailure = editor.failure, refreshInProgress = editor.busy && !editor.saving, refreshCompleted = false,
        powerAction = null, powerInProgress = false, powerResult = null, powerFailure = null,
        enabled = !state.isPerformingAction && !editor.blocked && !powerSettingsBusy && !power.busy,
        onEdit = { if (settings != null && services.begin(NasServiceValue.Hardware(settings))) editing = true },
        onRefresh = { services.refresh(NasServiceKind.HARDWARE) },
        onContinueEditing = { services.dismiss(NasServiceKind.HARDWARE); editing = true },
        onDismissResult = { services.dismiss(NasServiceKind.HARDWARE, discard = true) },
        onPowerAction = {}, onDismissPowerResult = {},
        powerControls = { NasPowerActionSection(model.nasPower, !state.isPerformingAction && !editor.busy && !powerSettingsBusy) },
        canContinueEditing = !editor.blocked && draft != null && editor.result?.errorCategory != MutationErrorCategory.CONFLICT,
        canDismiss = !editor.blocked,
        additionalSettings = { NasPowerSettingsSections(services, !state.isPerformingAction && !editor.busy && !power.busy) },
        onContinueLed = if (!editor.blocked && editor.draft == null && editor.record?.canContinueLed == true) ({ editor.record?.let { services.continuePendingStep(it) } }) else null,
    )
    if (editing && baseline != null && draft != null && !editor.blocked) HardwareSettingsDialog(
        initial = baseline, draft = draft, enabled = !state.isPerformingAction,
        onDraftChange = { services.draft(NasServiceKind.HARDWARE, NasServiceValue.Hardware(it)) },
        onContinue = { editing = false; confirming = true; true },
        onDismiss = { editing = false; services.draft(NasServiceKind.HARDWARE, null) },
    )
    if (confirming && baseline != null && draft != null && !editor.blocked) HardwareConfirmationDialog(
        baseline, draft, onConfirm = { services.save(NasServiceKind.HARDWARE).also { if (it) confirming = false } },
        onDismiss = { confirming = false; editing = true },
    )

}

@Composable
internal fun HardwareSettingsContent(
    settings: NasHardwareSettings?,
    settingsAvailable: Boolean,
    baseline: NasHardwareSettings?,
    draft: NasHardwareSettings?,
    mutationInProgress: Boolean,
    mutationResult: MutationResult?,
    mutationFailure: DsmFailure?,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    powerAction: NasPowerAction?,
    powerInProgress: Boolean,
    powerResult: MutationResult?,
    powerFailure: DsmFailure?,
    enabled: Boolean,
    onEdit: () -> Unit,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismissResult: () -> Unit,
    onPowerAction: (NasPowerAction) -> Unit,
    onDismissPowerResult: () -> Unit,
    canContinueEditing: Boolean? = null,
    canDismiss: Boolean? = null,
    onContinueLed: (() -> Unit)? = null,
    additionalSettings: @Composable () -> Unit = {},
    powerControls: (@Composable () -> Unit)? = null,
) {
    Column(Modifier.verticalScroll(rememberScrollState())) {
        TextButton(onClick = onRefresh, enabled = !mutationInProgress && !refreshInProgress, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.refresh_and_check_hardware_settings))
        }
        if (refreshInProgress) LinearProgressIndicator(Modifier.fillMaxWidth())
        onContinueLed?.let { action -> TextButton(onClick = action, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.hardware_continue_led)) } }
        when {
            mutationInProgress -> StructuredSettingsSavingCard(
                R.string.hardware_saving_title,
                R.string.hardware_saving_message,
            )
            mutationResult != null -> SettingsMutationFeedbackCard(
                result = mutationResult,
                failure = null,
                refreshFailure = refreshFailure,
                refreshInProgress = refreshInProgress,
                refreshCompleted = refreshCompleted,
                currentMatches = if (draft != null) settings?.let { hardwareSettingsMatch(it, draft) } else null,
                countsLabel = R.string.hardware_feedback_counts,
                refreshLabel = R.string.refresh_and_check_hardware_settings,
                onRefresh = onRefresh,
                onContinueEditing = onContinueEditing,
                onDismiss = onDismissResult,
                canContinueEditing = canContinueEditing, canDismiss = canDismiss,
            )
            mutationFailure != null -> SettingsMutationFeedbackCard(
                result = null,
                failure = mutationFailure,
                refreshFailure = refreshFailure,
                refreshInProgress = refreshInProgress,
                refreshCompleted = refreshCompleted,
                currentMatches = if (draft != null) settings?.let { hardwareSettingsMatch(it, draft) } else null,
                countsLabel = R.string.hardware_feedback_counts,
                refreshLabel = R.string.refresh_and_check_hardware_settings,
                onRefresh = onRefresh,
                onContinueEditing = onContinueEditing,
                onDismiss = onDismissResult,
                canContinueEditing = canContinueEditing, canDismiss = canDismiss,
            )
        }
        when {
            powerInProgress -> PowerActionProgressCard(powerAction)
            powerResult != null -> PowerActionFeedbackCard(powerAction, powerResult, null, onDismissPowerResult)
            powerFailure != null -> PowerActionFeedbackCard(powerAction, null, powerFailure, onDismissPowerResult)
        }
        if (!settingsAvailable || settings == null) {
            Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.hardware_settings_unavailable), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.hardware_settings_unavailable_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            ListItem(
                headlineContent = { Text(stringResource(R.string.hardware_settings)) },
                supportingContent = { Text(stringResource(R.string.hardware_settings_summary)) },
                leadingContent = { Icon(Icons.Outlined.SettingsSuggest, null) },
                trailingContent = {
                    val editDescription = stringResource(R.string.nas_edit_settings_accessibility, stringResource(R.string.hardware_settings))
                    TextButton(enabled = enabled, onClick = onEdit, modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = editDescription }) {
                        Text(stringResource(R.string.edit))
                    }
                },
            )
        }
        additionalSettings()
        if (powerControls != null) powerControls() else {
        ListItem(
            headlineContent = { Text(stringResource(R.string.nas_power)) },
            supportingContent = { Text(stringResource(R.string.nas_power_hint)) },
            leadingContent = { Icon(Icons.Outlined.PowerSettingsNew, null) },
        )
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TextButton(
                enabled = enabled,
                onClick = { onPowerAction(NasPowerAction.REBOOT) },
                modifier = Modifier.weight(1f).heightIn(min = 48.dp),
            ) { Text(stringResource(R.string.restart_nas)) }
            TextButton(
                enabled = enabled,
                onClick = { onPowerAction(NasPowerAction.SHUTDOWN) },
                modifier = Modifier.weight(1f).heightIn(min = 48.dp),
            ) { Text(stringResource(R.string.shut_down_nas), color = MaterialTheme.colorScheme.error) }
        }
        }
    }
}

@Composable
internal fun HardwareSettingsDialog(
    initial: NasHardwareSettings,
    draft: NasHardwareSettings,
    enabled: Boolean,
    onDraftChange: (NasHardwareSettings) -> Unit,
    onContinue: () -> Boolean,
    onDismiss: () -> Unit,
) {
    val ups = draft.ups
    val address = if (ups?.mode == "SNMP") ups.snmpServerAddress.orEmpty() else ups?.networkServerAddress.orEmpty()
    val upsValid = ups?.let {
        it.safeModeDelaySeconds?.let { seconds -> seconds in 0..604_800 } != false &&
            (!it.isEnabled || it.mode == "USB" || address.isNotBlank()) &&
            "://" !in address && address.none { character -> character.isWhitespace() || character in "/?#@" }
    } ?: true
    AlertDialog(
        onDismissRequest = { if (enabled) onDismiss() },
        title = { Text(stringResource(R.string.hardware_settings)) },
        text = {
            Column(Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                draft.restartsAfterPowerFailure?.let { value ->
                    SettingsSwitch(stringResource(R.string.restart_after_power_failure), value, enabled) {
                        onDraftChange(draft.copy(restartsAfterPowerFailure = it))
                    }
                }
                if (draft.ledBrightness != null && draft.ledBrightnessMinimum != null && draft.ledBrightnessMaximum != null) {
                    Text(stringResource(R.string.led_brightness_value, draft.ledBrightness))
                    Slider(
                        value = draft.ledBrightness.toFloat(),
                        onValueChange = { onDraftChange(draft.copy(ledBrightness = it.toInt())) },
                        enabled = enabled,
                        valueRange = draft.ledBrightnessMinimum.toFloat()..draft.ledBrightnessMaximum.toFloat(),
                        steps = (draft.ledBrightnessMaximum - draft.ledBrightnessMinimum - 1).coerceAtLeast(0),
                    )
                }
                draft.fanMode?.let { mode ->
                    Text(stringResource(R.string.fan_current_mode, fanModeLabel(mode)))
                    ModeSelector(
                        options = draft.supportedFanModes.orEmpty(),
                        selected = mode,
                        enabled = enabled,
                        label = { fanModeLabel(it) },
                    ) { onDraftChange(draft.copy(fanMode = it)) }
                }
                HardwareSwitches(draft, enabled, onDraftChange)
                ups?.let { currentUps ->
                    Text(stringResource(R.string.ups_settings), style = MaterialTheme.typography.titleSmall)
                    SettingsSwitch(stringResource(R.string.enable_ups_support), currentUps.isEnabled, enabled) {
                        onDraftChange(draft.copy(ups = currentUps.copy(isEnabled = it)))
                    }
                    ModeSelector(
                        options = listOf("USB", "SLAVE", "SNMP").filter { it == "USB" || it == currentUps.mode || if (it == "SLAVE") currentUps.networkServerAddress != null else currentUps.snmpServerAddress != null },
                        selected = currentUps.mode,
                        enabled = enabled,
                        label = { upsModeLabel(it) },
                    ) { mode ->
                        onDraftChange(draft.copy(ups = currentUps.copy(
                            mode = mode,
                        )))
                    }
                    if (currentUps.safeModeDelaySeconds != null) OutlinedTextField(
                        value = currentUps.safeModeDelaySeconds?.toString().orEmpty(),
                        onValueChange = { text -> text.filter(Char::isDigit).toIntOrNull()?.takeIf { it in 0..604_800 }?.let { seconds ->
                            onDraftChange(draft.copy(ups = currentUps.copy(safeModeDelaySeconds = seconds)))
                        } },
                        enabled = enabled,
                        label = { Text(stringResource(R.string.safe_mode_delay_seconds)) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (currentUps.mode != "USB" && (if (currentUps.mode == "SNMP") currentUps.snmpServerAddress else currentUps.networkServerAddress) != null) {
                        OutlinedTextField(
                            value = address,
                            onValueChange = { value -> onDraftChange(draft.copy(ups = if (currentUps.mode == "SNMP") {
                                currentUps.copy(snmpServerAddress = value)
                            } else currentUps.copy(networkServerAddress = value))) },
                            enabled = enabled,
                            label = { Text(stringResource(R.string.ups_server_address)) },
                            isError = !upsValid,
                            supportingText = if (!upsValid) {{ Text(stringResource(R.string.invalid_ups_settings)) }} else null,
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    currentUps.waitsUntilLowBattery?.let { value ->
                        SettingsSwitch(stringResource(R.string.wait_until_low_battery), value, enabled) {
                            onDraftChange(draft.copy(ups = currentUps.copy(waitsUntilLowBattery = it)))
                        }
                    }
                    currentUps.shutsDownUpsAfterSafeMode?.let { value ->
                        SettingsSwitch(stringResource(R.string.shut_down_ups_after_safe_mode), value, enabled) {
                            onDraftChange(draft.copy(ups = currentUps.copy(shutsDownUpsAfterSafeMode = it)))
                        }
                    }
                }
                Text(stringResource(R.string.hardware_impact_hint), color = MaterialTheme.colorScheme.error)
            }
        },
        confirmButton = {
            TextButton(enabled = enabled && upsValid && draft != initial, onClick = { onContinue() }) {
                Text(stringResource(R.string.continue_action))
            }
        },
        dismissButton = { TextButton(enabled = enabled, onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun HardwareSwitches(value: NasHardwareSettings, enabled: Boolean, onChange: (NasHardwareSettings) -> Unit) {
    listOf(
        Triple(R.string.fan_failure_alert, value.isFanFailureAlertEnabled) { state: Boolean -> value.copy(isFanFailureAlertEnabled = state) },
        Triple(R.string.volume_failure_alert, value.isVolumeFailureAlertEnabled) { state: Boolean -> value.copy(isVolumeFailureAlertEnabled = state) },
        Triple(R.string.power_on_sound, value.isPowerOnSoundEnabled) { state: Boolean -> value.copy(isPowerOnSoundEnabled = state) },
        Triple(R.string.power_off_sound, value.isPowerOffSoundEnabled) { state: Boolean -> value.copy(isPowerOffSoundEnabled = state) },
        Triple(R.string.reset_sound, value.isResetSoundEnabled) { state: Boolean -> value.copy(isResetSoundEnabled = state) },
        Triple(R.string.external_drive_deep_sleep, value.isExternalDriveDeepSleepEnabled) { state: Boolean -> value.copy(isExternalDriveDeepSleepEnabled = state) },
        Triple(R.string.wake_up_log, value.isWakeUpLogEnabled) { state: Boolean -> value.copy(isWakeUpLogEnabled = state) },
        Triple(R.string.sata_sleep, value.isSataSleepEnabled) { state: Boolean -> value.copy(isSataSleepEnabled = state) },
        Triple(R.string.ignore_network_discovery_during_sleep, value.ignoresNetworkDiscoveryDuringSleep) { state: Boolean -> value.copy(ignoresNetworkDiscoveryDuringSleep = state) },
        Triple(R.string.automatic_power_off, value.isAutomaticPowerOffEnabled) { state: Boolean -> value.copy(isAutomaticPowerOffEnabled = state) },
    ).forEach { (label, state, update) -> state?.let {
        SettingsSwitch(stringResource(label), it, enabled) { checked -> onChange(update(checked)) }
    } }
}

@Composable
private fun ModeSelector(options: List<String>, selected: String, enabled: Boolean, label: @Composable (String) -> String, onSelect: (String) -> Unit) {
    androidx.compose.foundation.layout.FlowRow(Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        options.forEach { option ->
            Row(
                Modifier.widthIn(min = 48.dp).heightIn(min = 48.dp).selectable(
                    selected = selected == option,
                    enabled = enabled,
                    role = Role.RadioButton,
                    onClick = { onSelect(option) },
                ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = selected == option, onClick = null, enabled = enabled)
                Text(label(option), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Composable
internal fun HardwareConfirmationDialog(
    baseline: NasHardwareSettings,
    draft: NasHardwareSettings,
    onConfirm: () -> Boolean,
    onDismiss: () -> Unit,
) {
    val groups = buildList {
        if (baseline.restartsAfterPowerFailure != draft.restartsAfterPowerFailure) add(stringResource(R.string.power_recovery_group))
        if (baseline.ledBrightness != draft.ledBrightness) add(stringResource(R.string.indicator_group))
        if (baseline.fanMode != draft.fanMode || baseline.isFanFailureAlertEnabled != draft.isFanFailureAlertEnabled) add(stringResource(R.string.cooling_group))
        if (baseline.isPowerOnSoundEnabled != draft.isPowerOnSoundEnabled || baseline.isPowerOffSoundEnabled != draft.isPowerOffSoundEnabled || baseline.isResetSoundEnabled != draft.isResetSoundEnabled) add(stringResource(R.string.sound_group))
        if (baseline.isExternalDriveDeepSleepEnabled != draft.isExternalDriveDeepSleepEnabled || baseline.isSataSleepEnabled != draft.isSataSleepEnabled || baseline.isAutomaticPowerOffEnabled != draft.isAutomaticPowerOffEnabled) add(stringResource(R.string.sleep_group))
        if (baseline.ups != draft.ups) add(stringResource(R.string.ups_settings))
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.save_hardware_settings_title)) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.save_hardware_settings_message))
            Text(stringResource(R.string.settings_change_summary, groups.joinToString(", ")))
        } },
        confirmButton = { TextButton(onClick = { onConfirm() }) { Text(stringResource(R.string.save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
internal fun PowerActionConfirmationDialog(action: NasPowerAction, onConfirm: () -> Boolean, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(if (action == NasPowerAction.SHUTDOWN) R.string.shut_down_nas_title else R.string.restart_nas_title)) },
        text = { Text(stringResource(if (action == NasPowerAction.SHUTDOWN) R.string.shut_down_nas_message else R.string.restart_nas_message)) },
        confirmButton = { TextButton(onClick = { onConfirm() }) {
            Text(stringResource(if (action == NasPowerAction.SHUTDOWN) R.string.shut_down_nas else R.string.restart_nas))
        } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun PowerActionProgressCard(action: NasPowerAction?) {
    Card(Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.power_request_sending), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(if (action == NasPowerAction.SHUTDOWN) R.string.shut_down_nas_message else R.string.restart_nas_message))
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}

@Composable
internal fun PowerActionFeedbackCard(action: NasPowerAction?, result: MutationResult?, failure: DsmFailure?, onDismiss: () -> Unit) {
    val success = result?.status == MutationResultStatus.CONFIRMED_SUCCESS
    val requiresDeviceCheck = result?.let(::powerResultRequiresDeviceCheck) == true
    val title = if (success) {
        if (action == NasPowerAction.SHUTDOWN) R.string.shutdown_accepted else R.string.reboot_accepted
    } else if (requiresDeviceCheck) {
        R.string.power_result_needs_device_check_title
    } else result?.let { settingsFeedbackPolicy(it).title } ?: R.string.settings_feedback_failed_title
    Card(
        modifier = Modifier.fillMaxWidth().padding(16.dp).semantics {
            liveRegion = if (success) LiveRegionMode.Polite else LiveRegionMode.Assertive
        },
        colors = if (failure != null) CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
            contentColor = MaterialTheme.colorScheme.onErrorContainer,
        ) else CardDefaults.cardColors(),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
            when {
                failure != null -> Text(failure.localize(LocalContext.current).combined)
                success -> Text(stringResource(R.string.power_accepted_not_completed))
                requiresDeviceCheck -> Text(stringResource(R.string.power_result_needs_device_check_message))
                result != null -> Text(stringResource(settingsFeedbackPolicy(result).message))
            }
            result?.counts?.takeIf { it.succeeded + it.failed + it.unknown > 0 }?.let {
                Text(stringResource(R.string.power_feedback_counts, it.succeeded, it.failed, it.unknown))
            }
            if (!requiresDeviceCheck) {
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) {
                    Text(stringResource(R.string.done))
                }
            }
        }
    }
}

internal fun powerResultRequiresDeviceCheck(result: MutationResult): Boolean =
    result.submitted && result.status != MutationResultStatus.CONFIRMED_SUCCESS

internal fun normalizedWritableHardwareSettings(value: NasHardwareSettings): NasHardwareSettings = value.copy(
    ledBrightnessMinimum = null,
    ledBrightnessMaximum = null,
    ups = value.ups?.copy(
        networkServerAddress = value.ups.networkServerAddress?.trim()?.takeIf(String::isNotEmpty),
        snmpServerAddress = value.ups.snmpServerAddress?.trim()?.takeIf(String::isNotEmpty),
    ),
)

internal fun hardwareSettingsMatch(current: NasHardwareSettings, draft: NasHardwareSettings): Boolean =
    normalizedWritableHardwareSettings(current) == normalizedWritableHardwareSettings(draft)

@Composable
private fun fanModeLabel(mode: String): String = when (mode) {
    "quietfan" -> stringResource(R.string.fan_quiet)
    "coolfan" -> stringResource(R.string.fan_cool)
    "fullfan" -> stringResource(R.string.fan_full)
    "highfan" -> stringResource(R.string.fan_high)
    "lowfan" -> stringResource(R.string.fan_low)
    "quietstopfan" -> stringResource(R.string.fan_quiet_stop)
    else -> mode
}

@Composable
private fun upsModeLabel(mode: String) = stringResource(when (mode) {
    "USB" -> R.string.ups_usb
    "SLAVE" -> R.string.ups_network
    else -> R.string.ups_snmp
})
