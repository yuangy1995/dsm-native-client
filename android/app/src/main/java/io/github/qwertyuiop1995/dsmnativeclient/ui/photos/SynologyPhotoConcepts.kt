package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Category
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
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
import kotlinx.coroutines.CancellationException

@Composable
internal fun PhotoConceptCardHeader(concept: SynologyPhotoCollection, model: SynologyPhotoConceptModel?) {
    Box(Modifier.fillMaxWidth()) {
        ConceptCover(concept, model, Modifier.fillMaxWidth().aspectRatio(1f))
        if (model?.available(concept.space) == true) {
            val state by model.state.collectAsState(); var expanded by remember(concept.id, concept.space) { mutableStateOf(false) }
            Box(Modifier.align(Alignment.TopEnd).background(MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.9f))) {
                IconButton(onClick = { expanded = true }, enabled = !state.working, modifier = Modifier.testTag("photos_concept_actions_${concept.id}")) {
                    Icon(Icons.Outlined.MoreVert, stringResource(R.string.sp_concept_actions, concept.name))
                }
                DropdownMenu(expanded, { expanded = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.sp_concepts_visibility)) },
                        onClick = { expanded = false; model.open(concept.space, concept) }, modifier = Modifier.testTag("photos_concept_visibility"))
                }
            }
        }
    }
}

@Composable
private fun ConceptCover(concept: SynologyPhotoCollection, model: SynologyPhotoConceptModel?, modifier: Modifier) {
    val bitmap by produceState<Bitmap?>(null, concept.id, concept.space, concept.thumbnail, model) {
        value = null
        if (model != null && concept.thumbnail != null) try { value = PhotoBitmapDecoder.decode(model.thumbnail(concept), 512) }
        catch (error: Exception) { if (error is CancellationException) throw error }
    }
    Box(modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
        val image = bitmap
        if (image == null) Icon(Icons.Outlined.Category, null)
        else Image(image.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    }
}

@Composable
internal fun PhotoConceptSelectionActions(model: SynologyPhotoConceptModel, navigation: SynologyPhotoNavigation,
    photos: List<SynologyPhoto>, enabled: Boolean, compact: Boolean = false, onOpen: () -> Unit = {}) {
    val concept = navigation.categoryItem ?: return
    if (navigation.category != SynologyPhotoCategory.SUBJECTS || navigation.album != null || !model.available(concept.space, true)) return
    var expanded by remember(concept.id, concept.space) { mutableStateOf(false) }
    val canOpen = enabled && photos.size in 1..100 && photos.all { it.id.space == concept.space && it.albumContext == null }
    Box {
        if (compact) IconButton(onClick = { expanded = true }, enabled = canOpen, modifier = Modifier.testTag("photos_concept_selection_actions")) {
            Icon(Icons.Outlined.Category, stringResource(R.string.sp_concept_manage))
        } else TextButton(onClick = { expanded = true }, enabled = canOpen,
            modifier = Modifier.testTag("photos_concept_selection_actions")) { Text(stringResource(R.string.sp_concept_manage)) }
        DropdownMenu(expanded, { expanded = false }) {
            listOf(SynologyPhotoAlbumAction.COVER_CONCEPT, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS).forEach { action ->
                DropdownMenuItem(text = { Text(stringResource(action.conceptLabel())) }, enabled = action != SynologyPhotoAlbumAction.COVER_CONCEPT || photos.size == 1,
                    onClick = { expanded = false; model.openPhotos(action, concept, photos); onOpen() }, modifier = Modifier.testTag("photos_concept_selection_${action.name}"))
            }
        }
    }
}

@Composable
internal fun SynologyPhotoConcepts(model: SynologyPhotoConceptModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    val number = NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0])
    val visibility = state.action == SynologyPhotoAlbumAction.SHOW_CONCEPTS
    val editable = state.loaded && !state.loading && !state.working && state.confirmation == null
    ClientPageDialog(stringResource(state.action.conceptLabel()), model::dismiss) {
        if (state.loading && !state.loaded && state.records.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        else LazyColumn(Modifier.fillMaxSize().testTag("photos_concepts_list"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { model.save() }, enabled = state.canSave, modifier = Modifier.testTag("photos_concepts_save")) {
                        Text(stringResource(if (state.action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) R.string.sp_concept_remove else R.string.save_changes))
                    }
                    OutlinedButton(onClick = { model.load() }, enabled = !state.loading && !state.working && state.confirmation == null,
                        modifier = Modifier.testTag("photos_concepts_refresh")) { Text(stringResource(R.string.sp_edit_refresh)) }
                }
            }
            if (state.loading || state.working) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            state.error?.let { error -> item { Text(conceptError(error), color = MaterialTheme.colorScheme.error) } }
            if (state.loaded) {
                if (visibility) {
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                listOf(true, false).forEach { shown -> FilterChip(state.desiredVisibility == shown, onClick = { model.visibility(shown) },
                                    label = { Text(stringResource(if (shown) R.string.sp_people_show else R.string.sp_people_hide)) }, enabled = editable,
                                    modifier = Modifier.heightIn(min = 48.dp).testTag("photos_concepts_visibility_$shown")) }
                            }
                            OutlinedTextField(state.query, model::search, enabled = editable, label = { Text(stringResource(R.string.sp_concepts_search)) },
                                singleLine = true, modifier = Modifier.fillMaxWidth().testTag("photos_concepts_search"))
                            Text(stringResource(R.string.sp_people_selected, number.format(state.selected.size), number.format(100)), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    if (state.filtered.isEmpty()) item { Text(stringResource(if (state.query.isNotBlank()) R.string.sp_concepts_search_empty else R.string.sp_concepts_empty),
                        Modifier.fillMaxWidth().padding(vertical = 24.dp)) }
                    items(state.filtered, key = { "concept:${it.id}" }) { concept -> ConceptChoice(concept, state, model) }
                } else {
                    state.target?.let { target -> item { Text(target.name, style = MaterialTheme.typography.titleMedium) } }
                    if (state.photos.isNotEmpty()) item { Text(pluralStringResource(R.plurals.sp_concept_selected_photos, state.photos.size, number.format(state.photos.size))) }
                    items(state.photos, key = { "photo:${it.id.itemId}" }) { photo -> Text(photo.filename, Modifier.fillMaxWidth()) }
                    if (state.action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS && state.target?.let { it.count == null || it.conceptDisplayThreshold == null } == true)
                        item { Text(stringResource(R.string.sp_concept_details_missing), color = MaterialTheme.colorScheme.error) }
                }
            }
            if (state.records.isNotEmpty()) item { Text(stringResource(R.string.sp_concepts_records), style = MaterialTheme.typography.titleMedium) }
            items(state.records, key = { it.id }) { record -> ConceptRecord(record, state.working || state.loading, model) }
        }
    }
    state.confirmation?.let { row ->
        val original = row.concept!!.originals.single()
        AlertDialog(onDismissRequest = model::cancelConfirmation, title = { Text(stringResource(R.string.sp_concept_remove)) },
            text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(pluralStringResource(R.plurals.sp_concept_remove_risk, row.targets.size, number.format(row.targets.size), original.name))
                if (original.count!! - row.targets.size < original.displayThreshold!!) Text(stringResource(R.string.sp_concept_threshold_risk))
            } }, confirmButton = { TextButton(onClick = { model.confirm() }, enabled = !state.working, modifier = Modifier.testTag("photos_concepts_confirm")) {
                Text(stringResource(R.string.sp_concept_remove))
            } }, dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun ConceptChoice(concept: SynologyPhotoCollection, state: SynologyPhotoConceptState, model: SynologyPhotoConceptModel) {
    val selected = concept.id in state.selected
    val enabled = !state.working && !state.loading && state.confirmation == null && (selected || state.selected.size < 100) &&
        concept.conceptVisible != null && concept.conceptVisible != state.desiredVisibility
    ListItem(headlineContent = { Text(concept.name) }, leadingContent = { ConceptCover(concept, model, Modifier.size(48.dp)) },
        supportingContent = { Column {
            concept.count?.let { Text(pluralStringResource(R.plurals.sp_people_photo_count, it, NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0]).format(it))) }
            Text(stringResource(when {
                concept.conceptVisible == false -> R.string.sp_people_hidden
                !SynologyPhotoConceptSnapshot(concept).appearsInList -> R.string.sp_concept_below_threshold
                else -> R.string.sp_people_shown
            }))
        } }, trailingContent = { Checkbox(selected, null, enabled = enabled) }, modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp)
            .toggleable(selected, enabled = enabled, role = Role.Checkbox, onValueChange = { model.toggle(concept.id) }).testTag("photos_concepts_select_${concept.id}"))
}

@Composable
private fun ConceptRecord(record: SynologyPhotoAlbumRecord, busy: Boolean, model: SynologyPhotoConceptModel) {
    val row = record.checkpoint; val value = row.concept!!
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(row.action.conceptLabel()), style = MaterialTheme.typography.titleSmall)
        Text(stringResource(when {
            row.phase == SynologyPhotoAlbumPhase.COMPLETED -> R.string.sp_concepts_saved
            value.rejected -> R.string.sp_concepts_rejected
            !row.submitted || !value.attempted -> R.string.sp_concepts_not_sent
            row.phase == SynologyPhotoAlbumPhase.PARTIAL -> R.string.sp_concepts_partial
            else -> R.string.sp_concepts_pending
        }))
        if (row.submitted && !row.finished) OutlinedButton(onClick = { model.resume(record.id) }, enabled = !busy,
            modifier = Modifier.testTag("photos_concepts_review")) { Text(stringResource(R.string.sp_edit_refresh)) }
        else TextButton(onClick = { model.discard(record.id) }, enabled = !busy,
            modifier = Modifier.testTag("photos_concepts_clear_record")) { Text(stringResource(R.string.sp_edit_clear_record)) }
        HorizontalDivider()
    }
}

internal fun SynologyPhotoAlbumAction.conceptLabel() = when (this) {
    SynologyPhotoAlbumAction.COVER_CONCEPT -> R.string.sp_concept_cover
    SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS -> R.string.sp_concept_remove
    else -> R.string.sp_concepts_visibility
}

@Composable
private fun conceptError(error: Throwable): String = when (error) {
    is SynologyPhotoAlbumFailure -> photoAlbumError(error)
    is SynologyPhotoFailure -> stringResource(when (error.kind) {
        SynologyPhotoFailureKind.PERMISSION -> R.string.sp_concepts_permission
        SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_concepts_changed
        else -> R.string.sp_concepts_failed
    })
    else -> stringResource(R.string.sp_concepts_failed)
}
