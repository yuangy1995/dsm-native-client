package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@Composable
internal fun SynologyPhotoDeletions(model: SynologyPhotoDeletionModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    ClientPageDialog(stringResource(if (state.recordsPage) R.string.sp_deletion_records else R.string.sp_delete_title), model::dismiss) {
        Column(Modifier.fillMaxSize()) {
            state.error?.let { Text(photoDeletionError(it), Modifier.fillMaxWidth().padding(16.dp), color = MaterialTheme.colorScheme.error) }
            when {
                state.checking && state.candidate == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                state.recordsPage -> DeletionRecords(state, model)
                state.candidate == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Button(onClick = { model.retry() }) { Text(stringResource(R.string.sp_retry)) }
                }
                else -> {
                    val photos = state.candidate!!
                    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_deletion_selection"), contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        item { Text(pluralStringResource(R.plurals.sp_deletion_selected, photos.size, photos.size), style = MaterialTheme.typography.titleMedium) }
                        item { Text(stringResource(R.string.sp_deletion_warning), color = MaterialTheme.colorScheme.error) }
                        items(photos, key = { "${it.id.space}:${it.id.itemId}" }) { Text(it.filename) }
                    }
                    HorizontalDivider()
                    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
                        Button(onClick = { model.confirm() }, modifier = Modifier.testTag("photos_deletion_confirm")) {
                            Text(stringResource(R.string.sp_deletion_confirm))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ColumnScope.DeletionRecords(state: SynologyPhotoDeletionState, model: SynologyPhotoDeletionModel) {
    val busy = state.writing || state.recovering || state.checking
    val locale = LocalConfiguration.current.locales[0]
    val format = remember(locale) { DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM).withLocale(locale).withZone(ZoneId.systemDefault()) }
    if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_deletion_records"), contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (state.records.isEmpty() && !busy) item { Text(stringResource(R.string.sp_deletion_empty)) }
        items(state.records, key = { it.id }) { row ->
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(format.format(Instant.ofEpochSecond(row.createdAtSeconds)), style = MaterialTheme.typography.titleMedium)
                Text(pluralStringResource(R.plurals.sp_deletion_selected, row.entries.size, row.entries.size))
                val pending = row.count(SynologyPhotoDeletionPhase.SUBMITTED)
                val remaining = row.count(SynologyPhotoDeletionPhase.PREPARED)
                for (phase in SynologyPhotoDeletionPhase.entries) {
                    val count = row.count(phase)
                    if (count > 0) Text(stringResource(when (phase) {
                        SynologyPhotoDeletionPhase.PREPARED -> R.string.sp_deletion_remaining
                        SynologyPhotoDeletionPhase.SUBMITTED -> R.string.sp_deletion_processing
                        SynologyPhotoDeletionPhase.CONFIRMED -> R.string.sp_deletion_completed
                        SynologyPhotoDeletionPhase.REJECTED -> R.string.sp_deletion_rejected
                        SynologyPhotoDeletionPhase.CANCELLED -> R.string.sp_deletion_cancelled
                    }, count))
                }
                if (pending > 0) Text(stringResource(R.string.sp_delete_pending))
                if (remaining > 0) {
                    if (pending == 0) Button(onClick = { model.resume(row.id) }, enabled = !busy,
                        modifier = Modifier.testTag("photos_deletion_resume")) { Text(stringResource(R.string.sp_deletion_continue)) }
                    TextButton(onClick = { model.cancelRemaining(row.id) }, enabled = !busy,
                        modifier = Modifier.testTag("photos_deletion_cancel_remaining")) { Text(stringResource(R.string.sp_deletion_cancel_remaining)) }
                }
                if (row.finished) TextButton(onClick = { model.discard(row.id) }, enabled = !busy) { Text(stringResource(R.string.sp_edit_clear_record)) }
                HorizontalDivider()
            }
        }
    }
    if (state.error != null) TextButton(onClick = { model.refreshRecords() }, enabled = !busy,
        modifier = Modifier.padding(horizontal = 16.dp)) { Text(stringResource(R.string.sp_retry)) }
}

@Composable
internal fun photoDeletionError(error: Throwable): String {
    if (error is SynologyPhotoDeletionFailure) return stringResource(when (error.problem) {
        SynologyPhotoDeletionProblem.STORAGE -> R.string.sp_deletion_storage_failed
        SynologyPhotoDeletionProblem.BUSY -> R.string.sp_edit_busy
        SynologyPhotoDeletionProblem.PENDING -> R.string.sp_deletion_conflict
        SynologyPhotoDeletionProblem.LIMIT -> R.string.sp_deletion_limit
    })
    val failure = error as? DsmFailure ?: error.cause as? DsmFailure
    if (failure?.code in setOf(106, 107, 119)) return stringResource(R.string.sp_deletion_sign_in)
    if (failure?.code == 105) return stringResource(R.string.sp_delete_denied)
    return if (error is SynologyPhotoFailure || error is SynologyPhotoEditFailure || error is SynologyPhotoAlbumFailure) photoError(error)
        else stringResource(R.string.sp_deletion_connection_failed)
}
