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
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import java.text.NumberFormat

@Composable
internal fun SynologyPhotoMaintenance(model: SynologyPhotoMaintenanceModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    ClientPageDialog(stringResource(R.string.sp_maintenance_title), model::dismiss) {
        if (state.loading && state.status == null && state.records.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        } else LazyColumn(Modifier.fillMaxSize().testTag("photos_maintenance_list"), contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                OutlinedButton(onClick = { model.load() }, enabled = !state.loading && !state.working && state.confirmation == null,
                    modifier = Modifier.testTag("photos_maintenance_refresh")) { Text(stringResource(R.string.sp_edit_refresh)) }
            }
            if (state.loading || state.working) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            state.error?.let { error -> item { Text(maintenanceError(error), color = MaterialTheme.colorScheme.error) } }
            state.status?.let { status ->
                items(SynologyPhotoMaintenanceAction.entries, key = { it.name }) { action ->
                    MaintenanceAction(status, action, !state.loading && !state.working && !state.pending && state.confirmation == null, model)
                }
            }
            if (state.records.isNotEmpty()) item { Text(stringResource(R.string.sp_maintenance_records), style = MaterialTheme.typography.titleMedium) }
            items(state.records, key = { it.id }) { record -> MaintenanceRecord(record, state.working || state.loading, model) }
        }
    }
    state.confirmation?.let { value ->
        AlertDialog(onDismissRequest = model::cancelConfirmation,
            title = { Text(stringResource(value.action.label())) },
            text = { Text(stringResource(if (value.action == SynologyPhotoMaintenanceAction.INDEX) R.string.sp_maintenance_index_risk else R.string.sp_maintenance_previews_risk,
                stringResource(value.original.space.label())), Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = { model.confirm() }, enabled = !state.working,
                modifier = Modifier.testTag("photos_maintenance_confirm")) { Text(stringResource(value.action.label())) } },
            dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun MaintenanceAction(status: SynologyPhotoMaintenanceStatus, action: SynologyPhotoMaintenanceAction, enabled: Boolean,
    model: SynologyPhotoMaintenanceModel) {
    val count = NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0]).format(status.count(action))
    val supported = action == SynologyPhotoMaintenanceAction.INDEX || status.supportsPreviews
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(action.label()), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(when {
            status.count(action) > 0 -> R.string.sp_maintenance_processing
            !supported -> R.string.sp_maintenance_previews_unavailable
            else -> R.string.sp_maintenance_idle
        }, count), color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedButton(onClick = { model.request(action) }, enabled = enabled && status.canStart(action),
            modifier = Modifier.testTag("photos_maintenance_${action.name}")) { Text(stringResource(action.label())) }
        HorizontalDivider()
    }
}

@Composable
private fun MaintenanceRecord(record: SynologyPhotoAlbumRecord, busy: Boolean, model: SynologyPhotoMaintenanceModel) {
    val row = record.checkpoint; val value = row.maintenance!!
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(value.action.label()), style = MaterialTheme.typography.titleSmall)
        Text(stringResource(value.original.space.label()), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(stringResource(when {
            row.phase == SynologyPhotoAlbumPhase.COMPLETED -> R.string.sp_maintenance_idle_after_request
            value.rejected -> R.string.sp_maintenance_rejected
            !value.attempted -> R.string.sp_maintenance_not_sent
            value.acknowledged -> R.string.sp_maintenance_received
            else -> R.string.sp_maintenance_unknown
        }))
        if (row.submitted && !row.finished) OutlinedButton(onClick = { model.resume(record.id) }, enabled = !busy,
            modifier = Modifier.testTag("photos_maintenance_review")) { Text(stringResource(R.string.sp_edit_refresh)) }
        if (!row.submitted || row.finished) TextButton(onClick = { model.discard(record.id) }, enabled = !busy,
            modifier = Modifier.testTag("photos_maintenance_clear")) { Text(stringResource(R.string.sp_edit_clear_record)) }
        HorizontalDivider()
    }
}

private fun SynologyPhotoMaintenanceAction.label() = if (this == SynologyPhotoMaintenanceAction.INDEX) R.string.sp_maintenance_index else R.string.sp_maintenance_previews
private fun SynologyPhotoSpace.label() = if (this == SynologyPhotoSpace.PERSONAL) R.string.sp_source_personal else R.string.sp_source_shared

@Composable
private fun maintenanceError(error: Throwable): String = when (error) {
    is SynologyPhotoAlbumFailure -> if (error.problem == SynologyPhotoAlbumProblem.BUSY) stringResource(R.string.sp_maintenance_busy) else photoAlbumError(error)
    is SynologyPhotoFailure -> stringResource(when (error.kind) {
        SynologyPhotoFailureKind.PERMISSION -> R.string.sp_maintenance_permission
        SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_maintenance_changed
        else -> R.string.sp_maintenance_failed
    })
    else -> stringResource(R.string.sp_maintenance_failed)
}
