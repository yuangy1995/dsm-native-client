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

@Serializable internal enum class FileVFSStep { UNSENT, SUBMITTED, ACKNOWLEDGED, REJECTED }

/** 分别保存连接与配置的提交/回执事实；未知操作仅提供只读恢复。 */
@Serializable
internal data class FileVFSPending(
    val schemaVersion: Int = 1, val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner,
    val change: FileVFSChange, val originalIds: Set<String>, val connection: FileVFSStep, val profile: FileVFSStep = FileVFSStep.UNSENT,
) {
    override fun toString() = "FileVFSPending($connection, $profile)"
}
internal data class FileVFSOutcome(val status: FileVFSOutcomeStatus, val pending: FileVFSPending? = null, val failure: DsmFailure? = null)

internal class FileVFSRecoveryStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_vfs_recovery",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true }
    fun pending(owner: WorkspaceOwner): List<FileVFSPending> = synchronized(lock) {
        val raw = preferences.getString(key(owner), null) ?: return@synchronized emptyList()
        val rows = runCatching { json.decodeFromString<List<FileVFSPending>>(raw) }.getOrElse { throw workspaceStorageFailure() }
        if (rows.size > 1 || rows.any { !valid(it, owner) }) throw workspaceStorageFailure()
        rows
    }
    fun begin(record: FileVFSPending) = synchronized(lock) {
        if (!valid(record, record.owner)) throw workspaceStorageFailure()
        if (pending(record.owner).isNotEmpty()) throw vfsPending()
        save(record.owner, record)
    }
    fun replace(before: FileVFSPending, after: FileVFSPending?) = synchronized(lock) {
        if (pending(before.owner).singleOrNull() != before || after != null && (!valid(after, before.owner) ||
            after.copy(connection = before.connection, profile = before.profile) != before ||
            !transition(before.connection, after.connection) || !transition(before.profile, after.profile))) throw workspaceStorageFailure()
        save(before.owner, after)
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val keys = preferences.all.keys.filter { it.startsWith("vfs_v1_") && runCatching {
            String(java.util.Base64.getUrlDecoder().decode(it.removePrefix("vfs_v1_")), Charsets.UTF_8).substringBefore('\u0000') == profileId
        }.getOrDefault(false) }
        if (keys.isNotEmpty()) {
            val editor = preferences.edit(); keys.forEach(editor::remove)
            if (!editor.commit()) throw workspaceStorageFailure()
        }
    }
    private fun valid(row: FileVFSPending, owner: WorkspaceOwner): Boolean = runCatching {
        if (row.schemaVersion != 1 || !row.owner.hasSameIdentity(owner) || row.id.isBlank() || row.originalIds.any(String::isEmpty)) return@runCatching false
        val baseline = row.change.baselineProfile
        if (baseline != null && (!baseline.owner.hasSameIdentity(owner) || baseline.id !in row.originalIds || baseline.protocolId.isEmpty())) return@runCatching false
        when (val change = row.change) {
            is FileVFSChange.Create -> require(validSetup(change.setup))
            is FileVFSChange.Update -> require(validSetup(change.setup) && change.setup.protocolId == change.baseline.profile.protocolId)
            is FileVFSChange.CreateCloud -> require(change.identity.protocolId in cloudProtocols && change.identity.alias.isNotBlank() && change.identity.account.isNotEmpty())
            is FileVFSChange.Reauthorize -> require(change.baseline.protocolId in cloudProtocols && !change.baseline.account.isNullOrEmpty())
            else -> Unit
        }
        when {
            row.change is FileVFSChange.RemoveSaved -> row.connection == FileVFSStep.UNSENT && row.profile != FileVFSStep.UNSENT
            row.change.writesBoth -> row.connection != FileVFSStep.UNSENT &&
                (row.profile == FileVFSStep.UNSENT || row.connection == FileVFSStep.ACKNOWLEDGED)
            else -> row.connection != FileVFSStep.UNSENT && row.profile == FileVFSStep.UNSENT
        }
    }.getOrDefault(false)
    private fun validSetup(setup: FileVFSConfiguration) = runCatching {
        setup.resolved(listOf(FileVFSProtocol(setup.protocolId, setup.protocolId, setup.port, false))) == setup
    }.getOrDefault(false)
    private fun transition(before: FileVFSStep, after: FileVFSStep) = before == after ||
        before == FileVFSStep.UNSENT && after == FileVFSStep.SUBMITTED ||
        before == FileVFSStep.SUBMITTED && after in setOf(FileVFSStep.ACKNOWLEDGED, FileVFSStep.REJECTED)
    private fun save(owner: WorkspaceOwner, row: FileVFSPending?) {
        val editor = preferences.edit()
        if (row == null) editor.remove(key(owner)) else editor.putString(key(owner), json.encodeToString(listOf(row)))
        if (!editor.commit()) throw workspaceStorageFailure()
    }
    private fun key(owner: WorkspaceOwner) = "vfs_v1_" + java.util.Base64.getUrlEncoder().withoutPadding()
        .encodeToString((owner.profileId + "\u0000" + owner.identityRevision).toByteArray(Charsets.UTF_8))
    private companion object {
        val lock = Any()
        val cloudProtocols = setOf("google", "dropbox", "baidu", "onedrive", "box")
    }
}

internal fun vfsPending() = DsmFailure(null, "An earlier connection change has not finished", "Refresh its status before changing another connection.", kind = DsmErrorKind.FILE_VFS_PENDING)
