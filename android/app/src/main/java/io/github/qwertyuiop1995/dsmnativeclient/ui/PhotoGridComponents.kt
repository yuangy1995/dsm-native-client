package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItemKind
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoBrowseMode

internal data class PhotoGridEntry(val indices: List<Int>, val date: LocalDate? = null)

/** 日期标题与三图组合只改变布局，显式保留到原照片索引的映射。 */
internal fun photoGridEntries(items: List<PhotoItem>, timeline: Boolean, zone: ZoneId): List<PhotoGridEntry> {
    if (!timeline) return items.indices.map { PhotoGridEntry(listOf(it)) }
    return buildList {
        items.indices.groupBy { index -> items[index].takenAtEpochSeconds?.let { Instant.ofEpochSecond(it).atZone(zone).toLocalDate() } }
            .forEach { (date, indices) ->
                add(PhotoGridEntry(emptyList(), date))
                if (indices.size >= 3) {
                    add(PhotoGridEntry(indices.take(3)))
                    indices.drop(3).forEach { add(PhotoGridEntry(listOf(it))) }
                } else indices.forEach { add(PhotoGridEntry(listOf(it))) }
            }
    }
}

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
    val zone = ZoneId.systemDefault()
    val entries = remember(items, state.photoBrowser.mode, zone) {
        photoGridEntries(items, state.photoBrowser.mode == PhotoBrowseMode.TIMELINE, zone)
    }
    val locale = LocalConfiguration.current.locales[0]
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
        displayedIndices = entries.map { it.indices },
    )
    LazyVerticalGrid(
        state = gridState,
        columns = GridCells.Adaptive(112.dp),
        contentPadding = PaddingValues(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        items(entries, key = { entry -> if (entry.indices.isEmpty()) "date:${entry.date}" else "photos:${items[entry.indices.first()].id}" },
            span = { if (it.indices.size == 1) GridItemSpan(1) else GridItemSpan(maxLineSpan) }) { entry ->
            when (entry.indices.size) {
                0 -> Text(entry.date?.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale))
                    ?: stringResource(R.string.client_undated_photos), style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp))
                1 -> PhotoGridCard(items[entry.indices[0]], items, state, model, onAction)
                else -> BoxWithConstraints {
                    val side = (maxWidth - 8.dp) / 3
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Box(Modifier.width(side * 2 + 4.dp)) { PhotoGridCard(items[entry.indices[0]], items, state, model, onAction) }
                        Column(Modifier.width(side), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            PhotoGridCard(items[entry.indices[1]], items, state, model, onAction)
                            PhotoGridCard(items[entry.indices[2]], items, state, model, onAction)
                        }
                    }
                }
            }
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
private fun PhotoGridCard(item: PhotoItem, sequence: List<PhotoItem>, state: WorkspaceState, model: AppViewModel, onAction: (PhotoItem) -> Unit) {
    PhotoCard(item, state, model, onClick = {
        if (item.kind == PhotoItemKind.FOLDER) model.openPhotoFolder(item) else model.openPhotoViewer(item, sequence)
    }, onAction = { onAction(item) })
}

@Composable
internal fun PhotoThumbnailWindowEffect(
    gridState: LazyGridState,
    items: List<PhotoItem>,
    profileId: String,
    enabled: Boolean,
    acquireThumbnail: (PhotoItem, String) -> Unit,
    releaseThumbnail: (PhotoItem, String) -> Unit,
    displayedIndices: List<List<Int>> = items.indices.map { listOf(it) },
) {
    LaunchedEffect(gridState, items, profileId, enabled, displayedIndices) {
        if (!enabled) return@LaunchedEffect
        val acquired = linkedMapOf<String, PhotoItem>()
        try {
            snapshotFlow {
                val visibleIndices = gridState.layoutInfo.visibleItemsInfo
                    .flatMap { displayedIndices.getOrNull(it.index).orEmpty() }
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
