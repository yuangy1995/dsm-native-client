package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientGroup
import java.time.DayOfWeek
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle

@Composable
internal fun FileSettingsGeneralForm(feature: FileSettingsFeatureModel, state: FileSettingsState) {
    val value = state.generalDraft ?: return
    val enabled = feature.canEdit()
    ClientGroup {
        FileSettingsToggle(stringResource(R.string.file_settings_record_transfers), value.recordsTransfers, { checked -> feature.editGeneral { it.copy(recordsTransfers = checked) } }, enabled, "settings_transfers")
        FileSettingsToggle(stringResource(R.string.file_settings_default_permissions), value.usesDefaultPermissions, { checked -> feature.editGeneral { it.copy(usesDefaultPermissions = checked) } }, enabled, "settings_permissions")
        FileSettingsToggle(stringResource(R.string.file_settings_show_accounts), value.showsAccounts, { checked -> feature.editGeneral { it.copy(showsAccounts = checked) } }, enabled, "settings_show_accounts")
        value.customSharingPage?.let { selected ->
            FileSettingsToggle(stringResource(R.string.file_settings_custom_page), selected, { checked -> feature.editGeneral { it.copy(customSharingPage = checked) } }, enabled, "settings_custom_page")
        }
    }
    FileSettingsChoice(stringResource(R.string.file_settings_share_permission), value.sharing, FileSettingsScope.entries,
        { stringResource(it.label()) }, { scope -> feature.editGeneral { it.copy(sharing = scope) } }, enabled, "settings_sharing")
    if (value.sharing == FileSettingsScope.SELECTED) OutlinedButton({ feature.openPolicyAccounts(false) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("settings_share_accounts"), enabled = enabled) {
        Text(stringResource(R.string.file_settings_choose_accounts, value.sharingAccounts.size))
    }
    FileSettingsChoice(stringResource(R.string.file_settings_request_permission), value.fileRequests, FileSettingsScope.entries,
        { stringResource(it.label()) }, { scope -> feature.editGeneral { it.copy(fileRequests = scope) } }, enabled, "settings_requests")
    if (value.fileRequests == FileSettingsScope.SELECTED) OutlinedButton({ feature.openPolicyAccounts(true) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("settings_request_accounts"), enabled = enabled) {
        Text(stringResource(R.string.file_settings_choose_accounts, value.requestAccounts.size))
    }
    FileSettingsNumber(stringResource(R.string.file_settings_link_limit), state.linkLimit, feature::linkLimit, enabled, "settings_link_limit",
        state.linkLimit.toIntOrNull() == null)
    Text(stringResource(R.string.file_settings_link_limit_hint), style = MaterialTheme.typography.bodySmall)
    FileSettingsChoice(stringResource(R.string.file_settings_mount_permission), value.remoteMounts, FileSettingsScope.entries.filter { it != FileSettingsScope.SELECTED },
        { stringResource(it.label()) }, { scope -> feature.editGeneral { it.copy(remoteMounts = scope) } }, enabled, "settings_mount_permission")
    FileSettingsChoice(stringResource(R.string.file_settings_iso_permission), value.isoMounts, FileSettingsScope.entries.filter { it != FileSettingsScope.SELECTED },
        { stringResource(it.label()) }, { scope -> feature.editGeneral { it.copy(isoMounts = scope) } }, enabled, "settings_iso_permission")
    FileSettingsChoice(stringResource(R.string.file_settings_bandwidth_policy), value.bandwidth, FileBandwidthPolicy.entries.filter { it != FileBandwidthPolicy.UNCONFIGURED },
        { stringResource(it.label()) }, { policy -> feature.editGeneral { it.copy(bandwidth = policy, schedule = if (policy == FileBandwidthPolicy.SCHEDULED && it.schedule.isEmpty()) "1".repeat(168) else it.schedule) } }, enabled, "settings_bandwidth_policy")
    if (value.bandwidth == FileBandwidthPolicy.SCHEDULED) FileSettingsSchedule(value.schedule, false, enabled) { schedule -> feature.editGeneral { it.copy(schedule = schedule) } }
}

@Composable
internal fun FileSettingsBandwidthForm(feature: FileSettingsFeatureModel, state: FileSettingsState) {
    val value = state.bandwidthDraft ?: return; val enabled = feature.canEdit()
    Text(value.name, style = MaterialTheme.typography.titleMedium)
    val options = FileBandwidthPolicy.entries.filter { it != FileBandwidthPolicy.UNCONFIGURED || state.bandwidthBaseline?.policy == FileBandwidthPolicy.UNCONFIGURED }
    FileSettingsChoice(stringResource(R.string.file_settings_bandwidth_policy), value.policy, options,
        { stringResource(it.label(value.ownerType.isGroup)) }, { policy -> feature.bandwidthDraft {
            it.copy(policy = policy, schedule = if (policy == FileBandwidthPolicy.SCHEDULED && it.schedule.isEmpty()) "1".repeat(168) else it.schedule)
        } }, enabled, "settings_account_policy")
    if (value.policy in setOf(FileBandwidthPolicy.ENABLED, FileBandwidthPolicy.SCHEDULED)) {
        Text(stringResource(R.string.file_settings_rate_units), style = MaterialTheme.typography.bodySmall)
        listOf(R.string.file_settings_upload_limit, R.string.file_settings_download_limit, R.string.file_settings_alternate_upload, R.string.file_settings_alternate_download)
            .take(if (value.policy == FileBandwidthPolicy.SCHEDULED) 4 else 2).forEachIndexed { index, label ->
                val rate = state.rates.getOrNull(index).orEmpty(); val number = rate.toIntOrNull()
                FileSettingsNumber(stringResource(label), rate, { feature.rate(index, it) }, enabled, "settings_rate_$index", number == null || number != 0 && number !in 10..999_999_999)
            }
    }
    if (value.policy == FileBandwidthPolicy.SCHEDULED) FileSettingsSchedule(value.schedule, true, enabled) { schedule -> feature.bandwidthDraft { it.copy(schedule = schedule) } }
}

@Composable
internal fun FileSettingsToggle(title: String, checked: Boolean, change: (Boolean) -> Unit, enabled: Boolean, tag: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).testTag(tag).toggleable(checked, enabled = enabled, role = Role.Checkbox, onValueChange = change)
        .padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, Modifier.weight(1f)); Checkbox(checked, onCheckedChange = null, enabled = enabled)
    }
}
@Composable
internal fun <T> FileSettingsChoice(title: String, value: T, options: List<T>, label: @Composable (T) -> String,
                                   change: (T) -> Unit, enabled: Boolean = true, tag: String) {
    var expanded by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = MaterialTheme.typography.labelLarge)
        Box {
            OutlinedButton({ expanded = true }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag), enabled = enabled) { Text(label(value)) }
            DropdownMenu(expanded && enabled, { expanded = false }) {
                options.forEach { option -> DropdownMenuItem(text = { Text(label(option)) }, onClick = { expanded = false; change(option) }) }
            }
        }
    }
}
@Composable
private fun FileSettingsNumber(title: String, value: String, change: (String) -> Unit, enabled: Boolean, tag: String, invalid: Boolean) {
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    OutlinedTextField(value, change, Modifier.fillMaxWidth().testTag(tag), enabled = enabled, singleLine = true,
        label = { Text(title) }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() }), isError = invalid,
        supportingText = if (invalid) ({ Text(stringResource(R.string.file_settings_number_invalid)) }) else null)
}

@Composable
internal fun FileSettingsSchedule(value: String, perAccount: Boolean, enabled: Boolean, change: (String) -> Unit) {
    var day by remember { mutableIntStateOf(0) }; var painting by remember { mutableStateOf('1') }
    val locale = LocalConfiguration.current.locales[0]
    val dayNames = remember(locale) { (0..6).map { DayOfWeek.of((it + 6) % 7 + 1).getDisplayName(TextStyle.FULL, locale) } }
    val hours = remember(locale) { (0..23).map { LocalTime.of(it, 0).format(DateTimeFormatter.ofPattern("HH:mm", locale)) } }
    Text(stringResource(R.string.file_settings_schedule_clock), style = MaterialTheme.typography.bodySmall)
    FileSettingsChoice(stringResource(R.string.file_settings_schedule_day), day, (0..6).toList(), { dayNames[it] }, { day = it }, enabled, "settings_schedule_day")
    fun slotLabel(slot: Char) = when (slot) { '0' -> R.string.file_settings_unlimited; '2' -> R.string.file_settings_alternate_limit; else -> R.string.file_settings_default_limit }
    FileSettingsChoice(stringResource(R.string.file_settings_schedule_paint), painting, if (perAccount) listOf('0', '1', '2') else listOf('0', '1'),
        { stringResource(slotLabel(it)) }, { painting = it }, enabled, "settings_schedule_paint")
    if (FileWeeklySchedule.valid(value, perAccount)) {
        OutlinedButton({ val next = value.toCharArray(); (0..23).forEach { next[FileWeeklySchedule.index(day, it)] = painting }; change(String(next)) },
            Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("settings_schedule_fill_day"), enabled = enabled) { Text(stringResource(R.string.file_settings_fill_day)) }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            (0..23).forEach { hour ->
                val slot = value[FileWeeklySchedule.index(day, hour)]; val title = stringResource(slotLabel(slot))
                val description = stringResource(R.string.file_settings_schedule_cell, dayNames[day], hours[hour], title)
                OutlinedButton({ val next = value.toCharArray(); next[FileWeeklySchedule.index(day, hour)] = painting; change(String(next)) },
                    Modifier.widthIn(min = 96.dp).heightIn(min = 64.dp).testTag("settings_schedule_hour_$hour").semantics { contentDescription = description }, enabled = enabled) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) { Text(hours[hour]); Text(title, style = MaterialTheme.typography.labelSmall) }
                }
            }
        }
    }
}

internal fun FileSettingsScope.label() = when (this) {
    FileSettingsScope.ADMINISTRATORS -> R.string.file_settings_administrators; FileSettingsScope.EVERYONE -> R.string.file_settings_everyone
    FileSettingsScope.SELECTED -> R.string.file_settings_selected_accounts
}
internal fun FileMountScope.label() = when (this) {
    FileMountScope.ADMINISTRATORS -> R.string.file_settings_administrators; FileMountScope.EVERYONE -> R.string.file_settings_everyone
    FileMountScope.SELECTED -> R.string.file_settings_selected_accounts
}
internal fun FileBandwidthPolicy.label(group: Boolean = false) = when (this) {
    FileBandwidthPolicy.DISABLED -> R.string.file_settings_unlimited; FileBandwidthPolicy.ENABLED -> R.string.file_settings_always_limit
    FileBandwidthPolicy.SCHEDULED -> R.string.file_settings_scheduled_limit
    FileBandwidthPolicy.UNCONFIGURED -> if (group) R.string.file_settings_unconfigured else R.string.file_settings_inherited
}
internal fun FileBandwidthOwner.label() = when (this) {
    FileBandwidthOwner.LOCAL_USER -> R.string.file_settings_local_users; FileBandwidthOwner.LOCAL_GROUP -> R.string.file_settings_local_groups
    FileBandwidthOwner.LDAP_USER -> R.string.file_settings_ldap_users; FileBandwidthOwner.LDAP_GROUP -> R.string.file_settings_ldap_groups
    FileBandwidthOwner.DOMAIN_USER -> R.string.file_settings_domain_users; FileBandwidthOwner.DOMAIN_GROUP -> R.string.file_settings_domain_groups
}
