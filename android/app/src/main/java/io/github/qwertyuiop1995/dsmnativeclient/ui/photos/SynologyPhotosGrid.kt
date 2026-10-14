package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.Role
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
    val editState = model.edits?.state?.collectAsState()?.value
    val fileState = model.files?.state?.collectAsState()?.value
    val grid = rememberLazyGridState()
    model.automaticPreviews?.let { AutomaticPreviewVisibility(grid, state.items, it) }
    val locale = LocalConfiguration.current.locales[0]
    val displaySettings = state.access?.displaySettings
    val dateFormat = remember(locale, displaySettings) { SynologyPhotoDisplayFormat.date(displaySettings, locale) }
    val clipboard = LocalClipboardManager.current
    LaunchedEffect(state.navigation.locationKey, state.navigation.folders.lastOrNull()?.sort, state.selectedMonth) { grid.scrollToItem(0) }
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
            val selectingFolder = state.navigation.section == SynologyPhotosSection.FOLDERS && editState?.selecting == true && model.files != null
            val selectedFolder = editState?.selectedFolders?.any { it.id == collection.id && it.space == collection.space } == true
            val cardModifier = Modifier.fillMaxWidth().heightIn(min = 96.dp)
            val cardInteraction = if (selectingFolder) cardModifier.toggleable(selectedFolder, enabled = fileState?.working != true,
                role = Role.Checkbox, onValueChange = { model.edits?.toggleFolder(collection) }) else cardModifier.combinedClickable(
                onClick = { model.openCollection(collection) }, onLongClick = if (state.navigation.section == SynologyPhotosSection.FOLDERS && model.files != null) ({ model.edits?.toggleFolder(collection); Unit }) else null,
                onLongClickLabel = stringResource(R.string.sp_files_select))
            Card(modifier = cardInteraction.testTag("photos_collection_${collection.id}")) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (state.navigation.section == SynologyPhotosSection.FOLDERS) Box(Modifier.fillMaxWidth().heightIn(min = 48.dp), contentAlignment = Alignment.CenterStart) {
                        FolderCover(collection, model)
                        if (selectingFolder) Checkbox(selectedFolder, null, Modifier.align(Alignment.TopEnd).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.9f)))
                        else if (model.folders != null || model.files != null || model.folderSharing?.canOpen(collection) == true) {
                            var expanded by remember { mutableStateOf(false) }
                            Box(Modifier.align(Alignment.TopEnd).background(MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.9f))) {
                                IconButton(onClick = { expanded = true }, enabled = editState?.selecting != true && model.folders?.state?.collectAsState()?.value?.working != true && fileState?.working != true) {
                                    Icon(Icons.Outlined.MoreVert, stringResource(R.string.sp_folder_actions, collection.name))
                                }
                                DropdownMenu(expanded, { expanded = false }) {
                                    model.folders?.let { folders -> listOf(SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoAlbumAction.RENAME_FOLDER,
                                        SynologyPhotoAlbumAction.SORT_FOLDER, SynologyPhotoAlbumAction.COVER_FOLDER).forEach { action ->
                                        DropdownMenuItem(text = { Text(stringResource(action.folderLabel())) }, onClick = { expanded = false; folders.open(action, collection) })
                                    } }
                                    model.folderSharing?.takeIf { it.canOpen(collection) }?.let { sharing ->
                                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_folder_sharing_title)) }, onClick = { expanded = false; sharing.open(collection) })
                                    }
                                    model.files?.let { PhotoFileMenuItems(it, emptyList(), listOf(collection)) { expanded = false } }
                                }
                            }
                        }
                    }
                    else if (state.navigation.showsCollectionRoot && model.albums != null) AlbumCover(collection.id, model)
                    else if (state.navigation.category == SynologyPhotoCategory.SUBJECTS) PhotoConceptCardHeader(collection, model.concepts)
                    else if (state.navigation.category == SynologyPhotoCategory.PEOPLE) PhotoPersonCardHeader(collection, model.people)
                    else Icon(Icons.Outlined.Folder, null)
                    Text(if (state.navigation.category == SynologyPhotoCategory.PEOPLE) personName(collection) else collection.name, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        items(state.visibleSharing, key = { "shared:${it.id}" }, span = { GridItemSpan(maxLineSpan) }) { shared ->
            ListItem(headlineContent = { Text(shared.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(enabled = shared.albumId != null) { model.openSharedAlbum(shared) },
                trailingContent = {
                    Row {
                        shared.url?.let { url -> IconButton(onClick = { clipboard.setText(AnnotatedString(url)) }) { Icon(Icons.Outlined.ContentCopy, stringResource(R.string.sp_copy_link)) } }
                        if (state.navigation.isRequests) model.requests?.let { requests ->
                            var expanded by remember { mutableStateOf(false) }
                            Box {
                                IconButton(onClick = { expanded = true }, enabled = !requests.state.collectAsState().value.working) {
                                    Icon(Icons.Outlined.MoreVert, stringResource(R.string.sp_request_actions, shared.title))
                                }
                                DropdownMenu(expanded, { expanded = false }) {
                                    DropdownMenuItem(text = { Text(stringResource(R.string.sp_request_edit)) }, onClick = { expanded = false; requests.open(shared.id) })
                                    DropdownMenuItem(text = { Text(stringResource(R.string.sp_request_delete)) }, onClick = { expanded = false; requests.open(shared.id, delete = true) })
                                }
                            }
                        }
                    }
                })
        }
        if (state.navigation.section == SynologyPhotosSection.FOLDERS || state.navigation.album != null) {
            items(state.items, key = { "photo:${it.id}" }) { photo ->
                SynologyPhotoTile(photo, model, onClick = { if (photo.similarGroup != null && model.similar != null) model.similar.open(photo) else model.preview.open(photo) },
                    selected = if (editState?.selecting == true) editState.selected.any { it.id == photo.id } else null,
                    onSelect = model.edits?.let { edits -> { edits.toggle(photo) } })
            }
        } else state.groups.forEach { group ->
            item(key = "date:${group.date}", span = { GridItemSpan(maxLineSpan) }) {
                Text(group.date.format(dateFormat), style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 12.dp).semantics { heading() })
            }
            items(group.items, key = { "photo:${it.id}" }) { photo ->
                SynologyPhotoTile(photo, model, onClick = { if (photo.similarGroup != null && model.similar != null) model.similar.open(photo) else model.preview.open(photo) },
                    selected = if (editState?.selecting == true) editState.selected.any { it.id == photo.id } else null,
                    onSelect = model.edits?.let { edits -> { edits.toggle(photo) } })
            }
        }
        if (state.empty && state.error == null && (!state.navigation.showsCollectionRoot || state.categories.isEmpty())) {
            item(key = "empty", span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.sp_empty_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(when {
                        state.navigation.filter.isActive || state.navigation.keyword.isNotEmpty() || state.navigation.isRequests && state.requestSearch.isNotEmpty() -> R.string.sp_library_no_results
                        state.navigation.section == SynologyPhotosSection.SHARING -> R.string.sp_sharing_empty
                        state.navigation.showsCollectionRoot -> R.string.sp_library_no_albums
                        else -> R.string.sp_library_empty
                    }))
                    val searching = state.navigation.filter.isActive || state.navigation.keyword.isNotEmpty() || state.navigation.isRequests && state.requestSearch.isNotEmpty()
                    TextButton(onClick = { if (searching) model.search("") else model.refresh() }) {
                        Text(stringResource(if (searching) R.string.sp_filters_clear else R.string.sp_library_refresh))
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
private fun FolderCover(folder: SynologyPhotoCollection, model: SynologyPhotosModel) {
    if (folder.folderCovers.isEmpty()) { Icon(Icons.Outlined.Folder, null); return }
    Column(Modifier.fillMaxWidth().aspectRatio(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        folder.folderCovers.chunked(2).forEach { row ->
            Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                row.forEach { cover ->
                    val bitmap by produceState<Bitmap?>(null, folder.id, folder.space, cover, model) {
                        try { value = PhotoBitmapDecoder.decode(model.folderThumbnail(folder, cover), 512) }
                        catch (error: Exception) { if (error is CancellationException) throw error }
                    }
                    Box(Modifier.weight(1f).fillMaxHeight().background(MaterialTheme.colorScheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
                        val image = bitmap
                        if (image == null) Icon(Icons.Outlined.Image, null)
                        else Image(image.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    }
                }
                if (row.size == 1 && folder.folderCovers.size > 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun AlbumCover(id: Long, model: SynologyPhotosModel) {
    val bitmap by produceState<Bitmap?>(null, id, model) {
        try { value = PhotoBitmapDecoder.decode(model.albumThumbnail(id), 512) }
        catch (error: Exception) { if (error is CancellationException) throw error }
    }
    Box(Modifier.fillMaxWidth().aspectRatio(1f).background(MaterialTheme.colorScheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
        val image = bitmap
        if (image == null) Icon(Icons.Outlined.Image, null)
        else Image(image.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    }
}

@Composable
internal fun SynologyPhotoTile(photo: SynologyPhoto, model: SynologyPhotosModel, onClick: () -> Unit,
    selected: Boolean? = null, onSelect: (() -> Unit)? = null, singleChoice: Boolean = false) {
    val bitmap by produceState<Bitmap?>(null, photo.id, photo.thumbnail, photo.albumContext, photo.orientation, model) {
        value = null
        try { value = PhotoBitmapDecoder.decode(model.thumbnail(photo), 512) }
        catch (error: Exception) { if (error is CancellationException) throw error }
    }
    val description = stringResource(if (photo.mediaType == "video") R.string.video_thumbnail_description else R.string.photo_thumbnail_description, photo.filename)
    val interaction = if (selected != null && singleChoice) Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).selectable(selected, role = Role.RadioButton, onClick = { onSelect?.invoke() })
        else if (selected != null) Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).toggleable(selected, role = Role.Checkbox, onValueChange = { onSelect?.invoke() })
        else Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).combinedClickable(onClick = onClick, onLongClick = onSelect, onLongClickLabel = stringResource(R.string.sp_edit_select))
    Box(Modifier.fillMaxWidth().aspectRatio(1f).heightIn(min = 48.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh).then(interaction), contentAlignment = Alignment.Center) {
        val image = bitmap
        if (image != null) Image(image.asImageBitmap(), description, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Icon(Icons.Outlined.Image, description, Modifier.size(40.dp))
        if (selected != null) {
            val indicator = Modifier.align(Alignment.TopEnd).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.9f))
            if (singleChoice) RadioButton(selected, null, indicator) else Checkbox(selected, null, indicator)
        }
        photo.similarGroup?.let { group ->
            Text(stringResource(R.string.sp_similar_group_count, java.text.NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0]).format(group.photoIds.size)),
                Modifier.align(Alignment.TopStart).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.9f)).padding(8.dp), style = MaterialTheme.typography.labelMedium)
        }
        when (photo.mediaType) {
            "video" -> Icon(Icons.Outlined.PlayArrow, null, Modifier.align(Alignment.BottomEnd).padding(8.dp).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.85f)))
            "live" -> Text(stringResource(R.string.sp_live), Modifier.align(Alignment.BottomStart).padding(8.dp).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.85f)), style = MaterialTheme.typography.labelSmall)
        }
    }
}
