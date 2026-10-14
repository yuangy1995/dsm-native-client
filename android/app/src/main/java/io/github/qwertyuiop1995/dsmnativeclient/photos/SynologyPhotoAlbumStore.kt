package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoCodecPromptCodec
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreviewRegenerationCodec
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoAutomaticPreviewCodec
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoSimilarCodec
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoConceptCodec
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPeopleCodec
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoManualFacesCodec
import io.github.qwertyuiop1995.dsmnativeclient.data.photoAlbumsConflict
import io.github.qwertyuiop1995.dsmnativeclient.data.validatePhotoAlbumCheckpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext

internal enum class SynologyPhotoAlbumProblem { STORAGE, BUSY, PENDING }
internal class SynologyPhotoAlbumFailure(val problem: SynologyPhotoAlbumProblem) : RuntimeException(problem.name)

@Serializable
internal data class SynologyPhotoAlbumRecord(
    val version: Int = 1, val owner: WorkspaceOwner, val checkpoint: SynologyPhotoAlbumCheckpoint,
    val createdAtSeconds: Long = System.currentTimeMillis() / 1000,
) {
    val id: String get() = checkpoint.operationId
    override fun toString() = "PhotoAlbumRecord(phase=${checkpoint.phase})"
}

/** 相册独立版本 1 加密存储，不迁移登录、上传和原件编辑记录。 */
internal class SynologyPhotoAlbumStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_photos_albums",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun records(owner: WorkspaceOwner, userId: Long): List<SynologyPhotoAlbumRecord> = synchronized(lock) {
        all().filter { it.owner.hasSameIdentity(owner) && it.checkpoint.userId == userId }.map { row ->
            if (row.id !in activeIds && row.checkpoint.phase == SynologyPhotoAlbumPhase.SUBMITTING)
                row.copy(checkpoint = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING)).also(::write) else row
        }.sortedByDescending { it.createdAtSeconds }
    }
    fun get(id: String, owner: WorkspaceOwner, userId: Long): SynologyPhotoAlbumRecord = synchronized(lock) {
        all().singleOrNull { it.id == id && it.owner.hasSameIdentity(owner) && it.checkpoint.userId == userId } ?: storageFailure()
    }
    fun begin(row: SynologyPhotoAlbumRecord) = synchronized(lock) {
        validate(row)
        if (row.checkpoint.submitted || all().any { it.id == row.id }) storageFailure()
        requireNoConflict(row)
        validateSimilarUndo(row, all())
        write(row)
    }
    fun beginSimilarBatch(rows: List<SynologyPhotoAlbumRecord>) = synchronized(lock) {
        if (rows.size !in 2..100) storageFailure()
        val first = rows.first(); val ids = rows.map { it.id }; val old = all()
        if (ids.distinct().size != rows.size || rows.any { !it.owner.hasSameIdentity(first.owner) || it.checkpoint.userId != first.checkpoint.userId ||
                it.checkpoint.submitted || it.checkpoint.similar?.batchOrder != ids || old.any { previous -> previous.id == it.id } } ||
            rows.map { it.checkpoint.similar!!.group.space to it.checkpoint.similar.group.id }.distinct().size != rows.size ||
            rows.flatMap { it.checkpoint.targets }.map { it.id }.let { it.distinct().size != it.size } ||
            rows.map { it.checkpoint.similar!!.edit }.distinct().size != 1) storageFailure()
        rows.forEach { validate(it); requireNoConflict(it); validateSimilarUndo(it, old) }
        val editor = preferences.edit()
        rows.forEach { editor.putString(key(it.id), json.encodeToString(it)) }
        if (!editor.commit()) storageFailure()
    }
    private fun validateSimilarUndo(row: SynologyPhotoAlbumRecord, records: List<SynologyPhotoAlbumRecord>) {
        row.checkpoint.similar?.undo?.let { undo ->
            val source = records.singleOrNull { it.id == undo.operationId && it.owner.hasSameIdentity(row.owner) }?.checkpoint ?: storageFailure()
            val original = source.similar ?: storageFailure()
            if (source.userId != row.checkpoint.userId || !original.canUndo || original.group != row.checkpoint.similar.group ||
                source.targets != row.checkpoint.targets || original.edit != undo.edit || original.selectedIds != undo.selectedIds ||
                original.resultingGroup != undo.resultingGroup || records.any { it.owner.hasSameIdentity(row.owner) &&
                    it.checkpoint.similar?.undo?.operationId == undo.operationId }) storageFailure()
        }
    }
    fun requireNoConflict(row: SynologyPhotoAlbumRecord) = synchronized(lock) {
        if (all().any { it.owner.hasSameIdentity(row.owner) && photoAlbumsConflict(it.checkpoint, row.checkpoint) })
            throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    fun save(id: String, owner: WorkspaceOwner, userId: Long, input: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumRecord = synchronized(lock) {
        val row = get(id, owner, userId)
        val before = row.checkpoint
        val next = input.copy(temporaryCancelRequested = input.temporaryCancelRequested || before.temporaryCancelRequested)
        if (!before.sameOperation(next) || before.finished && before != next || before.submitted && !next.submitted ||
            !before.submitted && next != before && next.phase != SynologyPhotoAlbumPhase.SUBMITTING ||
            before.phase == SynologyPhotoAlbumPhase.PENDING && next.phase == SynologyPhotoAlbumPhase.SUBMITTING ||
            !next.completed.containsAll(before.completed) || before.membershipHasFailures && !next.membershipHasFailures ||
            before.frozenDeletionAttempted && !next.frozenDeletionAttempted || before.frozenDeletionRejected && !next.frozenDeletionRejected ||
            before.sharingUpdateAttempted && !next.sharingUpdateAttempted || before.sharingUpdateAcknowledged && !next.sharingUpdateAcknowledged ||
            before.sharingEnableAttempted && !next.sharingEnableAttempted || before.sharingNoChanges && !next.sharingNoChanges ||
            before.temporaryCloseAttempted && !next.temporaryCloseAttempted || before.temporaryDeleteAttempted && !next.temporaryDeleteAttempted ||
            before.temporaryClosedRevision != null && before.temporaryClosedRevision != next.temporaryClosedRevision ||
            before.temporaryCreatedSnapshot != null && before.temporaryCreatedSnapshot != next.temporaryCreatedSnapshot ||
            before.request?.targetDigest != null && before.request.targetDigest != next.request?.targetDigest ||
            before.folder?.createdFolderId != null && before.folder.createdFolderId != next.folder?.createdFolderId ||
            before.folder?.coverAcknowledged == true && next.folder?.coverAcknowledged != true ||
            before.settings?.attempted == true && next.settings?.attempted != true ||
            before.codecPrompt?.let { old -> next.codecPrompt?.let { SynologyPhotoCodecPromptCodec.advances(old, it) } != true } == true ||
            before.previews?.let { old -> next.previews?.let { SynologyPhotoPreviewRegenerationCodec.advances(old, it) } != true } == true ||
            before.automaticPreview?.let { old -> next.automaticPreview?.let { SynologyPhotoAutomaticPreviewCodec.advances(old, it) } != true } == true ||
            before.similar?.let { old -> next.similar?.let { SynologyPhotoSimilarCodec.advances(old, it) } != true } == true ||
            before.concept?.let { old -> next.concept?.let { SynologyPhotoConceptCodec.advances(old, it) } != true } == true ||
            before.people?.let { old -> next.people?.let { SynologyPhotoPeopleCodec.advances(old, it) } != true } == true ||
            before.manualFaces?.let { old -> next.manualFaces?.let { SynologyPhotoManualFacesCodec.advances(old, it) } != true } == true ||
            before.maintenance?.attempted == true && next.maintenance?.attempted != true ||
            before.maintenance?.acknowledged == true && next.maintenance?.acknowledged != true ||
            before.maintenance?.rejected == true && next.maintenance?.rejected != true ||
            before.settings?.rejected == true && next.settings?.rejected != true ||
            before.settings?.globalProgress?.let { old -> next.settings?.globalProgress?.let { fresh ->
                !fresh.attempted.containsAll(old.attempted) || !fresh.acknowledged.containsAll(old.acknowledged) ||
                    !fresh.rejected.containsAll(old.rejected) || !fresh.completed.containsAll(old.completed)
            } != false } == true ||
            before.sharedMembers?.let { old -> next.sharedMembers?.let { fresh ->
                !fresh.attempted.containsAll(old.attempted) || !fresh.acknowledged.containsAll(old.acknowledged) ||
                    !fresh.rejected.containsAll(old.rejected) || !fresh.completed.containsAll(old.completed)
            } != false } == true ||
            before.background?.let { old -> next.background?.let { fresh ->
                !fresh.attempted.containsAll(old.attempted) || !fresh.rejected.containsAll(old.rejected) || !fresh.completed.containsAll(old.completed)
            } != false } == true ||
            before.folderSharing?.updateAttempted == true && next.folderSharing?.updateAttempted != true ||
            before.folderSharing?.updateAcknowledged == true && next.folderSharing?.updateAcknowledged != true ||
            before.folderSharing?.configAttempted == true && next.folderSharing?.configAttempted != true ||
            before.folderSharing?.rejected == true && next.folderSharing?.rejected != true ||
            before.files?.taskId != null && before.files.taskId != next.files?.taskId ||
            before.files?.total != null && before.files.total != next.files?.total ||
            before.files?.targetVerified == true && next.files?.targetVerified != true ||
            before.files?.result != null && before.files.result != next.files?.result ||
            before.createdAlbumId != null && before.createdAlbumId != next.createdAlbumId) storageFailure()
        row.copy(checkpoint = next).also(::write)
    }
    fun requestTemporaryCancellation(id: String, owner: WorkspaceOwner) = synchronized(lock) {
        val row = all().singleOrNull { it.id == id && it.owner.hasSameIdentity(owner) } ?: return@synchronized
        if (row.checkpoint.action != SynologyPhotoAlbumAction.CREATE_TEMPORARY) storageFailure()
        write(row.copy(checkpoint = row.checkpoint.copy(temporaryCancelRequested = true)))
    }
    fun discard(row: SynologyPhotoAlbumRecord) = synchronized(lock) {
        if (row.id in activeIds || row.checkpoint.submitted && !row.checkpoint.finished)
            throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
        if (row.checkpoint.similar?.undo?.operationId?.let { source -> all().any { it.id == source && it.owner.hasSameIdentity(row.owner) } } == true)
            throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
        if (get(row.id, row.owner, row.checkpoint.userId) != row || !preferences.edit().remove(key(row.id)).commit()) storageFailure()
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val rows = all().filter { it.owner.profileId == profileId }
        if (rows.any { it.id in activeIds }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        val editor = preferences.edit(); rows.forEach { editor.remove(key(it.id)) }
        if (rows.isNotEmpty() && !editor.commit()) storageFailure()
    }
    suspend fun <T> exclusive(owner: WorkspaceOwner, id: String, block: suspend () -> T): T {
        synchronized(lock) { automaticJobs[owner.profileId to owner.identityRevision] }?.cancelAndJoin()
        return locked(owner, id, false, block)
    }
    /** 用户操作先取消自动转换，等待清理及持久事实落定后再占用同身份互斥。 */
    suspend fun <T> automaticExclusive(owner: WorkspaceOwner, id: String, block: suspend () -> T): T = locked(owner, id, true, block)
    private suspend fun <T> locked(owner: WorkspaceOwner, id: String, automatic: Boolean, block: suspend () -> T): T {
        val identity = owner.profileId to owner.identityRevision
        val operation = currentCoroutineContext()[Job]!!
        synchronized(lock) {
            if (!activeOwners.add(identity)) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
            activeIds.add(id)
            if (automatic) automaticJobs[identity] = operation
        }
        try { return block() } finally { synchronized(lock) { activeOwners.remove(identity); activeIds.remove(id); if (automatic) automaticJobs.remove(identity) } }
    }
    private fun all(): List<SynologyPhotoAlbumRecord> = preferences.all.keys.filter { it.startsWith("photos_album_") }.map { key ->
        val raw = preferences.getString(key, null) ?: storageFailure()
        val row = runCatching { json.decodeFromString<SynologyPhotoAlbumRecord>(raw) }.getOrElse { storageFailure() }
        if (key != key(row.id)) storageFailure()
        validate(row); row
    }
    private fun write(row: SynologyPhotoAlbumRecord) {
        validate(row)
        if (!preferences.edit().putString(key(row.id), json.encodeToString(row)).commit()) storageFailure()
    }
    private fun validate(row: SynologyPhotoAlbumRecord) {
        if (row.version != 1 || row.owner.profileId != row.checkpoint.profileId || row.createdAtSeconds < 0) storageFailure()
        try { validatePhotoAlbumCheckpoint(row.checkpoint) } catch (_: SynologyPhotoFailure) { storageFailure() }
    }
    private fun key(id: String) = "photos_album_v1_$id"
    private fun storageFailure(): Nothing = throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.STORAGE)
    companion object {
        private val lock = Any()
        private val activeOwners = mutableSetOf<Pair<String, String>>()
        private val activeIds = mutableSetOf<String>()
        private val automaticJobs = mutableMapOf<Pair<String, String>, Job>()
        fun isProfileBusy(profileId: String) = synchronized(lock) { activeOwners.any { it.first == profileId } }
    }
}
