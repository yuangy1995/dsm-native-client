package io.github.qwertyuiop1995.dsmnativeclient.data.files

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileMountConnection
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileMountKind
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/** 只保存原目标及预期状态，重启后没有写操作重放入口。 */
@Serializable
internal data class FileISOMountPending(
    val schemaVersion: Int = 1, val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner,
    val connecting: Boolean, val connection: FileMountConnection,
)

internal class FileISOMountRecoveryStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_iso_recovery",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true }
    fun pending(owner: WorkspaceOwner): List<FileISOMountPending> = synchronized(lock) {
        val raw = preferences.getString(key(owner), null) ?: return@synchronized emptyList()
        val rows = runCatching { json.decodeFromString<List<FileISOMountPending>>(raw) }.getOrElse { throw workspaceStorageFailure() }
        if (rows.any { it.schemaVersion != 1 || !it.owner.hasSameIdentity(owner) || it.id.isBlank() ||
                it.connection.kind != FileMountKind.ISO || !isMountTargetPath(it.connection.mountPoint) ||
                !isFileMutationPath(it.connection.source) || it.connecting && it.connection.automatic == null } ||
            rows.map { it.id }.distinct().size != rows.size || rows.map { it.connection.mountPoint }.distinct().size != rows.size) throw workspaceStorageFailure()
        rows
    }
    fun begin(record: FileISOMountPending) = synchronized(lock) {
        val rows = pending(record.owner)
        if (rows.any { mountPathsOverlap(it.connection.mountPoint, record.connection.mountPoint) }) throw mountPending()
        save(record.owner, rows + record)
    }
    fun finish(record: FileISOMountPending) = synchronized(lock) {
        val rows = pending(record.owner)
        if (rows.singleOrNull { it.id == record.id } != record) throw workspaceStorageFailure()
        save(record.owner, rows.filterNot { it.id == record.id })
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val keys = preferences.all.keys.filter { it.startsWith("iso_v1_") && runCatching {
            String(java.util.Base64.getUrlDecoder().decode(it.removePrefix("iso_v1_")), Charsets.UTF_8).substringBefore('\u0000') == profileId
        }.getOrDefault(false) }
        if (keys.isNotEmpty()) {
            val editor = preferences.edit(); keys.forEach(editor::remove)
            if (!editor.commit()) throw workspaceStorageFailure()
        }
    }
    private fun save(owner: WorkspaceOwner, rows: List<FileISOMountPending>) {
        val editor = preferences.edit()
        if (rows.isEmpty()) editor.remove(key(owner)) else editor.putString(key(owner), json.encodeToString(rows))
        if (!editor.commit()) throw workspaceStorageFailure()
    }
    private fun key(owner: WorkspaceOwner) = "iso_v1_" + java.util.Base64.getUrlEncoder().withoutPadding()
        .encodeToString((owner.profileId + "\u0000" + owner.identityRevision).toByteArray(Charsets.UTF_8))
    private companion object { val lock = Any() }
}
