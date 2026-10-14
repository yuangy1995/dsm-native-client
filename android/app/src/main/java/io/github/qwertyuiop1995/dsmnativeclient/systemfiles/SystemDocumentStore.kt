package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.files.isFileMutationPath
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import java.util.UUID

@Serializable internal data class SystemFileLocation(
    val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner,
    val enabled: Boolean = true, val editing: Boolean = false, val version: Int = 1,
)
@Serializable internal data class SystemDocumentRef(
    val id: String = UUID.randomUUID().toString(), val locationId: String, val path: String,
    val directory: Boolean, val version: Int = 1,
) { override fun toString() = "SystemDocumentRef(directory=$directory)" }

/** 系统 URI 只含随机编号；路径和原账号映射独立加密保存，停用不删除用户副本。 */
internal class SystemDocumentStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_system_documents",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    fun locations(): List<SystemFileLocation> = synchronized(lock) {
        preferences.all.keys.filter { it.startsWith("location:") }.map { location(it.removePrefix("location:")) }
    }
    fun location(id: String): SystemFileLocation = synchronized(lock) {
        if (!uuid(id)) throw workspaceStorageFailure()
        decode<SystemFileLocation>("location:$id").also {
            if (it.version != 1 || it.id != id || it.owner.profileId.isBlank() || it.owner.identityRevision.isBlank() ||
                !it.enabled && it.editing) throw workspaceStorageFailure()
        }
    }
    fun enable(owner: WorkspaceOwner): SystemFileLocation = synchronized(lock) {
        val prior = locations().singleOrNull { it.owner.hasSameIdentity(owner) }
        (prior?.copy(enabled = true) ?: SystemFileLocation(owner = owner)).also(::write)
    }
    fun update(before: SystemFileLocation, enabled: Boolean, editing: Boolean = before.editing): SystemFileLocation = synchronized(lock) {
        if (location(before.id) != before) throw workspaceStorageFailure()
        before.copy(enabled = enabled, editing = enabled && editing).also(::write)
    }
    fun document(id: String): SystemDocumentRef = synchronized(lock) {
        if (!uuid(id)) throw workspaceStorageFailure()
        if (preferences.contains("location:$id")) {
            location(id); return@synchronized SystemDocumentRef(id, id, "", true)
        }
        decode<SystemDocumentRef>("document:$id").also {
            if (it.version != 1 || it.id != id || !uuid(it.locationId) || !validPath(it.path)) throw workspaceStorageFailure()
            location(it.locationId)
        }
    }
    fun document(location: SystemFileLocation, path: String, directory: Boolean): SystemDocumentRef = synchronized(lock) {
        if (!location.enabled || location(location.id) != location || !validPath(path)) throw workspaceStorageFailure()
        val index = "path:${location.id}:" + MessageDigest.getInstance("SHA-256").digest(path.toByteArray()).joinToString("") { "%02x".format(it) }
        preferences.getString(index, null)?.let { id -> return@synchronized document(id).also {
            if (it.locationId != location.id || it.path != path || it.directory != directory) throw workspaceStorageFailure()
        } }
        SystemDocumentRef(locationId = location.id, path = path, directory = directory).also { row ->
            if (!preferences.edit().putString("document:${row.id}", json.encodeToString(row)).putString(index, row.id).commit())
                throw workspaceStorageFailure()
        }
    }
    fun descendant(parent: SystemDocumentRef, child: SystemDocumentRef): Boolean = parent.directory && parent.id != child.id &&
        parent.locationId == child.locationId && child.path.isNotEmpty() &&
        (parent.path.isEmpty() || child.path.startsWith(parent.path + "/"))
    fun removeProfile(profileId: String) = synchronized(lock) {
        val ids = locations().filter { it.owner.profileId == profileId }.map { it.id }.toSet()
        val keys = preferences.all.keys.filter { key -> when {
            key.startsWith("location:") -> key.removePrefix("location:") in ids
            key.startsWith("path:") -> ids.any { key.startsWith("path:$it:") }
            key.startsWith("document:") -> document(key.removePrefix("document:")).locationId in ids
            else -> false
        } }
        if (keys.isNotEmpty() && !preferences.edit().also { editor -> keys.forEach(editor::remove) }.commit()) throw workspaceStorageFailure()
    }
    private fun write(row: SystemFileLocation) {
        if (!preferences.edit().putString("location:${row.id}", json.encodeToString(row)).commit()) throw workspaceStorageFailure()
    }
    private inline fun <reified T> decode(key: String): T = try {
        json.decodeFromString(preferences.getString(key, null) ?: throw workspaceStorageFailure())
    } catch (_: Exception) { throw workspaceStorageFailure() }
    private fun validPath(path: String) = isFileMutationPath(path) && path.split('/').none { it == "#recycle" }
    private fun uuid(id: String) = runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)
    private companion object { val lock = Any() }
}
