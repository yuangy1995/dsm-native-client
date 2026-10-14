package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import java.time.DayOfWeek
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle

@Composable internal fun NasScheduledTaskScreen(model: NasScheduledTaskModel) {
    val state by model.state.collectAsStateWithLifecycle()
    var activity by rememberSaveable { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableIntStateOf(0) }
    LaunchedEffect(model) { model.load() }
    DisposableEffect(model) { onDispose { model.leavePage() } }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(!activity, { activity = false }, label = { Text(stringResource(R.string.st_tasks)) })
            FilterChip(activity, { activity = true }, label = { Text(stringResource(R.string.pc_activity)) })
        }
        Row(Modifier.padding(horizontal = 12.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(model::load, enabled = !state.loading && !state.busy) { Text(stringResource(R.string.refresh)) }
            if (!activity) OutlinedButton(model::create, enabled = state.writable && state.canCreate) { Text(stringResource(R.string.st_create)) }
        }
        if (state.loading || state.busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(12.dp))
        state.failure?.let { TaskError(it, model::dismissFailure) }
        if (!activity && state.records.any { !it.terminal }) Column(Modifier.padding(horizontal = 12.dp)) {
            Text(stringResource(R.string.st_busy))
            TextButton({ activity = true }) { Text(stringResource(R.string.pc_activity)) }
        }
        if (!activity) {
            OutlinedTextField(search, { search = it }, label = { Text(stringResource(R.string.st_search)) }, singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(12.dp))
            Row(Modifier.padding(horizontal = 12.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(R.string.st_all, R.string.nd_enabled_status, R.string.nd_disabled_status).forEachIndexed { index, text ->
                    FilterChip(filter == index, { filter = index }, label = { Text(stringResource(text)) })
                }
            }
        }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (activity) {
                if (state.records.isEmpty()) item { Text(stringResource(R.string.st_no_activity)) }
                items(state.records, key = { it.id }) { record -> ClientGroup {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(stringResource(taskActionText(record.action)), style = MaterialTheme.typography.titleSmall)
                        Text(stringResource(when (record.stage) { NasTaskStage.COMPLETED -> if (record.action == NasTaskAction.RUN) R.string.st_run_sent else R.string.nd_completed
                            NasTaskStage.REJECTED -> R.string.nd_rejected; else -> R.string.st_unknown }))
                        if (record.terminal) TextButton({ model.discard(record.id) }, enabled = !state.busy) { Text(stringResource(R.string.nd_remove_record)) }
                        else OutlinedButton({ model.review(record.id) }, enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
                    }
                } }
            } else {
                val rows = state.tasks?.filter { (it.name.contains(search, true) || it.owner.orEmpty().contains(search, true)) &&
                    (filter == 0 || filter == 1 && it.enabled == true || filter == 2 && it.enabled == false) }
                if (rows?.isEmpty() == true && !state.loading && state.failure == null) item {
                    Text(stringResource(if (search.isNotBlank() || filter != 0) R.string.st_no_matches else R.string.st_empty))
                    Text(stringResource(if (search.isNotBlank() || filter != 0) R.string.st_filter_hint else R.string.st_empty_hint))
                }
                items(rows.orEmpty(), key = { it.id }) { task -> ClientGroup {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(task.name, style = MaterialTheme.typography.titleSmall)
                        Text(taskEnabledText(task.enabled))
                        task.owner?.let { Text(stringResource(R.string.st_runs_as, it)) }
                        task.nextTrigger?.takeIf { it.isNotBlank() }?.let { Text(stringResource(R.string.st_next, taskTime(it))) }
                        OutlinedButton({ model.inspect(task) }, enabled = !state.busy) { Text(stringResource(R.string.st_details)) }
                    }
                } }
            }
        }
    }
    if (state.selected != null && state.editor == null) TaskDetailSheet(state, model)
    state.editor?.let { TaskEditor(it, state.busy, state.failure, model::closeEditor, model::save) }
    state.confirmation?.let { change -> TaskConfirmation(change, state.busy, model::cancelConfirmation, model::confirm) }
    if (state.selectedResult != null) ClientSheet(stringResource(R.string.st_output), model::closeOutput) {
        if (state.outputLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.outputFailure?.let { TaskError(it) }
        state.output?.let { value ->
            if (value.command == null && value.output == null) Text(stringResource(R.string.st_output_unavailable))
            value.command?.let { Text(stringResource(R.string.st_command)); SelectionContainer { Text(it.ifEmpty { stringResource(R.string.st_empty_output) }, fontFamily = FontFamily.Monospace) } }
            value.output?.let { Text(stringResource(R.string.st_output)); SelectionContainer { Text(it.ifEmpty { stringResource(R.string.st_empty_output) }, fontFamily = FontFamily.Monospace) } }
        }
    }
}
@Composable private fun TaskDetailSheet(state: NasScheduledTaskState, model: NasScheduledTaskModel) {
    val task = state.selected ?: return
    ClientSheet(task.name, model::closeDetail, dismissEnabled = !state.busy) {
        Text(taskEnabledText(task.enabled)); task.owner?.let { Text(stringResource(R.string.st_runs_as, it)) }
        if (state.detailLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.detailFailure?.let { TaskError(it) }
        state.failure?.let { TaskError(it) }
        state.detail?.let { draft ->
            Text(stringResource(R.string.st_script)); SelectionContainer { Text(draft.script, fontFamily = FontFamily.Monospace) }
            Text(stringResource(R.string.st_time, draft.schedule.hour, draft.schedule.minute))
            if (draft.notificationEmails.isNotEmpty()) Text(stringResource(R.string.st_notification_to, draft.notificationEmails))
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(model::edit, enabled = state.writable && task.canEdit && state.detail != null) { Text(stringResource(R.string.edit)) }
            if (task.enabled != null) OutlinedButton({ model.request(if (task.enabled) NasTaskAction.DISABLE else NasTaskAction.ENABLE) },
                enabled = state.writable && task.canEdit && (task.enabled || state.detail != null)) { Text(stringResource(if (task.enabled) R.string.st_disable else R.string.st_enable)) }
            OutlinedButton({ model.request(NasTaskAction.RUN) }, enabled = state.writable && task.canRun && (task.type != "script" || state.detail != null)) { Text(stringResource(R.string.st_run)) }
            OutlinedButton({ model.request(NasTaskAction.DELETE) }, enabled = state.writable && task.canEdit) { Text(stringResource(R.string.delete)) }
        }
        OutlinedButton(model::results, enabled = !state.resultsLoading && !state.busy) { Text(stringResource(R.string.st_history)) }
        if (state.resultsLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.resultsFailure?.let { TaskError(it) }
        if (state.results?.isEmpty() == true) Text(stringResource(R.string.st_no_results))
        state.results?.forEach { result ->
            HorizontalDivider()
            result.started?.let { Text(taskTime(it)) }
            result.stopped?.let { Text(stringResource(R.string.st_finished, taskTime(it))) }
            result.exitCode?.let { Text(stringResource(R.string.st_exit_code, it)) }
            result.exitType?.let { Text(it) }
            OutlinedButton({ model.output(result) }) { Text(stringResource(R.string.st_view_output)) }
        }
    }
}
@Composable private fun TaskEditor(initial: NasTaskDraft, busy: Boolean, failure: Exception?, onDismiss: () -> Unit, onSave: (NasTaskDraft) -> Unit) {
    var draft by remember(initial) { mutableStateOf(initial) }
    var hour by remember(initial) { mutableStateOf(initial.schedule.hour.toString()) }
    var minute by remember(initial) { mutableStateOf(initial.schedule.minute.toString()) }
    val locale = LocalConfiguration.current.locales[0]
    ClientSheet(stringResource(if (initial.id == null) R.string.st_create else R.string.st_edit), onDismiss, dismissEnabled = !busy) {
        OutlinedTextField(draft.name, { draft = draft.copy(name = it) }, enabled = !busy, label = { Text(stringResource(R.string.nd_name)) }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        OutlinedTextField(draft.owner, { draft = draft.copy(owner = it) }, enabled = !busy, label = { Text(stringResource(R.string.st_owner)) }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        PackageToggle(stringResource(R.string.st_enabled), draft.enabled, !busy) { draft = draft.copy(enabled = it) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(hour, { hour = it }, enabled = !busy, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                label = { Text(stringResource(R.string.st_hour)) }, singleLine = true, modifier = Modifier.weight(1f))
            OutlinedTextField(minute, { minute = it }, enabled = !busy, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                label = { Text(stringResource(R.string.st_minute)) }, singleLine = true, modifier = Modifier.weight(1f))
        }
        if (draft.schedule.selectedDays == null) Text(stringResource(R.string.st_other_days)) else Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            (0..6).forEach { day -> val selected = day in draft.schedule.selectedDays.orEmpty()
                FilterChip(selected, {
                    val days = draft.schedule.selectedDays.orEmpty().toMutableSet()
                    if (selected) { if (days.size > 1) days.remove(day) } else days.add(day)
                    draft = draft.copy(schedule = draft.schedule.copy(weekdays = days.sorted().joinToString(",")))
                }, enabled = !busy, label = { Text(DayOfWeek.of(if (day == 0) 7 else day).getDisplayName(TextStyle.SHORT, locale)) })
            }
        }
        OutlinedTextField(draft.script, { draft = draft.copy(script = it) }, enabled = !busy, minLines = 5,
            label = { Text(stringResource(R.string.st_script)) }, textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace), modifier = Modifier.fillMaxWidth())
        PackageToggle(stringResource(R.string.st_notify_error), draft.notifyOnError, !busy) { draft = draft.copy(notifyOnError = it) }
        OutlinedTextField(draft.notificationEmails, { draft = draft.copy(notificationEmails = it) }, enabled = !busy,
            label = { Text(stringResource(R.string.st_notification_email)) }, modifier = Modifier.fillMaxWidth())
        failure?.let { TaskError(it) }
        Button({ onSave(draft.copy(schedule = draft.schedule.copy(hour = hour.toInt(), minute = minute.toInt()))) },
            enabled = !busy && draft.name.isNotBlank() && draft.owner.isNotBlank() && draft.script.isNotBlank() && hour.toIntOrNull() in 0..23 && minute.toIntOrNull() in 0..59,
            modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.nd_save_changes)) }
    }
}
@Composable private fun TaskConfirmation(change: NasTaskChange, busy: Boolean, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(onDismissRequest = { if (!busy) onDismiss() }, title = { Text(stringResource(taskActionText(change.action))) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(change.desired?.name ?: change.task?.name.orEmpty())
            (change.desired?.owner ?: change.task?.owner)?.let { Text(stringResource(R.string.st_runs_as, it)) }
            Text(stringResource(when (change.action) { NasTaskAction.RUN -> R.string.st_run_risk; NasTaskAction.DELETE -> R.string.st_delete_risk
                NasTaskAction.DISABLE -> R.string.st_disable_risk; NasTaskAction.ENABLE -> R.string.st_enable_risk; else -> R.string.st_save_risk }))
        }
    }, confirmButton = { TextButton(onConfirm, enabled = !busy) { Text(stringResource(taskActionText(change.action))) } },
        dismissButton = { TextButton(onDismiss, enabled = !busy) { Text(stringResource(R.string.cancel)) } })
}
internal fun taskActionText(action: NasTaskAction): Int = when (action) {
    NasTaskAction.CREATE -> R.string.st_create; NasTaskAction.SAVE -> R.string.nd_save_changes; NasTaskAction.ENABLE -> R.string.st_enable
    NasTaskAction.DISABLE -> R.string.st_disable; NasTaskAction.RUN -> R.string.st_run; NasTaskAction.DELETE -> R.string.delete
}
@Composable private fun taskEnabledText(value: Boolean?) = stringResource(when (value) { true -> R.string.nd_enabled_status; false -> R.string.nd_disabled_status; null -> R.string.st_state_unavailable })
@Composable private fun taskTime(value: String): String {
    val locale = LocalConfiguration.current.locales[0]
    val date = runCatching { LocalDateTime.parse(value, DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")) }
        .recoverCatching { LocalDateTime.parse(value) }.getOrNull()
    return date?.format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(locale)) ?: value
}
@Composable private fun TaskError(error: Exception, onDismiss: (() -> Unit)? = null) {
    Column(Modifier.padding(vertical = 8.dp)) {
        Text(if (error is NasTaskFailure) stringResource(when (error.problem) { NasTaskProblem.INCOMPLETE -> R.string.st_incomplete
            NasTaskProblem.INVALID -> R.string.st_invalid; NasTaskProblem.CHANGED -> R.string.st_changed; NasTaskProblem.PERMISSION -> R.string.st_permission
            NasTaskProblem.BUSY -> R.string.st_busy }) else packageErrorText(error), color = MaterialTheme.colorScheme.error)
        if (onDismiss != null) TextButton(onDismiss) { Text(stringResource(R.string.close)) }
    }
}
