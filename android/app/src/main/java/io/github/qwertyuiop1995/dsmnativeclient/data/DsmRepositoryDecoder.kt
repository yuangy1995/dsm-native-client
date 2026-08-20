package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogLevel
import io.github.qwertyuiop1995.dsmnativeclient.network.int
import io.github.qwertyuiop1995.dsmnativeclient.network.long
import io.github.qwertyuiop1995.dsmnativeclient.network.objectValue
import io.github.qwertyuiop1995.dsmnativeclient.network.string
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * 与网络传输和门面状态无关的 DSM 响应解码器。
 *
 * 所有函数保持既有宽容解析规则，以便生产请求与脱敏 fixture 使用相同语义。
 */
internal fun decodeTextPreview(bytes: ByteArray): String {
    val (content, charset) = when {
        bytes.startsWith(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())) ->
            bytes.copyOfRange(3, bytes.size) to Charsets.UTF_8
        bytes.startsWith(byteArrayOf(0xFF.toByte(), 0xFE.toByte())) ->
            bytes.copyOfRange(2, bytes.size) to Charsets.UTF_16LE
        bytes.startsWith(byteArrayOf(0xFE.toByte(), 0xFF.toByte())) ->
            bytes.copyOfRange(2, bytes.size) to Charsets.UTF_16BE
        else -> bytes to Charsets.UTF_8
    }
    return content.toString(charset).replace("\u0000", "�")
}

private fun ByteArray.startsWith(prefix: ByteArray): Boolean =
    size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }

/** 套件图标只接受 DSM 实际返回的常见位图格式，拒绝 HTML、SVG 和未知二进制内容。 */
internal fun hasKnownPackageIconSignature(bytes: ByteArray): Boolean = when {
    bytes.startsWith(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)) -> true
    bytes.startsWith(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte())) -> true
    bytes.startsWith(byteArrayOf(0x47, 0x49, 0x46, 0x38)) -> true
    bytes.size >= 12 && bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(0x52, 0x49, 0x46, 0x46)) &&
        bytes.copyOfRange(8, 12).contentEquals(byteArrayOf(0x57, 0x45, 0x42, 0x50)) -> true
    else -> false
}

/** 将 File Station 列表数据转换为稳定领域语义，供生产请求和脱敏 fixture 共用。 */
internal fun parseFilePageFixture(data: JsonObject, root: String = "files"): FilePage {
    val items = data.elements(root).mapNotNull { element ->
        val item = element as? JsonObject ?: return@mapNotNull null
        val additional = item.objectValue("additional")
        val time = additional?.objectValue("time")
        val permission = additional?.objectValue("perm")
        FileItem(
            path = item.string("path") ?: return@mapNotNull null,
            name = item.string("name") ?: item.string("path")?.substringAfterLast('/').orEmpty(),
            isDirectory = item.bool("isdir") ?: false,
            size = item.long("size") ?: additional?.long("size") ?: 0,
            modifiedAtEpochSeconds = time?.long("mtime") ?: item.long("mtime"),
            accessedAtEpochSeconds = time?.long("atime") ?: item.long("atime"),
            owner = additional?.objectValue("owner")?.string("user") ?: additional?.string("owner"),
            canRead = permission?.bool("read") ?: true,
            canWrite = permission?.bool("write") ?: false,
            canDelete = permission?.bool("delete") ?: false,
            mountPointType = additional?.string("mount_point_type") ?: item.string("mount_point_type"),
        )
    }
    return FilePage(
        items = items,
        total = data.int("total") ?: items.size,
        offset = data.int("offset") ?: 0,
    )
}

internal fun parseVirtualizationLogs(data: JsonObject): List<LogEntry> =
    sequenceOf("logs", "log", "events", "records", "entries", "items", "data", "list")
        .flatMap { data.elements(it).asSequence() }
        .distinctBy { it.toString() }
        .mapIndexedNotNull { index, element ->
            val item = element as? JsonObject ?: return@mapIndexedNotNull null
            val rawTime = item.long("time")
                ?: item.long("timestamp")
                ?: item.long("date")
                ?: item.long("event_time")
                ?: item.long("create_time")
                ?: item.long("created_at")
            val event = item.string("event")
                ?: item.string("message")
                ?: item.string("description")
                ?: item.string("msg")
                ?: item.string("content")
                ?: item.string("detail")
                ?: return@mapIndexedNotNull null
            LogEntry(
                id = item.string("id") ?: item.string("log_id") ?: "${rawTime ?: 0}:$index",
                level = parsedLogLevel(
                    item.string("level")
                        ?: item.string("severity")
                        ?: item.string("type")
                        ?: item.string("priority"),
                ),
                timeEpochSeconds = rawTime?.let { if (it > 10_000_000_000) it / 1_000 else it },
                user = item.string("user")
                    ?: item.string("username")
                    ?: item.string("owner")
                    ?: item.string("account")
                    ?: item.string("user_name")
                    ?: "SYSTEM",
                event = event,
            )
        }
        .toList()

internal fun parsedLogLevel(value: String?): LogLevel = when (value?.lowercase()) {
    "info", "information", "0" -> LogLevel.INFO
    "warning", "warn", "1" -> LogLevel.WARNING
    "error", "err", "2" -> LogLevel.ERROR
    else -> LogLevel.UNKNOWN
}

internal fun JsonObject.elements(key: String): List<JsonElement> =
    (this[key] as? JsonArray)?.toList().orEmpty()

internal fun JsonObject.bool(key: String): Boolean? =
    this[key]?.jsonPrimitive?.let { primitive ->
        primitive.booleanOrNull
            ?: primitive.contentOrNull?.let { value ->
                when (value.lowercase()) {
                    "1", "true" -> true
                    "0", "false" -> false
                    else -> null
                }
            }
    }

internal fun JsonObject.number(key: String): Double? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()?.takeIf { it.isFinite() }

internal fun JsonObject.nonNegativeLong(key: String): Long? =
    long(key)?.coerceAtLeast(0)

internal fun JsonObject.valueString(vararg keys: String): String? = keys.firstNotNullOfOrNull { key ->
    (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank)
}

internal fun JsonObject.firstNonBlank(vararg keys: String): String? =
    keys.firstNotNullOfOrNull { key -> string(key)?.trim()?.takeIf(String::isNotBlank) }

internal fun normalizeEpoch(value: Long?): Long? = value?.let {
    when {
        it > 10_000_000_000L -> it / 1_000
        it > 0 -> it
        else -> null
    }
}

internal fun normalizeEpochMillis(value: Long?): Long? = value?.let {
    when {
        it > 10_000_000_000L -> it
        it > 0 -> it * 1_000
        else -> null
    }
}
