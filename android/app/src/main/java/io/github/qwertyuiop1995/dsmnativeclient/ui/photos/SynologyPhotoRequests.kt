package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.app.DatePickerDialog
import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@Composable
internal fun SynologyPhotoRequests(model: SynologyPhotoRequestModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    val title = when (state.page) {
        SynologyPhotoRequestPage.RECORDS -> R.string.sp_request_records
        SynologyPhotoRequestPage.FOLDERS -> R.string.sp_request_choose_folder
        SynologyPhotoRequestPage.ALBUMS -> R.string.sp_request_choose_album
        SynologyPhotoRequestPage.FORM -> if (state.draft?.deleting == true) R.string.sp_request_delete else if (state.draft?.original != null) R.string.sp_request_edit else R.string.sp_request_create
    }
    ClientPageDialog(stringResource(title), {
        if (!state.working && state.page in setOf(SynologyPhotoRequestPage.FOLDERS, SynologyPhotoRequestPage.ALBUMS)) model.backToForm() else model.dismiss()
    }) {
        Column(Modifier.fillMaxSize()) {
            state.error?.let { Text(photoRequestError(it), Modifier.fillMaxWidth().padding(16.dp), color = MaterialTheme.colorScheme.error) }
            when {
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                state.page == SynologyPhotoRequestPage.FOLDERS -> PhotoRequestFolders(state, model)
                state.page == SynologyPhotoRequestPage.ALBUMS -> PhotoRequestAlbums(state, model)
                state.page == SynologyPhotoRequestPage.RECORDS -> RequestRecords(state, model)
                else -> RequestForm(state, model)
            }
        }
    }
}

@Composable
private fun ColumnScope.RequestForm(state: SynologyPhotoRequestState, model: SynologyPhotoRequestModel) {
    val draft = state.draft
    if (draft == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Button(onClick = { model.load() }) { Text(stringResource(R.string.sp_retry)) } }
        return
    }
    val enabled = !state.working
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_request_form"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (draft.deleting) {
            item { Text(draft.original!!.settings.subject, style = MaterialTheme.typography.titleMedium) }
            item { Text(stringResource(R.string.sp_request_delete_note)) }
        } else {
            item { OutlinedTextField(draft.settings.subject, model::subject, Modifier.fillMaxWidth().testTag("photos_request_subject"),
                label = { Text(stringResource(R.string.sp_request_subject)) }, singleLine = true, enabled = enabled,
                isError = draft.settings.subject.trim().length > 50,
                supportingText = if (draft.settings.subject.trim().length > 50) ({ Text(stringResource(R.string.sp_request_subject_limit)) }) else null,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next)) }
            item { OutlinedTextField(draft.settings.description, model::description, Modifier.fillMaxWidth().testTag("photos_request_description"),
                label = { Text(stringResource(R.string.sp_request_description)) }, enabled = enabled, minLines = 2,
                isError = draft.settings.description.length > 100,
                supportingText = if (draft.settings.description.length > 100) ({ Text(stringResource(R.string.sp_request_description_limit)) }) else null,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() })) }
            if (model.spaces.size > 1) item {
                SharingChoice(stringResource(R.string.sp_request_destination), stringResource(draft.settings.space.sourceLabel()),
                    model.spaces.map { it to stringResource(it.sourceLabel()) }, enabled, "photos_request_source", model::changeSpace)
            }
            if (model.canUseDefault) item { RequestToggle(stringResource(R.string.sp_request_default_folder), draft.usesDefaultFolder, enabled, "photos_request_default_folder", model::useDefaultFolder) }
            item {
                Text(stringResource(R.string.sp_request_save_to), style = MaterialTheme.typography.labelLarge)
                val path = if (draft.usesDefaultFolder) SynologyPhotoRequestSettings.defaultFolderPath(draft.settings.subject) else draft.settings.folderPath
                if (path.isNotEmpty()) Text(path)
                if (draft.original?.isFolderValid == false && !draft.usesDefaultFolder && draft.settings.space == draft.original.settings.space && draft.settings.folderId == draft.original.settings.folderId)
                    Text(stringResource(R.string.sp_request_invalid_folder), color = MaterialTheme.colorScheme.error)
                OutlinedButton(onClick = { focus.clearFocus(); keyboard?.hide(); model.folders() }, enabled = enabled,
                    modifier = Modifier.fillMaxWidth().testTag("photos_request_folders")) { Text(stringResource(R.string.sp_request_choose_folder)) }
            }
            item {
                val choice = state.albums.firstOrNull { it.albumId == draft.settings.albumId && it.passphrase == draft.settings.albumPassphrase }
                val hasAlbum = draft.settings.albumId != null || draft.settings.albumPassphrase != null
                val title = choice?.name ?: draft.original?.albumName?.takeIf { it.isNotEmpty() && hasAlbum &&
                    draft.settings.albumId == draft.original.settings.albumId && draft.settings.albumPassphrase == draft.original.settings.albumPassphrase }
                Text(stringResource(R.string.sp_request_album), style = MaterialTheme.typography.labelLarge)
                Text(title ?: stringResource(if (draft.settings.albumId != null || draft.settings.albumPassphrase != null) R.string.sp_request_current_album else R.string.sp_request_no_album))
                OutlinedButton(onClick = { focus.clearFocus(); keyboard?.hide(); model.selectAlbums() }, enabled = enabled,
                    modifier = Modifier.fillMaxWidth().testTag("photos_request_albums")) { Text(stringResource(R.string.sp_request_choose_album)) }
                if (choice?.shared == false) Text(stringResource(R.string.sp_request_private_album), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            item { RequestToggle(stringResource(R.string.sp_request_limit_size), draft.limitsSize, enabled, "photos_request_limit_size", model::limitsSize) }
            if (draft.limitsSize) item { OutlinedTextField(draft.sizeMiB, model::size, Modifier.fillMaxWidth().testTag("photos_request_size"),
                label = { Text(stringResource(R.string.sp_request_size)) }, singleLine = true, enabled = enabled,
                isError = draft.sizeMiB.toIntOrNull()?.let { it !in 1..3000 } != false,
                supportingText = { Text(stringResource(R.string.sp_request_size_range)) }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() })) }
            item { RequestExpiration(draft.settings.expiration, enabled, model::expiration) }
            if (draft.original?.settings == draft.settings && !draft.sizeEdited && !draft.usesDefaultFolder) draft.original.url?.let { url -> item { RequestLink(url, enabled) } }
        }
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
        Button(onClick = { focus.clearFocus(); keyboard?.hide(); model.save() }, enabled = model.canSave, modifier = Modifier.testTag("photos_request_save")) {
            Text(stringResource(if (draft.deleting) R.string.sp_request_delete else if (draft.original == null) R.string.sp_request_create else R.string.save_changes))
        }
    }
}

@Composable
private fun RequestExpiration(seconds: Long, enabled: Boolean, change: (Long) -> Unit) {
    val context = LocalContext.current; val locale = LocalConfiguration.current.locales[0]; val zone = ZoneId.systemDefault()
    val format = remember(locale, zone) { DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale).withZone(zone) }
    val displayed = if (seconds == 0L) stringResource(R.string.sp_sharing_no_expiration) else runCatching { format.format(Instant.ofEpochSecond(seconds)) }.getOrElse { stringResource(R.string.sp_sharing_expiration_unknown) }
    SharingChoice(stringResource(R.string.sp_sharing_expiration), displayed, listOf(0 to stringResource(R.string.sp_sharing_no_expiration),
        1 to stringResource(R.string.sp_sharing_choose_date)), enabled, "photos_request_expiration") { value ->
        if (value == 0) change(0) else {
            val initial = runCatching { Instant.ofEpochSecond(seconds).atZone(zone).toLocalDate() }.getOrNull()?.takeIf { seconds > 0 } ?: LocalDate.now(zone)
            DatePickerDialog(context, { _, year, month, day -> change(photoSharingExpiration(LocalDate.of(year, month + 1, day), zone)) },
                initial.year, initial.monthValue - 1, initial.dayOfMonth).apply { datePicker.minDate = LocalDate.now(zone).atStartOfDay(zone).toInstant().toEpochMilli() }.show()
        }
    }
}

@Composable
private fun ColumnScope.RequestRecords(state: SynologyPhotoRequestState, model: SynologyPhotoRequestModel) {
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_request_records"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        state.result?.url?.let { item { Text(state.result.settings.subject, style = MaterialTheme.typography.titleMedium); RequestLink(it, !state.working) } }
        if (state.records.isEmpty() && !state.working) item { Text(stringResource(R.string.sp_request_no_records)) }
        items(state.records, key = { it.id }) { record ->
            val row = record.checkpoint
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(when (row.action) {
                    SynologyPhotoAlbumAction.CREATE_REQUEST -> R.string.sp_request_create
                    SynologyPhotoAlbumAction.DELETE_REQUEST -> R.string.sp_request_delete
                    else -> R.string.sp_request_edit
                }), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(if (row.finished) R.string.sp_request_done else if (row.submitted) R.string.sp_request_pending else R.string.sp_request_not_sent))
                if (state.working && state.activeId == row.operationId) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (!row.finished) Button(onClick = { model.resume(row.operationId) }, enabled = !state.working, modifier = Modifier.testTag("photos_request_resume")) {
                    Text(stringResource(if (row.submitted) R.string.sp_edit_refresh else R.string.sp_request_reopen))
                }
                if (row.finished && row.action != SynologyPhotoAlbumAction.DELETE_REQUEST) OutlinedButton(onClick = { model.reopen(record) }, enabled = !state.working) {
                    Text(stringResource(R.string.sp_request_edit))
                }
                if (row.finished || !row.submitted) TextButton(onClick = { model.discard(record.id) }, enabled = !state.working) { Text(stringResource(R.string.sp_edit_clear_record)) }
                HorizontalDivider()
            }
        }
    }
}

@Composable
internal fun RequestToggle(label: String, checked: Boolean, enabled: Boolean, tag: String, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag).toggleable(checked, enabled = enabled, role = Role.Checkbox, onValueChange = change), verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked, null); Text(label, Modifier.weight(1f).padding(start = 8.dp))
    }
}
@Composable
private fun RequestLink(url: String, enabled: Boolean) {
    val clipboard = LocalClipboardManager.current; val context = LocalContext.current
    OutlinedButton(onClick = { clipboard.setText(AnnotatedString(url)); Toast.makeText(context, R.string.share_link_existing_copied, Toast.LENGTH_SHORT).show() },
        enabled = enabled, modifier = Modifier.fillMaxWidth().testTag("photos_request_copy")) { Text(stringResource(R.string.sp_copy_link)) }
}
private fun SynologyPhotoSpace.sourceLabel() = if (this == SynologyPhotoSpace.PERSONAL) R.string.sp_source_personal else R.string.sp_source_shared
@Composable
internal fun photoRequestError(error: Throwable): String = when {
    error is SynologyPhotoAlbumFailure -> photoAlbumError(error)
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.PERMISSION -> stringResource(R.string.sp_request_permission)
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED -> stringResource(R.string.sp_request_changed)
    else -> stringResource(R.string.sp_request_failed)
}
