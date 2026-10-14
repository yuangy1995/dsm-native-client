package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

@Composable
internal fun SynologyPhotoPreviewRegeneration(model: SynologyPhotoPreviewRegenerationModel, spaces: List<SynologyPhotoSpace>) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    val enabled = !state.working && !state.loading && state.confirmation == null
    ClientPageDialog(stringResource(R.string.sp_preview_regeneration_title), model::dismiss) {
        Column(Modifier.fillMaxSize()) {
            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val sources = spaces.filter(model::available)
                if (state.queue && sources.size > 1) sources.forEach { space ->
                    FilterChip(selected = state.space == space, onClick = { model.selectSpace(space) }, enabled = enabled,
                        label = { Text(stringResource(if (space == SynologyPhotoSpace.PERSONAL) R.string.sp_source_personal else R.string.sp_source_shared)) })
                }
                OutlinedButton(onClick = { model.refresh() }, enabled = enabled, modifier = Modifier.testTag("photos_previews_refresh")) { Text(stringResource(R.string.sp_edit_refresh)) }
                OutlinedButton(onClick = { model.request() }, enabled = enabled && !state.pending && state.selected.isNotEmpty(),
                    modifier = Modifier.testTag("photos_previews_start")) { Text(stringResource(R.string.sp_preview_regeneration_title)) }
            }
            if (state.photos.isNotEmpty()) OutlinedTextField(value = state.query, onValueChange = model::search, singleLine = true,
                enabled = enabled, label = { Text(stringResource(R.string.sp_previews_search)) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("photos_previews_search"))
            if (state.loading && state.photos.isEmpty() && state.records.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            } else if (state.error == null && state.photos.isEmpty() && state.records.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { Text(stringResource(R.string.sp_previews_empty)) }
            } else LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_previews_list"), contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (state.loading || state.working) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                state.error?.let { error -> item { Text(previewRegenerationError(error), color = MaterialTheme.colorScheme.error) } }
                if (state.photos.isNotEmpty()) item { Text(stringResource(R.string.sp_previews_selection, state.selected.size)) }
                if (state.photos.isNotEmpty() && state.filtered.isEmpty()) item { Text(stringResource(R.string.sp_previews_no_match)) }
                items(state.filtered, key = { "candidate-${it.id.space}-${it.id.itemId}" }) { photo ->
                    val selected = photo.id in state.selected
                    ListItem(headlineContent = { Text(photo.filename) }, leadingContent = { Checkbox(checked = selected, onCheckedChange = null) },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = selected,
                            enabled = enabled && !state.pending && (selected || state.selected.size < 100), role = Role.Checkbox,
                            onValueChange = { model.toggle(photo) }).testTag("photos_previews_item_${photo.id.space}_${photo.id.itemId}"))
                }
                items(state.records, key = { it.id }) { record -> PreviewRegenerationRecord(record, state, model) }
            }
        }
    }
    state.confirmation?.let { row ->
        AlertDialog(onDismissRequest = model::cancelConfirmation,
            title = { Text(stringResource(R.string.sp_preview_regeneration_title)) },
            text = { Text(pluralStringResource(R.plurals.sp_previews_confirm_message, row.targets.size, row.targets.size), Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = { model.confirm() }, enabled = !state.working,
                modifier = Modifier.testTag("photos_previews_confirm")) { Text(stringResource(R.string.sp_preview_regeneration_title)) } },
            dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun PreviewRegenerationRecord(record: SynologyPhotoAlbumRecord, state: SynologyPhotoPreviewRegenerationState,
    model: SynologyPhotoPreviewRegenerationModel) {
    val row = record.checkpoint
    var expanded by remember(record.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        HorizontalDivider()
        Text(pluralStringResource(R.plurals.sp_previews_progress, row.targets.size, row.completed.size, row.targets.size), style = MaterialTheme.typography.titleSmall)
        Text(stringResource(when {
            state.working && record.id == state.activeId -> R.string.sp_previews_updating
            row.phase == SynologyPhotoAlbumPhase.COMPLETED -> R.string.sp_previews_done
            row.phase == SynologyPhotoAlbumPhase.PARTIAL -> R.string.sp_previews_incomplete
            row.submitted -> R.string.sp_previews_pending
            else -> R.string.sp_previews_not_sent
        }))
        TextButton(onClick = { expanded = !expanded }, modifier = Modifier.testTag("photos_previews_details")) {
            Text(stringResource(if (expanded) R.string.sp_previews_hide_details else R.string.sp_previews_details))
        }
        if (expanded) row.targets.forEachIndexed { index, target ->
            val progress = row.previews!!.progress[index]
            Text(target.filename, style = MaterialTheme.typography.bodyMedium)
            Text(stringResource(when {
                index in row.completed -> R.string.sp_previews_item_done
                progress.failed -> R.string.sp_previews_item_failed
                progress.submitted || SynologyPhotoPreviewFact.MARK_ATTEMPTED in progress -> R.string.sp_previews_item_pending
                else -> R.string.sp_previews_not_sent
            }), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        val enabled = !state.working && !state.loading && state.confirmation == null
        if (row.submitted && !row.finished) OutlinedButton(onClick = { model.resume(record.id) }, enabled = enabled,
            modifier = Modifier.testTag("photos_previews_review")) { Text(stringResource(R.string.sp_edit_refresh)) }
        if (!row.submitted || row.finished) TextButton(onClick = { model.discard(record.id) }, enabled = enabled,
            modifier = Modifier.testTag("photos_previews_clear")) { Text(stringResource(R.string.sp_edit_clear_record)) }
    }
}

@Composable
private fun previewRegenerationError(error: Throwable): String = when (error) {
    is SynologyPhotoAlbumFailure -> photoAlbumError(error)
    is SynologyPhotoFailure -> stringResource(when (error.kind) {
        SynologyPhotoFailureKind.PERMISSION -> R.string.sp_previews_permission
        SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_previews_changed
        else -> R.string.sp_previews_failed
    })
    else -> stringResource(R.string.sp_previews_failed)
}
