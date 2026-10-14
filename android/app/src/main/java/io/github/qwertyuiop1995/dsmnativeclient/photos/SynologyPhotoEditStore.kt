package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.photoEditsConflict
import io.github.qwertyuiop1995.dsmnativeclient.data.validatePhotoEditCheckpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal enum class SynologyPhotoEditProblem { STORAGE, BUSY, PENDING, LIMIT }
internal class SynologyPhotoEditFailure(val problem: SynologyPhotoEditProblem) : RuntimeException(problem.name)

@Serializable
internal data class SynologyPhotoEditRecord(
    val version: Int = 1,
    val owner: WorkspaceOwner,
    val checkpoint: SynologyPhotoEditCheckpoint,
    val createdAtSeconds: Long = System.currentTimeMillis() / 1000,
) {
    val id: String get() = checkpoint.operationId
    override fun toString() = "PhotoEditRecord(phase=${checkpoint.phase})"
}

/** 独立版本 1 加密记录；不改登录、上传与备份格式，提交边界必须同步保存。 */
internal class SynologyPhotoEditStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_photos_edits",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun records(owner: WorkspaceOwner, userId: Long): List<SynologyPhotoEditRecord> = synchronized(lock) {
        all().filter { it.owner.hasSameIdentity(owner) && it.checkpoint.userId == userId }.map { row ->
            if (row.id !in activeIds && row.checkpoint.phase == SynologyPhotoEditPhase.SUBMITTING) {
                row.copy(checkpoint = row.checkpoint.copy(phase = SynologyPhotoEditPhase.PENDING)).also(::write)
            } else row
        }.sortedByDescending { it.createdAtSeconds }
    }

    fun get(id: String, owner: WorkspaceOwner, userId: Long): SynologyPhotoEditRecord = synchronized(lock) {
        all().singleOrNull { it.id == id && it.owner.hasSameIdentity(owner) && it.checkpoint.userId == userId } ?: storageFailure()
    }

    fun begin(row: SynologyPhotoEditRecord) = synchronized(lock) {
        validate(row)
        if (row.checkpoint.submitted || all().any { it.id == row.id }) storageFailure()
        requireNoConflict(row)
        write(row)
    }

    fun requireNoConflict(row: SynologyPhotoEditRecord) = synchronized(lock) {
        if (all().any { it.owner.hasSameIdentity(row.owner) && photoEditsConflict(it.checkpoint, row.checkpoint) })
            throw SynologyPhotoEditFailure(SynologyPhotoEditProblem.PENDING)
    }

    fun save(id: String, owner: WorkspaceOwner, userId: Long, next: SynologyPhotoEditCheckpoint): SynologyPhotoEditRecord = synchronized(lock) {
        val row = get(id, owner, userId)
        val before = row.checkpoint
        if (!before.sameOperation(next) || before.finished && before != next || before.submitted && !next.submitted ||
            !before.submitted && next != before && next.phase != SynologyPhotoEditPhase.SUBMITTING ||
            before.phase == SynologyPhotoEditPhase.PENDING && next.phase == SynologyPhotoEditPhase.SUBMITTING ||
            before.phase == SynologyPhotoEditPhase.PENDING && before.attempted != next.attempted ||
            !next.attempted.containsAll(before.attempted) || !next.completed.containsAll(before.completed) ||
            !next.reportedFailures.containsAll(before.reportedFailures) || before.createdTag != null && next.createdTag != before.createdTag) storageFailure()
        row.copy(checkpoint = next).also(::write)
    }

    fun discard(row: SynologyPhotoEditRecord) = synchronized(lock) {
        if (row.id in activeIds || row.checkpoint.submitted && !row.checkpoint.finished) throw SynologyPhotoEditFailure(SynologyPhotoEditProblem.PENDING)
        if (get(row.id, row.owner, row.checkpoint.userId) != row) storageFailure()
        if (!preferences.edit().remove(key(row.id)).commit()) storageFailure()
    }

    fun removeProfile(profileId: String) = synchronized(lock) {
        val rows = all().filter { it.owner.profileId == profileId }
        if (rows.any { it.id in activeIds }) throw SynologyPhotoEditFailure(SynologyPhotoEditProblem.BUSY)
        val editor = preferences.edit(); rows.forEach { editor.remove(key(it.id)) }
        if (rows.isNotEmpty() && !editor.commit()) storageFailure()
    }

    suspend fun <T> exclusive(owner: WorkspaceOwner, id: String, block: suspend () -> T): T {
        val identity = owner.profileId to owner.identityRevision
        synchronized(lock) {
            if (!activeOwners.add(identity)) throw SynologyPhotoEditFailure(SynologyPhotoEditProblem.BUSY)
            activeIds.add(id)
        }
        try { return block() } finally { synchronized(lock) { activeOwners.remove(identity); activeIds.remove(id) } }
    }

    private fun all(): List<SynologyPhotoEditRecord> = preferences.all.keys.filter { it.startsWith("photos_edit_") }.map { key ->
        val raw = preferences.getString(key, null) ?: storageFailure()
        val row = runCatching { json.decodeFromString<SynologyPhotoEditRecord>(raw) }.getOrElse { storageFailure() }
        if (key != key(row.id)) storageFailure()
        validate(row); row
    }
    private fun write(row: SynologyPhotoEditRecord) {
        validate(row)
        if (!preferences.edit().putString(key(row.id), json.encodeToString(row)).commit()) storageFailure()
    }
    private fun validate(row: SynologyPhotoEditRecord) {
        if (row.version != 1 || row.owner.profileId != row.checkpoint.profileId || row.createdAtSeconds < 0) storageFailure()
        try { validatePhotoEditCheckpoint(row.checkpoint) } catch (_: SynologyPhotoFailure) { storageFailure() }
    }
    private fun key(id: String) = "photos_edit_v1_$id"
    private fun storageFailure(): Nothing = throw SynologyPhotoEditFailure(SynologyPhotoEditProblem.STORAGE)
    companion object {
        private val lock = Any()
        private val activeOwners = mutableSetOf<Pair<String, String>>()
        private val activeIds = mutableSetOf<String>()
        fun isProfileBusy(profileId: String) = synchronized(lock) { activeOwners.any { it.first == profileId } }
    }
}
