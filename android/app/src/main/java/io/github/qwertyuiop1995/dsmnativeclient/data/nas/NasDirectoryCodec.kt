package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.Locale
import kotlinx.serialization.json.*

internal fun directoryFailure(problem: NasDirectoryProblem = NasDirectoryProblem.INCOMPLETE): Nothing = throw NasDirectoryFailure(problem)
internal fun directoryKey(name: String) = name.lowercase(Locale.ROOT)
internal fun directoryNameValid(name: String) = name.isNotBlank() && name.none(Char::isISOControl)
internal fun directoryRows(data: JsonObject, key: String): List<JsonObject> {
    val rows = data[key] as? JsonArray ?: directoryFailure()
    if (rows.size >= 1000 || data["total"]?.let { (it as? JsonPrimitive)?.longOrNull != rows.size.toLong() } == true) directoryFailure()
    val names = mutableSetOf<String>(); val ids = mutableSetOf<Long>()
    return rows.map { raw ->
        val row = raw as? JsonObject ?: directoryFailure()
        val extra = row["additional"]?.takeUnless { it is JsonNull }?.let { it as? JsonObject ?: directoryFailure() }.orEmpty()
        val fields = row.toMutableMap()
        extra.forEach { (name, value) ->
            val original = row[name]?.takeUnless { it is JsonNull }
            if (original != null && value !is JsonNull && original != value) directoryFailure()
            if (value !is JsonNull) fields[name] = value
        }
        JsonObject(fields).also { value ->
            val name = value.text("name") ?: directoryFailure()
            if (!directoryNameValid(name) || !names.add(directoryKey(name))) directoryFailure()
            value.number(if (key == "users") "uid" else "gid")?.let { if (!ids.add(it)) directoryFailure() }
        }
    }
}
internal fun JsonObject.text(key: String): String? = this[key]?.takeUnless { it is JsonNull }?.let { raw ->
    (raw as? JsonPrimitive)?.takeIf { it.isString }?.content ?: directoryFailure()
}
internal fun JsonObject.flag(key: String): Boolean? = this[key]?.takeUnless { it is JsonNull }?.let { raw ->
    (raw as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: directoryFailure()
}
internal fun JsonObject.number(key: String): Long? = this[key]?.takeUnless { it is JsonNull }?.let { raw ->
    (raw as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull?.takeIf { it >= 0 } ?: directoryFailure()
}
internal fun decodeDirectoryAccounts(data: JsonObject): List<NasAccount> = directoryRows(data, "users").map { row ->
    val expired = row["expired"]?.takeUnless { it is JsonNull }?.let {
        when (it) { JsonPrimitive("normal") -> false; JsonPrimitive("now") -> true; else -> row.flag("expired") }
    }
    val legacy = listOf("disabled", "is_disabled").mapNotNull { row.flag(it) }.distinct()
    if (legacy.size > 1 || expired != null && legacy.any { it != expired }) directoryFailure()
    val disabled = expired ?: legacy.singleOrNull()
    val groups = row["groups"]?.takeUnless { it is JsonNull }?.let { raw ->
        (raw as? JsonArray ?: directoryFailure()).map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: directoryFailure() }.also {
            if (it.any { name -> !directoryNameValid(name) } || it.map(::directoryKey).distinct().size != it.size) directoryFailure()
        }
    }
    val description = row.text("description"); val email = row.text("email")
    NasAccount(row.number("uid"), row.text("name") ?: directoryFailure(), description, email, disabled ?: false,
        row.flag("can_delete") == true, row.flag("can_edit") != false && description != null && email != null && disabled != null,
        groups, disabled != null)
}
internal fun decodeDirectoryGroups(data: JsonObject): List<NasGroup> = directoryRows(data, "groups").map { row ->
    val description = row.text("description")
    NasGroup(row.number("gid"), row.text("name") ?: directoryFailure(), description, row.flag("can_delete") == true,
        row.flag("can_edit") != false && description != null)
}
internal fun directoryFields(change: NasDirectoryChange): JsonObject = buildJsonObject {
    put("name", change.name); put("description", change.description)
    if (change.kind == NasDirectoryKind.ACCOUNT) {
        put("email", change.email); put("expired", change.disabled)
        change.groups?.let { put("groups", JsonArray(it.sorted().map(::JsonPrimitive))) }
    }
}
internal fun directoryFields(account: NasAccount, includeGroups: Boolean): JsonObject = buildJsonObject {
    put("name", account.name); put("description", account.description); put("email", account.email)
    if (account.disabledKnown) put("expired", account.disabled)
    if (includeGroups) put("groups", account.groups?.let { JsonArray(it.sorted().map(::JsonPrimitive)) } ?: JsonNull)
}
internal fun directoryFields(group: NasGroup): JsonObject = buildJsonObject { put("name", group.name); put("description", group.description) }
