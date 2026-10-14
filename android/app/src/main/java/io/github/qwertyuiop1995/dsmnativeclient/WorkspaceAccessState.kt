package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.flow.MutableStateFlow

internal fun List<ModuleAvailability>.allows(module: Module): Boolean =
    module == Module.SETTINGS || module == Module.TRANSFERS || any { it.module == module && it.isAvailable }

data class WorkspaceAccessUiState(
    val refreshing: Boolean = false,
    val failure: DsmFailure? = null,
)

/** 所有展示写入都使用当前仓储授权；迟到回调不能用旧 availability 恢复已撤销内容。 */
@OptIn(kotlinx.coroutines.ExperimentalForInheritanceCoroutinesApi::class)
internal class WorkspaceStateStore(
    private val availability: () -> List<ModuleAvailability>?,
    private val backing: MutableStateFlow<WorkspaceState?> = MutableStateFlow(null),
) : MutableStateFlow<WorkspaceState?> by backing {
    private fun project(value: WorkspaceState?): WorkspaceState? = value?.let {
        val current = availability()
        (if (current != null && current != it.availability) it.copy(availability = current) else it)
            .withoutUnavailableContent()
    }

    override var value: WorkspaceState?
        get() = backing.value
        set(value) { backing.value = project(value) }
    override fun compareAndSet(expect: WorkspaceState?, update: WorkspaceState?): Boolean =
        backing.compareAndSet(expect, project(update))
    override suspend fun emit(value: WorkspaceState?) { this.value = value }
    override fun tryEmit(value: WorkspaceState?): Boolean { this.value = value; return true }
}

/** 清除读取缓存与预览；保留提交目标、回执、未知结果及本机传输记录供原操作恢复。 */
internal fun WorkspaceState.withoutUnavailableContent(): WorkspaceState {
    var result = this
    if (!availability.allows(Module.FILES) && (files != Loadable.Idle || fileDirectoryBaselines.isNotEmpty() || fileIsLoadingMore ||
        fileFavorites != Loadable.Idle || fileRecentLocations != Loadable.Idle ||
        fileShareLinks != Loadable.Idle || favoritePaths.isNotEmpty() || fileCopyMoveFolders != Loadable.Idle ||
        fileBackgroundTasks != Loadable.Idle || fileBackgroundTaskSnapshotObservedAtEpochSeconds != null ||
        fileBackgroundTaskRefreshInProgress || fileBackgroundTaskIsLoadingMore ||
        fileBackgroundTaskRefreshFailure != null || fileBackgroundTasksLoadMoreFailure != null)) result = result.copy(
        files = Loadable.Idle, fileDirectoryBaselines = emptyMap(), fileIsLoadingMore = false,
        fileSearchCoverage = io.github.qwertyuiop1995.dsmnativeclient.domain.FileSearchIndexCoverage.NOT_REQUESTED,
        fileFavorites = Loadable.Idle, fileRecentLocations = Loadable.Idle,
        fileShareLinks = Loadable.Idle, favoritePaths = emptySet(), fileCopyMoveFolders = Loadable.Idle,
        fileBackgroundTasks = Loadable.Idle, fileBackgroundTaskSnapshotObservedAtEpochSeconds = null,
        fileBackgroundTaskRefreshInProgress = false, fileBackgroundTaskIsLoadingMore = false,
        fileBackgroundTaskRefreshFailure = null, fileBackgroundTasksLoadMoreFailure = null,
    )
    if (!availability.allows(Module.PHOTOS) && (photos != Loadable.Idle || photoTimeline != Loadable.Idle || photoViewer != null ||
        photoMove != null || photoMoveFolders != Loadable.Idle)) result = result.copy(
        photos = Loadable.Idle, photoTimeline = Loadable.Idle, photoViewer = null,
        photoMove = null, photoMoveFolders = Loadable.Idle,
    )
    if (!availability.allows(Module.CHAT) && (conversations != Loadable.Idle || selectedConversation != null || chatUsers != Loadable.Idle ||
        chatMembers != Loadable.Idle || chatReminders != Loadable.Idle || chatScheduledMessages != Loadable.Idle ||
        chatMessages != Loadable.Idle || chatIsLoadingMore || chatAttachmentThumbnails.isNotEmpty() ||
        chatAttachmentPreviewName != null || chatAttachmentPreviewBytes != null || chatAttachmentPreviewVideoFile != null ||
        chatAttachmentPreviewIsVideo || chatAttachmentPreviewIsLoading || chatAttachmentPreviewProgress != null ||
        chatAttachmentPreviewError != null || chatNewConversationVisible || chatMembersVisible || chatRemindersVisible ||
        chatScheduledMessagesVisible || chatScheduleComposerVisible || chatPollComposerVisible)) result = result.copy(
        conversations = Loadable.Idle, selectedConversation = null, chatUsers = Loadable.Idle,
        chatMembers = Loadable.Idle, chatReminders = Loadable.Idle, chatScheduledMessages = Loadable.Idle,
        chatMessages = Loadable.Idle, chatIsLoadingMore = false, chatAttachmentThumbnails = emptyMap(),
        chatAttachmentPreviewName = null, chatAttachmentPreviewBytes = null, chatAttachmentPreviewVideoFile = null,
        chatAttachmentPreviewIsVideo = false, chatAttachmentPreviewIsLoading = false,
        chatAttachmentPreviewProgress = null, chatAttachmentPreviewError = null,
        chatNewConversationVisible = false, chatMembersVisible = false, chatRemindersVisible = false,
        chatScheduledMessagesVisible = false, chatScheduleComposerVisible = false, chatPollComposerVisible = false,
    )
    if (!availability.allows(Module.DOWNLOADS) && (downloads != Loadable.Idle || downloadDetailsTask != null || downloadSettings != Loadable.Idle ||
        downloadRssSites != Loadable.Idle || selectedDownloadRssSite != null || downloadRssFeeds != Loadable.Idle ||
        downloadDestinationFolders != Loadable.Idle || downloadAdvancedRead.activity != Loadable.Idle ||
        downloadAdvancedRead.discoveryVisible || downloadAdvancedRead.btSearchCatalog != Loadable.Idle ||
        downloadAdvancedRead.btSearchResults != Loadable.Idle)) result = result.copy(
        downloads = Loadable.Idle, downloadDetailsTask = null, downloadSettings = Loadable.Idle,
        downloadRssSites = Loadable.Idle, selectedDownloadRssSite = null, downloadRssFeeds = Loadable.Idle,
        downloadDestinationFolders = Loadable.Idle,
        downloadAdvancedRead = downloadAdvancedRead.copy(activity = Loadable.Idle,
            discoveryVisible = false, btSearchCatalog = Loadable.Idle, btSearchResults = Loadable.Idle),
    )
    if (!availability.allows(Module.CONTAINERS) && (containers != Loadable.Idle || containerRegistryVisible || containerRegistryResults != Loadable.Idle ||
        selectedContainerRegistryImage != null || containerRegistryTags != Loadable.Idle)) result = result.copy(
        containers = Loadable.Idle, containerRegistryVisible = false, containerRegistryResults = Loadable.Idle,
        selectedContainerRegistryImage = null, containerRegistryTags = Loadable.Idle,
    )
    if (!availability.allows(Module.VIRTUAL_MACHINES) && (virtualMachines != Loadable.Idle || virtualMachineMutationState.guestDetailsTargetId != null ||
        virtualMachineMutationState.guestDetails != Loadable.Idle || virtualMachineMutationState.taskPolling != VirtualMachineTaskPollingState())) result = result.copy(
        virtualMachines = Loadable.Idle,
        virtualMachineMutationState = virtualMachineMutationState.copy(
            guestDetailsTargetId = null, guestDetails = Loadable.Idle, taskPolling = VirtualMachineTaskPollingState()),
    )
    if (!availability.allows(Module.NAS_SETTINGS) && (nasSettings != Loadable.Idle || nasSystemUpdate != Loadable.Idle || storageAnalysis != Loadable.Idle ||
        storageAnalysisProgress != null || diskTestStatuses.isNotEmpty() || nasPerformance.history.isNotEmpty() ||
        nasPerformance.isLoading || nasPerformance.error != null)) result = result.copy(
        nasSettings = Loadable.Idle, nasSystemUpdate = Loadable.Idle, storageAnalysis = Loadable.Idle,
        storageAnalysisProgress = null, diskTestStatuses = emptyMap(),
        nasPerformance = nasPerformance.copy(history = emptyList(), isLoading = false, error = null),
    )
    val previewModule = when (previewOwner) {
        PreviewOwner.FILES -> Module.FILES
        PreviewOwner.PHOTOS -> Module.PHOTOS
        null -> null
    }
    if (previewModule != null && !availability.allows(previewModule)) result = result.copy(
        preview = Loadable.Idle, previewItem = null, previewOwner = null, filePreviewSequence = null,
        textPreviewDraft = null, previewDiscardConfirmationVisible = false,
    )
    return result
}
