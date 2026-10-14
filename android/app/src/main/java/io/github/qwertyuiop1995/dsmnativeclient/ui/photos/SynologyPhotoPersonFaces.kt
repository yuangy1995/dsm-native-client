package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
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
internal fun PhotoPersonSelectionActions(model: SynologyPhotoPeopleModel, navigation: SynologyPhotoNavigation,
    photos: List<SynologyPhoto>, enabled: Boolean) {
    val person = navigation.categoryItem ?: return
    if (navigation.category != SynologyPhotoCategory.PEOPLE || navigation.album != null || !model.facesAvailable(person.space)) return
    var expanded by remember(person.id, person.space) { mutableStateOf(false) }
    Box {
        TextButton(onClick = { expanded = true }, enabled = enabled && photos.size in 1..100 && photos.all { it.id.space == person.space && it.albumContext == null },
            modifier = Modifier.testTag("photos_person_selection_actions")) { Text(stringResource(R.string.sp_person_faces_manage)) }
        DropdownMenu(expanded, { expanded = false }) {
            listOf(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, SynologyPhotoAlbumAction.COVER_PERSON).forEach { action ->
                DropdownMenuItem(text = { Text(stringResource(action.peopleLabel())) }, enabled = action != SynologyPhotoAlbumAction.COVER_PERSON || photos.size == 1,
                    onClick = { expanded = false; model.openFaces(action, person, photos) }, modifier = Modifier.testTag("photos_person_selection_${action.name}"))
            }
        }
    }
}

@Composable
internal fun SynologyPhotoPersonFaces(model: SynologyPhotoPeopleModel, state: SynologyPhotoPeopleState) {
    val number = NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0])
    val covering = state.action == SynologyPhotoAlbumAction.COVER_PERSON
    val moving = state.action == SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES
    val editable = state.loaded && !state.loading && !state.working && state.confirmation == null
    ClientPageDialog(stringResource(state.action.peopleLabel()), model::dismiss) {
        if (state.loading && !state.loaded && state.records.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        else LazyColumn(Modifier.fillMaxSize().testTag("photos_faces_list"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { model.save() }, enabled = state.canSave, modifier = Modifier.testTag("photos_faces_save")) {
                        Text(stringResource(if (covering) R.string.save_changes else state.action.peopleLabel()))
                    }
                    OutlinedButton(onClick = { model.load() }, enabled = !state.loading && !state.working && state.confirmation == null,
                        modifier = Modifier.testTag("photos_faces_refresh")) { Text(stringResource(R.string.sp_edit_refresh)) }
                }
            }
            if (state.loading || state.working) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            state.error?.let { error -> item { Text(peopleError(error), color = MaterialTheme.colorScheme.error) } }
            if (state.loaded) {
                state.target?.let { target -> item { Text(stringResource(R.string.sp_person_faces_source, personName(target)), style = MaterialTheme.typography.titleMedium) } }
                if (state.faces.isEmpty()) item { Text(stringResource(R.string.sp_person_faces_empty), Modifier.fillMaxWidth().padding(vertical = 24.dp)) }
                else {
                    if (!covering) item { Text(pluralStringResource(R.plurals.sp_person_faces_selected, state.selectedFaces.size, number.format(state.selectedFaces.size)), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    itemsIndexed(state.faces, key = { _, face -> face.id }) { index, face ->
                        val photo = state.photos.firstOrNull { it.id == face.photoId }
                        val selected = face.id in state.selectedFaces
                        val label = stringResource(R.string.sp_person_face_label, photo?.filename.orEmpty(), number.format(index + 1))
                        ListItem(headlineContent = { Text(label) }, leadingContent = { FaceThumbnail(face, model) },
                            trailingContent = if (covering) null else ({ Checkbox(selected, null, enabled = editable) }),
                            modifier = if (covering) Modifier.fillMaxWidth().heightIn(min = 72.dp).testTag("photos_face_${face.id}")
                                else Modifier.fillMaxWidth().heightIn(min = 72.dp).toggleable(selected, enabled = editable, role = Role.Checkbox,
                                    onValueChange = { model.toggleFace(face.id) }).testTag("photos_face_${face.id}"))
                    }
                }
                if (moving) {
                    item { HorizontalDivider(); Text(stringResource(R.string.sp_person_faces_target), style = MaterialTheme.typography.titleMedium) }
                    item { ListItem(headlineContent = { Text(stringResource(R.string.sp_person_faces_new)) },
                        trailingContent = { RadioButton(state.destination == null, null, enabled = editable) },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).selectable(state.destination == null, enabled = editable, role = Role.RadioButton,
                            onClick = { model.destination(null) }).testTag("photos_faces_new")) }
                    if (state.destination == null) item { OutlinedTextField(state.name, model::name, enabled = editable, label = { Text(stringResource(R.string.sp_person_name)) },
                        singleLine = true, modifier = Modifier.fillMaxWidth().testTag("photos_faces_name")) }
                    item { OutlinedTextField(state.query, model::search, enabled = editable, label = { Text(stringResource(R.string.sp_people_search)) },
                        singleLine = true, modifier = Modifier.fillMaxWidth().testTag("photos_faces_search")) }
                    if (state.filtered.isEmpty()) item { Text(stringResource(if (state.query.isNotBlank()) R.string.sp_people_search_empty else R.string.sp_people_empty)) }
                    items(state.filtered, key = { "target:${it.id}" }) { target -> ListItem(headlineContent = { Text(personName(target)) },
                        trailingContent = { RadioButton(state.destination == target.id, null, enabled = editable) },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).selectable(state.destination == target.id, enabled = editable, role = Role.RadioButton,
                            onClick = { model.destination(target.id) }).testTag("photos_faces_target_${target.id}")) }
                }
            }
            if (state.records.isNotEmpty()) item { Text(stringResource(R.string.sp_people_records), style = MaterialTheme.typography.titleMedium) }
            items(state.records, key = { it.id }) { PeopleRecord(it, state.loading || state.working, model) }
        }
    }
    state.confirmation?.let { row ->
        val source = row.people!!.originals.first().name.ifEmpty { stringResource(R.string.sp_person_unnamed) }
        val target = row.people.name.orEmpty().ifEmpty { stringResource(R.string.sp_person_unnamed) }
        AlertDialog(onDismissRequest = model::cancelConfirmation, title = { Text(stringResource(row.action.peopleLabel())) },
            text = { Text(stringResource(if (row.action == SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES) R.string.sp_person_faces_reassign_risk else R.string.sp_person_faces_remove_risk,
                source, target), Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = { model.confirm() }, enabled = !state.working, modifier = Modifier.testTag("photos_faces_confirm")) { Text(stringResource(row.action.peopleLabel())) } },
            dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun FaceThumbnail(face: SynologyPhotoPersonFace, model: SynologyPhotoPeopleModel) {
    val bitmap by produceState<Bitmap?>(null, face, model) {
        value = null
        if (face.revision != null) try { value = PhotoBitmapDecoder.decode(model.faceThumbnail(face), 256) }
        catch (error: Exception) { if (error is CancellationException) throw error }
    }
    Box(Modifier.size(56.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
        val image = bitmap
        if (image == null) Icon(Icons.Outlined.Person, null) else Image(image.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    }
}
