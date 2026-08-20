package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItemKind
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * 照片网格只接收页面状态与事件出口；缩略图引用的获取和释放保持与原页面相同的窗口语义。
 */
@Composable
internal fun PhotoGrid(
    state: WorkspaceState,
    items: List<PhotoItem>,
    model: AppViewModel,
    hasMore: Boolean,
    onAction: (PhotoItem) -> Unit,
) {
    val gridState = rememberLazyGridState()
    PhotoThumbnailWindowEffect(
        gridState = gridState,
        items = items,
        profileId = state.profile.id,
        enabled = state.supportsThumbnails,
        acquireThumbnail = { item, profileId ->
            model.acquireThumbnail(item.file, profileId)
        },
        releaseThumbnail = { item, profileId ->
            model.releaseThumbnail(item.file.path, profileId)
        },
    )
    LazyVerticalGrid(
        state = gridState,
        columns = GridCells.Adaptive(120.dp),
        contentPadding = PaddingValues(12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(items, key = PhotoItem::id) { item ->
            PhotoCard(
                item = item,
                state = state,
                model = model,
                onClick = {
                    if (item.kind == PhotoItemKind.FOLDER) {
                        model.openPhotoFolder(item)
                    } else {
                        model.openPhotoViewer(item, items)
                    }
                },
                onAction = { onAction(item) },
            )
        }
        if (hasMore) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    if (state.photoBrowser.isLoadingMore) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(Modifier.size(24.dp))
                            Text(stringResource(R.string.loading_more_photos))
                        }
                    } else {
                        Button(onClick = model::loadMorePhotos) {
                            Text(stringResource(R.string.load_more_photos))
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun PhotoThumbnailWindowEffect(
    gridState: LazyGridState,
    items: List<PhotoItem>,
    profileId: String,
    enabled: Boolean,
    acquireThumbnail: (PhotoItem, String) -> Unit,
    releaseThumbnail: (PhotoItem, String) -> Unit,
) {
    LaunchedEffect(gridState, items, profileId, enabled) {
        if (!enabled) return@LaunchedEffect
        val acquired = linkedMapOf<String, PhotoItem>()
        try {
            snapshotFlow {
                val visibleIndices = gridState.layoutInfo.visibleItemsInfo
                    .map { it.index }
                    .filter { it in items.indices }
                    .distinct()
                    .sorted()
                val visibleMedia = visibleIndices
                    .map(items::get)
                    .filter { it.kind in setOf(PhotoItemKind.IMAGE, PhotoItemKind.VIDEO) }
                (visibleMedia + thumbnailPrefetchItems(items, visibleIndices))
                    .distinctBy { it.file.path }
            }.distinctUntilChanged().collect { requested ->
                val requestedPaths = requested.mapTo(mutableSetOf()) { it.file.path }
                acquired.keys.filterNot(requestedPaths::contains).toList().forEach { path ->
                    acquired.remove(path)?.let { item ->
                        releaseThumbnail(item, profileId)
                    }
                }
                requested.forEach { item ->
                    if (item.file.path !in acquired) {
                        acquireThumbnail(item, profileId)
                        acquired[item.file.path] = item
                    }
                }
            }
        } finally {
            acquired.values.forEach { item ->
                releaseThumbnail(item, profileId)
            }
        }
    }
}
