package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch

@Composable
internal fun SynologyPhotoExport(model: SynologyPhotoExportModel) {
    val state by model.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pendingFile by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingDirectory by rememberSaveable { mutableStateOf<String?>(null) }
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val id = pendingFile
        pendingFile = null
        if (id != null) {
            if (uri == null) model.pickerCancelled(id)
            else {
                val destination = SynologyPhotoDocumentDestination(context.contentResolver, uri, false)
                if (model.deliver(id, destination, context.cacheDir) == null) scope.launch(NonCancellable) { destination.abandon() }
            }
        }
    }
    val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        val id = pendingDirectory
        pendingDirectory = null
        if (id != null) {
            if (uri == null) model.pickerCancelled(id)
            else model.deliver(id, SynologyPhotoDocumentDestination(context.contentResolver, uri, true), context.cacheDir)
        }
    }
    LaunchedEffect(state.id, state.phase) {
        val id = state.id ?: return@LaunchedEffect
        try {
            if (state.phase == SynologyPhotoExportPhase.FILE && pendingFile == null) {
                pendingFile = id; filePicker.launch(state.filename ?: return@LaunchedEffect)
            } else if (state.phase == SynologyPhotoExportPhase.DIRECTORY && pendingDirectory == null) {
                pendingDirectory = id; folderPicker.launch(null)
            }
        } catch (error: Exception) {
            pendingFile = null; pendingDirectory = null; model.pickerFailed(id, error)
        }
    }
    if (state.phase == SynologyPhotoExportPhase.FORMAT) ClientSheet(stringResource(R.string.sp_media_save), model::dismiss) {
        state.formats.forEach { format ->
            TextButton(onClick = { model.prepare(format, context.cacheDir) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("photos_export_${format.name}")) {
                Text(stringResource(when (format) {
                    SynologyPhotoDownloadFormat.ORIGINAL -> if (state.request is SynologyPhotoExportRequest.Archive) R.string.sp_export_original_zip else R.string.sp_export_original
                    SynologyPhotoDownloadFormat.OPTIMIZED_JPEG -> if (state.request is SynologyPhotoExportRequest.Archive) R.string.sp_export_optimized_zip else R.string.sp_export_optimized
                    SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG -> R.string.sp_export_original_jpeg
                }))
            }
        }
    }
    if (state.busy) AlertDialog(onDismissRequest = model::cancel,
        title = { Text(stringResource(R.string.sp_save_busy)) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.sp_export_progress, state.saved, state.total))
            state.progress?.let { LinearProgressIndicator(progress = { it.toFloat() }, modifier = Modifier.fillMaxWidth()) }
                ?: LinearProgressIndicator(Modifier.fillMaxWidth())
        } }, confirmButton = { TextButton(onClick = model::cancel) { Text(stringResource(R.string.cancel)) } })
    if (state.phase == SynologyPhotoExportPhase.FINISHED) AlertDialog(onDismissRequest = model::dismiss,
        title = { Text(stringResource(R.string.sp_media_save)) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(when {
                state.error != null -> R.string.sp_export_failed
                state.cancelled -> R.string.sp_export_cancelled
                else -> R.string.sp_export_completed
            }, state.saved, state.total))
            if (state.retainedOriginals > 0) Text(stringResource(R.string.sp_export_retained, state.retainedOriginals))
            if (state.request is SynologyPhotoExportRequest.Archive && state.format == SynologyPhotoDownloadFormat.OPTIMIZED_JPEG && state.saved > 0)
                Text(stringResource(R.string.sp_export_archive_originals))
            state.error?.let { error ->
                val failure = error as? DsmFailure ?: error.cause as? DsmFailure
                val specific = error is SynologyPhotoEditFailure || error is SynologyPhotoAlbumFailure || error is SynologyPhotoDeletionFailure ||
                    error is SynologyPhotoFailure && error.kind in setOf(SynologyPhotoFailureKind.UNAVAILABLE, SynologyPhotoFailureKind.PERMISSION, SynologyPhotoFailureKind.TARGET_CHANGED) ||
                    failure?.kind == DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED
                Text(if (specific) photoError(error) else stringResource(R.string.sp_export_retry), color = MaterialTheme.colorScheme.error)
            }
        } }, confirmButton = { TextButton(onClick = model::dismiss) { Text(stringResource(R.string.sp_media_close)) } })
}
