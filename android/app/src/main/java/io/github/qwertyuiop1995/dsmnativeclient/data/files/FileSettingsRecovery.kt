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

@Serializable internal enum class FileSettingsTargetKind { GENERAL, MOUNT_SCOPE, MOUNT_ACCOUNT, BANDWIDTH, THEME, THEME_UPLOAD_LOGO, THEME_UPLOAD_BACKGROUND }

/** 只记录原账号、目标摘要、期望状态摘要和回执，不保存账号名单、域、设置正文或图片。 */
@Serializable
internal data class FileSettingsPending(
    val schemaVersion: Int = 1, val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner,
    val kind: FileSettingsTargetKind, val target: String, val desired: String, val acknowledged: Boolean = false,
    val logoBefore: String? = null, val backgroundBefore: String? = null,
) { override fun toString() = "FileSettingsPending($kind, $acknowledged)" }
internal enum class FileSettingsOutcomeStatus { COMPLETED, UNKNOWN, REJECTED }
internal data class FileSettingsOutcome(val status: FileSettingsOutcomeStatus, val pending: FileSettingsPending? = null, val failure: DsmFailure? = null)

internal class FileSettingsRecoveryStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_file_settings_recovery",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true }
    fun pending(owner: WorkspaceOwner): List<FileSettingsPending> = synchronized(lock) {
        val raw = preferences.getString(key(owner), null) ?: return@synchronized emptyList()
        val rows = runCatching { json.decodeFromString<List<FileSettingsPending>>(raw) }.getOrElse { throw workspaceStorageFailure() }
        if (rows.any { !valid(it, owner) } || rows.map { it.id }.distinct().size != rows.size ||
            rows.map { it.kind to it.target }.distinct().size != rows.size) throw workspaceStorageFailure()
        rows
    }
    fun begin(record: FileSettingsPending) = synchronized(lock) {
        if (!valid(record, record.owner)) throw workspaceStorageFailure()
        val rows = pending(record.owner)
        if (rows.any { it.kind == record.kind && it.target == record.target }) throw settingsPending()
        save(record.owner, rows + record)
    }
    fun replace(before: FileSettingsPending, after: FileSettingsPending?) = synchronized(lock) {
        val rows = pending(before.owner)
        if (rows.singleOrNull { it.id == before.id } != before || after != null &&
            (!valid(after, before.owner) || after.copy(acknowledged = before.acknowledged) != before || before.acknowledged && !after.acknowledged))
            throw workspaceStorageFailure()
        save(before.owner, rows.mapNotNull { if (it.id == before.id) after else it })
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val keys = preferences.all.keys.filter { it.startsWith("settings_v1_") && runCatching {
            String(java.util.Base64.getUrlDecoder().decode(it.removePrefix("settings_v1_")), Charsets.UTF_8).substringBefore('\u0000') == profileId
        }.getOrDefault(false) }
        if (keys.isNotEmpty()) {
            val editor = preferences.edit(); keys.forEach(editor::remove)
            if (!editor.commit()) throw workspaceStorageFailure()
        }
    }
    private fun valid(row: FileSettingsPending, owner: WorkspaceOwner) = row.schemaVersion == 1 && row.owner.hasSameIdentity(owner) &&
        row.id.isNotBlank() && digest.matches(row.target) && digest.matches(row.desired) &&
        (row.logoBefore == null || row.kind == FileSettingsTargetKind.THEME && digest.matches(row.logoBefore)) &&
        (row.backgroundBefore == null || row.kind == FileSettingsTargetKind.THEME && digest.matches(row.backgroundBefore))
    private fun save(owner: WorkspaceOwner, rows: List<FileSettingsPending>) {
        val editor = preferences.edit()
        if (rows.isEmpty()) editor.remove(key(owner)) else editor.putString(key(owner), json.encodeToString(rows))
        if (!editor.commit()) throw workspaceStorageFailure()
    }
    private fun key(owner: WorkspaceOwner) = "settings_v1_" + java.util.Base64.getUrlEncoder().withoutPadding()
        .encodeToString((owner.profileId + "\u0000" + owner.identityRevision).toByteArray(Charsets.UTF_8))
    private companion object { val lock = Any(); val digest = Regex("[0-9a-f]{64}") }
}
internal fun settingsPending() = DsmFailure(null, "An earlier save has not finished", "Refresh the settings before saving again.", kind = DsmErrorKind.FILE_SETTINGS_PENDING)
