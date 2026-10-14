package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

internal const val SYSTEM_LOG = "SYNO.Core.SyslogClient.Log"
internal const val SYSTEM_PROCESS = "SYNO.Core.System.Process"
internal const val SYSTEM_PROCESS_GROUP = "SYNO.Core.System.ProcessGroup"
internal class NasObservationRepository(private val gateway: NasManagementGateway, private val supports: (String, Int) -> Boolean) {
    suspend fun logs(offset: Int, limit: Int): NasLogPage {
        require(offset >= 0 && limit in 1..500)
        val data = gateway.call(SYSTEM_LOG, "list", 1, mapOf("offset" to JsonPrimitive(offset), "limit" to JsonPrimitive(limit)))
        val rows = data["items"] as? JsonArray ?: observationIncomplete()
        if (rows.size > limit) observationIncomplete()
        fun count(key: String, required: Boolean = false): Int? {
            val value = data[key]?.takeUnless { it is JsonNull } ?: return null
            return (value as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull?.takeIf { it >= 0 }
                ?: if (required) observationIncomplete() else null
        }
        val entries = rows.mapIndexed { index, raw ->
            val row = raw as? JsonObject ?: observationIncomplete()
            val text = observationText(row, "descr", "message", "msg") ?: observationIncomplete()
            val level = when (observationText(row, "level")?.lowercase(java.util.Locale.ROOT)) {
                "info", "information" -> LogLevel.INFO; "warn", "warning" -> LogLevel.WARNING; "err", "error" -> LogLevel.ERROR; else -> LogLevel.UNKNOWN
            }
            NasLogItem("log:${offset + index}", observationText(row, "time"), observationText(row, "logtype", "orginalLogType"), level,
                observationText(row, "who"), text)
        }
        return NasLogPage(offset, limit, entries, count("total", true), count("infoCount"), count("warnCount"), count("errorCount"))
    }
    suspend fun processes(): NasProcessDirectory {
        val parameters = mapOf("start" to JsonPrimitive(0), "limit" to JsonPrimitive(500))
        val data = gateway.call(SYSTEM_PROCESS, "list", 1, parameters)
        val rows = observationRows(data, "process", "processes", "items")
        val seen = mutableSetOf<String>()
        val processes = rows.take(500).mapNotNull { raw ->
            val row = raw.jsonObject
            val id = processText(observationScalar(row, "pid", "process_id"), 32)?.takeIf { it.all(Char::isDigit) } ?: return@mapNotNull null
            val name = processName(observationScalar(row, "name", "process_name") ?: observationScalar(row, "command")?.trim()?.split(Regex("\\s+"), limit = 2)?.first()) ?: return@mapNotNull null
            if (!seen.add(id)) return@mapNotNull null
            NasSystemProcess(id, name, processText(observationScalar(row, "status"), 80), processGroupId(observationScalar(row, "group_id", "group", "service")))
        }
        var unavailable = !supports(SYSTEM_PROCESS_GROUP, 1)
        val groups = if (unavailable) emptyList() else try {
            val groupRows = observationRows(gateway.call(SYSTEM_PROCESS_GROUP, "list", 1, parameters), "slices", "groups", "items")
            val groupIds = mutableSetOf<String>()
            groupRows.take(500).mapNotNull { raw ->
                val row = raw.jsonObject
                val id = processGroupId(observationScalar(row, "unit_name", "id", "group_id", "service")) ?: return@mapNotNull null
                val name = processName(observationScalar(row, "display_name", "name", "service")) ?: return@mapNotNull null
                if (!groupIds.add(id)) return@mapNotNull null
                val count = observationScalar(row, "process_count", "count")?.toIntOrNull()?.takeIf { it in 0..1_000_000 }
                    ?: (row["process"] as? JsonArray)?.size
                NasProcessGroup(id, name, processText(observationScalar(row, "status"), 80), count)
            }
        } catch (error: Exception) {
            if (error is CancellationException || directoryTrustFailure(error) && (error as? DsmFailure)?.kind != DsmErrorKind.PERMISSION_DENIED) throw error
            unavailable = true; emptyList()
        }
        val reported = observationScalar(data, "total", "total_count")?.toIntOrNull()?.takeIf { it in 0..1_000_000 }
        val total = maxOf(rows.size, reported ?: rows.size)
        return NasProcessDirectory(processes, groups, total, processes.size < total || processes.size == 500, unavailable)
    }
}
internal fun observationIncomplete(): Nothing = throw DsmFailure(null, "Device information is incomplete", "Refresh the page and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
private fun observationText(row: JsonObject, vararg names: String): String? {
    for (name in names) { val raw = row[name]?.takeUnless { it is JsonNull } ?: continue
        return (raw as? JsonPrimitive)?.takeIf { it.isString }?.content ?: observationIncomplete()
    }; return null
}
private fun observationScalar(row: JsonObject, vararg names: String): String? = names.firstNotNullOfOrNull { name ->
    (row[name] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull
}
private fun observationRows(value: JsonObject, vararg roots: String): JsonArray {
    val rows = roots.firstNotNullOfOrNull { value[it] } as? JsonArray ?: observationIncomplete()
    if (rows.any { it !is JsonObject }) observationIncomplete()
    return rows
}
private fun processText(value: String?, maximum: Int) = value?.replace(Regex("[\\r\\n]+"), " ")?.trim()?.takeIf { it.isNotEmpty() }?.take(maximum)
private fun processName(value: String?) = processText(value, 512)?.split('/', '\\')?.lastOrNull()?.let { processText(it, 160) }
private fun processGroupId(value: String?) = processText(value, 128)?.takeIf { it.all { char -> char.isLetterOrDigit() || char in "._-:" } }
