package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.work.WorkManager
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedPhotoBackupSource
import kotlinx.coroutines.Job

/**
 * 统一持有前台传输任务的 Job 引用，避免同一任务在多个模块中分别注册和清理。
 */
internal class TransferTaskJobOwner {
    private val lock = Any()
    private val jobs = mutableMapOf<String, Job>()

    fun register(
        taskId: String,
        job: Job,
        beforeRemoval: (() -> Unit)? = null,
        afterRemoval: (() -> Unit)? = null,
    ) {
        synchronized(lock) {
            jobs[taskId] = job
        }
        job.invokeOnCompletion {
            val removed = synchronized(lock) {
                if (jobs[taskId] !== job) {
                    false
                } else {
                    jobs.remove(taskId)
                    true
                }
            }
            if (removed) {
                // 任务引用已先移除；回调不在锁内执行，避免取消或重入导致死锁。
                beforeRemoval?.invoke()
                afterRemoval?.invoke()
            }
        }
    }

    fun job(taskId: String): Job? = synchronized(lock) { jobs[taskId] }

    /** 仅在切换 NAS 时丢弃旧工作区引用；任务取消由调用方此前的等待逻辑负责。 */
    fun clearReferences() {
        synchronized(lock) {
            jobs.clear()
        }
    }

    fun cancelAndClear() {
        val jobsToCancel = synchronized(lock) {
            jobs.values.toList().also { jobs.clear() }
        }
        jobsToCancel.forEach(Job::cancel)
    }
}

/**
 * 照片备份目录扫描的唯一协调器。
 *
 * 周期 WorkManager 工作属于持久化配置，切换 Profile 时不应被本地生命周期误取消；但调度
 * 查询结果、观察 Job 与代次必须一并失效，避免旧 Profile 的迟到回调重新挂接观察者。
 */
internal class PhotoBackupCoordinator {
    private data class Observation(
        val profileId: String,
        val generation: Long,
        val job: Job?,
    )

    private val lock = Any()
    private var observation: Observation? = null
    private var observationGeneration = 0L
    private var scheduleGeneration = 0L

    fun nextScheduleGeneration(): Long = synchronized(lock) { ++scheduleGeneration }

    fun isCurrentScheduleGeneration(generation: Long): Boolean =
        synchronized(lock) { scheduleGeneration == generation }

    fun beginObservation(nextProfileId: String): Long {
        var previousJob: Job? = null
        val generation = synchronized(lock) {
            previousJob = observation?.job
            val nextGeneration = ++observationGeneration
            observation = Observation(nextProfileId, nextGeneration, job = null)
            nextGeneration
        }
        previousJob?.cancel()
        return generation
    }

    fun attachObservation(nextProfileId: String, generation: Long, job: Job) {
        var previousJob: Job? = null
        var shouldCancel = false
        synchronized(lock) {
            val current = observation
            if (current?.profileId == nextProfileId && current.generation == generation) {
                previousJob = current.job
                observation = current.copy(job = job)
                shouldCancel = false
            } else {
                previousJob = null
                shouldCancel = true
            }
        }
        previousJob?.cancel()
        if (shouldCancel) {
            job.cancel()
            return
        }
        job.invokeOnCompletion {
            synchronized(lock) {
                val current = observation
                if (
                    current?.profileId == nextProfileId && current.generation == generation &&
                    current.job === job
                ) {
                    observation = null
                }
            }
        }
    }

    fun isCurrentObservation(expectedProfileId: String, generation: Long): Boolean =
        synchronized(lock) {
            observation?.generation == generation && observation?.profileId == expectedProfileId
        }

    fun observationJob(): Job? = synchronized(lock) { observation?.job }

    fun cancelObservation(expectedProfileId: String, generation: Long? = null): Boolean {
        var job: Job? = null
        synchronized(lock) {
            val current = observation ?: return false
            if (
                current.profileId != expectedProfileId ||
                (generation != null && current.generation != generation)
            ) {
                return false
            }
            observationGeneration += 1
            observation = null
            job = current.job
        }
        job?.cancel()
        return true
    }

    /** 丢弃当前工作区的调度与观察引用，不取消已持久化的唯一 WorkManager 工作。 */
    fun clearForProfileSwitch() {
        val job = synchronized(lock) {
            scheduleGeneration += 1
            observationGeneration += 1
            observation?.job.also { observation = null }
        }
        job?.cancel()
    }

    fun cancelSourceWork(workManager: WorkManager, profileId: String) {
        cancelObservation(profileId)
        workManager.cancelUniqueWork(PhotoBackupScanWorker.UNIQUE_WORK_PREFIX + profileId)
        workManager.cancelUniqueWork(PhotoBackupScanWorker.UNIQUE_WORK_PREFIX + profileId + "-initial")
    }

    fun isCurrentSourceSchedule(
        expected: PersistedPhotoBackupSource,
        generation: Long,
        current: PersistedPhotoBackupSource?,
    ): Boolean = isCurrentScheduleGeneration(generation) && current?.let { source ->
        source.profileId == expected.profileId &&
            source.treeUri == expected.treeUri &&
            source.destinationPath == expected.destinationPath &&
            shouldScanPhotoBackupSource(source) &&
            source.workId == null
    } == true

    fun sourceRestoreMessage(
        application: Application,
        source: PersistedPhotoBackupSource?,
    ): String? = if (source?.needsAttention == true) {
        application.getString(R.string.photo_backup_folder_too_large)
    } else {
        null
    }
}
