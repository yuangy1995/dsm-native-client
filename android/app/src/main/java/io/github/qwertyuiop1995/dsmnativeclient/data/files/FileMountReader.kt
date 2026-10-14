package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.parseFilePageFixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

/** 挂载清单只读取已记录字段；缺失、重复和格式错误不会变成空清单。 */
internal class FileMountReader(private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject) {
    suspend fun inventory(): FileMountInventory {
        val data = call(MOUNT_LIST_API, "get", emptyMap(), 1)
        val config = data["mountConfig"] as? JsonObject ?: throw mountReadFailure()
        val rows = listOf("isoList", "remoteList").flatMap { key ->
            (data[key] as? JsonArray)?.map { value ->
                val row = value as? JsonObject ?: throw mountReadFailure()
                val kind = when (row.mountText("type")?.lowercase()) {
                    "iso" -> FileMountKind.ISO
                    "cifs" -> FileMountKind.CIFS
                    "nfs" -> FileMountKind.NFS
                    else -> throw mountReadFailure()
                }
                if ((key == "isoList") != (kind == FileMountKind.ISO)) throw mountReadFailure()
                val source = row.mountText("source")?.takeIf(String::isNotEmpty) ?: throw mountReadFailure()
                val point = row.mountText("mount_point")?.takeIf(::isMountTargetPath) ?: throw mountReadFailure()
                if (kind == FileMountKind.ISO && !isFileMutationPath(source)) throw mountReadFailure()
                val identity = if (kind == FileMountKind.ISO) source else runCatching { canonicalRemoteMountSource(kind, source) }.getOrElse { throw mountReadFailure() }
                FileMountConnection(kind, identity, point, if ("auto_mount" in row) row.mountBoolean("auto_mount") else null)
            } ?: throw mountReadFailure()
        }
        if (rows.map { it.mountPoint }.distinct().size != rows.size) throw mountReadFailure()
        return FileMountInventory(config.mountBoolean("enable_iso_mount"), config.mountBoolean("enable_remote_mount"), rows)
    }

    suspend fun item(path: String, allowMissing: Boolean = false, requireFileMetadata: Boolean = false): FileItem? {
        if (!isFileMutationPath(path)) throw mountChanged()
        val data = call("SYNO.FileStation.List", "getinfo", mapOf("path" to mountStrings(listOf(path)),
            "additional" to mountStrings(listOf("size", "time", "perm", "mount_point_type"))), 2)
        val row = (data["files"] as? JsonArray)?.singleOrNull() as? JsonObject ?: throw mountReadFailure()
        if (row.mountText("path") != path) throw mountReadFailure()
        val code = row["code"]?.mountInteger()
        if (allowMissing && code == 408L) return null
        if (code != null && code != 0L) throw mountReadFailure()
        val directory = row.mountBoolean("isdir")
        val additional = row["additional"] as? JsonObject ?: throw mountReadFailure()
        if (additional.mountText("mount_point_type") == null) throw mountReadFailure()
        if (requireFileMetadata) {
            if (directory) throw mountChanged()
            val size = (row["size"] ?: additional["size"])?.mountInteger() ?: throw mountReadFailure()
            val time = additional["time"] as? JsonObject
            if (size < 0 || (time?.get("mtime") ?: row["mtime"])?.mountInteger() == null) throw mountReadFailure()
        }
        return parseFilePageFixture(buildJsonObject { putJsonArray("files") { add(row) } }).items.single()
            .copy(accessedAtEpochSeconds = null)
    }

    suspend fun requireEmpty(path: String) {
        val data = call("SYNO.FileStation.List", "list", mapOf("folder_path" to path, "offset" to "0", "limit" to "1"), 2)
        val total = data["total"]?.mountInteger() ?: throw mountReadFailure()
        val items = data["files"] as? JsonArray ?: throw mountReadFailure()
        val offset = data["offset"]?.mountInteger() ?: throw mountReadFailure()
        if (offset != 0L || total < 0 || total == 0L && items.isNotEmpty()) throw mountReadFailure()
        if (total != 0L || items.isNotEmpty()) throw mountEmptyRequired()
    }
}

internal const val MOUNT_API = "SYNO.FileStation.Mount"
internal const val MOUNT_LIST_API = "SYNO.FileStation.Mount.List"
internal fun isMountTargetPath(path: String) = isFileMutationPath(path) && path.drop(1).split('/').size >= 2 && "#recycle" !in path.split('/')
internal fun mountPathsOverlap(first: String, second: String) = first == second || first.startsWith("$second/") || second.startsWith("$first/")
internal fun mountStrings(values: List<String>) = JsonArray(values.map(::JsonPrimitive)).toString()
private fun JsonObject.mountText(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
private fun JsonObject.mountBoolean(key: String) = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: throw mountReadFailure()
private fun JsonElement.mountInteger() = (this as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: throw mountReadFailure()
internal fun mountReadFailure() = DsmFailure(null, "Mounts could not be read", "Refresh and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
internal fun mountChanged() = DsmFailure(null, "The selected files or mount changed", "Refresh and choose them again.", kind = DsmErrorKind.FILE_MOUNT_CHANGED)
internal fun mountEmptyRequired() = DsmFailure(null, "The folder is not empty", "Choose an existing empty folder.", kind = DsmErrorKind.FILE_MOUNT_EMPTY_REQUIRED)
internal fun mountPending() = DsmFailure(null, "A related mount has not finished", "Open ISO mounts and refresh the earlier operation.", kind = DsmErrorKind.FILE_MOUNT_PENDING)
