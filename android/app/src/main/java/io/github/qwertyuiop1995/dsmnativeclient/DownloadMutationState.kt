package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssFeed
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssSite
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationAction
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationBaseline
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import java.security.MessageDigest

data class DownloadDestinationLocation(
    val path: String,
    val canWrite: Boolean,
    val baseline: FileItem? = null,
)

data class DownloadDestinationPickerState(
    val location: DownloadDestinationLocation = DownloadDestinationLocation("", canWrite = false),
    val history: List<DownloadDestinationLocation> = emptyList(),
) {
    val canSelectCurrent: Boolean get() = location.path.isNotBlank() && location.canWrite

    fun enter(folder: FileItem): DownloadDestinationPickerState {
        require(folder.isDirectory)
        return copy(
            location = DownloadDestinationLocation(folder.path, folder.canWrite, folder),
            history = history + location,
        )
    }

    fun goBack(): DownloadDestinationPickerState? = history.lastOrNull()?.let { previous ->
        copy(location = previous, history = history.dropLast(1))
    }
}

enum class DownloadControlOperation {
    PAUSE,
    RESUME,
    DELETE_TASK,
    END_TASK_AND_MOVE_FILES,
    ;

    val repositoryAction: DownloadTaskMutationAction
        get() = when (this) {
            PAUSE -> DownloadTaskMutationAction.PAUSE
            RESUME -> DownloadTaskMutationAction.RESUME
            DELETE_TASK -> DownloadTaskMutationAction.REMOVE_TASK
            END_TASK_AND_MOVE_FILES -> DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES
        }
    val resultOperation: String
        get() = when (this) {
            PAUSE -> "downloadPause"
            RESUME -> "downloadResume"
            DELETE_TASK -> "downloadDelete"
            END_TASK_AND_MOVE_FILES -> "downloadEndAndMove"
        }
    val isDeletion: Boolean get() = this == DELETE_TASK || this == END_TASK_AND_MOVE_FILES
}

data class DownloadControlTarget(
    val profileId: String,
    val taskBaseline: DownloadTask,
    val operation: DownloadControlOperation,
) {
    init {
        require(profileId.isNotBlank()) { "download_control.invalid_profile" }
        require(taskBaseline.id.isNotBlank() && taskBaseline.id == taskBaseline.id.trim()) {
            "download_control.invalid_target"
        }
    }
}

data class DownloadControlWorkspaceState(
    val target: DownloadControlTarget? = null,
    val confirmationRequested: Boolean = false,
    val mutationInProgress: Boolean = false,
    val mutationResult: MutationResult? = null,
    val mutationFailure: DsmFailure? = null,
    val mutationRefreshFailure: DsmFailure? = null,
    val mutationRefreshInProgress: Boolean = false,
    val mutationRefreshCompleted: Boolean = false,
    val mutationRefreshMatches: Boolean? = null,
    val mutationGeneration: Long = 0L,
)

/** 修改任务保存位置只保留当前内存中的任务与目录基线，不进入 SavedState 或持久化存储。 */
data class DownloadDestinationEditTarget(
    val profileId: String,
    val taskBaseline: DownloadTask,
    val destinationBaseline: FileItem,
) {
    init {
        require(profileId.isNotBlank()) { "download_destination_edit.invalid_profile" }
        require(taskBaseline.id.isNotBlank() && taskBaseline.id == taskBaseline.id.trim()) {
            "download_destination_edit.invalid_task"
        }
        require(
            destinationBaseline.path.isNotBlank() && destinationBaseline.isDirectory &&
                destinationBaseline.canWrite,
        ) { "download_destination_edit.invalid_destination" }
    }
}

data class DownloadDestinationEditWorkspaceState(
    val selectionTaskBaseline: DownloadTask? = null,
    val selectionTasks: List<DownloadTask> = emptyList(),
    val target: DownloadDestinationEditTarget? = null,
    val confirmationRequested: Boolean = false,
    val mutationInProgress: Boolean = false,
    val mutationResult: MutationResult? = null,
    val mutationFailure: DsmFailure? = null,
    val mutationRefreshFailure: DsmFailure? = null,
    val mutationRefreshInProgress: Boolean = false,
    val mutationRefreshCompleted: Boolean = false,
    val mutationRefreshMatches: Boolean? = null,
    val mutationGeneration: Long = 0L,
)

enum class DownloadCreationSourceKind {
    LINK,
    MAGNET,
    TASK_FILE,
    RSS,
    BT_SEARCH,
}

/** 创建目标不保存来源链接、磁力、Content URI 或任务文件内容；目录仅供当前界面核对，不落盘。 */
data class DownloadCreationTarget(
    val profileId: String,
    val sourceKind: DownloadCreationSourceKind,
    val requestFingerprint: String,
    val destination: String?,
) {
    init {
        require(profileId.isNotBlank()) { "download_creation.invalid_profile" }
        require(requestFingerprint.length == 64 && requestFingerprint.all { it in "0123456789abcdef" }) {
            "download_creation.invalid_fingerprint"
        }
    }
}

data class DownloadCreationWorkspaceState(
    val editorVisible: Boolean = false,
    // 草稿只存在 ViewModel 内存中，支持 Compose/Activity 重建；不写入 SavedState 或持久存储。
    val uriDraft: String = "",
    val destinationDraft: String = "",
    val pendingDiscoveryTitle: String? = null,
    val pendingDiscoveryUri: String? = null,
    val pendingDiscoverySource: DownloadCreationSourceKind? = null,
    val target: DownloadCreationTarget? = null,
    val mutationInProgress: Boolean = false,
    val mutationResult: MutationResult? = null,
    val mutationFailure: DsmFailure? = null,
    val mutationRefreshFailure: DsmFailure? = null,
    val mutationRefreshInProgress: Boolean = false,
    val mutationRefreshCompleted: Boolean = false,
    val mutationGeneration: Long = 0L,
)

/** 下载设置草稿只保存在当前 ViewModel 内存中，不写入 SavedState 或持久存储。 */
data class DownloadSettingsDraftState(
    val destination: String,
    val emuleEnabled: Boolean,
    val autoExtract: Boolean,
    val btDownload: String,
    val btUpload: String,
    val httpDownload: String,
    val ftpDownload: String,
    val nzbDownload: String,
    val emuleDownload: String,
    val emuleUpload: String,
    val scheduleEnabled: Boolean,
    val emuleScheduleEnabled: Boolean,
) {
    fun toSettingsOrNull(supportsSchedule: Boolean, baseline: DownloadSettings? = null): DownloadSettings? {
        val cleanDestination = if (baseline != null && "default_destination" !in baseline.availableFields) baseline.defaultDestination
            else io.github.qwertyuiop1995.dsmnativeclient.data.downloads.downloadDestination(destination) ?: return null
        val limits = listOf(
            btDownload,
            btUpload,
            httpDownload,
            ftpDownload,
            nzbDownload,
            emuleDownload,
            emuleUpload,
        ).map { it.toIntOrNull()?.takeIf { value -> value in 0..1_000_000 } ?: return null }
        if (limits[2] != limits[3]) return null
        return DownloadSettings(
            defaultDestination = cleanDestination,
            emuleEnabled = emuleEnabled,
            autoExtractEnabled = autoExtract,
            btDownloadLimitKb = limits[0],
            btUploadLimitKb = limits[1],
            httpDownloadLimitKb = limits[2],
            ftpDownloadLimitKb = limits[3],
            nzbDownloadLimitKb = limits[4],
            emuleDownloadLimitKb = limits[5],
            emuleUploadLimitKb = limits[6],
            scheduleEnabled = supportsSchedule && scheduleEnabled,
            emuleScheduleEnabled = supportsSchedule && emuleScheduleEnabled,
            availableFields = baseline?.availableFields ?: io.github.qwertyuiop1995.dsmnativeclient.domain.DOWNLOAD_SETTING_FIELDS,
            canManage = baseline?.canManage ?: false,
            scheduleFailure = baseline?.scheduleFailure,
            basicFailure = baseline?.basicFailure,
        )
    }

    companion object {
        fun from(settings: DownloadSettings) = DownloadSettingsDraftState(
            destination = settings.defaultDestination,
            emuleEnabled = settings.emuleEnabled,
            autoExtract = settings.autoExtractEnabled,
            btDownload = settings.btDownloadLimitKb.toString(),
            btUpload = settings.btUploadLimitKb.toString(),
            httpDownload = settings.httpDownloadLimitKb.toString(),
            ftpDownload = settings.httpDownloadLimitKb.toString(),
            nzbDownload = settings.nzbDownloadLimitKb.toString(),
            emuleDownload = settings.emuleDownloadLimitKb.toString(),
            emuleUpload = settings.emuleUploadLimitKb.toString(),
            scheduleEnabled = settings.scheduleEnabled,
            emuleScheduleEnabled = settings.emuleScheduleEnabled,
        )
    }
}

data class DownloadSettingsWorkspaceState(
    val editorVisible: Boolean = false,
    val baseline: DownloadSettings? = null,
    val draft: DownloadSettingsDraftState? = null,
    val mutationInProgress: Boolean = false,
    val mutationResult: MutationResult? = null,
    val mutationFailure: DsmFailure? = null,
    val mutationRefreshFailure: DsmFailure? = null,
    val mutationRefreshInProgress: Boolean = false,
    val mutationRefreshCompleted: Boolean = false,
    val mutationGeneration: Long = 0L,
)

data class DownloadRssRefreshTarget(
    val profileId: String,
    val siteId: String,
    val baselineLastUpdatedAtEpochSeconds: Long? = null,
) {
    init {
        require(profileId.isNotBlank()) { "download_rss_refresh.invalid_profile" }
        require(siteId.isNotBlank() && siteId == siteId.trim()) {
            "download_rss_refresh.invalid_site"
        }
    }
}

enum class DownloadRssRefreshVerification {
    MATCHES,
    DIFFERS,
    DISAPPEARED,
    UNAVAILABLE,
}

data class DownloadRssRefreshWorkspaceState(
    val target: DownloadRssRefreshTarget? = null,
    val mutationInProgress: Boolean = false,
    val mutationResult: MutationResult? = null,
    val mutationFailure: DsmFailure? = null,
    val mutationRefreshFailure: DsmFailure? = null,
    val mutationRefreshInProgress: Boolean = false,
    val mutationRefreshCompleted: Boolean = false,
    val mutationVerification: DownloadRssRefreshVerification? = null,
    val mutationGeneration: Long = 0L,
)

internal fun canonicalDownloadTask(task: DownloadTask): DownloadTask? {
    val normalizedId = task.id.trim()
    return normalizedId.takeIf(String::isNotEmpty)?.let { task.copy(id = it) }
}

internal fun downloadControlTarget(
    profileId: String,
    downloads: Loadable<List<DownloadTask>>,
    taskId: String,
    operation: DownloadControlOperation,
): DownloadControlTarget? {
    val normalizedId = taskId.trim().takeIf(String::isNotEmpty) ?: return null
    val candidates = (downloads as? Loadable.Ready)?.value.orEmpty()
        .mapNotNull(::canonicalDownloadTask)
        .filter { it.id == normalizedId }
    val baseline = candidates.singleOrNull() ?: return null
    if (!downloadControlOperationAllowed(operation, baseline.status)) return null
    return DownloadControlTarget(profileId, baseline, operation)
}

internal fun downloadControlOperationAllowed(
    operation: DownloadControlOperation,
    status: io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState,
): Boolean = when (operation) {
    DownloadControlOperation.PAUSE -> status in setOf(
        io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.RUNNING,
        io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.WAITING,
    )
    DownloadControlOperation.RESUME ->
        status == io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.PAUSED
    DownloadControlOperation.DELETE_TASK,
    DownloadControlOperation.END_TASK_AND_MOVE_FILES,
    -> true
}

internal fun downloadControlTargetIsCurrent(
    target: DownloadControlTarget,
    profileId: String,
    downloads: Loadable<List<DownloadTask>>,
): Boolean {
    if (target.profileId != profileId) return false
    val canonical = downloadControlTarget(
        profileId = profileId,
        downloads = downloads,
        taskId = target.taskBaseline.id,
        operation = target.operation,
    )
    return canonical != null && canonical.profileId == target.profileId &&
        canonical.operation == target.operation &&
        DownloadTaskMutationBaseline.from(canonical.taskBaseline) ==
        DownloadTaskMutationBaseline.from(target.taskBaseline)
}

internal fun downloadControlRefreshMatches(
    target: DownloadControlTarget,
    refreshed: List<DownloadTask>,
): Boolean {
    val matches = refreshed.mapNotNull(::canonicalDownloadTask)
        .filter { it.id == target.taskBaseline.id }
    return when (target.operation) {
        DownloadControlOperation.PAUSE ->
            matches.singleOrNull()?.status ==
                io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.PAUSED
        DownloadControlOperation.RESUME -> matches.singleOrNull()?.status in setOf(
            io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.RUNNING,
            io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.WAITING,
        )
        DownloadControlOperation.DELETE_TASK,
        DownloadControlOperation.END_TASK_AND_MOVE_FILES,
        -> matches.isEmpty()
    }
}

internal fun downloadControlCallbackMatches(
    repositoryMatches: Boolean,
    profileMatches: Boolean,
    stateTarget: DownloadControlTarget?,
    callbackTarget: DownloadControlTarget,
    stateGeneration: Long,
    callbackGeneration: Long,
    globalGeneration: Long,
): Boolean = repositoryMatches && profileMatches && stateTarget == callbackTarget &&
    stateGeneration == callbackGeneration && globalGeneration == callbackGeneration

internal fun canStartDownloadControlMutation(
    workspaceBusy: Boolean,
    state: DownloadControlWorkspaceState,
): Boolean = !workspaceBusy && state.target == null && !state.confirmationRequested &&
    !state.mutationInProgress && !state.mutationRefreshInProgress

internal fun canLoadDownloadsNormally(state: DownloadControlWorkspaceState): Boolean =
    state.target == null

internal fun cancelledDownloadControlResult(target: DownloadControlTarget): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    operation = target.operation.resultOperation,
    submitted = true,
    requiresRefresh = true,
    counts = MutationResultCounts(
        succeeded = 0,
        failed = 0,
        unknown = 1,
    ),
    errorCategory = MutationErrorCategory.UNKNOWN,
    diagnosticTag = "download-station.${target.operation.name.lowercase().replace('_', '-')}.cancelled-externally",
)

internal fun downloadControlRequiresRefreshBeforeDismiss(
    state: DownloadControlWorkspaceState,
): Boolean {
    val target = state.target ?: return false
    val result = state.mutationResult
    return result?.requiresRefresh == true ||
        target.operation.isDeletion && (result?.submitted == true || state.mutationFailure != null)
}

internal fun downloadControlBlocksWorkspaceExit(state: DownloadControlWorkspaceState): Boolean {
    if (state.confirmationRequested || state.mutationInProgress || state.mutationRefreshInProgress) {
        return true
    }
    return downloadControlRequiresRefreshBeforeDismiss(state) && !state.mutationRefreshCompleted
}

internal fun canDismissDownloadControlMutation(state: DownloadControlWorkspaceState): Boolean =
    state.target != null && !state.confirmationRequested && !state.mutationInProgress &&
        !state.mutationRefreshInProgress &&
        (!downloadControlRequiresRefreshBeforeDismiss(state) || state.mutationRefreshCompleted)

internal fun downloadDestinationEditTarget(
    profileId: String,
    downloads: Loadable<List<DownloadTask>>,
    taskId: String,
    destination: FileItem,
): DownloadDestinationEditTarget? {
    if (!destination.isDirectory || !destination.canWrite || destination.path.isBlank()) return null
    val normalizedId = taskId.trim().takeIf(String::isNotEmpty) ?: return null
    val task = (downloads as? Loadable.Ready)?.value.orEmpty()
        .mapNotNull(::canonicalDownloadTask)
        .filter { it.id == normalizedId }
        .singleOrNull() ?: return null
    if (task.destination?.trim() == destination.path.trim()) return null
    return DownloadDestinationEditTarget(profileId, task, destination)
}

internal fun downloadDestinationEditTargetIsCurrent(
    target: DownloadDestinationEditTarget,
    profileId: String,
    downloads: Loadable<List<DownloadTask>>,
): Boolean {
    if (target.profileId != profileId) return false
    val current = (downloads as? Loadable.Ready)?.value.orEmpty()
        .mapNotNull(::canonicalDownloadTask)
        .filter { it.id == target.taskBaseline.id }
        .singleOrNull() ?: return false
    return DownloadTaskMutationBaseline.from(current) ==
        DownloadTaskMutationBaseline.from(target.taskBaseline)
}

internal fun downloadDestinationEditRefreshMatches(
    target: DownloadDestinationEditTarget,
    refreshed: List<DownloadTask>,
): Boolean = refreshed.mapNotNull(::canonicalDownloadTask)
    .filter { it.id == target.taskBaseline.id }
    .singleOrNull()?.destination?.trim() == target.destinationBaseline.path.trim()

internal fun downloadDestinationEditCallbackMatches(
    repositoryMatches: Boolean,
    profileMatches: Boolean,
    stateTarget: DownloadDestinationEditTarget?,
    callbackTarget: DownloadDestinationEditTarget,
    stateGeneration: Long,
    callbackGeneration: Long,
    globalGeneration: Long,
): Boolean = repositoryMatches && profileMatches && stateTarget == callbackTarget &&
    stateGeneration == callbackGeneration && globalGeneration == callbackGeneration

internal fun cancelledDownloadDestinationEditResult(): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    operation = "downloadEditDestination",
    submitted = true,
    requiresRefresh = true,
    counts = MutationResultCounts(succeeded = 0, failed = 0, unknown = 1),
    errorCategory = MutationErrorCategory.UNKNOWN,
    diagnosticTag = "download-station.edit-destination.cancelled-externally",
)

internal fun downloadDestinationEditRequiresRefreshBeforeDismiss(
    state: DownloadDestinationEditWorkspaceState,
): Boolean = state.mutationFailure != null || state.mutationResult?.let { result ->
    result.requiresRefresh || result.counts.unknown > 0 ||
        result.status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
} == true

internal fun downloadDestinationEditBlocksWorkspaceExit(
    state: DownloadDestinationEditWorkspaceState,
): Boolean {
    if (state.selectionTaskBaseline != null || state.confirmationRequested ||
        state.mutationInProgress || state.mutationRefreshInProgress
    ) {
        return true
    }
    return state.target != null && downloadDestinationEditRequiresRefreshBeforeDismiss(state) &&
        !state.mutationRefreshCompleted
}

internal fun canDismissDownloadDestinationEditMutation(
    state: DownloadDestinationEditWorkspaceState,
): Boolean = state.target != null && !state.confirmationRequested && !state.mutationInProgress &&
    !state.mutationRefreshInProgress &&
    (!downloadDestinationEditRequiresRefreshBeforeDismiss(state) || state.mutationRefreshCompleted)

internal fun canStartDownloadCreation(
    workspaceBusy: Boolean,
    state: DownloadCreationWorkspaceState,
): Boolean = !workspaceBusy && state.target == null && !state.mutationInProgress &&
    !state.mutationRefreshInProgress && state.mutationResult == null && state.mutationFailure == null

internal fun downloadCreationCallbackMatches(
    repositoryMatches: Boolean,
    profileMatches: Boolean,
    stateTarget: DownloadCreationTarget?,
    callbackTarget: DownloadCreationTarget,
    stateGeneration: Long,
    callbackGeneration: Long,
    globalGeneration: Long,
): Boolean = repositoryMatches && profileMatches && stateTarget == callbackTarget &&
    stateGeneration == callbackGeneration && globalGeneration == callbackGeneration

internal fun downloadCreationRequiresRefreshBeforeDismiss(
    state: DownloadCreationWorkspaceState,
): Boolean = state.mutationFailure != null || state.mutationResult?.let { result ->
    result.requiresRefresh || result.counts.unknown > 0 ||
        result.status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
} == true

internal fun downloadCreationBlocksWorkspaceExit(state: DownloadCreationWorkspaceState): Boolean {
    if (state.mutationInProgress || state.mutationRefreshInProgress) return true
    // 未确认结果即使已刷新也必须由用户明确“已核对，关闭”；切换 NAS/退出不能隐式清掉证据。
    return state.target != null && downloadCreationRequiresRefreshBeforeDismiss(state)
}

internal fun canDismissDownloadCreationMutation(state: DownloadCreationWorkspaceState): Boolean =
    state.target != null && !state.mutationInProgress && !state.mutationRefreshInProgress &&
        (!downloadCreationRequiresRefreshBeforeDismiss(state) || state.mutationRefreshCompleted)

internal fun downloadCreationTarget(
    profileId: String,
    sourceKind: DownloadCreationSourceKind,
    sourceIdentity: String,
    destination: String?,
): DownloadCreationTarget {
    val messageDigest = MessageDigest.getInstance("SHA-256")
    listOf(sourceKind.name, sourceIdentity, destination.orEmpty()).forEach { value ->
        val bytes = value.toByteArray(Charsets.UTF_8)
        val size = bytes.size
        messageDigest.update(
            byteArrayOf(
                (size ushr 24).toByte(),
                (size ushr 16).toByte(),
                (size ushr 8).toByte(),
                size.toByte(),
            ),
        )
        messageDigest.update(bytes)
    }
    val digest = messageDigest.digest()
        .joinToString("") { byte -> (byte.toInt() and 0xff).toString(16).padStart(2, '0') }
    return DownloadCreationTarget(
        profileId = profileId,
        sourceKind = sourceKind,
        requestFingerprint = digest,
        destination = destination,
    )
}

internal fun cancelledDownloadCreationResult(target: DownloadCreationTarget): MutationResult =
    MutationResult(
        schemaVersion = 1,
        status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        operation = if (target.sourceKind == DownloadCreationSourceKind.TASK_FILE) {
            "downloadFileCreate"
        } else {
            "downloadCreate"
        },
        submitted = true,
        requiresRefresh = true,
        counts = MutationResultCounts(succeeded = 0, failed = 0, unknown = 1),
        errorCategory = MutationErrorCategory.UNKNOWN,
        diagnosticTag = "download-station.create.cancelled-externally",
    )

internal fun downloadSettingsRequiresRefreshBeforeDismiss(
    state: DownloadSettingsWorkspaceState,
): Boolean = state.mutationFailure != null || state.mutationResult?.let { result ->
    result.requiresRefresh || result.counts.unknown > 0 ||
        result.status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
} == true

internal fun downloadSettingsBlocksWorkspaceExit(state: DownloadSettingsWorkspaceState): Boolean {
    if (state.mutationInProgress || state.mutationRefreshInProgress) return true
    // 未知或异常边界即使完成只读刷新，也必须由用户明确关闭，不能由导航隐式丢弃证据。
    return (state.mutationResult != null || state.mutationFailure != null) &&
        downloadSettingsRequiresRefreshBeforeDismiss(state)
}

internal fun canDismissDownloadSettingsMutation(state: DownloadSettingsWorkspaceState): Boolean =
    !state.mutationInProgress && !state.mutationRefreshInProgress &&
        (!downloadSettingsRequiresRefreshBeforeDismiss(state) || state.mutationRefreshCompleted)

internal fun downloadSettingsCallbackMatches(
    repositoryMatches: Boolean,
    profileMatches: Boolean,
    editorVisible: Boolean,
    stateGeneration: Long,
    callbackGeneration: Long,
    globalGeneration: Long,
): Boolean = repositoryMatches && profileMatches && editorVisible &&
    stateGeneration == callbackGeneration && globalGeneration == callbackGeneration

internal fun cancelledDownloadSettingsResult(): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
    operation = "downloadSettingsSave",
    submitted = false,
    requiresRefresh = false,
    counts = MutationResultCounts(succeeded = 0, failed = 0, unknown = 0),
    diagnosticTag = "download-station.settings.cancelled-before-submission",
)

internal fun downloadRssRefreshCallbackMatches(
    repositoryMatches: Boolean,
    profileMatches: Boolean,
    selectedModule: Module,
    selectedSiteId: String?,
    stateTarget: DownloadRssRefreshTarget?,
    callbackTarget: DownloadRssRefreshTarget,
    stateGeneration: Long,
    callbackGeneration: Long,
    globalGeneration: Long,
): Boolean = repositoryMatches && profileMatches && selectedModule == Module.DOWNLOADS &&
    selectedSiteId == callbackTarget.siteId && stateTarget == callbackTarget &&
    stateGeneration == callbackGeneration && globalGeneration == callbackGeneration

internal fun cancelledDownloadRssRefreshResult(): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
    operation = "downloadRssRefresh",
    submitted = false,
    requiresRefresh = false,
    counts = MutationResultCounts(succeeded = 0, failed = 0, unknown = 0),
    diagnosticTag = "download-station.rss-refresh.cancelled-before-submission",
)

internal fun downloadRssRefreshVerification(
    target: DownloadRssRefreshTarget,
    sites: List<DownloadRssSite>?,
    feeds: List<DownloadRssFeed>?,
): DownloadRssRefreshVerification {
    if (sites == null) return DownloadRssRefreshVerification.UNAVAILABLE
    val matches = sites.filter { it.id.trim() == target.siteId }
    return when {
        matches.isEmpty() -> DownloadRssRefreshVerification.DISAPPEARED
        matches.size != 1 -> DownloadRssRefreshVerification.DIFFERS
        feeds == null -> DownloadRssRefreshVerification.UNAVAILABLE
        matches.single().isUpdating -> DownloadRssRefreshVerification.UNAVAILABLE
        matches.single().lastUpdatedAtEpochSeconds?.let { observed ->
            target.baselineLastUpdatedAtEpochSeconds?.let { observed > it } ?: true
        } == true -> DownloadRssRefreshVerification.MATCHES
        else -> DownloadRssRefreshVerification.DIFFERS
    }
}

internal fun downloadRssRefreshRequiresReadback(
    state: DownloadRssRefreshWorkspaceState,
): Boolean = state.mutationFailure != null || state.mutationResult?.let { result ->
    result.submitted || result.requiresRefresh || result.counts.unknown > 0 ||
        result.status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
} == true

internal fun canDismissDownloadRssRefreshMutation(
    state: DownloadRssRefreshWorkspaceState,
): Boolean {
    if (state.target == null || state.mutationInProgress || state.mutationRefreshInProgress) return false
    if (!downloadRssRefreshRequiresReadback(state)) {
        return state.mutationResult != null || state.mutationFailure != null
    }
    return state.mutationRefreshCompleted && state.mutationRefreshFailure == null &&
        state.mutationVerification != null &&
        state.mutationVerification != DownloadRssRefreshVerification.UNAVAILABLE
}

internal fun downloadRssRefreshBlocksWorkspaceExit(
    state: DownloadRssRefreshWorkspaceState,
): Boolean = state.mutationInProgress || state.mutationRefreshInProgress ||
    state.target != null && downloadRssRefreshRequiresReadback(state) &&
    !state.mutationRefreshCompleted
