package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.storage.ClientNavigationPreferences
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.ClientTaskCenterScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.ClientTaskSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 全新界面路由只拥有展示状态；业务导航和退出保护仍由 AppViewModel 决定。 */
@Composable
internal fun ClientWorkspace(state: WorkspaceState, model: AppViewModel) {
    val context = LocalContext.current.applicationContext
    val preferences = remember(context) { ClientNavigationPreferences(context) }
    var pinned by remember { mutableStateOf(preferences.load()) }
    var editorVisible by remember { mutableStateOf(false) }
    val signal by model.moduleNavigation.collectAsStateWithLifecycle()
    var destination by rememberSaveable(state.profile.id) { mutableStateOf(
        signal?.takeIf { it.profileId == state.profile.id }?.let { ClientDestination.forModule(it.module) }
            ?: ClientDestination.HOME,
    ) }
    var handledRevision by rememberSaveable(state.profile.id) { mutableLongStateOf(signal?.revision ?: 0L) }
    var deferredDestination by rememberSaveable(state.profile.id) { mutableStateOf<ClientDestination?>(null) }
    var entry by remember { mutableStateOf<ClientEntryRequest?>(null) }
    var nextEntryRevision by remember { mutableLongStateOf(0L) }
    var deviceCategory by rememberSaveable(state.profile.id) { mutableStateOf<DeviceCategory?>(null) }
    var taskSource by rememberSaveable(state.profile.id) { mutableStateOf(ClientTaskSource.PHONE) }
    var photosEntered by rememberSaveable(state.profile.id) { mutableStateOf(false) }

    fun requestEntry(action: ClientEntryAction?) {
        if (action == null) { entry = null; return }
        val revision = ++nextEntryRevision
        entry = ClientEntryRequest(action, revision) { if (entry?.revision == revision) entry = null }
    }

    fun navigate(target: ClientDestination, action: ClientEntryAction? = null, keepDeviceCategory: Boolean = false): Boolean {
        val result = model.requestClientModule(target.module)
        return when (result) {
            WorkspaceNavigationResult.APPLIED, WorkspaceNavigationResult.ALREADY_SELECTED -> {
                handledRevision = model.moduleNavigation.value?.revision ?: handledRevision
                destination = target
                deferredDestination = null
                if (!keepDeviceCategory) deviceCategory = null
                if (target == ClientDestination.TASKS) taskSource = ClientTaskSource.PHONE
                if (target == ClientDestination.PHOTOS && !photosEntered) {
                    photosEntered = true
                    if (action != ClientEntryAction.PHOTO_BACKUP) model.setPhotoMode(io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoBrowseMode.TIMELINE)
                }
                requestEntry(action)
                true
            }
            WorkspaceNavigationResult.DEFERRED -> { deferredDestination = target; false }
            WorkspaceNavigationResult.REJECTED -> { deferredDestination = null; false }
        }
    }

    LaunchedEffect(signal) {
        val event = signal ?: return@LaunchedEffect
        if (event.profileId != state.profile.id || event.revision == handledRevision) return@LaunchedEffect
        destination = deferredDestination?.takeIf { it.module == event.module } ?: ClientDestination.forModule(event.module)
        deferredDestination = null
        entry = null
        handledRevision = event.revision
    }
    LaunchedEffect(state.previewDiscardConfirmationVisible) {
        if (!state.previewDiscardConfirmationVisible && signal?.revision == handledRevision) deferredDestination = null
    }
    LaunchedEffect(destination, state.profile.id) {
        if (destination == ClientDestination.DEVICE && state.availability.firstOrNull { it.module == Module.NAS_SETTINGS }?.isAvailable != false) {
            model.load(Module.NAS_SETTINGS)
        }
    }

    val nestedBusinessRoute = destination !in listOf(ClientDestination.HOME, ClientDestination.DEVICE) && state.workspaceRouteStack().entries.size > 1
    val secondary = destination !in pinned.items && destination != ClientDestination.HOME
    val pageTitle = when {
        destination == ClientDestination.DEVICE && deviceCategory != null -> stringResource(deviceCategory!!.title)
        destination == ClientDestination.NAS_SETTINGS -> stringResource(state.nasPerformance.selectedTab.clientTitle())
        destination == ClientDestination.FILES && state.fileBrowser.path.isNotBlank() -> state.fileBrowser.path.substringAfterLast('/')
        secondary -> stringResource(destination.title)
        else -> null
    }
    WorkspaceShell(
        state = state,
        onModuleSelected = { navigate(ClientDestination.forModule(it)) },
        onRefresh = { model.load(if (destination == ClientDestination.DEVICE) Module.NAS_SETTINGS else null) },
        onNavigateUp = {
            when {
                destination == ClientDestination.DEVICE && deviceCategory != null -> deviceCategory = null
                destination == ClientDestination.NAS_SETTINGS -> navigate(ClientDestination.DEVICE, keepDeviceCategory = true)
                nestedBusinessRoute -> model.navigateUp()
                destination in listOf(ClientDestination.CONTAINERS, ClientDestination.VIRTUAL_MACHINES, ClientDestination.SETTINGS) -> navigate(ClientDestination.DEVICE)
                else -> navigate(ClientDestination.HOME)
            }
        },
        onSwitchNas = { model.switchNas() }, onLogout = model::logout, onMessageShown = model::clearMessage,
        canCopyPageLink = model.canCopyCurrentPageLink(), onCopyPageLink = { model.copyCurrentPageLink() },
        destination = destination, pinned = pinned,
        onDestinationSelected = { navigate(it) }, onCustomize = { editorVisible = true },
        onSearch = if (destination in listOf(ClientDestination.FILES, ClientDestination.PHOTOS, ClientDestination.CHAT))
            ({ requestEntry(ClientEntryAction.SEARCH) }) else null,
        pageTitle = pageTitle,
        canNavigateUp = nestedBusinessRoute || secondary || deviceCategory != null,
    ) {
        CompositionLocalProvider(LocalClientEntry provides entry) {
            WorkspaceModuleSaveableState(state.profile.id, state.selectedModule) {
            when (destination) {
                ClientDestination.HOME -> ClientHomeScreen(state, model.recentDirectories(),
                    onOpenDirectory = { if (navigate(ClientDestination.FILES)) model.openRecentDirectory(it) },
                    onOpen = { navigate(it) },
                    onAction = { action ->
                        navigate(when (action) {
                            ClientEntryAction.PHOTO_BACKUP -> ClientDestination.PHOTOS
                            ClientEntryAction.DOWNLOAD_CREATE -> ClientDestination.DOWNLOADS
                            else -> ClientDestination.FILES
                        }, action)
                    })
                ClientDestination.DEVICE -> ClientDeviceScreen(state, deviceCategory,
                    onCategory = { deviceCategory = it },
                    onTab = { if (navigate(ClientDestination.NAS_SETTINGS, keepDeviceCategory = true)) model.selectNasSettingsTab(it) },
                    onOpen = { navigate(it) }, onRefresh = { model.load(Module.NAS_SETTINGS) })
                ClientDestination.TASKS -> ClientTaskCenterScreen(state, model, taskSource) { source ->
                    val target = if (source == ClientTaskSource.DOWNLOADS) Module.DOWNLOADS else Module.TRANSFERS
                    val result = model.requestClientModule(target)
                    if (result == WorkspaceNavigationResult.APPLIED || result == WorkspaceNavigationResult.ALREADY_SELECTED) {
                        handledRevision = model.moduleNavigation.value?.revision ?: handledRevision
                        taskSource = source
                    }
                }
                ClientDestination.SETTINGS -> io.github.qwertyuiop1995.dsmnativeclient.ui.settings.SettingsScreen(state, model) { editorVisible = true }
                else -> ModuleContent(state, model)
            }
            }
        }
    }
    if (editorVisible) ClientNavigationEditor(pinned, onSave = { value ->
        val saved = withContext(Dispatchers.IO) { preferences.save(value) }
        if (saved) pinned = value
        saved
    }, onDismiss = { editorVisible = false })
}
