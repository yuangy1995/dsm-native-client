package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

internal data class NasScheduledTask(
    val id: Long, val name: String, val owner: String?, val realOwner: String?, val type: String?, val action: String?,
    val enabled: Boolean?, val nextTrigger: String?, val canRun: Boolean, val canEdit: Boolean,
) {
    fun sameIdentity(other: NasScheduledTask) = copy(nextTrigger = null) == other.copy(nextTrigger = null)
    override fun toString() = "NasScheduledTask($id)"
}
internal data class NasTaskSchedule(
    val dateType: Int = 0, val weekdays: String = "0,1,2,3,4,5,6", val date: String? = null,
    val repeatDate: Int = 1001, val monthlyWeek: List<Int> = emptyList(), val hour: Int = 0, val minute: Int = 0,
    val repeatHour: Int = 0, val repeatMinute: Int = 0, val lastWorkHour: Int = 0,
) {
    val selectedDays: Set<Int>? get() {
        val tokens = weekdays.split(','); val values = tokens.mapNotNull { it.trim().toIntOrNull() }
        return values.toSet().takeIf { it.isNotEmpty() && values.size == tokens.size && it.size == values.size && it.all { day -> day in 0..6 } }
    }
    fun samePreserved(other: NasTaskSchedule) = copy(weekdays = "", hour = 0, minute = 0) == other.copy(weekdays = "", hour = 0, minute = 0)
}
internal data class NasTaskDraft(
    val id: Long? = null, val name: String = "", val owner: String, val realOwner: String? = null,
    val enabled: Boolean = true, val script: String = "", val notifyOnError: Boolean = false,
    val notificationEmails: String = "", val schedule: NasTaskSchedule = NasTaskSchedule(),
) {
    val valid get() = name.isNotBlank() && owner.isNotBlank() && name.none(Char::isISOControl) && owner.none(Char::isISOControl) &&
        script.isNotBlank() && schedule.hour in 0..23 && schedule.minute in 0..59
    fun matches(task: NasScheduledTask) = id == task.id && name == task.name && owner == task.owner &&
        (task.realOwner == null || realOwner == task.realOwner) && enabled == task.enabled
    override fun toString() = "NasTaskDraft($id)"
}
internal data class NasTaskResult(val id: String, val taskName: String, val started: String?, val stopped: String?,
    val exitType: String?, val exitCode: Int?, val trigger: String?) { override fun toString() = "NasTaskResult" }
internal data class NasTaskOutput(val command: String?, val output: String?) { override fun toString() = "NasTaskOutput" }
@Serializable internal enum class NasTaskAction { CREATE, SAVE, ENABLE, DISABLE, RUN, DELETE }
@Serializable internal enum class NasTaskStage { SUBMITTED, ACCEPTED, COMPLETED, REJECTED }
internal enum class NasTaskProblem { INCOMPLETE, INVALID, CHANGED, PERMISSION, BUSY }
internal class NasTaskFailure(val problem: NasTaskProblem) : Exception(problem.name)
internal data class NasTaskChange(val action: NasTaskAction, val task: NasScheduledTask? = null,
    val original: NasTaskDraft? = null, val desired: NasTaskDraft? = null) {
    override fun toString() = "NasTaskChange($action)"
}
internal data class NasTaskCheckpoint(val stage: NasTaskStage, val existingIds: List<Long> = emptyList())
