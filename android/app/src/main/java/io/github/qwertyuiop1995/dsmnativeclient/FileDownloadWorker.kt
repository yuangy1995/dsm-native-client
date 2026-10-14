package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.net.Uri
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.WorkerParameters
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedDownload
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import java.io.IOException
import io.github.qwertyuiop1995.dsmnativeclient.data.isArchiveDownload
import kotlinx.coroutines.CancellationException

class FileDownloadWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    private val transfers = TransferStore(appContext)
    private val transferUris = TransferUriAccess(appContext, transfers)

    override suspend fun doWork(): Result {
        val taskId = inputData.getString(KEY_TASK_ID) ?: return Result.failure()
        val initial = transfers.download(taskId) ?: return Result.failure()
        val executionId = id.toString()
        if (!initial.ownsDownloadExecution(executionId)) return Result.success()
        if (initial.state !in setOf(TransferState.WAITING, TransferState.RUNNING)) {
            return Result.success(progressData(initial.completedBytes, initial.totalBytes))
        }
        val destination = Uri.parse(initial.destinationUri)
        val openTaskIntent = TransferNotifications.openAppIntent(applicationContext, taskId,
            io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind.DOWNLOAD)
        setForeground(
            TransferNotifications.foreground(
                applicationContext,
                taskId,
                id,
                TransferState.WAITING,
                initial.completedBytes,
                initial.totalBytes,
                openTaskIntent = openTaskIntent,
            ),
        )
        val running = transfers.update(taskId) { current ->
            if (!current.ownsDownloadExecution(executionId) ||
                current.state !in setOf(TransferState.WAITING, TransferState.RUNNING)
            ) {
                current
            } else {
                current.copy(
                    state = TransferState.RUNNING,
                    errorKind = null,
                    startedAtEpochMillis = System.currentTimeMillis(),
                )
            }
        } ?: return Result.failure()
        if (!running.ownsDownloadExecution(executionId) || running.state != TransferState.RUNNING) {
            return Result.success(progressData(running.completedBytes, running.totalBytes))
        }
        return try {
            val repo = repository(initial)
            var lastPublishedAt = 0L
            val written = executeFileDownload(applicationContext, repo, initial, transfers,
                requireExactResume = inputData.getBoolean(KEY_REQUIRE_EXACT_RESUME, false),
                requireActive = {
                    val current = transfers.download(taskId)
                    if (current?.ownsDownloadExecution(executionId) != true || current.state != TransferState.RUNNING)
                        throw CancellationException("Download execution changed")
                },
                onReset = { transfers.update(taskId) { current ->
                    if (current.ownsDownloadExecution(executionId)) current.copy(completedBytes = 0, totalBytes = current.expectedBytes) else current
                } },
            ) { completed, total ->
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastPublishedAt >= PROGRESS_INTERVAL_MILLIS || completed == total) {
                    lastPublishedAt = now
                    val resolvedTotal = total ?: initial.expectedBytes
                    transfers.update(taskId) { current ->
                        if (current.ownsDownloadExecution(executionId)) {
                            current.copy(completedBytes = completed, totalBytes = resolvedTotal)
                        } else {
                            current
                        }
                    }
                    setProgressAsync(progressData(completed, resolvedTotal))
                    setForegroundAsync(
                        TransferNotifications.foreground(
                            applicationContext,
                            taskId,
                            id,
                            TransferState.RUNNING,
                            completed,
                            resolvedTotal,
                            openTaskIntent = openTaskIntent,
                        ),
                    )
                }
            }
            val completed = transfers.update(taskId) { current ->
                if (current.ownsDownloadExecution(executionId) && current.state == TransferState.RUNNING) {
                    current.copy(completedBytes = written, totalBytes = written).completeDownloadExecution(executionId)
                } else current
            }
            if (completed?.ownsDownloadExecution(executionId) == true &&
                completed.state == TransferState.SUCCEEDED
            ) {
                releaseDestinationPermission(destination)
                TransferNotifications.completion(applicationContext, taskId, succeeded = true)
            }
            Result.success(
                progressData(
                    completed?.completedBytes ?: 0,
                    completed?.totalBytes,
                ),
            )
        } catch (error: CancellationException) {
            val cancelled = transfers.update(taskId) { current ->
                current.cancelDownloadExecution(executionId)
            }
            if (cancelled?.ownsDownloadExecution(executionId) == true &&
                cancelled.state == TransferState.CANCELLED
            ) {
                deleteIncomplete(destination)
                releaseDestinationPermission(destination)
            }
            throw error
        } catch (error: Throwable) {
            val kind = downloadFailureKind(error)
            val failed = transfers.update(taskId) { current ->
                if (!current.ownsDownloadExecution(executionId) ||
                    current.state != TransferState.RUNNING
                ) {
                    current
                } else {
                    current.copy(state = if (kind == DsmErrorKind.WORKSPACE_CHANGED) TransferState.PAUSED else TransferState.FAILED,
                        errorKind = kind.name)
                }
            }
            if (failed?.ownsDownloadExecution(executionId) == true &&
                failed.state == TransferState.FAILED
            ) {
                if (failed.shouldDeleteFailedDownload(executionId)) {
                    deleteIncomplete(destination)
                    releaseDestinationPermission(destination)
                }
                TransferNotifications.completion(applicationContext, taskId, succeeded = false)
            }
            Result.failure(Data.Builder().putString(KEY_ERROR_KIND, kind.name).build())
        }
    }

    private suspend fun repository(download: PersistedDownload): DsmRepository =
        restoreTaskRepository(applicationContext,
            io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind.DOWNLOAD, download.id, download.profileId)

    private fun deleteIncomplete(destination: Uri) = transferUris.deleteIncomplete(destination, inputData.getString(KEY_TASK_ID))
    private fun releaseDestinationPermission(destination: Uri) = transferUris.releaseDownload(destination, inputData.getString(KEY_TASK_ID))

    companion object {
        const val KEY_TASK_ID = "task_id"
        const val KEY_COMPLETED_BYTES = "completed_bytes"
        const val KEY_TOTAL_BYTES = "total_bytes"
        const val KEY_HAS_TOTAL = "has_total"
        const val KEY_ERROR_KIND = "error_kind"
        const val KEY_REQUIRE_EXACT_RESUME = "require_exact_resume"
        const val UNIQUE_WORK_PREFIX = "file-download-"
        private const val PROGRESS_INTERVAL_MILLIS = 400L

        fun progressData(completed: Long, total: Long?): Data = Data.Builder()
            .putLong(KEY_COMPLETED_BYTES, completed)
            .putLong(KEY_TOTAL_BYTES, total ?: 0)
            .putBoolean(KEY_HAS_TOTAL, total != null)
            .build()
    }
}

internal fun PersistedDownload.canPauseDownload(): Boolean =
    (!isDirectory || isArchiveDownload) && state in setOf(TransferState.WAITING, TransferState.RUNNING)

internal fun PersistedDownload.canResumeDownload(): Boolean =
    (!isDirectory || isArchiveDownload) && state == TransferState.PAUSED

internal fun PersistedDownload.canRetryDownload(): Boolean =
    state == TransferState.FAILED && (!isDirectory || isArchiveDownload) &&
        errorKind != DsmErrorKind.DOWNLOAD_SOURCE_UNAVAILABLE.name

internal fun PersistedDownload.ownsDownloadExecution(executionId: String): Boolean =
    workId.isCurrentDownloadExecution(executionId)

internal fun String?.isCurrentDownloadExecution(executionId: String): Boolean =
    this == executionId

internal enum class WorkerCancellationDecision {
    USER_CANCELLATION,
    PRESERVE_CURRENT_STATE,
}

internal fun workerCancellationDecision(
    state: TransferState,
    currentExecutionId: String?,
    cancelledExecutionId: String,
): WorkerCancellationDecision = if (
    state == TransferState.CANCELLING &&
    currentExecutionId.isCurrentDownloadExecution(cancelledExecutionId)
) {
    WorkerCancellationDecision.USER_CANCELLATION
} else {
    WorkerCancellationDecision.PRESERVE_CURRENT_STATE
}

internal fun shouldDeleteCancelledDownload(
    state: TransferState,
    currentExecutionId: String?,
    cancelledExecutionId: String,
): Boolean = workerCancellationDecision(state, currentExecutionId, cancelledExecutionId) ==
    WorkerCancellationDecision.USER_CANCELLATION

internal fun PersistedDownload.shouldDeleteFailedDownload(executionId: String): Boolean =
    isDirectory && !isArchiveDownload && state == TransferState.FAILED && ownsDownloadExecution(executionId)

internal fun downloadFailureKind(error: Throwable): DsmErrorKind =
    if (error is io.github.qwertyuiop1995.dsmnativeclient.data.ArchiveDownloadPlanUnavailable ||
        error is io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadPlanUnavailable)
        DsmErrorKind.DOWNLOAD_SOURCE_UNAVAILABLE else (error as? DsmFailure)?.kind ?: DsmErrorKind.DOWNLOAD_FAILED

internal fun PersistedDownload.cancelDownloadExecution(executionId: String): PersistedDownload =
    if (workerCancellationDecision(state, workId, executionId) ==
        WorkerCancellationDecision.USER_CANCELLATION
    ) {
        copy(state = TransferState.CANCELLED, errorKind = null)
    } else {
        this
    }

internal fun PersistedDownload.completeDownloadExecution(executionId: String): PersistedDownload =
    if (ownsDownloadExecution(executionId) && state == TransferState.RUNNING) {
        copy(
            state = TransferState.SUCCEEDED,
            completedBytes = totalBytes ?: completedBytes,
            errorKind = null,
        )
    } else {
        this
    }

internal fun shouldDeleteFailedForegroundDownload(
    download: PersistedDownload,
    ownsExecution: Boolean,
): Boolean = ownsExecution && download.isDirectory && !download.isArchiveDownload && download.state == TransferState.FAILED
