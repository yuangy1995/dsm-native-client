package io.github.qwertyuiop1995.dsmnativeclient.ui

import android.media.MediaDataSource
import android.media.MediaPlayer
import android.net.Uri
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.VideoView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Headphones
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.RandomAccessMediaSource
import java.io.File

@Composable
internal fun MediaPreview(
    localFile: File?,
    mediaSource: RandomAccessMediaSource?,
    itemName: String,
    audio: Boolean,
    playing: Boolean? = null,
    onReady: () -> Unit = {},
    onFinished: () -> Unit = {},
    onFailure: (Throwable) -> Unit = {},
) {
    val sourceKey = localFile?.path ?: mediaSource
    var videoView: VideoView? by remember(sourceKey) { mutableStateOf(null) }
    var streamingView: StreamingMediaView? by remember(sourceKey) { mutableStateOf(null) }
    var playbackFailed by remember(sourceKey) { mutableStateOf(false) }
    var videoPrepared by remember(sourceKey) { mutableStateOf(false) }
    var videoCompleted by remember(sourceKey) { mutableStateOf(false) }
    val desiredPlayback by rememberUpdatedState(playing)
    val ready by rememberUpdatedState(onReady)
    val finished by rememberUpdatedState(onFinished)
    val failure by rememberUpdatedState(onFailure)
    val reportFailure: () -> Unit = {
        if (!playbackFailed) { playbackFailed = true; failure(java.io.IOException("Media playback failed")) }
    }
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
                        playing = desiredPlayback,
                        onReady = { ready() },
                        onFinished = { finished() },
                        onPlaybackFailed = reportFailure,
                    ).also { streamingView = it }

                    localFile != null -> VideoView(viewContext).also { view ->
                        videoView = view
                        val mediaController = MediaController(viewContext)
                        if (desiredPlayback == null) view.setMediaController(mediaController)
                        mediaController.setAnchorView(view)
                        view.setVideoURI(Uri.fromFile(localFile))
                        view.setOnPreparedListener {
                            videoPrepared = true
                            if (desiredPlayback == null) mediaController.show(0)
                            else if (desiredPlayback == true) view.start()
                            ready()
                        }
                        view.setOnCompletionListener { videoCompleted = true; finished() }
                        view.setOnErrorListener { _, _, _ ->
                            reportFailure()
                            true
                        }
                        if (desiredPlayback == null) view.requestFocus()
                    }

                    else -> FrameLayout(viewContext).also { reportFailure() }
                }
            },
            update = {
                streamingView?.setPlayback(desiredPlayback)
                if (videoPrepared && !playbackFailed) when (desiredPlayback) {
                    true -> if (!videoCompleted && videoView?.isPlaying == false) videoView?.start()
                    false -> videoView?.pause()
                    null -> Unit
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
    playing: Boolean?,
    private val onReady: () -> Unit,
    private val onFinished: () -> Unit,
    private val onPlaybackFailed: () -> Unit,
) : FrameLayout(context), MediaController.MediaPlayerControl, SurfaceHolder.Callback {
    private val mediaPlayer = MediaPlayer()
    private val mediaController = MediaController(context)
    private val dataSource = StreamingMediaDataSource(source)
    private var prepared = false
    private var released = false
    private var desiredPlayback = playing
    private var completed = false

    init {
        if (!audio) {
            val surface = SurfaceView(context)
            surface.holder.addCallback(this)
            addView(surface, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        }
        isFocusable = playing == null
        isClickable = playing == null
        mediaController.setMediaPlayer(this)
        mediaController.setAnchorView(this)
        if (playing == null) setOnClickListener { mediaController.show() }
        mediaPlayer.setOnPreparedListener {
            if (released) return@setOnPreparedListener
            prepared = true
            mediaController.isEnabled = true
            if (desiredPlayback == null) mediaController.show(0) else setPlayback(desiredPlayback)
            onReady()
        }
        mediaPlayer.setOnCompletionListener {
            if (!released) {
                completed = true
                if (desiredPlayback == null) mediaController.show(0)
                onFinished()
            }
        }
        mediaPlayer.setOnErrorListener { _, _, _ ->
            if (!released) { prepared = false; onPlaybackFailed() }
            true
        }
        try { mediaPlayer.setDataSource(dataSource); mediaPlayer.prepareAsync() }
        catch (_: Exception) { onPlaybackFailed() }
        if (playing == null) requestFocus()
    }

    fun setPlayback(playing: Boolean?) {
        desiredPlayback = playing
        if (!prepared || released) return
        when (playing) {
            true -> if (!completed && !mediaPlayer.isPlaying) mediaPlayer.start()
            false -> if (mediaPlayer.isPlaying) mediaPlayer.pause()
            null -> Unit
        }
    }

    fun release() {
        if (released) return
        released = true
        prepared = false
        mediaController.hide()
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
        if (prepared && !released && mediaPlayer.isPlaying) mediaPlayer.pause()
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
