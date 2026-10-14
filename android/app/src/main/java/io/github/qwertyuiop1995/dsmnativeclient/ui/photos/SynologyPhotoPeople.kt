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
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Person
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
internal fun personName(person: SynologyPhotoCollection): String = person.name.ifEmpty { stringResource(R.string.sp_person_unnamed) }

@Composable
internal fun PhotoPersonCardHeader(person: SynologyPhotoCollection, model: SynologyPhotoPeopleModel?) {
    Box(Modifier.fillMaxWidth()) {
        PersonCover(person, model, Modifier.fillMaxWidth().aspectRatio(1f))
        if (model?.available(person.space) == true) {
            val state by model.state.collectAsState(); var expanded by remember(person.id, person.space) { mutableStateOf(false) }
            Box(Modifier.align(Alignment.TopEnd).background(MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.9f))) {
                IconButton(onClick = { expanded = true }, enabled = !state.working, modifier = Modifier.testTag("photos_person_actions_${person.id}")) {
                    Icon(Icons.Outlined.MoreVert, stringResource(R.string.sp_person_actions, personName(person)))
                }
                DropdownMenu(expanded, { expanded = false }) {
                    listOf(SynologyPhotoAlbumAction.RENAME_PERSON, SynologyPhotoAlbumAction.MERGE_PEOPLE, SynologyPhotoAlbumAction.SHOW_PEOPLE).forEach { action ->
                        if (model.available(person.space, action == SynologyPhotoAlbumAction.MERGE_PEOPLE)) DropdownMenuItem(
                            text = { Text(stringResource(action.peopleLabel())) }, modifier = Modifier.testTag("photos_person_menu_${action.name}"),
                            onClick = { expanded = false; model.open(action, person.space, person) })
                    }
                }
            }
        }
    }
}

@Composable
private fun PersonCover(person: SynologyPhotoCollection, model: SynologyPhotoPeopleModel?, modifier: Modifier) {
    val bitmap by produceState<Bitmap?>(null, person.id, person.space, person.personCover, model) {
        value = null
        if (model != null && person.personCover != null) try { value = PhotoBitmapDecoder.decode(model.thumbnail(person), 512) }
        catch (error: Exception) { if (error is CancellationException) throw error }
    }
    Box(modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
        val image = bitmap
        if (image == null) Icon(Icons.Outlined.Person, null)
        else Image(image.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    }
}

@Composable
internal fun SynologyPhotoPeople(model: SynologyPhotoPeopleModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    if (state.action.isPersonFaces) { SynologyPhotoPersonFaces(model, state); return }
    val number = NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0])
    ClientPageDialog(stringResource(state.action.peopleLabel()), model::dismiss) {
        if (state.loading && !state.loaded && state.records.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        else LazyColumn(Modifier.fillMaxSize().testTag("photos_people_list"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { model.save() }, enabled = state.canSave, modifier = Modifier.testTag("photos_people_save")) {
                        Text(stringResource(if (state.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) R.string.sp_people_merge else R.string.save_changes))
                    }
                    OutlinedButton(onClick = { model.load() }, enabled = !state.loading && !state.working && state.confirmation == null,
                        modifier = Modifier.testTag("photos_people_refresh")) { Text(stringResource(R.string.sp_edit_refresh)) }
                }
            }
            if (state.loading || state.working) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            state.error?.let { error -> item { Text(peopleError(error), color = MaterialTheme.colorScheme.error) } }
            if (state.loaded) {
                if (state.action != SynologyPhotoAlbumAction.SHOW_PEOPLE) item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (state.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) state.target?.let { Text(stringResource(R.string.sp_people_merge_target, personName(it))) }
                        OutlinedTextField(state.name, model::name, enabled = !state.working && state.confirmation == null,
                            label = { Text(stringResource(R.string.sp_person_name)) }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("photos_person_name"))
                    }
                }
                if (state.action != SynologyPhotoAlbumAction.RENAME_PERSON) {
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (state.action == SynologyPhotoAlbumAction.SHOW_PEOPLE) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                listOf(true, false).forEach { shown -> FilterChip(state.desiredVisibility == shown, onClick = { model.visibility(shown) },
                                    label = { Text(stringResource(if (shown) R.string.sp_people_show else R.string.sp_people_hide)) },
                                    enabled = !state.working && state.confirmation == null,
                                    modifier = Modifier.heightIn(min = 48.dp).testTag("photos_people_visibility_$shown")) }
                            }
                            OutlinedTextField(state.query, model::search, enabled = !state.working && state.confirmation == null,
                                label = { Text(stringResource(R.string.sp_people_search)) }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("photos_people_search"))
                            Text(stringResource(R.string.sp_people_selected, number.format(state.selected.size),
                                number.format(if (state.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) 99 else 100)), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    if (state.filtered.isEmpty()) item { Text(stringResource(if (state.query.isNotBlank()) R.string.sp_people_search_empty else R.string.sp_people_empty),
                        Modifier.fillMaxWidth().padding(vertical = 24.dp)) }
                    items(state.filtered, key = { "person:${it.id}" }) { person -> PeopleChoice(person, state, model) }
                }
            }
            if (state.records.isNotEmpty()) item { Text(stringResource(R.string.sp_people_records), style = MaterialTheme.typography.titleMedium) }
            items(state.records, key = { it.id }) { record -> PeopleRecord(record, state.working || state.loading, model) }
        }
    }
    state.confirmation?.let { checkpoint ->
        val value = checkpoint.people!!
        AlertDialog(onDismissRequest = model::cancelConfirmation, title = { Text(stringResource(checkpoint.action.peopleLabel())) },
            text = { Text(stringResource(if (checkpoint.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) R.string.sp_people_merge_risk else R.string.sp_person_clear_risk,
                number.format(value.originals.size - 1), value.name!!.ifEmpty { stringResource(R.string.sp_person_unnamed) }), Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = { model.confirm() }, enabled = !state.working, modifier = Modifier.testTag("photos_people_confirm")) {
                Text(stringResource(if (checkpoint.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) R.string.sp_people_merge else R.string.save_changes))
            } }, dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun PeopleChoice(person: SynologyPhotoCollection, state: SynologyPhotoPeopleState, model: SynologyPhotoPeopleModel) {
    val selected = person.id in state.selected
    val limit = if (state.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) 99 else 100
    val enabled = !state.working && !state.loading && state.confirmation == null && (selected || state.selected.size < limit) &&
        (state.action != SynologyPhotoAlbumAction.SHOW_PEOPLE || person.personVisible != state.desiredVisibility)
    ListItem(headlineContent = { Text(personName(person)) }, leadingContent = { PersonCover(person, model, Modifier.size(48.dp)) },
        supportingContent = {
            Column {
                person.count?.let { Text(pluralStringResource(R.plurals.sp_people_photo_count, it, NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0]).format(it))) }
                if (state.action == SynologyPhotoAlbumAction.SHOW_PEOPLE) Text(stringResource(if (person.personVisible == true) R.string.sp_people_shown else R.string.sp_people_hidden))
            }
        }, trailingContent = { Checkbox(selected, null, enabled = enabled) }, modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp)
            .toggleable(selected, enabled = enabled, role = Role.Checkbox, onValueChange = { model.toggle(person.id) }).testTag("photos_people_select_${person.id}"))
}

@Composable
internal fun PeopleRecord(record: SynologyPhotoAlbumRecord, busy: Boolean, model: SynologyPhotoPeopleModel) {
    val row = record.checkpoint; val value = row.people!!
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(row.action.peopleLabel()), style = MaterialTheme.typography.titleSmall)
        Text(stringResource(when {
            row.phase == SynologyPhotoAlbumPhase.COMPLETED -> R.string.sp_people_saved
            value.rejected -> R.string.sp_people_rejected
            !row.submitted || !value.attempted -> R.string.sp_people_not_sent
            row.phase == SynologyPhotoAlbumPhase.PARTIAL -> R.string.sp_people_partial
            else -> R.string.sp_people_pending
        }))
        if (row.submitted && !row.finished) OutlinedButton(onClick = { model.resume(record.id) }, enabled = !busy,
            modifier = Modifier.testTag("photos_people_review")) { Text(stringResource(R.string.sp_edit_refresh)) }
        else TextButton(onClick = { model.discard(record.id) }, enabled = !busy,
            modifier = Modifier.testTag("photos_people_clear_record")) { Text(stringResource(R.string.sp_edit_clear_record)) }
        HorizontalDivider()
    }
}

internal fun SynologyPhotoAlbumAction.peopleLabel() = when (this) {
    SynologyPhotoAlbumAction.RENAME_PERSON -> R.string.sp_person_rename
    SynologyPhotoAlbumAction.MERGE_PEOPLE -> R.string.sp_people_merge
    SynologyPhotoAlbumAction.REMOVE_PERSON_FACES -> R.string.sp_person_faces_remove
    SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES -> R.string.sp_person_faces_reassign
    SynologyPhotoAlbumAction.COVER_PERSON -> R.string.sp_person_cover
    else -> R.string.sp_people_visibility
}

@Composable
internal fun peopleError(error: Throwable): String = when (error) {
    is SynologyPhotoAlbumFailure -> photoAlbumError(error)
    is SynologyPhotoFailure -> stringResource(when (error.kind) {
        SynologyPhotoFailureKind.PERMISSION -> R.string.sp_people_permission
        SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_people_changed
        else -> R.string.sp_people_failed
    })
    else -> stringResource(R.string.sp_people_failed)
}
