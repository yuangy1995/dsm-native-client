package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmStage
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientGroup
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*

@Composable internal fun VmmTaskRecords(state: VmmTaskState, onRefresh: () -> Unit, onDismiss: (String, VmmTaskAction) -> Unit, onClose: () -> Unit) {
    ClientSheet(stringResource(R.string.vm_task_activity), onDismiss = onClose) {
        if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.failure?.let { Text(vmmErrorText(it), color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        if (state.nothingToClear) Text(stringResource(R.string.vm_task_nothing_to_clear))
        if (!state.nothingToClear && !state.busy && state.imports.isEmpty() && state.cleanups.isEmpty() && state.failure == null) Text(stringResource(R.string.vm_task_activity_empty))
        state.imports.forEachIndexed { index, record ->
            VmmTaskRecord(stringResource(R.string.virtual_machine_image_import_title), listOf(record.progress.stage), record.pending, state.busy,
                onRefresh, { onDismiss(record.id, VmmTaskAction.IMPORT) }, imported = true, number = index + 1)
        }
        state.cleanups.forEachIndexed { index, record ->
            VmmTaskRecord(stringResource(R.string.virtual_machine_task_cleanup_feedback_title), record.items.map { it.stage }, record.pending, state.busy,
                onRefresh, { onDismiss(record.id, VmmTaskAction.CLEANUP) }, imported = false, number = index + 1)
        }
        if (state.failure != null || state.imports.isEmpty() && state.cleanups.isEmpty()) TextButton(onClick = onRefresh, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
        TextButton(onClick = onClose, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.close)) }
    }
}

@Composable private fun VmmTaskRecord(title: String, stages: List<VmmStage>, pending: Boolean, busy: Boolean,
    onRefresh: () -> Unit, onDismiss: () -> Unit, imported: Boolean, number: Int) {
    ClientGroup { Column(Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.vm_task_activity_number, title, number), style = MaterialTheme.typography.titleSmall)
        stages.forEachIndexed { index, stage ->
            Text(stringResource(R.string.vm_item_status, stringResource(if (imported) R.string.vm_asset_number else R.string.virtual_machine_task_number, index + 1), stringResource(when (stage) {
                VmmStage.PREPARED, VmmStage.CANCELLED -> R.string.vm_not_sent
                VmmStage.SUBMITTED -> R.string.vm_result_unavailable
                VmmStage.ACCEPTED -> R.string.vm_processing
                VmmStage.REJECTED -> R.string.vm_rejected
                VmmStage.VERIFIED -> if (imported) R.string.virtual_machine_image_imported else R.string.vm_task_cleared
            })))
        }
        if (pending) Text(stringResource(R.string.vm_pending_hint))
        TextButton(onClick = if (pending) onRefresh else onDismiss, enabled = !busy, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(if (pending) R.string.refresh else R.string.vm_task_dismiss))
        }
    } }
}
