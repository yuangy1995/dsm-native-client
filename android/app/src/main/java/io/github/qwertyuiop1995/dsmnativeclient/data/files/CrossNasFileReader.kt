package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.parseFilePageFixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

/** 跨 NAS 写入前后需要完整结果，不能把漏字段或损坏行解释成不存在。 */
internal class CrossNasFileReader(private val call: suspend (String, Map<String, String>) -> JsonObject) {
    suspend fun page(path: String, offset: Int, limit: Int): FilePage {
        val data = call("list", mapOf("folder_path" to path, "offset" to offset.toString(), "limit" to limit.toString(),
            "sort_by" to "name", "sort_direction" to "asc", "filetype" to "all", "additional" to ADDITIONAL))
        val actualOffset = data.number("offset") ?: throw crossNasReadFailure()
        val total = data.number("total") ?: throw crossNasReadFailure()
        val rows = data["files"] as? JsonArray ?: throw crossNasReadFailure()
        if (actualOffset != offset.toLong() || total !in 0..Int.MAX_VALUE.toLong() || rows.size > limit ||
            offset.toLong() + rows.size > total || rows.isEmpty() && offset.toLong() != total) throw crossNasReadFailure()
        val items = rows.map { decode(it as? JsonObject ?: throw crossNasReadFailure()) }
        if (items.any { crossNasParent(it.path) != path } || items.map { it.path }.distinct().size != items.size) throw crossNasReadFailure()
        return FilePage(items, total.toInt(), offset)
    }
    suspend fun item(path: String): FileItem? {
        val data = call("getinfo", mapOf("path" to JsonArray(listOf(JsonPrimitive(path))).toString(), "additional" to ADDITIONAL))
        val row = (data["files"] as? JsonArray)?.singleOrNull() as? JsonObject ?: throw crossNasReadFailure()
        if (row.text("path") != path) throw crossNasReadFailure()
        if (row.number("code") == 408L) return null
        return decode(row)
    }
    private fun decode(row: JsonObject): FileItem {
        val path = row.text("path")?.takeIf(::isFileMutationPath) ?: throw crossNasReadFailure()
        val name = row.text("name") ?: throw crossNasReadFailure()
        val directory = (row["isdir"] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: throw crossNasReadFailure()
        val additional = row["additional"] as? JsonObject ?: throw crossNasReadFailure()
        val time = additional["time"] as? JsonObject
        val modified = time?.number("mtime") ?: row.number("mtime") ?: throw crossNasReadFailure()
        val size = row.number("size") ?: additional.number("size")
        if (name != path.substringAfterLast('/') || row.containsKey("code") && row.number("code") != 0L ||
            modified < 0 || !directory && (size == null || size < 0) ||
            (additional.text("mount_point_type") ?: row.text("mount_point_type")) == null || additional["perm"] !is JsonObject) throw crossNasReadFailure()
        return parseFilePageFixture(buildJsonObject { putJsonArray("files") { add(row) } }).items.single()
    }
    private fun JsonObject.text(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    private fun JsonObject.number(key: String) = (this[key] as? JsonPrimitive)?.longOrNull
    private companion object { const val ADDITIONAL = "[\"size\",\"time\",\"perm\",\"mount_point_type\"]" }
}
