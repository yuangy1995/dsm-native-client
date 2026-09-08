package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedPhotoBackupSource
import io.github.qwertyuiop1995.dsmnativeclient.data.toFileBackgroundTaskPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.*

/** 两种登录路径共用原有能力与本机恢复状态的装配，不请求网络、不保存凭据。 */
internal fun connectedWorkspace(
    profile: NasProfile,
    repo: DsmRepository,
    availability: List<ModuleAvailability>,
    restoredUi: Pair<Module, FileBrowserState>,
    backgroundTaskSnapshot: io.github.qwertyuiop1995.dsmnativeclient.data.PersistedFileBackgroundTaskSnapshot?,
    photoBackupSource: PersistedPhotoBackupSource?,
    backupRestoreMessage: String?,
    pinnedConversationIds: List<String>,
): WorkspaceState = WorkspaceState(
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
    message = backupRestoreMessage,
    chatPinnedConversationIds = pinnedConversationIds,
    fileBackgroundTasks = backgroundTaskSnapshot?.toFileBackgroundTaskPage()
        ?.let { Loadable.Ready(it) } ?: Loadable.Idle,
    fileBackgroundTaskSnapshotObservedAtEpochSeconds =
        backgroundTaskSnapshot?.observedAtEpochSeconds,
)
