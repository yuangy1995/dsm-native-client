package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.net.Uri
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.WorkerParameters
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedUpload
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.contentFingerprint
import io.github.qwertyuiop1995.dsmnativeclient.data.matchesUploadContent
import io.github.qwertyuiop1995.dsmnativeclient.data.toPersistedMutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import java.io.IOException
import kotlinx.coroutines.CancellationException

/** 用户通过系统照片选择器授权后，由 WorkManager 执行的单项备份。 */
class PhotoBackupWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    private val transfers = TransferStore(appContext)

    override suspend fun doWork(): Result {
        val taskId = inputData.getString(KEY_TASK_ID) ?: return Result.failure()
        val initial = transfers.upload(taskId) ?: return Result.failure()
        val executionId = id.toString()
        if (!initial.ownsUploadExecution(executionId)) return Result.success()
        // 目录任务不能被旧的单文件执行器当成树 URI 文件上传。
        if (runCatching { transfers.folderUploadPlan(taskId) }.fold({ it != null }, { true })) return Result.failure()
        if (initial.state !in setOf(TransferState.WAITING, TransferState.RUNNING)) {
            return Result.success(progressData(initial.completedBytes, initial.expectedBytes))
        }
        val openTaskIntent = TransferNotifications.openAppIntent(applicationContext, taskId,
            io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind.UPLOAD)
        setForeground(
            TransferNotifications.foreground(
                applicationContext,
                taskId,
                id,
                TransferState.WAITING,
                initial.completedBytes,
                initial.expectedBytes,
                TransferDirection.UPLOAD,
                openTaskIntent = openTaskIntent,
            ),
        )
        if (initial.state == TransferState.RUNNING) {
            val interrupted = transfers.updateUpload(taskId) { current ->
                current.applyUploadMutationResult(
                    executionId,
                    interruptedUploadResult(),
                    UploadMutationStage.UPLOAD,
                )
            }
            notifyMutationCompletion(taskId, interrupted)
            return Result.failure(
                errorData(interrupted?.errorKind ?: DsmErrorKind.CHANGE_NOT_CONFIRMED.name),
            )
        }
        val running = transfers.updateUpload(taskId) { current ->
            if (!current.ownsUploadExecution(executionId) ||
                current.state !in setOf(TransferState.WAITING, TransferState.RUNNING)
            ) {
                current
            } else {
                current.copy(
                    state = TransferState.RUNNING,
                    completedBytes = 0,
                    errorKind = null,
                    requiresRefresh = false,
                    startedAtEpochMillis = System.currentTimeMillis(),
                    directoryMutationResult = null,
                    uploadMutationResult = null,
                )
            }
        }
        if (running?.ownsUploadExecution(executionId) != true ||
            running.state != TransferState.RUNNING
        ) {
            return Result.success(progressData(running?.completedBytes ?: 0, initial.expectedBytes))
        }
        var uploadAttemptStarted = false
        return try {
            val repo = repository(initial)
            if (initial.backupMode || initial.mirrorDirectories) {
                val directoryResult = repo.ensureSubdirectoryResult(
                    initial.destinationRootPath,
                    initial.destinationPath,
                )
                val prepared = transfers.updateUpload(taskId) { current ->
                    current.applyUploadMutationResult(
                        executionId,
                        directoryResult,
                        UploadMutationStage.DIRECTORY,
                    )
                }
                if (directoryResult.status != MutationResultStatus.CONFIRMED_SUCCESS) {
                    notifyMutationCompletion(taskId, prepared)
                    return if (prepared?.state == TransferState.CANCELLED) {
                        Result.success(progressData(prepared.completedBytes, initial.expectedBytes))
                    } else {
                        Result.failure(errorData(prepared?.errorKind ?: DsmErrorKind.UPLOAD_FAILED.name))
                    }
                }
                if (prepared?.ownsUploadExecution(executionId) != true ||
                    prepared.state != TransferState.RUNNING
                ) {
                    return Result.success(progressData(prepared?.completedBytes ?: 0, initial.expectedBytes))
                }
            }
            val uri = Uri.parse(initial.sourceUri)
            val source = UploadSource(
                displayName = initial.title,
                contentType = initial.contentType,
                contentLength = initial.expectedBytes,
                openInputStream = {
                    applicationContext.contentResolver.openInputStream(uri)
                        ?: throw IOException("The selected photo is no longer available")
                },
                onContentRead = { fingerprint ->
                    try { repo.requireCurrentOwner() } catch (failure: DsmFailure) {
                        throw IOException("Upload connection changed", failure)
                    }
                    transfers.saveUploadContent(initial, executionId, fingerprint)
                },
            )
            val targetPath = initial.destinationPath.trimEnd('/') + "/" + initial.title
            val existing = if (repo.itemExists(targetPath)) repo.fileInfo(targetPath) else null
            var decision = if (initial.backupMode) {
                backupTargetDecision(existing, initial.expectedBytes)
            } else {
                userUploadTargetDecision(existing, initial.overwrite)
            }
            if (decision == BackupTargetDecision.VERIFY_CONTENT) {
                decision = if (repo.matchesUploadContent(requireNotNull(existing), source.contentFingerprint())) {
                    BackupTargetDecision.SKIP_MATCHING
                } else BackupTargetDecision.CONFLICT
            }
            when (decision) {
                BackupTargetDecision.SKIP_MATCHING -> {
                    transfers.updateUpload(taskId) { current ->
                        current.completeUploadExecution(executionId, skippedExisting = true)
                    }
                    return Result.success(progressData(initial.expectedBytes, initial.expectedBytes))
                }
                BackupTargetDecision.CONFLICT -> {
                    val conflict = transfers.updateUpload(taskId) { current ->
                        current.applyUploadMutationResult(
                            executionId,
                            uploadTargetConflictResult(),
                            UploadMutationStage.UPLOAD,
                        )
                    }
                    notifyMutationCompletion(taskId, conflict)
                    return Result.failure(
                        errorData(conflict?.errorKind ?: DsmErrorKind.CHANGE_NOT_CONFIRMED.name),
                    )
                }
                BackupTargetDecision.UPLOAD -> Unit
                BackupTargetDecision.VERIFY_CONTENT -> error("Content must be checked before deciding")
            }
            var lastPublishedAt = 0L
            uploadAttemptStarted = true
            val uploadResult = repo.uploadResult(
                source,
                initial.destinationPath,
                overwrite = initial.overwrite,
            ) { completed, total ->
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastPublishedAt >= PROGRESS_INTERVAL_MILLIS || completed == total) {
                    lastPublishedAt = now
                    transfers.updateUpload(taskId) { current ->
                        if (current.ownsUploadExecution(executionId) &&
                            current.state == TransferState.RUNNING
                        ) {
                            current.copy(completedBytes = completed)
                        } else {
                            current
                        }
                    }
                    setProgressAsync(progressData(completed, total))
                    setForegroundAsync(
                        TransferNotifications.foreground(
                            applicationContext,
                            taskId,
                            id,
                            TransferState.RUNNING,
                            completed,
                            total,
                            TransferDirection.UPLOAD,
                            openTaskIntent = openTaskIntent,
                        ),
                    )
                }
            }
            val completed = transfers.updateUpload(taskId) { current ->
                current.applyUploadMutationResult(
                    executionId,
                    uploadResult,
                    UploadMutationStage.UPLOAD,
                )
            }
            notifyMutationCompletion(taskId, completed)
            when (completed?.state) {
                TransferState.SUCCEEDED ->
                    Result.success(progressData(initial.expectedBytes, initial.expectedBytes))
                TransferState.CANCELLED ->
                    Result.success(progressData(completed.completedBytes, initial.expectedBytes))
                TransferState.FAILED ->
                    Result.failure(errorData(completed.errorKind ?: DsmErrorKind.UPLOAD_FAILED.name))
                else -> Result.success(progressData(completed?.completedBytes ?: 0, initial.expectedBytes))
            }
        } catch (error: CancellationException) {
            transfers.updateUpload(taskId) { current ->
                current.cancelUploadExecution(executionId, uploadAttemptStarted)
            }
            throw error
        } catch (error: Throwable) {
            val kind = (error as? DsmFailure)?.kind ?: DsmErrorKind.UPLOAD_FAILED
            val failed = transfers.updateUpload(taskId) { current ->
                if (!current.ownsUploadExecution(executionId) ||
                    current.state != TransferState.RUNNING
                ) {
                    current
                } else {
                    current.copy(
                        state = if (kind == DsmErrorKind.WORKSPACE_CHANGED) TransferState.PAUSED else TransferState.FAILED,
                        errorKind = kind.name,
                        requiresRefresh = current.requiresRefresh || uploadAttemptStarted && (
                            current.completedBytes > 0 || kind in setOf(
                                DsmErrorKind.WORKSPACE_CHANGED,
                                DsmErrorKind.CONNECTION_FAILED,
                                DsmErrorKind.INVALID_RESPONSE,
                                DsmErrorKind.CHANGE_NOT_CONFIRMED,
                                DsmErrorKind.UPLOAD_LENGTH_MISMATCH,
                            )
                        ),
                    )
                }
            }
            if (failed?.ownsUploadExecution(executionId) == true &&
                failed.state == TransferState.FAILED
            ) {
                notifyMutationCompletion(taskId, failed)
            }
            Result.failure(Data.Builder().putString(KEY_ERROR_KIND, kind.name).build())
        }
    }

    private fun notifyMutationCompletion(taskId: String, upload: PersistedUpload?) {
        val state = upload?.state ?: return
        if (!upload.ownsUploadExecution(id.toString()) || state !in setOf(
                TransferState.SUCCEEDED,
                TransferState.FAILED,
                TransferState.CANCELLED,
            )
        ) return
        TransferNotifications.completion(
            applicationContext,
            taskId,
            outcome = when {
                state == TransferState.SUCCEEDED -> TransferCompletionOutcome.SUCCESS
                upload.requiresRefresh -> TransferCompletionOutcome.NEEDS_REVIEW
                state == TransferState.CANCELLED -> TransferCompletionOutcome.CANCELLED
                else -> TransferCompletionOutcome.FAILURE
            },
            direction = TransferDirection.UPLOAD,
        )
    }

    private suspend fun repository(upload: PersistedUpload): DsmRepository =
        restoreTaskRepository(applicationContext,
            io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind.UPLOAD, upload.id, upload.profileId)

    companion object {
        const val KEY_TASK_ID = "task_id"
        const val KEY_COMPLETED_BYTES = "completed_bytes"
        const val KEY_TOTAL_BYTES = "total_bytes"
        const val KEY_ERROR_KIND = "error_kind"
        const val UNIQUE_WORK_PREFIX = "photo-backup-"
        const val FILE_UPLOAD_UNIQUE_WORK_PREFIX = "file-upload-"
        private const val PROGRESS_INTERVAL_MILLIS = 400L

        fun progressData(completed: Long, total: Long): Data = Data.Builder()
            .putLong(KEY_COMPLETED_BYTES, completed)
            .putLong(KEY_TOTAL_BYTES, total)
            .build()

        private fun errorData(kind: String): Data = Data.Builder()
            .putString(KEY_ERROR_KIND, kind)
            .build()
    }
}

internal enum class BackupTargetDecision { VERIFY_CONTENT, UPLOAD, SKIP_MATCHING, CONFLICT }

internal fun interruptedUploadResult(): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    operation = "fileUpload",
    submitted = true,
    requiresRefresh = true,
    counts = MutationResultCounts(0, 0, 1),
    errorCategory = MutationErrorCategory.UNKNOWN,
    diagnosticTag = "file-station.upload.worker-restarted-after-running",
)

internal fun uploadTargetConflictResult(): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.CONFIRMED_FAILURE,
    operation = "fileUpload",
    submitted = false,
    requiresRefresh = false,
    counts = MutationResultCounts(0, 1, 0),
    errorCategory = MutationErrorCategory.CONFLICT,
    diagnosticTag = "file-station.upload.target-conflict",
)

internal fun backupTargetDecision(
    existing: io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem?,
    expectedBytes: Long,
): BackupTargetDecision = when {
    existing == null -> BackupTargetDecision.UPLOAD
    !existing.isDirectory && existing.size == expectedBytes -> BackupTargetDecision.VERIFY_CONTENT
    else -> BackupTargetDecision.CONFLICT
}

internal fun userUploadTargetDecision(
    existing: io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem?,
    overwrite: Boolean,
): BackupTargetDecision = when {
    existing == null -> BackupTargetDecision.UPLOAD
    overwrite && !existing.isDirectory -> BackupTargetDecision.UPLOAD
    else -> BackupTargetDecision.CONFLICT
}

internal fun PersistedUpload.ownsUploadExecution(executionId: String): Boolean =
    workId.isCurrentDownloadExecution(executionId)

internal fun PersistedUpload.cancelUploadExecution(executionId: String, attemptStarted: Boolean = false): PersistedUpload =
    if (workerCancellationDecision(state, workId, executionId) ==
        WorkerCancellationDecision.USER_CANCELLATION
    ) {
        copy(
            state = TransferState.CANCELLED,
            errorKind = null,
            requiresRefresh = requiresRefresh || directoryMutationResult?.requiresRefresh == true ||
                uploadMutationResult?.requiresRefresh == true || attemptStarted || completedBytes > 0,
        )
    } else {
        this
    }

internal fun PersistedUpload.completeUploadExecution(
    executionId: String,
    skippedExisting: Boolean,
): PersistedUpload = if (ownsUploadExecution(executionId) && state == TransferState.RUNNING) {
    copy(
        state = TransferState.SUCCEEDED,
        completedBytes = expectedBytes,
        errorKind = null,
        skippedExisting = skippedExisting,
        requiresRefresh = false,
    )
} else {
    this
}

internal enum class UploadMutationStage { DIRECTORY, UPLOAD }

internal fun PersistedUpload.applyUploadMutationResult(
    executionId: String,
    result: MutationResult,
    stage: UploadMutationStage,
): PersistedUpload {
    if (!ownsUploadExecution(executionId) || state !in setOf(
            TransferState.RUNNING,
            TransferState.CANCELLING,
        )
    ) return this
    val persisted = result.toPersistedMutationResult(
        writeSubmitted = when (stage) {
            UploadMutationStage.DIRECTORY -> result.submitted &&
                result.diagnosticTag != "file-station.backup-folder.ensure.already-satisfied" &&
                result.diagnosticTag?.endsWith(".readback-only") != true
            UploadMutationStage.UPLOAD -> result.submitted
        },
    )
    val resultFields: PersistedUpload.() -> PersistedUpload = {
        when (stage) {
            UploadMutationStage.DIRECTORY -> copy(directoryMutationResult = persisted)
            UploadMutationStage.UPLOAD -> copy(uploadMutationResult = persisted)
        }
    }
    val withResult = resultFields()
    if (result.status == MutationResultStatus.CONFIRMED_SUCCESS) {
        return if (stage == UploadMutationStage.DIRECTORY) {
            withResult
        } else {
            withResult.copy(
                state = TransferState.SUCCEEDED,
                completedBytes = expectedBytes,
                errorKind = null,
                skippedExisting = false,
                requiresRefresh = false,
            )
        }
    }
    val cancelled = state == TransferState.CANCELLING || result.status in setOf(
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    )
    val needsRefresh = result.requiresRefresh || result.counts.unknown > 0 ||
        result.status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
    return withResult.copy(
        state = if (cancelled) TransferState.CANCELLED else TransferState.FAILED,
        errorKind = if (cancelled && !needsRefresh) null else result.uploadErrorKind().name,
        requiresRefresh = needsRefresh,
    )
}

private fun MutationResult.uploadErrorKind(): DsmErrorKind = when {
    errorCategory == MutationErrorCategory.PERMISSION -> DsmErrorKind.PERMISSION_DENIED
    errorCategory == MutationErrorCategory.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
    requiresRefresh || counts.unknown > 0 || submitted -> DsmErrorKind.CHANGE_NOT_CONFIRMED
    else -> DsmErrorKind.UPLOAD_FAILED
}
