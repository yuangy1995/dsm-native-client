package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskSummary
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationExpectedOutput
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationTarget
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationVerification
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import kotlinx.serialization.Serializable

@Serializable
data class PersistedDownload(
    val id: String,
    val profileId: String,
    val sourcePath: String,
    val title: String,
    val destinationUri: String,
    val isDirectory: Boolean,
    val expectedBytes: Long? = null,
    val state: TransferState = TransferState.WAITING,
    val completedBytes: Long = 0,
    val totalBytes: Long? = expectedBytes,
    val errorKind: String? = null,
    val workId: String? = null,
    val backgroundCapable: Boolean = false,
    val startedAtEpochMillis: Long? = null,
)

@Serializable
data class PersistedUpload(
    val id: String,
    val profileId: String,
    val sourceUri: String,
    val title: String,
    val contentType: String? = null,
    val expectedBytes: Long,
    val destinationPath: String,
    val destinationRootPath: String = destinationPath,
    val state: TransferState = TransferState.WAITING,
    val completedBytes: Long = 0,
    val errorKind: String? = null,
    val workId: String? = null,
    val skippedExisting: Boolean = false,
    val ownsPersistedReadGrant: Boolean = true,
    val sourceTreeUri: String? = null,
    val backupMode: Boolean = true,
    val overwrite: Boolean = false,
    val requiresRefresh: Boolean = false,
    val mirrorDirectories: Boolean = false,
    val startedAtEpochMillis: Long? = null,
    val directoryMutationResult: PersistedMutationResult? = null,
    val uploadMutationResult: PersistedMutationResult? = null,
)

/** NAS 写任务的请求边界；恢复后只有 `PREPARING` 能确认尚未提交。 */
@Serializable
enum class PersistedServerSubmissionPhase {
    PREPARING,
    SUBMITTING,
    SUBMITTED,
    TERMINAL,
}

@Serializable
enum class PersistedServerOperation {
    COMPRESS,
    EXTRACT,
}

/** 恢复目标核对所需的文件基线；内容只保存在现有加密传输存储中。 */
@Serializable
data class PersistedServerFileBaseline(
    val path: String,
    val name: String,
    val isDirectory: Boolean,
    val size: Long = 0,
    val modifiedAtEpochSeconds: Long? = null,
    val owner: String? = null,
    val canRead: Boolean = true,
    val canWrite: Boolean = false,
    val canDelete: Boolean = false,
    val mountPointType: String? = null,
)

@Serializable
data class PersistedServerExpectedOutput(
    val path: String,
    val isDirectory: Boolean,
    val requiresNonEmptyFile: Boolean = false,
)

/**
 * App 发起、由 NAS 执行的任务状态。opaque task ID 只用于恢复只读轮询，不包含会话或地址。
 */
@Serializable
data class PersistedServerTransfer(
    val id: String,
    val profileId: String,
    val title: String,
    val operation: PersistedServerOperation,
    val state: TransferState = TransferState.WAITING,
    val submissionPhase: PersistedServerSubmissionPhase = PersistedServerSubmissionPhase.PREPARING,
    val executionGeneration: Long = 0,
    val readOnlyObservation: Boolean = false,
    val nasTaskId: String? = null,
    val completedUnits: Long = 0,
    val totalUnits: Long? = null,
    val startedAtEpochMillis: Long? = null,
    val requiresRefresh: Boolean = false,
    val errorKind: String? = null,
    val sourceModule: String = Module.FILES.name,
    val sourceBaselines: List<PersistedServerFileBaseline> = emptyList(),
    val destinationFolderBaseline: PersistedServerFileBaseline? = null,
    val expectedOutputs: List<PersistedServerExpectedOutput> = emptyList(),
    val mutationResult: PersistedMutationResult? = null,
    val refreshCompleted: Boolean = false,
    val verification: String? = null,
    val refreshFailureKind: String? = null,
)

/** 官方 BackgroundTask 的脱敏快照；不保存路径、参数、消息或响应正文。 */
@Serializable
data class PersistedFileBackgroundTaskSnapshot(
    val profileId: String,
    val observedAtEpochSeconds: Long,
    val tasks: List<PersistedFileBackgroundTaskSummary> = emptyList(),
)

@Serializable
data class PersistedFileBackgroundTaskSummary(
    val id: String,
    val kind: PersistedFileBackgroundTaskKind,
    val state: PersistedFileBackgroundTaskState,
    val progress: Double? = null,
    val createdAtEpochSeconds: Long? = null,
    val processedItemCount: Int? = null,
    val totalItemCount: Int? = null,
    val processedBytes: Long? = null,
    val totalBytes: Long? = null,
)

@Serializable
enum class PersistedFileBackgroundTaskKind {
    COPY_OR_MOVE,
    DELETE,
    COMPRESS,
    EXTRACT,
}

@Serializable
enum class PersistedFileBackgroundTaskState {
    ACTIVE,
    FINISHED,
}

/** 仅保留恢复与结果展示所需的稳定语义，不保存响应、路径、凭据或用户数据。 */
@Serializable
data class PersistedMutationResult(
    val status: MutationResultStatus = MutationResultStatus.CONFIRMED_FAILURE,
    val submitted: Boolean = false,
    val requiresRefresh: Boolean = false,
    val counts: MutationResultCounts = MutationResultCounts(0, 0, 0),
    val errorCategory: MutationErrorCategory? = null,
    val diagnosticTag: String? = null,
    val writeSubmitted: Boolean = false,
)

internal fun MutationResult.toPersistedMutationResult(
    writeSubmitted: Boolean = submitted,
) = PersistedMutationResult(
    status = status,
    submitted = submitted,
    requiresRefresh = requiresRefresh,
    counts = counts,
    errorCategory = errorCategory,
    diagnosticTag = diagnosticTag,
    writeSubmitted = writeSubmitted,
)

internal fun PersistedMutationResult.toMutationResult(operation: String) = MutationResult(
    schemaVersion = 1,
    status = status,
    operation = operation,
    submitted = submitted,
    requiresRefresh = requiresRefresh,
    counts = counts,
    errorCategory = errorCategory,
    diagnosticTag = diagnosticTag,
)

internal fun FileItem.toPersistedServerFileBaseline() = PersistedServerFileBaseline(
    path = path,
    name = name,
    isDirectory = isDirectory,
    size = size,
    modifiedAtEpochSeconds = modifiedAtEpochSeconds,
    owner = owner,
    canRead = canRead,
    canWrite = canWrite,
    canDelete = canDelete,
    mountPointType = mountPointType,
)

internal fun PersistedServerFileBaseline.toFileItem() = FileItem(
    path = path,
    name = name,
    isDirectory = isDirectory,
    size = size,
    modifiedAtEpochSeconds = modifiedAtEpochSeconds,
    owner = owner,
    canRead = canRead,
    canWrite = canWrite,
    canDelete = canDelete,
    mountPointType = mountPointType,
)

internal fun FileServerMutationExpectedOutput.toPersistedServerExpectedOutput() =
    PersistedServerExpectedOutput(path, isDirectory, requiresNonEmptyFile)

internal fun PersistedServerExpectedOutput.toFileServerMutationExpectedOutput() =
    FileServerMutationExpectedOutput(path, isDirectory, requiresNonEmptyFile)

internal fun FileServerMutationOperation.toPersistedServerOperation() = when (this) {
    FileServerMutationOperation.COMPRESS -> PersistedServerOperation.COMPRESS
    FileServerMutationOperation.EXTRACT -> PersistedServerOperation.EXTRACT
}

internal fun PersistedServerOperation.toFileServerMutationOperation() = when (this) {
    PersistedServerOperation.COMPRESS -> FileServerMutationOperation.COMPRESS
    PersistedServerOperation.EXTRACT -> FileServerMutationOperation.EXTRACT
}

internal fun FileServerMutationTarget.toPersistedServerTransfer(
    id: String,
    title: String,
    state: TransferState = TransferState.WAITING,
    submissionPhase: PersistedServerSubmissionPhase = PersistedServerSubmissionPhase.PREPARING,
    startedAtEpochMillis: Long? = null,
) = PersistedServerTransfer(
    id = id,
    profileId = profileId,
    title = title,
    operation = operation.toPersistedServerOperation(),
    state = state,
    submissionPhase = submissionPhase,
    startedAtEpochMillis = startedAtEpochMillis,
    sourceModule = module.name,
    sourceBaselines = sourceBaselines.map(FileItem::toPersistedServerFileBaseline),
    destinationFolderBaseline = destinationFolderBaseline.toPersistedServerFileBaseline(),
    expectedOutputs = expectedOutputs.map(
        FileServerMutationExpectedOutput::toPersistedServerExpectedOutput,
    ),
)

internal fun PersistedServerTransfer.toFileServerMutationTarget(): FileServerMutationTarget? {
    val destination = destinationFolderBaseline ?: return null
    val module = runCatching { Module.valueOf(sourceModule) }.getOrNull() ?: return null
    return FileServerMutationTarget(
        profileId = profileId,
        module = module,
        operation = operation.toFileServerMutationOperation(),
        sourceBaselines = sourceBaselines.map(PersistedServerFileBaseline::toFileItem),
        destinationFolderBaseline = destination.toFileItem(),
        expectedOutputs = expectedOutputs.map(
            PersistedServerExpectedOutput::toFileServerMutationExpectedOutput,
        ),
    )
}

internal fun PersistedServerTransfer.toFileServerMutationVerification(): FileServerMutationVerification? =
    verification?.let { value ->
        runCatching { FileServerMutationVerification.valueOf(value) }.getOrNull()
    }

internal fun FileBackgroundTaskPage.toPersistedFileBackgroundTaskSnapshot(
    profileId: String,
    observedAtEpochSeconds: Long,
) = PersistedFileBackgroundTaskSnapshot(
    profileId = profileId,
    observedAtEpochSeconds = observedAtEpochSeconds,
    tasks = tasks.map(FileBackgroundTaskSummary::toPersistedFileBackgroundTaskSummary),
)

internal fun FileBackgroundTaskSummary.toPersistedFileBackgroundTaskSummary() =
    PersistedFileBackgroundTaskSummary(
        id = id,
        kind = kind.toPersistedFileBackgroundTaskKind(),
        state = state.toPersistedFileBackgroundTaskState(),
        progress = progress,
        createdAtEpochSeconds = createdAtEpochSeconds,
        processedItemCount = processedItemCount,
        totalItemCount = totalItemCount,
        processedBytes = processedBytes,
        totalBytes = totalBytes,
    )

internal fun PersistedFileBackgroundTaskSnapshot.toFileBackgroundTaskPage() = FileBackgroundTaskPage(
    tasks = tasks.map { task ->
        FileBackgroundTaskSummary(
            id = task.id,
            kind = task.kind.toFileBackgroundTaskKind(),
            state = task.state.toFileBackgroundTaskState(),
            progress = task.progress,
            createdAtEpochSeconds = task.createdAtEpochSeconds,
            processedItemCount = task.processedItemCount,
            totalItemCount = task.totalItemCount,
            processedBytes = task.processedBytes,
            totalBytes = task.totalBytes,
        )
    },
    offset = 0,
    nextOffset = tasks.size,
    total = tasks.size,
    hasMore = false,
)

internal fun FileBackgroundTaskKind.toPersistedFileBackgroundTaskKind() = when (this) {
    FileBackgroundTaskKind.COPY_OR_MOVE -> PersistedFileBackgroundTaskKind.COPY_OR_MOVE
    FileBackgroundTaskKind.DELETE -> PersistedFileBackgroundTaskKind.DELETE
    FileBackgroundTaskKind.COMPRESS -> PersistedFileBackgroundTaskKind.COMPRESS
    FileBackgroundTaskKind.EXTRACT -> PersistedFileBackgroundTaskKind.EXTRACT
}

internal fun PersistedFileBackgroundTaskKind.toFileBackgroundTaskKind() = when (this) {
    PersistedFileBackgroundTaskKind.COPY_OR_MOVE -> FileBackgroundTaskKind.COPY_OR_MOVE
    PersistedFileBackgroundTaskKind.DELETE -> FileBackgroundTaskKind.DELETE
    PersistedFileBackgroundTaskKind.COMPRESS -> FileBackgroundTaskKind.COMPRESS
    PersistedFileBackgroundTaskKind.EXTRACT -> FileBackgroundTaskKind.EXTRACT
}

internal fun FileBackgroundTaskState.toPersistedFileBackgroundTaskState() = when (this) {
    FileBackgroundTaskState.ACTIVE -> PersistedFileBackgroundTaskState.ACTIVE
    FileBackgroundTaskState.FINISHED -> PersistedFileBackgroundTaskState.FINISHED
}

internal fun PersistedFileBackgroundTaskState.toFileBackgroundTaskState() = when (this) {
    PersistedFileBackgroundTaskState.ACTIVE -> FileBackgroundTaskState.ACTIVE
    PersistedFileBackgroundTaskState.FINISHED -> FileBackgroundTaskState.FINISHED
}

@Serializable
data class PersistedPhotoBackupSource(
    val profileId: String,
    val treeUri: String,
    val destinationPath: String,
    val workId: String? = null,
    val enabled: Boolean = true,
    /** 扫描上限触发后暂停来源，要求用户选择更小的目录再继续。 */
    val needsAttention: Boolean = false,
    /** 新来源独立标识；旧记录没有可证明的账号归属，必须重新选择来源。 */
    val sourceId: String? = null,
)

internal fun TransferState.hasIncompleteDownloadDestination(): Boolean = this !in setOf(
    TransferState.SUCCEEDED,
    TransferState.FAILED,
    TransferState.CANCELLED,
)

internal fun PersistedUpload.canRemoveFinishedUpload(): Boolean =
    state in setOf(TransferState.SUCCEEDED, TransferState.FAILED, TransferState.CANCELLED) &&
        !requiresRefresh

internal fun PersistedServerTransfer.canRemoveFinishedServer(): Boolean =
    state in setOf(TransferState.SUCCEEDED, TransferState.FAILED, TransferState.CANCELLED) &&
        submissionPhase == PersistedServerSubmissionPhase.TERMINAL &&
        !requiresRefresh && (mutationResult?.requiresRefresh != true || refreshCompleted)
