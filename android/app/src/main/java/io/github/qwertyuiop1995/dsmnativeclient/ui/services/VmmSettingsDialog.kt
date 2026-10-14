package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable internal fun VmmSettingsSheet(state: VmmSettingsState, onChange: (VmmSettingsDraft) -> Unit,
    onSave: () -> Unit, onRetry: () -> Unit, onClose: () -> Unit) {
    if (!state.editor) return
    ClientSheet(stringResource(R.string.edit_virtual_machine), onDismiss = onClose, dismissEnabled = !state.busy) {
        Column(Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.failure?.let { error ->
                Text(vmmErrorText(error, R.string.vm_settings_changed), color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                TextButton(onClick = onRetry, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
            }
            val baseline = state.baseline; val draft = state.draft
            if (baseline != null && draft != null) {
                val enabled = !state.busy && state.failure == null && baseline.editable
                if (!baseline.editable) Text(stringResource(R.string.vm_actions_unavailable))
                OutlinedTextField(draft.name, { onChange(draft.copy(name = it)) }, label = { Text(stringResource(R.string.virtual_machine_name)) },
                    enabled = enabled, singleLine = true, isError = !validVmmSettingsName(draft.name),
                    supportingText = { if (!validVmmSettingsName(draft.name)) Text(stringResource(R.string.virtual_machine_name_invalid), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive }) }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(draft.description.orEmpty(), { onChange(draft.copy(description = it)) }, label = { Text(stringResource(R.string.virtual_machine_description)) },
                    enabled = enabled && baseline.configuration.description != null, minLines = 2, isError = (draft.description?.length ?: 0) > 1024,
                    supportingText = { if ((draft.description?.length ?: 0) > 1024) Text(stringResource(R.string.virtual_machine_description_invalid), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive }) }, modifier = Modifier.fillMaxWidth())
                VmmSettingsNumber(draft.cpu, { onChange(draft.copy(cpu = it)) }, R.string.virtual_machine_cpu, R.string.virtual_machine_cpu_range,
                    1..64, enabled && baseline.hardwareEditable && baseline.configuration.cpu != null)
                VmmSettingsNumber(draft.memory, { onChange(draft.copy(memory = it)) }, R.string.virtual_machine_memory_mib, R.string.virtual_machine_memory_range,
                    128..1_048_576, enabled && baseline.hardwareEditable && baseline.configuration.memoryMiB != null)
                if (!baseline.hardwareEditable) Text(stringResource(R.string.vm_hardware_stop), style = MaterialTheme.typography.bodySmall)
                if (listOf(baseline.configuration.description, baseline.configuration.cpu, baseline.configuration.memoryMiB, baseline.configuration.startup).any { it == null })
                    Text(stringResource(R.string.vm_settings_missing), style = MaterialTheme.typography.bodySmall)
                VmmSettingsChoice(R.string.vm_startup, draft.startup, listOf(0, 1, 2), listOf(R.string.vm_startup_off, R.string.vm_startup_restore, R.string.vm_startup_on),
                    enabled && baseline.configuration.startup != null) { onChange(draft.copy(startup = it)) }
                if (baseline.configuration.priority != null) VmmSettingsChoice(R.string.vm_priority, draft.priority, vmmPriorities,
                    listOf(R.string.vm_priority_lowest, R.string.vm_priority_low, R.string.vm_priority_normal, R.string.vm_priority_high, R.string.vm_priority_highest),
                    enabled) { onChange(draft.copy(priority = it)) }
            }
            Button(onClick = onSave, enabled = state.canSave, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.save_changes)) }
            TextButton(onClick = onClose, enabled = !state.busy, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) }
        }
    }
}

@Composable private fun VmmSettingsNumber(value: String?, onChange: (String) -> Unit, title: Int, hint: Int, range: IntRange, enabled: Boolean) {
    val invalid = value != null && value.toIntOrNull() !in range
    OutlinedTextField(value.orEmpty(), onChange, label = { Text(stringResource(title)) }, isError = invalid, enabled = enabled, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), supportingText = { if (invalid) Text(stringResource(hint), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive }) }, modifier = Modifier.fillMaxWidth())
}

@Composable internal fun VmmSettingsChoice(title: Int, value: Int?, options: List<Int>, labels: List<Int>, enabled: Boolean, onChange: (Int) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Text(stringResource(title), style = MaterialTheme.typography.labelLarge)
        Box {
            OutlinedButton(onClick = { expanded = true }, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text(stringResource(labels.getOrNull(options.indexOf(value)) ?: R.string.unavailable))
            }
            DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
                options.forEachIndexed { index, option -> DropdownMenuItem(text = { Text(stringResource(labels[index])) },
                    onClick = { expanded = false; onChange(option) }, modifier = Modifier.heightIn(min = 48.dp)) }
            }
        }
    }
}

@Composable internal fun VmmSettingsRecords(state: VmmSettingsState, targets: List<VmmControlTarget>, onRefresh: () -> Unit, onDismiss: () -> Unit) {
    if (!state.editor) state.failure?.let { error -> ClientGroup { Column(Modifier.padding(16.dp)) {
        Text(vmmErrorText(error, R.string.vm_settings_changed), color = MaterialTheme.colorScheme.error)
        TextButton(onClick = onRefresh, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
    } } }
    state.records.forEachIndexed { index, record -> ClientGroup {
        Column(Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.edit_virtual_machine), style = MaterialTheme.typography.titleSmall)
            val name = targets.singleOrNull { vmmDigest(it.id) == record.target }?.name ?: stringResource(R.string.vm_item_number, index + 1)
            Text(stringResource(R.string.vm_item_status, name, stringResource(when (record.stage) {
                VmmStage.PREPARED, VmmStage.CANCELLED -> R.string.vm_not_sent
                VmmStage.SUBMITTED -> R.string.vm_result_unavailable
                VmmStage.ACCEPTED -> R.string.vm_processing
                VmmStage.REJECTED -> R.string.vm_rejected
                VmmStage.VERIFIED -> R.string.vm_settings_saved
            })))
            if (record.pending) Text(stringResource(R.string.vm_pending_hint))
            TextButton(onClick = if (record.pending) onRefresh else onDismiss, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(if (record.pending) R.string.refresh else R.string.close)) }
        }
    } }
}
