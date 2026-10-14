package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

internal fun taskFailure(problem: NasTaskProblem = NasTaskProblem.INCOMPLETE): Nothing = throw NasTaskFailure(problem)
internal fun JsonElement?.taskText(): String? = this?.takeUnless { it is JsonNull }?.let { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: taskFailure() }
internal fun JsonElement?.taskLong(): Long? = this?.takeUnless { it is JsonNull }?.let { (it as? JsonPrimitive)?.takeUnless { p -> p.isString }?.longOrNull ?: taskFailure() }
internal fun JsonElement?.taskInt(): Int? = this.taskLong()?.let { if (it !in Int.MIN_VALUE..Int.MAX_VALUE) taskFailure(); it.toInt() }
internal fun JsonElement?.taskBool(): Boolean? = this?.takeUnless { it is JsonNull }?.let { (it as? JsonPrimitive)?.takeUnless { p -> p.isString }?.booleanOrNull ?: taskFailure() }
internal fun JsonElement?.taskObject() = this as? JsonObject ?: taskFailure()
internal fun JsonElement?.taskArray() = this as? JsonArray ?: taskFailure()
internal fun taskCoalesced(a: JsonElement?, b: JsonElement?): JsonElement? {
    val left = a?.takeUnless { it is JsonNull }; val right = b?.takeUnless { it is JsonNull }
    if (left != null && right != null && left != right) taskFailure()
    return left ?: right
}
internal fun decodeScheduledTasks(data: JsonObject): List<NasScheduledTask> {
    val rows = data["tasks"].taskArray(); val seen = mutableSetOf<Long>()
    if (rows.size >= 1000 || data["total"]?.takeUnless { it is JsonNull }?.taskLong()?.let { it != rows.size.toLong() } == true) taskFailure()
    return rows.map { raw -> val row = raw.taskObject()
        val id = row["id"].taskLong()?.takeIf { it >= 0 } ?: taskFailure()
        val name = row["name"].taskText()?.takeIf(::directoryNameValid) ?: taskFailure()
        if (!seen.add(id)) taskFailure()
        val enabled = row["enable"].taskBool(); val type = row["type"].taskText()
        NasScheduledTask(id, name, row["owner"].taskText() ?: row["real_owner"].taskText(), row["real_owner"].taskText(), type,
            row["action"].taskText(), enabled, row["next_trigger_time"].taskText(), row["can_run"].taskBool() == true,
            row["can_edit"].taskBool() == true && enabled != null && type == "script")
    }
}
internal fun decodeTaskDraft(value: JsonObject, expected: NasScheduledTask): NasTaskDraft {
    val schedule = value["schedule"].taskObject(); val extra = value["extra"].taskObject()
    if (value["id"].taskLong()?.let { it != expected.id } == true || expected.realOwner != null &&
        value["real_owner"].taskText()?.let { it != expected.realOwner } == true) taskFailure()
    return NasTaskDraft(expected.id, value["name"].taskText() ?: taskFailure(),
        value["owner"].taskText() ?: value["real_owner"].taskText() ?: taskFailure(), value["real_owner"].taskText() ?: expected.realOwner,
        value["enable"].taskBool() ?: taskFailure(), extra["script"].taskText() ?: taskFailure(),
        extra["notify_if_error"].taskBool() ?: taskFailure(), extra["notify_mail"].taskText() ?: taskFailure(),
        NasTaskSchedule(schedule["date_type"].taskInt() ?: taskFailure(), schedule["week_day"].taskText() ?: taskFailure(),
            schedule["date"].taskText(), schedule["repeat_date"].taskInt() ?: taskFailure(),
            schedule["monthly_week"]?.takeUnless { it is JsonNull }?.taskArray()?.map { it.taskInt() ?: taskFailure() }.orEmpty(),
            schedule["hour"].taskInt() ?: taskFailure(), schedule["minute"].taskInt() ?: taskFailure(),
            schedule["repeat_hour"].taskInt() ?: taskFailure(), schedule["repeat_min"].taskInt() ?: taskFailure(),
            schedule["last_work_hour"].taskInt() ?: taskFailure()))
        .also { if (!it.matches(expected)) taskFailure(NasTaskProblem.CHANGED) }
}
internal fun decodeTaskResults(data: JsonObject, taskName: String): List<NasTaskResult> {
    val seen = mutableSetOf<String>(); val rows = taskCoalesced(data["_array"], data["results"]).taskArray()
    return rows.map { raw -> val row = raw.taskObject()
        val id = taskCoalesced(row["result_id"], row["id"]).taskText()?.takeIf(::directoryNameValid) ?: taskFailure()
        if (!seen.add(id) || row["task_name"].taskText()?.let { it != taskName } == true) taskFailure()
        val info = row["exit_info"]?.taskObject().orEmpty()
        NasTaskResult(id, taskName, row["start_time"].taskText(), row["stop_time"].taskText(),
            taskCoalesced(info["exit_type"], row["exit_type"]).taskText(), taskCoalesced(info["exit_code"], row["exit_code"]).taskInt(), row["trigger_event"].taskText())
    }.reversed()
}
internal fun taskSelector(task: NasScheduledTask) = buildJsonObject {
    put("id", task.id); task.realOwner?.takeIf { it.isNotEmpty() }?.let { put("real_owner", it) }
}
internal fun taskScheduleFields(schedule: NasTaskSchedule) = buildJsonObject {
    put("date_type", schedule.dateType); put("week_day", schedule.weekdays); put("repeat_date", schedule.repeatDate)
    put("monthly_week", JsonArray(schedule.monthlyWeek.map(::JsonPrimitive))); put("hour", schedule.hour); put("minute", schedule.minute)
    put("repeat_hour", schedule.repeatHour); put("repeat_min", schedule.repeatMinute); put("last_work_hour", schedule.lastWorkHour)
    put("repeat_min_store_config", JsonArray(listOf(1, 5, 10, 15, 20, 30).map(::JsonPrimitive)))
    put("repeat_hour_store_config", JsonArray((1..23).map(::JsonPrimitive))); schedule.date?.takeIf { it.isNotEmpty() }?.let { put("date", it) }
}
internal fun taskSavedFields(draft: NasTaskDraft, canonical: Boolean = true) = buildJsonObject {
    put("name", draft.name.trim()); put("owner", draft.owner.trim()); put("enable", draft.enabled); put("type", "script")
    val schedule = if (canonical && draft.schedule.selectedDays != null) draft.schedule.copy(weekdays = draft.schedule.selectedDays!!.sorted().joinToString(",")) else draft.schedule
    put("schedule", taskScheduleFields(schedule))
    put("extra", buildJsonObject { put("script", draft.script); put("notify_enable", draft.notifyOnError || draft.notificationEmails.isNotEmpty())
        put("notify_if_error", draft.notifyOnError); put("notify_mail", draft.notificationEmails) })
}
internal fun taskTargetFields(task: NasScheduledTask) = buildJsonObject {
    put("id", task.id); put("real_owner", task.realOwner); put("name", task.name); put("owner", task.owner); put("type", task.type); put("action", task.action)
}
