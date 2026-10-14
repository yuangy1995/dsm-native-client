package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*
import java.net.URI
import java.time.LocalDate
import java.time.LocalTime

/** 扩展字段缺失时仍可阅读基础链接，但不可据此认定公开、无密码或已保存设置。 */
internal fun parseFileShareLink(value: JsonElement): FileShareLink {
    val item = value as? JsonObject ?: throw fileShareReadFailure()
    val identifier = item["id"] as? JsonPrimitive ?: throw fileShareReadFailure()
    if (!identifier.isString && identifier.longOrNull == null) throw fileShareReadFailure()
    val id = identifier.contentOrNull?.takeIf { it.isNotBlank() } ?: throw fileShareReadFailure()
    val path = item.text("path")?.takeIf { isFileMutationPath(it) } ?: throw fileShareReadFailure()
    val url = item.text("url") ?: throw fileShareReadFailure()
    val uri = runCatching { URI(url) }.getOrNull()
    if (uri == null || uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrEmpty() || uri.rawUserInfo != null) throw fileShareReadFailure()
    val password = item.flag("has_password")
    if (item.containsKey("has_password") && password == null) throw fileShareReadFailure()
    return FileShareLink(
        id = id, path = path, name = item.text("name") ?: path.substringAfterLast('/'), url = url,
        hasPassword = password ?: false, passwordKnown = password != null,
        expiresAt = item.shareDate("date_expired"), expirationKnown = item.containsKey("date_expired"),
        availableAt = item.shareDate("date_available"), availabilityKnown = item.containsKey("date_available"),
        status = FileShareStatus.entries.firstOrNull { it.name.equals(item.text("status"), ignoreCase = true) } ?: FileShareStatus.UNKNOWN,
        advanced = parseAdvancedShare(item),
    )
}

private fun JsonObject.shareDate(key: String): String? {
    if (!containsKey(key)) return null
    val value = this[key] as? JsonPrimitive ?: throw fileShareReadFailure()
    if (value is JsonNull) throw fileShareReadFailure()
    if (!value.isString) return if (value.intOrNull == 0) null else throw fileShareReadFailure()
    val text = value.content
    if (text.isEmpty() || text == "0") return null
    if (!text.matches(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}:[0-9]{2})?"))) throw fileShareReadFailure()
    try {
        LocalDate.parse(text.take(10))
        if (text.length == 19) LocalTime.parse(text.drop(11))
    } catch (_: Exception) { throw fileShareReadFailure() }
    return text
}

private fun parseAdvancedShare(item: JsonObject): FileShareAdvancedDetails? {
    val protection = when (item.text("protect_type")) {
        "none" -> FileShareProtection.NONE
        "password" -> FileShareProtection.PASSWORD
        "user" -> FileShareProtection.USERS
        else -> return null
    }
    val users = item.stringSet("protect_users") ?: return null
    val groups = item.stringSet("protect_groups") ?: return null
    val count = item.integer("expire_times")?.takeIf { it >= 0 } ?: return null
    val uploads = item.flag("enable_upload") ?: return null
    val isRequest = when (item.text("project_name")) {
        "SYNO.SDS.App.FileStation3.Instance" -> false
        "SYNO.SDS.App.SharingUpload.Application" -> true
        else -> return null
    }
    return FileShareAdvancedDetails(protection, users, groups, count, isRequest, uploads,
        item.text("request_name") ?: return null, item.text("request_info") ?: return null)
}

internal fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
internal fun JsonObject.integer(key: String): Int? = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
private fun JsonObject.flag(key: String): Boolean? = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.let {
    it.booleanOrNull ?: when (it.intOrNull) { 0 -> false; 1 -> true; else -> null }
}
private fun JsonObject.stringSet(key: String): Set<String>? {
    val values = this[key] as? JsonArray ?: return null
    val result = values.map { (it as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null }
    if (result.any(String::isBlank) || result.distinct().size != result.size) return null
    return result.toSet()
}
internal fun shareStrings(values: Collection<String>): String = JsonArray(values.map(::JsonPrimitive)).toString()
internal fun fileShareReadFailure(): DsmFailure = DsmFailure(null, "Shared links could not be read", "Refresh shared links and try again.", kind = DsmErrorKind.CHANGE_NOT_CONFIRMED)
