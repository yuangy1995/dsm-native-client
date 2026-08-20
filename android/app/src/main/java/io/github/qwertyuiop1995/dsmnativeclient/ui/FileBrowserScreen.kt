package io.github.qwertyuiop1995.dsmnativeclient.ui

import android.content.pm.PackageManager
import android.os.Build
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.automirrored.outlined.Sort
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FileCopy
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.RestoreFromTrash
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.ExperimentalMaterialApi
import androidx.compose.material.pullrefresh.PullRefreshIndicator
import androidx.compose.material.pullrefresh.pullRefresh
import androidx.compose.material.pullrefresh.rememberPullRefreshState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.core.content.ContextCompat
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.FileCopyMoveOperation
import io.github.qwertyuiop1995.dsmnativeclient.FileStationMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.POST_NOTIFICATIONS_PERMISSION
import io.github.qwertyuiop1995.dsmnativeclient.PreviewOwner
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBrowserState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileShareLink
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveFormat
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileSortOption
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileTypeFilter
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileViewMode
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.previewKind
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize

internal fun useInlineFilePreview(screenWidthDp: Int, hasPreview: Boolean): Boolean =
    AdaptiveLayoutPolicy.usesFileListDetail(screenWidthDp, hasPreview)

internal fun filePageUiState(
    files: Loadable<FilePage>,
    browser: FileBrowserState,
): PageUiState<FilePage> {
    val hasConstraint = browser.activeSearchQuery != null ||
        browser.typeFilter != FileTypeFilter.ALL
    return files.toPageUiState(
        isEmpty = { page -> browser.visibleItems(page.items).isEmpty() },
        isFilteredEmpty = { page ->
            hasConstraint && browser.visibleItems(page.items).isEmpty()
        },
    )
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterialApi::class)
@Composable
internal fun FileBrowserScreen(state: WorkspaceState, model: AppViewModel) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        FileBrowserContent(
            state = state,
            model = model,
            availableWidthDp = maxWidth.value.toInt(),
        )
    }
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterialApi::class)
@Composable
private fun FileBrowserContent(
    state: WorkspaceState,
    model: AppViewModel,
    availableWidthDp: Int,
) {
    val filePreviewItem = state.previewItem.takeIf { state.previewOwner == PreviewOwner.FILES }
    val browser = state.fileBrowser
    val mutation = state.fileStationMutationState
    var selected by remember { mutableStateOf<FileItem?>(null) }
    var pendingDownload by rememberSaveable(
        state.profile.id,
        stateSaver = PendingDownloadRequestStateSaver,
    ) { mutableStateOf(PendingDownloadRequestState()) }
    var showNotificationPermission by remember { mutableStateOf(false) }
    var showSortMenu by remember { mutableStateOf(false) }
    var showFilterMenu by remember { mutableStateOf(false) }
    var showUploadOptions by remember { mutableStateOf(false) }
    var showShareLinks by remember { mutableStateOf(false) }
    var compressTargets by remember { mutableStateOf<List<FileItem>>(emptyList()) }
    var extractTarget by remember { mutableStateOf<FileItem?>(null) }
    val context = LocalContext.current
    val inlinePreview = useInlineFilePreview(
        availableWidthDp,
        filePreviewItem != null,
    )
    val refreshing = state.files is Loadable.Loading
    val pullRefreshState = rememberPullRefreshState(refreshing, model::refreshFiles)
    val loadedItems = (state.files as? Loadable.Ready)?.value?.items.orEmpty()
    val selectedItems = loadedItems.filter { it.path in browser.selectedPaths }
    val pageUiState = filePageUiState(state.files, browser)
    val mutationBlocksWrites = mutation.editorVisible || mutation.confirmationRequested ||
        mutation.target != null || mutation.mutationInProgress || mutation.mutationRefreshInProgress ||
        mutation.mutationResult != null || mutation.mutationFailure != null ||
        mutation.mutationRefreshFailure != null
    val textSaveInProgress = mutation.target?.operation == FileStationMutationOperation.TEXT_SAVE &&
        mutation.mutationInProgress

    fun handleDownloadDestination(uri: android.net.Uri?) {
        val resolution = resolveDownloadDestination(
            pending = pendingDownload,
            activeProfileId = state.profile.id,
            destinationSelected = uri != null,
        )
        pendingDownload = resolution.nextPending
        when (resolution.decision) {
            DownloadDestinationDecision.CANCELLED -> Unit
            DownloadDestinationDecision.DISCARD_ORPHAN -> {
                if (uri != null) model.discardUnmatchedDownloadDestination(uri)
            }
            DownloadDestinationDecision.ENQUEUE -> {
                if (uri == null) return
                val item = resolution.request?.toFileItem() ?: run {
                    model.discardUnmatchedDownloadDestination(uri)
                    return
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

    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { showNotificationPermission = false }
    val fileDownloadLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/octet-stream"),
        onResult = ::handleDownloadDestination,
    )
    val folderDownloadLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/zip"),
        onResult = ::handleDownloadDestination,
    )
    val uploadLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        model.prepareFileUploads(uris)
    }
    val folderUploadLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree(),
    ) { uri ->
        uri?.let(model::enqueueFileTree)
    }

    Scaffold(
        contentWindowInsets = WindowInsets(0),
        floatingActionButton = {
            if (!inlinePreview) {
                Column(
                    horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                ExtendedFloatingActionButton(
                    onClick = {
                        if (model.prepareUpload()) showUploadOptions = true
                    },
                    icon = {
                        if (state.isPerformingAction) {
                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Outlined.UploadFile, contentDescription = null)
                        }
                    },
                    text = {
                        Text(
                            stringResource(R.string.upload_file),
                            fontWeight = FontWeight.SemiBold,
                        )
                    },
                    shape = MaterialTheme.shapes.medium,
                    expanded = !state.isPerformingAction,
                )
                if (browser.path.isNotBlank() && !mutationBlocksWrites) {
                    ExtendedFloatingActionButton(
                        onClick = { model.openCreateFolderEditor() },
                        icon = { Icon(Icons.Outlined.Add, contentDescription = null) },
                        text = {
                            Text(
                                stringResource(R.string.new_folder),
                                fontWeight = FontWeight.SemiBold,
                            )
                        },
                        shape = MaterialTheme.shapes.medium,
                        containerColor = MaterialTheme.colorScheme.primary,
                        contentColor = MaterialTheme.colorScheme.onPrimary,
                        expanded = !state.isPerformingAction,
                    )
                }
                }
            }
        },
    ) { padding ->
        Row(Modifier.fillMaxSize().padding(padding)) {
            Column(
                if (inlinePreview) {
                    Modifier.width(420.dp).fillMaxHeight()
                } else {
                    Modifier.fillMaxSize()
                },
            ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (browser.pathHistory.isNotEmpty()) {
                    IconButton(
                        onClick = model::goBackDirectory,
                        modifier = Modifier
                            .clip(MaterialTheme.shapes.small)
                            .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                    ) {
                        Icon(
                            Icons.AutoMirrored.Outlined.ArrowBack,
                            contentDescription = stringResource(R.string.go_up),
                        )
                    }
                }
                OutlinedTextField(
                    value = browser.searchQuery,
                    onValueChange = model::updateFileSearchQuery,
                    placeholder = { Text(stringResource(R.string.search_files)) },
                    leadingIcon = {
                        Icon(
                            Icons.Outlined.Search,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    },
                    trailingIcon = {
                        IconButton(onClick = model::searchFiles) {
                            Icon(
                                Icons.Outlined.Search,
                                contentDescription = stringResource(R.string.submit_file_search),
                            )
                        }
                    },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { model.searchFiles() }),
                    singleLine = true,
                    shape = MaterialTheme.shapes.small,
                    modifier = Modifier.weight(1f),
                )
            }
            if (browser.path.isNotBlank()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp)
                        .clip(MaterialTheme.shapes.extraSmall)
                        .background(MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.6f))
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val lineage = browser.pathHistory + browser.path
                    lineage.forEachIndexed { index, path ->
                        TextButton(
                            onClick = { model.navigateToFilePath(path) },
                            enabled = path != browser.path,
                        ) {
                            Text(
                                if (path.isBlank()) {
                                    stringResource(R.string.shared_folders)
                                } else {
                                    path.substringAfterLast('/').ifBlank { path }
                                },
                                maxLines = 1,
                            )
                        }
                        if (index < lineage.lastIndex) {
                            Text(
                                "/",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }
                    }
                }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.End,
            ) {
                if (browser.selectedPaths.isNotEmpty()) {
                    IconButton(onClick = model::clearFileSelection) {
                        Icon(Icons.Outlined.Close, stringResource(R.string.clear_selection))
                    }
                    Text(
                        stringResource(R.string.items_selected_count, browser.selectedPaths.size),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.weight(1f))
                    IconButton(
                        onClick = { compressTargets = selectedItems },
                        enabled = state.supportsCompression && browser.path.isNotBlank() &&
                            selectedItems.isNotEmpty() && selectedItems.all(FileItem::canRead) &&
                            !state.isPerformingAction,
                    ) {
                        Icon(
                            Icons.AutoMirrored.Outlined.InsertDriveFile,
                            stringResource(R.string.create_archive),
                        )
                    }
                    IconButton(
                        onClick = {
                            model.beginFileCopyMove(selectedItems, FileCopyMoveOperation.COPY)
                        },
                        enabled = state.supportsCopyMove && selectedItems.isNotEmpty() &&
                            selectedItems.all(FileItem::canRead) && !state.isPerformingAction &&
                            !mutationBlocksWrites,
                    ) {
                        Icon(Icons.Outlined.FileCopy, stringResource(R.string.copy_selected_items))
                    }
                    IconButton(
                        onClick = {
                            model.beginFileCopyMove(selectedItems, FileCopyMoveOperation.MOVE)
                        },
                        enabled = state.supportsCopyMove && selectedItems.isNotEmpty() &&
                            selectedItems.all(FileItem::canDelete) && !state.isPerformingAction &&
                            !mutationBlocksWrites,
                    ) {
                        Icon(
                            Icons.AutoMirrored.Outlined.DriveFileMove,
                            stringResource(R.string.move_selected_items),
                        )
                    }
                    IconButton(
                        onClick = { model.addFavorites(selectedItems) },
                        enabled = state.supportsFavorites && selectedItems.isNotEmpty() &&
                            selectedItems.all { it.isDirectory && !it.isFavorite } &&
                            !state.isPerformingAction && !mutationBlocksWrites,
                    ) {
                        Icon(Icons.Outlined.StarOutline, stringResource(R.string.add_to_favorites))
                    }
                    IconButton(
                        onClick = { model.deleteFiles(selectedItems) },
                        enabled = selectedItems.isNotEmpty() && selectedItems.all(FileItem::canDelete) &&
                            !state.isPerformingAction && !mutationBlocksWrites,
                    ) {
                        Icon(
                            Icons.Outlined.DeleteOutline,
                            stringResource(R.string.delete_selected_items),
                            tint = if (selectedItems.isNotEmpty() && selectedItems.all(FileItem::canDelete)) {
                                MaterialTheme.colorScheme.error
                            } else {
                                MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                            },
                        )
                    }
                } else {
                if (state.supportsFavorites) {
                    IconButton(onClick = model::loadFileFavorites) {
                        Icon(Icons.Outlined.Star, stringResource(R.string.open_favorites))
                    }
                }
                IconButton(onClick = model::loadFileRecentLocations) {
                    Icon(Icons.Outlined.History, stringResource(R.string.open_recent_locations))
                }
                if (state.supportsRemoteLocations) {
                    IconButton(onClick = model::loadFileRemoteLocations) {
                        Icon(Icons.Outlined.FolderOpen, stringResource(R.string.open_remote_locations))
                    }
                }
                if (state.supportsSharing) {
                    IconButton(
                        onClick = {
                            showShareLinks = true
                            model.loadFileShareLinks()
                        },
                    ) {
                        Icon(Icons.Outlined.Link, stringResource(R.string.manage_share_links))
                    }
                }
                Box {
                    IconButton(onClick = { showSortMenu = true }) {
                        Icon(Icons.AutoMirrored.Outlined.Sort, stringResource(R.string.sort_files))
                    }
                    DropdownMenu(
                        expanded = showSortMenu,
                        onDismissRequest = { showSortMenu = false },
                    ) {
                        FileSortOption.entries.forEach { option ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        stringResource(
                                            when (option) {
                                                FileSortOption.NAME -> R.string.sort_by_name
                                                FileSortOption.MODIFIED_TIME -> R.string.sort_by_modified
                                                FileSortOption.SIZE -> R.string.sort_by_size
                                            },
                                        ),
                                    )
                                },
                                leadingIcon = if (browser.sortOption == option) {
                                    {
                                        Icon(
                                            if (browser.sortAscending) {
                                                Icons.Outlined.KeyboardArrowUp
                                            } else {
                                                Icons.Outlined.KeyboardArrowDown
                                            },
                                            contentDescription = null,
                                        )
                                    }
                                } else {
                                    null
                                },
                                onClick = {
                                    showSortMenu = false
                                    model.changeFileSort(option)
                                },
                            )
                        }
                    }
                }
                Box {
                    IconButton(onClick = { showFilterMenu = true }) {
                        Icon(Icons.Outlined.FilterList, stringResource(R.string.filter_files))
                    }
                    DropdownMenu(
                        expanded = showFilterMenu,
                        onDismissRequest = { showFilterMenu = false },
                    ) {
                        FileTypeFilter.entries.forEach { filter ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        stringResource(
                                            when (filter) {
                                                FileTypeFilter.ALL -> R.string.show_all_items
                                                FileTypeFilter.FOLDERS -> R.string.show_folders_only
                                                FileTypeFilter.FILES -> R.string.show_files_only
                                            },
                                        ),
                                    )
                                },
                                trailingIcon = if (browser.typeFilter == filter) {
                                    { Text(stringResource(R.string.selected)) }
                                } else {
                                    null
                                },
                                onClick = {
                                    showFilterMenu = false
                                    model.changeFileFilter(filter)
                                },
                            )
                        }
                    }
                }
                IconButton(
                    onClick = {
                        model.changeFileViewMode(
                            if (browser.viewMode == FileViewMode.LIST) {
                                FileViewMode.GRID
                            } else {
                                FileViewMode.LIST
                            },
                        )
                    },
                ) {
                    Icon(
                        if (browser.viewMode == FileViewMode.LIST) {
                            Icons.Outlined.GridView
                        } else {
                            Icons.AutoMirrored.Outlined.List
                        },
                        stringResource(
                            if (browser.viewMode == FileViewMode.LIST) {
                                R.string.switch_to_grid
                            } else {
                                R.string.switch_to_list
                            },
                        ),
                    )
                }
                IconButton(onClick = model::refreshFiles) {
                    Icon(Icons.Outlined.Refresh, stringResource(R.string.refresh))
                }
                }
            }
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .pullRefresh(pullRefreshState),
            ) {
                val searchActive = browser.activeSearchQuery != null
                PageStateContent(
                    state = pageUiState,
                    emptyTitle = stringResource(R.string.directory_empty),
                    emptyMessage = stringResource(R.string.empty_folder_description),
                    emptyIcon = Icons.Outlined.Folder,
                    filteredEmptyTitle = stringResource(
                        if (searchActive) {
                            R.string.no_file_search_results
                        } else {
                            R.string.no_items_match_filter
                        },
                    ),
                    filteredEmptyMessage = stringResource(
                        if (searchActive) {
                            R.string.no_file_search_results_description
                        } else {
                            R.string.change_file_filter_hint
                        },
                    ),
                    filteredEmptyIcon = if (searchActive) {
                        Icons.Outlined.Search
                    } else {
                        Icons.Outlined.FilterList
                    },
                    onRetry = { model.load(Module.FILES) },
                ) { page ->
                    val visibleItems = browser.visibleItems(page.items)
                    FileItems(
                        items = visibleItems,
                        state = state,
                        model = model,
                        viewMode = browser.viewMode,
                        canLoadMore = browser.activeSearchQuery == null &&
                            page.offset + page.items.size < page.total,
                        onOpen = model::openDirectory,
                        onPreview = { model.openPreview(it, visibleItems) },
                        onSelect = { selected = it },
                        selectedPaths = browser.selectedPaths,
                        onToggleSelection = model::toggleFileSelection,
                    )
                }
                PullRefreshIndicator(
                    refreshing = refreshing,
                    state = pullRefreshState,
                    modifier = Modifier.align(Alignment.TopCenter),
                    backgroundColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    contentColor = MaterialTheme.colorScheme.primary,
                )
            }
            }
            if (inlinePreview) {
                VerticalDivider()
                filePreviewItem?.let { item ->
                    val sequence = state.filePreviewSequence
                    FilePreviewDialog(
                        item = item,
                        preview = state.preview,
                        onRetry = model::retryPreview,
                        onClose = model::closePreview,
                        onPrevious = sequence?.let { model::showPreviousFileImage },
                        onNext = sequence?.let { model::showNextFileImage },
                        previousEnabled = sequence?.hasPrevious == true,
                        nextEnabled = sequence?.hasNext == true,
                        onSaveText = model::requestTextPreviewSave,
                        savingText = textSaveInProgress,
                        textDraft = state.textPreviewDraft,
                        onTextDraftChange = model::updateTextPreviewDraft,
                        onCancelTextEdit = model::requestCancelTextPreviewEdit,
                        discardConfirmationVisible = state.previewDiscardConfirmationVisible,
                        onConfirmDiscard = model::confirmDiscardTextPreview,
                        onDismissDiscard = model::dismissPreviewDiscardConfirmation,
                        embedded = true,
                        modifier = Modifier.weight(1f).fillMaxHeight(),
                    )
                }
            }
        }
    }

    selected?.let { item ->
        AlertDialog(
            onDismissRequest = { selected = null },
            title = { Text(item.name) },
            text = {
                Column {
                    if (item.isDirectory) {
                        ActionRow(Icons.Outlined.FolderOpen, stringResource(R.string.open)) {
                            model.openDirectory(item)
                            selected = null
                        }
                        if (state.supportsFavorites) {
                            if (item.isFavorite) {
                                ActionRow(
                                    Icons.Outlined.Star,
                                    stringResource(R.string.remove_from_favorites),
                                ) {
                                    if (!mutationBlocksWrites) {
                                        model.removeFavorite(item)
                                        selected = null
                                    }
                                }
                            } else {
                                ActionRow(
                                    Icons.Outlined.StarOutline,
                                    stringResource(R.string.add_to_favorites),
                                ) {
                                    if (!mutationBlocksWrites) {
                                        model.addFavorite(item)
                                        selected = null
                                    }
                                }
                            }
                        }
                        if (browser.path.isBlank()) {
                            ActionRow(
                                Icons.Outlined.RestoreFromTrash,
                                stringResource(R.string.open_recycle_bin),
                            ) {
                                model.openRecycleBin(item)
                                selected = null
                            }
                        }
                    } else {
                        ActionRow(Icons.Outlined.Visibility, stringResource(R.string.preview)) {
                            model.openPreview(item)
                            selected = null
                        }
                        if (state.supportsExtraction && item.canRead && item.isSupportedArchive()) {
                            ActionRow(
                                Icons.Outlined.FolderOpen,
                                stringResource(R.string.extract_archive),
                            ) {
                                extractTarget = item
                                selected = null
                            }
                        }
                    }
                    if (state.supportsSharing && item.canRead) {
                        ActionRow(Icons.Outlined.Share, stringResource(R.string.create_share_link)) {
                            if (model.requestFileShareLinkCreation(item)) selected = null
                        }
                    }
                    if (state.supportsCopyMove && item.path.split('/').contains("#recycle")) {
                        ActionRow(
                            Icons.Outlined.RestoreFromTrash,
                            stringResource(R.string.restore_from_recycle_bin),
                        ) {
                            if (model.requestFileRestore(item)) selected = null
                        }
                    }
                    if (item.canRead) {
                        ActionRow(
                            Icons.Outlined.Download,
                            stringResource(
                                if (item.isDirectory) {
                                    R.string.download_folder_as_zip
                                } else {
                                    R.string.download_item
                                },
                            ),
                        ) {
                            pendingDownload = PendingDownloadRequestState(
                                item.toPendingDownloadRequest(state.profile.id),
                            )
                            selected = null
                            if (item.isDirectory) {
                                folderDownloadLauncher.launch("${item.name}.zip")
                            } else {
                                fileDownloadLauncher.launch(item.name)
                            }
                        }
                    } else {
                        Text(
                            stringResource(R.string.download_not_allowed),
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    ActionRow(Icons.Outlined.Edit, stringResource(R.string.rename)) {
                        if (model.openRenameFileEditor(item)) selected = null
                    }
                    ActionRow(
                        Icons.Outlined.DeleteOutline,
                        stringResource(R.string.delete),
                        destructive = true,
                    ) {
                        if (model.deleteFiles(listOf(item))) selected = null
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { selected = null }) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
    val shareDeleteConfirmation = mutation.confirmationRequested &&
        mutation.draftTarget?.operation == FileStationMutationOperation.SHARE_DELETE
    val shareDeleteResult = mutation.target?.operation == FileStationMutationOperation.SHARE_DELETE
    if (showShareLinks && !shareDeleteConfirmation && !shareDeleteResult) {
        AlertDialog(
            onDismissRequest = { if (!state.isPerformingAction) showShareLinks = false },
            title = { Text(stringResource(R.string.manage_share_links)) },
            text = {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 260.dp, max = 560.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    when (val links = state.fileShareLinks) {
                        Loadable.Idle,
                        Loadable.Loading,
                        -> CircularProgressIndicator()
                        is Loadable.Failed -> Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Icon(
                                Icons.Outlined.Link,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.error,
                            )
                            Text(
                                stringResource(R.string.manage_share_links_load_failed),
                                style = MaterialTheme.typography.titleMedium,
                            )
                            Text(
                                links.error.localize(context).combined,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            TextButton(onClick = model::loadFileShareLinks) {
                                Text(stringResource(R.string.retry))
                            }
                        }
                        is Loadable.Ready -> if (links.value.isEmpty()) {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                Icon(
                                    Icons.Outlined.Link,
                                    contentDescription = null,
                                    modifier = Modifier.size(48.dp),
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Text(
                                    stringResource(R.string.manage_share_links_empty),
                                    style = MaterialTheme.typography.titleMedium,
                                )
                                Text(
                                    stringResource(R.string.manage_share_links_empty_description),
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        } else {
                            LazyColumn(Modifier.fillMaxSize()) {
                                items(links.value, key = FileShareLink::id) { link ->
                                    ListItem(
                                        headlineContent = {
                                            Text(
                                                link.name.ifBlank {
                                                    stringResource(R.string.share_link_unnamed)
                                                },
                                            )
                                        },
                                        supportingContent = {
                                            Column {
                                                if (link.path.isNotBlank()) {
                                                    Text(link.path, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                                }
                                                if (link.hasPassword) {
                                                    Text(stringResource(R.string.share_link_password_protected))
                                                }
                                                link.expiresAt?.let {
                                                    Text(stringResource(R.string.share_link_expires_at, it))
                                                }
                                            }
                                        },
                                        trailingContent = {
                                            Row {
                                                IconButton(
                                                    onClick = { model.copyFileShareLink(link) },
                                                    enabled = !state.isPerformingAction,
                                                ) {
                                                    Icon(
                                                        Icons.Outlined.ContentCopy,
                                                        stringResource(R.string.copy_share_link),
                                                    )
                                                }
                                                IconButton(
                                                    onClick = {
                                                        model.requestFileShareLinkDeletion(listOf(link.id))
                                                    },
                                                    enabled = !state.isPerformingAction,
                                                ) {
                                                    Icon(
                                                        Icons.Outlined.DeleteOutline,
                                                        stringResource(R.string.delete_share_link),
                                                        tint = MaterialTheme.colorScheme.error,
                                                    )
                                                }
                                            }
                                        },
                                        colors = ListItemDefaults.colors(
                                            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                                        ),
                                    )
                                    HorizontalDivider()
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = model::loadFileShareLinks,
                    enabled = !state.isPerformingAction,
                ) {
                    Text(stringResource(R.string.refresh))
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { showShareLinks = false },
                    enabled = !state.isPerformingAction,
                ) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
    if (compressTargets.isNotEmpty()) {
        ArchiveCreateDialog(
            suggestedName = compressTargets.singleOrNull()?.name?.substringBeforeLast('.')
                ?: stringResource(R.string.archive_default_name),
            onConfirm = { name, format, password ->
                model.compressFiles(compressTargets, name, format, password)
                compressTargets = emptyList()
            },
            onDismiss = { compressTargets = emptyList() },
        )
    }
    extractTarget?.let { item ->
        ArchiveExtractDialog(
            itemName = item.name,
            onConfirm = { password ->
                model.extractFile(item, password)
                extractTarget = null
            },
            onDismiss = { extractTarget = null },
        )
    }
    if (!inlinePreview) filePreviewItem?.let { item ->
        val sequence = state.filePreviewSequence
        FilePreviewDialog(
            item = item,
            preview = state.preview,
            onRetry = model::retryPreview,
            onClose = model::closePreview,
            onPrevious = sequence?.let { model::showPreviousFileImage },
            onNext = sequence?.let { model::showNextFileImage },
            previousEnabled = sequence?.hasPrevious == true,
            nextEnabled = sequence?.hasNext == true,
            onSaveText = model::requestTextPreviewSave,
            savingText = textSaveInProgress,
            textDraft = state.textPreviewDraft,
            onTextDraftChange = model::updateTextPreviewDraft,
            onCancelTextEdit = model::requestCancelTextPreviewEdit,
            discardConfirmationVisible = state.previewDiscardConfirmationVisible,
            onConfirmDiscard = model::confirmDiscardTextPreview,
            onDismissDiscard = model::dismissPreviewDiscardConfirmation,
        )
    }
    if (showNotificationPermission) {
        AlertDialog(
            onDismissRequest = { showNotificationPermission = false },
            title = { Text(stringResource(R.string.notification_permission_title)) },
            text = { Text(stringResource(R.string.notification_permission_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showNotificationPermission = false
                        notificationPermissionLauncher.launch(POST_NOTIFICATIONS_PERMISSION)
                    },
                ) {
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
    val nameEditorVisible = mutation.editorVisible &&
        (mutation.editorParentBaseline != null || mutation.editorSourceBaseline != null)
    if (nameEditorVisible) {
        FileStationNameEditorDialog(
            state = mutation,
            onDraftChange = model::updateFileStationNameDraft,
            onConfirm = model::confirmFileStationNameEditor,
            onDismiss = model::cancelPendingFileStationMutation,
        )
    }
    val lifecycleConfirmationTarget = mutation.draftTarget?.takeIf { target ->
        target.module == Module.FILES && mutation.confirmationRequested && target.operation in setOf(
            FileStationMutationOperation.TEXT_SAVE,
            FileStationMutationOperation.DELETE,
            FileStationMutationOperation.RESTORE,
            FileStationMutationOperation.SHARE_CREATE,
            FileStationMutationOperation.SHARE_DELETE,
        )
    }
    lifecycleConfirmationTarget?.let { target ->
        FileStationMutationConfirmationDialog(
            target = target,
            onConfirm = model::confirmFileStationMutation,
            onDismiss = model::cancelFileStationMutationConfirmation,
        )
    }
    if (mutation.target?.module == Module.FILES) {
        FileStationMutationFeedbackDialog(
            state = mutation,
            onRefresh = model::refreshFileStationMutation,
            onContinueEditing = model::continueEditingFileStationMutation,
            onDismiss = { model.dismissFileStationMutationResult(discardDraft = true) },
        )
    }
    if (state.fileCopyMove != null && mutation.target == null) FileCopyMoveDialog(state, model)
    if (showUploadOptions) {
        AlertDialog(
            onDismissRequest = { showUploadOptions = false },
            title = { Text(stringResource(R.string.choose_upload_source)) },
            text = {
                Column {
                    ActionRow(Icons.Outlined.UploadFile, stringResource(R.string.upload_files)) {
                        showUploadOptions = false
                        uploadLauncher.launch(arrayOf("*/*"))
                    }
                    ActionRow(Icons.Outlined.FolderOpen, stringResource(R.string.upload_folder)) {
                        showUploadOptions = false
                        folderUploadLauncher.launch(null)
                    }
                    Text(
                        stringResource(R.string.upload_folder_description),
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { showUploadOptions = false }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
    state.pendingFileUploads?.let { pending ->
        AlertDialog(
            onDismissRequest = model::cancelPendingFileUploads,
            title = { Text(stringResource(R.string.replace_upload_conflicts_title)) },
            text = {
                Text(
                    stringResource(
                        R.string.replace_upload_conflicts_message,
                        pending.conflictCount,
                    ),
                )
            },
            confirmButton = {
                TextButton(onClick = model::confirmPendingFileUploads) {
                    Text(stringResource(R.string.replace_existing))
                }
            },
            dismissButton = {
                TextButton(onClick = model::cancelPendingFileUploads) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
    if (state.fileFavorites !is Loadable.Idle) {
        AlertDialog(
            onDismissRequest = model::closeFileFavorites,
            title = { Text(stringResource(R.string.favorite_folders)) },
            text = {
                when (val favorites = state.fileFavorites) {
                    Loadable.Idle -> Unit
                    Loadable.Loading -> Box(
                        Modifier.fillMaxWidth().heightIn(min = 160.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator()
                    }
                    is Loadable.Failed -> {
                        val localized = favorites.error.localize(context)
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(localized.message, color = MaterialTheme.colorScheme.error)
                            Text(localized.recovery)
                            TextButton(onClick = model::loadFileFavorites) {
                                Text(stringResource(R.string.retry))
                            }
                        }
                    }
                    is Loadable.Ready -> if (favorites.value.isEmpty()) {
                        Text(stringResource(R.string.no_favorite_folders))
                    } else {
                        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                            items(favorites.value, key = FileItem::path) { folder ->
                                ListItem(
                                    headlineContent = {
                                        Text(folder.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    },
                                    supportingContent = {
                                        Text(
                                            folder.path,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    },
                                    leadingContent = {
                                        Icon(Icons.Outlined.Folder, contentDescription = null)
                                    },
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(min = 48.dp)
                                        .clickable { model.openFileFavorite(folder) },
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = model::closeFileFavorites) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
    if (state.fileRemoteLocations !is Loadable.Idle) {
        AlertDialog(
            onDismissRequest = model::closeFileRemoteLocations,
            title = { Text(stringResource(R.string.remote_locations)) },
            text = {
                when (val locations = state.fileRemoteLocations) {
                    Loadable.Idle -> Unit
                    Loadable.Loading -> Box(
                        Modifier.fillMaxWidth().heightIn(min = 160.dp),
                        contentAlignment = Alignment.Center,
                    ) { CircularProgressIndicator() }
                    is Loadable.Failed -> {
                        val localized = locations.error.localize(context)
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(localized.message, color = MaterialTheme.colorScheme.error)
                            Text(localized.recovery)
                            TextButton(onClick = model::loadFileRemoteLocations) {
                                Text(stringResource(R.string.retry))
                            }
                        }
                    }
                    is Loadable.Ready -> if (locations.value.isEmpty()) {
                        Text(stringResource(R.string.no_remote_locations))
                    } else {
                        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                            items(locations.value, key = FileItem::path) { folder ->
                                ListItem(
                                    headlineContent = {
                                        Text(folder.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    },
                                    supportingContent = {
                                        Text(folder.path, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    },
                                    leadingContent = {
                                        Icon(Icons.Outlined.FolderOpen, contentDescription = null)
                                    },
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(min = 48.dp)
                                        .clickable { model.openFileRemoteLocation(folder) },
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = model::closeFileRemoteLocations) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
    if (state.fileRecentLocations !is Loadable.Idle) {
        AlertDialog(
            onDismissRequest = model::closeFileRecentLocations,
            title = { Text(stringResource(R.string.recent_locations)) },
            text = {
                when (val locations = state.fileRecentLocations) {
                    Loadable.Idle -> Unit
                    Loadable.Loading -> Box(
                        Modifier.fillMaxWidth().heightIn(min = 160.dp),
                        contentAlignment = Alignment.Center,
                    ) { CircularProgressIndicator() }
                    is Loadable.Failed -> Unit
                    is Loadable.Ready -> if (locations.value.isEmpty()) {
                        Text(stringResource(R.string.no_recent_locations))
                    } else {
                        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                            items(locations.value, key = FileItem::path) { folder ->
                                ListItem(
                                    headlineContent = {
                                        Text(folder.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    },
                                    supportingContent = {
                                        Text(folder.path, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    },
                                    leadingContent = {
                                        Icon(Icons.Outlined.History, contentDescription = null)
                                    },
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(min = 48.dp)
                                        .clickable { model.openFileRecentLocation(folder) },
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = model::closeFileRecentLocations) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }
}

private fun FileItem.isSupportedArchive(): Boolean =
    name.substringAfterLast('.', "").lowercase() in setOf("zip", "7z")

@Composable
private fun ArchiveCreateDialog(
    suggestedName: String,
    onConfirm: (String, ArchiveFormat, String?) -> Unit,
    onDismiss: () -> Unit,
) {
    var name by remember(suggestedName) { mutableStateOf(suggestedName) }
    var password by remember { mutableStateOf("") }
    var format by remember { mutableStateOf(ArchiveFormat.ZIP) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.create_archive)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(stringResource(R.string.archive_name)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(
                    modifier = Modifier.fillMaxWidth().selectableGroup(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ArchiveFormat.entries.forEach { option ->
                        Row(
                            modifier = Modifier
                                .weight(1f)
                                .heightIn(min = 48.dp)
                                .selectable(
                                    selected = format == option,
                                    role = Role.RadioButton,
                                    onClick = { format = option },
                                )
                                .padding(horizontal = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            RadioButton(selected = format == option, onClick = null)
                            Text(if (option == ArchiveFormat.ZIP) "ZIP" else "7z")
                        }
                    }
                }
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text(stringResource(R.string.archive_password_optional)) },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    stringResource(R.string.archive_no_overwrite_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name, format, password.ifBlank { null }) },
                enabled = name.isNotBlank() && '/' !in name,
            ) { Text(stringResource(R.string.create)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
private fun ArchiveExtractDialog(
    itemName: String,
    onConfirm: (String?) -> Unit,
    onDismiss: () -> Unit,
) {
    var password by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.extract_archive)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.extract_archive_message, itemName))
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text(stringResource(R.string.archive_password_optional)) },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    stringResource(R.string.archive_no_overwrite_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(password.ifBlank { null }) }) {
                Text(stringResource(R.string.extract))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}
