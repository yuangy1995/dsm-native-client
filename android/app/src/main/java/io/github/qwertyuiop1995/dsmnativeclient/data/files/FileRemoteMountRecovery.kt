package io.github.qwertyuiop1995.dsmnativeclient.data.files

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

@Serializable
internal enum class RemoteMountAction { CREATE, UPDATE, DISCONNECT }

/** 加密保存原账号与每一步的事实，不含密码；未知步骤不可继续或遗忘。 */
@Serializable
internal data class FileRemoteMountPending(
    val schemaVersion: Int = 1, val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner,
    val action: RemoteMountAction, val baseline: FileMountConnection?, val setup: FileRemoteMountSetup?, val stage: RemoteMountStage,
) {
    val paths get() = setOfNotNull(baseline?.mountPoint, setup?.mountPoint)
    val mountPoint get() = setup?.mountPoint ?: baseline!!.mountPoint
    override fun toString() = "FileRemoteMountPending($action, $stage)"
}

internal class FileRemoteMountRecoveryStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_remote_mount_recovery",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true }
    fun pending(owner: WorkspaceOwner): List<FileRemoteMountPending> = synchronized(lock) {
        val raw = preferences.getString(key(owner), null) ?: return@synchronized emptyList()
        val rows = runCatching { json.decodeFromString<List<FileRemoteMountPending>>(raw) }.getOrElse { throw workspaceStorageFailure() }
        if (rows.any { !valid(it, owner) } || rows.map { it.id }.distinct().size != rows.size ||
            rows.indices.any { i -> rows.take(i).any { previous -> rows[i].paths.any { path -> previous.paths.any { mountPathsOverlap(path, it) } } } })
            throw workspaceStorageFailure()
        rows
    }
    fun begin(record: FileRemoteMountPending) = synchronized(lock) {
        if (!valid(record, record.owner)) throw workspaceStorageFailure()
        val rows = pending(record.owner)
        if (rows.any { old -> old.paths.any { first -> record.paths.any { mountPathsOverlap(first, it) } } }) throw mountPending()
        save(record.owner, rows + record)
    }
    fun replace(before: FileRemoteMountPending, after: FileRemoteMountPending?) = synchronized(lock) {
        val rows = pending(before.owner)
        if (rows.singleOrNull { it.id == before.id } != before || after != null &&
            (!valid(after, before.owner) || after.copy(stage = before.stage) != before)) throw workspaceStorageFailure()
        save(before.owner, rows.filterNot { it.id == before.id } + listOfNotNull(after))
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val keys = preferences.all.keys.filter { it.startsWith("remote_v1_") && runCatching {
            String(java.util.Base64.getUrlDecoder().decode(it.removePrefix("remote_v1_")), Charsets.UTF_8).substringBefore('\u0000') == profileId
        }.getOrDefault(false) }
        if (keys.isNotEmpty()) {
            val editor = preferences.edit(); keys.forEach(editor::remove)
            if (!editor.commit()) throw workspaceStorageFailure()
        }
    }
    private fun valid(row: FileRemoteMountPending, owner: WorkspaceOwner): Boolean = runCatching {
        row.schemaVersion == 1 && row.owner.hasSameIdentity(owner) && row.id.isNotBlank() && row.paths.isNotEmpty() &&
            row.paths.all(::isMountTargetPath) && (row.baseline == null || row.baseline.kind != FileMountKind.ISO &&
            canonicalRemoteMountSource(row.baseline.kind, row.baseline.source) == row.baseline.source) &&
            (row.setup == null || row.setup.normalized() == row.setup) && when (row.action) {
                RemoteMountAction.CREATE -> row.baseline == null && row.setup != null && row.stage == RemoteMountStage.CHECK_CONNECTION
                RemoteMountAction.DISCONNECT -> row.baseline != null && row.setup == null && row.stage == RemoteMountStage.CHECK_DISCONNECTION
                RemoteMountAction.UPDATE -> row.baseline != null && row.setup != null &&
                    (row.baseline.mountPoint == row.setup.mountPoint || !mountPathsOverlap(row.baseline.mountPoint, row.setup.mountPoint)) &&
                    (row.stage != RemoteMountStage.READY_TO_CONNECT || row.baseline.mountPoint == row.setup.mountPoint) &&
                    (row.stage != RemoteMountStage.READY_TO_DISCONNECT || row.baseline.mountPoint != row.setup.mountPoint)
            }
    }.getOrDefault(false)
    private fun save(owner: WorkspaceOwner, rows: List<FileRemoteMountPending>) {
        val editor = preferences.edit()
        if (rows.isEmpty()) editor.remove(key(owner)) else editor.putString(key(owner), json.encodeToString(rows))
        if (!editor.commit()) throw workspaceStorageFailure()
    }
    private fun key(owner: WorkspaceOwner) = "remote_v1_" + java.util.Base64.getUrlEncoder().withoutPadding()
        .encodeToString((owner.profileId + "\u0000" + owner.identityRevision).toByteArray(Charsets.UTF_8))
    private companion object { val lock = Any() }
}
