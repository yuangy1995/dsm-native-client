package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasProgressBarRangeInfo
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerRegistryImage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBrowserState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewContent
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileTypeFilter
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasStorageDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.PERSONAL_PHOTO_SPACE
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoBrowserState
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItemKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoMediaFilter
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisProgress
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.SystemSummary
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineOverview
import io.github.qwertyuiop1995.dsmnativeclient.ui.ChatScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.FileBrowserScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.FileCopyMoveDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.FilePreviewDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.PhotoMoveDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.PhotosScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasSettingsScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasStorageScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.ContainersScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VirtualMachineCreationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VirtualMachinesScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

/** 高频页面族的真实生产 Composable 状态矩阵。 */
class PrimaryPageStateMatrixTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun ChatScreen覆盖加载空错误和内容() {
        val model = model()
        var state by mutableStateOf(baseState(conversations = Loadable.Loading))
        rule.setContent { LanStashTheme { ChatScreen(state, model) } }

        assertLoading()
        update { state = baseState(conversations = Loadable.Ready(emptyList())) }
        rule.onNodeWithText(text(R.string.no_conversations)).assertIsDisplayed()
        update { state = baseState(conversations = failure()) }
        assertFailure()
        update {
            state = baseState(
                conversations = Loadable.Ready(listOf(conversation())),
            )
        }
        rule.onNodeWithText(CHAT_TITLE).assertIsDisplayed()
    }

    @Test
    fun ChatScreen大字小屏错误恢复操作可见() {
        val model = model()
        setAdaptiveContent { ChatScreen(baseState(conversations = failure()), model) }
        assertFailure()
    }

    @Test
    fun FileBrowserScreen覆盖加载空筛选空错误和内容() {
        val model = model()
        var state by mutableStateOf(baseState(files = Loadable.Loading))
        rule.setContent { LanStashTheme { FileBrowserScreen(state, model) } }

        assertLoading(expectedCount = 2)
        update { state = baseState(files = Loadable.Ready(FilePage(emptyList(), 0, 0))) }
        rule.onNodeWithText(text(R.string.directory_empty)).assertIsDisplayed()
        update {
            state = baseState(
                files = Loadable.Ready(FilePage(listOf(folder()), 1, 0)),
                fileBrowser = FileBrowserState(typeFilter = FileTypeFilter.FILES),
            )
        }
        rule.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed()
        update { state = baseState(files = failure()) }
        assertFailure()
        update { state = baseState(files = Loadable.Ready(FilePage(listOf(folder()), 1, 0))) }
        rule.onNodeWithText(FOLDER_NAME).assertIsDisplayed()
    }

    @Test
    fun FileBrowserScreen大字小屏错误恢复操作可见() {
        val model = model()
        setAdaptiveContent { FileBrowserScreen(baseState(files = failure()), model) }
        assertFailure()
    }

    @Test
    fun FileCopyMoveDialog覆盖加载空错误和内容() {
        val model = model()
        var state by mutableStateOf(copyMoveState(Loadable.Loading))
        rule.setContent { LanStashTheme { FileCopyMoveDialog(state, model) } }

        assertLoading()
        update { state = copyMoveState(Loadable.Ready(FilePage(emptyList(), 0, 0))) }
        rule.onNodeWithText(text(R.string.no_subfolders)).assertIsDisplayed()
        update { state = copyMoveState(failure()) }
        assertFailure()
        update { state = copyMoveState(Loadable.Ready(FilePage(listOf(folder()), 1, 0))) }
        rule.onNodeWithText(FOLDER_NAME).assertIsDisplayed()
    }

    @Test
    fun FileCopyMoveDialog两倍字体错误恢复操作可见() {
        val model = model()
        setTwoXContent { FileCopyMoveDialog(copyMoveState(failure()), model) }
        assertFailure()
    }

    @Test
    fun FilePreviewDialog覆盖加载错误和内容() {
        val item = textFile()
        var preview: Loadable<FilePreviewContent> by mutableStateOf(Loadable.Loading)
        rule.setContent {
            LanStashTheme {
                FilePreviewDialog(item, preview, onRetry = {}, onClose = {}, embedded = true)
            }
        }

        rule.onNodeWithText(text(R.string.preview_loading)).assertIsDisplayed()
        update { preview = failure() }
        assertFailure()
        update {
            preview = Loadable.Ready(
                FilePreviewContent.Text(item, PREVIEW_BODY, truncated = false),
            )
        }
        rule.onNodeWithText(PREVIEW_BODY).assertIsDisplayed()
    }

    @Test
    fun FilePreviewDialog两倍字体错误恢复操作可见() {
        val item = textFile()
        setTwoXContent {
            FilePreviewDialog(item, failure(), onRetry = {}, onClose = {}, embedded = true)
        }
        assertFailure()
    }

    @Test
    fun PhotosScreen覆盖加载空筛选空错误和内容() {
        val model = model()
        var state by mutableStateOf(baseState(photos = Loadable.Loading))
        rule.setContent { LanStashTheme { PhotosScreen(state, model) } }

        assertLoading()
        update { state = baseState(photos = Loadable.Ready(photoPage())) }
        rule.onNodeWithText(text(R.string.no_photos)).assertIsDisplayed()
        update {
            state = baseState(
                photos = Loadable.Ready(photoPage(listOf(photo()))),
                photoBrowser = PhotoBrowserState(filter = PhotoMediaFilter.VIDEOS),
            )
        }
        rule.onNodeWithText(text(R.string.no_matching_photos)).assertIsDisplayed()
        update { state = baseState(photos = failure()) }
        assertFailure()
        update { state = baseState(photos = Loadable.Ready(photoPage(listOf(photo())))) }
        rule.onNodeWithContentDescription(InstrumentationRegistry.getInstrumentation().targetContext.getString(R.string.photo_thumbnail_description, PHOTO_NAME)).assertIsDisplayed()
    }

    @Test
    fun PhotosScreen大字小屏错误恢复操作可见() {
        val model = model()
        setAdaptiveContent { PhotosScreen(baseState(photos = failure()), model) }
        assertFailure()
    }

    @Test
    fun PhotoMoveDialog覆盖加载空错误和内容() {
        val model = model()
        var state by mutableStateOf(photoMoveState(Loadable.Loading))
        rule.setContent { LanStashTheme { PhotoMoveDialog(state, model) } }

        assertLoading()
        update { state = photoMoveState(Loadable.Ready(photoPage())) }
        rule.onNodeWithText(text(R.string.no_subfolders)).assertIsDisplayed()
        update { state = photoMoveState(failure()) }
        assertFailure()
        update { state = photoMoveState(Loadable.Ready(photoPage(listOf(photoFolder())))) }
        rule.onNodeWithText(FOLDER_NAME).assertIsDisplayed()
    }

    @Test
    fun PhotoMoveDialog两倍字体错误恢复操作可见() {
        val model = model()
        setTwoXContent { PhotoMoveDialog(photoMoveState(failure()), model) }
        assertFailure()
    }

    @Test
    fun NasSettingsScreen覆盖加载空总览错误和内容() {
        val model = model()
        var state by mutableStateOf(baseState(nasSettings = Loadable.Loading))
        rule.setContent { LanStashTheme { NasSettingsScreen(state, model) } }

        assertLoading()
        update { state = baseState(nasSettings = Loadable.Ready(nasSnapshot())) }
        rule.onNodeWithText(text(R.string.storage_space)).assertIsDisplayed()
        update { state = baseState(nasSettings = failure()) }
        assertFailure()
        update {
            state = baseState(
                nasSettings = Loadable.Ready(
                    nasSnapshot(system = SystemSummary(
                        serverName = NAS_SERVER_NAME,
                        model = "Synthetic model",
                        serial = null,
                        dsmVersion = "7.x",
                        uptimeSeconds = null,
                        temperatureCelsius = null,
                    )),
                ),
            )
        }
        rule.onNodeWithText(NAS_SERVER_NAME).assertIsDisplayed()
    }

    @Test
    fun NasSettingsScreen大字小屏错误恢复操作可见() {
        val model = model()
        setAdaptiveContent { NasSettingsScreen(baseState(nasSettings = failure()), model) }
        assertFailure()
    }

    @Test
    fun NasSettingsScreen日志页签覆盖源空和真实筛选空() {
        val initial = baseState(nasSettings = Loadable.Ready(nasSnapshot())).copy(
            selectedModule = io.github.qwertyuiop1995.dsmnativeclient.domain.Module.NAS_SETTINGS,
            nasPerformance = NasPerformanceWorkspaceState(selectedTab = NasSettingsTab.LOGS),
        )
        val model = ApprovedUiFixture.model(initial)
        rule.setContent {
            val state by model.workspace.collectAsState()
            LanStashTheme { NasSettingsScreen(state!!, model) }
        }
        rule.onNodeWithText(text(R.string.no_log_entries))
            .assertIsDisplayed()
        update {
            ApprovedUiFixture.setState(model, initial.copy(nasSettings = Loadable.Ready(nasSnapshot(logs = listOf(logEntry())))))
        }
        rule.onNodeWithText(LOG_EVENT).performScrollTo().assertIsDisplayed()
        rule.onNode(hasSetTextAction()).performTextInput(ABSENT_QUERY)
        rule.onNodeWithText(text(R.string.no_matching_log_entries))
            .assertIsDisplayed()
    }

    @Test
    fun NasStorageScreen覆盖空加载错误和分析内容() {
        var analysis: Loadable<StorageAnalysisSnapshot> by mutableStateOf(Loadable.Idle)
        var progress by mutableStateOf<StorageAnalysisProgress?>(null)
        rule.setContent {
            LanStashTheme { NasStorageScreenFixture(nasSnapshot(), analysis, progress) }
        }

        rule.onNodeWithText(text(R.string.smart_test_empty_title))
            .performScrollTo().assertIsDisplayed()
        update {
            analysis = Loadable.Loading
            progress = StorageAnalysisProgress("scanning", 0, 1)
        }
        rule.onNodeWithText(text(R.string.cancel_analysis)).performScrollTo().assertIsDisplayed()
        update {
            analysis = failure()
            progress = null
        }
        rule.onNodeWithText(text(R.string.retry_analysis)).performScrollTo().assertIsDisplayed()
        update { analysis = Loadable.Ready(storageAnalysis()) }
        rule.onNodeWithText(text(R.string.analysis_distribution))
            .performScrollTo().assertIsDisplayed()
    }

    @Test
    fun NasStorageScreen大字小屏错误恢复操作可见() {
        setAdaptiveContent { NasStorageScreenFixture(nasSnapshot(), failure(), null) }
        rule.onNodeWithText(text(R.string.retry_analysis)).performScrollTo().assertIsDisplayed()
    }

    @Test
    fun ContainersScreen覆盖加载空总览错误和内容() {
        val model = model()
        var state by mutableStateOf(baseState(containers = Loadable.Loading))
        rule.setContent { LanStashTheme { ContainersScreen(state, model) } }

        assertLoading()
        update { state = baseState(containers = Loadable.Ready(containerOverview())) }
        rule.onNodeWithText(containerTotal(0)).assertIsDisplayed()
        update { state = baseState(containers = failure()) }
        assertFailure()
        update {
            state = baseState(
                containers = Loadable.Ready(
                    containerOverview(containers = listOf(resource("container-1", CONTAINER_NAME))),
                ),
            )
        }
        rule.onNodeWithText(text(R.string.containers)).performClick()
        rule.onNodeWithText(CONTAINER_NAME).assertIsDisplayed()
    }

    @Test
    fun ContainersScreen大字小屏错误恢复操作可见() {
        val model = model()
        setAdaptiveContent { ContainersScreen(baseState(containers = failure()), model) }
        assertFailure()
    }

    @Test
    fun ContainersScreen事件页签覆盖日志内容和真实筛选空() {
        val model = model()
        val state = baseState(
            containers = Loadable.Ready(containerOverview(events = listOf(logEntry()))),
        )
        rule.setContent { LanStashTheme { ContainersScreen(state, model) } }

        rule.onNodeWithText(text(R.string.events)).performClick()
        rule.onNodeWithText(LOG_EVENT).performScrollTo().assertIsDisplayed()
        rule.onNode(hasSetTextAction()).performTextInput(ABSENT_QUERY)
        rule.onNodeWithText(text(R.string.no_matching_log_entries))
            .assertIsDisplayed()
    }

    @Test
    fun ContainerRegistry覆盖提示加载筛选空错误和内容() {
        val model = model()
        var state by mutableStateOf(registryState(Loadable.Idle))
        rule.setContent { LanStashTheme { ContainersScreen(state, model) } }

        rule.onNodeWithText(text(R.string.container_registry_search_hint)).assertIsDisplayed()
        update { state = registryState(Loadable.Loading) }
        rule.onNodeWithText(text(R.string.container_registry_searching)).assertIsDisplayed()
        update { state = registryState(failure()) }
        rule.onNodeWithText(text(R.string.operation_not_completed), substring = true)
            .assertIsDisplayed()
        update { state = registryState(Loadable.Ready(emptyList())) }
        rule.onNodeWithText(text(R.string.no_container_registry_results)).assertIsDisplayed()
        update { state = registryState(Loadable.Ready(listOf(registryImage()))) }
        rule.onNodeWithText(REGISTRY_IMAGE_NAME).assertIsDisplayed()
    }

    @Test
    fun ContainerRegistry两倍字体错误和关闭操作可见() {
        val model = model()
        setTwoXContent { ContainersScreen(registryState(failure()), model) }
        rule.onNodeWithText(text(R.string.operation_not_completed), substring = true)
            .assertIsDisplayed()
        rule.onNodeWithText(text(R.string.close)).assertIsDisplayed()
    }

    @Test
    fun VirtualMachinesScreen覆盖加载空错误和内容() {
        val model = model()
        var state by mutableStateOf(baseState(virtualMachines = Loadable.Loading))
        rule.setContent { LanStashTheme { VirtualMachinesScreen(state, model) } }

        assertLoading()
        update { state = baseState(virtualMachines = Loadable.Ready(virtualMachineOverview())) }
        rule.onNodeWithText(text(R.string.virtual_machine_empty_external_message))
            .assertIsDisplayed()
        update { state = baseState(virtualMachines = failure()) }
        assertFailure()
        update {
            state = baseState(
                virtualMachines = Loadable.Ready(
                    virtualMachineOverview(machines = listOf(resource("vm-1", VM_NAME))),
                ),
            )
        }
        rule.onNodeWithText(VM_NAME).assertIsDisplayed()
    }

    @Test
    fun VirtualMachinesScreen大字小屏错误恢复操作可见() {
        val model = model()
        setAdaptiveContent { VirtualMachinesScreen(baseState(virtualMachines = failure()), model) }
        assertFailure()
    }

    @Test
    fun VirtualMachinesScreen日志页签覆盖日志内容和真实筛选空() {
        val state = baseState(
            virtualMachines = Loadable.Ready(
                virtualMachineOverview(logs = listOf(logEntry())),
            ),
        ).copy(selectedModule = io.github.qwertyuiop1995.dsmnativeclient.domain.Module.VIRTUAL_MACHINES)
        val model = ApprovedUiFixture.model(state)
        rule.setContent {
            val current by model.workspace.collectAsState()
            LanStashTheme { VirtualMachinesScreen(current!!, model) }
        }

        rule.onNodeWithText(text(R.string.logs)).performClick()
        rule.onNodeWithText(LOG_EVENT).performScrollTo().assertIsDisplayed()
        rule.onNode(hasSetTextAction()).performTextInput(ABSENT_QUERY)
        rule.onNodeWithText(text(R.string.no_matching_log_entries))
            .assertIsDisplayed()
    }

    @Test
    fun VirtualMachineCreationDialog覆盖校验错误无存储和正常内容() {
        var draft by mutableStateOf(VirtualMachineCreationDraftState())
        var overview by mutableStateOf(virtualMachineOverview())
        rule.setContent {
            LanStashTheme {
                VirtualMachineCreationDialog(
                    overview = overview,
                    draft = draft,
                    submitting = false,
                    onDraftChange = { draft = it; true },
                    onConfirm = { true },
                    onDismiss = { true },
                )
            }
        }

        rule.onNodeWithText(text(R.string.virtual_machine_name_required)).assertIsDisplayed()
        update {
            draft = validCreationDraft(storageId = "", step = 2)
            overview = virtualMachineOverview()
        }
        rule.onNodeWithText(text(R.string.virtual_machine_no_storage))
            .performScrollTo().assertIsDisplayed()
        update {
            draft = validCreationDraft(storageId = "storage-1", step = 2)
            overview = virtualMachineOverview(
                storages = listOf(resource("storage-1", STORAGE_NAME)),
            )
        }
        rule.onNodeWithText(text(R.string.virtual_machine_review))
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(STORAGE_NAME).performScrollTo().assertIsDisplayed()
    }

    @Test
    fun VirtualMachineCreationDialog两倍字体校验错误和下一步可见() {
        var draft by mutableStateOf(VirtualMachineCreationDraftState())
        setTwoXContent {
            VirtualMachineCreationDialog(
                overview = virtualMachineOverview(),
                draft = draft,
                submitting = false,
                onDraftChange = { draft = it; true },
                onConfirm = { true },
                onDismiss = { true },
            )
        }
        rule.onNodeWithText(text(R.string.virtual_machine_name_required)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.virtual_machine_next_step)).assertIsDisplayed()
    }

    private fun copyMoveState(folders: Loadable<FilePage>) = baseState(
        fileCopyMove = FileCopyMoveState(
            items = listOf(textFile()),
            operation = FileCopyMoveOperation.COPY,
            sourceProfileId = PROFILE_ID,
            targetProfileId = PROFILE_ID,
            targetProfiles = listOf(profile()),
            location = FileCopyMoveLocation("/destination", canWrite = true),
        ),
        fileCopyMoveFolders = folders,
    )

    private fun photoMoveState(folders: Loadable<PhotoPage>) = baseState(
        photoMove = PhotoMoveState(
            item = photo(),
            space = PERSONAL_PHOTO_SPACE,
            location = PhotoMoveLocation("/destination", canWrite = true),
        ),
        photoMoveFolders = folders,
    )

    private fun baseState(
        conversations: Loadable<List<ChatConversation>> = Loadable.Idle,
        files: Loadable<FilePage> = Loadable.Idle,
        fileBrowser: FileBrowserState = FileBrowserState(),
        fileCopyMove: FileCopyMoveState? = null,
        fileCopyMoveFolders: Loadable<FilePage> = Loadable.Idle,
        photos: Loadable<PhotoPage> = Loadable.Idle,
        photoBrowser: PhotoBrowserState = PhotoBrowserState(),
        photoMove: PhotoMoveState? = null,
        photoMoveFolders: Loadable<PhotoPage> = Loadable.Idle,
        nasSettings: Loadable<NasSettingsSnapshot> = Loadable.Idle,
        containers: Loadable<ContainerOverview> = Loadable.Idle,
        containerRegistryVisible: Boolean = false,
        containerRegistryResults: Loadable<List<ContainerRegistryImage>> = Loadable.Idle,
        virtualMachines: Loadable<VirtualMachineOverview> = Loadable.Idle,
    ) = WorkspaceState(
        profile = profile(),
        conversations = conversations,
        files = files,
        fileBrowser = fileBrowser,
        fileCopyMove = fileCopyMove,
        fileCopyMoveFolders = fileCopyMoveFolders,
        photos = photos,
        photoBrowser = photoBrowser,
        photoMove = photoMove,
        photoMoveFolders = photoMoveFolders,
        nasSettings = nasSettings,
        containers = containers,
        containerRegistryVisible = containerRegistryVisible,
        containerRegistryResults = containerRegistryResults,
        virtualMachines = virtualMachines,
    )

    @Composable
    private fun NasStorageScreenFixture(
        snapshot: NasSettingsSnapshot,
        analysis: Loadable<StorageAnalysisSnapshot>,
        progress: StorageAnalysisProgress?,
    ) {
        NasStorageScreen(
            snapshot = snapshot,
            analysis = analysis,
            progress = progress,
            diskTestStatuses = emptyMap(),
            diskTestMutationTarget = null,
            diskTestMutationBaseline = null,
            diskTestMutationOperation = null,
            diskTestMutationConfirmationRequested = false,
            diskTestMutationInProgress = false,
            diskTestMutationResult = null,
            diskTestMutationFailure = null,
            diskTestMutationRefreshFailure = null,
            diskTestMutationRefreshInProgress = false,
            diskTestMutationRefreshCompleted = false,
            diskTestActionsEnabled = true,
            onBeginAnalysis = {},
            onCancelAnalysis = {},
            onLoadDiskTest = {},
            onRequestDiskTest = { _, _, _ -> },
            onConfirmDiskTest = { false },
            onCancelDiskTestConfirmation = {},
            onRefreshDiskTest = {},
            onContinueDiskTest = {},
            onCloseDiskTestResult = {},
        )
    }

    private fun nasSnapshot(
        system: SystemSummary? = null,
        logs: List<LogEntry> = emptyList(),
    ) = NasSettingsSnapshot(
        system = system,
        volumes = emptyList(),
        pools = emptyList(),
        disks = emptyList(),
        storageDisks = emptyList<NasStorageDisk>(),
        packages = emptyList(),
        scheduledTasks = emptyList(),
        accounts = emptyList(),
        groups = emptyList(),
        logs = logs,
        connections = emptyList(),
        connectionsAvailable = true,
        networkInterfaces = emptyList(),
        networkInterfacesAvailable = true,
        ddnsDirectory = null,
        ddnsDirectoryAvailable = true,
        fileServiceSettings = null,
        terminalSettings = null,
        proxySettings = null,
        regionSettings = null,
        securitySettings = null,
        hardwareSettings = null,
        security = emptyList(),
    )

    private fun storageAnalysis() = StorageAnalysisSnapshot(
        generatedAtEpochSeconds = 1,
        shares = emptyList(),
        categories = emptyList(),
        owners = emptyList(),
        largeFiles = emptyList(),
        recentlyModifiedFiles = emptyList(),
        leastRecentlyAccessedFiles = emptyList(),
        duplicateGroups = emptyList(),
        scannedFileCount = 0,
        scannedBytes = 0,
        duplicateCheckWasLimited = false,
        duplicateCheckUnavailable = false,
    )

    private fun containerOverview(
        containers: List<ManagedResource> = emptyList(),
        events: List<LogEntry> = emptyList(),
    ) = ContainerOverview(
        containers = containers,
        images = emptyList(),
        networks = emptyList(),
        projects = emptyList(),
        events = events,
    )

    private fun registryState(results: Loadable<List<ContainerRegistryImage>>) = baseState(
        containers = Loadable.Ready(containerOverview()),
        containerRegistryVisible = true,
        containerRegistryResults = results,
    )

    private fun registryImage() = ContainerRegistryImage(
        name = REGISTRY_IMAGE_NAME,
        registry = "registry.example.invalid",
        description = "Synthetic registry result",
        starCount = 0,
        isOfficial = false,
        isAutomated = false,
        isTrusted = false,
    )

    private fun virtualMachineOverview(
        machines: List<ManagedResource> = emptyList(),
        storages: List<ManagedResource> = emptyList(),
        logs: List<LogEntry> = emptyList(),
    ) = VirtualMachineOverview(
        machines = machines,
        hosts = emptyList(),
        storages = storages,
        networks = emptyList(),
        images = emptyList(),
        protectionPlans = emptyList(),
        protectionSchedules = emptyList(),
        retentionPolicies = emptyList(),
        logs = logs,
    )

    private fun logEntry() = LogEntry(
        id = "log-synthetic",
        level = LogLevel.INFO,
        timeEpochSeconds = 1,
        user = "Synthetic operator",
        event = LOG_EVENT,
    )

    private fun validCreationDraft(storageId: String, step: Int) =
        VirtualMachineCreationDraftState(
            step = step,
            name = VM_NAME,
            storageId = storageId,
        )

    private fun resource(id: String, name: String) = ManagedResource(
        id = id,
        name = name,
        detail = "",
        state = ResourceState.HEALTHY,
    )

    private fun containerTotal(count: Int): String {
        val resources = InstrumentationRegistry.getInstrumentation().targetContext.resources
        return resources.getQuantityString(R.plurals.container_overview_total, count, count)
    }

    private fun profile() = NasProfile(
        id = PROFILE_ID,
        name = "Synthetic",
        address = "https://nas.example.invalid",
        username = "operator",
    )

    private fun conversation() = ChatConversation(
        id = "conversation-synthetic",
        title = CHAT_TITLE,
        kind = ConversationKind.DIRECT,
        memberCount = 1,
    )

    private fun folder() = FileItem(
        path = "/destination/$FOLDER_NAME",
        name = FOLDER_NAME,
        isDirectory = true,
        canRead = true,
        canWrite = true,
    )

    private fun textFile() = FileItem(
        path = "/source/readme.txt",
        name = "readme.txt",
        isDirectory = false,
        canRead = true,
        canWrite = true,
    )

    private fun photo() = PhotoItem(
        id = "photo-synthetic",
        file = FileItem(
            path = "/source/$PHOTO_NAME",
            name = PHOTO_NAME,
            isDirectory = false,
            canRead = true,
            canWrite = true,
        ),
        kind = PhotoItemKind.IMAGE,
        takenAtEpochSeconds = null,
    )

    private fun photoFolder() = PhotoItem(
        id = "folder-synthetic",
        file = folder(),
        kind = PhotoItemKind.FOLDER,
        takenAtEpochSeconds = null,
    )

    private fun photoPage(items: List<PhotoItem> = emptyList()) = PhotoPage(
        folderPath = PERSONAL_PHOTO_SPACE.rootPath,
        items = items,
        offset = 0,
        nextOffset = items.size,
        sourceTotal = items.size,
        hasMore = false,
    )

    private fun failure() = Loadable.Failed(
        DsmFailure(null, FAILURE_MESSAGE, FAILURE_RECOVERY),
    )

    private fun model() = AppViewModel(
        ApplicationProvider.getApplicationContext<Application>(),
    )

    private fun update(block: () -> Unit) = rule.runOnIdle(block)

    private fun assertLoading(expectedCount: Int = 1) {
        rule.onAllNodes(
            hasProgressBarRangeInfo(
                androidx.compose.ui.semantics.ProgressBarRangeInfo.Indeterminate,
            ),
        ).assertCountEquals(expectedCount)
    }

    private fun assertFailure() {
        rule.onNodeWithText(text(R.string.operation_not_completed)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.try_again_later)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.retry)).assertIsDisplayed()
    }

    private fun setAdaptiveContent(content: @Composable () -> Unit) {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, fontScale = 2f),
            ) {
                LanStashTheme {
                    Box(Modifier.width(360.dp).height(720.dp)) { content() }
                }
            }
        }
    }

    private fun setTwoXContent(content: @Composable () -> Unit) {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, fontScale = 2f),
            ) {
                LanStashTheme { content() }
            }
        }
    }

    private fun text(id: Int) =
        InstrumentationRegistry.getInstrumentation().targetContext.getString(id)

    private companion object {
        const val PROFILE_ID = "profile-synthetic"
        const val CHAT_TITLE = "Synthetic conversation"
        const val FOLDER_NAME = "Synthetic folder"
        const val PHOTO_NAME = "Synthetic photo.jpg"
        const val PREVIEW_BODY = "Synthetic preview body"
        const val FAILURE_MESSAGE = "Synthetic page failure"
        const val FAILURE_RECOVERY = "Synthetic recovery guidance"
        const val NAS_SERVER_NAME = "Synthetic NAS"
        const val CONTAINER_NAME = "Synthetic container"
        const val REGISTRY_IMAGE_NAME = "synthetic/image"
        const val VM_NAME = "Synthetic VM"
        const val STORAGE_NAME = "Synthetic storage"
        const val LOG_EVENT = "Synthetic page event"
        const val ABSENT_QUERY = "not-present"
    }
}
