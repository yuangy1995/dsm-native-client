package io.github.qwertyuiop1995.dsmnativeclient.data.files

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

internal val officeDocumentChanges = MutableStateFlow(0L)

/** 私有副本独立于可清理缓存；索引同步加密保存，不把编辑器 URI 当作长期文件身份。 */
internal class OfficeDocumentStore(private val preferences: SharedPreferences, private val root: File) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_office_documents",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM), File(context.noBackupFilesDir, "office-documents"))
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    fun records(owner: WorkspaceOwner): List<OfficeDocumentRecord> = synchronized(lock) {
        all().filter { it.owner.hasSameIdentity(owner) }.map { row ->
            if (row.phase == OfficeDocumentPhase.SAVING && row.id !in activeIds)
                row.copy(phase = OfficeDocumentPhase.UNKNOWN).also(::write) else row
        }.sortedByDescending { it.createdAtSeconds }
    }
    fun get(id: String): OfficeDocumentRecord = synchronized(lock) { all().singleOrNull { it.id == id } ?: throw officeLocalFailure() }
    fun begin(row: OfficeDocumentRecord) = synchronized(lock) {
        if (!valid(row) || row.phase != OfficeDocumentPhase.READY || row.candidateId != null) throw workspaceStorageFailure()
        if (all().any { it.id == row.id || sameTarget(it.owner, it.baseline.path, row.owner, row.baseline.path) }) throw officePending()
        write(row)
    }
    fun replace(before: OfficeDocumentRecord, after: OfficeDocumentRecord) = synchronized(lock) {
        if (!valid(after) || before.copy(candidateId = after.candidateId, candidateFingerprint = after.candidateFingerprint,
                phase = after.phase, externalId = after.externalId) != after || get(before.id) != before) throw workspaceStorageFailure()
        if (before.uncertain && (before.candidateId != after.candidateId || before.candidateFingerprint != after.candidateFingerprint) ||
            before.phase == OfficeDocumentPhase.UNKNOWN && after.phase !in setOf(OfficeDocumentPhase.UNKNOWN, OfficeDocumentPhase.SAVED) ||
            before.phase == OfficeDocumentPhase.SAVED && before != after) throw officePending()
        write(after)
    }
    fun discard(row: OfficeDocumentRecord, discardExternal: Boolean = false) = synchronized(lock) {
        if (row.uncertain || row.externalId != null && !discardExternal || row.id in activeIds || get(row.id) != row) throw officePending()
        if (!preferences.edit().remove(key(row.id)).commit()) throw workspaceStorageFailure()
        directory(row.id).deleteRecursively()
        officeDocumentChanges.update { it + 1 }
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val rows = all().filter { it.owner.profileId == profileId }
        if (rows.any { it.id in activeIds || it.externalId != null }) throw officePending()
        val editor = preferences.edit(); rows.forEach { editor.remove(key(it.id)) }
        if (rows.isNotEmpty() && !editor.commit()) throw workspaceStorageFailure()
        rows.forEach { directory(it.id).deleteRecursively() }
    }
    fun canRemoveProfile(profileId: String) = synchronized(lock) {
        all().none { it.owner.profileId == profileId && (it.id in activeIds || it.externalId != null) }
    }
    fun artifact(id: String, fileId: String): File {
        if (!uuid(id) || !uuid(fileId)) throw workspaceStorageFailure()
        return File(directory(id), fileId)
    }
    fun directory(id: String): File {
        if (!uuid(id)) throw workspaceStorageFailure()
        return File(root, id)
    }
    suspend fun <T> exclusive(owner: WorkspaceOwner, path: String, id: String, block: suspend () -> T): T {
        val token = Triple(owner.profileId, owner.identityRevision, path)
        synchronized(lock) { if (!activeTargets.add(token)) throw officePending(); activeIds.add(id) }
        try { return block() } finally { synchronized(lock) { activeTargets.remove(token); activeIds.remove(id) } }
    }
    /** 文件描述符开放期间与上传、导入和清理使用同一把目标锁。 */
    fun holdExternal(row: OfficeDocumentRecord, externalId: String) = synchronized(lock) {
        val token = Triple(row.owner.profileId, row.owner.identityRevision, row.baseline.path)
        if (get(row.id) != row || !row.canImport || !activeTargets.add(token)) throw officePending()
        activeIds.add(row.id); externalIds[row.id] = externalId
    }
    fun externalActive(row: OfficeDocumentRecord) = synchronized(lock) { row.externalId != null && externalIds[row.id] == row.externalId }
    fun releaseExternal(row: OfficeDocumentRecord) = synchronized(lock) {
        if (externalActive(row) && externalIds.remove(row.id) != null) {
            activeIds.remove(row.id)
            activeTargets.remove(Triple(row.owner.profileId, row.owner.identityRevision, row.baseline.path))
        }
    }
    private fun all(): List<OfficeDocumentRecord> = preferences.all.keys.filter { it.startsWith("office_v1_") }.map { key ->
        val raw = preferences.getString(key, null) ?: throw workspaceStorageFailure()
        val row = runCatching { json.decodeFromString<OfficeDocumentRecord>(raw) }.getOrElse { throw workspaceStorageFailure() }
        if (key != key(row.id) || !valid(row)) throw workspaceStorageFailure()
        row
    }
    private fun write(row: OfficeDocumentRecord) {
        if (!preferences.edit().putString(key(row.id), json.encodeToString(row)).commit()) throw workspaceStorageFailure()
        officeDocumentChanges.update { it + 1 }
    }
    private fun valid(row: OfficeDocumentRecord) = row.schemaVersion == 1 && uuid(row.id) && uuid(row.originalId) &&
        OfficeDocumentPolicy.supports(row.baseline.asItem()) && row.originalFingerprint.valid &&
        row.originalFingerprint.bytes == row.baseline.size &&
        ((row.candidateId == null) == (row.candidateFingerprint == null)) &&
        (row.candidateId == null || uuid(row.candidateId) && row.candidateId != row.originalId) &&
        row.candidateFingerprint?.valid != false &&
        (row.externalId == null || uuid(row.externalId) && row.externalId !in setOf(row.originalId, row.candidateId) &&
            !row.uncertain && row.phase != OfficeDocumentPhase.SAVED) &&
        (row.phase !in setOf(OfficeDocumentPhase.CHANGED, OfficeDocumentPhase.UNCHANGED, OfficeDocumentPhase.SAVING,
            OfficeDocumentPhase.SAVED, OfficeDocumentPhase.UNKNOWN) || row.candidateId != null)
    private fun key(id: String) = "office_v1_$id"
    private fun uuid(value: String) = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
    private fun sameTarget(a: WorkspaceOwner, ap: String, b: WorkspaceOwner, bp: String) = a.hasSameIdentity(b) && ap == bp
    private companion object {
        val lock = Any()
        val activeIds = mutableSetOf<String>()
        val externalIds = mutableMapOf<String, String>()
        val activeTargets = mutableSetOf<Triple<String, String, String>>()
    }
}
