package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

enum class SynologyPhotoConditionField(val key: String, val supportsPolicy: Boolean = false) {
    KEYWORD("keyword", true), PERSON("person", true), CONCEPT("concept", true), TAG("general_tag", true),
    CAMERA("camera"), LENS("lens"), APERTURE("aperture"), ISO("iso"), LOCATION("geocoding"),
    FOCAL_LENGTH("focal_length_group"), EXPOSURE("exposure_time_group"), FLASH("flash");
    val canSuggest: Boolean get() = this != KEYWORD && this != FLASH
}

@Serializable
data class SynologyPhotoConditionOption(val value: JsonElement, val name: String? = null) {
    override fun toString() = "PhotoConditionOption"
}

/** 完整保留未知规则与无名引用；显示名称不参与请求或结果比较。 */
@Serializable
data class SynologyPhotoAlbumCondition(
    val fields: JsonObject = buildJsonObject { put("item_type", JsonArray(emptyList())) },
    val names: Map<String, List<SynologyPhotoConditionOption>> = emptyMap(),
) {
    val space: SynologyPhotoSpace get() = if ((fields["user_id"] as? JsonPrimitive)?.longOrNull == 0L)
        SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
    fun values(key: String): List<JsonElement> = (fields[key] as? JsonArray)?.toList().orEmpty()
    fun withValues(key: String, values: List<JsonElement>): SynologyPhotoAlbumCondition {
        val next = fields.toMutableMap()
        if (values.isEmpty() && key != "item_type") next.remove(key) else next[key] = JsonArray(values)
        if (values.isEmpty()) next.remove("${key}_policy")
        return copy(fields = JsonObject(next))
    }
    fun withField(key: String, value: JsonElement): SynologyPhotoAlbumCondition = copy(fields = JsonObject(fields + (key to value)))
    override fun toString() = "PhotoAlbumCondition"
}
