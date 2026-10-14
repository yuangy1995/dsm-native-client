package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import java.text.NumberFormat
import kotlinx.coroutines.CancellationException

@Composable
internal fun SynologyPhotoManualFaces(model: SynologyPhotoManualFacesModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    var imageFailed by remember(state.image) { mutableStateOf(false) }
    val bitmap by produceState<Bitmap?>(null, state.image) {
        value = null
        state.image?.let { data ->
            try { value = PhotoBitmapDecoder.decode(data, 2560) }
            catch (error: Exception) { if (error is CancellationException) throw error; imageFailed = true }
        }
    }
    val number = NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0])
    val drawing = state.drawing
    ClientPageDialog(stringResource(R.string.sp_manual_faces_title), model::dismiss) {
        LazyColumn(Modifier.fillMaxSize().testTag("photos_manual_list"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { model.save() }, enabled = state.canSave && bitmap != null, modifier = Modifier.testTag("photos_manual_save")) { Text(stringResource(R.string.save_changes)) }
                    OutlinedButton(onClick = { model.load() }, enabled = !state.loading && !state.working && state.confirmation == null,
                        modifier = Modifier.testTag("photos_manual_refresh")) { Text(stringResource(R.string.sp_edit_refresh)) }
                }
            }
            if (state.loading || state.working) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            state.error?.let { error -> item {
                Text(manualFacesError(error), color = MaterialTheme.colorScheme.error)
                if (error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED && !state.pending) TextButton(
                    onClick = { model.load(restart = true) }, enabled = !state.loading && !state.working, modifier = Modifier.testTag("photos_manual_restart")) {
                    Text(stringResource(R.string.sp_manual_faces_restart))
                }
            } }
            if (imageFailed) item { Text(stringResource(R.string.sp_media_failed), color = MaterialTheme.colorScheme.error) }
            else if (state.image != null) item { FaceCanvas(bitmap, state, model) }
            if (state.loaded || state.drafts.isNotEmpty()) {
                item {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { bitmap?.let { model.add(SynologyPhotoFaceEditing.center(it.width, it.height)) } }, enabled = state.editable && bitmap != null && state.drafts.count { !it.removed } < 50,
                            modifier = Modifier.testTag("photos_manual_add")) { Text(stringResource(R.string.sp_manual_faces_add)) }
                        OutlinedButton(onClick = { model.draw(!state.drawing) }, enabled = state.editable,
                            colors = ButtonDefaults.outlinedButtonColors(containerColor = if (state.drawing) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent),
                            modifier = Modifier.semantics { selected = drawing }.testTag("photos_manual_draw")) {
                            Text(stringResource(if (state.drawing) R.string.sp_manual_faces_stop_drawing else R.string.sp_manual_faces_draw))
                        }
                    }
                    if (state.drafts.isEmpty()) Text(stringResource(R.string.sp_manual_faces_empty), Modifier.padding(vertical = 8.dp))
                }
                item {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        state.drafts.forEachIndexed { index, draft ->
                            FilterChip(draft.key == state.selected, { model.select(draft.key) }, enabled = state.editable,
                                modifier = Modifier.heightIn(min = 48.dp).testTag("photos_manual_face_$index"),
                                label = { Text(stringResource(if (draft.removed) R.string.sp_manual_faces_removed else R.string.sp_manual_faces_number,
                                    number.format(index + 1), draft.name.ifEmpty { stringResource(R.string.sp_person_unnamed) })) })
                        }
                    }
                }
                state.selectedDraft?.let { draft ->
                    item { FacePosition(draft, state.editable && !draft.removed, model) }
                    item {
                        OutlinedButton(onClick = model::remove, enabled = state.editable, modifier = Modifier.testTag("photos_manual_remove")) {
                            Text(stringResource(if (draft.removed) R.string.sp_manual_faces_restore else R.string.sp_manual_faces_remove))
                        }
                    }
                    if (!draft.removed) {
                        item {
                            val enabled = state.editable
                            OutlinedTextField(state.query, model::search, enabled = enabled, label = { Text(stringResource(R.string.sp_people_search)) },
                                singleLine = true, modifier = Modifier.fillMaxWidth().testTag("photos_manual_search"))
                            ListItem(headlineContent = { Text(stringResource(R.string.sp_person_faces_new)) }, leadingContent = { RadioButton(draft.person == null, null, enabled = enabled) },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(draft.person == null, enabled = enabled, role = Role.RadioButton,
                                    onClick = { model.person(null) }).testTag("photos_manual_new_person"))
                            if (draft.person == null) OutlinedTextField(draft.name, model::name, enabled = enabled, label = { Text(stringResource(R.string.sp_person_name)) },
                                singleLine = true, modifier = Modifier.fillMaxWidth().testTag("photos_manual_name"))
                            else Text(stringResource(R.string.sp_manual_faces_person, draft.person.name.ifEmpty { stringResource(R.string.sp_person_unnamed) }))
                        }
                        if (state.filteredPeople.isEmpty() && state.query.isNotBlank()) item { Text(stringResource(R.string.sp_people_search_empty)) }
                        items(state.filteredPeople, key = { "person-${it.id}" }) { person ->
                            ListItem(headlineContent = { Text(personName(person)) }, leadingContent = { RadioButton(draft.person?.id == person.id, null, enabled = state.editable) },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(draft.person?.id == person.id, enabled = state.editable, role = Role.RadioButton,
                                    onClick = { model.person(person.id) }).testTag("photos_manual_person_${person.id}"))
                        }
                    }
                }
            }
            items(state.records, key = { it.id }) { record ->
                val row = record.checkpoint
                HorizontalDivider()
                Text(stringResource(when {
                    row.phase == SynologyPhotoAlbumPhase.COMPLETED -> R.string.sp_manual_faces_saved
                    row.phase == SynologyPhotoAlbumPhase.PARTIAL -> R.string.sp_manual_faces_partial
                    row.submitted -> R.string.sp_manual_faces_pending
                    else -> R.string.sp_people_not_sent
                }))
                if (row.submitted && !row.finished) OutlinedButton(onClick = { model.resume(record.id) }, enabled = !state.working && !state.loading,
                    modifier = Modifier.testTag("photos_manual_review")) { Text(stringResource(R.string.sp_edit_refresh)) }
                else TextButton(onClick = { model.discard(record.id) }, enabled = !state.working && !state.loading,
                    modifier = Modifier.testTag("photos_manual_clear_record")) { Text(stringResource(R.string.sp_edit_clear_record)) }
            }
        }
    }
    state.confirmation?.let { row ->
        val changes = row.manualFaces!!.changes
        val removed = changes.count { it is SynologyPhotoFaceChange.Remove }
        val reassigned = changes.count { it is SynologyPhotoFaceChange.Reassign }
        AlertDialog(onDismissRequest = model::cancelConfirmation, title = { Text(stringResource(R.string.sp_manual_faces_title)) },
            text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (removed > 0) Text(pluralStringResource(R.plurals.sp_manual_faces_remove_count, removed, number.format(removed)))
                if (reassigned > 0) Text(pluralStringResource(R.plurals.sp_manual_faces_reassign_count, reassigned, number.format(reassigned)))
                Text(stringResource(R.string.sp_manual_faces_risk))
            } },
            confirmButton = { TextButton(onClick = { model.confirm() }, enabled = !state.working, modifier = Modifier.testTag("photos_manual_confirm")) { Text(stringResource(R.string.save_changes)) } },
            dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun FaceCanvas(bitmap: Bitmap?, state: SynologyPhotoManualFacesState, model: SynologyPhotoManualFacesModel) {
    val image = bitmap
    if (image == null) { Box(Modifier.fillMaxWidth().height(160.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }; return }
    val primary = MaterialTheme.colorScheme.primary; val other = MaterialTheme.colorScheme.tertiary
    var drag by remember(image) { mutableStateOf<SynologyPhotoFaceBounds?>(null) }
    val description = stringResource(R.string.sp_manual_faces_canvas)
    BoxWithConstraints(Modifier.fillMaxWidth().heightIn(max = 360.dp), contentAlignment = Alignment.Center) {
        val ratio = image.width.toFloat() / image.height
        val width = minOf(maxWidth, 360.dp * ratio)
        Box(Modifier.width(width).aspectRatio(ratio).testTag("photos_manual_canvas").semantics { contentDescription = description }) {
            Image(image.asImageBitmap(), state.photo?.filename, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
            Canvas(Modifier.fillMaxSize().minimumInteractiveComponentSize().pointerInput(state.editable, state.drawing, state.drafts) {
                if (state.editable && state.drawing) {
                    var start = Offset.Zero
                    detectDragGestures(onDragStart = { start = it }, onDragCancel = { drag = null }, onDragEnd = {
                        drag?.let(model::add); drag = null
                    }) { change, _ ->
                        change.consume()
                        drag = SynologyPhotoFaceEditing.square(start.x, start.y, change.position.x, change.position.y, size.width.toFloat(), size.height.toFloat())
                    }
                } else if (state.editable) detectTapGestures { point ->
                    state.drafts.lastOrNull { face -> !face.removed && point.x / size.width >= face.bounds.x && point.y / size.height >= face.bounds.y &&
                        point.x / size.width <= face.bounds.x + face.bounds.width && point.y / size.height <= face.bounds.y + face.bounds.height }?.let { model.select(it.key) }
                }
            }) {
                fun box(bounds: SynologyPhotoFaceBounds, selected: Boolean) {
                    val offset = Offset((bounds.x * size.width).toFloat(), (bounds.y * size.height).toFloat())
                    val dimensions = Size((bounds.width * size.width).toFloat(), (bounds.height * size.height).toFloat())
                    val stroke = if (selected) 4.dp.toPx() else 2.dp.toPx()
                    drawRect(Color.White, topLeft = offset, size = dimensions, style = Stroke(stroke + 2.dp.toPx()))
                    drawRect(if (selected) primary else other, topLeft = offset, size = dimensions, style = Stroke(stroke))
                }
                state.drafts.filterNot { it.removed }.forEach { box(it.bounds, it.key == state.selected) }
                drag?.let { box(it, true) }
            }
        }
    }
}

@Composable
private fun FacePosition(draft: SynologyPhotoFaceDraft, enabled: Boolean, model: SynologyPhotoManualFacesModel) {
    val bounds = draft.bounds
    val percent = NumberFormat.getPercentInstance(LocalConfiguration.current.locales[0]).apply { maximumFractionDigits = 0 }
    Column(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.sp_manual_faces_position), style = MaterialTheme.typography.titleSmall)
        listOf(R.string.sp_manual_faces_left to bounds.x, R.string.sp_manual_faces_top to bounds.y,
            R.string.sp_manual_faces_width to bounds.width, R.string.sp_manual_faces_height to bounds.height).forEachIndexed { index, (label, value) ->
            val title = stringResource(label)
            Text(stringResource(R.string.sp_manual_faces_value, title, percent.format(value)))
            val minimum = if (index < 2) 0.0 else 0.001
            val maximum = when (index) { 0 -> 1 - bounds.width; 1 -> 1 - bounds.height; 2 -> 1 - bounds.x; else -> 1 - bounds.y }
            Slider(value.toFloat(), { raw ->
                val next = raw.toDouble().coerceIn(minimum, maximum)
                model.bounds(when (index) { 0 -> bounds.copy(x = next); 1 -> bounds.copy(y = next); 2 -> bounds.copy(width = next); else -> bounds.copy(height = next) })
            }, enabled = enabled && maximum > minimum, valueRange = minimum.toFloat()..maxOf(minimum, maximum).toFloat(),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = title }.testTag("photos_manual_position_$index"))
        }
    }
}

@Composable
private fun manualFacesError(error: Throwable): String = when (error) {
    is SynologyPhotoAlbumFailure -> photoAlbumError(error)
    is SynologyPhotoFailure -> stringResource(when (error.kind) {
        SynologyPhotoFailureKind.PERMISSION -> R.string.sp_manual_faces_permission
        SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_manual_faces_changed
        else -> R.string.sp_manual_faces_failed
    })
    else -> stringResource(R.string.sp_manual_faces_failed)
}
