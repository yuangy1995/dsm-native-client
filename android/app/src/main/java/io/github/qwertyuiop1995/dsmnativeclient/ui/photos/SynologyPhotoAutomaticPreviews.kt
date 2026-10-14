package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhoto
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoAutomaticPreviewModel
import kotlinx.coroutines.flow.distinctUntilChanged

/** 只报告真实可见面积，列表复用或离开页面时撤销可见集合。 */
@Composable
internal fun AutomaticPreviewVisibility(grid: LazyGridState, photos: List<SynologyPhoto>, model: SynologyPhotoAutomaticPreviewModel) {
    val keys = remember(photos) { photos.associateBy { "photo:${it.id}" } }
    DisposableEffect(model) { onDispose { model.setVisible(emptySet()) } }
    LaunchedEffect(grid, keys, model) {
        snapshotFlow {
            val layout = grid.layoutInfo
            layout.visibleItemsInfo.mapNotNull { item ->
                val photo = keys[item.key] ?: return@mapNotNull null
                val width = (minOf(item.offset.x + item.size.width, layout.viewportSize.width) - maxOf(item.offset.x, 0)).coerceAtLeast(0)
                val height = (minOf(item.offset.y + item.size.height, layout.viewportEndOffset) - maxOf(item.offset.y, layout.viewportStartOffset)).coerceAtLeast(0)
                photo.id.takeIf { item.size.width > 0 && item.size.height > 0 && width.toDouble() * height >= item.size.width.toDouble() * item.size.height * 0.8 }
            }.toSet()
        }.distinctUntilChanged().collect(model::setVisible)
    }
}

@Composable
internal fun SynologyPhotoAutomaticPreviews(model: SynologyPhotoAutomaticPreviewModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("photos_automatic_status"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(when {
            state.pending -> stringResource(R.string.sp_automatic_preview_pending)
            state.task != null -> stringResource(R.string.sp_automatic_preview_working, state.task!!.filename)
            state.paused -> stringResource(R.string.sp_automatic_preview_paused)
            else -> stringResource(R.string.sp_automatic_preview_failed)
        }, color = if (state.error != null && !state.pending) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall)
        if (state.working) LinearProgressIndicator(Modifier.fillMaxWidth())
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            if (state.pending) TextButton(onClick = model::refresh, enabled = !state.working, modifier = Modifier.testTag("photos_automatic_refresh")) {
                Text(stringResource(R.string.sp_edit_refresh))
            }
            if (state.enabled == true) {
                TextButton(onClick = if (state.paused || state.error != null && !state.working) model::resume else model::pause,
                    modifier = Modifier.testTag("photos_automatic_toggle")) {
                    Text(stringResource(if (state.paused || state.error != null && !state.working) R.string.sp_automatic_preview_resume else R.string.sp_automatic_preview_pause))
                }
            }
        }
    }
}
