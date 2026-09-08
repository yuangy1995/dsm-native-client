package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.activity.compose.BackHandler
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.CheckBoxOutlineBlank
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material3.Button
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*

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
    var details by remember { mutableStateOf<FileItem?>(null) }
    var pendingDownload by rememberSaveable(
        state.profile.id,
        stateSaver = PendingDownloadRequestStateSaver,
    ) { mutableStateOf(PendingDownloadRequestState()) }
    var showNotificationPermission by remember { mutableStateOf(false) }
    var showSearch by rememberSaveable { mutableStateOf(false) }
    var showOptions by remember { mutableStateOf(false) }
    var showAdd by remember { mutableStateOf(false) }
    var uploadDestinationMode by rememberSaveable { mutableStateOf(false) }
    var showShareLinks by remember { mutableStateOf(false) }
    val entry = LocalClientEntry.current
    LaunchedEffect(entry?.revision) {
        when (entry?.action) {
            ClientEntryAction.SEARCH -> showSearch = true
            ClientEntryAction.UPLOAD -> uploadDestinationMode = true
            ClientEntryAction.FAVORITES -> model.loadFileFavorites()
            ClientEntryAction.RECENT -> model.loadFileRecentLocations()
            ClientEntryAction.SHARE_LINKS -> { showShareLinks = true; model.loadFileShareLinks() }
            else -> Unit
        }
        entry?.consume()
    }
    BackHandler(enabled = showSearch || uploadDestinationMode) {
        if (showSearch) showSearch = false else uploadDestinationMode = false
    }
    var showSortMenu by remember { mutableStateOf(false) }
    var showFilterMenu by remember { mutableStateOf(false) }
    var showUploadOptions by remember { mutableStateOf(false) }
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
        bottomBar = {
            when {
                browser.selectedPaths.isNotEmpty() -> ClientFileSelectionBar(
                    state, model, selectedItems, mutationBlocksWrites,
                    onCompress = { compressTargets = selectedItems },
                )
                uploadDestinationMode -> androidx.compose.material3.Surface {
                    Column(Modifier.fillMaxWidth().padding(16.dp)) {
                        Text(stringResource(R.string.client_choose_upload_folder), style = MaterialTheme.typography.bodySmall)
                        Button(onClick = {
                            if (model.prepareUpload()) { uploadDestinationMode = false; showUploadOptions = true }
                        }, enabled = browser.path.isNotBlank() && !mutationBlocksWrites && !state.isPerformingAction,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.client_upload_here))
                        }
                    }
                }
            }
        },
        floatingActionButton = {
            if (!inlinePreview && browser.selectedPaths.isEmpty() && !uploadDestinationMode) {
                val label = stringResource(R.string.client_add)
                ExtendedFloatingActionButton(
                    onClick = { if (!mutationBlocksWrites && !state.isPerformingAction) showAdd = true },
                    icon = { Icon(Icons.Outlined.Add, null) }, text = { Text(label) },
                    modifier = Modifier.semantics { contentDescription = label },
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                )
            }
        },
    ) { padding ->
        Row(Modifier.fillMaxSize().padding(padding)) {
            Column(if (inlinePreview) Modifier.width(420.dp).fillMaxHeight() else Modifier.fillMaxSize()) {
                if (showSearch || browser.activeSearchQuery != null) {
                    Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        ClientSearchField(browser.searchQuery, model::updateFileSearchQuery,
                            stringResource(R.string.client_search_files), Modifier.weight(1f), onSearch = model::searchFiles)
                        IconButton(onClick = {
                            showSearch = false
                            model.updateFileSearchQuery("")
                            model.searchFiles()
                        }) { Icon(Icons.Outlined.Close, stringResource(R.string.close)) }
                    }
                }
                if (browser.path.isBlank() && browser.selectedPaths.isEmpty() && state.favoritePaths.isNotEmpty()) {
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                        ClientSectionTitle(stringResource(R.string.client_favorite_locations))
                        SavedLocationTiles(state.favoritePaths.toList().take(6), model::openRecentDirectory)
                    }
                }
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp).heightIn(min = 48.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(if (browser.path.isBlank()) R.string.shared_folders else R.string.client_files),
                        style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                    IconButton(onClick = { showOptions = true }) {
                        Icon(Icons.Outlined.Tune, stringResource(R.string.client_file_options))
                    }
                }
                Box(Modifier.weight(1f).fillMaxWidth().pullRefresh(pullRefreshState)) {
                    PageStateContent(
                        state = pageUiState,
                        emptyTitle = stringResource(R.string.directory_empty),
                        emptyMessage = stringResource(R.string.empty_folder_description),
                        emptyIcon = Icons.Outlined.Folder,
                        filteredEmptyTitle = stringResource(if (browser.activeSearchQuery != null) R.string.no_file_search_results else R.string.no_items_match_filter),
                        filteredEmptyMessage = stringResource(if (browser.activeSearchQuery != null) R.string.no_file_search_results_description else R.string.change_file_filter_hint),
                        filteredEmptyIcon = Icons.Outlined.Search,
                        onRetry = model::refreshFiles,
                    ) { page ->
                        val visibleItems = browser.visibleItems(page.items)
                        FileItems(
                            items = visibleItems, state = state, model = model, viewMode = browser.viewMode,
                            canLoadMore = browser.activeSearchQuery == null && page.offset + page.items.size < page.total,
                            onOpen = model::openDirectory, onPreview = { model.openPreview(it, visibleItems) },
                            onSelect = { selected = it }, selectedPaths = browser.selectedPaths,
                            onToggleSelection = model::toggleFileSelection,
                        )
                    }
                    PullRefreshIndicator(refreshing, pullRefreshState, Modifier.align(Alignment.TopCenter))
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
    if (showAdd) ClientSheet(stringResource(R.string.client_add), { showAdd = false }) {
        ClientRow(stringResource(R.string.upload_file), Icons.Outlined.UploadFile) {
            showAdd = false
            if (browser.path.isBlank()) uploadDestinationMode = true
            else if (model.prepareUpload()) showUploadOptions = true
        }
        if (browser.path.isNotBlank()) ClientRow(stringResource(R.string.new_folder), Icons.Outlined.CreateNewFolder,
            enabled = !mutationBlocksWrites && !state.isPerformingAction) {
            showAdd = false; model.openCreateFolderEditor()
        }
    }
    if (showOptions) ClientFileOptionsSheet(state, model, onShareLinks = {
        showOptions = false; showShareLinks = true; model.loadFileShareLinks()
    }, onDismiss = { showOptions = false })

    selected?.let { item ->
        ClientSheet(item.name, { selected = null }) {
            Text(if (item.isDirectory) stringResource(R.string.folder) else formatBytes(item.size),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            val writable = !mutationBlocksWrites && !state.isPerformingAction
            ClientActionGrid(buildList {
                add(ClientAction(stringResource(if (item.isDirectory) R.string.open else R.string.preview),
                    if (item.isDirectory) Icons.Outlined.FolderOpen else Icons.Outlined.Visibility) {
                    if (item.isDirectory) model.openDirectory(item) else model.openPreview(item)
                    selected = null
                })
                if (item.canRead) add(ClientAction(stringResource(if (item.isDirectory) R.string.download_folder_as_zip else R.string.download_item),
                    Icons.Outlined.Download) {
                    pendingDownload = PendingDownloadRequestState(item.toPendingDownloadRequest(state.profile.id))
                    selected = null
                    if (item.isDirectory) folderDownloadLauncher.launch("${item.name}.zip") else fileDownloadLauncher.launch(item.name)
                })
                if (state.supportsSharing && item.canRead) add(ClientAction(stringResource(R.string.create_share_link), Icons.Outlined.Share, writable) {
                    if (model.requestFileShareLinkCreation(item)) selected = null
                })
                add(ClientAction(stringResource(R.string.rename), Icons.Outlined.Edit, writable) {
                    if (model.openRenameFileEditor(item)) selected = null
                })
                if (state.supportsCopyMove && item.canRead) add(ClientAction(stringResource(R.string.copy_selected_items), Icons.Outlined.FileCopy, writable) {
                    model.beginFileCopyMove(listOf(item), FileCopyMoveOperation.COPY); selected = null
                })
                if (state.supportsCopyMove && item.canDelete) add(ClientAction(stringResource(R.string.move_selected_items), Icons.AutoMirrored.Outlined.DriveFileMove, writable) {
                    model.beginFileCopyMove(listOf(item), FileCopyMoveOperation.MOVE); selected = null
                })
            })
            ClientGroup {
                ClientRow(stringResource(R.string.select_item), Icons.Outlined.CheckBoxOutlineBlank) {
                    model.toggleFileSelection(item); selected = null
                }
                if (item.isDirectory && state.supportsFavorites) ClientRow(
                    stringResource(if (item.isFavorite) R.string.remove_from_favorites else R.string.add_to_favorites),
                    Icons.Outlined.StarOutline, enabled = writable) {
                    if (item.isFavorite) model.removeFavorite(item) else model.addFavorite(item)
                    selected = null
                }
                if (state.supportsCompression && item.canRead) ClientRow(stringResource(R.string.create_archive),
                    Icons.AutoMirrored.Outlined.InsertDriveFile, enabled = writable) {
                    compressTargets = listOf(item); selected = null
                }
                if (!item.isDirectory && state.supportsExtraction && item.canRead && item.isSupportedArchive()) {
                    ClientRow(stringResource(R.string.extract_archive), Icons.Outlined.FolderOpen, enabled = writable) {
                        extractTarget = item; selected = null
                    }
                }
                if (item.isDirectory && browser.path.isBlank()) ClientRow(stringResource(R.string.open_recycle_bin),
                    Icons.Outlined.RestoreFromTrash) { model.openRecycleBin(item); selected = null }
                if (state.supportsCopyMove && item.path.split('/').contains("#recycle")) ClientRow(
                    stringResource(R.string.restore_from_recycle_bin), Icons.Outlined.RestoreFromTrash, enabled = writable) {
                    if (model.requestFileRestore(item)) selected = null
                }
                ClientRow(stringResource(R.string.file_details), Icons.Outlined.Info) { details = item; selected = null }
            }
            if (!item.canRead) Text(stringResource(R.string.download_not_allowed), style = MaterialTheme.typography.bodySmall)
            ClientRow(stringResource(R.string.delete), Icons.Outlined.DeleteOutline, enabled = writable, destructive = true) {
                if (model.deleteFiles(listOf(item))) selected = null
            }
        }
    }
    details?.let { item -> ClientSheet(item.name, { details = null }) {
        PreviewDetails(item, state.preview.takeIf { state.previewItem?.path == item.path } ?: Loadable.Idle)
    } }
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
