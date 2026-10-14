package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import java.text.NumberFormat

/** 缩略图打开原有完整预览；独立选择行用于整理，不把查看和选择合成同一个动作。 */
@Composable
internal fun SynologyPhotoSimilarGroups(model: SynologyPhotoSimilarModel, library: SynologyPhotosModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    val number = NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0])
    ClientPageDialog(stringResource(if (state.original == null) R.string.sp_similar_records else R.string.sp_category_similar), model::dismiss) {
        LazyVerticalGrid(GridCells.Adaptive(150.dp * LocalConfiguration.current.fontScale.coerceAtLeast(1f)), Modifier.fillMaxSize().testTag("photos_similar_group"),
            contentPadding = PaddingValues(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { model.load() }, enabled = !state.loading && !state.working && state.confirmation.isEmpty(),
                        modifier = Modifier.testTag("photos_similar_refresh")) { Text(stringResource(R.string.sp_edit_refresh)) }
                    if (state.detail != null) OutlinedButton(onClick = model::exportCurrent, enabled = state.canEdit,
                        modifier = Modifier.testTag("photos_similar_export")) { Text(stringResource(R.string.sp_similar_export)) }
                }
            }
            if (state.loading || state.working) item(span = { GridItemSpan(maxLineSpan) }) { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            state.error?.let { error -> item(span = { GridItemSpan(maxLineSpan) }) { Text(similarError(error), color = MaterialTheme.colorScheme.error) } }
            if (state.dissolved) item(span = { GridItemSpan(maxLineSpan) }) { Text(stringResource(R.string.sp_similar_dissolved)) }
            state.detail?.let { detail ->
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(pluralStringResource(R.plurals.sp_similar_members, detail.photos.size, number.format(detail.photos.size)), style = MaterialTheme.typography.titleMedium)
                        if (model.available(detail.group.space)) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(onClick = { model.prepare(SynologyPhotoSimilarEdit.TOP_PICK) },
                                enabled = state.canEdit && state.selected.size == 1 && state.selected.single() != detail.group.topPickId,
                                modifier = Modifier.testTag("photos_similar_top_pick")) { Text(stringResource(R.string.sp_similar_top_pick)) }
                            TextButton(onClick = { model.prepare(SynologyPhotoSimilarEdit.REMOVE) }, enabled = state.canEdit && state.selected.isNotEmpty(),
                                modifier = Modifier.testTag("photos_similar_remove")) { Text(stringResource(R.string.sp_similar_remove)) }
                            TextButton(onClick = { model.prepare(SynologyPhotoSimilarEdit.UNGROUP) }, enabled = state.canEdit,
                                modifier = Modifier.testTag("photos_similar_ungroup")) { Text(stringResource(R.string.sp_similar_ungroup)) }
                            TextButton(onClick = { model.cleanUp() }, enabled = model.canCleanUp,
                                modifier = Modifier.testTag("photos_similar_clean_up")) { Text(stringResource(R.string.sp_similar_clean_up)) }
                        }
                    }
                }
                items(detail.photos, key = { "member:${it.id.itemId}" }) { photo ->
                    Column(Modifier.testTag("photos_similar_member_${photo.id.itemId}")) {
                        SynologyPhotoTile(photo.copy(similarGroup = null), library, onClick = { model.preview(photo.id.itemId) })
                        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(photo.id.itemId in state.selected,
                            enabled = state.canEdit, role = Role.Checkbox, onValueChange = { model.toggle(photo.id.itemId) })
                            .testTag("photos_similar_select_${photo.id.itemId}"), verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(photo.id.itemId in state.selected, null, enabled = state.canEdit)
                            Column(Modifier.weight(1f).padding(end = 4.dp)) {
                                Text(photo.filename, style = MaterialTheme.typography.bodySmall)
                                if (photo.id.itemId == detail.group.topPickId) Text(stringResource(R.string.sp_similar_recommended), style = MaterialTheme.typography.labelMedium)
                            }
                        }
                    }
                }
            }
            if (state.loaded && state.original == null && state.records.isEmpty() && state.confirmation.isEmpty())
                item(span = { GridItemSpan(maxLineSpan) }) { Text(stringResource(R.string.sp_similar_records_empty)) }
            if (state.records.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }) { Text(stringResource(R.string.sp_similar_records), style = MaterialTheme.typography.titleMedium) }
            items(state.records, key = { "record:${it.id}" }, span = { GridItemSpan(maxLineSpan) }) { record ->
                SimilarRecord(record, model, state.working || state.loading || state.confirmation.isNotEmpty(), state.pending)
            }
        }
    }
    if (state.confirmation.isNotEmpty()) {
        val rows = state.confirmation; val edit = rows.first().similar!!.edit
        AlertDialog(onDismissRequest = model::cancelConfirmation,
            title = { Text(stringResource(edit.similarLabel())) },
            text = { Text(when (edit) {
                SynologyPhotoSimilarEdit.REMOVE -> stringResource(R.string.sp_similar_remove_message)
                SynologyPhotoSimilarEdit.UNDO -> stringResource(R.string.sp_similar_undo_message)
                SynologyPhotoSimilarEdit.TOP_PICK -> stringResource(R.string.sp_similar_top_pick_message)
                SynologyPhotoSimilarEdit.UNGROUP -> pluralStringResource(R.plurals.sp_similar_ungroup_message, rows.size, number.format(rows.size))
            }) },
            confirmButton = { TextButton(onClick = { model.confirm() }, modifier = Modifier.testTag("photos_similar_confirm")) { Text(stringResource(edit.similarLabel())) } },
            dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun SimilarRecord(record: SynologyPhotoAlbumRecord, model: SynologyPhotoSimilarModel, busy: Boolean, pending: Boolean) {
    val row = record.checkpoint; val change = row.similar!!
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(change.edit.similarLabel()), style = MaterialTheme.typography.titleSmall)
        Text(stringResource(when {
            change.confirmed -> R.string.sp_similar_saved
            change.rejected -> R.string.sp_similar_rejected
            !row.submitted -> R.string.sp_similar_not_started
            row.finished -> R.string.sp_similar_not_changed
            else -> R.string.sp_similar_pending
        }))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (row.submitted && !row.finished) OutlinedButton(onClick = { model.resume(record.id) }, enabled = !busy,
                modifier = Modifier.testTag("photos_similar_review")) { Text(stringResource(R.string.sp_edit_refresh)) }
            if (!row.submitted) {
                OutlinedButton(onClick = { model.continueBatch(record.id) }, enabled = !busy && !pending,
                    modifier = Modifier.testTag("photos_similar_continue")) { Text(stringResource(R.string.sp_similar_continue)) }
                if (change.undo == null) TextButton(onClick = { model.cancelRemaining(record.id) }, enabled = !busy,
                    modifier = Modifier.testTag("photos_similar_cancel_remaining")) { Text(stringResource(R.string.sp_similar_cancel_remaining)) }
            }
            if (model.canUndo(record)) OutlinedButton(onClick = { model.undo(record.id) }, enabled = !busy,
                modifier = Modifier.testTag("photos_similar_undo")) { Text(stringResource(R.string.sp_similar_undo)) }
        }
        HorizontalDivider()
    }
}

private fun SynologyPhotoSimilarEdit.similarLabel() = when (this) {
    SynologyPhotoSimilarEdit.TOP_PICK -> R.string.sp_similar_top_pick
    SynologyPhotoSimilarEdit.REMOVE -> R.string.sp_similar_remove
    SynologyPhotoSimilarEdit.UNGROUP -> R.string.sp_similar_ungroup
    SynologyPhotoSimilarEdit.UNDO -> R.string.sp_similar_undo
}

@Composable
private fun similarError(error: Throwable) = when (error) {
    is SynologyPhotoAlbumFailure -> photoAlbumError(error)
    is SynologyPhotoFailure -> stringResource(when (error.kind) {
        SynologyPhotoFailureKind.PERMISSION -> R.string.sp_similar_permission
        SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_similar_changed
        else -> R.string.sp_similar_failed
    })
    else -> stringResource(R.string.sp_similar_failed)
}
