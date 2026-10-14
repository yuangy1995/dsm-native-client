package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

internal suspend fun readMemoryCompression(read: suspend (NasServiceStep) -> JsonObject?): NasMemoryCompression {
    val value = read(NasServiceStep.ZRAM) ?: throw DsmFailure(null, "Memory compression unavailable", "Open DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
    val aliases = listOf("enable_zram", "zram_enable", "enable", "enabled").mapNotNull { value[it]?.takeUnless { it is JsonNull } }
    val flags = aliases.map { it.nativeBoolean() }
    val enabled = flags.takeIf { it.isNotEmpty() && it.all { flag -> flag != null } && it.distinct().size == 1 }?.first()
    val reboot = try { read(NasServiceStep.REBOOT_REQUIRED)?.get("need_reboot").nativeBoolean() } catch (error: Exception) {
        if (error is CancellationException || error.serviceTrustFailure() || error is DsmFailure && error.kind in setOf(
                DsmErrorKind.AUTHENTICATION_FAILED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.PERMISSION_DENIED)) throw error
        null
    }
    val bytes = listOf("configured_bytes", "capacity_bytes", "size_bytes").firstNotNullOfOrNull { key ->
        (value[key] as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull?.takeIf { it >= 0 }
    }
    val algorithm = value["algorithm"].nativeString()?.lowercase()?.takeIf { it in setOf("lz4", "lzo", "zstd") }
    return NasMemoryCompression(enabled, reboot, bytes, algorithm)
}

internal fun readPowerSchedule(value: JsonObject): NasPowerSchedule {
    val paired = "poweron_tasks" in value || "poweroff_tasks" in value
    val rows: List<Pair<NasPowerScheduleAction?, JsonElement>> = if (paired) {
        val startup = value["poweron_tasks"] as? JsonArray ?: serviceInvalid()
        val shutdown = value["poweroff_tasks"] as? JsonArray ?: serviceInvalid()
        startup.map { NasPowerScheduleAction.STARTUP to it } + shutdown.map { NasPowerScheduleAction.SHUTDOWN to it }
    } else {
        val schedules = value["schedules"]?.takeUnless { it is JsonNull }
        val items = value["items"]?.takeUnless { it is JsonNull }
        if (schedules != null && items != null && schedules != items) serviceInvalid()
        ((schedules ?: items) as? JsonArray ?: serviceInvalid()).map { null to it }
    }
    val entries = rows.take(200).mapNotNull { (action, raw) ->
        val row = raw as? JsonObject ?: return@mapNotNull null
        val days = if (paired) {
            row["weekdays"].nativeString()?.split(',')?.map { it.trim().toIntOrNull()?.takeIf { day -> day in 0..6 } }
                ?.takeIf { it.isNotEmpty() && it.all { day -> day != null } }?.filterNotNull()?.toSet().orEmpty()
        } else {
            val rawDays = row["weekdays"] ?: row["days"] ?: row["repeat"]
            val tokens = (rawDays as? JsonArray)?.map { it.nativeString() }
                ?: rawDays.nativeString()?.split(Regex("[, ;]+"))
            val names = listOf(setOf("sun", "sunday"), setOf("mon", "monday"), setOf("tue", "tues", "tuesday"),
                setOf("wed", "wednesday"), setOf("thu", "thur", "thurs", "thursday"), setOf("fri", "friday"), setOf("sat", "saturday"))
            tokens?.map { token -> names.indexOfFirst { token?.lowercase() in it }.takeIf { it >= 0 } }
                ?.takeIf { it.all { day -> day != null } }?.filterNotNull()?.toSet().orEmpty()
        }
        val parsedAction = action ?: when ((row["action"] ?: row["type"] ?: row["operation"]).nativeString()?.lowercase()) {
            "startup", "start", "poweron", "power_on", "boot" -> NasPowerScheduleAction.STARTUP
            "shutdown", "stop", "poweroff", "power_off" -> NasPowerScheduleAction.SHUTDOWN
            "restart", "reboot" -> NasPowerScheduleAction.RESTART
            else -> NasPowerScheduleAction.UNKNOWN
        }
        fun number(key: String) = (row[key] as? JsonPrimitive)?.takeIf { !paired || !it.isString }?.intOrNull
        NasPowerScheduleEntry(parsedAction, (row["enabled"] ?: row["is_enabled"]).nativeBoolean(), days,
            number("hour")?.takeIf { it in 0..23 }, number(if (paired) "min" else "minute")?.takeIf { it in 0..59 },
            recurring = listOf("date", "run_date").none { row[it]?.takeUnless { field -> field is JsonNull } != null })
    }
    val total = maxOf(rows.size, (value["total"] ?: value["total_count"]).let { (it as? JsonPrimitive)?.intOrNull?.takeIf { count -> count >= 0 } } ?: rows.size)
    val zones = listOf("timezone", "time_zone").mapNotNull { value[it]?.takeUnless { it is JsonNull } }
    val zoneNames = zones.map { it.nativeString()?.takeIf { zone -> zone.length in 1..128 && zone.all { c -> c.isLetterOrDigit() || c in "_/+-" } } }
    val validZone = zoneNames.all { it != null } && zoneNames.distinct().size <= 1
    return NasPowerSchedule(entries, zoneNames.firstOrNull(), total,
        complete = paired && total == entries.size && rows.size <= 200 && validZone && entries.all { it.editable })
}

internal fun NasPowerSchedule.validSchedule(): Boolean = editable && entries.withIndex().all { (index, row) ->
    entries.take(index).none { it.hour == row.hour && it.minute == row.minute && it.weekdays.intersect(row.weekdays).isNotEmpty() }
}
internal fun NasPowerSchedule.powerScheduleGroup(): JsonObject = buildJsonObject {
    fun tasks(action: NasPowerScheduleAction) = JsonArray(entries.filter { it.action == action }.map { row -> buildJsonObject {
        put("enabled", row.enabled?.let(::JsonPrimitive) ?: JsonNull); put("weekdays", row.weekdays.sorted().joinToString(","))
        put("hour", row.hour?.let(::JsonPrimitive) ?: JsonNull); put("min", row.minute?.let(::JsonPrimitive) ?: JsonNull)
    } }.sortedBy { it.toString() })
    put("poweron_tasks", tasks(NasPowerScheduleAction.STARTUP)); put("poweroff_tasks", tasks(NasPowerScheduleAction.SHUTDOWN))
    put("_timezone", timezone?.let(::JsonPrimitive) ?: JsonNull); put("_complete", editable)
}
internal fun NasMemoryCompression.memoryGroups() = buildMap {
    enabled?.let { value ->
        put(NasServiceStep.ZRAM, buildJsonObject { put("enable_zram", value) })
        rebootRequired?.let { reboot -> put(NasServiceStep.REBOOT_REQUIRED, buildJsonObject { put("enable_zram", value); put("need_reboot", reboot) }) }
    }
}
private fun JsonElement?.nativeBoolean() = (this as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull
private fun JsonElement?.nativeString() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
