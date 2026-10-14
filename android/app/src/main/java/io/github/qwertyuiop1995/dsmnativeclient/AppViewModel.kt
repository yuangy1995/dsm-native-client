package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.downloads.*
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.reminders
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.schedules
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
import io.github.qwertyuiop1995.dsmnativeclient.data.isArchiveDownload
import io.github.qwertyuiop1995.dsmnativeclient.data.isVFSDownload
import io.github.qwertyuiop1995.dsmnativeclient.data.ArchiveDownloadPlan
import io.github.qwertyuiop1995.dsmnativeclient.data.ArchiveDownloadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.newArchiveDownloadId
import io.github.qwertyuiop1995.dsmnativeclient.ui.PendingDownloadRequest
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
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
import io.github.qwertyuiop1995.dsmnativeclient.data.canRemoveFromHistory
import io.github.qwertyuiop1995.dsmnativeclient.data.canRemoveFinishedUpload
import io.github.qwertyuiop1995.dsmnativeclient.data.toMutationResult
import io.github.qwertyuiop1995.dsmnativeclient.data.toFileBackgroundTaskPage
import io.github.qwertyuiop1995.dsmnativeclient.data.toFileServerMutationTarget
import io.github.qwertyuiop1995.dsmnativeclient.data.canRemoveFinishedServer
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
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind
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
import kotlinx.coroutines.ensureActive
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

class AppViewModel internal constructor(
    application: Application,
    selectedProfileId: String?,
    restoreOnCreate: Boolean,
    selectLastProfile: Boolean,
) : AndroidViewModel(application) {
    constructor(application: Application) : this(application, null, true, true)
    internal var onConnectionsRequested: (() -> Boolean)? = null
    internal var onSignInRequested: (() -> Boolean)? = null
    internal var onSystemFilesRequested: (() -> Unit)? = null
    internal val workspaceOwner get() = repository?.owner
    internal fun systemFileRepository(): DsmRepository? = repository?.takeIf {
        _workspace.value != null && runCatching { it.requireCurrentOwner() }.isSuccess
    }
    internal fun enqueueSharedUploads(records: List<PersistedUpload>) {
        records.forEach { record ->
            val current = transferStore.upload(record.id) ?: return@forEach
            if (current != record || current.workId != null) return@forEach
            try {
                enqueuePersistedFileUpload(current)
                transferStore.updateUpload(current.id) {
                    if (it.workId == null && it.state == TransferState.PAUSED) it.copy(state = TransferState.FAILED) else it
                }
            }
            catch (_: Exception) { transferStore.updateUpload(current.id) {
                if (it.workId == null) it.copy(state = TransferState.FAILED, errorKind = DsmErrorKind.LOCAL_STORAGE_FAILED.name) else it
            } }
        }
        records.firstOrNull()?.let { syncPersistedDownloads(it.profileId) }
    }
    private val api = DsmApiClient(io.github.qwertyuiop1995.dsmnativeclient.network.LocalNetworkAccess(application).httpClient())
    private val connectionResolver = DsmConnectionResolver(api)
    private val store = SecureProfileStore(application)
    private val cacheDirectories = io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceCacheDirectories(application.cacheDir)
    private val taskOwnership = WorkspaceTaskOwnership(store)
    internal val localNetworkPermission = LocalNetworkPermissionRequest()
    private val connections = WorkspaceConnectionService(store, api, connectionResolver, localNetworkPermission::request)
    private val transferStore = TransferStore(application)
    private val transferPresentation = TransferTaskPresentation(application)
    private val transferUris = TransferUriAccess(application, transferStore)
    private val workManager = WorkManager.getInstance(application)
    private val workspaceExecution = io.github.qwertyuiop1995.dsmnativeclient.background.AndroidWorkspaceExecution(application)
    private val photosSession = io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosSession(viewModelScope, application, workspaceExecution)
    private var repository: DsmRepository? by photosSession
    internal fun photoLibraryFor(profileId: String) = photosSession.modelFor(profileId, _workspace.value?.profile?.id)
    internal val fileSearch = FileSearchFeatureModel(viewModelScope, { repository }, { _workspace.value },
        { browser -> _workspace.update { it?.copy(fileBrowser = browser) } }) { browser ->
        _workspace.update { it?.copy(fileBrowser = browser) }
        repository?.let { repo -> viewModelScope.launch { loadFileBrowser(repo) } }
    }
    internal val fileSharing = FileSharingFeatureModel(viewModelScope, { repository }, { _workspace.value },
        { links -> _workspace.update { it?.copy(fileShareLinks = links) } },
        { busy -> _workspace.update { it?.copy(isPerformingAction = busy) } })
    internal val fileArchive = FileArchiveFeatureModel(viewModelScope, { repository }, { _workspace.value },
        { application.getString(R.string.archive_default_name) }, ::extractFile, ::compressFiles)
    internal val filePermissions = FilePermissionFeatureModel(viewModelScope, { repository }, { _workspace.value },
        { busy -> _workspace.update { it?.copy(isPerformingAction = busy) } }, ::refreshFileMetadata)
    internal val fileISOMounts = FileISOMountFeatureModel(viewModelScope, { repository }, { _workspace.value },
        { busy -> _workspace.update { it?.copy(isPerformingAction = busy) } }, ::refreshFileMetadata, ::openDirectory)
    internal val fileRemoteMounts = FileRemoteMountFeatureModel(viewModelScope, { repository }, { _workspace.value },
        { busy -> _workspace.update { it?.copy(isPerformingAction = busy) } }, ::refreshFileMetadata, ::openDirectory)
    internal val fileVFS = FileVFSFeatureModel(viewModelScope, { repository }, { _workspace.value },
        { busy -> _workspace.update { it?.copy(isPerformingAction = busy) } })
    internal val fileSettings = FileSettingsFeatureModel(viewModelScope, { repository }, { _workspace.value },
        { busy -> _workspace.update { it?.copy(isPerformingAction = busy) } })
    internal val fileBackgroundTaskControls = FileBackgroundTaskFeatureModel(viewModelScope, { repository }, { _workspace.value },
        { busy -> _workspace.update { it?.copy(isPerformingAction = busy) } }, ::refreshFileBackgroundTasks)
    private fun refreshFileMetadata() {
        fileBrowserRequestGeneration.incrementAndGet()
        fileSearch.invalidate()
        _workspace.update { it?.copy(files = Loadable.Idle, fileDirectoryBaselines = emptyMap()) }
        repository?.let { repo -> viewModelScope.launch { loadFileBrowser(repo) } }
    }
    private val fileRecovery by lazy { io.github.qwertyuiop1995.dsmnativeclient.data.files.FileRecoveryStores(application) }
    private var workspacePersistenceJob: Job? = null
    private var nasSwitchJob: Job? = null
    private var isSwitchingNas = false
    private val transferCoordinator = TransferCoordinator()
    internal val folderUploads = FolderUploadFeatureModel(application, viewModelScope, transferStore, store,
        transferCoordinator, workManager, { repository }, ::syncPersistedDownloads, ::monitorUpload)
    private val crossNasRepositories = mutableMapOf<String, DsmRepository>()
    internal val crossNasTransfers by lazy { CrossNasTransferFeatureModel(viewModelScope, fileRecovery.crossNas,
        { repository?.let(::RepositoryCrossNasTransferEndpoint) },
        { owner -> resolveCrossNasTarget(owner, store, crossNasRepositories) { profile, session -> connections.restore(profile, session, makeLastProfile = false) {} } },
        { _workspace.value?.let { it.selectedModule in setOf(Module.FILES, Module.TRANSFERS) && it.availability.allows(Module.FILES) } == true },
        { busy -> _workspace.update { it?.copy(isPerformingAction = busy) } },
        { _workspace.update { it?.copy(fileCopyMove = null, fileCopyMoveFolders = Loadable.Idle,
            fileBrowser = it.fileBrowser.clearSelection(), fileStationMutationState = FileStationMutationWorkspaceState()) } }, ::refreshFileMetadata, profileForOwner = store::profileForOwner, execution = workspaceExecution) }
    internal val officeDocuments by lazy { OfficeDocumentFeatureModel(viewModelScope, fileRecovery.office, { application.contentResolver },
        { repository?.let { io.github.qwertyuiop1995.dsmnativeclient.data.files.RepositoryOfficeDocumentEndpoint(it) } },
        { _workspace.value?.let { it.selectedModule == Module.FILES && it.availability.allows(Module.FILES) } == true },
        { busy -> _workspace.update { it?.copy(isPerformingAction = busy) } }, ::refreshFileMetadata,
        { _workspace.value?.isPerformingAction == false }, execution = workspaceExecution) }
    private var fileBackgroundTaskJob: Job? = null
    private val fileUploadPreflightJobs = mutableMapOf<String, Job>()
    private var fileUploadPreflightBusyToken: FileUploadPreflightToken? = null
    private val photoBackupCoordinator = PhotoBackupCoordinator()
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
    private var chatAttachmentPreviewJob: Job? = null
    private val chatAttachmentPreviewGeneration = AtomicLong(0)
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
    private val virtualMachineOverviewRequestGeneration = AtomicLong(0)
    private val virtualMachineGuestDetailsGeneration = AtomicLong(0)
    private val virtualMachineTaskPollingGeneration = AtomicLong(0)
    private val virtualMachineImageBrowserGeneration = AtomicLong(0)
    private val chatAttachmentPreflightGeneration = AtomicLong(0)
    private val previewRequestGeneration = AtomicLong(0)
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

    private val _login = MutableStateFlow(initialWorkspaceLoginState(store, selectedProfileId, selectLastProfile))
    val login: StateFlow<LoginState> = _login.asStateFlow()

    private val _workspace = WorkspaceStateStore(availability = { repository?.availability() })
    val workspace: StateFlow<WorkspaceState?> = _workspace.asStateFlow()
    private val _moduleNavigation = MutableStateFlow<ModuleNavigationSignal?>(null)
    internal val moduleNavigation: StateFlow<ModuleNavigationSignal?> = _moduleNavigation.asStateFlow()
    private val nasAdministrationFeature = NasAdministrationFeatureModel(
        scope = viewModelScope,
        workspace = _workspace,
        repositoryProvider = { repository },
    )
    private val chatFeature = ChatFeatureModel(
        scope = viewModelScope,
        workspace = _workspace,
        repositoryProvider = { repository },
        localizedFailure = { failure -> failure.localize(getApplication<Application>()).combined },
    )
    private val downloadActionStore by lazy { DownloadActionStore(getApplication<Application>()) }
    internal val downloadActions = DownloadActionModel(viewModelScope, { repository }, { downloadActionStore }, onChanged = {
        if (_workspace.value?.selectedModule == Module.DOWNLOADS) load(Module.DOWNLOADS)
    })
    internal val downloadCreation = DownloadCreationModel(viewModelScope, { repository },
        { java.io.File(cacheDirectories.previews, "download-inputs") }, downloadActions)

    private val serviceActivityStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.nas.NasServiceActivityStore(getApplication<Application>()) }
    internal val nasServices = io.github.qwertyuiop1995.dsmnativeclient.nas.NasServiceSettingsModel(viewModelScope, { repository }, { serviceActivityStore }, onChanged = {
        viewModelScope.launch { if (_workspace.value?.selectedModule == Module.NAS_SETTINGS) load(Module.NAS_SETTINGS) }
    })

    private val smartActivityStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.nas.NasSmartActivityStore(getApplication<Application>()) }
    private val vmmControlStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmControlStore(getApplication<Application>()) }
    private val vmmSettingsStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmSettingsStore(getApplication<Application>()) }
    private val vmmCreationStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmCreationStore(getApplication<Application>()) }
    private val vmmAssetStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmAssetStore(getApplication<Application>()) }
    private val vmmTaskStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmTaskStore(getApplication<Application>()) }
    private fun vmmExistingFlowAvailable(ignoreConsole: Boolean = false, ignoreTasks: Boolean = false, ignoreImport: Boolean = false): Boolean = _workspace.value?.let { current ->
        val state = current.virtualMachineMutationState
        (ignoreTasks || !vmmTasks.state.value.active) && (ignoreConsole || vmmConsole.state.value.target == null) && current.selectedModule == Module.VIRTUAL_MACHINES && current.availability.allows(Module.VIRTUAL_MACHINES) &&
            !current.isPerformingAction && (ignoreImport || !state.imageImportEditorVisible)
    } == true
    internal val vmmControls: io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmControlModel =
        io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmControlModel(viewModelScope, { repository }, { vmmControlStore }, canStart = { targets ->
            val owner = repository?.owner
            vmmExistingFlowAvailable() && owner != null && !vmmCreation.state.value.busy && !vmmCreation.state.value.editor && vmmCreation.state.value.reviewId == null &&
                vmmCreationStore.records(owner).none { record -> record.pending && targets.any { it.id == record.progress.guest || it.name.equals(record.snapshot.plan.configuration.name, ignoreCase = true) } } &&
                !vmmSettings.state.value.busy && !vmmSettings.state.value.editor &&
                vmmSettingsStore.records(owner).none { it.pending && targets.any { target -> io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(target.id) == it.target } } && !vmmAssets.state.value.busy && vmmAssets.state.value.confirmation == null &&
                vmmAssetStore.records(owner).flatMap { it.items }.none { item -> item.pending && targets.any { io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(it.id) in item.guests } }
        }, onChanged = { if (_workspace.value?.selectedModule == Module.VIRTUAL_MACHINES) load(Module.VIRTUAL_MACHINES) })
    internal val vmmAssets: io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmAssetModel =
        io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmAssetModel(viewModelScope, { repository }, { vmmAssetStore }, canStart = { confirmation ->
            val owner = repository?.owner
            vmmExistingFlowAvailable() && owner != null && confirmation.images.none { vmmTasks.protectsImage(it.id, it.name) } && !vmmCreation.state.value.busy && !vmmCreation.state.value.editor && vmmCreation.state.value.reviewId == null &&
                vmmCreationStore.records(owner).none { record -> record.pending && (confirmation.networks.any { network -> record.snapshot.plan.networks.any { it?.id == network.id } } ||
                    confirmation.images.any { image -> record.snapshot.plan.disks.any { it.image?.id == image.id } || record.snapshot.plan.iso?.ref?.id == image.id }) } &&
                !vmmSettings.state.value.busy && !vmmSettings.state.value.editor &&
                vmmSettingsStore.records(owner).none { it.pending && confirmation.networks.any { network -> network.guests.any { guest -> io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(guest.id) == it.target } } } && !vmmControls.state.value.busy && vmmControls.state.value.confirmation == null &&
                vmmControlStore.records(owner).flatMap { it.items }.none { item -> item.pending && confirmation.networks.any { network ->
                    network.guests.any { io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(it.id) == item.id }
                } }
        }, onChanged = { if (_workspace.value?.selectedModule == Module.VIRTUAL_MACHINES) load(Module.VIRTUAL_MACHINES) })
    internal val vmmSettings: io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmSettingsModel =
        io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmSettingsModel(viewModelScope, { repository }, { vmmSettingsStore }, canStart = { id ->
            val owner = repository?.owner
            vmmExistingFlowAvailable() && owner != null && !vmmCreation.hasPending() && !vmmControls.hasPending(id) && !vmmAssets.state.value.busy && vmmAssets.state.value.confirmation == null &&
                vmmAssetStore.records(owner).flatMap { it.items }.none { it.pending && io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(id) in it.guests }
        }, onChanged = { if (_workspace.value?.selectedModule == Module.VIRTUAL_MACHINES) { vmmControls.refresh(); load(Module.VIRTUAL_MACHINES) } })
    internal val vmmCreation: io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmCreationModel =
        io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmCreationModel(viewModelScope, { repository }, { vmmCreationStore }, canStart = { plan ->
            val owner = repository?.owner
            vmmExistingFlowAvailable() && owner != null && !vmmControls.state.value.busy && vmmControls.state.value.confirmation == null &&
                !vmmSettings.state.value.busy && !vmmSettings.state.value.editor && !vmmAssets.state.value.busy && vmmAssets.state.value.confirmation == null &&
                (plan == null || (plan.disks.mapNotNull { it.image } + listOfNotNull(plan.iso?.ref)).none { vmmTasks.protectsImage(it.id, it.name) } && vmmSettingsStore.records(owner).none { it.pending && io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(plan.configuration.name.lowercase()) in setOf(it.name, it.desiredName) } &&
                    vmmControlStore.records(owner).flatMap { it.items }.none { it.pending && it.name == io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(plan.configuration.name) } &&
                    vmmAssetStore.records(owner).none { record -> record.items.any { item -> item.pending && (if (record.kind == io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmAssetKind.NETWORK)
                        plan.networks.filterNotNull().any { io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(it.id) == item.id }
                        else (plan.disks.mapNotNull { it.image?.id } + listOfNotNull(plan.iso?.ref?.id)).any { io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(it) == item.id }) } })
        }, onChanged = { if (_workspace.value?.selectedModule == Module.VIRTUAL_MACHINES) { vmmControls.refresh(); load(Module.VIRTUAL_MACHINES) } })
    internal val vmmConsole: io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmConsoleModel =
        io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmConsoleModel(viewModelScope, { repository }, canStart = { target ->
            val owner = repository?.owner
            vmmExistingFlowAvailable(ignoreConsole = true) && owner != null && !vmmCreation.state.value.busy && !vmmCreation.state.value.editor && vmmCreation.state.value.reviewId == null &&
                vmmCreationStore.records(owner).none { it.pending && (it.progress.guest == target.id || it.snapshot.plan.configuration.name.equals(target.name, ignoreCase = true)) } &&
                !vmmSettings.state.value.busy && !vmmSettings.state.value.editor && !vmmControls.hasPending(target.id) &&
                vmmSettingsStore.records(owner).none { it.pending && it.target == io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(target.id) } &&
                !vmmAssets.state.value.busy && vmmAssets.state.value.confirmation == null &&
                vmmAssetStore.records(owner).flatMap { it.items }.none { it.pending && io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmDigest(target.id) in it.guests }
        })
    internal val vmmTasks: io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmTaskModel =
        io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmTaskModel(viewModelScope, { repository }, { vmmTaskStore }, canStart = { action ->
            vmmExistingFlowAvailable(ignoreTasks = true, ignoreImport = action == io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmTaskAction.IMPORT) &&
                !vmmCreation.state.value.busy && !vmmCreation.state.value.editor && vmmCreation.state.value.reviewId == null &&
                !vmmSettings.state.value.busy && !vmmSettings.state.value.editor && !vmmAssets.state.value.busy && vmmAssets.state.value.confirmation == null &&
                !vmmControls.state.value.busy && vmmControls.state.value.confirmation == null &&
                (action != io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmTaskAction.CLEANUP || !vmmCreation.hasPending() && !vmmLocalImportsPending())
        }, onChanged = { if (_workspace.value?.selectedModule == Module.VIRTUAL_MACHINES) { vmmAssets.refresh(io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmAssetKind.IMAGE); load(Module.VIRTUAL_MACHINES) } })
    internal fun vmmLocalImportsPending(): Boolean = _workspace.value?.profile?.id?.let { id ->
        transferStore.virtualMachineImageImports(id).any { !it.canRemoveFromHistory() }
    } ?: true
    private fun vmmAssetPending(): Boolean = repository?.owner?.let { owner ->
        vmmAssets.state.value.busy || vmmAssets.state.value.confirmation != null || runCatching { vmmAssetStore.records(owner).any { it.pending } }.getOrDefault(true)
    } ?: true
    private val containerControlStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.containers.ContainerControlStore(getApplication<Application>()) }
    private val containerImageStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.containers.ContainerImageStore(getApplication<Application>()) }
    private val containerNetworkStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.containers.ContainerNetworkStore(getApplication<Application>()) }
    internal val containerNetworks = io.github.qwertyuiop1995.dsmnativeclient.containers.ContainerNetworkModel(viewModelScope, { repository }, { containerNetworkStore }, canStart = {
        _workspace.value?.let { it.selectedModule == Module.CONTAINERS && it.availability.allows(Module.CONTAINERS) && !it.isPerformingAction } == true
    }, onChanged = { if (_workspace.value?.selectedModule == Module.CONTAINERS) load(Module.CONTAINERS) })
    internal val containerImages = io.github.qwertyuiop1995.dsmnativeclient.containers.ContainerImageModel(viewModelScope, { repository }, { containerImageStore }, canStart = {
        _workspace.value?.let { it.selectedModule == Module.CONTAINERS && it.availability.allows(Module.CONTAINERS) && !it.isPerformingAction } == true
    }, onChanged = { if (_workspace.value?.selectedModule == Module.CONTAINERS) load(Module.CONTAINERS) })
    internal val containerControls = io.github.qwertyuiop1995.dsmnativeclient.containers.ContainerControlModel(viewModelScope, { repository }, { containerControlStore }, canStart = {
        _workspace.value?.let { it.selectedModule == Module.CONTAINERS && it.availability.allows(Module.CONTAINERS) && !it.isPerformingAction } == true
    }, onChanged = { if (_workspace.value?.selectedModule == Module.CONTAINERS) load(Module.CONTAINERS) })
    internal val nasSmart: io.github.qwertyuiop1995.dsmnativeclient.nas.NasSmartTestModel = io.github.qwertyuiop1995.dsmnativeclient.nas.NasSmartTestModel(viewModelScope, { repository }, { smartActivityStore }, canStart = {
        _workspace.value?.isPerformingAction == false && !nasPower.state.value.busy
    })

    private val connectionActivityStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.nas.NasConnectionActivityStore(getApplication<Application>()) }
    internal val nasConnections = io.github.qwertyuiop1995.dsmnativeclient.nas.NasConnectionModel(viewModelScope, { repository }, { connectionActivityStore }, canStart = {
        _workspace.value?.isPerformingAction == false && !nasPower.state.value.busy
    })

    private val powerActivityStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.nas.NasPowerActivityStore(getApplication<Application>()) }
    internal val nasPower: io.github.qwertyuiop1995.dsmnativeclient.nas.NasPowerActionModel = io.github.qwertyuiop1995.dsmnativeclient.nas.NasPowerActionModel(viewModelScope, { repository }, { powerActivityStore }, canStart = {
        _workspace.value?.isPerformingAction == false && nasServices.state.value.values.none { it.busy } && !nasSmart.state.value.busy && !packageCenter.isActive
    })

    private val ddnsActivityStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.nas.NasDdnsActivityStore(getApplication<Application>()) }
    internal val nasDdns = io.github.qwertyuiop1995.dsmnativeclient.nas.NasDdnsModel(viewModelScope, { repository }, { ddnsActivityStore })

    private val regionActivityStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.nas.NasRegionActivityStore(getApplication<Application>()) }
    internal val nasRegion = io.github.qwertyuiop1995.dsmnativeclient.nas.NasRegionSettingsModel(viewModelScope, { repository }, { regionActivityStore }, onChanged = {
        viewModelScope.launch { if (_workspace.value?.selectedModule == Module.NAS_SETTINGS) load(Module.NAS_SETTINGS) }
    })

    internal val nasObservation = io.github.qwertyuiop1995.dsmnativeclient.nas.NasObservationModel(viewModelScope, { repository })

    private val scheduledTaskActivityStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.nas.NasTaskActivityStore(getApplication<Application>()) }
    internal val nasScheduledTasks = io.github.qwertyuiop1995.dsmnativeclient.nas.NasScheduledTaskModel(viewModelScope, { repository }, { scheduledTaskActivityStore })

    private val directoryActivityStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.nas.NasDirectoryActivityStore(getApplication<Application>()) }
    internal val nasDirectory = io.github.qwertyuiop1995.dsmnativeclient.nas.NasDirectoryModel(viewModelScope, { repository }, { directoryActivityStore })

    private val packageActivityStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.nas.PackageActivityStore(getApplication<Application>()) }
    internal val packageCenter: io.github.qwertyuiop1995.dsmnativeclient.nas.NasPackageCenterModel = io.github.qwertyuiop1995.dsmnativeclient.nas.NasPackageCenterModel(viewModelScope, { repository },
        { packageActivityStore }, { java.io.File(cacheDirectories.previews, "package-inputs") }, onChanged = {
            if (_workspace.value?.selectedModule == Module.NAS_SETTINGS) load(Module.NAS_SETTINGS)
        }, canStart = { _workspace.value?.isPerformingAction == false && !nasPower.state.value.busy })
    internal fun choosePackageFile(uri: Uri, token: Long) = packageCenter.chooseFile(token) { resolveUploadSource(uri) }

    private val chatActionStore by lazy { ChatActionStore(getApplication<Application>()) }
    private val chatDraftStore by lazy { ChatDraftStore(getApplication<Application>()) }
    internal val chatActions = ChatActionModel(viewModelScope, _workspace,
        sourceProvider = { repository?.takeIf { it.owner != null }?.let(::DsmChatActionSource) }, storeProvider = { chatActionStore },
        draftsProvider = { chatDraftStore },
        onConversation = ::openConversation, onChanged = { outcome ->
            chatContent.changed(outcome)
            chatNotices.changed()
            if (outcome.checkpoint.kind == ChatActionKind.CLOSE && _workspace.value?.selectedConversation?.id == outcome.checkpoint.channelId) closeConversation()
            if (_workspace.value?.chatRemindersVisible == true) showChatReminders()
            if (_workspace.value?.chatScheduledMessagesVisible == true) showChatScheduledMessages()
        })
    internal val chatContent: ChatContentModel = ChatContentModel(viewModelScope, _workspace,
        sourceProvider = { repository?.let(::DsmChatContentSource) }, actions = chatActions)
    internal val chatBatches = ChatBatchModel(viewModelScope, chatActions,
        sourceProvider = { repository?.takeIf { it.owner != null }?.let(::DsmChatActionSource) }, drafts = { chatDraftStore })
    private val chatNoticeStore by lazy { io.github.qwertyuiop1995.dsmnativeclient.chat.ChatNoticeStore(getApplication<Application>()) }
    internal val chatNotices: io.github.qwertyuiop1995.dsmnativeclient.chat.ChatNoticeModel by lazy {
        io.github.qwertyuiop1995.dsmnativeclient.chat.ChatNoticeModel(viewModelScope, chatNoticeStore, store,
            io.github.qwertyuiop1995.dsmnativeclient.chat.ChatNoticeDriver(getApplication<Application>(), chatNoticeStore, store),
            source = { repository?.takeIf { it.owner != null && it.availability().allows(Module.CHAT) }
                ?.let { io.github.qwertyuiop1995.dsmnativeclient.chat.DsmChatNoticeSource(it) } },
            seen = { chatContent.hasSeen(it) }, observe = { enabled ->
                chatFeature.observeNotices(if (enabled) ({ chatNotices.contentChanged() }) else null)
            })
    }
    internal val chatVoice = ChatVoiceModel(getApplication<Application>(), viewModelScope, chatActions, ownerProvider = { repository?.owner })
    private val nasSettingsRequestGeneration: AtomicLong
        get() = nasAdministrationFeature.settingsRequestGeneration
    private val nasSettingsStructuredMutationLock: Any
        get() = nasAdministrationFeature.mutationLock
    private val containerReadFeature = ContainerReadFeatureModel(viewModelScope, _workspace) { repository }
    private val workspaceAccess = WorkspaceAccessFeatureModel(viewModelScope, _workspace,
        repository = { repository }, onRevoked = ::stopRevokedModuleReads, onReload = { module ->
            load(module)
            chatNotices.connectionChanged()
            if (module == Module.NAS_SETTINGS) setNasPerformanceVisible(true)
        },
        onBackground = {
            vmmConsole.disconnect()
            chatFeature.stopForModuleExit()
            stopNasPerformanceSampling(resetPause = false)
            stopVirtualMachineTaskPolling()
        })
    internal fun refreshWorkspaceAccess(module: Module? = null) = workspaceAccess.refresh(module ?: _workspace.value?.selectedModule)
    internal fun setWorkspaceForeground(value: Boolean) {
        chatNotices.foreground(value)
        workspaceAccess.setForeground(value)
        chatContent.setVisible(value)
        if (!value) chatVoice.pause()
    }

    private val loginFeature = WorkspaceLoginModel(viewModelScope, _login, store, connections,
        { isSwitchingNas }, { _workspace.value?.profile?.id }, chatFeature::clearLocalReadMarkers, ::installConnectedWorkspace)

    private fun stopRevokedModuleReads(modules: Set<Module>, before: WorkspaceState) {
        filePermissions.authorizationChanged(); fileISOMounts.authorizationChanged(); fileRemoteMounts.authorizationChanged(); fileVFS.authorizationChanged(); fileSettings.authorizationChanged(); fileBackgroundTaskControls.authorizationChanged(); crossNasTransfers.authorizationChanged(); officeDocuments.authorizationChanged()
        if (Module.FILES in modules) {
            fileSearch.invalidate(); fileSharing.invalidate(); fileArchive.invalidate(); filePermissions.invalidate(); fileISOMounts.invalidate(); fileRemoteMounts.invalidate(); fileVFS.invalidate(); fileSettings.invalidate(); fileBackgroundTaskControls.invalidate(); crossNasTransfers.invalidate(); officeDocuments.invalidate()
            fileBrowserRequestGeneration.incrementAndGet()
            invalidateFileUploadPreflights()
            invalidateFileBackgroundTaskRequests()
            if (_workspace.value?.previewOwner != PreviewOwner.PHOTOS) closePreviewImmediately()
            if (before.previewOwner == PreviewOwner.FILES) cleanupPreviewFile(before.preview)
            thumbnailJobs.values.forEach(Job::cancel)
            thumbnailJobs.clear(); thumbnailReferences.clear(); thumbnailCache.evictAll()
        }
        if (Module.PHOTOS in modules) {
            photosSession.revokeAccess()
            photoTimelineJob?.cancel()
            if (_workspace.value?.previewOwner != PreviewOwner.FILES) closePreviewImmediately()
            if (before.previewOwner == PreviewOwner.PHOTOS) cleanupPreviewFile(before.preview)
        }
        if (Module.CHAT in modules) {
            chatNotices.revoke(before.profile.id)
            chatFeature.clearForProfileSwitch()
        chatActions.clear()
        chatContent.clear()
        chatBatches.clear()
        chatVoice.clear()
            invalidateChatAttachmentPreflights()
            closeChatAttachmentPreview()
            before.chatAttachmentPreviewVideoFile?.delete()
        }
        if (Module.DOWNLOADS in modules) {
            downloadActions.clear(); downloadCreation.clear()
            downloadListRequestGeneration.incrementAndGet()
            downloadActivityGeneration.incrementAndGet()
            downloadDiscoveryGeneration.incrementAndGet()
            listOf(downloadActivityJob, downloadDiscoveryLoadJob, downloadBtCatalogJob, downloadDiscoverySearchJob).forEach { it?.cancel() }
        }
        if (Module.CONTAINERS in modules) {
            containerReadFeature.invalidate()
            containerControls.clear()
            containerImages.clear()
            containerNetworks.clear()
        }
        if (Module.VIRTUAL_MACHINES in modules) {
            vmmTasks.clear(); vmmConsole.clear(); vmmCreation.clear(); vmmSettings.clear(); vmmAssets.clear(); vmmControls.clear()
            virtualMachineOverviewRequestGeneration.incrementAndGet()
            virtualMachineGuestDetailsGeneration.incrementAndGet()
            virtualMachineGuestDetailsJob?.cancel()
            stopVirtualMachineTaskPolling()
        }
        if (Module.NAS_SETTINGS in modules) {
            nasAdministrationFeature.clearForProfileSwitch()
            packageCenter.clear(); nasDirectory.clear(); nasScheduledTasks.clear(); nasObservation.clear(); nasServices.clear(); nasRegion.clear(); nasDdns.clear(); nasPower.clear(); nasConnections.clear(); nasSmart.clear()
            stopNasPerformanceSampling(resetPause = true)
            storageAnalysisJob?.cancel()
            clearPackageIconCache()
        }
    }

    init {
        startWorkspacePersistence()
        if (restoreOnCreate) loginFeature.restoreAutomatically()
    }

    private fun startWorkspacePersistence() {
        workspacePersistenceJob?.cancel()
        workspacePersistenceJob = viewModelScope.launch {
            _workspace.filterNotNull()
                .map { state -> state.profile.id to state.persistedUiState() }
                .distinctUntilChanged()
                .collect { (profileId, state) -> store.saveWorkspaceUiState(profileId, state, repository?.owner) }
        }
    }

    fun selectProfile(profile: NasProfile) = loginFeature.selectProfile(profile)
    fun newProfile() = loginFeature.newProfile()
    fun connect(profileId: String?, name: String, address: String, portText: String, username: String,
        password: String, otp: String, rememberPassword: Boolean, autoLoginEnabled: Boolean) =
        loginFeature.connect(profileId, name, address, portText, username, password, otp, rememberPassword, autoLoginEnabled)
    internal fun cancelLogin(): Boolean = loginFeature.cancelLogin()
    internal fun clearLoginAutofill() = loginFeature.clearAutofill()

    internal fun recentDirectories(): List<String> =
        _workspace.value?.profile?.id?.let(store::recentDirectories).orEmpty()

    internal fun requestClientModule(module: Module): WorkspaceNavigationResult {
        val state = _workspace.value ?: return WorkspaceNavigationResult.DEFERRED
        if (state.selectedModule != module && state.hasBlockingStructuredNasMutation()) {
            _workspace.update { it?.copy(message = getApplication<Application>().getString(R.string.switch_nas_blocked_active_operation)) }
            return WorkspaceNavigationResult.REJECTED
        }
        cancelOpaqueExternalNavigation(consumePending = true)
        return navigateTo(WorkspaceRoute.ModuleRoot(module))
    }

    internal fun openRecentDirectory(path: String) {
        val repo = repository ?: return
        val before = _workspace.value ?: return
        if (path !in store.recentDirectories(before.profile.id) && path !in before.favoritePaths) return
        viewModelScope.launch {
            val result = suspendRunCatching { repo.fileInfo(path) }
            val current = _workspace.value ?: return@launch
            if (repository !== repo || current.selectedModule != Module.FILES ||
                current.fileBrowser.path != before.fileBrowser.path ||
                fileStationMutationBlocksOrdinaryLoad(current.fileStationMutationState)) return@launch
            result.onSuccess { item ->
                if (item?.isDirectory == true) openFileRecentLocation(item)
                else _workspace.update { it?.copy(message = getApplication<Application>().getString(R.string.client_saved_location_unavailable)) }
            }
                .onFailure { error -> _workspace.update { it?.copy(message = error.asDsmFailure().localize(getApplication()).combined) } }
        }
    }

    fun restore(profile: NasProfile, fallbackPassword: String? = null) = loginFeature.restore(profile, fallbackPassword)

    private fun installConnectedWorkspace(profile: NasProfile, repo: DsmRepository) {
        fileSearch.invalidate(); fileSharing.invalidate(); fileArchive.invalidate(); filePermissions.invalidate(); fileISOMounts.invalidate(); fileRemoteMounts.invalidate(); fileVFS.invalidate(); fileSettings.invalidate(); fileBackgroundTaskControls.invalidate(); crossNasTransfers.invalidate(); officeDocuments.invalidate()
        _moduleNavigation.value = null
        chatFeature.clearLocalReadMarkers()
        fileBrowserRequestGeneration.incrementAndGet()
        downloadListRequestGeneration.incrementAndGet()
        fileBackgroundTaskRequestGeneration.incrementAndGet()
        clearPackageIconCache()
        repository = repo
        fileRecovery.bind(repo)
        repo.owner?.let { cacheDirectories.bind(it); pauseUnownedTransfers(store, transferStore, it) }
        workspaceAccess.reset()
        val availability = repo.availability()
        val restoredUi = restoredWorkspaceUi(profile.id, availability)
        val backgroundTaskSnapshot = transferStore.fileBackgroundTaskSnapshot(profile.id)
        val photoBackupSource = transferStore.photoBackupSource(profile.id)
        _workspace.value = connectedWorkspace(profile, repo, availability, restoredUi, backgroundTaskSnapshot, photoBackupSource,
            photoBackupCoordinator.sourceRestoreMessage(getApplication(), photoBackupSource), restoredPinnedConversationIds(profile.id))
        if (repo.availability().any { it.module == Module.FILES && it.isAvailable }) viewModelScope.launch { refreshFavorites(repo) }
        when {
            photoBackupSource?.needsAttention == true ->
                photoBackupCoordinator.cancelSourceWork(workManager, profile.id)
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
    }

    fun removeProfile(profile: NasProfile) {
        if (isSwitchingNas) return
        if (!canRemoveSavedConnection(profile.id)) { reportConnectionBusy(); return }
        try {
            io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmExecutionGate.requireIdle(profile.id)
            chatDraftStore.removeProfile(profile.id)
            chatActionStore.removeProfile(profile.id)
            downloadActionStore.removeProfile(profile.id)
            packageActivityStore.removeProfile(profile.id)
            directoryActivityStore.removeProfile(profile.id)
            scheduledTaskActivityStore.removeProfile(profile.id)
            serviceActivityStore.removeProfile(profile.id)
            regionActivityStore.removeProfile(profile.id)
            ddnsActivityStore.removeProfile(profile.id)
            powerActivityStore.removeProfile(profile.id)
            connectionActivityStore.removeProfile(profile.id)
            smartActivityStore.removeProfile(profile.id)
            vmmControlStore.removeProfile(profile.id)
            vmmAssetStore.removeProfile(profile.id)
            vmmSettingsStore.removeProfile(profile.id)
            vmmCreationStore.removeProfile(profile.id)
            vmmTaskStore.removeProfile(profile.id)
            containerControlStore.removeProfile(profile.id)
            containerImageStore.removeProfile(profile.id)
            containerNetworkStore.removeProfile(profile.id)
        } catch (error: Exception) {
            val failure = error.asDsmFailure()
            if (_workspace.value == null) _login.update { it.copy(error = failure) }
            else _workspace.update { it?.copy(message = failure.localize(getApplication()).combined) }
            return
        }
        val previousSelection = _login.value.selectedProfileId
        transferStore.downloads(profile.id).forEach { download ->
            if (download.state != TransferState.SUCCEEDED) {
                download.workId?.let { value ->
                    runCatching { workManager.cancelWorkById(UUID.fromString(value)) }
                }
                deleteIncompleteDownload(Uri.parse(download.destinationUri), download.id)
            }
            releasePersistedDownloadPermission(Uri.parse(download.destinationUri), download.id)
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
            photoBackupCoordinator.cancelSourceWork(workManager, profile.id)
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
        io.github.qwertyuiop1995.dsmnativeclient.systemfiles.SharedInputStore(getApplication()).reconcile(transferStore)
        fileRecovery.removeProfile(profile.id)
        io.github.qwertyuiop1995.dsmnativeclient.systemfiles.SystemDocumentStore(getApplication<Application>()).removeProfile(profile.id)
        photosSession.removeProfile(profile.id)
        store.removeProfile(profile.id)
        chatNotices.revoke(profile.id)
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
        if (!state.availability.allows(module)) {
            val unavailable = state.availability.firstOrNull { item -> item.module == module }
            _workspace.update {
                it?.copy(
                    message = unavailable?.reason?.localize(getApplication<Application>())
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
            containerReadFeature.invalidate()
        }
        if (state.selectedModule == Module.CHAT && module != Module.CHAT) {
            invalidateChatAttachmentPreflights()
        }
        if (state.selectedModule == Module.FILES && module != Module.FILES) { fileSearch.invalidate(); fileSharing.invalidate(); fileArchive.invalidate(); filePermissions.invalidate(); fileISOMounts.invalidate(); fileRemoteMounts.invalidate(); fileVFS.invalidate(); fileSettings.invalidate(); fileBackgroundTaskControls.invalidate(); crossNasTransfers.invalidate(); officeDocuments.invalidate(); invalidateFileUploadPreflights() }
        if (state.selectedModule == Module.TRANSFERS && module != Module.TRANSFERS) {
            fileBackgroundTaskControls.invalidate(); crossNasTransfers.invalidate(); officeDocuments.invalidate(); invalidateFileBackgroundTaskRequests()
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
            chatFeature.stopForModuleExit()
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
        _moduleNavigation.value = ModuleNavigationSignal(state.profile.id, module, (_moduleNavigation.value?.revision ?: 0L) + 1L)
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
            is OpaqueWorkspaceTarget.LocalTransfer -> OpaqueExternalNavigationResolution.REJECTED
            is OpaqueWorkspaceTarget.Page -> prepareOpaqueObjectNavigation(request, target.page.module).let { prepared ->
                if (prepared != OpaqueExternalNavigationResolution.APPLIED) prepared
                else {
                    when (target.page) {
                        io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspacePage.CONTAINER_REGISTRY -> navigateToContainerRegistry()
                        io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspacePage.VIRTUAL_MACHINE_TASKS -> navigateToVirtualMachineTasks()
                        io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspacePage.NAS_PERFORMANCE -> navigateToNasSettingsPerformance()
                        else -> {
                            if (target.page.module == Module.CONTAINERS) closeContainerRegistry()
                            if (target.page.module == Module.VIRTUAL_MACHINES) closeVirtualMachineTasks()
                            if (target.page.module == Module.NAS_SETTINGS) closeNasSettingsPerformance()
                        }
                    }
                    OpaqueExternalNavigationResolution.APPLIED
                }
            }
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
                    item.previewKind() == FilePreviewKind.UNSUPPORTED && !io.github.qwertyuiop1995.dsmnativeclient.data.files.OfficeDocumentPolicy.supports(item)
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
            val value = captureLoadable { repo.virtualMachineGuestDetails(guestId) }
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
        repository?.let(nasAdministrationFeature::loadSettings)
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
        if (_workspace.value?.availability?.none { it.module == targetModule && it.isAvailable } == true) return
        if (targetModule == Module.PHOTOS) {
            _workspace.value?.profile?.id?.let(::photoLibraryFor)?.activate()
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
                    downloadActions.restore()
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
                            _workspace.value = current.withDownloads(Loadable.Loading)
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
                Module.CONTAINERS -> containerReadFeature.loadModule(repo)
                Module.VIRTUAL_MACHINES -> {
                    val token = synchronized(virtualMachineMutationLock) {
                        val current = _workspace.value ?: return@synchronized null
                        if (repository !== repo || current.selectedModule != Module.VIRTUAL_MACHINES) {
                            return@synchronized null
                        }
                        val mutation = current.virtualMachineMutationState
                        if (virtualMachineOrdinaryLoadBlocked(mutation)) {
                            return@synchronized null
                        }
                        VirtualMachineOverviewRequestToken(
                            profileId = current.profile.id,
                            generation = virtualMachineOverviewRequestGeneration.incrementAndGet(),
                        ).also {
                            _workspace.value = current.copy(virtualMachines = Loadable.Loading)
                        }
                    }
                    if (token == null) return@launch
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
                    chatFeature.loadModule(repo)
                    chatActions.restore()
                    chatBatches.restore()
                }
                Module.NAS_SETTINGS -> {
                    packageCenter.restore()
                    nasAdministrationFeature.loadSettings(repo)
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
                                merged == null -> io.github.qwertyuiop1995.dsmnativeclient.data.files.backgroundTaskChanged()
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
        if (_workspace.value?.selectedConversation?.id != conversation.id) {
            invalidateChatAttachmentPreflights()
        }
        chatFeature.openConversation(conversation)
    }

    fun toggleChatConversationPin(conversationId: String) {
        chatFeature.toggleConversationPin(conversationId)
    }

    fun closeConversation() {
        if (_workspace.value?.selectedConversation != null) invalidateChatAttachmentPreflights()
        chatFeature.closeConversation()
    }

    private fun WorkspaceState.hasActiveChatMutation(vararg operations: ChatMutationOperation): Boolean =
        chatActions.state.value.items.any { it.kind.legacyOperation() in operations && (it.busy || it.confirmation) }

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
                        if (repository === repo && state?.chatNewConversationVisible == true) state.copy(chatUsers = value) else state
                    }
                },
            )
        }
    }

    fun closeNewChatConversation() {
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
        if (selected.isEmpty() || selected.size > 1 && state.chatGroupTitle.isBlank()) return
        chatActions.request(ChatActionDraft(if (selected.size == 1) ChatActionKind.DIRECT else ChatActionKind.GROUP,
            if (selected.size == 1) "new-direct:${selected.single()}" else "new-group", text = state.chatGroupTitle, memberIds = selected))
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
                        if (repository === repo && state?.chatMembersVisible == true &&
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
                block = { repo.chatRepository.reminders(conversation.id) },
                update = { value ->
                    _workspace.update { state ->
                        if (repository === repo && state?.chatRemindersVisible == true && state.selectedConversation?.id == conversation.id) {
                            state.copy(chatReminders = value)
                        } else state
                    }
                },
            )
        }
    }

    fun closeChatReminders() {
        _workspace.update { it?.copy(chatRemindersVisible = false) }
    }

    fun setChatReminder(messageId: String, remindAtEpochMillis: Long) {
        val state = _workspace.value ?: return
        val conversation = state.selectedConversation ?: return
        val message = (state.chatMessages as? Loadable.Ready)?.value?.messages?.firstOrNull { it.id == messageId } ?: return
        chatActions.request(ChatActionDraft(ChatActionKind.REMINDER_SET, conversation.id, original = message,
            atMillis = remindAtEpochMillis, reminder = (state.chatReminders as? Loadable.Ready)?.value?.firstOrNull { it.messageId == messageId }))
    }

    fun requestDeleteChatReminder(messageId: String): Boolean {
        val state = _workspace.value ?: return false
        val channel = state.selectedConversation?.id ?: return false
        val reminder = (state.chatReminders as? Loadable.Ready)?.value?.firstOrNull { it.messageId == messageId } ?: return false
        return chatActions.request(ChatActionDraft(ChatActionKind.REMINDER_DELETE, channel, reminder = reminder), confirm = true) != null
    }

    fun deleteChatReminder(messageId: String) {
        requestDeleteChatReminder(messageId)
    }

    fun cancelChatMutation(requestId: String): Boolean = chatActions.cancel(requestId)

    fun refreshChatMutation(requestId: String): Boolean = chatActions.refresh(requestId)

    fun dismissChatMutation(requestId: String, discardDraft: Boolean = false): Boolean =
        if (discardDraft) chatActions.discard(requestId) else chatActions.dismiss(requestId)

    fun continueEditingChatMutation(requestId: String): Boolean {
        val item = chatActions.state.value.items.firstOrNull { it.id == requestId && it.canEdit } ?: return false
        val draft = item.draft ?: return false
        if (!chatActions.discard(requestId)) return false
        _workspace.update { state -> state?.copy(chatDrafts = state.chatDrafts + (draft.channelId to draft.text)) }
        return true
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
                block = { repo.chatRepository.schedules(conversation.id) },
                update = { value ->
                    _workspace.update { state ->
                        if (repository === repo && state?.chatScheduledMessagesVisible == true && state.selectedConversation?.id == conversation.id) {
                            state.copy(chatScheduledMessages = value)
                        } else state
                    }
                },
            )
        }
    }

    fun closeChatScheduledMessages() {
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
        val channel = state.selectedConversation?.id ?: return
        chatActions.request(ChatActionDraft(ChatActionKind.SCHEDULE_CREATE, channel,
            text = state.chatScheduleDraft, atMillis = state.chatScheduleSendAtEpochMillis))
    }

    fun deleteChatScheduledMessage(id: String) {
        requestDeleteChatScheduledMessage(id)
    }

    fun requestDeleteChatScheduledMessage(id: String): Boolean {
        val state = _workspace.value ?: return false
        val channel = state.selectedConversation?.id ?: return false
        val scheduled = (state.chatScheduledMessages as? Loadable.Ready)?.value?.firstOrNull { it.id == id } ?: return false
        return chatActions.request(ChatActionDraft(ChatActionKind.SCHEDULE_DELETE, channel, schedule = scheduled), confirm = true) != null
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
        val channel = state.selectedConversation?.id ?: return
        chatActions.request(ChatActionDraft(ChatActionKind.POLL_CREATE, channel, text = state.chatPollQuestion,
            options = state.chatPollOptions, multiple = state.chatPollAllowsMultiple, anonymous = state.chatPollIsAnonymous))
    }

    fun closeChatMembers() {
        _workspace.update { it?.copy(chatMembersVisible = false, chatMembers = Loadable.Idle) }
    }

    fun loadOlderChatMessages() {
        chatFeature.loadOlderMessages()
    }

    fun updateChatDraft(value: String) {
        val conversationId = _workspace.value?.selectedConversation?.id ?: return
        chatActions.updateComposer(conversationId, value)
    }

    fun sendChatMessage() {
        val state = _workspace.value ?: return
        val channel = state.selectedConversation?.id ?: return
        val text = state.chatDrafts[channel].orEmpty()
        if (text.isBlank()) return
        chatActions.request(ChatActionDraft(ChatActionKind.SEND, channel, text = text))
    }

    fun sendChatAttachment(uri: Uri) {
        val repo = repository ?: return
        val state = _workspace.value ?: return
        val channel = state.selectedConversation?.id ?: return
        val generation = chatAttachmentPreflightGeneration.get()
        viewModelScope.launch {
            suspendRunCatching { resolveUploadSource(uri) }.onSuccess { source ->
                if (repository === repo && _workspace.value?.selectedConversation?.id == channel &&
                    _workspace.value?.selectedModule == Module.CHAT && chatAttachmentPreflightGeneration.get() == generation)
                    chatActions.request(ChatActionDraft(ChatActionKind.ATTACHMENT, channel,
                        text = state.chatDrafts[channel].orEmpty(), attachment = source))
            }.onFailure { error -> if (repository === repo) _workspace.update { it?.copy(message = error.asDsmFailure().localize(getApplication<Application>()).combined) } }
        }
    }

    private fun invalidateChatAttachmentPreflights() { chatAttachmentPreflightGeneration.incrementAndGet() }

    fun cancelChatAttachment(localId: String) { chatActions.cancel(localId.removePrefix("local:")) }

    fun saveChatAttachment(
        messageId: String,
        attachment: io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment,
        destination: Uri,
    ) {
        val repo = repository ?: return
        viewModelScope.launch {
            suspendRunCatching {
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
                    if (repository !== repo) return@update it
                    it?.copy(message = getApplication<Application>().getString(R.string.attachment_saved))
                }
            }.onFailure { error ->
                if (error is CancellationException) return@onFailure
                _workspace.update {
                    if (repository !== repo) return@update it
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
        val previewGeneration = chatAttachmentPreviewGeneration.get()
        if (attachment.isVideoAttachment() || attachment.mimeType?.startsWith("audio/", ignoreCase = true) == true ||
            attachment.name.substringAfterLast('.', "").lowercase() in setOf("m4a", "mp3", "aac", "wav", "ogg", "flac")) {
            previewChatMediaAttachment(repo, messageId, attachment)
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
            suspendRunCatching { repo.chatAttachmentThumbnail(messageId) }
                .onSuccess { bytes ->
                    _workspace.update {
                        if (repository !== repo || chatAttachmentPreviewGeneration.get() != previewGeneration || it?.chatAttachmentPreviewName != attachment.name ||
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
                        if (repository !== repo || chatAttachmentPreviewGeneration.get() != previewGeneration) return@update it
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
        chatAttachmentPreviewGeneration.incrementAndGet()
        chatAttachmentPreviewJob?.cancel()
        chatAttachmentPreviewJob = null
        _workspace.value?.chatAttachmentPreviewVideoFile?.delete()
        _workspace.update {
            it?.copy(
                chatAttachmentPreviewName = null,
                chatAttachmentPreviewBytes = null,
                chatAttachmentPreviewVideoFile = null,
                chatAttachmentPreviewIsVideo = false,
                chatAttachmentPreviewIsAudio = false,
                chatAttachmentPreviewIsLoading = false,
                chatAttachmentPreviewProgress = null,
                chatAttachmentPreviewError = null,
            )
        }
    }

    private fun previewChatMediaAttachment(
        repo: DsmRepository,
        messageId: String,
        attachment: io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment,
    ) {
        val previewGeneration = chatAttachmentPreviewGeneration.get()
        _workspace.update {
            it?.copy(
                chatAttachmentPreviewName = attachment.name,
                chatAttachmentPreviewIsVideo = true,
                chatAttachmentPreviewIsAudio = !attachment.isVideoAttachment(),
                chatAttachmentPreviewIsLoading = true,
                chatAttachmentPreviewProgress = 0f,
            )
        }
        chatAttachmentPreviewJob = viewModelScope.launch {
            var temporaryFile: File? = null
            try {
                suspendRunCatching {
                withContext(Dispatchers.IO) {
                    val directory = cacheDirectories.chatPreviews
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
                                    if (repository === repo && chatAttachmentPreviewGeneration.get() == previewGeneration && state?.chatAttachmentPreviewName == attachment.name &&
                                        state.chatAttachmentPreviewIsVideo
                                    ) state.copy(chatAttachmentPreviewProgress = progress) else state
                                }
                            }
                        }
                    }
                }
            }.onSuccess { file ->
                _workspace.update { state ->
                    if (repository === repo && chatAttachmentPreviewGeneration.get() == previewGeneration && state?.chatAttachmentPreviewName == attachment.name &&
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
                _workspace.update { state ->
                    if (repository === repo && chatAttachmentPreviewGeneration.get() == previewGeneration && state?.chatAttachmentPreviewName == attachment.name &&
                        state.chatAttachmentPreviewIsVideo
                    ) state.copy(
                        chatAttachmentPreviewIsLoading = false,
                        chatAttachmentPreviewProgress = null,
                        chatAttachmentPreviewError = error.asDsmFailure()
                            .localize(getApplication<Application>()).combined,
                    ) else state
                }
            }
            } catch (cancelled: CancellationException) {
                // 取消会由 suspendRunCatching 直接传播，已创建的预览文件不能遗留在缓存中。
                temporaryFile?.delete()
                throw cancelled
            }
        }
    }

    fun retryChatMessage(localId: String) { chatActions.refresh(localId.removePrefix("local:")) }

    fun removeFailedChatMessage(localId: String): Boolean = chatActions.discard(localId.removePrefix("local:"))

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
        store.recordRecentDirectory(current.profile.id, item.path, repository?.owner)
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
            suspendRunCatching {
                repo.listFavorites().take(MAX_FILE_FAVORITES).mapNotNull { favorite ->
                    suspendRunCatching { repo.fileInfo(favorite.path) }.getOrNull()
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

    fun loadFileRecentLocations() {
        val repo = repository ?: return
        val profileId = _workspace.value?.profile?.id ?: return
        _workspace.update { it?.copy(fileRecentLocations = Loadable.Loading) }
        viewModelScope.launch {
            val locations = store.recentDirectories(profileId).mapNotNull { path ->
                suspendRunCatching { repo.fileInfo(path) }.getOrNull()?.takeIf(FileItem::isDirectory)
            }
            _workspace.update { it?.copy(fileRecentLocations = Loadable.Ready(locations)) }
        }
    }

    fun closeFileRecentLocations() {
        _workspace.update { it?.copy(fileRecentLocations = Loadable.Idle) }
    }

    fun openFileRecentLocation(item: FileItem) {
        val profileId = _workspace.value?.profile?.id ?: return
        store.recordRecentDirectory(profileId, item.path, repository?.owner)
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
                suspendRunCatching { repo.fileInfo(path) }.getOrNull()?.takeIf(FileItem::isDirectory)?.let { item ->
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
        if (state.fileBrowser.activeSearchQuery == null || state.files !is Loadable.Ready) repository?.let { repo -> viewModelScope.launch { loadFileBrowser(repo) } }
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
            suspendRunCatching { listFilePage(repo, browser, nextOffset) }
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

    internal fun compressFiles(request: io.github.qwertyuiop1995.dsmnativeclient.domain.FileCompressionRequest): Boolean {
        val current = _workspace.value ?: return false
        if (!request.isValid) return false
        val destinationPath = request.destination.path.trimEnd('/') + "/" + request.filename
        val target = FileServerMutationTarget(current.profile.id, Module.FILES, FileServerMutationOperation.COMPRESS,
            request.sources, request.destination, listOf(FileServerMutationExpectedOutput(destinationPath, false, requiresNonEmptyFile = true)))
        return enqueueServerTransfer(request.filename, target) { repo, progress, beforeSubmit, taskStarted, _ ->
            val result = repo.compressResult(sourceBaselines = request.sources, destinationBaseline = request.destination,
                destinationFilePath = destinationPath, format = request.format, level = request.level, password = request.password,
                onProgress = progress, onBeforeSubmit = beforeSubmit, onTaskStarted = taskStarted)
            if ((result.submitted || result.requiresRefresh) && currentCoroutineContext().isActive) loadFileBrowser(repo)
            FileServerMutationExecution(result, target.expectedOutputs)
        }
    }

    internal fun extractFile(request: io.github.qwertyuiop1995.dsmnativeclient.domain.FileExtractionRequest): Boolean {
        val current = _workspace.value ?: return false
        if (!request.options.isValid || request.source.isDirectory || !request.source.canRead || !request.destination.canWrite) return false
        val target = FileServerMutationTarget(current.profile.id, Module.FILES, FileServerMutationOperation.EXTRACT,
            listOf(request.source), request.destination)
        return enqueueServerTransfer(request.source.name, target) { repo, progress, beforeSubmit, taskStarted, expectedOutputsChanged ->
            var outputs = emptyList<FileServerMutationExpectedOutput>()
            val result = repo.extractResult(request, onProgress = progress,
                onExpectedOutputs = { outputs = it; expectedOutputsChanged(it) }, onBeforeSubmit = beforeSubmit, onTaskStarted = taskStarted)
            if ((result.submitted || result.requiresRefresh) && currentCoroutineContext().isActive) loadFileBrowser(repo)
            FileServerMutationExecution(result, outputs)
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
            suspendRunCatching { resolveFileCopyMoveRepository(next) }
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
            suspendRunCatching { resolveFileCopyMoveRepository(move) }
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
        if (operation.targetProfileId != operation.sourceProfileId) {
            if (current.isPerformingAction) return false
            val destinationRepo = fileCopyMoveRepository(operation) ?: return false
            val started = crossNasTransfers.start(RepositoryCrossNasTransferEndpoint(destinationRepo), operation.items,
                destinationBaseline, operation.operation == FileCopyMoveOperation.MOVE, current.profile.name,
                operation.targetProfiles.firstOrNull { it.id == operation.targetProfileId }?.name ?: return false)
            if (started) _workspace.update { it?.copy(fileStationMutationState = FileStationMutationWorkspaceState(editorVisible = true)) }
            return started
        }
        val target = FileStationMutationTarget(
            profileId = current.profile.id,
            module = Module.FILES,
            operation = if (operation.operation == FileCopyMoveOperation.COPY) FileStationMutationOperation.COPY else FileStationMutationOperation.MOVE,
            sourceBaselines = operation.items,
            destinationPath = operation.location.path,
            destinationBaseline = destinationBaseline,
        )
        return fileStationMutation(
            target,
            FileStationMutationRefresh.FILE_BROWSER,
            ::fileCopyMoveMessageResource,
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
            when (operation.operation) {
                FileCopyMoveOperation.COPY -> repo.copyResult(operation.items, destinationBaseline)
                FileCopyMoveOperation.MOVE -> repo.moveResult(operation.items, destinationBaseline)
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

    fun loadFileShareLinks() = fileSharing.refreshLinks()

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
        val owner = repository?.owner ?: return
        val uri = when (val destination = state.pageLinkDestination()) {
            is WorkspacePageLinkDestination.Fixed -> destination.uri.workspacePageOrNull()?.let { page ->
                store.issueOpaqueWorkspaceTarget(state.profile.id, OpaqueWorkspaceTarget.Page(page), owner)
                    ?.let(::opaqueObjectExternalWorkspaceUri)
            }
            is WorkspacePageLinkDestination.Opaque -> store.issueOpaqueWorkspaceTarget(
                profileId = state.profile.id,
                target = destination.target,
                owner = owner,
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

    fun requestFileShareLinkCreation(item: FileItem): Boolean = fileSharing.openCreate(listOf(item))

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
                        if (!checkTransferOwner(WorkspaceRecordKind.UPLOAD, record.id, claim.repository, create = true)) return@synchronized
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
            transferCoordinator.registerForegroundTask(taskId, job)
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
        folderUploads.invalidatePreview()
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
        val repo = repository ?: return
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
                val source = suspendRunCatching { resolveUploadSource(uri) }.getOrNull()
                    ?: return@forEach
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
                if (!checkTransferOwner(WorkspaceRecordKind.UPLOAD, record.id, repo, create = true)) {
                    releasePersistedReadPermission(uri)
                    return@forEach
                }
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
        val repo = repository ?: return
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
            sourceId = UUID.randomUUID().toString(),
        )
        if (!checkTransferOwner(WorkspaceRecordKind.PHOTO_SOURCE, requireNotNull(source.sourceId), repo, create = true) ||
            !schedulePhotoBackupSource(source)) {
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
        val destination = _workspace.value?.fileBrowser?.path.orEmpty()
        if (destination.isBlank()) return
        val claim = claimFileUploadPreflight(destination, markWorkspaceBusy = true) ?: return
        launchFileUploadPreflight(claim) {
            try {
                folderUploads.prepare(treeUri, destination, claim.token.profileId, claim.repository) {
                    _workspace.value?.let { fileUploadPreflightMatches(claim, it) } == true
                }
            } finally {
                synchronized(fileStationMutationLock) {
                    val current = _workspace.value
                    if (current != null && fileUploadPreflightMatches(claim, current)) {
                        fileUploadPreflightBusyToken = null
                        _workspace.value = current.copy(isPerformingAction = false)
                    }
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
        photoBackupCoordinator.cancelSourceWork(workManager, state.profile.id)
        _workspace.update {
            it?.copy(
                photoBackupSourceEnabled = false,
                message = getApplication<Application>().getString(R.string.photo_backup_folder_disabled),
            )
        }
    }

    internal fun enqueueDownload(request: PendingDownloadRequest, destination: Uri): DownloadEnqueueResult {
        val repo = repository ?: run {
            deleteIncompleteDownload(destination)
            return DownloadEnqueueResult.REJECTED
        }
        val state = _workspace.value ?: run {
            deleteIncompleteDownload(destination)
            return DownloadEnqueueResult.REJECTED
        }
        if (repo.owner != request.owner || request.owner.profileId != state.profile.id ||
            runCatching { repo.requireCurrentOwner() }.isFailure) {
            discardUnmatchedDownloadDestination(destination)
            return DownloadEnqueueResult.REJECTED
        }
        val items = request.items
        val remote = request.vfsSource
        val validSource = if (remote == null) items.all { io.github.qwertyuiop1995.dsmnativeclient.data.files.isFileMutationPath(it.path) }
            else remote.profile.owner == request.owner && items.size == 1 && remote.matches(items.single())
        if (items.isEmpty() || items.any { !it.canRead } || !validSource) {
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
        val archive = request.isArchive
        val item = items.first()
        val taskId = if (remote != null) io.github.qwertyuiop1995.dsmnativeclient.data.newVFSDownloadId() else if (archive) newArchiveDownloadId() else UUID.randomUUID().toString()
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
            title = request.title,
            destinationUri = destination.toString(),
            isDirectory = archive,
            expectedBytes = item.size.takeIf { !archive && it > 0 },
            backgroundCapable = backgroundCapable,
            workId = backgroundRequest?.id?.toString(),
        )
        val owned = checkTransferOwner(WorkspaceRecordKind.DOWNLOAD, record.id, repo, create = true)
        val persisted = if (!owned) false else if (remote != null) {
            runCatching { transferStore.createVFSDownloadDurably(record, io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadPlan(
                taskId = taskId, destinationUri = record.destinationUri, source = remote)) }.getOrDefault(false)
        } else if (archive) {
            runCatching { transferStore.createArchiveDownloadDurably(record, ArchiveDownloadPlan(
                taskId = taskId, profileId = record.profileId, destinationUri = record.destinationUri,
                sources = items.distinctBy(FileItem::path).map { ArchiveDownloadSource(it.path, it.name, it.isDirectory) },
            )) }.getOrDefault(false)
        } else if (backgroundCapable) {
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
            suspendRunCatching {
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
                    cacheDirectories.previews,
                ).sumOf { directory -> directory.listFiles()?.sumOf(File::length) ?: 0L }
            }
            _workspace.update { it?.copy(regenerableCacheBytes = bytes) }
        }
    }

    fun openPreview(item: FileItem) = openPreview(item, emptyList())

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

    private fun startPreview(item: FileItem, owner: PreviewOwner) {
        if (owner == PreviewOwner.FILES && io.github.qwertyuiop1995.dsmnativeclient.data.files.OfficeDocumentPolicy.supports(item)) {
            closePreviewImmediately(); officeDocuments.open(item); return
        }
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
            suspendRunCatching { loadPreview(repo, item) }
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
        val job = transferCoordinator.foregroundTask(id)
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
        transferCoordinator.foregroundTask(id)?.cancel()
        paused.workId?.let { value ->
            runCatching { workManager.cancelWorkById(UUID.fromString(value)) }
        }
    }

    private fun checkTransferOwner(kind: WorkspaceRecordKind, id: String, repo: DsmRepository?, create: Boolean = false): Boolean =
        runCatching {
            val target = repo ?: throw io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure()
            if (create) taskOwnership.bind(kind, id, target) else taskOwnership.require(kind, id, target)
        }.onFailure { error -> _workspace.update { it?.copy(message = error.asDsmFailure().localize(getApplication()).combined) } }.isSuccess

    fun canResumeTransfer(id: String): Boolean =
        transferStore.download(id)?.canResumeDownload() == true && taskOwnership.canUse(WorkspaceRecordKind.DOWNLOAD, id, repository)

    fun resumeTransfer(id: String) {
        if (!checkTransferOwner(WorkspaceRecordKind.DOWNLOAD, id, repository)) return
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
        if (download?.canRetryDownload() == true) return taskOwnership.canUse(WorkspaceRecordKind.DOWNLOAD, id, repository)
        val upload = transferStore.upload(id) ?: return false
        if (folderUploads.isFolder(id)) return taskOwnership.canUse(WorkspaceRecordKind.UPLOAD, id, repository) &&
            upload.state in setOf(TransferState.FAILED, TransferState.CANCELLED, TransferState.PAUSED)
        return taskOwnership.canUse(WorkspaceRecordKind.UPLOAD, id, repository) && upload.state in setOf(
            TransferState.FAILED,
            TransferState.CANCELLED,
        )
    }

    fun retryTransfer(id: String) {
        val repo = repository ?: return
        transferStore.download(id)?.takeIf {
            it.canRetryDownload()
        }?.let { download ->
            if (!checkTransferOwner(WorkspaceRecordKind.DOWNLOAD, id, repo)) return
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
        if (!checkTransferOwner(WorkspaceRecordKind.UPLOAD, id, repo)) return
        if (!canRetryTransfer(id) || _workspace.value?.isPerformingAction == true) return
        if (folderUploads.isFolder(id)) { folderUploads.retry(id); return }
        viewModelScope.launch {
            _workspace.update { it?.copy(isPerformingAction = true, message = null) }
            suspendRunCatching {
                retryStoredUpload(repo, upload, transferStore, store, UploadSource(
                    displayName = upload.title, contentType = upload.contentType, contentLength = upload.expectedBytes,
                    openInputStream = { getApplication<Application>().contentResolver.openInputStream(Uri.parse(upload.sourceUri))
                        ?: throw java.io.IOException("The selected file is unavailable") },
                ))
            }.onSuccess { (decision, next) ->
                syncPersistedDownloads(upload.profileId)
                _workspace.update { it?.copy(isPerformingAction = false,
                    message = getApplication<Application>().getString(decision.message)) }
                if (decision == RetryUploadDecision.REQUEUE) {
                    enqueuePersistedFileUpload(next,
                        existingWorkPolicy = transferEnqueuePolicy(TransferEnqueueReason.USER_RETRY))
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

    fun canOpenUploadTarget(id: String): Boolean = transferStore.upload(id) != null &&
        taskOwnership.canUse(WorkspaceRecordKind.UPLOAD, id, repository)

    fun openUploadTarget(id: String) {
        val repo = repository ?: return
        val upload = transferStore.upload(id) ?: return
        if (!checkTransferOwner(WorkspaceRecordKind.UPLOAD, id, repo)) return
        val token = store.issueOpaqueWorkspaceTarget(upload.profileId,
            OpaqueWorkspaceTarget.FileDirectory(upload.destinationPath), repo.owner ?: return) ?: return
        navigateToOpaqueExternalRoute(token)
    }

    fun clearFinishedTransfers() {
        _workspace.value?.profile?.id?.let { profileId ->
            transferStore.downloads(profileId)
                .filter { it.state in TERMINAL_TRANSFER_STATES }
                .forEach {
                    val destination = Uri.parse(it.destinationUri)
                    if (it.state == TransferState.FAILED) deleteIncompleteDownload(destination, it.id)
                    releasePersistedDownloadPermission(destination, it.id)
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
            io.github.qwertyuiop1995.dsmnativeclient.systemfiles.SharedInputStore(getApplication()).reconcile(transferStore)
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
        return taskOwnership.canUse(WorkspaceRecordKind.SERVER, id, repository) && lifecycle.target.profileId == current.profile.id &&
            !lifecycle.refreshInProgress && needsRecovery
    }

    fun refreshFileServerTransfer(id: String): Boolean {
        if (!checkTransferOwner(WorkspaceRecordKind.SERVER, id, repository)) return false
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
            val outcome = suspendRunCatching {
                verifyFileServerMutation(claim.repository, claim.target, transferStore.server(id), transferStore)
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
            suspendRunCatching { repo.loadDownloadSettings() }
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
            suspendRunCatching { repo.loadDownloadActivity() }
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
            suspendRunCatching { repo.loadDownloadBtSearchCatalog() }
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
            suspendRunCatching { claim.first.listDownloadRssSites() }
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
            suspendRunCatching { claim.first.listDownloadRssFeeds(claim.third) }
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
        _workspace.value?.selectedDownloadRssSite?.let(downloadActions::requestRss)
    }
    fun recheckDownloadRssRefresh(): Boolean { downloadActions.show(); return true }
    fun dismissDownloadRssRefreshMutation(): Boolean { downloadActions.show(false); return true }

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
            suspendRunCatching { repo.searchDownloadBt(options) }
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
        val original = _workspace.value?.downloadSettingsState?.baseline ?: return false
        val accepted = downloadActions.requestSettings(original, settings)
        if (accepted) closeDownloadSettings()
        return accepted
    }
    fun refreshDownloadSettingsMutation() { downloadActions.show() }
    fun dismissDownloadSettingsMutation(): Boolean { downloadActions.show(false); return true }

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

    fun beginDownloadTasksDestinationSelection(ids: Set<String>): Boolean {
        val tasks = ids.map { currentDownloadTask(it) ?: return false }
        if (tasks.isEmpty() || !beginDownloadTaskDestinationSelection(tasks.first().id)) return false
        _workspace.update { it?.copy(downloadDestinationEditState = it.downloadDestinationEditState.copy(selectionTasks = tasks)) }
        return true
    }

    fun requestDownloadDestinationEdit(): Boolean {
        val current = _workspace.value ?: return false
        val task = current.downloadDestinationEditState.selectionTaskBaseline ?: return false
        val destination = current.downloadDestinationPicker?.location?.baseline ?: return false
        val accepted = downloadActions.requestTasks(current.downloadDestinationEditState.selectionTasks.ifEmpty { listOf(task) }, DownloadActionKind.EDIT, destination)
        if (accepted) cancelDownloadDestinationSelection()
        return accepted
    }

    fun openDownloadCreationEditor(): Boolean = downloadCreation.open()
    fun updateDownloadCreationDraft(uri: String, destination: String) = downloadCreation.update(uri, destination)
    fun closeDownloadCreationEditor(): Boolean { downloadCreation.clear(); return true }
    fun beginDiscoveryDownloadCreation(title: String, uri: String, sourceKind: DownloadCreationSourceKind): Boolean {
        if (sourceKind !in setOf(DownloadCreationSourceKind.RSS, DownloadCreationSourceKind.BT_SEARCH)) return false
        closeDownloadDiscovery()
        return downloadCreation.open(uri, title)
    }
    fun createDownloadFromFile(uri: Uri, selectionToken: Long = downloadCreation.selectionToken): Boolean = downloadCreation.chooseFile(selectionToken) { resolveUploadSource(uri) }

    fun openDownloadTaskDetails(task: DownloadTask) {
        cancelOpaqueExternalNavigation(consumePending = true)
        val repo = repository ?: return
        _workspace.update { it?.copy(downloadDetailsTask = task, downloadAdvancedRead = it.downloadAdvancedRead.copy(downloadDetails = Loadable.Loading)) }
        viewModelScope.launch {
            val result = try { Loadable.Ready(repo.downloadTaskDetails(task.id)) }
                catch (error: Exception) { if (error is CancellationException) return@launch; Loadable.Failed(error.asDsmFailure()) }
            _workspace.update { current -> if (repository === repo && current?.downloadDetailsTask?.id == task.id)
                current.copy(downloadAdvancedRead = current.downloadAdvancedRead.copy(downloadDetails = result)) else current }
        }
    }

    fun closeDownloadTaskDetails() {
        _workspace.update { it?.copy(downloadDetailsTask = null, downloadAdvancedRead = it.downloadAdvancedRead.copy(downloadDetails = Loadable.Idle)) }
    }

    private fun currentDownloadTask(id: String): DownloadTask? = (_workspace.value?.downloads as? Loadable.Ready)?.value?.singleOrNull { it.id == id }
    fun requestDownloadPause(taskId: String): Boolean = currentDownloadTask(taskId)?.let {
        downloadActions.requestTasks(listOf(it), DownloadActionKind.PAUSE) } == true
    fun requestDownloadResume(taskId: String): Boolean = currentDownloadTask(taskId)?.let {
        downloadActions.requestTasks(listOf(it), DownloadActionKind.RESUME) } == true
    fun requestDownloadDeletion(taskId: String, deleteFiles: Boolean): Boolean = currentDownloadTask(taskId)?.let {
        downloadActions.requestTasks(listOf(it), if (deleteFiles) DownloadActionKind.END_AND_MOVE else DownloadActionKind.REMOVE) } == true
    fun refreshDownloadControlMutation() { downloadActions.show() }
    fun refreshDownloadDestinationEditMutation() { downloadActions.show() }

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

    fun showContainerRegistry() = containerReadFeature.showRegistry()
    fun closeContainerRegistry() = containerReadFeature.closeRegistry()
    fun updateContainerRegistryQuery(value: String) = containerReadFeature.updateQuery(value)
    fun searchContainerRegistry() = containerReadFeature.searchRegistry()
    fun selectContainerRegistryImage(image: ContainerRegistryImage) = containerReadFeature.selectImage(image)
    internal val containerEvents get() = containerReadFeature.events
    internal fun loadContainerEvents() = containerReadFeature.loadEvents()
    internal fun stopContainerEvents() = containerReadFeature.stopEvents()

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
            state.imageImportEditorVisible ||
            (vmmTasks.state.value.active || vmmConsole.state.value.target != null || vmmAssetPending() || vmmControls.hasPending() || vmmSettings.hasPending() || vmmCreation.hasPending() || current.isPerformingAction)
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
        if (!state.imageImportEditorVisible || draft.browserPath != existing.browserPath ||
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
            if (!state.imageImportEditorVisible || draft.source != VirtualMachineImageImportSource.LOCAL
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
                !selected.isDirectory || !selected.canWrite
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
            if (!state.imageImportEditorVisible || !selected.isDirectory || !selected.canRead
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
        if (!state.imageImportEditorVisible) return false
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
            if (!state.imageImportEditorVisible || selected.isDirectory || !selected.canRead
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
        if (!state.imageImportEditorVisible || draft.browserItems !is Loadable.Failed
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
        if (!state.imageImportEditorVisible) return false
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
            if (!state.imageImportEditorVisible) return false
            state.imageImportDraft?.toImportOrNull()
        } ?: return false
        val profileId = _workspace.value?.profile?.id ?: return false
        if (vmmTasks.conflictsWithImport(desired.imageName) || transferStore.virtualMachineImageImports(profileId).any { it.imageName.equals(desired.imageName, ignoreCase = true) &&
                !it.canRemoveFromHistory() }) return reportVmmImportNameBusy()
        if (!vmmTasks.startImport(desired)) return false
        closeVirtualMachineImageImportEditor()
        return true
    }

    private fun reportVmmImportNameBusy(): Boolean {
        val failure = vmmTasks.state.value.failure
        val message = if (failure is io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmFailure && failure.problem == io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmProblem.STORAGE) R.string.vm_storage else R.string.vm_image_import_name_busy
        _workspace.update { it?.copy(message = getApplication<Application>().getString(message)) }
        return false
    }

    fun confirmVirtualMachineLocalImageImport(
        submission: VirtualMachineLocalImageImportSubmission,
    ): Boolean {
        if (vmmTasks.state.value.active) return false
        if (vmmTasks.conflictsWithImport(submission.imageName)) return reportVmmImportNameBusy()
        val prepared = synchronized(virtualMachineMutationLock) {
            val current = _workspace.value ?: return false
            val state = current.virtualMachineMutationState
            val expected = state.imageImportDraft?.toLocalSubmissionOrNull()
            val uri = pendingVirtualMachineLocalImageUri
            if (!state.imageImportEditorVisible || expected != submission || uri == null
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
        val workId = if (checkTransferOwner(WorkspaceRecordKind.VMM_IMPORT, record.id, repository, create = true))
            VirtualMachineImageImportWorker.enqueue(getApplication(), record) else null
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

    fun checkNasSystemUpdate() {
        val repo = repository ?: return
        if (_workspace.value?.nasSystemUpdate is Loadable.Loading) return
        viewModelScope.launch {
            _workspace.update { it?.copy(nasSystemUpdate = Loadable.Loading) }
            suspendRunCatching { repo.checkSystemUpdate() }
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
                suspendRunCatching { repo.performanceSample() }
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

    fun switchNas(): Boolean = onConnectionsRequested?.invoke() ?: returnToLogin()
    internal fun requestSignIn(): Boolean = onSignInRequested?.invoke() ?: returnToLogin()

    internal fun canSwitchWorkspace(): Boolean = synchronized(downloadMutationCoordinatorLock) {
        val current = _workspace.value ?: return true
        if (isSwitchingNas) return false
        val blocked = workspaceSwitchIsBlocked(current, transferStore)
        if (blocked) _workspace.value = current.copy(message = getApplication<Application>().getString(R.string.switch_nas_blocked_active_operation))
        !blocked
    }

    internal fun refreshSavedProfiles() {
        val profiles = store.profiles()
        _login.update { it.copy(profiles = profiles) }
        val repo = repository ?: return
        if (runCatching { repo.requireCurrentOwner() }.isFailure) return
        _workspace.update { current -> current?.let { state -> profiles.firstOrNull { it.id == state.profile.id }
            ?.let { state.copy(profile = it) } ?: state } }
    }

    internal fun reportConnectionUnavailable() {
        val failure = io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure()
        if (_workspace.value == null) _login.update { it.copy(error = failure) }
        else _workspace.update { it?.copy(message = failure.localize(getApplication()).combined) }
    }

    internal fun canRemoveSavedConnection(profileId: String): Boolean =
        runCatching { fileRecovery.office.canRemoveProfile(profileId) }.getOrDefault(false) &&
        !(_login.value.selectedProfileId == profileId && _login.value.isConnecting) &&
            (_workspace.value?.profile?.id != profileId || canSwitchWorkspace() &&
                chatActions.state.value.items.none { it.busy } && chatBatches.state.value.items.none { it.busy } &&
                downloadActions.state.value.busy.isEmpty() && !downloadCreation.state.value.copying && !packageCenter.isActive && !nasDirectory.state.value.busy && !nasScheduledTasks.state.value.busy &&
                !chatVoice.state.value.recording && !chatVoice.state.value.saving)

    internal fun reportConnectionBusy() {
        val failure = DsmFailure(null, "An operation is still active", "Return to the connection and finish the operation.", kind = DsmErrorKind.WORKSPACE_BUSY)
        if (_workspace.value == null) _login.update { it.copy(error = failure) }
        else _workspace.update { it?.copy(message = failure.localize(getApplication()).combined) }
    }

    internal fun returnToLogin(): Boolean {
        val state = synchronized(downloadMutationCoordinatorLock) {
            val candidate = _workspace.value ?: return true
            if (isSwitchingNas) return false
            if (!canSwitchWorkspace()) return false
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
            virtualMachineOverviewRequestGeneration.incrementAndGet()
            virtualMachineTaskPollingGeneration.incrementAndGet()
            chatAttachmentPreflightGeneration.incrementAndGet()
            fileSearch.invalidate(); fileSharing.invalidate(); fileArchive.invalidate(); filePermissions.invalidate(); fileISOMounts.invalidate(); fileRemoteMounts.invalidate(); fileVFS.invalidate(); fileSettings.invalidate(); fileBackgroundTaskControls.invalidate(); crossNasTransfers.invalidate(); officeDocuments.invalidate()
            chatNotices.revoke(candidate.profile.id)
            repository?.invalidateAccess()
            repository = null
            clearPackageIconCache()
            crossNasRepositories.values.forEach(DsmRepository::invalidateAccess)
            crossNasRepositories.clear()
            _workspace.value = null
            candidate
        }
        cancelOpaqueExternalNavigation(consumePending = true)
        nasAdministrationFeature.clearForProfileSwitch()
        chatNotices.clear()
        chatFeature.clearForProfileSwitch()
        chatActions.clear()
        chatContent.clear()
        chatBatches.clear()
        chatVoice.clear()
        downloadActions.clear(); downloadCreation.clear(); vmmTasks.clear(); vmmConsole.clear(); vmmCreation.clear(); vmmSettings.clear(); vmmAssets.clear(); vmmControls.clear(); containerControls.clear(); containerImages.clear(); containerNetworks.clear(); packageCenter.clear(); nasDirectory.clear(); nasScheduledTasks.clear(); nasObservation.clear(); nasServices.clear(); nasRegion.clear(); nasDdns.clear(); nasPower.clear(); nasConnections.clear(); nasSmart.clear()
        containerReadFeature.invalidate()
        releasePendingVirtualMachineLocalImageGrant()
        chatPendingAttachmentUrisForRelease(state).forEach(::releasePersistedReadPermission)
        _login.update {
            it.copy(
                isConnecting = true,
                connectionStatus = null,
                error = null,
                needsOtp = false,
            )
        }
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            val switchingJob = currentCoroutineContext()[Job]
            val activeWorkspaceJobs = viewModelScope.coroutineContext[Job]
                ?.children
                ?.filter { child -> child !== switchingJob && child !== workspacePersistenceJob }
                ?.toList()
                .orEmpty()
            activeWorkspaceJobs.forEach(Job::cancel)
            activeWorkspaceJobs.forEach { child -> child.join() }

            transferCoordinator.clearForProfileSwitch()
            photoBackupCoordinator.clearForProfileSwitch()
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
            chatAttachmentPreviewJob = null
            thumbnailJobs.clear()
            thumbnailReferences.clear()
            thumbnailCache.evictAll()
            cleanupPreviewFile(state.preview)
            state.chatAttachmentPreviewVideoFile?.delete()
            cacheDirectories.clearPreviews()

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
        val owner = repository?.owner
        if (owner != null && runCatching { store.requireCurrentOwner(owner) }.isFailure) {
            reportConnectionUnavailable(); return
        }
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
            virtualMachineOverviewRequestGeneration.incrementAndGet()
            chatAttachmentPreflightGeneration.incrementAndGet()
            fileSearch.invalidate(); fileSharing.invalidate(); fileArchive.invalidate(); filePermissions.invalidate(); fileISOMounts.invalidate(); fileRemoteMounts.invalidate(); fileVFS.invalidate(); fileSettings.invalidate(); fileBackgroundTaskControls.invalidate(); crossNasTransfers.invalidate(); officeDocuments.invalidate()
            chatNotices.revoke(candidate.profile.id)
            repository?.invalidateAccess()
            repository = null
            clearPackageIconCache()
            crossNasRepositories.values.forEach(DsmRepository::invalidateAccess)
            crossNasRepositories.clear()
            _workspace.value = null
            candidate
        }
        cancelOpaqueExternalNavigation(consumePending = true)
        nasAdministrationFeature.clearForProfileSwitch()
        chatNotices.clear()
        chatFeature.clearForProfileSwitch()
        chatActions.clear()
        chatContent.clear()
        chatBatches.clear()
        chatVoice.clear()
        downloadActions.clear(); downloadCreation.clear(); vmmTasks.clear(); vmmConsole.clear(); vmmCreation.clear(); vmmSettings.clear(); vmmAssets.clear(); vmmControls.clear(); containerControls.clear(); containerImages.clear(); containerNetworks.clear(); packageCenter.clear(); nasDirectory.clear(); nasScheduledTasks.clear(); nasObservation.clear(); nasServices.clear(); nasRegion.clear(); nasDdns.clear(); nasPower.clear(); nasConnections.clear(); nasSmart.clear()
        containerReadFeature.invalidate()
        releasePendingVirtualMachineLocalImageGrant()
        chatPendingAttachmentUrisForRelease(state).forEach(::releasePersistedReadPermission)
        transferCoordinator.cancelAndClear()
        photoBackupCoordinator.clearForProfileSwitch()
        virtualMachineImageImportWatchJobs.values.forEach(Job::cancel)
        virtualMachineImageImportWatchJobs.clear()
        photoTimelineJob?.cancel()
        photoTimelineJob = null
        storageAnalysisJob?.cancel()
        storageAnalysisJob = null
        stopNasPerformanceSampling(resetPause = true)
        closeChatAttachmentPreview()
        transferStore.downloads(state.profile.id).forEach { download ->
            if (download.state.hasIncompleteDownloadDestination()) {
                download.workId?.let { runCatching { workManager.cancelWorkById(UUID.fromString(it)) } }
                deleteIncompleteDownload(Uri.parse(download.destinationUri), download.id)
                releasePersistedDownloadPermission(Uri.parse(download.destinationUri), download.id)
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
        if (owner != null) store.signOut(owner) else {
            store.clearSession(repoProfile.id)
            store.setAutoLoginEnabled(repoProfile.id, false)
        }
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

    private suspend fun refreshFavorites(repo: DsmRepository) {
        if (repo !== repository || !repo.supportsFavorites()) return
        suspendRunCatching { repo.listFavorites().mapTo(mutableSetOf()) { it.path } }
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
        fileSearch.cancelSearch()
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
            }?.copy(files = Loadable.Loading, fileIsLoadingMore = false, fileSearchCoverage = io.github.qwertyuiop1995.dsmnativeclient.domain.FileSearchIndexCoverage.NOT_REQUESTED)
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
        suspendRunCatching {
            // 目录基线只决定后续写入口是否可用，读取失败不能阻断原本可用的浏览。
            val directoryBaseline = browser.path.takeIf(String::isNotBlank)?.let { path ->
                suspendRunCatching { repo.fileInfo(path) }.getOrElse { error ->
                    if (error is CancellationException) throw error
                    null
                }
            }
            val result = if (browser.activeSearchQuery != null) fileSearch.search(repo, browser)
                else io.github.qwertyuiop1995.dsmnativeclient.domain.FileSearchResult(listFilePage(repo, browser, 0))
            directoryBaseline to result
        }.onSuccess { (directoryBaseline, result) ->
            val page = result.page
            _workspace.update { current ->
                current?.takeIf {
                    repo === repository &&
                    it.selectedModule == Module.FILES &&
                        it.fileBrowser.matchesFileBrowserRequest(
                            requestToken,
                            fileBrowserRequestGeneration.get(),
                        )
                }?.copy(
                    fileSearchCoverage = result.indexCoverage,
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
        suspendRunCatching {
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
        suspendRunCatching {
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
        suspendRunCatching {
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
        fileCopyMoveRepository(operation)?.let { it.requireCurrentOwner(); return it }
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
        return connections.restore(profile, session, makeLastProfile = false) {}.also {
            crossNasRepositories[profile.id] = it
        }
    }

    private suspend fun loadDownloadDestinationFolders(repo: DsmRepository, picker: DownloadDestinationPickerState) {
        suspendRunCatching {
            val items = mutableListOf<FileItem>()
            val seen = mutableSetOf<String>()
            var total: Int? = null
            while (true) {
                val page = if (picker.location.path.isEmpty()) repo.listShares(offset = items.size, limit = 500)
                    else repo.listDirectory(picker.location.path, offset = items.size, limit = 500, fileType = "dir")
                if (total == null) total = page.total
                if (page.total != total || page.offset != items.size || page.items.any { !seen.add(it.path) } || page.items.size > 500)
                    throw DsmFailure(null, "The folder list changed", "Refresh the folder and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
                items += page.items
                if (items.size == total) break
                if (page.items.isEmpty() || items.size > requireNotNull(total)) throw DsmFailure(null, "The folder list is incomplete", "Refresh the folder and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
            }
            FilePage(items, items.size, 0)
        }.onSuccess { page ->
            _workspace.update { current -> current?.takeIf { repository === repo && it.downloadDestinationPicker == picker }
                ?.copy(downloadDestinationFolders = Loadable.Ready(page)) ?: current }
        }.onFailure { error ->
            if (error is CancellationException) return@onFailure
            _workspace.update { current -> current?.takeIf { repository === repo && it.downloadDestinationPicker == picker }
                ?.copy(downloadDestinationFolders = Loadable.Failed(error.asDsmFailure())) ?: current }
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
        cacheDirectories.thumbnails

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
        val outcome = suspendRunCatching {
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
                    _workspace.update { current ->
                        if (repository === claim.repository && current?.profile?.id == claim.profileId)
                            current.copy(fileShareLinks = Loadable.Ready(links)) else current
                    }
                }
                FileStationMutationRefresh.TEXT_PREVIEW -> Unit
            }
            if (!claim.verifyOnRefresh) {
                FileStationMutationVerification.MATCHES to null
            } else if (claim.target.operation == FileStationMutationOperation.TEXT_SAVE) {
                verifyTextPreviewSave(claim.repository, claim.target)
            } else {
                _workspace.value.verifyFileStationMutation(claim.target, claim.repository::fileInfo) to null
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

    fun refreshDownloadCreationMutation() { downloadActions.show() }

    private fun serviceMutationResultMessage(
        result: MutationResult,
        @StringRes success: Int,
    ): String {
        val context = getApplication<Application>()
        return context.getString(serviceMutationMessageResource(result, success))
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
                    cacheDirectories.previews,
                    "preview-${UUID.randomUUID()}.$extension",
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
                    cacheDirectories.previews,
                    "preview-${UUID.randomUUID()}.$extension",
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
        cacheDirectories.clearPreviews()
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
        if (!checkTransferOwner(WorkspaceRecordKind.DOWNLOAD, record.id, repository)) {
            transferStore.update(record.id) { it.copy(state = TransferState.PAUSED, errorKind = DsmErrorKind.WORKSPACE_CHANGED.name) }
            return
        }
        workManager.enqueueUniqueWork(
            FileDownloadWorker.UNIQUE_WORK_PREFIX + record.id,
            existingWorkPolicy,
            request,
        )
        monitorDownload(record.id, request.id)
        syncPersistedDownloads(record.profileId)
    }

    private fun enqueuePhotoBackup(record: PersistedUpload) {
        if (!checkTransferOwner(WorkspaceRecordKind.UPLOAD, record.id, repository)) {
            transferStore.updateUpload(record.id) { it.copy(state = TransferState.PAUSED, errorKind = DsmErrorKind.WORKSPACE_CHANGED.name) }
            return
        }
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
        if (!checkTransferOwner(WorkspaceRecordKind.UPLOAD, record.id, repository)) {
            transferStore.updateUpload(record.id) { it.copy(state = TransferState.PAUSED, errorKind = DsmErrorKind.WORKSPACE_CHANGED.name) }
            return
        }
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
        val sourceId = source.sourceId ?: return false
        if (!checkTransferOwner(WorkspaceRecordKind.PHOTO_SOURCE, sourceId, repository)) return false
        val input = workDataOf(PhotoBackupScanWorker.KEY_PROFILE_ID to profileId, PhotoBackupScanWorker.KEY_SOURCE_ID to sourceId)
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
        photoBackupCoordinator.cancelObservation(profileId)
        val scheduleGeneration = photoBackupCoordinator.nextScheduleGeneration()
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
            if (!photoBackupCoordinator.isCurrentSourceSchedule(
                    source,
                    scheduleGeneration,
                    transferStore.photoBackupSource(source.profileId),
                )
            ) {
                reconcilePhotoBackupSourceScheduleAttention(source)
                return@launch
            }
            if (actualPeriodicWorkId == null) {
                photoBackupCoordinator.cancelSourceWork(workManager, profileId)
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
                photoBackupCoordinator.cancelSourceWork(workManager, profileId)
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
        photoBackupCoordinator.cancelSourceWork(workManager, expected.profileId)
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
        val profileId = source.profileId
        val generation = photoBackupCoordinator.beginObservation(profileId)
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
        photoBackupCoordinator.attachObservation(profileId, generation, job)
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
                observationIsCurrent = photoBackupCoordinator.isCurrentObservation(
                    source.profileId,
                    generation,
                ),
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
                    photoBackupCoordinator.cancelSourceWork(workManager, source.profileId)
                }

                PhotoBackupScanFailureDecision.SHOW_SOURCE_STATE_UNAVAILABLE -> {
                    _workspace.update { current ->
                        current?.takeIf { it.profile.id == source.profileId }?.copy(
                            message = getApplication<Application>().getString(
                                R.string.photo_backup_source_state_unavailable,
                            ),
                        ) ?: current
                    }
                    photoBackupCoordinator.cancelObservation(source.profileId, generation)
                }

                PhotoBackupScanFailureDecision.IGNORE -> Unit
            }
            if (workInfo.state.isFinished) {
                currentCoroutineContext()[Job]?.cancel()
            }
        }
    }

    private fun enqueueForegroundDownload(
        repo: DsmRepository,
        record: PersistedDownload,
        destination: Uri,
        requireExactResume: Boolean = false,
    ) {
        lateinit var executionId: String
        fun ownsExecution(): Boolean =
            transferCoordinator.isCurrentForegroundDownloadExecution(record.id, executionId)
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
                val written = executeFileDownload(getApplication(), repo, record, transferStore, requireExactResume,
                    requireActive = {
                        if (!ownsExecution() || transferStore.download(record.id)?.state != TransferState.RUNNING)
                            throw CancellationException("Download execution changed")
                    },
                    onReset = { transferStore.update(record.id) { current ->
                        if (ownsExecution()) current.copy(completedBytes = 0, totalBytes = current.expectedBytes) else current
                    } },
                ) { completed, total ->
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
                val completed = transferStore.update(record.id) { current ->
                    if (!ownsExecution() || current.state != TransferState.RUNNING) {
                        current
                    } else {
                        current.copy(
                            state = TransferState.SUCCEEDED,
                            completedBytes = written,
                            totalBytes = written,
                            errorKind = null,
                        )
                    }
                }
                if (ownsExecution() && completed?.state == TransferState.SUCCEEDED) {
                    releasePersistedDownloadPermission(destination, record.id)
                    TransferNotifications.completion(getApplication(), record.id, succeeded = true)
                    _workspace.update {
                        it?.copy(message = getApplication<Application>().getString(R.string.download_completed))
                    }
                }
            } catch (_: CancellationException) {
                val current = transferStore.download(record.id)
                if (current != null && shouldDeleteCancelledDownload(
                        current.state,
                        executionId.takeIf { ownsExecution() },
                        executionId,
                    )
                ) {
                    deleteIncompleteDownload(destination, record.id)
                    releasePersistedDownloadPermission(destination, record.id)
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
                        current.copy(state = if (kind == DsmErrorKind.WORKSPACE_CHANGED) TransferState.PAUSED else TransferState.FAILED, errorKind = kind.name)
                    }
                }
                if (ownsExecution() && failed?.state == TransferState.FAILED) {
                    if (shouldDeleteFailedForegroundDownload(failed, ownsExecution = true)) {
                        deleteIncompleteDownload(destination, record.id)
                        releasePersistedDownloadPermission(destination, record.id)
                    }
                    TransferNotifications.completion(getApplication(), record.id, succeeded = false)
                }
            } finally {
                syncPersistedDownloads(record.profileId)
            }
        }
        executionId = transferCoordinator.beginForegroundDownload(record.id)
        transferCoordinator.registerForegroundTask(record.id, job, beforeRemoval = {
            var finalizedCancellation = false
            val cancelled = transferStore.update(record.id) { current ->
                val next = current.finalizeForegroundDownloadCancellation(
                    ownsExecution = ownsExecution(),
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
                deleteIncompleteDownload(destination, record.id)
                releasePersistedDownloadPermission(destination, record.id)
                syncPersistedDownloads(cancelled.profileId)
            }
        }, afterRemoval = {
            transferCoordinator.clearForegroundDownloadExecution(record.id, executionId)
        })
        job.start()
    }

    private fun restoreDownloads(profileId: String) {
        transferCoordinator.cancelWorkObservations()
        transferStore.downloads(profileId).forEach { record ->
            val workId = record.workId?.let { value ->
                runCatching { UUID.fromString(value) }.getOrNull()
            }
            if (record.state == TransferState.PAUSED) {
                Unit
            } else if (workId != null && record.state !in TERMINAL_TRANSFER_STATES) {
                restorePersistedBackgroundDownload(profileId, record, workId)
            } else if (workId == null && (record.isArchiveDownload || record.isVFSDownload) && record.state !in TERMINAL_TRANSFER_STATES) {
                transferStore.update(record.id) { it.copy(state = TransferState.PAUSED) }
            } else if (workId == null && record.state !in TERMINAL_TRANSFER_STATES) {
                val destination = Uri.parse(record.destinationUri)
                deleteIncompleteDownload(destination, record.id)
                releasePersistedDownloadPermission(destination, record.id)
                transferStore.update(record.id) {
                    it.copy(state = TransferState.FAILED, errorKind = DsmErrorKind.DOWNLOAD_FAILED.name)
                }
            }
        }
        transferStore.uploads(profileId).forEach { record ->
            if (folderUploads.isFolder(record.id)) { folderUploads.restore(record); return@forEach }
            if (record.state == TransferState.PAUSED) return@forEach
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
            if (record.state in TERMINAL_TRANSFER_STATES || record.state == TransferState.PAUSED) return@forEach
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
        if (!checkTransferOwner(WorkspaceRecordKind.SERVER, record.id, repo)) return
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
                    expectedOutputs = transferStore.extractionOutputs(record),
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
        transferCoordinator.registerForegroundTask(record.id, job)
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
        if (!checkTransferOwner(WorkspaceRecordKind.VMM_IMPORT, id, repository)) return false
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
            workManager.getWorkInfoByIdFlow(workId).filterNotNull().collectLatest { info ->
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

    private fun releaseVirtualMachineLocalImageGrant(uri: Uri) { transferUris.releaseRead(uri) }

    private fun monitorUpload(taskId: String, workId: UUID) = transferCoordinator.observeUpload(
        viewModelScope, workManager, transferStore, taskId, workId, ::syncPersistedDownloads,
    )

    private fun monitorDownload(taskId: String, workId: UUID) {
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            workManager.getWorkInfoByIdFlow(workId).filterNotNull().collectLatest { info ->
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
                    transferCoordinator.removeWorkObservation(
                        taskId,
                        currentCoroutineContext()[Job],
                    )
                    currentCoroutineContext()[Job]?.cancel()
                }
            }
        }
        transferCoordinator.replaceWorkObservation(taskId, job)
        job.start()
    }

    private fun syncPersistedDownloads(profileId: String) {
        val downloads = transferStore.downloads(profileId).map(transferPresentation::download)
        val uploads = transferStore.uploads(profileId).map(transferPresentation::upload)
        val servers = transferStore.servers(profileId)
            .sortedByDescending(PersistedServerTransfer::startedAtEpochMillis)
            .mapNotNull(transferPresentation::server)
        val persistedIds = (downloads + uploads + servers).mapTo(mutableSetOf(), TransferTask::id)
        _workspace.update { current ->
            current?.takeIf { it.profile.id == profileId }?.copy(
                transfers = servers + uploads + downloads +
                    current.transfers.filterNot { it.id in persistedIds },
            ) ?: current
        }
    }

    private fun deleteIncompleteDownload(uri: Uri, excludingRecordId: String? = null) = transferUris.deleteIncomplete(uri, excludingRecordId)
    private fun releasePersistedReadPermission(uri: Uri) { transferUris.releaseRead(uri) }
    private fun releasePersistedDownloadPermission(uri: Uri, excludingRecordId: String? = null) = transferUris.releaseDownload(uri, excludingRecordId)

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
    ): Boolean {
        val repo = repository ?: return false
        val taskId = if (target.operation == FileServerMutationOperation.EXTRACT) io.github.qwertyuiop1995.dsmnativeclient.data.newFileExtractionId() else UUID.randomUUID().toString()
        val application = getApplication<Application>()
        val generation = fileServerMutationGeneration.incrementAndGet()
        val startedAt = System.currentTimeMillis()
        val claim = synchronized(fileStationMutationLock) {
            val current = _workspace.value ?: return false
            if (repository !== repo || current.selectedModule != Module.FILES || current.isPerformingAction ||
                fileStationMutationBlocksOrdinaryLoad(current.fileStationMutationState)) return false
            if (transferStore.servers(current.profile.id).any { previous ->
                !previous.canRemoveFinishedServer() && taskOwnership.canUse(WorkspaceRecordKind.SERVER, previous.id, repo) &&
                    previous.toFileServerMutationTarget()?.let(target::overlapsArchiveTarget) == true
            }) return false
            val persisted = target.toPersistedServerTransfer(
                id = taskId,
                title = title,
                state = TransferState.RUNNING,
                submissionPhase = PersistedServerSubmissionPhase.PREPARING,
                startedAtEpochMillis = startedAt,
            ).copy(executionGeneration = generation)
            if (!checkTransferOwner(WorkspaceRecordKind.SERVER, taskId, repo, create = true) ||
                runCatching { transferStore.upsert(persisted) }.isFailure) {
                _workspace.value = current.copy(
                    message = application.getString(R.string.server_transfer_state_unavailable),
                )
                return false
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
                        val active = checkNotNull(transferStore.server(taskId))
                        if (target.operation == FileServerMutationOperation.EXTRACT) transferStore.extractionOutputs(active)
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
                        repo.requireCurrentOwner()
                        check(repository === repo) { "transfer.server_state_not_persisted" }
                        checkNotNull(transferStore.updateExtractionOutputs(taskId, generation, outputs)) { "transfer.server_state_not_persisted" }
                        syncPersistedDownloads(claim.profileId)
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
        transferCoordinator.registerForegroundTask(taskId, job)
        job.start()
        return true
    }

    private fun updateServerTransfer(
        claim: FileServerTransferClaim,
        taskId: String,
        transform: (TransferTask) -> TransferTask,
    ) {
        val current = transferStore.server(taskId) ?: return
        val projected = transferPresentation.server(current) ?: return
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
        update(captureLoadable(block))
    }

    override fun onCleared() {
        fileSearch.invalidate(); fileSharing.invalidate(); fileArchive.invalidate(); filePermissions.invalidate(); fileISOMounts.invalidate(); fileRemoteMounts.invalidate(); fileVFS.invalidate(); fileSettings.invalidate(); fileBackgroundTaskControls.invalidate(); crossNasTransfers.invalidate(); officeDocuments.invalidate()
        repository?.invalidateAccess()
        crossNasRepositories.values.forEach(DsmRepository::invalidateAccess)
        repository = null
        releasePendingVirtualMachineLocalImageGrant()
        nasAdministrationFeature.clearForProfileSwitch()
        chatNotices.clear()
        chatFeature.clearForProfileSwitch()
        chatActions.clear()
        chatContent.clear()
        chatBatches.clear()
        chatVoice.clear()
        downloadActions.clear(); downloadCreation.clear(); vmmTasks.clear(); vmmConsole.clear(); vmmCreation.clear(); vmmSettings.clear(); vmmAssets.clear(); vmmControls.clear(); containerControls.clear(); containerImages.clear(); containerNetworks.clear(); packageCenter.clear(); nasDirectory.clear(); nasScheduledTasks.clear(); nasObservation.clear(); nasServices.clear(); nasRegion.clear(); nasDdns.clear(); nasPower.clear(); nasConnections.clear(); nasSmart.clear()
        containerReadFeature.invalidate()
        photoBackupCoordinator.clearForProfileSwitch()
        super.onCleared()
    }
}
