package io.github.qwertyuiop1995.dsmnativeclient

import android.net.Uri
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File

internal enum class FileBackgroundTaskRequestKind { REFRESH, LOAD_MORE }

/** 仅保存 VMM 固定分区枚举，供可见性控制和无载荷深页投影使用。 */
enum class VirtualMachineTab {
    MACHINES,
    HOSTS,
    STORAGES,
    NETWORKS,
    IMAGES,
    PROTECTION,
    LOGS,
    TASKS,
}

/** 仅保存 NAS 设置固定分区枚举，供性能深页和返回层级使用。 */
enum class NasSettingsTab {
    OVERVIEW,
    PERFORMANCE,
    STORAGE,
    PACKAGES,
    ACCOUNT,
    LOGS,
    CONNECTIONS,
    SERVICES,
    REGION_AND_TIME,
    NETWORKS,
    SECURITY,
    HARDWARE_AND_POWER,
    SCHEDULED_TASKS,
    PROCESSES,
}

internal data class FileBackgroundTaskRequestToken(
    val profileId: String,
    val generation: Long,
    val offset: Int,
    val kind: FileBackgroundTaskRequestKind,
)

/** 性能读取、能力与固定页签共用单一内存状态，避免继续扩大超长 WorkspaceState 构造参数。 */
data class NasPerformanceWorkspaceState(
    val history: List<PerformanceSample> = emptyList(),
    val isLoading: Boolean = false,
    val error: DsmFailure? = null,
    val isPaused: Boolean = false,
    val supportsPerformance: Boolean = false,
    val selectedTab: NasSettingsTab = NasSettingsTab.OVERVIEW,
)

internal data class NasPerformanceRequestToken(
    val generation: Long,
    val profileId: String,
)

internal fun WorkspaceState.matchesNasPerformanceRequest(
    token: NasPerformanceRequestToken,
    currentGeneration: Long,
    repositoryMatches: Boolean,
    isVisible: Boolean,
): Boolean = repositoryMatches && isVisible && token.generation == currentGeneration &&
    profile.id == token.profileId && selectedModule == Module.NAS_SETTINGS &&
    nasPerformance.selectedTab == NasSettingsTab.PERFORMANCE && !nasPerformance.isPaused

internal fun fileBackgroundTaskCallbackMatches(
    repositoryMatches: Boolean,
    selectedModule: Module,
    currentProfileId: String,
    token: FileBackgroundTaskRequestToken,
    currentGeneration: Long,
): Boolean = repositoryMatches && selectedModule == Module.TRANSFERS &&
    currentProfileId == token.profileId && currentGeneration == token.generation

internal fun appendFileBackgroundTaskPage(
    current: FileBackgroundTaskPage,
    incoming: FileBackgroundTaskPage,
    expectedOffset: Int,
): FileBackgroundTaskPage? {
    if (current.nextOffset != expectedOffset || incoming.offset != expectedOffset) return null
    val seenIds = current.tasks.mapTo(mutableSetOf(), FileBackgroundTaskSummary::id)
    val appended = incoming.tasks.filter { seenIds.add(it.id) }
    return FileBackgroundTaskPage(
        tasks = current.tasks + appended,
        offset = current.offset,
        nextOffset = incoming.nextOffset,
        total = maxOf(current.tasks.size + appended.size, incoming.total),
        hasMore = incoming.hasMore,
    )
}

data class DownloadAdvancedReadWorkspaceState(
    val downloadDetails: Loadable<DownloadTask> = Loadable.Idle,
    val downloadListFailure: DsmFailure? = null,
    val downloadListRefreshing: Boolean = false,
    val downloadLastTasks: List<DownloadTask>? = null,
    val supportsActivity: Boolean = false,
    val activity: Loadable<DownloadStationActivity> = Loadable.Idle,
    val discoveryVisible: Boolean = false,
    val discoveryTab: DownloadDiscoveryTab = DownloadDiscoveryTab.RSS,
    val btSearchCatalog: Loadable<DownloadBtSearchCatalog> = Loadable.Idle,
    val btAdvancedOptionsVisible: Boolean = false,
    val btSearchOptions: DownloadBtSearchOptions = DownloadBtSearchOptions(),
    val btSearchResults: Loadable<List<DownloadBtSearchResult>> = Loadable.Idle,
)

/** BT 搜索只能提交当前已加载目录仍能解释的选项，避免目录刷新后发送陈旧标识。 */
internal fun canSubmitDownloadBtSearch(
    catalogState: Loadable<DownloadBtSearchCatalog>,
    options: DownloadBtSearchOptions,
    resultsState: Loadable<List<DownloadBtSearchResult>>,
): Boolean {
    val catalog = (catalogState as? Loadable.Ready)?.value ?: return false
    if (catalog.modules.isEmpty() || options.keyword.isBlank() || resultsState is Loadable.Loading) {
        return false
    }
    val moduleIds = catalog.modules.mapTo(mutableSetOf(), DownloadBtSearchModule::id)
    if (!moduleIds.containsAll(options.selectedModuleIds)) return false
    when (options.moduleScope) {
        DownloadBtSearchModuleScope.SELECTED -> if (options.selectedModuleIds.isEmpty()) return false
        DownloadBtSearchModuleScope.ALL -> if (options.selectedModuleIds.isNotEmpty()) return false
        DownloadBtSearchModuleScope.ENABLED -> if (
            options.selectedModuleIds.isNotEmpty() || catalog.modules.none(DownloadBtSearchModule::enabled)
        ) return false
    }
    return options.categoryId == null || catalog.categories.any { it.id == options.categoryId }
}

data class WorkspaceState(
    val profile: NasProfile,
    val selectedModule: Module = Module.FILES,
    val availability: List<ModuleAvailability> = emptyList(),
    val access: WorkspaceAccessUiState = WorkspaceAccessUiState(),
    val files: Loadable<FilePage> = Loadable.Idle,
    val fileSearchCoverage: io.github.qwertyuiop1995.dsmnativeclient.domain.FileSearchIndexCoverage = io.github.qwertyuiop1995.dsmnativeclient.domain.FileSearchIndexCoverage.NOT_REQUESTED,
    val fileBrowser: FileBrowserState = FileBrowserState(),
    val fileDirectoryBaselines: Map<String, FileItem> = emptyMap(),
    val fileIsLoadingMore: Boolean = false,
    val fileCopyMove: FileCopyMoveState? = null,
    val fileCopyMoveFolders: Loadable<FilePage> = Loadable.Idle,
    val fileStationMutationState: FileStationMutationWorkspaceState =
        FileStationMutationWorkspaceState(),
    val pendingFileUploads: PendingFileUploads? = null,
    val fileFavorites: Loadable<List<FileItem>> = Loadable.Idle,
    val fileRecentLocations: Loadable<List<FileItem>> = Loadable.Idle,
    val fileShareLinks: Loadable<List<FileShareLink>> = Loadable.Idle,
    val photos: Loadable<PhotoPage> = Loadable.Idle,
    val photoTimeline: Loadable<PhotoTimelineProgress> = Loadable.Idle,
    val photoBrowser: PhotoBrowserState = PhotoBrowserState(),
    val photoViewer: PhotoViewerState? = null,
    val photoMove: PhotoMoveState? = null,
    val photoMoveFolders: Loadable<PhotoPage> = Loadable.Idle,
    val supportsFavorites: Boolean = false,
    val supportsUploads: Boolean = false,
    val supportsThumbnails: Boolean = false,
    val supportsCopyMove: Boolean = false,
    val supportsSharing: Boolean = false,
    val supportsCompression: Boolean = false,
    val supportsExtraction: Boolean = false,
    val supportsDownloadSettings: Boolean = false,
    val supportsDownloadSchedule: Boolean = false,
    val supportsDownloadTaskDestinationEditing: Boolean = false,
    val supportsDownloadRss: Boolean = false,
    val supportsDownloadBtSearch: Boolean = false,
    val supportsChatReminders: Boolean = false,
    val supportsChatScheduledMessages: Boolean = false,
    val supportsChatPollCreation: Boolean = false,
    val photoBackupSourceEnabled: Boolean = false,
    val favoritePaths: Set<String> = emptySet(),
    val downloads: Loadable<List<DownloadTask>> = Loadable.Idle,
    val downloadAdvancedRead: DownloadAdvancedReadWorkspaceState =
        DownloadAdvancedReadWorkspaceState(),
    val downloadCreationState: DownloadCreationWorkspaceState = DownloadCreationWorkspaceState(),
    val downloadControlState: DownloadControlWorkspaceState = DownloadControlWorkspaceState(),
    val downloadDestinationEditState: DownloadDestinationEditWorkspaceState =
        DownloadDestinationEditWorkspaceState(),
    val downloadDetailsTask: DownloadTask? = null,
    val downloadSettings: Loadable<DownloadSettings> = Loadable.Idle,
    val downloadSettingsState: DownloadSettingsWorkspaceState = DownloadSettingsWorkspaceState(),
    val downloadRssSites: Loadable<List<DownloadRssSite>> = Loadable.Idle,
    val selectedDownloadRssSite: DownloadRssSite? = null,
    val downloadRssFeeds: Loadable<List<DownloadRssFeed>> = Loadable.Idle,
    val downloadRssRefreshState: DownloadRssRefreshWorkspaceState =
        DownloadRssRefreshWorkspaceState(),
    val downloadDestinationPicker: DownloadDestinationPickerState? = null,
    val downloadDestinationFolders: Loadable<FilePage> = Loadable.Idle,
    val containers: Loadable<ContainerOverview> = Loadable.Idle,
    val supportsContainerRegistry: Boolean = false,
    val supportsOfficialVirtualMachineCreation: Boolean = false,
    val supportsOfficialVirtualMachineSettings: Boolean = false,
    val supportsOfficialVirtualMachineImageImport: Boolean = false,
    val containerRegistryVisible: Boolean = false,
    val containerRegistryQuery: String = "",
    val containerRegistryResults: Loadable<List<ContainerRegistryImage>> = Loadable.Idle,
    val selectedContainerRegistryImage: ContainerRegistryImage? = null,
    val containerRegistryTags: Loadable<List<String>> = Loadable.Idle,
    val virtualMachines: Loadable<VirtualMachineOverview> = Loadable.Idle,
    val virtualMachineMutationState: VirtualMachineMutationWorkspaceState =
        VirtualMachineMutationWorkspaceState(),
    val chatMutationState: ChatMutationWorkspaceState = ChatMutationWorkspaceState(),
    val conversations: Loadable<List<ChatConversation>> = Loadable.Idle,
    val chatPinnedConversationIds: List<String> = emptyList(),
    val selectedConversation: ChatConversation? = null,
    val chatUsers: Loadable<List<ChatUser>> = Loadable.Idle,
    val chatNewConversationVisible: Boolean = false,
    val chatSelectedUserIds: Set<String> = emptySet(),
    val chatGroupTitle: String = "",
    val chatMembers: Loadable<List<ChatUser>> = Loadable.Idle,
    val chatMembersVisible: Boolean = false,
    val chatReminders: Loadable<List<ChatReminder>> = Loadable.Idle,
    val chatRemindersVisible: Boolean = false,
    val chatScheduledMessages: Loadable<List<ChatScheduledMessage>> = Loadable.Idle,
    val chatScheduledMessagesVisible: Boolean = false,
    val chatScheduleComposerVisible: Boolean = false,
    val chatScheduleDraft: String = "",
    val chatScheduleSendAtEpochMillis: Long? = null,
    val chatPollComposerVisible: Boolean = false,
    val chatPollQuestion: String = "",
    val chatPollOptions: List<String> = listOf("", ""),
    val chatPollAllowsMultiple: Boolean = false,
    val chatPollIsAnonymous: Boolean = false,
    val chatMessages: Loadable<ChatMessagePage> = Loadable.Idle,
    val chatIsLoadingMore: Boolean = false,
    val chatDrafts: Map<String, String> = emptyMap(),
    val chatOutgoingMessages: Map<String, List<ChatMessage>> = emptyMap(),
    val chatPendingAttachmentUris: Map<String, Uri> = emptyMap(),
    val chatAttachmentThumbnails: Map<String, Loadable<ByteArray>> = emptyMap(),
    val chatAttachmentPreviewName: String? = null,
    val chatAttachmentPreviewBytes: ByteArray? = null,
    val chatAttachmentPreviewVideoFile: File? = null,
    val chatAttachmentPreviewIsVideo: Boolean = false,
    val chatAttachmentPreviewIsAudio: Boolean = false,
    val chatAttachmentPreviewIsLoading: Boolean = false,
    val chatAttachmentPreviewProgress: Float? = null,
    val chatAttachmentPreviewError: String? = null,
    val nasSettings: Loadable<NasSettingsSnapshot> = Loadable.Idle,
    val nasPerformance: NasPerformanceWorkspaceState = NasPerformanceWorkspaceState(),
    val fileServiceSettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings? = null,
    val fileServiceMutationInProgress: Boolean = false,
    val fileServiceMutationResult: MutationResult? = null,
    val fileServiceMutationFailure: DsmFailure? = null,
    val fileServiceMutationRefreshCompleted: Boolean = false,
    val terminalSettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings? = null,
    val terminalMutationInProgress: Boolean = false,
    val terminalMutationResult: MutationResult? = null,
    val terminalMutationFailure: DsmFailure? = null,
    val terminalMutationRefreshCompleted: Boolean = false,
    val proxySettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings? = null,
    val proxyMutationInProgress: Boolean = false,
    val proxyMutationResult: MutationResult? = null,
    val proxyMutationFailure: DsmFailure? = null,
    val proxyMutationRefreshCompleted: Boolean = false,
    val regionSettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings? = null,
    val regionMutationInProgress: Boolean = false,
    val regionMutationResult: MutationResult? = null,
    val regionMutationFailure: DsmFailure? = null,
    val regionMutationRefreshCompleted: Boolean = false,
    val remoteAccessState: RemoteAccessWorkspaceState = RemoteAccessWorkspaceState(),
    val ethernetBaseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface? = null,
    val ethernetSettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface? = null,
    val ethernetEditorVisible: Boolean = false,
    val ethernetConfirmationRequested: Boolean = false,
    val ethernetMutationInProgress: Boolean = false,
    val ethernetMutationResult: MutationResult? = null,
    val ethernetMutationFailure: DsmFailure? = null,
    val ethernetMutationRefreshFailure: DsmFailure? = null,
    val ethernetMutationRefreshInProgress: Boolean = false,
    val ethernetMutationRefreshCompleted: Boolean = false,
    val ddnsBaseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord? = null,
    val ddnsSettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft? = null,
    val ddnsEditorVisible: Boolean = false,
    val ddnsConfirmationOperation: DdnsMutationOperation? = null,
    val ddnsDeleteTarget: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord? = null,
    val ddnsAddressRefreshTargetProviderIds: Set<String> = emptySet(),
    val ddnsAddressRefreshTargets: List<io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord> = emptyList(),
    val ddnsMutationOperation: DdnsMutationOperation? = null,
    val ddnsMutationTargetProviderId: String? = null,
    val ddnsMutationInProgress: Boolean = false,
    val ddnsMutationResult: MutationResult? = null,
    val ddnsMutationFailure: DsmFailure? = null,
    val ddnsMutationRefreshFailure: DsmFailure? = null,
    val ddnsMutationRefreshInProgress: Boolean = false,
    val ddnsMutationRefreshCompleted: Boolean = false,
    val securitySettingsBaseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings? = null,
    val securitySettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings? = null,
    val securitySettingsEditorVisible: Boolean = false,
    val securitySettingsConfirmationRequested: Boolean = false,
    val securitySettingsMutationInProgress: Boolean = false,
    val securitySettingsMutationResult: MutationResult? = null,
    val securitySettingsMutationFailure: DsmFailure? = null,
    val securitySettingsMutationRefreshFailure: DsmFailure? = null,
    val securitySettingsMutationRefreshInProgress: Boolean = false,
    val securitySettingsMutationRefreshCompleted: Boolean = false,
    val securitySettingsMutationGeneration: Long = 0L,
    val hardwareSettingsBaseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings? = null,
    val hardwareSettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings? = null,
    val hardwareSettingsEditorVisible: Boolean = false,
    val hardwareSettingsConfirmationRequested: Boolean = false,
    val hardwareSettingsMutationInProgress: Boolean = false,
    val hardwareSettingsMutationResult: MutationResult? = null,
    val hardwareSettingsMutationFailure: DsmFailure? = null,
    val hardwareSettingsMutationRefreshFailure: DsmFailure? = null,
    val hardwareSettingsMutationRefreshInProgress: Boolean = false,
    val hardwareSettingsMutationRefreshCompleted: Boolean = false,
    val hardwareSettingsMutationGeneration: Long = 0L,
    val packageMutationTarget: PackageInfo? = null,
    val packageMutationOperation: PackageMutationOperation? = null,
    val packageMutationConfirmationRequested: Boolean = false,
    val packageMutationInProgress: Boolean = false,
    val packageMutationResult: MutationResult? = null,
    val packageMutationFailure: DsmFailure? = null,
    val packageMutationRefreshFailure: DsmFailure? = null,
    val packageMutationRefreshInProgress: Boolean = false,
    val packageMutationRefreshCompleted: Boolean = false,
    val packageMutationGeneration: Long = 0L,
    val directoryMutationTarget: DirectoryEntryMutationTarget? = null,
    val directoryMutationConfirmationRequested: Boolean = false,
    val directoryMutationInProgress: Boolean = false,
    val directoryMutationResult: MutationResult? = null,
    val directoryMutationFailure: DsmFailure? = null,
    val directoryMutationRefreshFailure: DsmFailure? = null,
    val directoryMutationRefreshInProgress: Boolean = false,
    val directoryMutationRefreshCompleted: Boolean = false,
    val directoryMutationGeneration: Long = 0L,
    val nasSystemUpdate: Loadable<NasSystemUpdateInfo> = Loadable.Idle,
    val storageAnalysis: Loadable<StorageAnalysisSnapshot> = Loadable.Idle,
    val storageAnalysisProgress: StorageAnalysisProgress? = null,
    val diskTestStatuses: Map<String, Loadable<NasDiskTestStatus>> = emptyMap(),
    val diskTestMutationTarget: NasStorageDisk? = null,
    val diskTestMutationBaseline: NasDiskTestStatus? = null,
    val diskTestMutationOperation: NasDiskTestType? = null,
    val diskTestMutationConfirmationRequested: Boolean = false,
    val diskTestMutationInProgress: Boolean = false,
    val diskTestMutationResult: MutationResult? = null,
    val diskTestMutationFailure: DsmFailure? = null,
    val diskTestMutationRefreshFailure: DsmFailure? = null,
    val diskTestMutationRefreshInProgress: Boolean = false,
    val diskTestMutationRefreshCompleted: Boolean = false,
    val diskTestMutationGeneration: Long = 0L,
    val transfers: List<TransferTask> = emptyList(),
    val fileBackgroundTasks: Loadable<FileBackgroundTaskPage> = Loadable.Idle,
    val fileBackgroundTaskSnapshotObservedAtEpochSeconds: Long? = null,
    val fileBackgroundTaskRefreshInProgress: Boolean = false,
    val fileBackgroundTaskRefreshFailure: DsmFailure? = null,
    val fileBackgroundTaskIsLoadingMore: Boolean = false,
    val fileBackgroundTasksLoadMoreFailure: DsmFailure? = null,
    val previewItem: FileItem? = null,
    val preview: Loadable<FilePreviewContent> = Loadable.Idle,
    val previewOwner: PreviewOwner? = null,
    val filePreviewSequence: FilePreviewSequence? = null,
    val textPreviewDraft: String? = null,
    val previewDiscardConfirmationVisible: Boolean = false,
    val previewDiscardClosesPreview: Boolean = true,
    val thumbnailGeneration: Int = 0,
    val isPerformingAction: Boolean = false,
    val message: String? = null,
    val regenerableCacheBytes: Long = 0,
) {
    val downloadDetails: Loadable<DownloadTask> get() = downloadAdvancedRead.downloadDetails
    val downloadListFailure: DsmFailure? get() = downloadAdvancedRead.downloadListFailure
    val downloadListRefreshing: Boolean get() = downloadAdvancedRead.downloadListRefreshing
    val downloadLastTasks: List<DownloadTask>? get() = downloadAdvancedRead.downloadLastTasks

    val remoteAccessSettingsBaseline get() = remoteAccessState.settingsBaseline
    val remoteAccessSettingsDraft get() = remoteAccessState.settingsDraft
    val remoteAccessEditorVisible get() = remoteAccessState.editorVisible
    val remoteAccessConfirmationRequested get() = remoteAccessState.confirmationRequested
    val remoteAccessMutationInProgress get() = remoteAccessState.mutationInProgress
    val remoteAccessMutationResult get() = remoteAccessState.mutationResult
    val remoteAccessMutationFailure get() = remoteAccessState.mutationFailure
    val remoteAccessMutationRefreshFailure get() = remoteAccessState.mutationRefreshFailure
    val remoteAccessMutationRefreshInProgress get() = remoteAccessState.mutationRefreshInProgress
    val remoteAccessMutationRefreshCompleted get() = remoteAccessState.mutationRefreshCompleted
    val remoteAccessMutationGeneration get() = remoteAccessState.mutationGeneration
    val fileBackgroundTasksHasMore: Boolean
        get() = (fileBackgroundTasks as? Loadable.Ready)?.value?.hasMore == true
}
internal data class FileBrowserRequestIdentity(
    val path: String,
    val activeSearchQuery: String?,
    val sortOption: FileSortOption,
    val sortAscending: Boolean,
    val typeFilter: FileTypeFilter,
    val searchRequest: io.github.qwertyuiop1995.dsmnativeclient.domain.FileSearchRequest? = null,
)

/** Download 活动读取独立于任务列表，读取失败或重试不得替换任务列表状态。 */
internal fun WorkspaceState.withDownloadActivity(
    value: Loadable<DownloadStationActivity>,
): WorkspaceState = copy(downloadAdvancedRead = downloadAdvancedRead.copy(activity = value))

internal data class DownloadListRequestToken(
    val generation: Long,
    val profileId: String,
)

internal data class ContainerRegistrySearchToken(
    val generation: Long,
    val profileId: String,
    val query: String,
)

internal fun WorkspaceState.matchesContainerRegistrySearch(
    token: ContainerRegistrySearchToken,
    currentGeneration: Long,
): Boolean = token.generation == currentGeneration &&
    profile.id == token.profileId &&
    selectedModule == Module.CONTAINERS &&
    containerRegistryVisible &&
    containerRegistryQuery.trim() == token.query

internal data class ContainerRegistryTagsToken(
    val generation: Long,
    val profileId: String,
    val imageId: String,
)

internal fun WorkspaceState.matchesContainerRegistryTags(
    token: ContainerRegistryTagsToken,
    currentGeneration: Long,
): Boolean = token.generation == currentGeneration &&
    profile.id == token.profileId &&
    selectedModule == Module.CONTAINERS &&
    containerRegistryVisible &&
    selectedContainerRegistryImage?.id == token.imageId

internal fun WorkspaceState.matchesDownloadListRequest(
    token: DownloadListRequestToken,
    currentGeneration: Long,
): Boolean = token.generation == currentGeneration && profile.id == token.profileId &&
    canLoadDownloadsNormally(downloadControlState) && downloadCreationState.target == null &&
    downloadDestinationEditState.target == null

internal data class FileBrowserRequestToken(
    val generation: Long,
    val identity: FileBrowserRequestIdentity,
)

internal fun FileBrowserState.fileBrowserRequestIdentity() = FileBrowserRequestIdentity(
    path = path,
    activeSearchQuery = activeSearchQuery,
    sortOption = sortOption,
    sortAscending = sortAscending,
    typeFilter = typeFilter,
    searchRequest = searchRequest,
)

internal fun FileBrowserState.matchesFileBrowserRequest(
    identity: FileBrowserRequestIdentity,
): Boolean = fileBrowserRequestIdentity() == identity

internal fun FileBrowserState.matchesFileBrowserRequest(
    token: FileBrowserRequestToken,
    currentGeneration: Long,
): Boolean = token.generation == currentGeneration && matchesFileBrowserRequest(token.identity)

internal fun WorkspaceState.withDownloads(
    value: Loadable<List<DownloadTask>>,
): WorkspaceState {
    val reconciledDetails = if (value is Loadable.Ready) {
        downloadDetailsTask?.let { selected ->
            value.value.firstOrNull { it.id == selected.id }
        }
    } else {
        downloadDetailsTask
    }
    val previous = (downloads as? Loadable.Ready)?.value ?: downloadLastTasks
    return copy(downloads = if (value !is Loadable.Ready && previous != null) Loadable.Ready(previous) else value,
        downloadDetailsTask = reconciledDetails, downloadAdvancedRead = downloadAdvancedRead.copy(
            downloadLastTasks = (value as? Loadable.Ready)?.value ?: previous,
            downloadListRefreshing = value == Loadable.Loading, downloadListFailure = (value as? Loadable.Failed)?.error))
}
