package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import kotlinx.serialization.json.*

/** 内部条件相册契约见 photos-advanced-management.md；不推断闪光灯和范围的值域。 */
internal object SynologyPhotoConditionCodec {
    val references = setOf("folder_filter", "rating", "person", "concept", "general_tag", "camera", "lens", "aperture", "iso", "geocoding")
    private val sets = SynologyPhotoConditionField.entries.map { it.key }.toSet() + setOf("folder_filter", "rating", "item_type", "time")

    fun number(value: JsonElement?): Long? = (value as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull
    fun string(value: JsonElement?): String? = (value as? JsonPrimitive)?.takeIf { it.isString }?.content

    fun decode(raw: JsonObject): SynologyPhotoAlbumCondition {
        val fields = raw.toMutableMap()
        val names = mutableMapOf<String, List<SynologyPhotoConditionOption>>()
        for (key in references) {
            val values = fields[key] ?: continue
            names[key] = (values as? JsonArray ?: invalid()).map { value ->
                val item = value as? JsonObject ?: invalid()
                SynologyPhotoConditionOption(JsonPrimitive(number(item["id"]) ?: invalid()), string(item["name"]))
            }
            fields[key] = JsonArray(names.getValue(key).map { it.value })
        }
        return SynologyPhotoAlbumCondition(JsonObject(fields), names)
    }

    fun canonical(condition: SynologyPhotoAlbumCondition, user: Long): JsonObject {
        if (user <= 0) invalid()
        val fields = condition.fields
        val source = if (condition.space == SynologyPhotoSpace.SHARED) 0L else user
        if (fields.containsKey("user_id") && number(fields["user_id"]) != source)
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        for (key in sets) if (key in fields && fields[key] !is JsonArray) invalid()
        val media = condition.values("item_type")
        if (media.any { number(it) == null }) invalid()
        for (key in references) if (condition.values(key).any { number(it) == null }) invalid()
        if (condition.values("folder_filter").any { number(it)!! <= 0 } ||
            condition.values("rating").any { number(it) !in 0L..5L } ||
            condition.values("keyword").any { string(it).isNullOrBlank() }) invalid()
        for (field in SynologyPhotoConditionField.entries.filter { it.supportsPolicy }) {
            if (condition.values(field.key).isNotEmpty() && string(fields["${field.key}_policy"]) !in setOf("and", "or")) invalid()
        }
        for (range in condition.values("time")) {
            val value = range as? JsonObject ?: invalid()
            val start = number(value["start_time"]); val end = number(value["end_time"])
            if (start == null && end == null || "start_time" in value && start == null || "end_time" in value && end == null ||
                start != null && start < 0 || end != null && end < 0 || start != null && end != null && start > end) invalid()
        }
        for (key in setOf("focal_length_group", "exposure_time_group")) if (condition.values(key).any {
            it !is JsonObject || "start" !in it || "end" !in it
        }) invalid()
        val result = fields.toMutableMap()
        result["user_id"] = JsonPrimitive(source)
        result.putIfAbsent("item_type", JsonArray(emptyList()))
        for (key in sets) {
            val values = result[key] as? JsonArray ?: continue
            if (values.isEmpty() && key != "item_type") result.remove(key)
            else result[key] = JsonArray(values.sortedBy { stable(it).toString() })
        }
        return JsonObject(result)
    }

    // JSON 数字的普通小数与科学计数法含义相同；仅比较时归一化，不改未知数组顺序或请求值。
    fun matches(first: SynologyPhotoAlbumCondition, second: SynologyPhotoAlbumCondition, user: Long): Boolean =
        stable(canonical(first, user)) == stable(canonical(second, user))

    private fun stable(value: JsonElement): JsonElement = when (value) {
        is JsonObject -> JsonObject(value.toSortedMap().mapValues { stable(it.value) })
        is JsonArray -> JsonArray(value.map(::stable))
        is JsonPrimitive -> if (value == JsonNull || value.isString || value.booleanOrNull != null) value
            else JsonPrimitive((value.content.toBigDecimalOrNull() ?: invalid()).stripTrailingZeros())
        else -> value
    }

    fun suggestions(raw: JsonObject): Map<String, List<SynologyPhotoConditionOption>> {
        val result = mutableMapOf<String, List<SynologyPhotoConditionOption>>()
        fun location(value: JsonElement, parents: List<String>, parentId: Long?, output: MutableList<SynologyPhotoConditionOption>) {
            val item = value as? JsonObject ?: invalid()
            val id = number(item["id"]) ?: invalid(); val name = string(item["name"]) ?: invalid()
            val children = item["children"]?.let { it as? JsonArray ?: invalid() }.orEmpty()
            if (children.isEmpty()) {
                val repeated = name == parents.lastOrNull() && parentId != null
                output += SynologyPhotoConditionOption(JsonPrimitive(if (repeated) parentId else id),
                    (if (repeated) parents else parents + name).joinToString(", "))
            } else children.forEach { location(it, parents + name, id, output) }
        }
        for (field in SynologyPhotoConditionField.entries.filter { it.canSuggest }) {
            val rawValues = raw[field.key] ?: continue
            val values = rawValues as? JsonArray ?: invalid()
            result[field.key] = if (field == SynologyPhotoConditionField.LOCATION) buildList { values.forEach { location(it, emptyList(), null, this) } }
                else values.map { value ->
                    val item = value as? JsonObject ?: invalid()
                    if (field in setOf(SynologyPhotoConditionField.FOCAL_LENGTH, SynologyPhotoConditionField.EXPOSURE)) {
                        if ("start" !in item || "end" !in item) invalid()
                        SynologyPhotoConditionOption(item)
                    } else SynologyPhotoConditionOption(JsonPrimitive(number(item["id"]) ?: invalid()), string(item["name"]) ?: invalid())
                }
        }
        return result.mapValues { it.value.distinctBy { choice -> choice.value } }
    }
}
