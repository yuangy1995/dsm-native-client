package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.MAX_VIRTUAL_MACHINE_DISKS
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable internal fun VmmCreationSheet(state: VmmCreationState, onChange: (VmmCreationDraft) -> Unit,
    onCreate: () -> Unit, onRetry: () -> Unit, onClose: () -> Unit, onContinue: () -> Unit) {
    val review = state.review
    if (review != null) {
        ClientSheet(stringResource(R.string.create_virtual_machine), onDismiss = onClose, dismissEnabled = !state.busy) {
            VmmCreationSummary(review.snapshot.plan)
            Text(stringResource(vmmCreationStageLabel(review.progress.stage, state.busy)))
            state.failure?.let { Text(vmmErrorText(it, R.string.vm_creation_changed), color = MaterialTheme.colorScheme.error) }
            Button(onClick = onContinue, enabled = !state.busy, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.continue_action)) }
            TextButton(onClick = onClose, enabled = !state.busy, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) }
        }
        return
    }
    if (!state.editor) return
    ClientSheet(stringResource(R.string.create_virtual_machine), onDismiss = onClose, dismissEnabled = !state.busy) {
        val draft = state.draft
        BackHandler(enabled = !state.busy && draft != null && draft.step > 0) { draft?.let { onChange(it.copy(step = it.step - 1)) } }
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.records.singleOrNull { it.id == state.activeId }?.let { record ->
                Text(stringResource(vmmCreationStageLabel(record.progress.stage, active = true)), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                record.progress.percent?.takeIf { record.progress.stage == VmmCreationStage.CREATING }?.let { percent ->
                    LinearProgressIndicator(progress = { percent / 100f }, modifier = Modifier.fillMaxWidth())
                }
            }
            state.failure?.let { error ->
                Text(vmmErrorText(error, R.string.vm_creation_changed), color = MaterialTheme.colorScheme.error)
                TextButton(onClick = onRetry, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
            }
            if (draft != null && state.resources != null) {
                val enabled = !state.busy && state.failure == null
                val resources = state.resources
                Text(stringResource(R.string.virtual_machine_creation_step, draft.step + 1, 3), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                when (draft.step) {
                    0 -> {
                        val presets = VmmCreationPreset.entries.filter { (if (it == VmmCreationPreset.GENERAL) VmmSource.PUBLIC else VmmSource.INTERNAL) in state.sources }
                        if (presets.size > 1) VmmSettingsChoice(R.string.vm_creation_template, draft.preset.ordinal, presets.map { it.ordinal }, presets.map(::vmmPresetLabel), enabled) {
                            onChange(draft.copy(preset = VmmCreationPreset.entries[it]))
                        }
                        if (draft.source == VmmSource.INTERNAL) Text(stringResource(R.string.vm_creation_template_limit), style = MaterialTheme.typography.bodySmall)
                        OutlinedTextField(draft.name, { onChange(draft.copy(name = it)) }, label = { Text(stringResource(R.string.virtual_machine_name)) },
                            enabled = enabled, singleLine = true, isError = draft.name.isNotEmpty() && !validVmmSettingsName(draft.name),
                            supportingText = { if (draft.name.isNotEmpty() && !validVmmSettingsName(draft.name)) Text(stringResource(R.string.virtual_machine_name_invalid), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive }) }, modifier = Modifier.fillMaxWidth())
                        OutlinedTextField(draft.description, { onChange(draft.copy(description = it)) }, label = { Text(stringResource(R.string.virtual_machine_description)) },
                            enabled = enabled, minLines = 2, isError = draft.description.length > 1024,
                            supportingText = { if (draft.description.length > 1024) Text(stringResource(R.string.virtual_machine_description_invalid), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive }) }, modifier = Modifier.fillMaxWidth())
                        VmmSettingsChoice(R.string.vm_startup, draft.startup, listOf(0, 1, 2), listOf(R.string.vm_startup_off, R.string.vm_startup_restore, R.string.vm_startup_on), enabled) {
                            onChange(draft.copy(startup = it))
                        }
                    }
                    1 -> {
                        CreationNumber(draft.cpu, R.string.virtual_machine_cpu, 1..64, R.string.virtual_machine_cpu_range, enabled) { onChange(draft.copy(cpu = it)) }
                        CreationNumber(draft.memory, R.string.virtual_machine_memory_mib, 128..1_048_576, R.string.virtual_machine_memory_range, enabled) { onChange(draft.copy(memory = it)) }
                        draft.disks.forEachIndexed { index, disk ->
                            Text(stringResource(R.string.virtual_machine_disk_number, index + 1), style = MaterialTheme.typography.titleSmall)
                            if (draft.source == VmmSource.PUBLIC && resources.images.isNotEmpty()) CreationSelection(
                                stringResource(R.string.virtual_machine_disk_source), disk.image,
                                listOf(null to stringResource(R.string.virtual_machine_empty_disk)) + resources.images.map { it.ref.id to it.ref.name }, enabled) { id ->
                                onChange(draft.copy(disks = draft.disks.mapIndexed { i, value -> if (i == index) value.copy(image = id) else value }))
                            }
                            if (disk.image == null) CreationNumber(disk.size, R.string.virtual_machine_disk_gib,
                                (if (draft.source == VmmSource.INTERNAL) 10 else 1)..1_048_576,
                                if (draft.source == VmmSource.INTERNAL) R.string.vm_creation_disk_range else R.string.virtual_machine_disk_range, enabled) { size ->
                                onChange(draft.copy(disks = draft.disks.mapIndexed { i, value -> if (i == index) value.copy(size = size) else value }))
                            } else Text(stringResource(R.string.virtual_machine_image_original_capacity))
                            if (index > 0) TextButton(onClick = { onChange(draft.copy(disks = draft.disks.filterIndexed { i, _ -> i != index })) }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) {
                                Text(stringResource(R.string.virtual_machine_remove_disk_number, index + 1))
                            }
                        }
                        if (draft.source == VmmSource.PUBLIC) {
                            if (!resources.imagesAvailable) Text(stringResource(R.string.vm_creation_images_unavailable), style = MaterialTheme.typography.bodySmall)
                            TextButton(onClick = { onChange(draft.copy(disks = draft.disks + VmmCreationDiskDraft())) }, enabled = enabled && draft.disks.size < MAX_VIRTUAL_MACHINE_DISKS, modifier = Modifier.heightIn(min = 48.dp)) {
                                Text(stringResource(R.string.virtual_machine_add_disk))
                            }
                        } else VmmSettingsChoice(R.string.vm_creation_firmware, if (draft.uefi) 1 else 0, listOf(1, 0),
                            listOf(R.string.vm_creation_uefi, R.string.vm_creation_legacy), enabled) { onChange(draft.copy(uefi = it == 1)) }
                    }
                    2 -> {
                        if (resources.storages.isEmpty()) {
                            Text(stringResource(R.string.virtual_machine_no_storage))
                            TextButton(onClick = onRetry, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
                        } else CreationSelection(stringResource(R.string.virtual_machine_storage), draft.storage, resources.storages.map { it.ref.id to it.ref.name }, enabled) {
                            onChange(draft.copy(storage = it))
                        }
                        draft.networks.forEachIndexed { index, network ->
                            CreationSelection(stringResource(R.string.virtual_machine_additional_network_number, index + 1), network,
                                listOf(null to stringResource(R.string.virtual_machine_disconnected_network)) + resources.networks.map { it.id to it.name }, enabled) { selected ->
                                onChange(draft.copy(networks = draft.networks.mapIndexed { i, value -> if (i == index) selected else value }))
                            }
                            if (index > 0) TextButton(onClick = { onChange(draft.copy(networks = draft.networks.filterIndexed { i, _ -> i != index })) }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) {
                                Text(stringResource(R.string.virtual_machine_remove_network_number, index + 1))
                            }
                        }
                        if (!resources.networksAvailable) Text(stringResource(R.string.vm_creation_networks_unavailable), style = MaterialTheme.typography.bodySmall)
                        if (draft.source == VmmSource.PUBLIC) TextButton(onClick = { onChange(draft.copy(networks = draft.networks + listOf(null))) }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.virtual_machine_add_network))
                        } else {
                            val storage = resources.storages.singleOrNull { it.ref.id == draft.storage }
                            CreationSelection(stringResource(R.string.vm_creation_iso), draft.iso,
                                listOf(null to stringResource(R.string.vm_creation_no_iso)) + resources.images.filter { it.storage == storage?.ref?.id && it.host == storage?.host }.map { it.ref.id to it.ref.name }, enabled) {
                                onChange(draft.copy(iso = it))
                            }
                            if (!resources.imagesAvailable) Text(stringResource(R.string.vm_creation_images_unavailable), style = MaterialTheme.typography.bodySmall)
                        }
                        ListItem(headlineContent = { Text(stringResource(R.string.vm_creation_power_on)) },
                            supportingContent = { if (draft.powerOn) Text(stringResource(R.string.vm_start_risk)) },
                            trailingContent = { Switch(draft.powerOn, onCheckedChange = null, enabled = enabled && state.powerAvailable) },
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(draft.powerOn, enabled && state.powerAvailable, Role.Switch) { onChange(draft.copy(powerOn = it)) })
                        state.plan?.let { plan -> HorizontalDivider(); VmmCreationSummary(plan) }
                    }
                }
                Button(onClick = { if (draft.step == 2) onCreate() else onChange(draft.copy(step = draft.step + 1)) },
                    enabled = enabled && when (draft.step) { 0 -> draft.basicsValid; 1 -> draft.hardwareValid; else -> state.canCreate },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Text(stringResource(if (draft.step == 2) R.string.create else R.string.virtual_machine_next_step))
                }
                if (draft.step > 0) TextButton(onClick = { onChange(draft.copy(step = draft.step - 1)) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.virtual_machine_previous_step))
                }
            }
            TextButton(onClick = onClose, enabled = !state.busy, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) }
        }
    }
}

@Composable private fun CreationNumber(value: String, label: Int, range: IntRange, error: Int, enabled: Boolean, onChange: (String) -> Unit) {
    val invalid = value.toIntOrNull() !in range
    OutlinedTextField(value, onChange, label = { Text(stringResource(label)) }, singleLine = true, enabled = enabled, isError = invalid,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), supportingText = { if (invalid) Text(stringResource(error), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive }) }, modifier = Modifier.fillMaxWidth())
}
@Composable private fun CreationSelection(title: String, selected: String?, options: List<Pair<String?, String>>, enabled: Boolean, onChange: (String?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Text(title, style = MaterialTheme.typography.labelLarge)
        if (options.size == 1 && selected == options.single().first) Text(options.single().second)
        else Box {
            OutlinedButton(onClick = { expanded = true }, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text(options.singleOrNull { it.first == selected }?.second ?: stringResource(R.string.virtual_machine_selection_unavailable))
            }
            DropdownMenu(expanded, onDismissRequest = { expanded = false }) { options.forEach { (id, name) ->
                DropdownMenuItem(text = { Text(name) }, onClick = { expanded = false; onChange(id) }, modifier = Modifier.heightIn(min = 48.dp))
            } }
        }
    }
}
internal fun vmmPresetLabel(preset: VmmCreationPreset) = when (preset) {
    VmmCreationPreset.GENERAL -> R.string.vm_creation_general
    VmmCreationPreset.LINUX -> R.string.vm_creation_linux
    VmmCreationPreset.WINDOWS -> R.string.vm_creation_windows
    VmmCreationPreset.OTHER -> R.string.vm_creation_other
}
@Composable private fun VmmCreationSummary(plan: VmmCreationPlan) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(plan.configuration.name, style = MaterialTheme.typography.titleMedium)
        if (!plan.configuration.description.isNullOrEmpty()) Text(plan.configuration.description)
        Text(stringResource(vmmPresetLabel(plan.preset)))
        Text(stringResource(R.string.virtual_machine_review_item, stringResource(R.string.virtual_machine_cpu), stringResource(R.string.virtual_machine_processor_count, plan.configuration.cpu!!)))
        Text(stringResource(R.string.virtual_machine_memory_value, plan.configuration.memoryMiB!!))
        Text(stringResource(R.string.virtual_machine_review_item, stringResource(R.string.virtual_machine_storage), plan.storage.ref.name))
        plan.disks.forEachIndexed { index, disk -> Text(if (disk.image == null) stringResource(R.string.virtual_machine_additional_empty_disk_review, index + 1,
            java.text.NumberFormat.getIntegerInstance(androidx.compose.ui.platform.LocalConfiguration.current.locales[0]).format(disk.gib))
            else stringResource(R.string.virtual_machine_additional_image_disk_review, index + 1, disk.image.name)) }
        plan.networks.forEachIndexed { index, network -> Text(stringResource(R.string.virtual_machine_additional_network_review, index + 1,
            network?.name ?: stringResource(R.string.virtual_machine_disconnected_network))) }
        if (plan.source == VmmSource.INTERNAL) {
            Text(stringResource(if (plan.uefi) R.string.vm_creation_uefi else R.string.vm_creation_legacy))
            Text(plan.iso?.ref?.name ?: stringResource(R.string.vm_creation_no_iso))
        }
        Text(stringResource(R.string.virtual_machine_review_item, stringResource(R.string.vm_startup), stringResource(when (plan.configuration.startup) {
            1 -> R.string.vm_startup_restore; 2 -> R.string.vm_startup_on; else -> R.string.vm_startup_off
        })))
        Text(stringResource(if (plan.powerOn) R.string.vm_creation_power_on else R.string.vm_creation_keep_off))
    }
}

@Composable internal fun VmmCreationRecords(state: VmmCreationState, onRefresh: () -> Unit, onReview: (String) -> Unit, onDismiss: (String) -> Unit) {
    if (!state.editor && state.reviewId == null) state.failure?.let { error -> ClientGroup { Column(Modifier.padding(16.dp)) {
        Text(vmmErrorText(error, R.string.vm_creation_changed), color = MaterialTheme.colorScheme.error)
        TextButton(onClick = onRefresh, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
    } } }
    state.records.forEach { record -> ClientGroup {
        Column(Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(record.snapshot.plan.configuration.name, style = MaterialTheme.typography.titleSmall)
            Text(stringResource(vmmCreationStageLabel(record.progress.stage, state.busy && state.activeId == record.id)))
            if (record.pending && !record.progress.stage.canContinue) Text(stringResource(R.string.vm_pending_hint))
            record.progress.percent?.takeIf { record.progress.stage == VmmCreationStage.CREATING }?.let { LinearProgressIndicator(progress = { it / 100f }, modifier = Modifier.fillMaxWidth()) }
            if (record.progress.stage.canContinue) TextButton(onClick = { onReview(record.id) }, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.continue_action)) }
            TextButton(onClick = { if (record.pending) onRefresh() else onDismiss(record.id) }, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(if (record.pending) R.string.refresh else R.string.close))
            }
        }
    } }
}

private fun vmmCreationStageLabel(stage: VmmCreationStage, active: Boolean = false) = when (stage) {
    VmmCreationStage.PREPARED, VmmCreationStage.CANCELLED -> R.string.vm_not_sent
    VmmCreationStage.CREATE_SENT -> if (active) R.string.vm_creation_creating else R.string.vm_result_unavailable
    VmmCreationStage.CONFIGURE_SENT -> if (active) R.string.vm_creation_configuring else R.string.vm_result_unavailable
    VmmCreationStage.POWER_SENT -> if (active) R.string.vm_creation_starting else R.string.vm_result_unavailable
    VmmCreationStage.CREATING -> R.string.vm_creation_creating
    VmmCreationStage.CREATED -> R.string.vm_creation_continue_settings
    VmmCreationStage.CONFIGURED -> R.string.vm_creation_continue_power
    VmmCreationStage.CONFIGURING -> R.string.vm_creation_configuring
    VmmCreationStage.STARTING -> R.string.vm_creation_starting
    VmmCreationStage.COMPLETE -> R.string.vm_creation_complete
    VmmCreationStage.REJECTED -> R.string.vm_rejected
    VmmCreationStage.PARTIAL -> R.string.vm_creation_partial
}
