package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.validatePhotoUploadCheckpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.File
import java.util.UUID
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** 索引加密保存，媒体副本位于不参与备份的私有目录；提交边界必须同步落盘。 */
internal class SynologyPhotoUploadStore(private val preferences: SharedPreferences, private val root: File) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_photos_uploads",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM), File(context.noBackupFilesDir, "photos-uploads"))
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun records(owner: WorkspaceOwner, userId: Long): List<SynologyPhotoUploadBatch> = synchronized(lock) {
        all().filter { it.owner.hasSameIdentity(owner) && it.userId == userId }.map { row ->
            if (row.id in activeIds) row else {
                fun recover(record: SynologyPhotoUploadCheckpoint) = if (record.phase == SynologyPhotoUploadPhase.SUBMITTING)
                    record.copy(phase = SynologyPhotoUploadPhase.PENDING) else record
                val next = row.copy(entries = row.entries.map { it.copy(checkpoint = it.checkpoint?.let(::recover)) },
                    folderCheckpoints = row.folderCheckpoints.mapValues { recover(it.value) })
                if (next != row) write(next)
                next
            }
        }.sortedByDescending { it.createdAtSeconds }
    }

    fun get(id: String, owner: WorkspaceOwner, userId: Long): SynologyPhotoUploadBatch = synchronized(lock) {
        all().singleOrNull { it.id == id && it.owner.hasSameIdentity(owner) && it.userId == userId } ?: storageFailure()
    }

    fun begin(row: SynologyPhotoUploadBatch) = synchronized(lock) {
        validate(row)
        if (row.checkpoints.isNotEmpty()) storageFailure()
        val previous = all()
        if (previous.any { it.id == row.id }) storageFailure()
        if (previous.any { conflicts(it, row) }) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.PENDING)
        if (row.entries.any { !artifact(row.id, it.id).isFile || artifact(row.id, it.id).length() != it.size }) storageFailure()
        write(row)
    }

    fun requireNoConflictingBatch(row: SynologyPhotoUploadBatch) = synchronized(lock) {
        if (all().any { conflicts(it, row) }) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.PENDING)
    }

    private fun conflicts(old: SynologyPhotoUploadBatch, row: SynologyPhotoUploadBatch): Boolean =
        old.id != row.id && old.owner.hasSameIdentity(row.owner) && old.userId == row.userId && old.target == row.target &&
            old.requiresReview && (old.folders.intersect(row.folders.toSet()).isNotEmpty() || old.entries.any { a ->
                row.entries.any { b -> a.filename == b.filename && a.sha256 == b.sha256 && a.relativeFolder == b.relativeFolder }
            })

    fun saveFile(batchId: String, owner: WorkspaceOwner, userId: Long, entryId: String, checkpoint: SynologyPhotoUploadCheckpoint) = synchronized(lock) {
        val row = get(batchId, owner, userId)
        val entry = row.entries.singleOrNull { it.id == entryId } ?: storageFailure()
        if (checkpoint.action != row.fileAction(entry)) storageFailure()
        validateUpdate(row, entry.checkpoint, checkpoint)
        write(row.copy(entries = row.entries.map { if (it.id == entryId) it.copy(checkpoint = checkpoint) else it }))
        if (checkpoint.finished) artifact(batchId, entryId).delete()
    }

    fun saveFolder(batchId: String, owner: WorkspaceOwner, userId: Long, path: String, checkpoint: SynologyPhotoUploadCheckpoint) = synchronized(lock) {
        val row = get(batchId, owner, userId)
        if (path !in row.folders || checkpoint.action != row.folderAction(path)) storageFailure()
        validateUpdate(row, row.folderCheckpoints[path], checkpoint)
        write(row.copy(folderCheckpoints = row.folderCheckpoints + (path to checkpoint)))
    }

    fun discard(row: SynologyPhotoUploadBatch) = synchronized(lock) {
        if (row.id in activeIds || row.requiresReview) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.PENDING)
        if (get(row.id, row.owner, row.userId) != row) storageFailure()
        if (!preferences.edit().remove(key(row.id)).commit()) storageFailure()
        directory(row.id).deleteRecursively()
    }

    fun removeProfile(profileId: String) = synchronized(lock) {
        val rows = all().filter { it.owner.profileId == profileId }
        if (rows.any { it.id in activeIds }) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.BUSY)
        val editor = preferences.edit(); rows.forEach { editor.remove(key(it.id)) }
        if (rows.isNotEmpty() && !editor.commit()) storageFailure()
        rows.forEach { directory(it.id).deleteRecursively() }
    }

    fun directory(id: String): File { if (!uuid(id)) storageFailure(); return File(root, id) }
    fun artifact(batchId: String, entryId: String): File { if (!uuid(entryId)) storageFailure(); return File(directory(batchId), entryId) }

    suspend fun <T> exclusive(owner: WorkspaceOwner, batchId: String, block: suspend () -> T): T {
        val key = owner.profileId to owner.identityRevision
        synchronized(lock) {
            if (!activeOwners.add(key)) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.BUSY)
            activeIds.add(batchId)
        }
        try { return block() } finally { synchronized(lock) { activeOwners.remove(key); activeIds.remove(batchId) } }
    }

    private fun validateUpdate(batch: SynologyPhotoUploadBatch, before: SynologyPhotoUploadCheckpoint?, after: SynologyPhotoUploadCheckpoint) {
        validateCheckpoint(after)
        if (after.profileId != batch.owner.profileId || after.userId != batch.userId) storageFailure()
        if (before != null && (!before.sameOperation(after) || before.finished && before != after ||
                before.submitted && !after.submitted || before.itemId != null && before.itemId != after.itemId ||
                before.folderId != null && before.folderId != after.folderId || before.uploadAction != null && before.uploadAction != after.uploadAction ||
                before.phase == SynologyPhotoUploadPhase.PENDING && after.phase == SynologyPhotoUploadPhase.SUBMITTING)) storageFailure()
        if (before == null && after.phase != SynologyPhotoUploadPhase.SUBMITTING) storageFailure()
    }

    private fun all(): List<SynologyPhotoUploadBatch> = preferences.all.keys.filter { it.startsWith("photos_upload_v1_") }.map { key ->
        val raw = preferences.getString(key, null) ?: storageFailure()
        val row = runCatching { json.decodeFromString<SynologyPhotoUploadBatch>(raw) }.getOrElse { storageFailure() }
        if (key != key(row.id)) storageFailure()
        validate(row)
        row
    }
    private fun write(row: SynologyPhotoUploadBatch) {
        validate(row)
        if (!preferences.edit().putString(key(row.id), json.encodeToString(row)).commit()) storageFailure()
    }
    private fun validate(row: SynologyPhotoUploadBatch) {
        fun path(value: String) = value.isNotBlank() && value.split('/').all { name(it) }
        if (row.version != 1 || !uuid(row.id) || row.owner.profileId.isBlank() || row.userId <= 0 || row.entries.isEmpty() ||
            row.entries.map { it.id }.distinct().size != row.entries.size || row.folders.distinct().size != row.folders.size ||
            row.folders.any { !path(it) } || row.folders.isNotEmpty() && row.target !is SynologyPhotoUploadTarget.Folder ||
            row.folderCheckpoints.keys.any { it !in row.folders }) storageFailure()
        if (row.target is SynologyPhotoUploadTarget.Folder && row.target.id <= 0 || row.target is SynologyPhotoUploadTarget.Album && row.target.id <= 0) storageFailure()
        if (row.entries.any { !uuid(it.id) || !name(it.filename) || it.size <= 0 || it.modifiedAtSeconds < 0 ||
                !it.sha256.matches(Regex("[a-f0-9]{64}")) || it.relativeFolder.isNotEmpty() && it.relativeFolder !in row.folders }) storageFailure()
        if (row.folders.any { val parent = it.substringBeforeLast('/', ""); parent.isNotEmpty() && parent !in row.folders }) storageFailure()
        row.folderCheckpoints.forEach { (path, record) -> if (record.action != row.folderAction(path)) storageFailure() }
        row.entries.forEach { entry -> if (entry.checkpoint?.action?.let { it != row.fileAction(entry) } == true) storageFailure() }
        row.checkpoints.forEach { checkpoint ->
            validateCheckpoint(checkpoint)
            if (checkpoint.phase == SynologyPhotoUploadPhase.READY || checkpoint.profileId != row.owner.profileId || checkpoint.userId != row.userId) storageFailure()
        }
        if (row.checkpoints.map { it.operationId }.distinct().size != row.checkpoints.size) storageFailure()
    }
    private fun name(value: String) = value.isNotBlank() && value !in setOf(".", "..") && value.none { it == '/' || it == '\u0000' }
    private fun validateCheckpoint(value: SynologyPhotoUploadCheckpoint) {
        try { validatePhotoUploadCheckpoint(value) } catch (_: SynologyPhotoFailure) { storageFailure() }
    }
    private fun key(id: String) = "photos_upload_v1_$id"
    private fun uuid(value: String) = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
    private fun storageFailure(): Nothing = throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.STORAGE)
    companion object {
        private val lock = Any()
        private val activeIds = mutableSetOf<String>()
        private val activeOwners = mutableSetOf<Pair<String, String>>()
        fun isProfileBusy(profileId: String): Boolean = synchronized(lock) { activeOwners.any { it.first == profileId } }
    }
}
