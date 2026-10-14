package io.github.qwertyuiop1995.dsmnativeclient.ui.downloads

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.downloads.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

@Composable
internal fun DownloadActionsPanel(model: DownloadActionModel, tasks: List<DownloadTask>) {
    val state by model.state.collectAsState()
    state.confirmation?.let { pending ->
        val move = pending.record.steps.first().kind == DownloadActionKind.END_AND_MOVE
        AlertDialog(onDismissRequest = model::cancelConfirmation,
            title = { Text(stringResource(if (move) R.string.download_batch_end_title else R.string.download_batch_remove_title, pending.titles.size)) },
            text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                pending.titles.take(6).forEach { Text(it, maxLines = 2) }
                Text(stringResource(if (move) R.string.download_delete_files_risk_summary else R.string.download_batch_remove_note))
            } },
            confirmButton = { TextButton(onClick = { model.confirm() }) { Text(stringResource(if (move) R.string.confirm_remove_task_and_files else R.string.confirm_remove_task_only)) } },
            dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
    if (!state.visible) return
    ClientPageDialog(stringResource(R.string.download_actions_title), { model.show(false) }) {
        Column(Modifier.fillMaxSize()) {
            if (state.restoring) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(16.dp)) }
            if (state.records.isEmpty() && !state.restoring) Text(stringResource(R.string.download_actions_empty), Modifier.padding(24.dp))
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(state.records, key = { it.id }) { record ->
                    val busy = record.id in state.busy
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            record.steps.forEachIndexed { index, step ->
                                Text(stringResource(step.kind.label()), style = MaterialTheme.typography.titleSmall)
                                if (step.kind in setOf(DownloadActionKind.PAUSE, DownloadActionKind.RESUME, DownloadActionKind.REMOVE, DownloadActionKind.END_AND_MOVE, DownloadActionKind.EDIT))
                                    Text(tasks.firstOrNull { it.id == step.target && downloadTaskDigest(it) == step.identityDigest }?.title ?: stringResource(R.string.download_action_item, index + 1), maxLines = 2)
                                Text(stringResource(when (step.phase) {
                                    DownloadActionPhase.READY -> R.string.download_action_ready
                                    DownloadActionPhase.SUBMITTED -> R.string.download_action_submitted
                                    DownloadActionPhase.COMPLETED -> if (step.kind == DownloadActionKind.CREATE_LINK || step.kind == DownloadActionKind.CREATE_FILE) R.string.download_action_accepted else R.string.download_action_complete
                                    DownloadActionPhase.REJECTED -> R.string.download_action_rejected
                                    DownloadActionPhase.CANCELLED -> R.string.download_action_cancelled
                                }))
                                if (step.kind == DownloadActionKind.END_AND_MOVE) Text(stringResource(R.string.download_delete_files_verification_notice), style = MaterialTheme.typography.bodySmall)
                                if (step.phase == DownloadActionPhase.SUBMITTED && step.kind in setOf(DownloadActionKind.CREATE_LINK, DownloadActionKind.CREATE_FILE))
                                    Text(stringResource(R.string.download_action_unknown_creation), style = MaterialTheme.typography.bodySmall)
                            }
                            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                            if (record.steps.any { it.phase == DownloadActionPhase.SUBMITTED }) TextButton(onClick = { model.refresh(record.id) }, enabled = !busy) { Text(stringResource(R.string.refresh)) }
                            if (record.steps.any { it.phase == DownloadActionPhase.READY }) {
                                TextButton(onClick = { model.continuePending(record.id) }, enabled = !busy && record.steps.none { it.phase == DownloadActionPhase.SUBMITTED }) { Text(stringResource(R.string.download_action_continue)) }
                                TextButton(onClick = { model.cancelPending(record.id) }, enabled = !busy) { Text(stringResource(R.string.download_action_cancel_pending)) }
                            }
                            if (record.terminal) TextButton(onClick = { model.discard(record.id) }, enabled = !busy) { Text(stringResource(R.string.download_action_remove_record)) }
                        }
                    }
                }
            }
        }
    }
}

private fun DownloadActionKind.label(): Int = when (this) {
    DownloadActionKind.CREATE_LINK, DownloadActionKind.CREATE_FILE -> R.string.add_download_task
    DownloadActionKind.PAUSE -> R.string.pause
    DownloadActionKind.RESUME -> R.string.resume
    DownloadActionKind.REMOVE -> R.string.remove_task
    DownloadActionKind.END_AND_MOVE -> R.string.remove_task_and_files
    DownloadActionKind.EDIT -> R.string.change_download_destination
    DownloadActionKind.SETTINGS -> R.string.download_settings_title
    DownloadActionKind.SCHEDULE -> R.string.download_schedule_title
    DownloadActionKind.RSS -> R.string.download_rss_refresh
}
