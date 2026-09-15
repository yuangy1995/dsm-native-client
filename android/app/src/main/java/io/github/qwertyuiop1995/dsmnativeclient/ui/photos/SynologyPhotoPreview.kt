package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.net.Uri
import android.provider.DocumentsContract
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.NavigateBefore
import androidx.compose.material.icons.automirrored.outlined.NavigateNext
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material.icons.outlined.ZoomIn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhoto
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.MediaPreview
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet
import java.io.File
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.*

@Composable
internal fun SynologyPhotoPreview(model: SynologyPhotosModel) {
    val state by model.preview.state.collectAsState()
    val deletion by model.deletion.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pendingPath by rememberSaveable(model.profileId) { mutableStateOf<String?>(null) }
    var exportCopying by remember { mutableStateOf(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val expectedPath = pendingPath
        pendingPath = null
        val file = model.preview.state.value.exportFile?.takeIf { it.path == expectedPath }
        if (uri == null) model.preview.finishExport()
        else scope.launch {
            exportCopying = true
            var successful = false
            try {
                if (file == null) throw java.io.IOException("Photos export no longer owned")
                copyPreparedOriginal(context, file, uri)
                ensureActive()
                successful = true
                model.preview.finishExport(saved = true)
            } catch (error: Exception) {
                model.preview.finishExport(error = error.takeUnless { it is CancellationException })
                if (error is CancellationException) throw error
            } finally {
                // URI 来自本次“创建文档”；失败/迟到结果不能留一个看似完整的空文件。
                if (!successful) withContext(NonCancellable + Dispatchers.IO) {
                    runCatching { DocumentsContract.deleteDocument(context.contentResolver, uri) }
                }
                exportCopying = false
            }
        }
    }
    LaunchedEffect(state.exportFile) {
        state.exportFile?.let { file ->
            if (pendingPath == null) {
                pendingPath = file.path
                try { picker.launch(file.name) }
                catch (error: Exception) { pendingPath = null; model.preview.finishExport(error) }
            }
        }
    }
    val photo = state.photo
    if (photo != null) ClientPageDialog(photo.filename, model.preview::closePreview) {
        var showInfo by rememberSaveable(photo.id.itemId) { mutableStateOf(false) }
        var zoom by remember(photo.id) { mutableFloatStateOf(1f) }
        BoxWithConstraints(Modifier.fillMaxSize().onPreviewKeyEvent {
            if (it.type != KeyEventType.KeyDown) false else when (it.key) {
                Key.DirectionLeft -> { model.preview.adjacent(-1); true }
                Key.DirectionRight -> { model.preview.adjacent(1); true }
                Key.Escape -> { model.preview.closePreview(); true }
                else -> false
            }
        }) {
            val wide = maxWidth >= 840.dp
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.weight(1f).fillMaxWidth()) {
                    Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                        when {
                            state.loading -> CircularProgressIndicator()
                            state.error != null -> PhotoErrorPanel(state.error!!, onRetry = { model.preview.open(photo, state.playingMotion) })
                            state.source != null -> key(state.source) { MediaPreview(null, state.source, photo.filename, audio = false) }
                            state.image != null -> PhotoZoomImage(state.image!!, photo, zoom, { zoom = it })
                        }
                    }
                    if (wide && showInfo) PhotoMetadata(photo, Modifier.width(320.dp).fillMaxHeight())
                }
                if (state.saving || exportCopying) {
                    Text(stringResource(R.string.sp_save_busy), Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelMedium)
                    state.saveProgress?.let { LinearProgressIndicator(progress = it.toFloat(), modifier = Modifier.fillMaxWidth()) }
                        ?: LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                state.saveError?.let { Text(stringResource(R.string.sp_media_save_failed), Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
                if (state.saved) Text(stringResource(R.string.sp_media_saved), Modifier.padding(12.dp))
                deletion.error?.let { Text(photoError(it), Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
                LazyRow(Modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.Center) {
                    item { IconButton(onClick = { model.preview.adjacent(-1) }, enabled = model.preview.canMove(-1)) { Icon(Icons.AutoMirrored.Outlined.NavigateBefore, stringResource(R.string.sp_media_previous)) } }
                    item { IconButton(onClick = { model.preview.adjacent(1) }, enabled = model.preview.canMove(1)) { Icon(Icons.AutoMirrored.Outlined.NavigateNext, stringResource(R.string.sp_media_next)) } }
                    item { IconButton(onClick = { zoom = if (zoom > 1f) 1f else 2f }, enabled = state.image != null && state.source == null) { Icon(Icons.Outlined.ZoomIn, stringResource(R.string.sp_media_zoom)) } }
                    item { IconButton(onClick = { showInfo = !showInfo }) { Icon(Icons.Outlined.Info, stringResource(R.string.sp_media_info)) } }
                    item { IconButton(onClick = { model.preview.prepareExport(photo, context.cacheDir) }, enabled = !state.saving && !exportCopying && state.exportFile == null) { Icon(Icons.Outlined.Download, stringResource(R.string.sp_media_save)) } }
                    if (photo.mediaType == "live") item { IconButton(onClick = model.preview::toggleMotion, enabled = !state.loading) { Icon(if (state.playingMotion) Icons.Outlined.Stop else Icons.Outlined.PlayArrow, stringResource(R.string.sp_media_play_motion)) } }
                    if (model.deletion.enabled) item { IconButton(onClick = { model.deletion.prepare(photo) }, enabled = !deletion.checking && !deletion.writing && deletion.pending == null) { Icon(Icons.Outlined.DeleteOutline, stringResource(R.string.sp_delete_action)) } }
                }
            }
            if (showInfo && !wide) ClientSheet(stringResource(R.string.sp_media_info), { showInfo = false }) { PhotoMetadataContent(photo) }
        }
    }
    // 系统保存选择器会暂时关闭预览；结果仍然在图库层反馈，不能依赖旧预览仍存在。
    if (photo == null && (state.saveError != null || state.saved)) AlertDialog(
        onDismissRequest = { model.preview.finishExport() },
        text = { Text(stringResource(if (state.saved) R.string.sp_media_saved else R.string.sp_media_save_failed)) },
        confirmButton = { TextButton(onClick = { model.preview.finishExport() }) { Text(stringResource(R.string.sp_media_close)) } },
    )
}

private suspend fun copyPreparedOriginal(context: android.content.Context, file: File, uri: Uri) = withContext(Dispatchers.IO) {
    val expected = file.length()
    file.inputStream().use { input ->
        val output = context.contentResolver.openOutputStream(uri, "w") ?: throw java.io.IOException("Photos destination unavailable")
        output.use {
            val buffer = ByteArray(64 * 1024)
            var copied = 0L
            while (true) {
                ensureActive()
                val count = input.read(buffer)
                if (count < 0) break
                it.write(buffer, 0, count)
                copied += count
            }
            if (copied != expected) throw java.io.IOException("Photos staging length changed")
            ensureActive()
            it.flush()
        }
    }
}

@Composable
private fun PhotoZoomImage(data: ByteArray, photo: SynologyPhoto, zoom: Float, onZoom: (Float) -> Unit) {
    var failed by remember(data) { mutableStateOf(false) }
    val bitmap by produceState<android.graphics.Bitmap?>(null, data) {
        value = null
        try { value = PhotoBitmapDecoder.decode(data, 2560) }
        catch (error: Exception) { if (error is CancellationException) throw error; failed = true }
    }
    var offset by remember(photo.id) { mutableStateOf(Offset.Zero) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    LaunchedEffect(zoom) { if (zoom == 1f) offset = Offset.Zero }
    val transform = rememberTransformableState { scale, pan, _ ->
        val next = (zoom * scale).coerceIn(1f, 8f)
        onZoom(next)
        val maxX = size.width * (next - 1f) / 2
        val maxY = size.height * (next - 1f) / 2
        offset = Offset((offset.x + pan.x).coerceIn(-maxX, maxX), (offset.y + pan.y).coerceIn(-maxY, maxY))
    }
    val image = bitmap
    if (failed) Text(stringResource(R.string.sp_media_failed), Modifier.padding(24.dp))
    else if (image == null) CircularProgressIndicator()
    else Image(image.asImageBitmap(), photo.filename, contentScale = ContentScale.Fit,
        modifier = Modifier.fillMaxSize().sizeIn(minWidth = 48.dp, minHeight = 48.dp).onSizeChanged { size = it }.graphicsLayer {
            scaleX = zoom; scaleY = zoom; translationX = offset.x; translationY = offset.y; clip = true
        }.pointerInput(photo.id, zoom) { detectTapGestures(onDoubleTap = { onZoom(if (zoom > 1f) 1f else 2f) }) }.transformable(transform))
}

@Composable
private fun PhotoMetadata(photo: SynologyPhoto, modifier: Modifier = Modifier) {
    Column(modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) { PhotoMetadataContent(photo) }
}

@Composable
private fun ColumnScope.PhotoMetadataContent(photo: SynologyPhoto) {
    val locale = LocalConfiguration.current.locales[0]
    val context = LocalContext.current
    val format = remember(locale) { DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM).withLocale(locale).withZone(ZoneId.systemDefault()) }
    val numbers = remember(locale) { NumberFormat.getNumberInstance(locale).apply { maximumFractionDigits = 6 } }
    val dates = listOf(R.string.sp_detail_taken to photo.takenAt, R.string.sp_detail_added to photo.indexedAt)
    dates.forEach { (label, time) -> MetadataRow(stringResource(label), format.format(Instant.ofEpochMilli((time * 1000).toLong()))) }
    MetadataRow(stringResource(R.string.sp_detail_size), Formatter.formatShortFileSize(context, photo.sizeBytes))
    MetadataRow(stringResource(R.string.sp_detail_format), photo.filename.substringAfterLast('.', photo.mediaType).uppercase(locale))
    if (photo.width != null && photo.height != null) MetadataRow(stringResource(R.string.sp_detail_resolution), stringResource(R.string.sp_media_dimensions, photo.width, photo.height))
    listOf(R.string.sp_detail_camera to photo.camera, R.string.sp_detail_lens to photo.lens, R.string.sp_detail_aperture to photo.aperture,
        R.string.sp_detail_shutter to photo.exposureTime, R.string.sp_detail_focal to photo.focalLength, R.string.sp_detail_iso to photo.iso,
        R.string.sp_detail_description to photo.description).forEach { (label, value) -> value?.takeIf { it.isNotBlank() }?.let { MetadataRow(stringResource(label), it) } }
    photo.duration?.let { MetadataRow(stringResource(R.string.sp_detail_duration), stringResource(R.string.sp_seconds, numbers.format(it))) }
    photo.rating?.let { MetadataRow(stringResource(R.string.sp_detail_rating), stringResource(R.string.sp_stars, it)) }
    if (photo.address.isNotEmpty()) MetadataRow(stringResource(R.string.sp_detail_location), photo.address.joinToString(", "))
    if (photo.latitude != null && photo.longitude != null) MetadataRow(stringResource(R.string.sp_detail_coordinates), stringResource(R.string.sp_coordinates, numbers.format(photo.latitude), numbers.format(photo.longitude)))
}

@Composable
private fun MetadataRow(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}
