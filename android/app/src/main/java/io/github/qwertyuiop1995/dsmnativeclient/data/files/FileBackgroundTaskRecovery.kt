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

@Serializable internal enum class FileBackgroundTaskAction { STOP, CLEAR }
@Serializable internal data class FileBackgroundTaskIdentity(
    val taskId: String, val kind: FileBackgroundTaskKind, val createdAtSeconds: Double, val apiVersion: Int?,
) {
    fun matches(task: FileBackgroundTaskSummary) = task.identity() == this
    override fun toString() = "FileBackgroundTaskIdentity($kind)"
}
internal fun FileBackgroundTaskSummary.identity(): FileBackgroundTaskIdentity? =
    if (method == "start" && normalizedBackgroundTaskId(id) == id && controlCreatedAtSeconds != null &&
        controlCreatedAtSeconds.isFinite() && controlCreatedAtSeconds >= 946_684_800)
        FileBackgroundTaskIdentity(id, kind, controlCreatedAtSeconds, apiVersion) else null

/** 独立于旧只读任务快照；只保存原任务身份、动作和提交事实，不含文件路径或内容。 */
@Serializable internal data class FileBackgroundTaskPending(
    val schemaVersion: Int = 1, val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner,
    val target: FileBackgroundTaskIdentity, val action: FileBackgroundTaskAction, val acknowledged: Boolean = false,
) { override fun toString() = "FileBackgroundTaskPending($action, $acknowledged)" }
internal enum class FileBackgroundTaskOutcomeStatus { COMPLETED, UNKNOWN, REJECTED }
internal data class FileBackgroundTaskOutcome(val status: FileBackgroundTaskOutcomeStatus,
    val task: FileBackgroundTaskSummary? = null, val failure: DsmFailure? = null)

internal class FileBackgroundTaskRecoveryStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_file_background_task_recovery",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true }
    fun pending(owner: WorkspaceOwner): List<FileBackgroundTaskPending> = synchronized(lock) {
        val raw = preferences.getString(key(owner), null) ?: return@synchronized emptyList()
        val rows = runCatching { json.decodeFromString<List<FileBackgroundTaskPending>>(raw) }.getOrElse { throw workspaceStorageFailure() }
        if (rows.any { !valid(it, owner) } || rows.map { it.id }.distinct().size != rows.size ||
            rows.map { it.target.taskId }.distinct().size != rows.size) throw workspaceStorageFailure()
        rows
    }
    fun begin(record: FileBackgroundTaskPending) = synchronized(lock) {
        if (!valid(record, record.owner) || record.acknowledged) throw workspaceStorageFailure()
        val rows = pending(record.owner)
        if (rows.any { it.target.taskId == record.target.taskId }) throw backgroundTaskPending()
        save(record.owner, rows + record)
    }
    fun replace(before: FileBackgroundTaskPending, after: FileBackgroundTaskPending?) = synchronized(lock) {
        val rows = pending(before.owner)
        if (rows.singleOrNull { it.id == before.id } != before || after != null &&
            (!valid(after, before.owner) || after.copy(acknowledged = before.acknowledged) != before || before.acknowledged && !after.acknowledged))
            throw workspaceStorageFailure()
        save(before.owner, rows.mapNotNull { if (it.id == before.id) after else it })
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val keys = preferences.all.keys.filter { it.startsWith("background_v1_") && runCatching {
            String(java.util.Base64.getUrlDecoder().decode(it.removePrefix("background_v1_")), Charsets.UTF_8).substringBefore('\u0000') == profileId
        }.getOrDefault(false) }
        if (keys.isNotEmpty()) {
            val editor = preferences.edit(); keys.forEach(editor::remove)
            if (!editor.commit()) throw workspaceStorageFailure()
        }
    }
    private fun valid(row: FileBackgroundTaskPending, owner: WorkspaceOwner) = row.schemaVersion == 1 && row.owner.hasSameIdentity(owner) &&
        row.id.isNotBlank() && normalizedBackgroundTaskId(row.target.taskId) == row.target.taskId &&
        row.target.createdAtSeconds.isFinite() && row.target.createdAtSeconds >= 946_684_800 &&
        (row.target.apiVersion == null || row.target.apiVersion > 0) &&
        (row.action != FileBackgroundTaskAction.STOP || row.target.apiVersion == row.target.kind.taskAPI.second)
    private fun save(owner: WorkspaceOwner, rows: List<FileBackgroundTaskPending>) {
        val editor = preferences.edit()
        if (rows.isEmpty()) editor.remove(key(owner)) else editor.putString(key(owner), json.encodeToString(rows))
        if (!editor.commit()) throw workspaceStorageFailure()
    }
    private fun key(owner: WorkspaceOwner) = "background_v1_" + java.util.Base64.getUrlEncoder().withoutPadding()
        .encodeToString((owner.profileId + "\u0000" + owner.identityRevision).toByteArray(Charsets.UTF_8))
    private companion object { val lock = Any() }
}
