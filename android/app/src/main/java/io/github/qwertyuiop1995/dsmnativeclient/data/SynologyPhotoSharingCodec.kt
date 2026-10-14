package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.net.URI
import java.security.MessageDigest
import kotlinx.serialization.json.*

/** Photos 内部分享契约；读取不会生成链接，未知成员列表保留为不可编辑状态。 */
internal object SynologyPhotoSharingCodec {
    fun decode(raw: JsonObject, album: SynologyPhotoAlbumSnapshot): SynologyPhotoAlbumSharing {
        val info = raw.optionalObject("additional")?.optionalObject("sharing_info")
        val shared = raw.optionalBoolean("shared") ?: invalid()
        val policy = when (info?.optionalText("privacy_type")) {
            "private" -> SynologyPhotoLinkAccess.INVITED
            "public-view" -> SynologyPhotoLinkAccess.VIEW
            "public-download" -> SynologyPhotoLinkAccess.DOWNLOAD
            else -> null
        }
        val access = if (!shared) SynologyPhotoLinkAccess.DISABLED else policy ?: invalid()
        val members = runCatching {
            val values = info?.get("permission") as? JsonArray ?: invalid()
            val named = values.map { it.obj() }.filter { it.optionalText("type") != "public" }
            val recipients = named.map(::recipient)
            if (recipients.map { it.id }.distinct().size != recipients.size) invalid()
            recipients to named.mapIndexed { index, value -> SynologyPhotoShareGrant(recipients[index].id, value.text("role")) }
        }.getOrNull()
        val expirationRaw = info?.get("expiration")
        val expiration = (expirationRaw as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBigDecimalOrNull()
            ?.let { runCatching { it.longValueExact() }.getOrNull() }?.takeIf { it >= 0 }
        val revision = digest(buildJsonObject {
            put("id", album.id); put("shared", shared); put("temporary", album.temporary?.let(::JsonPrimitive) ?: JsonNull)
            put("sharing", info ?: JsonNull)
        })
        // 区分缺失与未知原值，未编辑时不归一化或清除。
        val expirationDigest = digest(buildJsonObject { expirationRaw?.let { put("expiration", it) } })
        return SynologyPhotoAlbumSharing(album, SynologyPhotoSharingSnapshot(revision, access, members?.second,
            info?.optionalBoolean("enable_password"), expiration, expirationDigest), members?.first.orEmpty(),
            info?.optionalText("sharing_link")?.takeIf { shared && safeUrl(it) }, policy)
    }

    fun validId(value: JsonPrimitive): Boolean = value != JsonNull &&
        if (value.isString) value.content.isNotEmpty() else value.longOrNull?.let { it > 0 } == true
    fun recipient(value: JsonObject): SynologyPhotoShareRecipient {
        val type = value.text("type"); val id = value["id"] as? JsonPrimitive ?: invalid()
        if (type !in setOf("user", "group") || !validId(id)) invalid()
        return SynologyPhotoShareRecipient(SynologyPhotoShareMemberId(type, id), value.text("name"))
    }
    fun safeUrl(value: String): Boolean = runCatching { URI(value).let {
        it.scheme?.lowercase() in setOf("https", "http") && !it.host.isNullOrEmpty() && it.rawUserInfo == null
    } }.getOrDefault(false)

    fun roles(members: List<SynologyPhotoShareGrant>) = members.associate { it.id to it.role }
    fun validate(change: SynologyPhotoSharingChange, conditional: Boolean) {
        val original = change.original
        if (!original.revision.matches(Regex("[0-9a-f]{64}")) || !original.expirationDigest.matches(Regex("[0-9a-f]{64}")) ||
            original.expiration?.let { it < 0 } == true || change.expiration?.let { it < 0 } == true) invalid()
        fun valid(members: List<SynologyPhotoShareGrant>) {
            if (members.map { it.id }.distinct().size != members.size || members.any {
                    it.id.type !in setOf("user", "group") || !validId(it.id.value) || it.role.isEmpty() }) invalid()
        }
        original.members?.let(::valid)
        change.members?.let { desired ->
            valid(desired)
            val before = roles(original.members ?: invalid())
            val allowed = if (conditional) setOf("view", "download") else setOf("view", "download", "upload")
            if (desired.any { before[it.id] != it.role && it.role !in allowed }) invalid()
        }
    }
    fun memberChanges(change: SynologyPhotoSharingChange): List<JsonObject> {
        val desired = change.members ?: return emptyList()
        val original = change.original.members ?: invalid()
        val before = roles(original); val after = roles(desired)
        fun entry(grant: SynologyPhotoShareGrant, remove: Boolean) = buildJsonObject {
            put("action", if (remove) "delete" else "update")
            put("member", buildJsonObject { put("type", grant.id.type); put("id", grant.id.value) })
            if (!remove) put("role", grant.role)
        }
        return original.filter { it.id !in after }.map { entry(it, true) } + desired.filter { before[it.id] != it.role }.map { entry(it, false) }
    }
    fun changes(change: SynologyPhotoSharingChange): List<JsonObject> = memberChanges(change) +
        if (change.access != SynologyPhotoLinkAccess.DISABLED && change.access != change.original.access) listOf(buildJsonObject {
            put("action", if (change.access == SynologyPhotoLinkAccess.INVITED) "delete" else "update")
            put("member", buildJsonObject { put("type", "public") })
            if (change.access != SynologyPhotoLinkAccess.INVITED) put("role", if (change.access == SynologyPhotoLinkAccess.VIEW) "view" else "download")
        }) else emptyList()
    fun expirationChanged(change: SynologyPhotoSharingChange) = change.expiration != null && change.expiration != change.original.expiration
    fun modifiesProtectionOrMembers(change: SynologyPhotoSharingChange) = memberChanges(change).isNotEmpty() ||
        expirationChanged(change) || change.password != SynologyPhotoSharingPassword.UNCHANGED
    fun digest(value: JsonElement): String = MessageDigest.getInstance("SHA-256")
        .digest(stable(value).toString().toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    private fun stable(value: JsonElement): JsonElement = when (value) {
        is JsonObject -> JsonObject(value.toSortedMap().mapValues { stable(it.value) })
        is JsonArray -> JsonArray(value.map(::stable))
        is JsonPrimitive -> if (value == JsonNull || value.isString || value.booleanOrNull != null) value
            else JsonPrimitive((value.content.toBigDecimalOrNull() ?: invalid()).stripTrailingZeros())
    }
}
