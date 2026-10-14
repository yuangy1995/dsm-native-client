package io.github.qwertyuiop1995.dsmnativeclient.ui

import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun CrossNasTransferDialog(feature: CrossNasTransferFeatureModel) {
    val state by feature.state.collectAsStateWithLifecycle()
    if (!state.visible) return
    val row = state.selected
    val context = LocalContext.current
    fun label(owner: io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner, fallback: String,
        other: io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner): String =
        feature.connectionProfile(owner)?.let { profile -> connectionConfirmationName(context, profile,
            listOfNotNull(profile, feature.connectionProfile(other))) } ?: fallback
    val sourceName = row?.let { label(it.sourceOwner, it.sourceName, it.targetOwner) }.orEmpty()
    val targetName = row?.let { label(it.targetOwner, it.targetName, it.sourceOwner) }.orEmpty()
    var unfinished by rememberSaveable(row?.id) { mutableStateOf(false) }
    ClientPageDialog(stringResource(R.string.cross_nas_title), { if (state.selectedId != null) feature.backToList() else feature.dismiss() }) {
        Column(Modifier.fillMaxSize().testTag("cross_nas_dialog")) {
            if (state.busy || state.reading) LinearProgressIndicator(Modifier.fillMaxWidth())
            when (val records = state.records) {
                is Loadable.Failed -> Column(Modifier.weight(1f).fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.Center) {
                    Text(records.error.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error)
                    OutlinedButton(feature::refresh, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.retry)) }
                }
                Loadable.Idle, Loadable.Loading -> Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) { CircularProgressIndicator() }
                is Loadable.Ready -> if (row == null) {
                    if (records.value.isEmpty() && state.selectedId == null && !state.busy && state.failure == null) {
                        Box(Modifier.weight(1f).fillMaxWidth()) { EmptyState(stringResource(R.string.cross_nas_empty),
                            stringResource(R.string.cross_nas_empty_hint), Icons.Outlined.SwapHoriz) }
                    } else LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        item { CrossNasFeedback(state) }
                        if (state.busy) item { Column {
                            Text(stringResource(R.string.cross_nas_preparing))
                            OutlinedButton(feature::pause, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.pause)) }
                        } }
                        else if (state.selectedId != null) item { Text(stringResource(R.string.task_record_missing)) }
                        items(records.value, key = { it.id }) { item -> ClientGroup {
                            ClientRow(stringResource(R.string.cross_nas_route, label(item.sourceOwner, item.sourceName, item.targetOwner), label(item.targetOwner, item.targetName, item.sourceOwner)), Icons.Outlined.SwapHoriz,
                                detail = stringResource(crossNasPhaseLabel(item)), enabled = !state.busy) { feature.show(item.id) }
                        } }
                    }
                } else {
                    val entries = row.entries.filter { !unfinished || it.state !in setOf(CrossNasEntryState.COPIED, CrossNasEntryState.REMOVED) }
                    LazyColumn(Modifier.weight(1f).testTag("cross_nas_items"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        item { ClientGroup { Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(stringResource(R.string.cross_nas_route, sourceName, targetName), style = MaterialTheme.typography.titleMedium)
                            Text(stringResource(crossNasPhaseLabel(row)))
                            Text(stringResource(R.string.cross_nas_destination, row.destination.path), style = MaterialTheme.typography.bodyMedium)
                            Text(stringResource(R.string.cross_nas_counts,
                                row.entries.count { it.state in setOf(CrossNasEntryState.COPIED, CrossNasEntryState.REMOVED, CrossNasEntryState.DELETING, CrossNasEntryState.DELETE_UNKNOWN) },
                                row.entries.size, row.entries.count { it.state == CrossNasEntryState.REMOVED }), style = MaterialTheme.typography.bodySmall)
                            if (state.busy && state.totalBytes > 0) {
                                LinearProgressIndicator(progress = { (state.completedBytes.toDouble() / state.totalBytes).coerceIn(0.0, 1.0).toFloat() }, Modifier.fillMaxWidth())
                                Text(stringResource(R.string.transfer_bytes_progress, Formatter.formatFileSize(LocalContext.current, state.completedBytes), Formatter.formatFileSize(LocalContext.current, state.totalBytes)))
                            }
                            if (row.hasUnknown && !state.busy) Text(stringResource(R.string.cross_nas_interrupted_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        } } }
                        item { CrossNasFeedback(state) }
                        item { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (state.busy) OutlinedButton(feature::pause, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("cross_nas_pause")) { Text(stringResource(R.string.pause)) }
                            else {
                                if (row.canContinueCopy) Button(feature::continueCopy, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("cross_nas_continue"), enabled = !state.reading) { Text(stringResource(R.string.cross_nas_continue)) }
                                if (row.canRemoveSource) {
                                    Button(feature::requestRemoval, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("cross_nas_remove"), enabled = !state.reading) { Text(stringResource(R.string.cross_nas_remove)) }
                                    OutlinedButton(feature::keepOriginals, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("cross_nas_keep"), enabled = !state.reading) { Text(stringResource(R.string.cross_nas_keep)) }
                                }
                                OutlinedButton(feature::refresh, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("cross_nas_refresh"), enabled = !state.reading) { Text(stringResource(R.string.refresh)) }
                            }
                        } }
                        item { LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            item { FilterChip(!unfinished, { unfinished = false }, label = { Text(stringResource(R.string.show_all_items)) }) }
                            item { FilterChip(unfinished, { unfinished = true }, label = { Text(stringResource(R.string.cross_nas_remaining)) }) }
                        } }
                        if (entries.isEmpty()) item { Text(stringResource(R.string.cross_nas_no_remaining), Modifier.padding(16.dp)) }
                        items(entries, key = { it.source.path }) { entry -> ClientGroup { Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(entry.source.name, style = MaterialTheme.typography.titleSmall)
                            Text(stringResource(crossNasEntryLabel(entry)), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(stringResource(R.string.cross_nas_source, entry.source.path), style = MaterialTheme.typography.bodySmall)
                            Text(stringResource(R.string.cross_nas_destination, entry.targetPath), style = MaterialTheme.typography.bodySmall)
                        } } }
                    }
                }
            }
        }
    }
    if (state.confirmRemoval && row != null) AlertDialog(onDismissRequest = feature::dismissRemoval,
        title = { Text(stringResource(R.string.cross_nas_remove)) },
        text = { Text(stringResource(R.string.cross_nas_remove_warning, sourceName, targetName)) },
        confirmButton = { TextButton(feature::confirmRemoval, Modifier.heightIn(min = 48.dp).testTag("cross_nas_confirm_remove")) { Text(stringResource(R.string.cross_nas_remove)) } },
        dismissButton = { TextButton(feature::dismissRemoval, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun CrossNasFeedback(state: CrossNasTransferViewState) {
    state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
}
internal fun crossNasPhaseLabel(row: CrossNasTransferRecord): Int = when (row.phase) {
    CrossNasPhase.PAUSED, CrossNasPhase.INTERRUPTED -> R.string.transfer_paused
    CrossNasPhase.COPYING -> R.string.cross_nas_copying
    CrossNasPhase.COPIED -> R.string.cross_nas_copied
    CrossNasPhase.KEPT -> R.string.cross_nas_kept
    CrossNasPhase.REMOVING -> R.string.cross_nas_removing
    CrossNasPhase.FINISHED -> if (row.moveRequested) R.string.cross_nas_moved else R.string.transfer_completed
}
private fun crossNasEntryLabel(entry: CrossNasEntry): Int = when (entry.state) {
    CrossNasEntryState.PENDING -> R.string.transfer_waiting
    CrossNasEntryState.WRITING -> R.string.cross_nas_copying
    CrossNasEntryState.COPIED -> R.string.cross_nas_copied
    CrossNasEntryState.WRITE_UNKNOWN, CrossNasEntryState.DELETE_UNKNOWN -> R.string.transfer_paused
    CrossNasEntryState.DELETING -> R.string.cross_nas_removing
    CrossNasEntryState.REMOVED -> R.string.cross_nas_removed
}
