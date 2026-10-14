package io.github.qwertyuiop1995.dsmnativeclient

import java.util.UUID
import androidx.work.WorkManager
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.filterNotNull

/**
 * 集中管理传输运行时所有权。
 *
 * 持久化传输记录仍由 [TransferStore] 管理；本对象只保存不可持久化的前台 Job、前台下载
 * execution id 与 WorkManager 观察 Job。三者必须一起替换和清理，才能让旧 Job 的完成
 * 回调不能影响同一 taskId 的新执行。
 */
internal class TransferCoordinator {
    private val lock = Any()
    private val taskJobs = TransferTaskJobOwner()
    private val foregroundDownloadExecutionIds = mutableMapOf<String, String>()
    private val workObservationJobs = mutableMapOf<String, Job>()

    fun beginForegroundDownload(taskId: String): String {
        val executionId = UUID.randomUUID().toString()
        synchronized(lock) {
            foregroundDownloadExecutionIds[taskId] = executionId
        }
        return executionId
    }

    fun isCurrentForegroundDownloadExecution(taskId: String, executionId: String): Boolean =
        synchronized(lock) {
            foregroundDownloadExecutionIds[taskId] == executionId
        }

    fun clearForegroundDownloadExecution(taskId: String, executionId: String) {
        synchronized(lock) {
            if (foregroundDownloadExecutionIds[taskId] == executionId) {
                foregroundDownloadExecutionIds.remove(taskId)
            }
        }
    }

    fun registerForegroundTask(
        taskId: String,
        job: Job,
        beforeRemoval: (() -> Unit)? = null,
        afterRemoval: (() -> Unit)? = null,
    ) {
        taskJobs.register(taskId, job, beforeRemoval, afterRemoval)
    }

    fun foregroundTask(taskId: String): Job? = taskJobs.job(taskId)

    /**
     * 同一传输只能保留一个 WorkManager 观察者。取消旧观察者在锁外执行，避免其 finally
     * 或完成回调重入本对象时造成死锁。
     */
    fun replaceWorkObservation(taskId: String, job: Job) {
        val previous = synchronized(lock) {
            workObservationJobs.put(taskId, job)
        }
        previous?.cancel()
    }

    fun removeWorkObservation(taskId: String, job: Job?): Boolean {
        if (job == null) return false
        return synchronized(lock) {
            if (workObservationJobs[taskId] !== job) {
                false
            } else {
                workObservationJobs.remove(taskId)
                true
            }
        }
    }

    /** 上传观察统一在 IO 线程保存事实；目录取消先收敛逐项阶段，再套用共用工作状态。 */
    fun observeUpload(scope: CoroutineScope, workManager: WorkManager, store: TransferStore, taskId: String, workId: UUID,
        onChanged: (String) -> Unit) {
        val job = scope.launch(start = CoroutineStart.LAZY) {
            workManager.getWorkInfoByIdFlow(workId).filterNotNull().collectLatest { info ->
                val completed = info.progress.getLong(PhotoBackupWorker.KEY_COMPLETED_BYTES, 0)
                withContext(Dispatchers.IO) {
                    if (info.state.isFinished && store.hasFolderUploadPlan(taskId)) {
                        finalizeFolderUploadCancellation(store, taskId, workId.toString())
                    }
                    store.updateUpload(taskId) { current -> current.applyUploadWorkObservation(
                        executionId = workId.toString(), workState = info.state, observedCompletedBytes = completed,
                        observedErrorKind = info.outputData.getString(PhotoBackupWorker.KEY_ERROR_KIND)) }
                }?.let { onChanged(it.profileId) }
                if (info.state.isFinished) {
                    removeWorkObservation(taskId, currentCoroutineContext()[Job])
                    currentCoroutineContext()[Job]?.cancel()
                }
            }
        }
        replaceWorkObservation(taskId, job)
        job.start()
    }

    /** 重新恢复持久化任务时仅替换 WorkManager 观察者，不碰前台传输所有权。 */
    fun cancelWorkObservations() {
        val observations = synchronized(lock) {
            workObservationJobs.values.toList().also { workObservationJobs.clear() }
        }
        observations.forEach(Job::cancel)
    }

    /** 切换 Profile/NAS 后清除旧引用并停止旧观察，不影响新的 ViewModel scope。 */
    fun clearForProfileSwitch() {
        taskJobs.clearReferences()
        synchronized(lock) { foregroundDownloadExecutionIds.clear() }
        cancelWorkObservations()
    }

    /** 退出登录时取消本工作区拥有的前台任务及后台工作观察。 */
    fun cancelAndClear() {
        taskJobs.cancelAndClear()
        synchronized(lock) { foregroundDownloadExecutionIds.clear() }
        cancelWorkObservations()
    }

    internal fun currentForegroundDownloadExecution(taskId: String): String? = synchronized(lock) {
        foregroundDownloadExecutionIds[taskId]
    }

    internal fun currentWorkObservation(taskId: String): Job? = synchronized(lock) {
        workObservationJobs[taskId]
    }
}
