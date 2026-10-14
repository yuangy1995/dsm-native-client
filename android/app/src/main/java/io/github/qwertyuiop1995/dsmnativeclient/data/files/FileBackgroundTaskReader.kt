package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.number
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

internal const val FILE_BACKGROUND_API = "SYNO.FileStation.BackgroundTask"
internal val FileBackgroundTaskKind.taskAPI: Pair<String, Int> get() = when (this) {
    FileBackgroundTaskKind.COPY_OR_MOVE -> "SYNO.FileStation.CopyMove" to 3
    FileBackgroundTaskKind.DELETE -> "SYNO.FileStation.Delete" to 2
    FileBackgroundTaskKind.COMPRESS -> "SYNO.FileStation.Compress" to 3
    FileBackgroundTaskKind.EXTRACT -> "SYNO.FileStation.Extract" to 2
}

/** 展示保持既有宽容解码，控制回读拒绝缺页、坏行与重复身份。响应正文和路径不出解码边界。 */
internal class FileBackgroundTaskReader(
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
) {
    suspend fun page(offset: Int = 0, limit: Int = 100, strict: Boolean = false): FileBackgroundTaskPage {
        val requestedOffset = offset.coerceAtLeast(0); val requestedLimit = limit.coerceIn(1, 100)
        val data = call(FILE_BACKGROUND_API, "list", mapOf(
            "offset" to requestedOffset.toString(), "limit" to requestedLimit.toString(),
            "sort_by" to "crtime", "sort_direction" to "desc",
            "api_filter" to JsonArray(listOf(FileBackgroundTaskKind.COPY_OR_MOVE, FileBackgroundTaskKind.DELETE,
                FileBackgroundTaskKind.EXTRACT, FileBackgroundTaskKind.COMPRESS).map { JsonPrimitive(it.taskAPI.first) }).toString(),
        ), 3)
        val source = data["tasks"] as? JsonArray
        val raw = source?.take(requestedLimit).orEmpty()
        val responseOffset = data.long("offset"); val responseTotal = data.long("total")
        if (strict && (source == null || source.size > requestedLimit || responseOffset != requestedOffset.toLong() ||
            responseTotal == null || responseTotal !in (requestedOffset.toLong() + raw.size)..Int.MAX_VALUE.toLong() ||
            raw.isEmpty() && responseTotal != requestedOffset.toLong())) throw backgroundTaskChanged()
        val ids = mutableSetOf<String>()
        val tasks = raw.mapNotNull { element ->
            val summary = (element as? JsonObject)?.let { summary(it, strict) } ?: return@mapNotNull null
            summary.takeIf { ids.add(it.id) }
        }
        if (strict && tasks.size != raw.size) throw backgroundTaskChanged()
        val resolvedOffset = (responseOffset ?: requestedOffset.toLong()).coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
        val next = (resolvedOffset.toLong() + raw.size).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        val total = maxOf(next, (responseTotal ?: next.toLong()).coerceIn(0, Int.MAX_VALUE.toLong()).toInt())
        return FileBackgroundTaskPage(tasks, resolvedOffset, next, total, raw.isNotEmpty() && next < total)
    }

    suspend fun find(id: String): FileBackgroundTaskSummary? {
        var offset = 0; var total: Int? = null; var found: FileBackgroundTaskSummary? = null
        val ids = mutableSetOf<String>()
        do {
            currentCoroutineContext().ensureActive()
            val page = page(offset, strict = true)
            if (total != null && total != page.total || page.tasks.any { !ids.add(it.id) }) throw backgroundTaskChanged()
            page.tasks.singleOrNull { it.id == id }?.let { found = it }
            total = page.total; offset = page.nextOffset
        } while (offset < total!!)
        return found
    }

    private fun summary(payload: JsonObject, strict: Boolean): FileBackgroundTaskSummary? {
        fun text(key: String) = (payload[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        val rawId = text("taskid"); val id = normalizedBackgroundTaskId(rawId) ?: return null
        if (strict && id != rawId) return null
        val kind = FileBackgroundTaskKind.entries.firstOrNull { it.taskAPI.first == text("api") } ?: return null
        val finished = (payload["finished"] as? JsonPrimitive)?.contentOrNull?.lowercase()?.let {
            when (it) { "true", "1" -> true; "false", "0" -> false; else -> null }
        } ?: return null
        val created = payload.number("crtime")?.takeIf { it >= 946_684_800.0 && it <= System.currentTimeMillis() / 1000.0 + 86_400 }
        val total = payload.long("total")?.takeIf { it >= 0 }
        return FileBackgroundTaskSummary(id, kind, if (finished) FileBackgroundTaskState.FINISHED else FileBackgroundTaskState.ACTIVE,
            payload.number("progress")?.takeIf { it > 0 && it <= 1 }, created?.toLong(),
            payload.long("processed_num")?.takeIf { it in 0..Int.MAX_VALUE.toLong() }?.toInt(),
            if (kind == FileBackgroundTaskKind.DELETE) total?.takeIf { it <= Int.MAX_VALUE }?.toInt() else null,
            payload.long("processed_size")?.takeIf { it >= 0 }, if (kind == FileBackgroundTaskKind.COPY_OR_MOVE) total else null,
            payload.long("version")?.takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt(),
            text("method")?.takeIf { it == "start" }, created)
    }
}

internal fun normalizedBackgroundTaskId(value: String?): String? = value?.trim()?.takeIf { it.isNotEmpty() &&
    it.toByteArray(Charsets.UTF_8).size <= 256 && it.all { char -> char.isLetterOrDigit() || char in "._-:" } }
private fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.contentOrNull?.toLongOrNull()
internal fun backgroundTaskChanged() = DsmFailure(null, "Task details could not be refreshed", "Refresh the NAS tasks and try again.", kind = DsmErrorKind.FILE_BACKGROUND_TASK_CHANGED)
internal fun backgroundTaskPending() = DsmFailure(null, "An earlier task action has not finished", "Refresh this task before trying another action.", kind = DsmErrorKind.FILE_BACKGROUND_TASK_PENDING)
