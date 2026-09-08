package io.github.qwertyuiop1995.dsmnativeclient.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.media.ExifInterface
import android.media.MediaDataSource
import android.media.MediaPlayer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.text.format.Formatter
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.VideoView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CenterFocusStrong
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Headphones
import androidx.compose.material.icons.outlined.ZoomIn
import androidx.compose.material.icons.outlined.ZoomOut
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewContent
import io.github.qwertyuiop1995.dsmnativeclient.domain.RandomAccessMediaSource
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import java.io.File
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

@Composable
internal fun FilePreviewDialog(
    item: FileItem,
    preview: Loadable<FilePreviewContent>,
    onRetry: () -> Unit,
    onClose: () -> Unit,
    onPrevious: (() -> Unit)? = null,
    onNext: (() -> Unit)? = null,
    previousEnabled: Boolean = false,
    nextEnabled: Boolean = false,
    onSaveText: ((FileItem, String) -> Unit)? = null,
    savingText: Boolean = false,
    textDraft: String? = null,
    onTextDraftChange: (String?) -> Unit = {},
    onCancelTextEdit: () -> Unit = {},
    discardConfirmationVisible: Boolean = false,
    onConfirmDiscard: () -> Unit = {},
    onDismissDiscard: () -> Unit = {},
    embedded: Boolean = false,
    modifier: Modifier = Modifier,
) {
    var showDetails by rememberSaveable(item.path) { mutableStateOf(false) }
    val previewContent: @Composable () -> Unit = {
        val contentModifier = if (embedded) {
            Modifier.fillMaxSize()
        } else {
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .imePadding()
        }
        Surface(
            modifier = modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            Column(contentModifier) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 64.dp)
                        .padding(horizontal = 8.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(
                        onClick = onClose,
                        enabled = !savingText,
                        modifier = Modifier.size(48.dp),
                    ) {
                        Icon(Icons.Outlined.Close, contentDescription = stringResource(R.string.close))
                    }
                    Text(
                        text = item.name,
                        modifier = Modifier
                            .weight(1f)
                            .padding(horizontal = 8.dp),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    IconButton(
                        onClick = { showDetails = !showDetails },
                        modifier = Modifier.size(48.dp),
                    ) {
                        Icon(
                            Icons.Outlined.Info,
                            contentDescription = stringResource(R.string.file_details),
                        )
                    }
                    if (onPrevious != null) {
                        IconButton(
                            onClick = onPrevious,
                            enabled = previousEnabled && textDraft == null,
                            modifier = Modifier.size(48.dp),
                        ) {
                            Icon(
                                Icons.AutoMirrored.Outlined.ArrowBack,
                                contentDescription = stringResource(R.string.previous_photo),
                            )
                        }
                    }
                    if (onNext != null) {
                        IconButton(
                            onClick = onNext,
                            enabled = nextEnabled && textDraft == null,
                            modifier = Modifier.size(48.dp),
                        ) {
                            Icon(
                                Icons.AutoMirrored.Outlined.ArrowForward,
                                contentDescription = stringResource(R.string.next_photo),
                            )
                        }
                    }
                }
                if (showDetails) PreviewDetails(item, preview)
                HorizontalDivider()
                Box(Modifier.fillMaxSize()) {
                    when (preview) {
                        Loadable.Idle,
                        Loadable.Loading,
                        -> PreviewLoading()
                        is Loadable.Failed -> PreviewFailure(preview, onRetry)
                        is Loadable.Ready -> PreviewReady(
                            preview.value,
                            onRetry,
                            textDraft,
                            onDraftChange = onTextDraftChange,
                            onCancelEdit = onCancelTextEdit,
                            onRequestSave = {
                                textDraft?.let { draft -> onSaveText?.invoke(item, draft) }
                            },
                            canEditText = onSaveText != null,
                            savingText = savingText,
                        )
                    }
                }
            }
        }
    }
    if (embedded) {
        previewContent()
    } else {
        Dialog(
            onDismissRequest = { if (!savingText) onClose() },
            properties = DialogProperties(
                usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false,
            ),
        ) {
            previewContent()
        }
    }
    if (discardConfirmationVisible) {
        AlertDialog(
            onDismissRequest = onDismissDiscard,
            title = { Text(stringResource(R.string.discard_text_changes_title)) },
            text = { Text(stringResource(R.string.discard_text_changes_message)) },
            confirmButton = {
                TextButton(
                    onClick = onConfirmDiscard,
                ) {
                    Text(stringResource(R.string.discard_changes))
                }
            },
            dismissButton = {
                TextButton(onClick = onDismissDiscard) {
                    Text(stringResource(R.string.keep_editing))
                }
            },
        )
    }
}

@Composable
internal fun PreviewDetails(item: FileItem, preview: Loadable<FilePreviewContent>) {
    val context = LocalContext.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        DetailLine(stringResource(R.string.file_detail_type), item.extension.uppercase().ifBlank {
            stringResource(R.string.unknown_file_type)
        })
        DetailLine(stringResource(R.string.file_detail_size), Formatter.formatFileSize(context, item.size))
        item.modifiedAtEpochSeconds
            ?.takeIf { it in 0..253_402_300_799L }
            ?.let { epochSeconds ->
            DetailLine(
                stringResource(R.string.file_detail_modified),
                DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, context.resources.configuration.locales[0])
                    .format(Date(epochSeconds * 1000)),
            )
        }
        val mediaDetails = when (val content = (preview as? Loadable.Ready)?.value) {
            is FilePreviewContent.Image -> content.mediaDetails
            is FilePreviewContent.Video -> content.mediaDetails
            is FilePreviewContent.Audio -> content.mediaDetails
            else -> null
        }
        if (mediaDetails?.width != null && mediaDetails.height != null) {
            DetailLine(
                stringResource(R.string.file_detail_dimensions),
                stringResource(
                    R.string.file_detail_dimensions_value,
                    mediaDetails.width,
                    mediaDetails.height,
                ),
            )
        }
        mediaDetails?.durationMillis?.let { duration ->
            val totalSeconds = duration / 1_000
            DetailLine(
                stringResource(R.string.file_detail_duration),
                String.format("%d:%02d", totalSeconds / 60, totalSeconds % 60),
            )
        }
        mediaDetails?.capturedAtEpochMillis?.let { capturedAt ->
            DetailLine(
                stringResource(R.string.file_detail_taken),
                DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, context.resources.configuration.locales[0])
                    .format(Date(capturedAt)),
            )
        }
        mediaDetails?.camera?.let { camera ->
            DetailLine(stringResource(R.string.file_detail_camera), camera)
        }
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            value,
            modifier = Modifier.weight(2f),
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
private fun PreviewLoading() {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator()
        Text(
            stringResource(R.string.preview_loading),
            modifier = Modifier.padding(top = 16.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun PreviewFailure(failure: Loadable.Failed, onRetry: () -> Unit) {
    val localized = failure.error.localize(LocalContext.current)
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Outlined.ErrorOutline,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.error,
        )
        Text(
            localized.message,
            modifier = Modifier.padding(top = 16.dp),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            localized.recovery,
            modifier = Modifier.padding(top = 8.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onRetry, modifier = Modifier.padding(top = 20.dp)) {
            Text(stringResource(R.string.retry))
        }
    }
}

@Composable
private fun PreviewReady(
    content: FilePreviewContent,
    onRetry: () -> Unit,
    textDraft: String?,
    onDraftChange: (String?) -> Unit,
    onCancelEdit: () -> Unit,
    onRequestSave: () -> Unit,
    canEditText: Boolean,
    savingText: Boolean,
) {
    when (content) {
        is FilePreviewContent.Image -> ImagePreview(content, onRetry)
        is FilePreviewContent.Video -> VideoPreview(content)
        is FilePreviewContent.Audio -> AudioPreview(content)
        is FilePreviewContent.Pdf -> PdfPreview(content, onRetry)
        is FilePreviewContent.Text -> TextPreview(
            content,
            textDraft,
            onDraftChange,
            onCancelEdit,
            onRequestSave,
            canEditText,
            savingText,
        )
    }
}

@Composable
private fun ImagePreview(content: FilePreviewContent.Image, onRetry: () -> Unit) {
    var scale by rememberSaveable(content.localFile.path) { mutableFloatStateOf(1f) }
    var translationX by rememberSaveable(content.localFile.path) { mutableFloatStateOf(0f) }
    var translationY by rememberSaveable(content.localFile.path) { mutableFloatStateOf(0f) }
    val transformState = rememberTransformableState { zoomChange, panChange, _ ->
        val nextScale = (scale * zoomChange).coerceIn(1f, MAX_IMAGE_SCALE)
        scale = nextScale
        if (nextScale == 1f) {
            translationX = 0f
            translationY = 0f
        } else {
            translationX += panChange.x
            translationY += panChange.y
        }
    }
    val result by produceState<BitmapResult>(BitmapResult.Loading, content.localFile.path) {
        value = withContext(Dispatchers.Default) {
            runCatching { decodePreviewBitmap(content.localFile, MAX_IMAGE_DIMENSION) }
                .fold(BitmapResult::Ready) { BitmapResult.Failed }
        }
    }
    when (val current = result) {
        BitmapResult.Loading -> PreviewLoading()
        BitmapResult.Failed -> LocalPreviewFailure(onRetry)
        is BitmapResult.Ready -> Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                Image(
                    bitmap = current.bitmap.asImageBitmap(),
                    contentDescription = stringResource(R.string.preview_image_description, content.item.name),
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(12.dp)
                        .graphicsLayer(
                            scaleX = scale,
                            scaleY = scale,
                            translationX = translationX,
                            translationY = translationY,
                        )
                        .transformable(transformState),
                )
            }
            HorizontalDivider()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FilledTonalIconButton(
                    onClick = { scale = (scale - IMAGE_SCALE_STEP).coerceAtLeast(1f) },
                    enabled = scale > 1f,
                ) {
                    Icon(Icons.Outlined.ZoomOut, contentDescription = stringResource(R.string.zoom_out))
                }
                Text(
                    stringResource(R.string.zoom_percent, (scale * 100).toInt()),
                    modifier = Modifier.padding(horizontal = 20.dp),
                )
                FilledTonalIconButton(
                    onClick = { scale = (scale + IMAGE_SCALE_STEP).coerceAtMost(MAX_IMAGE_SCALE) },
                    enabled = scale < MAX_IMAGE_SCALE,
                ) {
                    Icon(Icons.Outlined.ZoomIn, contentDescription = stringResource(R.string.zoom_in))
                }
                FilledTonalIconButton(
                    onClick = {
                        scale = 1f
                        translationX = 0f
                        translationY = 0f
                    },
                    enabled = scale != 1f || translationX != 0f || translationY != 0f,
                    modifier = Modifier.padding(start = 12.dp),
                ) {
                    Icon(
                        Icons.Outlined.CenterFocusStrong,
                        contentDescription = stringResource(R.string.reset_zoom),
                    )
                }
            }
        }
    }
}

@Composable
private fun VideoPreview(content: FilePreviewContent.Video) {
    MediaPreview(content.localFile, content.mediaSource, content.item.name, audio = false)
}

@Composable
private fun AudioPreview(content: FilePreviewContent.Audio) {
    MediaPreview(content.localFile, content.mediaSource, content.item.name, audio = true)
}

@Composable
private fun MediaPreview(
    localFile: File?,
    mediaSource: RandomAccessMediaSource?,
    itemName: String,
    audio: Boolean,
) {
    val context = LocalContext.current
    val sourceKey = localFile?.path ?: mediaSource
    var videoView: VideoView? by remember(sourceKey) { mutableStateOf(null) }
    var streamingView: StreamingMediaView? by remember(sourceKey) { mutableStateOf(null) }
    var playbackFailed by remember(sourceKey) { mutableStateOf(false) }
    val description = stringResource(
        if (audio) R.string.preview_audio_description else R.string.preview_video_description,
        itemName,
    )
    Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
        AndroidView(
            factory = { viewContext ->
                when {
                    mediaSource != null -> StreamingMediaView(
                        context = viewContext,
                        source = mediaSource,
                        audio = audio,
                        onPlaybackFailed = { playbackFailed = true },
                    ).also { streamingView = it }

                    localFile != null -> VideoView(viewContext).also { view ->
                        videoView = view
                        val mediaController = MediaController(viewContext)
                        view.setMediaController(mediaController)
                        mediaController.setAnchorView(view)
                        view.setVideoURI(Uri.fromFile(localFile))
                        view.setOnPreparedListener { mediaController.show(0) }
                        view.setOnErrorListener { _, _, _ ->
                            playbackFailed = true
                            true
                        }
                        view.requestFocus()
                    }

                    else -> FrameLayout(viewContext).also { playbackFailed = true }
                }
            },
            modifier = Modifier
                .fillMaxSize()
                .semantics { contentDescription = description },
        )
        if (audio && !playbackFailed) {
            Column(
                modifier = Modifier.align(Alignment.Center).padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(
                    Icons.Outlined.Headphones,
                    contentDescription = null,
                    tint = androidx.compose.ui.graphics.Color.White,
                    modifier = Modifier.size(72.dp),
                )
                Text(
                    itemName,
                    color = androidx.compose.ui.graphics.Color.White,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    stringResource(R.string.audio_controls_hint),
                    color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.8f),
                )
            }
        }
        if (playbackFailed) {
            Column(
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    Icons.Outlined.ErrorOutline,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(48.dp),
                )
                Text(
                    stringResource(
                        if (audio) R.string.audio_playback_failed else R.string.video_playback_failed,
                    ),
                    color = androidx.compose.ui.graphics.Color.White,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    stringResource(
                        if (audio) {
                            R.string.audio_playback_failed_recovery
                        } else {
                            R.string.video_playback_failed_recovery
                        },
                    ),
                    color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.8f),
                )
            }
        }
    }
    DisposableEffect(sourceKey) {
        onDispose {
            videoView?.stopPlayback()
            videoView = null
            streamingView?.release()
            streamingView = null
        }
    }
}

private class StreamingMediaDataSource(
    private val source: RandomAccessMediaSource,
) : MediaDataSource() {
    override fun getSize(): Long = source.size

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int =
        source.readAt(position, buffer, offset, size)

    override fun close() = source.close()
}

private class StreamingMediaView(
    context: android.content.Context,
    source: RandomAccessMediaSource,
    audio: Boolean,
    private val onPlaybackFailed: () -> Unit,
) : FrameLayout(context), MediaController.MediaPlayerControl, SurfaceHolder.Callback {
    private val mediaPlayer = MediaPlayer()
    private val mediaController = MediaController(context)
    private val dataSource = StreamingMediaDataSource(source)
    private var prepared = false
    private var released = false

    init {
        if (!audio) {
            val surface = SurfaceView(context)
            surface.holder.addCallback(this)
            addView(surface, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        }
        isFocusable = true
        isClickable = true
        mediaController.setMediaPlayer(this)
        mediaController.setAnchorView(this)
        setOnClickListener { mediaController.show() }
        mediaPlayer.setDataSource(dataSource)
        mediaPlayer.setOnPreparedListener {
            prepared = true
            mediaController.isEnabled = true
            mediaController.show(0)
        }
        mediaPlayer.setOnCompletionListener { mediaController.show(0) }
        mediaPlayer.setOnErrorListener { _, _, _ ->
            onPlaybackFailed()
            true
        }
        mediaPlayer.prepareAsync()
        requestFocus()
    }

    fun release() {
        if (released) return
        released = true
        prepared = false
        mediaController.hide()
        runCatching { mediaPlayer.stop() }
        mediaPlayer.reset()
        mediaPlayer.release()
        dataSource.close()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        if (!released) mediaPlayer.setDisplay(holder)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        if (!released) mediaPlayer.setDisplay(null)
    }

    override fun start() {
        if (prepared && !released) mediaPlayer.start()
    }

    override fun pause() {
        if (prepared && !released) mediaPlayer.pause()
    }

    override fun getDuration(): Int = if (prepared && !released) mediaPlayer.duration else 0

    override fun getCurrentPosition(): Int = if (prepared && !released) mediaPlayer.currentPosition else 0

    override fun seekTo(position: Int) {
        if (prepared && !released) mediaPlayer.seekTo(position)
    }

    override fun isPlaying(): Boolean = prepared && !released && mediaPlayer.isPlaying

    override fun getBufferPercentage(): Int = 0

    override fun canPause(): Boolean = true

    override fun canSeekBackward(): Boolean = true

    override fun canSeekForward(): Boolean = true

    override fun getAudioSessionId(): Int = if (released) 0 else mediaPlayer.audioSessionId
}

@Composable
private fun TextPreview(
    content: FilePreviewContent.Text,
    draft: String?,
    onDraftChange: (String?) -> Unit,
    onCancelEdit: () -> Unit,
    onRequestSave: () -> Unit,
    canEdit: Boolean,
    saving: Boolean,
) {
    if (draft != null) {
        Column(Modifier.fillMaxSize()) {
            OutlinedTextField(
                value = draft,
                onValueChange = { if (it.encodeToByteArray().size <= MAX_EDIT_TEXT_BYTES) onDraftChange(it) },
                label = { Text(stringResource(R.string.edit_text_file)) },
                enabled = !saving,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier.weight(1f).fillMaxWidth().padding(16.dp),
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(
                    onClick = onCancelEdit,
                    enabled = !saving,
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text(stringResource(R.string.cancel))
                }
                Button(
                    onClick = onRequestSave,
                    enabled = !saving && draft != content.value,
                    modifier = Modifier.padding(start = 8.dp).heightIn(min = 48.dp),
                ) {
                    if (saving) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Text(stringResource(R.string.save))
                    }
                }
            }
        }
        return
    }
    if (content.value.isEmpty()) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(Icons.Outlined.Description, contentDescription = null, modifier = Modifier.size(48.dp))
            Text(
                stringResource(R.string.preview_empty_text),
                modifier = Modifier.padding(top = 16.dp),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                stringResource(R.string.preview_empty_text_description),
                modifier = Modifier.padding(top = 8.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (canEdit && content.item.canWrite && !content.truncated) {
                Button(
                    onClick = { onDraftChange("") },
                    modifier = Modifier.padding(top = 20.dp),
                ) {
                    Text(stringResource(R.string.edit_text_file))
                }
            }
        }
        return
    }
    Column(Modifier.fillMaxSize()) {
        if (content.truncated) {
            Text(
                stringResource(R.string.preview_truncated),
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.secondaryContainer)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
            )
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            SelectionContainer {
                Text(
                    text = content.value,
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(16.dp),
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                )
            }
        }
        if (canEdit && content.item.canWrite && !content.truncated) {
            HorizontalDivider()
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                Button(onClick = { onDraftChange(content.value) }) {
                    Text(stringResource(R.string.edit_text_file))
                }
            }
        }
    }
}

@Composable
private fun PdfPreview(content: FilePreviewContent.Pdf, onRetry: () -> Unit) {
    var pageIndex by rememberSaveable(content.localFile.path) { mutableIntStateOf(0) }
    var scale by rememberSaveable(content.localFile.path) { mutableFloatStateOf(1f) }
    var translationX by rememberSaveable(content.localFile.path) { mutableFloatStateOf(0f) }
    var translationY by rememberSaveable(content.localFile.path) { mutableFloatStateOf(0f) }
    val transformState = rememberTransformableState { zoomChange, panChange, _ ->
        val nextScale = (scale * zoomChange).coerceIn(1f, MAX_PDF_SCALE)
        scale = nextScale
        if (nextScale == 1f) {
            translationX = 0f
            translationY = 0f
        } else {
            translationX += panChange.x
            translationY += panChange.y
        }
    }
    val result by produceState<PdfResult>(PdfResult.Loading, content.localFile.path, pageIndex) {
        value = withContext(Dispatchers.IO) {
            runCatching { renderPdfPage(content.localFile, pageIndex) }
                .fold({ PdfResult.Ready(it.bitmap, it.pageCount) }) { PdfResult.Failed }
        }
    }
    Column(Modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            when (val current = result) {
                PdfResult.Loading -> PreviewLoading()
                PdfResult.Failed -> LocalPreviewFailure(onRetry)
                is PdfResult.Ready -> Image(
                    bitmap = current.bitmap.asImageBitmap(),
                    contentDescription = stringResource(
                        R.string.pdf_page_count,
                        pageIndex + 1,
                        current.pageCount,
                    ),
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(12.dp)
                        .graphicsLayer(
                            scaleX = scale,
                            scaleY = scale,
                            translationX = translationX,
                            translationY = translationY,
                        )
                        .transformable(transformState),
                )
            }
        }
        val pageCount = (result as? PdfResult.Ready)?.pageCount ?: 0
        if (pageCount > 0) {
            HorizontalDivider()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FilledTonalIconButton(
                    onClick = { pageIndex-- },
                    enabled = pageIndex > 0,
                ) {
                    Icon(
                        Icons.AutoMirrored.Outlined.ArrowBack,
                        contentDescription = stringResource(R.string.previous_page),
                    )
                }
                FilledTonalIconButton(
                    onClick = { scale = (scale - PDF_SCALE_STEP).coerceAtLeast(1f) },
                    enabled = scale > 1f,
                ) {
                    Icon(Icons.Outlined.ZoomOut, stringResource(R.string.zoom_out))
                }
                Text(stringResource(R.string.pdf_page_count, pageIndex + 1, pageCount))
                Text(stringResource(R.string.zoom_percent, (scale * 100).toInt()))
                FilledTonalIconButton(
                    onClick = { scale = (scale + PDF_SCALE_STEP).coerceAtMost(MAX_PDF_SCALE) },
                    enabled = scale < MAX_PDF_SCALE,
                ) {
                    Icon(Icons.Outlined.ZoomIn, stringResource(R.string.zoom_in))
                }
                FilledTonalIconButton(
                    onClick = { pageIndex++ },
                    enabled = pageIndex + 1 < pageCount,
                ) {
                    Icon(
                        Icons.AutoMirrored.Outlined.ArrowForward,
                        contentDescription = stringResource(R.string.next_page),
                    )
                }
            }
        }
    }
}

@Composable
private fun LocalPreviewFailure(onRetry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Outlined.ErrorOutline,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.error,
        )
        Text(
            stringResource(R.string.preview_local_failed),
            modifier = Modifier.padding(top = 16.dp, start = 24.dp, end = 24.dp),
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            stringResource(R.string.preview_local_failed_recovery),
            modifier = Modifier.padding(top = 8.dp, start = 24.dp, end = 24.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onRetry, modifier = Modifier.padding(top = 20.dp)) {
            Text(stringResource(R.string.retry))
        }
    }
}

private sealed interface BitmapResult {
    data object Loading : BitmapResult
    data object Failed : BitmapResult
    data class Ready(val bitmap: Bitmap) : BitmapResult
}

private sealed interface PdfResult {
    data object Loading : PdfResult
    data object Failed : PdfResult
    data class Ready(val bitmap: Bitmap, val pageCount: Int) : PdfResult
}

private data class RenderedPdfPage(val bitmap: Bitmap, val pageCount: Int)

internal fun decodeSampledBitmap(file: File, maximumDimension: Int): Bitmap {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    require(bounds.outWidth > 0 && bounds.outHeight > 0)
    var sampleSize = 1
    while (max(bounds.outWidth, bounds.outHeight) / sampleSize > maximumDimension) {
        sampleSize *= 2
    }
    return BitmapFactory.decodeFile(
        file.path,
        BitmapFactory.Options().apply { inSampleSize = sampleSize },
    ) ?: error("Unable to decode preview")
}

internal data class PreviewExifOrientationTransform(
    val rotationDegrees: Int,
    val mirrorHorizontally: Boolean,
) {
    companion object {
        val Identity = PreviewExifOrientationTransform(rotationDegrees = 0, mirrorHorizontally = false)
    }
}

internal fun previewExifOrientationTransform(orientation: Int): PreviewExifOrientationTransform = when (orientation) {
    ExifInterface.ORIENTATION_NORMAL -> PreviewExifOrientationTransform.Identity
    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> PreviewExifOrientationTransform(0, true)
    ExifInterface.ORIENTATION_ROTATE_180 -> PreviewExifOrientationTransform(180, false)
    ExifInterface.ORIENTATION_FLIP_VERTICAL -> PreviewExifOrientationTransform(180, true)
    ExifInterface.ORIENTATION_TRANSPOSE -> PreviewExifOrientationTransform(90, true)
    ExifInterface.ORIENTATION_ROTATE_90 -> PreviewExifOrientationTransform(90, false)
    ExifInterface.ORIENTATION_TRANSVERSE -> PreviewExifOrientationTransform(270, true)
    ExifInterface.ORIENTATION_ROTATE_270 -> PreviewExifOrientationTransform(270, false)
    else -> PreviewExifOrientationTransform.Identity
}

internal fun decodePreviewBitmap(file: File, maximumDimension: Int): Bitmap {
    val decoded = decodeSampledBitmap(file, maximumDimension)
    val orientation = runCatching {
        ExifInterface(file.path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
    }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
    val transformed = applyPreviewExifOrientation(decoded, orientation)
    if (transformed !== decoded) decoded.recycle()
    return transformed
}

internal fun applyPreviewExifOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
    val transform = previewExifOrientationTransform(orientation)
    if (transform == PreviewExifOrientationTransform.Identity) return bitmap
    val matrix = Matrix().apply {
        if (transform.rotationDegrees != 0) setRotate(transform.rotationDegrees.toFloat())
        if (transform.mirrorHorizontally) postScale(-1f, 1f)
    }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
}

private fun renderPdfPage(file: File, requestedPage: Int): RenderedPdfPage {
    ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
        PdfRenderer(descriptor).use { renderer ->
            require(renderer.pageCount > 0)
            val pageIndex = requestedPage.coerceIn(0, renderer.pageCount - 1)
            renderer.openPage(pageIndex).use { page ->
                val scale = minOf(
                    1f,
                    MAX_PDF_DIMENSION.toFloat() / max(page.width, page.height).toFloat(),
                )
                val bitmap = Bitmap.createBitmap(
                    max(1, (page.width * scale).toInt()),
                    max(1, (page.height * scale).toInt()),
                    Bitmap.Config.ARGB_8888,
                )
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                return RenderedPdfPage(bitmap, renderer.pageCount)
            }
        }
    }
}

private const val MAX_IMAGE_DIMENSION = 2_048
private const val MAX_PDF_DIMENSION = 1_600
private const val MAX_IMAGE_SCALE = 5f
private const val IMAGE_SCALE_STEP = 0.5f
private const val MAX_PDF_SCALE = 4f
private const val PDF_SCALE_STEP = 0.5f
private const val MAX_EDIT_TEXT_BYTES = 512 * 1024
