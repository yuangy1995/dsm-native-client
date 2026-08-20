package io.github.qwertyuiop1995.dsmnativeclient.ui

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
    BoxWithConstraints(Modifier.fillMaxSize()) {
        PhotosContent(
            state = state,
            model = model,
            availableWidthDp = maxWidth.value.toInt(),
        )
    }
}

@Composable
private fun PhotosContent(
    state: WorkspaceState,
    model: AppViewModel,
    availableWidthDp: Int,
) {
    val browser = state.photoBrowser
    val page = (state.photos as? Loadable.Ready)?.value
    val visibleItems = page?.let(browser::visibleItems).orEmpty()
    val timeline = (state.photoTimeline as? Loadable.Ready)?.value
    val visibleTimelineItems = timeline?.let(browser::visibleTimelineItems).orEmpty()
    val focusManager = LocalFocusManager.current
    val context = LocalContext.current
    val photoPreviewItem = state.previewItem.takeIf {
        state.previewOwner == PreviewOwner.PHOTOS &&
            state.photoViewer?.current?.path == state.previewItem?.path
    }
    val inlinePreview = useInlinePhotoPreview(
        availableWidthDp,
        photoPreviewItem != null,
    )
    var selectedPhoto by remember { mutableStateOf<PhotoItem?>(null) }
    var pendingExport by rememberSaveable(
        state.profile.id,
        stateSaver = PendingDownloadRequestStateSaver,
    ) { mutableStateOf(PendingDownloadRequestState()) }
    var showNotificationPermission by remember { mutableStateOf(false) }
    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { showNotificationPermission = false }
    val backupPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(50),
    ) { uris ->
        if (uris.isNotEmpty()) {
            model.enqueuePhotoBackups(uris)
            val needsPermission = Build.VERSION.SDK_INT >= 33 &&
                ContextCompat.checkSelfPermission(context, POST_NOTIFICATIONS_PERMISSION) !=
                PackageManager.PERMISSION_GRANTED
            if (needsPermission) showNotificationPermission = true
        }
    }
    val backupFolderPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree(),
    ) { uri ->
        uri?.let(model::configurePhotoBackupSource)
    }
    val exportLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        val resolution = resolveDownloadDestination(
            pending = pendingExport,
            activeProfileId = state.profile.id,
            destinationSelected = uri != null,
        )
        pendingExport = resolution.nextPending
        when (resolution.decision) {
            DownloadDestinationDecision.CANCELLED -> Unit
            DownloadDestinationDecision.DISCARD_ORPHAN -> {
                if (uri != null) model.discardUnmatchedDownloadDestination(uri)
            }
            DownloadDestinationDecision.ENQUEUE -> {
                if (uri == null) return@rememberLauncherForActivityResult
                val item = resolution.request?.toFileItem() ?: run {
                    model.discardUnmatchedDownloadDestination(uri)
                    return@rememberLauncherForActivityResult
                }
                val enqueueResult = model.enqueueDownload(item, uri)
                val permissionGranted = ContextCompat.checkSelfPermission(
                    context,
                    POST_NOTIFICATIONS_PERMISSION,
                ) == PackageManager.PERMISSION_GRANTED
                if (shouldRequestDownloadNotificationPermission(
                        enqueueResult = enqueueResult,
                        sdkInt = Build.VERSION.SDK_INT,
                        notificationPermissionGranted = permissionGranted,
                    )
                ) {
                    showNotificationPermission = true
                }
            }
        }
    }

    Row(Modifier.fillMaxSize()) {
    Column(
        if (inlinePreview) Modifier.width(520.dp).fillMaxHeight() else Modifier.fillMaxSize(),
    ) {
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(browser.spaces.size) { index ->
                val space = browser.spaces[index]
                PhotoSpaceChip(
                    space = space,
                    selected = space.id == browser.selectedSpaceId,
                    access = browser.spaceAccess[space.id] ?: PhotoSpaceAccess.UNKNOWN,
                    onClick = { model.selectPhotoSpace(space.id) },
                )
            }
        }
        Row(
            modifier = Modifier.padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            PhotoBrowseMode.entries.forEach { mode ->
                FilterChip(
                    selected = browser.mode == mode,
                    onClick = { model.setPhotoMode(mode) },
                    label = { Text(photoModeTitle(mode)) },
                )
            }
        }
        if (state.supportsUploads) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                Button(
                    onClick = {
                        backupPicker.launch(
                            PickVisualMediaRequest(
                                ActivityResultContracts.PickVisualMedia.ImageAndVideo,
                            ),
                        )
                    },
                ) {
                    Icon(Icons.Outlined.CloudUpload, contentDescription = null)
                    Text(
                        stringResource(R.string.back_up_selected_photos),
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
            }
            Text(
                text = stringResource(R.string.photo_backup_conditions),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp),
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                if (state.photoBackupSourceEnabled) {
                    TextButton(onClick = model::disablePhotoBackupSource) {
                        Text(stringResource(R.string.stop_automatic_photo_discovery))
                    }
                } else {
                    TextButton(onClick = { backupFolderPicker.launch(null) }) {
                        Icon(Icons.Outlined.FolderOpen, contentDescription = null)
                        Text(
                            stringResource(R.string.choose_automatic_backup_folder),
                            modifier = Modifier.padding(start = 8.dp),
                        )
                    }
                }
            }
        }
        if (browser.mode == PhotoBrowseMode.FOLDERS) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(
                    onClick = model::goBackPhotoFolder,
                    enabled = browser.pathHistory.isNotEmpty(),
                    modifier = Modifier.size(48.dp),
                ) {
                    Icon(
                        Icons.AutoMirrored.Outlined.ArrowBack,
                        contentDescription = stringResource(R.string.photo_folder_up),
                    )
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        photoSpaceTitle(browser.selectedSpace),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    if (browser.pathHistory.isNotEmpty()) {
                        Text(
                            browser.folderPath.substringAfterLast('/'),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
        OutlinedTextField(
            value = browser.searchQuery,
            onValueChange = model::updatePhotoSearchQuery,
            label = { Text(stringResource(R.string.search_photos)) },
            leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
            trailingIcon = {
                TextButton(
                    onClick = {
                        model.searchPhotos()
                        focusManager.clearFocus()
                    },
                ) { Text(stringResource(R.string.submit_photo_search)) }
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = {
                model.searchPhotos()
                focusManager.clearFocus()
            }),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(PhotoMediaFilter.entries.size) { index ->
                val filter = PhotoMediaFilter.entries[index]
                FilterChip(
                    selected = browser.filter == filter,
                    onClick = { model.setPhotoFilter(filter) },
                    label = { Text(photoFilterTitle(filter)) },
                )
            }
        }
        if (browser.mode == PhotoBrowseMode.TIMELINE && timeline != null) {
            PhotoDateFilters(state, model)
        }
        Box(Modifier.fillMaxSize()) {
            if (browser.mode == PhotoBrowseMode.FOLDERS) {
                when (val photos = state.photos) {
                    Loadable.Idle, Loadable.Loading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                    is Loadable.Failed -> PhotoFailure(photos, onRetry = { model.load() })
                    is Loadable.Ready -> when {
                        photos.value.items.isEmpty() -> EmptyState(
                            stringResource(R.string.no_photos),
                            stringResource(R.string.photo_folder_empty_description),
                            Icons.Outlined.PhotoLibrary,
                        )
                        visibleItems.isEmpty() -> PhotoFilteredEmpty(model::clearPhotoFilters)
                        else -> PhotoGrid(
                            state,
                            visibleItems,
                            model,
                            photos.value.hasMore,
                            onAction = { selectedPhoto = it },
                        )
                    }
                }
            } else {
                when (val value = state.photoTimeline) {
                    Loadable.Idle, Loadable.Loading -> PhotoTimelineLoading()
                    is Loadable.Failed -> PhotoFailure(value, onRetry = { model.load() })
                    is Loadable.Ready -> when {
                        value.value.items.isEmpty() && value.value.isComplete -> EmptyState(
                            stringResource(R.string.no_photos),
                            stringResource(R.string.photo_timeline_empty_description),
                            Icons.Outlined.PhotoLibrary,
                        )
                        visibleTimelineItems.isEmpty() && value.value.items.isNotEmpty() ->
                            PhotoFilteredEmpty(model::clearPhotoFilters)
                        else -> PhotoTimelineGrid(
                            state,
                            visibleTimelineItems,
                            model,
                            onAction = { selectedPhoto = it },
                        )
                    }
                }
            }
        }
    }
    if (inlinePreview) {
        VerticalDivider()
        photoPreviewItem?.let { item ->
            val viewer = state.photoViewer
            FilePreviewDialog(
                item = item,
                preview = state.preview,
                onRetry = model::retryPreview,
                onClose = model::closePreview,
                onPrevious = model::showPreviousPhoto,
                onNext = model::showNextPhoto,
                previousEnabled = viewer?.hasPrevious == true,
                nextEnabled = viewer?.hasNext == true,
                embedded = true,
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )
        }
    }
    }

    if (!inlinePreview) photoPreviewItem?.let { item ->
        val viewer = state.photoViewer
        FilePreviewDialog(
            item = item,
            preview = state.preview,
            onRetry = model::retryPreview,
            onClose = model::closePreview,
            onPrevious = model::showPreviousPhoto,
            onNext = model::showNextPhoto,
            previousEnabled = viewer?.hasPrevious == true,
            nextEnabled = viewer?.hasNext == true,
        )
    }
    selectedPhoto?.let { item ->
        AlertDialog(
            onDismissRequest = { selectedPhoto = null },
            title = { Text(item.file.name) },
            text = {
                Column {
                    if (state.supportsFavorites) {
                        val isFavorite = item.file.path in state.favoritePaths
                        ActionRow(
                            if (isFavorite) Icons.Outlined.Star else Icons.Outlined.StarBorder,
                            stringResource(
                                if (isFavorite) R.string.remove_from_favorites else R.string.add_to_favorites,
                            ),
                        ) {
                            if (isFavorite) model.removeFavorite(item.file) else model.addFavorite(item.file)
                            selectedPhoto = null
                        }
                    }
                    if (item.kind != PhotoItemKind.FOLDER && item.file.canRead) {
                        ActionRow(Icons.Outlined.Download, stringResource(R.string.export_photo)) {
                            pendingExport = PendingDownloadRequestState(
                                item.file.toPendingDownloadRequest(state.profile.id),
                            )
                            selectedPhoto = null
                            exportLauncher.launch(item.file.name)
                        }
                    }
                    if (state.supportsCopyMove && item.file.canDelete) {
                        ActionRow(Icons.AutoMirrored.Outlined.DriveFileMove, stringResource(R.string.move_photo)) {
                            model.beginPhotoMove(item)
                            selectedPhoto = null
                        }
                    }
                    if (state.supportsSharing && item.file.canRead) {
                        ActionRow(Icons.Outlined.Share, stringResource(R.string.create_share_link)) {
                            if (model.requestPhotoShareLinkCreation(item)) selectedPhoto = null
                        }
                    }
                    if (state.supportsCopyMove && item.file.path.split('/').contains("#recycle")) {
                        ActionRow(
                            Icons.Outlined.RestoreFromTrash,
                            stringResource(R.string.restore_from_recycle_bin),
                        ) {
                            if (model.requestPhotoRestore(item)) selectedPhoto = null
                        }
                    }
                    if (item.file.canDelete) {
                        ActionRow(
                            Icons.Outlined.DeleteOutline,
                            stringResource(R.string.delete),
                            destructive = true,
                        ) {
                            if (model.requestPhotoDeletion(item)) selectedPhoto = null
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { selectedPhoto = null }) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
    if (showNotificationPermission) {
        AlertDialog(
            onDismissRequest = { showNotificationPermission = false },
            title = { Text(stringResource(R.string.notification_permission_title)) },
            text = { Text(stringResource(R.string.notification_permission_message)) },
            confirmButton = {
                TextButton(onClick = {
                    showNotificationPermission = false
                    notificationPermissionLauncher.launch(POST_NOTIFICATIONS_PERMISSION)
                }) {
                    Text(stringResource(R.string.allow_notifications))
                }
            },
            dismissButton = {
                TextButton(onClick = { showNotificationPermission = false }) {
                    Text(stringResource(R.string.not_now))
                }
            },
        )
    }
    val fileMutation = state.fileStationMutationState
    val photoConfirmation = fileMutation.draftTarget?.takeIf { target ->
        target.module == Module.PHOTOS && fileMutation.confirmationRequested &&
            target.operation in setOf(
                FileStationMutationOperation.DELETE,
                FileStationMutationOperation.MOVE,
                FileStationMutationOperation.RESTORE,
                FileStationMutationOperation.SHARE_CREATE,
            )
    }
    photoConfirmation?.let { target ->
        FileStationMutationConfirmationDialog(
            target = target,
            onConfirm = model::confirmFileStationLifecycleMutation,
            onDismiss = model::cancelPendingFileStationMutation,
        )
    }
    if (fileMutation.target?.module == Module.PHOTOS) {
        FileStationMutationFeedbackDialog(
            state = fileMutation,
            onRefresh = model::refreshFileStationMutation,
            onContinueEditing = model::continueEditingFileStationMutation,
            onDismiss = { model.dismissFileStationMutationResult(discardDraft = true) },
        )
    }
    if (
        state.photoMove != null && fileMutation.editorVisible &&
        !fileMutation.confirmationRequested && fileMutation.target == null
    ) {
        PhotoMoveDialog(state, model)
    }
}

@Composable
private fun PhotoSpaceChip(
    space: PhotoSpace,
    selected: Boolean,
    access: PhotoSpaceAccess,
    onClick: () -> Unit,
) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = {
            Text(
                if (access == PhotoSpaceAccess.UNAVAILABLE) {
                    stringResource(R.string.photo_space_unavailable, photoSpaceTitle(space))
                } else {
                    photoSpaceTitle(space)
                },
            )
        },
    )
}

@Composable
private fun PhotoTimelineGrid(
    state: WorkspaceState,
    items: List<PhotoItem>,
    model: AppViewModel,
    onAction: (PhotoItem) -> Unit,
) {
    val timeline = (state.photoTimeline as Loadable.Ready).value
    Column(Modifier.fillMaxSize()) {
        if (!timeline.isComplete || timeline.failedFolderCount > 0 || timeline.isTruncated) {
            Text(
                text = when {
                    timeline.isTruncated -> stringResource(R.string.photo_timeline_limit_reached)
                    !timeline.isComplete -> stringResource(
                        R.string.photo_timeline_scanning,
                        timeline.scannedFolderCount,
                    )
                    else -> stringResource(
                        R.string.photo_timeline_partial,
                        timeline.failedFolderCount,
                    )
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.secondaryContainer)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                color = MaterialTheme.colorScheme.onSecondaryContainer,
                style = MaterialTheme.typography.bodySmall,
            )
        }
        if (items.isNotEmpty()) {
            Box(Modifier.weight(1f)) {
                PhotoGrid(state, items, model, hasMore = false, onAction = onAction)
            }
        } else if (!timeline.isComplete) {
            PhotoTimelineLoading()
        }
    }
}

@Composable
private fun PhotoDateFilters(state: WorkspaceState, model: AppViewModel) {
    val timeline = (state.photoTimeline as? Loadable.Ready)?.value ?: return
    val browser = state.photoBrowser
    val zone = ZoneId.systemDefault()
    val datedItems = timeline.items.mapNotNull { item ->
        item.takenAtEpochSeconds?.let { Instant.ofEpochSecond(it).atZone(zone) }
    }
    val years = datedItems.map { it.year }.distinct().sortedDescending()
    val months = browser.selectedYear?.let { year ->
        datedItems.filter { it.year == year }.map { it.monthValue }.distinct().sorted()
    }.orEmpty()
    if (years.isEmpty()) return
    LazyRow(
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            FilterChip(
                selected = browser.selectedYear == null,
                onClick = { model.selectPhotoYear(null) },
                label = { Text(stringResource(R.string.photo_date_all)) },
            )
        }
        items(years.size) { index ->
            val year = years[index]
            FilterChip(
                selected = browser.selectedYear == year,
                onClick = { model.selectPhotoYear(year) },
                label = { Text(stringResource(R.string.photo_year, year)) },
            )
        }
    }
    if (browser.selectedYear != null && months.isNotEmpty()) {
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item {
                FilterChip(
                    selected = browser.selectedMonth == null,
                    onClick = { model.selectPhotoMonth(null) },
                    label = { Text(stringResource(R.string.photo_month_all)) },
                )
            }
            items(months.size) { index ->
                val month = months[index]
                FilterChip(
                    selected = browser.selectedMonth == month,
                    onClick = { model.selectPhotoMonth(month) },
                    label = { Text(stringResource(R.string.photo_month, month)) },
                )
            }
        }
    }
}

@Composable
private fun PhotoTimelineLoading() {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator()
        Text(
            stringResource(R.string.photo_timeline_preparing),
            modifier = Modifier.padding(top = 16.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun PhotoCard(
    item: PhotoItem,
    state: WorkspaceState,
    model: AppViewModel,
    onClick: () -> Unit,
    onAction: () -> Unit,
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(onClick = onClick),
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
            Text(
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
            IconButton(
                onClick = onAction,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .size(48.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.86f)),
            ) {
                Icon(Icons.Outlined.MoreVert, contentDescription = stringResource(R.string.more_actions))
            }
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

@Composable
private fun PhotoFailure(failure: Loadable.Failed, onRetry: () -> Unit) {
    val localized = failure.error.localize(LocalContext.current)
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.PhotoLibrary, contentDescription = null, modifier = Modifier.size(48.dp))
        Text(localized.message, modifier = Modifier.padding(top = 16.dp), fontWeight = FontWeight.SemiBold)
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
private fun PhotoFilteredEmpty(onClear: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.Search, contentDescription = null, modifier = Modifier.size(48.dp))
        Text(
            stringResource(R.string.no_matching_photos),
            modifier = Modifier.padding(top = 16.dp),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            stringResource(R.string.no_matching_photos_description),
            modifier = Modifier.padding(top = 8.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onClear, modifier = Modifier.padding(top = 20.dp)) {
            Text(stringResource(R.string.clear_photo_filters))
        }
    }
}

@Composable
private fun photoSpaceTitle(space: PhotoSpace): String = stringResource(
    when (space.kind) {
        PhotoSpaceKind.PERSONAL -> R.string.photo_personal_space
        PhotoSpaceKind.SHARED -> R.string.photo_shared_space
    },
)

@Composable
private fun photoFilterTitle(filter: PhotoMediaFilter): String = stringResource(
    when (filter) {
        PhotoMediaFilter.ALL -> R.string.photo_filter_all
        PhotoMediaFilter.PHOTOS -> R.string.photo_filter_photos
        PhotoMediaFilter.VIDEOS -> R.string.photo_filter_videos
    },
)

@Composable
private fun photoModeTitle(mode: PhotoBrowseMode): String = stringResource(
    when (mode) {
        PhotoBrowseMode.FOLDERS -> R.string.photo_mode_folders
        PhotoBrowseMode.TIMELINE -> R.string.photo_mode_timeline
    },
)
