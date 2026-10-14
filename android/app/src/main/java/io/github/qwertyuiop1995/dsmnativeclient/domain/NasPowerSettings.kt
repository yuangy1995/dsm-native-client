package io.github.qwertyuiop1995.dsmnativeclient.domain

/** 缺失开关保持未知；容量、算法和重启要求只读，不补设备默认值。 */
internal data class NasMemoryCompression(val enabled: Boolean?, val rebootRequired: Boolean?,
    val configuredBytes: Long? = null, val algorithm: String? = null) {
    val editable get() = enabled != null && rebootRequired != null
}
internal enum class NasPowerScheduleAction { STARTUP, SHUTDOWN, RESTART, UNKNOWN }
internal data class NasPowerScheduleEntry(val action: NasPowerScheduleAction, val enabled: Boolean?,
    val weekdays: Set<Int>, val hour: Int?, val minute: Int?, val recurring: Boolean = true) {
    val editable get() = action in setOf(NasPowerScheduleAction.STARTUP, NasPowerScheduleAction.SHUTDOWN) &&
        enabled != null && weekdays.isNotEmpty() && weekdays.all { it in 0..6 } && hour in 0..23 && minute in 0..59 && recurring
}
/** 条目时间始终属于 NAS；摘要或不完整清单可以展示，但不能覆盖保存。 */
internal data class NasPowerSchedule(val entries: List<NasPowerScheduleEntry>, val timezone: String?,
    val total: Int, val complete: Boolean) {
    val editable get() = complete && total == entries.size && entries.size <= 200 && entries.all { it.editable }
    override fun toString() = "NasPowerSchedule"
}
