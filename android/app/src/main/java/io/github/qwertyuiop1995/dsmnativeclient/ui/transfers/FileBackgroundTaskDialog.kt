package io.github.qwertyuiop1995.dsmnativeclient.ui.transfers

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.EmptyState
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@Composable
internal fun FileBackgroundTaskRecoveryEntry(feature: FileBackgroundTaskFeatureModel) {
    val state by feature.state.collectAsStateWithLifecycle()
    if (state.pending is Loadable.Failed || (state.pending as? Loadable.Ready)?.value?.isNotEmpty() == true) {
        OutlinedButton(feature::openRecovery, Modifier.fillMaxWidth().padding(horizontal = 16.dp).heightIn(min = 48.dp)
            .testTag("background_recovery_entry"), enabled = !state.busy) { Text(stringResource(R.string.file_background_task_recovery)) }
    }
}

@Composable
internal fun FileBackgroundTaskDialog(feature: FileBackgroundTaskFeatureModel) {
    val state by feature.state.collectAsStateWithLifecycle()
    val screen = state.screen ?: return
    ClientPageDialog(stringResource(if (screen == FileBackgroundTaskScreen.RECOVERY) R.string.file_background_task_recovery else R.string.file_background_task_details), feature::back) {
        Column(Modifier.fillMaxSize().testTag("background_task_page")) {
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (screen == FileBackgroundTaskScreen.RECOVERY) FileBackgroundTaskRecoveryList(feature, state)
            else Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(state.account, style = MaterialTheme.typography.titleMedium)
                when (val details = state.detail) {
                    Loadable.Idle, Loadable.Loading -> CircularProgressIndicator()
                    is Loadable.Failed -> BackgroundTaskFailure(details.error)
                    is Loadable.Ready -> if (details.value != null) BackgroundTaskDetails(details.value) else if (state.completedAction != FileBackgroundTaskAction.CLEAR) {
                        Text(stringResource(R.string.file_background_task_not_listed), style = MaterialTheme.typography.titleMedium)
                        Text(stringResource(R.string.file_background_task_not_listed_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                state.completedAction?.let { Text(stringResource(if (it == FileBackgroundTaskAction.CLEAR) R.string.file_background_task_cleared else R.string.file_background_task_ended),
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }.testTag("background_action_completed")) }
                state.failure?.let { BackgroundTaskFailure(it) }
                (state.pending as? Loadable.Failed)?.let { BackgroundTaskFailure(it.error) }
                if (feature.pendingCurrent() != null) {
                    Text(stringResource(R.string.file_background_task_pending), modifier = Modifier.testTag("background_action_unknown"))
                    Text(stringResource(R.string.file_background_task_pending_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    FileBackgroundTaskAction.entries.forEach { action ->
                        if (feature.canControl(action)) Button({ feature.prepare(action) }, Modifier.fillMaxWidth().heightIn(min = 48.dp)
                            .testTag(if (action == FileBackgroundTaskAction.STOP) "background_stop" else "background_clear"), enabled = !state.busy) {
                            Text(stringResource(action.label()))
                        }
                    }
                }
                OutlinedButton(feature::reload, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("background_refresh"), enabled = !state.busy) {
                    Text(stringResource(R.string.refresh))
                }
            }
        }
    }
    state.confirmation?.let { action ->
        AlertDialog(onDismissRequest = feature::dismissConfirmation, title = { Text(stringResource(action.label())) },
            text = { Text(stringResource(if (action == FileBackgroundTaskAction.STOP) R.string.file_background_task_stop_notice else R.string.file_background_task_clear_notice)) },
            confirmButton = { TextButton(feature::confirm, Modifier.heightIn(min = 48.dp).testTag("background_confirm")) { Text(stringResource(action.label())) } },
            dismissButton = { TextButton(feature::dismissConfirmation, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun FileBackgroundTaskRecoveryList(feature: FileBackgroundTaskFeatureModel, state: FileBackgroundTaskControlState) {
    when (val pending = state.pending) {
        Loadable.Idle, Loadable.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        is Loadable.Failed -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            BackgroundTaskFailure(pending.error)
            OutlinedButton(feature::reload, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.retry)) }
        }
        is Loadable.Ready -> if (pending.value.isEmpty()) EmptyState(stringResource(R.string.file_background_task_recovery_empty),
            stringResource(R.string.file_background_task_recovery_empty_hint), Icons.Outlined.TaskAlt)
        else LazyColumn(Modifier.fillMaxSize().testTag("background_recovery_list"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(pending.value, key = { it.id }) { record ->
                ClientGroup { ClientRow(stringResource(record.target.kind.labelResource()), Icons.Outlined.History,
                    detail = stringResource(R.string.file_background_task_recovery_detail, stringResource(record.action.label()),
                        backgroundTaskDate(record.target.createdAtSeconds.toLong()))) { feature.open(record) } }
            }
        }
    }
}

@Composable
private fun BackgroundTaskDetails(task: FileBackgroundTaskSummary) {
    var reference by rememberSaveable(task.id) { mutableStateOf(false) }
    val context = LocalContext.current
    Text(stringResource(task.kind.labelResource()), style = MaterialTheme.typography.titleLarge)
    Text(stringResource(task.state.labelResource()))
    task.createdAtEpochSeconds?.let { Text(stringResource(R.string.file_background_task_created, backgroundTaskDate(it))) }
    task.progress?.let { LinearProgressIndicator(progress = { it.toFloat() }, modifier = Modifier.fillMaxWidth()) }
    task.processedItemCount?.let { processed -> Text(if (task.totalItemCount != null)
        stringResource(R.string.file_background_task_items_progress, processed, task.totalItemCount)
        else pluralStringResource(R.plurals.file_background_task_items_processed, processed, processed)) }
    task.processedBytes?.let { processed -> Text(if (task.totalBytes != null)
        stringResource(R.string.transfer_bytes_progress, android.text.format.Formatter.formatFileSize(context, processed), android.text.format.Formatter.formatFileSize(context, task.totalBytes))
        else stringResource(R.string.file_background_task_bytes_processed, android.text.format.Formatter.formatFileSize(context, processed))) }
    if (task.state == FileBackgroundTaskState.FINISHED) Text(stringResource(R.string.file_background_task_ended_scope), color = MaterialTheme.colorScheme.onSurfaceVariant)
    OutlinedButton({ reference = !reference }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("background_reference")) {
        Text(stringResource(R.string.file_background_task_reference))
    }
    if (reference) SelectionContainer { Text(task.id) }
}

@Composable
private fun BackgroundTaskFailure(failure: DsmFailure) {
    val localized = failure.localize(LocalContext.current)
    Text(localized.message, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive })
    Text(localized.recovery, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
private fun FileBackgroundTaskAction.label() = if (this == FileBackgroundTaskAction.STOP) R.string.file_background_task_stop else R.string.file_background_task_clear

@Composable
private fun backgroundTaskDate(seconds: Long): String {
    val locale = LocalContext.current.resources.configuration.locales[0]
    val formatter = remember(locale) { DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM).withLocale(locale).withZone(ZoneId.systemDefault()) }
    return formatter.format(Instant.ofEpochSecond(seconds))
}
