package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal enum class SynologyPhotoDeletionProblem { STORAGE, BUSY, PENDING, LIMIT }
internal class SynologyPhotoDeletionFailure(val problem: SynologyPhotoDeletionProblem) : RuntimeException(problem.name)

@Serializable
internal data class SynologyPhotoDeletionRecord(
    val version: Int = 1,
    val id: String = UUID.randomUUID().toString(),
    val owner: WorkspaceOwner,
    val userId: Long,
    val entries: List<SynologyPhotoDeletionCheckpoint>,
    val createdAtSeconds: Long = System.currentTimeMillis() / 1000,
) {
    val finished: Boolean get() = entries.all { it.finished }
    fun count(phase: SynologyPhotoDeletionPhase): Int = entries.count { it.phase == phase }
    override fun toString() = "PhotoDeletionRecord(entries=${entries.size}, finished=$finished)"
}

/** 独立版本1加密批次；每项提交边界同步保存，未决批次不能被新确认覆盖。 */
internal class SynologyPhotoDeletionStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_photos_deletions",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun records(owner: WorkspaceOwner, userId: Long): List<SynologyPhotoDeletionRecord> = synchronized(lock) {
        all().filter { it.owner.hasSameIdentity(owner) && it.userId == userId }.sortedByDescending { it.createdAtSeconds }
    }
    fun get(id: String, owner: WorkspaceOwner, userId: Long): SynologyPhotoDeletionRecord = synchronized(lock) {
        all().singleOrNull { it.id == id && it.owner.hasSameIdentity(owner) && it.userId == userId } ?: storageFailure()
    }
    fun begin(row: SynologyPhotoDeletionRecord) = synchronized(lock) {
        validate(row)
        val previous = all()
        if (row.entries.any { it.phase != SynologyPhotoDeletionPhase.PREPARED } || previous.any { it.id == row.id }) storageFailure()
        if (previous.any { it.owner.hasSameIdentity(row.owner) && it.userId == row.userId && !it.finished })
            throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.PENDING)
        write(row)
    }
    fun update(id: String, owner: WorkspaceOwner, userId: Long, next: SynologyPhotoDeletionCheckpoint): SynologyPhotoDeletionRecord = synchronized(lock) {
        val row = get(id, owner, userId)
        val index = row.entries.indexOfFirst { it.operationId == next.operationId }.takeIf { it >= 0 } ?: storageFailure()
        val previous = row.entries[index]
        if (!previous.sameOperation(next) || previous.phase != next.phase && when (previous.phase) {
            SynologyPhotoDeletionPhase.PREPARED -> next.phase !in setOf(SynologyPhotoDeletionPhase.SUBMITTED, SynologyPhotoDeletionPhase.CANCELLED)
            SynologyPhotoDeletionPhase.SUBMITTED -> next.phase !in setOf(SynologyPhotoDeletionPhase.CONFIRMED, SynologyPhotoDeletionPhase.REJECTED)
            else -> true
        }) storageFailure()
        row.copy(entries = row.entries.toMutableList().apply { set(index, next) }).also(::write)
    }
    fun cancelRemaining(id: String, owner: WorkspaceOwner, userId: Long): SynologyPhotoDeletionRecord = synchronized(lock) {
        if (id in activeIds) throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.BUSY)
        val row = get(id, owner, userId)
        row.copy(entries = row.entries.map { if (it.phase == SynologyPhotoDeletionPhase.PREPARED)
            it.copy(phase = SynologyPhotoDeletionPhase.CANCELLED) else it }).also(::write)
    }
    fun discard(row: SynologyPhotoDeletionRecord) = synchronized(lock) {
        if (row.id in activeIds || !row.finished) throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.PENDING)
        if (get(row.id, row.owner, row.userId) != row) storageFailure()
        if (!preferences.edit().remove(key(row.id)).commit()) storageFailure()
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val rows = all().filter { it.owner.profileId == profileId }
        if (rows.any { it.id in activeIds }) throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.BUSY)
        val editor = preferences.edit(); rows.forEach { editor.remove(key(it.id)) }
        if (rows.isNotEmpty() && !editor.commit()) storageFailure()
    }
    suspend fun <T> exclusive(owner: WorkspaceOwner, id: String, block: suspend () -> T): T {
        val identity = owner.profileId to owner.identityRevision
        synchronized(lock) {
            if (!activeOwners.add(identity)) throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.BUSY)
            activeIds.add(id)
        }
        try { return block() } finally { synchronized(lock) { activeOwners.remove(identity); activeIds.remove(id) } }
    }
    private fun all(): List<SynologyPhotoDeletionRecord> = preferences.all.keys.filter { it.startsWith("photos_deletion_") }.map { key ->
        val row = runCatching { json.decodeFromString<SynologyPhotoDeletionRecord>(preferences.getString(key, null) ?: storageFailure()) }
            .getOrElse { storageFailure() }
        if (key != key(row.id)) storageFailure()
        validate(row); row
    }
    private fun validate(row: SynologyPhotoDeletionRecord) {
        if (row.version != 1 || runCatching { UUID.fromString(row.id).toString() == row.id }.getOrDefault(false).not() ||
            row.userId <= 0 || row.createdAtSeconds < 0 || row.entries.size !in 1..100 ||
            row.entries.map { it.operationId }.distinct().size != row.entries.size || row.entries.map { it.target.id }.distinct().size != row.entries.size ||
            row.entries.any { it.userId != row.userId || it.target.id.profileId != row.owner.profileId }) storageFailure()
        try { row.entries.forEach { it.validate() } } catch (_: SynologyPhotoFailure) { storageFailure() }
    }
    private fun write(row: SynologyPhotoDeletionRecord) {
        validate(row)
        if (!preferences.edit().putString(key(row.id), json.encodeToString(row)).commit()) storageFailure()
    }
    private fun key(id: String) = "photos_deletion_v1_$id"
    private fun storageFailure(): Nothing = throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.STORAGE)
    companion object {
        private val lock = Any()
        private val activeOwners = mutableSetOf<Pair<String, String>>()
        private val activeIds = mutableSetOf<String>()
        fun isProfileBusy(profileId: String): Boolean = synchronized(lock) { activeOwners.any { it.first == profileId } }
    }
}
