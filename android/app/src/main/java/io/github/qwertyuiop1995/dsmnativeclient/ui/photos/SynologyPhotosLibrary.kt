package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Upload
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import java.time.format.DateTimeFormatter

/** 手机使用触控标签和全屏预览，大屏保留自适应网格和可并排的详情。 */
@Composable
internal fun SynologyPhotosLibrary(model: SynologyPhotosModel, canBackup: Boolean, onBackup: () -> Unit) {
    val state by model.state.collectAsState()
    val editState = model.edits?.state?.collectAsState()?.value
    val albumState = model.albums?.state?.collectAsState()?.value
    val requestState = model.requests?.state?.collectAsState()?.value
    val folderState = model.folders?.state?.collectAsState()?.value
    val folderSharingState = model.folderSharing?.state?.collectAsState()?.value
    val sharedMembersState = model.sharedMembers?.state?.collectAsState()?.value
    val settingsState = model.settings?.state?.collectAsState()?.value
    val previewsState = model.previewRegeneration?.state?.collectAsState()?.value
    val codecState = model.codecPrompt?.state?.collectAsState()?.value
    val maintenanceState = model.maintenance?.state?.collectAsState()?.value
    val similarState = model.similar?.state?.collectAsState()?.value
    val conceptsState = model.concepts?.state?.collectAsState()?.value
    val peopleState = model.people?.state?.collectAsState()?.value
    val backgroundState = model.background?.state?.collectAsState()?.value
    val fileState = model.files?.state?.collectAsState()?.value
    val deletionState by model.deletion.state.collectAsState()
    val export by model.exports.state.collectAsState()
    val writing = similarState?.working == true || conceptsState?.working == true || peopleState?.working == true || previewsState?.working == true || codecState?.working == true || maintenanceState?.working == true || sharedMembersState?.working == true || backgroundState?.working == true || export.busy || deletionState.writing || editState?.working == true || albumState?.working == true || requestState?.working == true || folderState?.working == true || fileState?.working == true || folderSharingState?.working == true || settingsState?.working == true
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val context = LocalContext.current
    var search by rememberSaveable(model.profileId) { mutableStateOf("") }
    var filters by remember { mutableStateOf(false) }
    var months by remember { mutableStateOf(false) }
    var sources by remember { mutableStateOf(false) }
    var more by remember { mutableStateOf(false) }
    DisposableEffect(model, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> model.activate()
                Lifecycle.Event.ON_PAUSE -> model.slideshow.pause()
                Lifecycle.Event.ON_STOP -> model.deactivate(preservePreparedExport = true)
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) model.activate()
        onDispose { lifecycle.removeObserver(observer); model.deactivate(preservePreparedExport = context.photoActivity()?.isChangingConfigurations == true) }
    }
    DisposableEffect(model, state.navigation.category, state.navigation.space) {
        model.similar?.browsing(state.navigation.space.takeIf { state.navigation.category == SynologyPhotoCategory.SIMILAR })
        onDispose { model.similar?.browsing(null) }
    }
    LaunchedEffect(state.navigation, state.requestSearch) { search = if (state.navigation.isRequests) state.requestSearch else state.navigation.keyword }
    LaunchedEffect(state.navigation.locationKey) { model.edits?.selectMode(false) }
    BackHandler(editState?.selecting == true && !editState.visible) { model.edits?.selectMode(false) }
    BackHandler(state.navigation.canGoBack && !filters && !months) { model.goBack() }
    Column(Modifier.fillMaxSize()) {
        ClientToolbar(
            title = state.navigation.categoryItem?.let { if (state.navigation.category == SynologyPhotoCategory.PEOPLE) personName(it) else it.name } ?: state.navigation.album?.name ?: state.navigation.folders.lastOrNull()?.name
                ?: stringResource(state.navigation.category?.label() ?: state.navigation.section.label()),
            onBack = if (state.navigation.canGoBack) ({ model.goBack(); Unit }) else null,
            titleContent = if (state.navigation.section == SynologyPhotosSection.FOLDERS && state.navigation.folders.isNotEmpty()) ({
                PhotoFolderPath(state.navigation.folders, !writing, Modifier.weight(1f), model::folderBackTo)
            }) else null,
        ) {
            if (state.access?.spaces.orEmpty().size > 1) Box {
                TextButton(onClick = { sources = true }, modifier = Modifier.heightIn(min = 48.dp).testTag("photos_source")) {
                    Text(stringResource(if (state.navigation.space == SynologyPhotoSpace.PERSONAL) R.string.sp_source_personal else R.string.sp_source_shared))
                    Icon(Icons.Outlined.ArrowDropDown, null)
                }
                DropdownMenu(sources, { sources = false }) {
                    state.access?.spaces.orEmpty().forEach { space ->
                        DropdownMenuItem(text = { Text(stringResource(if (space == SynologyPhotoSpace.PERSONAL) R.string.sp_source_personal else R.string.sp_source_shared)) },
                            onClick = { sources = false; filters = false; months = false; model.selectSpace(space) })
                    }
                }
            }
            model.uploads?.let { uploads ->
                IconButton(onClick = { uploads.open(state.navigation, state.access) }, enabled = state.access != null && !writing) {
                    Icon(Icons.Outlined.Upload, stringResource(R.string.sp_upload_title))
                }
            }
            if (state.items.isNotEmpty() || model.edits != null || model.requests != null || model.folders != null || model.files != null || model.folderSharing != null || model.settings != null || model.sharedMembers?.available == true || model.background != null || model.concepts?.available(state.navigation.space) == true && state.navigation.category == SynologyPhotoCategory.SUBJECTS || model.people?.available(state.navigation.space) == true && state.navigation.category == SynologyPhotoCategory.PEOPLE || model.maintenance?.available(state.navigation.space) == true || model.codecPrompt?.available == true || model.previewRegeneration?.available(state.navigation.space) == true) Box {
                IconButton(onClick = { more = true }, enabled = state.access != null && !writing) {
                    Icon(Icons.Outlined.MoreVert, stringResource(R.string.sp_edit_actions))
                }
                DropdownMenu(more, { more = false }) {
                    model.concepts?.takeIf { state.navigation.category == SynologyPhotoCategory.SUBJECTS && it.available(state.navigation.space) }?.let { concepts ->
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_concepts_visibility)) }, enabled = !state.loading,
                            onClick = { more = false; concepts.open(state.navigation.space) }, modifier = Modifier.testTag("photos_concepts_menu"))
                    }
                    model.people?.takeIf { state.navigation.category == SynologyPhotoCategory.PEOPLE && it.available(state.navigation.space) }?.let { people ->
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_people_visibility)) }, enabled = !state.loading,
                            onClick = { more = false; people.open(SynologyPhotoAlbumAction.SHOW_PEOPLE, state.navigation.space) }, modifier = Modifier.testTag("photos_people_menu"))
                    }
                    model.previewRegeneration?.takeIf { it.available(state.navigation.space) }?.let { previews ->
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_previews_queue)) }, enabled = !state.loading,
                            onClick = { more = false; previews.openQueue(state.navigation.space, context.cacheDir) }, modifier = Modifier.testTag("photos_previews_menu"))
                    }
                    model.codecPrompt?.takeIf { it.available }?.let { codec ->
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_codec_title)) }, enabled = !state.loading,
                            onClick = { more = false; codec.open() }, modifier = Modifier.testTag("photos_codec_menu"))
                    }
                    model.maintenance?.takeIf { it.available(state.navigation.space) }?.let { maintenance ->
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_maintenance_title)) }, enabled = !state.loading,
                            onClick = { more = false; maintenance.open(state.navigation.space) }, modifier = Modifier.testTag("photos_maintenance_menu"))
                    }
                    model.background?.let { tasks -> DropdownMenuItem(text = { Text(stringResource(R.string.sp_tasks_title)) },
                        onClick = { more = false; tasks.open() }, modifier = Modifier.testTag("photos_tasks_menu")) }
                    if (state.items.isNotEmpty()) DropdownMenuItem(text = { Text(stringResource(R.string.sp_slideshow_start)) },
                        enabled = model.canStartSlideshow, onClick = { more = false; model.startSlideshow() })
                    val archive = state.navigation.album?.let { SynologyPhotoArchiveTarget.Album(it.id) to it.name }
                        ?: state.navigation.folders.lastOrNull()?.takeIf { state.navigation.section == SynologyPhotosSection.FOLDERS }?.let { SynologyPhotoArchiveTarget.Folder(it.id, it.space) to it.name.takeUnless { name -> name == "/" }.orEmpty().ifEmpty { context.getString(R.string.sp_library_folders) } }
                    if (archive != null) DropdownMenuItem(text = { Text(stringResource(if (archive.first is SynologyPhotoArchiveTarget.Album) R.string.sp_export_album else R.string.sp_export_folder)) },
                        enabled = !writing && !state.loading, onClick = { more = false; model.exports.open(SynologyPhotoExportRequest.Archive(archive.first, archive.second)) })
                    if (state.navigation.category == SynologyPhotoCategory.SIMILAR) model.similar?.let { similar ->
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_similar_records)) }, enabled = !writing,
                            onClick = { more = false; similar.showRecords(state.navigation.space) }, modifier = Modifier.testTag("photos_similar_records_menu"))
                    }
                    model.sharedMembers?.takeIf { it.available }?.let { members ->
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_members_title)) }, enabled = !state.loading,
                            onClick = { more = false; members.open() }, modifier = Modifier.testTag("photos_members_menu"))
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_members_records)) },
                            onClick = { more = false; members.showRecords() }, modifier = Modifier.testTag("photos_members_records_menu"))
                    }
                    model.settings?.let { settings ->
                        val targets = buildList {
                            val navigation = state.navigation
                            if (navigation.album != null && navigation.keyword.isEmpty() && !navigation.filter.isActive && navigation.category == null)
                                add(SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.ALBUM_SORT, albumId = navigation.album.id))
                            navigation.albumListScope?.let { listScope ->
                                add(SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.LIST_SORT, listScope = listScope))
                                if (listScope == SynologyPhotoAlbumListScope.ALBUMS) add(SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.LIST_DISPLAY))
                            }
                        }
                        targets.filter { settings.available(it.kind) }.forEach { target ->
                            DropdownMenuItem(text = { Text(stringResource(target.settingsLabel())) }, enabled = !state.loading,
                                onClick = { more = false; settings.open(target) }, modifier = Modifier.testTag("photos_settings_menu_${target.kind.name}"))
                        }
                        SynologyPhotoSettingsKind.entries.filter { (it.userSetting || it in setOf(SynologyPhotoSettingsKind.SHARED, SynologyPhotoSettingsKind.GLOBAL)) && settings.available(it) }.forEach { kind ->
                            DropdownMenuItem(text = { Text(stringResource(kind.settingsLabel())) }, enabled = !state.loading,
                                onClick = { more = false; settings.open(kind) }, modifier = Modifier.testTag("photos_settings_menu_${kind.name}"))
                        }
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_settings_records)) }, onClick = { more = false; settings.showRecords() })
                    }
                    model.folders?.let { folders ->
                        state.folderAccess?.let { access ->
                            listOf(SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoAlbumAction.RENAME_FOLDER,
                                SynologyPhotoAlbumAction.SORT_FOLDER, SynologyPhotoAlbumAction.COVER_FOLDER).filter { SynologyPhotoFolderModel.allows(it, access) }.forEach { action ->
                                DropdownMenuItem(text = { Text(stringResource(action.folderLabel())) }, enabled = editState?.selecting != true,
                                    onClick = { more = false; folders.open(action, access.collection()) })
                            }
                        }
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_folder_records)) }, onClick = { more = false; folders.showRecords() })
                    }
                    model.folderSharing?.let { sharing ->
                        state.navigation.folders.lastOrNull()?.takeIf(sharing::canOpen)?.let { folder ->
                            DropdownMenuItem(text = { Text(stringResource(R.string.sp_folder_sharing_title)) }, enabled = editState?.selecting != true,
                                onClick = { more = false; sharing.open(folder) })
                        }
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_folder_sharing_records)) }, onClick = { more = false; sharing.showRecords() })
                    }
                    if (model.deletion.available) DropdownMenuItem(text = { Text(stringResource(R.string.sp_deletion_records)) }, onClick = { more = false; model.deletion.showRecords() })
                    model.files?.let { files -> DropdownMenuItem(text = { Text(stringResource(R.string.sp_files_records)) }, onClick = { more = false; files.showRecords() }) }
                    if ((state.items.isNotEmpty() || model.files != null && state.navigation.section == SynologyPhotosSection.FOLDERS && state.collections.isNotEmpty()) && model.edits != null) DropdownMenuItem(text = { Text(stringResource(if (model.files != null && state.navigation.section == SynologyPhotosSection.FOLDERS) R.string.sp_files_select else R.string.sp_edit_select)) },
                        onClick = { more = false; model.edits.selectMode(true) })
                    model.requests?.let { requests ->
                        if (state.access?.spaces.orEmpty().isNotEmpty()) DropdownMenuItem(text = { Text(stringResource(R.string.sp_request_create)) }, onClick = {
                            more = false
                            requests.open(folder = state.navigation.folders.lastOrNull().takeIf { state.navigation.section == SynologyPhotosSection.FOLDERS },
                                albumId = state.navigation.album?.takeIf { !it.isConditional && !it.isFrozen && !it.isTemporary }?.id)
                        })
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_request_records)) }, onClick = { more = false; requests.showRecords() })
                    }
                    model.albums?.let { albums ->
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_album_create)) }, onClick = { more = false; albums.open(SynologyPhotoAlbumAction.CREATE) })
                        if (albums.canManageConditions && state.access?.spaces.orEmpty().any { it == SynologyPhotoSpace.PERSONAL || state.access?.canManageSharedSpace == true })
                            DropdownMenuItem(text = { Text(stringResource(R.string.sp_condition_create)) }, onClick = { more = false; albums.open(SynologyPhotoAlbumAction.CREATE_CONDITION) })
                        state.navigation.album?.let { album -> DropdownMenuItem(text = { Text(stringResource(R.string.sp_album_manage)) },
                            onClick = { more = false; albums.manage(album.id, state.navigation.section == SynologyPhotosSection.SHARING && state.navigation.shareScope == SynologyPhotoShareScope.WITH_OTHERS) }) }
                        DropdownMenuItem(text = { Text(stringResource(R.string.sp_album_records)) }, onClick = { more = false; albums.showRecords() })
                    }
                    if (model.edits != null && model.canEditPhotos && state.navigation.space in state.access?.spaces.orEmpty()) DropdownMenuItem(text = { Text(stringResource(R.string.sp_edit_create_tag)) },
                        onClick = { more = false; model.edits?.open(emptyList(), state.navigation.space) })
                    if (model.edits != null && model.canEditPhotos) DropdownMenuItem(text = { Text(stringResource(R.string.sp_edit_records)) }, onClick = { more = false; model.edits.showRecords() })
                }
            }
            if (canBackup) IconButton(onClick = onBackup) { Icon(Icons.Outlined.CloudUpload, stringResource(R.string.client_photo_backup)) }
            IconButton(onClick = { model.refresh() }, enabled = !state.loading && !writing) { Icon(Icons.Outlined.Refresh, stringResource(R.string.sp_library_refresh)) }
        }
        if (editState?.selecting == true) {
            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.Center) {
                Text(stringResource(R.string.items_selected_count, editState.selected.size + editState.selectedFolders.size), Modifier.padding(vertical = 14.dp))
                TextButton(onClick = { model.edits?.selectLoaded(state.items, state.collections.takeIf { state.navigation.section == SynologyPhotosSection.FOLDERS && model.files != null }.orEmpty()) }, enabled = !writing) { Text(stringResource(if (model.files != null && state.navigation.section == SynologyPhotosSection.FOLDERS) R.string.sp_files_select_loaded else R.string.sp_edit_select_loaded)) }
                TextButton(onClick = {
                    val request = if (editState.selectedFolders.isEmpty()) SynologyPhotoExportRequest.Items(editState.selected)
                        else SynologyPhotoExportRequest.Archive(SynologyPhotoArchiveTarget.Selection(editState.selected, editState.selectedFolders),
                            context.getString(R.string.sp_export_selection_filename))
                    if (state.navigation.category == SynologyPhotoCategory.SIMILAR && editState.selectedFolders.isEmpty() && model.similar != null)
                        model.similar.exportGroups(editState.selected)
                    else model.exports.open(request, state.access?.supportsOriginalSizeJPEG == true)
                }, enabled = (editState.selected.isNotEmpty() || editState.selectedFolders.isNotEmpty()) && !writing,
                    modifier = Modifier.testTag("photos_export_selected")) { Text(stringResource(R.string.sp_media_save)) }
                model.previewRegeneration?.let { previews ->
                    if (editState.selected.isNotEmpty() && editState.selected.all { previews.available(it.id.space) }) TextButton(
                        onClick = { previews.open(editState.selected, context.cacheDir) }, enabled = editState.selected.size <= 100 && editState.selectedFolders.isEmpty() && !writing,
                        modifier = Modifier.testTag("photos_previews_selected")) { Text(stringResource(R.string.sp_preview_regeneration_title)) }
                }
                if (model.canEditPhotos) TextButton(onClick = { model.edits?.open(editState.selected, state.navigation.space) }, enabled = editState.selected.isNotEmpty() && editState.selectedFolders.isEmpty() && !writing) { Text(stringResource(R.string.sp_edit_title)) }
                if (state.navigation.category == SynologyPhotoCategory.SIMILAR) model.similar?.let { similar ->
                    if (similar.available(state.navigation.space)) TextButton(onClick = { similar.prepareBatch(editState.selected) },
                        enabled = editState.selected.size in 1..100 && editState.selectedFolders.isEmpty() && !writing,
                        modifier = Modifier.testTag("photos_similar_ungroup_selected")) { Text(stringResource(R.string.sp_similar_ungroup)) }
                }
                model.concepts?.let { PhotoConceptSelectionActions(it, state.navigation, editState.selected, editState.selectedFolders.isEmpty() && !writing) }
                model.people?.let { PhotoPersonSelectionActions(it, state.navigation, editState.selected, editState.selectedFolders.isEmpty() && !writing) }
                model.files?.let { files ->
                    var actions by remember { mutableStateOf(false) }
                    Box {
                        TextButton(onClick = { actions = true }, enabled = (editState.selected.isNotEmpty() || editState.selectedFolders.isNotEmpty()) &&
                            (files.canTransfer || files.canDelete && editState.selectedFolders.isNotEmpty()) && !writing,
                            modifier = Modifier.testTag("photos_files_actions")) { Text(stringResource(R.string.sp_files_manage)) }
                        DropdownMenu(actions, { actions = false }) { PhotoFileMenuItems(files, editState.selected, editState.selectedFolders) { actions = false } }
                    }
                }
                if (model.deletion.available && editState.selectedFolders.isEmpty()) TextButton(
                    onClick = { model.deletion.prepare(editState.selected) },
                    enabled = editState.selected.isNotEmpty() && editState.selected.all(model.deletion::enabled) && !writing && !deletionState.checking,
                    modifier = Modifier.testTag("photos_deletion_selected")) { Text(stringResource(R.string.sp_delete_action)) }
                model.albums?.let { albums ->
                    var actions by remember { mutableStateOf(false) }
                    Box {
                        TextButton(onClick = { actions = true }, enabled = editState.selected.isNotEmpty() && editState.selectedFolders.isEmpty() && !writing) { Text(stringResource(R.string.sp_album_manage)) }
                        DropdownMenu(actions, { actions = false }) {
                            if (albums.canManageSharing && SynologyPhotoSpace.PERSONAL in state.access?.spaces.orEmpty())
                                DropdownMenuItem(text = { Text(stringResource(R.string.sp_temporary_create)) }, onClick = { actions = false; albums.open(SynologyPhotoAlbumAction.CREATE_TEMPORARY, editState.selected) })
                            DropdownMenuItem(text = { Text(stringResource(R.string.sp_album_create)) }, onClick = { actions = false; albums.open(SynologyPhotoAlbumAction.CREATE, editState.selected) })
                            DropdownMenuItem(text = { Text(stringResource(R.string.sp_album_add)) }, onClick = { actions = false; albums.open(SynologyPhotoAlbumAction.ADD, editState.selected) })
                            state.navigation.album?.let { album ->
                                if (!album.isConditional && !album.isFrozen && !album.isTemporary) DropdownMenuItem(text = { Text(stringResource(R.string.sp_album_remove)) }, onClick = { actions = false; albums.open(SynologyPhotoAlbumAction.REMOVE, editState.selected, album.id) })
                                if (editState.selected.size == 1 && !album.isTemporary) DropdownMenuItem(text = { Text(stringResource(R.string.sp_album_cover)) }, onClick = { actions = false; albums.open(SynologyPhotoAlbumAction.COVER, editState.selected, album.id) })
                            }
                        }
                    }
                }
                TextButton(onClick = { model.edits?.selectMode(false) }, enabled = !writing) { Text(stringResource(R.string.cancel)) }
            }
            editState.error?.let { Text(photoEditError(it), Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error) }
        }
        LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(SynologyPhotosSection.entries.filter { state.access?.spaces?.isEmpty() != true || it in setOf(SynologyPhotosSection.ALBUMS, SynologyPhotosSection.SHARING) }, key = { it.name }) { section ->
                FilterChip(state.navigation.section == section, onClick = { model.selectSection(section) }, label = { Text(stringResource(section.label())) })
            }
        }
        if (state.access?.spaces?.isEmpty() != true) Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            ClientSearchField(search, { search = it }, stringResource(if (state.navigation.isRequests) R.string.sp_request_search else R.string.sp_library_search), Modifier.weight(1f), onSearch = { model.search(search) })
            if (!state.navigation.isRequests) IconButton(onClick = { filters = true; model.loadFilterOptions() }) { Icon(Icons.Outlined.FilterList, stringResource(R.string.sp_filters)) }
            if (state.months.isNotEmpty()) IconButton(onClick = { months = true }) { Icon(Icons.Outlined.CalendarMonth, stringResource(R.string.sp_timeline_navigator)) }
        }
        if (state.navigation.filter.isActive) TextButton(onClick = { model.applyFilter(SynologyPhotoFilter()) }, modifier = Modifier.padding(horizontal = 12.dp)) {
            Text(stringResource(R.string.sp_filters_clear))
        }
        if (state.navigation.section == SynologyPhotosSection.SHARING && state.navigation.album == null) {
            LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(SynologyPhotoShareScope.entries) { scope ->
                    FilterChip(state.navigation.shareScope == scope, { model.selectShareScope(scope) }, label = { Text(stringResource(scope.label())) })
                }
            }
        }
        if (state.preferenceErrors.isNotEmpty()) Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.sp_album_preferences_failed), Modifier.weight(1f), color = MaterialTheme.colorScheme.error)
            TextButton(onClick = { model.refresh() }, enabled = !state.loading && !writing) { Text(stringResource(R.string.sp_retry)) }
        }
        similarState?.status?.takeIf { it.visible }?.let { status ->
            Text(stringResource(if (status.running) R.string.sp_similar_recognizing else R.string.sp_similar_waiting), Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        }
        model.automaticPreviews?.let { SynologyPhotoAutomaticPreviews(it) }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when {
                state.loading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                state.empty && state.error != null -> PhotoErrorPanel(state.error!!, onRetry = { model.refresh() }, Modifier.align(Alignment.Center))
                else -> SynologyPhotosGrid(state, model)
            }
        }
    }
    if (filters) SynologyPhotoFilters(state, onRetry = { model.loadFilterOptions() }, onDismiss = { filters = false }) { filter ->
        filters = false; model.applyFilter(filter)
    }
    if (months) ClientPageDialog(stringResource(R.string.sp_timeline_navigator), { months = false }) {
        val locale = LocalConfiguration.current.locales[0]
        val format = remember(locale) { DateTimeFormatter.ofPattern("LLLL yyyy", locale) }
        LazyColumn(Modifier.fillMaxSize()) {
            items(state.months, key = { it.toString() }) { month ->
                ListItem(headlineContent = { Text(month.format(format)) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable {
                    months = false; model.jumpToMonth(month)
                })
            }
        }
    }
    model.similar?.let { SynologyPhotoSimilarGroups(it, model) }
    SynologyPhotoPreview(model)
    SynologyPhotoSlideshow(model.slideshow)
    SynologyPhotoExport(model.exports)
    SynologyPhotoDeletions(model.deletion)
    model.uploads?.let { SynologyPhotoUploads(state, it) }
    model.edits?.let { SynologyPhotoEdits(it) }
    model.albums?.let { SynologyPhotoAlbums(it) }
    model.requests?.let { SynologyPhotoRequests(it) }
    model.folders?.let { SynologyPhotoFolders(it, model) }
    model.folderSharing?.let { SynologyPhotoFolderSharing(it) }
    model.files?.let { SynologyPhotoFiles(it) }
    model.settings?.let { SynologyPhotoSettings(it) }
    model.sharedMembers?.let { SynologyPhotoSharedMembers(it) }
    model.background?.let { SynologyPhotoBackgroundTasks(it) }
    model.maintenance?.let { SynologyPhotoMaintenance(it) }
    model.concepts?.let { SynologyPhotoConcepts(it) }
    model.people?.let { SynologyPhotoPeople(it) }
    model.manualFaces?.let { SynologyPhotoManualFaces(it) }
    model.codecPrompt?.let { SynologyPhotoCodecPrompt(it) }
    model.previewRegeneration?.let { SynologyPhotoPreviewRegeneration(it, state.access?.spaces.orEmpty()) }
}

@Composable
internal fun PhotoErrorPanel(error: Throwable, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(photoError(error), color = MaterialTheme.colorScheme.error)
        Button(onClick = onRetry) { Text(stringResource(R.string.sp_retry)) }
    }
}

private fun Context.photoActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.takeIf { it !== this }?.photoActivity()
    else -> null
}
