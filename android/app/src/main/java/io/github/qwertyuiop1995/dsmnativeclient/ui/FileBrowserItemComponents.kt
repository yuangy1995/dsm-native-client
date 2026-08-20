package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileViewMode
import io.github.qwertyuiop1995.dsmnativeclient.domain.previewKind

/**
 * 文件列表的纯渲染组件：状态由调用方输入，打开、预览和选择只通过回调输出。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun FileItems(
    items: List<FileItem>,
    state: WorkspaceState,
    model: AppViewModel,
    viewMode: FileViewMode,
    canLoadMore: Boolean,
    selectedPaths: Set<String>,
    onToggleSelection: (FileItem) -> Unit,
    onOpen: (FileItem) -> Unit,
    onPreview: (FileItem) -> Unit,
    onSelect: (FileItem) -> Unit,
) {
    val selectItemLabel = stringResource(R.string.select_item)
    if (viewMode == FileViewMode.GRID) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(144.dp),
            contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 120.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            gridItems(items, key = FileItem::path) { item ->
                FileGridItem(
                    item,
                    state,
                    model,
                    item.path in selectedPaths,
                    onOpen,
                    onPreview,
                    onSelect,
                    onToggleSelection,
                )
            }
            if (canLoadMore || state.fileIsLoadingMore) {
                item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                    LoadMoreFiles(state.fileIsLoadingMore, model::loadMoreFiles)
                }
            }
        }
        return
    }
    LazyColumn(
        contentPadding = PaddingValues(bottom = 96.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(items, key = FileItem::path) { item ->
            val isSelected = item.path in selectedPaths
            ListItem(
                headlineContent = {
                    Text(
                        item.name,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        fontWeight = FontWeight.Medium,
                    )
                },
                supportingContent = {
                    Text(
                        if (item.isDirectory) stringResource(R.string.folder) else formatBytes(item.size),
                        maxLines = 1,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                },
                leadingContent = {
                    FileItemThumbnail(item, state, model)
                },
                trailingContent = {
                    if (!isSelected && selectedPaths.isEmpty()) {
                        IconButton(onClick = { onSelect(item) }) {
                            Icon(
                                Icons.Outlined.MoreVert,
                                contentDescription = stringResource(R.string.more_actions),
                            )
                        }
                    }
                },
                colors = ListItemDefaults.colors(
                    containerColor = if (isSelected) {
                        MaterialTheme.colorScheme.secondaryContainer
                    } else {
                        MaterialTheme.colorScheme.surface
                    },
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .combinedClickable(
                        onClick = {
                            if (selectedPaths.isNotEmpty()) {
                                onToggleSelection(item)
                            } else if (item.isDirectory) {
                                onOpen(item)
                            } else {
                                onPreview(item)
                            }
                        },
                        onLongClickLabel = selectItemLabel,
                        onLongClick = { onToggleSelection(item) },
                    ).semantics { selected = isSelected },
            )
            HorizontalDivider(
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f),
                modifier = Modifier.padding(start = 72.dp),
            )
        }
        if (canLoadMore || state.fileIsLoadingMore) {
            item { LoadMoreFiles(state.fileIsLoadingMore, model::loadMoreFiles) }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun FileGridItem(
    item: FileItem,
    state: WorkspaceState,
    model: AppViewModel,
    isSelected: Boolean,
    onOpen: (FileItem) -> Unit,
    onPreview: (FileItem) -> Unit,
    onSelect: (FileItem) -> Unit,
    onToggleSelection: (FileItem) -> Unit,
) {
    val selectItemLabel = stringResource(R.string.select_item)
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .combinedClickable(
                onClick = {
                    if (state.fileBrowser.selectedPaths.isNotEmpty()) {
                        onToggleSelection(item)
                    } else if (item.isDirectory) {
                        onOpen(item)
                    } else {
                        onPreview(item)
                    }
                },
                onLongClickLabel = selectItemLabel,
                onLongClick = { onToggleSelection(item) },
            ).semantics { selected = isSelected },
        colors = CardDefaults.cardColors(
            containerColor = if (isSelected) {
                MaterialTheme.colorScheme.secondaryContainer
            } else {
                MaterialTheme.colorScheme.surfaceContainer
            },
        ),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(contentAlignment = Alignment.TopEnd) {
                Box(Modifier.size(72.dp), contentAlignment = Alignment.Center) {
                    FileItemThumbnail(item, state, model)
                }
                if (state.fileBrowser.selectedPaths.isEmpty()) {
                    IconButton(
                        onClick = { onSelect(item) },
                        modifier = Modifier.size(48.dp),
                    ) {
                        Icon(Icons.Outlined.MoreVert, stringResource(R.string.more_actions))
                    }
                }
            }
            Text(
                item.name,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
            )
            Text(
                if (item.isDirectory) stringResource(R.string.folder) else formatBytes(item.size),
                maxLines = 1,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun LoadMoreFiles(loading: Boolean, onLoadMore: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(
                modifier = Modifier.size(32.dp),
                strokeWidth = 3.dp,
            )
        } else {
            TextButton(onClick = onLoadMore) {
                Text(stringResource(R.string.load_more_files))
            }
        }
    }
}

@Composable
internal fun FileItemThumbnail(
    item: FileItem,
    state: WorkspaceState,
    model: AppViewModel,
) {
    val canLoadThumbnail = state.supportsThumbnails && item.previewKind() == FilePreviewKind.IMAGE
    if (canLoadThumbnail) {
        DisposableEffect(item.path, state.profile.id) {
            model.acquireThumbnail(item, state.profile.id)
            onDispose { model.releaseThumbnail(item.path, state.profile.id) }
        }
    }
    @Suppress("UNUSED_VARIABLE")
    val generation = state.thumbnailGeneration
    val bitmap = if (canLoadThumbnail) model.thumbnail(item.path, state.profile.id) else null
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(
                if (item.isDirectory) {
                    MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.7f)
                } else {
                    MaterialTheme.colorScheme.surfaceContainerHigh
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Icon(
                if (item.isDirectory) Icons.Outlined.Folder else Icons.AutoMirrored.Outlined.InsertDriveFile,
                contentDescription = null,
                tint = if (item.isDirectory) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
                modifier = Modifier.size(22.dp),
            )
        }
    }
}
