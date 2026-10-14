package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.validatePhotoEditCheckpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import java.text.DateFormat
import java.text.NumberFormat
import java.util.Calendar
import java.util.Date

@Composable
internal fun SynologyPhotoEdits(model: SynologyPhotoEditModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    ClientPageDialog(stringResource(if (state.draft != null) R.string.sp_edit_title else R.string.sp_edit_records), model::dismiss) {
        Column(Modifier.fillMaxSize()) {
            state.error?.let { Text(photoEditError(it), Modifier.fillMaxWidth().padding(16.dp), color = MaterialTheme.colorScheme.error) }
            if (state.loading) Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            else if (!state.detailsReady && state.draft != null) Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                TextButton(onClick = { state.draft?.let { model.open(it.photos, it.space) } }) { Text(stringResource(R.string.sp_retry)) }
            }
            else if (state.draft != null) PhotoEditForm(state, model)
            else PhotoEditRecords(state, model)
        }
    }
}

@Composable
private fun ColumnScope.PhotoEditForm(state: SynologyPhotoEditState, model: SynologyPhotoEditModel) {
    val draft = state.draft ?: return
    val edit = draft.edit
    val mixed = draft.photos.map { it.id.space }.distinct().size > 1
    var choose by remember(draft.id) { mutableStateOf(false) }
    val types = buildList {
        if (draft.photos.isNotEmpty()) {
            add(SynologyPhotoEdit.Rating(draft.photos.singleOrNull()?.rating ?: 0))
            if (!mixed) add(SynologyPhotoEdit.Description(draft.photos.singleOrNull()?.description.orEmpty()))
            add(SynologyPhotoEdit.TakenAt(draft.photos.first().takenAt.toLong().coerceAtLeast(0)))
            add(SynologyPhotoEdit.ShiftDates(3600))
            if (!mixed) { add(SynologyPhotoEdit.AddTags(emptyList())); add(SynologyPhotoEdit.RemoveTags(emptyList())) }
        }
        if (!mixed) add(SynologyPhotoEdit.CreateTag(""))
    }
    LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (draft.photos.isNotEmpty()) item {
            Text(draft.photos.singleOrNull()?.filename ?: stringResource(R.string.items_selected_count, draft.photos.size), style = MaterialTheme.typography.titleMedium)
        }
        item {
            if (types.size == 1) Text(stringResource(edit.label()), style = MaterialTheme.typography.titleMedium) else Box {
                OutlinedButton(onClick = { choose = true }, enabled = !state.working, modifier = Modifier.fillMaxWidth().testTag("photos_edit_kind")) {
                    Text(stringResource(edit.label()), Modifier.weight(1f)); Icon(Icons.Outlined.ArrowDropDown, null)
                }
                DropdownMenu(choose, { choose = false }) {
                    types.forEach { type -> DropdownMenuItem(text = { Text(stringResource(type.label())) }, onClick = {
                        choose = false; model.setEdit(type)
                        if (type is SynologyPhotoEdit.AddTags || type is SynologyPhotoEdit.RemoveTags) model.loadTags()
                    }) }
                }
            }
            if (mixed) Text(stringResource(R.string.sp_edit_mixed), Modifier.padding(top = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        when (edit) {
            is SynologyPhotoEdit.Rotation -> Unit
            is SynologyPhotoEdit.Rating -> item {
                @OptIn(ExperimentalLayoutApi::class)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val format = NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0])
                    (0..5).forEach { value -> FilterChip(edit.value == value, { model.setEdit(SynologyPhotoEdit.Rating(value)) },
                        label = { Text(if (value == 0) stringResource(R.string.sp_edit_unrated) else format.format(value)) },
                        modifier = Modifier.heightIn(min = 48.dp).testTag("photos_edit_rating_$value"), enabled = !state.working) }
                }
            }
            is SynologyPhotoEdit.Description -> item {
                OutlinedTextField(edit.value, { model.setEdit(SynologyPhotoEdit.Description(it)) }, Modifier.fillMaxWidth().testTag("photos_edit_description"),
                    label = { Text(stringResource(R.string.sp_detail_description)) }, minLines = 4, enabled = !state.working)
            }
            is SynologyPhotoEdit.TakenAt -> item { PhotoEditDate(edit.seconds, !state.working) { model.setEdit(SynologyPhotoEdit.TakenAt(it)) } }
            is SynologyPhotoEdit.ShiftDates -> item { key(draft.id) { PhotoEditShift(edit.seconds, !state.working) { model.setEdit(SynologyPhotoEdit.ShiftDates(it)) } } }
            is SynologyPhotoEdit.CreateTag -> item {
                OutlinedTextField(edit.name, { model.setEdit(SynologyPhotoEdit.CreateTag(it)) }, Modifier.fillMaxWidth().testTag("photos_edit_tag_name"),
                    label = { Text(stringResource(R.string.sp_edit_tag_name)) }, singleLine = true, enabled = !state.working)
            }
            is SynologyPhotoEdit.AddTags, is SynologyPhotoEdit.RemoveTags -> {
                val selected = if (edit is SynologyPhotoEdit.AddTags) edit.ids else (edit as SynologyPhotoEdit.RemoveTags).ids
                if (edit is SynologyPhotoEdit.RemoveTags) item { Text(stringResource(R.string.sp_edit_remove_tags_note), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(state.tags, key = { "tag-${it.id}" }) { tag ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(tag.id in selected, enabled = !state.working,
                        role = Role.Checkbox, onValueChange = { checked ->
                            val ids = if (checked) (selected + tag.id).distinct() else selected - tag.id
                            model.setEdit(if (edit is SynologyPhotoEdit.AddTags) SynologyPhotoEdit.AddTags(ids) else SynologyPhotoEdit.RemoveTags(ids))
                        }), verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(tag.id in selected, null); Text(tag.name, Modifier.weight(1f).padding(start = 8.dp))
                    }
                }
                if (state.tagsLoading) item { CircularProgressIndicator(Modifier.size(24.dp)) }
                else if (state.moreTags) item { TextButton(onClick = { model.loadTags() }) { Text(stringResource(if (state.error == null) R.string.sp_edit_more_tags else R.string.sp_retry)) } }
                else if (state.tags.isEmpty()) item { Text(stringResource(R.string.sp_edit_no_tags)) }
            }
        }
        if (state.records.isNotEmpty()) item { TextButton(onClick = model::showRecords, enabled = !state.working) { Text(stringResource(R.string.sp_edit_records)) } }
    }
    val valid = remember(draft) {
        runCatching { validatePhotoEditCheckpoint(SynologyPhotoEditCheckpoint(profileId = draft.photos.firstOrNull()?.id?.profileId ?: "new-tag",
            userId = 1, space = draft.space, targets = draft.photos.map(::SynologyPhotoEditTarget), edit = edit)) }.isSuccess
    }
    Button(onClick = { model.save() }, enabled = valid && !state.working, modifier = Modifier.fillMaxWidth().padding(16.dp).testTag("photos_edit_save")) {
        Text(stringResource(if (edit is SynologyPhotoEdit.CreateTag) {
            if (draft.photos.isEmpty()) R.string.sp_edit_create_tag else R.string.sp_edit_create_and_apply
        } else R.string.save_changes))
    }
}

@Composable
internal fun PhotoEditDate(seconds: Long, enabled: Boolean, onChange: (Long) -> Unit) {
    val context = LocalContext.current
    val locale = LocalConfiguration.current.locales[0]
    val formatted = remember(seconds, locale) { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale).format(Date(seconds * 1000)) }
    OutlinedButton(onClick = {
        val initial = Calendar.getInstance().apply { timeInMillis = seconds * 1000 }
        DatePickerDialog(context, { _, year, month, day ->
            TimePickerDialog(context, { _, hour, minute ->
                val value = Calendar.getInstance().apply { set(year, month, day, hour, minute, 0); set(Calendar.MILLISECOND, 0) }
                onChange(value.timeInMillis / 1000)
            }, initial.get(Calendar.HOUR_OF_DAY), initial.get(Calendar.MINUTE), android.text.format.DateFormat.is24HourFormat(context)).show()
        }, initial.get(Calendar.YEAR), initial.get(Calendar.MONTH), initial.get(Calendar.DAY_OF_MONTH)).apply { datePicker.minDate = 0 }.show()
    }, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("photos_edit_date")) { Text(formatted) }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PhotoEditShift(initial: Long, enabled: Boolean, onChange: (Long) -> Unit) {
    var later by remember { mutableStateOf(initial >= 0) }
    val magnitude = kotlin.math.abs(initial)
    var days by remember { mutableStateOf((magnitude / 86400).toString()) }
    var hours by remember { mutableStateOf((magnitude % 86400 / 3600).toString()) }
    var minutes by remember { mutableStateOf((magnitude % 3600 / 60).toString()) }
    var seconds by remember { mutableStateOf((magnitude % 60).toString()) }
    fun apply() {
        val total = runCatching {
            listOf(days to 86400L, hours to 3600L, minutes to 60L, seconds to 1L).fold(0L) { sum, (text, unit) ->
                Math.addExact(sum, Math.multiplyExact(text.toLong().also { require(it >= 0) }, unit))
            }
        }.getOrDefault(0)
        onChange(if (later) total else -total)
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(!later, { later = false; apply() }, label = { Text(stringResource(R.string.sp_edit_earlier)) }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp))
            FilterChip(later, { later = true; apply() }, label = { Text(stringResource(R.string.sp_edit_later)) }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp))
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            PhotoShiftNumber(days, R.string.sp_edit_days, enabled) { days = it; apply() }
            PhotoShiftNumber(hours, R.string.sp_edit_hours, enabled) { hours = it; apply() }
            PhotoShiftNumber(minutes, R.string.sp_edit_minutes, enabled) { minutes = it; apply() }
            PhotoShiftNumber(seconds, R.string.sp_edit_seconds, enabled) { seconds = it; apply() }
        }
    }
}

@Composable
private fun PhotoShiftNumber(value: String, label: Int, enabled: Boolean, onChange: (String) -> Unit) {
    OutlinedTextField(value, onChange, Modifier.width((110 * LocalDensity.current.fontScale).dp), label = { Text(stringResource(label)) },
        enabled = enabled, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
}

@Composable
private fun ColumnScope.PhotoEditRecords(state: SynologyPhotoEditState, model: SynologyPhotoEditModel) {
    if (state.records.isEmpty()) Box(Modifier.weight(1f).fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(stringResource(R.string.sp_edit_records_empty))
    } else LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        items(state.records, key = { it.id }) { record ->
            val row = record.checkpoint
            var showPhotos by remember(row.operationId) { mutableStateOf(false) }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(row.edit.label()), style = MaterialTheme.typography.titleMedium)
                row.createdTag?.let { Text(it.name) }
                row.targets.firstOrNull()?.let { first ->
                    Text(if (row.targets.size == 1) first.filename else stringResource(R.string.sp_edit_photo_group, first.filename, row.targets.size - 1))
                    if (row.finished) Text(stringResource(R.string.sp_edit_result_count, row.completed.size, row.targets.size))
                    if (row.targets.size > 1) TextButton(onClick = { showPhotos = !showPhotos }) {
                        Text(stringResource(if (showPhotos) R.string.sp_edit_hide_photos else R.string.sp_edit_show_photos))
                    }
                }
                if (showPhotos) row.targets.forEachIndexed { index, target ->
                    ListItem(headlineContent = { Text(target.filename) }, supportingContent = {
                        Text(stringResource(when {
                            index in row.completed -> R.string.sp_edit_saved
                            row.finished || index !in row.attempted -> R.string.sp_edit_not_saved
                            else -> R.string.sp_edit_status_unavailable
                        }))
                    })
                }
                Text(stringResource(when {
                    state.working && state.activeId == row.operationId -> R.string.sp_edit_saving
                    row.phase == SynologyPhotoEditPhase.COMPLETED -> R.string.sp_edit_saved
                    row.phase == SynologyPhotoEditPhase.PARTIAL -> R.string.sp_edit_partial
                    row.submitted -> R.string.sp_edit_interrupted
                    else -> R.string.sp_edit_not_saved
                }), color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (state.working && state.activeId == row.operationId) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (row.phase == SynologyPhotoEditPhase.PARTIAL && row.edit !is SynologyPhotoEdit.Rotation) Button(onClick = { model.continueRemaining(row.operationId) }, enabled = !state.working) {
                    Text(stringResource(R.string.sp_edit_continue))
                }
                else if (!row.finished) Button(onClick = { model.resume(row.operationId) }, enabled = !state.working,
                    modifier = Modifier.testTag("photos_edit_resume")) {
                    Text(stringResource(if (row.submitted) R.string.sp_edit_refresh else R.string.save_changes))
                }
                if (row.finished || !row.submitted) TextButton(onClick = { model.discard(row.operationId) }, enabled = !state.working) {
                    Text(stringResource(R.string.sp_edit_clear_record))
                }
                HorizontalDivider()
            }
        }
    }
}

private fun SynologyPhotoEdit.label(): Int = when (this) {
    is SynologyPhotoEdit.Rotation -> R.string.sp_rotate_action
    is SynologyPhotoEdit.Rating -> R.string.sp_detail_rating
    is SynologyPhotoEdit.Description -> R.string.sp_detail_description
    is SynologyPhotoEdit.TakenAt -> R.string.sp_edit_date
    is SynologyPhotoEdit.ShiftDates -> R.string.sp_edit_shift
    is SynologyPhotoEdit.AddTags -> R.string.sp_edit_add_tags
    is SynologyPhotoEdit.RemoveTags -> R.string.sp_edit_remove_tags
    is SynologyPhotoEdit.CreateTag -> R.string.sp_edit_create_tag
}

@Composable
internal fun photoEditError(error: Throwable): String = when (error) {
    is SynologyPhotoAlbumFailure -> photoAlbumError(error)
    is SynologyPhotoEditFailure -> stringResource(when (error.problem) {
        SynologyPhotoEditProblem.STORAGE -> R.string.sp_edit_storage_failed
        SynologyPhotoEditProblem.BUSY -> R.string.sp_edit_busy
        SynologyPhotoEditProblem.PENDING -> R.string.sp_edit_conflict
        SynologyPhotoEditProblem.LIMIT -> R.string.sp_edit_limit
    })
    is SynologyPhotoFailure -> when (error.kind) {
        SynologyPhotoFailureKind.TARGET_CHANGED -> stringResource(R.string.sp_edit_changed)
        SynologyPhotoFailureKind.PERMISSION -> stringResource(R.string.sp_edit_permission)
        else -> photoError(error)
    }
    else -> stringResource(R.string.sp_edit_failed)
}
