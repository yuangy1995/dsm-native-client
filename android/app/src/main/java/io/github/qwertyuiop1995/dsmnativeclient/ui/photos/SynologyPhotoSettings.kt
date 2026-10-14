package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import java.time.LocalDate
import java.time.format.DateTimeFormatter

@Composable
internal fun SynologyPhotoSettings(model: SynologyPhotoSettingsModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    ClientPageDialog(stringResource(if (state.recordsPage) R.string.sp_settings_records else state.target?.settingsLabel() ?: R.string.sp_settings_title), model::dismiss) {
        Column(Modifier.fillMaxSize()) {
            state.error?.let { Text(settingsError(it), Modifier.fillMaxWidth().padding(16.dp), color = MaterialTheme.colorScheme.error) }
            when {
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                state.recordsPage -> SettingsRecords(state, model)
                state.desired == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Button(onClick = { model.load() }) { Text(stringResource(R.string.sp_retry)) }
                }
                else -> {
                    Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp).testTag("photos_settings_form"),
                        verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        when (val value = state.desired) {
                            is SynologyPhotoAutomaticPreviewSettings -> {
                                SettingsSwitch(stringResource(R.string.sp_automatic_preview_enable), value.enabled, state.canEdit,
                                    "photos_settings_automatic_preview") { model.edit(value.copy(enabled = it)) }
                                Text(stringResource(R.string.sp_automatic_preview_scope), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            is SynologyPhotoDisplaySettings -> DisplaySettings(value, state.canEdit, model::edit)
                            is SynologyPhotoDuplicateSettings -> DuplicateSettings(value, state.canEdit, model::edit)
                            is SynologyPhotoRecognitionSettings -> RecognitionSettings(value, state.canEdit, model::edit)
                            is SynologyPhotoSharedSettings -> SharedSettings(value, state.canEdit, model::edit, model::changeSharedEnabled)
                            is SynologyPhotoGlobalSettings -> GlobalSettings(value, state, model)
                            is SynologyPhotoConversionCache -> ConversionCache(state, model)
                            is SynologyPhotoAlbumSortSettings, is SynologyPhotoAlbumListSortSettings, is SynologyPhotoAlbumDisplaySettings -> AlbumPreferenceSettings(value, state.canEdit, model::edit)
                            null -> Unit
                        }
                    }
                    if (state.desired !is SynologyPhotoConversionCache) {
                    HorizontalDivider()
                    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
                        Button(onClick = { model.save() }, enabled = model.canSave, modifier = Modifier.testTag("photos_settings_save")) { Text(stringResource(R.string.save_changes)) }
                    }
                    }
                }
            }
        }
    }
    if (state.confirmation != null) AlertDialog(onDismissRequest = model::cancelConfirmation,
        title = { Text(stringResource(if (state.confirmation?.globalProgress != null) R.string.sp_global_confirm else if (state.confirmation?.desired is SynologyPhotoSharedSettings) R.string.sp_shared_settings_confirm else R.string.sp_files_overwrite_title)) },
        text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            if (state.confirmation!!.globalProgress != null) GlobalSettingsConfirmation(state.confirmation!!)
            else Text(stringResource(state.confirmation!!.settingsConfirmation()))
        } },
        confirmButton = { TextButton(onClick = { model.confirm() }, modifier = Modifier.testTag("photos_settings_confirm")) { Text(stringResource(if (state.confirmation?.desired is SynologyPhotoConversionCache) R.string.sp_global_clear_cache else R.string.save_changes)) } },
        dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun DisplaySettings(value: SynologyPhotoDisplaySettings, enabled: Boolean, change: (SynologyPhotoSettings) -> Unit) {
    val locale = LocalConfiguration.current.locales[0]
    val dateOptions = SynologyPhotoDisplaySettings.Date.entries.map { it to LocalDate.of(2019, 12, 31).format(DateTimeFormatter.ofPattern(it.pattern, locale)) }
    SharingChoice(stringResource(R.string.sp_settings_grouping), stringResource(value.grouping.groupingLabel()),
        SynologyPhotoDisplaySettings.Grouping.entries.map { it to stringResource(it.groupingLabel()) }, enabled, "photos_settings_grouping") { change(value.copy(grouping = it)) }
    SharingChoice(stringResource(R.string.sp_settings_date), dateOptions.first { it.first == value.date }.second,
        dateOptions, enabled, "photos_settings_date") { change(value.copy(date = it)) }
    SharingChoice(stringResource(R.string.sp_settings_clock), stringResource(value.clock.clockLabel()),
        SynologyPhotoDisplaySettings.Clock.entries.map { it to stringResource(it.clockLabel()) }, enabled, "photos_settings_clock") { change(value.copy(clock = it)) }
    SharingChoice(stringResource(R.string.sp_settings_default_sort), stringResource(value.sort.field.folderLabel()),
        SynologyPhotoSort.Field.entries.map { it to stringResource(it.folderLabel()) }, enabled, "photos_settings_sort_field") { change(value.copy(sort = value.sort.copy(field = it))) }
    SharingChoice(stringResource(R.string.sp_folder_sort_direction), stringResource(value.sort.direction.folderLabel()),
        SynologyPhotoSort.Direction.entries.map { it to stringResource(it.folderLabel()) }, enabled, "photos_settings_sort_direction") { change(value.copy(sort = value.sort.copy(direction = it))) }
    SettingsSwitch(stringResource(R.string.sp_settings_show_info), value.showInfo, enabled, "photos_settings_show_info") { change(value.copy(showInfo = it)) }
}

@Composable
private fun DuplicateSettings(value: SynologyPhotoDuplicateSettings, enabled: Boolean, change: (SynologyPhotoSettings) -> Unit) {
    val uploads = SynologyPhotoUploadDuplicate.entries.map { it to stringResource(if (it == SynologyPhotoUploadDuplicate.IGNORE) R.string.sp_upload_skip else R.string.sp_upload_keep_both) }
    SharingChoice(stringResource(R.string.sp_settings_upload), uploads.first { it.first == value.upload }.second, uploads, enabled,
        "photos_settings_upload") { change(value.copy(upload = it)) }
    val transfers = SynologyPhotoTransferDuplicate.entries.map { it to stringResource(if (it == SynologyPhotoTransferDuplicate.SKIP) R.string.sp_files_skip else R.string.sp_files_replace) }
    SharingChoice(stringResource(R.string.sp_settings_transfer), transfers.first { it.first == value.transfer }.second, transfers, enabled,
        "photos_settings_transfer") { change(value.copy(transfer = it)) }
}

@Composable
private fun RecognitionSettings(value: SynologyPhotoRecognitionSettings, enabled: Boolean, change: (SynologyPhotoSettings) -> Unit) {
    if (!value.personalEnabled) Text(stringResource(R.string.sp_settings_home_disabled), color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (value.known.isEmpty()) Text(stringResource(R.string.sp_settings_recognition_empty), color = MaterialTheme.colorScheme.onSurfaceVariant)
    SynologyPhotoRecognition.entries.filter { it in value.known }.forEach { key ->
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            SettingsSwitch(stringResource(key.recognitionLabel()), value.personal[key] == true, enabled && key in value.editable,
                "photos_settings_recognition_${key.name}") { change(value.copy(personal = value.personal + (key to it))) }
            if (value.global[key] != true) Text(stringResource(R.string.sp_settings_admin_disabled), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
internal fun SettingsSwitch(label: String, value: Boolean, enabled: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(value, onChange, enabled = enabled, modifier = Modifier.testTag(tag).semantics { contentDescription = label })
    }
}

@Composable
private fun SettingsRecords(state: SynologyPhotoSettingsState, model: SynologyPhotoSettingsModel) {
    LazyColumn(Modifier.fillMaxSize().testTag("photos_settings_records"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (state.records.isEmpty() && !state.working) item { Text(stringResource(R.string.sp_settings_no_records)) }
        items(state.records, key = { it.id }) { record ->
            val row = record.checkpoint
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(row.settings!!.desired.target().settingsLabel()), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(when {
                    row.phase == SynologyPhotoAlbumPhase.PARTIAL && row.settings.globalProgress?.completed?.isNotEmpty() == true -> R.string.sp_global_partial
                    row.settings.rejected -> R.string.sp_settings_rejected
                    row.phase == SynologyPhotoAlbumPhase.COMPLETED -> R.string.sp_settings_done
                    row.submitted -> R.string.sp_settings_pending
                    else -> R.string.sp_request_not_sent
                }))
                if (state.working && state.activeId == record.id) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (!row.finished) Button(onClick = { model.resume(record.id) }, enabled = !state.working, modifier = Modifier.testTag("photos_settings_resume")) {
                    Text(stringResource(if (row.submitted) R.string.sp_edit_refresh else R.string.sp_request_reopen))
                }
                if (row.finished || !row.submitted) TextButton(onClick = { model.discard(record.id) }, enabled = !state.working) { Text(stringResource(R.string.sp_edit_clear_record)) }
                HorizontalDivider()
            }
        }
    }
}

internal fun SynologyPhotoSettingsKind.settingsLabel(): Int = when (this) {
    SynologyPhotoSettingsKind.AUTOMATIC_PREVIEWS -> R.string.sp_automatic_preview_title
    SynologyPhotoSettingsKind.DISPLAY -> R.string.sp_settings_display
    SynologyPhotoSettingsKind.DUPLICATES -> R.string.sp_settings_duplicates
    SynologyPhotoSettingsKind.RECOGNITION -> R.string.sp_settings_recognition
    SynologyPhotoSettingsKind.SHARED -> R.string.sp_shared_settings_title
    SynologyPhotoSettingsKind.GLOBAL -> R.string.sp_global_title
    SynologyPhotoSettingsKind.CACHE -> R.string.sp_global_cache
    SynologyPhotoSettingsKind.ALBUM_SORT -> R.string.sp_album_photo_sort
    SynologyPhotoSettingsKind.LIST_SORT -> R.string.sp_album_list_sort
    SynologyPhotoSettingsKind.LIST_DISPLAY -> R.string.sp_album_list_display
}
private fun SynologyPhotoDisplaySettings.Grouping.groupingLabel(): Int = if (this == SynologyPhotoDisplaySettings.Grouping.DAY) R.string.sp_settings_group_day else R.string.sp_settings_group_month
private fun SynologyPhotoDisplaySettings.Clock.clockLabel(): Int = if (this == SynologyPhotoDisplaySettings.Clock.TWELVE) R.string.sp_settings_clock_12 else R.string.sp_settings_clock_24
private fun SynologyPhotoRecognition.recognitionLabel(): Int = when (this) {
    SynologyPhotoRecognition.PEOPLE -> R.string.sp_settings_people
    SynologyPhotoRecognition.SUBJECTS -> R.string.sp_settings_subjects
    SynologyPhotoRecognition.SIMILAR -> R.string.sp_settings_similar
}
@Composable
private fun settingsError(error: Throwable): String = stringResource(when {
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.STORAGE -> R.string.sp_folder_storage_failed
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.BUSY -> R.string.sp_edit_busy
    error is SynologyPhotoAlbumFailure && error.problem == SynologyPhotoAlbumProblem.PENDING -> R.string.sp_settings_conflict
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_settings_changed
    error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.PERMISSION -> R.string.sp_settings_permission
    else -> R.string.sp_settings_failed
})
