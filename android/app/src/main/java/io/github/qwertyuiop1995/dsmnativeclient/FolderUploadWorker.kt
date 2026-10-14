package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.CancellationException

/** 与单文件任务沿用相同任务归属和通知路由，执行目录清单中的每一项。 */
class FolderUploadWorker(appContext: Context, parameters: WorkerParameters) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        val taskId = inputData.getString(PhotoBackupWorker.KEY_TASK_ID) ?: return Result.failure()
        val store = TransferStore(applicationContext)
        val upload = store.upload(taskId) ?: return Result.failure()
        val execution = id.toString()
        if (upload.workId != execution || upload.state !in setOf(TransferState.WAITING, TransferState.RUNNING)) return Result.success()
        val intent = TransferNotifications.openAppIntent(applicationContext, taskId, WorkspaceRecordKind.UPLOAD)
        setForeground(TransferNotifications.foreground(applicationContext, taskId, id, TransferState.WAITING,
            upload.completedBytes, upload.expectedBytes, TransferDirection.UPLOAD, openTaskIntent = intent))
        return try {
            checkNotNull(store.folderUploadPlan(taskId))
            val repo = restoreTaskRepository(applicationContext, WorkspaceRecordKind.UPLOAD, taskId, upload.profileId)
            var lastProgress = 0L
            val result = FolderUploadCoordinator(store, RepositoryFolderUploadEndpoint(repo, applicationContext.contentResolver,
                WorkspaceTaskOwnership(SecureProfileStore(applicationContext)), taskId), taskId, execution) { completed, total ->
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastProgress >= 400 || completed == total) {
                    lastProgress = now
                    setProgressAsync(PhotoBackupWorker.progressData(completed, total))
                    setForegroundAsync(TransferNotifications.foreground(applicationContext, taskId, id, TransferState.RUNNING,
                        completed, total, TransferDirection.UPLOAD, openTaskIntent = intent))
                }
            }.run()
            if (result?.workId != execution) return Result.success()
            TransferNotifications.completion(applicationContext, taskId, outcome = when {
                result.state == TransferState.SUCCEEDED -> TransferCompletionOutcome.SUCCESS
                result.requiresRefresh -> TransferCompletionOutcome.NEEDS_REVIEW
                result.state == TransferState.CANCELLED -> TransferCompletionOutcome.CANCELLED
                else -> TransferCompletionOutcome.FAILURE
            }, direction = TransferDirection.UPLOAD)
            if (result.state == TransferState.SUCCEEDED) Result.success() else Result.failure()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            runCatching { store.updateUpload(taskId) { if (it.workId == execution && it.state in setOf(TransferState.WAITING, TransferState.RUNNING))
                it.copy(state = TransferState.PAUSED, errorKind = (failure as? DsmFailure)?.kind?.name ?: DsmErrorKind.LOCAL_STORAGE_FAILED.name) else it } }
            Result.failure()
        } finally {
            runCatching { finalizeFolderUploadCancellation(store, taskId, execution) }
        }
    }
}
