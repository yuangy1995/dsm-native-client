package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.NavigateBefore
import androidx.compose.material.icons.automirrored.outlined.NavigateNext
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoSlideshowModel
import io.github.qwertyuiop1995.dsmnativeclient.ui.MediaPreview
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

@Composable
internal fun SynologyPhotoSlideshow(model: SynologyPhotoSlideshowModel) {
    val state by model.state.collectAsState()
    val media by model.preview.state.collectAsState()
    if (!state.active) return
    ClientPageDialog(media.photo?.filename ?: stringResource(R.string.sp_slideshow_start), model::stop) {
        val focus = remember { FocusRequester() }
        val view = LocalView.current
        DisposableEffect(view, state.playing) {
            val previous = view.keepScreenOn
            view.keepScreenOn = state.playing
            onDispose { view.keepScreenOn = previous }
        }
        LaunchedEffect(Unit) { focus.requestFocus() }
        Column(Modifier.fillMaxSize().testTag("photos_slideshow").onPreviewKeyEvent {
            if (it.type != KeyEventType.KeyDown) false else when (it.key) {
                Key.DirectionLeft -> { model.move(-1); true }
                Key.DirectionRight -> { model.move(1); true }
                Key.Spacebar -> { model.togglePlaying(); true }
                Key.Escape -> { model.stop(); true }
                else -> false
            }
        }.focusRequester(focus).focusable()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                val photo = media.photo
                val token = state.mediaToken
                when {
                    state.error != null -> Column(horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(24.dp)) {
                        Text(stringResource(R.string.sp_slideshow_failed))
                        TextButton(onClick = { model.retry() }) { Text(stringResource(R.string.retry)) }
                    }
                    media.loading || photo == null -> CircularProgressIndicator()
                    else -> key(token) {
                        when {
                            media.source != null -> MediaPreview(null, media.source, photo.filename, audio = false,
                                playing = state.playing && !state.loading, onReady = { model.mediaReady(token) },
                                onFinished = { model.videoFinished(token) },
                                onFailure = { model.mediaFailed(token, it) })
                            media.image != null -> PhotoZoomImage(media.image!!, photo, 1f, {},
                                onReady = { model.mediaReady(token) }, onFailure = { model.mediaFailed(token, it) })
                        }
                    }
                }
                if (state.loading && !media.loading && state.error == null) CircularProgressIndicator(Modifier.align(Alignment.Center))
            }
            LazyRow(Modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.Center) {
                item { IconButton(onClick = { model.move(-1) }, enabled = !state.loading) {
                    Icon(Icons.AutoMirrored.Outlined.NavigateBefore, stringResource(R.string.sp_media_previous))
                } }
                item { IconButton(onClick = model::togglePlaying, enabled = state.error == null) {
                    Icon(if (state.playing) Icons.Outlined.Pause else Icons.Outlined.PlayArrow,
                        stringResource(if (state.playing) R.string.sp_slideshow_pause else R.string.sp_slideshow_resume))
                } }
                item { IconButton(onClick = { model.move(1) }, enabled = !state.loading) {
                    Icon(Icons.AutoMirrored.Outlined.NavigateNext, stringResource(R.string.sp_media_next))
                } }
                item { IconButton(onClick = model::stop) {
                    Icon(Icons.Outlined.Stop, stringResource(R.string.sp_slideshow_stop))
                } }
            }
        }
    }
}
