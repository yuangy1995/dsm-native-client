package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.ui.platform.LocalResources
import android.content.ClipData
import android.content.Intent
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Description
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
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun OfficeDocumentDialog(feature: OfficeDocumentFeatureModel, profile: NasProfile, profiles: List<NasProfile>) {
    val state by feature.state.collectAsStateWithLifecycle()
    if (!state.visible) return
    val context = LocalContext.current
    val resources = LocalResources.current
    val row = state.selected
    val connection = connectionConfirmationName(context, profile, profiles)
    val enabled = !state.busy && state.picker == null
    ClientPageDialog(row?.baseline?.name ?: state.preparingItem?.name ?: stringResource(R.string.office_copies), {
        if (state.selectedId != null) feature.back() else feature.dismiss()
    }) {
        Column(Modifier.fillMaxSize().testTag("office_dialog")) {
            if (state.busy) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                TextButton(feature::cancel, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_cancel")) { Text(stringResource(R.string.cancel)) }
            }
            when (val records = state.records) {
                Loadable.Idle, Loadable.Loading -> Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) { CircularProgressIndicator() }
                is Loadable.Failed -> Column(Modifier.weight(1f).fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.Center) {
                    Text(records.error.localize(context).combined, color = MaterialTheme.colorScheme.error)
                    OutlinedButton(feature::refresh, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.retry)) }
                }
                is Loadable.Ready -> if (records.value.isEmpty() && row == null && state.failure == null) {
                    Box(Modifier.weight(1f).fillMaxWidth()) { EmptyState(stringResource(R.string.office_empty),
                        stringResource(R.string.office_empty_hint), Icons.Outlined.Description) }
                } else LazyColumn(Modifier.weight(1f).testTag("office_content"), contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (row == null) {
                        item { OfficeFeedback(state) }
                        if (state.selectedId != null) item { Text(stringResource(R.string.office_record_missing)) }
                        items(records.value, key = { it.id }) { document -> ClientGroup {
                            ClientRow(document.baseline.name, Icons.Outlined.Description,
                                detail = stringResource(if (document.externalId != null) R.string.office_external_editing else officePhaseLabel(document.phase)), enabled = enabled) { feature.select(document.id) }
                        } }
                        if (state.failure != null) item { OutlinedButton(feature::refresh, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_retry")) { Text(stringResource(R.string.retry)) } }
                    } else {
                        item { ClientGroup { Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(connection, style = MaterialTheme.typography.titleMedium)
                            Text(stringResource(R.string.office_original, row.baseline.path), style = MaterialTheme.typography.bodyMedium)
                            Text(stringResource(if (row.externalId != null) R.string.office_external_editing else officePhaseLabel(if (state.saving) OfficeDocumentPhase.SAVING else row.phase)), Modifier.testTag("office_phase"))
                            if (row.externalId != null) Text(stringResource(R.string.office_external_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (row.phase == OfficeDocumentPhase.UNKNOWN) Text(stringResource(R.string.office_unknown_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (row.phase == OfficeDocumentPhase.CONFLICT) Text(stringResource(R.string.office_changed_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (state.busy && state.totalBytes > 0) {
                                LinearProgressIndicator(progress = { (state.completedBytes.toDouble() / state.totalBytes).coerceIn(0.0, 1.0).toFloat() }, Modifier.fillMaxWidth())
                                Text(stringResource(R.string.transfer_bytes_progress, Formatter.formatFileSize(context, state.completedBytes), Formatter.formatFileSize(context, state.totalBytes)))
                            }
                        } } }
                        item { OfficeFeedback(state) }
                        if (row.canSave) item { Button(feature::requestSave, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_save"), enabled = enabled) { Text(stringResource(R.string.office_save)) } }
                        if (row.phase == OfficeDocumentPhase.UNKNOWN) item { OutlinedButton(feature::refresh,
                            Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_refresh"), enabled = enabled) { Text(stringResource(R.string.refresh)) } }
                        if (row.externalId != null) item { OutlinedButton(feature::receiveExternal,
                            Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_receive_external"), enabled = enabled) { Text(stringResource(R.string.office_receive_external)) } }
                        if (row.externalId == null) item { OutlinedButton({ feature.requestPicker(OfficePickerKind.OPEN) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_open"), enabled = enabled) { Text(stringResource(R.string.office_open)) } }
                        if (row.canImport) {
                            item { OutlinedButton({ feature.requestPicker(OfficePickerKind.EDIT) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_edit"), enabled = enabled) { Text(stringResource(R.string.office_edit)) } }
                            item { OutlinedButton({ feature.requestPicker(OfficePickerKind.IMPORT) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_import"), enabled = enabled) { Text(stringResource(R.string.office_import)) } }
                        }
                        if (row.externalId == null) item { OutlinedButton({ feature.requestPicker(OfficePickerKind.EXPORT) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_export"), enabled = enabled) { Text(stringResource(R.string.office_export)) } }
                        if (!row.uncertain) item { TextButton(feature::requestDiscard, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("office_finish"), enabled = enabled) { Text(stringResource(R.string.office_finish)) } }
                    }
                }
            }
        }
    }
    if (row != null && state.confirmSave) AlertDialog(onDismissRequest = feature::dismissConfirmation,
        title = { Text(stringResource(R.string.office_save)) }, text = { Text(stringResource(R.string.office_save_confirm, row.baseline.name, connection)) },
        confirmButton = { TextButton(feature::save, Modifier.heightIn(min = 48.dp).testTag("office_confirm_save")) { Text(stringResource(R.string.office_save)) } },
        dismissButton = { TextButton(feature::dismissConfirmation, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) } })
    if (row != null && state.confirmDiscard) AlertDialog(onDismissRequest = feature::dismissConfirmation,
        title = { Text(stringResource(R.string.office_finish)) }, text = { Text(if (row.externalId != null || row.phase in setOf(OfficeDocumentPhase.CHANGED, OfficeDocumentPhase.CONFLICT))
            stringResource(R.string.office_finish_confirm, row.baseline.name) else stringResource(R.string.office_local_only_hint)) },
        confirmButton = { TextButton(feature::discard, Modifier.heightIn(min = 48.dp).testTag("office_confirm_finish")) { Text(stringResource(R.string.office_finish)) } },
        dismissButton = { TextButton(feature::dismissConfirmation, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) } })
    OfficeSystemPicker(state, feature)
    state.exported?.let { exported -> LaunchedEffect(exported.request.token) {
        var opened = true
        if (exported.request.kind != OfficePickerKind.EXPORT) {
            try { context.startActivity(Intent.createChooser(officeExternalIntent(exported), resources.getString(R.string.office_open))) }
            catch (_: android.content.ActivityNotFoundException) { opened = false }
            catch (_: SecurityException) { opened = false }
        }
        feature.consumeExport(exported.request.token, opened)
    } }
}

@Composable
private fun OfficeSystemPicker(state: OfficeDocumentViewState, feature: OfficeDocumentFeatureModel) {
    state.picker?.let { request -> key(request.token) {
        var launched by rememberSaveable(request.token) { mutableStateOf(false) }
        // 每个请求独立注册，切换账号后旧选择器结果不能进入新请求。
        if (request.kind == OfficePickerKind.IMPORT) {
            val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { feature.pickerResult(request.token, it) }
            LaunchedEffect(request.token) {
                if (launched) return@LaunchedEffect
                launched = true
                try { launcher.launch(arrayOf(OfficeDocumentPolicy.mime(request.name))) }
                catch (_: android.content.ActivityNotFoundException) { feature.pickerUnavailable(request.token) }
            }
        } else {
            val launcher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(OfficeDocumentPolicy.mime(request.name))) { feature.pickerResult(request.token, it) }
            LaunchedEffect(request.token) {
                if (launched) return@LaunchedEffect
                launched = true
                try { launcher.launch(request.name) }
                catch (_: android.content.ActivityNotFoundException) { feature.pickerUnavailable(request.token) }
            }
        }
    } }
}

internal fun officeExternalIntent(exported: OfficeExportResult) = Intent(
    if (exported.request.kind == OfficePickerKind.EDIT) Intent.ACTION_EDIT else Intent.ACTION_VIEW,
).apply {
    setDataAndType(exported.uri, OfficeDocumentPolicy.mime(exported.request.name))
    clipData = ClipData.newRawUri(exported.request.name, exported.uri)
    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    if (exported.request.kind == OfficePickerKind.EDIT) addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
}

@Composable
private fun OfficeFeedback(state: OfficeDocumentViewState) {
    state.failure?.takeUnless { it.kind == io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.OFFICE_CHANGED && state.selected?.phase == OfficeDocumentPhase.CONFLICT }
        ?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
    state.notice?.takeUnless { it == R.string.office_external_hint && state.selected?.externalId != null }
        ?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.onSurfaceVariant) }
}
internal fun officePhaseLabel(phase: OfficeDocumentPhase) = when (phase) {
    OfficeDocumentPhase.READY -> R.string.office_ready
    OfficeDocumentPhase.CHANGED -> R.string.office_changed_status
    OfficeDocumentPhase.UNCHANGED -> R.string.office_unchanged
    OfficeDocumentPhase.SAVING -> R.string.office_saving
    OfficeDocumentPhase.SAVED -> R.string.office_saved
    OfficeDocumentPhase.CONFLICT -> R.string.office_changed
    OfficeDocumentPhase.UNKNOWN -> R.string.office_unknown
}
