package io.github.qwertyuiop1995.dsmnativeclient

import kotlinx.coroutines.Job

/**
 * 统一持有前台传输任务的 Job 引用，避免同一任务在多个模块中分别注册和清理。
 */
internal class TransferTaskJobOwner {
    private val jobs = mutableMapOf<String, Job>()

    fun register(
        taskId: String,
        job: Job,
        beforeRemoval: (() -> Unit)? = null,
        afterRemoval: (() -> Unit)? = null,
    ) {
        jobs[taskId] = job
        job.invokeOnCompletion {
            beforeRemoval?.invoke()
            jobs.remove(taskId, job)
            afterRemoval?.invoke()
        }
    }

    fun job(taskId: String): Job? = jobs[taskId]

    /** 仅在切换 NAS 时丢弃旧工作区引用；任务取消由调用方此前的等待逻辑负责。 */
    fun clearReferences() {
        jobs.clear()
    }

    fun cancelAndClear() {
        jobs.values.toList().forEach(Job::cancel)
        jobs.clear()
    }
}

/**
 * 照片备份目录扫描只有一个观察任务；该对象集中管理其 profile、Job 与代次。
 */
internal class PhotoBackupScanObservationOwner {
    private var observationJob: Job? = null
    private var profileId: String? = null
    private var observationGeneration = 0L
    private var scheduleGeneration = 0L

    fun nextScheduleGeneration(): Long = ++scheduleGeneration

    fun isCurrentScheduleGeneration(generation: Long): Boolean =
        scheduleGeneration == generation

    fun beginObservation(nextProfileId: String): Long {
        observationJob?.cancel()
        val generation = ++observationGeneration
        profileId = nextProfileId
        return generation
    }

    fun attachObservation(nextProfileId: String, generation: Long, job: Job) {
        observationJob = job
        job.invokeOnCompletion {
            if (isCurrentObservation(nextProfileId, generation)) {
                observationJob = null
                profileId = null
            }
        }
    }

    fun isCurrentObservation(expectedProfileId: String, generation: Long): Boolean =
        observationGeneration == generation && profileId == expectedProfileId

    fun cancelObservation(expectedProfileId: String, generation: Long? = null): Boolean {
        if (
            profileId != expectedProfileId ||
            (generation != null && observationGeneration != generation)
        ) {
            return false
        }
        observationGeneration += 1
        observationJob?.cancel()
        observationJob = null
        profileId = null
        return true
    }
}
