package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import java.text.DateFormat
import java.text.NumberFormat
import java.util.Date

@Composable
internal fun SynologyPhotoBackgroundTasks(model: SynologyPhotoBackgroundModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    ClientPageDialog(stringResource(if (state.recordsPage) R.string.sp_tasks_records else R.string.sp_tasks_title), model::dismiss) {
        LazyColumn(Modifier.fillMaxSize().testTag("photos_tasks_list"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { if (state.recordsPage) model.refreshRecords() else model.refresh() }, enabled = !state.loading && !state.working,
                        modifier = Modifier.testTag("photos_tasks_refresh")) { Text(stringResource(R.string.sp_edit_refresh)) }
                    OutlinedButton(onClick = { if (state.recordsPage) model.showTasks() else model.showRecords() },
                        modifier = Modifier.testTag("photos_tasks_history")) { Text(stringResource(if (state.recordsPage) R.string.sp_tasks_list else R.string.sp_tasks_records)) }
                }
            }
            state.error?.let { failure -> item { Text(taskError(failure), color = MaterialTheme.colorScheme.error) } }
            if (state.working || state.preparing || state.navigating) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (state.recordsPage) {
                if (state.records.isEmpty()) item { Text(stringResource(R.string.sp_tasks_no_records)) }
                items(state.records, key = { it.id }) { record -> BackgroundRecord(record, state.working, model) }
            } else {
                item {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        SynologyPhotoBackgroundFilter.entries.forEach { filter ->
                            FilterChip(state.filter == filter, onClick = { model.filter(filter) }, label = { Text(stringResource(filter.label())) },
                                modifier = Modifier.testTag("photos_tasks_filter_${filter.name}"))
                        }
                    }
                }
                if (state.hasPending) item { Text(stringResource(R.string.sp_tasks_pending), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                state.listError?.let { item { Text(stringResource(R.string.sp_tasks_load_failed), color = MaterialTheme.colorScheme.error) } }
                if (state.loading && !state.loaded) item { Box(Modifier.fillMaxWidth().heightIn(min = 160.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
                else if (state.visibleTasks.isEmpty() && state.listError == null) item {
                    Column(Modifier.fillMaxWidth().padding(vertical = 32.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(stringResource(if (state.tasks.isEmpty()) R.string.sp_tasks_empty else R.string.sp_tasks_filter_empty), style = MaterialTheme.typography.titleMedium)
                        Text(stringResource(if (state.tasks.isEmpty()) R.string.sp_tasks_empty_hint else R.string.sp_tasks_filter_empty_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                items(state.visibleTasks, key = { it.id }) { task -> BackgroundTaskRow(task, model) }
                if (state.tasks.any { it.snapshot.canClear }) item {
                    OutlinedButton(onClick = { model.prepareClear(state.tasks.filter { it.snapshot.canClear }) }, enabled = model.canControl,
                        modifier = Modifier.testTag("photos_tasks_clear_finished")) { Text(stringResource(R.string.sp_tasks_clear_finished)) }
                }
            }
        }
    }
    state.confirmation?.let { row ->
        val clearing = row.action == SynologyPhotoAlbumAction.CLEAR_TASKS
        val count = taskCount(row.background!!.tasks.size.toLong())
        AlertDialog(onDismissRequest = model::cancelConfirmation,
            title = { Text(stringResource(if (clearing) R.string.sp_tasks_clear_title else R.string.sp_tasks_stop_title)) },
            text = { Text(if (clearing) stringResource(R.string.sp_tasks_clear_hint, count) else stringResource(R.string.sp_tasks_stop_hint),
                Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = { model.confirm() }, enabled = !state.working,
                modifier = Modifier.testTag("photos_tasks_confirm")) { Text(stringResource(if (clearing) R.string.sp_tasks_clear else R.string.sp_tasks_stop)) } },
            dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
    if (state.errorTask != null) BackgroundErrors(state, model)
}

@Composable
private fun BackgroundTaskRow(task: SynologyPhotoBackgroundTask, model: SynologyPhotoBackgroundModel) {
    val value = task.snapshot
    val progress = stringResource(R.string.sp_tasks_progress, taskCount(task.completion), taskCount(value.total))
    val locale = LocalConfiguration.current.locales[0]
    val date = remember(value.createdAt, locale) { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale).format(Date((value.createdAt * 1000).toLong())) }
    Column(Modifier.fillMaxWidth().testTag("photos_task_${task.id}"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(value.operation.taskLabel()), style = MaterialTheme.typography.titleMedium)
        Text(date, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(stringResource(task.statusLabel()))
        if (value.status == SynologyPhotoBackgroundStatus.PROCESSING && value.total > 0)
            LinearProgressIndicator(progress = { (task.completion.toDouble() / value.total).toFloat() }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = progress })
        Text(progress)
        Text(stringResource(R.string.sp_tasks_counts, taskCount(task.errors), taskCount(task.skipped), taskCount(task.overwritten)), style = MaterialTheme.typography.bodySmall)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (value.canStop) OutlinedButton(onClick = { model.prepareStop(task) }, enabled = model.canControl,
                modifier = Modifier.testTag("photos_task_stop_${task.id}")) { Text(stringResource(R.string.sp_tasks_stop)) }
            if (value.canClear) OutlinedButton(onClick = { model.prepareClear(listOf(task)) }, enabled = model.canControl,
                modifier = Modifier.testTag("photos_task_clear_${task.id}")) { Text(stringResource(R.string.sp_tasks_clear)) }
            if (task.errors > 0) OutlinedButton(onClick = { model.openErrors(task) }, modifier = Modifier.testTag("photos_task_errors_${task.id}")) { Text(stringResource(R.string.sp_tasks_errors)) }
            if (task.canOpenTarget) OutlinedButton(onClick = { model.openTarget(task) }, enabled = model.canControl,
                modifier = Modifier.testTag("photos_task_target_${task.id}")) { Text(stringResource(R.string.sp_tasks_open_target)) }
        }
        HorizontalDivider()
    }
}

@Composable
private fun BackgroundRecord(record: SynologyPhotoAlbumRecord, busy: Boolean, model: SynologyPhotoBackgroundModel) {
    val row = record.checkpoint; val value = row.background!!
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(if (row.action == SynologyPhotoAlbumAction.STOP_TASK) R.string.sp_tasks_stop else R.string.sp_tasks_clear), style = MaterialTheme.typography.titleMedium)
        Text(when {
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && row.action == SynologyPhotoAlbumAction.STOP_TASK -> stringResource(R.string.sp_tasks_stop_done)
            row.phase == SynologyPhotoAlbumPhase.COMPLETED -> stringResource(R.string.sp_tasks_cleared, taskCount(value.completed.size.toLong()))
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && value.completed.isNotEmpty() -> stringResource(R.string.sp_tasks_result_partial, taskCount(value.completed.size.toLong()), taskCount(value.tasks.size.toLong()))
            row.phase == SynologyPhotoAlbumPhase.PARTIAL -> stringResource(R.string.sp_tasks_rejected)
            row.submitted -> stringResource(R.string.sp_tasks_pending)
            else -> stringResource(R.string.sp_tasks_not_sent)
        })
        if (row.submitted && !row.finished) OutlinedButton(onClick = { model.review(record.id) }, enabled = !busy,
            modifier = Modifier.testTag("photos_tasks_review")) { Text(stringResource(R.string.sp_edit_refresh)) }
        if (row.finished || !row.submitted) TextButton(onClick = { model.discard(record.id) }, enabled = !busy) { Text(stringResource(R.string.sp_edit_clear_record)) }
        HorizontalDivider()
    }
}

@Composable
private fun BackgroundErrors(state: SynologyPhotoBackgroundState, model: SynologyPhotoBackgroundModel) {
    ClientPageDialog(stringResource(R.string.sp_tasks_errors), model::closeErrors) {
        when {
            state.errorsLoading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            state.errorsFailure != null -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(stringResource(R.string.sp_tasks_errors_failed), color = MaterialTheme.colorScheme.error)
                OutlinedButton(onClick = { model.loadErrors() }) { Text(stringResource(R.string.sp_retry)) }
            }
            state.errors.isEmpty() -> Box(Modifier.fillMaxSize().padding(16.dp), contentAlignment = Alignment.Center) { Text(stringResource(R.string.sp_tasks_errors_empty)) }
            else -> LazyColumn(Modifier.fillMaxSize().testTag("photos_task_errors"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                items(state.errors, key = { it.key }) { entry ->
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(entry.name ?: stringResource(when (entry.kind) {
                            SynologyPhotoBackgroundError.Kind.ITEM -> R.string.sp_tasks_item
                            SynologyPhotoBackgroundError.Kind.FOLDER -> R.string.sp_tasks_folder
                            SynologyPhotoBackgroundError.Kind.UNKNOWN -> R.string.sp_tasks_unknown_item
                        }), style = MaterialTheme.typography.titleMedium)
                        entry.folderPath?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        Text(stringResource(entry.reason.label()))
                        HorizontalDivider()
                    }
                }
            }
        }
    }
}

@Composable
private fun taskCount(value: Long): String = NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0]).format(value)
private fun String.taskLabel() = when (this) { "copy" -> R.string.sp_tasks_copy; "move" -> R.string.sp_tasks_move; else -> R.string.sp_tasks_other }
private fun SynologyPhotoBackgroundFilter.label() = when (this) {
    SynologyPhotoBackgroundFilter.ALL -> R.string.sp_tasks_all
    SynologyPhotoBackgroundFilter.ACTIVE -> R.string.sp_tasks_active
    SynologyPhotoBackgroundFilter.FINISHED -> R.string.sp_tasks_finished
}
private fun SynologyPhotoBackgroundTask.statusLabel(): Int = when (snapshot.status) {
    SynologyPhotoBackgroundStatus.WAITING -> R.string.sp_tasks_waiting
    SynologyPhotoBackgroundStatus.PROCESSING -> R.string.sp_tasks_processing
    SynologyPhotoBackgroundStatus.ABORTING -> R.string.sp_tasks_stopping
    SynologyPhotoBackgroundStatus.UNKNOWN -> R.string.sp_tasks_unknown
    SynologyPhotoBackgroundStatus.DONE -> when {
        stopped -> R.string.sp_tasks_stopped
        errors > 0 && successful == 0L -> R.string.sp_tasks_failed
        errors > 0 -> R.string.sp_tasks_partial
        else -> R.string.sp_tasks_done
    }
}
private fun SynologyPhotoBackgroundError.Reason.label(): Int = when (this) {
    SynologyPhotoBackgroundError.Reason.QUOTA -> R.string.sp_tasks_reason_quota
    SynologyPhotoBackgroundError.Reason.SPACE -> R.string.sp_tasks_reason_space
    SynologyPhotoBackgroundError.Reason.SUBFOLDER -> R.string.sp_tasks_reason_subfolder
    SynologyPhotoBackgroundError.Reason.MISSING -> R.string.sp_tasks_reason_missing
    SynologyPhotoBackgroundError.Reason.TARGET_MISSING -> R.string.sp_tasks_reason_target_missing
    SynologyPhotoBackgroundError.Reason.EXCLUDED -> R.string.sp_tasks_reason_excluded
    SynologyPhotoBackgroundError.Reason.UNKNOWN -> R.string.sp_tasks_reason_unknown
}
@Composable
private fun taskError(error: Throwable): String = when {
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.STORAGE -> stringResource(R.string.sp_folder_storage_failed)
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.PENDING -> stringResource(R.string.sp_tasks_conflict)
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.BUSY -> stringResource(R.string.sp_edit_busy)
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.PERMISSION -> stringResource(R.string.sp_tasks_permission)
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED -> stringResource(R.string.sp_tasks_changed)
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.UNAVAILABLE -> photoError(error)
    else -> stringResource(R.string.sp_tasks_action_failed)
}
