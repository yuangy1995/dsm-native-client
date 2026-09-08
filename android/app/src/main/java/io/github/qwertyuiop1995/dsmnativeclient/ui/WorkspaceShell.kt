package io.github.qwertyuiop1995.dsmnativeclient.ui

import android.animation.ValueAnimator
import androidx.activity.BackEventCompat
import androidx.activity.compose.PredictiveBackHandler
import androidx.annotation.StringRes
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.chatUnreadCount
import io.github.qwertyuiop1995.dsmnativeclient.workspaceRouteStack
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspaceRouteStack
import io.github.qwertyuiop1995.dsmnativeclient.localization.messageResource
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

internal enum class WorkspaceBackAction {
    CLOSE_DRAWER,
    NAVIGATE_UP,
    EXIT,
}

internal fun workspaceBackAction(
    isExpanded: Boolean,
    isDrawerOpen: Boolean,
    routeStack: WorkspaceRouteStack,
): WorkspaceBackAction = when {
    !isExpanded && isDrawerOpen -> WorkspaceBackAction.CLOSE_DRAWER
    routeStack.entries.size > 1 -> WorkspaceBackAction.NAVIGATE_UP
    else -> WorkspaceBackAction.EXIT
}

internal fun predictiveBackVisualProgress(
    progress: Float,
    animationsEnabled: Boolean,
): Float = if (animationsEnabled) progress.coerceIn(0f, 1f) else 0f

internal fun predictiveBackDirection(swipeEdge: Int): Float =
    if (swipeEdge == BackEventCompat.EDGE_RIGHT) -1f else 1f


@Composable
internal fun WorkspaceShell(
    state: WorkspaceState,
    onModuleSelected: (Module) -> Unit,
    onRefresh: () -> Unit,
    onNavigateUp: () -> Unit,
    onSwitchNas: () -> Unit = {},
    onLogout: () -> Unit,
    onMessageShown: () -> Unit,
    canCopyPageLink: Boolean = false,
    onCopyPageLink: () -> Unit = {},
    destination: ClientDestination = ClientDestination.forModule(state.selectedModule),
    pinned: PinnedModules = PinnedModules(),
    onDestinationSelected: (ClientDestination) -> Unit = { onModuleSelected(it.module) },
    onCustomize: () -> Unit = {},
    onSearch: (() -> Unit)? = null,
    pageTitle: String? = null,
    canNavigateUp: Boolean = state.workspaceRouteStack().entries.size > 1,
    content: @Composable () -> Unit,
) {
    var featuresVisible by remember { mutableStateOf(false) }
    var profileVisible by remember { mutableStateOf(false) }
    var logoutConfirmation by remember { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    val predictiveBackProgress = remember { Animatable(0f) }
    var predictiveBackSwipeEdge by remember { mutableIntStateOf(BackEventCompat.EDGE_LEFT) }
    LaunchedEffect(state.message) {
        state.message?.let { snackbar.showSnackbar(it); onMessageShown() }
    }
    val backAction = if (canNavigateUp) WorkspaceBackAction.NAVIGATE_UP else WorkspaceBackAction.EXIT
    PredictiveBackHandler(enabled = backAction != WorkspaceBackAction.EXIT && !featuresVisible && !profileVisible) { events ->
        try {
            events.collect { event ->
                predictiveBackSwipeEdge = event.swipeEdge
                predictiveBackProgress.snapTo(
                    predictiveBackVisualProgress(
                        progress = event.progress,
                        animationsEnabled = ValueAnimator.areAnimatorsEnabled(),
                    ),
                )
            }
            onNavigateUp()
            predictiveBackProgress.snapTo(0f)
        } catch (_: CancellationException) {
            withContext(NonCancellable) {
                if (ValueAnimator.areAnimatorsEnabled()) {
                    predictiveBackProgress.animateTo(0f, animationSpec = tween(150))
                } else {
                    predictiveBackProgress.snapTo(0f)
                }
            }
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val compact = maxWidth < 600.dp
        val expanded = maxWidth >= 840.dp
        val focusedConversation = compact && destination == ClientDestination.CHAT && state.selectedConversation != null
        Row(Modifier.fillMaxSize()) {
            if (!compact) ClientSideNavigation(state, pinned, destination, expanded, onDestinationSelected) {
                featuresVisible = true
            }
            Scaffold(
                modifier = Modifier.weight(1f).fillMaxHeight(),
                contentWindowInsets = WindowInsets(0),
                topBar = {
                    if (!focusedConversation) Surface(color = MaterialTheme.colorScheme.surface) {
                        Column {
                            Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = 56.dp).padding(horizontal = 8.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                if (canNavigateUp) IconButton(onClick = onNavigateUp) {
                                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.go_up))
                                }
                                if (pageTitle != null) {
                                    Text(pageTitle, style = MaterialTheme.typography.titleMedium,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).padding(8.dp))
                                } else TextButton(onClick = { profileVisible = true }, modifier = Modifier.weight(1f),
                                    contentPadding = PaddingValues(horizontal = 8.dp)) {
                                    Text(state.profile.name, color = MaterialTheme.colorScheme.onSurface, maxLines = 1,
                                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                                    Icon(Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
                                }
                                if (onSearch != null) IconButton(onClick = onSearch) {
                                    Icon(Icons.Outlined.Search, stringResource(R.string.client_search))
                                }
                                if (destination != ClientDestination.TASKS) IconButton(onClick = { onDestinationSelected(ClientDestination.TASKS) }) {
                                    Icon(Icons.Outlined.AssignmentTurnedIn, stringResource(R.string.client_tasks))
                                }
                                if (compact) IconButton(onClick = { featuresVisible = true }) {
                                    Icon(Icons.Outlined.GridView, stringResource(R.string.client_all_features))
                                }
                            }
                            HorizontalDivider()
                        }
                    }
                },
                bottomBar = {
                    if (compact && !focusedConversation) ClientBottomNavigation(pinned,
                        if (destination == ClientDestination.NAS_SETTINGS) ClientDestination.DEVICE else destination,
                        onDestinationSelected, chatUnreadCount(state.conversations), availability = state.availability)
                },
                snackbarHost = { SnackbarHost(snackbar, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) },
            ) { padding ->
                Box(Modifier.fillMaxSize().padding(padding)
                    .then(if (focusedConversation) Modifier.safeDrawingPadding() else if (!compact || pinned.items.isEmpty())
                        Modifier.navigationBarsPadding() else Modifier)
                    .graphicsLayer {
                        val progress = if (backAction == WorkspaceBackAction.NAVIGATE_UP) predictiveBackProgress.value else 0f
                        translationX = progress * predictiveBackDirection(predictiveBackSwipeEdge) * 32.dp.toPx()
                        alpha = 1f - progress * 0.08f
                    }) {
                    content()
                    if (state.isPerformingAction) {
                        val processing = stringResource(R.string.processing_action)
                        LinearProgressIndicator(Modifier.fillMaxWidth().semantics { contentDescription = processing })
                    }
                }
            }
        }
    }
    if (featuresVisible) ClientSheet(stringResource(R.string.client_all_features), { featuresVisible = false }, Modifier.testTag(WORKSPACE_MODAL_DRAWER_TEST_TAG)) {
        ClientFeatureGrid(ClientDestination.pinnable, pinned, state.availability) {
            featuresVisible = false
            onDestinationSelected(it)
        }
        HorizontalDivider()
        ClientRow(stringResource(R.string.client_custom_navigation), Icons.Outlined.Edit) {
            featuresVisible = false; onCustomize()
        }
        ClientRow(stringResource(R.string.refresh), Icons.Outlined.Refresh) { featuresVisible = false; onRefresh() }
        if (canCopyPageLink && destination !in listOf(ClientDestination.HOME, ClientDestination.DEVICE)) {
            ClientRow(stringResource(R.string.copy_page_link), Icons.Outlined.Link) { featuresVisible = false; onCopyPageLink() }
        }
    }
    if (profileVisible) ClientSheet(state.profile.name, { profileVisible = false }) {
        ClientRow(stringResource(R.string.switch_nas), Icons.Outlined.Dns,
            stringResource(R.string.switch_nas_description), enabled = !state.isPerformingAction) {
            profileVisible = false; onSwitchNas()
        }
        ClientRow(stringResource(R.string.client_app_settings), Icons.Outlined.Settings) {
            profileVisible = false; onDestinationSelected(ClientDestination.SETTINGS)
        }
        ClientRow(stringResource(R.string.sign_out_description), Icons.AutoMirrored.Outlined.Logout,
            enabled = !state.isPerformingAction, destructive = true) { logoutConfirmation = true; profileVisible = false }
    }
    if (logoutConfirmation) ConfirmDialog(
        stringResource(R.string.client_logout_confirmation), stringResource(R.string.client_logout_hint),
        stringResource(R.string.sign_out_description), true,
        onConfirm = { logoutConfirmation = false; onLogout() }, onDismiss = { logoutConfirmation = false },
    )
}

@Composable
private fun ClientSideNavigation(state: WorkspaceState, pinned: PinnedModules, selected: ClientDestination, expanded: Boolean,
    onSelect: (ClientDestination) -> Unit, onShowFeatures: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.width(if (expanded) 216.dp else 88.dp).fillMaxHeight().safeDrawingPadding()
            .verticalScroll(rememberScrollState()).padding(8.dp).testTag(WORKSPACE_NAVIGATION_RAIL_TEST_TAG)) {
            IconButton(onClick = onShowFeatures) { Icon(Icons.Outlined.GridView, stringResource(R.string.client_all_features)) }
            pinned.items.forEach { item ->
                val unread = if (item == ClientDestination.CHAT) chatUnreadCount(state.conversations) else 0
                val reason = state.availability.firstOrNull { it.module == item.module }.navigationStatusResource()?.let { stringResource(it) }
                    ?: if (unread > 0) pluralStringResource(R.plurals.unread_count, unread, unread) else null
                val status = Modifier.semantics { reason?.let { stateDescription = it } }
                if (expanded) NavigationDrawerItem(
                    modifier = status,
                    label = { Text(stringResource(item.title)) }, icon = { Icon(item.icon, null) },
                    selected = item == selected, onClick = { onSelect(item) },
                ) else NavigationRailItem(
                    modifier = status,
                    selected = item == selected, onClick = { onSelect(item) },
                    icon = { Icon(item.icon, null) }, label = { Text(stringResource(item.title)) },
                )
            }
        }
    }
}

internal const val WORKSPACE_NAVIGATION_RAIL_TEST_TAG = "workspace_navigation_rail"
internal const val WORKSPACE_BOTTOM_NAVIGATION_TEST_TAG = "client_bottom_navigation"
internal const val WORKSPACE_MODAL_DRAWER_TEST_TAG = "client_all_features"

@StringRes
internal fun ModuleAvailability?.navigationStatusResource(): Int? = when {
    this?.isAvailable != false -> null
    reason != null -> reason.messageResource()
    else -> R.string.unavailable
}

@StringRes
internal fun Module.titleResource(): Int = when (this) {
    Module.FILES -> R.string.module_files
    Module.PHOTOS -> R.string.module_photos
    Module.CHAT -> R.string.module_chat
    Module.DOWNLOADS -> R.string.module_downloads
    Module.CONTAINERS -> R.string.module_containers
    Module.VIRTUAL_MACHINES -> R.string.module_virtual_machines
    Module.NAS_SETTINGS -> R.string.module_nas_settings
    Module.TRANSFERS -> R.string.module_transfers
    Module.SETTINGS -> R.string.module_settings
}

internal fun Module.icon(): ImageVector = when (this) {
    Module.FILES -> Icons.Outlined.Folder
    Module.PHOTOS -> Icons.Outlined.PhotoLibrary
    Module.CHAT -> Icons.Outlined.ChatBubbleOutline
    Module.DOWNLOADS -> Icons.Outlined.CloudDownload
    Module.CONTAINERS -> Icons.Outlined.Dns
    Module.VIRTUAL_MACHINES -> Icons.Outlined.Computer
    Module.NAS_SETTINGS -> Icons.Outlined.Storage
    Module.TRANSFERS -> Icons.Outlined.SwapVert
    Module.SETTINGS -> Icons.Outlined.Settings
}
