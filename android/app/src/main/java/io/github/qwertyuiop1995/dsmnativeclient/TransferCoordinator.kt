package io.github.qwertyuiop1995.dsmnativeclient

import java.util.UUID
import kotlinx.coroutines.Job

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
