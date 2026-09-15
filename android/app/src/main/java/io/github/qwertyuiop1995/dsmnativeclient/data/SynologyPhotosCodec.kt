package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.time.DateTimeException
import java.time.LocalDate
import kotlinx.serialization.json.*

/** 严格解码已记录的 Photos 字段：缺失列表不伪装为空，未知媒体类型不按扩展名猜测。 */
internal object SynologyPhotosCodec {
    fun invalid(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
    fun JsonElement.obj(): JsonObject = this as? JsonObject ?: invalid()
    fun JsonObject.obj(key: String): JsonObject = this[key]?.obj() ?: invalid()
    fun JsonObject.optionalObject(key: String): JsonObject? = when (val value = this[key]) {
        null, JsonNull -> null
        else -> value.obj()
    }
    fun JsonObject.list(key: String = "list"): List<JsonObject> = (this[key] as? JsonArray)?.map { it.obj() } ?: invalid()
    fun JsonObject.optionalList(key: String): List<JsonObject> = when (this[key]) {
        null, JsonNull -> emptyList()
        else -> list(key)
    }
    fun JsonObject.text(key: String): String = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: invalid()
    fun JsonObject.optionalText(key: String): String? = when (this[key]) {
        null, JsonNull -> null
        else -> text(key)
    }
    fun JsonObject.number(key: String): Long = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: invalid()
    fun JsonObject.intNumber(key: String): Int = number(key).let { if (it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) it.toInt() else invalid() }
    fun JsonObject.positive(key: String): Long = number(key).takeIf { it > 0 } ?: invalid()
    fun JsonObject.decimal(key: String): Double = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() } ?: invalid()
    fun JsonObject.optionalInt(key: String): Int? = when (this[key]) { null, JsonNull -> null; else -> intNumber(key) }
    fun JsonObject.boolean(key: String): Boolean = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: invalid()
    fun JsonObject.permission(key: String): Boolean = this[key] == JsonPrimitive(true)

    fun thumbnail(value: JsonObject?): SynologyPhotoThumbnail? = value?.let {
        SynologyPhotoThumbnail(it.positive("unit_id"), it.text("cache_key"))
    }

    fun photo(value: JsonObject, profileId: String, space: SynologyPhotoSpace): SynologyPhoto {
        val size = value.number("filesize").also { if (it < 0) invalid() }
        val additional = value.optionalObject("additional")
        val resolution = additional?.optionalObject("resolution")
        val exif = additional?.optionalObject("exif")
        val gps = additional?.optionalObject("gps")
        val latitude = gps?.decimal("latitude")
        val longitude = gps?.decimal("longitude")
        val hasValidGPS = latitude != null && longitude != null && latitude in -90.0..90.0 && longitude in -180.0..180.0
        val address = additional?.optionalObject("address")
        val video = additional?.optionalObject("video_meta")
        return SynologyPhoto(
            id = SynologyPhotoId(profileId, space, value.positive("id")), filename = value.text("filename"),
            sizeBytes = size, takenAt = value.decimal("time"), indexedAt = value.decimal("indexed_time"),
            folderId = value.positive("folder_id"), mediaType = value.text("type"),
            thumbnail = thumbnail(additional?.optionalObject("thumbnail")),
            width = resolution?.intNumber("width"), height = resolution?.intNumber("height"),
            orientation = additional?.optionalInt("orientation"),
            description = additional?.optionalText("description"), camera = exif?.optionalText("camera"),
            lens = exif?.optionalText("lens"), aperture = exif?.optionalText("aperture"),
            exposureTime = exif?.optionalText("exposure_time"), focalLength = exif?.optionalText("focal_length"),
            iso = exif?.optionalText("iso"), duration = video?.takeIf { it["duration"] != null && it["duration"] != JsonNull }?.decimal("duration"),
            rating = additional?.optionalInt("rating"),
            address = listOf("country", "state", "county", "city", "town", "district", "village", "route", "landmark")
                .mapNotNull { address?.optionalText(it)?.takeIf(String::isNotEmpty) }.distinct(),
            latitude = latitude.takeIf { hasValidGPS }, longitude = longitude.takeIf { hasValidGPS },
        )
    }

    fun days(payload: JsonObject): List<SynologyPhotoDay> = payload.list("section").flatMap { section ->
        section.list().map { day ->
            val date = try { LocalDate.of(day.intNumber("year"), day.intNumber("month"), day.intNumber("day")) }
                catch (_: DateTimeException) { invalid() }
            SynologyPhotoDay(date, day.intNumber("item_count").also { if (it < 0) invalid() })
        }
    }

    fun collection(value: JsonObject, folder: Boolean = false): SynologyPhotoCollection = SynologyPhotoCollection(
        id = value.positive("id"),
        name = value.text("name").let { if (folder) it.trimEnd('/').substringAfterLast('/').ifEmpty { "/" } else it },
        parentId = if (folder) value.number("parent") else null,
        count = value.optionalInt("item_count")?.also { if (it < 0) invalid() },
    )

    fun collectionPage(payload: JsonObject, limit: Int, folder: Boolean = false, parentId: Long? = null): List<SynologyPhotoCollection> {
        val result = payload.list().map { collection(it, folder) }
        if (result.size > limit || result.map { it.id }.distinct().size != result.size ||
            (parentId != null && result.any { it.parentId != parentId })) invalid()
        return result
    }

    fun filterOptions(value: JsonObject): SynologyPhotoFilterOptions {
        fun choices(key: String, required: Boolean = false): List<SynologyPhotoChoice> {
            val result = (if (required) value.list(key) else value.optionalList(key)).map {
                SynologyPhotoChoice(it.positive("id"), it.text("name"))
            }
            if (result.map { it.id }.distinct().size != result.size) invalid()
            return result
        }
        val seenLocations = mutableSetOf<Long>()
        fun location(item: JsonObject, depth: Int): SynologyPhotoLocation {
            if (depth > 32) invalid()
            val id = item.positive("id")
            if (!seenLocations.add(id)) invalid()
            return SynologyPhotoLocation(id, item.text("name"), item.intNumber("level"),
                item.optionalList("children").map { location(it, depth + 1) })
        }
        fun fraction(item: JsonObject): SynologyPhotoFraction = SynologyPhotoFraction(item.intNumber("num"), item.intNumber("den")).also {
            if (it.num < 0 || it.den <= 0) invalid()
        }
        return SynologyPhotoFilterOptions(
            people = choices("person", required = true), locations = value.list("geocoding").map { location(it, 0) },
            tags = choices("general_tag"), cameras = choices("camera"), lenses = choices("lens"),
            iso = choices("iso"), apertures = choices("aperture"),
            focalRanges = value.optionalList("focal_length_group").map {
                SynologyPhotoFocalRange(it.intNumber("start"), it.intNumber("end"))
            }.distinct(),
            exposureRanges = value.optionalList("exposure_time_group").map {
                SynologyPhotoExposureRange(fraction(it.obj("start")), fraction(it.obj("end")))
            }.distinct(),
        )
    }

    fun filterParameters(filter: SynologyPhotoFilter): Map<String, JsonElement> = buildMap {
        if ((filter.startTime == null) != (filter.endTime == null)) invalid()
        filter.mediaType?.let { if (it !in 0..1) invalid(); put("item_type", array(it)) }
        val choices = listOf("person" to filter.personId, "geocoding" to filter.locationId,
            "general_tag" to filter.tagId, "camera" to filter.cameraId, "lens" to filter.lensId,
            "iso" to filter.isoId, "aperture" to filter.apertureId)
        choices.forEach { (key, id) -> id?.let { if (it <= 0) invalid(); put(key, array(it)) } }
        if (filter.personId != null) put("person_policy", JsonPrimitive("or"))
        if (filter.tagId != null) put("general_tag_policy", JsonPrimitive("or"))
        filter.rating?.let { if (it !in 0..5) invalid(); put("rating", array(it)) }
        if (filter.startTime != null && filter.endTime != null) put("time", time(filter.startTime, filter.endTime))
        filter.focalRange?.let {
            if (it.start < 0 || it.end < 0) invalid()
            put("focal_length_group", JsonArray(listOf(json("start" to it.start, "end" to it.end))))
        }
        filter.exposureRange?.let {
            if (it.start.num < 0 || it.end.num < 0 || it.start.den <= 0 || it.end.den <= 0) invalid()
            put("exposure_time_group", JsonArray(listOf(JsonObject(mapOf(
                "start" to json("num" to it.start.num, "den" to it.start.den),
                "end" to json("num" to it.end.num, "den" to it.end.den),
            )))))
        }
    }

    fun time(start: Long, end: Long): JsonArray {
        if (start < 0 || end < start) invalid()
        return JsonArray(listOf(json("start_time" to start, "end_time" to end)))
    }
    fun array(vararg values: Any): JsonArray = JsonArray(values.map(::primitive))
    fun json(vararg values: Pair<String, Any>): JsonObject = JsonObject(values.associate { it.first to primitive(it.second) })
    fun primitive(value: Any): JsonElement = when (value) {
        is JsonElement -> value
        is String -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        else -> invalid()
    }
    fun encode(values: Map<String, JsonElement>): Map<String, String> = values.mapValues { it.value.toString() }
}
