package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.media.ExifInterface
import android.net.Uri
import android.provider.OpenableColumns
import android.content.Intent
import android.util.LruCache
import androidx.annotation.StringRes
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.CrossNasTransferCoordinator
import io.github.qwertyuiop1995.dsmnativeclient.data.RepositoryCrossNasTransferEndpoint
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedDownload
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedPhotoBackupSource
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedServerSubmissionPhase
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedServerTransfer
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedUpload
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedVirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedVirtualMachineImageImportStage
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedVirtualMachineImageType
import io.github.qwertyuiop1995.dsmnativeclient.data.PhotoRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.data.hasIncompleteDownloadDestination
import io.github.qwertyuiop1995.dsmnativeclient.data.canRemoveFinishedUpload
import io.github.qwertyuiop1995.dsmnativeclient.data.toMutationResult
import io.github.qwertyuiop1995.dsmnativeclient.data.toFileBackgroundTaskPage
import io.github.qwertyuiop1995.dsmnativeclient.data.toFileServerMutationTarget
import io.github.qwertyuiop1995.dsmnativeclient.data.toFileServerMutationVerification
import io.github.qwertyuiop1995.dsmnativeclient.data.toPersistedFileBackgroundTaskSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.data.toPersistedMutationResult
import io.github.qwertyuiop1995.dsmnativeclient.data.toPersistedServerExpectedOutput
import io.github.qwertyuiop1995.dsmnativeclient.data.toPersistedServerTransfer
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveCompressionLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveFormat
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatDeliveryState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatReminder
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatScheduledMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerRegistryImage
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationAction
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationBaseline
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssSite
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssFeed
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchOptions
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadDiscoveryTab
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineCreation
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.domain.safeTemporaryFileSuffix
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageImportVerification
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.isEligibleForVirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskSummary
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileShareLink
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBrowserState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileSortOption
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileTypeFilter
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileViewMode
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewContent
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewSequence
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationExpectedOutput
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationTarget
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationVerification
import io.github.qwertyuiop1995.dsmnativeclient.domain.MediaDetails
import io.github.qwertyuiop1995.dsmnativeclient.domain.previewKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRemoteAccessSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.PackageInfo
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSystemUpdateInfo
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestType
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasStorageDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.OpaqueWorkspaceTarget
import io.github.qwertyuiop1995.dsmnativeclient.domain.PerformanceSample
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisProgress
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoBrowserState
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoBrowseMode
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItemKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoMediaFilter
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoSpace
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoSpaceAccess
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoTimelineProgress
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoViewerState
import io.github.qwertyuiop1995.dsmnativeclient.domain.SHARED_PHOTO_SPACE
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.RecycleLocation
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.domain.UploadMutationLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineGuestDetails
import io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspaceRoute
import io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspaceRouteStack
import io.github.qwertyuiop1995.dsmnativeclient.domain.deriveWorkspaceRouteStack
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmConnectionResolver
import io.github.qwertyuiop1995.dsmnativeclient.network.ConnectionStatus
import io.github.qwertyuiop1995.dsmnativeclient.network.ChatRealtimeClient
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import io.github.qwertyuiop1995.dsmnativeclient.storage.PersistedWorkspaceUiState
import java.util.UUID
import java.io.File
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.text.SimpleDateFormat
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val api = DsmApiClient()
    private val connectionResolver = DsmConnectionResolver(api)
    private val store = SecureProfileStore(application)
    private val transferStore = TransferStore(application)
    private val workManager = WorkManager.getInstance(application)
    private var repository: DsmRepository? = null
    private var workspacePersistenceJob: Job? = null
    private var nasSwitchJob: Job? = null
    private var isSwitchingNas = false
    private val transferJobs = mutableMapOf<String, Job>()
    private val crossNasRepositories = mutableMapOf<String, DsmRepository>()
    private val crossNasTransferCoordinator = CrossNasTransferCoordinator()
    private var fileBackgroundTaskJob: Job? = null
    private val fileUploadPreflightJobs = mutableMapOf<String, Job>()
    private var fileUploadPreflightBusyToken: FileUploadPreflightToken? = null
    private val foregroundDownloadExecutionIds = mutableMapOf<String, String>()
    private val transferWatchJobs = mutableMapOf<String, Job>()
    private var photoBackupScanWatchJob: Job? = null
    private var photoBackupScanWatchProfileId: String? = null
    private var photoBackupScanWatchGeneration = 0L
    private var photoBackupScanScheduleGeneration = 0L
    private val virtualMachineImageImportWatchJobs = mutableMapOf<String, Job>()
    private var pendingVirtualMachineLocalImageUri: Uri? = null
    private var pendingVirtualMachineLocalImageContentType: String? = null
    private val _virtualMachineLocalImageImports =
        MutableStateFlow<List<VirtualMachineLocalImageImportUiState>>(emptyList())
    val virtualMachineLocalImageImports: StateFlow<List<VirtualMachineLocalImageImportUiState>> =
        _virtualMachineLocalImageImports.asStateFlow()
    private var previewJob: Job? = null
    private var pendingModuleAfterPreviewDiscard: Module? = null
    private var activeExternalNavigationModule: Module? = null
    private var pendingExternalModuleAfterPreviewDiscard: Module? = null
    private var cancelledExternalNavigationModule: Module? = null
    private var cancelledOpaqueExternalNavigationToken: String? = null
    private var opaqueExternalNavigationJob: Job? = null
    private var opaqueExternalNavigation: OpaqueExternalNavigationRequest? = null
    private val opaqueExternalNavigationGeneration = AtomicLong(0)
    private val _opaqueExternalNavigationRevision = MutableStateFlow(0L)
    internal val opaqueExternalNavigationRevision: StateFlow<Long> =
        _opaqueExternalNavigationRevision.asStateFlow()
    private var photoTimelineJob: Job? = null
    private var chatRefreshJob: Job? = null
    private var chatRealtimeRefreshJob: Job? = null
    private var chatRealtimeClient: ChatRealtimeClient? = null
    @Volatile private var chatRealtimeConnected = false
    private var chatLocalReadMarkers: Map<String, ChatLocalReadMarker> = emptyMap()
    private var chatAttachmentPreviewJob: Job? = null
    private val chatAttachmentJobs = mutableMapOf<String, Job>()
    private val chatMutationJobs = mutableMapOf<String, Job>()
    private var storageAnalysisJob: Job? = null
    private var nasPerformanceJob: Job? = null
    private var nasPerformanceVisible = false
    private val nasPerformanceGeneration = AtomicLong(0)
    private var downloadDiscoveryLoadJob: Job? = null
    private var downloadBtCatalogJob: Job? = null
    private var downloadDiscoverySearchJob: Job? = null
    private var downloadActivityJob: Job? = null
    private var virtualMachineTaskPollingJob: Job? = null
    private var virtualMachineGuestDetailsJob: Job? = null
    private val fileBrowserRequestGeneration = AtomicLong(0)
    private val fileStationMutationGeneration = AtomicLong(0)
    private val fileServerMutationGeneration = AtomicLong(0)
    private val fileUploadPreflightGeneration = AtomicLong(0)
    private val downloadListRequestGeneration = AtomicLong(0)
    private val fileBackgroundTaskRequestGeneration = AtomicLong(0)
    private val downloadCreationMutationGeneration = AtomicLong(0)
    private val downloadControlMutationGeneration = AtomicLong(0)
    private val downloadDestinationEditMutationGeneration = AtomicLong(0)
    private val downloadSettingsMutationGeneration = AtomicLong(0)
    private val downloadRssRefreshMutationGeneration = AtomicLong(0)
    private val downloadDiscoveryGeneration = AtomicLong(0)
    private val downloadActivityGeneration = AtomicLong(0)
    private val virtualMachineMutationGeneration = AtomicLong(0)
    private val virtualMachineOverviewRequestGeneration = AtomicLong(0)
    private val virtualMachineGuestDetailsGeneration = AtomicLong(0)
    private val virtualMachineTaskPollingGeneration = AtomicLong(0)
    private val virtualMachineImageBrowserGeneration = AtomicLong(0)
    private val chatMutationGeneration = AtomicLong(0)
    private val chatMutationGenerations = ConcurrentHashMap<String, Long>()
    private val chatAttachmentPreflightGeneration = AtomicLong(0)
    private val previewRequestGeneration = AtomicLong(0)
    private val nasSettingsRequestGeneration = AtomicLong(0)
    private val nasSettingsStructuredMutationLock = Any()
    // 下载创建、任务控制、设置保存和工作区退出共用同一 claim 边界，避免跨线程旧状态覆盖。
    private val downloadMutationCoordinatorLock = Any()
    private val downloadCreationMutationLock = downloadMutationCoordinatorLock
    private val fileStationMutationLock = downloadMutationCoordinatorLock
    private val downloadControlMutationLock = downloadMutationCoordinatorLock
    private val downloadDestinationEditMutationLock = downloadMutationCoordinatorLock
    private val downloadSettingsMutationLock = downloadMutationCoordinatorLock
    private val downloadRssRefreshMutationLock = downloadMutationCoordinatorLock
    // VMM 创建、设置、生命周期写操作与工作区退出共用同步 claim 边界。
    private val virtualMachineMutationLock = downloadMutationCoordinatorLock
    private val diskTestStatusRequestGeneration = AtomicLong(0)
    private val diskTestStatusRequestGenerations = ConcurrentHashMap<String, Long>()
    private val containerRegistrySearchGeneration = AtomicLong(0)
    private val containerRegistryTagsGeneration = AtomicLong(0)
    private val thumbnailJobs = mutableMapOf<String, Job>()
    private val thumbnailReferences = mutableMapOf<String, Int>()
    private val thumbnailCache = object : LruCache<String, Bitmap>(32 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.allocationByteCount
    }
    private val packageIconJobs = mutableMapOf<String, Job>()
    private val packageIconCache = object : LruCache<String, Bitmap>(MAX_PACKAGE_ICON_MEMORY_CACHE_BYTES) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.allocationByteCount
    }
    private val _packageIconGeneration = MutableStateFlow(0)
    val packageIconGeneration: StateFlow<Int> = _packageIconGeneration.asStateFlow()

    private val initialProfiles = store.profiles()
    private val initialProfile = initialProfiles.firstOrNull { it.id == store.lastProfileId() }
        ?: initialProfiles.firstOrNull()
    private val initialPassword = initialProfile?.let { store.password(it.id) }.orEmpty()
    private val _login = MutableStateFlow(
        LoginState(
            profiles = initialProfiles,
            selectedProfileId = initialProfile?.id,
            savedPassword = initialPassword,
            rememberPassword = initialPassword.isNotEmpty(),
            autoLoginEnabled = initialPassword.isNotEmpty() &&
                initialProfile?.let { store.isAutoLoginEnabled(it.id) } == true,
        )
    )
    val login: StateFlow<LoginState> = _login.asStateFlow()

    private val _workspace = MutableStateFlow<WorkspaceState?>(null)
    val workspace: StateFlow<WorkspaceState?> = _workspace.asStateFlow()

    init {
        startWorkspacePersistence()
        if (initialProfile != null &&
            store.isAutoLoginEnabled(initialProfile.id) &&
            initialPassword.isNotEmpty()
        ) {
            restore(initialProfile, initialPassword)
        }
    }

    private fun startWorkspacePersistence() {
        workspacePersistenceJob?.cancel()
        workspacePersistenceJob = viewModelScope.launch {
            _workspace.filterNotNull()
                .map { state -> state.profile.id to state.persistedUiState() }
                .distinctUntilChanged()
                .collect { (profileId, state) -> store.saveWorkspaceUiState(profileId, state) }
        }
    }

    fun selectProfile(profile: NasProfile) {
        if (isSwitchingNas) return
        if (_workspace.value?.profile?.id != profile.id) chatLocalReadMarkers = emptyMap()
        store.setLastProfileId(profile.id)
        val storedPassword = store.password(profile.id).orEmpty()
        _login.update {
            it.copy(
                selectedProfileId = profile.id,
                savedPassword = storedPassword,
                rememberPassword = storedPassword.isNotEmpty(),
                autoLoginEnabled = storedPassword.isNotEmpty() &&
                    store.isAutoLoginEnabled(profile.id),
                error = null,
                needsOtp = false,
            )
        }
    }

    fun newProfile() {
        if (isSwitchingNas) return
        chatLocalReadMarkers = emptyMap()
        store.setLastProfileId(null)
        _login.update {
            it.copy(
                selectedProfileId = null,
                savedPassword = "",
                rememberPassword = false,
                autoLoginEnabled = false,
                error = null,
                needsOtp = false,
            )
        }
    }

    fun connect(
        profileId: String?,
        name: String,
        address: String,
        portText: String,
        username: String,
        password: String,
        otp: String,
        rememberPassword: Boolean,
        autoLoginEnabled: Boolean,
    ) {
        if (isSwitchingNas) return
        if (_login.value.isConnecting) return
        val existing = profileId?.let { id -> _login.value.profiles.firstOrNull { it.id == id } }
        val profile = NasProfile(
            id = existing?.id ?: UUID.randomUUID().toString(),
            name = name.trim().ifBlank { "NAS" },
            address = address.trim(),
            username = username.trim(),
            port = portText.toIntOrNull(),
            rememberSession = rememberPassword,
        )
        if (profile.address.isBlank() || profile.username.isBlank() || password.isBlank()) {
            _login.update {
                it.copy(
                    error = DsmFailure(
                        null,
                        "NAS address, account, and password are required",
                        "Complete the sign-in information and connect again.",
                        kind = DsmErrorKind.MISSING_LOGIN_FIELDS,
                    )
                )
            }
            return
        }
        viewModelScope.launch {
            _login.update {
                it.copy(
                    isConnecting = true,
                    connectionStatus = ConnectionStatus.PREPARING,
                    error = null,
                )
            }
            runCatching {
                val discovered = connectionResolver.discover(profile) { status ->
                    _login.update { it.copy(connectionStatus = status) }
                }
                val previousSession = store.session(profile.id)
                val session = api.login(
                    profile = discovered.profile,
                    password = password,
                    otp = otp.ifBlank { null },
                    deviceId = previousSession?.deviceId,
                )
                store.saveProfile(profile)
                store.setLastProfileId(profile.id)
                if (rememberPassword) {
                    store.savePassword(profile.id, password)
                    store.saveSession(session)
                    store.setAutoLoginEnabled(profile.id, autoLoginEnabled)
                } else {
                    store.clearPassword(profile.id)
                    store.clearSession(profile.id)
                }
                DsmRepository(discovered.profile, session, api, discovered.capabilities)
            }.onSuccess { repo ->
                chatLocalReadMarkers = emptyMap()
                fileBrowserRequestGeneration.incrementAndGet()
                downloadListRequestGeneration.incrementAndGet()
                fileBackgroundTaskRequestGeneration.incrementAndGet()
                clearPackageIconCache()
                repository = repo
                _login.value = LoginState(
                    profiles = store.profiles(),
                    selectedProfileId = profile.id,
                    savedPassword = if (rememberPassword) password else "",
                    rememberPassword = rememberPassword,
                    autoLoginEnabled = rememberPassword && autoLoginEnabled,
                )
                val availability = repo.availability()
                val restoredUi = restoredWorkspaceUi(profile.id, availability)
                val backgroundTaskSnapshot = transferStore.fileBackgroundTaskSnapshot(profile.id)
                val photoBackupSource = transferStore.photoBackupSource(profile.id)
                _workspace.value = WorkspaceState(
                    profile = profile,
                    selectedModule = restoredUi.first,
                    availability = availability,
                    fileBrowser = restoredUi.second,
                    supportsFavorites = repo.supportsFavorites(),
                    supportsUploads = repo.supportsUploads(),
                    supportsThumbnails = repo.supportsThumbnails(),
                    supportsCopyMove = repo.supportsCopyMove(),
                    supportsSharing = repo.supportsSharing(),
                    supportsCompression = repo.supportsCompression(),
                    supportsExtraction = repo.supportsExtraction(),
                    supportsRemoteLocations = repo.supportsRemoteLocations(),
                    supportsDownloadSettings = repo.supportsDownloadSettings(),
                    supportsDownloadSchedule = repo.supportsDownloadSchedule(),
                    supportsDownloadTaskDestinationEditing =
                        repo.supportsDownloadTaskDestinationEditing(),
                    supportsDownloadRss = repo.supportsDownloadRss(),
                    supportsDownloadBtSearch = repo.supportsDownloadBtSearch(),
                    downloadAdvancedRead = DownloadAdvancedReadWorkspaceState(
                        supportsActivity = repo.supportsDownloadActivity(),
                    ),
                    supportsChatReminders = repo.supportsChatReminders(),
                    supportsChatScheduledMessages = repo.supportsChatScheduledMessages(),
                    supportsChatPollCreation = repo.supportsChatPollCreation(),
                    supportsContainerRegistry = repo.supportsContainerRegistry(),
                    supportsOfficialVirtualMachineCreation = repo.supportsOfficialVirtualMachineCreation(),
                    supportsOfficialVirtualMachineSettings = repo.supportsOfficialVirtualMachineSettings(),
                    supportsOfficialVirtualMachineImageImport =
                        repo.supportsOfficialVirtualMachineImageImport(),
                    virtualMachineMutationState = VirtualMachineMutationWorkspaceState(
                        supportsOfficialTasks = repo.supportsOfficialVirtualMachineTasks(),
                    ),
                    nasPerformance = NasPerformanceWorkspaceState(
                        supportsPerformance = repo.supportsPerformance(),
                    ),
                    photoBackupSourceEnabled = photoBackupSource?.let(::shouldScanPhotoBackupSource) == true,
                    message = photoBackupSourceRestoreMessage(photoBackupSource),
                    chatPinnedConversationIds = restoredPinnedConversationIds(profile.id),
                    fileBackgroundTasks = backgroundTaskSnapshot?.toFileBackgroundTaskPage()
                        ?.let { Loadable.Ready(it) } ?: Loadable.Idle,
                    fileBackgroundTaskSnapshotObservedAtEpochSeconds =
                        backgroundTaskSnapshot?.observedAtEpochSeconds,
                )
                viewModelScope.launch { refreshFavorites(repo) }
                when {
                    photoBackupSource?.needsAttention == true ->
                        cancelPhotoBackupSourceWork(profile.id)
                    photoBackupSource?.let(::shouldScanPhotoBackupSource) == true &&
                        !schedulePhotoBackupSource(photoBackupSource) -> {
                        _workspace.update {
                            it?.copy(
                                message = getApplication<Application>().getString(
                                    R.string.photo_backup_source_state_unavailable,
                                ),
                            )
                        }
                    }
                }
                restoreDownloads(profile.id)
                load(restoredUi.first)
            }.onFailure { error ->
                val failure = error.asDsmFailure()
                _login.update {
                    it.copy(
                        isConnecting = false,
                        connectionStatus = null,
                        error = failure,
                        needsOtp = failure.code in setOf(406, 407),
                    )
                }
            }
        }
    }

    fun restore(profile: NasProfile, fallbackPassword: String? = null) {
        if (isSwitchingNas) return
        store.setLastProfileId(profile.id)
        val session = store.session(profile.id)
        if (session == null) {
            if (!fallbackPassword.isNullOrEmpty()) {
                connect(
                    profile.id,
                    profile.name,
                    profile.address,
                    profile.port?.toString().orEmpty(),
                    profile.username,
                    fallbackPassword,
                    "",
                    rememberPassword = true,
                    autoLoginEnabled = store.isAutoLoginEnabled(profile.id),
                )
            } else {
                selectProfile(profile)
                _login.update {
                    it.copy(
                        error = DsmFailure(
                            null,
                            "No saved session is available",
                            "Enter the password and connect again.",
                            true,
                            DsmErrorKind.NO_SAVED_SESSION,
                        )
                    )
                }
            }
            return
        }
        if (_login.value.isConnecting) return
        viewModelScope.launch {
            _login.update {
                it.copy(
                    isConnecting = true,
                    connectionStatus = ConnectionStatus.RESTORING_SESSION,
                    error = null,
                )
            }
            runCatching {
                val discovered = connectionResolver.discover(profile) { status ->
                    _login.update { it.copy(connectionStatus = status) }
                }
                val repo = DsmRepository(
                    discovered.profile,
                    session,
                    api,
                    discovered.capabilities,
                )
                repo.listShares()
                repo
            }.onSuccess { repo ->
                chatLocalReadMarkers = emptyMap()
                fileBrowserRequestGeneration.incrementAndGet()
                downloadListRequestGeneration.incrementAndGet()
                fileBackgroundTaskRequestGeneration.incrementAndGet()
                clearPackageIconCache()
                repository = repo
                _login.update { it.copy(isConnecting = false, connectionStatus = null) }
                val availability = repo.availability()
                val restoredUi = restoredWorkspaceUi(profile.id, availability)
                val backgroundTaskSnapshot = transferStore.fileBackgroundTaskSnapshot(profile.id)
                val photoBackupSource = transferStore.photoBackupSource(profile.id)
                _workspace.value = WorkspaceState(
                    profile = profile,
                    selectedModule = restoredUi.first,
                    availability = availability,
                    fileBrowser = restoredUi.second,
                    supportsFavorites = repo.supportsFavorites(),
                    supportsUploads = repo.supportsUploads(),
                    supportsThumbnails = repo.supportsThumbnails(),
                    supportsCopyMove = repo.supportsCopyMove(),
                    supportsSharing = repo.supportsSharing(),
                    supportsCompression = repo.supportsCompression(),
                    supportsExtraction = repo.supportsExtraction(),
                    supportsRemoteLocations = repo.supportsRemoteLocations(),
                    supportsDownloadSettings = repo.supportsDownloadSettings(),
                    supportsDownloadSchedule = repo.supportsDownloadSchedule(),
                    supportsDownloadTaskDestinationEditing =
                        repo.supportsDownloadTaskDestinationEditing(),
                    supportsDownloadRss = repo.supportsDownloadRss(),
                    supportsDownloadBtSearch = repo.supportsDownloadBtSearch(),
                    downloadAdvancedRead = DownloadAdvancedReadWorkspaceState(
                        supportsActivity = repo.supportsDownloadActivity(),
                    ),
                    supportsChatReminders = repo.supportsChatReminders(),
                    supportsChatScheduledMessages = repo.supportsChatScheduledMessages(),
                    supportsChatPollCreation = repo.supportsChatPollCreation(),
                    supportsContainerRegistry = repo.supportsContainerRegistry(),
                    supportsOfficialVirtualMachineCreation = repo.supportsOfficialVirtualMachineCreation(),
                    supportsOfficialVirtualMachineSettings = repo.supportsOfficialVirtualMachineSettings(),
                    supportsOfficialVirtualMachineImageImport =
                        repo.supportsOfficialVirtualMachineImageImport(),
                    virtualMachineMutationState = VirtualMachineMutationWorkspaceState(
                        supportsOfficialTasks = repo.supportsOfficialVirtualMachineTasks(),
                    ),
                    nasPerformance = NasPerformanceWorkspaceState(
                        supportsPerformance = repo.supportsPerformance(),
                    ),
                    photoBackupSourceEnabled = photoBackupSource?.let(::shouldScanPhotoBackupSource) == true,
                    message = photoBackupSourceRestoreMessage(photoBackupSource),
                    chatPinnedConversationIds = restoredPinnedConversationIds(profile.id),
                    fileBackgroundTasks = backgroundTaskSnapshot?.toFileBackgroundTaskPage()
                        ?.let { Loadable.Ready(it) } ?: Loadable.Idle,
                    fileBackgroundTaskSnapshotObservedAtEpochSeconds =
                        backgroundTaskSnapshot?.observedAtEpochSeconds,
                )
                viewModelScope.launch { refreshFavorites(repo) }
                when {
                    photoBackupSource?.needsAttention == true ->
                        cancelPhotoBackupSourceWork(profile.id)
                    photoBackupSource?.let(::shouldScanPhotoBackupSource) == true &&
                        !schedulePhotoBackupSource(photoBackupSource) -> {
                        _workspace.update {
                            it?.copy(
                                message = getApplication<Application>().getString(
                                    R.string.photo_backup_source_state_unavailable,
                                ),
                            )
                        }
                    }
                }
                restoreDownloads(profile.id)
                load(restoredUi.first)
            }.onFailure {
                store.clearSession(profile.id)
                val savedPassword = fallbackPassword ?: store.password(profile.id)
                _login.update { it.copy(isConnecting = false, connectionStatus = null) }
                if (!savedPassword.isNullOrEmpty() && store.isAutoLoginEnabled(profile.id)) {
                    connect(
                        profile.id,
                        profile.name,
                        profile.address,
                        profile.port?.toString().orEmpty(),
                        profile.username,
                        savedPassword,
                        "",
                        rememberPassword = true,
                        autoLoginEnabled = true,
                    )
                } else {
                    selectProfile(profile)
                    _login.update {
                        it.copy(
                            error = DsmFailure(
                                null,
                                "The saved session expired",
                                "The saved password is filled in. Connect again.",
                                true,
                                DsmErrorKind.SAVED_SESSION_EXPIRED,
                            ),
                        )
                    }
                }
            }
        }
    }

    fun removeProfile(profile: NasProfile) {
        if (isSwitchingNas) return
        val previousSelection = _login.value.selectedProfileId
        transferStore.downloads(profile.id).forEach { download ->
            if (download.state != TransferState.SUCCEEDED) {
                download.workId?.let { value ->
                    runCatching { workManager.cancelWorkById(UUID.fromString(value)) }
                }
                deleteIncompleteDownload(Uri.parse(download.destinationUri))
            }
            releasePersistedDownloadPermission(Uri.parse(download.destinationUri))
        }
        transferStore.uploads(profile.id).forEach { upload ->
            upload.workId?.let { value ->
                runCatching { workManager.cancelWorkById(UUID.fromString(value)) }
            }
            releasePersistedReadPermission(Uri.parse(upload.sourceUri))
        }
        transferStore.uploads(profile.id).mapNotNull(PersistedUpload::sourceTreeUri).distinct().forEach { treeUri ->
            releasePersistedReadPermission(Uri.parse(treeUri))
        }
        transferStore.photoBackupSource(profile.id)?.let { source ->
            cancelPhotoBackupSourceWork(profile.id)
            releasePersistedReadPermission(Uri.parse(source.treeUri))
        }
        transferStore.virtualMachineImageImports(profile.id).forEach { import ->
            import.workId?.let { value ->
                runCatching { workManager.cancelWorkById(UUID.fromString(value)) }
            }
            if (import.ownsPersistedReadGrant) {
                releaseVirtualMachineLocalImageGrant(Uri.parse(import.sourceUri))
            }
            virtualMachineImageImportWatchJobs.remove(import.id)?.cancel()
        }
        if (_workspace.value?.profile?.id == profile.id) {
            releasePendingVirtualMachineLocalImageGrant()
        }
        transferStore.removeProfile(profile.id)
        store.removeProfile(profile.id)
        val profiles = store.profiles()
        val selected = profiles.firstOrNull { it.id == previousSelection }
            ?: profiles.firstOrNull()
        if (selected == null) {
            newProfile()
            _login.update { it.copy(profiles = profiles) }
        } else {
            _login.update { it.copy(profiles = profiles) }
            selectProfile(selected)
        }
    }

    fun select(module: Module) {
        cancelOpaqueExternalNavigation(consumePending = true)
        navigateTo(WorkspaceRoute.ModuleRoot(module))
    }

    internal fun navigateExternalRequest(
        module: Module,
        navigation: () -> WorkspaceNavigationResult,
    ): WorkspaceNavigationResult {
        if (cancelledExternalNavigationModule == module) {
            cancelledExternalNavigationModule = null
            return WorkspaceNavigationResult.REJECTED
        }
        activeExternalNavigationModule = module
        return try {
            navigation()
        } finally {
            activeExternalNavigationModule = null
        }
    }

    /** 顶层模块导航只接受强类型根路由，不把模块切换误当成可返回的详情历史。 */
    internal fun navigateTo(route: WorkspaceRoute.ModuleRoot): WorkspaceNavigationResult =
        synchronized(downloadMutationCoordinatorLock) {
        val module = route.module
        val state = _workspace.value ?: return@synchronized WorkspaceNavigationResult.DEFERRED
        if (
            state.selectedModule != module &&
            fileStationMutationBlocksWorkspaceExit(state.fileStationMutationState)
        ) {
            _workspace.value = state.copy(
                message = getApplication<Application>()
                    .getString(R.string.switch_nas_blocked_active_operation),
            )
            return@synchronized WorkspaceNavigationResult.REJECTED
        }
        if (
            workspaceNavigationBlockedByChat(state, module)
        ) {
            _workspace.value = state.copy(
                message = getApplication<Application>()
                    .getString(R.string.switch_nas_blocked_active_operation),
            )
            return@synchronized WorkspaceNavigationResult.REJECTED
        }
        if (
            state.selectedModule == Module.DOWNLOADS && module != Module.DOWNLOADS &&
            (downloadCreationBlocksWorkspaceExit(state.downloadCreationState) ||
                downloadControlBlocksWorkspaceExit(state.downloadControlState) ||
                downloadDestinationEditBlocksWorkspaceExit(state.downloadDestinationEditState) ||
                downloadSettingsBlocksWorkspaceExit(state.downloadSettingsState) ||
                downloadRssRefreshBlocksWorkspaceExit(state.downloadRssRefreshState))
        ) {
            _workspace.update {
                it?.copy(
                    message = getApplication<Application>()
                        .getString(R.string.switch_nas_blocked_active_operation),
                )
            }
            return@synchronized WorkspaceNavigationResult.REJECTED
        }
        if (
            state.selectedModule == Module.VIRTUAL_MACHINES && module != Module.VIRTUAL_MACHINES &&
            virtualMachineMutationBlocksWorkspaceExit(state.virtualMachineMutationState)
        ) {
            _workspace.value = state.copy(
                message = getApplication<Application>()
                    .getString(R.string.switch_nas_blocked_active_operation),
            )
            return@synchronized WorkspaceNavigationResult.REJECTED
        }
        if (state.availability.firstOrNull { it.module == module }?.isAvailable == false) {
            val unavailable = state.availability.first { item -> item.module == module }
            _workspace.update {
                it?.copy(
                    message = unavailable.reason?.localize(getApplication<Application>())
                        ?: getApplication<Application>().getString(R.string.module_unavailable_generic)
                )
            }
            return@synchronized WorkspaceNavigationResult.REJECTED
        }
        if (state.selectedModule != module && state.previewItem != null) {
            if (fileStationMutationBlocksWorkspaceExit(state.fileStationMutationState)) {
                return@synchronized WorkspaceNavigationResult.DEFERRED
            }
            if (state.hasDirtyTextPreview()) {
                pendingModuleAfterPreviewDiscard = module
                if (activeExternalNavigationModule == module) {
                    pendingExternalModuleAfterPreviewDiscard = module
                }
                _workspace.update {
                    it?.copy(
                        previewDiscardConfirmationVisible = true,
                        previewDiscardClosesPreview = true,
                    )
                }
                return@synchronized WorkspaceNavigationResult.DEFERRED
            }
            closePreviewImmediately()
        }
        if (state.selectedModule == Module.CONTAINERS && module != Module.CONTAINERS) {
            containerRegistrySearchGeneration.incrementAndGet()
            containerRegistryTagsGeneration.incrementAndGet()
        }
        if (state.selectedModule == Module.CHAT && module != Module.CHAT) {
            invalidateChatAttachmentPreflights()
        }
        if (state.selectedModule == Module.FILES && module != Module.FILES) {
            invalidateFileUploadPreflights()
        }
        if (state.selectedModule == Module.TRANSFERS && module != Module.TRANSFERS) {
            invalidateFileBackgroundTaskRequests()
        }
        val discardSettledFileMutation = state.selectedModule != module &&
            shouldDiscardSettledFileStationMutationOnModuleChange(
                state.fileStationMutationState,
                module,
            )
        if (discardSettledFileMutation) fileStationMutationGeneration.incrementAndGet()
        _workspace.update { current ->
            current?.copy(
                selectedModule = module,
                fileStationMutationState = if (discardSettledFileMutation) {
                    FileStationMutationWorkspaceState()
                } else {
                    current.fileStationMutationState
                },
                pendingFileUploads = current.pendingFileUploads.takeIf { module == Module.FILES },
                fileBackgroundTasks = if (
                    module != Module.TRANSFERS && current.fileBackgroundTasks is Loadable.Loading
                ) {
                    Loadable.Idle
                } else {
                    current.fileBackgroundTasks
                },
                fileBackgroundTaskIsLoadingMore = current.fileBackgroundTaskIsLoadingMore &&
                    module == Module.TRANSFERS,
                fileBackgroundTasksLoadMoreFailure = current.fileBackgroundTasksLoadMoreFailure
                    .takeIf { module == Module.TRANSFERS },
                downloadDetailsTask = current.downloadDetailsTask.takeIf {
                    module == Module.DOWNLOADS && current.selectedModule == Module.DOWNLOADS
                },
                containerRegistryVisible = current.containerRegistryVisible &&
                    module == Module.CONTAINERS && current.selectedModule == Module.CONTAINERS,
                containerRegistryResults = current.containerRegistryResults.takeUnless {
                    module != Module.CONTAINERS && it is Loadable.Loading
                } ?: Loadable.Idle,
                selectedContainerRegistryImage = current.selectedContainerRegistryImage.takeIf {
                    module == Module.CONTAINERS && current.selectedModule == Module.CONTAINERS
                },
                containerRegistryTags = current.containerRegistryTags.takeIf {
                    module == Module.CONTAINERS && current.selectedModule == Module.CONTAINERS
                } ?: Loadable.Idle,
                virtualMachineMutationState = current.virtualMachineMutationState.copy(
                    selectedTab = VirtualMachineTab.MACHINES,
                    guestDetailsTargetId = null,
                    guestDetails = Loadable.Idle,
                ),
                nasPerformance = current.nasPerformance.copy(
                    selectedTab = NasSettingsTab.OVERVIEW,
                ),
                message = null,
            )
        }
        if (module != Module.CHAT) {
            chatRefreshJob?.cancel()
            chatRefreshJob = null
            chatRealtimeRefreshJob?.cancel()
            chatRealtimeClient?.stop()
            chatRealtimeClient = null
            chatRealtimeConnected = false
        }
        if (module != Module.NAS_SETTINGS ||
            state.nasPerformance.selectedTab == NasSettingsTab.PERFORMANCE
        ) {
            stopNasPerformanceSampling(resetPause = true)
        }
        val navigationResult = if (state.selectedModule == module) {
            WorkspaceNavigationResult.ALREADY_SELECTED
        } else {
            WorkspaceNavigationResult.APPLIED
        }
        if (state.virtualMachineMutationState.selectedTab == VirtualMachineTab.TASKS ||
            shouldStopVirtualMachineTaskPollingAfterNavigation(
                state.selectedModule,
                module,
                navigationResult,
            )
        ) {
            stopVirtualMachineTaskPolling()
        }
        load(module)
        navigationResult
    }

    /**
     * 解析并恢复本机不透明对象外链。
     *
     * 令牌映射只在当前资料的加密存储中读取；不匹配当前登录资料时拒绝，而不是自动切换 NAS。
     */
    internal fun navigateToOpaqueExternalRoute(token: String): WorkspaceNavigationResult {
        if (cancelledOpaqueExternalNavigationToken == token) {
            cancelledOpaqueExternalNavigationToken = null
            return WorkspaceNavigationResult.REJECTED
        }
        if (ExternalWorkspaceRoute.OpaqueObject.fromTokenOrNull(token) == null) {
            return opaqueExternalNavigationUnavailable()
        }
        val state = _workspace.value ?: return WorkspaceNavigationResult.DEFERRED
        val repo = repository ?: return WorkspaceNavigationResult.DEFERRED
        val existing = opaqueExternalNavigation
        if (existing != null && existing.token == token && existing.profileId == state.profile.id &&
            existing.repository === repo
        ) {
            return when (existing.phase) {
                OpaqueExternalNavigationPhase.RESOLVING,
                OpaqueExternalNavigationPhase.WAITING_FOR_PREVIEW_DISCARD,
                -> WorkspaceNavigationResult.DEFERRED

                OpaqueExternalNavigationPhase.RETRYABLE -> {
                    existing.phase = OpaqueExternalNavigationPhase.RESOLVING
                    launchOpaqueExternalNavigation(existing)
                    WorkspaceNavigationResult.DEFERRED
                }

                OpaqueExternalNavigationPhase.APPLIED -> WorkspaceNavigationResult.APPLIED
                OpaqueExternalNavigationPhase.REJECTED -> WorkspaceNavigationResult.REJECTED
            }
        }
        if (existing != null) clearOpaqueExternalNavigation()

        val record = store.opaqueWorkspaceRoute(token) ?: return opaqueExternalNavigationUnavailable()
        if (record.profileId != state.profile.id) return opaqueExternalNavigationUnavailable()

        val request = OpaqueExternalNavigationRequest(
            token = token,
            profileId = record.profileId,
            target = record.target,
            repository = repo,
            generation = opaqueExternalNavigationGeneration.incrementAndGet(),
            phase = OpaqueExternalNavigationPhase.RESOLVING,
        )
        opaqueExternalNavigation = request
        _workspace.update { current ->
            current?.takeIf {
                it.profile.id == request.profileId && repository === request.repository
            }?.copy(message = null) ?: current
        }
        if (deferOpaqueExternalNavigationForDirtyPreview(request)) {
            return WorkspaceNavigationResult.DEFERRED
        }
        launchOpaqueExternalNavigation(request)
        return WorkspaceNavigationResult.DEFERRED
    }

    /** Activity 消费 URI 后清除仅用于本次解析的内存上下文。 */
    internal fun completeOpaqueExternalNavigation(token: String) {
        if (opaqueExternalNavigation?.token == token) clearOpaqueExternalNavigation()
    }

    /** 新的固定外链或 Activity 意图替换当前对象外链时主动取消旧请求。 */
    internal fun cancelOpaqueExternalNavigation(consumePending: Boolean = false) {
        val token = opaqueExternalNavigation?.token
        clearOpaqueExternalNavigation()
        if (consumePending && token != null) {
            cancelledOpaqueExternalNavigationToken = token
            _opaqueExternalNavigationRevision.update { it + 1L }
        }
    }

    private fun clearOpaqueExternalNavigation() {
        val request = opaqueExternalNavigation
        val ownsPreviewDiscardConfirmation =
            request?.phase == OpaqueExternalNavigationPhase.WAITING_FOR_PREVIEW_DISCARD
        opaqueExternalNavigationGeneration.incrementAndGet()
        opaqueExternalNavigationJob?.cancel()
        opaqueExternalNavigationJob = null
        opaqueExternalNavigation = null
        if (ownsPreviewDiscardConfirmation) {
            pendingModuleAfterPreviewDiscard = null
            _workspace.update { current ->
                current?.copy(previewDiscardConfirmationVisible = false) ?: current
            }
        }
    }

    private fun cancelOpaqueExternalNavigationAfterPreviewDiscard() {
        val request = opaqueExternalNavigation
            ?.takeIf { it.phase == OpaqueExternalNavigationPhase.WAITING_FOR_PREVIEW_DISCARD }
            ?: return
        opaqueExternalNavigationGeneration.incrementAndGet()
        opaqueExternalNavigationJob?.cancel()
        opaqueExternalNavigationJob = null
        request.phase = OpaqueExternalNavigationPhase.REJECTED
        pendingModuleAfterPreviewDiscard = null
        _opaqueExternalNavigationRevision.update { it + 1L }
    }

    private fun opaqueExternalNavigationUnavailable(): WorkspaceNavigationResult {
        _workspace.update { current ->
            current?.copy(
                message = getApplication<Application>().getString(R.string.page_link_unavailable),
            ) ?: current
        }
        return WorkspaceNavigationResult.REJECTED
    }

    private fun opaqueExternalNavigationMatches(request: OpaqueExternalNavigationRequest): Boolean {
        val state = _workspace.value ?: return false
        return opaqueExternalNavigation === request &&
            opaqueExternalNavigationGeneration.get() == request.generation &&
            request.phase == OpaqueExternalNavigationPhase.RESOLVING &&
            repository === request.repository &&
            state.profile.id == request.profileId
    }

    private fun deferOpaqueExternalNavigationForDirtyPreview(
        request: OpaqueExternalNavigationRequest,
    ): Boolean {
        val state = _workspace.value ?: return false
        if (!opaqueExternalNavigationMatches(request) || !state.hasDirtyTextPreview()) return false
        val preservesCurrentPreview = request.target is OpaqueWorkspaceTarget.FilePreview &&
            state.selectedModule == Module.FILES &&
            state.previewOwner == PreviewOwner.FILES &&
            state.previewItem?.path == request.target.canonicalPath
        if (preservesCurrentPreview) return false
        request.phase = OpaqueExternalNavigationPhase.WAITING_FOR_PREVIEW_DISCARD
        pendingModuleAfterPreviewDiscard = null
        _workspace.update { current ->
            current?.takeIf { it.profile.id == request.profileId }?.copy(
                previewDiscardConfirmationVisible = true,
                previewDiscardClosesPreview = true,
            ) ?: current
        }
        return true
    }

    private fun launchOpaqueExternalNavigation(request: OpaqueExternalNavigationRequest) {
        opaqueExternalNavigationJob?.cancel()
        val job = viewModelScope.launch {
            when (resolveOpaqueExternalNavigation(request)) {
                OpaqueExternalNavigationResolution.APPLIED -> {
                    if (opaqueExternalNavigationMatches(request)) {
                        request.phase = OpaqueExternalNavigationPhase.APPLIED
                        _opaqueExternalNavigationRevision.update { it + 1L }
                    }
                }

                OpaqueExternalNavigationResolution.REJECTED -> {
                    if (opaqueExternalNavigationMatches(request)) {
                        request.phase = OpaqueExternalNavigationPhase.REJECTED
                        _opaqueExternalNavigationRevision.update { it + 1L }
                        _workspace.update { current ->
                            current?.takeIf {
                                it.profile.id == request.profileId && repository === request.repository
                            }?.copy(
                                message = getApplication<Application>().getString(
                                    R.string.page_link_unavailable,
                                ),
                            ) ?: current
                        }
                    }
                }

                OpaqueExternalNavigationResolution.DEFERRED,
                -> if (opaqueExternalNavigationMatches(request)) {
                    request.phase = OpaqueExternalNavigationPhase.RETRYABLE
                }

                OpaqueExternalNavigationResolution.STALE -> Unit
            }
        }
        opaqueExternalNavigationJob = job
        job.invokeOnCompletion {
            if (opaqueExternalNavigationJob === job) opaqueExternalNavigationJob = null
        }
    }

    private suspend fun resolveOpaqueExternalNavigation(
        request: OpaqueExternalNavigationRequest,
    ): OpaqueExternalNavigationResolution {
        return try {
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        when (val target = request.target) {
            is OpaqueWorkspaceTarget.FileDirectory -> {
                val browser = FileBrowserState.fromCanonicalDirectoryPath(target.canonicalPath)
                    ?: return OpaqueExternalNavigationResolution.REJECTED
                val item = request.repository.fileInfo(target.canonicalPath)
                if (!opaqueExternalNavigationMatches(request)) {
                    OpaqueExternalNavigationResolution.STALE
                } else if (item == null || !item.isDirectory || !item.canRead) {
                    OpaqueExternalNavigationResolution.REJECTED
                } else {
                    applyOpaqueFileDirectoryNavigation(request, browser, item)
                }
            }

            is OpaqueWorkspaceTarget.FilePreview -> {
                val browser = FileBrowserState.fromCanonicalFilePath(target.canonicalPath)
                    ?: return OpaqueExternalNavigationResolution.REJECTED
                val item = request.repository.fileInfo(target.canonicalPath)
                if (!opaqueExternalNavigationMatches(request)) {
                    OpaqueExternalNavigationResolution.STALE
                } else if (item == null || item.isDirectory || !item.canRead ||
                    item.previewKind() == FilePreviewKind.UNSUPPORTED
                ) {
                    OpaqueExternalNavigationResolution.REJECTED
                } else {
                    applyOpaqueFilePreviewNavigation(request, browser, item)
                }
            }

            is OpaqueWorkspaceTarget.PhotoFolder -> {
                val state = _workspace.value ?: return OpaqueExternalNavigationResolution.STALE
                val browser = state.photoBrowser.restoreCanonicalFolder(
                    target.spaceId,
                    target.canonicalPath,
                ) ?: return OpaqueExternalNavigationResolution.REJECTED
                val space = state.photoBrowser.spaces.firstOrNull { it.id == target.spaceId }
                    ?: return OpaqueExternalNavigationResolution.REJECTED
                val item = PhotoRepository(request.repository).item(space, target.canonicalPath)
                if (!opaqueExternalNavigationMatches(request)) {
                    OpaqueExternalNavigationResolution.STALE
                } else if (item == null || item.kind != PhotoItemKind.FOLDER || !item.file.canRead) {
                    OpaqueExternalNavigationResolution.REJECTED
                } else {
                    applyOpaquePhotoFolderNavigation(request, browser)
                }
            }

            is OpaqueWorkspaceTarget.PhotoViewer -> {
                val state = _workspace.value ?: return OpaqueExternalNavigationResolution.STALE
                val browser = state.photoBrowser.restoreCanonicalMediaParent(
                    target.spaceId,
                    target.canonicalPath,
                ) ?: return OpaqueExternalNavigationResolution.REJECTED
                val space = state.photoBrowser.spaces.firstOrNull { it.id == target.spaceId }
                    ?: return OpaqueExternalNavigationResolution.REJECTED
                val item = PhotoRepository(request.repository).item(space, target.canonicalPath)
                if (!opaqueExternalNavigationMatches(request)) {
                    OpaqueExternalNavigationResolution.STALE
                } else if (item == null || item.kind !in setOf(
                        PhotoItemKind.IMAGE,
                        PhotoItemKind.VIDEO,
                    ) || !item.file.canRead || item.file.previewKind() == FilePreviewKind.UNSUPPORTED
                ) {
                    OpaqueExternalNavigationResolution.REJECTED
                } else {
                    applyOpaquePhotoViewerNavigation(request, browser, item)
                }
            }

            is OpaqueWorkspaceTarget.ChatConversation -> {
                val conversationId = target.conversationId.takeIf {
                    it.isNotBlank() && it == it.trim()
                } ?: return OpaqueExternalNavigationResolution.REJECTED
                val conversation = request.repository.chatConversations()
                    .firstOrNull { it.id == conversationId }
                if (!opaqueExternalNavigationMatches(request)) {
                    OpaqueExternalNavigationResolution.STALE
                } else if (conversation == null) {
                    OpaqueExternalNavigationResolution.REJECTED
                } else {
                    applyOpaqueChatConversationNavigation(request, conversation)
                }
            }

            is OpaqueWorkspaceTarget.DownloadTask -> {
                val taskId = target.taskId.takeIf { it.isNotBlank() && it == it.trim() }
                    ?: return OpaqueExternalNavigationResolution.REJECTED
                val task = request.repository.downloadTask(taskId)
                if (!opaqueExternalNavigationMatches(request)) {
                    OpaqueExternalNavigationResolution.STALE
                } else if (task == null) {
                    OpaqueExternalNavigationResolution.REJECTED
                } else {
                    applyOpaqueDownloadTaskNavigation(request, task)
                }
            }

            is OpaqueWorkspaceTarget.VirtualMachineGuest -> {
                val guestId = target.guestId.takeIf { it.isNotBlank() && it == it.trim() }
                    ?: return OpaqueExternalNavigationResolution.REJECTED
                val mutation = _workspace.value?.virtualMachineMutationState
                    ?: return OpaqueExternalNavigationResolution.STALE
                if (virtualMachineGuestExternalNavigationBlocked(mutation)) {
                    return OpaqueExternalNavigationResolution.REJECTED
                }
                if (!request.repository.supportsOfficialVirtualMachineGuestDetails()) {
                    return OpaqueExternalNavigationResolution.REJECTED
                }
                val details = try {
                    request.repository.virtualMachineGuestDetails(guestId)
                } catch (error: DsmFailure) {
                    if (error.kind in setOf(
                            DsmErrorKind.FEATURE_UNSUPPORTED,
                            DsmErrorKind.INVALID_RESPONSE,
                        )
                    ) return OpaqueExternalNavigationResolution.REJECTED
                    throw error
                }
                if (!opaqueExternalNavigationMatches(request)) {
                    OpaqueExternalNavigationResolution.STALE
                } else if (_workspace.value?.virtualMachineMutationState?.let(
                        ::virtualMachineGuestExternalNavigationBlocked,
                    ) != false
                ) {
                    OpaqueExternalNavigationResolution.REJECTED
                } else if (details.resource.id != guestId || details.hardware.machineId != guestId) {
                    OpaqueExternalNavigationResolution.REJECTED
                } else {
                    applyOpaqueVirtualMachineGuestNavigation(request, guestId, details)
                }
            }
        }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            OpaqueExternalNavigationResolution.DEFERRED
        }
    }

    private fun prepareOpaqueObjectNavigation(
        request: OpaqueExternalNavigationRequest,
        module: Module,
    ): OpaqueExternalNavigationResolution {
        if (!opaqueExternalNavigationMatches(request)) {
            return OpaqueExternalNavigationResolution.STALE
        }
        if (deferOpaqueExternalNavigationForDirtyPreview(request)) {
            return OpaqueExternalNavigationResolution.DEFERRED
        }
        return when (navigateTo(WorkspaceRoute.ModuleRoot(module))) {
            WorkspaceNavigationResult.APPLIED,
            WorkspaceNavigationResult.ALREADY_SELECTED,
            -> if (opaqueExternalNavigationMatches(request)) {
                OpaqueExternalNavigationResolution.APPLIED
            } else {
                OpaqueExternalNavigationResolution.STALE
            }

            WorkspaceNavigationResult.DEFERRED -> OpaqueExternalNavigationResolution.DEFERRED
            WorkspaceNavigationResult.REJECTED -> OpaqueExternalNavigationResolution.REJECTED
        }
    }

    private fun applyOpaqueFileDirectoryNavigation(
        request: OpaqueExternalNavigationRequest,
        browser: FileBrowserState,
        item: FileItem,
    ): OpaqueExternalNavigationResolution {
        val prepared = prepareOpaqueObjectNavigation(request, Module.FILES)
        if (prepared != OpaqueExternalNavigationResolution.APPLIED) return prepared
        if (_workspace.value?.previewItem != null) closePreviewImmediately()
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        _workspace.update { current ->
            current?.takeIf {
                it.profile.id == request.profileId && repository === request.repository
            }?.copy(
                fileBrowser = browser,
                fileDirectoryBaselines = current.fileDirectoryBaselines + (item.path to item),
                files = Loadable.Loading,
                fileIsLoadingMore = false,
            ) ?: current
        }
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        load(Module.FILES)
        return OpaqueExternalNavigationResolution.APPLIED
    }

    private fun applyOpaqueFilePreviewNavigation(
        request: OpaqueExternalNavigationRequest,
        browser: FileBrowserState,
        item: FileItem,
    ): OpaqueExternalNavigationResolution {
        val current = _workspace.value
        if (current?.selectedModule == Module.FILES && current.previewOwner == PreviewOwner.FILES &&
            current.previewItem?.path == item.path && current.hasDirtyTextPreview()
        ) {
            // 当前就是同一对象，保留草稿；仅刷新目录读取以触发已消费外链的状态推进。
            load(Module.FILES)
            return OpaqueExternalNavigationResolution.APPLIED
        }
        val prepared = prepareOpaqueObjectNavigation(request, Module.FILES)
        if (prepared != OpaqueExternalNavigationResolution.APPLIED) return prepared
        if (_workspace.value?.previewItem != null) closePreviewImmediately()
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        _workspace.update { state ->
            state?.takeIf {
                it.profile.id == request.profileId && repository === request.repository
            }?.copy(
                fileBrowser = browser,
                files = Loadable.Loading,
                fileIsLoadingMore = false,
                photoViewer = null,
                filePreviewSequence = null,
                previewOwner = PreviewOwner.FILES,
            ) ?: state
        }
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        startPreview(item, PreviewOwner.FILES)
        load(Module.FILES)
        return OpaqueExternalNavigationResolution.APPLIED
    }

    private fun applyOpaquePhotoFolderNavigation(
        request: OpaqueExternalNavigationRequest,
        browser: PhotoBrowserState,
    ): OpaqueExternalNavigationResolution {
        val prepared = prepareOpaqueObjectNavigation(request, Module.PHOTOS)
        if (prepared != OpaqueExternalNavigationResolution.APPLIED) return prepared
        if (_workspace.value?.previewItem != null) closePreviewImmediately()
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        photoTimelineJob?.cancel()
        _workspace.update { current ->
            current?.takeIf {
                it.profile.id == request.profileId && repository === request.repository
            }?.copy(
                photoBrowser = browser,
                photos = Loadable.Loading,
                photoTimeline = Loadable.Idle,
                photoViewer = null,
            ) ?: current
        }
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        load(Module.PHOTOS)
        return OpaqueExternalNavigationResolution.APPLIED
    }

    private fun applyOpaquePhotoViewerNavigation(
        request: OpaqueExternalNavigationRequest,
        browser: PhotoBrowserState,
        item: PhotoItem,
    ): OpaqueExternalNavigationResolution {
        val prepared = prepareOpaqueObjectNavigation(request, Module.PHOTOS)
        if (prepared != OpaqueExternalNavigationResolution.APPLIED) return prepared
        if (_workspace.value?.previewItem != null) closePreviewImmediately()
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        photoTimelineJob?.cancel()
        _workspace.update { current ->
            current?.takeIf {
                it.profile.id == request.profileId && repository === request.repository
            }?.copy(
                photoBrowser = browser,
                photos = Loadable.Loading,
                photoTimeline = Loadable.Idle,
                photoViewer = PhotoViewerState(listOf(item.file), 0),
                filePreviewSequence = null,
                previewOwner = PreviewOwner.PHOTOS,
            ) ?: current
        }
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        startPreview(item.file, PreviewOwner.PHOTOS)
        load(Module.PHOTOS)
        return OpaqueExternalNavigationResolution.APPLIED
    }

    private fun applyOpaqueChatConversationNavigation(
        request: OpaqueExternalNavigationRequest,
        conversation: ChatConversation,
    ): OpaqueExternalNavigationResolution {
        val prepared = prepareOpaqueObjectNavigation(request, Module.CHAT)
        if (prepared != OpaqueExternalNavigationResolution.APPLIED) return prepared
        if (!opaqueExternalNavigationMatches(request)) return OpaqueExternalNavigationResolution.STALE
        openConversation(conversation, consumePendingOpaque = false)
        return if (opaqueExternalNavigationMatches(request)) {
            OpaqueExternalNavigationResolution.APPLIED
        } else {
            OpaqueExternalNavigationResolution.STALE
        }
    }

    private fun applyOpaqueDownloadTaskNavigation(
        request: OpaqueExternalNavigationRequest,
        task: DownloadTask,
    ): OpaqueExternalNavigationResolution {
        val prepared = prepareOpaqueObjectNavigation(request, Module.DOWNLOADS)
        if (prepared != OpaqueExternalNavigationResolution.APPLIED) return prepared
        _workspace.update { current ->
            current?.takeIf {
                it.profile.id == request.profileId && repository === request.repository &&
                    it.selectedModule == Module.DOWNLOADS
            }?.copy(downloadDetailsTask = task) ?: current
        }
        return if (opaqueExternalNavigationMatches(request)) {
            OpaqueExternalNavigationResolution.APPLIED
        } else {
            OpaqueExternalNavigationResolution.STALE
        }
    }

    private fun applyOpaqueVirtualMachineGuestNavigation(
        request: OpaqueExternalNavigationRequest,
        guestId: String,
        details: VirtualMachineGuestDetails,
    ): OpaqueExternalNavigationResolution {
        val prepared = prepareOpaqueObjectNavigation(request, Module.VIRTUAL_MACHINES)
        if (prepared != OpaqueExternalNavigationResolution.APPLIED) return prepared
        _workspace.update { current ->
            current?.takeIf {
                it.profile.id == request.profileId && repository === request.repository &&
                    it.selectedModule == Module.VIRTUAL_MACHINES
            }?.copy(
                virtualMachineMutationState = current.virtualMachineMutationState.copy(
                    selectedTab = VirtualMachineTab.MACHINES,
                    guestDetailsTargetId = guestId,
                    guestDetails = Loadable.Ready(details),
                ),
            ) ?: current
        }
        return if (opaqueExternalNavigationMatches(request)) {
            OpaqueExternalNavigationResolution.APPLIED
        } else {
            OpaqueExternalNavigationResolution.STALE
        }
    }

    /** 外部固定任务页仅在 VMM 模块和公开 Task.Info v1 都可用时进入。 */
    internal fun navigateToVirtualMachineTasks(): WorkspaceNavigationResult {
        val state = _workspace.value ?: return WorkspaceNavigationResult.DEFERRED
        if (state.availability.firstOrNull { it.module == Module.VIRTUAL_MACHINES }?.isAvailable == false ||
            !state.virtualMachineMutationState.supportsOfficialTasks
        ) {
            _workspace.value = state.copy(
                message = getApplication<Application>().getString(R.string.module_unavailable_generic),
            )
            return WorkspaceNavigationResult.REJECTED
        }
        if (state.selectedModule == Module.VIRTUAL_MACHINES &&
            state.virtualMachineMutationState.selectedTab == VirtualMachineTab.TASKS
        ) return WorkspaceNavigationResult.ALREADY_SELECTED
        val moduleResult = navigateTo(WorkspaceRoute.ModuleRoot(Module.VIRTUAL_MACHINES))
        if (moduleResult == WorkspaceNavigationResult.DEFERRED ||
            moduleResult == WorkspaceNavigationResult.REJECTED
        ) return moduleResult
        if (_workspace.value?.virtualMachineMutationState?.selectedTab == VirtualMachineTab.TASKS) {
            return WorkspaceNavigationResult.ALREADY_SELECTED
        }
        selectVirtualMachineTab(VirtualMachineTab.TASKS)
        return if (_workspace.value?.virtualMachineMutationState?.selectedTab == VirtualMachineTab.TASKS) {
            WorkspaceNavigationResult.APPLIED
        } else {
            WorkspaceNavigationResult.REJECTED
        }
    }

    /** 外部固定性能页仅在 System.Utilization v1 已发现时进入。 */
    internal fun navigateToNasSettingsPerformance(): WorkspaceNavigationResult {
        val state = _workspace.value ?: return WorkspaceNavigationResult.DEFERRED
        if (state.availability.firstOrNull { it.module == Module.NAS_SETTINGS }?.isAvailable == false ||
            !state.nasPerformance.supportsPerformance
        ) {
            _workspace.value = state.copy(
                message = getApplication<Application>().getString(R.string.module_unavailable_generic),
            )
            return WorkspaceNavigationResult.REJECTED
        }
        if (state.selectedModule == Module.NAS_SETTINGS &&
            state.nasPerformance.selectedTab == NasSettingsTab.PERFORMANCE
        ) return WorkspaceNavigationResult.ALREADY_SELECTED
        val moduleResult = navigateTo(WorkspaceRoute.ModuleRoot(Module.NAS_SETTINGS))
        if (moduleResult == WorkspaceNavigationResult.DEFERRED ||
            moduleResult == WorkspaceNavigationResult.REJECTED
        ) return moduleResult
        if (_workspace.value?.nasPerformance?.selectedTab == NasSettingsTab.PERFORMANCE) {
            return WorkspaceNavigationResult.ALREADY_SELECTED
        }
        selectNasSettingsTab(NasSettingsTab.PERFORMANCE)
        return if (_workspace.value?.nasPerformance?.selectedTab == NasSettingsTab.PERFORMANCE) {
            WorkspaceNavigationResult.APPLIED
        } else {
            WorkspaceNavigationResult.REJECTED
        }
    }

    internal fun selectVirtualMachineTab(tab: VirtualMachineTab) {
        val state = _workspace.value ?: return
        if (state.selectedModule != Module.VIRTUAL_MACHINES) return
        if (state.virtualMachineMutationState.guestDetailsTargetId != null) {
            closeVirtualMachineGuestDetails()
        }
        if (state.virtualMachineMutationState.selectedTab == tab) {
            if (tab != VirtualMachineTab.TASKS) stopVirtualMachineTaskPolling()
            return
        }
        _workspace.update { current ->
            current?.takeIf { it.selectedModule == Module.VIRTUAL_MACHINES }
                ?.copy(
                    virtualMachineMutationState = current.virtualMachineMutationState.copy(
                        selectedTab = tab,
                    ),
                ) ?: current
        }
        if (tab != VirtualMachineTab.TASKS) {
            stopVirtualMachineTaskPolling()
            return
        }
        val overview = (_workspace.value?.virtualMachines as? Loadable.Ready)?.value
        val repo = repository
        val current = _workspace.value
        if (repo != null && current != null && shouldPollVirtualMachineTasks(
                current.selectedModule,
                current.virtualMachineMutationState.selectedTab,
                overview,
            )
        ) {
            startVirtualMachineTaskPolling(repo, current.profile.id)
        }
    }

    internal fun openVirtualMachineGuestDetails(guestId: String): Boolean {
        val id = guestId.trim().takeIf { it.isNotEmpty() } ?: return false
        val state = _workspace.value ?: return false
        val repo = repository ?: return false
        if (state.selectedModule != Module.VIRTUAL_MACHINES ||
            !repo.supportsOfficialVirtualMachineGuestDetails()
        ) return false
        cancelOpaqueExternalNavigation(consumePending = true)
        loadVirtualMachineGuestDetails(repo, state.profile.id, id)
        return true
    }

    internal fun retryVirtualMachineGuestDetails() {
        val state = _workspace.value ?: return
        val id = state.virtualMachineMutationState.guestDetailsTargetId ?: return
        val repo = repository ?: return
        loadVirtualMachineGuestDetails(repo, state.profile.id, id)
    }

    internal fun closeVirtualMachineGuestDetails() {
        virtualMachineGuestDetailsGeneration.incrementAndGet()
        virtualMachineGuestDetailsJob?.cancel()
        virtualMachineGuestDetailsJob = null
        _workspace.update { current ->
            current?.copy(
                virtualMachineMutationState = current.virtualMachineMutationState.copy(
                    guestDetailsTargetId = null,
                    guestDetails = Loadable.Idle,
                ),
            )
        }
    }

    private fun loadVirtualMachineGuestDetails(
        repo: DsmRepository,
        profileId: String,
        guestId: String,
    ) {
        val generation = virtualMachineGuestDetailsGeneration.incrementAndGet()
        virtualMachineGuestDetailsJob?.cancel()
        _workspace.update { current ->
            current?.takeIf {
                repository === repo && it.profile.id == profileId &&
                    it.selectedModule == Module.VIRTUAL_MACHINES
            }?.copy(
                virtualMachineMutationState = current.virtualMachineMutationState.copy(
                    selectedTab = VirtualMachineTab.MACHINES,
                    guestDetailsTargetId = guestId,
                    guestDetails = Loadable.Loading,
                ),
            ) ?: current
        }
        val job = viewModelScope.launch {
            val value = runCatching { repo.virtualMachineGuestDetails(guestId) }
                .fold(
                    onSuccess = { Loadable.Ready(it) },
                    onFailure = { Loadable.Failed(it.asDsmFailure()) },
                )
            _workspace.update { current ->
                current?.takeIf {
                    repository === repo && it.profile.id == profileId &&
                        virtualMachineGuestDetailsGeneration.get() == generation &&
                        it.virtualMachineMutationState.guestDetailsTargetId == guestId
                }?.copy(
                    virtualMachineMutationState = current.virtualMachineMutationState.copy(
                        guestDetails = value,
                    ),
                ) ?: current
            }
        }
        virtualMachineGuestDetailsJob = job
        job.invokeOnCompletion {
            if (virtualMachineGuestDetailsJob === job) virtualMachineGuestDetailsJob = null
        }
    }

    internal fun selectNasSettingsTab(tab: NasSettingsTab) {
        val state = _workspace.value ?: return
        if (state.selectedModule != Module.NAS_SETTINGS) return
        if (state.nasPerformance.selectedTab == tab) {
            if (tab != NasSettingsTab.PERFORMANCE) stopNasPerformanceSampling(resetPause = true)
            return
        }
        _workspace.update { current ->
            current?.takeIf { it.selectedModule == Module.NAS_SETTINGS }
                ?.copy(nasPerformance = current.nasPerformance.copy(selectedTab = tab)) ?: current
        }
        if (tab == NasSettingsTab.PERFORMANCE) {
            setNasPerformanceVisible(true)
        } else {
            stopNasPerformanceSampling(resetPause = true)
        }
    }

    internal fun closeVirtualMachineTasks() {
        selectVirtualMachineTab(VirtualMachineTab.MACHINES)
    }

    internal fun closeNasSettingsPerformance() {
        selectNasSettingsTab(NasSettingsTab.OVERVIEW)
    }

    /** 依据当前领域状态派生的强类型栈返回一级，不复制路径或会话标识。 */
    internal fun navigateUp(): Boolean {
        cancelOpaqueExternalNavigation(consumePending = true)
        return when (_workspace.value?.workspaceRouteStack()?.entries?.lastOrNull()) {
            WorkspaceRoute.FilePreview, WorkspaceRoute.PhotoViewer -> {
                requestClosePreview()
                true
            }
            WorkspaceRoute.FileSelection -> {
                clearFileSelection()
                true
            }
            is WorkspaceRoute.FileDirectory -> {
                goBackDirectory()
                true
            }
            is WorkspaceRoute.PhotoFolder -> {
                goBackPhotoFolder()
                true
            }
            WorkspaceRoute.ChatConversation -> {
                closeConversation()
                true
            }
            WorkspaceRoute.DownloadTaskDetails -> {
                closeDownloadTaskDetails()
                true
            }
            WorkspaceRoute.ContainerRegistry -> {
                closeContainerRegistry()
                true
            }
            WorkspaceRoute.VirtualMachineTasks -> {
                closeVirtualMachineTasks()
                true
            }
            WorkspaceRoute.VirtualMachineGuestDetails -> {
                closeVirtualMachineGuestDetails()
                true
            }
            WorkspaceRoute.NasSettingsPerformance -> {
                closeNasSettingsPerformance()
                true
            }
            is WorkspaceRoute.ModuleRoot, null -> false
        }
    }

    fun load(module: Module? = null) {
        val targetModule = module ?: _workspace.value?.selectedModule ?: return
        val repo = repository ?: return
        if (targetModule == Module.PHOTOS) {
            if (_workspace.value?.photoBrowser?.mode == PhotoBrowseMode.TIMELINE) {
                startPhotoTimelineLoad(repo)
            } else {
                viewModelScope.launch { loadPhotoPage(repo, reset = true) }
            }
            return
        }
        viewModelScope.launch {
            when (targetModule) {
                Module.FILES -> {
                    val state = _workspace.value ?: return@launch
                    if (!fileStationMutationBlocksOrdinaryLoad(state.fileStationMutationState)) {
                        loadFileBrowser(repo)
                    }
                }
                Module.PHOTOS -> Unit
                Module.DOWNLOADS -> {
                    var refreshStructuredMutation = false
                    val token = synchronized(downloadControlMutationLock) {
                        val current = _workspace.value ?: return@synchronized null
                        if (
                            !canLoadDownloadsNormally(current.downloadControlState) ||
                            current.downloadCreationState.target != null ||
                            current.downloadDestinationEditState.target != null
                        ) {
                            refreshStructuredMutation =
                                current.downloadControlState.mutationResult != null ||
                                current.downloadControlState.mutationFailure != null ||
                                current.downloadCreationState.mutationResult != null ||
                                current.downloadCreationState.mutationFailure != null ||
                                current.downloadDestinationEditState.mutationResult != null ||
                                current.downloadDestinationEditState.mutationFailure != null
                            return@synchronized null
                        }
                        DownloadListRequestToken(
                            generation = downloadListRequestGeneration.incrementAndGet(),
                            profileId = current.profile.id,
                        ).also {
                            _workspace.value = current.copy(downloads = Loadable.Loading)
                        }
                    }
                    if (token == null) {
                        if (refreshStructuredMutation) {
                            if (_workspace.value?.downloadCreationState?.target != null) {
                                refreshDownloadCreationMutation()
                            } else if (_workspace.value?.downloadDestinationEditState?.target != null) {
                                refreshDownloadDestinationEditMutation()
                            } else {
                                refreshDownloadControlMutation()
                            }
                        }
                        return@launch
                    }
                    loadDownloadActivity()
                    capture(
                        block = { repo.listDownloads() },
                        update = { value ->
                            _workspace.update { current ->
                                current?.takeIf {
                                    repository === repo && it.matchesDownloadListRequest(
                                        token,
                                        downloadListRequestGeneration.get(),
                                    )
                                }?.withDownloads(value) ?: current
                            }
                        },
                    )
                }
                Module.CONTAINERS -> {
                    _workspace.update { it?.copy(containers = Loadable.Loading) }
                    capture(
                        block = { repo.containerOverview() },
                        update = { value -> _workspace.update { it?.copy(containers = value) } },
                    )
                }
                Module.VIRTUAL_MACHINES -> {
                    var refreshStructuredMutation = false
                    val token = synchronized(virtualMachineMutationLock) {
                        val current = _workspace.value ?: return@synchronized null
                        if (repository !== repo || current.selectedModule != Module.VIRTUAL_MACHINES) {
                            return@synchronized null
                        }
                        val mutation = current.virtualMachineMutationState
                        if (virtualMachineOrdinaryLoadBlocked(mutation)) {
                            refreshStructuredMutation = mutation.target != null &&
                                !mutation.mutationInProgress && !mutation.mutationRefreshInProgress &&
                                (mutation.mutationResult != null || mutation.mutationFailure != null)
                            return@synchronized null
                        }
                        VirtualMachineOverviewRequestToken(
                            profileId = current.profile.id,
                            generation = virtualMachineOverviewRequestGeneration.incrementAndGet(),
                        ).also {
                            _workspace.value = current.copy(virtualMachines = Loadable.Loading)
                        }
                    }
                    if (token == null) {
                        if (refreshStructuredMutation) refreshVirtualMachineMutation()
                        return@launch
                    }
                    capture(
                        block = { repo.virtualMachineOverview() },
                        update = { value ->
                            var acceptedOverview: VirtualMachineOverview? = null
                            _workspace.update { current ->
                                current?.takeIf {
                                    virtualMachineOverviewCallbackMatches(
                                        repositoryMatches = repository === repo,
                                        selectedModule = it.selectedModule,
                                        currentProfileId = it.profile.id,
                                        token = token,
                                        globalGeneration = virtualMachineOverviewRequestGeneration.get(),
                                    )
                                }?.copy(
                                    virtualMachines = value,
                                    virtualMachineMutationState = current.virtualMachineMutationState.copy(
                                        taskPolling = VirtualMachineTaskPollingState(),
                                    ),
                                )?.also { accepted ->
                                    acceptedOverview = (accepted.virtualMachines as? Loadable.Ready)?.value
                                } ?: current
                            }
                            val overview = acceptedOverview
                            val latest = _workspace.value
                            if (latest != null && shouldPollVirtualMachineTasks(
                                    latest.selectedModule,
                                    latest.virtualMachineMutationState.selectedTab,
                                    overview,
                                )
                            ) {
                                startVirtualMachineTaskPolling(repo, token.profileId)
                            } else {
                                stopVirtualMachineTaskPolling()
                            }
                        },
                    )
                }
                Module.CHAT -> {
                    startChatRealtime(repo)
                    val conversation = _workspace.value?.selectedConversation
                    if (conversation != null) {
                        loadChatMessages(repo, conversation, reset = true)
                    } else {
                        chatRefreshJob?.cancel()
                        _workspace.update { it?.copy(conversations = Loadable.Loading) }
                        capture(
                            block = { repo.chatConversations() },
                            update = { value ->
                                if (value is Loadable.Ready) {
                                    updateChatConversationState(repo, value.value)
                                } else {
                                    _workspace.update { state -> state?.copy(conversations = value) }
                                }
                            },
                        )
                        startChatConversationPolling(repo)
                    }
                }
                Module.NAS_SETTINGS -> {
                    var previousSnapshot: NasSettingsSnapshot? = null
                    var generation = 0L
                    val profileId = synchronized(nasSettingsStructuredMutationLock) {
                        val current = _workspace.value ?: return@launch
                        if (current.isPerformingAction) return@launch
                        previousSnapshot = (current.nasSettings as? Loadable.Ready)?.value
                        generation = nasSettingsRequestGeneration.incrementAndGet()
                        _workspace.value = current.copy(
                            nasSettings = Loadable.Loading,
                            diskTestStatuses = diskTestStatusesWithoutPendingLoads(current.diskTestStatuses),
                        )
                        current.profile.id
                    }
                    val value = try {
                        Loadable.Ready(repo.nasSettings())
                    } catch (error: Throwable) {
                        Loadable.Failed(error.asDsmFailure())
                    }
                    _workspace.update { current ->
                        current?.takeIf {
                            repository === repo && it.profile.id == profileId &&
                                nasSettingsRequestGeneration.get() == generation
                        }?.copy(
                            nasSettings = value,
                            diskTestStatuses = if (value is Loadable.Ready) {
                                reconciledDiskTestStatusesAfterSettingsRefresh(
                                    previousSnapshot,
                                    value.value,
                                    current.diskTestStatuses,
                                )
                            } else current.diskTestStatuses,
                            fileServiceMutationRefreshCompleted =
                                value is Loadable.Ready && value.value.fileServiceSettings != null &&
                                    current.fileServiceMutationResult != null,
                            terminalMutationRefreshCompleted =
                                value is Loadable.Ready && value.value.terminalSettings != null &&
                                    current.terminalMutationResult != null,
                            proxyMutationRefreshCompleted =
                                value is Loadable.Ready && value.value.proxySettings != null &&
                                    current.proxyMutationResult != null,
                            regionMutationRefreshCompleted =
                                value is Loadable.Ready && value.value.regionSettings != null &&
                                    current.regionMutationResult != null,
                            remoteAccessState = current.remoteAccessState.copy(
                                mutationRefreshCompleted =
                                    value is Loadable.Ready && value.value.remoteAccessSettingsAvailable &&
                                        (current.remoteAccessMutationResult != null ||
                                            current.remoteAccessMutationFailure != null) &&
                                        remoteAccessMutationRefreshIsComplete(
                                            current.remoteAccessSettingsBaseline,
                                            current.remoteAccessSettingsDraft,
                                            value.value.remoteAccessSettings,
                                        ),
                                mutationRefreshFailure = if (
                                    value is Loadable.Ready && value.value.remoteAccessSettingsAvailable &&
                                    value.value.remoteAccessSettings != null
                                ) null else current.remoteAccessMutationRefreshFailure,
                            ),
                        ) ?: current
                    }
                }
                Module.TRANSFERS -> {
                    if (_workspace.value?.let {
                            it.fileBackgroundTasks is Loadable.Idle ||
                                it.fileBackgroundTaskSnapshotObservedAtEpochSeconds != null
                        } == true
                    ) {
                        refreshFileBackgroundTasks()
                    }
                }
                Module.SETTINGS -> refreshRegenerableCacheUsage()
            }
        }
    }

    fun retryVirtualMachineTaskPolling(): Boolean {
        val repo = repository ?: return false
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        if (!shouldPollVirtualMachineTasks(
                current.selectedModule,
                current.virtualMachineMutationState.selectedTab,
                overview,
            )
        ) return false
        startVirtualMachineTaskPolling(repo, current.profile.id, immediate = true)
        return true
    }

    private fun startVirtualMachineTaskPolling(
        repo: DsmRepository,
        profileId: String,
        immediate: Boolean = false,
    ) {
        virtualMachineTaskPollingJob?.cancel()
        val generation = virtualMachineTaskPollingGeneration.incrementAndGet()
        virtualMachineTaskPollingJob = viewModelScope.launch {
            try {
                if (!immediate) delay(VMM_TASK_POLL_INTERVAL_MILLIS)
                while (currentCoroutineContext().isActive) {
                    val before = _workspace.value ?: return@launch
                    val beforeOverview = (before.virtualMachines as? Loadable.Ready)?.value
                        ?: return@launch
                    if (repository !== repo || before.profile.id != profileId ||
                        !shouldPollVirtualMachineTasks(
                            before.selectedModule,
                            before.virtualMachineMutationState.selectedTab,
                            beforeOverview,
                        ) ||
                        generation != virtualMachineTaskPollingGeneration.get()
                    ) return@launch
                    _workspace.update { state ->
                        state?.takeIf {
                                repository === repo && it.profile.id == profileId &&
                                it.selectedModule == Module.VIRTUAL_MACHINES &&
                                it.virtualMachineMutationState.selectedTab == VirtualMachineTab.TASKS &&
                                generation == virtualMachineTaskPollingGeneration.get()
                        }?.copy(
                            virtualMachineMutationState = state.virtualMachineMutationState.copy(
                                taskPolling = VirtualMachineTaskPollingState(refreshing = true),
                            ),
                        ) ?: state
                    }
                    val tasks = try {
                        repo.virtualMachineTasks()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (error: Throwable) {
                        _workspace.update { state ->
                            state?.takeIf {
                                repository === repo && it.profile.id == profileId &&
                                    it.selectedModule == Module.VIRTUAL_MACHINES &&
                                    it.virtualMachineMutationState.selectedTab == VirtualMachineTab.TASKS &&
                                    generation == virtualMachineTaskPollingGeneration.get()
                            }?.withVirtualMachineTaskPollingFailure(error.asDsmFailure()) ?: state
                        }
                        return@launch
                    }
                    var hasUnfinishedTasks = false
                    _workspace.update { state ->
                        val overview = (state?.virtualMachines as? Loadable.Ready)?.value
                        state?.takeIf {
                            overview != null && repository === repo && it.profile.id == profileId &&
                                it.selectedModule == Module.VIRTUAL_MACHINES &&
                                it.virtualMachineMutationState.selectedTab == VirtualMachineTab.TASKS &&
                                generation == virtualMachineTaskPollingGeneration.get()
                        }?.withVirtualMachineTaskPollingResult(tasks)?.also {
                            hasUnfinishedTasks = tasks.any { task -> !task.isFinished }
                        } ?: state
                    }
                    if (!hasUnfinishedTasks) return@launch
                    delay(VMM_TASK_POLL_INTERVAL_MILLIS)
                }
            } finally {
                if (generation == virtualMachineTaskPollingGeneration.get()) {
                    virtualMachineTaskPollingJob = null
                }
            }
        }
    }

    private fun stopVirtualMachineTaskPolling() {
        virtualMachineTaskPollingGeneration.incrementAndGet()
        virtualMachineTaskPollingJob?.cancel()
        virtualMachineTaskPollingJob = null
        _workspace.update { state ->
            state?.copy(
                virtualMachineMutationState = state.virtualMachineMutationState.copy(
                    taskPolling = VirtualMachineTaskPollingState(),
                ),
            )
        }
    }

    fun refreshFileBackgroundTasks() {
        val repo = repository ?: return
        val token = synchronized(downloadMutationCoordinatorLock) {
            val current = _workspace.value ?: return@synchronized null
            if (repository !== repo || current.selectedModule != Module.TRANSFERS) {
                return@synchronized null
            }
            fileBackgroundTaskJob?.cancel()
            FileBackgroundTaskRequestToken(
                profileId = current.profile.id,
                generation = fileBackgroundTaskRequestGeneration.incrementAndGet(),
                offset = 0,
                kind = FileBackgroundTaskRequestKind.REFRESH,
            ).also {
                _workspace.value = current.copy(
                    fileBackgroundTasks = if (
                        current.fileBackgroundTaskSnapshotObservedAtEpochSeconds != null &&
                        current.fileBackgroundTasks is Loadable.Ready
                    ) current.fileBackgroundTasks else Loadable.Loading,
                    fileBackgroundTaskRefreshInProgress = true,
                    fileBackgroundTaskRefreshFailure = null,
                    fileBackgroundTaskIsLoadingMore = false,
                    fileBackgroundTasksLoadMoreFailure = null,
                )
            }
        } ?: return
        launchFileBackgroundTaskRequest(repo, token)
    }

    fun loadMoreFileBackgroundTasks() {
        val repo = repository ?: return
        val token = synchronized(downloadMutationCoordinatorLock) {
            val current = _workspace.value ?: return@synchronized null
            val page = (current.fileBackgroundTasks as? Loadable.Ready)?.value
                ?: return@synchronized null
            if (repository !== repo || current.selectedModule != Module.TRANSFERS ||
                current.fileBackgroundTaskIsLoadingMore || !page.hasMore
            ) {
                return@synchronized null
            }
            FileBackgroundTaskRequestToken(
                profileId = current.profile.id,
                generation = fileBackgroundTaskRequestGeneration.incrementAndGet(),
                offset = page.nextOffset,
                kind = FileBackgroundTaskRequestKind.LOAD_MORE,
            ).also {
                _workspace.value = current.copy(
                    fileBackgroundTaskIsLoadingMore = true,
                    fileBackgroundTasksLoadMoreFailure = null,
                )
            }
        } ?: return
        launchFileBackgroundTaskRequest(repo, token)
    }

    private fun launchFileBackgroundTaskRequest(
        repo: DsmRepository,
        token: FileBackgroundTaskRequestToken,
    ) {
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            val outcome = try {
                Result.success(repo.listFileBackgroundTasks(offset = token.offset, limit = 100))
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                Result.failure(error)
            }
            synchronized(downloadMutationCoordinatorLock) {
                val current = _workspace.value ?: return@synchronized
                if (!fileBackgroundTaskCallbackMatches(
                        repositoryMatches = repository === repo,
                        selectedModule = current.selectedModule,
                        currentProfileId = current.profile.id,
                        token = token,
                        currentGeneration = fileBackgroundTaskRequestGeneration.get(),
                    )
                ) {
                    return@synchronized
                }
                val page = outcome.getOrNull()
                val failure = outcome.exceptionOrNull()?.asDsmFailure()
                _workspace.value = when (token.kind) {
                    FileBackgroundTaskRequestKind.REFRESH -> {
                        val snapshotFailure = page?.let {
                            runCatching {
                                transferStore.replaceFileBackgroundTaskSnapshot(
                                    it.toPersistedFileBackgroundTaskSnapshot(
                                        profileId = token.profileId,
                                        observedAtEpochSeconds = System.currentTimeMillis() / 1_000,
                                    ),
                                )
                            }.exceptionOrNull()?.asDsmFailure()
                        }
                        current.copy(
                            fileBackgroundTasks = page?.let { Loadable.Ready(it) }
                                ?: if (
                                    current.fileBackgroundTaskSnapshotObservedAtEpochSeconds != null &&
                                    current.fileBackgroundTasks is Loadable.Ready
                                ) current.fileBackgroundTasks else Loadable.Failed(checkNotNull(failure)),
                            fileBackgroundTaskSnapshotObservedAtEpochSeconds =
                                if (page != null) null else current.fileBackgroundTaskSnapshotObservedAtEpochSeconds,
                            fileBackgroundTaskRefreshInProgress = false,
                            fileBackgroundTaskRefreshFailure = failure ?: snapshotFailure,
                            fileBackgroundTaskIsLoadingMore = false,
                            fileBackgroundTasksLoadMoreFailure = null,
                        )
                    }
                    FileBackgroundTaskRequestKind.LOAD_MORE -> {
                        val existing = (current.fileBackgroundTasks as? Loadable.Ready)?.value
                        val merged = if (existing != null && page != null) {
                            appendFileBackgroundTaskPage(existing, page, token.offset)
                        } else {
                            null
                        }
                        val snapshotFailure = merged?.let {
                            runCatching {
                                transferStore.replaceFileBackgroundTaskSnapshot(
                                    it.toPersistedFileBackgroundTaskSnapshot(
                                        profileId = token.profileId,
                                        observedAtEpochSeconds = System.currentTimeMillis() / 1_000,
                                    ),
                                )
                            }.exceptionOrNull()?.asDsmFailure()
                        }
                        current.copy(
                            fileBackgroundTasks = merged?.let { Loadable.Ready(it) }
                                ?: current.fileBackgroundTasks,
                            fileBackgroundTaskSnapshotObservedAtEpochSeconds = null,
                            fileBackgroundTaskIsLoadingMore = false,
                            fileBackgroundTasksLoadMoreFailure = when {
                                failure != null -> failure
                                snapshotFailure != null -> snapshotFailure
                                merged == null -> DsmFailure(
                                    null,
                                    "The NAS returned an unrecognized task page",
                                    "Refresh the NAS tasks and try again.",
                                    kind = DsmErrorKind.INVALID_RESPONSE,
                                )
                                else -> null
                            },
                        )
                    }
                }
            }
        }
        synchronized(downloadMutationCoordinatorLock) {
            if (fileBackgroundTaskRequestGeneration.get() != token.generation || repository !== repo) {
                job.cancel()
                return@synchronized
            }
            fileBackgroundTaskJob = job
        }
        job.invokeOnCompletion {
            synchronized(downloadMutationCoordinatorLock) {
                if (fileBackgroundTaskJob === job) fileBackgroundTaskJob = null
            }
        }
        job.start()
    }

    private fun invalidateFileBackgroundTaskRequests() = synchronized(downloadMutationCoordinatorLock) {
        fileBackgroundTaskRequestGeneration.incrementAndGet()
        fileBackgroundTaskJob?.cancel()
        fileBackgroundTaskJob = null
    }

    fun openConversation(conversation: ChatConversation) {
        openConversation(conversation, consumePendingOpaque = true)
    }

    private fun openConversation(
        conversation: ChatConversation,
        consumePendingOpaque: Boolean,
    ) {
        if (consumePendingOpaque) cancelOpaqueExternalNavigation(consumePending = true)
        val repo = repository ?: return
        if (_workspace.value?.selectedConversation?.id != conversation.id) {
            invalidateChatAttachmentPreflights()
        }
        chatRefreshJob?.cancel()
        val canonicalConversation = (_workspace.value?.conversations as? Loadable.Ready)
            ?.value
            ?.firstOrNull { it.id == conversation.id }
            ?: conversation
        val marker = canonicalConversation.toChatLocalReadMarker()
        chatLocalReadMarkers = if (marker == null) {
            chatLocalReadMarkers - canonicalConversation.id
        } else {
            chatLocalReadMarkers + (canonicalConversation.id to marker)
        }
        _workspace.update { state ->
            state ?: return@update state
            val conversations = (state.conversations as? Loadable.Ready)?.value
            state.copy(
                selectedConversation = canonicalConversation.copy(unreadCount = 0),
                chatMessages = Loadable.Loading,
                chatIsLoadingMore = false,
                conversations = conversations?.map { item ->
                    if (item.id == conversation.id) item.copy(unreadCount = 0) else item
                }?.let { value -> Loadable.Ready(value) } ?: state.conversations,
            )
        }
        viewModelScope.launch { loadChatMessages(repo, canonicalConversation, reset = true) }
        if (!chatRealtimeConnected) startChatMessagePolling(repo, canonicalConversation)
    }

    fun toggleChatConversationPin(conversationId: String) {
        if (conversationId.isBlank()) return
        _workspace.update { state ->
            state ?: return@update state
            val pinned = if (conversationId in state.chatPinnedConversationIds) {
                state.chatPinnedConversationIds.filterNot { it == conversationId }
            } else {
                (listOf(conversationId) + state.chatPinnedConversationIds)
                    .distinct()
                    .take(MAX_PINNED_CHAT_CONVERSATIONS)
            }
            val conversations = (state.conversations as? Loadable.Ready)?.value
            state.copy(
                chatPinnedConversationIds = pinned,
                conversations = conversations?.let {
                    Loadable.Ready(applyChatConversationPreferences(it, pinned))
                } ?: state.conversations,
                selectedConversation = state.selectedConversation?.let {
                    if (it.id == conversationId) it.copy(isPinnedLocally = conversationId in pinned) else it
                },
            )
        }
    }

    private fun startChatMessagePolling(repo: DsmRepository, conversation: ChatConversation) {
        chatRefreshJob?.cancel()
        chatRefreshJob = viewModelScope.launch {
            while (true) {
                delay(CHAT_REFRESH_INTERVAL_MILLIS)
                val current = _workspace.value
                if (current?.selectedModule != Module.CHAT ||
                    current.selectedConversation?.id != conversation.id
                ) {
                    break
                }
                refreshLatestChatMessages(repo, conversation)
            }
        }
    }

    fun closeConversation() {
        val repo = repository
        if (_workspace.value?.selectedConversation != null) invalidateChatAttachmentPreflights()
        chatRefreshJob?.cancel()
        chatRefreshJob = null
        _workspace.update {
            it?.copy(
                selectedConversation = null,
                chatMessages = Loadable.Idle,
                chatIsLoadingMore = false,
            )
        }
        if (repo != null) {
            viewModelScope.launch {
                runCatching { repo.chatConversations() }.getOrNull()?.let { conversations ->
                    updateChatConversationState(repo, conversations)
                }
                if (!chatRealtimeConnected) startChatConversationPolling(repo)
            }
        }
    }

    private fun WorkspaceState.hasActiveChatMutation(
        vararg operations: ChatMutationOperation,
    ): Boolean = chatMutationState.entries.values.any { entry ->
        entry.target.operation in operations &&
            (entry.confirmationRequested || entry.mutationInProgress ||
                entry.mutationRefreshInProgress)
    }

    private fun claimChatMutation(
        target: ChatMutationTarget,
        confirmationRequested: Boolean = false,
    ): ChatMutationClaim? = synchronized(downloadMutationCoordinatorLock) {
        val repo = repository ?: return@synchronized null
        val current = _workspace.value ?: return@synchronized null
        if (current.profile.id != target.profileId || current.selectedModule != Module.CHAT ||
            current.chatMutationState.entries.containsKey(target.requestId)
        ) return@synchronized null
        if (!target.operation.isOutgoingMessage && current.chatMutationState.entries.values.any {
                !it.target.operation.isOutgoingMessage &&
                    (it.confirmationRequested || it.mutationInProgress ||
                        it.mutationRefreshInProgress || chatMutationRequiresRefresh(it) &&
                        !it.mutationRefreshCompleted)
            }
        ) return@synchronized null
        val generation = chatMutationGeneration.incrementAndGet()
        chatMutationGenerations[target.requestId] = generation
        val entry = ChatMutationEntry(
            target = target,
            confirmationRequested = confirmationRequested,
            mutationInProgress = !confirmationRequested,
            generation = generation,
        )
        _workspace.value = current.copy(
            chatMutationState = current.chatMutationState.copy(
                entries = current.chatMutationState.entries + (target.requestId to entry),
            ),
            message = null,
        )
        ChatMutationClaim(repo, current.profile.id, target, generation)
    }

    private fun claimConfirmedChatMutation(requestId: String): ChatMutationClaim? =
        synchronized(downloadMutationCoordinatorLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            val entry = current.chatMutationState.entries[requestId] ?: return@synchronized null
            val target = entry.target
            if (!entry.confirmationRequested || entry.mutationInProgress ||
                current.profile.id != target.profileId || current.selectedModule != Module.CHAT ||
                chatMutationGenerations[requestId] != entry.generation
            ) return@synchronized null
            _workspace.value = current.copy(
                chatMutationState = current.chatMutationState.copy(
                    entries = current.chatMutationState.entries + (
                        requestId to entry.copy(
                            confirmationRequested = false,
                            mutationInProgress = true,
                        )
                    ),
                ),
                message = null,
            )
            ChatMutationClaim(repo, current.profile.id, target, entry.generation)
        }

    private fun reclaimChatMutation(
        target: ChatMutationTarget,
        expectedRepository: DsmRepository,
    ): ChatMutationClaim? {
        synchronized(downloadMutationCoordinatorLock) {
            val current = _workspace.value ?: return null
            val entry = current.chatMutationState.entries[target.requestId] ?: return null
            if (entry.mutationInProgress || entry.mutationRefreshInProgress ||
                current.profile.id != target.profileId || repository !== expectedRepository
            ) return null
            chatMutationGenerations.remove(target.requestId)
            _workspace.value = current.copy(
                chatMutationState = current.chatMutationState.copy(
                    entries = current.chatMutationState.entries - target.requestId,
                ),
            )
        }
        return claimChatMutation(target)
    }

    private fun launchChatMutation(
        claim: ChatMutationClaim,
        block: suspend (DsmRepository) -> ChatMutationCompletion,
    ) {
        val job = viewModelScope.launch {
            try {
                val completion = block(claim.repository)
                if (finishChatMutation(claim, completion)) completion.afterApply?.invoke()
            } catch (error: CancellationException) {
                finishChatMutation(
                    claim,
                    ChatMutationCompletion(cancelledChatMutationResult(claim.target)),
                )
                throw error
            } catch (error: Throwable) {
                failChatMutation(claim, error.asDsmFailure())
            }
        }
        chatMutationJobs[claim.target.requestId] = job
        job.invokeOnCompletion {
            chatMutationJobs.removeIfSame(claim.target.requestId, job)
        }
    }

    private fun finishChatMutation(
        claim: ChatMutationClaim,
        completion: ChatMutationCompletion,
    ): Boolean = synchronized(downloadMutationCoordinatorLock) {
        val current = _workspace.value ?: return@synchronized false
        val entry = current.chatMutationState.entries[claim.target.requestId]
        if (!chatMutationCallbackMatches(
                repositoryMatches = repository === claim.repository,
                profileMatches = current.profile.id == claim.profileId,
                stateEntry = entry,
                callbackTarget = claim.target,
                callbackGeneration = claim.generation,
                registeredGeneration = chatMutationGenerations[claim.target.requestId],
            )
        ) return@synchronized false
        val applied = completion.apply(current)
        val updatedEntry = checkNotNull(
            applied.chatMutationState.entries[claim.target.requestId] ?: entry,
        ).copy(
            confirmationRequested = false,
            mutationInProgress = false,
            mutationResult = completion.result,
            mutationFailure = null,
            mutationRefreshFailure = null,
            mutationRefreshInProgress = false,
            mutationRefreshCompleted = !completion.result.requiresRefresh &&
                completion.result.counts.unknown == 0 &&
                completion.result.status !in setOf(
                    MutationResultStatus.PARTIAL_SUCCESS,
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                ) && completion.verification != null &&
                completion.verification != ChatMutationVerification.UNAVAILABLE,
            mutationVerification = completion.verification,
        )
        _workspace.value = applied.copy(
            chatMutationState = applied.chatMutationState.copy(
                entries = applied.chatMutationState.entries +
                    (claim.target.requestId to updatedEntry),
            ),
        )
        true
    }

    private fun failChatMutation(claim: ChatMutationClaim, failure: DsmFailure): Boolean =
        synchronized(downloadMutationCoordinatorLock) {
            val current = _workspace.value ?: return@synchronized false
            val entry = current.chatMutationState.entries[claim.target.requestId]
            if (!chatMutationCallbackMatches(
                    repositoryMatches = repository === claim.repository,
                    profileMatches = current.profile.id == claim.profileId,
                    stateEntry = entry,
                    callbackTarget = claim.target,
                    callbackGeneration = claim.generation,
                    registeredGeneration = chatMutationGenerations[claim.target.requestId],
                )
            ) return@synchronized false
            val failedState = if (claim.target.operation.isOutgoingMessage) {
                current.chatOutgoingMessages.values.flatten()
                    .firstOrNull { it.clientRequestId == claim.target.requestId }
                    ?.let { current.withFailedOutgoingChatMessage(it) } ?: current
            } else current
            _workspace.value = failedState.copy(
                chatMutationState = failedState.chatMutationState.copy(
                    entries = failedState.chatMutationState.entries + (
                        claim.target.requestId to checkNotNull(entry).copy(
                            confirmationRequested = false,
                            mutationInProgress = false,
                            mutationFailure = failure,
                        )
                    ),
                ),
            )
            true
        }

    fun openNewChatConversation() {
        val repo = repository ?: return
        _workspace.update {
            it?.copy(
                chatNewConversationVisible = true,
                chatUsers = Loadable.Loading,
                chatSelectedUserIds = emptySet(),
                chatGroupTitle = "",
            )
        }
        viewModelScope.launch {
            capture(
                block = { repo.chatUsers().filterNot { it.isCurrent || it.isDisabled } },
                update = { value ->
                    _workspace.update { state ->
                        if (state?.chatNewConversationVisible == true) state.copy(chatUsers = value) else state
                    }
                },
            )
        }
    }

    fun closeNewChatConversation() {
        if (_workspace.value?.hasActiveChatMutation(
                ChatMutationOperation.DIRECT_CONVERSATION_CREATE,
                ChatMutationOperation.PRIVATE_GROUP_CREATE,
            ) == true
        ) return
        _workspace.update {
            it?.copy(
                chatNewConversationVisible = false,
                chatSelectedUserIds = emptySet(),
                chatGroupTitle = "",
            )
        }
    }

    fun toggleChatConversationUser(userId: String) {
        if (_workspace.value?.hasActiveChatMutation(
                ChatMutationOperation.DIRECT_CONVERSATION_CREATE,
                ChatMutationOperation.PRIVATE_GROUP_CREATE,
            ) == true
        ) return
        _workspace.update { state ->
            state ?: return@update state
            val selected = state.chatSelectedUserIds.toMutableSet().apply {
                if (!add(userId)) remove(userId)
            }
            state.copy(
                chatSelectedUserIds = selected,
                chatGroupTitle = if (selected.size < 2) "" else state.chatGroupTitle,
            )
        }
    }

    fun updateChatGroupTitle(value: String) {
        if (value.length > MAX_CHAT_GROUP_TITLE_CHARACTERS) return
        _workspace.update { it?.copy(chatGroupTitle = value) }
    }

    fun submitChatConversation() {
        val state = _workspace.value ?: return
        val selected = state.chatSelectedUserIds.sorted()
        if (selected.isEmpty() || state.hasActiveChatMutation(
                ChatMutationOperation.DIRECT_CONVERSATION_CREATE,
                ChatMutationOperation.PRIVATE_GROUP_CREATE,
            )
        ) return
        if (selected.size > 1 && state.chatGroupTitle.isBlank()) return
        val requestId = UUID.randomUUID().toString()
        val operation = if (selected.size == 1) {
            ChatMutationOperation.DIRECT_CONVERSATION_CREATE
        } else {
            ChatMutationOperation.PRIVATE_GROUP_CREATE
        }
        val target = chatMutationTarget(
            profileId = state.profile.id,
            operation = operation,
            requestId = requestId,
            resourceIds = selected,
            requestParts = if (selected.size == 1) selected else listOf(state.chatGroupTitle) + selected,
        )
        val claim = claimChatMutation(target) ?: return
        launchChatMutation(claim) { repo ->
            val outcome = if (selected.size == 1) {
                repo.openDirectChatConversationResult(selected.single(), requestId)
            } else {
                repo.createPrivateChatGroupResult(state.chatGroupTitle, selected, requestId)
            }
            val verification = chatMutationVerification(
                target,
                conversations = outcome.conversations,
            )
            ChatMutationCompletion(
                result = outcome.result,
                verification = verification,
                apply = { current ->
                    val conversations = outcome.conversations?.let {
                        Loadable.Ready(
                            applyChatConversationPreferences(it, current.chatPinnedConversationIds),
                        )
                    } ?: current.conversations
                    if (outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS &&
                        outcome.conversation != null
                    ) current.copy(
                        conversations = conversations,
                        chatNewConversationVisible = false,
                        chatSelectedUserIds = emptySet(),
                        chatGroupTitle = "",
                    ) else current.copy(conversations = conversations)
                },
                afterApply = outcome.conversation?.takeIf {
                    outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS
                }?.let { conversation -> { openConversation(conversation) } },
            )
        }
    }

    fun showChatMembers() {
        val repo = repository ?: return
        val conversation = _workspace.value?.selectedConversation ?: return
        _workspace.update { it?.copy(chatMembersVisible = true, chatMembers = Loadable.Loading) }
        viewModelScope.launch {
            capture(
                block = { repo.chatConversationMembers(conversation.id) },
                update = { value ->
                    _workspace.update { state ->
                        if (state?.chatMembersVisible == true &&
                            state.selectedConversation?.id == conversation.id
                        ) state.copy(chatMembers = value) else state
                    }
                },
            )
        }
    }

    fun showChatReminders() {
        val repo = repository ?: return
        val conversation = _workspace.value?.selectedConversation ?: return
        _workspace.update {
            it?.copy(
                chatRemindersVisible = true,
                chatReminders = Loadable.Loading,
            )
        }
        viewModelScope.launch {
            capture(
                block = { repo.chatReminders(conversation.id) },
                update = { value ->
                    _workspace.update { state ->
                        if (state?.chatRemindersVisible == true) {
                            state.copy(chatReminders = value)
                        } else state
                    }
                },
            )
        }
    }

    fun closeChatReminders() {
        if (_workspace.value?.hasActiveChatMutation(
                ChatMutationOperation.REMINDER_SET,
                ChatMutationOperation.REMINDER_DELETE,
            ) == true
        ) return
        _workspace.update { it?.copy(chatRemindersVisible = false) }
    }

    fun setChatReminder(messageId: String, remindAtEpochMillis: Long) {
        val state = _workspace.value ?: return
        val conversation = state.selectedConversation ?: return
        val requestId = UUID.randomUUID().toString()
        val target = chatMutationTarget(
            state.profile.id,
            ChatMutationOperation.REMINDER_SET,
            requestId,
            conversation.id,
            resourceIds = listOf(messageId),
            expectedEpochMillis = remindAtEpochMillis,
            requestParts = listOf(messageId, remindAtEpochMillis.toString()),
        )
        val claim = claimChatMutation(target) ?: return
        launchChatMutation(claim) { repo ->
            val outcome = repo.setChatReminderResult(
                conversation.id,
                messageId,
                remindAtEpochMillis,
                requestId,
            )
            ChatMutationCompletion(
                outcome.result,
                chatMutationVerification(target, reminders = outcome.reminders),
                apply = { current ->
                    current.copy(
                        chatReminders = outcome.reminders?.let { Loadable.Ready(it) }
                            ?: current.chatReminders,
                    )
                },
            )
        }
    }

    fun requestDeleteChatReminder(messageId: String): Boolean {
        val state = _workspace.value ?: return false
        val conversation = state.selectedConversation ?: return false
        val baseline = (state.chatReminders as? Loadable.Ready)?.value
            ?.firstOrNull { it.messageId == messageId } ?: return false
        val requestId = UUID.randomUUID().toString()
        val target = chatMutationTarget(
            state.profile.id,
            ChatMutationOperation.REMINDER_DELETE,
            requestId,
            conversation.id,
            resourceIds = listOf(messageId),
            requestParts = listOf(messageId, baseline.id),
            reminderBaseline = baseline,
        )
        return claimChatMutation(target, confirmationRequested = true) != null
    }

    fun deleteChatReminder(messageId: String) {
        requestDeleteChatReminder(messageId)
    }

    fun confirmChatMutation(requestId: String): Boolean {
        val claim = claimConfirmedChatMutation(requestId) ?: return false
        when (claim.target.operation) {
            ChatMutationOperation.REMINDER_DELETE -> {
                val baseline = claim.target.reminderBaseline ?: return false
                launchChatMutation(claim) { repo ->
                    val outcome = repo.deleteChatReminderResult(
                        checkNotNull(claim.target.conversationId),
                        baseline,
                        requestId,
                    )
                    ChatMutationCompletion(
                        outcome.result,
                        chatMutationVerification(claim.target, reminders = outcome.reminders),
                        apply = { current ->
                            current.copy(
                                chatReminders = outcome.reminders?.let { Loadable.Ready(it) }
                                    ?: current.chatReminders,
                            )
                        },
                    )
                }
            }
            ChatMutationOperation.SCHEDULE_DELETE -> {
                val baseline = claim.target.scheduleBaseline ?: return false
                launchChatMutation(claim) { repo ->
                    val outcome = repo.deleteChatScheduledMessageResult(
                        checkNotNull(claim.target.conversationId),
                        baseline,
                        requestId,
                    )
                    ChatMutationCompletion(
                        outcome.result,
                        chatMutationVerification(
                            claim.target,
                            schedules = outcome.scheduledMessages,
                        ),
                        apply = { current ->
                            current.copy(
                                chatScheduledMessages = outcome.scheduledMessages
                                    ?.let { Loadable.Ready(it) }
                                    ?: current.chatScheduledMessages,
                            )
                        },
                    )
                }
            }
            else -> return false
        }
        return true
    }

    fun cancelChatMutation(requestId: String): Boolean {
        val entry = _workspace.value?.chatMutationState?.entries?.get(requestId) ?: return false
        if (entry.confirmationRequested) {
            synchronized(downloadMutationCoordinatorLock) {
                val current = _workspace.value ?: return@synchronized
                if (current.chatMutationState.entries[requestId] == entry) {
                    chatMutationGenerations.remove(requestId)
                    _workspace.value = current.copy(
                        chatMutationState = current.chatMutationState.copy(
                            entries = current.chatMutationState.entries - requestId,
                        ),
                    )
                }
            }
            return true
        }
        val job = chatMutationJobs[requestId] ?: return false
        job.cancel()
        return true
    }

    fun refreshChatMutation(requestId: String): Boolean {
        val repo = repository ?: return false
        val current = _workspace.value ?: return false
        val entry = current.chatMutationState.entries[requestId] ?: return false
        if (entry.mutationInProgress || entry.mutationRefreshInProgress ||
            current.profile.id != entry.target.profileId
        ) return false
        _workspace.value = current.copy(
            chatMutationState = current.chatMutationState.copy(
                entries = current.chatMutationState.entries +
                    (requestId to entry.copy(
                        mutationRefreshInProgress = true,
                        mutationRefreshFailure = null,
                    )),
            ),
        )
        viewModelScope.launch {
            val target = entry.target
            val refreshed = runCatching {
                when (target.operation) {
                    ChatMutationOperation.DIRECT_CONVERSATION_CREATE,
                    ChatMutationOperation.PRIVATE_GROUP_CREATE,
                    -> ChatMutationRefreshSnapshot(conversations = repo.chatConversations())
                    ChatMutationOperation.REMINDER_SET,
                    ChatMutationOperation.REMINDER_DELETE,
                    -> ChatMutationRefreshSnapshot(
                        reminders = repo.chatReminders(checkNotNull(target.conversationId)),
                    )
                    ChatMutationOperation.SCHEDULE_CREATE,
                    ChatMutationOperation.SCHEDULE_DELETE,
                    -> ChatMutationRefreshSnapshot(
                        schedules = repo.chatScheduledMessages(checkNotNull(target.conversationId)),
                    )
                    ChatMutationOperation.POLL_CREATE,
                    ChatMutationOperation.TEXT_SEND,
                    ChatMutationOperation.ATTACHMENT_SEND,
                    -> ChatMutationRefreshSnapshot(
                        messages = repo.chatMessages(checkNotNull(target.conversationId), 0, 50).messages,
                    )
                }
            }
            synchronized(downloadMutationCoordinatorLock) {
                val state = _workspace.value ?: return@synchronized
                val active = state.chatMutationState.entries[requestId] ?: return@synchronized
                if (!chatMutationCallbackMatches(
                        repository === repo,
                        state.profile.id == target.profileId,
                        active,
                        target,
                        entry.generation,
                        chatMutationGenerations[requestId],
                    )
                ) return@synchronized
                refreshed.fold(
                    onSuccess = { snapshot ->
                        val verification = chatMutationVerification(
                            target,
                            conversations = snapshot.conversations,
                            reminders = snapshot.reminders,
                            schedules = snapshot.schedules,
                            messages = snapshot.messages,
                        )
                        val attachmentUriToRelease = if (
                            verification == ChatMutationVerification.MATCHES &&
                            target.operation == ChatMutationOperation.ATTACHMENT_SEND
                        ) {
                            state.chatOutgoingMessages.values.flatten()
                                .firstOrNull { it.clientRequestId == target.requestId }
                                ?.let { state.chatPendingAttachmentUris[it.id] }
                        } else null
                        val converged = if (verification == ChatMutationVerification.MATCHES) {
                            convergeChatMutationRefreshMatch(state, target, snapshot.messages.orEmpty())
                        } else state
                        _workspace.value = converged.copy(
                            conversations = snapshot.conversations?.let { Loadable.Ready(it) }
                                ?: converged.conversations,
                            chatReminders = snapshot.reminders?.let { Loadable.Ready(it) }
                                ?: converged.chatReminders,
                            chatScheduledMessages = snapshot.schedules?.let { Loadable.Ready(it) }
                                ?: converged.chatScheduledMessages,
                            chatMutationState = converged.chatMutationState.copy(
                                entries = converged.chatMutationState.entries +
                                    (requestId to active.copy(
                                        mutationRefreshInProgress = false,
                                        mutationRefreshCompleted = true,
                                        mutationRefreshFailure = null,
                                        mutationFailure = if (
                                            verification == ChatMutationVerification.MATCHES
                                        ) null else active.mutationFailure,
                                        mutationVerification = verification,
                                    )),
                            ),
                        )
                        attachmentUriToRelease?.let(::releasePersistedReadPermission)
                    },
                    onFailure = { error ->
                        _workspace.value = state.copy(
                            chatMutationState = state.chatMutationState.copy(
                                entries = state.chatMutationState.entries +
                                    (requestId to active.copy(
                                        mutationRefreshInProgress = false,
                                        mutationRefreshFailure = error.asDsmFailure(),
                                    )),
                            ),
                        )
                    },
                )
            }
        }
        return true
    }

    fun dismissChatMutation(requestId: String, discardDraft: Boolean = false): Boolean =
        synchronized(downloadMutationCoordinatorLock) {
            val current = _workspace.value ?: return@synchronized false
            val entry = current.chatMutationState.entries[requestId] ?: return@synchronized false
            if (!canDismissChatMutation(entry)) return@synchronized false
            val local = current.chatOutgoingMessages.values.flatten().firstOrNull {
                it.clientRequestId == requestId && it.deliveryState == ChatDeliveryState.FAILED
            }
            val attachmentUri = local?.let { current.chatPendingAttachmentUris[it.id] }
            val withoutFailed = local?.let { removeLocalChatMessage(current, it) } ?: current
            chatMutationGenerations.remove(requestId)
            _workspace.value = withoutFailed.copy(
                chatMutationState = withoutFailed.chatMutationState.copy(
                    entries = withoutFailed.chatMutationState.entries - requestId,
                ),
                chatDrafts = if (discardDraft && entry.target.operation.isOutgoingMessage) {
                    entry.target.conversationId?.let { withoutFailed.chatDrafts + (it to "") }
                        ?: withoutFailed.chatDrafts
                } else withoutFailed.chatDrafts,
            )
            attachmentUri?.let(::releasePersistedReadPermission)
            true
        }

    fun continueEditingChatMutation(requestId: String): Boolean {
        return synchronized(downloadMutationCoordinatorLock) {
            val current = _workspace.value ?: return@synchronized false
            val entry = current.chatMutationState.entries[requestId] ?: return@synchronized false
            if (!chatMutationCanContinueEditing(entry)) {
                return@synchronized false
            }
            val local = current.chatOutgoingMessages.values.flatten()
                .firstOrNull { it.clientRequestId == requestId }
            val attachmentUri = local?.let { current.chatPendingAttachmentUris[it.id] }
            val withoutFailed = local?.takeIf {
                it.deliveryState == ChatDeliveryState.FAILED
            }?.let { removeLocalChatMessage(current, it) } ?: current
            chatMutationGenerations.remove(requestId)
            _workspace.value = withoutFailed.copy(
                chatDrafts = if (local?.body?.isNotBlank() == true) {
                    withoutFailed.chatDrafts + (local.conversationId to local.body)
                } else withoutFailed.chatDrafts,
                chatMutationState = withoutFailed.chatMutationState.copy(
                    entries = withoutFailed.chatMutationState.entries - requestId,
                ),
            )
            attachmentUri?.let(::releasePersistedReadPermission)
            true
        }
    }

    fun showChatScheduledMessages() {
        val repo = repository ?: return
        val conversation = _workspace.value?.selectedConversation ?: return
        _workspace.update {
            it?.copy(
                chatScheduledMessagesVisible = true,
                chatScheduledMessages = Loadable.Loading,
            )
        }
        viewModelScope.launch {
            capture(
                block = { repo.chatScheduledMessages(conversation.id) },
                update = { value ->
                    _workspace.update { state ->
                        if (state?.chatScheduledMessagesVisible == true) {
                            state.copy(chatScheduledMessages = value)
                        } else state
                    }
                },
            )
        }
    }

    fun closeChatScheduledMessages() {
        if (_workspace.value?.hasActiveChatMutation(
                ChatMutationOperation.SCHEDULE_CREATE,
                ChatMutationOperation.SCHEDULE_DELETE,
            ) == true
        ) return
        _workspace.update {
            it?.copy(
                chatScheduledMessagesVisible = false,
                chatScheduleComposerVisible = false,
            )
        }
    }

    fun openChatScheduleComposer() {
        _workspace.update {
            it?.copy(
                chatScheduleComposerVisible = true,
                chatScheduleDraft = "",
                chatScheduleSendAtEpochMillis = System.currentTimeMillis() + 3_600_000,
            )
        }
    }

    fun closeChatScheduleComposer() {
        if (_workspace.value?.hasActiveChatMutation(
                ChatMutationOperation.SCHEDULE_CREATE,
                ChatMutationOperation.SCHEDULE_DELETE,
            ) == true
        ) return
        _workspace.update { it?.copy(chatScheduleComposerVisible = false) }
    }

    fun updateChatScheduleDraft(value: String) {
        if (value.length > MAX_CHAT_MESSAGE_CHARACTERS) return
        _workspace.update { it?.copy(chatScheduleDraft = value) }
    }

    fun updateChatScheduleTime(value: Long) {
        _workspace.update {
            it?.copy(chatScheduleSendAtEpochMillis = value)
        }
    }

    fun createChatScheduledMessage() {
        val state = _workspace.value ?: return
        val conversation = state.selectedConversation ?: return
        val sendAt = state.chatScheduleSendAtEpochMillis ?: return
        if (state.hasActiveChatMutation(
                ChatMutationOperation.SCHEDULE_CREATE,
                ChatMutationOperation.SCHEDULE_DELETE,
            ) || state.chatScheduleDraft.isBlank()
        ) return
        val requestId = UUID.randomUUID().toString()
        val target = chatMutationTarget(
            state.profile.id,
            ChatMutationOperation.SCHEDULE_CREATE,
            requestId,
            conversation.id,
            expectedEpochMillis = sendAt,
            requestParts = listOf(state.chatScheduleDraft),
        )
        val claim = claimChatMutation(target) ?: return
        launchChatMutation(claim) { repo ->
            val outcome = repo.createChatScheduledMessageResult(
                conversation.id,
                state.chatScheduleDraft,
                sendAt,
                requestId,
            )
            ChatMutationCompletion(
                outcome.result,
                chatMutationVerification(target, schedules = outcome.scheduledMessages),
                apply = { current ->
                    current.copy(
                        chatScheduledMessages = outcome.scheduledMessages?.let { Loadable.Ready(it) }
                            ?: current.chatScheduledMessages,
                        chatScheduleComposerVisible = if (outcome.result.status ==
                            MutationResultStatus.CONFIRMED_SUCCESS
                        ) false else current.chatScheduleComposerVisible,
                        chatScheduleDraft = if (outcome.result.status ==
                            MutationResultStatus.CONFIRMED_SUCCESS
                        ) "" else current.chatScheduleDraft,
                        chatScheduleSendAtEpochMillis = if (outcome.result.status ==
                            MutationResultStatus.CONFIRMED_SUCCESS
                        ) null else current.chatScheduleSendAtEpochMillis,
                    )
                },
            )
        }
    }

    fun deleteChatScheduledMessage(id: String) {
        requestDeleteChatScheduledMessage(id)
    }

    fun requestDeleteChatScheduledMessage(id: String): Boolean {
        val state = _workspace.value ?: return false
        val conversation = state.selectedConversation ?: return false
        val baseline = (state.chatScheduledMessages as? Loadable.Ready)?.value
            ?.firstOrNull { it.id == id } ?: return false
        val requestId = UUID.randomUUID().toString()
        val target = chatMutationTarget(
            state.profile.id,
            ChatMutationOperation.SCHEDULE_DELETE,
            requestId,
            conversation.id,
            resourceIds = listOf(id),
            expectedEpochMillis = baseline.sendAtEpochMillis,
            requestParts = listOf(id, baseline.text),
            scheduleBaseline = baseline,
        )
        val claimed = claimChatMutation(target, confirmationRequested = true) != null
        return claimed
    }

    fun cancelDeleteChatScheduledMessage() {
        val entry = _workspace.value?.chatMutationState?.latestManagementEntry
        if (entry?.target?.operation == ChatMutationOperation.SCHEDULE_DELETE) {
            cancelChatMutation(entry.target.requestId)
        }
    }

    fun confirmDeleteChatScheduledMessage() {
        val entry = _workspace.value?.chatMutationState?.latestManagementEntry ?: return
        if (entry.target.operation == ChatMutationOperation.SCHEDULE_DELETE) {
            confirmChatMutation(entry.target.requestId)
        }
    }

    fun openChatPollComposer() {
        _workspace.update {
            it?.copy(
                chatPollComposerVisible = true,
                chatPollQuestion = "",
                chatPollOptions = listOf("", ""),
                chatPollAllowsMultiple = false,
                chatPollIsAnonymous = false,
            )
        }
    }

    fun closeChatPollComposer() {
        if (_workspace.value?.hasActiveChatMutation(ChatMutationOperation.POLL_CREATE) == true) return
        _workspace.update { it?.copy(chatPollComposerVisible = false) }
    }

    fun updateChatPollQuestion(value: String) {
        if (value.length > MAX_CHAT_MESSAGE_CHARACTERS) return
        _workspace.update { it?.copy(chatPollQuestion = value) }
    }

    fun updateChatPollOption(index: Int, value: String) {
        if (value.length > MAX_CHAT_POLL_OPTION_CHARACTERS) return
        _workspace.update { state ->
            if (state == null || index !in state.chatPollOptions.indices) state else state.copy(
                chatPollOptions = state.chatPollOptions.mapIndexed { position, current ->
                    if (position == index) value else current
                },
            )
        }
    }

    fun addChatPollOption() {
        _workspace.update { state ->
            if (state == null || state.chatPollOptions.size >= MAX_CHAT_POLL_OPTIONS) state
            else state.copy(chatPollOptions = state.chatPollOptions + "")
        }
    }

    fun removeChatPollOption(index: Int) {
        _workspace.update { state ->
            if (state == null || state.chatPollOptions.size <= 2 || index !in state.chatPollOptions.indices) {
                state
            } else state.copy(chatPollOptions = state.chatPollOptions.filterIndexed { i, _ -> i != index })
        }
    }

    fun toggleChatPollMultiple() {
        _workspace.update { it?.copy(chatPollAllowsMultiple = !it.chatPollAllowsMultiple) }
    }

    fun toggleChatPollAnonymous() {
        _workspace.update { it?.copy(chatPollIsAnonymous = !it.chatPollIsAnonymous) }
    }

    fun createChatPoll() {
        val state = _workspace.value ?: return
        val conversation = state.selectedConversation ?: return
        if (state.hasActiveChatMutation(ChatMutationOperation.POLL_CREATE)) return
        val requestId = UUID.randomUUID().toString()
        val target = chatMutationTarget(
            state.profile.id,
            ChatMutationOperation.POLL_CREATE,
            requestId,
            conversation.id,
            expectedEpochMillis = System.currentTimeMillis(),
            requestParts = listOf(
                state.chatPollQuestion,
                state.chatPollAllowsMultiple.toString(),
                state.chatPollIsAnonymous.toString(),
            ) + state.chatPollOptions,
        )
        val claim = claimChatMutation(target) ?: return
        launchChatMutation(claim) { repo ->
            val outcome = repo.createChatPollResult(
                conversation.id,
                state.chatPollQuestion,
                state.chatPollOptions,
                state.chatPollAllowsMultiple,
                state.chatPollIsAnonymous,
                requestId,
            )
            ChatMutationCompletion(
                outcome.result,
                chatMutationVerification(target, messages = listOfNotNull(outcome.message)),
                apply = { current ->
                    val success = outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS &&
                        outcome.message != null
                    current.copy(
                        chatPollComposerVisible = if (success) false else current.chatPollComposerVisible,
                        chatPollQuestion = if (success) "" else current.chatPollQuestion,
                        chatPollOptions = if (success) listOf("", "") else current.chatPollOptions,
                    )
                },
                afterApply = outcome.message?.takeIf {
                    outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS
                }?.let { message ->
                    { updateOutgoingChatMessage(message) }
                },
            )
        }
    }

    fun closeChatMembers() {
        _workspace.update { it?.copy(chatMembersVisible = false, chatMembers = Loadable.Idle) }
    }

    fun loadOlderChatMessages() {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        val conversation = state.selectedConversation ?: return
        val page = (state.chatMessages as? Loadable.Ready)?.value ?: return
        if (!page.hasMore || state.chatIsLoadingMore) return
        viewModelScope.launch { loadChatMessages(repo, conversation, reset = false) }
    }

    fun updateChatDraft(value: String) {
        val conversationId = _workspace.value?.selectedConversation?.id ?: return
        if (value.length > MAX_CHAT_MESSAGE_CHARACTERS) return
        _workspace.update { state ->
            state?.copy(chatDrafts = state.chatDrafts + (conversationId to value))
        }
    }

    fun sendChatMessage() {
        val state = _workspace.value ?: return
        val conversation = state.selectedConversation ?: return
        val text = state.chatDrafts[conversation.id]?.trim().orEmpty()
        if (text.isEmpty() || text.length > MAX_CHAT_MESSAGE_CHARACTERS) return
        val requestId = UUID.randomUUID().toString()
        val createdAtEpochSeconds = System.currentTimeMillis() / 1_000
        val target = chatMutationTarget(
            state.profile.id,
            ChatMutationOperation.TEXT_SEND,
            requestId,
            conversation.id,
            expectedEpochMillis = createdAtEpochSeconds * 1_000,
            requestParts = listOf(text),
        )
        val claim = claimChatMutation(target) ?: return
        val local = ChatMessage(
            id = "local:$requestId",
            conversationId = conversation.id,
            sender = io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser(
                "current", state.profile.username, state.profile.username,
            ),
            body = text,
            createdAtEpochSeconds = createdAtEpochSeconds,
            isMine = true,
            clientRequestId = requestId,
            deliveryState = ChatDeliveryState.SENDING,
        )
        updateOutgoingChatMessage(local, clearsDraft = true)
        performChatSend(claim, local)
    }

    fun sendChatAttachment(uri: Uri) {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        val conversation = state.selectedConversation ?: return
        val preflight = ChatAttachmentPreflightToken(
            repo,
            state.profile.id,
            conversation.id,
            chatAttachmentPreflightGeneration.get(),
            System.currentTimeMillis() / 1_000,
        )
        val text = state.chatDrafts[conversation.id]?.trim().orEmpty()
        val requestId = UUID.randomUUID().toString()
        val localId = "local:$requestId"
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            var persistedPermissionAcquired = false
            try {
                runCatching {
                persistedPermissionAcquired = runCatching {
                    getApplication<Application>().contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                }.isSuccess
                resolveUploadSource(uri)
            }.onSuccess { source ->
                if (!chatAttachmentPreflightMatches(preflight)) {
                    if (releaseChatAttachmentPermissionAfterPreflight(
                            persistedPermissionAcquired,
                            preflightMatches = false,
                            claimSucceeded = false,
                        )
                    ) releasePersistedReadPermission(uri)
                    return@onSuccess
                }
                val createdAtEpochSeconds = System.currentTimeMillis() / 1_000
                val target = chatMutationTarget(
                    state.profile.id,
                    ChatMutationOperation.ATTACHMENT_SEND,
                    requestId,
                    conversation.id,
                    expectedEpochMillis = createdAtEpochSeconds * 1_000,
                    requestParts = listOf(
                        text,
                        source.displayName,
                        source.contentLength?.toString().orEmpty(),
                    ),
                )
                val claim = claimChatMutation(target)
                if (claim == null) {
                    if (releaseChatAttachmentPermissionAfterPreflight(
                            persistedPermissionAcquired,
                            preflightMatches = true,
                            claimSucceeded = false,
                        )
                    ) releasePersistedReadPermission(uri)
                    return@onSuccess
                }
                val local = ChatMessage(
                    id = localId,
                    conversationId = conversation.id,
                    sender = ChatUser(
                        "current", state.profile.username, state.profile.username, isCurrent = true,
                    ),
                    body = text,
                    createdAtEpochSeconds = createdAtEpochSeconds,
                    isMine = true,
                    attachments = listOf(
                        io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment(
                            "local-file:$requestId",
                            source.displayName,
                            source.contentType,
                            source.contentLength,
                        ),
                    ),
                    clientRequestId = requestId,
                    deliveryState = ChatDeliveryState.SENDING,
                    attachmentProgress = 0f,
                )
                _workspace.update { current ->
                    current?.copy(
                        chatPendingAttachmentUris = current.chatPendingAttachmentUris + (local.id to uri),
                    )
                }
                updateOutgoingChatMessage(local, clearsDraft = true)
                performChatAttachmentSend(claim, local, source, uri)
                }.onFailure { error ->
                if (error is CancellationException) {
                    if (persistedPermissionAcquired) releasePersistedReadPermission(uri)
                    return@onFailure
                }
                if (!chatAttachmentPreflightMatches(preflight)) {
                    if (persistedPermissionAcquired) releasePersistedReadPermission(uri)
                    return@onFailure
                }
                if (persistedPermissionAcquired) releasePersistedReadPermission(uri)
                recordChatAttachmentPreflightFailure(
                    preflight,
                    requestId,
                    localId,
                    text,
                    uri,
                    error.asDsmFailure(),
                )
                }
            } finally {
                chatAttachmentJobs.remove(localId)
            }
        }
        chatAttachmentJobs[localId] = job
        job.start()
    }

    private fun chatAttachmentPreflightMatches(token: ChatAttachmentPreflightToken): Boolean =
        synchronized(downloadMutationCoordinatorLock) {
            val current = _workspace.value ?: return@synchronized false
            chatAttachmentPreflightIsCurrent(
                repository === token.repository,
                current.profile.id == token.profileId,
                current.selectedModule == Module.CHAT,
                current.selectedConversation?.id == token.conversationId,
                chatAttachmentPreflightGeneration.get() == token.generation,
            )
        }

    private fun invalidateChatAttachmentPreflights() {
        chatAttachmentPreflightGeneration.incrementAndGet()
        chatAttachmentJobs.values.forEach(Job::cancel)
        chatAttachmentJobs.clear()
    }

    private fun recordChatAttachmentPreflightFailure(
        token: ChatAttachmentPreflightToken,
        requestId: String,
        localId: String,
        body: String,
        uri: Uri,
        failure: DsmFailure,
    ): Boolean = synchronized(downloadMutationCoordinatorLock) {
        if (!chatAttachmentPreflightMatches(token)) return@synchronized false
        val current = _workspace.value ?: return@synchronized false
        val target = chatMutationTarget(
            token.profileId,
            ChatMutationOperation.ATTACHMENT_SEND,
            requestId,
            token.conversationId,
            expectedEpochMillis = token.createdAtEpochSeconds * 1_000,
            requestParts = listOf(body),
        )
        val generation = chatMutationGeneration.incrementAndGet()
        chatMutationGenerations[requestId] = generation
        val local = ChatMessage(
            id = localId,
            conversationId = token.conversationId,
            sender = ChatUser(
                "current",
                current.profile.username,
                current.profile.username,
                isCurrent = true,
            ),
            body = body,
            createdAtEpochSeconds = token.createdAtEpochSeconds,
            isMine = true,
            clientRequestId = requestId,
            deliveryState = ChatDeliveryState.FAILED,
        )
        val outgoing = (current.chatOutgoingMessages[token.conversationId].orEmpty() + local)
            .distinctBy(ChatMessage::id)
        val page = (current.chatMessages as? Loadable.Ready)?.value
        _workspace.value = current.copy(
            chatMutationState = current.chatMutationState.copy(
                entries = current.chatMutationState.entries + (
                    requestId to ChatMutationEntry(
                        target = target,
                        mutationResult = chatMutationFailedBeforeSubmissionResult(target),
                        mutationFailure = failure,
                        mutationRefreshCompleted = true,
                        generation = generation,
                    )
                ),
            ),
            chatOutgoingMessages = current.chatOutgoingMessages +
                (token.conversationId to outgoing),
            chatMessages = page?.copy(
                messages = (page.messages + local).distinctBy(ChatMessage::id)
                    .sortedBy(ChatMessage::createdAtEpochSeconds),
            )?.let { Loadable.Ready(it) } ?: current.chatMessages,
            chatPendingAttachmentUris = current.chatPendingAttachmentUris + (localId to uri),
        )
        true
    }

    fun cancelChatAttachment(localId: String) {
        chatAttachmentJobs.remove(localId)?.cancel()
        val requestId = _workspace.value?.chatOutgoingMessages?.values?.flatten()
            ?.firstOrNull { it.id == localId }?.clientRequestId ?: return
        cancelChatMutation(requestId)
    }

    fun saveChatAttachment(
        messageId: String,
        attachment: io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment,
        destination: Uri,
    ) {
        val repo = repository ?: return
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val output = getApplication<Application>().contentResolver.openOutputStream(destination, "w")
                        ?: throw DsmFailure(
                            null,
                            "The selected location could not be opened",
                            "Choose another location and try again.",
                            kind = DsmErrorKind.PERMISSION_DENIED,
                        )
                    output.use {
                        repo.downloadChatAttachment(messageId, attachment.size, it) { _, _ -> }
                    }
                }
            }.onSuccess {
                _workspace.update {
                    it?.copy(message = getApplication<Application>().getString(R.string.attachment_saved))
                }
            }.onFailure { error ->
                if (error is CancellationException) return@onFailure
                _workspace.update {
                    it?.copy(message = error.asDsmFailure().localize(getApplication<Application>()).combined)
                }
            }
        }
    }

    fun previewChatAttachment(
        messageId: String,
        attachment: io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment,
    ) {
        val repo = repository ?: return
        closeChatAttachmentPreview()
        if (attachment.isVideoAttachment()) {
            previewChatVideoAttachment(repo, messageId, attachment)
            return
        }
        val cached = _workspace.value?.chatAttachmentThumbnails?.get(messageId)
        if (cached is Loadable.Ready) {
            _workspace.update {
                it?.copy(
                    chatAttachmentPreviewName = attachment.name,
                    chatAttachmentPreviewBytes = cached.value,
                    chatAttachmentPreviewIsLoading = false,
                )
            }
            return
        }
        _workspace.update {
            it?.copy(
                chatAttachmentPreviewName = attachment.name,
                chatAttachmentPreviewIsLoading = true,
                chatAttachmentThumbnails = it.chatAttachmentThumbnails +
                    (messageId to Loadable.Loading),
            )
        }
        chatAttachmentPreviewJob = viewModelScope.launch {
            runCatching { repo.chatAttachmentThumbnail(messageId) }
                .onSuccess { bytes ->
                    _workspace.update {
                        if (it?.chatAttachmentPreviewName != attachment.name ||
                            it.chatAttachmentPreviewIsVideo
                        ) return@update it
                        it?.copy(
                            chatAttachmentThumbnails = it.chatAttachmentThumbnails +
                                (messageId to Loadable.Ready(bytes)),
                            chatAttachmentPreviewBytes = bytes,
                            chatAttachmentPreviewIsLoading = false,
                        )
                    }
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    val failure = error.asDsmFailure()
                    _workspace.update {
                        it?.copy(
                            chatAttachmentThumbnails = it.chatAttachmentThumbnails +
                                (messageId to Loadable.Failed(failure)),
                            chatAttachmentPreviewIsLoading = false,
                            chatAttachmentPreviewError = failure
                                .localize(getApplication<Application>()).combined,
                        )
                    }
                }
        }
    }

    fun closeChatAttachmentPreview() {
        chatAttachmentPreviewJob?.cancel()
        chatAttachmentPreviewJob = null
        _workspace.value?.chatAttachmentPreviewVideoFile?.delete()
        _workspace.update {
            it?.copy(
                chatAttachmentPreviewName = null,
                chatAttachmentPreviewBytes = null,
                chatAttachmentPreviewVideoFile = null,
                chatAttachmentPreviewIsVideo = false,
                chatAttachmentPreviewIsLoading = false,
                chatAttachmentPreviewProgress = null,
                chatAttachmentPreviewError = null,
            )
        }
    }

    private fun previewChatVideoAttachment(
        repo: DsmRepository,
        messageId: String,
        attachment: io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment,
    ) {
        _workspace.update {
            it?.copy(
                chatAttachmentPreviewName = attachment.name,
                chatAttachmentPreviewIsVideo = true,
                chatAttachmentPreviewIsLoading = true,
                chatAttachmentPreviewProgress = 0f,
            )
        }
        chatAttachmentPreviewJob = viewModelScope.launch {
            var temporaryFile: File? = null
            runCatching {
                withContext(Dispatchers.IO) {
                    val directory = File(getApplication<Application>().cacheDir, "chat-preview")
                        .also { it.mkdirs() }
                    val extension = attachment.name.substringAfterLast('.', "mp4")
                        .lowercase(Locale.ROOT)
                        .filter(Char::isLetterOrDigit)
                        .take(8)
                        .ifBlank { "mp4" }
                    File.createTempFile("video-", ".$extension", directory).also { file ->
                        temporaryFile = file
                        FileOutputStream(file).use { output ->
                            repo.downloadChatVideoPreview(
                                messageId,
                                attachment.size,
                                output,
                            ) { completed, total ->
                                val progress = if (total != null && total > 0) {
                                    (completed.toFloat() / total).coerceIn(0f, 1f)
                                } else null
                                _workspace.update { state ->
                                    if (state?.chatAttachmentPreviewName == attachment.name &&
                                        state.chatAttachmentPreviewIsVideo
                                    ) state.copy(chatAttachmentPreviewProgress = progress) else state
                                }
                            }
                        }
                    }
                }
            }.onSuccess { file ->
                _workspace.update { state ->
                    if (state?.chatAttachmentPreviewName == attachment.name &&
                        state.chatAttachmentPreviewIsVideo
                    ) state.copy(
                        chatAttachmentPreviewVideoFile = file,
                        chatAttachmentPreviewIsLoading = false,
                        chatAttachmentPreviewProgress = 1f,
                    ) else {
                        file.delete()
                        state
                    }
                }
            }.onFailure { error ->
                temporaryFile?.delete()
                if (error is CancellationException) return@onFailure
                _workspace.update { state ->
                    if (state?.chatAttachmentPreviewName == attachment.name &&
                        state.chatAttachmentPreviewIsVideo
                    ) state.copy(
                        chatAttachmentPreviewIsLoading = false,
                        chatAttachmentPreviewProgress = null,
                        chatAttachmentPreviewError = error.asDsmFailure()
                            .localize(getApplication<Application>()).combined,
                    ) else state
                }
            }
        }
    }

    fun retryChatMessage(localId: String) {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        val failed = state.chatOutgoingMessages.values.flatten().firstOrNull {
            it.id == localId && it.deliveryState == ChatDeliveryState.FAILED
        } ?: return
        val existingEntry = state.chatMutationState.entry(failed.clientRequestId) ?: return
        synchronized(downloadMutationCoordinatorLock) {
            val current = _workspace.value ?: return
            val active = current.chatMutationState.entry(existingEntry.target.requestId) ?: return
            if (!chatMutationCallbackMatches(
                    repository === repo,
                    current.profile.id == existingEntry.target.profileId,
                    active,
                    existingEntry.target,
                    existingEntry.generation,
                    chatMutationGenerations[existingEntry.target.requestId],
                ) || active.mutationInProgress || active.mutationRefreshInProgress
            ) return
            _workspace.value = current.copy(
                chatMutationState = current.chatMutationState.copy(
                    entries = current.chatMutationState.entries +
                        (existingEntry.target.requestId to active.copy(
                            mutationRefreshInProgress = true,
                            mutationRefreshFailure = null,
                        )),
                ),
            )
        }
        viewModelScope.launch {
            val recentResult = runCatching { repo.chatMessages(failed.conversationId, 0, 50) }
            val recent = recentResult.getOrNull()
            val canResend = synchronized(downloadMutationCoordinatorLock) {
                val current = _workspace.value ?: return@synchronized false
                val active = current.chatMutationState.entry(existingEntry.target.requestId)
                    ?: return@synchronized false
                if (!chatMutationCallbackMatches(
                        repository === repo,
                        current.profile.id == existingEntry.target.profileId,
                        active,
                        existingEntry.target,
                        existingEntry.generation,
                        chatMutationGenerations[existingEntry.target.requestId],
                    )
                ) return@synchronized false
                recentResult.fold(
                    onSuccess = { page ->
                        val verification = chatMutationVerification(
                            existingEntry.target,
                            messages = page.messages,
                        )
                        val decision = chatRetryReadbackDecision(true, null, verification)
                        val attachmentUriToRelease = if (
                            decision == ChatRetryReadbackDecision.CONVERGE &&
                            existingEntry.target.operation == ChatMutationOperation.ATTACHMENT_SEND
                        ) current.chatPendingAttachmentUris[failed.id] else null
                        val converged = if (decision == ChatRetryReadbackDecision.CONVERGE) {
                            convergeChatMutationRefreshMatch(current, existingEntry.target, page.messages)
                        } else current
                        _workspace.value = converged.copy(
                            chatMutationState = converged.chatMutationState.copy(
                                entries = converged.chatMutationState.entries +
                                    (existingEntry.target.requestId to active.copy(
                                        mutationRefreshInProgress = false,
                                        mutationRefreshCompleted = true,
                                        mutationRefreshFailure = null,
                                        mutationFailure = if (
                                            verification == ChatMutationVerification.MATCHES
                                        ) null else active.mutationFailure,
                                        mutationVerification = verification,
                                    )),
                            ),
                        )
                        attachmentUriToRelease?.let(::releasePersistedReadPermission)
                        decision == ChatRetryReadbackDecision.RESEND
                    },
                    onFailure = { error ->
                        val failure = error.asDsmFailure()
                        _workspace.value = current.copy(
                            chatMutationState = current.chatMutationState.copy(
                                entries = current.chatMutationState.entries +
                                    (existingEntry.target.requestId to active.copy(
                                        mutationRefreshInProgress = false,
                                        mutationRefreshCompleted = false,
                                        mutationRefreshFailure = failure,
                                    )),
                            ),
                        )
                        false
                    },
                )
            }
            if (!canResend || recent == null) {
                return@launch
            }
            val uri = state.chatPendingAttachmentUris[failed.id]
            if (uri == null) {
                val claim = reclaimChatMutation(existingEntry.target, repo) ?: return@launch
                val sending = failed.copy(deliveryState = ChatDeliveryState.SENDING)
                updateOutgoingChatMessage(sending)
                performChatSend(claim, sending)
            } else {
                runCatching { resolveUploadSource(uri) }
                    .onSuccess { source ->
                        val retryTarget = chatMutationTarget(
                            existingEntry.target.profileId,
                            ChatMutationOperation.ATTACHMENT_SEND,
                            existingEntry.target.requestId,
                            existingEntry.target.conversationId,
                            expectedEpochMillis = existingEntry.target.expectedEpochMillis,
                            requestParts = listOf(
                                failed.body,
                                source.displayName,
                                source.contentLength.toString(),
                            ),
                        )
                        val claim = reclaimChatMutation(retryTarget, repo) ?: return@onSuccess
                        val sending = failed.copy(deliveryState = ChatDeliveryState.SENDING)
                        updateOutgoingChatMessage(sending)
                        performChatAttachmentSend(claim, sending, source, uri)
                    }
                    .onFailure { error ->
                        synchronized(downloadMutationCoordinatorLock) {
                            val current = _workspace.value ?: return@synchronized
                            val active = current.chatMutationState.entry(existingEntry.target.requestId)
                                ?: return@synchronized
                            if (!chatMutationCallbackMatches(
                                    repository === repo,
                                    current.profile.id == existingEntry.target.profileId,
                                    active,
                                    existingEntry.target,
                                    existingEntry.generation,
                                    chatMutationGenerations[existingEntry.target.requestId],
                                )
                            ) return@synchronized
                            _workspace.value = current.copy(
                                chatMutationState = current.chatMutationState.copy(
                                    entries = current.chatMutationState.entries +
                                        (existingEntry.target.requestId to active.copy(
                                            mutationFailure = error.asDsmFailure(),
                                        )),
                                ),
                            )
                        }
                    }
            }
        }
    }

    fun removeFailedChatMessage(localId: String): Boolean =
        synchronized(downloadMutationCoordinatorLock) {
            val state = _workspace.value ?: return@synchronized false
            val failed = state.chatOutgoingMessages.values.flatten().firstOrNull {
                it.id == localId && it.deliveryState == ChatDeliveryState.FAILED
            } ?: return@synchronized false
            val requestId = failed.clientRequestId ?: return@synchronized false
            val entry = state.chatMutationState.entry(requestId) ?: return@synchronized false
            if (!chatMutationCanRemoveFailed(entry)) return@synchronized false
            val attachmentUri = state.chatPendingAttachmentUris[localId]
            val withoutFailed = removeLocalChatMessage(state, failed)
            chatMutationGenerations.remove(requestId)
            _workspace.value = withoutFailed.copy(
                chatMutationState = withoutFailed.chatMutationState.copy(
                    entries = withoutFailed.chatMutationState.entries - requestId,
                ),
            )
            attachmentUri?.let(::releasePersistedReadPermission)
            true
        }

    fun openDirectory(item: FileItem) {
        if (!item.isDirectory) return
        cancelOpaqueExternalNavigation(consumePending = true)
        val current = _workspace.value ?: return
        if (fileStationMutationBlocksOrdinaryLoad(current.fileStationMutationState)) return
        val nextBrowser = current.fileBrowser.enterDirectory(item.path)
        _workspace.update {
            it?.copy(
                fileBrowser = nextBrowser,
                fileDirectoryBaselines = it.fileDirectoryBaselines + (item.path to item),
            )
        }
        store.recordRecentDirectory(current.profile.id, item.path)
        repository?.let { repo ->
            viewModelScope.launch { loadFileBrowser(repo) }
        }
    }

    fun goBackDirectory() {
        cancelOpaqueExternalNavigation(consumePending = true)
        val state = _workspace.value ?: return
        if (fileStationMutationBlocksOrdinaryLoad(state.fileStationMutationState)) return
        val previous = state.fileBrowser.navigateUp() ?: return
        _workspace.update {
            it?.copy(fileBrowser = previous)
        }
        repository?.let { repo ->
            viewModelScope.launch { loadFileBrowser(repo) }
        }
    }

    fun openRecycleBin(share: FileItem) {
        if (!share.isDirectory || _workspace.value?.fileBrowser?.path?.isNotBlank() == true) return
        val recycle = share.copy(
            path = share.path.trimEnd('/') + "/#recycle",
            name = "#recycle",
            canWrite = false,
        )
        openDirectory(recycle)
    }

    fun loadFileFavorites() {
        val repo = repository ?: return
        if (_workspace.value?.supportsFavorites != true) return
        _workspace.update { it?.copy(fileFavorites = Loadable.Loading) }
        viewModelScope.launch {
            runCatching {
                repo.listFavorites().take(MAX_FILE_FAVORITES).mapNotNull { favorite ->
                    runCatching { repo.fileInfo(favorite.path) }.getOrNull()
                        ?.takeIf(FileItem::isDirectory)
                        ?.copy(isFavorite = true)
                }
            }.onSuccess { favorites ->
                _workspace.update { it?.copy(fileFavorites = Loadable.Ready(favorites)) }
            }.onFailure { error ->
                _workspace.update {
                    it?.copy(fileFavorites = Loadable.Failed(error.asDsmFailure()))
                }
            }
        }
    }

    fun closeFileFavorites() {
        _workspace.update { it?.copy(fileFavorites = Loadable.Idle) }
    }

    fun openFileFavorite(item: FileItem) {
        _workspace.update {
            it?.copy(
                fileBrowser = it.fileBrowser.openShortcut(item.path),
                fileFavorites = Loadable.Idle,
                fileDirectoryBaselines = it.fileDirectoryBaselines + (item.path to item),
            )
        }
        repository?.let { repo -> viewModelScope.launch { loadFileBrowser(repo) } }
    }

    fun loadFileRemoteLocations() {
        val repo = repository ?: return
        if (_workspace.value?.supportsRemoteLocations != true) return
        _workspace.update { it?.copy(fileRemoteLocations = Loadable.Loading) }
        viewModelScope.launch {
            runCatching { repo.listRemoteLocations(limit = MAX_FILE_REMOTE_LOCATIONS).items }
                .onSuccess { locations ->
                    _workspace.update { it?.copy(fileRemoteLocations = Loadable.Ready(locations)) }
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    _workspace.update {
                        it?.copy(fileRemoteLocations = Loadable.Failed(error.asDsmFailure()))
                    }
                }
        }
    }

    fun closeFileRemoteLocations() {
        _workspace.update { it?.copy(fileRemoteLocations = Loadable.Idle) }
    }

    fun openFileRemoteLocation(item: FileItem) {
        _workspace.update {
            it?.copy(
                fileBrowser = it.fileBrowser.openShortcut(item.path),
                fileRemoteLocations = Loadable.Idle,
                fileDirectoryBaselines = it.fileDirectoryBaselines + (item.path to item),
            )
        }
        repository?.let { repo -> viewModelScope.launch { loadFileBrowser(repo) } }
    }

    fun loadFileRecentLocations() {
        val repo = repository ?: return
        val profileId = _workspace.value?.profile?.id ?: return
        _workspace.update { it?.copy(fileRecentLocations = Loadable.Loading) }
        viewModelScope.launch {
            val locations = store.recentDirectories(profileId).mapNotNull { path ->
                runCatching { repo.fileInfo(path) }.getOrNull()?.takeIf(FileItem::isDirectory)
            }
            _workspace.update { it?.copy(fileRecentLocations = Loadable.Ready(locations)) }
        }
    }

    fun closeFileRecentLocations() {
        _workspace.update { it?.copy(fileRecentLocations = Loadable.Idle) }
    }

    fun openFileRecentLocation(item: FileItem) {
        val profileId = _workspace.value?.profile?.id ?: return
        store.recordRecentDirectory(profileId, item.path)
        _workspace.update {
            it?.copy(
                fileBrowser = it.fileBrowser.openShortcut(item.path),
                fileRecentLocations = Loadable.Idle,
                fileDirectoryBaselines = it.fileDirectoryBaselines + (item.path to item),
            )
        }
        repository?.let { repo -> viewModelScope.launch { loadFileBrowser(repo) } }
    }

    fun navigateToFilePath(path: String) {
        val state = _workspace.value ?: return
        if (fileStationMutationBlocksOrdinaryLoad(state.fileStationMutationState)) return
        val next = state.fileBrowser.navigateTo(path) ?: return
        _workspace.update { it?.copy(fileBrowser = next) }
        repository?.let { repo ->
            viewModelScope.launch {
                runCatching { repo.fileInfo(path) }.getOrNull()?.takeIf(FileItem::isDirectory)?.let { item ->
                    _workspace.update { current ->
                        current?.takeIf {
                            repository === repo && it.fileBrowser.path == path
                        }?.copy(
                            fileDirectoryBaselines = current.fileDirectoryBaselines + (path to item),
                        ) ?: current
                    }
                }
                loadFileBrowser(repo)
            }
        }
    }

    fun refreshFiles() {
        repository?.let { repo -> viewModelScope.launch { loadFileBrowser(repo) } }
    }

    fun changeFileSort(option: FileSortOption) {
        val state = _workspace.value ?: return
        _workspace.update { it?.copy(fileBrowser = state.fileBrowser.changeSort(option)) }
        repository?.let { repo -> viewModelScope.launch { loadFileBrowser(repo) } }
    }

    fun changeFileFilter(filter: FileTypeFilter) {
        _workspace.update { it?.copy(fileBrowser = it.fileBrowser.changeFilter(filter)) }
        repository?.let { repo -> viewModelScope.launch { loadFileBrowser(repo) } }
    }

    fun changeFileViewMode(mode: FileViewMode) {
        _workspace.update { it?.copy(fileBrowser = it.fileBrowser.changeViewMode(mode)) }
    }

    fun toggleFileSelection(item: FileItem) {
        _workspace.update {
            it?.copy(fileBrowser = it.fileBrowser.toggleSelection(item.path))
        }
    }

    fun clearFileSelection() {
        _workspace.update { it?.copy(fileBrowser = it.fileBrowser.clearSelection()) }
    }

    fun loadMoreFiles() {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        val page = (state.files as? Loadable.Ready)?.value ?: return
        if (state.fileIsLoadingMore || state.fileBrowser.activeSearchQuery != null) return
        val nextOffset = page.offset + page.items.size
        if (nextOffset >= page.total) return
        val browser = state.fileBrowser
        val requestToken = FileBrowserRequestToken(
            generation = fileBrowserRequestGeneration.incrementAndGet(),
            identity = browser.fileBrowserRequestIdentity(),
        )
        _workspace.update { current ->
            current?.takeIf {
                repo === repository &&
                it.selectedModule == Module.FILES &&
                    it.fileBrowser.matchesFileBrowserRequest(
                        requestToken,
                        fileBrowserRequestGeneration.get(),
                    ) &&
                    !it.fileIsLoadingMore &&
                    (it.files as? Loadable.Ready)?.value == page
            }?.copy(fileIsLoadingMore = true)
                ?: current
        }
        val activeState = _workspace.value
        if (repo !== repository ||
            activeState?.selectedModule != Module.FILES ||
            activeState.fileBrowser.matchesFileBrowserRequest(
                requestToken,
                fileBrowserRequestGeneration.get(),
            ).not() ||
            !activeState.fileIsLoadingMore ||
            activeState.files !is Loadable.Ready
        ) return
        viewModelScope.launch {
            runCatching { listFilePage(repo, browser, nextOffset) }
                .onSuccess { next ->
                    _workspace.update { current ->
                        val currentPage = (current?.files as? Loadable.Ready)?.value
                        if (current != null && currentPage != null &&
                            repo === repository &&
                            current.selectedModule == Module.FILES &&
                            current.fileBrowser.matchesFileBrowserRequest(
                                requestToken,
                                fileBrowserRequestGeneration.get(),
                            ) &&
                            current.fileIsLoadingMore
                        ) {
                            current.copy(
                                files = Loadable.Ready(
                                    currentPage.copy(
                                        items = (currentPage.items + next.items)
                                            .distinctBy(FileItem::path)
                                            .map { item ->
                                                if (item.path in current.favoritePaths) {
                                                    item.copy(isFavorite = true)
                                                } else {
                                                    item
                                                }
                                            },
                                        total = next.total,
                                    ),
                                ),
                                fileIsLoadingMore = false,
                            )
                        } else {
                            current
                        }
                    }
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    _workspace.update { current ->
                        current?.takeIf {
                            repo === repository &&
                            it.selectedModule == Module.FILES &&
                                it.fileBrowser.matchesFileBrowserRequest(
                                    requestToken,
                                    fileBrowserRequestGeneration.get(),
                                ) &&
                                it.fileIsLoadingMore
                        }?.copy(
                            fileIsLoadingMore = false,
                            message = error.asDsmFailure().recovery,
                        ) ?: current
                    }
                }
        }
    }

    fun updateFileSearchQuery(query: String) {
        _workspace.update {
            it?.copy(fileBrowser = it.fileBrowser.editSearchQuery(query))
        }
    }

    fun searchFiles() {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        val browser = state.fileBrowser.submitSearch()
        _workspace.update { it?.copy(fileBrowser = browser) }
        viewModelScope.launch {
            loadFileBrowser(repo)
        }
    }

    fun openCreateFolderEditor(): Boolean = synchronized(fileStationMutationLock) {
        val current = _workspace.value ?: return false
        val parent = current.fileDirectoryBaselines[current.fileBrowser.path] ?: return false
        val state = current.fileStationMutationState
        if (current.selectedModule != Module.FILES || current.isPerformingAction ||
            fileStationMutationBlocksOrdinaryLoad(state)
        ) return false
        _workspace.value = current.copy(
            fileStationMutationState = FileStationMutationWorkspaceState(
                editorVisible = true,
                editorParentBaseline = parent,
            ),
        )
        true
    }

    fun openRenameFileEditor(item: FileItem): Boolean = synchronized(fileStationMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.fileStationMutationState
        if (current.selectedModule != Module.FILES || current.isPerformingAction ||
            fileStationMutationBlocksOrdinaryLoad(state)
        ) return false
        _workspace.value = current.copy(
            fileStationMutationState = FileStationMutationWorkspaceState(
                editorVisible = true,
                nameDraft = item.name,
                editorSourceBaseline = item,
            ),
        )
        true
    }

    fun updateFileStationNameDraft(name: String): Boolean = synchronized(fileStationMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.fileStationMutationState
        if (!state.editorVisible || state.mutationInProgress) return false
        _workspace.value = current.copy(
            fileStationMutationState = state.copy(nameDraft = name),
        )
        true
    }

    fun confirmFileStationNameEditor(): Boolean {
        val state = _workspace.value?.fileStationMutationState ?: return false
        if (!state.editorVisible || state.nameDraft.trim().isEmpty()) return false
        return when {
            state.editorSourceBaseline != null -> {
                renameFile(state.editorSourceBaseline, state.nameDraft)
                _workspace.value?.fileStationMutationState?.mutationInProgress == true
            }
            state.editorParentBaseline != null -> {
                createFolder(state.nameDraft)
                _workspace.value?.fileStationMutationState?.mutationInProgress == true
            }
            else -> false
        }
    }

    fun createFolder(name: String) {
        val current = _workspace.value ?: return
        val parent = current.fileBrowser.path
        val parentBaseline = current.fileDirectoryBaselines[parent] ?: return
        val requestedName = name.trim()
        val target = runCatching {
            FileStationMutationTarget(
                profileId = current.profile.id,
                module = Module.FILES,
                operation = FileStationMutationOperation.CREATE_FOLDER,
                parentPath = parent,
                parentBaseline = parentBaseline,
                requestedName = requestedName,
            )
        }.getOrNull() ?: return
        fileStationMutation(
            target,
            FileStationMutationRefresh.FILE_BROWSER,
            ::fileEntryMutationMessageResource,
        ) { repo -> repo.createFolderResult(parentBaseline, requestedName) }
    }

    fun renameFile(item: FileItem, newName: String) {
        val current = _workspace.value ?: return
        val requestedName = newName.trim()
        val target = runCatching {
            FileStationMutationTarget(
                profileId = current.profile.id,
                module = Module.FILES,
                operation = FileStationMutationOperation.RENAME,
                sourceBaselines = listOf(item),
                requestedName = requestedName,
            )
        }.getOrNull() ?: return
        fileStationMutation(
            target,
            FileStationMutationRefresh.FILE_BROWSER,
            ::fileEntryMutationMessageResource,
        ) { repo -> repo.renameResult(item, requestedName) }
    }

    fun deleteFiles(items: List<FileItem>): Boolean {
        if (items.isEmpty()) return false
        if (items.any { !it.canDelete }) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.file_delete_not_allowed))
            }
            return false
        }
        val current = _workspace.value ?: return false
        return requestFileStationLifecycleMutation(
            FileStationMutationTarget(
                profileId = current.profile.id,
                module = Module.FILES,
                operation = FileStationMutationOperation.DELETE,
                sourceBaselines = items,
            ),
        )
    }

    fun compressFiles(
        items: List<FileItem>,
        archiveName: String,
        format: ArchiveFormat,
        password: String?,
    ) {
        val current = _workspace.value ?: return
        val folder = current.fileBrowser.path
        val destinationBaseline = current.fileDirectoryBaselines[folder] ?: return
        val requestedName = archiveName.trim()
        val cleanName = requestedName.substringBeforeLast('.', requestedName)
        if (items.isEmpty() || folder.isBlank() || cleanName.isBlank() || '/' in cleanName) return
        val title = "$cleanName.${format.fileExtension}"
        val destinationPath = "$folder/$title"
        val target = FileServerMutationTarget(
            profileId = current.profile.id,
            module = Module.FILES,
            operation = FileServerMutationOperation.COMPRESS,
            sourceBaselines = items,
            destinationFolderBaseline = destinationBaseline,
            expectedOutputs = listOf(
                FileServerMutationExpectedOutput(
                    destinationPath,
                    isDirectory = false,
                    requiresNonEmptyFile = true,
                ),
            ),
        )
        enqueueServerTransfer(title, target) { repo, progress, beforeSubmit, taskStarted, _ ->
            val result = repo.compressResult(
                sourceBaselines = items,
                destinationBaseline = destinationBaseline,
                destinationFilePath = destinationPath,
                format = format,
                level = ArchiveCompressionLevel.MODERATE,
                password = password,
                onProgress = progress,
                onBeforeSubmit = beforeSubmit,
                onTaskStarted = taskStarted,
            )
            if ((result.submitted || result.requiresRefresh) && currentCoroutineContext().isActive) {
                loadFileBrowser(repo)
            }
            FileServerMutationExecution(result, target.expectedOutputs)
        }
    }

    fun extractFile(item: FileItem, password: String?) {
        val current = _workspace.value ?: return
        val folder = current.fileBrowser.path
        val destinationBaseline = current.fileDirectoryBaselines[folder] ?: return
        if (folder.isBlank() || item.isDirectory || !item.canRead) return
        val target = FileServerMutationTarget(
            profileId = current.profile.id,
            module = Module.FILES,
            operation = FileServerMutationOperation.EXTRACT,
            sourceBaselines = listOf(item),
            destinationFolderBaseline = destinationBaseline,
        )
        enqueueServerTransfer(
            item.name,
            target,
        ) { repo, progress, beforeSubmit, taskStarted, expectedOutputsChanged ->
            var expectedOutputs = emptyList<FileServerMutationExpectedOutput>()
            val result = repo.extractResult(
                sourceBaseline = item,
                destinationBaseline = destinationBaseline,
                password = password,
                onProgress = progress,
                onExpectedOutputs = {
                    expectedOutputs = it
                    expectedOutputsChanged(it)
                },
                onBeforeSubmit = beforeSubmit,
                onTaskStarted = taskStarted,
            )
            if ((result.submitted || result.requiresRefresh) && currentCoroutineContext().isActive) {
                loadFileBrowser(repo)
            }
            FileServerMutationExecution(result, expectedOutputs)
        }
    }

    fun addFavorites(items: List<FileItem>) {
        val current = _workspace.value ?: return
        val candidates = items.filter { it.isDirectory && !it.isFavorite }
        if (candidates.isEmpty()) return
        val target = FileStationMutationTarget(
            profileId = current.profile.id,
            module = Module.FILES,
            operation = FileStationMutationOperation.FAVORITE_ADD_BATCH,
            sourceBaselines = candidates,
        )
        fileStationMutation(
            target,
            FileStationMutationRefresh.FAVORITES,
            ::fileStationFavoriteBatchMessageResource,
            applyResult = { workspace, result ->
                workspace.copy(
                    fileBrowser = if (result.submitted) {
                        workspace.fileBrowser.clearSelection()
                    } else {
                        workspace.fileBrowser
                    },
                )
            },
        ) { repo ->
            val results = candidates.map { item ->
                try {
                    repo.addFavoriteResult(item)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    null
                }
            }
            aggregateFileStationMutationResults(
                FileStationMutationOperation.FAVORITE_ADD_BATCH,
                candidates.size,
                results,
            )
        }
    }

    fun beginFileCopyMove(items: List<FileItem>, operation: FileCopyMoveOperation) {
        val repo = repository ?: return
        val workspace = _workspace.value ?: return
        if (items.isEmpty()) return
        val targetProfiles = (store.profiles() + workspace.profile)
            .distinctBy(NasProfile::id)
            .filter { it.id == workspace.profile.id || store.session(it.id) != null }
        if (!workspace.supportsCopyMove && targetProfiles.size == 1) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.file_copy_move_unavailable))
            }
            return
        }
        val move = FileCopyMoveState(
            items = items,
            operation = operation,
            sourceProfileId = workspace.profile.id,
            targetProfileId = workspace.profile.id,
            targetProfiles = targetProfiles,
        )
        val target = FileStationMutationTarget(
            profileId = workspace.profile.id,
            module = Module.FILES,
            operation = if (operation == FileCopyMoveOperation.COPY) {
                FileStationMutationOperation.COPY
            } else {
                FileStationMutationOperation.MOVE
            },
            sourceBaselines = items,
        )
        _workspace.update {
            it?.copy(
                fileCopyMove = move,
                fileCopyMoveFolders = Loadable.Loading,
                fileStationMutationState = FileStationMutationWorkspaceState(
                    draftTarget = target,
                    editorVisible = true,
                ),
            )
        }
        viewModelScope.launch { loadFileCopyMoveFolders(repo, move) }
    }

    fun selectFileCopyMoveTarget(profileId: String) {
        val current = _workspace.value ?: return
        val operation = current.fileCopyMove ?: return
        if (current.isPerformingAction || operation.targetProfiles.none { it.id == profileId }) return
        val next = operation.copy(
            targetProfileId = profileId,
            location = FileCopyMoveLocation("", canWrite = false),
            history = emptyList(),
            destinationBaselines = emptyMap(),
        )
        _workspace.update { it?.copy(fileCopyMove = next, fileCopyMoveFolders = Loadable.Loading) }
        viewModelScope.launch {
            runCatching { resolveFileCopyMoveRepository(next) }
                .onSuccess { loadFileCopyMoveFolders(it, next) }
                .onFailure { error ->
                    if (error is CancellationException) throw error
                    _workspace.update { workspace ->
                        workspace?.takeIf {
                            it.fileCopyMove?.targetProfileId == profileId &&
                                it.fileCopyMove.location.path.isBlank()
                        }?.copy(
                            fileCopyMoveFolders = Loadable.Failed(error.asDsmFailure()),
                        ) ?: workspace
                    }
                }
        }
    }

    fun openFileCopyMoveFolder(folder: FileItem) {
        if (!folder.isDirectory) return
        val current = _workspace.value?.fileCopyMove ?: return
        val repo = fileCopyMoveRepository(current) ?: return
        val next = current.copy(
            location = FileCopyMoveLocation(folder.path, folder.canWrite),
            history = current.history + current.location,
            destinationBaselines = current.destinationBaselines + (folder.path to folder),
        )
        _workspace.update {
            it?.copy(fileCopyMove = next, fileCopyMoveFolders = Loadable.Loading)
        }
        viewModelScope.launch { loadFileCopyMoveFolders(repo, next) }
    }

    fun goBackFileCopyMoveFolder() {
        val current = _workspace.value?.fileCopyMove ?: return
        val repo = fileCopyMoveRepository(current) ?: return
        val previous = current.history.lastOrNull() ?: return
        val next = current.copy(
            location = previous,
            history = current.history.dropLast(1),
        )
        _workspace.update {
            it?.copy(fileCopyMove = next, fileCopyMoveFolders = Loadable.Loading)
        }
        viewModelScope.launch { loadFileCopyMoveFolders(repo, next) }
    }

    fun retryFileCopyMoveFolders() {
        val move = _workspace.value?.fileCopyMove ?: return
        _workspace.update { it?.copy(fileCopyMoveFolders = Loadable.Loading) }
        viewModelScope.launch {
            runCatching { resolveFileCopyMoveRepository(move) }
                .onSuccess { loadFileCopyMoveFolders(it, move) }
                .onFailure { error ->
                    if (error is CancellationException) throw error
                    _workspace.update { current ->
                        current?.takeIf {
                            it.fileCopyMove?.targetProfileId == move.targetProfileId &&
                                it.fileCopyMove.location.path == move.location.path
                        }?.copy(
                            fileCopyMoveFolders = Loadable.Failed(error.asDsmFailure()),
                        ) ?: current
                    }
                }
        }
    }

    fun cancelFileCopyMove() {
        if (_workspace.value?.fileStationMutationState?.mutationInProgress == true) return
        _workspace.update {
            it?.copy(
                fileCopyMove = null,
                fileCopyMoveFolders = Loadable.Idle,
                fileStationMutationState = FileStationMutationWorkspaceState(),
            )
        }
    }

    fun continueEditingFileStationMutation(): Boolean = synchronized(fileStationMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.fileStationMutationState
        if (!canContinueEditingFileStationMutation(state)) return false
        val draft = state.draftTarget ?: state.target ?: return false
        val isNameEditor = draft.operation in setOf(
            FileStationMutationOperation.CREATE_FOLDER,
            FileStationMutationOperation.RENAME,
        )
        val isCopyMove = draft.operation in setOf(
            FileStationMutationOperation.COPY,
            FileStationMutationOperation.MOVE,
        )
        val hasMatchingPicker = when (draft.module) {
            Module.PHOTOS -> current.photoMove?.item?.file == draft.sourceBaselines.singleOrNull()
            else -> current.fileCopyMove?.items == draft.sourceBaselines
        }
        if (isCopyMove && !hasMatchingPicker) return false
        fileStationMutationGeneration.incrementAndGet()
        _workspace.value = current.copy(
            isPerformingAction = false,
            fileStationMutationState = FileStationMutationWorkspaceState(
                draftTarget = draft,
                editorVisible = isNameEditor || isCopyMove,
                nameDraft = draft.requestedName.orEmpty(),
                editorParentBaseline = draft.parentBaseline,
                editorSourceBaseline = draft.sourceBaselines.singleOrNull(),
            ),
        )
        true
    }

    fun dismissFileStationMutationResult(discardDraft: Boolean = false): Boolean =
        synchronized(fileStationMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.fileStationMutationState
            if (state.mutationInProgress || state.mutationRefreshInProgress) return false
            val result = state.mutationResult
            if (!state.mutationRefreshCompleted &&
                (state.mutationFailure != null || state.mutationRefreshFailure != null ||
                    result?.let(::destructiveServiceMutationRequiresRefreshBeforeDismiss) == true)
            ) return false
            fileStationMutationGeneration.incrementAndGet()
            val discardedPickerTarget = (state.draftTarget ?: state.target).takeIf { target ->
                discardDraft && target?.operation in setOf(
                    FileStationMutationOperation.COPY,
                    FileStationMutationOperation.MOVE,
                )
            }
            val discardedFileDelete = discardDraft &&
                (state.draftTarget ?: state.target)?.let { target ->
                    target.module == Module.FILES &&
                        target.operation == FileStationMutationOperation.DELETE
                } == true
            _workspace.value = current.copy(
                fileBrowser = if (discardedFileDelete &&
                    shouldClearFileSelectionAfterDelete(result, userDiscarded = true)
                ) {
                    current.fileBrowser.clearSelection()
                } else {
                    current.fileBrowser
                },
                fileCopyMove = current.fileCopyMove.takeUnless {
                    discardedPickerTarget?.module == Module.FILES
                },
                fileCopyMoveFolders = if (discardedPickerTarget?.module == Module.FILES) {
                    Loadable.Idle
                } else {
                    current.fileCopyMoveFolders
                },
                photoMove = current.photoMove.takeUnless {
                    discardedPickerTarget?.module == Module.PHOTOS
                },
                photoMoveFolders = if (discardedPickerTarget?.module == Module.PHOTOS) {
                    Loadable.Idle
                } else {
                    current.photoMoveFolders
                },
                fileStationMutationState = if (discardDraft) {
                    FileStationMutationWorkspaceState()
                } else {
                    FileStationMutationWorkspaceState(draftTarget = state.draftTarget)
                },
            )
            true
        }

    fun refreshFileStationMutation(): Boolean {
        val claimAndRefresh = synchronized(fileStationMutationLock) {
            val repo = repository ?: return false
            val current = _workspace.value ?: return false
            val state = current.fileStationMutationState
            val target = state.target ?: return false
            if (state.mutationInProgress || state.mutationRefreshInProgress ||
                state.mutationResult == null && state.mutationFailure == null &&
                state.mutationRefreshFailure == null
            ) return false
            val refresh = when (target.operation) {
                FileStationMutationOperation.TEXT_SAVE -> FileStationMutationRefresh.TEXT_PREVIEW
                FileStationMutationOperation.FAVORITE_ADD,
                FileStationMutationOperation.FAVORITE_REMOVE,
                FileStationMutationOperation.FAVORITE_ADD_BATCH,
                -> FileStationMutationRefresh.FAVORITES
                FileStationMutationOperation.SHARE_CREATE,
                FileStationMutationOperation.SHARE_DELETE,
                -> FileStationMutationRefresh.SHARE_LINKS
                else -> if (target.module == Module.PHOTOS) {
                    FileStationMutationRefresh.PHOTOS
                } else {
                    FileStationMutationRefresh.FILE_BROWSER
                }
            }
            FileStationMutationClaim(
                repo,
                current.profile.id,
                target,
                state.mutationGeneration,
            ) to refresh
        }
        viewModelScope.launch {
            refreshFileStationMutation(claimAndRefresh.first, claimAndRefresh.second)
        }
        return true
    }

    fun cancelPendingFileStationMutation(): Boolean = synchronized(fileStationMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.fileStationMutationState
        if (state.mutationInProgress || state.mutationRefreshInProgress) return false
        val draft = state.draftTarget
        val copyMoveConfirmation = state.confirmationRequested &&
            draft?.operation in setOf(
                FileStationMutationOperation.COPY,
                FileStationMutationOperation.MOVE,
            ) && when (draft?.module) {
                Module.PHOTOS -> current.photoMove != null
                else -> current.fileCopyMove != null
            }
        fileStationMutationGeneration.incrementAndGet()
        _workspace.value = if (copyMoveConfirmation) {
            current.copy(
                fileStationMutationState = FileStationMutationWorkspaceState(
                    draftTarget = state.draftTarget,
                    editorVisible = true,
                ),
            )
        } else {
            current.copy(fileStationMutationState = FileStationMutationWorkspaceState())
        }
        true
    }

    fun confirmFileCopyMove(): Boolean {
        if (_workspace.value?.fileStationMutationState?.confirmationRequested != true &&
            !requestFileCopyMoveConfirmation()
        ) return false
        val current = _workspace.value ?: return false
        val operation = current.fileCopyMove ?: return false
        if (!operation.location.canWrite) return false
        val destinationBaseline = operation.destinationBaselines[operation.location.path] ?: return false
        val target = FileStationMutationTarget(
            profileId = current.profile.id,
            module = Module.FILES,
            operation = if (operation.operation == FileCopyMoveOperation.COPY) {
                FileStationMutationOperation.COPY
            } else {
                FileStationMutationOperation.MOVE
            },
            sourceBaselines = operation.items,
            destinationPath = operation.location.path,
            destinationBaseline = destinationBaseline,
        )
        return fileStationMutation(
            target,
            FileStationMutationRefresh.FILE_BROWSER,
            ::fileCopyMoveMessageResource,
            verifyOnRefresh = operation.targetProfileId == operation.sourceProfileId,
            applyResult = { workspace, result ->
                workspace.copy(
                    fileBrowser = if (result.submitted || result.counts.succeeded > 0) {
                        workspace.fileBrowser.clearSelection()
                    } else {
                        workspace.fileBrowser
                    },
                    fileCopyMove = if (result.submitted) null else workspace.fileCopyMove,
                    fileCopyMoveFolders = if (result.submitted) Loadable.Idle
                    else workspace.fileCopyMoveFolders,
                )
            },
        ) { repo ->
            if (operation.targetProfileId == operation.sourceProfileId) {
                when (operation.operation) {
                    FileCopyMoveOperation.COPY -> repo.copyResult(operation.items, destinationBaseline)
                    FileCopyMoveOperation.MOVE -> repo.moveResult(operation.items, destinationBaseline)
                }
            } else {
                val targetRepository = checkNotNull(fileCopyMoveRepository(operation))
                crossNasTransferCoordinator.transfer(
                    source = RepositoryCrossNasTransferEndpoint(repo),
                    target = RepositoryCrossNasTransferEndpoint(targetRepository),
                    items = operation.items,
                    destination = destinationBaseline,
                    moveSource = operation.operation == FileCopyMoveOperation.MOVE,
                )
            }
        }
    }

    fun requestFileCopyMoveConfirmation(): Boolean = synchronized(fileStationMutationLock) {
        val current = _workspace.value ?: return false
        val picker = current.fileCopyMove ?: return false
        val destination = picker.destinationBaselines[picker.location.path] ?: return false
        val state = current.fileStationMutationState
        if (!state.editorVisible || state.mutationInProgress || !picker.location.canWrite) return false
        _workspace.value = current.copy(
            fileStationMutationState = state.copy(
                draftTarget = FileStationMutationTarget(
                    profileId = current.profile.id,
                    module = Module.FILES,
                    operation = if (picker.operation == FileCopyMoveOperation.COPY) {
                        FileStationMutationOperation.COPY
                    } else FileStationMutationOperation.MOVE,
                    sourceBaselines = picker.items,
                    destinationPath = destination.path,
                    destinationBaseline = destination,
                ),
                editorVisible = false,
                confirmationRequested = true,
            ),
        )
        true
    }

    fun addFavorite(item: FileItem) {
        val current = _workspace.value ?: return
        val target = FileStationMutationTarget(
            profileId = current.profile.id,
            module = current.selectedModule,
            operation = FileStationMutationOperation.FAVORITE_ADD,
            sourceBaselines = listOf(item),
        )
        fileStationMutation(
            target,
            FileStationMutationRefresh.FAVORITES,
            ::fileStationFavoriteMessageResource,
        ) { repo -> repo.addFavoriteResult(item) }
    }

    fun removeFavorite(item: FileItem) {
        val current = _workspace.value ?: return
        val target = FileStationMutationTarget(
            profileId = current.profile.id,
            module = current.selectedModule,
            operation = FileStationMutationOperation.FAVORITE_REMOVE,
            sourceBaselines = listOf(item),
        )
        fileStationMutation(
            target,
            FileStationMutationRefresh.FAVORITES,
            ::fileStationFavoriteMessageResource,
        ) { repo -> repo.removeFavoriteResult(item) }
    }

    fun loadFileShareLinks() {
        val repo = repository ?: return
        _workspace.update { it?.copy(fileShareLinks = Loadable.Loading) }
        viewModelScope.launch {
            capture(
                block = repo::listShareLinks,
                update = { value -> _workspace.update { it?.copy(fileShareLinks = value) } },
            )
        }
    }

    fun copyFileShareLink(link: FileShareLink) {
        val application = getApplication<Application>()
        val clipboard = application.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(
            ClipData.newPlainText(application.getString(R.string.share_link_clip_label), link.url),
        )
        _workspace.update {
            it?.copy(message = application.getString(R.string.share_link_existing_copied))
        }
    }

    /** 仅复制当前资料可恢复的固定页或已加密映射的不透明对象页。 */
    internal fun canCopyCurrentPageLink(): Boolean = _workspace.value
        ?.pageLinkDestination()
        ?.let { it !is WorkspacePageLinkDestination.Unavailable }
        ?: false

    fun copyCurrentPageLink() {
        val state = _workspace.value ?: return
        val uri = when (val destination = state.pageLinkDestination()) {
            is WorkspacePageLinkDestination.Fixed -> destination.uri
            is WorkspacePageLinkDestination.Opaque -> store.issueOpaqueWorkspaceTarget(
                profileId = state.profile.id,
                target = destination.target,
            )?.let(::opaqueObjectExternalWorkspaceUri)

            WorkspacePageLinkDestination.Unavailable -> null
        }
        val application = getApplication<Application>()
        if (uri == null) {
            _workspace.update { current ->
                current?.takeIf { it.profile.id == state.profile.id }?.copy(
                    message = application.getString(R.string.page_link_unavailable),
                ) ?: current
            }
            return
        }
        val clipboard = application.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(
            ClipData.newPlainText(application.getString(R.string.copy_page_link), uri),
        )
        _workspace.update { current ->
            current?.takeIf { it.profile.id == state.profile.id }?.copy(
                message = application.getString(R.string.page_link_copied),
            ) ?: current
        }
    }

    fun requestFileShareLinkCreation(item: FileItem): Boolean {
        if (!item.canRead) return false
        val current = _workspace.value ?: return false
        return requestFileStationLifecycleMutation(
            FileStationMutationTarget(
                profileId = current.profile.id,
                module = Module.FILES,
                operation = FileStationMutationOperation.SHARE_CREATE,
                sourceBaselines = listOf(item),
            ),
        )
    }

    fun requestFileShareLinkDeletion(ids: List<String>): Boolean {
        val current = _workspace.value ?: return false
        val links = (current.fileShareLinks as? Loadable.Ready)?.value
            ?.filter { it.id in ids.toSet() }
            .orEmpty()
        if (links.isEmpty() || links.size != ids.distinct().size) return false
        return requestFileStationLifecycleMutation(
            FileStationMutationTarget(
                profileId = current.profile.id,
                module = Module.FILES,
                operation = FileStationMutationOperation.SHARE_DELETE,
                shareLinkBaselines = links,
            ),
        )
    }

    private fun executeFileShareLinkDeletion(target: FileStationMutationTarget): Boolean {
        val links = target.shareLinkBaselines
        return fileStationMutation(
            target,
            FileStationMutationRefresh.SHARE_LINKS,
            ::shareLinkDeleteMessageResource,
        ) { repo -> repo.deleteShareLinksResult(links.map(FileShareLink::id), links) }
    }

    fun requestFileRestore(item: FileItem): Boolean {
        val current = _workspace.value ?: return false
        return requestFileStationLifecycleMutation(
            FileStationMutationTarget(
                profileId = current.profile.id,
                module = Module.FILES,
                operation = FileStationMutationOperation.RESTORE,
                sourceBaselines = listOf(item),
            ),
        )
    }

    private fun executeFileRestore(target: FileStationMutationTarget): Boolean {
        val item = target.sourceBaselines.single()
        return fileStationMutation(
            target,
            if (target.module == Module.PHOTOS) {
                FileStationMutationRefresh.PHOTOS
            } else {
                FileStationMutationRefresh.FILE_BROWSER
            },
            ::fileRestoreMessageResource,
        ) { repo -> repo.restoreFromRecycleResult(item) }
    }

    fun requestPhotoShareLinkCreation(item: PhotoItem): Boolean {
        if (!item.file.canRead) return false
        val current = _workspace.value ?: return false
        return requestFileStationLifecycleMutation(
            FileStationMutationTarget(
                profileId = current.profile.id,
                module = Module.PHOTOS,
                operation = FileStationMutationOperation.SHARE_CREATE,
                sourceBaselines = listOf(item.file),
            ),
        )
    }

    fun requestPhotoRestore(item: PhotoItem): Boolean {
        val current = _workspace.value ?: return false
        return requestFileStationLifecycleMutation(
            FileStationMutationTarget(
                profileId = current.profile.id,
                module = Module.PHOTOS,
                operation = FileStationMutationOperation.RESTORE,
                sourceBaselines = listOf(item.file),
            ),
        )
    }

    fun requestPhotoDeletion(item: PhotoItem): Boolean {
        if (!item.file.canDelete) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.photo_delete_not_allowed))
            }
            return false
        }
        val current = _workspace.value ?: return false
        return requestFileStationLifecycleMutation(
            FileStationMutationTarget(
                profileId = current.profile.id,
                module = Module.PHOTOS,
                operation = FileStationMutationOperation.DELETE,
                sourceBaselines = listOf(item.file),
            ),
        )
    }

    private fun executePhotoMove(target: FileStationMutationTarget): Boolean {
        if (target.module != Module.PHOTOS) return false
        val source = target.sourceBaselines.singleOrNull() ?: return false
        val destination = target.destinationBaseline ?: return false
        return fileStationMutation(
            target,
            FileStationMutationRefresh.PHOTOS,
            ::photoMoveMessageResource,
            applyResult = { workspace, result ->
                workspace.copy(
                    photoMove = if (result.submitted) null else workspace.photoMove,
                    photoMoveFolders = if (result.submitted) {
                        Loadable.Idle
                    } else {
                        workspace.photoMoveFolders
                    },
                )
            },
        ) { repo -> repo.moveResult(listOf(source), destination) }
    }

    private fun executeFileStationDeletion(target: FileStationMutationTarget): Boolean {
        return fileStationMutation(
            target,
            if (target.module == Module.PHOTOS) {
                FileStationMutationRefresh.PHOTOS
            } else {
                FileStationMutationRefresh.FILE_BROWSER
            },
            if (target.module == Module.PHOTOS) {
                ::photoDeleteMessageResource
            } else {
                ::fileDeleteMutationMessageResource
            },
            messageText = if (target.module == Module.FILES) {
                ::fileDeleteResultMessage
            } else {
                null
            },
            applyResult = { workspace, result ->
                workspace.copy(
                    fileBrowser = if (target.module == Module.FILES &&
                        shouldClearFileSelectionAfterDelete(result)
                    ) {
                        workspace.fileBrowser.clearSelection()
                    } else {
                        workspace.fileBrowser
                    },
                )
            },
        ) { repo -> repo.deleteResult(target.sourceBaselines) }
    }

    private fun requestFileStationLifecycleMutation(
        target: FileStationMutationTarget,
    ): Boolean = synchronized(fileStationMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.fileStationMutationState
        if (current.profile.id != target.profileId || current.selectedModule != target.module ||
            current.isPerformingAction || fileStationMutationBlocksOrdinaryLoad(state)
        ) return false
        _workspace.value = current.copy(
            fileStationMutationState = FileStationMutationWorkspaceState(
                draftTarget = target,
                confirmationRequested = true,
            ),
        )
        true
    }

    fun confirmFileStationLifecycleMutation(): Boolean {
        val target = _workspace.value?.fileStationMutationState?.draftTarget ?: return false
        if (_workspace.value?.fileStationMutationState?.confirmationRequested != true) return false
        return when (target.operation) {
            FileStationMutationOperation.TEXT_SAVE -> executeTextPreviewSave(target)
            FileStationMutationOperation.MOVE -> executePhotoMove(target)
            FileStationMutationOperation.DELETE -> executeFileStationDeletion(target)
            FileStationMutationOperation.RESTORE -> executeFileRestore(target)
            FileStationMutationOperation.SHARE_CREATE ->
                createShareLinkMutation(target.sourceBaselines.single())
            FileStationMutationOperation.SHARE_DELETE -> executeFileShareLinkDeletion(target)
            else -> return false
        }
    }

    fun confirmFileStationMutation(): Boolean = confirmFileStationLifecycleMutation()

    fun cancelFileStationMutationConfirmation(): Boolean = cancelPendingFileStationMutation()

    fun prepareFileUploads(uris: List<Uri>) {
        val destination = _workspace.value?.fileBrowser?.path.orEmpty()
        if (destination.isBlank()) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.open_folder_before_upload))
            }
            return
        }
        if (uris.distinct().size > MAX_FILE_UPLOAD_BATCH) {
            _workspace.update {
                it?.copy(
                    message = getApplication<Application>().getString(
                        R.string.upload_batch_too_large,
                        MAX_FILE_UPLOAD_BATCH,
                    ),
                )
            }
            return
        }
        val selected = uris.distinct()
        if (selected.isEmpty()) return
        val claim = claimFileUploadPreflight(destination, markWorkspaceBusy = true) ?: return
        launchFileUploadPreflight(claim) {
            try {
                val sources = selected.map { uri -> uri to resolveUploadSource(uri) }
                if (sources.map { it.second.displayName.lowercase(Locale.ROOT) }.distinct().size !=
                    sources.size
                ) {
                    throw DuplicateUploadNamesException()
                }
                val conflicts = claim.repository.existingChildNames(
                    destination,
                    sources.map { it.second.displayName },
                ).size
                val accepted = synchronized(fileStationMutationLock) {
                    val current = _workspace.value ?: return@synchronized false
                    if (!fileUploadPreflightMatches(claim, current)) return@synchronized false
                    if (fileUploadPreflightBusyToken == claim.token) {
                        fileUploadPreflightBusyToken = null
                    }
                    _workspace.value = current.copy(
                        isPerformingAction = false,
                        pendingFileUploads = if (conflicts > 0) {
                            PendingFileUploads(
                                selected,
                                destination,
                                conflicts,
                                claim.token.profileId,
                                claim.token.module,
                                claim.token.generation,
                            )
                        } else {
                            null
                        },
                    )
                    true
                }
                if (accepted && conflicts == 0) {
                    queueFileUploads(selected, overwrite = false, claim = claim)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                val message = if (error is DuplicateUploadNamesException) {
                    getApplication<Application>().getString(R.string.upload_duplicate_names)
                } else if (error is DsmFailure) {
                    error.localize(getApplication<Application>()).combined
                } else {
                    getApplication<Application>().getString(R.string.upload_source_unavailable)
                }
                synchronized(fileStationMutationLock) {
                    val current = _workspace.value ?: return@synchronized
                    if (fileUploadPreflightMatches(claim, current)) {
                        if (fileUploadPreflightBusyToken == claim.token) {
                            fileUploadPreflightBusyToken = null
                        }
                        _workspace.value = current.copy(isPerformingAction = false, message = message)
                    }
                }
            }
        }
    }

    fun confirmPendingFileUploads() {
        val request = synchronized(fileStationMutationLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            val pending = current.pendingFileUploads ?: return@synchronized null
            val token = FileUploadPreflightToken(
                profileId = pending.profileId,
                module = pending.module,
                destinationPath = pending.destinationPath,
                generation = pending.generation,
            )
            _workspace.value = current.copy(pendingFileUploads = null)
            if (!current.matchesFileUploadPreflight(token, fileUploadPreflightGeneration.get())) {
                return@synchronized null
            }
            pending to FileUploadPreflightClaim(repo, token)
        } ?: return
        queueFileUploads(request.first.uris, overwrite = true, claim = request.second)
    }

    fun cancelPendingFileUploads() {
        synchronized(fileStationMutationLock) {
            invalidateFileUploadPreflights()
            _workspace.update { it?.copy(pendingFileUploads = null) }
        }
    }

    private fun queueFileUploads(
        uris: List<Uri>,
        overwrite: Boolean,
        claim: FileUploadPreflightClaim,
    ) {
        val backgroundCapable = store.session(claim.token.profileId) != null
        uris.forEach { uri ->
            launchFileUploadPreflight(claim) {
                val source = try {
                    resolveUploadSource(uri)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Throwable) {
                    synchronized(fileStationMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        if (fileUploadPreflightMatches(claim, current)) {
                            _workspace.value = current.copy(
                                message = getApplication<Application>()
                                    .getString(R.string.upload_source_unavailable),
                            )
                        }
                    }
                    return@launchFileUploadPreflight
                }
                if (!backgroundCapable) {
                    startForegroundUpload(claim, source, overwrite)
                    return@launchFileUploadPreflight
                }
                val currentBeforeGrant = synchronized(fileStationMutationLock) {
                    _workspace.value?.let { fileUploadPreflightMatches(claim, it) } == true
                }
                if (!currentBeforeGrant) return@launchFileUploadPreflight
                val grantTaken = runCatching {
                    getApplication<Application>().contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                }.isSuccess
                if (!grantTaken) {
                    startForegroundUpload(claim, source, overwrite)
                    return@launchFileUploadPreflight
                }
                var grantClaimed = false
                try {
                    synchronized(fileStationMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        if (!fileUploadPreflightMatches(claim, current)) return@synchronized
                        val record = PersistedUpload(
                            id = UUID.randomUUID().toString(),
                            profileId = claim.token.profileId,
                            sourceUri = uri.toString(),
                            title = source.displayName,
                            contentType = source.contentType,
                            expectedBytes = source.contentLength,
                            destinationPath = claim.token.destinationPath,
                            destinationRootPath = claim.token.destinationPath,
                            backupMode = false,
                            overwrite = overwrite,
                        )
                        transferStore.upsert(record)
                        grantClaimed = true
                        enqueuePersistedFileUpload(record)
                    }
                } finally {
                    if (!grantClaimed) releasePersistedReadPermission(uri)
                }
            }
        }
    }

    fun enqueueUpload(
        uri: Uri,
        overwrite: Boolean = false,
        destinationSnapshot: String? = null,
    ) {
        val destination = resolveUploadDestination(
            destinationSnapshot = destinationSnapshot,
            currentBrowserPath = _workspace.value?.fileBrowser?.path.orEmpty(),
        )
        if (destination.isBlank()) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.open_folder_before_upload))
            }
            return
        }
        val claim = claimFileUploadPreflight(destination, markWorkspaceBusy = false) ?: return
        launchFileUploadPreflight(claim) {
            val source = try {
                resolveUploadSource(uri)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                synchronized(fileStationMutationLock) {
                    val current = _workspace.value ?: return@synchronized
                    if (fileUploadPreflightMatches(claim, current)) {
                        _workspace.value = current.copy(
                            message = error.asDsmFailure()
                                .localize(getApplication<Application>())
                                .combined,
                        )
                    }
                }
                return@launchFileUploadPreflight
            }
            startForegroundUpload(claim, source, overwrite)
        }
    }

    private fun startForegroundUpload(
        claim: FileUploadPreflightClaim,
        source: UploadSource,
        overwrite: Boolean,
    ): Boolean {
        val destination = claim.token.destinationPath
        return synchronized(fileStationMutationLock) {
            val current = _workspace.value ?: return@synchronized false
            if (!fileUploadPreflightMatches(claim, current)) return@synchronized false
            val taskId = UUID.randomUUID().toString()
            val task = TransferTask(
                id = taskId,
                title = source.displayName,
                detail = getApplication<Application>().getString(R.string.transfer_waiting),
                direction = TransferDirection.UPLOAD,
                state = TransferState.WAITING,
                totalBytes = source.contentLength,
            )
            lateinit var job: Job
            job = viewModelScope.launch(start = CoroutineStart.LAZY) {
                updateFileUploadTransfer(claim, taskId) {
                    it.copy(
                        state = TransferState.RUNNING,
                        detail = getApplication<Application>().getString(R.string.transfer_uploading),
                        startedAtEpochMillis = System.currentTimeMillis(),
                    )
                }
                try {
                    val result = claim.repository.uploadResult(
                        source,
                        destination,
                        overwrite = overwrite,
                    ) { completed, total ->
                        updateFileUploadTransfer(claim, taskId) {
                            it.copy(completedBytes = completed, totalBytes = total)
                        }
                    }
                    val message = getApplication<Application>().getString(uploadMutationMessageResource(result))
                    val succeeded = result.status == MutationResultStatus.CONFIRMED_SUCCESS
                    val cancelled = result.status in setOf(
                        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    )
                    updateFileUploadTransfer(claim, taskId) {
                        it.copy(
                            state = when {
                                succeeded -> TransferState.SUCCEEDED
                                cancelled -> TransferState.CANCELLED
                                else -> TransferState.FAILED
                            },
                            completedBytes = if (succeeded) source.contentLength else it.completedBytes,
                            detail = message,
                            errorMessage = message.takeUnless { succeeded || cancelled },
                            requiresRefresh = result.requiresRefresh,
                        )
                    }
                    if ((result.submitted || result.requiresRefresh) && currentCoroutineContext().isActive &&
                        repository === claim.repository &&
                        _workspace.value?.profile?.id == claim.token.profileId &&
                        _workspace.value?.selectedModule == Module.FILES &&
                        _workspace.value?.fileBrowser?.path == destination
                    ) {
                        loadFileBrowser(claim.repository)
                    }
                    updateFileUploadWorkspaceMessage(claim, message)
                } catch (_: CancellationException) {
                    val submitted = _workspace.value?.takeIf {
                        repository === claim.repository && it.profile.id == claim.token.profileId
                    }?.transfers?.firstOrNull { it.id == taskId }?.completedBytes?.let { it > 0 } == true
                    updateFileUploadTransfer(claim, taskId) {
                        it.copy(
                            state = TransferState.CANCELLED,
                            detail = getApplication<Application>().getString(
                                if (submitted) R.string.transfer_cancelled_refresh else R.string.transfer_cancelled,
                            ),
                            requiresRefresh = submitted,
                        )
                    }
                } catch (error: Throwable) {
                    val failure = error.asDsmFailure()
                    val requiresRefresh = failure.kind in setOf(
                        DsmErrorKind.CONNECTION_FAILED,
                        DsmErrorKind.INVALID_RESPONSE,
                        DsmErrorKind.CHANGE_NOT_CONFIRMED,
                        DsmErrorKind.UPLOAD_LENGTH_MISMATCH,
                    )
                    updateFileUploadTransfer(claim, taskId) {
                        it.copy(
                            state = TransferState.FAILED,
                            detail = getApplication<Application>().getString(R.string.transfer_failed),
                            errorMessage = if (requiresRefresh) {
                                getApplication<Application>().getString(R.string.upload_unverified)
                            } else {
                                failure.localize(getApplication<Application>()).combined
                            },
                            requiresRefresh = requiresRefresh,
                        )
                    }
                }
            }
            _workspace.value = current.copy(transfers = listOf(task) + current.transfers)
            transferJobs[taskId] = job
            job.invokeOnCompletion { transferJobs.remove(taskId, job) }
            job.start()
            true
        }
    }

    private fun updateFileUploadTransfer(
        claim: FileUploadPreflightClaim,
        taskId: String,
        transform: (TransferTask) -> TransferTask,
    ) {
        synchronized(fileStationMutationLock) {
            val current = _workspace.value ?: return
            if (repository !== claim.repository || current.profile.id != claim.token.profileId) return
            _workspace.value = current.copy(
                transfers = current.transfers.map { task ->
                    if (task.id == taskId) transform(task) else task
                },
            )
        }
    }

    private fun updateFileUploadWorkspaceMessage(claim: FileUploadPreflightClaim, message: String) {
        synchronized(fileStationMutationLock) {
            val current = _workspace.value ?: return
            if (repository === claim.repository && current.profile.id == claim.token.profileId) {
                _workspace.value = current.copy(message = message)
            }
        }
    }

    private fun claimFileUploadPreflight(
        destination: String,
        markWorkspaceBusy: Boolean,
    ): FileUploadPreflightClaim? = synchronized(fileStationMutationLock) {
        val repo = repository ?: return@synchronized null
        invalidateFileUploadPreflights()
        val current = _workspace.value ?: return@synchronized null
        if (isSwitchingNas || current.selectedModule != Module.FILES ||
            current.fileBrowser.path != destination || markWorkspaceBusy && current.isPerformingAction
        ) return@synchronized null
        val token = FileUploadPreflightToken(
            profileId = current.profile.id,
            module = Module.FILES,
            destinationPath = destination,
            generation = fileUploadPreflightGeneration.get(),
        )
        if (markWorkspaceBusy) {
            fileUploadPreflightBusyToken = token
            _workspace.value = current.copy(isPerformingAction = true, message = null)
        }
        FileUploadPreflightClaim(repo, token)
    }

    private fun fileUploadPreflightMatches(
        claim: FileUploadPreflightClaim,
        current: WorkspaceState,
    ): Boolean = repository === claim.repository &&
        current.matchesFileUploadPreflight(claim.token, fileUploadPreflightGeneration.get())

    private fun launchFileUploadPreflight(
        claim: FileUploadPreflightClaim,
        block: suspend () -> Unit,
    ): Job? {
        val jobId = UUID.randomUUID().toString()
        lateinit var job: Job
        job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            try {
                block()
            } finally {
                synchronized(fileStationMutationLock) {
                    fileUploadPreflightJobs.remove(jobId, job)
                }
            }
        }
        val registered = synchronized(fileStationMutationLock) {
            val current = _workspace.value
            if (current == null || !fileUploadPreflightMatches(claim, current)) {
                false
            } else {
                fileUploadPreflightJobs[jobId] = job
                true
            }
        }
        if (!registered) {
            job.cancel()
            return null
        }
        job.start()
        return job
    }

    private fun invalidateFileUploadPreflights() = synchronized(fileStationMutationLock) {
        val busyToken = fileUploadPreflightBusyToken
        val current = _workspace.value
        if (busyToken != null && current != null && current.isPerformingAction &&
            current.matchesFileUploadPreflight(
                busyToken,
                fileUploadPreflightGeneration.get(),
            )
        ) {
            _workspace.value = current.copy(isPerformingAction = false)
        }
        fileUploadPreflightBusyToken = null
        fileUploadPreflightGeneration.incrementAndGet()
        fileUploadPreflightJobs.values.forEach(Job::cancel)
        fileUploadPreflightJobs.clear()
    }

    fun enqueuePhotoBackups(uris: List<Uri>) {
        val state = _workspace.value ?: return
        if (uris.isEmpty()) return
        if (store.session(state.profile.id) == null) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.backup_requires_saved_session))
            }
            return
        }
        val destination = state.photoBrowser.folderPath
        viewModelScope.launch {
            var added = 0
            uris.distinct().forEach { uri ->
                val source = runCatching { resolveUploadSource(uri) }.getOrNull() ?: return@forEach
                val grantTaken = runCatching {
                    getApplication<Application>().contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                }.isSuccess
                if (!grantTaken) return@forEach
                val duplicate = transferStore.uploads(state.profile.id).any {
                    it.sourceUri == uri.toString() &&
                        it.destinationPath == destination &&
                        it.title == source.displayName &&
                        it.state !in setOf(TransferState.FAILED, TransferState.CANCELLED)
                }
                if (duplicate) return@forEach
                val record = PersistedUpload(
                    id = UUID.randomUUID().toString(),
                    profileId = state.profile.id,
                    sourceUri = uri.toString(),
                    title = source.displayName,
                    contentType = source.contentType,
                    expectedBytes = source.contentLength,
                    destinationPath = destination,
                )
                transferStore.upsert(record)
                enqueuePhotoBackup(record)
                added++
            }
            syncPersistedDownloads(state.profile.id)
            _workspace.update {
                it?.copy(
                    message = if (added > 0) {
                        getApplication<Application>().getString(R.string.photo_backup_queued, added)
                    } else {
                        getApplication<Application>().getString(R.string.photo_backup_nothing_queued)
                    },
                )
            }
        }
    }

    fun configurePhotoBackupSource(treeUri: Uri) {
        val state = _workspace.value ?: return
        if (store.session(state.profile.id) == null) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.backup_requires_saved_session))
            }
            return
        }
        val resolver = getApplication<Application>().contentResolver
        val hasPersistedReadGrant = resolver.persistedUriPermissions.any { permission ->
            permission.uri == treeUri && permission.isReadPermission
        }
        val acquiredPersistedReadGrant = !hasPersistedReadGrant && runCatching {
            resolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }.isSuccess
        if (!hasPersistedReadGrant && !acquiredPersistedReadGrant) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.photo_backup_folder_permission_failed))
            }
            return
        }
        val previous = transferStore.photoBackupSource(state.profile.id)
        val source = PersistedPhotoBackupSource(
            profileId = state.profile.id,
            treeUri = treeUri.toString(),
            destinationPath = state.photoBrowser.folderPath,
        )
        if (!schedulePhotoBackupSource(source)) {
            if (acquiredPersistedReadGrant) releasePersistedReadPermission(treeUri)
            _workspace.update {
                it?.copy(
                    message = getApplication<Application>().getString(
                        R.string.photo_backup_source_state_unavailable,
                    ),
                )
            }
            return
        }
        previous?.treeUri?.takeIf { it != source.treeUri }?.let { oldTree ->
            val stillUsed = transferStore.uploads(state.profile.id).any { it.sourceTreeUri == oldTree }
            if (!stillUsed) releasePersistedReadPermission(Uri.parse(oldTree))
        }
        _workspace.update {
            it?.copy(
                photoBackupSourceEnabled = true,
                message = getApplication<Application>().getString(R.string.photo_backup_folder_enabled),
            )
        }
    }

    fun enqueueFileTree(treeUri: Uri) {
        val state = _workspace.value ?: return
        val destinationRoot = state.fileBrowser.path
        if (destinationRoot.isBlank()) return
        if (store.session(state.profile.id) == null) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.folder_upload_requires_saved_session))
            }
            return
        }
        val granted = runCatching {
            getApplication<Application>().contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }.isSuccess
        if (!granted) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.folder_upload_permission_failed))
            }
            return
        }
        viewModelScope.launch {
            _workspace.update { it?.copy(isPerformingAction = true, message = null) }
            runCatching {
                withContext(Dispatchers.IO) {
                    scanDocumentTree(
                        getApplication(),
                        treeUri,
                        MAX_FILE_TREE_DOCUMENTS,
                    ) { true }
                }
            }.onSuccess { scan ->
                if (scan.truncated) {
                    releasePersistedReadPermission(treeUri)
                    _workspace.update {
                        it?.copy(
                            isPerformingAction = false,
                            message = getApplication<Application>().getString(
                                R.string.folder_upload_too_large,
                                MAX_FILE_TREE_DOCUMENTS,
                            ),
                        )
                    }
                    return@onSuccess
                }
                if (scan.files.isEmpty()) {
                    releasePersistedReadPermission(treeUri)
                    _workspace.update {
                        it?.copy(
                            isPerformingAction = false,
                            message = getApplication<Application>().getString(R.string.folder_upload_empty),
                        )
                    }
                    return@onSuccess
                }
                val existing = transferStore.uploads(state.profile.id)
                var queued = 0
                scan.files.forEach { item ->
                    val destination = backupDestination(destinationRoot, item.relativeFolder)
                    val duplicate = existing.any {
                        it.sourceUri == item.uri.toString() &&
                            it.destinationPath == destination &&
                            it.state !in TERMINAL_TRANSFER_STATES
                    }
                    if (duplicate) return@forEach
                    val record = PersistedUpload(
                        id = UUID.randomUUID().toString(),
                        profileId = state.profile.id,
                        sourceUri = item.uri.toString(),
                        title = item.name,
                        contentType = item.mimeType,
                        expectedBytes = item.size,
                        destinationPath = destination,
                        destinationRootPath = destinationRoot,
                        ownsPersistedReadGrant = false,
                        sourceTreeUri = treeUri.toString(),
                        backupMode = false,
                        overwrite = false,
                        mirrorDirectories = true,
                    )
                    transferStore.upsert(record)
                    enqueuePersistedFileUpload(record)
                    queued++
                }
                _workspace.update {
                    it?.copy(
                        isPerformingAction = false,
                        message = getApplication<Application>().getString(
                            R.string.folder_upload_queued,
                            queued,
                        ),
                    )
                }
            }.onFailure {
                releasePersistedReadPermission(treeUri)
                _workspace.update {
                    it?.copy(
                        isPerformingAction = false,
                        message = getApplication<Application>().getString(R.string.folder_upload_scan_failed),
                    )
                }
            }
        }
    }

    fun disablePhotoBackupSource() {
        val state = _workspace.value ?: return
        val source = transferStore.photoBackupSource(state.profile.id) ?: return
        if (
            runCatching {
                transferStore.upsertPhotoBackupSource(source.copy(enabled = false, workId = null))
            }.isFailure
        ) {
            _workspace.update {
                it?.copy(
                    message = getApplication<Application>().getString(
                        R.string.photo_backup_source_state_unavailable,
                    ),
                )
            }
            return
        }
        cancelPhotoBackupSourceWork(state.profile.id)
        _workspace.update {
            it?.copy(
                photoBackupSourceEnabled = false,
                message = getApplication<Application>().getString(R.string.photo_backup_folder_disabled),
            )
        }
    }

    internal fun enqueueDownload(item: FileItem, destination: Uri): DownloadEnqueueResult {
        val repo = repository ?: run {
            deleteIncompleteDownload(destination)
            return DownloadEnqueueResult.REJECTED
        }
        val state = _workspace.value ?: run {
            deleteIncompleteDownload(destination)
            return DownloadEnqueueResult.REJECTED
        }
        if (!item.canRead) {
            deleteIncompleteDownload(destination)
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.download_not_allowed))
            }
            return DownloadEnqueueResult.REJECTED
        }
        val resolver = getApplication<Application>().contentResolver
        val hasPersistedWriteGrant = resolver.persistedUriPermissions.any { permission ->
            permission.uri == destination && permission.isWritePermission
        }
        val acquiredPersistedWriteGrant = !hasPersistedWriteGrant && runCatching {
            resolver.takePersistableUriPermission(
                destination,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }.isSuccess
        val persistableGrantAvailable = hasPersistedWriteGrant || acquiredPersistedWriteGrant
        val destinationWritable = runCatching {
            resolver.openFileDescriptor(destination, "rw")?.use { true } ?: false
        }.getOrDefault(false)
        if (!destinationWritable) {
            if (acquiredPersistedWriteGrant) {
                runCatching {
                    resolver.releasePersistableUriPermission(
                        destination,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                }
            }
            deleteIncompleteDownload(destination)
            _workspace.update {
                it?.copy(
                    message = getApplication<Application>().getString(
                        R.string.download_destination_not_writable,
                    ),
                )
            }
            return DownloadEnqueueResult.REJECTED
        }
        val taskId = UUID.randomUUID().toString()
        val savedSessionAvailable = store.session(state.profile.id) != null
        val backgroundCapable = canRunDownloadInBackground(
            savedSessionAvailable = savedSessionAvailable,
            persistableDestinationGrant = persistableGrantAvailable,
        )
        val backgroundRequest = if (backgroundCapable) {
            backgroundDownloadRequest(taskId, requireExactResume = false)
        } else {
            null
        }
        val record = PersistedDownload(
            id = taskId,
            profileId = state.profile.id,
            sourcePath = item.path,
            title = item.name,
            destinationUri = destination.toString(),
            isDirectory = item.isDirectory,
            expectedBytes = item.size.takeIf { !item.isDirectory && it > 0 },
            backgroundCapable = backgroundCapable,
            workId = backgroundRequest?.id?.toString(),
        )
        val persisted = if (backgroundCapable) {
            runCatching { transferStore.upsertDownloadDurably(record) }.getOrDefault(false)
        } else {
            runCatching {
                transferStore.upsert(record)
                true
            }.getOrDefault(false)
        }
        if (!persisted) {
            if (acquiredPersistedWriteGrant) {
                runCatching {
                    resolver.releasePersistableUriPermission(
                        destination,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                }
            }
            deleteIncompleteDownload(destination)
            _workspace.update {
                it?.copy(
                    message = getApplication<Application>().getString(R.string.download_state_unavailable),
                )
            }
            return DownloadEnqueueResult.REJECTED
        }
        syncPersistedDownloads(state.profile.id)
        return if (backgroundCapable) {
            enqueuePersistedBackgroundDownload(
                record = record,
                request = checkNotNull(backgroundRequest),
                existingWorkPolicy = transferEnqueuePolicy(TransferEnqueueReason.INITIAL),
            )
            DownloadEnqueueResult.BACKGROUND
        } else {
            enqueueForegroundDownload(repo, record, destination)
            DownloadEnqueueResult.FOREGROUND
        }
    }

    fun discardUnmatchedDownloadDestination(destination: Uri) {
        deleteIncompleteDownload(destination)
        _workspace.update {
            it?.copy(
                message = getApplication<Application>().getString(
                    R.string.download_request_context_lost,
                ),
            )
        }
    }

    fun prepareUpload(): Boolean {
        val state = _workspace.value ?: return false
        val message = when {
            state.isPerformingAction -> return false
            state.fileBrowser.path.isBlank() -> R.string.open_folder_before_upload
            !state.supportsUploads -> R.string.upload_not_available
            else -> return true
        }
        _workspace.update {
            it?.copy(message = getApplication<Application>().getString(message))
        }
        return false
    }

    fun fileUploadsUseBackgroundWork(): Boolean =
        _workspace.value?.profile?.id?.let(store::session) != null

    fun selectPhotoSpace(spaceId: String) {
        cancelOpaqueExternalNavigation(consumePending = true)
        val state = _workspace.value ?: return
        val next = state.photoBrowser.selectSpace(spaceId)
        if (next == state.photoBrowser) return
        photoTimelineJob?.cancel()
        _workspace.update {
            it?.copy(
                photoBrowser = next,
                photos = Loadable.Idle,
                photoTimeline = Loadable.Idle,
            )
        }
        load(Module.PHOTOS)
    }

    fun openPhotoFolder(item: PhotoItem) {
        if (item.kind != PhotoItemKind.FOLDER) return
        cancelOpaqueExternalNavigation(consumePending = true)
        val repo = repository ?: return
        _workspace.update {
            it?.copy(
                photoBrowser = it.photoBrowser.enterFolder(item.file.path),
                photos = Loadable.Loading,
            )
        }
        viewModelScope.launch { loadPhotoPage(repo, reset = true) }
    }

    fun goBackPhotoFolder() {
        cancelOpaqueExternalNavigation(consumePending = true)
        val browser = _workspace.value?.photoBrowser ?: return
        if (browser.mode != PhotoBrowseMode.FOLDERS) return
        val previous = browser.navigateUp() ?: return
        _workspace.update { it?.copy(photoBrowser = previous, photos = Loadable.Loading) }
        repository?.let { repo ->
            viewModelScope.launch { loadPhotoPage(repo, reset = true) }
        }
    }

    fun updatePhotoSearchQuery(query: String) {
        _workspace.update {
            it?.copy(photoBrowser = it.photoBrowser.copy(searchQuery = query))
        }
    }

    fun searchPhotos() {
        _workspace.update {
            it?.copy(photoBrowser = it.photoBrowser.submitSearch())
        }
    }

    fun setPhotoFilter(filter: PhotoMediaFilter) {
        _workspace.update {
            it?.copy(photoBrowser = it.photoBrowser.copy(filter = filter))
        }
    }

    fun setPhotoMode(mode: PhotoBrowseMode) {
        val current = _workspace.value ?: return
        if (current.photoBrowser.mode == mode) return
        if (mode == PhotoBrowseMode.FOLDERS) photoTimelineJob?.cancel()
        _workspace.update {
            it?.copy(
                photoBrowser = it.photoBrowser.copy(
                    mode = mode,
                    selectedYear = null,
                    selectedMonth = null,
                ),
            )
        }
        load(Module.PHOTOS)
    }

    fun selectPhotoYear(year: Int?) {
        _workspace.update {
            it?.copy(photoBrowser = it.photoBrowser.selectYear(year))
        }
    }

    fun selectPhotoMonth(month: Int?) {
        _workspace.update {
            it?.copy(photoBrowser = it.photoBrowser.selectMonth(month))
        }
    }

    fun clearPhotoFilters() {
        _workspace.update {
            it?.copy(
                photoBrowser = it.photoBrowser.copy(
                    searchQuery = "",
                    activeSearchQuery = null,
                    filter = PhotoMediaFilter.ALL,
                    selectedYear = null,
                    selectedMonth = null,
                ),
            )
        }
    }

    fun beginPhotoMove(item: PhotoItem) {
        val repo = repository ?: return
        val workspace = _workspace.value ?: return
        if (workspace.selectedModule != Module.PHOTOS || workspace.isPerformingAction ||
            fileStationMutationBlocksOrdinaryLoad(workspace.fileStationMutationState)
        ) return
        if (!workspace.supportsCopyMove) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.photo_move_unavailable))
            }
            return
        }
        val space = workspace.photoBrowser.spaces.firstOrNull { candidate ->
            item.file.path == candidate.rootPath || item.file.path.startsWith("${candidate.rootPath}/")
        } ?: return
        val move = PhotoMoveState(
            item = item,
            space = space,
            location = PhotoMoveLocation(space.rootPath, canWrite = false),
        )
        _workspace.update {
            it?.copy(
                photoMove = move,
                photoMoveFolders = Loadable.Loading,
                fileStationMutationState = FileStationMutationWorkspaceState(
                    draftTarget = FileStationMutationTarget(
                        profileId = workspace.profile.id,
                        module = Module.PHOTOS,
                        operation = FileStationMutationOperation.MOVE,
                        sourceBaselines = listOf(item.file),
                    ),
                    editorVisible = true,
                ),
            )
        }
        viewModelScope.launch { loadPhotoMoveFolders(repo, move) }
    }

    fun openPhotoMoveFolder(folder: PhotoItem) {
        if (folder.kind != PhotoItemKind.FOLDER) return
        val repo = repository ?: return
        val current = _workspace.value?.photoMove ?: return
        if (folder.file.path != current.space.rootPath &&
            !folder.file.path.startsWith("${current.space.rootPath}/")
        ) return
        val next = current.copy(
            location = PhotoMoveLocation(
                folder.file.path,
                folder.file.canWrite,
                baseline = folder.file,
            ),
            history = current.history + current.location,
        )
        _workspace.update {
            it?.copy(photoMove = next, photoMoveFolders = Loadable.Loading)
        }
        viewModelScope.launch { loadPhotoMoveFolders(repo, next) }
    }

    fun goBackPhotoMoveFolder() {
        val repo = repository ?: return
        val current = _workspace.value?.photoMove ?: return
        val previous = current.history.lastOrNull() ?: return
        val next = current.copy(
            location = previous,
            history = current.history.dropLast(1),
        )
        _workspace.update {
            it?.copy(photoMove = next, photoMoveFolders = Loadable.Loading)
        }
        viewModelScope.launch { loadPhotoMoveFolders(repo, next) }
    }

    fun retryPhotoMoveFolders() {
        val repo = repository ?: return
        val move = _workspace.value?.photoMove ?: return
        _workspace.update { it?.copy(photoMoveFolders = Loadable.Loading) }
        viewModelScope.launch { loadPhotoMoveFolders(repo, move) }
    }

    fun cancelPhotoMove() {
        if (_workspace.value?.fileStationMutationState?.mutationInProgress == true) return
        _workspace.update {
            it?.copy(
                photoMove = null,
                photoMoveFolders = Loadable.Idle,
                fileStationMutationState = FileStationMutationWorkspaceState(),
            )
        }
    }

    fun requestPhotoMoveConfirmation(): Boolean = synchronized(fileStationMutationLock) {
        val current = _workspace.value ?: return false
        val move = current.photoMove ?: return false
        val state = current.fileStationMutationState
        if (current.selectedModule != Module.PHOTOS || !state.editorVisible ||
            state.mutationInProgress || current.isPerformingAction
        ) return false
        if (!move.location.canWrite) {
            _workspace.value = current.copy(
                message = getApplication<Application>().getString(R.string.photo_move_destination_read_only),
            )
            return false
        }
        if (move.item.file.path.substringBeforeLast('/', "") == move.location.path) {
            _workspace.value = current.copy(
                message = getApplication<Application>().getString(R.string.photo_move_same_folder),
            )
            return false
        }
        val destination = move.location.baseline
            ?.takeIf { it.isDirectory && it.path == move.location.path && it.canWrite }
            ?: return false
        _workspace.value = current.copy(
            message = null,
            fileStationMutationState = state.copy(
                draftTarget = FileStationMutationTarget(
                    profileId = current.profile.id,
                    module = Module.PHOTOS,
                    operation = FileStationMutationOperation.MOVE,
                    sourceBaselines = listOf(move.item.file),
                    destinationPath = destination.path,
                    destinationBaseline = destination,
                ),
                editorVisible = false,
                confirmationRequested = true,
            ),
        )
        true
    }

    fun loadMorePhotos() {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        val page = (state.photos as? Loadable.Ready)?.value ?: return
        if (!page.hasMore || state.photoBrowser.isLoadingMore) return
        _workspace.update {
            it?.copy(photoBrowser = it.photoBrowser.copy(isLoadingMore = true))
        }
        viewModelScope.launch { loadPhotoPage(repo, reset = false) }
    }

    fun thumbnail(path: String, profileId: String): Bitmap? = thumbnailCache.get(thumbnailKey(profileId, path))

    fun acquireThumbnail(item: FileItem, profileId: String) {
        if (item.previewKind() !in setOf(FilePreviewKind.IMAGE, FilePreviewKind.VIDEO) ||
            _workspace.value?.supportsThumbnails != true
        ) {
            return
        }
        val key = thumbnailKey(profileId, item.path)
        thumbnailReferences[key] = (thumbnailReferences[key] ?: 0) + 1
        if (thumbnailCache.get(key) != null || thumbnailJobs.containsKey(key)) return
        val repo = repository ?: return
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            runCatching {
                val cacheFile = thumbnailDiskFile(key)
                val bytes = withContext(Dispatchers.IO) {
                    loadCachedThumbnailBytes(
                        cacheFile = cacheFile,
                        fetch = { repo.thumbnail(item.path) },
                        isValid = ::canDecodeThumbnail,
                    ).also {
                        pruneThumbnailDiskCache()
                    }
                }
                withContext(Dispatchers.Default) {
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                        ?: throw DsmFailure(
                            null,
                            "The thumbnail could not be decoded",
                            "Open the file to try the full preview.",
                            kind = DsmErrorKind.INVALID_RESPONSE,
                        )
                }
            }.onSuccess { bitmap ->
                thumbnailCache.put(key, bitmap)
                _workspace.update {
                    it?.copy(thumbnailGeneration = it.thumbnailGeneration + 1)
                }
            }
        }
        thumbnailJobs[key] = job
        job.invokeOnCompletion {
            viewModelScope.launch {
                thumbnailJobs.removeIfSame(key, job)
            }
        }
        job.start()
    }

    fun releaseThumbnail(path: String, profileId: String) {
        val key = thumbnailKey(profileId, path)
        val remaining = (thumbnailReferences[key] ?: 1) - 1
        if (remaining <= 0) {
            thumbnailReferences.remove(key)
            thumbnailJobs.remove(key)?.cancel()
        } else {
            thumbnailReferences[key] = remaining
        }
    }

    fun packageIcon(packageInfo: PackageInfo, profileId: String): Bitmap? = packageIconCache.get(
        packageIconCacheKey(
            profileId = profileId,
            packageInfo = packageInfo,
            requestedSize = PACKAGE_ICON_DISPLAY_SIZE,
        ),
    )

    /** 仅为当前可见的套件行读取图标，读取失败保留本地图标且不影响套件列表。 */
    fun loadPackageIcon(packageInfo: PackageInfo, profileId: String) {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        if (state.profile.id != profileId || state.selectedModule != Module.NAS_SETTINGS ||
            !repo.supportsPackageIcons() || packageInfo.id.isBlank() || packageInfo.version.isBlank()
        ) {
            return
        }
        val requestedSize = PACKAGE_ICON_DISPLAY_SIZE
        val key = packageIconCacheKey(profileId, packageInfo, requestedSize)
        if (packageIconCache.get(key) != null || packageIconJobs.containsKey(key)) return
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            val bitmap = try {
                val bytes = withContext(Dispatchers.IO) { repo.packageIcon(packageInfo) }
                withContext(Dispatchers.Default) { decodePackageIcon(bytes, requestedSize) }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                null
            }
            if (bitmap != null) {
                val current = _workspace.value
                if (packageIconRequestMatches(
                        repositoryMatches = repository === repo,
                        currentProfileId = current?.profile?.id,
                        currentModule = current?.selectedModule,
                        expectedProfileId = profileId,
                    )
                ) {
                    packageIconCache.put(key, bitmap)
                    _packageIconGeneration.update { it + 1 }
                } else {
                    bitmap.recycle()
                }
            }
        }
        packageIconJobs[key] = job
        job.invokeOnCompletion {
            viewModelScope.launch {
                packageIconJobs.removeIfSame(key, job)
            }
        }
        job.start()
    }

    fun clearRegenerableCaches() {
        viewModelScope.launch {
            closePreviewImmediately()
            clearPreviewCaches(preserveActiveThumbnails = true)
            withContext(Dispatchers.IO) {
                thumbnailDiskDirectory().listFiles()
                    ?.filter { it.isFile && it.extension == "bin" }
                    ?.forEach(File::delete)
            }
            refreshRegenerableCacheUsage()
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.cache_cleared))
            }
        }
    }

    private fun refreshRegenerableCacheUsage() {
        viewModelScope.launch {
            val bytes = withContext(Dispatchers.IO) {
                sequenceOf(
                    thumbnailDiskDirectory(),
                    File(getApplication<Application>().cacheDir, "preview"),
                ).sumOf { directory -> directory.listFiles()?.sumOf(File::length) ?: 0L }
            }
            _workspace.update { it?.copy(regenerableCacheBytes = bytes) }
        }
    }

    fun openPreview(item: FileItem) {
        cancelOpaqueExternalNavigation(consumePending = true)
        val state = _workspace.value ?: return
        if (state.selectedModule != Module.FILES) return
        if (state.previewOwner == PreviewOwner.FILES && state.previewItem?.path == item.path) return
        if (state.previewItem?.path != item.path && state.hasDirtyTextPreview()) {
            requestClosePreview()
            return
        }
        _workspace.update {
            it?.copy(photoViewer = null, filePreviewSequence = null, previewOwner = PreviewOwner.FILES)
        }
        startPreview(item, PreviewOwner.FILES)
    }

    fun openPreview(item: FileItem, visibleItems: List<FileItem>) {
        cancelOpaqueExternalNavigation(consumePending = true)
        val state = _workspace.value ?: return
        if (state.selectedModule != Module.FILES) return
        if (state.previewOwner == PreviewOwner.FILES && state.previewItem?.path == item.path) return
        if (state.previewItem?.path != item.path && state.hasDirtyTextPreview()) {
            requestClosePreview()
            return
        }
        val images = visibleItems.filter { it.previewKind() == FilePreviewKind.IMAGE }
        val index = images.indexOfFirst { it.path == item.path }
        _workspace.update {
            it?.copy(
                photoViewer = null,
                filePreviewSequence = if (index >= 0) FilePreviewSequence(images, index) else null,
                previewOwner = PreviewOwner.FILES,
            )
        }
        startPreview(item, PreviewOwner.FILES)
    }

    fun showPreviousFileImage() {
        val sequence = _workspace.value?.filePreviewSequence?.takeIf { it.hasPrevious } ?: return
        val next = sequence.copy(index = sequence.index - 1)
        _workspace.update { it?.copy(filePreviewSequence = next) }
        startPreview(next.current, PreviewOwner.FILES)
    }

    fun showNextFileImage() {
        val sequence = _workspace.value?.filePreviewSequence?.takeIf { it.hasNext } ?: return
        val next = sequence.copy(index = sequence.index + 1)
        _workspace.update { it?.copy(filePreviewSequence = next) }
        startPreview(next.current, PreviewOwner.FILES)
    }

    fun openPhotoViewer(item: PhotoItem, visibleItems: List<PhotoItem>) {
        cancelOpaqueExternalNavigation(consumePending = true)
        if (_workspace.value?.selectedModule != Module.PHOTOS) return
        val media = visibleItems
            .filter { it.kind in setOf(PhotoItemKind.IMAGE, PhotoItemKind.VIDEO) }
            .map(PhotoItem::file)
        val index = media.indexOfFirst { it.path == item.file.path }
        if (index < 0) return
        _workspace.update {
            it?.copy(
                photoViewer = PhotoViewerState(media, index),
                filePreviewSequence = null,
                previewOwner = PreviewOwner.PHOTOS,
                textPreviewDraft = null,
            )
        }
        startPreview(item.file, PreviewOwner.PHOTOS)
    }

    fun showPreviousPhoto() {
        val viewer = _workspace.value?.photoViewer?.takeIf(PhotoViewerState::hasPrevious) ?: return
        val next = viewer.copy(index = viewer.index - 1)
        _workspace.update { it?.copy(photoViewer = next) }
        startPreview(next.current, PreviewOwner.PHOTOS)
    }

    fun showNextPhoto() {
        val viewer = _workspace.value?.photoViewer?.takeIf(PhotoViewerState::hasNext) ?: return
        val next = viewer.copy(index = viewer.index + 1)
        _workspace.update { it?.copy(photoViewer = next) }
        startPreview(next.current, PreviewOwner.PHOTOS)
    }

    private fun startPreview(item: FileItem, owner: PreviewOwner) {
        if (item.previewKind() == FilePreviewKind.UNSUPPORTED) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.preview_not_supported))
            }
            return
        }
        previewJob?.cancel()
        val requestGeneration = previewRequestGeneration.incrementAndGet()
        cleanupPreviewFile(_workspace.value?.preview)
        _workspace.update {
            it?.copy(
                previewItem = item,
                preview = Loadable.Loading,
                previewOwner = owner,
                textPreviewDraft = null,
                previewDiscardConfirmationVisible = false,
            )
        }
        val repo = repository ?: return
        previewJob = viewModelScope.launch {
            runCatching { loadPreview(repo, item) }
                .onSuccess { content ->
                    _workspace.update { current ->
                        current?.takeIf {
                            repository === repo && it.previewOwner == owner &&
                                it.previewItem?.path == item.path &&
                                previewRequestGeneration.get() == requestGeneration
                        }
                            ?.copy(preview = Loadable.Ready(content)) ?: current
                    }
                    val acceptedContent = (_workspace.value?.preview as? Loadable.Ready)?.value
                    if (acceptedContent !== content) cleanupPreviewFile(Loadable.Ready(content))
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    _workspace.update { current ->
                        current?.takeIf {
                            repository === repo && it.previewOwner == owner &&
                                it.previewItem?.path == item.path &&
                                previewRequestGeneration.get() == requestGeneration
                        }
                            ?.copy(preview = Loadable.Failed(error.asDsmFailure())) ?: current
                    }
                }
        }
    }

    fun retryPreview() {
        val state = _workspace.value ?: return
        val owner = state.previewOwner ?: return
        state.previewItem?.let { startPreview(it, owner) }
    }

    fun requestTextPreviewSave(item: FileItem, value: String): Boolean {
        val current = _workspace.value ?: return false
        if (current.previewOwner != PreviewOwner.FILES ||
            current.previewItem?.path != item.path || !item.canWrite
        ) return false
        val bytes = value.encodeToByteArray()
        val target = FileStationMutationTarget(
            profileId = current.profile.id,
            module = Module.FILES,
            operation = FileStationMutationOperation.TEXT_SAVE,
            sourceBaselines = listOf(item),
            expectedContentSha256 = sha256Hex(bytes),
            expectedContentByteCount = bytes.size.toLong(),
        )
        return requestFileStationLifecycleMutation(target)
    }

    fun saveTextPreview(item: FileItem, value: String) {
        requestTextPreviewSave(item, value)
    }

    private fun executeTextPreviewSave(target: FileStationMutationTarget): Boolean {
        val current = _workspace.value ?: return false
        val value = current.textPreviewDraft ?: return false
        val bytes = value.encodeToByteArray()
        if (sha256Hex(bytes) != target.expectedContentSha256 ||
            bytes.size.toLong() != target.expectedContentByteCount
        ) return false
        var savedContent: FilePreviewContent.Text? = null
        return fileStationMutation(
            target,
            FileStationMutationRefresh.TEXT_PREVIEW,
            ::textSaveMutationMessageResource,
            applyResult = { workspace, result ->
                val saved = savedContent
                if (result.status == MutationResultStatus.CONFIRMED_SUCCESS && saved != null &&
                    workspace.previewOwner == PreviewOwner.FILES &&
                    workspace.previewItem?.path == target.sourceBaselines.single().path
                ) workspace.copy(
                    previewItem = saved.item,
                    preview = Loadable.Ready(saved),
                    textPreviewDraft = null,
                ) else workspace
            },
        ) { repo -> repo.saveTextResult(target.sourceBaselines.single(), value).also {
            savedContent = it.content
        }.result }
    }

    fun updateTextPreviewDraft(value: String?) {
        _workspace.update { state ->
            state?.takeIf { it.previewOwner == PreviewOwner.FILES }
                ?.copy(textPreviewDraft = value) ?: state
        }
    }

    fun requestCancelTextPreviewEdit() {
        val state = _workspace.value ?: return
        if (state.hasDirtyTextPreview()) {
            _workspace.update {
                it?.copy(
                    previewDiscardConfirmationVisible = true,
                    previewDiscardClosesPreview = false,
                )
            }
        } else {
            updateTextPreviewDraft(null)
        }
    }

    fun requestClosePreview() {
        val state = _workspace.value ?: return
        if (state.isPerformingAction && state.textPreviewDraft != null) return
        if (state.hasDirtyTextPreview()) {
            _workspace.update {
                it?.copy(
                    previewDiscardConfirmationVisible = true,
                    previewDiscardClosesPreview = true,
                )
            }
        } else {
            closePreviewImmediately()
        }
    }

    fun dismissPreviewDiscardConfirmation() {
        pendingExternalModuleAfterPreviewDiscard?.let { module ->
            cancelledExternalNavigationModule = module
            _opaqueExternalNavigationRevision.update { it + 1L }
        }
        pendingExternalModuleAfterPreviewDiscard = null
        cancelOpaqueExternalNavigationAfterPreviewDiscard()
        pendingModuleAfterPreviewDiscard = null
        _workspace.update { it?.copy(previewDiscardConfirmationVisible = false) }
    }

    fun confirmDiscardTextPreview() {
        if (fileStationMutationBlocksWorkspaceExit(
                _workspace.value?.fileStationMutationState ?: return,
            )
        ) return
        val shouldClose = _workspace.value?.previewDiscardClosesPreview == true
        val pendingModule = pendingModuleAfterPreviewDiscard
        pendingExternalModuleAfterPreviewDiscard = null
        val opaqueRequest = opaqueExternalNavigation?.takeIf {
            it.phase == OpaqueExternalNavigationPhase.WAITING_FOR_PREVIEW_DISCARD
        }
        pendingModuleAfterPreviewDiscard = null
        if (shouldClose) {
            closePreviewImmediately()
            if (opaqueRequest != null) {
                opaqueRequest.phase = OpaqueExternalNavigationPhase.RESOLVING
                if (opaqueExternalNavigationMatches(opaqueRequest)) {
                    launchOpaqueExternalNavigation(opaqueRequest)
                }
            } else if (pendingModule != null) {
                navigateTo(WorkspaceRoute.ModuleRoot(pendingModule))
            }
        } else {
            _workspace.update {
                it?.copy(
                    textPreviewDraft = null,
                    previewDiscardConfirmationVisible = false,
                )
            }
            if (opaqueRequest != null) {
                opaqueRequest.phase = OpaqueExternalNavigationPhase.RESOLVING
                if (opaqueExternalNavigationMatches(opaqueRequest)) {
                    launchOpaqueExternalNavigation(opaqueRequest)
                }
            }
        }
    }

    fun closePreview() = requestClosePreview()

    private fun closePreviewImmediately() {
        previewJob?.cancel()
        previewJob = null
        previewRequestGeneration.incrementAndGet()
        cleanupPreviewFile(_workspace.value?.preview)
        _workspace.update {
            it?.copy(
                previewItem = null,
                preview = Loadable.Idle,
                previewOwner = null,
                photoViewer = null,
                filePreviewSequence = null,
                textPreviewDraft = null,
                previewDiscardConfirmationVisible = false,
            )
        }
    }

    fun cancelTransfer(id: String) {
        if (transferStore.server(id)?.readOnlyObservation == true) return
        val job = transferJobs[id]
        val persisted = transferStore.download(id)
        val upload = transferStore.upload(id)
        if (persisted?.state == TransferState.PAUSED) {
            transferStore.update(id) {
                it.copy(state = TransferState.CANCELLED, errorKind = null)
            }
            deleteIncompleteDownload(Uri.parse(persisted.destinationUri))
            releasePersistedDownloadPermission(Uri.parse(persisted.destinationUri))
            syncPersistedDownloads(persisted.profileId)
            job?.cancel()
            persisted.workId?.let { value ->
                runCatching { workManager.cancelWorkById(UUID.fromString(value)) }
            }
            return
        }
        if (job == null && persisted?.workId == null && upload?.workId == null) return
        updateTransfer(id) {
            it.requestUserCancellation(
                cancellingDetail = getApplication<Application>().getString(R.string.transfer_cancelling),
            )
        }
        val cancellingDownload = transferStore.update(id) { current ->
            current.requestUserCancellation(persisted?.workId)
        }
        val cancellingUpload = transferStore.updateUpload(id) { current ->
            current.requestUserCancellation(upload?.workId)
        }
        if (job != null) {
            job.invokeOnCompletion {
                updateTransfer(id) { current ->
                    current.finalizeForegroundUserCancellation(
                        cancelledDetail = getApplication<Application>().getString(R.string.transfer_cancelled),
                        refreshDetail = getApplication<Application>().getString(
                            R.string.transfer_cancelled_refresh,
                        ),
                    )
                }
            }
            job.cancel()
        } else {
            cancellingDownload?.takeIf { it.state == TransferState.CANCELLING }?.workId?.let { value ->
                runCatching { UUID.fromString(value) }.getOrNull()?.let { workId ->
                    monitorDownload(id, workId)
                    workManager.cancelWorkById(workId)
                }
            }
            cancellingUpload?.takeIf { it.state == TransferState.CANCELLING }?.workId?.let { value ->
                runCatching { UUID.fromString(value) }.getOrNull()?.let { workId ->
                    monitorUpload(id, workId)
                    workManager.cancelWorkById(workId)
                }
            }
        }
    }

    fun canPauseTransfer(id: String): Boolean =
        transferStore.download(id)?.canPauseDownload() == true

    fun pauseTransfer(id: String) {
        val paused = transferStore.update(id) { current ->
            if (current.canPauseDownload()) current.copy(state = TransferState.PAUSED) else current
        }?.takeIf { it.state == TransferState.PAUSED } ?: return
        syncPersistedDownloads(paused.profileId)
        transferJobs[id]?.cancel()
        paused.workId?.let { value ->
            runCatching { workManager.cancelWorkById(UUID.fromString(value)) }
        }
    }

    fun canResumeTransfer(id: String): Boolean =
        transferStore.download(id)?.canResumeDownload() == true

    fun resumeTransfer(id: String) {
        val download = transferStore.download(id)?.takeIf(PersistedDownload::canResumeDownload)
            ?: return
        val usesBackgroundWork = download.backgroundCapable && store.session(download.profileId) != null
        val repo = repository
        if (!usesBackgroundWork && repo == null) return
        val next = transferStore.update(id) { current ->
            if (current.canResumeDownload()) {
                current.copy(
                    state = TransferState.WAITING,
                    errorKind = null,
                    workId = null,
                    startedAtEpochMillis = null,
                )
            } else {
                current
            }
        }?.takeIf { it.state == TransferState.WAITING } ?: return
        syncPersistedDownloads(next.profileId)
        if (usesBackgroundWork) {
            enqueueBackgroundDownload(
                next,
                existingWorkPolicy = transferEnqueuePolicy(TransferEnqueueReason.USER_RETRY),
                requireExactResume = true,
            )
        } else {
            enqueueForegroundDownload(
                requireNotNull(repo),
                next,
                Uri.parse(next.destinationUri),
                requireExactResume = true,
            )
        }
    }

    fun canRetryTransfer(id: String): Boolean {
        val download = transferStore.download(id)
        if (download?.state == TransferState.FAILED && !download.isDirectory) return true
        val upload = transferStore.upload(id) ?: return false
        return upload.state in setOf(
            TransferState.FAILED,
            TransferState.CANCELLED,
        )
    }

    fun retryTransfer(id: String) {
        val repo = repository ?: return
        transferStore.download(id)?.takeIf {
            it.state == TransferState.FAILED && !it.isDirectory
        }?.let { download ->
            val next = transferStore.update(id) {
                it.copy(
                    state = TransferState.WAITING,
                    errorKind = null,
                    workId = null,
                    startedAtEpochMillis = null,
                )
            } ?: return
            if (download.backgroundCapable && store.session(download.profileId) != null) {
                enqueueBackgroundDownload(
                    next,
                    existingWorkPolicy = transferEnqueuePolicy(TransferEnqueueReason.USER_RETRY),
                )
            } else {
                enqueueForegroundDownload(repo, next, Uri.parse(next.destinationUri))
            }
            return
        }
        val upload = transferStore.upload(id) ?: return
        if (!canRetryTransfer(id) || _workspace.value?.isPerformingAction == true) return
        if (store.session(upload.profileId) == null) {
            _workspace.update {
                it?.copy(message = getApplication<Application>().getString(R.string.upload_retry_requires_login))
            }
            return
        }
        viewModelScope.launch {
            _workspace.update { it?.copy(isPerformingAction = true, message = null) }
            runCatching {
                val target = upload.destinationPath.trimEnd('/') + "/" + upload.title
                val existing = if (repo.itemExists(target)) repo.fileInfo(target) else null
                retryUploadDecision(existing, upload.expectedBytes, upload.overwrite)
            }.onSuccess { decision ->
                when (decision) {
                    RetryUploadDecision.ALREADY_COMPLETE -> {
                        transferStore.updateUpload(id) {
                            it.copy(
                                state = TransferState.SUCCEEDED,
                                completedBytes = it.expectedBytes,
                                errorKind = null,
                                requiresRefresh = false,
                                uploadMutationResult = confirmedUploadReadbackResult()
                                    .toPersistedMutationResult(writeSubmitted = false),
                            )
                        }
                        syncPersistedDownloads(upload.profileId)
                        _workspace.update {
                            it?.copy(
                                isPerformingAction = false,
                                message = getApplication<Application>().getString(
                                    R.string.upload_retry_already_complete,
                                ),
                            )
                        }
                    }
                    RetryUploadDecision.CONFLICT -> {
                        transferStore.updateUpload(id) {
                            it.copy(
                                state = TransferState.FAILED,
                                errorKind = DsmErrorKind.UPLOAD_FAILED.name,
                                requiresRefresh = false,
                                uploadMutationResult = uploadTargetConflictResult()
                                    .toPersistedMutationResult(writeSubmitted = false),
                            )
                        }
                        syncPersistedDownloads(upload.profileId)
                        _workspace.update {
                            it?.copy(
                                isPerformingAction = false,
                                message = getApplication<Application>().getString(
                                    R.string.upload_retry_conflict,
                                ),
                            )
                        }
                    }
                    RetryUploadDecision.REQUEUE -> {
                        val next = transferStore.updateUpload(id) {
                            it.copy(
                                state = TransferState.WAITING,
                                completedBytes = 0,
                                errorKind = null,
                                workId = null,
                                requiresRefresh = false,
                                directoryMutationResult = null,
                                uploadMutationResult = null,
                            )
                        }
                        _workspace.update {
                            it?.copy(
                                isPerformingAction = false,
                                message = getApplication<Application>().getString(R.string.upload_retry_queued),
                            )
                        }
                        next?.let {
                            enqueuePersistedFileUpload(
                                it,
                                existingWorkPolicy = transferEnqueuePolicy(
                                    TransferEnqueueReason.USER_RETRY,
                                ),
                            )
                        }
                    }
                }
            }.onFailure { error ->
                _workspace.update {
                    it?.copy(
                        isPerformingAction = false,
                        message = error.asDsmFailure()
                            .localize(getApplication<Application>())
                            .combined,
                    )
                }
            }
        }
    }

    fun clearFinishedTransfers() {
        _workspace.value?.profile?.id?.let { profileId ->
            transferStore.downloads(profileId)
                .filter { it.state in TERMINAL_TRANSFER_STATES }
                .forEach {
                    val destination = Uri.parse(it.destinationUri)
                    if (it.state == TransferState.FAILED) deleteIncompleteDownload(destination)
                    releasePersistedDownloadPermission(destination)
                }
            val uploads = transferStore.uploads(profileId)
            val clearableUploads = uploads.filter(PersistedUpload::canRemoveFinishedUpload)
            clearableUploads
                .filter(PersistedUpload::ownsPersistedReadGrant)
                .forEach { releasePersistedReadPermission(Uri.parse(it.sourceUri)) }
            val configuredTree = transferStore.photoBackupSource(profileId)?.treeUri
            val activeTrees = uploads.filter {
                it.state !in TERMINAL_TRANSFER_STATES || it.requiresRefresh
            }
                .mapNotNullTo(mutableSetOf(), PersistedUpload::sourceTreeUri)
            clearableUploads
                .mapNotNull(PersistedUpload::sourceTreeUri)
                .filter { it != configuredTree && it !in activeTrees }
                .distinct()
                .forEach { releasePersistedReadPermission(Uri.parse(it)) }
            transferStore.removeTerminal(profileId)
        }
        _workspace.update { current ->
            current?.copy(
                transfers = current.transfers.filter {
                    it.state !in setOf(
                        TransferState.SUCCEEDED,
                        TransferState.FAILED,
                        TransferState.CANCELLED,
                    ) || it.direction == TransferDirection.UPLOAD && it.requiresRefresh ||
                        fileServerMutationBlocksWorkspaceExit(it.fileServerMutation) &&
                        !fileServerMutationCanBeExplicitlyCleared(it.fileServerMutation)
                },
            )
        }
    }

    fun canRefreshFileServerTransfer(id: String): Boolean {
        val current = _workspace.value ?: return false
        val lifecycle = current.transfers.singleOrNull { it.id == id }
            ?.fileServerMutation ?: return false
        val needsRecovery = lifecycle.refreshFailure != null || !lifecycle.refreshCompleted &&
            (lifecycle.result?.requiresRefresh == true || lifecycle.failure != null)
        return repository != null && lifecycle.target.profileId == current.profile.id &&
            !lifecycle.refreshInProgress && needsRecovery
    }

    fun refreshFileServerTransfer(id: String): Boolean {
        val claim = synchronized(fileStationMutationLock) {
            val repo = repository ?: return false
            val current = _workspace.value ?: return false
            val task = current.transfers.singleOrNull { it.id == id } ?: return false
            val lifecycle = task.fileServerMutation ?: return false
            if (!canRefreshFileServerTransfer(id)) return false
            val candidate = FileServerTransferClaim(
                repo,
                current.profile.id,
                lifecycle.target.module,
                id,
                lifecycle.target,
                lifecycle.generation,
            )
            _workspace.value = current.copy(
                transfers = current.transfers.map {
                    if (it.id == id) it.copy(
                        fileServerMutation = lifecycle.copy(
                            refreshInProgress = true,
                            refreshFailure = null,
                        ),
                    ) else it
                },
            )
            candidate
        }
        viewModelScope.launch {
            val outcome = runCatching {
                verifyFileServerMutation(claim.repository, claim.target)
            }
            val persistenceFailure = runCatching {
                updateServerTransfer(claim, id) { task ->
                    val lifecycle = checkNotNull(task.fileServerMutation)
                    task.copy(
                        requiresRefresh = outcome.isFailure,
                        fileServerMutation = lifecycle.copy(
                            refreshInProgress = false,
                            refreshCompleted = outcome.isSuccess,
                            refreshFailure = outcome.exceptionOrNull()?.asDsmFailure(),
                            verification = outcome.getOrNull()
                                ?: FileServerMutationVerification.UNAVAILABLE,
                        ),
                    )
                }
            }.exceptionOrNull()
            if (persistenceFailure != null) {
                val failure = DsmFailure(
                    null,
                    "",
                    "",
                    kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
                )
                _workspace.update { current ->
                    current?.takeIf {
                        repository === claim.repository && it.profile.id == claim.profileId
                    }?.copy(
                        transfers = current.transfers.map { task ->
                            if (fileServerMutationCallbackMatches(task, claim)) {
                                task.copy(
                                    requiresRefresh = true,
                                    fileServerMutation = task.fileServerMutation?.copy(
                                        refreshInProgress = false,
                                        refreshCompleted = false,
                                        refreshFailure = failure,
                                        verification = FileServerMutationVerification.UNAVAILABLE,
                                    ),
                                )
                            } else task
                        },
                    ) ?: current
                }
            }
            val current = _workspace.value
            if (current?.selectedModule == Module.FILES &&
                current.fileBrowser.path == claim.target.destinationFolderBaseline.path
            ) loadFileBrowser(claim.repository)
        }
        return true
    }

    fun openAndRefreshFileServerTransferTarget(id: String): Boolean {
        val current = _workspace.value ?: return false
        val target = current.transfers.singleOrNull { it.id == id }
            ?.fileServerMutation?.target ?: return false
        if (target.profileId != current.profile.id) return false
        _workspace.value = current.copy(
            selectedModule = Module.FILES,
            fileBrowser = current.fileBrowser.openShortcut(target.destinationFolderBaseline.path),
        )
        return refreshFileServerTransfer(id)
    }

    fun beginDownloadDestinationSelection() {
        val repo = repository ?: return
        val picker = DownloadDestinationPickerState()
        _workspace.update {
            it?.copy(
                downloadDestinationPicker = picker,
                downloadDestinationFolders = Loadable.Loading,
            )
        }
        viewModelScope.launch { loadDownloadDestinationFolders(repo, picker) }
    }

    fun openDownloadSettings(): Boolean = synchronized(downloadSettingsMutationLock) {
        val repo = repository ?: return@synchronized false
        val current = _workspace.value ?: return@synchronized false
        val settingsState = current.downloadSettingsState
        if (current.selectedModule != Module.DOWNLOADS || !current.supportsDownloadSettings ||
            current.isPerformingAction || current.downloadCreationState.target != null ||
            current.downloadControlState.target != null || current.downloadRssRefreshState.target != null ||
            current.downloadDestinationEditState != DownloadDestinationEditWorkspaceState() ||
            settingsState.editorVisible ||
            settingsState.mutationInProgress || settingsState.mutationRefreshInProgress
        ) return@synchronized false
        val generation = downloadSettingsMutationGeneration.incrementAndGet()
        _workspace.value = current.copy(
            downloadSettings = Loadable.Loading,
            downloadSettingsState = DownloadSettingsWorkspaceState(
                editorVisible = true,
                mutationGeneration = generation,
            ),
        )
        launchDownloadSettingsLoad(repo, current.profile.id, generation)
        true
    }

    fun loadDownloadSettings() {
        val claim = synchronized(downloadSettingsMutationLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            if (!current.downloadSettingsState.editorVisible ||
                current.downloadSettingsState.mutationInProgress ||
                current.downloadSettingsState.mutationRefreshInProgress ||
                current.downloadSettingsState.mutationResult != null ||
                current.downloadSettingsState.mutationFailure != null
            ) return@synchronized null
            val generation = downloadSettingsMutationGeneration.incrementAndGet()
            _workspace.value = current.copy(
                downloadSettings = Loadable.Loading,
                downloadSettingsState = current.downloadSettingsState.copy(
                    baseline = null,
                    draft = null,
                    mutationResult = null,
                    mutationFailure = null,
                    mutationRefreshFailure = null,
                    mutationRefreshCompleted = false,
                    mutationGeneration = generation,
                ),
            )
            Triple(repo, current.profile.id, generation)
        } ?: return
        launchDownloadSettingsLoad(claim.first, claim.second, claim.third)
    }

    private fun launchDownloadSettingsLoad(repo: DsmRepository, profileId: String, generation: Long) {
        viewModelScope.launch {
            runCatching { repo.loadDownloadSettings() }
                .onSuccess { settings ->
                    synchronized(downloadSettingsMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        val state = current.downloadSettingsState
                        if (repository !== repo || current.profile.id != profileId ||
                            state.mutationGeneration != generation ||
                            downloadSettingsMutationGeneration.get() != generation ||
                            !state.editorVisible
                        ) return@synchronized
                        _workspace.value = current.copy(
                            downloadSettings = Loadable.Ready(settings),
                            downloadSettingsState = state.copy(
                                baseline = settings,
                                draft = DownloadSettingsDraftState.from(settings),
                            ),
                        )
                    }
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    synchronized(downloadSettingsMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        val state = current.downloadSettingsState
                        if (repository !== repo || current.profile.id != profileId ||
                            state.mutationGeneration != generation ||
                            downloadSettingsMutationGeneration.get() != generation ||
                            !state.editorVisible
                        ) return@synchronized
                        _workspace.value = current.copy(
                            downloadSettings = Loadable.Failed(error.asDsmFailure()),
                        )
                    }
                }
        }
    }

    fun updateDownloadSettingsDraft(draft: DownloadSettingsDraftState) =
        synchronized(downloadSettingsMutationLock) {
            _workspace.update { current ->
                current?.takeIf {
                    it.downloadSettingsState.editorVisible &&
                        !it.downloadSettingsState.mutationInProgress &&
                        !it.downloadSettingsState.mutationRefreshInProgress
                }?.copy(
                    downloadSettingsState = current.downloadSettingsState.copy(draft = draft),
                ) ?: current
            }
        }

    fun closeDownloadSettings(): Boolean = synchronized(downloadSettingsMutationLock) {
        val current = _workspace.value ?: return@synchronized true
        val state = current.downloadSettingsState
        if (state.mutationInProgress || state.mutationRefreshInProgress ||
            state.mutationResult != null || state.mutationFailure != null
        ) return@synchronized false
        downloadSettingsMutationGeneration.incrementAndGet()
        _workspace.value = current.copy(
            downloadSettings = Loadable.Idle,
            downloadSettingsState = DownloadSettingsWorkspaceState(),
        )
        true
    }

    fun loadDownloadActivity() {
        val repo = repository ?: return
        val current = _workspace.value ?: return
        if (!repo.supportsDownloadActivity() || current.selectedModule != Module.DOWNLOADS) return
        downloadActivityJob?.cancel()
        val generation = downloadActivityGeneration.incrementAndGet()
        val profileId = current.profile.id
        _workspace.value = current.withDownloadActivity(Loadable.Loading)
        downloadActivityJob = viewModelScope.launch {
            runCatching { repo.loadDownloadActivity() }
                .onSuccess { activity ->
                    _workspace.update { state ->
                        state?.takeIf {
                            repository === repo && it.profile.id == profileId &&
                                it.selectedModule == Module.DOWNLOADS &&
                                generation == downloadActivityGeneration.get()
                        }?.withDownloadActivity(Loadable.Ready(activity)) ?: state
                    }
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    _workspace.update { state ->
                        state?.takeIf {
                            repository === repo && it.profile.id == profileId &&
                                it.selectedModule == Module.DOWNLOADS &&
                                generation == downloadActivityGeneration.get()
                        }?.withDownloadActivity(Loadable.Failed(error.asDsmFailure())) ?: state
                    }
                }
        }
    }

    fun openDownloadDiscovery(): Boolean {
        val repo = repository ?: return false
        val current = _workspace.value ?: return false
        if (current.selectedModule != Module.DOWNLOADS ||
            (!repo.supportsDownloadRss() && !repo.supportsDownloadBtSearch())
        ) return false
        downloadDiscoveryLoadJob?.cancel()
        downloadBtCatalogJob?.cancel()
        downloadDiscoverySearchJob?.cancel()
        val generation = downloadDiscoveryGeneration.incrementAndGet()
        _workspace.value = current.copy(
            downloadAdvancedRead = current.downloadAdvancedRead.copy(
                discoveryVisible = true,
                discoveryTab = if (repo.supportsDownloadRss()) {
                    DownloadDiscoveryTab.RSS
                } else {
                    DownloadDiscoveryTab.BT_SEARCH
                },
                btSearchCatalog = if (repo.supportsDownloadBtSearch()) {
                    Loadable.Loading
                } else {
                    Loadable.Idle
                },
                btAdvancedOptionsVisible = false,
                btSearchOptions = DownloadBtSearchOptions(),
                btSearchResults = Loadable.Idle,
            ),
            downloadRssSites = if (repo.supportsDownloadRss()) Loadable.Loading else Loadable.Idle,
            selectedDownloadRssSite = null,
            downloadRssFeeds = Loadable.Idle,
        )
        if (repo.supportsDownloadRss()) loadDownloadRssSites()
        if (repo.supportsDownloadBtSearch()) loadDownloadBtSearchCatalog(generation)
        return true
    }

    fun loadDownloadBtSearchCatalog() {
        val current = _workspace.value ?: return
        if (!current.downloadAdvancedRead.discoveryVisible) return
        loadDownloadBtSearchCatalog(downloadDiscoveryGeneration.get())
    }

    private fun loadDownloadBtSearchCatalog(generation: Long) {
        val repo = repository ?: return
        val current = _workspace.value ?: return
        if (!repo.supportsDownloadBtSearch() || current.selectedModule != Module.DOWNLOADS ||
            !current.downloadAdvancedRead.discoveryVisible
        ) return
        downloadBtCatalogJob?.cancel()
        _workspace.value = current.copy(
            downloadAdvancedRead = current.downloadAdvancedRead.copy(
                btSearchCatalog = Loadable.Loading,
            ),
        )
        val profileId = current.profile.id
        downloadBtCatalogJob = viewModelScope.launch {
            runCatching { repo.loadDownloadBtSearchCatalog() }
                .onSuccess { catalog ->
                    _workspace.update { state ->
                        state?.takeIf {
                            repository === repo && it.profile.id == profileId &&
                                it.selectedModule == Module.DOWNLOADS &&
                                it.downloadAdvancedRead.discoveryVisible &&
                                generation == downloadDiscoveryGeneration.get()
                        }?.let { valid ->
                            valid.copy(
                                downloadAdvancedRead = valid.downloadAdvancedRead.copy(
                                    btSearchCatalog = Loadable.Ready(catalog),
                                ),
                            )
                        } ?: state
                    }
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    _workspace.update { state ->
                        state?.takeIf {
                            repository === repo && it.profile.id == profileId &&
                                it.selectedModule == Module.DOWNLOADS &&
                                it.downloadAdvancedRead.discoveryVisible &&
                                generation == downloadDiscoveryGeneration.get()
                        }?.let { valid ->
                            valid.copy(
                                downloadAdvancedRead = valid.downloadAdvancedRead.copy(
                                    btSearchCatalog = Loadable.Failed(error.asDsmFailure()),
                                ),
                            )
                        } ?: state
                    }
                }
        }
    }

    fun updateDownloadBtSearchOptions(options: DownloadBtSearchOptions) {
        _workspace.update { current ->
            current?.takeIf {
                it.downloadAdvancedRead.discoveryVisible &&
                    it.downloadAdvancedRead.btSearchResults !is Loadable.Loading
            }?.let { valid ->
                valid.copy(
                    downloadAdvancedRead = valid.downloadAdvancedRead.copy(btSearchOptions = options),
                )
            } ?: current
        }
    }

    fun toggleDownloadBtAdvancedOptions() {
        _workspace.update { current ->
            current?.takeIf { it.downloadAdvancedRead.discoveryVisible }?.let { valid ->
                valid.copy(
                    downloadAdvancedRead = valid.downloadAdvancedRead.copy(
                        btAdvancedOptionsVisible = !valid.downloadAdvancedRead.btAdvancedOptionsVisible,
                    ),
                )
            } ?: current
        }
    }

    fun selectDownloadDiscoveryTab(tab: DownloadDiscoveryTab) {
        _workspace.update { current ->
            current?.takeIf {
                it.downloadAdvancedRead.discoveryVisible &&
                    (tab != DownloadDiscoveryTab.RSS || it.supportsDownloadRss) &&
                    (tab != DownloadDiscoveryTab.BT_SEARCH || it.supportsDownloadBtSearch)
            }?.let { valid ->
                valid.copy(
                    downloadAdvancedRead = valid.downloadAdvancedRead.copy(discoveryTab = tab),
                )
            } ?: current
        }
    }

    fun loadDownloadRssSites() {
        val claim = synchronized(downloadRssRefreshMutationLock) {
            val repo = repository ?: return
            val current = _workspace.value ?: return
            if (!repo.supportsDownloadRss() || current.selectedModule != Module.DOWNLOADS ||
                current.downloadRssRefreshState.target != null
            ) return
            downloadDiscoveryLoadJob?.cancel()
            _workspace.value = current.copy(
                downloadRssSites = Loadable.Loading,
                selectedDownloadRssSite = null,
                downloadRssFeeds = Loadable.Idle,
            )
            repo to current.profile.id
        }
        downloadDiscoveryLoadJob = viewModelScope.launch {
            runCatching { claim.first.listDownloadRssSites() }
                .onSuccess { sites ->
                    synchronized(downloadRssRefreshMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        if (repository !== claim.first || current.profile.id != claim.second ||
                            current.selectedModule != Module.DOWNLOADS ||
                            current.downloadRssRefreshState.target != null
                        ) return@synchronized
                        _workspace.value = current.copy(downloadRssSites = Loadable.Ready(sites))
                    }
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    synchronized(downloadRssRefreshMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        if (repository !== claim.first || current.profile.id != claim.second ||
                            current.selectedModule != Module.DOWNLOADS ||
                            current.downloadRssRefreshState.target != null
                        ) return@synchronized
                        _workspace.value = current.copy(
                            downloadRssSites = Loadable.Failed(error.asDsmFailure()),
                        )
                    }
                }
        }
    }

    fun selectDownloadRssSite(site: DownloadRssSite) {
        val claim = synchronized(downloadRssRefreshMutationLock) {
            val repo = repository ?: return
            val current = _workspace.value ?: return
            if (current.selectedModule != Module.DOWNLOADS ||
                current.downloadRssRefreshState.target != null
            ) return
            downloadDiscoveryLoadJob?.cancel()
            _workspace.value = current.copy(
                selectedDownloadRssSite = site,
                downloadRssFeeds = Loadable.Loading,
            )
            Triple(repo, current.profile.id, site.id)
        }
        downloadDiscoveryLoadJob = viewModelScope.launch {
            runCatching { claim.first.listDownloadRssFeeds(claim.third) }
                .onSuccess { feeds ->
                    synchronized(downloadRssRefreshMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        if (repository !== claim.first || current.profile.id != claim.second ||
                            current.selectedModule != Module.DOWNLOADS ||
                            current.selectedDownloadRssSite?.id != claim.third ||
                            current.downloadRssRefreshState.target != null
                        ) return@synchronized
                        _workspace.value = current.copy(downloadRssFeeds = Loadable.Ready(feeds))
                    }
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    synchronized(downloadRssRefreshMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        if (repository !== claim.first || current.profile.id != claim.second ||
                            current.selectedModule != Module.DOWNLOADS ||
                            current.selectedDownloadRssSite?.id != claim.third ||
                            current.downloadRssRefreshState.target != null
                        ) return@synchronized
                        _workspace.value = current.copy(
                            downloadRssFeeds = Loadable.Failed(error.asDsmFailure()),
                        )
                    }
                }
        }
    }

    fun refreshSelectedDownloadRssSite() {
        val claim = synchronized(downloadRssRefreshMutationLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            val siteId = current.selectedDownloadRssSite?.id?.trim()?.takeIf(String::isNotEmpty)
                ?: return@synchronized null
            if (current.selectedModule != Module.DOWNLOADS || !current.supportsDownloadRss ||
                current.isPerformingAction || current.downloadRssRefreshState.target != null ||
                current.downloadCreationState.target != null ||
                current.downloadControlState.target != null ||
                current.downloadSettingsState.editorVisible
            ) return@synchronized null
            downloadDiscoveryLoadJob?.cancel()
            downloadDiscoveryLoadJob = null
            val target = DownloadRssRefreshTarget(
                profileId = current.profile.id,
                siteId = siteId,
                baselineLastUpdatedAtEpochSeconds = current.selectedDownloadRssSite
                    ?.lastUpdatedAtEpochSeconds,
            )
            val generation = downloadRssRefreshMutationGeneration.incrementAndGet()
            _workspace.value = current.copy(
                downloadRssRefreshState = DownloadRssRefreshWorkspaceState(
                    target = target,
                    mutationInProgress = true,
                    mutationGeneration = generation,
                ),
            )
            DownloadRssRefreshClaim(repo, current.profile.id, target, generation)
        } ?: return
        viewModelScope.launch {
            try {
                val result = claim.repository.refreshDownloadRssSiteResult(claim.target.siteId)
                if (!finishDownloadRssRefreshSubmission(claim, result)) return@launch
                if (downloadRssRefreshRequiresReadback(
                        DownloadRssRefreshWorkspaceState(
                            target = claim.target,
                            mutationResult = result,
                        ),
                    )
                ) {
                    startDownloadRssRefreshReadback(claim)
                }
            } catch (error: CancellationException) {
                finishDownloadRssRefreshSubmission(claim, cancelledDownloadRssRefreshResult())
                throw error
            } catch (error: Throwable) {
                if (finishDownloadRssRefreshFailure(claim, error.asDsmFailure())) {
                    startDownloadRssRefreshReadback(claim)
                }
            }
        }
    }

    private fun finishDownloadRssRefreshSubmission(
        claim: DownloadRssRefreshClaim,
        result: MutationResult,
    ): Boolean = synchronized(downloadRssRefreshMutationLock) {
        val current = _workspace.value ?: return false
        if (!downloadRssRefreshCallbackMatches(
                repositoryMatches = repository === claim.repository,
                profileMatches = current.profile.id == claim.profileId,
                selectedModule = current.selectedModule,
                selectedSiteId = current.selectedDownloadRssSite?.id,
                stateTarget = current.downloadRssRefreshState.target,
                callbackTarget = claim.target,
                stateGeneration = current.downloadRssRefreshState.mutationGeneration,
                callbackGeneration = claim.generation,
                globalGeneration = downloadRssRefreshMutationGeneration.get(),
            )
        ) return false
        _workspace.value = current.copy(
            downloadRssRefreshState = current.downloadRssRefreshState.copy(
                mutationInProgress = false,
                mutationResult = result,
                mutationFailure = null,
            ),
        )
        true
    }

    private fun finishDownloadRssRefreshFailure(
        claim: DownloadRssRefreshClaim,
        failure: DsmFailure,
    ): Boolean = synchronized(downloadRssRefreshMutationLock) {
        val current = _workspace.value ?: return false
        if (!downloadRssRefreshCallbackMatches(
                repositoryMatches = repository === claim.repository,
                profileMatches = current.profile.id == claim.profileId,
                selectedModule = current.selectedModule,
                selectedSiteId = current.selectedDownloadRssSite?.id,
                stateTarget = current.downloadRssRefreshState.target,
                callbackTarget = claim.target,
                stateGeneration = current.downloadRssRefreshState.mutationGeneration,
                callbackGeneration = claim.generation,
                globalGeneration = downloadRssRefreshMutationGeneration.get(),
            )
        ) return false
        _workspace.value = current.copy(
            downloadRssRefreshState = current.downloadRssRefreshState.copy(
                mutationInProgress = false,
                mutationFailure = failure,
            ),
        )
        true
    }

    fun recheckDownloadRssRefresh(): Boolean {
        val claim = synchronized(downloadRssRefreshMutationLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            val state = current.downloadRssRefreshState
            val target = state.target ?: return@synchronized null
            if (current.selectedModule != Module.DOWNLOADS ||
                current.selectedDownloadRssSite?.id != target.siteId || state.mutationInProgress ||
                state.mutationRefreshInProgress ||
                state.mutationResult == null && state.mutationFailure == null
            ) return@synchronized null
            val generation = downloadRssRefreshMutationGeneration.incrementAndGet()
            _workspace.value = current.copy(
                downloadRssRefreshState = state.copy(
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = true,
                    mutationRefreshCompleted = false,
                    mutationVerification = null,
                    mutationGeneration = generation,
                ),
            )
            DownloadRssRefreshClaim(repo, current.profile.id, target, generation)
        } ?: return false
        viewModelScope.launch { performDownloadRssRefreshReadback(claim) }
        return true
    }

    private fun startDownloadRssRefreshReadback(claim: DownloadRssRefreshClaim) {
        val accepted = synchronized(downloadRssRefreshMutationLock) {
            val current = _workspace.value ?: return
            if (!downloadRssRefreshCallbackMatches(
                    repositoryMatches = repository === claim.repository,
                    profileMatches = current.profile.id == claim.profileId,
                    selectedModule = current.selectedModule,
                    selectedSiteId = current.selectedDownloadRssSite?.id,
                    stateTarget = current.downloadRssRefreshState.target,
                    callbackTarget = claim.target,
                    stateGeneration = current.downloadRssRefreshState.mutationGeneration,
                    callbackGeneration = claim.generation,
                    globalGeneration = downloadRssRefreshMutationGeneration.get(),
                )
            ) return
            _workspace.value = current.copy(
                downloadRssRefreshState = current.downloadRssRefreshState.copy(
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = true,
                    mutationRefreshCompleted = false,
                    mutationVerification = null,
                ),
            )
            true
        }
        if (accepted) viewModelScope.launch { performDownloadRssRefreshReadback(claim) }
    }

    private suspend fun performDownloadRssRefreshReadback(claim: DownloadRssRefreshClaim) {
        try {
            val sites = claim.repository.listDownloadRssSites()
            val matchingSites = sites.filter { it.id.trim() == claim.target.siteId }
            val feeds = if (matchingSites.size == 1) {
                claim.repository.listDownloadRssFeeds(claim.target.siteId)
            } else {
                null
            }
            val verification = downloadRssRefreshVerification(claim.target, sites, feeds)
            synchronized(downloadRssRefreshMutationLock) {
                val current = _workspace.value ?: return@synchronized
                if (!downloadRssRefreshCallbackMatches(
                        repositoryMatches = repository === claim.repository,
                        profileMatches = current.profile.id == claim.profileId,
                        selectedModule = current.selectedModule,
                        selectedSiteId = current.selectedDownloadRssSite?.id,
                        stateTarget = current.downloadRssRefreshState.target,
                        callbackTarget = claim.target,
                        stateGeneration = current.downloadRssRefreshState.mutationGeneration,
                        callbackGeneration = claim.generation,
                        globalGeneration = downloadRssRefreshMutationGeneration.get(),
                    )
                ) return@synchronized
                _workspace.value = current.copy(
                    downloadRssSites = Loadable.Ready(sites),
                    selectedDownloadRssSite = matchingSites.singleOrNull()
                        ?: current.selectedDownloadRssSite,
                    downloadRssFeeds = feeds?.let { Loadable.Ready(it) } ?: current.downloadRssFeeds,
                    downloadRssRefreshState = current.downloadRssRefreshState.copy(
                        mutationRefreshFailure = null,
                        mutationRefreshInProgress = false,
                        mutationRefreshCompleted = true,
                        mutationVerification = verification,
                    ),
                )
            }
        } catch (error: CancellationException) {
            finishDownloadRssRefreshReadbackFailure(claim, null)
            throw error
        } catch (error: Throwable) {
            finishDownloadRssRefreshReadbackFailure(claim, error.asDsmFailure())
        }
    }

    private fun finishDownloadRssRefreshReadbackFailure(
        claim: DownloadRssRefreshClaim,
        failure: DsmFailure?,
    ) {
        synchronized(downloadRssRefreshMutationLock) {
            val current = _workspace.value ?: return
            if (!downloadRssRefreshCallbackMatches(
                    repositoryMatches = repository === claim.repository,
                    profileMatches = current.profile.id == claim.profileId,
                    selectedModule = current.selectedModule,
                    selectedSiteId = current.selectedDownloadRssSite?.id,
                    stateTarget = current.downloadRssRefreshState.target,
                    callbackTarget = claim.target,
                    stateGeneration = current.downloadRssRefreshState.mutationGeneration,
                    callbackGeneration = claim.generation,
                    globalGeneration = downloadRssRefreshMutationGeneration.get(),
                )
            ) return
            _workspace.value = current.copy(
                downloadRssRefreshState = current.downloadRssRefreshState.copy(
                    mutationRefreshFailure = failure,
                    mutationRefreshInProgress = false,
                    mutationRefreshCompleted = false,
                    mutationVerification = DownloadRssRefreshVerification.UNAVAILABLE,
                ),
            )
        }
    }

    fun dismissDownloadRssRefreshMutation(): Boolean = synchronized(downloadRssRefreshMutationLock) {
        val current = _workspace.value ?: return false
        if (!canDismissDownloadRssRefreshMutation(current.downloadRssRefreshState)) return false
        downloadRssRefreshMutationGeneration.incrementAndGet()
        _workspace.value = current.copy(
            downloadRssRefreshState = DownloadRssRefreshWorkspaceState(),
        )
        true
    }

    fun searchDownloadBt(keyword: String) {
        val current = _workspace.value ?: return
        updateDownloadBtSearchOptions(current.downloadAdvancedRead.btSearchOptions.copy(keyword = keyword))
        searchDownloadBt()
    }

    fun searchDownloadBt() {
        val repo = repository ?: return
        val current = _workspace.value ?: return
        val advanced = current.downloadAdvancedRead
        if (!repo.supportsDownloadBtSearch() || current.selectedModule != Module.DOWNLOADS ||
            !advanced.discoveryVisible || advanced.discoveryTab != DownloadDiscoveryTab.BT_SEARCH ||
            !canSubmitDownloadBtSearch(
                advanced.btSearchCatalog,
                advanced.btSearchOptions,
                advanced.btSearchResults,
            )
        ) return
        val options = advanced.btSearchOptions
        val generation = downloadDiscoveryGeneration.get()
        val profileId = current.profile.id
        downloadDiscoverySearchJob?.cancel()
        _workspace.update { state ->
            state?.copy(
                downloadAdvancedRead = state.downloadAdvancedRead.copy(
                    btSearchResults = Loadable.Loading,
                ),
            )
        }
        downloadDiscoverySearchJob = viewModelScope.launch {
            runCatching { repo.searchDownloadBt(options) }
                .onSuccess { results ->
                    _workspace.update { state ->
                        state?.takeIf {
                            repository === repo && it.profile.id == profileId &&
                                it.selectedModule == Module.DOWNLOADS &&
                                it.downloadAdvancedRead.discoveryVisible &&
                                generation == downloadDiscoveryGeneration.get()
                        }?.let { valid ->
                            valid.copy(
                                downloadAdvancedRead = valid.downloadAdvancedRead.copy(
                                    btSearchResults = Loadable.Ready(results),
                                ),
                            )
                        } ?: state
                    }
                }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    _workspace.update { state ->
                        state?.takeIf {
                            repository === repo && it.profile.id == profileId &&
                                it.selectedModule == Module.DOWNLOADS &&
                                it.downloadAdvancedRead.discoveryVisible &&
                                generation == downloadDiscoveryGeneration.get()
                        }?.let { valid ->
                            valid.copy(
                                downloadAdvancedRead = valid.downloadAdvancedRead.copy(
                                    btSearchResults = Loadable.Failed(error.asDsmFailure()),
                                ),
                            )
                        } ?: state
                    }
                }
        }
    }

    fun closeDownloadDiscovery(): Boolean {
        synchronized(downloadRssRefreshMutationLock) {
            val current = _workspace.value ?: return false
            val refreshState = current.downloadRssRefreshState
            if (refreshState.target != null && !canDismissDownloadRssRefreshMutation(refreshState)) {
                _workspace.value = current.copy(
                    message = getApplication<Application>()
                        .getString(R.string.switch_nas_blocked_active_operation),
                )
                return false
            }
            downloadDiscoveryLoadJob?.cancel()
            downloadDiscoveryLoadJob = null
            downloadBtCatalogJob?.cancel()
            downloadBtCatalogJob = null
            downloadDiscoverySearchJob?.cancel()
            downloadDiscoverySearchJob = null
            downloadDiscoveryGeneration.incrementAndGet()
            downloadRssRefreshMutationGeneration.incrementAndGet()
            _workspace.value = current.copy(
                downloadAdvancedRead = DownloadAdvancedReadWorkspaceState(
                    supportsActivity = current.downloadAdvancedRead.supportsActivity,
                ),
                downloadRssSites = Loadable.Idle,
                selectedDownloadRssSite = null,
                downloadRssFeeds = Loadable.Idle,
                downloadRssRefreshState = DownloadRssRefreshWorkspaceState(),
            )
            return true
        }
    }

    fun saveDownloadSettings(settings: DownloadSettings): Boolean {
        val claim = synchronized(downloadSettingsMutationLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            val state = current.downloadSettingsState
            val baseline = state.baseline ?: return@synchronized null
            val expected = state.draft?.toSettingsOrNull(current.supportsDownloadSchedule)
                ?: return@synchronized null
            if (settings != expected || settings == baseline ||
                current.selectedModule != Module.DOWNLOADS || !state.editorVisible ||
                current.isPerformingAction || state.mutationInProgress ||
                state.mutationRefreshInProgress || state.mutationResult != null ||
                state.mutationFailure != null || current.downloadCreationState.target != null ||
                current.downloadControlState.target != null ||
                current.downloadRssRefreshState.target != null
            ) return@synchronized null
            val generation = downloadSettingsMutationGeneration.incrementAndGet()
            _workspace.value = current.copy(
                downloadSettingsState = state.copy(
                    mutationInProgress = true,
                    mutationResult = null,
                    mutationFailure = null,
                    mutationRefreshFailure = null,
                    mutationRefreshCompleted = false,
                    mutationGeneration = generation,
                ),
                message = null,
            )
            DownloadSettingsMutationClaim(
                repository = repo,
                profileId = current.profile.id,
                generation = generation,
                baseline = baseline,
                desired = settings,
            )
        } ?: return false
        val repo = claim.repository
        val profileId = claim.profileId
        val generation = claim.generation
        val baseline = claim.baseline
        val desired = claim.desired
        viewModelScope.launch {
            val outcome = runCatching { repo.saveDownloadSettingsResult(baseline, desired) }
            val result = outcome.getOrNull() ?: outcome.exceptionOrNull()
                ?.takeIf { it is CancellationException }
                ?.let { cancelledDownloadSettingsResult() }
            val refreshedOutcome = if (result?.submitted == true || result?.requiresRefresh == true) {
                runCatching { repo.loadDownloadSettings() }
            } else {
                null
            }
            synchronized(downloadSettingsMutationLock) {
                val current = _workspace.value ?: return@synchronized
                val state = current.downloadSettingsState
                if (repository !== repo || current.profile.id != profileId ||
                    state.mutationGeneration != generation ||
                    downloadSettingsMutationGeneration.get() != generation
                ) return@synchronized
                val refreshed = refreshedOutcome?.getOrNull()
                val failure = outcome.exceptionOrNull()?.takeUnless { it is CancellationException }
                    ?.asDsmFailure()
                val refreshFailure = refreshedOutcome?.exceptionOrNull()
                    ?.takeUnless { it is CancellationException }?.asDsmFailure()
                _workspace.value = current.copy(
                    downloadSettings = refreshed?.let { Loadable.Ready(it) } ?: current.downloadSettings,
                    downloadSettingsState = state.copy(
                        baseline = refreshed ?: state.baseline,
                        draft = refreshed?.let(DownloadSettingsDraftState::from) ?: state.draft,
                        mutationInProgress = false,
                        mutationResult = result,
                        mutationFailure = failure,
                        mutationRefreshFailure = refreshFailure,
                        mutationRefreshCompleted = refreshed != null,
                    ),
                )
            }
        }
        return true
    }

    fun refreshDownloadSettingsMutation() {
        val claim = synchronized(downloadSettingsMutationLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            val state = current.downloadSettingsState
            if (!state.editorVisible || state.mutationInProgress || state.mutationRefreshInProgress ||
                (state.mutationResult == null && state.mutationFailure == null)
            ) return@synchronized null
            val generation = state.mutationGeneration
            _workspace.value = current.copy(
                downloadSettingsState = state.copy(
                    mutationRefreshInProgress = true,
                    mutationRefreshFailure = null,
                    mutationRefreshCompleted = false,
                ),
            )
            Triple(repo, current.profile.id, generation)
        } ?: return
        viewModelScope.launch {
            val outcome = runCatching { claim.first.loadDownloadSettings() }
            synchronized(downloadSettingsMutationLock) {
                val current = _workspace.value ?: return@synchronized
                val state = current.downloadSettingsState
                if (repository !== claim.first || current.profile.id != claim.second ||
                    state.mutationGeneration != claim.third ||
                    downloadSettingsMutationGeneration.get() != claim.third
                ) return@synchronized
                val refreshed = outcome.getOrNull()
                val failure = outcome.exceptionOrNull()?.takeUnless { it is CancellationException }
                    ?.asDsmFailure()
                _workspace.value = current.copy(
                    downloadSettings = refreshed?.let { Loadable.Ready(it) } ?: current.downloadSettings,
                    downloadSettingsState = state.copy(
                        baseline = refreshed ?: state.baseline,
                        draft = refreshed?.let(DownloadSettingsDraftState::from) ?: state.draft,
                        mutationRefreshInProgress = false,
                        mutationRefreshFailure = failure,
                        mutationRefreshCompleted = refreshed != null,
                    ),
                )
            }
        }
    }

    fun dismissDownloadSettingsMutation(): Boolean = synchronized(downloadSettingsMutationLock) {
        val current = _workspace.value ?: return@synchronized false
        val state = current.downloadSettingsState
        if ((state.mutationResult == null && state.mutationFailure == null) ||
            !canDismissDownloadSettingsMutation(state)
        ) return@synchronized false
        _workspace.value = current.copy(
            downloadSettingsState = state.copy(
                mutationResult = null,
                mutationFailure = null,
                mutationRefreshFailure = null,
                mutationRefreshCompleted = false,
            ),
        )
        true
    }

    fun openDownloadDestinationFolder(folder: FileItem) {
        if (!folder.isDirectory) return
        val repo = repository ?: return
        val current = _workspace.value?.downloadDestinationPicker ?: return
        val next = current.enter(folder)
        _workspace.update {
            it?.copy(
                downloadDestinationPicker = next,
                downloadDestinationFolders = Loadable.Loading,
            )
        }
        viewModelScope.launch { loadDownloadDestinationFolders(repo, next) }
    }

    fun goBackDownloadDestinationFolder() {
        val repo = repository ?: return
        val current = _workspace.value?.downloadDestinationPicker ?: return
        val next = current.goBack() ?: return
        _workspace.update {
            it?.copy(
                downloadDestinationPicker = next,
                downloadDestinationFolders = Loadable.Loading,
            )
        }
        viewModelScope.launch { loadDownloadDestinationFolders(repo, next) }
    }

    fun retryDownloadDestinationFolders() {
        val repo = repository ?: return
        val picker = _workspace.value?.downloadDestinationPicker ?: return
        _workspace.update { it?.copy(downloadDestinationFolders = Loadable.Loading) }
        viewModelScope.launch { loadDownloadDestinationFolders(repo, picker) }
    }

    fun cancelDownloadDestinationSelection() {
        _workspace.update {
            it?.copy(
                downloadDestinationPicker = null,
                downloadDestinationFolders = Loadable.Idle,
                downloadDestinationEditState = if (
                    it.downloadDestinationEditState.selectionTaskBaseline != null &&
                    it.downloadDestinationEditState.target == null
                ) {
                    DownloadDestinationEditWorkspaceState()
                } else {
                    it.downloadDestinationEditState
                },
            )
        }
    }

    fun beginDownloadTaskDestinationSelection(taskId: String): Boolean =
        synchronized(downloadDestinationEditMutationLock) {
            val repo = repository ?: return@synchronized false
            val current = _workspace.value ?: return@synchronized false
            if (!current.supportsDownloadTaskDestinationEditing ||
                current.selectedModule != Module.DOWNLOADS || current.isPerformingAction ||
                current.downloadCreationState.target != null || current.downloadControlState.target != null ||
                current.downloadSettingsState.editorVisible || current.downloadRssRefreshState.target != null ||
                current.downloadDestinationEditState != DownloadDestinationEditWorkspaceState()
            ) return@synchronized false
            val normalizedId = taskId.trim().takeIf(String::isNotEmpty) ?: return@synchronized false
            val task = (current.downloads as? Loadable.Ready)?.value.orEmpty()
                .mapNotNull(::canonicalDownloadTask)
                .filter { it.id == normalizedId }
                .singleOrNull() ?: return@synchronized false
            val picker = DownloadDestinationPickerState()
            _workspace.value = current.copy(
                downloadDestinationPicker = picker,
                downloadDestinationFolders = Loadable.Loading,
                downloadDestinationEditState = DownloadDestinationEditWorkspaceState(
                    selectionTaskBaseline = task,
                ),
            )
            viewModelScope.launch { loadDownloadDestinationFolders(repo, picker) }
            true
        }

    fun requestDownloadDestinationEdit(): Boolean = synchronized(downloadDestinationEditMutationLock) {
        val current = _workspace.value ?: return@synchronized false
        val state = current.downloadDestinationEditState
        val task = state.selectionTaskBaseline ?: return@synchronized false
        val destination = current.downloadDestinationPicker?.location?.baseline
            ?: return@synchronized false
        val target = downloadDestinationEditTarget(
            current.profile.id,
            current.downloads,
            task.id,
            destination,
        ) ?: return@synchronized false
        if (DownloadTaskMutationBaseline.from(target.taskBaseline) !=
            DownloadTaskMutationBaseline.from(task)
        ) return@synchronized false
        val generation = downloadDestinationEditMutationGeneration.incrementAndGet()
        downloadListRequestGeneration.incrementAndGet()
        _workspace.value = current.copy(
            downloadDestinationPicker = null,
            downloadDestinationFolders = Loadable.Idle,
            downloadDestinationEditState = DownloadDestinationEditWorkspaceState(
                target = target.copy(taskBaseline = task),
                confirmationRequested = true,
                mutationGeneration = generation,
            ),
        )
        true
    }

    fun cancelDownloadDestinationEdit() {
        synchronized(downloadDestinationEditMutationLock) {
            val current = _workspace.value ?: return
            val state = current.downloadDestinationEditState
            if (!state.confirmationRequested || state.mutationInProgress) return
            downloadDestinationEditMutationGeneration.incrementAndGet()
            _workspace.value = current.copy(
                downloadDestinationEditState = DownloadDestinationEditWorkspaceState(),
            )
        }
    }

    fun openDownloadCreationEditor(): Boolean = synchronized(downloadCreationMutationLock) {
        val current = _workspace.value ?: return false
        if (
            current.selectedModule != Module.DOWNLOADS || current.downloadControlState.target != null ||
            current.downloadSettingsState.editorVisible || current.downloadRssRefreshState.target != null ||
            current.downloadDestinationEditState != DownloadDestinationEditWorkspaceState() ||
            !canStartDownloadCreation(current.isPerformingAction, current.downloadCreationState)
        ) {
            return false
        }
        if (current.downloadCreationState.pendingDiscoveryUri != null) return false
        _workspace.value = current.copy(
            downloadCreationState = current.downloadCreationState.copy(editorVisible = true),
        )
        true
    }

    fun updateDownloadCreationDraft(uri: String, destination: String) =
        synchronized(downloadCreationMutationLock) {
            val current = _workspace.value ?: return
            val creation = current.downloadCreationState
            if (!creation.editorVisible || creation.mutationInProgress) return
            _workspace.value = current.copy(
                downloadCreationState = creation.copy(
                    uriDraft = uri.take(MAX_DOWNLOAD_CREATION_DRAFT_CHARACTERS),
                    destinationDraft = destination.take(MAX_DOWNLOAD_CREATION_DESTINATION_CHARACTERS),
                ),
            )
        }

    fun closeDownloadCreationEditor(): Boolean = synchronized(downloadCreationMutationLock) {
        val current = _workspace.value ?: return false
        val creation = current.downloadCreationState
        if (creation.mutationInProgress || creation.mutationRefreshInProgress) return false
        _workspace.value = current.copy(
            downloadCreationState = creation.copy(
                editorVisible = false,
                uriDraft = "",
                destinationDraft = "",
                pendingDiscoveryTitle = null,
                pendingDiscoveryUri = null,
                pendingDiscoverySource = null,
            ),
        )
        true
    }

    fun beginDiscoveryDownloadCreation(
        title: String,
        uri: String,
        sourceKind: DownloadCreationSourceKind,
    ): Boolean = synchronized(downloadCreationMutationLock) {
        val current = _workspace.value ?: return false
        if (sourceKind !in setOf(DownloadCreationSourceKind.RSS, DownloadCreationSourceKind.BT_SEARCH) ||
            current.selectedModule != Module.DOWNLOADS || current.downloadControlState.target != null ||
            current.downloadSettingsState.editorVisible || current.downloadRssRefreshState.target != null ||
            current.downloadDestinationEditState != DownloadDestinationEditWorkspaceState() ||
            !canStartDownloadCreation(current.isPerformingAction, current.downloadCreationState) ||
            current.downloadCreationState.editorVisible ||
            current.downloadCreationState.pendingDiscoveryUri != null
        ) return false
        _workspace.value = current.copy(
            downloadCreationState = current.downloadCreationState.copy(
                pendingDiscoveryTitle = title.take(MAX_DOWNLOAD_CREATION_TITLE_CHARACTERS),
                pendingDiscoveryUri = uri.take(MAX_DOWNLOAD_CREATION_DRAFT_CHARACTERS),
                pendingDiscoverySource = sourceKind,
            ),
        )
        true
    }

    fun cancelDiscoveryDownloadCreation() = synchronized(downloadCreationMutationLock) {
        val current = _workspace.value ?: return
        if (current.downloadCreationState.mutationInProgress) return
        _workspace.value = current.copy(
            downloadCreationState = current.downloadCreationState.copy(
                pendingDiscoveryTitle = null,
                pendingDiscoveryUri = null,
                pendingDiscoverySource = null,
            ),
        )
    }

    fun createDownload(
        uri: String,
        destination: String?,
        sourceKind: DownloadCreationSourceKind = if (
            uri.trim().startsWith("magnet:", ignoreCase = true)
        ) DownloadCreationSourceKind.MAGNET else DownloadCreationSourceKind.LINK,
    ): Boolean {
        val normalizedDestination = destination?.trim()?.takeIf(String::isNotEmpty)
        val target = downloadCreationTarget(
            profileId = _workspace.value?.profile?.id ?: return false,
            sourceKind = sourceKind,
            sourceIdentity = uri.trim(),
            destination = normalizedDestination,
        )
        val editableDraft = if (sourceKind in setOf(
                DownloadCreationSourceKind.LINK,
                DownloadCreationSourceKind.MAGNET,
            )
        ) uri to destination.orEmpty() else null
        return launchDownloadCreation(target, editableDraft) { repo ->
            repo.createDownloadResult(uri, normalizedDestination)
        }
    }

    fun createDownloadFromFile(uri: Uri): Boolean {
        val target = downloadCreationTarget(
            profileId = _workspace.value?.profile?.id ?: return false,
            sourceKind = DownloadCreationSourceKind.TASK_FILE,
            sourceIdentity = uri.toString(),
            destination = null,
        )
        return launchDownloadCreation(target, editableDraft = null) { repo ->
            repo.createDownloadFromFileResult(resolveUploadSource(uri))
        }
    }

    fun openDownloadTaskDetails(task: DownloadTask) {
        cancelOpaqueExternalNavigation(consumePending = true)
        _workspace.update { current ->
            val currentTask = current
                ?.takeIf { it.selectedModule == Module.DOWNLOADS }
                ?.downloads
                ?.let { it as? Loadable.Ready }
                ?.value
                ?.firstOrNull { candidate -> candidate.id == task.id }
            current?.copy(downloadDetailsTask = currentTask) ?: current
        }
    }

    fun closeDownloadTaskDetails() {
        _workspace.update { it?.copy(downloadDetailsTask = null) }
    }

    fun requestDownloadPause(taskId: String): Boolean =
        requestDownloadControl(taskId, DownloadControlOperation.PAUSE)

    fun requestDownloadResume(taskId: String): Boolean =
        requestDownloadControl(taskId, DownloadControlOperation.RESUME)

    fun requestDownloadDeletion(taskId: String, deleteFiles: Boolean): Boolean =
        synchronized(downloadControlMutationLock) {
            val current = _workspace.value ?: return false
            val operation = if (deleteFiles) {
                DownloadControlOperation.DELETE_TASK_AND_FILES
            } else {
                DownloadControlOperation.DELETE_TASK
            }
            if (!canStartDownloadControlMutation(
                    current.isPerformingAction,
                    current.downloadControlState,
                ) || current.selectedModule != Module.DOWNLOADS ||
                current.downloadCreationState.target != null ||
                current.downloadDestinationEditState != DownloadDestinationEditWorkspaceState() ||
                current.downloadSettingsState.editorVisible || current.downloadRssRefreshState.target != null
            ) return false
            val target = downloadControlTarget(
                current.profile.id,
                current.downloads,
                taskId,
                operation,
            ) ?: return false
            val generation = downloadControlMutationGeneration.incrementAndGet()
            downloadListRequestGeneration.incrementAndGet()
            downloadActivityGeneration.incrementAndGet()
            _workspace.value = current.copy(
                downloadControlState = DownloadControlWorkspaceState(
                    target = target,
                    confirmationRequested = true,
                    mutationGeneration = generation,
                ),
            )
            true
        }

    fun cancelDownloadDeletion() {
        synchronized(downloadControlMutationLock) {
            val current = _workspace.value ?: return
            val control = current.downloadControlState
            if (!control.confirmationRequested || control.mutationInProgress) return
            downloadControlMutationGeneration.incrementAndGet()
            _workspace.value = current.copy(downloadControlState = DownloadControlWorkspaceState())
        }
    }

    fun confirmDownloadDeletion(): Boolean {
        val repo = repository ?: return false
        lateinit var target: DownloadControlTarget
        var generation = 0L
        val profileId = synchronized(downloadControlMutationLock) {
            val current = _workspace.value ?: return false
            val control = current.downloadControlState
            val requested = control.target
            if (
                repository !== repo || current.isPerformingAction || !control.confirmationRequested ||
                current.selectedModule != Module.DOWNLOADS || current.downloadCreationState.target != null ||
                current.downloadSettingsState.editorVisible ||
                current.downloadDestinationEditState != DownloadDestinationEditWorkspaceState() ||
                control.mutationInProgress || requested == null || !requested.operation.isDeletion
            ) return false
            if (!downloadControlTargetIsCurrent(requested, current.profile.id, current.downloads)) {
                _workspace.value = current.copy(
                    downloadControlState = control.copy(
                        mutationFailure = downloadControlTargetChangedFailure(),
                    ),
                )
                return false
            }
            target = requested
            generation = downloadControlMutationGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                downloadControlState = control.copy(
                    confirmationRequested = false,
                    mutationInProgress = true,
                    mutationResult = null,
                    mutationFailure = null,
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = false,
                    mutationRefreshCompleted = false,
                    mutationRefreshMatches = null,
                    mutationGeneration = generation,
                ),
            )
            current.profile.id
        }
        launchDownloadControlMutation(repo, profileId, target, generation)
        return true
    }

    private fun requestDownloadControl(
        taskId: String,
        operation: DownloadControlOperation,
    ): Boolean {
        require(!operation.isDeletion) { "download_control.confirmation_required" }
        val repo = repository ?: return false
        lateinit var target: DownloadControlTarget
        var generation = 0L
        val profileId = synchronized(downloadControlMutationLock) {
            val current = _workspace.value ?: return false
            if (repository !== repo || current.selectedModule != Module.DOWNLOADS ||
                current.downloadCreationState.target != null ||
                current.downloadSettingsState.editorVisible ||
                current.downloadDestinationEditState != DownloadDestinationEditWorkspaceState() ||
                current.downloadRssRefreshState.target != null || !canStartDownloadControlMutation(
                    current.isPerformingAction,
                    current.downloadControlState,
                )
            ) return false
            target = downloadControlTarget(
                current.profile.id,
                current.downloads,
                taskId,
                operation,
            ) ?: return false
            generation = downloadControlMutationGeneration.incrementAndGet()
            downloadListRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                downloadControlState = DownloadControlWorkspaceState(
                    target = target,
                    mutationInProgress = true,
                    mutationGeneration = generation,
                ),
            )
            current.profile.id
        }
        launchDownloadControlMutation(repo, profileId, target, generation)
        return true
    }

    private fun launchDownloadControlMutation(
        repo: DsmRepository,
        profileId: String,
        target: DownloadControlTarget,
        generation: Long,
    ) {
        viewModelScope.launch {
            try {
                val result = repo.controlDownloadsResult(
                    listOf(DownloadTaskMutationBaseline.from(target.taskBaseline)),
                    target.operation.repositoryAction,
                )
                val accepted = synchronized(downloadControlMutationLock) {
                    val current = _workspace.value
                    if (current == null || !downloadControlCallbackMatches(
                            repositoryMatches = repository === repo,
                            profileMatches = current.profile.id == profileId,
                            stateTarget = current.downloadControlState.target,
                            callbackTarget = target,
                            stateGeneration = current.downloadControlState.mutationGeneration,
                            callbackGeneration = generation,
                            globalGeneration = downloadControlMutationGeneration.get(),
                        )
                    ) return@synchronized false
                    _workspace.value = current.copy(
                        isPerformingAction = false,
                        downloadControlState = current.downloadControlState.copy(
                            mutationInProgress = false,
                            mutationResult = result,
                            mutationFailure = null,
                        ),
                    )
                    true
                }
                if (accepted && (result.submitted || result.requiresRefresh)) {
                    refreshDownloadControlMutation()
                }
            } catch (error: CancellationException) {
                if (finishDownloadControlMutationCancellation(repo, profileId, target, generation)) {
                    refreshDownloadControlMutation()
                }
                throw error
            } catch (error: Throwable) {
                finishDownloadControlMutationFailure(
                    repo,
                    profileId,
                    target,
                    generation,
                    error.asDsmFailure(),
                )
            }
        }
    }

    private fun finishDownloadControlMutationCancellation(
        repo: DsmRepository,
        profileId: String,
        target: DownloadControlTarget,
        generation: Long,
    ): Boolean = synchronized(downloadControlMutationLock) {
        val current = _workspace.value ?: return false
        if (!downloadControlCallbackMatches(
                repositoryMatches = repository === repo,
                profileMatches = current.profile.id == profileId,
                stateTarget = current.downloadControlState.target,
                callbackTarget = target,
                stateGeneration = current.downloadControlState.mutationGeneration,
                callbackGeneration = generation,
                globalGeneration = downloadControlMutationGeneration.get(),
            )
        ) return false
        _workspace.value = current.copy(
            isPerformingAction = false,
            downloadControlState = current.downloadControlState.copy(
                mutationInProgress = false,
                mutationResult = cancelledDownloadControlResult(target),
                mutationFailure = null,
            ),
        )
        true
    }

    private fun finishDownloadControlMutationFailure(
        repo: DsmRepository,
        profileId: String,
        target: DownloadControlTarget,
        generation: Long,
        failure: DsmFailure?,
    ) {
        synchronized(downloadControlMutationLock) {
            val current = _workspace.value ?: return
            if (!downloadControlCallbackMatches(
                    repositoryMatches = repository === repo,
                    profileMatches = current.profile.id == profileId,
                    stateTarget = current.downloadControlState.target,
                    callbackTarget = target,
                    stateGeneration = current.downloadControlState.mutationGeneration,
                    callbackGeneration = generation,
                    globalGeneration = downloadControlMutationGeneration.get(),
                )
            ) return
            _workspace.value = current.copy(
                isPerformingAction = false,
                downloadControlState = current.downloadControlState.copy(
                    mutationInProgress = false,
                    mutationFailure = failure,
                ),
            )
        }
    }

    fun refreshDownloadControlMutation() {
        val repo = repository ?: return
        lateinit var target: DownloadControlTarget
        var generation = 0L
        val profileId = synchronized(downloadControlMutationLock) {
            val current = _workspace.value ?: return
            val control = current.downloadControlState
            if (
                repository !== repo || current.isPerformingAction || control.target == null ||
                control.confirmationRequested || control.mutationInProgress ||
                control.mutationRefreshInProgress ||
                control.mutationResult == null && control.mutationFailure == null
            ) return
            target = control.target
            generation = downloadControlMutationGeneration.incrementAndGet()
            downloadListRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                downloadControlState = control.copy(
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = true,
                    mutationRefreshCompleted = false,
                    mutationRefreshMatches = null,
                    mutationGeneration = generation,
                ),
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val refreshed = repo.activeDownloadTasksForMutation()
                synchronized(downloadControlMutationLock) {
                    val current = _workspace.value ?: return@synchronized
                    if (!downloadControlCallbackMatches(
                            repositoryMatches = repository === repo,
                            profileMatches = current.profile.id == profileId,
                            stateTarget = current.downloadControlState.target,
                            callbackTarget = target,
                            stateGeneration = current.downloadControlState.mutationGeneration,
                            callbackGeneration = generation,
                            globalGeneration = downloadControlMutationGeneration.get(),
                        )
                    ) return@synchronized
                    _workspace.value = current.withDownloads(Loadable.Ready(refreshed)).copy(
                        isPerformingAction = false,
                        downloadControlState = current.downloadControlState.copy(
                            mutationRefreshFailure = null,
                            mutationRefreshInProgress = false,
                            // 表示严格作用域列表读取已经成功；目标是否匹配由
                            // 同代严格快照单独记录，不能把“不同”伪装成读取失败。
                            mutationRefreshCompleted = true,
                            mutationRefreshMatches = downloadControlRefreshMatches(target, refreshed),
                        ),
                    )
                }
            } catch (error: CancellationException) {
                finishDownloadControlRefreshFailure(repo, profileId, target, generation, null)
                throw error
            } catch (error: Throwable) {
                finishDownloadControlRefreshFailure(
                    repo,
                    profileId,
                    target,
                    generation,
                    error.asDsmFailure(),
                )
            }
        }
    }

    private fun finishDownloadControlRefreshFailure(
        repo: DsmRepository,
        profileId: String,
        target: DownloadControlTarget,
        generation: Long,
        failure: DsmFailure?,
    ) {
        synchronized(downloadControlMutationLock) {
            val current = _workspace.value ?: return
            if (!downloadControlCallbackMatches(
                    repositoryMatches = repository === repo,
                    profileMatches = current.profile.id == profileId,
                    stateTarget = current.downloadControlState.target,
                    callbackTarget = target,
                    stateGeneration = current.downloadControlState.mutationGeneration,
                    callbackGeneration = generation,
                    globalGeneration = downloadControlMutationGeneration.get(),
                )
            ) return
            _workspace.value = current.copy(
                isPerformingAction = false,
                downloadControlState = current.downloadControlState.copy(
                    mutationRefreshFailure = failure,
                    mutationRefreshInProgress = false,
                    mutationRefreshCompleted = false,
                    mutationRefreshMatches = null,
                ),
            )
        }
    }

    fun dismissDownloadControlMutation(): Boolean = synchronized(downloadControlMutationLock) {
        val current = _workspace.value ?: return false
        if (!canDismissDownloadControlMutation(current.downloadControlState)) return false
        downloadControlMutationGeneration.incrementAndGet()
        _workspace.value = current.copy(downloadControlState = DownloadControlWorkspaceState())
        true
    }

    fun confirmDownloadDestinationEdit(): Boolean {
        val repo = repository ?: return false
        lateinit var target: DownloadDestinationEditTarget
        var generation = 0L
        val profileId = synchronized(downloadDestinationEditMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.downloadDestinationEditState
            val requested = state.target
            if (repository !== repo || current.isPerformingAction ||
                current.selectedModule != Module.DOWNLOADS || !state.confirmationRequested ||
                state.mutationInProgress || requested == null ||
                current.downloadCreationState.target != null || current.downloadControlState.target != null ||
                current.downloadSettingsState.editorVisible || current.downloadRssRefreshState.target != null
            ) return false
            if (!downloadDestinationEditTargetIsCurrent(requested, current.profile.id, current.downloads)) {
                _workspace.value = current.copy(
                    downloadDestinationEditState = state.copy(
                        mutationFailure = downloadControlTargetChangedFailure(),
                    ),
                )
                return false
            }
            target = requested
            generation = downloadDestinationEditMutationGeneration.incrementAndGet()
            downloadListRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                downloadDestinationEditState = state.copy(
                    confirmationRequested = false,
                    mutationInProgress = true,
                    mutationResult = null,
                    mutationFailure = null,
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = false,
                    mutationRefreshCompleted = false,
                    mutationRefreshMatches = null,
                    mutationGeneration = generation,
                ),
            )
            current.profile.id
        }
        viewModelScope.launch {
            val outcome = try {
                Result.success(
                repo.editDownloadDestinationResult(
                    DownloadTaskMutationBaseline.from(target.taskBaseline),
                    target.destinationBaseline,
                ),
                )
            } catch (error: CancellationException) {
                val accepted = finishDownloadDestinationEditCancellation(
                    repo,
                    profileId,
                    target,
                    generation,
                )
                if (accepted) refreshDownloadDestinationEditMutation()
                throw error
            } catch (error: Throwable) {
                Result.failure(error)
            }
            val result = outcome.getOrNull()
            val failure = outcome.exceptionOrNull()?.asDsmFailure()
            val persistentResult = result
            val accepted = synchronized(downloadDestinationEditMutationLock) {
                val current = _workspace.value
                if (current == null || !downloadDestinationEditCallbackMatches(
                        repositoryMatches = repository === repo,
                        profileMatches = current.profile.id == profileId,
                        stateTarget = current.downloadDestinationEditState.target,
                        callbackTarget = target,
                        stateGeneration = current.downloadDestinationEditState.mutationGeneration,
                        callbackGeneration = generation,
                        globalGeneration = downloadDestinationEditMutationGeneration.get(),
                    )
                ) return@synchronized false
                _workspace.value = current.copy(
                    isPerformingAction = false,
                    downloadDestinationEditState = current.downloadDestinationEditState.copy(
                        mutationInProgress = false,
                        mutationResult = persistentResult,
                        mutationFailure = failure,
                    ),
                )
                true
            }
            if (accepted && (failure != null || persistentResult?.let {
                    it.submitted || it.requiresRefresh || it.counts.unknown > 0
                } == true)
            ) {
                refreshDownloadDestinationEditMutation()
            }
        }
        return true
    }

    private fun finishDownloadDestinationEditCancellation(
        repo: DsmRepository,
        profileId: String,
        target: DownloadDestinationEditTarget,
        generation: Long,
    ): Boolean = synchronized(downloadDestinationEditMutationLock) {
        val current = _workspace.value ?: return@synchronized false
        val state = current.downloadDestinationEditState
        if (!downloadDestinationEditCallbackMatches(
                repositoryMatches = repository === repo,
                profileMatches = current.profile.id == profileId,
                stateTarget = state.target,
                callbackTarget = target,
                stateGeneration = state.mutationGeneration,
                callbackGeneration = generation,
                globalGeneration = downloadDestinationEditMutationGeneration.get(),
            )
        ) return@synchronized false
        _workspace.value = current.copy(
            isPerformingAction = false,
            downloadDestinationEditState = state.copy(
                mutationInProgress = false,
                mutationResult = cancelledDownloadDestinationEditResult(),
                mutationFailure = null,
            ),
        )
        true
    }

    fun refreshDownloadDestinationEditMutation() {
        val repo = repository ?: return
        lateinit var target: DownloadDestinationEditTarget
        var generation = 0L
        val profileId = synchronized(downloadDestinationEditMutationLock) {
            val current = _workspace.value ?: return
            val state = current.downloadDestinationEditState
            if (repository !== repo || current.isPerformingAction || state.target == null ||
                state.confirmationRequested || state.mutationInProgress || state.mutationRefreshInProgress ||
                state.mutationResult == null && state.mutationFailure == null
            ) return
            target = state.target
            generation = downloadDestinationEditMutationGeneration.incrementAndGet()
            downloadListRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                downloadDestinationEditState = state.copy(
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = true,
                    mutationRefreshCompleted = false,
                    mutationRefreshMatches = null,
                    mutationGeneration = generation,
                ),
            )
            current.profile.id
        }
        viewModelScope.launch {
            val outcome = try {
                Result.success(repo.activeDownloadTasksForMutation())
            } catch (error: CancellationException) {
                synchronized(downloadDestinationEditMutationLock) {
                    val current = _workspace.value ?: return@synchronized
                    val state = current.downloadDestinationEditState
                    if (downloadDestinationEditCallbackMatches(
                            repositoryMatches = repository === repo,
                            profileMatches = current.profile.id == profileId,
                            stateTarget = state.target,
                            callbackTarget = target,
                            stateGeneration = state.mutationGeneration,
                            callbackGeneration = generation,
                            globalGeneration = downloadDestinationEditMutationGeneration.get(),
                        )
                    ) {
                        _workspace.value = current.copy(
                            isPerformingAction = false,
                            downloadDestinationEditState = state.copy(
                                mutationRefreshInProgress = false,
                                mutationRefreshCompleted = false,
                                mutationRefreshMatches = null,
                            ),
                        )
                    }
                }
                throw error
            } catch (error: Throwable) {
                Result.failure(error)
            }
            synchronized(downloadDestinationEditMutationLock) {
                val current = _workspace.value ?: return@synchronized
                val state = current.downloadDestinationEditState
                if (!downloadDestinationEditCallbackMatches(
                        repositoryMatches = repository === repo,
                        profileMatches = current.profile.id == profileId,
                        stateTarget = state.target,
                        callbackTarget = target,
                        stateGeneration = state.mutationGeneration,
                        callbackGeneration = generation,
                        globalGeneration = downloadDestinationEditMutationGeneration.get(),
                    )
                ) return@synchronized
                val refreshed = outcome.getOrNull()
                _workspace.value = current.withDownloads(
                    refreshed?.let { Loadable.Ready(it) } ?: current.downloads,
                ).copy(
                    isPerformingAction = false,
                    downloadDestinationEditState = state.copy(
                        mutationRefreshFailure = outcome.exceptionOrNull()
                            ?.takeUnless { it is CancellationException }
                            ?.asDsmFailure(),
                        mutationRefreshInProgress = false,
                        mutationRefreshCompleted = refreshed != null,
                        mutationRefreshMatches = refreshed?.let {
                            downloadDestinationEditRefreshMatches(target, it)
                        },
                    ),
                )
            }
        }
    }

    fun dismissDownloadDestinationEditMutation(): Boolean =
        synchronized(downloadDestinationEditMutationLock) {
            val current = _workspace.value ?: return@synchronized false
            if (!canDismissDownloadDestinationEditMutation(current.downloadDestinationEditState)) {
                return@synchronized false
            }
            downloadDestinationEditMutationGeneration.incrementAndGet()
            _workspace.value = current.copy(
                downloadDestinationEditState = DownloadDestinationEditWorkspaceState(),
            )
            true
        }

    fun controlContainer(id: String, command: String) = containerMutation(
        success = R.string.container_state_updated,
    ) { repo ->
        repo.controlContainerResult(id, command)
    }

    fun deleteContainer(id: String) = containerMutation(
        success = R.string.container_deleted,
    ) { repo ->
        repo.deleteContainerResult(id)
    }

    fun deleteContainerImage(id: String) = containerMutation(
        success = R.string.image_deleted,
    ) { repo ->
        repo.deleteContainerImageResult(id)
    }

    fun createContainerNetwork(name: String, driver: String) = containerMutation(
        success = R.string.network_created,
    ) { repo ->
        repo.createContainerNetworkResult(name, driver)
    }

    fun deleteContainerNetwork(id: String) = containerMutation(
        success = R.string.network_deleted,
    ) { repo ->
        repo.deleteContainerNetworkResult(id)
    }

    /** 外部固定页只在当前容器模块与既有能力门禁均满足时打开。 */
    internal fun navigateToContainerRegistry(): WorkspaceNavigationResult {
        val state = _workspace.value ?: return WorkspaceNavigationResult.DEFERRED
        if (state.availability.firstOrNull { it.module == Module.CONTAINERS }?.isAvailable == false ||
            !state.supportsContainerRegistry
        ) {
            _workspace.value = state.copy(
                message = getApplication<Application>().getString(R.string.module_unavailable_generic),
            )
            return WorkspaceNavigationResult.REJECTED
        }
        val moduleResult = navigateTo(WorkspaceRoute.ModuleRoot(Module.CONTAINERS))
        if (moduleResult == WorkspaceNavigationResult.DEFERRED ||
            moduleResult == WorkspaceNavigationResult.REJECTED
        ) return moduleResult
        if (_workspace.value?.containerRegistryVisible == true) {
            return WorkspaceNavigationResult.ALREADY_SELECTED
        }
        showContainerRegistry()
        return if (_workspace.value?.containerRegistryVisible == true) {
            WorkspaceNavigationResult.APPLIED
        } else {
            WorkspaceNavigationResult.REJECTED
        }
    }

    fun showContainerRegistry() {
        val state = _workspace.value ?: return
        if (state.selectedModule != Module.CONTAINERS || !state.supportsContainerRegistry) return
        if (state.containerRegistryVisible) return
        containerRegistrySearchGeneration.incrementAndGet()
        containerRegistryTagsGeneration.incrementAndGet()
        _workspace.update { current ->
            current?.takeIf {
                it.selectedModule == Module.CONTAINERS && it.supportsContainerRegistry
            }?.copy(
                containerRegistryVisible = true,
                containerRegistryResults = current.containerRegistryResults.takeUnless { value ->
                    value is Loadable.Loading
                } ?: Loadable.Idle,
                selectedContainerRegistryImage = null,
                containerRegistryTags = Loadable.Idle,
            ) ?: current
        }
    }

    fun closeContainerRegistry() {
        containerRegistrySearchGeneration.incrementAndGet()
        containerRegistryTagsGeneration.incrementAndGet()
        _workspace.update {
            it?.copy(
                containerRegistryVisible = false,
                containerRegistryResults = it.containerRegistryResults.takeUnless { value ->
                    value is Loadable.Loading
                } ?: Loadable.Idle,
                selectedContainerRegistryImage = null,
                containerRegistryTags = Loadable.Idle,
            )
        }
    }

    fun updateContainerRegistryQuery(value: String) {
        if (value.length > 200) return
        if (_workspace.value?.containerRegistryQuery == value) return
        containerRegistrySearchGeneration.incrementAndGet()
        containerRegistryTagsGeneration.incrementAndGet()
        _workspace.update {
            it?.copy(
                containerRegistryQuery = value,
                containerRegistryResults = Loadable.Idle,
                selectedContainerRegistryImage = null,
                containerRegistryTags = Loadable.Idle,
            )
        }
    }

    fun searchContainerRegistry() {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        if (!state.containerRegistryVisible || state.selectedModule != Module.CONTAINERS) return
        val query = state.containerRegistryQuery.trim()
        if (query.isEmpty()) return
        val token = ContainerRegistrySearchToken(
            generation = containerRegistrySearchGeneration.incrementAndGet(),
            profileId = state.profile.id,
            query = query,
        )
        containerRegistryTagsGeneration.incrementAndGet()
        _workspace.update {
            it?.copy(
                containerRegistryResults = Loadable.Loading,
                selectedContainerRegistryImage = null,
                containerRegistryTags = Loadable.Idle,
            )
        }
        viewModelScope.launch {
            capture(
                block = { repo.searchContainerRegistry(query) },
                update = { value ->
                    _workspace.update { state ->
                        if (repository === repo && state?.matchesContainerRegistrySearch(
                                token,
                                containerRegistrySearchGeneration.get(),
                            ) == true
                        ) {
                            state.copy(containerRegistryResults = value)
                        } else state
                    }
                },
            )
        }
    }

    fun selectContainerRegistryImage(image: ContainerRegistryImage) {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        if (!state.containerRegistryVisible || state.selectedModule != Module.CONTAINERS) return
        val token = ContainerRegistryTagsToken(
            generation = containerRegistryTagsGeneration.incrementAndGet(),
            profileId = state.profile.id,
            imageId = image.id,
        )
        _workspace.update {
            it?.copy(
                selectedContainerRegistryImage = image,
                containerRegistryTags = Loadable.Loading,
            )
        }
        viewModelScope.launch {
            capture(
                block = { repo.containerRegistryTags(image.name) },
                update = { value ->
                    _workspace.update { state ->
                        if (repository === repo && state?.matchesContainerRegistryTags(
                                token,
                                containerRegistryTagsGeneration.get(),
                            ) == true
                        ) {
                            state.copy(containerRegistryTags = value)
                        } else state
                    }
                },
            )
        }
    }

    fun openVirtualMachineCreationEditor(): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        val state = current.virtualMachineMutationState
        if (current.selectedModule != Module.VIRTUAL_MACHINES ||
            !current.supportsOfficialVirtualMachineCreation || overview.storages.isEmpty() ||
            state.creationEditorVisible || state.settingsEditorVisible ||
            state.imageImportEditorVisible ||
            state.lifecycleConfirmationRequested ||
            state.taskCleanupConfirmationRequested ||
            !canStartVirtualMachineMutation(current.isPerformingAction, state)
        ) return false
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(
                creationEditorVisible = true,
                creationDraft = VirtualMachineCreationDraftState(
                    storageId = overview.storages.first().id,
                ),
            ),
        )
        true
    }

    fun updateVirtualMachineCreationDraft(
        draft: VirtualMachineCreationDraftState,
    ): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.virtualMachineMutationState
        if (!state.creationEditorVisible || state.target != null || state.mutationInProgress ||
            state.mutationRefreshInProgress || draft.step !in 0..2
        ) return false
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(creationDraft = draft),
        )
        true
    }

    fun closeVirtualMachineCreationEditor(): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.virtualMachineMutationState
        if (!state.creationEditorVisible || state.target != null || state.mutationInProgress ||
            state.mutationRefreshInProgress
        ) return false
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(
                creationEditorVisible = false,
                creationDraft = null,
            ),
        )
        true
    }

    fun confirmVirtualMachineCreation(): Boolean {
        val desired = synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            if (!state.creationEditorVisible || state.target != null ||
                state.mutationInProgress || state.mutationRefreshInProgress
            ) return false
            state.creationDraft?.toCreationOrNull()
        } ?: return false
        return createVirtualMachine(desired)
    }

    fun openVirtualMachineImageImportEditor(): Boolean = synchronized(virtualMachineMutationLock) {
        val repo = repository ?: return false
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        val state = current.virtualMachineMutationState
        val storage = overview.storages.firstOrNull {
            it.isEligibleForVirtualMachineImageImport()
        } ?: return false
        if (current.selectedModule != Module.VIRTUAL_MACHINES ||
            !current.supportsOfficialVirtualMachineImageImport ||
            state.creationEditorVisible || state.imageImportEditorVisible ||
            state.settingsEditorVisible || state.lifecycleConfirmationRequested ||
            state.taskCleanupConfirmationRequested ||
            !canStartVirtualMachineMutation(current.isPerformingAction, state)
        ) return false
        val generation = virtualMachineImageBrowserGeneration.incrementAndGet()
        val draft = VirtualMachineImageImportDraftState(
            storage = storage,
            browserItems = Loadable.Loading,
        )
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(
                imageImportEditorVisible = true,
                imageImportDraft = draft,
            ),
        )
        viewModelScope.launch { loadVirtualMachineImageBrowser(repo, "", generation) }
        syncVirtualMachineLocalImageImports(current.profile.id)
        true
    }

    fun updateVirtualMachineImageImportDraft(
        draft: VirtualMachineImageImportDraftState,
    ): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.virtualMachineMutationState
        val existing = state.imageImportDraft ?: return false
        if (!state.imageImportEditorVisible || state.target != null || state.mutationInProgress ||
            state.mutationRefreshInProgress || draft.browserPath != existing.browserPath ||
            draft.browserHistory != existing.browserHistory ||
            draft.browserItems != existing.browserItems
        ) return false
        val next = if (existing.source == VirtualMachineImageImportSource.LOCAL &&
            draft.source == VirtualMachineImageImportSource.NAS
        ) {
            releasePendingVirtualMachineLocalImageGrant()
            draft.copy(localFile = null, localStagingDirectory = null)
        } else draft
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(imageImportDraft = next),
        )
        true
    }

    fun selectVirtualMachineLocalImage(uri: Uri): Boolean {
        val resolver = getApplication<Application>().contentResolver
        val metadata = runCatching {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                val name = nameIndex.takeIf { it >= 0 }?.let(cursor::getString)
                    ?: return@use null
                val size = sizeIndex.takeIf { it >= 0 && !cursor.isNull(it) }
                    ?.let(cursor::getLong)
                VirtualMachineLocalImageSelection(name, size)
            }
        }.getOrNull() ?: return virtualMachineLocalImageSelectionFailed()
        val contentType = runCatching { resolver.getType(uri) }.getOrNull()
        val acquired = runCatching {
            resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
        }.getOrDefault(false)
        if (!acquired) return virtualMachineLocalImageSelectionFailed()
        val accepted = synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return@synchronized false
            val state = current.virtualMachineMutationState
            val draft = state.imageImportDraft ?: return@synchronized false
            if (!state.imageImportEditorVisible || draft.source != VirtualMachineImageImportSource.LOCAL ||
                state.target != null || state.mutationInProgress || state.mutationRefreshInProgress
            ) return@synchronized false
            val previous = pendingVirtualMachineLocalImageUri
            pendingVirtualMachineLocalImageUri = uri
            pendingVirtualMachineLocalImageContentType = contentType
            _workspace.value = current.copy(
                virtualMachineMutationState = state.copy(
                    imageImportDraft = draft.copy(
                        localFile = metadata,
                        imageName = draft.imageName.ifBlank {
                            metadata.displayName.substringBeforeLast('.')
                        },
                    ),
                ),
                message = null,
            )
            if (previous != null && previous != uri) releaseVirtualMachineLocalImageGrant(previous)
            true
        }
        if (!accepted) releaseVirtualMachineLocalImageGrant(uri)
        return accepted
    }

    private fun virtualMachineLocalImageSelectionFailed(): Boolean {
        _workspace.update { current ->
            current?.takeIf {
                it.virtualMachineMutationState.imageImportEditorVisible
            }?.copy(
                message = getApplication<Application>().getString(
                    R.string.virtual_machine_local_image_selection_failed,
                ),
            ) ?: current
        }
        return false
    }

    fun selectVirtualMachineImageImportStagingDirectory(item: FileItem): Boolean =
        synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            val draft = state.imageImportDraft ?: return false
            val page = (draft.browserItems as? Loadable.Ready)?.value ?: return false
            val selected = page.items.singleOrNull { it == item } ?: return false
            if (!state.imageImportEditorVisible ||
                draft.source != VirtualMachineImageImportSource.LOCAL ||
                !selected.isDirectory || !selected.canWrite || state.target != null ||
                state.mutationInProgress || state.mutationRefreshInProgress
            ) return false
            _workspace.value = current.copy(
                virtualMachineMutationState = state.copy(
                    imageImportDraft = draft.copy(localStagingDirectory = selected),
                ),
            )
            true
        }

    fun enterVirtualMachineImageImportFolder(item: FileItem): Boolean =
        synchronized(virtualMachineMutationLock) {
            val repo = repository ?: return false
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            val draft = state.imageImportDraft ?: return false
            val page = (draft.browserItems as? Loadable.Ready)?.value ?: return false
            val selected = page.items.singleOrNull { it == item } ?: return false
            if (!state.imageImportEditorVisible || !selected.isDirectory || !selected.canRead ||
                state.target != null || state.mutationInProgress || state.mutationRefreshInProgress
            ) return false
            val generation = virtualMachineImageBrowserGeneration.incrementAndGet()
            val next = draft.copy(
                sourceFile = null,
                browserPath = selected.path,
                browserHistory = draft.browserHistory + draft.browserPath,
                browserItems = Loadable.Loading,
            )
            _workspace.value = current.copy(
                virtualMachineMutationState = state.copy(imageImportDraft = next),
            )
            viewModelScope.launch { loadVirtualMachineImageBrowser(repo, selected.path, generation) }
            true
        }

    fun goBackVirtualMachineImageImportFolder(): Boolean = synchronized(virtualMachineMutationLock) {
        val repo = repository ?: return false
        val current = _workspace.value ?: return false
        val state = current.virtualMachineMutationState
        val draft = state.imageImportDraft ?: return false
        val previous = draft.browserHistory.lastOrNull() ?: return false
        if (!state.imageImportEditorVisible || state.target != null || state.mutationInProgress ||
            state.mutationRefreshInProgress
        ) return false
        val generation = virtualMachineImageBrowserGeneration.incrementAndGet()
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(
                imageImportDraft = draft.copy(
                    sourceFile = null,
                    browserPath = previous,
                    browserHistory = draft.browserHistory.dropLast(1),
                    browserItems = Loadable.Loading,
                ),
            ),
        )
        viewModelScope.launch { loadVirtualMachineImageBrowser(repo, previous, generation) }
        true
    }

    fun selectVirtualMachineImageImportFile(item: FileItem): Boolean =
        synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            val draft = state.imageImportDraft ?: return false
            val page = (draft.browserItems as? Loadable.Ready)?.value ?: return false
            val selected = page.items.singleOrNull { it == item } ?: return false
            if (!state.imageImportEditorVisible || selected.isDirectory || !selected.canRead ||
                state.target != null || state.mutationInProgress || state.mutationRefreshInProgress
            ) return false
            _workspace.value = current.copy(
                virtualMachineMutationState = state.copy(
                    imageImportDraft = draft.copy(
                        sourceFile = selected,
                        imageName = draft.imageName.ifBlank { selected.name.substringBeforeLast('.') },
                    ),
                ),
            )
            true
        }

    fun retryVirtualMachineImageImportBrowser(): Boolean = synchronized(virtualMachineMutationLock) {
        val repo = repository ?: return false
        val current = _workspace.value ?: return false
        val state = current.virtualMachineMutationState
        val draft = state.imageImportDraft ?: return false
        if (!state.imageImportEditorVisible || draft.browserItems !is Loadable.Failed ||
            state.target != null || state.mutationInProgress || state.mutationRefreshInProgress
        ) return false
        val generation = virtualMachineImageBrowserGeneration.incrementAndGet()
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(
                imageImportDraft = draft.copy(browserItems = Loadable.Loading),
            ),
        )
        viewModelScope.launch { loadVirtualMachineImageBrowser(repo, draft.browserPath, generation) }
        true
    }

    fun closeVirtualMachineImageImportEditor(): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.virtualMachineMutationState
        if (!state.imageImportEditorVisible || state.target != null || state.mutationInProgress ||
            state.mutationRefreshInProgress
        ) return false
        virtualMachineImageBrowserGeneration.incrementAndGet()
        releasePendingVirtualMachineLocalImageGrant()
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(
                imageImportEditorVisible = false,
                imageImportDraft = null,
            ),
        )
        true
    }

    fun confirmVirtualMachineImageImport(): Boolean {
        val desired = synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            if (!state.imageImportEditorVisible || state.target != null || state.mutationInProgress ||
                state.mutationRefreshInProgress
            ) return false
            state.imageImportDraft?.toImportOrNull()
        } ?: return false
        return importVirtualMachineImage(desired)
    }

    fun confirmVirtualMachineLocalImageImport(
        submission: VirtualMachineLocalImageImportSubmission,
    ): Boolean {
        val prepared = synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            val expected = state.imageImportDraft?.toLocalSubmissionOrNull()
            val uri = pendingVirtualMachineLocalImageUri
            if (!state.imageImportEditorVisible || state.target != null ||
                state.mutationInProgress || state.mutationRefreshInProgress ||
                expected != submission || uri == null
            ) return false
            val displayName = state.imageImportDraft?.localFile?.displayName ?: return false
            VirtualMachineLocalImagePreparation(
                current.profile.id,
                uri,
                pendingVirtualMachineLocalImageContentType,
                displayName,
            )
        }
        val profileId = prepared.profileId
        val recordId = UUID.randomUUID().toString()
        val record = PersistedVirtualMachineImageImport(
            id = recordId,
            profileId = profileId,
            sourceUri = prepared.uri.toString(),
            sourceDisplayName = prepared.displayName,
            expectedBytes = submission.image.originalSizeBytes,
            stagingDirectoryPath = submission.stagingDirectory.path,
            temporaryFileName = ".lanstash-vmm-$recordId${submission.image.safeTemporaryFileSuffix()}",
            imageName = submission.imageName,
            imageType = submission.image.imageType.toPersistedVirtualMachineImageType(),
            storageId = submission.storage.id,
            sourceContentType = prepared.contentType,
            storageName = submission.storage.name,
            storageStatus = submission.storage.metadata["status"].orEmpty(),
        )
        val workId = VirtualMachineImageImportWorker.enqueue(getApplication(), record)
        if (workId == null) {
            releaseVirtualMachineLocalImageGrant(prepared.uri)
            synchronized(virtualMachineMutationLock) {
                pendingVirtualMachineLocalImageUri = null
                pendingVirtualMachineLocalImageContentType = null
                _workspace.value = _workspace.value?.let { current ->
                    current.copy(
                        virtualMachineMutationState = current.virtualMachineMutationState.copy(
                            imageImportDraft = current.virtualMachineMutationState.imageImportDraft
                                ?.copy(localFile = null),
                        ),
                    )
                }
            }
            syncVirtualMachineLocalImageImports(profileId)
            return false
        }
        synchronized(virtualMachineMutationLock) {
            pendingVirtualMachineLocalImageUri = null
            pendingVirtualMachineLocalImageContentType = null
            _workspace.value = _workspace.value?.let { current ->
                current.copy(
                    virtualMachineMutationState = current.virtualMachineMutationState.copy(
                        imageImportEditorVisible = false,
                        imageImportDraft = null,
                    ),
                )
            }
        }
        syncVirtualMachineLocalImageImports(profileId)
        monitorVirtualMachineImageImport(recordId, workId)
        return true
    }

    fun openVirtualMachineSettingsEditor(id: String): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        val resource = overview.machines.firstOrNull { it.id == id } ?: return false
        val state = current.virtualMachineMutationState
        if (current.selectedModule != Module.VIRTUAL_MACHINES ||
            !current.supportsOfficialVirtualMachineSettings || state.creationEditorVisible ||
            state.imageImportEditorVisible || state.settingsEditorVisible ||
            state.lifecycleConfirmationRequested ||
            state.taskCleanupConfirmationRequested ||
            !canStartVirtualMachineMutation(current.isPerformingAction, state)
        ) return false
        val baseline = virtualMachineSettingsBaseline(resource) ?: return false
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(
                settingsEditorVisible = true,
                settingsTargetId = resource.id,
                settingsBaseline = baseline,
                settingsDraft = VirtualMachineSettingsDraftState.from(baseline),
            ),
        )
        true
    }

    fun updateVirtualMachineSettingsDraft(
        draft: VirtualMachineSettingsDraftState,
    ): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.virtualMachineMutationState
        if (!state.settingsEditorVisible || state.target != null || state.mutationInProgress ||
            state.mutationRefreshInProgress
        ) return false
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(settingsDraft = draft),
        )
        true
    }

    fun closeVirtualMachineSettingsEditor(): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.virtualMachineMutationState
        if (!state.settingsEditorVisible || state.target != null || state.mutationInProgress ||
            state.mutationRefreshInProgress
        ) return false
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(
                settingsEditorVisible = false,
                settingsTargetId = null,
                settingsBaseline = null,
                settingsDraft = null,
            ),
        )
        true
    }

    fun confirmVirtualMachineSettings(): Boolean {
        val claim = synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            val id = state.settingsTargetId ?: return false
            val desired = state.settingsDraft?.toSettingsOrNull() ?: return false
            if (!state.settingsEditorVisible || state.settingsBaseline == null ||
                desired == state.settingsBaseline || state.target != null ||
                state.mutationInProgress || state.mutationRefreshInProgress
            ) return false
            id to desired
        }
        return updateVirtualMachineSettings(claim.first, claim.second)
    }

    fun requestVirtualMachineLifecycleConfirmation(
        id: String,
        operation: VirtualMachineLifecycleOperation,
        command: String? = null,
    ): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        val state = current.virtualMachineMutationState
        val normalizedId = id.trim()
        val resource = when (operation) {
            VirtualMachineLifecycleOperation.DELETE_IMAGE -> overview.images
            VirtualMachineLifecycleOperation.DELETE_NETWORK,
            VirtualMachineLifecycleOperation.RENAME_NETWORK,
            -> overview.networks
            else -> overview.machines
        }.firstOrNull { it.id == normalizedId }
        if (resource == null || current.selectedModule != Module.VIRTUAL_MACHINES ||
            state.creationEditorVisible || state.settingsEditorVisible ||
            state.imageImportEditorVisible ||
            state.lifecycleConfirmationRequested ||
            !canStartVirtualMachineMutation(current.isPerformingAction, state)
        ) return false
        val target = runCatching {
            VirtualMachineLifecycleTarget(
                profileId = current.profile.id,
                resourceId = normalizedId,
                operation = operation,
                baselineState = resource.state,
                command = command?.trim(),
            )
        }.getOrNull() ?: return false
        _workspace.value = current.copy(
            virtualMachineMutationState = state.copy(
                lifecycleConfirmationTarget = target,
                lifecycleConfirmationRequested = true,
            ),
        )
        true
    }

    fun cancelVirtualMachineLifecycleConfirmation(): Boolean =
        synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            if (!state.lifecycleConfirmationRequested || state.mutationInProgress) return false
            _workspace.value = current.copy(
                virtualMachineMutationState = state.copy(
                    lifecycleConfirmationTarget = null,
                    lifecycleConfirmationRequested = false,
                ),
            )
            true
        }

    fun requestVirtualMachineTaskCleanupConfirmation(): Boolean =
        synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
            val state = current.virtualMachineMutationState
            val finished = overview.tasks.filter(VirtualMachineTask::isFinished)
            if (current.selectedModule != Module.VIRTUAL_MACHINES || finished.isEmpty() ||
                state.creationEditorVisible || state.imageImportEditorVisible ||
                state.settingsEditorVisible || state.lifecycleConfirmationRequested ||
                state.taskCleanupConfirmationRequested ||
                !canStartVirtualMachineMutation(current.isPerformingAction, state)
            ) return false
            _workspace.value = current.copy(
                virtualMachineMutationState = state.copy(
                    taskCleanupConfirmationRequested = true,
                    taskCleanupBaseline = overview.tasks,
                ),
            )
            true
        }

    fun cancelVirtualMachineTaskCleanupConfirmation(): Boolean =
        synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            if (!state.taskCleanupConfirmationRequested || state.mutationInProgress) return false
            _workspace.value = current.copy(
                virtualMachineMutationState = state.copy(
                    taskCleanupConfirmationRequested = false,
                    taskCleanupBaseline = emptyList(),
                ),
            )
            true
        }

    fun confirmVirtualMachineTaskCleanup(): Boolean {
        val baseline = synchronized(virtualMachineMutationLock) {
            val state = _workspace.value?.virtualMachineMutationState ?: return false
            if (!state.taskCleanupConfirmationRequested ||
                state.taskCleanupBaseline.none(VirtualMachineTask::isFinished) ||
                state.mutationInProgress || state.mutationRefreshInProgress
            ) return false
            state.taskCleanupBaseline
        }
        return clearFinishedVirtualMachineTasks(baseline)
    }

    fun confirmVirtualMachineLifecycle(): Boolean = synchronized(virtualMachineMutationLock) {
        val state = _workspace.value?.virtualMachineMutationState ?: return false
        val target = state.lifecycleConfirmationTarget ?: return false
        if (!state.lifecycleConfirmationRequested || state.mutationInProgress ||
            state.mutationRefreshInProgress
        ) return false
        when (target.operation) {
            VirtualMachineLifecycleOperation.CONTROL ->
                controlVirtualMachine(
                    target.resourceId,
                    target.baselineState,
                    checkNotNull(target.command),
                )
            VirtualMachineLifecycleOperation.DELETE_MACHINE ->
                deleteVirtualMachine(target.resourceId, target.baselineState)
            VirtualMachineLifecycleOperation.DELETE_IMAGE ->
                deleteVirtualMachineImage(target.resourceId, target.baselineState)
            VirtualMachineLifecycleOperation.DELETE_NETWORK ->
                deleteVirtualMachineNetwork(target.resourceId, target.baselineState)
            VirtualMachineLifecycleOperation.RENAME_NETWORK ->
                renameVirtualMachineNetwork(
                    target.resourceId,
                    target.baselineState,
                    checkNotNull(target.command),
                )
        }
    }

    fun controlVirtualMachine(id: String, command: String): Boolean {
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        val normalizedId = id.trim()
        val baselineState = overview.machines.firstOrNull { it.id == normalizedId }?.state
            ?: return false
        return controlVirtualMachine(normalizedId, baselineState, command.trim())
    }

    private fun controlVirtualMachine(
        id: String,
        baselineState: ResourceState,
        command: String,
    ): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val normalizedCommand = command.trim()
        if (virtualMachineControlExpectedState(baselineState, normalizedCommand) == null) return false
        val lifecycle = VirtualMachineLifecycleTarget(
            profileId = profileId,
            resourceId = id.trim(),
            operation = VirtualMachineLifecycleOperation.CONTROL,
            baselineState = baselineState,
            command = normalizedCommand,
        )
        val target = virtualMachineMutationTarget(
            profileId,
            VirtualMachineMutationKind.LIFECYCLE,
            "virtualMachineControl",
            id,
            listOf(baselineState.name, normalizedCommand),
        )
        return virtualMachineMutation(
            target,
            R.string.virtual_machine_state_updated,
            lifecycleTarget = lifecycle,
        ) { repo, _ ->
            repo.controlVirtualMachineResult(id, baselineState, normalizedCommand)
        }
    }

    private fun clearFinishedVirtualMachineTasks(baseline: List<VirtualMachineTask>): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val finished = baseline.filter(VirtualMachineTask::isFinished)
        if (finished.isEmpty()) return false
        val target = virtualMachineMutationTarget(
            profileId = profileId,
            kind = VirtualMachineMutationKind.TASK_CLEANUP,
            operation = "virtualMachineTaskCleanup",
            resourceId = null,
            requestParts = finished.map(VirtualMachineTask::taskToken).sorted(),
        )
        return virtualMachineMutation(
            target = target,
            success = R.string.virtual_machine_tasks_cleared,
            taskCleanupBaseline = baseline,
        ) { repo, generation ->
            repo.clearFinishedVirtualMachineTasksResult(baseline) { resolved ->
                recordVirtualMachineTaskCleanupResolvedResult(
                    repo,
                    profileId,
                    target,
                    generation,
                    resolved,
                )
            }
        }
    }

    private fun recordVirtualMachineTaskCleanupResolvedResult(
        repo: DsmRepository,
        profileId: String,
        target: VirtualMachineMutationTarget,
        generation: Long,
        result: MutationResult,
    ) {
        synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return
            val state = current.virtualMachineMutationState
            if (!virtualMachineMutationCallbackMatches(
                    repositoryMatches = repository === repo,
                    profileMatches = current.profile.id == profileId,
                    stateTarget = state.target,
                    callbackTarget = target,
                    stateGeneration = state.mutationGeneration,
                    callbackGeneration = generation,
                    globalGeneration = virtualMachineMutationGeneration.get(),
                )
            ) return
            _workspace.value = current.copy(
                virtualMachineMutationState = state.copy(taskCleanupResolvedResult = result),
            )
        }
    }

    fun createVirtualMachine(configuration: VirtualMachineCreation): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val target = virtualMachineMutationTarget(
            profileId,
            VirtualMachineMutationKind.CREATION,
            "virtualMachineCreate",
            resourceId = null,
            requestParts = listOf(
                configuration.name.trim(),
                configuration.description.trim(),
                configuration.cpuCount.toString(),
                configuration.memoryMiB.toString(),
                configuration.diskGiB.toString(),
                configuration.storageId.trim(),
                configuration.networkId?.trim().orEmpty(),
                configuration.diskImageId?.trim().orEmpty(),
                configuration.autoStart.toString(),
            ) + configuration.additionalDisks.flatMapIndexed { index, disk ->
                listOf(
                    "disk:$index",
                    disk.sizeGiB.toString(),
                    disk.diskImageId?.trim().orEmpty(),
                )
            } + configuration.additionalNetworkInterfaces.flatMapIndexed { index, network ->
                listOf("network:$index", network.networkId?.trim().orEmpty())
            },
        )
        return virtualMachineMutation(
            target,
            R.string.virtual_machine_created,
            creationDraft = VirtualMachineCreationDraftState.from(configuration),
        ) { repo, _ ->
            repo.createVirtualMachineResult(configuration)
        }
    }

    fun importVirtualMachineImage(configuration: VirtualMachineImageImport): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val target = virtualMachineMutationTarget(
            profileId,
            VirtualMachineMutationKind.IMAGE_IMPORT,
            "virtualMachineImageImport",
            resourceId = null,
            requestParts = listOf(
                configuration.imageName.trim(),
                configuration.imageType.apiValue,
                configuration.sourceFile.path,
                configuration.sourceFile.size.toString(),
                configuration.sourceFile.modifiedAtEpochSeconds?.toString().orEmpty(),
                configuration.storage.id,
                configuration.storage.name,
                configuration.storage.state.name,
            ),
        )
        val draft = _workspace.value?.virtualMachineMutationState?.imageImportDraft ?: return false
        return virtualMachineMutation(
            target,
            R.string.virtual_machine_image_imported,
            imageImportDraft = draft,
        ) { repo, claimGeneration ->
            repo.importVirtualMachineImageResult(
                configuration,
                onTaskStarted = { taskId ->
                    synchronized(virtualMachineMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        val state = current.virtualMachineMutationState
                        if (virtualMachineMutationCallbackMatches(
                                repositoryMatches = repository === repo,
                                profileMatches = current.profile.id == target.profileId,
                                stateTarget = state.target,
                                callbackTarget = target,
                                stateGeneration = state.mutationGeneration,
                                callbackGeneration = claimGeneration,
                                globalGeneration = virtualMachineMutationGeneration.get(),
                            ) && state.mutationInProgress && state.imageImportTaskId == null
                        ) {
                            _workspace.value = current.copy(
                                virtualMachineMutationState = state.copy(imageImportTaskId = taskId),
                            )
                        }
                    }
                },
            )
        }
    }

    fun updateVirtualMachineSettings(id: String, settings: VirtualMachineSettings): Boolean {
        val current = _workspace.value ?: return false
        val profileId = current.profile.id
        val mutation = current.virtualMachineMutationState
        val baseline = mutation.settingsBaseline?.takeIf { mutation.settingsTargetId == id } ?: run {
            val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
            overview.machines.firstOrNull { it.id == id }?.let(::virtualMachineSettingsBaseline)
                ?: return false
        }
        val target = virtualMachineMutationTarget(
            profileId,
            VirtualMachineMutationKind.SETTINGS,
            "virtualMachineSettings",
            id,
            listOf(
                settings.name.trim(),
                settings.description.trim(),
                settings.cpuCount.toString(),
                settings.memoryMiB.toString(),
                settings.autoStart.toString(),
            ),
        )
        return virtualMachineMutation(
            target,
            R.string.virtual_machine_settings_updated,
            settingsTargetId = id,
            settingsBaseline = baseline,
            settingsDraft = VirtualMachineSettingsDraftState.from(settings),
        ) { repo, _ ->
            repo.updateVirtualMachineSettingsResult(id, baseline, settings)
        }
    }

    fun deleteVirtualMachine(id: String): Boolean {
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        val normalizedId = id.trim()
        val baselineState = overview.machines.firstOrNull { it.id == normalizedId }?.state
            ?: return false
        return deleteVirtualMachine(normalizedId, baselineState)
    }

    private fun deleteVirtualMachine(id: String, baselineState: ResourceState): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val lifecycle = VirtualMachineLifecycleTarget(
            profileId = profileId,
            resourceId = id.trim(),
            operation = VirtualMachineLifecycleOperation.DELETE_MACHINE,
            baselineState = baselineState,
        )
        val target = virtualMachineMutationTarget(
            profileId,
            VirtualMachineMutationKind.LIFECYCLE,
            "virtualMachineDelete",
            id,
            listOf(baselineState.name),
        )
        return virtualMachineMutation(
            target,
            R.string.virtual_machine_deleted,
            lifecycleTarget = lifecycle,
        ) { repo, _ ->
            repo.deleteVirtualMachineResult(id)
        }
    }

    fun deleteVirtualMachineImage(id: String): Boolean {
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        val normalizedId = id.trim()
        val baselineState = overview.images.firstOrNull { it.id == normalizedId }?.state
            ?: return false
        return deleteVirtualMachineImage(normalizedId, baselineState)
    }

    private fun deleteVirtualMachineImage(id: String, baselineState: ResourceState): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val lifecycle = VirtualMachineLifecycleTarget(
            profileId = profileId,
            resourceId = id.trim(),
            operation = VirtualMachineLifecycleOperation.DELETE_IMAGE,
            baselineState = baselineState,
        )
        val target = virtualMachineMutationTarget(
            profileId,
            VirtualMachineMutationKind.LIFECYCLE,
            "virtualMachineImageDelete",
            id,
            listOf(baselineState.name),
        )
        return virtualMachineMutation(target, R.string.image_deleted, lifecycleTarget = lifecycle) { repo, _ ->
            repo.deleteVirtualMachineImageResult(id)
        }
    }

    fun renameVirtualMachineNetwork(id: String, name: String): Boolean {
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        val normalizedId = id.trim()
        val baselineState = overview.networks.firstOrNull { it.id == normalizedId }?.state
            ?: return false
        return renameVirtualMachineNetwork(normalizedId, baselineState, name.trim())
    }

    private fun renameVirtualMachineNetwork(
        id: String,
        baselineState: ResourceState,
        name: String,
    ): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val lifecycle = VirtualMachineLifecycleTarget(
            profileId = profileId,
            resourceId = id.trim(),
            operation = VirtualMachineLifecycleOperation.RENAME_NETWORK,
            baselineState = baselineState,
            command = name.trim(),
        )
        val target = virtualMachineMutationTarget(
            profileId,
            VirtualMachineMutationKind.LIFECYCLE,
            "virtualMachineNetworkRename",
            id,
            listOf(baselineState.name, name.trim()),
        )
        return virtualMachineMutation(target, R.string.network_changed, lifecycleTarget = lifecycle) { repo, _ ->
            repo.renameVirtualMachineNetworkResult(id, name)
        }
    }

    fun deleteVirtualMachineNetwork(id: String): Boolean {
        val current = _workspace.value ?: return false
        val overview = (current.virtualMachines as? Loadable.Ready)?.value ?: return false
        val normalizedId = id.trim()
        val baselineState = overview.networks.firstOrNull { it.id == normalizedId }?.state
            ?: return false
        return deleteVirtualMachineNetwork(normalizedId, baselineState)
    }

    private fun deleteVirtualMachineNetwork(id: String, baselineState: ResourceState): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val lifecycle = VirtualMachineLifecycleTarget(
            profileId = profileId,
            resourceId = id.trim(),
            operation = VirtualMachineLifecycleOperation.DELETE_NETWORK,
            baselineState = baselineState,
        )
        val target = virtualMachineMutationTarget(
            profileId,
            VirtualMachineMutationKind.LIFECYCLE,
            "virtualMachineNetworkDelete",
            id,
            listOf(baselineState.name),
        )
        return virtualMachineMutation(target, R.string.network_deleted, lifecycleTarget = lifecycle) { repo, _ ->
            repo.deleteVirtualMachineNetworkResult(id)
        }
    }

    fun requestPackageMutation(
        target: PackageInfo,
        operation: PackageMutationOperation,
    ): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
        if (
            current == null || snapshot == null || !canRequestPackageMutation(snapshot, target, operation) ||
            current.isPerformingAction || current.packageMutationTarget != null ||
            current.packageMutationConfirmationRequested || current.packageMutationInProgress ||
            current.packageMutationRefreshInProgress || current.packageMutationResult != null ||
            current.packageMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                packageMutationTarget = target,
                packageMutationOperation = operation,
                packageMutationConfirmationRequested = true,
                packageMutationRefreshFailure = null,
                packageMutationRefreshCompleted = false,
            )
            true
        }
    }

    fun cancelPackageMutationConfirmation(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current == null || !current.packageMutationConfirmationRequested ||
            current.packageMutationInProgress || current.packageMutationResult != null ||
            current.packageMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                packageMutationTarget = null,
                packageMutationOperation = null,
                packageMutationConfirmationRequested = false,
            )
            true
        }
    }

    fun confirmPackageMutation(): Boolean {
        val repo = repository ?: return false
        lateinit var target: PackageInfo
        lateinit var operation: PackageMutationOperation
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            val snapshot = (current.nasSettings as? Loadable.Ready)?.value ?: return false
            target = current.packageMutationTarget ?: return false
            operation = current.packageMutationOperation ?: return false
            if (
                repository !== repo || current.isPerformingAction ||
                !current.packageMutationConfirmationRequested ||
                !canRequestPackageMutation(snapshot, target, operation) ||
                current.packageMutationInProgress || current.packageMutationResult != null ||
                current.packageMutationFailure != null
            ) return false
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                packageMutationConfirmationRequested = false,
                packageMutationInProgress = true,
                packageMutationResult = null,
                packageMutationFailure = null,
                packageMutationRefreshFailure = null,
                packageMutationRefreshInProgress = true,
                packageMutationRefreshCompleted = false,
                packageMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = when (operation) {
                    PackageMutationOperation.START -> repo.controlPackageResult(target, "start")
                    PackageMutationOperation.STOP -> repo.controlPackageResult(target, "stop")
                    PackageMutationOperation.UNINSTALL -> repo.uninstallPackageResult(target)
                }
                val shouldRefresh = result.submitted || result.requiresRefresh ||
                    destructiveServiceMutationRequiresRefreshBeforeDismiss(result)
                var refreshFailure: DsmFailure? = null
                val packages = if (shouldRefresh) try {
                    when (operation) {
                        PackageMutationOperation.START,
                        PackageMutationOperation.STOP,
                        -> repo.activePackagesForControl()
                        PackageMutationOperation.UNINSTALL -> repo.activePackagesForUninstall()
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    refreshFailure = error.asDsmFailure()
                    null
                } else null
                _workspace.update { current ->
                    current?.takeIf {
                        scopedMutationCallbackMatches(
                            repository === repo, it.profile.id == profileId,
                            it.packageMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                        )
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        val updated = when {
                            snapshot != null && packages != null -> snapshot.copy(
                                packages = packages,
                                packagesAvailable = true,
                            )
                            snapshot != null && result.status == MutationResultStatus.CONFIRMED_SUCCESS ->
                                confirmedPackageMutationFallback(snapshot, target, operation)
                            else -> null
                        }
                        active.copy(
                            nasSettings = updated?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            packageMutationInProgress = false,
                            packageMutationResult = result,
                            packageMutationRefreshFailure = refreshFailure,
                            packageMutationRefreshInProgress = false,
                            packageMutationRefreshCompleted = packages != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishPackageMutationFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishPackageMutationFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
        return true
    }

    private fun finishPackageMutationFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                scopedMutationCallbackMatches(
                    repository === repo, it.profile.id == profileId,
                    it.packageMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                )
            }?.copy(
                isPerformingAction = false,
                packageMutationInProgress = false,
                packageMutationFailure = failure,
                packageMutationRefreshInProgress = false,
            ) ?: current
        }
    }

    fun refreshPackageMutation() {
        val repo = repository ?: return
        lateinit var operation: PackageMutationOperation
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            if (
                repository !== repo || current.isPerformingAction || current.packageMutationTarget == null ||
                current.packageMutationInProgress || current.packageMutationRefreshInProgress ||
                current.packageMutationResult == null && current.packageMutationFailure == null
            ) return
            operation = current.packageMutationOperation ?: return
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                packageMutationRefreshFailure = null,
                packageMutationRefreshInProgress = true,
                packageMutationRefreshCompleted = false,
                packageMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val packages = when (operation) {
                    PackageMutationOperation.START,
                    PackageMutationOperation.STOP,
                    -> repo.activePackagesForControl()
                    PackageMutationOperation.UNINSTALL -> repo.activePackagesForUninstall()
                }
                _workspace.update { current ->
                    current?.takeIf {
                        scopedMutationCallbackMatches(
                            repository === repo, it.profile.id == profileId,
                            it.packageMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                        )
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        active.copy(
                            nasSettings = snapshot?.copy(
                                packages = packages,
                                packagesAvailable = true,
                            )?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            packageMutationRefreshInProgress = false,
                            packageMutationRefreshCompleted = snapshot != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishPackageRefreshFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishPackageRefreshFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
    }

    private fun finishPackageRefreshFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                scopedMutationCallbackMatches(
                    repository === repo, it.profile.id == profileId,
                    it.packageMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                )
            }?.copy(
                isPerformingAction = false,
                packageMutationRefreshFailure = failure,
                packageMutationRefreshInProgress = false,
            ) ?: current
        }
    }

    fun dismissPackageMutationResult(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val result = current?.packageMutationResult
        val requiresRefresh = result?.let(::destructiveServiceMutationRequiresRefreshBeforeDismiss) == true ||
            current?.packageMutationFailure != null
        if (
            current == null || current.isPerformingAction || current.packageMutationInProgress ||
            current.packageMutationRefreshInProgress ||
            requiresRefresh && !current.packageMutationRefreshCompleted
        ) false else {
            _workspace.value = current.copy(
                packageMutationTarget = null,
                packageMutationOperation = null,
                packageMutationConfirmationRequested = false,
                packageMutationResult = null,
                packageMutationFailure = null,
                packageMutationRefreshFailure = null,
                packageMutationRefreshInProgress = false,
                packageMutationRefreshCompleted = false,
            )
            true
        }
    }

    @Deprecated("Use the stable PackageInfo target and persistent confirmation state")
    fun controlPackage(id: String, command: String): Boolean {
        val operation = when (command) {
            "start" -> PackageMutationOperation.START
            "stop" -> PackageMutationOperation.STOP
            else -> return false
        }
        val target = ((_workspace.value?.nasSettings as? Loadable.Ready)?.value?.packages)
            ?.firstOrNull { it.id == id } ?: return false
        return requestPackageMutation(target, operation) && confirmPackageMutation()
    }

    @Deprecated("Use the stable PackageInfo target and persistent confirmation state")
    fun uninstallPackage(id: String): Boolean {
        val target = ((_workspace.value?.nasSettings as? Loadable.Ready)?.value?.packages)
            ?.firstOrNull { it.id == id } ?: return false
        return requestPackageMutation(target, PackageMutationOperation.UNINSTALL) && confirmPackageMutation()
    }

    fun requestConnectionDisconnect(
        connection: io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection,
    ): Boolean {
        return synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value
            val canonical = (current?.nasSettings as? Loadable.Ready)?.value?.connections
                ?.firstOrNull { it.id == connection.id }
            if (
                current == null || current.isPerformingAction || canonical?.canDisconnect != true ||
                current.connectionMutationInProgress || current.connectionMutationResult != null ||
                current.connectionMutationFailure != null
            ) {
                false
            } else {
                _workspace.value = current.copy(
                    connectionMutationTarget = canonical,
                    connectionMutationRefreshFailure = null,
                    connectionMutationRefreshCompleted = false,
                )
                true
            }
        }
    }

    fun cancelConnectionDisconnectRequest() {
        _workspace.update { current ->
            if (
                current?.connectionMutationInProgress == true ||
                current?.connectionMutationResult != null ||
                current?.connectionMutationFailure != null
            ) current else current?.copy(connectionMutationTarget = null)
        }
    }

    fun confirmConnectionDisconnect(): Boolean {
        val repo = repository ?: return false
        lateinit var connection: io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection
        var mutationGeneration = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            if (current.isPerformingAction || repository !== repo) return false
            connection = current.connectionMutationTarget ?: return false
            val canonical = (current.nasSettings as? Loadable.Ready)?.value?.connections
                ?.firstOrNull { it.id == connection.id }
            if (canonical?.canDisconnect != true || canonical != connection) return false
            mutationGeneration = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                connectionMutationInProgress = true,
                connectionMutationResult = null,
                connectionMutationFailure = null,
                connectionMutationRefreshFailure = null,
                connectionMutationRefreshInProgress = true,
                connectionMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.disconnectConnectionResult(connection.id)
                var automaticRefreshFailure: DsmFailure? = null
                val refreshedConnections = if (result.submitted || result.requiresRefresh) {
                    try {
                        repo.activeConnections()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        automaticRefreshFailure = error.asDsmFailure()
                        null
                    }
                } else {
                    null
                }
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == mutationGeneration
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        val verifiedConnections = refreshedConnections ?: snapshot?.connections?.let { cached ->
                            cached.filterNot { item ->
                                result.status == MutationResultStatus.CONFIRMED_SUCCESS &&
                                    item.id == connection.id
                            }
                        }
                        active.copy(
                            nasSettings = if (snapshot != null && verifiedConnections != null) {
                                Loadable.Ready(
                                    snapshot.copy(
                                        connections = verifiedConnections,
                                        connectionsAvailable = refreshedConnections != null ||
                                            snapshot.connectionsAvailable,
                                    ),
                                )
                            } else {
                                active.nasSettings
                            },
                            isPerformingAction = false,
                            connectionMutationInProgress = false,
                            connectionMutationResult = result,
                            connectionMutationRefreshFailure = automaticRefreshFailure,
                            connectionMutationRefreshCompleted = refreshedConnections != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == mutationGeneration
                    }?.copy(
                        isPerformingAction = false,
                        connectionMutationInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == mutationGeneration
                    }?.copy(
                        isPerformingAction = false,
                        connectionMutationInProgress = false,
                        connectionMutationFailure = error.asDsmFailure(),
                    ) ?: current
                }
            }
        }
        return true
    }

    fun refreshConnectionMutation() {
        val repo = repository ?: return
        var refreshGeneration = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            if (
                current.isPerformingAction || repository !== repo ||
                current.connectionMutationTarget == null || current.connectionMutationResult == null
            ) return
            refreshGeneration = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                connectionMutationRefreshFailure = null,
                connectionMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val connections = repo.activeConnections()
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == refreshGeneration
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        active.copy(
                            nasSettings = snapshot?.copy(
                                connections = connections,
                                connectionsAvailable = true,
                            )
                                ?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            connectionMutationRefreshInProgress = false,
                            connectionMutationRefreshCompleted = true,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == refreshGeneration
                    }?.copy(
                        isPerformingAction = false,
                        connectionMutationRefreshInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == refreshGeneration
                    }?.copy(
                        isPerformingAction = false,
                        connectionMutationRefreshInProgress = false,
                        connectionMutationRefreshFailure = error.asDsmFailure(),
                    ) ?: current
                }
            }
        }
    }

    fun dismissConnectionMutationResult() {
        _workspace.update { current ->
            val result = current?.connectionMutationResult
            if (
                current == null || current.connectionMutationInProgress || current.isPerformingAction ||
                result != null && connectionMutationRequiresRefreshBeforeDismiss(result) &&
                !current.connectionMutationRefreshCompleted
            ) return@update current
            current.copy(
                connectionMutationTarget = null,
                connectionMutationResult = null,
                connectionMutationFailure = null,
                connectionMutationRefreshFailure = null,
                connectionMutationRefreshInProgress = false,
                connectionMutationRefreshCompleted = false,
            )
        }
    }

    fun requestDirectoryDeletion(
        account: io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount,
    ): Boolean = requestDirectoryDeletion(
        DirectoryEntryMutationTarget(DirectoryEntryKind.ACCOUNT, account = account),
    )

    fun requestDirectoryDeletion(
        group: io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup,
    ): Boolean = requestDirectoryDeletion(
        DirectoryEntryMutationTarget(DirectoryEntryKind.GROUP, group = group),
    )

    fun requestDirectoryDeletion(target: DirectoryEntryMutationTarget): Boolean =
        synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value
            val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
            if (
                current == null || snapshot == null || !canRequestDirectoryDeletion(snapshot, target) ||
                current.isPerformingAction || current.directoryMutationTarget != null ||
                current.directoryMutationConfirmationRequested || current.directoryMutationInProgress ||
                current.directoryMutationRefreshInProgress || current.directoryMutationResult != null ||
                current.directoryMutationFailure != null
            ) false else {
                _workspace.value = current.copy(
                    directoryMutationTarget = target,
                    directoryMutationConfirmationRequested = true,
                    directoryMutationRefreshFailure = null,
                    directoryMutationRefreshCompleted = false,
                )
                true
            }
        }

    fun cancelDirectoryDeletionConfirmation(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current == null || !current.directoryMutationConfirmationRequested ||
            current.directoryMutationInProgress || current.directoryMutationResult != null ||
            current.directoryMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                directoryMutationTarget = null,
                directoryMutationConfirmationRequested = false,
            )
            true
        }
    }

    fun confirmDirectoryDeletion(): Boolean {
        val repo = repository ?: return false
        lateinit var target: DirectoryEntryMutationTarget
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            val snapshot = (current.nasSettings as? Loadable.Ready)?.value ?: return false
            target = current.directoryMutationTarget ?: return false
            if (
                repository !== repo || current.isPerformingAction ||
                !current.directoryMutationConfirmationRequested ||
                !canRequestDirectoryDeletion(snapshot, target) ||
                current.directoryMutationInProgress || current.directoryMutationResult != null ||
                current.directoryMutationFailure != null
            ) return false
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                directoryMutationConfirmationRequested = false,
                directoryMutationInProgress = true,
                directoryMutationResult = null,
                directoryMutationFailure = null,
                directoryMutationRefreshFailure = null,
                directoryMutationRefreshInProgress = true,
                directoryMutationRefreshCompleted = false,
                directoryMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = when (target.kind) {
                    DirectoryEntryKind.ACCOUNT -> repo.deleteAccountResult(checkNotNull(target.account))
                    DirectoryEntryKind.GROUP -> repo.deleteGroupResult(checkNotNull(target.group))
                }
                val shouldRefresh = result.submitted || result.requiresRefresh ||
                    destructiveServiceMutationRequiresRefreshBeforeDismiss(result)
                var refreshFailure: DsmFailure? = null
                var accounts: List<io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount>? = null
                var groups: List<io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup>? = null
                if (shouldRefresh) try {
                    when (target.kind) {
                        DirectoryEntryKind.ACCOUNT -> accounts = repo.activeAccounts()
                        DirectoryEntryKind.GROUP -> groups = repo.activeGroups()
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    refreshFailure = error.asDsmFailure()
                }
                val refreshed = accounts != null || groups != null
                _workspace.update { current ->
                    current?.takeIf {
                        scopedMutationCallbackMatches(
                            repository === repo, it.profile.id == profileId,
                            it.directoryMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                        )
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        val updated = when {
                            snapshot != null && accounts != null -> snapshot.copy(
                                accounts = checkNotNull(accounts),
                                accountsAvailable = true,
                            )
                            snapshot != null && groups != null -> snapshot.copy(
                                groups = checkNotNull(groups),
                                groupsAvailable = true,
                            )
                            snapshot != null && result.status == MutationResultStatus.CONFIRMED_SUCCESS ->
                                confirmedDirectoryDeletionFallback(snapshot, target)
                            else -> null
                        }
                        active.copy(
                            nasSettings = updated?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            directoryMutationInProgress = false,
                            directoryMutationResult = result,
                            directoryMutationRefreshFailure = refreshFailure,
                            directoryMutationRefreshInProgress = false,
                            directoryMutationRefreshCompleted = refreshed,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishDirectoryMutationFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishDirectoryMutationFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
        return true
    }

    private fun finishDirectoryMutationFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                scopedMutationCallbackMatches(
                    repository === repo, it.profile.id == profileId,
                    it.directoryMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                )
            }?.copy(
                isPerformingAction = false,
                directoryMutationInProgress = false,
                directoryMutationFailure = failure,
                directoryMutationRefreshInProgress = false,
            ) ?: current
        }
    }

    fun refreshDirectoryDeletionMutation() {
        val repo = repository ?: return
        lateinit var kind: DirectoryEntryKind
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            kind = current.directoryMutationTarget?.kind ?: return
            if (
                repository !== repo || current.isPerformingAction || current.directoryMutationInProgress ||
                current.directoryMutationRefreshInProgress ||
                current.directoryMutationResult == null && current.directoryMutationFailure == null
            ) return
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                directoryMutationRefreshFailure = null,
                directoryMutationRefreshInProgress = true,
                directoryMutationRefreshCompleted = false,
                directoryMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val accounts = if (kind == DirectoryEntryKind.ACCOUNT) repo.activeAccounts() else null
                val groups = if (kind == DirectoryEntryKind.GROUP) repo.activeGroups() else null
                _workspace.update { current ->
                    current?.takeIf {
                        scopedMutationCallbackMatches(
                            repository === repo, it.profile.id == profileId,
                            it.directoryMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                        )
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        active.copy(
                            nasSettings = snapshot?.let {
                                if (accounts != null) it.copy(accounts = accounts, accountsAvailable = true)
                                else it.copy(groups = checkNotNull(groups), groupsAvailable = true)
                            }?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            directoryMutationRefreshInProgress = false,
                            directoryMutationRefreshCompleted = snapshot != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishDirectoryRefreshFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishDirectoryRefreshFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
    }

    private fun finishDirectoryRefreshFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                scopedMutationCallbackMatches(
                    repository === repo, it.profile.id == profileId,
                    it.directoryMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                )
            }?.copy(
                isPerformingAction = false,
                directoryMutationRefreshFailure = failure,
                directoryMutationRefreshInProgress = false,
            ) ?: current
        }
    }

    fun dismissDirectoryDeletionResult(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val result = current?.directoryMutationResult
        val requiresRefresh = result?.let(::destructiveServiceMutationRequiresRefreshBeforeDismiss) == true ||
            current?.directoryMutationFailure != null
        if (
            current == null || current.isPerformingAction || current.directoryMutationInProgress ||
            current.directoryMutationRefreshInProgress ||
            requiresRefresh && !current.directoryMutationRefreshCompleted
        ) false else {
            _workspace.value = current.copy(
                directoryMutationTarget = null,
                directoryMutationConfirmationRequested = false,
                directoryMutationResult = null,
                directoryMutationFailure = null,
                directoryMutationRefreshFailure = null,
                directoryMutationRefreshInProgress = false,
                directoryMutationRefreshCompleted = false,
            )
            true
        }
    }

    @Deprecated("Use the stable NasAccount target and persistent confirmation state")
    fun deleteAccount(name: String): Boolean {
        val target = ((_workspace.value?.nasSettings as? Loadable.Ready)?.value?.accounts)
            ?.firstOrNull { it.name == name } ?: return false
        return requestDirectoryDeletion(target) && confirmDirectoryDeletion()
    }

    @Deprecated("Use the stable NasGroup target and persistent confirmation state")
    fun deleteGroup(name: String): Boolean {
        val target = ((_workspace.value?.nasSettings as? Loadable.Ready)?.value?.groups)
            ?.firstOrNull { it.name == name } ?: return false
        return requestDirectoryDeletion(target) && confirmDirectoryDeletion()
    }

    fun requestEthernetEditing(id: String): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val canonical = (current?.nasSettings as? Loadable.Ready)?.value?.networkInterfaces
            ?.firstOrNull { it.id == id }
        if (
            current == null || canonical == null || current.isPerformingAction ||
            current.ethernetEditorVisible || current.ethernetConfirmationRequested ||
            current.ethernetMutationInProgress || current.ethernetMutationRefreshInProgress ||
            current.ethernetMutationResult != null || current.ethernetMutationFailure != null
        ) {
            false
        } else {
            _workspace.value = current.copy(
                ethernetBaseline = canonical,
                ethernetSettingsDraft = canonical,
                ethernetEditorVisible = true,
                ethernetConfirmationRequested = false,
                ethernetMutationRefreshFailure = null,
                ethernetMutationRefreshCompleted = false,
            )
            true
        }
    }

    fun updateEthernetSettingsDraft(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface,
    ) {
        _workspace.update { current ->
            val baseline = current?.ethernetBaseline
            if (
                current == null || baseline == null || !current.ethernetEditorVisible ||
                current.ethernetConfirmationRequested || current.ethernetMutationInProgress ||
                current.ethernetMutationResult != null || current.ethernetMutationFailure != null ||
                value.id != baseline.id || value.displayName != baseline.displayName ||
                value.status != baseline.status
            ) {
                current
            } else {
                current.copy(ethernetSettingsDraft = value)
            }
        }
    }

    fun cancelEthernetEditing() {
        _workspace.update { current ->
            if (
                current == null || current.ethernetConfirmationRequested ||
                current.ethernetMutationInProgress || current.ethernetMutationResult != null ||
                current.ethernetMutationFailure != null
            ) {
                current
            } else {
                current.copy(
                    ethernetBaseline = null,
                    ethernetSettingsDraft = null,
                    ethernetEditorVisible = false,
                    ethernetMutationRefreshFailure = null,
                    ethernetMutationRefreshCompleted = false,
                )
            }
        }
    }

    fun requestEthernetSaveConfirmation(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val baseline = current?.ethernetBaseline
        val draft = current?.ethernetSettingsDraft
        if (
            current == null || baseline == null || draft == null || !current.ethernetEditorVisible ||
            current.isPerformingAction || current.ethernetMutationInProgress ||
            current.ethernetMutationResult != null || current.ethernetMutationFailure != null ||
            draft.id != baseline.id || draft.displayName != baseline.displayName ||
            draft.status != baseline.status || draft == baseline
        ) {
            false
        } else {
            _workspace.value = current.copy(
                ethernetEditorVisible = false,
                ethernetConfirmationRequested = true,
            )
            true
        }
    }

    fun cancelEthernetSaveConfirmation() {
        _workspace.update { current ->
            if (
                current == null || !current.ethernetConfirmationRequested ||
                current.ethernetMutationInProgress || current.ethernetMutationResult != null ||
                current.ethernetMutationFailure != null
            ) {
                current
            } else {
                current.copy(
                    ethernetEditorVisible = true,
                    ethernetConfirmationRequested = false,
                )
            }
        }
    }

    fun confirmEthernetSettings(): Boolean {
        val repo = repository ?: return false
        lateinit var baseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
        lateinit var draft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
        var mutationGeneration = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            if (
                current.isPerformingAction || repository !== repo ||
                !current.ethernetConfirmationRequested || current.ethernetMutationInProgress ||
                current.ethernetMutationRefreshInProgress || current.ethernetMutationResult != null ||
                current.ethernetMutationFailure != null
            ) return false
            baseline = current.ethernetBaseline ?: return false
            draft = current.ethernetSettingsDraft ?: return false
            val canonical = (current.nasSettings as? Loadable.Ready)?.value?.networkInterfaces
                ?.firstOrNull { it.id == baseline.id }
            if (
                canonical != baseline || draft.id != baseline.id ||
                draft.displayName != baseline.displayName || draft.status != baseline.status ||
                draft == baseline
            ) return false
            mutationGeneration = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                ethernetEditorVisible = false,
                ethernetMutationInProgress = true,
                ethernetMutationResult = null,
                ethernetMutationFailure = null,
                ethernetMutationRefreshFailure = null,
                ethernetMutationRefreshInProgress = true,
                ethernetMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.saveEthernetInterfaceResult(baseline, draft)
                val shouldRefresh = result.submitted || result.requiresRefresh ||
                    ethernetMutationRequiresRefreshBeforeDismiss(result)
                var automaticRefreshFailure: DsmFailure? = null
                val refreshedInterfaces = if (shouldRefresh) {
                    try {
                        repo.activeEthernetInterfaces()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        automaticRefreshFailure = error.asDsmFailure()
                        null
                    }
                } else {
                    null
                }
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == mutationGeneration
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        val verifiedFallback = if (
                            refreshedInterfaces == null &&
                            result.status == MutationResultStatus.CONFIRMED_SUCCESS
                        ) {
                            snapshot?.let { confirmedEthernetSettingsFallback(it, draft) }
                        } else {
                            null
                        }
                        val updatedSnapshot = when {
                            snapshot != null && refreshedInterfaces != null -> snapshot.copy(
                                networkInterfaces = refreshedInterfaces,
                                networkInterfacesAvailable = true,
                            )
                            else -> verifiedFallback
                        }
                        active.copy(
                            nasSettings = updatedSnapshot?.let { Loadable.Ready(it) }
                                ?: active.nasSettings,
                            isPerformingAction = false,
                            ethernetConfirmationRequested = false,
                            ethernetMutationInProgress = false,
                            ethernetMutationResult = result,
                            ethernetMutationRefreshFailure = automaticRefreshFailure,
                            ethernetMutationRefreshInProgress = false,
                            ethernetMutationRefreshCompleted = refreshedInterfaces != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == mutationGeneration
                    }?.copy(
                        isPerformingAction = false,
                        ethernetMutationInProgress = false,
                        ethernetMutationRefreshInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == mutationGeneration
                    }?.copy(
                        isPerformingAction = false,
                        ethernetConfirmationRequested = false,
                        ethernetMutationInProgress = false,
                        ethernetMutationFailure = error.asDsmFailure(),
                        ethernetMutationRefreshInProgress = false,
                    ) ?: current
                }
            }
        }
        return true
    }

    fun refreshEthernetMutation() {
        val repo = repository ?: return
        var refreshGeneration = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            if (
                current.isPerformingAction || repository !== repo ||
                current.ethernetBaseline == null || current.ethernetSettingsDraft == null ||
                current.ethernetMutationInProgress || current.ethernetMutationRefreshInProgress ||
                current.ethernetMutationResult == null && current.ethernetMutationFailure == null
            ) return
            refreshGeneration = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                ethernetMutationRefreshFailure = null,
                ethernetMutationRefreshInProgress = true,
                ethernetMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val interfaces = repo.activeEthernetInterfaces()
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == refreshGeneration
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        active.copy(
                            nasSettings = snapshot?.copy(
                                networkInterfaces = interfaces,
                                networkInterfacesAvailable = true,
                            )
                                ?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            ethernetMutationRefreshInProgress = false,
                            ethernetMutationRefreshCompleted = true,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == refreshGeneration
                    }?.copy(
                        isPerformingAction = false,
                        ethernetMutationRefreshInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == refreshGeneration
                    }?.copy(
                        isPerformingAction = false,
                        ethernetMutationRefreshFailure = error.asDsmFailure(),
                        ethernetMutationRefreshInProgress = false,
                    ) ?: current
                }
            }
        }
    }

    fun dismissEthernetMutationResult(discardDraft: Boolean = false) {
        _workspace.update { current ->
            val result = current?.ethernetMutationResult
            if (
                current == null || current.isPerformingAction || current.ethernetMutationInProgress ||
                current.ethernetMutationRefreshInProgress ||
                result != null && ethernetMutationRequiresRefreshBeforeDismiss(result) &&
                !current.ethernetMutationRefreshCompleted ||
                current.ethernetMutationFailure != null && !current.ethernetMutationRefreshCompleted
            ) return@update current
            val rebased = if (discardDraft) {
                null
            } else {
                val snapshot = (current.nasSettings as? Loadable.Ready)?.value
                val draft = current.ethernetSettingsDraft
                if (snapshot != null && draft != null) {
                    rebasedEthernetSettingsDraft(snapshot, draft)
                } else {
                    null
                }
            }
            current.copy(
                ethernetBaseline = rebased?.first,
                ethernetSettingsDraft = rebased?.second,
                ethernetEditorVisible = rebased != null,
                ethernetConfirmationRequested = false,
                ethernetMutationResult = null,
                ethernetMutationFailure = null,
                ethernetMutationRefreshFailure = null,
                ethernetMutationRefreshInProgress = false,
                ethernetMutationRefreshCompleted = false,
            )
        }
    }

    fun requestDdnsEditing(
        draft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft,
    ): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val directory = (current?.nasSettings as? Loadable.Ready)?.value?.ddnsDirectory
        val baseline = draft.originalProviderId?.let { originalId ->
            directory?.records?.firstOrNull { it.providerId == originalId }
        }
        val validTarget = directory?.providers?.any { it.id == draft.providerId } == true &&
            if (draft.originalProviderId == null) {
                directory.records.none { it.providerId == draft.providerId }
            } else {
                draft.originalProviderId == draft.providerId && baseline != null
            }
        if (
            current == null || !validTarget || current.isPerformingAction || current.ddnsEditorVisible ||
            current.ddnsConfirmationOperation != null || current.ddnsMutationInProgress ||
            current.ddnsMutationRefreshInProgress || current.ddnsMutationResult != null ||
            current.ddnsMutationFailure != null
        ) {
            false
        } else {
            _workspace.value = current.copy(
                ddnsBaseline = baseline,
                ddnsSettingsDraft = draft,
                ddnsEditorVisible = true,
                ddnsConfirmationOperation = null,
                ddnsDeleteTarget = null,
                ddnsAddressRefreshTargetProviderIds = emptySet(),
                ddnsAddressRefreshTargets = emptyList(),
                ddnsMutationOperation = null,
                ddnsMutationTargetProviderId = null,
                ddnsMutationRefreshFailure = null,
                ddnsMutationRefreshCompleted = false,
            )
            true
        }
    }

    fun updateDdnsSettingsDraft(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft,
    ) {
        _workspace.update { current ->
            val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
            val baseline = current?.ddnsBaseline
            val directory = snapshot?.ddnsDirectory
            val identityIsValid = if (baseline == null) {
                value.originalProviderId == null &&
                    directory?.providers?.any { it.id == value.providerId } == true &&
                    directory.records.none { it.providerId == value.providerId }
            } else {
                value.originalProviderId == baseline.providerId && value.providerId == baseline.providerId
            }
            if (
                current == null || !current.ddnsEditorVisible || !identityIsValid ||
                current.ddnsConfirmationOperation != null || current.ddnsMutationInProgress ||
                current.ddnsMutationResult != null || current.ddnsMutationFailure != null
            ) current else current.copy(ddnsSettingsDraft = value)
        }
    }

    fun cancelDdnsEditing() {
        _workspace.update { current ->
            if (
                current == null || current.ddnsConfirmationOperation != null ||
                current.ddnsMutationInProgress || current.ddnsMutationResult != null ||
                current.ddnsMutationFailure != null
            ) current else current.copy(
                ddnsBaseline = null,
                ddnsSettingsDraft = null,
                ddnsEditorVisible = false,
                ddnsMutationRefreshFailure = null,
                ddnsMutationRefreshCompleted = false,
            )
        }
    }

    fun requestDdnsConfirmation(operation: DdnsMutationOperation): Boolean =
        synchronized(nasSettingsStructuredMutationLock) {
            if (operation !in setOf(DdnsMutationOperation.TEST, DdnsMutationOperation.SAVE)) return false
            val current = _workspace.value
            val draft = current?.ddnsSettingsDraft
            val directory = (current?.nasSettings as? Loadable.Ready)?.value?.ddnsDirectory
            val canonical = draft?.providerId?.let { providerId ->
                directory?.records?.firstOrNull { it.providerId == providerId }
            }
            val targetIsCurrent = draft != null &&
                directory?.providers?.any { it.id == draft.providerId } == true &&
                if (draft.originalProviderId == null) canonical == null
                else draft.originalProviderId == draft.providerId && canonical == current?.ddnsBaseline
            if (
                current == null || !current.ddnsEditorVisible || !targetIsCurrent ||
                current.isPerformingAction || current.ddnsConfirmationOperation != null ||
                current.ddnsMutationInProgress || current.ddnsMutationResult != null ||
                current.ddnsMutationFailure != null
            ) {
                false
            } else {
                _workspace.value = current.copy(
                    ddnsEditorVisible = false,
                    ddnsConfirmationOperation = operation,
                )
                true
            }
        }

    fun requestDdnsDelete(
        record: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord,
    ): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val canonical = (current?.nasSettings as? Loadable.Ready)?.value?.ddnsDirectory?.records
            ?.firstOrNull { it.providerId == record.providerId }
        if (
            current == null || canonical != record || current.isPerformingAction ||
            current.ddnsEditorVisible || current.ddnsConfirmationOperation != null ||
            current.ddnsMutationInProgress || current.ddnsMutationResult != null ||
            current.ddnsMutationFailure != null
        ) {
            false
        } else {
            _workspace.value = current.copy(
                ddnsDeleteTarget = canonical,
                ddnsConfirmationOperation = DdnsMutationOperation.DELETE,
                ddnsAddressRefreshTargetProviderIds = emptySet(),
                ddnsAddressRefreshTargets = emptyList(),
            )
            true
        }
    }

    fun requestDdnsAddressRefresh(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val records = (current?.nasSettings as? Loadable.Ready)?.value?.ddnsDirectory?.records.orEmpty()
        val providerIds = records.map { it.providerId }.toSet()
        if (
            current == null || providerIds.isEmpty() || current.isPerformingAction ||
            current.ddnsEditorVisible || current.ddnsConfirmationOperation != null ||
            current.ddnsMutationInProgress || current.ddnsMutationResult != null ||
            current.ddnsMutationFailure != null
        ) {
            false
        } else {
            _workspace.value = current.copy(
                ddnsDeleteTarget = null,
                ddnsAddressRefreshTargetProviderIds = providerIds,
                ddnsAddressRefreshTargets = records,
                ddnsConfirmationOperation = DdnsMutationOperation.ADDRESS_REFRESH,
            )
            true
        }
    }

    fun cancelDdnsConfirmation() {
        _workspace.update { current ->
            if (
                current == null || current.ddnsConfirmationOperation == null ||
                current.ddnsMutationInProgress || current.ddnsMutationResult != null ||
                current.ddnsMutationFailure != null
            ) {
                current
            } else {
                val returnsToEditor = current.ddnsConfirmationOperation in setOf(
                    DdnsMutationOperation.TEST,
                    DdnsMutationOperation.SAVE,
                )
                current.copy(
                    ddnsEditorVisible = returnsToEditor,
                    ddnsConfirmationOperation = null,
                    ddnsDeleteTarget = null,
                    ddnsAddressRefreshTargetProviderIds = emptySet(),
                    ddnsAddressRefreshTargets = emptyList(),
                )
            }
        }
    }

    fun confirmDdnsMutation(): Boolean {
        val repo = repository ?: return false
        lateinit var operation: DdnsMutationOperation
        var submittedDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft? = null
        var baseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord? = null
        var deleteTarget: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord? = null
        var refreshProviderIds: Set<String> = emptySet()
        var mutationGeneration = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            if (
                current.isPerformingAction || repository !== repo || current.ddnsMutationInProgress ||
                current.ddnsMutationRefreshInProgress || current.ddnsMutationResult != null ||
                current.ddnsMutationFailure != null
            ) return false
            operation = current.ddnsConfirmationOperation ?: return false
            val directory = (current.nasSettings as? Loadable.Ready)?.value?.ddnsDirectory ?: return false
            when (operation) {
                DdnsMutationOperation.TEST,
                DdnsMutationOperation.SAVE,
                -> {
                    val draft = current.ddnsSettingsDraft ?: return false
                    val canonical = directory.records.firstOrNull { it.providerId == draft.providerId }
                    if (
                        directory.providers.none { it.id == draft.providerId } ||
                        (draft.originalProviderId == null && canonical != null) ||
                        (draft.originalProviderId != null && (
                            draft.originalProviderId != draft.providerId || canonical != current.ddnsBaseline
                            ))
                    ) return false
                    submittedDraft = draft
                    baseline = current.ddnsBaseline
                }
                DdnsMutationOperation.DELETE -> {
                    val target = current.ddnsDeleteTarget ?: return false
                    if (directory.records.firstOrNull { it.providerId == target.providerId } != target) return false
                    deleteTarget = target
                }
                DdnsMutationOperation.ADDRESS_REFRESH -> {
                    val currentIds = directory.records.map { it.providerId }.toSet()
                    if (
                        current.ddnsAddressRefreshTargetProviderIds.isEmpty() ||
                        currentIds != current.ddnsAddressRefreshTargetProviderIds
                    ) return false
                    refreshProviderIds = currentIds
                }
            }
            mutationGeneration = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                ddnsSettingsDraft = current.ddnsSettingsDraft?.let(::scrubDdnsPassword),
                ddnsEditorVisible = false,
                ddnsConfirmationOperation = null,
                ddnsMutationOperation = operation,
                ddnsMutationTargetProviderId = submittedDraft?.providerId ?: deleteTarget?.providerId,
                ddnsMutationInProgress = true,
                ddnsMutationResult = null,
                ddnsMutationFailure = null,
                ddnsMutationRefreshFailure = null,
                ddnsMutationRefreshInProgress = operation != DdnsMutationOperation.TEST,
                ddnsMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = when (operation) {
                    DdnsMutationOperation.TEST -> repo.testDdnsResult(checkNotNull(submittedDraft))
                    DdnsMutationOperation.SAVE -> repo.saveDdnsResult(baseline, checkNotNull(submittedDraft))
                    DdnsMutationOperation.DELETE -> repo.deleteDdnsResult(checkNotNull(deleteTarget))
                    DdnsMutationOperation.ADDRESS_REFRESH -> repo.refreshDdnsResult(refreshProviderIds)
                }
                val shouldRefresh = operation != DdnsMutationOperation.TEST &&
                    (result.submitted || result.requiresRefresh ||
                        ddnsMutationRequiresRefreshBeforeDismiss(operation, result))
                var automaticRefreshFailure: DsmFailure? = null
                val refreshedDirectory = if (shouldRefresh) {
                    try {
                        repo.activeDdnsDirectory()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        automaticRefreshFailure = error.asDsmFailure()
                        null
                    }
                } else null
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == mutationGeneration
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        val fallback = if (
                            refreshedDirectory == null && result.status == MutationResultStatus.CONFIRMED_SUCCESS &&
                            snapshot != null
                        ) when (operation) {
                            DdnsMutationOperation.SAVE -> confirmedDdnsSaveFallback(
                                snapshot,
                                checkNotNull(submittedDraft),
                            )
                            DdnsMutationOperation.DELETE -> confirmedDdnsDeleteFallback(
                                snapshot,
                                checkNotNull(deleteTarget).providerId,
                            )
                            DdnsMutationOperation.TEST,
                            DdnsMutationOperation.ADDRESS_REFRESH,
                            -> null
                        } else null
                        val updated = if (snapshot != null && refreshedDirectory != null) {
                            snapshot.copy(
                                ddnsDirectory = refreshedDirectory,
                                ddnsDirectoryAvailable = true,
                            )
                        } else fallback
                        active.copy(
                            nasSettings = updated?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            ddnsMutationInProgress = false,
                            ddnsMutationResult = result,
                            ddnsMutationRefreshFailure = automaticRefreshFailure,
                            ddnsMutationRefreshInProgress = false,
                            ddnsMutationRefreshCompleted = refreshedDirectory != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == mutationGeneration
                    }?.copy(
                        isPerformingAction = false,
                        ddnsMutationInProgress = false,
                        ddnsMutationRefreshInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == mutationGeneration
                    }?.copy(
                        isPerformingAction = false,
                        ddnsMutationInProgress = false,
                        ddnsMutationFailure = error.asDsmFailure(),
                        ddnsMutationRefreshInProgress = false,
                    ) ?: current
                }
            }
        }
        return true
    }

    fun refreshDdnsMutation() {
        val repo = repository ?: return
        var refreshGeneration = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            val operation = current.ddnsMutationOperation ?: return
            if (
                operation == DdnsMutationOperation.TEST || current.isPerformingAction || repository !== repo ||
                current.ddnsMutationInProgress || current.ddnsMutationRefreshInProgress ||
                current.ddnsMutationResult == null && current.ddnsMutationFailure == null
            ) return
            refreshGeneration = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                ddnsMutationRefreshFailure = null,
                ddnsMutationRefreshInProgress = true,
                ddnsMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val directory = repo.activeDdnsDirectory()
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == refreshGeneration
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        active.copy(
                            nasSettings = snapshot?.copy(
                                ddnsDirectory = directory,
                                ddnsDirectoryAvailable = true,
                            )?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            ddnsMutationRefreshInProgress = false,
                            ddnsMutationRefreshCompleted = true,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == refreshGeneration
                    }?.copy(
                        isPerformingAction = false,
                        ddnsMutationRefreshInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            nasSettingsRequestGeneration.get() == refreshGeneration
                    }?.copy(
                        isPerformingAction = false,
                        ddnsMutationRefreshFailure = error.asDsmFailure(),
                        ddnsMutationRefreshInProgress = false,
                    ) ?: current
                }
            }
        }
    }

    fun dismissDdnsMutationResult(discardDraft: Boolean = false) {
        _workspace.update { current ->
            val operation = current?.ddnsMutationOperation
            val result = current?.ddnsMutationResult
            val requiresRefresh = operation != null && result != null &&
                ddnsMutationRequiresRefreshBeforeDismiss(operation, result)
            val failureRequiresRefresh = operation != null && operation != DdnsMutationOperation.TEST &&
                current?.ddnsMutationFailure != null
            if (
                current == null || current.isPerformingAction || current.ddnsMutationInProgress ||
                current.ddnsMutationRefreshInProgress ||
                (requiresRefresh || failureRequiresRefresh) && !current.ddnsMutationRefreshCompleted
            ) return@update current
            val rebased = if (
                !discardDraft && operation in setOf(DdnsMutationOperation.TEST, DdnsMutationOperation.SAVE)
            ) {
                val snapshot = (current.nasSettings as? Loadable.Ready)?.value
                val draft = current.ddnsSettingsDraft
                if (snapshot != null && draft != null) {
                    rebasedDdnsSettingsDraft(
                        snapshot,
                        draft,
                        adoptExistingRecord = operation == DdnsMutationOperation.SAVE,
                    )
                } else null
            } else null
            current.copy(
                ddnsBaseline = rebased?.baseline,
                ddnsSettingsDraft = rebased?.draft,
                ddnsEditorVisible = rebased != null,
                ddnsConfirmationOperation = null,
                ddnsDeleteTarget = null,
                ddnsAddressRefreshTargetProviderIds = emptySet(),
                ddnsAddressRefreshTargets = emptyList(),
                ddnsMutationOperation = null,
                ddnsMutationTargetProviderId = null,
                ddnsMutationResult = null,
                ddnsMutationFailure = null,
                ddnsMutationRefreshFailure = null,
                ddnsMutationRefreshInProgress = false,
                ddnsMutationRefreshCompleted = false,
            )
        }
    }

    fun saveFileServiceSettings(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings,
    ): Boolean {
        val repo = repository ?: return false
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            if (current.isPerformingAction || repository !== repo) return false
            nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                fileServiceSettingsDraft = value,
                fileServiceMutationInProgress = true,
                fileServiceMutationResult = null,
                fileServiceMutationFailure = null,
                fileServiceMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.saveFileServiceSettingsResult(value)
                val refreshed = if (result.submitted || result.requiresRefresh) {
                    runCatching { repo.nasSettings() }.getOrNull()
                        ?.takeIf { it.fileServiceSettings != null }
                } else {
                    null
                }
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.let { active ->
                        val verifiedFallback = if (
                            result.status == MutationResultStatus.CONFIRMED_SUCCESS
                        ) {
                            (active.nasSettings as? Loadable.Ready)?.value?.copy(
                                fileServiceSettings = value,
                            )
                        } else {
                            null
                        }
                        active.copy(
                        nasSettings = (refreshed ?: verifiedFallback)?.let { Loadable.Ready(it) }
                            ?: active.nasSettings,
                        isPerformingAction = false,
                        fileServiceMutationInProgress = false,
                        fileServiceSettingsDraft = active.fileServiceSettingsDraft.takeUnless {
                            result.status == MutationResultStatus.CONFIRMED_SUCCESS
                        },
                        fileServiceMutationResult = result,
                        fileServiceMutationRefreshCompleted = refreshed != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.copy(
                        isPerformingAction = false,
                        fileServiceMutationInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                val failure = error.asDsmFailure()
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.copy(
                        isPerformingAction = false,
                        fileServiceMutationInProgress = false,
                        fileServiceMutationFailure = failure,
                    ) ?: current
                }
            }
        }
        return true
    }

    fun dismissFileServiceMutationResult(discardDraft: Boolean = false) {
        _workspace.update {
            if (it?.fileServiceMutationInProgress == true) return@update it
            it?.copy(
                fileServiceSettingsDraft = it.fileServiceSettingsDraft.takeUnless { discardDraft },
                fileServiceMutationResult = null,
                fileServiceMutationFailure = null,
                fileServiceMutationRefreshCompleted = false,
            )
        }
    }

    fun updateFileServiceSettingsDraft(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings?,
    ) {
        _workspace.update {
            if (it?.fileServiceMutationInProgress == true) it
            else it?.copy(fileServiceSettingsDraft = value)
        }
    }

    fun saveTerminalSettings(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings,
    ): Boolean {
        val repo = repository ?: return false
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            if (current.isPerformingAction || repository !== repo) return false
            nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                terminalSettingsDraft = value,
                terminalMutationInProgress = true,
                terminalMutationResult = null,
                terminalMutationFailure = null,
                terminalMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.saveTerminalSettingsResult(value)
                val refreshed = if (result.submitted || result.requiresRefresh) {
                    runCatching { repo.nasSettings() }.getOrNull()
                        ?.takeIf { it.terminalSettings != null }
                } else {
                    null
                }
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.let { active ->
                        val verifiedFallback = if (
                            result.status == MutationResultStatus.CONFIRMED_SUCCESS
                        ) {
                            (active.nasSettings as? Loadable.Ready)?.value?.copy(
                                terminalSettings = value,
                            )
                        } else {
                            null
                        }
                        active.copy(
                            nasSettings = (refreshed ?: verifiedFallback)?.let { Loadable.Ready(it) }
                                ?: active.nasSettings,
                            isPerformingAction = false,
                            terminalMutationInProgress = false,
                            terminalSettingsDraft = active.terminalSettingsDraft.takeUnless {
                                result.status == MutationResultStatus.CONFIRMED_SUCCESS
                            },
                            terminalMutationResult = result,
                            terminalMutationRefreshCompleted = refreshed != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.copy(
                        isPerformingAction = false,
                        terminalMutationInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                val failure = error.asDsmFailure()
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.copy(
                        isPerformingAction = false,
                        terminalMutationInProgress = false,
                        terminalMutationFailure = failure,
                    ) ?: current
                }
            }
        }
        return true
    }

    fun dismissTerminalMutationResult(discardDraft: Boolean = false) {
        _workspace.update {
            if (it?.terminalMutationInProgress == true) return@update it
            it?.copy(
                terminalSettingsDraft = it.terminalSettingsDraft.takeUnless { discardDraft },
                terminalMutationResult = null,
                terminalMutationFailure = null,
                terminalMutationRefreshCompleted = false,
            )
        }
    }

    fun updateTerminalSettingsDraft(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings?,
    ) {
        _workspace.update {
            if (it?.terminalMutationInProgress == true) it
            else it?.copy(terminalSettingsDraft = value)
        }
    }

    fun saveProxySettings(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings,
    ): Boolean {
        val repo = repository ?: return false
        val normalizedValue = value.copy(host = value.host.trim())
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            if (current.isPerformingAction || repository !== repo) return false
            nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                proxySettingsDraft = normalizedValue,
                proxyMutationInProgress = true,
                proxyMutationResult = null,
                proxyMutationFailure = null,
                proxyMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.saveProxySettingsResult(normalizedValue)
                val refreshed = if (result.submitted || result.requiresRefresh) {
                    runCatching { repo.nasSettings() }.getOrNull()
                        ?.takeIf { it.proxySettings != null }
                } else {
                    null
                }
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.let { active ->
                        val verifiedFallback = if (
                            result.status == MutationResultStatus.CONFIRMED_SUCCESS
                        ) {
                            (active.nasSettings as? Loadable.Ready)?.value?.let { snapshot ->
                                confirmedProxySettingsFallback(snapshot, normalizedValue)
                            }
                        } else {
                            null
                        }
                        active.copy(
                            nasSettings = (refreshed ?: verifiedFallback)?.let { Loadable.Ready(it) }
                                ?: active.nasSettings,
                            isPerformingAction = false,
                            proxyMutationInProgress = false,
                            proxySettingsDraft = active.proxySettingsDraft.takeUnless {
                                result.status == MutationResultStatus.CONFIRMED_SUCCESS
                            },
                            proxyMutationResult = result,
                            proxyMutationRefreshCompleted = refreshed != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.copy(
                        isPerformingAction = false,
                        proxyMutationInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                val failure = error.asDsmFailure()
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.copy(
                        isPerformingAction = false,
                        proxyMutationInProgress = false,
                        proxyMutationFailure = failure,
                    ) ?: current
                }
            }
        }
        return true
    }

    fun dismissProxyMutationResult(discardDraft: Boolean = false) {
        _workspace.update {
            if (it?.proxyMutationInProgress == true) return@update it
            it?.copy(
                proxySettingsDraft = it.proxySettingsDraft.takeUnless { discardDraft },
                proxyMutationResult = null,
                proxyMutationFailure = null,
                proxyMutationRefreshCompleted = false,
            )
        }
    }

    fun updateProxySettingsDraft(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings?,
    ) {
        _workspace.update {
            if (it?.proxyMutationInProgress == true) it
            else it?.copy(proxySettingsDraft = value)
        }
    }

    fun saveRegionSettings(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings,
    ): Boolean {
        val repo = repository ?: return false
        val normalizedValue = value.copy(
            dateFormat = value.dateFormat.trim(),
            timeFormat = value.timeFormat.trim(),
            timeServers = value.timeServers.map(String::trim).filter(String::isNotEmpty),
        )
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            if (current.isPerformingAction || repository !== repo) return false
            nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                regionSettingsDraft = normalizedValue,
                regionMutationInProgress = true,
                regionMutationResult = null,
                regionMutationFailure = null,
                regionMutationRefreshCompleted = false,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.saveRegionSettingsResult(normalizedValue)
                val refreshed = if (result.submitted || result.requiresRefresh) {
                    runCatching { repo.nasSettings() }.getOrNull()
                        ?.takeIf { it.regionSettings != null }
                } else {
                    null
                }
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.let { active ->
                        val verifiedFallback = if (
                            result.status == MutationResultStatus.CONFIRMED_SUCCESS
                        ) {
                            (active.nasSettings as? Loadable.Ready)?.value?.let { snapshot ->
                                confirmedRegionSettingsFallback(snapshot, normalizedValue)
                            }
                        } else {
                            null
                        }
                        active.copy(
                            nasSettings = (refreshed ?: verifiedFallback)?.let { Loadable.Ready(it) }
                                ?: active.nasSettings,
                            isPerformingAction = false,
                            regionMutationInProgress = false,
                            regionSettingsDraft = active.regionSettingsDraft.takeUnless {
                                result.status == MutationResultStatus.CONFIRMED_SUCCESS
                            },
                            regionMutationResult = result,
                            regionMutationRefreshCompleted = refreshed != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.copy(
                        isPerformingAction = false,
                        regionMutationInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                val failure = error.asDsmFailure()
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId
                    }?.copy(
                        isPerformingAction = false,
                        regionMutationInProgress = false,
                        regionMutationFailure = failure,
                    ) ?: current
                }
            }
        }
        return true
    }

    fun dismissRegionMutationResult(discardDraft: Boolean = false) {
        _workspace.update {
            if (it?.regionMutationInProgress == true) return@update it
            it?.copy(
                regionSettingsDraft = it.regionSettingsDraft.takeUnless { discardDraft },
                regionMutationResult = null,
                regionMutationFailure = null,
                regionMutationRefreshCompleted = false,
            )
        }
    }

    fun updateRegionSettingsDraft(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings?,
    ) {
        _workspace.update {
            if (it?.regionMutationInProgress == true) it
            else it?.copy(regionSettingsDraft = value)
        }
    }

    fun requestRemoteAccessEditing(value: NasRemoteAccessSettings): Boolean =
        synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value
            val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
            if (
                current == null || snapshot == null || !canRequestRemoteAccessEditing(snapshot, value) ||
                current.isPerformingAction || current.remoteAccessEditorVisible ||
                current.remoteAccessConfirmationRequested || current.remoteAccessMutationInProgress ||
                current.remoteAccessMutationRefreshInProgress || current.remoteAccessMutationResult != null ||
                current.remoteAccessMutationFailure != null
            ) false else {
                _workspace.value = current.copy(
                    remoteAccessState = current.remoteAccessState.copy(
                        settingsBaseline = value,
                        settingsDraft = value,
                        editorVisible = true,
                        mutationRefreshFailure = null,
                        mutationRefreshCompleted = false,
                    ),
                )
                true
            }
        }

    fun updateRemoteAccessSettingsDraft(value: NasRemoteAccessSettings) =
        synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value
            val baseline = current?.remoteAccessSettingsBaseline
            val normalized = baseline?.let { normalizedRemoteAccessSettingsDraft(it, value) }
            if (
                current != null && normalized != null && current.remoteAccessEditorVisible &&
                !current.remoteAccessConfirmationRequested && !current.remoteAccessMutationInProgress &&
                current.remoteAccessMutationResult == null && current.remoteAccessMutationFailure == null
            ) _workspace.value = current.copy(
                remoteAccessState = current.remoteAccessState.copy(settingsDraft = normalized),
            )
        }

    fun cancelRemoteAccessEditing() = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current != null && !current.remoteAccessConfirmationRequested &&
            !current.remoteAccessMutationInProgress && current.remoteAccessMutationResult == null &&
            current.remoteAccessMutationFailure == null
        ) {
            _workspace.value = current.copy(
                remoteAccessState = current.remoteAccessState.copy(
                    settingsBaseline = null,
                    settingsDraft = null,
                    editorVisible = false,
                    mutationRefreshFailure = null,
                    mutationRefreshCompleted = false,
                ),
            )
        }
    }

    fun requestRemoteAccessConfirmation(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
        val baseline = current?.remoteAccessSettingsBaseline
        val draft = current?.remoteAccessSettingsDraft
        if (
            current == null || snapshot == null || baseline == null || draft == null ||
            !current.remoteAccessEditorVisible ||
            !canRequestRemoteAccessConfirmation(snapshot, baseline, draft) || current.isPerformingAction ||
            current.remoteAccessConfirmationRequested || current.remoteAccessMutationInProgress ||
            current.remoteAccessMutationResult != null || current.remoteAccessMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                remoteAccessState = current.remoteAccessState.copy(
                    editorVisible = false,
                    confirmationRequested = true,
                ),
            )
            true
        }
    }

    fun cancelRemoteAccessConfirmation() = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current != null && current.remoteAccessConfirmationRequested &&
            !current.remoteAccessMutationInProgress
        ) {
            _workspace.value = current.copy(
                remoteAccessState = current.remoteAccessState.copy(
                    editorVisible = true,
                    confirmationRequested = false,
                ),
            )
        }
    }

    fun confirmRemoteAccessMutation(): Boolean {
        val repo = repository ?: return false
        lateinit var baseline: NasRemoteAccessSettings
        lateinit var expected: NasRemoteAccessSettings
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            val snapshot = (current.nasSettings as? Loadable.Ready)?.value ?: return false
            baseline = current.remoteAccessSettingsBaseline ?: return false
            expected = current.remoteAccessSettingsDraft ?: return false
            if (
                repository === repo && current.remoteAccessConfirmationRequested &&
                remoteAccessCanonicalHasDrifted(snapshot, baseline)
            ) {
                _workspace.value = current.copy(
                    remoteAccessState = current.remoteAccessState.copy(
                        editorVisible = false,
                        confirmationRequested = false,
                        mutationFailure = DsmFailure(
                            null,
                            "Remote access settings changed",
                            "Review the latest settings before trying again.",
                            kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
                        ),
                        mutationRefreshCompleted = snapshot.remoteAccessSettingsAvailable &&
                            snapshot.remoteAccessSettings != null,
                    ),
                )
                return false
            }
            if (
                repository !== repo || current.isPerformingAction ||
                !current.remoteAccessConfirmationRequested ||
                !canRequestRemoteAccessConfirmation(snapshot, baseline, expected) ||
                current.remoteAccessMutationInProgress || current.remoteAccessMutationResult != null ||
                current.remoteAccessMutationFailure != null
            ) return false
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                remoteAccessState = current.remoteAccessState.copy(
                    editorVisible = false,
                    confirmationRequested = false,
                    mutationInProgress = true,
                    mutationResult = null,
                    mutationFailure = null,
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = true,
                    mutationRefreshCompleted = false,
                    mutationGeneration = generation,
                ),
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.saveRemoteAccessSettingsResult(baseline, expected)
                val shouldRefresh = result.status == MutationResultStatus.CONFIRMED_SUCCESS ||
                    result.submitted || result.requiresRefresh ||
                    structuredSettingsMutationRequiresRefreshBeforeDismiss(result)
                var refreshFailure: DsmFailure? = null
                val refreshed = if (shouldRefresh) try {
                    repo.activeRemoteAccessSettings()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    refreshFailure = error.asDsmFailure()
                    null
                } else null
                _workspace.update { current ->
                    current?.takeIf {
                        remoteAccessCallbackMatches(
                            repository === repo,
                            it.profile.id == profileId,
                            it.remoteAccessMutationGeneration,
                            generation,
                            nasSettingsRequestGeneration.get(),
                        )
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        val fallback = if (
                            snapshot != null && refreshed == null &&
                            result.status == MutationResultStatus.CONFIRMED_SUCCESS
                        ) confirmedRemoteAccessSettingsFallback(snapshot, baseline, expected) else null
                        val updated = when {
                            snapshot != null && refreshed != null -> snapshot.copy(
                                remoteAccessSettings = refreshed,
                                remoteAccessSettingsAvailable = true,
                            )
                            fallback != null -> fallback
                            else -> null
                        }
                        val targetConfirmed = refreshed?.let {
                            remoteAccessMutationTargetReached(baseline, it, expected)
                        } ?: (fallback != null)
                        val refreshCompleted = snapshot != null &&
                            remoteAccessMutationRefreshIsComplete(baseline, expected, refreshed)
                        active.copy(
                            nasSettings = updated?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            remoteAccessState = active.remoteAccessState.copy(
                                mutationInProgress = false,
                                mutationResult = remoteAccessMutationResultAfterStateCheck(
                                    result,
                                    targetConfirmed,
                                ),
                                mutationRefreshFailure = refreshFailure,
                                mutationRefreshInProgress = false,
                                mutationRefreshCompleted = refreshCompleted,
                            ),
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishRemoteAccessMutationFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishRemoteAccessMutationFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
        return true
    }

    private fun finishRemoteAccessMutationFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                remoteAccessCallbackMatches(
                    repository === repo,
                    it.profile.id == profileId,
                    it.remoteAccessMutationGeneration,
                    generation,
                    nasSettingsRequestGeneration.get(),
                )
            }?.copy(
                isPerformingAction = false,
                remoteAccessState = current.remoteAccessState.copy(
                    mutationInProgress = false,
                    mutationFailure = failure,
                    mutationRefreshInProgress = false,
                ),
            ) ?: current
        }
    }

    fun refreshRemoteAccessMutation() {
        val repo = repository ?: return
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            if (
                repository !== repo || current.isPerformingAction || current.remoteAccessMutationInProgress ||
                current.remoteAccessMutationRefreshInProgress ||
                current.remoteAccessMutationResult == null && current.remoteAccessMutationFailure == null
            ) return
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                remoteAccessState = current.remoteAccessState.copy(
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = true,
                    mutationRefreshCompleted = false,
                    mutationGeneration = generation,
                ),
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val refreshed = repo.activeRemoteAccessSettings()
                _workspace.update { current ->
                    current?.takeIf {
                        remoteAccessCallbackMatches(
                            repository === repo,
                            it.profile.id == profileId,
                            it.remoteAccessMutationGeneration,
                            generation,
                            nasSettingsRequestGeneration.get(),
                        )
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        active.copy(
                            nasSettings = snapshot?.copy(
                                remoteAccessSettings = refreshed,
                                remoteAccessSettingsAvailable = true,
                            )?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            remoteAccessState = active.remoteAccessState.copy(
                                mutationRefreshInProgress = false,
                                mutationRefreshCompleted = snapshot != null &&
                                    remoteAccessMutationRefreshIsComplete(
                                        active.remoteAccessSettingsBaseline,
                                        active.remoteAccessSettingsDraft,
                                        refreshed,
                                    ),
                            ),
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishRemoteAccessRefreshFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishRemoteAccessRefreshFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
    }

    private fun finishRemoteAccessRefreshFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                remoteAccessCallbackMatches(
                    repository === repo,
                    it.profile.id == profileId,
                    it.remoteAccessMutationGeneration,
                    generation,
                    nasSettingsRequestGeneration.get(),
                )
            }?.copy(
                isPerformingAction = false,
                remoteAccessState = current.remoteAccessState.copy(
                    mutationRefreshFailure = failure,
                    mutationRefreshInProgress = false,
                ),
            ) ?: current
        }
    }

    fun dismissRemoteAccessMutationResult(discardDraft: Boolean = false): Boolean =
        synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            val requiresRefresh = current.remoteAccessMutationResult?.let(
                ::structuredSettingsMutationRequiresRefreshBeforeDismiss,
            ) == true || current.remoteAccessMutationFailure != null ||
                current.remoteAccessMutationRefreshFailure != null
            if (
                current.isPerformingAction || current.remoteAccessMutationInProgress ||
                current.remoteAccessMutationRefreshInProgress ||
                requiresRefresh && !current.remoteAccessMutationRefreshCompleted
            ) return false
            val rebased = if (!discardDraft) {
                val snapshot = (current.nasSettings as? Loadable.Ready)?.value
                val draft = current.remoteAccessSettingsDraft
                if (snapshot != null && draft != null) {
                    rebasedRemoteAccessSettingsDraft(snapshot, draft)
                } else null
            } else null
            _workspace.value = current.copy(
                remoteAccessState = current.remoteAccessState.copy(
                    settingsBaseline = rebased?.first,
                    settingsDraft = rebased?.second,
                    editorVisible = rebased != null,
                    confirmationRequested = false,
                    mutationResult = null,
                    mutationFailure = null,
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = false,
                    mutationRefreshCompleted = false,
                ),
            )
            true
        }

    fun requestSecuritySettingsEditing(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings,
    ): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
        val canonical = snapshot?.securitySettings?.takeIf { snapshot.securitySettingsAvailable }
        if (
            current == null || canonical != value || current.isPerformingAction ||
            current.securitySettingsEditorVisible || current.securitySettingsConfirmationRequested ||
            current.securitySettingsMutationInProgress || current.securitySettingsMutationRefreshInProgress ||
            current.securitySettingsMutationResult != null || current.securitySettingsMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                securitySettingsBaseline = canonical,
                securitySettingsDraft = value,
                securitySettingsEditorVisible = true,
                securitySettingsMutationRefreshFailure = null,
                securitySettingsMutationRefreshCompleted = false,
            )
            true
        }
    }

    fun updateSecuritySettingsDraft(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings,
    ) = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current != null && current.securitySettingsEditorVisible &&
            !current.securitySettingsConfirmationRequested && !current.securitySettingsMutationInProgress &&
            current.securitySettingsMutationResult == null && current.securitySettingsMutationFailure == null
        ) _workspace.value = current.copy(securitySettingsDraft = value)
    }

    fun cancelSecuritySettingsEditing() = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current != null && !current.securitySettingsConfirmationRequested &&
            !current.securitySettingsMutationInProgress && current.securitySettingsMutationResult == null &&
            current.securitySettingsMutationFailure == null
        ) {
            _workspace.value = current.copy(
                securitySettingsBaseline = null,
                securitySettingsDraft = null,
                securitySettingsEditorVisible = false,
                securitySettingsMutationRefreshFailure = null,
                securitySettingsMutationRefreshCompleted = false,
            )
        }
    }

    fun requestSecuritySettingsConfirmation(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
        if (
            current == null || !current.securitySettingsEditorVisible ||
            current.securitySettingsDraft == null || snapshot?.securitySettingsAvailable != true ||
            snapshot?.securitySettings != current.securitySettingsBaseline || current.isPerformingAction ||
            current.securitySettingsConfirmationRequested || current.securitySettingsMutationInProgress ||
            current.securitySettingsMutationResult != null || current.securitySettingsMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                securitySettingsEditorVisible = false,
                securitySettingsConfirmationRequested = true,
            )
            true
        }
    }

    fun cancelSecuritySettingsConfirmation() = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current != null && current.securitySettingsConfirmationRequested &&
            !current.securitySettingsMutationInProgress
        ) {
            _workspace.value = current.copy(
                securitySettingsEditorVisible = true,
                securitySettingsConfirmationRequested = false,
            )
        }
    }

    fun confirmSecuritySettingsMutation(): Boolean {
        val repo = repository ?: return false
        lateinit var baseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings
        lateinit var expected: io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            val snapshot = (current.nasSettings as? Loadable.Ready)?.value ?: return false
            baseline = current.securitySettingsBaseline ?: return false
            expected = current.securitySettingsDraft ?: return false
            if (
                repository !== repo || current.isPerformingAction ||
                !current.securitySettingsConfirmationRequested || !snapshot.securitySettingsAvailable ||
                snapshot.securitySettings != baseline || current.securitySettingsMutationInProgress ||
                current.securitySettingsMutationResult != null || current.securitySettingsMutationFailure != null
            ) return false
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                securitySettingsEditorVisible = false,
                securitySettingsConfirmationRequested = false,
                securitySettingsMutationInProgress = true,
                securitySettingsMutationResult = null,
                securitySettingsMutationFailure = null,
                securitySettingsMutationRefreshFailure = null,
                securitySettingsMutationRefreshInProgress = true,
                securitySettingsMutationRefreshCompleted = false,
                securitySettingsMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.saveSecuritySettingsResult(baseline, expected)
                val shouldRefresh = result.submitted || result.requiresRefresh ||
                    structuredSettingsMutationRequiresRefreshBeforeDismiss(result)
                var refreshFailure: DsmFailure? = null
                val refreshed = if (shouldRefresh) try {
                    repo.activeSecuritySettings()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    refreshFailure = error.asDsmFailure()
                    null
                } else null
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            it.securitySettingsMutationGeneration == generation &&
                            nasSettingsRequestGeneration.get() == generation
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        val updated = when {
                            snapshot != null && refreshed != null -> snapshot.copy(
                                securitySettings = refreshed,
                                securitySettingsAvailable = true,
                            )
                            snapshot != null && result.status == MutationResultStatus.CONFIRMED_SUCCESS ->
                                confirmedSecuritySettingsFallback(snapshot, baseline, expected)
                            else -> null
                        }
                        active.copy(
                            nasSettings = updated?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            securitySettingsMutationInProgress = false,
                            securitySettingsMutationResult = result,
                            securitySettingsMutationRefreshFailure = refreshFailure,
                            securitySettingsMutationRefreshInProgress = false,
                            securitySettingsMutationRefreshCompleted = refreshed != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            it.securitySettingsMutationGeneration == generation &&
                            nasSettingsRequestGeneration.get() == generation
                    }?.copy(
                        isPerformingAction = false,
                        securitySettingsMutationInProgress = false,
                        securitySettingsMutationRefreshInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            it.securitySettingsMutationGeneration == generation &&
                            nasSettingsRequestGeneration.get() == generation
                    }?.copy(
                        isPerformingAction = false,
                        securitySettingsMutationInProgress = false,
                        securitySettingsMutationFailure = error.asDsmFailure(),
                        securitySettingsMutationRefreshInProgress = false,
                    ) ?: current
                }
            }
        }
        return true
    }

    fun refreshSecuritySettingsMutation() {
        val repo = repository ?: return
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            if (
                repository !== repo || current.isPerformingAction || current.securitySettingsMutationInProgress ||
                current.securitySettingsMutationRefreshInProgress ||
                current.securitySettingsMutationResult == null && current.securitySettingsMutationFailure == null
            ) return
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                securitySettingsMutationRefreshFailure = null,
                securitySettingsMutationRefreshInProgress = true,
                securitySettingsMutationRefreshCompleted = false,
                securitySettingsMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val refreshed = repo.activeSecuritySettings()
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            it.securitySettingsMutationGeneration == generation &&
                            nasSettingsRequestGeneration.get() == generation
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        active.copy(
                            nasSettings = snapshot?.copy(
                                securitySettings = refreshed,
                                securitySettingsAvailable = true,
                            )?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            securitySettingsMutationRefreshInProgress = false,
                            securitySettingsMutationRefreshCompleted = snapshot != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishSecuritySettingsRefreshFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishSecuritySettingsRefreshFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
    }

    private fun finishSecuritySettingsRefreshFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                repository === repo && it.profile.id == profileId &&
                    it.securitySettingsMutationGeneration == generation &&
                    nasSettingsRequestGeneration.get() == generation
            }?.copy(
                isPerformingAction = false,
                securitySettingsMutationRefreshFailure = failure,
                securitySettingsMutationRefreshInProgress = false,
            ) ?: current
        }
    }

    fun dismissSecuritySettingsMutationResult(discardDraft: Boolean = false) {
        _workspace.update { current ->
            val requiresRefresh = current?.securitySettingsMutationResult?.let(
                ::structuredSettingsMutationRequiresRefreshBeforeDismiss,
            ) == true || current?.securitySettingsMutationFailure != null
            if (
                current == null || current.isPerformingAction || current.securitySettingsMutationInProgress ||
                current.securitySettingsMutationRefreshInProgress ||
                requiresRefresh && !current.securitySettingsMutationRefreshCompleted
            ) return@update current
            val rebased = if (!discardDraft) {
                val snapshot = (current.nasSettings as? Loadable.Ready)?.value
                val draft = current.securitySettingsDraft
                if (snapshot != null && draft != null) rebasedSecuritySettingsDraft(snapshot, draft) else null
            } else null
            current.copy(
                securitySettingsBaseline = rebased?.first,
                securitySettingsDraft = rebased?.second,
                securitySettingsEditorVisible = rebased != null,
                securitySettingsConfirmationRequested = false,
                securitySettingsMutationResult = null,
                securitySettingsMutationFailure = null,
                securitySettingsMutationRefreshFailure = null,
                securitySettingsMutationRefreshInProgress = false,
                securitySettingsMutationRefreshCompleted = false,
            )
        }
    }

    fun requestPowerAction(
        action: io.github.qwertyuiop1995.dsmnativeclient.domain.NasPowerAction,
    ): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current == null || current.isPerformingAction || current.pendingPowerAction != null ||
            current.powerMutationInProgress || current.powerMutationResult != null ||
            current.powerMutationFailure != null
        ) false else {
            _workspace.value = current.copy(pendingPowerAction = action)
            true
        }
    }

    fun cancelPowerActionConfirmation(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current == null || current.pendingPowerAction == null || current.powerMutationInProgress ||
            current.powerMutationResult != null || current.powerMutationFailure != null
        ) false else {
            _workspace.value = current.copy(pendingPowerAction = null)
            true
        }
    }

    fun confirmPowerAction(): Boolean {
        val repo = repository ?: return false
        lateinit var action: io.github.qwertyuiop1995.dsmnativeclient.domain.NasPowerAction
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            action = current.pendingPowerAction ?: return false
            if (
                repository !== repo || current.isPerformingAction || current.powerMutationInProgress ||
                current.powerMutationResult != null || current.powerMutationFailure != null
            ) return false
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                powerMutationInProgress = true,
                powerMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.performPowerActionResult(action)
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            it.powerMutationGeneration == generation &&
                            nasSettingsRequestGeneration.get() == generation
                    }?.copy(
                        isPerformingAction = false,
                        powerMutationInProgress = false,
                        powerMutationResult = result,
                    ) ?: current
                }
            } catch (error: CancellationException) {
                finishPowerMutationFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishPowerMutationFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
        return true
    }

    private fun finishPowerMutationFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                repository === repo && it.profile.id == profileId &&
                    it.powerMutationGeneration == generation && nasSettingsRequestGeneration.get() == generation
            }?.copy(
                isPerformingAction = false,
                powerMutationInProgress = false,
                powerMutationFailure = failure,
            ) ?: current
        }
    }

    fun dismissPowerActionResult(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val result = current?.powerMutationResult
        if (
            current == null || current.pendingPowerAction == null || current.isPerformingAction ||
            current.powerMutationInProgress || result == null || !canDismissPowerMutationResult(result)
        ) false else {
            _workspace.value = current.copy(
                pendingPowerAction = null,
                powerMutationResult = null,
                powerMutationFailure = null,
            )
            true
        }
    }

    fun checkNasSystemUpdate() {
        val repo = repository ?: return
        if (_workspace.value?.nasSystemUpdate is Loadable.Loading) return
        viewModelScope.launch {
            _workspace.update { it?.copy(nasSystemUpdate = Loadable.Loading) }
            runCatching { repo.checkSystemUpdate() }
                .onSuccess { result ->
                    _workspace.update { it?.copy(nasSystemUpdate = Loadable.Ready(result)) }
                }
                .onFailure { error ->
                    _workspace.update {
                        it?.copy(nasSystemUpdate = Loadable.Failed(error.asDsmFailure()))
                    }
                }
        }
    }

    fun requestHardwareSettingsEditing(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings,
    ): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
        val canonical = snapshot?.hardwareSettings?.takeIf { snapshot.hardwareSettingsAvailable }
        if (
            current == null || canonical != value || current.isPerformingAction ||
            current.hardwareSettingsEditorVisible || current.hardwareSettingsConfirmationRequested ||
            current.hardwareSettingsMutationInProgress || current.hardwareSettingsMutationRefreshInProgress ||
            current.hardwareSettingsMutationResult != null || current.hardwareSettingsMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                hardwareSettingsBaseline = canonical,
                hardwareSettingsDraft = value,
                hardwareSettingsEditorVisible = true,
                hardwareSettingsMutationRefreshFailure = null,
                hardwareSettingsMutationRefreshCompleted = false,
            )
            true
        }
    }

    fun updateHardwareSettingsDraft(
        value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings,
    ) = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current != null && current.hardwareSettingsEditorVisible &&
            !current.hardwareSettingsConfirmationRequested && !current.hardwareSettingsMutationInProgress &&
            current.hardwareSettingsMutationResult == null && current.hardwareSettingsMutationFailure == null
        ) _workspace.value = current.copy(hardwareSettingsDraft = value)
    }

    fun cancelHardwareSettingsEditing() = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current != null && !current.hardwareSettingsConfirmationRequested &&
            !current.hardwareSettingsMutationInProgress && current.hardwareSettingsMutationResult == null &&
            current.hardwareSettingsMutationFailure == null
        ) {
            _workspace.value = current.copy(
                hardwareSettingsBaseline = null,
                hardwareSettingsDraft = null,
                hardwareSettingsEditorVisible = false,
                hardwareSettingsMutationRefreshFailure = null,
                hardwareSettingsMutationRefreshCompleted = false,
            )
        }
    }

    fun requestHardwareSettingsConfirmation(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
        if (
            current == null || !current.hardwareSettingsEditorVisible ||
            current.hardwareSettingsDraft == null || snapshot?.hardwareSettingsAvailable != true ||
            snapshot?.hardwareSettings != current.hardwareSettingsBaseline || current.isPerformingAction ||
            current.hardwareSettingsConfirmationRequested || current.hardwareSettingsMutationInProgress ||
            current.hardwareSettingsMutationResult != null || current.hardwareSettingsMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                hardwareSettingsEditorVisible = false,
                hardwareSettingsConfirmationRequested = true,
            )
            true
        }
    }

    fun cancelHardwareSettingsConfirmation() = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current != null && current.hardwareSettingsConfirmationRequested &&
            !current.hardwareSettingsMutationInProgress
        ) {
            _workspace.value = current.copy(
                hardwareSettingsEditorVisible = true,
                hardwareSettingsConfirmationRequested = false,
            )
        }
    }

    fun confirmHardwareSettingsMutation(): Boolean {
        val repo = repository ?: return false
        lateinit var baseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings
        lateinit var expected: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            val snapshot = (current.nasSettings as? Loadable.Ready)?.value ?: return false
            baseline = current.hardwareSettingsBaseline ?: return false
            expected = current.hardwareSettingsDraft ?: return false
            if (
                repository !== repo || current.isPerformingAction ||
                !current.hardwareSettingsConfirmationRequested || !snapshot.hardwareSettingsAvailable ||
                snapshot.hardwareSettings != baseline || current.hardwareSettingsMutationInProgress ||
                current.hardwareSettingsMutationResult != null || current.hardwareSettingsMutationFailure != null
            ) return false
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                hardwareSettingsEditorVisible = false,
                hardwareSettingsConfirmationRequested = false,
                hardwareSettingsMutationInProgress = true,
                hardwareSettingsMutationResult = null,
                hardwareSettingsMutationFailure = null,
                hardwareSettingsMutationRefreshFailure = null,
                hardwareSettingsMutationRefreshInProgress = true,
                hardwareSettingsMutationRefreshCompleted = false,
                hardwareSettingsMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.saveHardwareSettingsResult(baseline, expected)
                val shouldRefresh = result.submitted || result.requiresRefresh ||
                    structuredSettingsMutationRequiresRefreshBeforeDismiss(result)
                var refreshFailure: DsmFailure? = null
                val refreshed = if (shouldRefresh) try {
                    repo.activeHardwareSettings()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    refreshFailure = error.asDsmFailure()
                    null
                } else null
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            it.hardwareSettingsMutationGeneration == generation &&
                            nasSettingsRequestGeneration.get() == generation
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        val updated = when {
                            snapshot != null && refreshed != null -> snapshot.copy(
                                hardwareSettings = refreshed,
                                hardwareSettingsAvailable = true,
                            )
                            snapshot != null && result.status == MutationResultStatus.CONFIRMED_SUCCESS ->
                                confirmedHardwareSettingsFallback(snapshot, baseline, expected)
                            else -> null
                        }
                        active.copy(
                            nasSettings = updated?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            hardwareSettingsMutationInProgress = false,
                            hardwareSettingsMutationResult = result,
                            hardwareSettingsMutationRefreshFailure = refreshFailure,
                            hardwareSettingsMutationRefreshInProgress = false,
                            hardwareSettingsMutationRefreshCompleted = refreshed != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            it.hardwareSettingsMutationGeneration == generation &&
                            nasSettingsRequestGeneration.get() == generation
                    }?.copy(
                        isPerformingAction = false,
                        hardwareSettingsMutationInProgress = false,
                        hardwareSettingsMutationRefreshInProgress = false,
                    ) ?: current
                }
                throw error
            } catch (error: Throwable) {
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            it.hardwareSettingsMutationGeneration == generation &&
                            nasSettingsRequestGeneration.get() == generation
                    }?.copy(
                        isPerformingAction = false,
                        hardwareSettingsMutationInProgress = false,
                        hardwareSettingsMutationFailure = error.asDsmFailure(),
                        hardwareSettingsMutationRefreshInProgress = false,
                    ) ?: current
                }
            }
        }
        return true
    }

    fun refreshHardwareSettingsMutation() {
        val repo = repository ?: return
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            if (
                repository !== repo || current.isPerformingAction || current.hardwareSettingsMutationInProgress ||
                current.hardwareSettingsMutationRefreshInProgress ||
                current.hardwareSettingsMutationResult == null && current.hardwareSettingsMutationFailure == null
            ) return
            generation = nasSettingsRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                hardwareSettingsMutationRefreshFailure = null,
                hardwareSettingsMutationRefreshInProgress = true,
                hardwareSettingsMutationRefreshCompleted = false,
                hardwareSettingsMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val refreshed = repo.activeHardwareSettings()
                _workspace.update { current ->
                    current?.takeIf {
                        repository === repo && it.profile.id == profileId &&
                            it.hardwareSettingsMutationGeneration == generation &&
                            nasSettingsRequestGeneration.get() == generation
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        active.copy(
                            nasSettings = snapshot?.copy(
                                hardwareSettings = refreshed,
                                hardwareSettingsAvailable = true,
                            )?.let { Loadable.Ready(it) } ?: active.nasSettings,
                            isPerformingAction = false,
                            hardwareSettingsMutationRefreshInProgress = false,
                            hardwareSettingsMutationRefreshCompleted = snapshot != null,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishHardwareSettingsRefreshFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishHardwareSettingsRefreshFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
    }

    private fun finishHardwareSettingsRefreshFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                repository === repo && it.profile.id == profileId &&
                    it.hardwareSettingsMutationGeneration == generation &&
                    nasSettingsRequestGeneration.get() == generation
            }?.copy(
                isPerformingAction = false,
                hardwareSettingsMutationRefreshFailure = failure,
                hardwareSettingsMutationRefreshInProgress = false,
            ) ?: current
        }
    }

    fun dismissHardwareSettingsMutationResult(discardDraft: Boolean = false) {
        _workspace.update { current ->
            val requiresRefresh = current?.hardwareSettingsMutationResult?.let(
                ::structuredSettingsMutationRequiresRefreshBeforeDismiss,
            ) == true || current?.hardwareSettingsMutationFailure != null
            if (
                current == null || current.isPerformingAction || current.hardwareSettingsMutationInProgress ||
                current.hardwareSettingsMutationRefreshInProgress ||
                requiresRefresh && !current.hardwareSettingsMutationRefreshCompleted
            ) return@update current
            val rebased = if (!discardDraft) {
                val snapshot = (current.nasSettings as? Loadable.Ready)?.value
                val draft = current.hardwareSettingsDraft
                if (snapshot != null && draft != null) rebasedHardwareSettingsDraft(snapshot, draft) else null
            } else null
            current.copy(
                hardwareSettingsBaseline = rebased?.first,
                hardwareSettingsDraft = rebased?.second,
                hardwareSettingsEditorVisible = rebased != null,
                hardwareSettingsConfirmationRequested = false,
                hardwareSettingsMutationResult = null,
                hardwareSettingsMutationFailure = null,
                hardwareSettingsMutationRefreshFailure = null,
                hardwareSettingsMutationRefreshInProgress = false,
                hardwareSettingsMutationRefreshCompleted = false,
            )
        }
    }

    fun beginStorageAnalysis() {
        val repo = repository ?: return
        if (storageAnalysisJob?.isActive == true) return
        storageAnalysisJob = viewModelScope.launch {
            _workspace.update {
                it?.copy(
                    storageAnalysis = Loadable.Loading,
                    storageAnalysisProgress = StorageAnalysisProgress("scanning", 0, 0),
                )
            }
            try {
                val result = repo.analyzeStorage { progress ->
                    _workspace.update { current -> current?.copy(storageAnalysisProgress = progress) }
                }
                _workspace.update {
                    it?.copy(
                        storageAnalysis = Loadable.Ready(result),
                        storageAnalysisProgress = null,
                    )
                }
            } catch (_: CancellationException) {
                _workspace.update {
                    it?.copy(
                        storageAnalysis = Loadable.Idle,
                        storageAnalysisProgress = null,
                        message = getApplication<Application>().getString(R.string.storage_analysis_cancelled),
                    )
                }
            } catch (error: Throwable) {
                _workspace.update {
                    it?.copy(
                        storageAnalysis = Loadable.Failed(error.asDsmFailure()),
                        storageAnalysisProgress = null,
                    )
                }
            }
        }
    }

    fun cancelStorageAnalysis() {
        storageAnalysisJob?.cancel()
    }

    fun loadDiskTestStatus(diskId: String) {
        val repo = repository ?: return
        lateinit var disk: NasStorageDisk
        var generation = 0L
        var settingsGeneration = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            val snapshot = (current.nasSettings as? Loadable.Ready)?.value ?: return
            disk = snapshot.storageDisks.firstOrNull { it.id == diskId } ?: return
            if (
                current.diskTestStatuses[diskId] is Loadable.Loading ||
                current.diskTestMutationTarget?.id == diskId
            ) return
            generation = diskTestStatusRequestGeneration.incrementAndGet()
            settingsGeneration = nasSettingsRequestGeneration.get()
            diskTestStatusRequestGenerations[diskId] = generation
            _workspace.value = current.copy(
                diskTestStatuses = current.diskTestStatuses + (diskId to Loadable.Loading),
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val status = repo.loadDiskTestStatus(disk)
                _workspace.update { current ->
                    current?.takeIf {
                        diskTestStatusLoadCallbackMatches(
                            repositoryMatches = repository === repo,
                            profileMatches = it.profile.id == profileId,
                            requestGeneration = generation,
                            currentGeneration = diskTestStatusRequestGenerations[diskId],
                            settingsGeneration = settingsGeneration,
                            currentSettingsGeneration = nasSettingsRequestGeneration.get(),
                            requestedDisk = disk,
                            currentDisk = (it.nasSettings as? Loadable.Ready)?.value?.storageDisks
                                ?.firstOrNull { candidate -> candidate.id == diskId },
                        )
                    }?.copy(
                        diskTestStatuses = current.diskTestStatuses + (diskId to Loadable.Ready(status)),
                    ) ?: current
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                _workspace.update { current ->
                    current?.takeIf {
                        diskTestStatusLoadCallbackMatches(
                            repositoryMatches = repository === repo,
                            profileMatches = it.profile.id == profileId,
                            requestGeneration = generation,
                            currentGeneration = diskTestStatusRequestGenerations[diskId],
                            settingsGeneration = settingsGeneration,
                            currentSettingsGeneration = nasSettingsRequestGeneration.get(),
                            requestedDisk = disk,
                            currentDisk = (it.nasSettings as? Loadable.Ready)?.value?.storageDisks
                                ?.firstOrNull { candidate -> candidate.id == diskId },
                        )
                    }?.copy(
                        diskTestStatuses = current.diskTestStatuses +
                            (diskId to Loadable.Failed(error.asDsmFailure())),
                    ) ?: current
                }
            }
        }
    }

    fun requestDiskTestMutation(
        disk: NasStorageDisk,
        baseline: NasDiskTestStatus,
        operation: NasDiskTestType?,
    ): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val snapshot = (current?.nasSettings as? Loadable.Ready)?.value
        val canonical = snapshot?.storageDisks?.firstOrNull { it.id == disk.id }
        if (
            current == null || snapshot == null ||
            !canRequestDiskTestMutation(snapshot, current.diskTestStatuses, disk, baseline, operation) ||
            current.isPerformingAction || current.diskTestMutationTarget != null ||
            current.diskTestMutationConfirmationRequested || current.diskTestMutationInProgress ||
            current.diskTestMutationRefreshInProgress || current.diskTestMutationResult != null ||
            current.diskTestMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                diskTestMutationTarget = checkNotNull(canonical),
                diskTestMutationBaseline = baseline,
                diskTestMutationOperation = operation,
                diskTestMutationConfirmationRequested = true,
                diskTestMutationRefreshFailure = null,
                diskTestMutationRefreshCompleted = false,
            )
            true
        }
    }

    fun cancelDiskTestMutationConfirmation(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        if (
            current == null || !current.diskTestMutationConfirmationRequested ||
            current.diskTestMutationInProgress || current.diskTestMutationResult != null ||
            current.diskTestMutationFailure != null
        ) false else {
            _workspace.value = current.copy(
                diskTestMutationTarget = null,
                diskTestMutationBaseline = null,
                diskTestMutationOperation = null,
                diskTestMutationConfirmationRequested = false,
            )
            true
        }
    }

    fun confirmDiskTestMutation(): Boolean {
        val repo = repository ?: return false
        lateinit var disk: NasStorageDisk
        lateinit var baseline: NasDiskTestStatus
        var operation: NasDiskTestType? = null
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return false
            val snapshot = (current.nasSettings as? Loadable.Ready)?.value ?: return false
            val requestedDisk = current.diskTestMutationTarget ?: return false
            disk = snapshot.storageDisks.firstOrNull {
                it.id == requestedDisk.id && sameDiskTestTarget(requestedDisk, it)
            } ?: return false
            baseline = current.diskTestMutationBaseline ?: return false
            operation = current.diskTestMutationOperation
            if (
                repository !== repo || current.isPerformingAction ||
                !current.diskTestMutationConfirmationRequested ||
                !canRequestDiskTestMutation(snapshot, current.diskTestStatuses, disk, baseline, operation) ||
                current.diskTestMutationInProgress || current.diskTestMutationResult != null ||
                current.diskTestMutationFailure != null
            ) return false
            generation = nasSettingsRequestGeneration.incrementAndGet()
            diskTestStatusRequestGenerations[disk.id] = diskTestStatusRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                diskTestMutationTarget = disk,
                diskTestMutationConfirmationRequested = false,
                diskTestMutationInProgress = true,
                diskTestMutationResult = null,
                diskTestMutationFailure = null,
                diskTestMutationRefreshFailure = null,
                diskTestMutationRefreshInProgress = true,
                diskTestMutationRefreshCompleted = false,
                diskTestMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val result = repo.changeDiskTestResult(disk, baseline, operation)
                val shouldRefresh = result.submitted || result.requiresRefresh ||
                    destructiveServiceMutationRequiresRefreshBeforeDismiss(result)
                var refreshFailure: DsmFailure? = null
                val status = if (shouldRefresh) try {
                    repo.activeDiskTestStatus(disk)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    refreshFailure = error.asDsmFailure()
                    null
                } else null
                _workspace.update { current ->
                    current?.takeIf {
                        scopedMutationCallbackMatches(
                            repository === repo, it.profile.id == profileId,
                            it.diskTestMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                        )
                    }?.let { active ->
                        val snapshot = (active.nasSettings as? Loadable.Ready)?.value
                        val mergedStatus = status?.let {
                            mergeDiskTestStatusHistory(
                                it,
                                (active.diskTestStatuses[disk.id] as? Loadable.Ready)?.value ?: baseline,
                            )
                        }
                        val trustedRefresh = mergedStatus != null &&
                            isTrustedDiskTestStatus(disk, mergedStatus)
                        val refreshedTargetReached = trustedRefresh &&
                            diskTestMutationTargetReached(disk, checkNotNull(mergedStatus), operation)
                        val fallback = if (
                            !trustedRefresh && snapshot != null &&
                            result.status == MutationResultStatus.CONFIRMED_SUCCESS
                        ) {
                            confirmedDiskTestMutationFallback(
                                snapshot, active.diskTestStatuses, disk, baseline, operation,
                            )
                        } else null
                        val statuses = when {
                            trustedRefresh -> active.diskTestStatuses +
                                (disk.id to Loadable.Ready(checkNotNull(mergedStatus)))
                            fallback != null -> fallback
                            else -> active.diskTestStatuses
                        }
                        active.copy(
                            diskTestStatuses = statuses,
                            isPerformingAction = false,
                            diskTestMutationInProgress = false,
                            diskTestMutationResult = diskTestMutationResultAfterStateCheck(
                                result,
                                targetStateConfirmed = refreshedTargetReached || fallback != null,
                            ),
                            diskTestMutationRefreshFailure = refreshFailure,
                            diskTestMutationRefreshInProgress = false,
                            diskTestMutationRefreshCompleted = trustedRefresh,
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishDiskTestMutationFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishDiskTestMutationFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
        return true
    }

    private fun finishDiskTestMutationFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                scopedMutationCallbackMatches(
                    repository === repo, it.profile.id == profileId,
                    it.diskTestMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                )
            }?.copy(
                isPerformingAction = false,
                diskTestMutationInProgress = false,
                diskTestMutationFailure = failure,
                diskTestMutationRefreshInProgress = false,
            ) ?: current
        }
    }

    fun refreshDiskTestMutation() {
        val repo = repository ?: return
        lateinit var disk: NasStorageDisk
        var generation = 0L
        val profileId = synchronized(nasSettingsStructuredMutationLock) {
            val current = _workspace.value ?: return
            disk = current.diskTestMutationTarget ?: return
            if (
                repository !== repo || current.isPerformingAction || current.diskTestMutationInProgress ||
                current.diskTestMutationRefreshInProgress ||
                current.diskTestMutationResult == null && current.diskTestMutationFailure == null
            ) return
            generation = nasSettingsRequestGeneration.incrementAndGet()
            diskTestStatusRequestGenerations[disk.id] = diskTestStatusRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                diskTestMutationRefreshFailure = null,
                diskTestMutationRefreshInProgress = true,
                diskTestMutationRefreshCompleted = false,
                diskTestMutationGeneration = generation,
            )
            current.profile.id
        }
        viewModelScope.launch {
            try {
                val status = repo.activeDiskTestStatus(disk)
                _workspace.update { current ->
                    current?.takeIf {
                        scopedMutationCallbackMatches(
                            repository === repo, it.profile.id == profileId,
                            it.diskTestMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                        )
                    }?.let { active ->
                        val mergedStatus = mergeDiskTestStatusHistory(
                            status,
                            (active.diskTestStatuses[disk.id] as? Loadable.Ready)?.value
                                ?: active.diskTestMutationBaseline,
                        )
                        val trusted = isTrustedDiskTestStatus(disk, mergedStatus)
                        active.copy(
                            diskTestStatuses = if (trusted) {
                                active.diskTestStatuses + (disk.id to Loadable.Ready(mergedStatus))
                            } else active.diskTestStatuses,
                            isPerformingAction = false,
                            diskTestMutationRefreshInProgress = false,
                            diskTestMutationRefreshCompleted = trusted,
                            diskTestMutationRefreshFailure = if (trusted) null else DsmFailure(
                                null,
                                "The drive test status could not be verified",
                                "Refresh storage information and check the drive again.",
                                kind = DsmErrorKind.INVALID_RESPONSE,
                            ),
                        )
                    } ?: current
                }
            } catch (error: CancellationException) {
                finishDiskTestRefreshFailure(repo, profileId, generation, null)
                throw error
            } catch (error: Throwable) {
                finishDiskTestRefreshFailure(repo, profileId, generation, error.asDsmFailure())
            }
        }
    }

    private fun finishDiskTestRefreshFailure(
        repo: DsmRepository,
        profileId: String,
        generation: Long,
        failure: DsmFailure?,
    ) {
        _workspace.update { current ->
            current?.takeIf {
                scopedMutationCallbackMatches(
                    repository === repo, it.profile.id == profileId,
                    it.diskTestMutationGeneration, generation, nasSettingsRequestGeneration.get(),
                )
            }?.copy(
                isPerformingAction = false,
                diskTestMutationRefreshFailure = failure,
                diskTestMutationRefreshInProgress = false,
            ) ?: current
        }
    }

    fun dismissDiskTestMutationResult(): Boolean = synchronized(nasSettingsStructuredMutationLock) {
        val current = _workspace.value
        val result = current?.diskTestMutationResult
        val requiresRefresh = result?.let(::destructiveServiceMutationRequiresRefreshBeforeDismiss) == true ||
            current?.diskTestMutationFailure != null
        if (
            current == null || current.isPerformingAction || current.diskTestMutationInProgress ||
            current.diskTestMutationRefreshInProgress || requiresRefresh && !current.diskTestMutationRefreshCompleted
        ) false else {
            _workspace.value = current.copy(
                diskTestMutationTarget = null,
                diskTestMutationBaseline = null,
                diskTestMutationOperation = null,
                diskTestMutationConfirmationRequested = false,
                diskTestMutationResult = null,
                diskTestMutationFailure = null,
                diskTestMutationRefreshFailure = null,
                diskTestMutationRefreshInProgress = false,
                diskTestMutationRefreshCompleted = false,
            )
            true
        }
    }

    @Deprecated("Use the full disk target, original test status, and persistent confirmation flow")
    fun changeDiskTest(diskId: String, type: NasDiskTestType?) {
        val current = _workspace.value ?: return
        val snapshot = (current.nasSettings as? Loadable.Ready)?.value ?: return
        val disk = snapshot.storageDisks.firstOrNull { it.id == diskId } ?: return
        val baseline = (current.diskTestStatuses[diskId] as? Loadable.Ready)?.value ?: return
        if (requestDiskTestMutation(disk, baseline, type)) confirmDiskTestMutation()
    }

    fun clearMessage() {
        _workspace.update { it?.copy(message = null) }
    }

    fun setNasPerformanceVisible(visible: Boolean) {
        if (!visible) {
            stopNasPerformanceSampling(resetPause = true)
            return
        }
        val state = _workspace.value ?: return
        if (state.selectedModule != Module.NAS_SETTINGS ||
            state.nasPerformance.selectedTab != NasSettingsTab.PERFORMANCE
        ) return
        nasPerformanceVisible = true
        val repo = repository ?: return
        startNasPerformanceSampling(repo)
    }

    fun toggleNasPerformancePause() {
        val state = _workspace.value ?: return
        val pause = !state.nasPerformance.isPaused
        _workspace.update { current ->
            current?.copy(nasPerformance = current.nasPerformance.copy(isPaused = pause))
        }
        if (pause) {
            nasPerformanceGeneration.incrementAndGet()
            nasPerformanceJob?.cancel()
            nasPerformanceJob = null
        } else {
            repository?.let(::startNasPerformanceSampling)
        }
    }

    fun retryNasPerformance() {
        val repo = repository ?: return
        if (!nasPerformanceVisible || _workspace.value?.selectedModule != Module.NAS_SETTINGS ||
            _workspace.value?.nasPerformance?.selectedTab != NasSettingsTab.PERFORMANCE
        ) return
        _workspace.update { state ->
            state?.copy(
                nasPerformance = state.nasPerformance.copy(
                    error = null,
                    isPaused = false,
                    isLoading = state.nasPerformance.history.isEmpty(),
                ),
            )
        }
        startNasPerformanceSampling(repo)
    }

    private fun startNasPerformanceSampling(repo: DsmRepository) {
        val state = _workspace.value ?: return
        if (!nasPerformanceVisible || state.selectedModule != Module.NAS_SETTINGS ||
            state.nasPerformance.selectedTab != NasSettingsTab.PERFORMANCE ||
            state.nasPerformance.isPaused || nasPerformanceJob?.isActive == true
        ) return
        val token = NasPerformanceRequestToken(
            generation = nasPerformanceGeneration.incrementAndGet(),
            profileId = state.profile.id,
        )
        nasPerformanceJob = viewModelScope.launch {
            while (true) {
                val current = _workspace.value ?: break
                if (!current.matchesNasPerformanceRequest(
                        token,
                        nasPerformanceGeneration.get(),
                        repository === repo,
                        nasPerformanceVisible,
                    )
                ) break
                _workspace.update { workspace ->
                    workspace?.takeIf { it.matchesNasPerformanceRequest(
                        token,
                        nasPerformanceGeneration.get(),
                        repository === repo,
                        nasPerformanceVisible,
                    ) }?.copy(
                        nasPerformance = workspace.nasPerformance.copy(
                            isLoading = workspace.nasPerformance.history.isEmpty() &&
                                workspace.nasPerformance.error == null,
                        ),
                    ) ?: workspace
                }
                runCatching { repo.performanceSample() }
                    .onSuccess { sample ->
                        _workspace.update { workspace ->
                            workspace?.takeIf { it.matchesNasPerformanceRequest(
                                token,
                                nasPerformanceGeneration.get(),
                                repository === repo,
                                nasPerformanceVisible,
                            ) }?.copy(
                                nasPerformance = workspace.nasPerformance.copy(
                                    history = appendPerformanceSample(
                                        workspace.nasPerformance.history,
                                        sample,
                                    ),
                                    isLoading = false,
                                    error = null,
                                ),
                            ) ?: workspace
                        }
                    }
                    .onFailure { error ->
                        if (error is CancellationException) throw error
                        _workspace.update { workspace ->
                            workspace?.takeIf { it.matchesNasPerformanceRequest(
                                token,
                                nasPerformanceGeneration.get(),
                                repository === repo,
                                nasPerformanceVisible,
                            ) }?.copy(
                                nasPerformance = workspace.nasPerformance.copy(
                                    isLoading = false,
                                    error = error.asDsmFailure(),
                                ),
                            ) ?: workspace
                        }
                    }
                delay(NAS_PERFORMANCE_SAMPLE_INTERVAL_MILLIS)
            }
        }
    }

    private fun stopNasPerformanceSampling(resetPause: Boolean) {
        nasPerformanceVisible = false
        nasPerformanceGeneration.incrementAndGet()
        nasPerformanceJob?.cancel()
        nasPerformanceJob = null
        _workspace.update { state ->
            state?.copy(
                nasPerformance = state.nasPerformance.copy(
                    isLoading = false,
                    isPaused = if (resetPause) false else state.nasPerformance.isPaused,
                ),
            )
        }
    }

    fun switchNas(): Boolean {
        val state = synchronized(downloadMutationCoordinatorLock) {
            val candidate = _workspace.value ?: return true
            if (isSwitchingNas) return false
            val downloads = transferStore.downloads(candidate.profile.id)
            val uploads = transferStore.uploads(candidate.profile.id)
            val hasActiveChatMutation = chatMutationBlocksWorkspaceExit(candidate.chatMutationState) ||
                candidate.chatOutgoingMessages.values.flatten().any {
                    it.deliveryState == ChatDeliveryState.SENDING
                } ||
                (candidate.chatMessages as? Loadable.Ready)?.value?.messages.orEmpty().any {
                    it.deliveryState == ChatDeliveryState.SENDING
                }
            if (candidate.hasBlockingStructuredNasMutation() ||
                fileStationMutationBlocksWorkspaceExit(candidate.fileStationMutationState) ||
                downloadCreationBlocksWorkspaceExit(candidate.downloadCreationState) ||
                downloadControlBlocksWorkspaceExit(candidate.downloadControlState) ||
                downloadDestinationEditBlocksWorkspaceExit(candidate.downloadDestinationEditState) ||
                downloadSettingsBlocksWorkspaceExit(candidate.downloadSettingsState) ||
                downloadRssRefreshBlocksWorkspaceExit(candidate.downloadRssRefreshState) ||
                virtualMachineMutationBlocksWorkspaceExit(candidate.virtualMachineMutationState) ||
                !canSafelySwitchNas(
                    downloads = downloads,
                    uploads = uploads,
                    transfers = candidate.transfers,
                    isPerformingAction = candidate.isPerformingAction,
                    hasActiveChatMutation = hasActiveChatMutation,
                )
            ) {
                _workspace.value = candidate.copy(
                    message = getApplication<Application>()
                        .getString(R.string.switch_nas_blocked_active_operation),
                )
                return false
            }
            isSwitchingNas = true
            fileBrowserRequestGeneration.incrementAndGet()
            fileStationMutationGeneration.incrementAndGet()
            invalidateFileUploadPreflights()
            downloadListRequestGeneration.incrementAndGet()
            invalidateFileBackgroundTaskRequests()
            downloadCreationMutationGeneration.incrementAndGet()
            downloadControlMutationGeneration.incrementAndGet()
            downloadDestinationEditMutationGeneration.incrementAndGet()
            downloadSettingsMutationGeneration.incrementAndGet()
            downloadRssRefreshMutationGeneration.incrementAndGet()
            virtualMachineMutationGeneration.incrementAndGet()
            virtualMachineOverviewRequestGeneration.incrementAndGet()
            virtualMachineTaskPollingGeneration.incrementAndGet()
            chatMutationGeneration.incrementAndGet()
            chatAttachmentPreflightGeneration.incrementAndGet()
            chatMutationGenerations.clear()
            repository = null
            clearPackageIconCache()
            crossNasRepositories.clear()
            _workspace.value = null
            candidate
        }
        cancelOpaqueExternalNavigation(consumePending = true)
        releasePendingVirtualMachineLocalImageGrant()
        store.saveWorkspaceUiState(state.profile.id, state.persistedUiState())
        chatPendingAttachmentUrisForRelease(state).forEach(::releasePersistedReadPermission)
        _login.update {
            it.copy(
                isConnecting = true,
                connectionStatus = null,
                error = null,
                needsOtp = false,
            )
        }
        chatRealtimeClient?.stop()
        chatRealtimeClient = null
        chatRealtimeConnected = false
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            val switchingJob = currentCoroutineContext()[Job]
            val activeWorkspaceJobs = viewModelScope.coroutineContext[Job]
                ?.children
                ?.filter { child -> child !== switchingJob && child !== workspacePersistenceJob }
                ?.toList()
                .orEmpty()
            activeWorkspaceJobs.forEach(Job::cancel)
            activeWorkspaceJobs.forEach { child -> child.join() }

            transferJobs.clear()
            foregroundDownloadExecutionIds.clear()
            transferWatchJobs.clear()
            virtualMachineImageImportWatchJobs.clear()
            photoTimelineJob = null
            storageAnalysisJob = null
            nasPerformanceVisible = false
            nasPerformanceJob = null
            downloadDiscoveryLoadJob = null
            downloadBtCatalogJob = null
            downloadDiscoverySearchJob = null
            downloadActivityJob = null
            virtualMachineTaskPollingJob = null
            chatRefreshJob = null
            chatRealtimeRefreshJob = null
            chatLocalReadMarkers = emptyMap()
            chatAttachmentPreviewJob = null
            chatAttachmentJobs.clear()
            chatMutationJobs.clear()
            thumbnailJobs.clear()
            thumbnailReferences.clear()
            thumbnailCache.evictAll()
            cleanupPreviewFile(state.preview)
            state.chatAttachmentPreviewVideoFile?.delete()
            File(getApplication<Application>().cacheDir, "preview")
                .listFiles()
                ?.forEach(File::delete)
            File(getApplication<Application>().cacheDir, "chat-preview")
                .listFiles()
                ?.forEach(File::delete)

            val profile = state.profile
            val savedPassword = store.password(profile.id).orEmpty()
            _login.update {
                it.copy(
                    profiles = store.profiles(),
                    selectedProfileId = profile.id,
                    savedPassword = savedPassword,
                    rememberPassword = savedPassword.isNotEmpty(),
                    autoLoginEnabled = savedPassword.isNotEmpty() &&
                        store.isAutoLoginEnabled(profile.id),
                    isConnecting = false,
                    connectionStatus = null,
                    error = null,
                    needsOtp = false,
                )
            }
            isSwitchingNas = false
            nasSwitchJob = null
        }
        nasSwitchJob = job
        job.start()
        return true
    }

    fun logout() {
        val state = synchronized(downloadMutationCoordinatorLock) {
            val candidate = _workspace.value ?: return
            if (candidate.isPerformingAction || candidate.hasBlockingStructuredNasMutation() ||
                hasBlockingFileServerTransfer(candidate.transfers) ||
                fileStationMutationBlocksWorkspaceExit(candidate.fileStationMutationState) ||
                downloadCreationBlocksWorkspaceExit(candidate.downloadCreationState) ||
                downloadControlBlocksWorkspaceExit(candidate.downloadControlState) ||
                downloadDestinationEditBlocksWorkspaceExit(candidate.downloadDestinationEditState) ||
                downloadSettingsBlocksWorkspaceExit(candidate.downloadSettingsState) ||
                downloadRssRefreshBlocksWorkspaceExit(candidate.downloadRssRefreshState) ||
                virtualMachineMutationBlocksWorkspaceExit(candidate.virtualMachineMutationState) ||
                chatMutationBlocksWorkspaceExit(candidate.chatMutationState)
            ) {
                _workspace.value = candidate.copy(
                    message = getApplication<Application>()
                        .getString(R.string.switch_nas_blocked_active_operation),
                )
                return
            }
            fileBrowserRequestGeneration.incrementAndGet()
            fileStationMutationGeneration.incrementAndGet()
            invalidateFileUploadPreflights()
            downloadListRequestGeneration.incrementAndGet()
            invalidateFileBackgroundTaskRequests()
            downloadCreationMutationGeneration.incrementAndGet()
            downloadControlMutationGeneration.incrementAndGet()
            downloadDestinationEditMutationGeneration.incrementAndGet()
            downloadSettingsMutationGeneration.incrementAndGet()
            downloadRssRefreshMutationGeneration.incrementAndGet()
            virtualMachineMutationGeneration.incrementAndGet()
            virtualMachineOverviewRequestGeneration.incrementAndGet()
            chatMutationGeneration.incrementAndGet()
            chatAttachmentPreflightGeneration.incrementAndGet()
            chatMutationGenerations.clear()
            repository = null
            clearPackageIconCache()
            crossNasRepositories.clear()
            _workspace.value = null
            candidate
        }
        cancelOpaqueExternalNavigation(consumePending = true)
        releasePendingVirtualMachineLocalImageGrant()
        chatPendingAttachmentUrisForRelease(state).forEach(::releasePersistedReadPermission)
        transferJobs.values.forEach(Job::cancel)
        transferJobs.clear()
        transferWatchJobs.values.forEach(Job::cancel)
        transferWatchJobs.clear()
        virtualMachineImageImportWatchJobs.values.forEach(Job::cancel)
        virtualMachineImageImportWatchJobs.clear()
        photoTimelineJob?.cancel()
        photoTimelineJob = null
        storageAnalysisJob?.cancel()
        storageAnalysisJob = null
        stopNasPerformanceSampling(resetPause = true)
        chatRefreshJob?.cancel()
        chatRealtimeRefreshJob?.cancel()
        chatRealtimeClient?.stop()
        chatRealtimeClient = null
        chatRealtimeConnected = false
        chatLocalReadMarkers = emptyMap()
        chatAttachmentJobs.values.forEach(Job::cancel)
        chatAttachmentJobs.clear()
        chatMutationJobs.values.forEach(Job::cancel)
        chatMutationJobs.clear()
        closeChatAttachmentPreview()
        transferStore.downloads(state.profile.id).forEach { download ->
            if (download.state.hasIncompleteDownloadDestination()) {
                download.workId?.let { runCatching { workManager.cancelWorkById(UUID.fromString(it)) } }
                deleteIncompleteDownload(Uri.parse(download.destinationUri))
                releasePersistedDownloadPermission(Uri.parse(download.destinationUri))
                transferStore.update(download.id) { it.copy(state = TransferState.CANCELLED) }
            }
        }
        transferStore.uploads(state.profile.id)
            .filter { it.state !in TERMINAL_TRANSFER_STATES }
            .forEach { upload ->
                upload.workId?.let { value ->
                    runCatching { workManager.cancelWorkById(UUID.fromString(value)) }
                }
                transferStore.updateUpload(upload.id) {
                    it.cancelUploadForLogout()
                }
            }
        clearPreviewCaches()
        val repoProfile = state.profile
        store.clearSession(repoProfile.id)
        store.setAutoLoginEnabled(repoProfile.id, false)
        val savedPassword = store.password(repoProfile.id).orEmpty()
        _login.update {
            it.copy(
                profiles = store.profiles(),
                selectedProfileId = repoProfile.id,
                savedPassword = savedPassword,
                rememberPassword = savedPassword.isNotEmpty(),
                autoLoginEnabled = false,
                connectionStatus = null,
                error = null,
                needsOtp = false,
            )
        }
    }

    private suspend fun loadFiles(repo: DsmRepository, path: String) {
        _workspace.update { it?.copy(files = Loadable.Loading) }
        capture(
            block = { if (path.isBlank()) repo.listShares() else repo.listDirectory(path) },
            update = { value -> _workspace.update { it?.copy(files = value) } },
        )
    }

    private suspend fun refreshFavorites(repo: DsmRepository) {
        if (repo !== repository || !repo.supportsFavorites()) return
        runCatching { repo.listFavorites().mapTo(mutableSetOf()) { it.path } }
            .onSuccess { favoritePaths ->
                _workspace.update { current ->
                    current?.takeIf { repo === repository }?.copy(
                        favoritePaths = favoritePaths,
                        files = current.files.withFavoritePaths(favoritePaths),
                    ) ?: current
                }
            }
    }

    private suspend fun loadFileBrowser(repo: DsmRepository) {
        if (repo !== repository) return
        val state = _workspace.value ?: return
        if (state.selectedModule != Module.FILES) return
        val browser = state.fileBrowser
        val requestToken = FileBrowserRequestToken(
            generation = fileBrowserRequestGeneration.incrementAndGet(),
            identity = browser.fileBrowserRequestIdentity(),
        )
        _workspace.update { current ->
            current?.takeIf {
                repo === repository &&
                it.selectedModule == Module.FILES &&
                    it.fileBrowser.matchesFileBrowserRequest(
                        requestToken,
                        fileBrowserRequestGeneration.get(),
                    )
            }?.copy(files = Loadable.Loading, fileIsLoadingMore = false)
                ?: current
        }
        val activeState = _workspace.value
        if (repo !== repository ||
            activeState?.selectedModule != Module.FILES ||
            activeState.fileBrowser.matchesFileBrowserRequest(
                requestToken,
                fileBrowserRequestGeneration.get(),
            ).not() ||
            activeState.files != Loadable.Loading
        ) return
        runCatching {
            // 目录基线只决定后续写入口是否可用，读取失败不能阻断原本可用的浏览。
            val directoryBaseline = browser.path.takeIf(String::isNotBlank)?.let { path ->
                runCatching { repo.fileInfo(path) }.getOrElse { error ->
                    if (error is CancellationException) throw error
                    null
                }
            }
            val page = browser.activeSearchQuery?.let { repo.search(browser.path, it) }
                ?: listFilePage(repo, browser, 0)
            directoryBaseline to page
        }.onSuccess { (directoryBaseline, page) ->
            _workspace.update { current ->
                current?.takeIf {
                    repo === repository &&
                    it.selectedModule == Module.FILES &&
                        it.fileBrowser.matchesFileBrowserRequest(
                            requestToken,
                            fileBrowserRequestGeneration.get(),
                        )
                }?.copy(
                    fileDirectoryBaselines = directoryBaseline?.let { baseline ->
                        current.fileDirectoryBaselines + (baseline.path to baseline)
                    } ?: current.fileDirectoryBaselines,
                    files = Loadable.Ready(
                        page.copy(
                            items = page.items.map { item ->
                                if (item.path in current.favoritePaths) item.copy(isFavorite = true) else item
                            },
                        ),
                    ),
                ) ?: current
            }
        }.onFailure { error ->
            _workspace.update { current ->
                current?.takeIf {
                    repo === repository &&
                    it.selectedModule == Module.FILES &&
                        it.fileBrowser.matchesFileBrowserRequest(
                            requestToken,
                            fileBrowserRequestGeneration.get(),
                        )
                }?.copy(files = Loadable.Failed(error.asDsmFailure())) ?: current
            }
        }
    }

    private suspend fun listFilePage(
        repo: DsmRepository,
        browser: FileBrowserState,
        offset: Int,
    ): FilePage {
        val sortBy = when (browser.sortOption) {
            FileSortOption.NAME -> "name"
            FileSortOption.MODIFIED_TIME -> "mtime"
            FileSortOption.SIZE -> "size"
        }
        return if (browser.path.isBlank()) {
            repo.listShares(offset, FILE_PAGE_SIZE, sortBy, browser.sortAscending)
        } else {
            repo.listDirectory(
                browser.path,
                offset,
                FILE_PAGE_SIZE,
                sortBy,
                browser.sortAscending,
                when (browser.typeFilter) {
                    FileTypeFilter.ALL -> "all"
                    FileTypeFilter.FOLDERS -> "dir"
                    FileTypeFilter.FILES -> "file"
                },
            )
        }
    }

    private suspend fun loadChatMessages(
        repo: DsmRepository,
        conversation: ChatConversation,
        reset: Boolean,
    ) {
        val currentPage = (_workspace.value?.chatMessages as? Loadable.Ready)?.value
        val offset = if (reset) 0 else currentPage?.nextOffset ?: return
        if (!reset) _workspace.update { it?.copy(chatIsLoadingMore = true) }
        runCatching { repo.chatMessages(conversation.id, offset) }
            .onSuccess { page ->
                _workspace.update { current ->
                    if (current?.selectedConversation?.id != conversation.id) return@update current
                    val merged = if (reset || currentPage == null) {
                        page.copy(
                            messages = (page.messages + current.chatOutgoingMessages[conversation.id].orEmpty())
                                .distinctBy(ChatMessage::id)
                                .sortedBy(ChatMessage::createdAtEpochSeconds),
                        )
                    } else {
                        page.copy(
                            messages = (page.messages + currentPage.messages)
                                .distinctBy(ChatMessage::id)
                                .sortedBy(ChatMessage::createdAtEpochSeconds),
                        )
                    }
                    current.copy(chatMessages = Loadable.Ready(merged), chatIsLoadingMore = false)
                }
            }
            .onFailure { error ->
                if (error is CancellationException) return@onFailure
                _workspace.update { current ->
                    if (current?.selectedConversation?.id != conversation.id) return@update current
                    if (reset) {
                        current.copy(chatMessages = Loadable.Failed(error.asDsmFailure()))
                    } else {
                        current.copy(
                            chatIsLoadingMore = false,
                            message = error.asDsmFailure().localize(getApplication<Application>()).combined,
                        )
                    }
                }
            }
    }

    private suspend fun refreshLatestChatMessages(
        repo: DsmRepository,
        conversation: ChatConversation,
    ) {
        val latest = runCatching { repo.chatMessages(conversation.id, 0) }.getOrNull() ?: return
        _workspace.update { current ->
            if (current?.selectedConversation?.id != conversation.id) return@update current
            val existing = (current.chatMessages as? Loadable.Ready)?.value ?: return@update current
            current.copy(
                chatMessages = Loadable.Ready(
                    existing.copy(
                        messages = (existing.messages + latest.messages)
                            .distinctBy(ChatMessage::id)
                            .sortedBy(ChatMessage::createdAtEpochSeconds),
                    ),
                ),
            )
        }
    }

    private fun updateChatConversationState(
        expectedRepository: DsmRepository,
        conversations: List<ChatConversation>?,
    ) = updateChatConversationState(
        expectedRepository,
        conversations,
        requireConversationListActive = false,
    )

    private fun updateChatConversationState(
        expectedRepository: DsmRepository,
        conversations: List<ChatConversation>?,
        requireConversationListActive: Boolean,
    ) {
        if (repository !== expectedRepository) return
        val state = _workspace.value ?: return
        if (requireConversationListActive &&
            (state.selectedModule != Module.CHAT || state.selectedConversation != null)
        ) return
        val withConversations = conversations?.let { incoming ->
            val overlay = applyChatLocalReadOverlay(incoming, chatLocalReadMarkers)
            chatLocalReadMarkers = overlay.markers
            val visible = applyChatConversationPreferences(
                overlay.conversations,
                state.chatPinnedConversationIds,
            )
            state.withRefreshedChatConversations(visible)
        } ?: state
        _workspace.value = withConversations
    }

    private fun startChatConversationPolling(repo: DsmRepository) {
        chatRefreshJob?.cancel()
        chatRefreshJob = viewModelScope.launch {
            while (true) {
                delay(CHAT_REFRESH_INTERVAL_MILLIS)
                val current = _workspace.value
                if (current?.selectedModule != Module.CHAT || current.selectedConversation != null) break
                runCatching { repo.chatConversations() }.getOrNull()?.let { conversations ->
                    updateChatConversationState(
                        expectedRepository = repo,
                        conversations = conversations,
                        requireConversationListActive = true,
                    )
                }
            }
        }
    }

    private fun startChatRealtime(repo: DsmRepository) {
        if (chatRealtimeClient != null) return
        chatRealtimeClient = repo.chatRealtimeClient(
            onConnectionChanged = { connected ->
                viewModelScope.launch {
                    chatRealtimeConnected = connected
                    if (connected) {
                        chatRefreshJob?.cancel()
                        chatRefreshJob = null
                    } else {
                        val state = _workspace.value
                        if (state?.selectedModule == Module.CHAT) {
                            val conversation = state.selectedConversation
                            if (conversation == null) startChatConversationPolling(repo)
                            else startChatMessagePolling(repo, conversation)
                        }
                    }
                }
            },
            onContentChanged = {
                viewModelScope.launch {
                    chatRealtimeRefreshJob?.cancel()
                    chatRealtimeRefreshJob = viewModelScope.launch {
                        delay(CHAT_REALTIME_COALESCE_MILLIS)
                        val state = _workspace.value
                        if (state?.selectedModule != Module.CHAT) return@launch
                        val conversation = state.selectedConversation
                        if (conversation != null) {
                            refreshLatestChatMessages(repo, conversation)
                        } else {
                            runCatching { repo.chatConversations() }.getOrNull()?.let { conversations ->
                                updateChatConversationState(
                                    expectedRepository = repo,
                                    conversations = conversations,
                                    requireConversationListActive = true,
                                )
                            }
                        }
                    }
                }
            },
        ).also { it.start(viewModelScope) }
    }

    private fun performChatSend(claim: ChatMutationClaim, local: ChatMessage) {
        val requestId = local.clientRequestId ?: return
        launchChatMutation(claim) { repo ->
            val outcome = repo.sendChatTextMessageResult(local.conversationId, local.body, requestId)
            val sent = outcome.message
            val confirmed = outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS &&
                sent != null
            ChatMutationCompletion(
                outcome.result,
                chatMutationVerification(claim.target, messages = listOfNotNull(sent)),
                apply = { current ->
                    if (confirmed) current.withCompletedOutgoingChatMessage(local, checkNotNull(sent))
                    else current.withFailedOutgoingChatMessage(local)
                },
            )
        }
    }

    private fun performChatAttachmentSend(
        claim: ChatMutationClaim,
        local: ChatMessage,
        source: UploadSource,
        persistedUri: Uri,
    ) {
        val requestId = local.clientRequestId ?: return
        launchChatMutation(claim) { repo ->
            val outcome =
            repo.sendChatAttachmentMessageResult(
                local.conversationId,
                local.body,
                source,
                requestId,
            ) { completed, total ->
                val progress = if (total > 0) {
                    (completed.toFloat() / total).coerceIn(0f, 1f)
                } else null
                synchronized(downloadMutationCoordinatorLock) {
                    val state = _workspace.value ?: return@synchronized
                    val entry = state.chatMutationState.entries[requestId]
                    if (!chatMutationCallbackMatches(
                            repository === claim.repository,
                            state.profile.id == claim.profileId,
                            entry,
                            claim.target,
                            claim.generation,
                            chatMutationGenerations[requestId],
                        )
                    ) return@synchronized
                    val outgoing = state?.chatOutgoingMessages?.get(local.conversationId)
                        ?: return@synchronized
                    val updated = outgoing.map {
                        if (it.id == local.id) it.copy(attachmentProgress = progress) else it
                    }
                    val page = (state.chatMessages as? Loadable.Ready)?.value
                    _workspace.value = state.copy(
                        chatOutgoingMessages = state.chatOutgoingMessages +
                            (local.conversationId to updated),
                        chatMessages = page?.takeIf {
                            state.selectedConversation?.id == local.conversationId
                        }?.copy(
                            messages = page.messages.map {
                                if (it.id == local.id) it.copy(attachmentProgress = progress) else it
                            },
                        )?.let { Loadable.Ready(it) } ?: state.chatMessages,
                    )
                }
            }
            val sent = outcome.message
            val confirmed = outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS &&
                sent != null
            ChatMutationCompletion(
                outcome.result,
                chatMutationVerification(claim.target, messages = listOfNotNull(sent)),
                apply = { current ->
                    if (confirmed) current.withCompletedOutgoingChatMessage(local, checkNotNull(sent))
                        .copy(chatPendingAttachmentUris = current.chatPendingAttachmentUris - local.id)
                    else current.withFailedOutgoingChatMessage(local)
                },
                afterApply = if (confirmed) {
                    { releasePersistedReadPermission(persistedUri) }
                } else null,
            )
        }
    }

    private fun WorkspaceState.withFailedOutgoingChatMessage(local: ChatMessage): WorkspaceState {
        val failed = local.copy(deliveryState = ChatDeliveryState.FAILED, attachmentProgress = null)
        val outgoing = chatOutgoingMessages[local.conversationId].orEmpty().map {
            if (it.id == local.id) failed else it
        }
        val page = (chatMessages as? Loadable.Ready)?.value
        return copy(
            chatOutgoingMessages = chatOutgoingMessages + (local.conversationId to outgoing),
            chatMessages = page?.takeIf {
                selectedConversation?.id == local.conversationId
            }?.copy(
                messages = page.messages.map { if (it.id == local.id) failed else it },
            )?.let { Loadable.Ready(it) } ?: chatMessages,
        )
    }

    private fun WorkspaceState.withCompletedOutgoingChatMessage(
        local: ChatMessage,
        sent: ChatMessage,
    ): WorkspaceState {
        val confirmed = sent.copy(clientRequestId = local.clientRequestId)
        val outgoing = chatOutgoingMessages[local.conversationId].orEmpty()
            .filterNot { it.id == local.id || it.id == confirmed.id } + confirmed
        val page = (chatMessages as? Loadable.Ready)?.value
        return copy(
            chatOutgoingMessages = chatOutgoingMessages + (local.conversationId to outgoing),
            chatMessages = page?.takeIf {
                selectedConversation?.id == local.conversationId
            }?.copy(
                messages = (page.messages.filterNot { it.id == local.id || it.id == confirmed.id } + confirmed)
                    .sortedBy(ChatMessage::createdAtEpochSeconds),
            )?.let { Loadable.Ready(it) } ?: chatMessages,
        )
    }

    private fun updateOutgoingChatMessage(message: ChatMessage, clearsDraft: Boolean = false) {
        _workspace.update { state ->
            state ?: return@update state
            val outgoing = state.chatOutgoingMessages[message.conversationId].orEmpty()
            val updated = (outgoing.filterNot { it.id == message.id } + message)
                .sortedBy(ChatMessage::createdAtEpochSeconds)
                .takeLast(MAX_LOCAL_CHAT_MESSAGES_PER_CONVERSATION)
            val page = (state.chatMessages as? Loadable.Ready)?.value
            val visible = if (state.selectedConversation?.id == message.conversationId && page != null) {
                Loadable.Ready(
                    page.copy(
                        messages = (page.messages.filterNot { it.id == message.id } + message)
                            .distinctBy(ChatMessage::id)
                            .sortedBy(ChatMessage::createdAtEpochSeconds),
                    ),
                )
            } else {
                state.chatMessages
            }
            state.copy(
                chatDrafts = if (clearsDraft) state.chatDrafts + (message.conversationId to "") else state.chatDrafts,
                chatOutgoingMessages = state.chatOutgoingMessages + (message.conversationId to updated),
                chatMessages = visible,
            )
        }
    }

    private fun replaceOutgoingChatMessage(local: ChatMessage, sent: ChatMessage) {
        _workspace.update { state ->
            state ?: return@update state
            val confirmed = sent.copy(deliveryState = ChatDeliveryState.SENT)
            val outgoing = state.chatOutgoingMessages[local.conversationId].orEmpty()
                .filterNot { it.id == local.id }.plus(confirmed)
                .takeLast(MAX_LOCAL_CHAT_MESSAGES_PER_CONVERSATION)
            val page = (state.chatMessages as? Loadable.Ready)?.value
            state.copy(
                chatOutgoingMessages = state.chatOutgoingMessages +
                    (local.conversationId to outgoing.distinctBy(ChatMessage::id)),
                chatMessages = if (state.selectedConversation?.id == local.conversationId && page != null) {
                    Loadable.Ready(
                        page.copy(
                            messages = (page.messages.filterNot { it.id == local.id } + confirmed)
                                .distinctBy(ChatMessage::id)
                                .sortedBy(ChatMessage::createdAtEpochSeconds),
                        ),
                    )
                } else state.chatMessages,
            )
        }
    }

    private suspend fun loadPhotoPage(repo: DsmRepository, reset: Boolean) {
        val state = _workspace.value ?: return
        if (state.selectedModule != Module.PHOTOS) return
        val browser = state.photoBrowser
        val existing = (state.photos as? Loadable.Ready)?.value
        val offset = if (reset) 0 else existing?.nextOffset ?: return
        if (reset) {
            _workspace.update { current ->
                current?.takeIf {
                    it.selectedModule == Module.PHOTOS && it.photoBrowser == browser
                }?.copy(photos = Loadable.Loading) ?: current
            }
        }
        runCatching {
            PhotoRepository(repo).page(
                space = browser.selectedSpace,
                folderPath = browser.folderPath,
                offset = offset,
            )
        }.onSuccess { page ->
            _workspace.update { current ->
                if (current == null ||
                    current.selectedModule != Module.PHOTOS ||
                    current.photoBrowser.selectedSpaceId != browser.selectedSpaceId ||
                    current.photoBrowser.folderPath != browser.folderPath
                ) {
                    return@update current
                }
                val merged = if (reset || existing == null) {
                    page
                } else {
                    page.copy(
                        items = (existing.items + page.items).distinctBy { it.id },
                        offset = existing.offset,
                    )
                }
                current.copy(
                    photos = Loadable.Ready(merged),
                    photoBrowser = current.photoBrowser.copy(
                        spaceAccess = current.photoBrowser.spaceAccess +
                            (browser.selectedSpaceId to PhotoSpaceAccess.AVAILABLE),
                        isLoadingMore = false,
                    ),
                )
            }
        }.onFailure { error ->
            val failure = error.asDsmFailure()
            _workspace.update { current ->
                if (current == null ||
                    current.selectedModule != Module.PHOTOS ||
                    current.photoBrowser.selectedSpaceId != browser.selectedSpaceId ||
                    current.photoBrowser.folderPath != browser.folderPath
                ) {
                    return@update current
                }
                val atSpaceRoot = browser.folderPath == browser.selectedSpace.rootPath
                current.copy(
                    photos = if (reset || existing == null) {
                        Loadable.Failed(failure)
                    } else {
                        current.photos
                    },
                    photoBrowser = current.photoBrowser.copy(
                        spaceAccess = if (reset && atSpaceRoot) {
                            current.photoBrowser.spaceAccess +
                                (browser.selectedSpaceId to PhotoSpaceAccess.UNAVAILABLE)
                        } else {
                            current.photoBrowser.spaceAccess
                        },
                        isLoadingMore = false,
                    ),
                    message = if (!reset && existing != null) {
                        failure.localize(getApplication<Application>()).combined
                    } else {
                        current.message
                    },
                )
            }
        }
    }

    private suspend fun loadPhotoMoveFolders(repo: DsmRepository, move: PhotoMoveState) {
        runCatching {
            val page = PhotoRepository(repo).page(
                move.space,
                move.location.path,
                limit = 500,
            )
            val info = try {
                repo.fileInfo(move.location.path)
            } catch (_: DsmFailure) {
                null
            }
            page to info
        }.onSuccess { (page, info) ->
            _workspace.update { current ->
                val active = current?.photoMove ?: return@update current
                if (active.item.id != move.item.id || active.location.path != move.location.path) {
                    return@update current
                }
                current.copy(
                    photoMove = active.copy(
                        location = active.location.copy(
                            canWrite = info?.canWrite ?: active.location.canWrite,
                            baseline = info?.takeIf(FileItem::isDirectory)
                                ?: active.location.baseline,
                        ),
                    ),
                    photoMoveFolders = Loadable.Ready(page),
                )
            }
        }.onFailure { error ->
            if (error is CancellationException) throw error
            _workspace.update { current ->
                current?.takeIf {
                    it.photoMove?.item?.id == move.item.id &&
                        it.photoMove.location.path == move.location.path
                }?.copy(photoMoveFolders = Loadable.Failed(error.asDsmFailure())) ?: current
            }
        }
    }

    private suspend fun loadFileCopyMoveFolders(
        repo: DsmRepository,
        operation: FileCopyMoveState,
    ) {
        runCatching {
            if (operation.location.path.isBlank()) {
                repo.listShares(limit = 500)
            } else {
                repo.listDirectory(
                    path = operation.location.path,
                    limit = 500,
                    fileType = "dir",
                )
            }
        }.onSuccess { page ->
            _workspace.update { current ->
                current?.takeIf {
                    it.fileCopyMove?.items?.map(FileItem::path) == operation.items.map(FileItem::path) &&
                        it.fileCopyMove.targetProfileId == operation.targetProfileId &&
                        it.fileCopyMove.location.path == operation.location.path
                }?.copy(fileCopyMoveFolders = Loadable.Ready(page)) ?: current
            }
        }.onFailure { error ->
            _workspace.update { current ->
                current?.takeIf {
                    it.fileCopyMove?.items?.map(FileItem::path) == operation.items.map(FileItem::path) &&
                        it.fileCopyMove.targetProfileId == operation.targetProfileId &&
                        it.fileCopyMove.location.path == operation.location.path
                }?.copy(fileCopyMoveFolders = Loadable.Failed(error.asDsmFailure())) ?: current
            }
        }
    }

    private fun fileCopyMoveRepository(operation: FileCopyMoveState): DsmRepository? =
        if (operation.targetProfileId == operation.sourceProfileId) {
            repository
        } else {
            crossNasRepositories[operation.targetProfileId]
        }

    private suspend fun resolveFileCopyMoveRepository(
        operation: FileCopyMoveState,
    ): DsmRepository {
        fileCopyMoveRepository(operation)?.let { return it }
        val profile = operation.targetProfiles.firstOrNull { it.id == operation.targetProfileId }
            ?: throw DsmFailure(
                null,
                "The destination NAS is no longer available",
                "Choose another NAS and try again.",
                kind = DsmErrorKind.NO_SAVED_SESSION,
            )
        val session = store.session(profile.id) ?: throw DsmFailure(
            null,
            "The destination NAS needs you to sign in again",
            "Connect to that NAS, then retry the transfer.",
            true,
            DsmErrorKind.NO_SAVED_SESSION,
        )
        val discovered = connectionResolver.discover(profile)
        return DsmRepository(discovered.profile, session, api, discovered.capabilities).also {
            crossNasRepositories[profile.id] = it
        }
    }

    private suspend fun loadDownloadDestinationFolders(
        repo: DsmRepository,
        picker: DownloadDestinationPickerState,
    ) {
        runCatching {
            if (picker.location.path.isBlank()) {
                repo.listShares(limit = 500)
            } else {
                repo.listDirectory(
                    path = picker.location.path,
                    limit = 500,
                    fileType = "dir",
                )
            }
        }.onSuccess { page ->
            _workspace.update { current ->
                current?.takeIf {
                    it.downloadDestinationPicker?.location?.path == picker.location.path
                }?.copy(downloadDestinationFolders = Loadable.Ready(page)) ?: current
            }
        }.onFailure { error ->
            _workspace.update { current ->
                current?.takeIf {
                    it.downloadDestinationPicker?.location?.path == picker.location.path
                }?.copy(
                    downloadDestinationFolders = Loadable.Failed(error.asDsmFailure()),
                ) ?: current
            }
        }
    }

    private suspend fun loadVirtualMachineImageBrowser(
        repo: DsmRepository,
        path: String,
        generation: Long,
    ) {
        try {
            val page = if (path.isBlank()) {
                repo.listShares(limit = 500)
            } else {
                repo.listDirectory(path = path, limit = 500, fileType = "all")
            }
            _workspace.update { current ->
                val draft = current?.virtualMachineMutationState?.imageImportDraft
                current?.takeIf {
                    repository === repo && it.selectedModule == Module.VIRTUAL_MACHINES &&
                        virtualMachineImageBrowserGeneration.get() == generation &&
                        it.virtualMachineMutationState.imageImportEditorVisible &&
                        draft?.browserPath == path
                }?.copy(
                    virtualMachineMutationState = current.virtualMachineMutationState.copy(
                        imageImportDraft = draft?.copy(browserItems = Loadable.Ready(page)),
                    ),
                ) ?: current
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val failure = error.asDsmFailure()
            _workspace.update { current ->
                val draft = current?.virtualMachineMutationState?.imageImportDraft
                current?.takeIf {
                    repository === repo && it.selectedModule == Module.VIRTUAL_MACHINES &&
                        virtualMachineImageBrowserGeneration.get() == generation &&
                        it.virtualMachineMutationState.imageImportEditorVisible &&
                        draft?.browserPath == path
                }?.copy(
                    virtualMachineMutationState = current.virtualMachineMutationState.copy(
                        imageImportDraft = draft?.copy(browserItems = Loadable.Failed(failure)),
                    ),
                ) ?: current
            }
        }
    }

    private fun startPhotoTimelineLoad(repo: DsmRepository) {
        photoTimelineJob?.cancel()
        val browser = _workspace.value?.photoBrowser ?: return
        _workspace.update { current ->
            current?.takeIf {
                it.selectedModule == Module.PHOTOS &&
                    it.photoBrowser.selectedSpaceId == browser.selectedSpaceId &&
                    it.photoBrowser.mode == PhotoBrowseMode.TIMELINE
            }?.copy(photoTimeline = Loadable.Loading) ?: current
        }
        photoTimelineJob = viewModelScope.launch {
            runCatching {
                PhotoRepository(repo).scanTimeline(browser.selectedSpace) { progress ->
                    _workspace.update { current ->
                        current?.takeIf {
                            it.selectedModule == Module.PHOTOS &&
                                it.photoBrowser.selectedSpaceId == browser.selectedSpaceId &&
                                it.photoBrowser.mode == PhotoBrowseMode.TIMELINE
                        }?.copy(photoTimeline = Loadable.Ready(progress)) ?: current
                    }
                }
            }.onSuccess { progress ->
                _workspace.update { current ->
                    current?.takeIf {
                        it.selectedModule == Module.PHOTOS &&
                            it.photoBrowser.selectedSpaceId == browser.selectedSpaceId &&
                            it.photoBrowser.mode == PhotoBrowseMode.TIMELINE
                    }?.copy(
                        photoTimeline = Loadable.Ready(progress),
                        photoBrowser = current.photoBrowser.copy(
                            spaceAccess = current.photoBrowser.spaceAccess +
                                (browser.selectedSpaceId to PhotoSpaceAccess.AVAILABLE),
                        ),
                    ) ?: current
                }
            }.onFailure { error ->
                if (error is CancellationException) return@onFailure
                _workspace.update { current ->
                    current?.takeIf {
                        it.selectedModule == Module.PHOTOS &&
                            it.photoBrowser.selectedSpaceId == browser.selectedSpaceId &&
                            it.photoBrowser.mode == PhotoBrowseMode.TIMELINE
                    }?.copy(
                        photoTimeline = Loadable.Failed(error.asDsmFailure()),
                        photoBrowser = current.photoBrowser.copy(
                            spaceAccess = current.photoBrowser.spaceAccess +
                                (browser.selectedSpaceId to PhotoSpaceAccess.UNAVAILABLE),
                        ),
                    ) ?: current
                }
            }
        }.also { job ->
            job.invokeOnCompletion {
                if (photoTimelineJob == job) photoTimelineJob = null
            }
        }
    }

    private fun thumbnailKey(profileId: String, path: String): String = "$profileId\u0000$path"

    private fun clearPackageIconCache() {
        packageIconJobs.values.forEach(Job::cancel)
        packageIconJobs.clear()
        packageIconCache.evictAll()
        _packageIconGeneration.update { it + 1 }
    }

    private fun decodePackageIcon(bytes: ByteArray, requestedSize: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val maximumDimension = maxOf(requestedSize * 2, MIN_PACKAGE_ICON_DECODE_DIMENSION)
        val sampleSize = packageIconSampleSize(
            width = bounds.outWidth,
            height = bounds.outHeight,
            maximumDimension = maximumDimension,
        )
        val bitmap = BitmapFactory.decodeByteArray(
            bytes,
            0,
            bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sampleSize },
        ) ?: return null
        if (bitmap.allocationByteCount > MAX_PACKAGE_ICON_MEMORY_CACHE_BYTES) {
            bitmap.recycle()
            return null
        }
        return bitmap
    }

    private fun thumbnailDiskDirectory() =
        File(getApplication<Application>().cacheDir, "file-thumbnails-v1")

    private fun thumbnailDiskFile(key: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(key.encodeToByteArray())
        val name = digest.joinToString("") { "%02x".format(it) }
        return File(thumbnailDiskDirectory(), "$name.bin")
    }

    private fun canDecodeThumbnail(bytes: ByteArray): Boolean =
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let { bitmap ->
            bitmap.recycle()
            true
        } ?: false

    private fun pruneThumbnailDiskCache() {
        val files = thumbnailDiskDirectory().listFiles()
            ?.filter { it.isFile && it.extension == "bin" }
            .orEmpty()
        var total = files.sumOf(File::length)
        files.sortedBy(File::lastModified).forEach { file ->
            if (total <= MAX_THUMBNAIL_DISK_CACHE_BYTES) return
            val length = file.length()
            if (file.delete()) total -= length
        }
    }

    private fun fileStationMutation(
        target: FileStationMutationTarget,
        refresh: FileStationMutationRefresh,
        messageResource: (MutationResult) -> Int,
        messageText: ((MutationResult) -> String)? = null,
        applyResult: (WorkspaceState, MutationResult) -> WorkspaceState = { current, _ -> current },
        verifyOnRefresh: Boolean = true,
        block: suspend (DsmRepository) -> MutationResult,
    ): Boolean {
        val claim = synchronized(fileStationMutationLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            val state = current.fileStationMutationState
            val interactionMatches = when {
                state.confirmationRequested -> state.draftTarget == target
                state.editorVisible -> when (target.operation) {
                    FileStationMutationOperation.CREATE_FOLDER ->
                        state.editorParentBaseline == target.parentBaseline &&
                            state.nameDraft.trim() == target.requestedName
                    FileStationMutationOperation.RENAME ->
                        state.editorSourceBaseline == target.sourceBaselines.singleOrNull() &&
                            state.nameDraft.trim() == target.requestedName
                    FileStationMutationOperation.COPY,
                    FileStationMutationOperation.MOVE,
                    -> state.draftTarget?.sourceBaselines == target.sourceBaselines
                    else -> false
                }
                else -> state.draftTarget == null || state.draftTarget == target
            }
            if (repository !== repo || current.profile.id != target.profileId ||
                current.selectedModule != target.module || current.isPerformingAction ||
                !interactionMatches ||
                state.target != null || state.mutationInProgress || state.mutationRefreshInProgress ||
                state.mutationResult != null || state.mutationFailure != null
            ) return@synchronized null
            val generation = fileStationMutationGeneration.incrementAndGet()
            fileBrowserRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                fileStationMutationState = state.copy(
                    draftTarget = target,
                    target = target,
                    editorVisible = false,
                    nameDraft = target.requestedName.orEmpty(),
                    confirmationRequested = false,
                    mutationInProgress = true,
                    mutationResult = null,
                    createdShareLink = null,
                    mutationFailure = null,
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = false,
                    mutationRefreshCompleted = false,
                    mutationGeneration = generation,
                ),
            )
            FileStationMutationClaim(
                repo,
                current.profile.id,
                target,
                generation,
                verifyOnRefresh,
            )
        } ?: return false
        viewModelScope.launch {
            try {
                val result = block(claim.repository)
                val accepted = synchronized(fileStationMutationLock) {
                    val current = _workspace.value ?: return@synchronized false
                    val state = current.fileStationMutationState
                    if (!fileStationMutationCallbackMatches(
                            repositoryMatches = repository === claim.repository,
                            profileMatches = current.profile.id == claim.profileId,
                            stateTarget = state.target,
                            callbackTarget = claim.target,
                            stateGeneration = state.mutationGeneration,
                            callbackGeneration = claim.generation,
                            globalGeneration = fileStationMutationGeneration.get(),
                        )
                    ) return@synchronized false
                    val updated = applyResult(current, result)
                    _workspace.value = updated.copy(
                        isPerformingAction = false,
                        message = messageText?.invoke(result)
                            ?: getApplication<Application>().getString(messageResource(result)),
                        fileStationMutationState = updated.fileStationMutationState.copy(
                            target = claim.target,
                            mutationInProgress = false,
                            mutationResult = result,
                            mutationFailure = null,
                        ),
                    )
                    true
                }
                if (accepted && (result.submitted || result.requiresRefresh)) {
                    refreshFileStationMutation(claim, refresh)
                }
            } catch (error: CancellationException) {
                synchronized(fileStationMutationLock) {
                    val current = _workspace.value
                    val state = current?.fileStationMutationState
                    if (current != null && state != null && fileStationMutationCallbackMatches(
                            repositoryMatches = repository === claim.repository,
                            profileMatches = current.profile.id == claim.profileId,
                            stateTarget = state.target,
                            callbackTarget = claim.target,
                            stateGeneration = state.mutationGeneration,
                            callbackGeneration = claim.generation,
                            globalGeneration = fileStationMutationGeneration.get(),
                        )
                    ) {
                        _workspace.value = current.copy(
                            isPerformingAction = false,
                            fileStationMutationState = state.copy(
                                mutationInProgress = false,
                                mutationResult = cancelledFileStationMutationResult(
                                    claim.target.operation,
                                ),
                            ),
                        )
                    }
                }
                throw error
            } catch (error: Throwable) {
                synchronized(fileStationMutationLock) {
                    val current = _workspace.value
                    val state = current?.fileStationMutationState
                    if (current != null && state != null && fileStationMutationCallbackMatches(
                            repositoryMatches = repository === claim.repository,
                            profileMatches = current.profile.id == claim.profileId,
                            stateTarget = state.target,
                            callbackTarget = claim.target,
                            stateGeneration = state.mutationGeneration,
                            callbackGeneration = claim.generation,
                            globalGeneration = fileStationMutationGeneration.get(),
                        )
                    ) {
                        _workspace.value = current.copy(
                            isPerformingAction = false,
                            fileStationMutationState = state.copy(
                                mutationInProgress = false,
                                mutationFailure = error.asDsmFailure(),
                            ),
                        )
                    }
                }
            }
        }
        return true
    }

    private suspend fun refreshFileStationMutation(
        claim: FileStationMutationClaim,
        refresh: FileStationMutationRefresh,
    ) {
        val started = synchronized(fileStationMutationLock) {
            val current = _workspace.value ?: return@synchronized false
            val state = current.fileStationMutationState
            if (!fileStationMutationCallbackMatches(
                    repositoryMatches = repository === claim.repository,
                    profileMatches = current.profile.id == claim.profileId,
                    stateTarget = state.target,
                    callbackTarget = claim.target,
                    stateGeneration = state.mutationGeneration,
                    callbackGeneration = claim.generation,
                    globalGeneration = fileStationMutationGeneration.get(),
                )
            ) return@synchronized false
            _workspace.value = current.copy(
                fileStationMutationState = state.copy(
                    mutationRefreshInProgress = true,
                    mutationRefreshFailure = null,
                ),
            )
            true
        }
        if (!started) return
        val outcome = runCatching {
            when (refresh) {
                FileStationMutationRefresh.FILE_BROWSER -> {
                    loadFileBrowser(claim.repository)
                    check(_workspace.value?.files is Loadable.Ready) { "file_station.refresh_failed" }
                }
                FileStationMutationRefresh.PHOTOS -> {
                    loadPhotoPage(claim.repository, reset = true)
                    check(_workspace.value?.photos is Loadable.Ready) { "file_station.photo-refresh-failed" }
                }
                FileStationMutationRefresh.FAVORITES -> {
                    val paths = claim.repository.listFavorites().mapTo(mutableSetOf()) { it.path }
                    _workspace.update { current ->
                        current?.copy(
                            favoritePaths = paths,
                            files = current.files.withFavoritePaths(paths),
                        )
                    }
                }
                FileStationMutationRefresh.SHARE_LINKS -> {
                    val links = claim.repository.listShareLinks()
                    _workspace.update { it?.copy(fileShareLinks = Loadable.Ready(links)) }
                }
                FileStationMutationRefresh.TEXT_PREVIEW -> Unit
            }
            if (!claim.verifyOnRefresh) {
                FileStationMutationVerification.MATCHES to null
            } else if (claim.target.operation == FileStationMutationOperation.TEXT_SAVE) {
                verifyTextPreviewSave(claim.repository, claim.target)
            } else {
                verifyFileStationMutation(claim.repository, claim.target) to null
            }
        }
        synchronized(fileStationMutationLock) {
            val current = _workspace.value ?: return@synchronized
            val state = current.fileStationMutationState
            if (!fileStationMutationCallbackMatches(
                    repositoryMatches = repository === claim.repository,
                    profileMatches = current.profile.id == claim.profileId,
                    stateTarget = state.target,
                    callbackTarget = claim.target,
                    stateGeneration = state.mutationGeneration,
                    callbackGeneration = claim.generation,
                    globalGeneration = fileStationMutationGeneration.get(),
                )
            ) return@synchronized
            val verified = outcome.getOrNull()
            val verification = verified?.first ?: FileStationMutationVerification.UNAVAILABLE
            val refreshedText = verified?.second
            _workspace.value = current.copy(
                previewItem = refreshedText?.item ?: current.previewItem,
                preview = refreshedText?.let { Loadable.Ready(it) } ?: current.preview,
                textPreviewDraft = if (
                    verification == FileStationMutationVerification.MATCHES && refreshedText != null
                ) null else current.textPreviewDraft,
                fileStationMutationState = state.copy(
                    mutationRefreshInProgress = false,
                    mutationRefreshCompleted = outcome.isSuccess,
                    mutationRefreshFailure = outcome.exceptionOrNull()?.asDsmFailure(),
                    mutationVerification = verification,
                ),
            )
        }
    }

    private suspend fun verifyTextPreviewSave(
        repo: DsmRepository,
        target: FileStationMutationTarget,
    ): Pair<FileStationMutationVerification, FilePreviewContent.Text?> {
        val source = target.sourceBaselines.single()
        val current = repo.fileInfo(source.path)
            ?: return FileStationMutationVerification.DISAPPEARED to null
        if (current.isDirectory || current.previewKind() != FilePreviewKind.TEXT) {
            return FileStationMutationVerification.DIFFERS to null
        }
        val (value, truncated) = repo.readTextPreview(current)
        val content = FilePreviewContent.Text(current, value, truncated)
        val bytes = value.encodeToByteArray()
        val matches = !truncated && bytes.size.toLong() == target.expectedContentByteCount &&
            sha256Hex(bytes) == target.expectedContentSha256
        return (if (matches) FileStationMutationVerification.MATCHES
        else FileStationMutationVerification.DIFFERS) to content
    }

    private suspend fun verifyFileStationMutation(
        repo: DsmRepository,
        target: FileStationMutationTarget,
    ): FileStationMutationVerification {
        val current = _workspace.value ?: return FileStationMutationVerification.UNAVAILABLE
        return verifyFileStationMutationOutcome(
            target = target,
            fileInfo = repo::fileInfo,
            favoritePaths = current.favoritePaths,
            shareLinks = (current.fileShareLinks as? Loadable.Ready)?.value,
            createdShareLink = current.fileStationMutationState.createdShareLink,
        )
    }

    private fun createShareLinkMutation(item: FileItem): Boolean {
        val current = _workspace.value ?: return false
        val target = FileStationMutationTarget(
            profileId = current.profile.id,
            module = current.selectedModule,
            operation = FileStationMutationOperation.SHARE_CREATE,
            sourceBaselines = listOf(item),
        )
        var createdLink: FileShareLink? = null
        return fileStationMutation(
            target,
            FileStationMutationRefresh.SHARE_LINKS,
            ::shareLinkMutationMessageResource,
            applyResult = { workspace, result ->
                if (result.status == MutationResultStatus.CONFIRMED_SUCCESS) {
                    createdLink?.let { link ->
                        val application = getApplication<Application>()
                        val clipboard = application.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(
                            ClipData.newPlainText(
                                application.getString(R.string.share_link_clip_label),
                                link.url,
                            ),
                        )
                    }
                }
                workspace
                    .copy(
                        fileStationMutationState = workspace.fileStationMutationState.copy(
                            createdShareLink = createdLink,
                        ),
                    )
            },
        ) { repo ->
            repo.createShareLinkResult(item).also { createdLink = it.link }.result
        }
    }

    private fun launchDownloadCreation(
        target: DownloadCreationTarget,
        editableDraft: Pair<String, String>?,
        block: suspend (DsmRepository) -> MutationResult,
    ): Boolean {
        val repo = repository ?: return false
        val generation = synchronized(downloadCreationMutationLock) {
            val current = _workspace.value ?: return false
            if (
                repository !== repo || current.profile.id != target.profileId ||
                current.selectedModule != Module.DOWNLOADS || current.downloadControlState.target != null ||
                current.downloadSettingsState.editorVisible ||
                current.downloadDestinationEditState != DownloadDestinationEditWorkspaceState() ||
                !canStartDownloadCreation(current.isPerformingAction, current.downloadCreationState)
            ) return false
            val nextGeneration = downloadCreationMutationGeneration.incrementAndGet()
            downloadListRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                downloadCreationState = current.downloadCreationState.copy(
                    editorVisible = false,
                    uriDraft = "",
                    destinationDraft = "",
                    pendingDiscoveryTitle = null,
                    pendingDiscoveryUri = null,
                    pendingDiscoverySource = null,
                    target = target,
                    mutationInProgress = true,
                    mutationResult = null,
                    mutationFailure = null,
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = false,
                    mutationRefreshCompleted = false,
                    mutationGeneration = nextGeneration,
                ),
            )
            nextGeneration
        }
        viewModelScope.launch {
            val outcome = runCatching { block(repo) }
            val result = outcome.getOrNull()
            val failure = outcome.exceptionOrNull()?.takeUnless { it is CancellationException }
                ?.asDsmFailure()
            val cancelled = outcome.exceptionOrNull() is CancellationException
            val persistentResult = result ?: if (cancelled) {
                cancelledDownloadCreationResult(target)
            } else {
                null
            }
            val needsRefresh = failure != null || persistentResult?.let {
                it.submitted || it.requiresRefresh || it.counts.unknown > 0
            } == true
            val refreshOutcome = if (needsRefresh) {
                runCatching { repo.activeDownloadTasksForMutation() }
            } else {
                null
            }
            synchronized(downloadCreationMutationLock) {
                val current = _workspace.value ?: return@synchronized
                val creation = current.downloadCreationState
                if (!downloadCreationCallbackMatches(
                        repositoryMatches = repository === repo,
                        profileMatches = current.profile.id == target.profileId,
                        stateTarget = creation.target,
                        callbackTarget = target,
                        stateGeneration = creation.mutationGeneration,
                        callbackGeneration = generation,
                        globalGeneration = downloadCreationMutationGeneration.get(),
                    )
                ) return@synchronized
                val refreshed = refreshOutcome?.getOrNull()
                val refreshFailure = refreshOutcome?.exceptionOrNull()
                    ?.takeUnless { it is CancellationException }
                    ?.asDsmFailure()
                _workspace.value = current.withDownloads(
                    refreshed?.let { Loadable.Ready(it) } ?: current.downloads,
                ).copy(
                    isPerformingAction = false,
                    downloadCreationState = creation.copy(
                        uriDraft = editableDraft?.first.takeIf {
                            persistentResult?.submitted == false
                        }.orEmpty(),
                        destinationDraft = editableDraft?.second.takeIf {
                            persistentResult?.submitted == false
                        }.orEmpty(),
                        mutationInProgress = false,
                        mutationResult = persistentResult,
                        mutationFailure = failure,
                        mutationRefreshFailure = refreshFailure,
                        mutationRefreshInProgress = false,
                        mutationRefreshCompleted = needsRefresh && refreshed != null,
                    ),
                )
            }
        }
        return true
    }

    fun refreshDownloadCreationMutation() {
        val repo = repository ?: return
        val target: DownloadCreationTarget
        val generation: Long
        synchronized(downloadCreationMutationLock) {
            val current = _workspace.value ?: return
            val creation = current.downloadCreationState
            if (
                repository !== repo || current.isPerformingAction || creation.target == null ||
                creation.mutationInProgress || creation.mutationRefreshInProgress ||
                creation.mutationResult == null && creation.mutationFailure == null
            ) return
            target = creation.target
            generation = downloadCreationMutationGeneration.incrementAndGet()
            downloadListRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                downloadCreationState = creation.copy(
                    mutationRefreshInProgress = true,
                    mutationRefreshFailure = null,
                    mutationRefreshCompleted = false,
                    mutationGeneration = generation,
                ),
            )
        }
        viewModelScope.launch {
            val refresh = runCatching { repo.activeDownloadTasksForMutation() }
            synchronized(downloadCreationMutationLock) {
                val current = _workspace.value ?: return@synchronized
                val creation = current.downloadCreationState
                if (!downloadCreationCallbackMatches(
                        repositoryMatches = repository === repo,
                        profileMatches = current.profile.id == target.profileId,
                        stateTarget = creation.target,
                        callbackTarget = target,
                        stateGeneration = creation.mutationGeneration,
                        callbackGeneration = generation,
                        globalGeneration = downloadCreationMutationGeneration.get(),
                    )
                ) return@synchronized
                val refreshed = refresh.getOrNull()
                _workspace.value = current.withDownloads(
                    refreshed?.let { Loadable.Ready(it) } ?: current.downloads,
                ).copy(
                    isPerformingAction = false,
                    downloadCreationState = creation.copy(
                        mutationRefreshInProgress = false,
                        mutationRefreshFailure = refresh.exceptionOrNull()
                            ?.takeUnless { it is CancellationException }
                            ?.asDsmFailure(),
                        mutationRefreshCompleted = refreshed != null,
                    ),
                )
            }
        }
    }

    fun dismissDownloadCreationMutation(): Boolean = synchronized(downloadCreationMutationLock) {
        val current = _workspace.value ?: return false
        if (!canDismissDownloadCreationMutation(current.downloadCreationState)) return false
        downloadCreationMutationGeneration.incrementAndGet()
        _workspace.value = current.copy(downloadCreationState = DownloadCreationWorkspaceState())
        true
    }

    fun editDownloadCreationAfterResult(): Boolean = synchronized(downloadCreationMutationLock) {
        val current = _workspace.value ?: return false
        val creation = current.downloadCreationState
        if (
            !canDismissDownloadCreationMutation(creation) || creation.mutationResult?.submitted != false ||
            creation.target?.sourceKind !in setOf(
                DownloadCreationSourceKind.LINK,
                DownloadCreationSourceKind.MAGNET,
            )
        ) {
            return false
        }
        downloadCreationMutationGeneration.incrementAndGet()
        _workspace.value = current.copy(
            downloadCreationState = DownloadCreationWorkspaceState(
                editorVisible = true,
                uriDraft = creation.uriDraft,
                destinationDraft = creation.destinationDraft,
            ),
        )
        true
    }

    private fun containerMutation(
        @StringRes success: Int,
        block: suspend (DsmRepository) -> MutationResult,
    ) {
        if (!containerWriteActionsEnabled()) {
            _workspace.update {
                it?.copy(
                    isPerformingAction = false,
                    message = getApplication<Application>().getString(
                        R.string.container_management_read_only,
                    ),
                )
            }
            return
        }
        val repo = repository ?: return
        if (_workspace.value?.isPerformingAction == true) return
        viewModelScope.launch {
            _workspace.update { it?.copy(isPerformingAction = true, message = null) }
            runCatching { block(repo) }
                .onSuccess { result ->
                    val refreshed = if (result.submitted || result.requiresRefresh) {
                        runCatching { repo.containerOverview() }.getOrNull()
                    } else {
                        null
                    }
                    _workspace.update { current ->
                        current?.copy(
                            containers = refreshed?.let { Loadable.Ready(it) } ?: current.containers,
                            isPerformingAction = false,
                            message = serviceMutationResultMessage(result, success),
                        )
                    }
                }
                .onFailure { error ->
                    _workspace.update {
                        it?.copy(
                            isPerformingAction = false,
                            message = error.asDsmFailure()
                                .localize(getApplication<Application>())
                                .combined,
                        )
                    }
                }
        }
    }

    private fun virtualMachineMutation(
        target: VirtualMachineMutationTarget,
        @StringRes success: Int,
        creationDraft: VirtualMachineCreationDraftState? = null,
        imageImportDraft: VirtualMachineImageImportDraftState? = null,
        settingsTargetId: String? = null,
        settingsBaseline: VirtualMachineSettings? = null,
        settingsDraft: VirtualMachineSettingsDraftState? = null,
        lifecycleTarget: VirtualMachineLifecycleTarget? = null,
        taskCleanupBaseline: List<VirtualMachineTask> = emptyList(),
        block: suspend (DsmRepository, Long) -> MutationResult,
    ): Boolean {
        val claim = synchronized(virtualMachineMutationLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            val state = current.virtualMachineMutationState
            val editorMatches = when (target.kind) {
                VirtualMachineMutationKind.CREATION ->
                    !state.imageImportEditorVisible && !state.settingsEditorVisible &&
                        !state.lifecycleConfirmationRequested &&
                        !state.taskCleanupConfirmationRequested
                VirtualMachineMutationKind.IMAGE_IMPORT ->
                    !state.creationEditorVisible && !state.settingsEditorVisible &&
                        !state.lifecycleConfirmationRequested &&
                        !state.taskCleanupConfirmationRequested && state.imageImportEditorVisible
                VirtualMachineMutationKind.TASK_CLEANUP ->
                    !state.creationEditorVisible && !state.imageImportEditorVisible &&
                        !state.settingsEditorVisible && !state.lifecycleConfirmationRequested &&
                        state.taskCleanupConfirmationRequested &&
                        state.taskCleanupBaseline == taskCleanupBaseline
                VirtualMachineMutationKind.SETTINGS ->
                    !state.creationEditorVisible && !state.imageImportEditorVisible &&
                        !state.lifecycleConfirmationRequested &&
                        !state.taskCleanupConfirmationRequested
                VirtualMachineMutationKind.LIFECYCLE ->
                    !state.creationEditorVisible && !state.imageImportEditorVisible &&
                        !state.settingsEditorVisible &&
                        !state.taskCleanupConfirmationRequested &&
                        (!state.lifecycleConfirmationRequested ||
                            state.lifecycleConfirmationTarget == lifecycleTarget)
            }
            if (repository !== repo || current.profile.id != target.profileId ||
                current.selectedModule != Module.VIRTUAL_MACHINES ||
                !editorMatches ||
                !canStartVirtualMachineMutation(
                    current.isPerformingAction,
                    state,
                )
            ) return@synchronized null
            val generation = virtualMachineMutationGeneration.incrementAndGet()
            virtualMachineOverviewRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                message = null,
                virtualMachineMutationState = VirtualMachineMutationWorkspaceState(
                    selectedTab = state.selectedTab,
                    supportsOfficialTasks = state.supportsOfficialTasks,
                    creationEditorVisible = state.creationEditorVisible,
                    target = target,
                    creationDraft = creationDraft,
                    imageImportEditorVisible = state.imageImportEditorVisible,
                    imageImportDraft = imageImportDraft,
                    settingsEditorVisible = state.settingsEditorVisible,
                    settingsTargetId = settingsTargetId,
                    settingsBaseline = settingsBaseline,
                    settingsDraft = settingsDraft,
                    lifecycleConfirmationTarget = lifecycleTarget,
                    lifecycleConfirmationRequested = false,
                    taskCleanupConfirmationRequested = false,
                    taskCleanupBaseline = taskCleanupBaseline,
                    taskCleanupResolvedResult = null,
                    mutationInProgress = true,
                    mutationGeneration = generation,
                ),
            )
            VirtualMachineMutationClaim(repo, current.profile.id, target, generation)
        } ?: return false
        viewModelScope.launch {
            try {
                val result = block(claim.repository, claim.generation)
                val accepted = synchronized(virtualMachineMutationLock) {
                    val current = _workspace.value ?: return@synchronized false
                    if (!virtualMachineMutationCallbackMatches(
                            repositoryMatches = repository === claim.repository,
                            profileMatches = current.profile.id == claim.profileId,
                            stateTarget = current.virtualMachineMutationState.target,
                            callbackTarget = claim.target,
                            stateGeneration = current.virtualMachineMutationState.mutationGeneration,
                            callbackGeneration = claim.generation,
                            globalGeneration = virtualMachineMutationGeneration.get(),
                        )
                    ) return@synchronized false
                    _workspace.value = current.copy(
                        isPerformingAction = false,
                        message = serviceMutationResultMessage(result, success),
                        virtualMachineMutationState = current.virtualMachineMutationState.copy(
                            mutationInProgress = false,
                            mutationResult = result,
                            mutationFailure = null,
                        ),
                    )
                    true
                }
                if (accepted && (result.submitted || result.requiresRefresh)) {
                    refreshVirtualMachineMutation()
                }
            } catch (error: CancellationException) {
                val cancellationResult = finishVirtualMachineMutationCancellation(claim)
                if (cancellationResult?.let { it.submitted || it.requiresRefresh } == true) {
                    refreshVirtualMachineMutation()
                }
                throw error
            } catch (error: Throwable) {
                finishVirtualMachineMutationFailure(claim, error.asDsmFailure())
            }
        }
        return true
    }

    private fun finishVirtualMachineMutationCancellation(
        claim: VirtualMachineMutationClaim,
    ): MutationResult? = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return null
        if (!virtualMachineMutationCallbackMatches(
                repositoryMatches = repository === claim.repository,
                profileMatches = current.profile.id == claim.profileId,
                stateTarget = current.virtualMachineMutationState.target,
                callbackTarget = claim.target,
                stateGeneration = current.virtualMachineMutationState.mutationGeneration,
                callbackGeneration = claim.generation,
                globalGeneration = virtualMachineMutationGeneration.get(),
            )
        ) return null
        val state = current.virtualMachineMutationState
        val result = cancelledVirtualMachineMutationResult(
            claim.target,
            state.taskCleanupResolvedResult,
        )
        _workspace.value = current.copy(
            isPerformingAction = false,
            virtualMachineMutationState = state.copy(
                mutationInProgress = false,
                mutationResult = result,
                mutationFailure = null,
            ),
        )
        result
    }

    private fun finishVirtualMachineMutationFailure(
        claim: VirtualMachineMutationClaim,
        failure: DsmFailure,
    ) {
        synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return
            if (!virtualMachineMutationCallbackMatches(
                    repositoryMatches = repository === claim.repository,
                    profileMatches = current.profile.id == claim.profileId,
                    stateTarget = current.virtualMachineMutationState.target,
                    callbackTarget = claim.target,
                    stateGeneration = current.virtualMachineMutationState.mutationGeneration,
                    callbackGeneration = claim.generation,
                    globalGeneration = virtualMachineMutationGeneration.get(),
                )
            ) return
            _workspace.value = current.copy(
                isPerformingAction = false,
                message = failure.localize(getApplication<Application>()).combined,
                virtualMachineMutationState = current.virtualMachineMutationState.copy(
                    mutationInProgress = false,
                    mutationFailure = failure,
                ),
            )
        }
    }

    fun refreshVirtualMachineMutation(): Boolean {
        val claim = synchronized(virtualMachineMutationLock) {
            val repo = repository ?: return@synchronized null
            val current = _workspace.value ?: return@synchronized null
            val state = current.virtualMachineMutationState
            val target = state.target ?: return@synchronized null
            if (repository !== repo || current.profile.id != target.profileId ||
                state.mutationInProgress || state.mutationRefreshInProgress ||
                state.mutationResult == null && state.mutationFailure == null
            ) return@synchronized null
            val generation = virtualMachineMutationGeneration.incrementAndGet()
            virtualMachineOverviewRequestGeneration.incrementAndGet()
            _workspace.value = current.copy(
                isPerformingAction = true,
                virtualMachineMutationState = state.copy(
                    mutationRefreshFailure = null,
                    mutationRefreshInProgress = true,
                    mutationRefreshCompleted = false,
                    mutationVerification = null,
                    mutationGeneration = generation,
                ),
            )
            VirtualMachineMutationClaim(repo, current.profile.id, target, generation)
        } ?: return false
        viewModelScope.launch {
            try {
                val imageImportVerification = if (claim.target.kind == VirtualMachineMutationKind.IMAGE_IMPORT) {
                    val importState = _workspace.value?.virtualMachineMutationState
                    val importTarget = importState?.imageImportDraft?.toImportOrNull()
                    val taskId = importState?.imageImportTaskId
                    if (taskId != null && importTarget != null) {
                        claim.repository.verifyVirtualMachineImageImportTask(
                            taskId,
                            importTarget.imageName,
                            importTarget.imageType,
                            onTaskCleared = { clearedTaskId ->
                                synchronized(virtualMachineMutationLock) {
                                    val current = _workspace.value ?: return@synchronized
                                    val state = current.virtualMachineMutationState
                                    if (virtualMachineMutationCallbackMatches(
                                            repositoryMatches = repository === claim.repository,
                                            profileMatches = current.profile.id == claim.profileId,
                                            stateTarget = state.target,
                                            callbackTarget = claim.target,
                                            stateGeneration = state.mutationGeneration,
                                            callbackGeneration = claim.generation,
                                            globalGeneration = virtualMachineMutationGeneration.get(),
                                        ) && state.imageImportTaskId == clearedTaskId
                                    ) {
                                        _workspace.value = current.copy(
                                            virtualMachineMutationState = state.copy(
                                                imageImportTaskId = null,
                                            ),
                                        )
                                    }
                                }
                            },
                        )
                    } else null
                } else null
                if (imageImportVerification == VirtualMachineImageImportVerification.PENDING) {
                    synchronized(virtualMachineMutationLock) {
                        val current = _workspace.value ?: return@synchronized
                        if (!virtualMachineMutationCallbackMatches(
                                repositoryMatches = repository === claim.repository,
                                profileMatches = current.profile.id == claim.profileId,
                                stateTarget = current.virtualMachineMutationState.target,
                                callbackTarget = claim.target,
                                stateGeneration = current.virtualMachineMutationState.mutationGeneration,
                                callbackGeneration = claim.generation,
                                globalGeneration = virtualMachineMutationGeneration.get(),
                            )
                        ) return@synchronized
                        _workspace.value = current.copy(
                            isPerformingAction = false,
                            virtualMachineMutationState = current.virtualMachineMutationState.copy(
                                mutationRefreshFailure = null,
                                mutationRefreshInProgress = false,
                                mutationRefreshCompleted = false,
                                mutationVerification = null,
                            ),
                        )
                    }
                    return@launch
                }
                val refreshed = claim.repository.virtualMachineOverview()
                synchronized(virtualMachineMutationLock) {
                    val current = _workspace.value ?: return@synchronized
                    if (!virtualMachineMutationCallbackMatches(
                            repositoryMatches = repository === claim.repository,
                            profileMatches = current.profile.id == claim.profileId,
                            stateTarget = current.virtualMachineMutationState.target,
                            callbackTarget = claim.target,
                            stateGeneration = current.virtualMachineMutationState.mutationGeneration,
                            callbackGeneration = claim.generation,
                            globalGeneration = virtualMachineMutationGeneration.get(),
                        )
                    ) return@synchronized
                    _workspace.value = current.copy(
                        virtualMachines = Loadable.Ready(refreshed),
                        isPerformingAction = false,
                        virtualMachineMutationState = current.virtualMachineMutationState.copy(
                            mutationRefreshFailure = null,
                            mutationRefreshInProgress = false,
                            mutationRefreshCompleted = true,
                            mutationVerification = when (imageImportVerification) {
                                VirtualMachineImageImportVerification.MATCHES ->
                                    VirtualMachineMutationVerification.MATCHES
                                VirtualMachineImageImportVerification.DIFFERS ->
                                    VirtualMachineMutationVerification.DIFFERS
                                VirtualMachineImageImportVerification.PENDING -> null
                                null -> virtualMachineMutationVerification(
                                    current.virtualMachineMutationState,
                                    refreshed,
                                )
                            },
                            imageImportTaskId = current.virtualMachineMutationState.imageImportTaskId
                                ?.takeUnless {
                                    imageImportVerification ==
                                        VirtualMachineImageImportVerification.MATCHES
                                },
                        ),
                    )
                }
            } catch (error: CancellationException) {
                finishVirtualMachineMutationRefreshFailure(claim, null)
                throw error
            } catch (error: Throwable) {
                finishVirtualMachineMutationRefreshFailure(claim, error.asDsmFailure())
            }
        }
        return true
    }

    private fun finishVirtualMachineMutationRefreshFailure(
        claim: VirtualMachineMutationClaim,
        failure: DsmFailure?,
    ) {
        synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return
            if (!virtualMachineMutationCallbackMatches(
                    repositoryMatches = repository === claim.repository,
                    profileMatches = current.profile.id == claim.profileId,
                    stateTarget = current.virtualMachineMutationState.target,
                    callbackTarget = claim.target,
                    stateGeneration = current.virtualMachineMutationState.mutationGeneration,
                    callbackGeneration = claim.generation,
                    globalGeneration = virtualMachineMutationGeneration.get(),
                )
            ) return
            _workspace.value = current.copy(
                isPerformingAction = false,
                virtualMachineMutationState = current.virtualMachineMutationState.copy(
                    mutationRefreshFailure = failure,
                    mutationRefreshInProgress = false,
                    mutationRefreshCompleted = false,
                    mutationVerification = null,
                ),
            )
        }
    }

    fun dismissVirtualMachineMutation(): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        if (!canDismissVirtualMachineMutation(current.virtualMachineMutationState)) return false
        virtualMachineMutationGeneration.incrementAndGet()
        _workspace.value = current.copy(
            virtualMachineMutationState = VirtualMachineMutationWorkspaceState(
                selectedTab = current.virtualMachineMutationState.selectedTab,
                supportsOfficialTasks = current.virtualMachineMutationState.supportsOfficialTasks,
            ),
        )
        true
    }

    fun continueEditingVirtualMachineMutation(): Boolean = synchronized(virtualMachineMutationLock) {
        val current = _workspace.value ?: return false
        val state = current.virtualMachineMutationState
        if (!canContinueEditingVirtualMachineMutation(state)) return false
        val generation = virtualMachineMutationGeneration.incrementAndGet()
        _workspace.value = current.copy(
            isPerformingAction = false,
            message = null,
            virtualMachineMutationState = state.copy(
                lifecycleConfirmationTarget = null,
                lifecycleConfirmationRequested = false,
                target = null,
                mutationInProgress = false,
                mutationResult = null,
                mutationFailure = null,
                mutationRefreshFailure = null,
                mutationRefreshInProgress = false,
                mutationRefreshCompleted = false,
                mutationVerification = null,
                imageImportTaskId = null,
                mutationGeneration = generation,
            ),
        )
        true
    }

    private fun serviceMutationResultMessage(
        result: MutationResult,
        @StringRes success: Int,
    ): String {
        val context = getApplication<Application>()
        return context.getString(serviceMutationMessageResource(result, success))
    }

    private fun favoriteResultMessage(result: MutationResult): String {
        val removing = result.operation == "favoriteRemove"
        val resource = when {
            result.status == MutationResultStatus.CONFIRMED_SUCCESS -> if (removing) {
                R.string.favorite_removed
            } else {
                R.string.favorite_added
            }
            result.errorCategory == MutationErrorCategory.CONFLICT -> R.string.favorite_add_in_progress
            result.status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED ||
                result.status == MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION ->
                R.string.favorite_add_unverified
            result.status == MutationResultStatus.PERMISSION_DENIED -> R.string.favorite_add_permission_denied
            result.status == MutationResultStatus.UNSUPPORTED -> R.string.favorite_add_unsupported
            result.status == MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.favorite_add_cancelled
            else -> R.string.favorite_add_failed
        }
        return getApplication<Application>().getString(resource)
    }

    private fun fileDeleteResultMessage(result: MutationResult): String {
        val application = getApplication<Application>()
        return when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> application.getString(
                R.string.file_delete_confirmed,
                result.counts.succeeded,
            )
            MutationResultStatus.PARTIAL_SUCCESS -> application.getString(
                R.string.file_delete_partial,
                result.counts.succeeded,
                result.counts.failed + result.counts.unknown,
            )
            else -> application.getString(fileDeleteMutationMessageResource(result))
        }
    }

    private fun fileCopyMoveResultMessage(result: MutationResult): String {
        val application = getApplication<Application>()
        return when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> application.getString(
                if (result.operation == "fileCopy") R.string.files_copied else R.string.files_moved,
                result.counts.succeeded,
            )
            MutationResultStatus.PARTIAL_SUCCESS -> application.getString(
                R.string.file_copy_move_partial,
                result.counts.succeeded,
                result.counts.failed + result.counts.unknown,
            )
            else -> application.getString(fileCopyMoveMessageResource(result))
        }
    }

    private fun downloadMutationResultMessage(result: MutationResult): String {
        val application = getApplication<Application>()
        return when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> application.getString(
                when (result.operation) {
                    "downloadPause" -> R.string.download_pause_confirmed
                    "downloadResume" -> R.string.download_resume_confirmed
                    else -> R.string.download_delete_confirmed
                },
                result.counts.succeeded,
            )
            MutationResultStatus.PARTIAL_SUCCESS -> application.getString(
                R.string.download_action_partial,
                result.counts.succeeded,
                result.counts.failed + result.counts.unknown,
            )
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> application.getString(R.string.download_action_unverified)
            MutationResultStatus.PERMISSION_DENIED ->
                application.getString(R.string.download_action_permission_denied)
            MutationResultStatus.UNSUPPORTED ->
                application.getString(R.string.download_action_unsupported)
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION ->
                application.getString(R.string.download_action_cancelled)
            MutationResultStatus.CONFIRMED_FAILURE -> if (
                result.errorCategory == MutationErrorCategory.CONFLICT
            ) {
                application.getString(R.string.download_action_conflict)
            } else {
                application.getString(R.string.download_action_failed)
            }
        }
    }

    private suspend fun resolveUploadSource(uri: Uri): UploadSource = withContext(Dispatchers.IO) {
        val resolver = getApplication<Application>().contentResolver
        var displayName: String? = null
        var size: Long? = null
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        displayName = cursor.getString(nameIndex)
                    }
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex).takeIf { it >= 0 }
                    }
                }
            }
        if (size == null) {
            size = resolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.length.takeIf { it >= 0 }
            }
        }
        val safeName = displayName?.trim()?.takeIf {
            it.isNotEmpty() && '/' !in it && '\\' !in it
        } ?: throw DsmFailure(
            null,
            "The selected file name is unavailable",
            "Choose a regular file and try again.",
            kind = DsmErrorKind.UPLOAD_FAILED,
        )
        val contentLength = size ?: throw DsmFailure(
            null,
            "The selected file size is unavailable",
            "Choose a file whose size can be read and try again.",
            kind = DsmErrorKind.UPLOAD_LENGTH_MISMATCH,
        )
        UploadSource(
            displayName = safeName,
            contentType = resolver.getType(uri),
            contentLength = contentLength,
            openInputStream = {
                resolver.openInputStream(uri) ?: throw DsmFailure(
                    null,
                    "The selected file can no longer be opened",
                    "Choose the file again.",
                    kind = DsmErrorKind.UPLOAD_FAILED,
                )
            },
        )
    }

    private suspend fun loadPreview(repo: DsmRepository, item: FileItem): FilePreviewContent =
        when (item.previewKind()) {
            FilePreviewKind.TEXT -> {
                val (text, truncated) = repo.readTextPreview(item)
                FilePreviewContent.Text(item, text, truncated)
            }
            FilePreviewKind.VIDEO,
            FilePreviewKind.AUDIO,
            -> if (item.size > 0) {
                val source = repo.streamingMediaSource(item)
                if (item.previewKind() == FilePreviewKind.VIDEO) {
                    FilePreviewContent.Video(item = item, mediaSource = source)
                } else {
                    FilePreviewContent.Audio(item = item, mediaSource = source)
                }
            } else {
                val extension = item.extension.take(8).takeIf { it.isNotBlank() } ?: "bin"
                val file = File(
                    getApplication<Application>().cacheDir,
                    "preview/preview-${UUID.randomUUID()}.$extension",
                )
                withTemporaryFileOwnership(file) { ownedFile ->
                    repo.downloadPreview(item, ownedFile)
                    if (item.previewKind() == FilePreviewKind.VIDEO) {
                        FilePreviewContent.Video(
                            item = item,
                            localFile = ownedFile,
                            mediaDetails = videoDetails(ownedFile),
                        )
                    } else {
                        FilePreviewContent.Audio(
                            item = item,
                            localFile = ownedFile,
                            mediaDetails = videoDetails(ownedFile),
                        )
                    }
                }
            }
            FilePreviewKind.IMAGE,
            FilePreviewKind.PDF,
            -> {
                val extension = item.extension.take(8).takeIf { it.isNotBlank() } ?: "bin"
                val file = File(
                    getApplication<Application>().cacheDir,
                    "preview/preview-${UUID.randomUUID()}.$extension",
                )
                withTemporaryFileOwnership(file) { ownedFile ->
                    repo.downloadPreview(item, ownedFile)
                    when (item.previewKind()) {
                        FilePreviewKind.IMAGE ->
                            FilePreviewContent.Image(item, ownedFile, imageDetails(ownedFile))
                        FilePreviewKind.PDF -> FilePreviewContent.Pdf(item, ownedFile)
                        else -> error("Unexpected preview kind")
                    }
                }
            }
            FilePreviewKind.UNSUPPORTED -> throw DsmFailure(
                null,
                "This file type cannot be previewed",
                "Download it to open it in another app.",
                kind = DsmErrorKind.FEATURE_UNSUPPORTED,
            )
        }

    @Suppress("DEPRECATION")
    private fun imageDetails(file: File): MediaDetails? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val exif = runCatching { ExifInterface(file.path) }.getOrNull()
        val capturedAt = exif?.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)?.let { value ->
            runCatching {
                SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US).parse(value)?.time
            }.getOrNull()
        }
        val camera = listOfNotNull(
            exif?.getAttribute(ExifInterface.TAG_MAKE)?.trim()?.takeIf(String::isNotBlank),
            exif?.getAttribute(ExifInterface.TAG_MODEL)?.trim()?.takeIf(String::isNotBlank),
        ).distinct().joinToString(" ").takeIf(String::isNotBlank)
        val (orientedWidth, orientedHeight) = imageDimensionsAfterExifOrientation(
            width = bounds.outWidth,
            height = bounds.outHeight,
            orientation = exif?.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            ) ?: ExifInterface.ORIENTATION_NORMAL,
        )
        MediaDetails(
            width = orientedWidth.takeIf { it > 0 },
            height = orientedHeight.takeIf { it > 0 },
            capturedAtEpochMillis = capturedAt,
            camera = camera,
        )
    }.getOrNull()

    private fun videoDetails(file: File): MediaDetails? = runCatching {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.path)
            var width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
            var height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()
            if (rotation == 90 || rotation == 270) {
                width = height.also { height = width }
            }
            MediaDetails(
                width = width,
                height = height,
                durationMillis = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull(),
            )
        } finally {
            retriever.release()
        }
    }.getOrNull()

    private fun cleanupPreviewFile(preview: Loadable<FilePreviewContent>?) {
        val content = (preview as? Loadable.Ready)?.value
        when (content) {
            is FilePreviewContent.Image -> runCatching { content.localFile.delete() }
            is FilePreviewContent.Pdf -> runCatching { content.localFile.delete() }
            is FilePreviewContent.Video -> {
                runCatching { content.mediaSource?.close() }
                runCatching { content.localFile?.delete() }
            }
            is FilePreviewContent.Audio -> {
                runCatching { content.mediaSource?.close() }
                runCatching { content.localFile?.delete() }
            }
            else -> Unit
        }
    }

    private fun clearPreviewCaches(preserveActiveThumbnails: Boolean = false) {
        previewJob?.cancel()
        previewJob = null
        if (preserveActiveThumbnails) {
            inactiveThumbnailKeys(thumbnailCache.snapshot().keys, thumbnailReferences)
                .forEach(thumbnailCache::remove)
        } else {
            thumbnailJobs.values.forEach(Job::cancel)
            thumbnailJobs.clear()
            thumbnailReferences.clear()
            thumbnailCache.evictAll()
        }
        cleanupPreviewFile(_workspace.value?.preview)
        File(getApplication<Application>().cacheDir, "preview")
            .listFiles()
            ?.forEach(File::delete)
        File(getApplication<Application>().cacheDir, "chat-preview")
            .listFiles()
            ?.forEach(File::delete)
    }

    private fun enqueueBackgroundDownload(
        record: PersistedDownload,
        existingWorkPolicy: ExistingWorkPolicy = transferEnqueuePolicy(TransferEnqueueReason.INITIAL),
        requireExactResume: Boolean = false,
    ): Boolean {
        val request = backgroundDownloadRequest(record.id, requireExactResume)
        val scheduled = runCatching {
            transferStore.updateDownloadDurably(record.id) { current ->
                current.takeIf { it.canReplaceBackgroundDownloadWorkId(record) }
                    ?.copy(workId = request.id.toString())
            }
        }.getOrNull()
        if (scheduled == null) {
            markBackgroundDownloadStateUnavailable(record, request.id.toString())
            return false
        }
        enqueuePersistedBackgroundDownload(scheduled, request, existingWorkPolicy)
        return true
    }

    private fun markBackgroundDownloadStateUnavailable(
        expected: PersistedDownload,
        attemptedWorkId: String,
    ) {
        var markedFailed = false
        val failed = transferStore.update(expected.id) { current ->
            if (
                current.canReplaceBackgroundDownloadWorkId(expected) ||
                current.canReplaceBackgroundDownloadWorkId(expected.copy(workId = attemptedWorkId))
            ) {
                markedFailed = true
                current.copy(
                    state = TransferState.FAILED,
                    workId = null,
                    errorKind = DsmErrorKind.DOWNLOAD_FAILED.name,
                )
            } else {
                current
            }
        }
        if (markedFailed && failed != null) {
            syncPersistedDownloads(failed.profileId)
            _workspace.update { current ->
                current?.takeIf { it.profile.id == failed.profileId }?.copy(
                    message = getApplication<Application>().getString(R.string.download_state_unavailable),
                ) ?: current
            }
        }
    }

    private fun backgroundDownloadRequest(
        taskId: String,
        requireExactResume: Boolean,
    ): OneTimeWorkRequest =
        OneTimeWorkRequestBuilder<FileDownloadWorker>()
            .setInputData(
                workDataOf(
                    FileDownloadWorker.KEY_TASK_ID to taskId,
                    FileDownloadWorker.KEY_REQUIRE_EXACT_RESUME to requireExactResume,
                ),
            )
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .addTag(FileDownloadWorker.UNIQUE_WORK_PREFIX + taskId)
            .build()

    private fun enqueuePersistedBackgroundDownload(
        record: PersistedDownload,
        request: OneTimeWorkRequest,
        existingWorkPolicy: ExistingWorkPolicy,
    ) {
        workManager.enqueueUniqueWork(
            FileDownloadWorker.UNIQUE_WORK_PREFIX + record.id,
            existingWorkPolicy,
            request,
        )
        monitorDownload(record.id, request.id)
        syncPersistedDownloads(record.profileId)
    }

    private fun enqueuePhotoBackup(record: PersistedUpload) {
        val request = OneTimeWorkRequestBuilder<PhotoBackupWorker>()
            .setInputData(workDataOf(PhotoBackupWorker.KEY_TASK_ID to record.id))
            .setConstraints(photoBackupConstraints())
            .addTag(PhotoBackupWorker.UNIQUE_WORK_PREFIX + record.id)
            .build()
        transferStore.updateUpload(record.id) { it.copy(workId = request.id.toString()) }
        workManager.enqueueUniqueWork(
            PhotoBackupWorker.UNIQUE_WORK_PREFIX + record.id,
            ExistingWorkPolicy.KEEP,
            request,
        )
        monitorUpload(record.id, request.id)
    }

    private fun enqueuePersistedFileUpload(
        record: PersistedUpload,
        existingWorkPolicy: ExistingWorkPolicy = transferEnqueuePolicy(TransferEnqueueReason.INITIAL),
    ) {
        val request = OneTimeWorkRequestBuilder<PhotoBackupWorker>()
            .setInputData(workDataOf(PhotoBackupWorker.KEY_TASK_ID to record.id))
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .addTag(PhotoBackupWorker.FILE_UPLOAD_UNIQUE_WORK_PREFIX + record.id)
            .build()
        transferStore.updateUpload(record.id) { it.copy(workId = request.id.toString()) }
        workManager.enqueueUniqueWork(
            PhotoBackupWorker.FILE_UPLOAD_UNIQUE_WORK_PREFIX + record.id,
            existingWorkPolicy,
            request,
        )
        monitorUpload(record.id, request.id)
        syncPersistedDownloads(record.profileId)
    }

    private fun schedulePhotoBackupSource(source: PersistedPhotoBackupSource): Boolean {
        if (!shouldScanPhotoBackupSource(source)) return true
        val profileId = source.profileId
        val periodicWorkName = PhotoBackupScanWorker.UNIQUE_WORK_PREFIX + profileId
        val input = workDataOf(PhotoBackupScanWorker.KEY_PROFILE_ID to profileId)
        val periodic = PeriodicWorkRequestBuilder<PhotoBackupScanWorker>(6, TimeUnit.HOURS)
            .setInputData(input)
            .setConstraints(photoBackupConstraints())
            .addTag(periodicWorkName)
            .build()
        val initial = OneTimeWorkRequestBuilder<PhotoBackupScanWorker>()
            .setInputData(input)
            .setConstraints(photoBackupConstraints())
            .build()
        if (
            runCatching {
                transferStore.upsertPhotoBackupSource(
                    source.copy(
                        workId = null,
                        enabled = true,
                        needsAttention = false,
                    ),
                )
            }.isFailure
        ) {
            return false
        }
        cancelPhotoBackupScanObservation(profileId)
        val scheduleGeneration = ++photoBackupScanScheduleGeneration
        val periodicOperation = workManager.enqueueUniquePeriodicWork(
            periodicWorkName,
            ExistingPeriodicWorkPolicy.UPDATE,
            periodic,
        )
        val initialOperation = workManager.enqueueUniqueWork(
            PhotoBackupScanWorker.UNIQUE_WORK_PREFIX + profileId + "-initial",
            ExistingWorkPolicy.REPLACE,
            initial,
        )
        viewModelScope.launch {
            val actualPeriodicWorkId = withContext(Dispatchers.IO) {
                runCatching {
                    periodicOperation.result.get()
                    initialOperation.result.get()
                    resolvedPhotoBackupPeriodicWorkId(
                        workManager.getWorkInfosForUniqueWork(periodicWorkName)
                            .get()
                            .filterNot { it.state.isFinished }
                            .map(WorkInfo::id),
                    )
                }.getOrNull()
            }
            if (!isCurrentPhotoBackupSourceSchedule(source, scheduleGeneration)) {
                reconcilePhotoBackupSourceScheduleAttention(source)
                return@launch
            }
            if (actualPeriodicWorkId == null) {
                cancelPhotoBackupSourceWork(profileId)
                _workspace.update { current ->
                    current?.takeIf { it.profile.id == profileId }?.copy(
                        message = getApplication<Application>().getString(
                            R.string.photo_backup_source_state_unavailable,
                        ),
                    ) ?: current
                }
                return@launch
            }
            val current = transferStore.photoBackupSource(profileId)?.takeIf {
                it.treeUri == source.treeUri &&
                    it.destinationPath == source.destinationPath &&
                    shouldScanPhotoBackupSource(it) &&
                    it.workId == null
            } ?: run {
                reconcilePhotoBackupSourceScheduleAttention(source)
                return@launch
            }
            val scheduledSource = current.copy(workId = actualPeriodicWorkId.toString())
            if (runCatching { transferStore.upsertPhotoBackupSource(scheduledSource) }.isFailure) {
                cancelPhotoBackupSourceWork(profileId)
                _workspace.update { workspace ->
                    workspace?.takeIf { it.profile.id == profileId }?.copy(
                        message = getApplication<Application>().getString(
                            R.string.photo_backup_source_state_unavailable,
                        ),
                    ) ?: workspace
                }
                return@launch
            }
            observePhotoBackupSourceScans(scheduledSource, actualPeriodicWorkId, initial.id)
        }
        return true
    }

    private fun isCurrentPhotoBackupSourceSchedule(
        expected: PersistedPhotoBackupSource,
        generation: Long,
    ): Boolean =
        photoBackupScanScheduleGeneration == generation &&
            transferStore.photoBackupSource(expected.profileId)?.let { current ->
                current.treeUri == expected.treeUri &&
                    current.destinationPath == expected.destinationPath &&
                    shouldScanPhotoBackupSource(current) &&
                    current.workId == null
            } == true

    private fun reconcilePhotoBackupSourceScheduleAttention(expected: PersistedPhotoBackupSource) {
        if (
            !isPhotoBackupSourceAttentionFor(
                current = transferStore.photoBackupSource(expected.profileId),
                expectedProfileId = expected.profileId,
                expectedTreeUri = expected.treeUri,
                expectedDestinationPath = expected.destinationPath,
            )
        ) {
            return
        }
        cancelPhotoBackupSourceWork(expected.profileId)
        _workspace.update { current ->
            current?.takeIf { it.profile.id == expected.profileId }?.copy(
                photoBackupSourceEnabled = false,
                message = getApplication<Application>().getString(
                    R.string.photo_backup_folder_too_large,
                ),
            ) ?: current
        }
    }

    private fun observePhotoBackupSourceScans(
        source: PersistedPhotoBackupSource,
        periodicWorkId: UUID,
        initialWorkId: UUID,
    ) {
        photoBackupScanWatchJob?.cancel()
        val generation = ++photoBackupScanWatchGeneration
        val profileId = source.profileId
        photoBackupScanWatchProfileId = profileId
        val job = viewModelScope.launch {
            launch {
                observePhotoBackupSourceScan(
                    source = source,
                    periodicWorkId = periodicWorkId.toString(),
                    observedWorkId = periodicWorkId,
                    generation = generation,
                )
            }
            launch {
                observePhotoBackupSourceScan(
                    source = source,
                    periodicWorkId = periodicWorkId.toString(),
                    observedWorkId = initialWorkId,
                    generation = generation,
                )
            }
        }
        photoBackupScanWatchJob = job
        job.invokeOnCompletion {
            if (photoBackupScanWatchGeneration == generation) {
                photoBackupScanWatchJob = null
                photoBackupScanWatchProfileId = null
            }
        }
    }

    private suspend fun observePhotoBackupSourceScan(
        source: PersistedPhotoBackupSource,
        periodicWorkId: String,
        observedWorkId: UUID,
        generation: Long,
    ) {
        workManager.getWorkInfoByIdFlow(observedWorkId).collectLatest { info ->
            val workInfo = info ?: return@collectLatest
            val decision = photoBackupScanFailureDecision(
                observationIsCurrent = photoBackupScanWatchGeneration == generation &&
                    photoBackupScanWatchProfileId == source.profileId,
                workspaceProfileId = _workspace.value?.profile?.id,
                currentSource = transferStore.photoBackupSource(source.profileId),
                expectedProfileId = source.profileId,
                expectedTreeUri = source.treeUri,
                expectedDestinationPath = source.destinationPath,
                expectedPeriodicWorkId = periodicWorkId,
                expectedObservedWorkId = observedWorkId.toString(),
                observedWorkId = workInfo.id.toString(),
                workState = workInfo.state,
                scanOutcome = workInfo.outputData.getString(PhotoBackupScanWorker.KEY_SCAN_OUTCOME),
            )
            when (decision) {
                PhotoBackupScanFailureDecision.DISABLE_SOURCE -> {
                    _workspace.update { current ->
                        current?.takeIf { it.profile.id == source.profileId }?.copy(
                            photoBackupSourceEnabled = false,
                            message = getApplication<Application>().getString(
                                R.string.photo_backup_folder_too_large,
                            ),
                        ) ?: current
                    }
                    cancelPhotoBackupSourceWork(source.profileId)
                }

                PhotoBackupScanFailureDecision.SHOW_SOURCE_STATE_UNAVAILABLE -> {
                    _workspace.update { current ->
                        current?.takeIf { it.profile.id == source.profileId }?.copy(
                            message = getApplication<Application>().getString(
                                R.string.photo_backup_source_state_unavailable,
                            ),
                        ) ?: current
                    }
                    cancelPhotoBackupScanObservation(source.profileId, generation)
                }

                PhotoBackupScanFailureDecision.IGNORE -> Unit
            }
            if (workInfo.state.isFinished) {
                currentCoroutineContext()[Job]?.cancel()
            }
        }
    }

    private fun cancelPhotoBackupSourceWork(profileId: String) {
        cancelPhotoBackupScanObservation(profileId)
        workManager.cancelUniqueWork(PhotoBackupScanWorker.UNIQUE_WORK_PREFIX + profileId)
        workManager.cancelUniqueWork(PhotoBackupScanWorker.UNIQUE_WORK_PREFIX + profileId + "-initial")
    }

    private fun cancelPhotoBackupScanObservation(profileId: String, generation: Long? = null) {
        if (
            photoBackupScanWatchProfileId != profileId ||
            (generation != null && photoBackupScanWatchGeneration != generation)
        ) {
            return
        }
        photoBackupScanWatchGeneration += 1
        photoBackupScanWatchJob?.cancel()
        photoBackupScanWatchJob = null
        photoBackupScanWatchProfileId = null
    }

    private fun photoBackupSourceRestoreMessage(source: PersistedPhotoBackupSource?): String? =
        if (source?.needsAttention == true) {
            getApplication<Application>().getString(R.string.photo_backup_folder_too_large)
        } else {
            null
        }

    private fun enqueueForegroundDownload(
        repo: DsmRepository,
        record: PersistedDownload,
        destination: Uri,
        requireExactResume: Boolean = false,
    ) {
        val executionId = UUID.randomUUID().toString()
        fun ownsExecution(): Boolean =
            foregroundDownloadExecutionIds[record.id].isCurrentDownloadExecution(executionId)
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            val running = transferStore.update(record.id) { current ->
                if (!ownsExecution() || current.state == TransferState.PAUSED) {
                    current
                } else {
                    current.copy(
                        state = TransferState.RUNNING,
                        startedAtEpochMillis = System.currentTimeMillis(),
                    )
                }
            }
            syncPersistedDownloads(record.profileId)
            if (!ownsExecution() || running?.state != TransferState.RUNNING) {
                return@launch
            }
            try {
                val descriptor = getApplication<Application>().contentResolver
                    .openFileDescriptor(destination, "rw")
                    ?: throw java.io.IOException("The destination could not be opened")
                descriptor.use { parcel ->
                    FileOutputStream(parcel.fileDescriptor).use { stream ->
                        val requestedResume = if (!record.isDirectory) record.completedBytes else 0L
                        val resumeFrom = runCatching {
                            if (requestedResume > 0 && stream.channel.size() == requestedResume) {
                                stream.channel.position(requestedResume)
                                requestedResume
                            } else if (requireExactResume && requestedResume > 0) {
                                throw java.io.IOException(
                                    "The saved partial download does not match its resume offset",
                                )
                            } else {
                                stream.channel.truncate(0)
                                stream.channel.position(0)
                                0L
                            }
                        }.getOrElse {
                            throw java.io.IOException("The destination does not support safe resume", it)
                        }
                        if (resumeFrom == 0L) {
                            transferStore.update(record.id) { current ->
                                if (ownsExecution()) {
                                    current.copy(completedBytes = 0)
                                } else {
                                    current
                                }
                            }
                        }
                    repo.download(record.toDownloadFileItem(), stream, resumeFrom = resumeFrom) { completed, total ->
                        transferStore.update(record.id) { current ->
                            if (ownsExecution()) {
                                current.copy(
                                    completedBytes = completed,
                                    totalBytes = total ?: current.expectedBytes,
                                )
                            } else {
                                current
                            }
                        }
                        syncPersistedDownloads(record.profileId)
                    }
                    }
                }
                val completed = transferStore.update(record.id) { current ->
                    if (!ownsExecution() || current.state != TransferState.RUNNING) {
                        current
                    } else {
                        current.copy(
                            state = TransferState.SUCCEEDED,
                            completedBytes = current.totalBytes ?: current.completedBytes,
                            errorKind = null,
                        )
                    }
                }
                if (ownsExecution() && completed?.state == TransferState.SUCCEEDED) {
                    releasePersistedDownloadPermission(destination)
                    TransferNotifications.completion(getApplication(), record.id, succeeded = true)
                    _workspace.update {
                        it?.copy(message = getApplication<Application>().getString(R.string.download_completed))
                    }
                }
            } catch (_: CancellationException) {
                val current = transferStore.download(record.id)
                if (current != null && shouldDeleteCancelledDownload(
                        current.state,
                        foregroundDownloadExecutionIds[record.id],
                        executionId,
                    )
                ) {
                    deleteIncompleteDownload(destination)
                    releasePersistedDownloadPermission(destination)
                    transferStore.update(record.id) { latest ->
                        if (ownsExecution() && latest.state != TransferState.PAUSED) {
                            latest.copy(state = TransferState.CANCELLED)
                        } else {
                            latest
                        }
                    }
                }
            } catch (error: Throwable) {
                val kind = downloadFailureKind(error)
                val failed = transferStore.update(record.id) { current ->
                    if (!ownsExecution() || current.state != TransferState.RUNNING) {
                        current
                    } else {
                        current.copy(state = TransferState.FAILED, errorKind = kind.name)
                    }
                }
                if (ownsExecution() && failed?.state == TransferState.FAILED) {
                    if (shouldDeleteFailedForegroundDownload(failed, ownsExecution = true)) {
                        deleteIncompleteDownload(destination)
                        releasePersistedDownloadPermission(destination)
                    }
                    TransferNotifications.completion(getApplication(), record.id, succeeded = false)
                }
            } finally {
                syncPersistedDownloads(record.profileId)
            }
        }
        foregroundDownloadExecutionIds[record.id] = executionId
        transferJobs[record.id] = job
        job.invokeOnCompletion {
            var finalizedCancellation = false
            val cancelled = transferStore.update(record.id) { current ->
                val next = current.finalizeForegroundDownloadCancellation(
                    ownsExecution = foregroundDownloadExecutionIds[record.id]
                        .isCurrentDownloadExecution(executionId),
                )
                finalizedCancellation = current.state == TransferState.CANCELLING &&
                    next.state == TransferState.CANCELLED
                next
            }
            if (finalizedCancellation &&
                cancelled?.state == TransferState.CANCELLED &&
                cancelled.workId == null
            ) {
                val destination = Uri.parse(cancelled.destinationUri)
                deleteIncompleteDownload(destination)
                releasePersistedDownloadPermission(destination)
                syncPersistedDownloads(cancelled.profileId)
            }
            transferJobs.remove(record.id, job)
            foregroundDownloadExecutionIds.remove(record.id, executionId)
        }
        job.start()
    }

    private fun restoreDownloads(profileId: String) {
        transferWatchJobs.values.forEach(Job::cancel)
        transferWatchJobs.clear()
        transferStore.downloads(profileId).forEach { record ->
            val workId = record.workId?.let { value ->
                runCatching { UUID.fromString(value) }.getOrNull()
            }
            if (record.state == TransferState.PAUSED) {
                Unit
            } else if (workId != null && record.state !in TERMINAL_TRANSFER_STATES) {
                restorePersistedBackgroundDownload(profileId, record, workId)
            } else if (workId == null && record.state !in TERMINAL_TRANSFER_STATES) {
                val destination = Uri.parse(record.destinationUri)
                deleteIncompleteDownload(destination)
                releasePersistedDownloadPermission(destination)
                transferStore.update(record.id) {
                    it.copy(state = TransferState.FAILED, errorKind = DsmErrorKind.DOWNLOAD_FAILED.name)
                }
            }
        }
        transferStore.uploads(profileId).forEach { record ->
            val workId = record.workId?.let { value ->
                runCatching { UUID.fromString(value) }.getOrNull()
            }
            if (workId != null && record.state !in TERMINAL_TRANSFER_STATES) {
                monitorUpload(record.id, workId)
            } else if (workId == null && record.state !in TERMINAL_TRANSFER_STATES) {
                transferStore.updateUpload(record.id) {
                    it.copy(state = TransferState.FAILED, errorKind = DsmErrorKind.UPLOAD_FAILED.name)
                }
            }
        }
        transferStore.servers(profileId).forEach { record ->
            if (record.state in TERMINAL_TRANSFER_STATES) return@forEach
            val target = record.toFileServerMutationTarget()
            when {
                target == null -> transferStore.removeInvalidServer(record.id)
                record.submissionPhase == PersistedServerSubmissionPhase.PREPARING ->
                    transferStore.updateServer(record.id) {
                        val result = interruptedServerMutationResult(
                            target.operation,
                            submitted = false,
                            expectedCount = target.expectedOutputs.size,
                        )
                        it.copy(
                            state = TransferState.FAILED,
                            submissionPhase = PersistedServerSubmissionPhase.TERMINAL,
                            requiresRefresh = false,
                            errorKind = null,
                            mutationResult = result.toPersistedMutationResult(writeSubmitted = false),
                        )
                    }
                record.submissionPhase == PersistedServerSubmissionPhase.SUBMITTED &&
                    !record.nasTaskId.isNullOrBlank() && target.expectedOutputs.isNotEmpty() ->
                    resumePersistedServerTransfer(profileId, record, target)
                else -> transferStore.updateServer(record.id) {
                    val result = interruptedServerMutationResult(
                        target.operation,
                        submitted = true,
                        expectedCount = target.expectedOutputs.size,
                    )
                    it.copy(
                        state = TransferState.FAILED,
                        submissionPhase = PersistedServerSubmissionPhase.TERMINAL,
                        requiresRefresh = true,
                        errorKind = DsmErrorKind.CHANGE_NOT_CONFIRMED.name,
                        mutationResult = result.toPersistedMutationResult(writeSubmitted = true),
                    )
                }
            }
        }
        syncPersistedDownloads(profileId)
    }

    private fun restorePersistedBackgroundDownload(
        profileId: String,
        record: PersistedDownload,
        workId: UUID,
    ) {
        val expectedWorkId = workId.toString()
        viewModelScope.launch {
            val lookup = withContext(Dispatchers.IO) {
                runCatching {
                    if (workManager.getWorkInfoById(workId).get() == null) {
                        RestoredBackgroundWorkLookup.MISSING
                    } else {
                        RestoredBackgroundWorkLookup.PRESENT
                    }
                }.getOrDefault(RestoredBackgroundWorkLookup.QUERY_FAILED)
            }
            val current = transferStore.download(record.id)
            when (
                restoredBackgroundDownloadDecision(
                    lookup = lookup,
                    current = current,
                    expectedRecordId = record.id,
                    expectedProfileId = profileId,
                    expectedWorkId = expectedWorkId,
                )
            ) {
                RestoredBackgroundDownloadDecision.MONITOR -> monitorDownload(record.id, workId)
                RestoredBackgroundDownloadDecision.REENQUEUE -> enqueueBackgroundDownload(
                    record = checkNotNull(current),
                    existingWorkPolicy = ExistingWorkPolicy.REPLACE,
                )
                RestoredBackgroundDownloadDecision.FINALIZE_CANCELLATION ->
                    finalizeMissingBackgroundDownloadCancellation(
                        record = checkNotNull(current),
                        expectedWorkId = expectedWorkId,
                    )
                RestoredBackgroundDownloadDecision.IGNORE -> Unit
            }
        }
    }

    private fun finalizeMissingBackgroundDownloadCancellation(
        record: PersistedDownload,
        expectedWorkId: String,
    ) {
        var finalized = false
        val cancelled = transferStore.update(record.id) { current ->
            if (
                current.id == record.id &&
                current.profileId == record.profileId &&
                current.workId == expectedWorkId &&
                current.state == TransferState.CANCELLING
            ) {
                finalized = true
                current.copy(
                    state = TransferState.CANCELLED,
                    workId = null,
                    errorKind = null,
                )
            } else {
                current
            }
        }
        if (finalized && cancelled?.state == TransferState.CANCELLED) {
            val destination = Uri.parse(cancelled.destinationUri)
            deleteIncompleteDownload(destination)
            releasePersistedDownloadPermission(destination)
            syncPersistedDownloads(cancelled.profileId)
        }
    }

    private fun resumePersistedServerTransfer(
        profileId: String,
        record: PersistedServerTransfer,
        target: FileServerMutationTarget,
    ) {
        val repo = repository ?: return
        val taskId = record.nasTaskId ?: return
        val generation = fileServerMutationGeneration.incrementAndGet()
        transferStore.updateServer(record.id) {
            it.copy(
                executionGeneration = generation,
                readOnlyObservation = true,
                state = TransferState.RUNNING,
            )
        }
        val job = viewModelScope.launch {
            try {
                val result = repo.resumeArchiveMutationResult(
                    operation = target.operation,
                    taskId = taskId,
                    expectedOutputs = target.expectedOutputs,
                ) { completed, total ->
                    updatePersistedServerRecord(repo, profileId, record.id, generation) {
                        it.copy(completedUnits = completed, totalUnits = total)
                    }
                }
                updatePersistedServerRecord(repo, profileId, record.id, generation) {
                    val completed = result.status == MutationResultStatus.CONFIRMED_SUCCESS
                    val cancelled = result.status in setOf(
                        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    )
                    it.copy(
                        state = when {
                            completed -> TransferState.SUCCEEDED
                            cancelled -> TransferState.CANCELLED
                            else -> TransferState.FAILED
                        },
                        submissionPhase = PersistedServerSubmissionPhase.TERMINAL,
                        requiresRefresh = result.requiresRefresh,
                        errorKind = if (completed || cancelled) null else DsmErrorKind.CHANGE_NOT_CONFIRMED.name,
                        mutationResult = result.toPersistedMutationResult(writeSubmitted = true),
                    )
                }
            } catch (error: CancellationException) {
                updatePersistedServerRecord(repo, profileId, record.id, generation) {
                    val result = interruptedServerMutationResult(
                        target.operation,
                        submitted = true,
                        expectedCount = target.expectedOutputs.size,
                    )
                    it.copy(
                        state = TransferState.FAILED,
                        submissionPhase = PersistedServerSubmissionPhase.TERMINAL,
                        requiresRefresh = true,
                        errorKind = DsmErrorKind.CHANGE_NOT_CONFIRMED.name,
                        mutationResult = result.toPersistedMutationResult(writeSubmitted = true),
                    )
                }
                throw error
            } catch (error: Throwable) {
                val failure = error.asDsmFailure()
                updatePersistedServerRecord(repo, profileId, record.id, generation) {
                    val result = interruptedServerMutationResult(
                        target.operation,
                        submitted = true,
                        expectedCount = target.expectedOutputs.size,
                    )
                    it.copy(
                        state = TransferState.FAILED,
                        submissionPhase = PersistedServerSubmissionPhase.TERMINAL,
                        requiresRefresh = true,
                        errorKind = failure.kind.name,
                        mutationResult = result.toPersistedMutationResult(writeSubmitted = true),
                    )
                }
            }
        }
        transferJobs[record.id] = job
        job.invokeOnCompletion { transferJobs.remove(record.id, job) }
    }

    private fun updatePersistedServerRecord(
        repo: DsmRepository,
        profileId: String,
        taskId: String,
        generation: Long,
        transform: (PersistedServerTransfer) -> PersistedServerTransfer,
    ): PersistedServerTransfer? {
        if (repository !== repo) return null
        val current = transferStore.server(taskId) ?: return null
        if (current.profileId != profileId || current.executionGeneration != generation) return null
        return transferStore.updateServer(taskId) { active ->
            if (active.profileId == profileId && active.executionGeneration == generation) {
                transform(active)
            } else {
                active
            }
        }?.also { syncPersistedDownloads(profileId) }
    }

    fun refreshVirtualMachineLocalImageImports(): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        syncVirtualMachineLocalImageImports(profileId)
        transferStore.virtualMachineImageImports(profileId).forEach { record ->
            val workId = record.workId?.let { value ->
                runCatching { UUID.fromString(value) }.getOrNull()
            }
            if (workId != null) monitorVirtualMachineImageImport(record.id, workId)
        }
        return true
    }

    fun retryVirtualMachineLocalImageImport(id: String): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val record = transferStore.virtualMachineImageImport(id)?.takeIf {
            it.profileId == profileId &&
                it.stage == PersistedVirtualMachineImageImportStage.PREPARING &&
                it.workId == null
        } ?: return false
        val workId = VirtualMachineImageImportWorker.enqueue(getApplication(), record.id) ?: return false
        syncVirtualMachineLocalImageImports(profileId)
        monitorVirtualMachineImageImport(record.id, workId)
        return true
    }

    fun removeVirtualMachineLocalImageImport(id: String): Boolean {
        val profileId = _workspace.value?.profile?.id ?: return false
        val record = transferStore.virtualMachineImageImport(id)?.takeIf {
            it.profileId == profileId && it.stage == PersistedVirtualMachineImageImportStage.SUCCEEDED
        } ?: return false
        if (!transferStore.removeVirtualMachineImageImport(record.id)) return false
        virtualMachineImageImportWatchJobs.remove(record.id)?.cancel()
        syncVirtualMachineLocalImageImports(profileId)
        return true
    }

    private fun syncVirtualMachineLocalImageImports(profileId: String) {
        if (_workspace.value?.profile?.id != profileId) return
        _virtualMachineLocalImageImports.value = transferStore.virtualMachineImageImports(profileId)
            .map(PersistedVirtualMachineImageImport::toVirtualMachineLocalImageImportUiState)
    }

    private fun monitorVirtualMachineImageImport(recordId: String, workId: UUID) {
        virtualMachineImageImportWatchJobs.remove(recordId)?.cancel()
        virtualMachineImageImportWatchJobs[recordId] = viewModelScope.launch {
            workManager.getWorkInfoByIdFlow(workId).collectLatest { info ->
                val profileId = transferStore.virtualMachineImageImport(recordId)?.profileId
                    ?: return@collectLatest
                syncVirtualMachineLocalImageImports(profileId)
                if (info.state.isFinished) {
                    virtualMachineImageImportWatchJobs.remove(
                        recordId,
                        currentCoroutineContext()[Job],
                    )
                    currentCoroutineContext()[Job]?.cancel()
                }
            }
        }
    }

    private fun releasePendingVirtualMachineLocalImageGrant() {
        pendingVirtualMachineLocalImageUri?.let(::releaseVirtualMachineLocalImageGrant)
        pendingVirtualMachineLocalImageUri = null
        pendingVirtualMachineLocalImageContentType = null
    }

    private fun releaseVirtualMachineLocalImageGrant(uri: Uri) {
        runCatching {
            getApplication<Application>().contentResolver.releasePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
    }

    private fun monitorUpload(taskId: String, workId: UUID) {
        transferWatchJobs.remove(taskId)?.cancel()
        transferWatchJobs[taskId] = viewModelScope.launch {
            workManager.getWorkInfoByIdFlow(workId).collectLatest { info ->
                val completed = info.progress.getLong(PhotoBackupWorker.KEY_COMPLETED_BYTES, 0)
                transferStore.updateUpload(taskId) { current ->
                    current.applyUploadWorkObservation(
                        executionId = workId.toString(),
                        workState = info.state,
                        observedCompletedBytes = completed,
                        observedErrorKind = info.outputData.getString(PhotoBackupWorker.KEY_ERROR_KIND),
                    )
                }?.let { syncPersistedDownloads(it.profileId) }
                if (info.state.isFinished) {
                    transferWatchJobs.remove(taskId, currentCoroutineContext()[Job])
                    currentCoroutineContext()[Job]?.cancel()
                }
            }
        }
    }

    private fun monitorDownload(taskId: String, workId: UUID) {
        transferWatchJobs.remove(taskId)?.cancel()
        transferWatchJobs[taskId] = viewModelScope.launch {
            workManager.getWorkInfoByIdFlow(workId).collectLatest { info ->
                val completed = info.progress.getLong(FileDownloadWorker.KEY_COMPLETED_BYTES, 0)
                val total = info.progress.takeIf {
                    it.getBoolean(FileDownloadWorker.KEY_HAS_TOTAL, false)
                }?.getLong(FileDownloadWorker.KEY_TOTAL_BYTES, 0)
                var deleteCancelledDestination = false
                val updated = transferStore.update(taskId) { current ->
                    val next = current.applyDownloadWorkObservation(
                        executionId = workId.toString(),
                        workState = info.state,
                        observedCompletedBytes = completed,
                        observedTotalBytes = total,
                        observedErrorKind = info.outputData.getString(FileDownloadWorker.KEY_ERROR_KIND),
                    )
                    deleteCancelledDestination = current.state == TransferState.CANCELLING &&
                        next.state == TransferState.CANCELLED &&
                        next.workId == workId.toString()
                    next
                }
                if (deleteCancelledDestination &&
                    updated?.state == TransferState.CANCELLED &&
                    updated.workId == workId.toString()
                ) {
                    val destination = Uri.parse(updated.destinationUri)
                    deleteIncompleteDownload(destination)
                    releasePersistedDownloadPermission(destination)
                }
                updated?.let { syncPersistedDownloads(it.profileId) }
                if (info.state.isFinished) {
                    transferWatchJobs.remove(taskId, currentCoroutineContext()[Job])
                    currentCoroutineContext()[Job]?.cancel()
                }
            }
        }
    }

    private fun syncPersistedDownloads(profileId: String) {
        val downloads = transferStore.downloads(profileId).map(::downloadTransferTask)
        val uploads = transferStore.uploads(profileId).map(::uploadTransferTask)
        val servers = transferStore.servers(profileId)
            .sortedByDescending(PersistedServerTransfer::startedAtEpochMillis)
            .mapNotNull(::serverTransferTask)
        val persistedIds = (downloads + uploads + servers).mapTo(mutableSetOf(), TransferTask::id)
        _workspace.update { current ->
            current?.takeIf { it.profile.id == profileId }?.copy(
                transfers = servers + uploads + downloads +
                    current.transfers.filterNot { it.id in persistedIds },
            ) ?: current
        }
    }

    private fun serverTransferTask(server: PersistedServerTransfer): TransferTask? {
        val target = server.toFileServerMutationTarget() ?: return null
        val application = getApplication<Application>()
        val operationName = when (target.operation) {
            FileServerMutationOperation.COMPRESS -> "archiveCompress"
            FileServerMutationOperation.EXTRACT -> "archiveExtract"
        }
        val result = server.mutationResult?.toMutationResult(operationName)
        val failure = server.errorKind?.let { value ->
            val kind = runCatching { DsmErrorKind.valueOf(value) }.getOrDefault(DsmErrorKind.UNKNOWN)
            DsmFailure(null, "", "", kind = kind)
        }
        val refreshFailure = server.refreshFailureKind?.let { value ->
            val kind = runCatching { DsmErrorKind.valueOf(value) }.getOrDefault(DsmErrorKind.UNKNOWN)
            DsmFailure(null, "", "", kind = kind)
        }
        val detail = when (server.state) {
            TransferState.WAITING, TransferState.RUNNING -> application.getString(
                if (target.operation == FileServerMutationOperation.COMPRESS) {
                    R.string.archive_creating
                } else {
                    R.string.archive_extracting
                },
            )
            TransferState.CANCELLING -> application.getString(R.string.transfer_cancelling)
            TransferState.SUCCEEDED,
            TransferState.FAILED,
            TransferState.CANCELLED,
            -> result?.let { application.getString(archiveMutationMessageResource(it)) }
                ?: application.getString(
                    if (server.requiresRefresh) R.string.transfer_refresh_before_retry
                    else R.string.transfer_failed,
                )
            TransferState.PAUSED -> application.getString(R.string.transfer_waiting)
        }
        return TransferTask(
            id = server.id,
            title = server.title,
            detail = detail,
            direction = TransferDirection.SERVER,
            state = server.state,
            completedBytes = server.completedUnits,
            totalBytes = server.totalUnits,
            errorMessage = failure?.localize(application)?.combined,
            requiresRefresh = server.requiresRefresh,
            startedAtEpochMillis = server.startedAtEpochMillis,
            fileServerMutation = FileServerMutationLifecycle(
                target = target,
                result = result,
                failure = failure,
                refreshCompleted = server.refreshCompleted,
                refreshFailure = refreshFailure,
                verification = server.toFileServerMutationVerification(),
                generation = server.executionGeneration,
            ),
            canCancel = !server.readOnlyObservation,
        )
    }

    private fun uploadTransferTask(upload: PersistedUpload): TransferTask {
        val application = getApplication<Application>()
        val uploadMutation = UploadMutationLifecycle(
            directoryResult = upload.directoryMutationResult?.toMutationResult("backupFolderEnsure"),
            uploadResult = upload.uploadMutationResult?.toMutationResult("fileUpload"),
        ).takeIf { it.directoryResult != null || it.uploadResult != null }
        val hasTerminalMutationFeedback = upload.uploadMutationResult != null ||
            upload.directoryMutationResult?.status?.let {
                it != MutationResultStatus.CONFIRMED_SUCCESS
            } == true
        val detail = when (upload.state) {
            TransferState.WAITING -> application.getString(
                if (upload.backupMode) R.string.transfer_waiting_to_backup else R.string.transfer_waiting,
            )
            TransferState.RUNNING -> application.getString(
                if (upload.backupMode) R.string.transfer_backing_up else R.string.transfer_uploading,
            )
            TransferState.CANCELLING -> application.getString(R.string.transfer_cancelling)
            TransferState.SUCCEEDED -> application.getString(
                if (upload.skippedExisting) R.string.transfer_backup_already_exists
                else R.string.transfer_completed,
            )
            TransferState.FAILED -> application.getString(
                if (upload.backupMode) R.string.transfer_backup_failed else R.string.transfer_failed,
            )
            TransferState.CANCELLED -> application.getString(
                if (upload.requiresRefresh) R.string.transfer_cancelled_refresh
                else R.string.transfer_cancelled,
            )
            TransferState.PAUSED -> application.getString(
                if (upload.backupMode) R.string.transfer_waiting_to_backup else R.string.transfer_waiting,
            )
        }
        val errorMessage = if (hasTerminalMutationFeedback) {
            null
        } else if (upload.requiresRefresh && upload.state == TransferState.FAILED) {
            application.getString(R.string.upload_unverified)
        } else upload.errorKind?.let { name ->
            val kind = runCatching { DsmErrorKind.valueOf(name) }.getOrDefault(DsmErrorKind.UPLOAD_FAILED)
            DsmFailure(null, "", "", kind = kind).localize(application).combined
        }
        return TransferTask(
            id = upload.id,
            title = upload.title,
            detail = detail,
            direction = TransferDirection.UPLOAD,
            state = upload.state,
            completedBytes = upload.completedBytes,
            totalBytes = upload.expectedBytes,
            errorMessage = errorMessage,
            requiresRefresh = upload.requiresRefresh,
            startedAtEpochMillis = upload.startedAtEpochMillis,
            uploadMutation = uploadMutation,
        )
    }

    private fun downloadTransferTask(download: PersistedDownload): TransferTask {
        val application = getApplication<Application>()
        val detail = when (download.state) {
            TransferState.WAITING -> application.getString(R.string.transfer_waiting_to_download)
            TransferState.RUNNING -> application.getString(
                if (download.backgroundCapable) {
                    R.string.transfer_downloading
                } else {
                    R.string.transfer_downloading_keep_open
                },
            )
            TransferState.CANCELLING -> application.getString(R.string.transfer_cancelling)
            TransferState.SUCCEEDED -> application.getString(R.string.transfer_completed)
            TransferState.FAILED -> application.getString(R.string.transfer_download_failed)
            TransferState.CANCELLED -> application.getString(R.string.transfer_download_cancelled)
            TransferState.PAUSED -> application.getString(R.string.transfer_download_paused)
        }
        val errorMessage = download.errorKind?.let { name ->
            val kind = runCatching { DsmErrorKind.valueOf(name) }.getOrDefault(DsmErrorKind.DOWNLOAD_FAILED)
            DsmFailure(null, "", "", kind = kind).localize(application).combined
        }
        return TransferTask(
            id = download.id,
            title = download.title,
            detail = detail,
            direction = TransferDirection.DOWNLOAD,
            state = download.state,
            completedBytes = download.completedBytes,
            totalBytes = download.totalBytes,
            errorMessage = errorMessage,
            startedAtEpochMillis = download.startedAtEpochMillis,
        )
    }

    private fun deleteIncompleteDownload(uri: Uri) {
        runCatching { getApplication<Application>().contentResolver.delete(uri, null, null) }
    }

    private fun releasePersistedReadPermission(uri: Uri) {
        runCatching {
            getApplication<Application>().contentResolver.releasePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
    }

    private fun releasePersistedDownloadPermission(uri: Uri) {
        runCatching {
            getApplication<Application>().contentResolver.releasePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
    }

    private fun updateTransfer(id: String, transform: (TransferTask) -> TransferTask) {
        _workspace.update { current ->
            current?.copy(
                transfers = current.transfers.map { task ->
                    if (task.id == id) transform(task) else task
                },
            )
        }
    }

    private fun restoredWorkspaceUi(
        profileId: String,
        availability: List<ModuleAvailability>,
    ): Pair<Module, FileBrowserState> = restoreWorkspaceUiState(
        saved = store.workspaceUiState(profileId),
        availability = availability,
    )

    private fun restoredPinnedConversationIds(profileId: String): List<String> =
        store.workspaceUiState(profileId)?.chatPinnedConversationIds
            .orEmpty()
            .filter { it.isNotBlank() && it.length <= MAX_CHAT_CONVERSATION_ID_CHARACTERS }
            .distinct()
            .take(MAX_PINNED_CHAT_CONVERSATIONS)

    private fun enqueueServerTransfer(
        title: String,
        target: FileServerMutationTarget,
        block: suspend (
            DsmRepository,
            (Long, Long?) -> Unit,
            () -> Unit,
            (String) -> Unit,
            (List<FileServerMutationExpectedOutput>) -> Unit,
        ) -> FileServerMutationExecution,
    ) {
        val repo = repository ?: return
        val taskId = UUID.randomUUID().toString()
        val application = getApplication<Application>()
        val generation = fileServerMutationGeneration.incrementAndGet()
        val startedAt = System.currentTimeMillis()
        val claim = synchronized(fileStationMutationLock) {
            val current = _workspace.value ?: return
            if (repository !== repo || current.selectedModule != Module.FILES) return
            val persisted = target.toPersistedServerTransfer(
                id = taskId,
                title = title,
                state = TransferState.RUNNING,
                submissionPhase = PersistedServerSubmissionPhase.PREPARING,
                startedAtEpochMillis = startedAt,
            ).copy(executionGeneration = generation)
            if (runCatching { transferStore.upsert(persisted) }.isFailure) {
                _workspace.value = current.copy(
                    message = application.getString(R.string.server_transfer_state_unavailable),
                )
                return
            }
            _workspace.value = current.copy(message = null)
            syncPersistedDownloads(current.profile.id)
            FileServerTransferClaim(
                repo,
                current.profile.id,
                current.selectedModule,
                taskId,
                target,
                generation,
            )
        }
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            try {
                val execution = block(
                    repo,
                    { completed, total ->
                        updateServerTransfer(claim, taskId) {
                            it.copy(completedBytes = completed, totalBytes = total)
                        }
                    },
                    {
                        checkNotNull(updatePersistedServerRecord(repo, claim.profileId, taskId, generation) {
                            it.copy(submissionPhase = PersistedServerSubmissionPhase.SUBMITTING)
                        }) { "transfer.server_state_not_persisted" }
                    },
                    { nasTaskId ->
                        checkNotNull(updatePersistedServerRecord(repo, claim.profileId, taskId, generation) {
                            it.copy(
                                submissionPhase = PersistedServerSubmissionPhase.SUBMITTED,
                                nasTaskId = nasTaskId,
                            )
                        }) { "transfer.server_state_not_persisted" }
                    },
                    { outputs ->
                        checkNotNull(updatePersistedServerRecord(repo, claim.profileId, taskId, generation) {
                            it.copy(
                                expectedOutputs = outputs.map(
                                    FileServerMutationExpectedOutput::toPersistedServerExpectedOutput,
                                ),
                            )
                        }) { "transfer.server_state_not_persisted" }
                    },
                )
                val result = execution.result
                val message = application.getString(archiveMutationMessageResource(result))
                val completed = result.status == MutationResultStatus.CONFIRMED_SUCCESS
                val cancelled = result.status in setOf(
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                )
                if (completed) clearFileSelectionAfterServerMutation(claim)
                updateServerTransfer(claim, taskId) {
                    it.copy(
                        state = when {
                            completed -> TransferState.SUCCEEDED
                            cancelled -> TransferState.CANCELLED
                            else -> TransferState.FAILED
                        },
                        detail = message,
                        errorMessage = message.takeUnless { completed || cancelled },
                        requiresRefresh = result.requiresRefresh,
                        fileServerMutation = it.fileServerMutation?.copy(
                            target = it.fileServerMutation.target.copy(
                                expectedOutputs = execution.expectedOutputs,
                            ),
                            result = result,
                            failure = null,
                        ),
                    )
                }
                updateServerTransferMessage(claim, message)
            } catch (error: CancellationException) {
                val submitted = transferStore.server(taskId)?.submissionPhase !=
                    PersistedServerSubmissionPhase.PREPARING
                val result = if (submitted) {
                    cancelledFileServerMutationResult(target.operation)
                } else {
                    interruptedServerMutationResult(
                        target.operation,
                        submitted = false,
                        expectedCount = target.expectedOutputs.size,
                    ).copy(
                        status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        counts = MutationResultCounts(0, 0, 0),
                        diagnosticTag = "archive.cancelled-before-submission",
                    )
                }
                updateServerTransfer(claim, taskId) {
                    it.copy(
                        state = TransferState.CANCELLED,
                        detail = application.getString(
                            if (submitted) R.string.transfer_cancelled_refresh
                            else R.string.transfer_cancelled,
                        ),
                        requiresRefresh = submitted,
                        fileServerMutation = it.fileServerMutation?.copy(result = result),
                    )
                }
                throw error
            } catch (error: Throwable) {
                val failure = error.asDsmFailure()
                val message = failure.localize(application).combined
                val submitted = transferStore.server(taskId)?.submissionPhase !=
                    PersistedServerSubmissionPhase.PREPARING
                val result = interruptedServerMutationResult(
                    target.operation,
                    submitted = submitted,
                    expectedCount = transferStore.server(taskId)?.expectedOutputs?.size
                        ?: target.expectedOutputs.size,
                )
                updateServerTransfer(claim, taskId) {
                    it.copy(
                        state = TransferState.FAILED,
                        detail = application.getString(R.string.transfer_failed),
                        errorMessage = message,
                        requiresRefresh = submitted,
                        fileServerMutation = it.fileServerMutation?.copy(
                            result = result,
                            failure = failure,
                        ),
                    )
                }
            }
        }
        transferJobs[taskId] = job
        job.invokeOnCompletion { transferJobs.remove(taskId, job) }
        job.start()
    }

    private fun updateServerTransfer(
        claim: FileServerTransferClaim,
        taskId: String,
        transform: (TransferTask) -> TransferTask,
    ) {
        val current = transferStore.server(taskId) ?: return
        val projected = serverTransferTask(current) ?: return
        if (!fileServerMutationCallbackMatches(projected, claim)) return
        val transformed = transform(projected)
        val lifecycle = transformed.fileServerMutation ?: return
        updatePersistedServerRecord(
            claim.repository,
            claim.profileId,
            taskId,
            claim.generation,
        ) { persisted ->
            persisted.copy(
                state = transformed.state,
                submissionPhase = if (transformed.state in TERMINAL_TRANSFER_STATES) {
                    PersistedServerSubmissionPhase.TERMINAL
                } else {
                    persisted.submissionPhase
                },
                completedUnits = transformed.completedBytes,
                totalUnits = transformed.totalBytes,
                requiresRefresh = transformed.requiresRefresh,
                errorKind = lifecycle.failure?.kind?.name,
                expectedOutputs = lifecycle.target.expectedOutputs.map(
                    FileServerMutationExpectedOutput::toPersistedServerExpectedOutput,
                ),
                mutationResult = lifecycle.result?.toPersistedMutationResult(),
                refreshCompleted = lifecycle.refreshCompleted,
                verification = lifecycle.verification?.name,
                refreshFailureKind = lifecycle.refreshFailure?.kind?.name,
            )
        }
    }

    private fun clearFileSelectionAfterServerMutation(claim: FileServerTransferClaim) {
        _workspace.update { current ->
            current?.takeIf {
                repository === claim.repository && it.profile.id == claim.profileId &&
                    it.selectedModule == Module.FILES &&
                    it.fileBrowser.path == claim.target.destinationFolderBaseline.path &&
                    it.transfers.any { task -> fileServerMutationCallbackMatches(task, claim) }
            }?.copy(fileBrowser = current.fileBrowser.clearSelection()) ?: current
        }
    }

    private fun fileServerMutationCallbackMatches(
        task: TransferTask,
        claim: FileServerTransferClaim,
    ): Boolean {
        val lifecycle = task.fileServerMutation ?: return false
        return task.id == claim.taskId &&
            lifecycle.target.copy(expectedOutputs = emptyList()) ==
                claim.target.copy(expectedOutputs = emptyList()) &&
            lifecycle.generation == claim.generation
    }

    private suspend fun verifyFileServerMutation(
        repo: DsmRepository,
        target: FileServerMutationTarget,
    ): FileServerMutationVerification {
        val destination = repo.fileInfo(target.destinationFolderBaseline.path)
            ?: return FileServerMutationVerification.DISAPPEARED
        if (!destination.isDirectory) return FileServerMutationVerification.DIFFERS
        if (target.expectedOutputs.isEmpty()) return FileServerMutationVerification.UNAVAILABLE
        val outputsMatch = target.expectedOutputs.all { expected ->
                repo.fileInfo(expected.path)?.let { actual ->
                    actual.path == expected.path && actual.isDirectory == expected.isDirectory &&
                        (!expected.requiresNonEmptyFile || actual.size > 0)
                } == true
            }
        return when {
            !outputsMatch -> FileServerMutationVerification.DIFFERS
            else -> FileServerMutationVerification.MATCHES
        }
    }

    private fun updateServerTransferMessage(claim: FileServerTransferClaim, message: String) {
        _workspace.update { current ->
            current?.takeIf {
                repository === claim.repository && it.profile.id == claim.profileId &&
                    it.selectedModule == claim.sourceModule
            }?.copy(message = message) ?: current
        }
    }

    private suspend fun <T> capture(
        block: suspend () -> T,
        update: (Loadable<T>) -> Unit,
    ) {
        runCatching { block() }
            .onSuccess { update(Loadable.Ready(it)) }
            .onFailure { update(Loadable.Failed(it.asDsmFailure())) }
    }

    override fun onCleared() {
        releasePendingVirtualMachineLocalImageGrant()
        super.onCleared()
    }
}
