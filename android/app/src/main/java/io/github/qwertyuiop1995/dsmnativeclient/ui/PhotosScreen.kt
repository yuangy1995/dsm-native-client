package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ExpandMore
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*

import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.PickVisualMediaRequest
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.RestoreFromTrash
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.FileStationMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.POST_NOTIFICATIONS_PERMISSION
import io.github.qwertyuiop1995.dsmnativeclient.PreviewOwner
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItemKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoBrowseMode
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoMediaFilter
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoSpace
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoSpaceAccess
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoSpaceKind
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import androidx.core.content.ContextCompat
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged

internal fun useInlinePhotoPreview(screenWidthDp: Int, hasPreview: Boolean): Boolean =
    AdaptiveLayoutPolicy.usesPhotoListDetail(screenWidthDp, hasPreview)

internal fun thumbnailPrefetchItems(
    items: List<PhotoItem>,
    visibleIndices: Collection<Int>,
    maximumItems: Int = 4,
): List<PhotoItem> {
    if (maximumItems <= 0) return emptyList()
    val visible = visibleIndices.filterTo(sortedSetOf()) { it in items.indices }
    val lastVisible = visible.lastOrNull() ?: return emptyList()
    return ((lastVisible + 1)..items.lastIndex)
        .asSequence()
        .filterNot(visible::contains)
        .map(items::get)
        .filter { it.kind in setOf(PhotoItemKind.IMAGE, PhotoItemKind.VIDEO) }
        .take(maximumItems)
        .toList()
}

@Composable
internal fun PhotosScreen(state: WorkspaceState, model: AppViewModel) {
    val library = remember(state.profile.id, model) { model.photoLibraryFor(state.profile.id) }
    var showBackup by remember { mutableStateOf(false) }
    val entry = LocalClientEntry.current
    LaunchedEffect(entry?.revision) {
        if (entry?.action == ClientEntryAction.PHOTO_BACKUP) showBackup = true
        entry?.consume()
    }
    if (library != null) {
        io.github.qwertyuiop1995.dsmnativeclient.ui.photos.SynologyPhotosLibrary(library, state.supportsUploads) { showBackup = true }
    } else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    io.github.qwertyuiop1995.dsmnativeclient.ui.photos.PhotoBackupSheet(state, model, showBackup) { showBackup = false }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun PhotoCard(
    item: PhotoItem,
    state: WorkspaceState,
    model: AppViewModel,
    onClick: () -> Unit,
    onAction: () -> Unit,
) {
    Card(
        shape = RoundedCornerShape(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .combinedClickable(onClick = onClick, onLongClickLabel = stringResource(R.string.more_actions), onLongClick = onAction),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .background(MaterialTheme.colorScheme.surfaceContainerHigh),
            contentAlignment = Alignment.Center,
        ) {
            when (item.kind) {
                PhotoItemKind.IMAGE,
                PhotoItemKind.VIDEO,
                -> PhotoThumbnail(item, state, model)
                PhotoItemKind.FOLDER -> Icon(
                    Icons.Outlined.Folder,
                    contentDescription = null,
                    modifier = Modifier.size(48.dp),
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
            if (item.kind == PhotoItemKind.FOLDER) Text(
                item.file.name,
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.BottomCenter)
                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.9f))
                    .padding(8.dp),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.labelMedium,
            )

        }
    }
}

@Composable
private fun PhotoThumbnail(item: PhotoItem, state: WorkspaceState, model: AppViewModel) {
    @Suppress("UNUSED_VARIABLE")
    val generation = state.thumbnailGeneration
    val bitmap = if (state.supportsThumbnails) {
        model.thumbnail(item.file.path, state.profile.id)
    } else {
        null
    }
    PhotoThumbnailArtwork(item, bitmap)
}

@Composable
internal fun PhotoThumbnailArtwork(item: PhotoItem, bitmap: Bitmap?) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (bitmap == null) {
            Icon(
                Icons.Outlined.Image,
                contentDescription = stringResource(
                    if (item.kind == PhotoItemKind.VIDEO) {
                        R.string.video_thumbnail_description
                    } else {
                        R.string.photo_thumbnail_description
                    },
                    item.file.name,
                ),
                modifier = Modifier.size(48.dp),
                tint = MaterialTheme.colorScheme.primary,
            )
        } else {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = stringResource(
                    if (item.kind == PhotoItemKind.VIDEO) {
                        R.string.video_thumbnail_description
                    } else {
                        R.string.photo_thumbnail_description
                    },
                    item.file.name,
                ),
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
        if (item.kind == PhotoItemKind.VIDEO) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.86f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Outlined.PlayArrow,
                    contentDescription = stringResource(R.string.play_video_preview, item.file.name),
                    modifier = Modifier.size(30.dp),
                    tint = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}
