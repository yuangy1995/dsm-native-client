package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.text.format.Formatter
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
import androidx.compose.material.icons.outlined.Face
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.RotateLeft
import androidx.compose.material.icons.outlined.Slideshow
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhoto
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoEdit
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoEditPhase
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoDisplaySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoAlbumAction
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.MediaPreview
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.*

@Composable
internal fun SynologyPhotoPreview(model: SynologyPhotosModel) {
    val state by model.preview.state.collectAsState()
    val gallery by model.state.collectAsState()
    val displaySettings = gallery.access?.displaySettings
    val deletion by model.deletion.state.collectAsState()
    val edits = model.edits?.state?.collectAsState()?.value
    val export by model.exports.state.collectAsState()
    val previews = model.previewRegeneration
    val previewsState = previews?.state?.collectAsState()?.value
    val manualFaces = model.manualFaces
    val manualState = manualFaces?.state?.collectAsState()?.value
    val context = LocalContext.current
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
                            state.loading && state.image == null -> CircularProgressIndicator()
                            state.error != null -> PhotoErrorPanel(state.error!!, onRetry = { model.preview.open(photo, state.playingMotion) })
                            state.source != null -> key(state.source) { MediaPreview(null, state.source, photo.filename, audio = false) }
                            state.image != null -> PhotoZoomImage(state.image!!, photo, zoom, { zoom = it },
                                onReady = { model.preview.imageReady(state.image!!) }, rotationDegrees = state.rotationDegrees)
                        }
                    }
                    if (wide && showInfo) PhotoMetadata(photo, displaySettings, Modifier.width(320.dp).fillMaxHeight())
                }
                if (displaySettings?.showInfo == true && !showInfo && photo.mediaType !in setOf("video", "video360") &&
                    !state.loading && state.error == null && state.image != null && state.source == null) {
                    PhotoPreviewInformation(photo, displaySettings)
                }
                val rotation = edits?.records?.firstOrNull { record -> record.checkpoint.edit is SynologyPhotoEdit.Rotation &&
                    record.checkpoint.targets.singleOrNull()?.id == photo.id &&
                    (record.id == edits.rotationId || record.checkpoint.submitted && !record.checkpoint.finished) }
                if (rotation != null || edits?.rotationPhoto == photo.id) {
                    val working = edits?.working == true && edits.rotationPhoto == photo.id
                    Text(stringResource(when {
                        working -> R.string.sp_rotate_saving
                        rotation?.checkpoint?.phase == SynologyPhotoEditPhase.COMPLETED -> R.string.sp_rotate_saved
                        rotation?.checkpoint?.submitted == true && !rotation.checkpoint.finished -> R.string.sp_rotate_interrupted
                        else -> R.string.sp_rotate_failed
                    }), Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall)
                    if (working) LinearProgressIndicator(Modifier.fillMaxWidth())
                    else if (rotation?.checkpoint?.submitted == true && !rotation.checkpoint.finished) TextButton(onClick = { model.edits?.resume(rotation.id) }) {
                        Text(stringResource(R.string.sp_edit_refresh))
                    }
                }
                deletion.error?.let { Text(photoError(it), Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
                val canRotate = model.canRotatePreview
                val canStartSlideshow = model.canStartSlideshow
                LazyRow(Modifier.fillMaxWidth().testTag("photos_preview_actions"), contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.Center) {
                    item { IconButton(onClick = { model.preview.adjacent(-1) }, enabled = model.preview.canMove(-1)) { Icon(Icons.AutoMirrored.Outlined.NavigateBefore, stringResource(R.string.sp_media_previous)) } }
                    item { IconButton(onClick = { model.preview.adjacent(1) }, enabled = model.preview.canMove(1)) { Icon(Icons.AutoMirrored.Outlined.NavigateNext, stringResource(R.string.sp_media_next)) } }
                    item { IconButton(onClick = { zoom = if (zoom > 1f) 1f else 2f }, enabled = state.image != null && state.source == null) { Icon(Icons.Outlined.ZoomIn, stringResource(R.string.sp_media_zoom)) } }
                    item { IconButton(onClick = { showInfo = !showInfo }) { Icon(Icons.Outlined.Info, stringResource(R.string.sp_media_info)) } }
                    item { IconButton(onClick = { model.startSlideshow() }, enabled = canStartSlideshow) {
                        Icon(Icons.Outlined.Slideshow, stringResource(R.string.sp_slideshow_start))
                    } }
                    if (model.canEditPhotos && photo.supportsRotation) item { IconButton(onClick = { model.rotatePreview() }, enabled = canRotate && !export.busy) {
                        Icon(Icons.Outlined.RotateLeft, stringResource(R.string.sp_rotate_action))
                    } }
                    model.edits?.takeIf { model.canEditPhotos }?.let { editor -> item { IconButton(onClick = {
                        model.preview.closePreview(); editor.open(listOf(photo), photo.id.space)
                    }, enabled = !export.busy && edits?.working != true && !deletion.writing && !editor.blocks(photo)) {
                        Icon(Icons.Outlined.Edit, stringResource(R.string.sp_edit_title))
                    } } }
                    if (previews?.available(photo.id.space) == true && gallery.navigation.album?.isFrozen != true) item {
                        IconButton(onClick = { previews.open(listOf(photo), context.cacheDir) },
                            enabled = !state.loading && !export.busy && !deletion.writing && edits?.working != true && previewsState?.working != true,
                            modifier = Modifier.testTag("photos_previews_preview")) {
                            Icon(Icons.Outlined.Refresh, stringResource(R.string.sp_preview_regeneration_title))
                        }
                    }
                    if (manualFaces?.available(photo) == true) item {
                        IconButton(onClick = { manualFaces.open(photo); model.preview.closePreview() },
                            enabled = !state.loading && state.rotationDegrees == 0f && !export.busy && !deletion.writing && edits?.working != true && manualState?.working != true,
                            modifier = Modifier.testTag("photos_manual_open")) { Icon(Icons.Outlined.Face, stringResource(R.string.sp_manual_faces_title)) }
                    }
                    model.concepts?.let { concepts -> item {
                        PhotoConceptSelectionActions(concepts, gallery.navigation, listOf(photo), !state.loading && !export.busy && !deletion.writing, compact = true) { model.preview.closePreview() }
                    } }
                    model.files?.takeIf { it.canTransfer }?.let { files ->
                        item { IconButton(onClick = { model.preview.closePreview(); files.open(SynologyPhotoAlbumAction.MOVE_ITEMS, listOf(photo)) },
                            enabled = !deletion.writing && !export.busy) {
                            Icon(Icons.AutoMirrored.Outlined.DriveFileMove, stringResource(R.string.sp_files_move))
                        } }
                        item { IconButton(onClick = { model.preview.closePreview(); files.open(SynologyPhotoAlbumAction.COPY_ITEMS, listOf(photo)) },
                            enabled = !deletion.writing && !export.busy) {
                            Icon(Icons.Outlined.ContentCopy, stringResource(R.string.sp_files_copy))
                        } }
                    }
                    item { IconButton(onClick = { model.exports.open(SynologyPhotoExportRequest.Items(listOf(photo)), gallery.access?.supportsOriginalSizeJPEG == true) }, enabled = !export.busy && edits?.working != true && model.edits?.blocks(photo) != true) { Icon(Icons.Outlined.Download, stringResource(R.string.sp_media_save)) } }
                    if (photo.canPlayMotion) item { IconButton(onClick = model.preview::toggleMotion, enabled = !state.loading && edits?.working != true && state.rotationDegrees == 0f) { Icon(if (state.playingMotion) Icons.Outlined.Stop else Icons.Outlined.PlayArrow, stringResource(R.string.sp_media_play_motion)) } }
                    if (model.deletion.enabled(photo)) item { IconButton(onClick = { model.deletion.prepare(photo) }, enabled = !export.busy && !deletion.checking && !deletion.writing && deletion.pending == null && model.edits?.blocks(photo) != true) { Icon(Icons.Outlined.DeleteOutline, stringResource(R.string.sp_delete_action)) } }
                }
            }
            if (showInfo && !wide) ClientSheet(stringResource(R.string.sp_media_info), { showInfo = false }) { PhotoMetadataContent(photo, displaySettings) }
        }
    }
}

@Composable
internal fun PhotoZoomImage(data: ByteArray, photo: SynologyPhoto, zoom: Float, onZoom: (Float) -> Unit,
    onReady: () -> Unit = {}, onFailure: (Throwable) -> Unit = {}, rotationDegrees: Float = 0f) {
    val ready by rememberUpdatedState(onReady)
    val failure by rememberUpdatedState(onFailure)
    var failed by remember(data) { mutableStateOf(false) }
    val bitmap by produceState<android.graphics.Bitmap?>(null, data) {
        value = null
        try { value = PhotoBitmapDecoder.decode(data, 2560) }
        catch (error: Exception) { if (error is CancellationException) throw error; failed = true; failure(error) }
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
    LaunchedEffect(image) { if (image != null) { withFrameNanos { }; ready() } }
    if (failed) Text(stringResource(R.string.sp_media_failed), Modifier.padding(24.dp))
    else if (image == null) CircularProgressIndicator()
    else Image(image.asImageBitmap(), photo.filename, contentScale = ContentScale.Fit,
        modifier = Modifier.fillMaxSize().sizeIn(minWidth = 48.dp, minHeight = 48.dp).onSizeChanged { size = it }.graphicsLayer {
            val fit = if (rotationDegrees != 0f && size.width > 0 && size.height > 0)
                minOf(size.width.toFloat() / image.height, size.height.toFloat() / image.width) /
                    minOf(size.width.toFloat() / image.width, size.height.toFloat() / image.height) else 1f
            scaleX = zoom * fit; scaleY = zoom * fit; rotationZ = rotationDegrees
            translationX = offset.x; translationY = offset.y; clip = true
        }.pointerInput(photo.id, zoom) { detectTapGestures(onDoubleTap = { onZoom(if (zoom > 1f) 1f else 2f) }) }.transformable(transform))
}

@Composable
private fun PhotoMetadata(photo: SynologyPhoto, displaySettings: SynologyPhotoDisplaySettings?, modifier: Modifier = Modifier) {
    Column(modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) { PhotoMetadataContent(photo, displaySettings) }
}

@Composable
private fun ColumnScope.PhotoMetadataContent(photo: SynologyPhoto, displaySettings: SynologyPhotoDisplaySettings?) {
    val locale = LocalConfiguration.current.locales[0]
    val context = LocalContext.current
    val format = remember(locale, displaySettings) { SynologyPhotoDisplayFormat.timestamp(displaySettings, locale) }
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

@Composable
private fun PhotoPreviewInformation(photo: SynologyPhoto, settings: SynologyPhotoDisplaySettings) {
    val locale = LocalConfiguration.current.locales[0]
    val format = remember(locale, settings) { SynologyPhotoDisplayFormat.timestamp(settings, locale) }
    Column(Modifier.fillMaxWidth().heightIn(max = 160.dp).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp)
        .testTag("photos_preview_information"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(format.format(Instant.ofEpochMilli((photo.takenAt * 1000).toLong())), style = MaterialTheme.typography.bodySmall)
        if (photo.address.isNotEmpty()) Text(photo.address.take(3).joinToString(", "), style = MaterialTheme.typography.bodySmall)
        photo.description?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}
