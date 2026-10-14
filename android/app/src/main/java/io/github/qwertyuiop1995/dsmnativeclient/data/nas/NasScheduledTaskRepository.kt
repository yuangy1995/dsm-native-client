package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.*

internal const val TASK_SCHEDULER = "SYNO.Core.TaskScheduler"
internal const val TASK_RESULTS = "SYNO.Core.EventScheduler"
internal class NasScheduledTaskRepository(private val gateway: NasManagementGateway, private val username: String,
    private val supportsVersion: (Int) -> Boolean) {
    private val mutex = Mutex()
    var recoveryPending: () -> Boolean = { false }
    val canCreate get() = supportsVersion(3) && supportsVersion(4)
    fun newDraft(): NasTaskDraft { if (!canCreate) throw DsmFailure(103, "Feature unsupported", "Use DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED); return NasTaskDraft(owner = username) }
    suspend fun tasks() = decodeScheduledTasks(gateway.call(TASK_SCHEDULER, "list", 3, mapOf("start" to JsonPrimitive(0), "limit" to JsonPrimitive(1000))))
    internal suspend fun draft(task: NasScheduledTask) = decodeTaskDraft(gateway.call(TASK_SCHEDULER, "get", 4, taskSelector(task)), task)
    suspend fun inspect(task: NasScheduledTask): NasTaskDraft? {
        currentTask(task)
        return if (task.type == "script") draft(task) else null
    }
    private suspend fun currentTask(expected: NasScheduledTask, uniqueName: Boolean = false) {
        val rows = tasks(); val actual = rows.singleOrNull { it.id == expected.id }
        if (actual == null || !expected.sameIdentity(actual) || uniqueName && rows.count { it.name == expected.name } != 1) taskFailure(NasTaskProblem.CHANGED)
    }
    suspend fun results(task: NasScheduledTask): List<NasTaskResult> {
        currentTask(task, true)
        return decodeTaskResults(gateway.call(TASK_RESULTS, "result_list", 1, mapOf("task_name" to JsonPrimitive(task.name))), task.name)
    }
    suspend fun output(task: NasScheduledTask, result: NasTaskResult): NasTaskOutput {
        if (results(task).none { it.id == result.id && it.taskName == result.taskName }) taskFailure(NasTaskProblem.CHANGED)
        val data = gateway.call(TASK_RESULTS, "result_get_file", 1, mapOf("task_name" to JsonPrimitive(task.name), "result_id" to JsonPrimitive(result.id)))
        return NasTaskOutput(data["script_in"].taskText(), data["script_out"].taskText())
    }
    suspend fun change(change: NasTaskChange, checkpoint: suspend (NasTaskCheckpoint) -> Unit): Boolean {
        if (!mutex.tryLock()) taskFailure(NasTaskProblem.BUSY)
        try {
            if (recoveryPending()) taskFailure(NasTaskProblem.BUSY)
            validate(change)
            gateway.requireWriteAccess()
            val before = tasks()
            if (change.task != null) {
                if (before.singleOrNull { it.id == change.task.id }?.let { change.task.sameIdentity(it) } != true) taskFailure(NasTaskProblem.CHANGED)
                change.original?.let { if (draft(change.task) != it) taskFailure(NasTaskProblem.CHANGED) }
            } else if (before.any { it.name == change.desired!!.name.trim() && it.owner == change.desired.owner.trim() }) taskFailure(NasTaskProblem.CHANGED)
            currentCoroutineContext().ensureActive()
            val ids = if (change.action == NasTaskAction.CREATE) before.map { it.id } else emptyList()
            checkpoint(NasTaskCheckpoint(NasTaskStage.SUBMITTED, ids))
            var accepted = false
            try {
                val parameters: Map<String, JsonElement>; val method: String; val version: Int
                if (change.action in setOf(NasTaskAction.CREATE, NasTaskAction.SAVE)) {
                    val desired = requireNotNull(change.desired); val values = taskSavedFields(desired, false).toMutableMap()
                    desired.id?.let { values["id"] = JsonPrimitive(it) }; desired.realOwner?.takeIf { it.isNotEmpty() }?.let { values["real_owner"] = JsonPrimitive(it) }
                    parameters = values; method = if (change.action == NasTaskAction.CREATE) "create" else "set"; version = 4
                } else {
                    val values = taskSelector(requireNotNull(change.task)).toMutableMap()
                    if (change.action in setOf(NasTaskAction.ENABLE, NasTaskAction.DISABLE)) values["enable"] = JsonPrimitive(change.action == NasTaskAction.ENABLE)
                    parameters = values; version = 3; method = when (change.action) { NasTaskAction.RUN -> "run"; NasTaskAction.DELETE -> "delete"; else -> "set_enable" }
                }
                gateway.call(TASK_SCHEDULER, method, version, parameters, true); accepted = true
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (directoryExplicitRejection(error)) { checkpoint(NasTaskCheckpoint(NasTaskStage.REJECTED)); throw error }
                if (directoryTrustFailure(error)) throw error
            }
            if (accepted) checkpoint(NasTaskCheckpoint(NasTaskStage.ACCEPTED))
            val complete = if (change.action == NasTaskAction.RUN) accepted else try { matches(change, accepted, ids) } catch (error: Exception) {
                if (error is CancellationException || directoryTrustFailure(error)) throw error
                false
            }
            if (complete) checkpoint(NasTaskCheckpoint(NasTaskStage.COMPLETED))
            return complete
        } finally { mutex.unlock() }
    }
    private fun validate(change: NasTaskChange) {
        val task = change.task; val original = change.original; val desired = change.desired
        val needsDraft = change.action in setOf(NasTaskAction.SAVE, NasTaskAction.ENABLE) || change.action == NasTaskAction.RUN && task?.type == "script"
        if (!supportsVersion(3) || (needsDraft || change.action == NasTaskAction.CREATE) && !supportsVersion(4)) throw DsmFailure(103, "Feature unsupported", "Use DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        if (task?.id?.let { it < 0 } == true || change.action != NasTaskAction.CREATE && task == null) taskFailure(NasTaskProblem.INVALID)
        if (needsDraft && (original == null || !original.matches(requireNotNull(task)) || change.action != NasTaskAction.SAVE && !original.valid)) taskFailure(NasTaskProblem.INVALID)
        when (change.action) {
            NasTaskAction.CREATE, NasTaskAction.SAVE -> {
                if (desired?.valid != true || original == null || original.id != desired.id || original.realOwner != desired.realOwner || !original.schedule.samePreserved(desired.schedule) ||
                    desired.schedule.selectedDays == null && (task == null || desired.schedule.weekdays != original.schedule.weekdays)) taskFailure(NasTaskProblem.INVALID)
                if (change.action == NasTaskAction.CREATE) { if (task != null || desired.id != null || desired.realOwner != null || original != newDraft()) taskFailure(NasTaskProblem.INVALID) }
                else if (task?.canEdit != true || task.type != "script" || taskSavedFields(original) == taskSavedFields(desired)) taskFailure(NasTaskProblem.PERMISSION)
            }
            NasTaskAction.ENABLE, NasTaskAction.DISABLE -> if (task?.canEdit != true || task.type != "script" || task.enabled == null || task.enabled == (change.action == NasTaskAction.ENABLE) ||
                change.action == NasTaskAction.DISABLE && original != null) taskFailure(NasTaskProblem.PERMISSION)
            NasTaskAction.RUN -> if (task?.canRun != true || task.type.isNullOrEmpty()) taskFailure(NasTaskProblem.PERMISSION)
            NasTaskAction.DELETE -> if (task?.canEdit != true || task.type != "script" || task.enabled == null || original != null) taskFailure(NasTaskProblem.PERMISSION)
        }
    }
    private suspend fun matches(change: NasTaskChange, accepted: Boolean, existingIds: List<Long>): Boolean {
        val rows = tasks(); val task = change.task
        if (change.action == NasTaskAction.DELETE) return rows.none { it.id == task!!.id }
        if (change.action == NasTaskAction.DISABLE) return rows.singleOrNull { it.id == task!!.id }?.let {
            it.enabled == false && taskTargetFields(it) == taskTargetFields(task!!)
        } == true
        val desired = if (change.action == NasTaskAction.ENABLE) change.original!!.copy(enabled = true) else change.desired ?: return false
        val candidates = if (task != null) rows.filter { it.id == task.id && it.realOwner == task.realOwner }
            else if (accepted) rows.filter { it.id !in existingIds && it.name == desired.name.trim() && it.owner == desired.owner.trim() } else emptyList()
        val current = candidates.singleOrNull()?.takeIf { it.type == "script" } ?: return false
        return taskSavedFields(draft(current)) == taskSavedFields(desired)
    }
}
