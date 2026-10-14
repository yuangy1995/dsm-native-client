package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.parseFilePageFixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.int
import io.github.qwertyuiop1995.dsmnativeclient.network.string
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

/** 只处理本次任务；正文扩展见 file-station-content-search 记录。 */
internal class DsmFileSearchRepository(
    private val call: suspend (String, Map<String, String>) -> JsonObject,
    private val timeoutMillis: Long = 300_000,
    private val pollDelayMillis: Long = 250,
) {
    suspend fun search(request: FileSearchRequest): FileSearchResult {
        request.nameError?.let { throw searchFailure(it) }
        if (!request.isValid) throw searchFailure(DsmErrorKind.FILE_SEARCH_INVALID_CONDITIONS)
        currentCoroutineContext().ensureActive()
        val parameters = buildMap {
            put("folder_path", JsonArray(request.folders.distinct().map(::JsonPrimitive)).toString())
            put("pattern", if (request.nameSearch.isRegularExpression) "*" else request.name)
            put("recursive", request.recursive.toString()); put("filetype", request.kind.apiValue)
            listOf("extension" to request.extension, "owner" to request.owner, "group" to request.group)
                .filter { it.second.isNotEmpty() }.forEach { (key, value) -> put(key, value) }
            request.minimumBytes?.let { put("size_from", it.toString()) }
            request.maximumBytes?.let { put("size_to", it.toString()) }
            listOf("mtime" to request.modified, "crtime" to request.created, "atime" to request.accessed).forEach { (prefix, range) ->
                range.fromEpochSeconds?.let { put("${prefix}_from", it.toString()) }
                range.toEpochSeconds?.let { put("${prefix}_to", it.toString()) }
            }
            if (request.searchesContents) { put("search_content", "true"); put("search_type", "advance") }
        }
        val start = call("start", parameters)
        val id = start.string("taskid")?.takeIf { it.isNotBlank() } ?: throw searchFailure(DsmErrorKind.SEARCH_NOT_STARTED)
        var completed = false
        try {
            val coverage = if (!request.searchesContents) FileSearchIndexCoverage.NOT_REQUESTED else {
                when (start.nativeBoolean("has_not_index_share")) {
                    true -> FileSearchIndexCoverage.INCOMPLETE
                    false -> FileSearchIndexCoverage.COMPLETE
                    null -> throw searchFailure(DsmErrorKind.FILE_CONTENT_SEARCH_UNAVAILABLE)
                }
            }
            val page = withTimeoutOrNull(timeoutMillis) { readCompleteResult(id) }
                ?: throw searchFailure(DsmErrorKind.FILE_SEARCH_TIMED_OUT)
            completed = true
            val filtered = request.nameSearch.expression?.let { expression ->
                withContext(Dispatchers.Default) {
                    val items = page.items.filter { item ->
                        currentCoroutineContext().ensureActive()
                        expression.containsMatchIn(item.name)
                    }
                    FilePage(items, items.size, 0)
                }
            } ?: page
            return FileSearchResult(filtered, coverage)
        } finally {
            withContext(NonCancellable) {
                withTimeoutOrNull(5_000) {
                    if (!completed) runCatching { call("stop", mapOf("taskid" to id)) }
                    runCatching { call("clean", mapOf("taskid" to id)) }
                }
            }
        }
    }

    private suspend fun readCompleteResult(id: String): FilePage {
        var delayMillis = pollDelayMillis
        var first: JsonObject
        while (true) {
            currentCoroutineContext().ensureActive()
            first = list(id, 0)
            when (first.nativeBoolean("finished")) {
                true -> break
                false -> { delay(delayMillis); delayMillis = (delayMillis * 2).coerceAtMost(1_000) }
                null -> throw searchFailure(DsmErrorKind.FILE_SEARCH_INCOMPLETE)
            }
        }
        val items = linkedMapOf<String, FileItem>()
        var payload = first
        var offset = 0
        val total = first.int("total") ?: throw searchFailure(DsmErrorKind.FILE_SEARCH_INCOMPLETE)
        if (total < 0) throw searchFailure(DsmErrorKind.FILE_SEARCH_INCOMPLETE)
        while (true) {
            currentCoroutineContext().ensureActive()
            val raw = payload["files"] as? JsonArray ?: throw searchFailure(DsmErrorKind.FILE_SEARCH_INCOMPLETE)
            if (payload.int("offset")?.let { it != offset } == true ||
                payload.int("total")?.let { it != total } == true || raw.size > PAGE_SIZE ||
                raw.size > total - offset || raw.isEmpty() && offset < total
            ) throw searchFailure(DsmErrorKind.FILE_SEARCH_INCOMPLETE)
            val decoded = parseFilePageFixture(payload).items
            if (decoded.size != raw.size) throw searchFailure(DsmErrorKind.FILE_SEARCH_INCOMPLETE)
            decoded.forEach { items.putIfAbsent(it.path, it) }
            offset += raw.size
            if (offset >= total) break
            payload = list(id, offset)
            if (payload.nativeBoolean("finished") != true) throw searchFailure(DsmErrorKind.FILE_SEARCH_INCOMPLETE)
        }
        return FilePage(items.values.toList(), items.size, 0)
    }

    private suspend fun list(id: String, offset: Int) = call("list", mapOf(
        "taskid" to id, "offset" to offset.toString(), "limit" to PAGE_SIZE.toString(),
        "additional" to "[\"real_path\",\"size\",\"owner\",\"time\",\"perm\",\"mount_point_type\"]",
    ))

    private fun JsonObject.nativeBoolean(key: String): Boolean? = (this[key] as? JsonPrimitive)
        ?.takeUnless { it.isString }?.booleanOrNull

    private fun searchFailure(kind: DsmErrorKind) = DsmFailure(null, "File search is unavailable", "Adjust the search and try again.", kind = kind)
    private companion object { const val PAGE_SIZE = 500 }
}
