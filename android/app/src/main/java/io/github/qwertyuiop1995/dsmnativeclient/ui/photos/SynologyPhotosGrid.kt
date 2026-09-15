package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import java.nio.ByteBuffer
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/** 解码与网络分别限流，ImageDecoder 负责 EXIF 方向；不把原始分辨率位图加载到主线程。 */
internal object PhotoBitmapDecoder {
    private val permits = Semaphore(4)
    suspend fun decode(data: ByteArray, maximumDimension: Int): Bitmap = permits.withPermit {
        withContext(Dispatchers.Default) {
            ensureActive()
            val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(data))) { decoder, info, _ ->
                val longest = maxOf(info.size.width, info.size.height)
                require(longest > 0 && maximumDimension > 0)
                val ratio = minOf(1.0, maximumDimension.toDouble() / longest)
                decoder.setTargetSize(maxOf(1, (info.size.width * ratio).toInt()), maxOf(1, (info.size.height * ratio).toInt()))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
            try { ensureActive(); bitmap } catch (error: CancellationException) { bitmap.recycle(); throw error }
        }
    }
}

@Composable
internal fun SynologyPhotosGrid(state: SynologyPhotosState, model: SynologyPhotosModel) {
    val grid = rememberLazyGridState()
    val locale = LocalConfiguration.current.locales[0]
    val dateFormat = remember(locale) { DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale) }
    val clipboard = LocalClipboardManager.current
    LaunchedEffect(state.navigation, state.selectedMonth) { grid.scrollToItem(0) }
    LaunchedEffect(grid, model, state.paginationKey, state.hasMore, state.hasMoreCollections, state.error) {
        snapshotFlow {
            val layout = grid.layoutInfo
            layout.totalItemsCount > 0 && (layout.visibleItemsInfo.lastOrNull()?.index ?: -1) >= layout.totalItemsCount - 8
        }.distinctUntilChanged().collect { atEnd -> if (atEnd) model.loadMore(automatic = true) }
    }
    LazyVerticalGrid(columns = GridCells.Adaptive(120.dp), state = grid, modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (state.hasPrevious) item(key = "previous", span = { GridItemSpan(maxLineSpan) }) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                state.previousError?.let { Text(photoError(it), color = MaterialTheme.colorScheme.error) }
                TextButton(onClick = { model.loadPrevious() }, enabled = !state.loadingPrevious) {
                    if (state.loadingPrevious) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    Text(stringResource(R.string.sp_timeline_newer), Modifier.padding(8.dp))
                }
            }
        }
        if (state.navigation.showsCollectionRoot) {
            state.categoriesError?.let { error -> item(key = "categoriesError", span = { GridItemSpan(maxLineSpan) }) {
                PhotoErrorPanel(error, onRetry = { model.refresh() })
            } }
            items(state.categories.toList(), key = { "category:${it.name}" }) { category ->
                Card(onClick = { model.openCategory(category) }, modifier = Modifier.fillMaxWidth().heightIn(min = 96.dp)) {
                    Text(stringResource(category.label()), Modifier.padding(16.dp), style = MaterialTheme.typography.titleSmall)
                }
            }
        }
        items(state.collections, key = { "collection:${it.id}" }) { collection ->
            Card(onClick = { model.openCollection(collection) }, modifier = Modifier.fillMaxWidth().heightIn(min = 96.dp)) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Outlined.Folder, null)
                    Text(collection.name, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        items(state.sharing, key = { "shared:${it.id}" }, span = { GridItemSpan(maxLineSpan) }) { shared ->
            ListItem(headlineContent = { Text(shared.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                modifier = Modifier.clickable(enabled = shared.albumId != null) { model.openSharedAlbum(shared) },
                trailingContent = {
                    shared.url?.let { url -> IconButton(onClick = { clipboard.setText(AnnotatedString(url)) }) {
                        Icon(Icons.Outlined.ContentCopy, stringResource(R.string.sp_copy_link))
                    } }
                })
        }
        state.groups.forEach { group ->
            item(key = "date:${group.date}", span = { GridItemSpan(maxLineSpan) }) {
                Text(group.date.format(dateFormat), style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 12.dp).semantics { heading() })
            }
            items(group.items, key = { "photo:${it.id}" }) { photo ->
                SynologyPhotoTile(photo, model, onClick = { model.preview.open(photo) })
            }
        }
        if (state.empty && state.error == null && (!state.navigation.showsCollectionRoot || state.categories.isEmpty())) {
            item(key = "empty", span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.sp_empty_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(when {
                        state.navigation.filter.isActive || state.navigation.keyword.isNotEmpty() -> R.string.sp_library_no_results
                        state.navigation.section == SynologyPhotosSection.SHARING -> R.string.sp_sharing_empty
                        state.navigation.showsCollectionRoot -> R.string.sp_library_no_albums
                        else -> R.string.sp_library_empty
                    }))
                    TextButton(onClick = { if (state.navigation.filter.isActive || state.navigation.keyword.isNotEmpty()) model.search("") else model.refresh() }) {
                        Text(stringResource(if (state.navigation.filter.isActive || state.navigation.keyword.isNotEmpty()) R.string.sp_filters_clear else R.string.sp_library_refresh))
                    }
                }
            }
        }
        state.error?.let { error -> item(key = "error", span = { GridItemSpan(maxLineSpan) }) {
            PhotoErrorPanel(error, onRetry = { if (state.hasMore || state.hasMoreCollections) model.loadMore() else model.refresh() })
        } }
        if (state.hasMore || state.hasMoreCollections) item(key = "next", span = { GridItemSpan(maxLineSpan) }) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                if (state.loadingMore) CircularProgressIndicator(Modifier.padding(16.dp))
                else TextButton(onClick = { model.loadMore() }) { Text(stringResource(if (state.hasMoreCollections) R.string.sp_library_more_collections else R.string.sp_library_more)) }
            }
        }
    }
}

@Composable
internal fun SynologyPhotoTile(photo: SynologyPhoto, model: SynologyPhotosModel, onClick: () -> Unit) {
    val bitmap by produceState<Bitmap?>(null, photo.id, photo.thumbnail, model) {
        value = null
        try { value = PhotoBitmapDecoder.decode(model.thumbnail(photo), 512) }
        catch (error: Exception) { if (error is CancellationException) throw error }
    }
    val description = stringResource(if (photo.mediaType == "video") R.string.video_thumbnail_description else R.string.photo_thumbnail_description, photo.filename)
    Box(Modifier.fillMaxWidth().aspectRatio(1f).background(MaterialTheme.colorScheme.surfaceContainerHigh).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        val image = bitmap
        if (image != null) Image(image.asImageBitmap(), description, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Icon(Icons.Outlined.Image, description, Modifier.size(40.dp))
        when (photo.mediaType) {
            "video" -> Icon(Icons.Outlined.PlayArrow, null, Modifier.align(Alignment.BottomEnd).padding(8.dp).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.85f)))
            "live" -> Text(stringResource(R.string.sp_live), Modifier.align(Alignment.BottomStart).padding(8.dp).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.85f)), style = MaterialTheme.typography.labelSmall)
        }
    }
}
