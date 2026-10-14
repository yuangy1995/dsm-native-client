package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.validSchedule
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatBytes
import java.time.DayOfWeek
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle

@Composable internal fun NasPowerSettingsSections(model: NasServiceSettingsModel, enabled: Boolean) {
    val states by model.state.collectAsState()
    val memory = states.getValue(NasServiceKind.MEMORY_COMPRESSION)
    val plans = states.getValue(NasServiceKind.POWER_SCHEDULE)
    var memoryEditor by remember { mutableStateOf(false) }
    var memoryConfirmation by remember { mutableStateOf(false) }
    var continuationConfirmation by remember(memory.record?.id) { mutableStateOf(false) }
    var showPlans by remember { mutableStateOf(false) }
    LaunchedEffect(model) {
        model.refresh(NasServiceKind.MEMORY_COMPRESSION, notify = false)
        model.refresh(NasServiceKind.POWER_SCHEDULE, notify = false)
    }
    val compression = (memory.current as? NasServiceValue.MemoryCompression)?.settings
    val draft = (memory.draft as? NasServiceValue.MemoryCompression)?.settings
    LaunchedEffect(memory.draft == null) {
        if (memory.draft == null) { memoryEditor = false; memoryConfirmation = false }
    }
    PowerSettingsGroup(R.string.nas_memory_compression, memory, { model.refresh(NasServiceKind.MEMORY_COMPRESSION, notify = false) }) {
        PowerSettingsFeedback(memory, NasServiceKind.MEMORY_COMPRESSION, model)
        if (compression != null) {
            Text(stringResource(when (compression.enabled) { true -> R.string.enabled; false -> R.string.disabled; null -> R.string.unknown_status }))
            compression.configuredBytes?.let { Text(stringResource(R.string.nas_memory_size, formatBytes(it))) }
            compression.algorithm?.let { Text(stringResource(R.string.nas_memory_algorithm, it)) }
            if (compression.rebootRequired == true) Text(stringResource(R.string.nas_memory_reboot_required))
            if (!compression.editable) Text(stringResource(R.string.nas_power_settings_readonly))
            val editDescription = stringResource(R.string.nas_edit_settings_accessibility, stringResource(R.string.nas_memory_compression))
            OutlinedButton({ if (model.begin(NasServiceValue.MemoryCompression(compression))) memoryEditor = true },
                modifier = Modifier.semantics { contentDescription = editDescription }, enabled = enabled && compression.editable && !memory.blocked && memory.failure == null) { Text(stringResource(R.string.edit)) }
        } else if (memory.loaded && memory.failure == null) Text(stringResource(R.string.nas_power_settings_unavailable))
        if (memory.record?.continuationStep == NasServiceStep.REBOOT_REQUIRED && !memory.blocked && draft == null) {
            OutlinedButton({ continuationConfirmation = true }, enabled = enabled) { Text(stringResource(R.string.nas_memory_mark_reboot)) }
        }
    }
    PowerSettingsGroup(R.string.nas_power_schedule, plans, { model.refresh(NasServiceKind.POWER_SCHEDULE, notify = false) }) {
        PowerSettingsFeedback(plans, NasServiceKind.POWER_SCHEDULE, model)
        val schedule = (plans.current as? NasServiceValue.PowerSchedule)?.settings
        if (schedule != null) {
            Text(pluralStringResource(R.plurals.nas_power_schedule_count, schedule.total, schedule.total))
            OutlinedButton({ showPlans = true }, enabled = !plans.saving) { Text(stringResource(R.string.nas_power_schedule_open)) }
        } else if (plans.loaded && plans.failure == null) Text(stringResource(R.string.nas_power_settings_unavailable))
    }
    if (memoryEditor && draft != null && !memory.blocked) ClientSheet(stringResource(R.string.nas_memory_compression), {
        memoryEditor = false; model.draft(NasServiceKind.MEMORY_COMPRESSION, null)
    }) {
        SettingsSwitch(stringResource(R.string.nas_memory_enabled), draft.enabled == true, enabled) {
            model.draft(NasServiceKind.MEMORY_COMPRESSION, NasServiceValue.MemoryCompression(draft.copy(enabled = it)))
        }
        Text(stringResource(R.string.nas_memory_save_risk))
        Button({ memoryEditor = false; memoryConfirmation = true }, enabled = enabled && memory.original != memory.draft) { Text(stringResource(R.string.save_changes)) }
    }
    if (memoryConfirmation && draft != null && !memory.blocked) AlertDialog(
        onDismissRequest = { memoryConfirmation = false; memoryEditor = true },
        title = { Text(stringResource(R.string.nas_memory_save_title)) },
        text = { Text(stringResource(R.string.nas_memory_save_risk)) },
        confirmButton = { TextButton({ if (model.save(NasServiceKind.MEMORY_COMPRESSION)) memoryConfirmation = false }, enabled = enabled) { Text(stringResource(R.string.save_changes)) } },
        dismissButton = { TextButton({ memoryConfirmation = false; memoryEditor = true }) { Text(stringResource(R.string.cancel)) } },
    )
    if (continuationConfirmation && memory.record?.continuationStep == NasServiceStep.REBOOT_REQUIRED && !memory.blocked) AlertDialog(
        onDismissRequest = { continuationConfirmation = false }, title = { Text(stringResource(R.string.nas_memory_mark_reboot)) },
        text = { Text(stringResource(R.string.nas_memory_mark_risk)) },
        confirmButton = { TextButton({ memory.record?.let { if (model.continuePendingStep(it)) continuationConfirmation = false } }, enabled = enabled) { Text(stringResource(R.string.nas_memory_mark_reboot)) } },
        dismissButton = { TextButton({ continuationConfirmation = false }) { Text(stringResource(R.string.cancel)) } },
    )
    if (showPlans) NasPowerSchedulePage(plans, model, enabled) { if (!plans.saving) { showPlans = false; model.draft(NasServiceKind.POWER_SCHEDULE, null) } }
}

@Composable private fun PowerSettingsGroup(title: Int, state: NasServiceEditorState, refresh: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    ClientGroup(Modifier.padding(12.dp)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
            OutlinedButton(refresh, enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            content()
        }
    }
}
@Composable private fun PowerSettingsFeedback(state: NasServiceEditorState, kind: NasServiceKind, model: NasServiceSettingsModel) {
    if (state.result != null || state.failure != null) SettingsMutationFeedbackCard(
        result = state.result, failure = if (state.result == null) state.failure else null, refreshFailure = state.failure,
        refreshInProgress = state.busy && !state.saving, refreshCompleted = false, currentMatches = null,
        countsLabel = R.string.nas_power_settings_counts, refreshLabel = R.string.refresh,
        onRefresh = { model.refresh(kind, notify = false) }, onContinueEditing = {}, onDismiss = { model.dismiss(kind, discard = true) },
        canContinueEditing = false, canDismiss = !state.blocked,
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun NasPowerSchedulePage(state: NasServiceEditorState, model: NasServiceSettingsModel, enabled: Boolean, onDismiss: () -> Unit) {
    val current = (state.current as? NasServiceValue.PowerSchedule)?.settings
    val draft = (state.draft as? NasServiceValue.PowerSchedule)?.settings
    val displayed = draft ?: current
    var editingRow by remember { mutableStateOf<Pair<Int, NasPowerScheduleEntry>?>(null) }
    var confirming by remember { mutableStateOf(false) }
    var filter by remember { mutableIntStateOf(0) }
    LaunchedEffect(state.draft == null) {
        if (state.draft == null) { editingRow = null; confirming = false }
    }
    val editable = enabled && !state.blocked && state.failure == null && displayed?.editable == true
    fun change(entries: List<NasPowerScheduleEntry>) {
        if (draft != null) model.draft(NasServiceKind.POWER_SCHEDULE, NasServiceValue.PowerSchedule(draft.copy(entries = entries, total = entries.size)))
    }
    ClientPageDialog(stringResource(R.string.nas_power_schedule), onDismiss) {
        Column(Modifier.fillMaxSize()) {
            FlowRow(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton({ model.refresh(NasServiceKind.POWER_SCHEDULE, notify = false) }, enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
                if (draft == null) {
                    OutlinedButton({ current?.let { model.begin(NasServiceValue.PowerSchedule(it)) } }, enabled = editable) { Text(stringResource(R.string.edit)) }
                } else {
                    OutlinedButton({ confirming = true }, enabled = editable && state.draft != state.original && draft.validSchedule()) { Text(stringResource(R.string.save_changes)) }
                    OutlinedButton({ model.draft(NasServiceKind.POWER_SCHEDULE, state.original) }, enabled = !state.blocked) { Text(stringResource(R.string.nas_power_schedule_restore)) }
                }
                OutlinedButton({
                    if (draft != null || current?.let { model.begin(NasServiceValue.PowerSchedule(it)) } == true)
                        editingRow = -1 to NasPowerScheduleEntry(NasPowerScheduleAction.STARTUP, false, (0..6).toSet(), 8, 0)
                }, enabled = editable && (displayed?.entries?.size ?: 200) < 200) { Text(stringResource(R.string.nas_power_schedule_add)) }
            }
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            FlowRow(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(R.string.st_all, R.string.nd_enabled_status, R.string.nd_disabled_status).forEachIndexed { index, label ->
                    FilterChip(filter == index, { filter = index }, label = { Text(stringResource(label)) })
                }
            }
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                item { PowerSettingsFeedback(state, NasServiceKind.POWER_SCHEDULE, model) }
                if (displayed != null) {
                    item {
                        Text(if (displayed.timezone == null) stringResource(R.string.nas_power_schedule_local_time) else stringResource(R.string.nas_power_schedule_timezone, displayed.timezone))
                        if (!displayed.editable) Text(stringResource(R.string.nas_power_schedule_readonly), color = MaterialTheme.colorScheme.error)
                        if (draft != null && !draft.validSchedule()) Text(stringResource(R.string.nas_power_schedule_conflict), color = MaterialTheme.colorScheme.error)
                    }
                    val rows = displayed.entries.withIndex().filter { filter == 0 || filter == 1 && it.value.enabled == true || filter == 2 && it.value.enabled == false }
                    if (rows.isEmpty()) item {
                        Text(stringResource(if (filter != 0) R.string.st_no_matches else if (displayed.complete) R.string.nas_power_schedule_empty else R.string.nas_power_settings_unavailable))
                        if (filter != 0) TextButton({ filter = 0 }) { Text(stringResource(R.string.st_all)) }
                        else if (displayed.editable) Text(stringResource(R.string.nas_power_schedule_empty_hint))
                    }
                    itemsIndexed(rows) { _, indexed -> val (index, row) = indexed
                        ClientGroup {
                            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(powerScheduleAction(row.action), style = MaterialTheme.typography.titleSmall)
                                Text(powerScheduleTime(row))
                                Text(powerScheduleDays(row))
                                if (draft != null && row.enabled != null) SettingsSwitch(stringResource(R.string.nas_power_schedule_enabled), row.enabled, editable) { flag ->
                                    change(draft.entries.mapIndexed { i, value -> if (i == index) value.copy(enabled = flag) else value })
                                } else Text(stringResource(when (row.enabled) { true -> R.string.enabled; false -> R.string.disabled; null -> R.string.unknown_status }))
                                if (draft != null) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    OutlinedButton({ editingRow = index to row }, enabled = editable) { Text(stringResource(R.string.edit)) }
                                    OutlinedButton({ change(draft.entries.filterIndexed { i, _ -> i != index }) }, enabled = editable) { Text(stringResource(R.string.remove)) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (editingRow != null && draft != null && !state.blocked) {
        val (index, row) = requireNotNull(editingRow)
        PowerScheduleEntryEditor(row, { editingRow = null }) { value ->
            change(if (index == -1) draft.entries + value else draft.entries.mapIndexed { i, entry -> if (i == index) value else entry })
            editingRow = null
        }
    }
    if (confirming && draft != null && !state.blocked) AlertDialog(
        onDismissRequest = { confirming = false }, title = { Text(stringResource(R.string.nas_power_schedule_save_title)) },
        text = { Text(pluralStringResource(R.plurals.nas_power_schedule_save_risk, draft.entries.size, draft.entries.size)) },
        confirmButton = { TextButton({ if (model.save(NasServiceKind.POWER_SCHEDULE)) confirming = false }, enabled = editable && draft.validSchedule()) { Text(stringResource(R.string.save_changes)) } },
        dismissButton = { TextButton({ confirming = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun PowerScheduleEntryEditor(initial: NasPowerScheduleEntry, onDismiss: () -> Unit, onSave: (NasPowerScheduleEntry) -> Unit) {
    var draft by remember(initial) { mutableStateOf(initial) }
    var hour by remember(initial) { mutableStateOf(initial.hour?.toString().orEmpty()) }
    var minute by remember(initial) { mutableStateOf(initial.minute?.toString().orEmpty()) }
    val locale = LocalConfiguration.current.locales[0]
    ClientSheet(stringResource(R.string.nas_power_schedule_entry), onDismiss) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(NasPowerScheduleAction.STARTUP, NasPowerScheduleAction.SHUTDOWN).forEach { action ->
                FilterChip(draft.action == action, { draft = draft.copy(action = action) }, label = { Text(powerScheduleAction(action)) })
            }
        }
        SettingsSwitch(stringResource(R.string.nas_power_schedule_enabled), draft.enabled == true, true) { draft = draft.copy(enabled = it) }
        Text(stringResource(R.string.nas_power_schedule_local_time))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(hour, { hour = it }, label = { Text(stringResource(R.string.st_hour)) }, isError = hour.toIntOrNull() !in 0..23,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true, modifier = Modifier.weight(1f))
            OutlinedTextField(minute, { minute = it }, label = { Text(stringResource(R.string.st_minute)) }, isError = minute.toIntOrNull() !in 0..59,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true, modifier = Modifier.weight(1f))
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            (0..6).forEach { day -> FilterChip(day in draft.weekdays, {
                draft = draft.copy(weekdays = if (day in draft.weekdays) draft.weekdays - day else draft.weekdays + day)
            }, label = { Text(DayOfWeek.of(if (day == 0) 7 else day).getDisplayName(TextStyle.FULL, locale)) }) }
        }
        val proposed = draft.copy(hour = hour.toIntOrNull(), minute = minute.toIntOrNull())
        if (!proposed.editable) Text(stringResource(R.string.nas_power_schedule_entry_invalid), color = MaterialTheme.colorScheme.error)
        Button({ onSave(proposed) }, enabled = proposed.editable) { Text(stringResource(R.string.nas_power_schedule_keep_entry)) }
    }
}
@Composable private fun powerScheduleAction(action: NasPowerScheduleAction) = stringResource(when (action) {
    NasPowerScheduleAction.STARTUP -> R.string.nas_power_schedule_startup
    NasPowerScheduleAction.SHUTDOWN -> R.string.nas_power_schedule_shutdown
    NasPowerScheduleAction.RESTART -> R.string.restart_nas
    NasPowerScheduleAction.UNKNOWN -> R.string.unknown_status
})
@Composable private fun powerScheduleTime(row: NasPowerScheduleEntry): String {
    val locale = LocalConfiguration.current.locales[0]
    return if (row.hour != null && row.minute != null) LocalTime.of(row.hour, row.minute).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale))
        else stringResource(R.string.unknown_status)
}
@Composable private fun powerScheduleDays(row: NasPowerScheduleEntry): String {
    val locale = LocalConfiguration.current.locales[0]
    return if (row.recurring && row.weekdays.isNotEmpty()) row.weekdays.sorted().joinToString(", ") { DayOfWeek.of(if (it == 0) 7 else it).getDisplayName(TextStyle.SHORT, locale) }
        else stringResource(R.string.nas_power_schedule_other_recurrence)
}
