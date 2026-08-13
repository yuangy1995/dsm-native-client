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

data class LoginState(
    val profiles: List<NasProfile> = emptyList(),
    val selectedProfileId: String? = null,
    val savedPassword: String = "",
    val rememberPassword: Boolean = false,
    val autoLoginEnabled: Boolean = false,
    val isConnecting: Boolean = false,
    val connectionStatus: ConnectionStatus? = null,
    val error: DsmFailure? = null,
    val needsOtp: Boolean = false,
)

data class VirtualMachineLocalImageImportUiState(
    val id: String,
    val imageName: String,
    val stage: PersistedVirtualMachineImageImportStage,
    val canRetry: Boolean,
    val needsReview: Boolean,
    val canRemove: Boolean,
)

sealed interface Loadable<out T> {
    data object Idle : Loadable<Nothing>
    data object Loading : Loadable<Nothing>
    data class Ready<T>(val value: T) : Loadable<T>
    data class Failed(val error: DsmFailure) : Loadable<Nothing>
}

internal enum class WorkspaceNavigationResult {
    APPLIED,
    ALREADY_SELECTED,
    REJECTED,
    DEFERRED,
}

internal fun shouldStopVirtualMachineTaskPollingAfterNavigation(
    previousModule: Module,
    nextModule: Module,
    result: WorkspaceNavigationResult,
): Boolean = previousModule == Module.VIRTUAL_MACHINES &&
    nextModule != Module.VIRTUAL_MACHINES && result == WorkspaceNavigationResult.APPLIED

internal fun Loadable<FilePage>.withFavoritePaths(paths: Set<String>): Loadable<FilePage> =
    (this as? Loadable.Ready)?.let { ready ->
        Loadable.Ready(
            ready.value.copy(
                items = ready.value.items.map { item ->
                    item.copy(isFavorite = item.path in paths)
                },
            ),
        )
    } ?: this


internal data class FileStationMutationClaim(
    val repository: DsmRepository,
    val profileId: String,
    val target: FileStationMutationTarget,
    val generation: Long,
    val verifyOnRefresh: Boolean = true,
)

internal enum class FileStationMutationRefresh {
    FILE_BROWSER,
    PHOTOS,
    FAVORITES,
    SHARE_LINKS,
    TEXT_PREVIEW,
}


internal data class FileUploadPreflightClaim(
    val repository: DsmRepository,
    val token: FileUploadPreflightToken,
)

internal data class FileServerTransferClaim(
    val repository: DsmRepository,
    val profileId: String,
    val sourceModule: Module,
    val taskId: String,
    val target: FileServerMutationTarget,
    val generation: Long,
)

internal data class FileServerMutationExecution(
    val result: MutationResult,
    val expectedOutputs: List<FileServerMutationExpectedOutput>,
)


enum class PreviewOwner { FILES, PHOTOS }


internal data class DownloadRssRefreshClaim(
    val repository: DsmRepository,
    val profileId: String,
    val target: DownloadRssRefreshTarget,
    val generation: Long,
)

internal data class DownloadSettingsMutationClaim(
    val repository: DsmRepository,
    val profileId: String,
    val generation: Long,
    val baseline: DownloadSettings,
    val desired: DownloadSettings,
)



internal data class ChatMutationClaim(
    val repository: DsmRepository,
    val profileId: String,
    val target: ChatMutationTarget,
    val generation: Long,
)

internal data class ChatMutationCompletion(
    val result: MutationResult,
    val verification: ChatMutationVerification? = null,
    val apply: (WorkspaceState) -> WorkspaceState = { it },
    val afterApply: (() -> Unit)? = null,
)

internal data class ChatMutationRefreshSnapshot(
    val conversations: List<ChatConversation>? = null,
    val reminders: List<ChatReminder>? = null,
    val schedules: List<ChatScheduledMessage>? = null,
    val messages: List<ChatMessage>? = null,
)

internal data class ChatAttachmentPreflightToken(
    val repository: DsmRepository,
    val profileId: String,
    val conversationId: String,
    val generation: Long,
    val createdAtEpochSeconds: Long,
)

internal data class VirtualMachineMutationClaim(
    val repository: DsmRepository,
    val profileId: String,
    val target: VirtualMachineMutationTarget,
    val generation: Long,
)

internal data class VirtualMachineLocalImagePreparation(
    val profileId: String,
    val uri: Uri,
    val contentType: String?,
    val displayName: String,
)

/**
 * 对象外链在 ViewModel 内短暂保留的解析上下文。
 *
 * URI 只携带令牌；这里的目标来自加密资料存储，绝不进入 Activity Bundle 或持久 UI 状态。
 */
internal data class OpaqueExternalNavigationRequest(
    val token: String,
    val profileId: String,
    val target: OpaqueWorkspaceTarget,
    val repository: DsmRepository,
    val generation: Long,
    var phase: OpaqueExternalNavigationPhase,
)

internal enum class OpaqueExternalNavigationPhase {
    RESOLVING,
    RETRYABLE,
    WAITING_FOR_PREVIEW_DISCARD,
    APPLIED,
    REJECTED,
}

internal enum class OpaqueExternalNavigationResolution {
    APPLIED,
    DEFERRED,
    REJECTED,
    STALE,
}

internal sealed interface WorkspacePageLinkDestination {
    data class Fixed(val uri: String) : WorkspacePageLinkDestination
    data class Opaque(val target: OpaqueWorkspaceTarget) : WorkspacePageLinkDestination
    data object Unavailable : WorkspacePageLinkDestination
}

internal fun downloadControlTargetChangedFailure(): DsmFailure = DsmFailure(
    code = null,
    message = "The download task changed before confirmation",
    recovery = "Review the current task state before confirming the action again.",
    kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
)
