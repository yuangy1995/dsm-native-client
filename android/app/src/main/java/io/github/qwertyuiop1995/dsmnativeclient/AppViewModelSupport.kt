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

internal fun WorkspaceState.pageLinkDestination(): WorkspacePageLinkDestination = when (selectedModule) {
    Module.FILES -> when {
        previewDiscardConfirmationVisible ||
            fileStationMutationBlocksWorkspaceExit(fileStationMutationState) -> {
            WorkspacePageLinkDestination.Unavailable
        }

        previewOwner == PreviewOwner.FILES && previewItem != null -> {
            val item = requireNotNull(previewItem)
            if (!item.isDirectory && item.canRead &&
                FileBrowserState.fromCanonicalFilePath(item.path) != null
            ) {
                WorkspacePageLinkDestination.Opaque(OpaqueWorkspaceTarget.FilePreview(item.path))
            } else {
                WorkspacePageLinkDestination.Unavailable
            }
        }

        fileBrowser.selectedPaths.isNotEmpty() || fileCopyMove != null || pendingFileUploads != null ||
            fileStationMutationState.editorVisible ||
            fileStationMutationState.confirmationRequested ||
            fileStationMutationState.target != null ||
            fileFavorites !is Loadable.Idle || fileRemoteLocations !is Loadable.Idle ||
            fileRecentLocations !is Loadable.Idle || fileShareLinks !is Loadable.Idle -> {
            WorkspacePageLinkDestination.Unavailable
        }

        fileBrowser.path.isNotBlank() -> {
            if (FileBrowserState.fromCanonicalDirectoryPath(fileBrowser.path) != null) {
                WorkspacePageLinkDestination.Opaque(
                    OpaqueWorkspaceTarget.FileDirectory(fileBrowser.path),
                )
            } else {
                WorkspacePageLinkDestination.Unavailable
            }
        }

        else -> WorkspacePageLinkDestination.Fixed(Module.FILES.fixedExternalWorkspaceUri())
    }

    Module.PHOTOS -> when {
        photoMove != null -> WorkspacePageLinkDestination.Unavailable
        previewOwner == PreviewOwner.PHOTOS && photoViewer != null &&
            previewItem?.path == photoViewer.current.path -> {
            val item = requireNotNull(previewItem)
            if (item.canRead && photoBrowser.restoreCanonicalMediaParent(
                    photoBrowser.selectedSpaceId,
                    item.path,
                ) != null
            ) {
                WorkspacePageLinkDestination.Opaque(
                    OpaqueWorkspaceTarget.PhotoViewer(photoBrowser.selectedSpaceId, item.path),
                )
            } else {
                WorkspacePageLinkDestination.Unavailable
            }
        }

        photoBrowser.mode != PhotoBrowseMode.FOLDERS -> WorkspacePageLinkDestination.Unavailable
        photoBrowser.selectedSpaceId == SHARED_PHOTO_SPACE.id ||
            photoBrowser.folderPath != photoBrowser.selectedSpace.rootPath -> {
            if (photoBrowser.restoreCanonicalFolder(
                    photoBrowser.selectedSpaceId,
                    photoBrowser.folderPath,
                ) != null
            ) {
                WorkspacePageLinkDestination.Opaque(
                    OpaqueWorkspaceTarget.PhotoFolder(
                        photoBrowser.selectedSpaceId,
                        photoBrowser.folderPath,
                    ),
                )
            } else {
                WorkspacePageLinkDestination.Unavailable
            }
        }

        else -> WorkspacePageLinkDestination.Fixed(Module.PHOTOS.fixedExternalWorkspaceUri())
    }

    Module.CHAT -> when {
        chatMutationBlocksWorkspaceExit(chatMutationState) -> WorkspacePageLinkDestination.Unavailable
        chatNewConversationVisible || chatMembersVisible || chatRemindersVisible ||
            chatScheduledMessagesVisible || chatScheduleComposerVisible || chatPollComposerVisible -> {
            WorkspacePageLinkDestination.Unavailable
        }

        selectedConversation != null -> selectedConversation
            ?.id
            ?.takeIf { it.isNotBlank() && it == it.trim() }
            ?.let { id ->
                WorkspacePageLinkDestination.Opaque(OpaqueWorkspaceTarget.ChatConversation(id))
            } ?: WorkspacePageLinkDestination.Unavailable

        else -> WorkspacePageLinkDestination.Fixed(Module.CHAT.fixedExternalWorkspaceUri())
    }

    Module.DOWNLOADS -> when {
        downloadCreationState.editorVisible || downloadCreationState.target != null ||
            downloadControlState.target != null || downloadDestinationEditState.selectionTaskBaseline != null ||
            downloadDestinationEditState.target != null || downloadSettingsState.editorVisible ||
            downloadDestinationPicker != null || selectedDownloadRssSite != null ||
            downloadRssRefreshState.target != null || downloadAdvancedRead.discoveryVisible -> {
            WorkspacePageLinkDestination.Unavailable
        }

        downloadDetailsTask != null -> downloadDetailsTask
            ?.id
            ?.takeIf { it.isNotBlank() && it == it.trim() }
            ?.let { id -> WorkspacePageLinkDestination.Opaque(OpaqueWorkspaceTarget.DownloadTask(id)) }
            ?: WorkspacePageLinkDestination.Unavailable

        else -> WorkspacePageLinkDestination.Fixed(Module.DOWNLOADS.fixedExternalWorkspaceUri())
    }

    Module.CONTAINERS -> when {
        containerRegistryVisible && selectedContainerRegistryImage != null -> {
            WorkspacePageLinkDestination.Unavailable
        }

        containerRegistryVisible -> WorkspacePageLinkDestination.Fixed(
            "lanstash://open/containers/registry",
        )

        else -> WorkspacePageLinkDestination.Fixed(Module.CONTAINERS.fixedExternalWorkspaceUri())
    }

    Module.VIRTUAL_MACHINES -> when {
        virtualMachineMutationState.creationEditorVisible ||
            virtualMachineMutationState.imageImportEditorVisible ||
            virtualMachineMutationState.settingsEditorVisible ||
            virtualMachineMutationState.lifecycleConfirmationRequested ||
            virtualMachineMutationState.taskCleanupConfirmationRequested ||
            virtualMachineMutationState.target != null -> WorkspacePageLinkDestination.Unavailable

        virtualMachineMutationState.guestDetailsTargetId != null -> {
            val id = virtualMachineMutationState.guestDetailsTargetId
            val details = virtualMachineMutationState.guestDetails as? Loadable.Ready
            if (id == id.trim() && id.isNotEmpty() &&
                details?.value?.resource?.id == id
            ) {
                WorkspacePageLinkDestination.Opaque(
                    OpaqueWorkspaceTarget.VirtualMachineGuest(id),
                )
            } else {
                WorkspacePageLinkDestination.Unavailable
            }
        }

        virtualMachineMutationState.selectedTab == VirtualMachineTab.TASKS -> {
            WorkspacePageLinkDestination.Fixed("lanstash://open/virtual-machines/tasks")
        }

        virtualMachineMutationState.selectedTab == VirtualMachineTab.MACHINES -> {
            WorkspacePageLinkDestination.Fixed(Module.VIRTUAL_MACHINES.fixedExternalWorkspaceUri())
        }

        else -> WorkspacePageLinkDestination.Unavailable
    }

    Module.NAS_SETTINGS -> when (nasPerformance.selectedTab) {
        NasSettingsTab.PERFORMANCE -> WorkspacePageLinkDestination.Fixed(
            "lanstash://open/nas-settings/performance",
        )

        NasSettingsTab.OVERVIEW -> WorkspacePageLinkDestination.Fixed(
            Module.NAS_SETTINGS.fixedExternalWorkspaceUri(),
        )

        else -> WorkspacePageLinkDestination.Unavailable
    }

    Module.TRANSFERS,
    Module.SETTINGS,
    -> WorkspacePageLinkDestination.Fixed(selectedModule.fixedExternalWorkspaceUri())
}

private fun Module.fixedExternalWorkspaceUri(): String =
    "lanstash://open/${externalWorkspaceSlug()}"


/** EXIF 方向会交换横纵轴的四种情况；镜像不改变媒体详情中的尺寸。 */
internal fun imageDimensionsAfterExifOrientation(
    width: Int,
    height: Int,
    orientation: Int,
): Pair<Int, Int> = when (orientation) {
    ExifInterface.ORIENTATION_TRANSPOSE,
    ExifInterface.ORIENTATION_ROTATE_90,
    ExifInterface.ORIENTATION_TRANSVERSE,
    ExifInterface.ORIENTATION_ROTATE_270 -> height to width

    else -> width to height
}

internal fun WorkspaceState.persistedUiState() = PersistedWorkspaceUiState(
    selectedModule = selectedModule.name,
    filePath = fileBrowser.path,
    filePathHistory = fileBrowser.pathHistory.takeLast(64),
    fileSearchQuery = fileBrowser.searchQuery.take(256),
    fileActiveSearchQuery = fileBrowser.activeSearchQuery?.take(256),
    fileSortOption = fileBrowser.sortOption.name,
    fileSortAscending = fileBrowser.sortAscending,
    fileTypeFilter = fileBrowser.typeFilter.name,
    fileViewMode = fileBrowser.viewMode.name,
    chatPinnedConversationIds = chatPinnedConversationIds
        .filter { it.isNotBlank() && it.length <= MAX_CHAT_CONVERSATION_ID_CHARACTERS }
        .distinct()
        .take(MAX_PINNED_CHAT_CONVERSATIONS),
)

internal fun restoreWorkspaceUiState(
    saved: PersistedWorkspaceUiState?,
    availability: List<ModuleAvailability>,
): Pair<Module, FileBrowserState> {
    val availableModules = availability.filter(ModuleAvailability::isAvailable).mapTo(mutableSetOf()) {
        it.module
    }
    val savedModule = saved?.let {
        runCatching { Module.valueOf(it.selectedModule) }.getOrNull()
    }
    val module = savedModule
        ?.takeIf { it in availableModules }
        ?: listOf(Module.FILES, Module.TRANSFERS, Module.SETTINGS)
            .firstOrNull { it in availableModules }
        ?: availableModules.firstOrNull()
        // Repository 始终公开本地设置；该兜底只保护损坏的合成状态。
        ?: Module.SETTINGS
    return module to (saved?.let(::restoreFileBrowserState) ?: FileBrowserState())
}

internal fun restoreFileBrowserState(saved: PersistedWorkspaceUiState): FileBrowserState {
    val path = saved.filePath.takeIf { it.isBlank() || it.startsWith('/') }.orEmpty()
    val history = saved.filePathHistory
        .filter { it.isBlank() || it.startsWith('/') }
        .take(64)
    return FileBrowserState(
        path = path,
        pathHistory = history,
        searchQuery = saved.fileSearchQuery.take(256),
        activeSearchQuery = saved.fileActiveSearchQuery?.take(256),
        sortOption = runCatching { FileSortOption.valueOf(saved.fileSortOption) }
            .getOrDefault(FileSortOption.NAME),
        sortAscending = saved.fileSortAscending,
        typeFilter = runCatching { FileTypeFilter.valueOf(saved.fileTypeFilter) }
            .getOrDefault(FileTypeFilter.ALL),
        viewMode = runCatching { FileViewMode.valueOf(saved.fileViewMode) }
            .getOrDefault(FileViewMode.LIST),
    )
}

internal data class ChatLocalReadMarker(
    val latestAtEpochSeconds: Long?,
    val latestPreview: String?,
)

internal data class ChatLocalReadOverlay(
    val conversations: List<ChatConversation>,
    val markers: Map<String, ChatLocalReadMarker>,
)

/**
 * 在服务器已读回写尚未验证时，用进程内标记防止刚打开的会话未读数被旧列表反弹。
 * 时间前进或同秒预览变化都视为新活动。缺少足以比较的时间和预览时立即撤销覆盖，
 * 避免因服务端字段缺失而永久隐藏后续新消息。
 */
internal fun applyChatLocalReadOverlay(
    conversations: List<ChatConversation>,
    markers: Map<String, ChatLocalReadMarker>,
): ChatLocalReadOverlay {
    val updatedMarkers = markers.toMutableMap()
    updatedMarkers.keys.retainAll(conversations.mapTo(mutableSetOf(), ChatConversation::id))
    val updatedConversations = conversations.map { conversation ->
        val marker = markers[conversation.id] ?: return@map conversation
        val incomingTime = conversation.latestAtEpochSeconds.normalizedChatActivityTime()
        val incomingPreview = conversation.latestPreview.normalizedChatActivityPreview()
        val comparableTimes = marker.latestAtEpochSeconds != null && incomingTime != null
        val comparablePreviews = marker.latestPreview != null && incomingPreview != null
        val insufficientActivityIdentity = !comparableTimes && !comparablePreviews
        val hasNewActivity = when {
            comparableTimes && requireNotNull(incomingTime) > requireNotNull(marker.latestAtEpochSeconds) -> true
            comparableTimes && incomingTime == marker.latestAtEpochSeconds &&
                incomingPreview != marker.latestPreview -> true
            !comparableTimes && comparablePreviews && incomingPreview != marker.latestPreview -> true
            else -> false
        }
        if (conversation.unreadCount <= 0 || insufficientActivityIdentity || hasNewActivity) {
            updatedMarkers.remove(conversation.id)
            conversation
        } else {
            conversation.copy(unreadCount = 0)
        }
    }
    return ChatLocalReadOverlay(updatedConversations, updatedMarkers)
}

internal fun ChatConversation.toChatLocalReadMarker(): ChatLocalReadMarker? {
    if (unreadCount <= 0) return null
    val latestTime = latestAtEpochSeconds.normalizedChatActivityTime()
    val preview = latestPreview.normalizedChatActivityPreview()
    if (latestTime == null && preview == null) return null
    return ChatLocalReadMarker(latestAtEpochSeconds = latestTime, latestPreview = preview)
}

private fun Long?.normalizedChatActivityTime(): Long? = this?.takeIf { it > 0L }

private fun String?.normalizedChatActivityPreview(): String? = this?.takeIf(String::isNotBlank)

internal fun applyChatConversationPreferences(
    conversations: List<ChatConversation>,
    pinnedConversationIds: List<String>,
): List<ChatConversation> {
    val ranks = pinnedConversationIds.withIndex().associate { it.value to it.index }
    return conversations.map { conversation ->
        conversation.copy(isPinnedLocally = conversation.id in ranks)
    }.withIndex().sortedWith(
        compareBy<IndexedValue<ChatConversation>> {
            ranks[it.value.id] ?: Int.MAX_VALUE
        }.thenBy { it.index },
    ).map { it.value }
}

internal fun chatUnreadCount(conversations: Loadable<List<ChatConversation>>): Int =
    ((conversations as? Loadable.Ready)?.value.orEmpty())
        .sumOf { it.unreadCount.coerceAtLeast(0).toLong() }
        .coerceAtMost(999L)
        .toInt()

internal fun confirmedFavoriteCount(results: List<MutationResult?>): Int = results.sumOf { result ->
    when (result?.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> 1
        MutationResultStatus.PARTIAL_SUCCESS -> result.counts.succeeded.coerceIn(0, 1)
        else -> 0
    }
}

@StringRes
internal fun favoriteBatchMessageResource(results: List<MutationResult?>): Int {
    fun hasStatus(vararg statuses: MutationResultStatus): Boolean =
        results.any { it?.status in statuses }

    return when {
        hasStatus(
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        ) -> R.string.favorite_add_unverified
        hasStatus(MutationResultStatus.PERMISSION_DENIED) -> R.string.favorite_add_permission_denied
        hasStatus(MutationResultStatus.UNSUPPORTED) -> R.string.favorite_add_unsupported
        results.any { it?.errorCategory == MutationErrorCategory.CONFLICT } ->
            R.string.favorite_add_in_progress
        hasStatus(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION) -> R.string.favorite_add_cancelled
        results.isNotEmpty() && results.all {
            it?.status == MutationResultStatus.CONFIRMED_SUCCESS
        } -> R.string.favorites_added_count
        confirmedFavoriteCount(results) > 0 || hasStatus(MutationResultStatus.PARTIAL_SUCCESS) ->
            R.string.favorites_added_partial
        else -> R.string.favorite_add_failed
    }
}

@StringRes
internal fun fileStationFavoriteBatchMessageResource(result: MutationResult): Int = when (
    result.status
) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.favorite_added
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.favorite_add_unverified
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.favorite_add_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.favorite_add_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.favorite_add_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.favorite_add_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) R.string.favorite_add_in_progress else R.string.favorite_add_failed
}

@StringRes
internal fun fileStationFavoriteMessageResource(result: MutationResult): Int {
    val removing = result.operation == "favoriteRemove"
    return when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> if (removing) {
            R.string.favorite_removed
        } else {
            R.string.favorite_added
        }
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> R.string.favorite_add_unverified
        MutationResultStatus.PERMISSION_DENIED -> R.string.favorite_add_permission_denied
        MutationResultStatus.UNSUPPORTED -> R.string.favorite_add_unsupported
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.favorite_add_cancelled
        MutationResultStatus.CONFIRMED_FAILURE -> if (
            result.errorCategory == MutationErrorCategory.CONFLICT
        ) R.string.favorite_add_in_progress else R.string.favorite_add_failed
    }
}

@StringRes
internal fun serviceMutationMessageResource(
    result: MutationResult,
    @StringRes success: Int,
): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> success
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.service_action_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.service_action_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.service_action_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.service_action_cancelled
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.service_action_partial
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.service_action_conflict
    } else {
        R.string.service_action_failed
    }
}

@StringRes
internal fun fileDeleteMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.delete_submitted
    MutationResultStatus.PARTIAL_SUCCESS,
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.file_delete_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.file_delete_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.file_delete_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.file_delete_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.file_delete_in_progress
    } else {
        R.string.file_delete_failed
    }
}

@StringRes
internal fun photoDeleteMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.photo_deleted
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.photo_delete_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.photo_delete_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.photo_delete_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.photo_delete_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.photo_delete_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.photo_delete_in_progress
    } else {
        R.string.photo_delete_failed
    }
}

@StringRes
internal fun photoMoveMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.photo_moved
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.photo_move_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.photo_move_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.photo_move_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.photo_move_unavailable
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.photo_move_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.photo_move_conflict
    } else {
        R.string.photo_move_failed
    }
}

@StringRes
internal fun fileCopyMoveMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> if (result.operation == "fileCopy") {
        R.string.files_copied
    } else {
        R.string.files_moved
    }
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.file_copy_move_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.file_copy_move_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.file_copy_move_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.file_copy_move_unavailable
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.file_copy_move_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.file_copy_move_conflict
    } else {
        R.string.file_copy_move_failed
    }
}

@StringRes
internal fun fileEntryMutationMessageResource(result: MutationResult): Int {
    val folderCreate = result.operation == "folderCreate"
    return when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> if (folderCreate) {
            R.string.folder_created
        } else {
            R.string.name_changed
        }
        MutationResultStatus.PARTIAL_SUCCESS -> if (folderCreate) {
            R.string.folder_create_partial
        } else {
            R.string.file_rename_partial
        }
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> if (folderCreate) {
            R.string.folder_create_unverified
        } else {
            R.string.file_rename_unverified
        }
        MutationResultStatus.PERMISSION_DENIED -> if (folderCreate) {
            R.string.folder_create_permission_denied
        } else {
            R.string.file_rename_permission_denied
        }
        MutationResultStatus.UNSUPPORTED -> if (folderCreate) {
            R.string.folder_create_unsupported
        } else {
            R.string.file_rename_unsupported
        }
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> if (folderCreate) {
            R.string.folder_create_cancelled
        } else {
            R.string.file_rename_cancelled
        }
        MutationResultStatus.CONFIRMED_FAILURE -> if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            if (folderCreate) R.string.folder_create_conflict else R.string.file_rename_conflict
        } else {
            if (folderCreate) R.string.folder_create_failed else R.string.file_rename_failed
        }
    }
}

@StringRes
internal fun fileRestoreMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.photo_restored
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.file_restore_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.file_restore_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.file_restore_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.file_restore_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.file_restore_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.file_restore_conflict
    } else {
        R.string.file_restore_failed
    }
}

@StringRes
internal fun shareLinkMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.share_link_copied
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.share_link_create_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.share_link_create_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.share_link_create_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.share_link_create_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.share_link_create_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.share_link_create_conflict
    } else {
        R.string.share_link_create_failed
    }
}

@StringRes
internal fun shareLinkDeleteMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.share_link_delete_success
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.share_link_delete_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.share_link_delete_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.share_link_delete_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.share_link_delete_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.share_link_delete_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.share_link_delete_conflict
    } else {
        R.string.share_link_delete_failed
    }
}

@StringRes
internal fun chatMutationMessageResource(
    operation: ChatMutationOperation,
    result: MutationResult,
): Int = when (operation) {
    ChatMutationOperation.DIRECT_CONVERSATION_CREATE,
    ChatMutationOperation.PRIVATE_GROUP_CREATE,
    -> chatConversationMutationMessageResource(result)
    ChatMutationOperation.REMINDER_SET,
    ChatMutationOperation.REMINDER_DELETE,
    -> chatReminderMutationMessageResource(result)
    ChatMutationOperation.SCHEDULE_CREATE,
    ChatMutationOperation.SCHEDULE_DELETE,
    -> chatScheduleMutationMessageResource(result)
    ChatMutationOperation.POLL_CREATE -> chatPollMutationMessageResource(result)
    ChatMutationOperation.TEXT_SEND -> chatTextSendMessageResource(result)
    ChatMutationOperation.ATTACHMENT_SEND -> chatAttachmentSendMessageResource(result)
}

@StringRes
internal fun chatTextSendMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.message_sent
    MutationResultStatus.PARTIAL_SUCCESS,
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.chat_text_send_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.chat_text_send_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.chat_text_send_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.chat_text_send_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.chat_text_send_conflict
    } else if (result.errorCategory == MutationErrorCategory.VALIDATION) {
        R.string.chat_text_send_invalid
    } else {
        R.string.message_send_failed
    }
}

@StringRes
internal fun chatAttachmentSendMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.message_sent
    MutationResultStatus.PARTIAL_SUCCESS,
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.chat_attachment_send_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.chat_attachment_send_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.chat_attachment_send_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.chat_attachment_send_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.chat_attachment_send_conflict
    } else if (result.errorCategory == MutationErrorCategory.VALIDATION) {
        R.string.chat_attachment_send_invalid
    } else {
        R.string.message_send_failed
    }
}

@StringRes
internal fun chatReminderMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> if (result.operation == "chatReminderDelete") {
        R.string.chat_reminder_removed
    } else {
        R.string.chat_reminder_saved
    }
    MutationResultStatus.PARTIAL_SUCCESS,
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.chat_reminder_change_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.chat_reminder_change_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.chat_reminder_change_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.chat_reminder_change_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.chat_reminder_change_conflict
    } else if (result.errorCategory == MutationErrorCategory.VALIDATION) {
        R.string.chat_reminder_change_invalid
    } else {
        R.string.chat_reminder_change_failed
    }
}

@StringRes
internal fun chatScheduleMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> if (result.operation == "chatScheduleDelete") {
        R.string.chat_schedule_removed
    } else {
        R.string.chat_schedule_saved
    }
    MutationResultStatus.PARTIAL_SUCCESS,
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.chat_schedule_change_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.chat_schedule_change_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.chat_schedule_change_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.chat_schedule_change_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.chat_schedule_change_conflict
    } else if (result.errorCategory == MutationErrorCategory.VALIDATION) {
        R.string.chat_schedule_change_invalid
    } else {
        R.string.chat_schedule_change_failed
    }
}

@StringRes
internal fun chatPollMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.chat_poll_created
    MutationResultStatus.PARTIAL_SUCCESS,
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.chat_poll_change_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.chat_poll_change_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.chat_poll_change_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.chat_poll_change_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.chat_poll_change_conflict
    } else if (result.errorCategory == MutationErrorCategory.VALIDATION) {
        R.string.chat_poll_change_invalid
    } else {
        R.string.chat_poll_change_failed
    }
}

@StringRes
internal fun chatConversationMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> if (result.operation == "chatGroupCreate") {
        R.string.private_group_created
    } else {
        R.string.conversation_started
    }
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.chat_conversation_change_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.chat_conversation_change_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.chat_conversation_change_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.chat_conversation_change_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.chat_conversation_change_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.chat_conversation_change_conflict
    } else if (result.errorCategory == MutationErrorCategory.VALIDATION) {
        R.string.chat_conversation_change_invalid
    } else {
        R.string.chat_conversation_change_failed
    }
}

@StringRes
internal fun downloadCreateMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.download_task_created
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.download_create_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.download_create_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.download_create_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.download_create_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.download_create_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.download_create_conflict
    } else {
        R.string.download_create_failed
    }
}

@StringRes
internal fun archiveMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> if (result.operation == "archiveExtract") {
        R.string.archive_extracted
    } else {
        R.string.archive_created
    }
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.archive_operation_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.archive_operation_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.archive_operation_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.archive_operation_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.archive_operation_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.archive_operation_conflict
    } else {
        R.string.archive_operation_failed
    }
}

@StringRes
internal fun uploadMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.upload_completed
    MutationResultStatus.PARTIAL_SUCCESS,
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.upload_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.upload_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.upload_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.upload_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.upload_conflict
    } else {
        R.string.upload_failed
    }
}

@StringRes
internal fun textSaveMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.text_file_saved
    MutationResultStatus.PARTIAL_SUCCESS,
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.text_save_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.text_save_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.text_save_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.text_save_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.text_save_conflict
    } else {
        R.string.text_save_failed
    }
}

@StringRes
internal fun downloadSettingsMutationMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.download_settings_saved
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.download_settings_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.download_settings_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.download_settings_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.download_settings_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.download_settings_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.download_settings_conflict
    } else {
        R.string.download_settings_failed
    }
}

internal fun Throwable.asDsmFailure(): DsmFailure =
    this as? DsmFailure
        ?: DsmFailure(
            null,
            "The operation was not completed",
            "Try again later.",
            kind = DsmErrorKind.REQUEST_FAILED,
        )

internal fun io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment.isVideoAttachment(): Boolean =
    mimeType?.startsWith("video/", ignoreCase = true) == true ||
        name.substringAfterLast('.', "").lowercase(Locale.ROOT) in setOf(
            "mp4", "m4v", "mov", "avi", "mkv", "webm", "mpeg", "mpg", "ts", "m2ts",
        )

internal fun PersistedDownload.toDownloadFileItem() = FileItem(
    path = sourcePath,
    name = title,
    isDirectory = isDirectory,
    size = expectedBytes ?: 0,
    canRead = true,
)

internal val TERMINAL_TRANSFER_STATES = setOf(
    TransferState.SUCCEEDED,
    TransferState.FAILED,
    TransferState.CANCELLED,
)

internal enum class DownloadEnqueueResult {
    BACKGROUND,
    FOREGROUND,
    REJECTED,
}

/** 恢复时只在 WorkManager 明确没有旧任务时重放后台下载；查询异常沿用旧任务观察。 */
internal enum class RestoredBackgroundWorkLookup {
    PRESENT,
    MISSING,
    QUERY_FAILED,
}

internal enum class RestoredBackgroundDownloadDecision {
    MONITOR,
    REENQUEUE,
    FINALIZE_CANCELLATION,
    IGNORE,
}

internal fun restoredBackgroundDownloadDecision(
    lookup: RestoredBackgroundWorkLookup,
    current: PersistedDownload?,
    expectedRecordId: String,
    expectedProfileId: String,
    expectedWorkId: String,
): RestoredBackgroundDownloadDecision {
    if (
        current == null ||
        current.id != expectedRecordId ||
        current.profileId != expectedProfileId ||
        current.workId != expectedWorkId ||
        current.state == TransferState.PAUSED ||
        current.state in TERMINAL_TRANSFER_STATES
    ) {
        return RestoredBackgroundDownloadDecision.IGNORE
    }
    return when (lookup) {
        RestoredBackgroundWorkLookup.PRESENT,
        RestoredBackgroundWorkLookup.QUERY_FAILED,
        -> RestoredBackgroundDownloadDecision.MONITOR

        RestoredBackgroundWorkLookup.MISSING -> when {
            current.state == TransferState.CANCELLING ->
                RestoredBackgroundDownloadDecision.FINALIZE_CANCELLATION
            current.backgroundCapable -> RestoredBackgroundDownloadDecision.REENQUEUE
            else -> RestoredBackgroundDownloadDecision.IGNORE
        }
    }
}

/**
 * 入队回调只能替换仍属于同一下载执行的记录，避免恢复查询或用户操作后的迟到写入。
 */
internal fun PersistedDownload.canReplaceBackgroundDownloadWorkId(
    expected: PersistedDownload,
): Boolean =
    id == expected.id &&
        profileId == expected.profileId &&
        workId == expected.workId &&
        state == expected.state &&
        backgroundCapable &&
        state !in TERMINAL_TRANSFER_STATES &&
        state !in setOf(TransferState.PAUSED, TransferState.CANCELLING)

internal enum class PhotoBackupScanFailureDecision {
    DISABLE_SOURCE,
    SHOW_SOURCE_STATE_UNAVAILABLE,
    IGNORE,
}

/** 唯一周期任务更新会保留既有 WorkSpec 时，使用查询到的活动 UUID 作为事实来源。 */
internal fun resolvedPhotoBackupPeriodicWorkId(activeWorkIds: List<UUID>): UUID? =
    activeWorkIds.singleOrNull()

internal fun isPhotoBackupSourceAttentionFor(
    current: PersistedPhotoBackupSource?,
    expectedProfileId: String,
    expectedTreeUri: String,
    expectedDestinationPath: String,
): Boolean =
    current?.profileId == expectedProfileId &&
        current.treeUri == expectedTreeUri &&
        current.destinationPath == expectedDestinationPath &&
        !current.enabled &&
        current.needsAttention &&
        current.workId == null

/**
 * 扫描失败只影响仍属于当前配置和当前 WorkManager 观察代次的来源。
 * 截断已由 Worker 同步停用来源；来源状态写入失败时只提示，不能伪造停用结果。
 */
internal fun photoBackupScanFailureDecision(
    observationIsCurrent: Boolean,
    workspaceProfileId: String?,
    currentSource: PersistedPhotoBackupSource?,
    expectedProfileId: String,
    expectedTreeUri: String,
    expectedDestinationPath: String,
    expectedPeriodicWorkId: String,
    expectedObservedWorkId: String,
    observedWorkId: String,
    workState: WorkInfo.State,
    scanOutcome: String?,
): PhotoBackupScanFailureDecision {
    if (
        !observationIsCurrent ||
        workspaceProfileId != expectedProfileId ||
        currentSource == null ||
        currentSource.profileId != expectedProfileId ||
        currentSource.treeUri != expectedTreeUri ||
        currentSource.destinationPath != expectedDestinationPath ||
        observedWorkId != expectedObservedWorkId
    ) {
        return PhotoBackupScanFailureDecision.IGNORE
    }
    if (
        isPhotoBackupSourceAttentionFor(
            current = currentSource,
            expectedProfileId = expectedProfileId,
            expectedTreeUri = expectedTreeUri,
            expectedDestinationPath = expectedDestinationPath,
        )
    ) {
        return PhotoBackupScanFailureDecision.DISABLE_SOURCE
    }
    if (workState != WorkInfo.State.FAILED) return PhotoBackupScanFailureDecision.IGNORE
    return when (scanOutcome) {
        PhotoBackupScanWorker.SCAN_OUTCOME_TOO_MANY_DOCUMENTS ->
            PhotoBackupScanFailureDecision.IGNORE

        PhotoBackupScanWorker.SCAN_OUTCOME_SOURCE_STATE_NOT_PERSISTED -> if (
            currentSource.workId == expectedPeriodicWorkId
        ) {
            PhotoBackupScanFailureDecision.SHOW_SOURCE_STATE_UNAVAILABLE
        } else {
            PhotoBackupScanFailureDecision.IGNORE
        }

        else -> PhotoBackupScanFailureDecision.IGNORE
    }
}

internal fun shouldDeleteFailedForegroundDownload(
    download: PersistedDownload,
    ownsExecution: Boolean,
): Boolean = ownsExecution && download.isDirectory && download.state == TransferState.FAILED

/** Container 私有写接口在行为验证和兼容记录同时满足前保持关闭。 */
internal fun containerWriteActionsEnabled(): Boolean = false

/** 只从现有领域状态投影路由层级，不复制路径、会话标识或其他业务载荷。 */
internal fun WorkspaceState.workspaceRouteStack(): WorkspaceRouteStack =
    deriveWorkspaceRouteStack(
        module = selectedModule,
        fileHistoryDepth = fileBrowser.pathHistory.size,
        hasFileSelection = fileBrowser.selectedPaths.isNotEmpty(),
        photoHistoryDepth = photoBrowser.pathHistory.size.takeIf {
            photoBrowser.mode == PhotoBrowseMode.FOLDERS
        } ?: 0,
        hasConversation = selectedConversation != null,
        hasFilePreview = selectedModule == Module.FILES &&
            previewOwner == PreviewOwner.FILES && previewItem != null,
        hasPhotoViewer = selectedModule == Module.PHOTOS &&
            previewOwner == PreviewOwner.PHOTOS && photoViewer != null &&
            photoViewer.current.path == previewItem?.path,
        hasDownloadTaskDetails = selectedModule == Module.DOWNLOADS && downloadDetailsTask != null,
        hasContainerRegistry = selectedModule == Module.CONTAINERS && containerRegistryVisible,
        hasVirtualMachineTasks = selectedModule == Module.VIRTUAL_MACHINES &&
            virtualMachineMutationState.selectedTab == VirtualMachineTab.TASKS,
        hasVirtualMachineGuestDetails = selectedModule == Module.VIRTUAL_MACHINES &&
            virtualMachineMutationState.guestDetailsTargetId != null,
        hasNasSettingsPerformance = selectedModule == Module.NAS_SETTINGS &&
            nasPerformance.selectedTab == NasSettingsTab.PERFORMANCE,
    )

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
    return copy(downloads = value, downloadDetailsTask = reconciledDetails)
}

internal fun WorkspaceState.hasDirtyTextPreview(): Boolean {
    val savedText = ((preview as? Loadable.Ready)?.value as? FilePreviewContent.Text)?.value
    return previewOwner == PreviewOwner.FILES && textPreviewDraft != null && textPreviewDraft != savedText
}

internal fun canRunDownloadInBackground(
    savedSessionAvailable: Boolean,
    persistableDestinationGrant: Boolean,
): Boolean = savedSessionAvailable && persistableDestinationGrant

internal fun resolveUploadDestination(
    destinationSnapshot: String?,
    currentBrowserPath: String,
): String = destinationSnapshot ?: currentBrowserPath

internal enum class TransferEnqueueReason {
    INITIAL,
    USER_RETRY,
}

internal fun transferEnqueuePolicy(reason: TransferEnqueueReason): ExistingWorkPolicy =
    when (reason) {
        TransferEnqueueReason.INITIAL -> ExistingWorkPolicy.KEEP
        TransferEnqueueReason.USER_RETRY -> ExistingWorkPolicy.REPLACE
    }

internal fun PersistedDownload.requestUserCancellation(
    expectedWorkId: String?,
): PersistedDownload = if (
    workId == expectedWorkId && state in setOf(TransferState.WAITING, TransferState.RUNNING)
) {
    copy(state = TransferState.CANCELLING)
} else {
    this
}

internal fun PersistedUpload.requestUserCancellation(
    expectedWorkId: String?,
): PersistedUpload = if (
    workId == expectedWorkId && state in setOf(TransferState.WAITING, TransferState.RUNNING)
) {
    copy(state = TransferState.CANCELLING)
} else {
    this
}

internal fun PersistedDownload.finalizeForegroundDownloadCancellation(
    ownsExecution: Boolean,
): PersistedDownload = if (ownsExecution && workId == null && state == TransferState.CANCELLING) {
    copy(state = TransferState.CANCELLED, errorKind = null)
} else {
    this
}

internal fun TransferTask.requestUserCancellation(cancellingDetail: String): TransferTask =
    if (state in setOf(TransferState.WAITING, TransferState.RUNNING)) {
        copy(state = TransferState.CANCELLING, detail = cancellingDetail)
    } else {
        this
    }

internal fun TransferTask.finalizeForegroundUserCancellation(
    cancelledDetail: String,
    refreshDetail: String,
): TransferTask {
    if (state != TransferState.CANCELLING) return this
    val needsRefresh = requiresRefresh ||
        direction == TransferDirection.SERVER ||
        (direction == TransferDirection.UPLOAD && completedBytes > 0)
    return copy(
        state = TransferState.CANCELLED,
        detail = if (needsRefresh) refreshDetail else cancelledDetail,
        requiresRefresh = needsRefresh,
    )
}

internal fun PersistedUpload.applyUploadWorkObservation(
    executionId: String,
    workState: WorkInfo.State,
    observedCompletedBytes: Long = 0,
    observedErrorKind: String? = null,
): PersistedUpload {
    if (workId != executionId ||
        state == TransferState.PAUSED ||
        state in TERMINAL_TRANSFER_STATES ||
        (state == TransferState.CANCELLING && workState !in setOf(
            WorkInfo.State.SUCCEEDED,
            WorkInfo.State.FAILED,
            WorkInfo.State.CANCELLED,
        ))
    ) {
        return this
    }
    if (state == TransferState.CANCELLING && workState.isFinished) {
        return cancelUploadExecution(executionId)
    }
    return when (workState) {
        WorkInfo.State.ENQUEUED,
        WorkInfo.State.BLOCKED,
        -> if (state == TransferState.RUNNING) this else copy(state = TransferState.WAITING)
        WorkInfo.State.RUNNING -> copy(
            state = TransferState.RUNNING,
            completedBytes = maxOf(completedBytes, observedCompletedBytes),
        )
        WorkInfo.State.SUCCEEDED -> copy(
            state = TransferState.SUCCEEDED,
            completedBytes = expectedBytes,
            errorKind = null,
            requiresRefresh = false,
        )
        WorkInfo.State.FAILED -> copy(
            state = TransferState.FAILED,
            errorKind = observedErrorKind ?: errorKind ?: DsmErrorKind.UPLOAD_FAILED.name,
        )
        WorkInfo.State.CANCELLED -> if (state == TransferState.WAITING) {
            copy(state = TransferState.CANCELLED, errorKind = null)
        } else {
            copy(
                state = TransferState.FAILED,
                errorKind = DsmErrorKind.CHANGE_NOT_CONFIRMED.name,
                requiresRefresh = true,
            )
        }
    }
}

internal fun PersistedUpload.cancelUploadForLogout(): PersistedUpload {
    if (state in TERMINAL_TRANSFER_STATES) return this
    val mayHaveReachedNas = state in setOf(TransferState.RUNNING, TransferState.CANCELLING) ||
        completedBytes > 0 ||
        directoryMutationResult?.requiresRefresh == true ||
        uploadMutationResult?.requiresRefresh == true
    return copy(
        state = TransferState.CANCELLED,
        errorKind = if (mayHaveReachedNas) DsmErrorKind.CHANGE_NOT_CONFIRMED.name else null,
        requiresRefresh = mayHaveReachedNas,
    )
}

internal fun PersistedDownload.applyDownloadWorkObservation(
    executionId: String,
    workState: WorkInfo.State,
    observedCompletedBytes: Long = 0,
    observedTotalBytes: Long? = null,
    observedErrorKind: String? = null,
): PersistedDownload {
    if (workId != executionId ||
        state == TransferState.PAUSED ||
        state in TERMINAL_TRANSFER_STATES ||
        (state == TransferState.CANCELLING && workState !in setOf(
            WorkInfo.State.SUCCEEDED,
            WorkInfo.State.FAILED,
            WorkInfo.State.CANCELLED,
        ))
    ) {
        return this
    }
    if (state == TransferState.CANCELLING && workState.isFinished) {
        return cancelDownloadExecution(executionId)
    }
    return when (workState) {
        WorkInfo.State.ENQUEUED,
        WorkInfo.State.BLOCKED,
        -> copy(state = TransferState.WAITING)
        WorkInfo.State.RUNNING -> copy(
            state = TransferState.RUNNING,
            completedBytes = maxOf(completedBytes, observedCompletedBytes),
            totalBytes = observedTotalBytes ?: totalBytes,
        )
        WorkInfo.State.SUCCEEDED -> copy(
            state = TransferState.SUCCEEDED,
            completedBytes = totalBytes ?: completedBytes,
            errorKind = null,
        )
        WorkInfo.State.FAILED -> copy(
            state = TransferState.FAILED,
            errorKind = observedErrorKind ?: errorKind ?: DsmErrorKind.DOWNLOAD_FAILED.name,
        )
        WorkInfo.State.CANCELLED -> cancelDownloadExecution(executionId)
    }
}

internal fun canSafelySwitchNas(
    downloads: List<PersistedDownload>,
    uploads: List<PersistedUpload>,
    transfers: List<TransferTask>,
    isPerformingAction: Boolean = false,
    hasActiveChatMutation: Boolean = false,
): Boolean {
    if (isPerformingAction || hasActiveChatMutation) return false

    val activeForegroundDownload = downloads.any { download ->
        download.workId == null &&
            download.state !in TERMINAL_TRANSFER_STATES &&
            (download.isDirectory || download.state != TransferState.PAUSED)
    }
    if (activeForegroundDownload) return false

    val persistedUploadIds = uploads.mapTo(mutableSetOf(), PersistedUpload::id)
    val activeForegroundUpload = uploads.any { upload ->
        upload.workId == null && upload.state !in TERMINAL_TRANSFER_STATES
    } || transfers.any { transfer ->
        transfer.direction == TransferDirection.UPLOAD &&
            transfer.id !in persistedUploadIds &&
            transfer.state !in TERMINAL_TRANSFER_STATES
    }
    if (activeForegroundUpload) return false

    return !hasBlockingFileServerTransfer(transfers)
}

internal fun hasBlockingFileServerTransfer(transfers: List<TransferTask>): Boolean =
    transfers.any { transfer ->
        transfer.direction == TransferDirection.SERVER && (
            transfer.state !in TERMINAL_TRANSFER_STATES ||
                fileServerMutationBlocksWorkspaceExit(transfer.fileServerMutation)
            )
    }

internal fun fileServerMutationBlocksWorkspaceExit(
    lifecycle: FileServerMutationLifecycle?,
): Boolean = lifecycle?.let {
    it.refreshInProgress || it.refreshFailure != null ||
        (it.failure != null && it.result?.submitted != false && (!it.refreshCompleted ||
            it.verification == FileServerMutationVerification.UNAVAILABLE)) ||
        (it.result?.requiresRefresh == true && (!it.refreshCompleted ||
            it.verification == FileServerMutationVerification.UNAVAILABLE))
} == true

internal fun fileServerMutationCanBeExplicitlyCleared(
    lifecycle: FileServerMutationLifecycle?,
): Boolean = lifecycle?.let {
    it.refreshCompleted && !it.refreshInProgress && it.refreshFailure == null
} == true

internal fun cancelledFileServerMutationResult(
    operation: FileServerMutationOperation,
): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    operation = when (operation) {
        FileServerMutationOperation.COMPRESS -> "archiveCompress"
        FileServerMutationOperation.EXTRACT -> "archiveExtract"
    },
    submitted = true,
    requiresRefresh = true,
    counts = MutationResultCounts(succeeded = 0, failed = 0, unknown = 1),
)

internal fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
    .digest(bytes)
    .joinToString("") { "%02x".format(it) }

/** 图标缓存只依赖当前 NAS、套件 ID、版本与实际请求尺寸，不复用其它版本的图标。 */
internal fun packageIconCacheKey(
    profileId: String,
    packageInfo: PackageInfo,
    requestedSize: Int,
): String = "$profileId\u0000${packageInfo.id}\u0000${packageInfo.version}\u0000$requestedSize"

/** 旧 NAS、旧 Repository 或离开 NAS 设置页后的响应不得写回当前工作区。 */
internal fun packageIconRequestMatches(
    repositoryMatches: Boolean,
    currentProfileId: String?,
    currentModule: Module?,
    expectedProfileId: String,
): Boolean = repositoryMatches && currentProfileId == expectedProfileId &&
    currentModule == Module.NAS_SETTINGS

internal fun packageIconSampleSize(
    width: Int,
    height: Int,
    maximumDimension: Int,
): Int {
    require(width > 0 && height > 0 && maximumDimension > 0)
    var sampleSize = 1
    while (width / sampleSize > maximumDimension || height / sampleSize > maximumDimension) {
        if (sampleSize > Int.MAX_VALUE / 2) return sampleSize
        sampleSize *= 2
    }
    return sampleSize
}

internal fun <K, V : Any> MutableMap<K, V>.removeIfSame(key: K, expected: V): Boolean {
    if (this[key] !== expected) return false
    remove(key)
    return true
}

internal suspend fun loadCachedThumbnailBytes(
    cacheFile: File,
    fetch: suspend () -> ByteArray,
    isValid: (ByteArray) -> Boolean,
): ByteArray {
    val cached = runCatching { cacheFile.takeIf(File::isFile)?.readBytes() }.getOrNull()
    if (cached != null && runCatching { isValid(cached) }.getOrDefault(false)) {
        cacheFile.setLastModified(System.currentTimeMillis())
        return cached
    }
    if (cacheFile.exists()) cacheFile.delete()

    val downloaded = fetch()
    check(downloaded.isNotEmpty() && runCatching { isValid(downloaded) }.getOrDefault(false)) {
        "The downloaded thumbnail is invalid"
    }
    replaceFileAtomically(cacheFile) { output -> output.write(downloaded) }
    cacheFile.setLastModified(System.currentTimeMillis())
    return downloaded
}

internal fun replaceFileAtomically(
    destination: File,
    writePart: (FileOutputStream) -> Unit,
) {
    val directory = destination.parentFile ?: error("The cache file has no parent directory")
    check(directory.exists() || directory.mkdirs()) { "The cache directory could not be created" }
    val part = File.createTempFile("${destination.name}.", ".part", directory)
    try {
        FileOutputStream(part).use { output ->
            writePart(output)
            output.flush()
            output.fd.sync()
        }
        try {
            Files.move(
                part.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(part.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    } finally {
        part.delete()
    }
}

internal suspend fun <T> withTemporaryFileOwnership(
    file: File,
    block: suspend (File) -> T,
): T {
    var transferred = false
    try {
        return block(file).also { transferred = true }
    } finally {
        if (!transferred) file.delete()
    }
}

internal fun inactiveThumbnailKeys(
    cachedKeys: Set<String>,
    references: Map<String, Int>,
): Set<String> = cachedKeys.filterTo(mutableSetOf()) { key ->
    (references[key] ?: 0) <= 0
}

internal const val CHAT_REFRESH_INTERVAL_MILLIS = 5_000L
internal const val CHAT_REALTIME_COALESCE_MILLIS = 250L
internal const val NAS_PERFORMANCE_SAMPLE_INTERVAL_MILLIS = 2_000L
internal const val VMM_TASK_POLL_INTERVAL_MILLIS = 2_000L
internal const val MAX_NAS_PERFORMANCE_SAMPLES = 120
internal const val MAX_CHAT_MESSAGE_CHARACTERS = 10_000
internal const val MAX_CHAT_GROUP_TITLE_CHARACTERS = 100
internal const val MAX_LOCAL_CHAT_MESSAGES_PER_CONVERSATION = 200
internal const val MAX_PINNED_CHAT_CONVERSATIONS = 100
internal const val MAX_CHAT_CONVERSATION_ID_CHARACTERS = 512
internal const val MAX_CHAT_POLL_OPTIONS = 10
internal const val MAX_CHAT_POLL_OPTION_CHARACTERS = 500
internal const val MAX_DOWNLOAD_CREATION_DRAFT_CHARACTERS = 8_192
internal const val MAX_DOWNLOAD_CREATION_DESTINATION_CHARACTERS = 2_048
internal const val MAX_DOWNLOAD_CREATION_TITLE_CHARACTERS = 512
internal const val FILE_PAGE_SIZE = 100
internal const val MAX_FILE_UPLOAD_BATCH = 100
internal const val MAX_FILE_TREE_DOCUMENTS = 1_000
internal const val MAX_FILE_FAVORITES = 500
internal const val MAX_FILE_REMOTE_LOCATIONS = 200
internal const val MAX_THUMBNAIL_DISK_CACHE_BYTES = 128L * 1024L * 1024L
internal const val MAX_PACKAGE_ICON_MEMORY_CACHE_BYTES = 4 * 1024 * 1024
internal const val MIN_PACKAGE_ICON_DECODE_DIMENSION = 256
internal const val PACKAGE_ICON_DISPLAY_SIZE = 128

internal fun io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageType
    .toPersistedVirtualMachineImageType(): PersistedVirtualMachineImageType = when (this) {
    io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageType.DISK ->
        PersistedVirtualMachineImageType.DISK
    io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageType.VDSM ->
        PersistedVirtualMachineImageType.VDSM
    io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageType.ISO ->
        PersistedVirtualMachineImageType.ISO
}

internal fun PersistedVirtualMachineImageImport.toVirtualMachineLocalImageImportUiState() =
    VirtualMachineLocalImageImportUiState(
        id = id,
        imageName = imageName,
        stage = stage,
        canRetry = stage == PersistedVirtualMachineImageImportStage.PREPARING && workId == null,
        needsReview = stage in setOf(
            PersistedVirtualMachineImageImportStage.NEEDS_REVIEW,
            PersistedVirtualMachineImageImportStage.CLEANUP_PENDING,
        ),
        canRemove = stage == PersistedVirtualMachineImageImportStage.SUCCEEDED &&
            !requiresRefresh && temporaryFileBaseline == null,
    )

internal class DuplicateUploadNamesException : IllegalArgumentException()

internal fun appendPerformanceSample(
    history: List<PerformanceSample>,
    sample: PerformanceSample,
): List<PerformanceSample> = if (history.lastOrNull()?.timeEpochSeconds == sample.timeEpochSeconds) {
    history
} else {
    (history + sample).takeLast(MAX_NAS_PERFORMANCE_SAMPLES)
}

internal enum class RetryUploadDecision { ALREADY_COMPLETE, CONFLICT, REQUEUE }

internal fun confirmedUploadReadbackResult(): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.CONFIRMED_SUCCESS,
    operation = "fileUpload",
    submitted = true,
    requiresRefresh = false,
    counts = MutationResultCounts(1, 0, 0),
    diagnosticTag = "file-station.upload.confirmed-by-explicit-retry-readback",
)

internal fun retryUploadDecision(
    existing: FileItem?,
    expectedBytes: Long,
    overwrite: Boolean,
): RetryUploadDecision = when {
    existing != null && !existing.isDirectory && existing.size == expectedBytes ->
        RetryUploadDecision.ALREADY_COMPLETE
    existing != null && !overwrite -> RetryUploadDecision.CONFLICT
    else -> RetryUploadDecision.REQUEUE
}

internal fun photoBackupConstraints(): Constraints = Constraints.Builder()
    .setRequiredNetworkType(NetworkType.UNMETERED)
    .setRequiresCharging(true)
    .setRequiresBatteryNotLow(true)
    .setRequiresStorageNotLow(true)
    .build()
