package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import java.security.MessageDigest
import kotlinx.serialization.json.*

/** 按已记录的冻结契约生成可重建规则；不可迁移条件只提示，不送进新相册。 */
internal object SynologyPhotoFrozenAlbumCodec {
    private val supported = SynologyPhotoConditionField.entries.map { it.key }.toSet() + setOf(
        "user_id", "folder_filter", "item_type", "time", "rating", "keyword_policy", "person_policy", "general_tag_policy", "concept_policy")

    fun decode(raw: JsonObject, album: SynologyPhotoAlbumSnapshot, user: Long): SynologyPhotoFrozenAlbum {
        if (album.ownerUserId != user) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        if (!album.recoverable) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
        val count = raw.number("item_count").takeIf { it >= 0 } ?: invalid()
        val condition = raw.obj("additional").obj("condition_object")
        val unsupported = raw.obj("cant_migrate_condition")
        val shared = raw.optionalBoolean("shared") ?: invalid()
        val sharing = raw.obj("additional").optionalObject("sharing_info")
        if (shared && sharing?.optionalText("privacy_type") !in setOf("private", "public-view", "public-download")) invalid()
        val fields = JsonObject(condition.filterKeys { it in supported })
        val source = SynologyPhotoConditionCodec.number(fields["user_id"])
        val rebuild = if (source !in setOf(0L, user) || condition.size == 1 && source == 0L) null else runCatching {
            SynologyPhotoConditionCodec.decode(fields).also { SynologyPhotoConditionCodec.canonical(it, user) }
        }.getOrNull()
        val state = buildJsonObject {
            put("condition", condition); put("unsupported", unsupported); put("shared", shared)
            put("sharing", sharing ?: JsonNull)
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(stable(state).toString().toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return SynologyPhotoFrozenAlbum(album, SynologyPhotoFrozenAlbumSnapshot(count, digest, shared),
            unsupported.keys + condition.keys.filter { it !in supported }, rebuild)
    }

    private fun stable(value: JsonElement): JsonElement = when (value) {
        is JsonObject -> JsonObject(value.toSortedMap().mapValues { stable(it.value) })
        is JsonArray -> JsonArray(value.map(::stable))
        is JsonPrimitive -> if (value == JsonNull || value.isString || value.booleanOrNull != null) value
            else JsonPrimitive((value.content.toBigDecimalOrNull() ?: invalid()).stripTrailingZeros())
        else -> value
    }
}
