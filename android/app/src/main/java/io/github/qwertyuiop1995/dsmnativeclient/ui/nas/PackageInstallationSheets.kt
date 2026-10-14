package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import kotlinx.serialization.json.*

@Composable
internal fun PackageToggle(label: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(checked, enabled, Role.Switch, onValueChange = onChange).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f)); Switch(checked, null, enabled = enabled)
    }
}
@Composable
internal fun PackageChoice(label: String, selected: String, choices: List<NasPackageChoice>, enabled: Boolean = true, onChange: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column {
        OutlinedButton(onClick = { expanded = true }, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.pc_choice, label, choices.firstOrNull { it.id == selected }?.name ?: stringResource(R.string.pc_choose)))
        }
        DropdownMenu(expanded, { expanded = false }) { choices.forEach { choice ->
            DropdownMenuItem(text = { Text(choice.name) }, onClick = { expanded = false; onChange(choice.id) })
        } }
    }
}
@Composable
internal fun PackagePlanSheet(plan: NasPackageInstallPlan, busy: Boolean, onDismiss: () -> Unit, onInstall: (Map<String, String>, Boolean) -> Unit) {
    var volumes by remember(plan.id) { mutableStateOf(plan.items.associate { it.entry.id to (it.volumes.singleOrNull()?.id ?: it.defaultVolume) }) }
    var start by remember(plan.id) { mutableStateOf(true) }
    ClientSheet(stringResource(R.string.pc_install_plan), onDismiss, dismissEnabled = !busy) {
        Text(stringResource(R.string.pc_install_risk))
        plan.items.forEach { item ->
            Text(item.entry.name, style = MaterialTheme.typography.titleSmall)
            Text(stringResource(R.string.pc_version, item.entry.version))
            if (item.volumes.size > 1) PackageChoice(stringResource(R.string.pc_location), volumes[item.entry.id].orEmpty(), item.volumes, !busy) {
                volumes = volumes + (item.entry.id to it)
            }
        }
        if (plan.affected.isNotEmpty()) { Text(stringResource(R.string.pc_affected)); plan.affected.forEach { Text(it) } }
        PackageToggle(stringResource(R.string.pc_start_after), start, !busy) { start = it }
        Button(onClick = { onInstall(volumes, start) }, enabled = !busy && plan.items.all { item ->
            item.volumes.isEmpty() && volumes[item.entry.id].isNullOrEmpty() || item.volumes.any { it.id == volumes[item.entry.id] }
        }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pc_install_confirm)) }
    }
}
@Composable
internal fun PackageProgressCard(progress: NasPackageProgress, busy: Boolean, onRefresh: () -> Unit, onCancel: () -> Unit, onOptions: () -> Unit) {
    ClientGroup(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(progress.entry.name, style = MaterialTheme.typography.titleSmall)
            Text(stringResource(when (progress.phase) {
                NasPackageInstallPhase.DOWNLOADING -> R.string.pc_downloading
                NasPackageInstallPhase.OPTIONS -> R.string.pc_options
                NasPackageInstallPhase.INSTALLING -> R.string.pc_installing
                NasPackageInstallPhase.COMPLETED -> R.string.pc_completed
                NasPackageInstallPhase.FAILED -> R.string.pc_failed
                NasPackageInstallPhase.CANCELLED -> R.string.pc_cancelled
                NasPackageInstallPhase.UNKNOWN -> R.string.pc_status_unavailable
            }))
            if (progress.total > 1) Text(stringResource(R.string.pc_completed_count, progress.completed, progress.total))
            if (progress.phase in setOf(NasPackageInstallPhase.DOWNLOADING, NasPackageInstallPhase.INSTALLING)) {
                progress.fraction?.let { LinearProgressIndicator(progress = { it.toFloat() }, modifier = Modifier.fillMaxWidth()) }
                    ?: LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            progress.problem?.let { Text(packageErrorText(NasPackageFailure(it)), color = MaterialTheme.colorScheme.error) }
            Row(Modifier.horizontalScroll(rememberScrollState())) {
                if (progress.phase == NasPackageInstallPhase.UNKNOWN) TextButton(onRefresh, enabled = !busy) { Text(stringResource(R.string.refresh)) }
                if (progress.phase == NasPackageInstallPhase.OPTIONS) TextButton(onOptions) { Text(stringResource(R.string.pc_continue_install)) }
                if (progress.canCancel) TextButton(onCancel, enabled = !busy) { Text(stringResource(R.string.pc_cancel_preparation)) }
            }
        }
    }
}
@Composable
internal fun PackageOptionsSheet(options: NasPackageConfiguration, busy: Boolean, onDismiss: () -> Unit,
    onInstall: (String, Boolean, Boolean, Map<String, JsonPrimitive>) -> Unit) {
    var volume by remember(options) { mutableStateOf(options.volumes.singleOrNull()?.id ?: options.defaultVolume) }
    var start by remember(options) { mutableStateOf(options.canStart) }
    var accepted by remember(options) { mutableStateOf(false) }
    // 安装口令只保留在当前内存，不使用 rememberSaveable 或系统状态保存。
    var values by remember(options) { mutableStateOf(options.fields.filter { it.kind != NasPackageFieldKind.DESCRIPTION }.associate { it.id to it.defaultValue }) }
    ClientSheet(options.name, onDismiss, dismissEnabled = !busy) {
        Text(stringResource(R.string.pc_version, options.version))
        if (options.requiresRestart) Text(stringResource(R.string.pc_restart_later))
        if (options.volumes.size > 1) PackageChoice(stringResource(R.string.pc_location), volume, options.volumes, !busy) { volume = it }
        options.license?.let { license ->
            ClientSectionTitle(stringResource(R.string.pc_license))
            SelectionContainer { Text(packagePlainText(license)) }
            PackageToggle(stringResource(R.string.pc_accept_license), accepted, !busy) { accepted = it }
        }
        options.fields.forEach { field ->
            val value = values[field.id] ?: field.defaultValue
            when (field.kind) {
                NasPackageFieldKind.DESCRIPTION -> Text(packagePlainText(field.label))
                NasPackageFieldKind.TOGGLE -> PackageToggle(packagePlainText(field.label), value.booleanOrNull == true, !busy) { values = values + (field.id to JsonPrimitive(it)) }
                NasPackageFieldKind.RADIO -> Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value.booleanOrNull == true, !busy, Role.RadioButton) { selected ->
                    values = values.toMutableMap().also { map -> options.fields.filter { it.group == field.group }.forEach { map[it.id] = JsonPrimitive(selected && it.id == field.id) } }
                }, verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(value.booleanOrNull == true, null, enabled = !busy); Text(packagePlainText(field.label), Modifier.weight(1f))
                }
                NasPackageFieldKind.CHOICE -> PackageChoice(packagePlainText(field.label), value.content, field.choices, !busy) { values = values + (field.id to JsonPrimitive(it)) }
                NasPackageFieldKind.TEXT, NasPackageFieldKind.PASSWORD -> OutlinedTextField(value.content, { values = values + (field.id to JsonPrimitive(it)) },
                    label = { Text(packagePlainText(field.label)) }, enabled = !busy, singleLine = true, modifier = Modifier.fillMaxWidth(),
                    visualTransformation = if (field.kind == NasPackageFieldKind.PASSWORD) PasswordVisualTransformation() else VisualTransformation.None)
            }
        }
        if (options.canStart) PackageToggle(stringResource(R.string.pc_start_after), start, !busy) { start = it }
        Text(stringResource(R.string.pc_install_risk))
        Button(onClick = { onInstall(volume, start, accepted, values) }, enabled = !busy && (options.license == null || accepted), modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.pc_install_confirm))
        }
    }
}
