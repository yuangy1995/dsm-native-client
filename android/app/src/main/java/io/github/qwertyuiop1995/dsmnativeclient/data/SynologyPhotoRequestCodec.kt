package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalLong
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.net.URI
import java.security.MessageDigest
import kotlinx.serialization.json.*

internal object SynologyPhotoRequestCodec {
    fun decode(value: JsonObject, profileId: String): SynologyPhotoRequest {
        val passphrase = value.optionalText("album_passphrase")?.takeIf { it.isNotEmpty() }
        val settings = SynologyPhotoRequestSettings(value.text("subject"), value.text("description"),
            when (value.text("library")) {
                "personal_space" -> SynologyPhotoSpace.PERSONAL
                "shared_space" -> SynologyPhotoSpace.SHARED
                else -> invalid()
            }, value.text("folder_home_path"), value.optionalLong("folder_id")?.takeIf { it > 0 },
            value.optionalLong("album_id")?.takeIf { it > 0 && passphrase == null }, passphrase,
            value.number("expiration"), value.number("filesize_limit"))
        if (settings.expiration < 0 || settings.sizeLimit < 0) invalid()
        return SynologyPhotoRequest(value.text("passphrase").also { if (it.isEmpty()) invalid() }, profileId, settings,
            value.boolean("is_folder_valid"), value.optionalText("album_name"), safeUrl(value.optionalText("sharing_link")))
    }
    private fun safeUrl(value: String?): String? = value?.let { runCatching { URI(it) }.getOrNull() }
        ?.takeIf { it.scheme == "https" && it.host != null && it.userInfo == null }?.toString()

    fun validate(settings: SynologyPhotoRequestSettings) {
        if (settings.subject.isEmpty() || settings.subject != settings.subject.trim() || settings.subject.length > 50 ||
            settings.description.length > 100 || settings.expiration < 0 || settings.sizeLimit != 0L && settings.sizeLimit !in 1_048_576L..3_145_728_000L ||
            settings.folderId?.let { it <= 0 } == true || settings.albumId?.let { it <= 0 } == true ||
            settings.albumPassphrase?.isEmpty() == true || settings.albumPassphrase != null && settings.albumId != null ||
            settings.folderPath.isEmpty()) invalid()
    }
    fun parameters(settings: SynologyPhotoRequestSettings): Map<String, JsonElement> = json(
        "subject" to settings.subject, "description" to settings.description,
        "library" to if (settings.space == SynologyPhotoSpace.PERSONAL) "personal_space" else "shared_space",
        "folder_home_path" to settings.folderPath, "expiration" to settings.expiration, "filesize_limit" to settings.sizeLimit) + when {
        settings.albumPassphrase != null -> json("album_passphrase" to settings.albumPassphrase)
        settings.albumId != null -> json("album_id" to settings.albumId)
        else -> emptyMap()
    }
    fun updates(original: SynologyPhotoRequestSettings, settings: SynologyPhotoRequestSettings): Map<String, JsonElement> {
        val previous = parameters(original); val desired = parameters(settings)
        val fields = desired.filter { (key, value) -> previous[key] != value }.toMutableMap()
        if (original.space != settings.space || original.folderPath != settings.folderPath) {
            fields["library"] = desired.getValue("library"); fields["folder_home_path"] = desired.getValue("folder_home_path")
        }
        if (original.albumId != settings.albumId || original.albumPassphrase != settings.albumPassphrase) {
            if (settings.albumPassphrase != null) { fields["album_passphrase"] = JsonPrimitive(settings.albumPassphrase); fields.remove("album_id") }
            else { fields["album_id"] = JsonPrimitive(settings.albumId ?: -1); fields.remove("album_passphrase") }
        }
        return fields
    }
    fun hash(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    fun digest(settings: SynologyPhotoRequestSettings, includesFolderId: Boolean): String = hash(JsonObject((parameters(settings) +
        if (includesFolderId) mapOf("folder_id" to (settings.folderId?.let(::JsonPrimitive) ?: JsonNull)) else emptyMap()).toSortedMap()).toString())
    private fun originalDigest(value: SynologyPhotoRequest): String = hash(JsonObject(json("id" to value.id, "profile" to value.profileId,
        "settings" to digest(value.settings, true), "valid" to value.isFolderValid) + mapOf(
        "albumName" to (value.albumName?.let(::JsonPrimitive) ?: JsonNull), "url" to (value.url?.let(::JsonPrimitive) ?: JsonNull))).toString())
    fun checkpoint(action: SynologyPhotoAlbumAction, change: SynologyPhotoRequestChange): SynologyPhotoRequestCheckpoint {
        if (!action.isRequest || (action == SynologyPhotoAlbumAction.CREATE_REQUEST) != (change.original == null) ||
            (action == SynologyPhotoAlbumAction.DELETE_REQUEST) != (change.settings == null) || change.original?.id?.isEmpty() == true) invalid()
        val settings = change.settings ?: change.original!!.settings
        return SynologyPhotoRequestCheckpoint(settings.space, change.original?.id?.let(::hash),
            change.settings?.let { digest(it, it.folderId != null) }, settings.folderId != null, change.original?.let(::originalDigest))
    }
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val saved = row.request ?: invalid()
        fun valid(value: String?) = value?.matches(Regex("[0-9a-f]{64}")) == true
        if (!row.action.isRequest || saved.targetDigest?.let { !valid(it) } == true ||
            row.action != SynologyPhotoAlbumAction.CREATE_REQUEST && saved.targetDigest == null ||
            (row.action == SynologyPhotoAlbumAction.CREATE_REQUEST) != (saved.originalDigest == null) ||
            saved.originalDigest?.let { !valid(it) } == true ||
            if (row.action == SynologyPhotoAlbumAction.DELETE_REQUEST) saved.settingsDigest != null else !valid(saved.settingsDigest)) invalid()
        if (!row.submitted && row.action == SynologyPhotoAlbumAction.CREATE_REQUEST && saved.targetDigest != null ||
            row.finished && (row.phase != SynologyPhotoAlbumPhase.COMPLETED || saved.targetDigest == null)) invalid()
    }
}
