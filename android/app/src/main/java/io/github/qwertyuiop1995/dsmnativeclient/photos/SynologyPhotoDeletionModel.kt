package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoDeletionState(
    val visible: Boolean = false,
    val recordsPage: Boolean = false,
    val candidate: List<SynologyPhoto>? = null,
    val resumeId: String? = null,
    val records: List<SynologyPhotoDeletionRecord> = emptyList(),
    val checking: Boolean = false,
    val writing: Boolean = false,
    val recovering: Boolean = false,
    val error: Throwable? = null,
) {
    val pending: SynologyPhotoDeletionRecord? get() = records.firstOrNull { !it.finished }
}

/** 固定确认、逐项保存提交边界；离开停止后续写入，重启后未发送项必须再次确认。 */
internal class SynologyPhotoDeletionModel(
    private val repository: SynologyPhotosServing,
    parent: CoroutineScope,
    private val store: SynologyPhotoDeletionStore? = null,
    private val owner: WorkspaceOwner? = null,
    private val requireCurrent: () -> Unit = {},
    private val canStart: () -> Boolean = { true },
    private val beforeWrite: suspend (SynologyPhoto) -> Unit = {},
    private val onConfirmed: (SynologyPhotoDeletionCheckpoint) -> Unit,
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoDeletionState())
    val state = mutable.asStateFlow()
    val available: Boolean get() = store != null && owner != null && repository.canDeleteOriginals
    fun enabled(photo: SynologyPhoto): Boolean = available && repository.canDelete(photo)
    private var active = false; private var generation = 0L; private var draftGeneration = 0L
    private var loader: Job? = null; private var worker: Job? = null; private var recovery: Job? = null
    private var opening: List<SynologyPhoto>? = null
    private val applied = mutableSetOf<String>()

    fun prepare(photo: SynologyPhoto): Job? = prepare(listOf(photo))
    fun prepare(photos: List<SynologyPhoto>): Job? {
        if (!canOpen()) return null
        if (photos.size !in 1..100 || photos.map { it.id }.distinct().size != photos.size) {
            mutable.update { it.copy(error = SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.LIMIT)) }; return null
        }
        opening = photos.toList()
        return prepareDraft(null)
    }
    fun retry(): Job? = if (state.value.recordsPage) refreshRecords() else prepareDraft(state.value.resumeId)
    fun resume(id: String): Job? {
        if (!canOpen()) return null
        opening = null
        return prepareDraft(id)
    }
    private fun prepareDraft(id: String?): Job? {
        if (!canOpen() || id == null && opening == null) return null
        val token = generation; val draftToken = ++draftGeneration
        loader?.cancel()
        mutable.update { it.copy(visible = true, recordsPage = false, candidate = null, resumeId = id, checking = true, error = null) }
        loader = scope.launch {
            try {
                val user = identity(); val rows = records(user); check(token)
                val photos = if (id == null) {
                    if (rows.any { !it.finished }) throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.PENDING)
                    opening ?: changed()
                } else {
                    val row = rows.singleOrNull { it.id == id } ?: changed()
                    if (row.entries.any { it.phase == SynologyPhotoDeletionPhase.SUBMITTED }) throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.PENDING)
                    row.entries.filter { it.phase == SynologyPhotoDeletionPhase.PREPARED }.map { repository.deletionTarget(it) }.ifEmpty { changed() }
                }
                for (photo in photos) {
                    check(token)
                    if (!enabled(photo)) throw SynologyPhotoFailure(SynologyPhotoFailureKind.DELETION_UNVERIFIED)
                    beforeWrite(photo); repository.prepareDeletion(photo)
                }
                if (repository.photoEditIdentity() != user) denied()
                check(token)
                if (draftToken == draftGeneration) mutable.update { it.copy(candidate = photos.toList(), records = rows) }
            } catch (error: Exception) { if (draftToken == draftGeneration) present(error, token) }
            finally { if (current(token) && draftToken == draftGeneration) mutable.update { it.copy(checking = false) } }
        }
        return loader
    }
    fun cancelCandidate() {
        draftGeneration++; loader?.cancel(); opening = null
        mutable.update { it.copy(candidate = null, resumeId = null, checking = false, visible = false, error = null) }
    }
    fun confirm(): Job? {
        val photos = state.value.candidate ?: return null
        if (!canOpen() || photos.any { !enabled(it) }) return null
        val resume = state.value.resumeId; val token = generation
        val newId = java.util.UUID.randomUUID().toString()
        mutable.update { it.copy(candidate = null, checking = false, writing = true, recordsPage = true, error = null) }
        worker = scope.launch {
            var batchBegan = resume != null
            try {
                val user = identity()
                store!!.exclusive(owner!!, resume ?: newId) {
                    // 确认后先复查整份清单，再逐项复用写前预检。
                    for (photo in photos) { check(token); beforeWrite(photo); repository.prepareDeletion(photo) }
                    check(token)
                    if (repository.photoEditIdentity() != user) denied()
                    var row = if (resume == null) SynologyPhotoDeletionRecord(id = newId, owner = owner, userId = user,
                        entries = photos.map { SynologyPhotoDeletionCheckpoint(userId = user, target = SynologyPhotoDeletionTarget(it)) })
                        .also { batchBegan = true; withContext(Dispatchers.IO) { store.begin(it) } }
                    else withContext(Dispatchers.IO) { store.get(resume, owner, user) }
                    if (row.entries.any { it.phase == SynologyPhotoDeletionPhase.SUBMITTED } ||
                        row.entries.filter { it.phase == SynologyPhotoDeletionPhase.PREPARED }.map { it.target } != photos.map(::SynologyPhotoDeletionTarget)) changed()
                    reload(token, user)
                    for (photo in photos) {
                        check(token)
                        if (!canStart()) throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.BUSY)
                        beforeWrite(photo)
                        val entry = row.entries.single { it.target.id == photo.id }
                        val result = withContext(Dispatchers.IO) {
                            repository.performPhotoDeletion(photo, entry) { next -> store.update(row.id, owner, user, next) }
                        }
                        check(token); reload(token, user)
                        row = withContext(Dispatchers.IO) { store.get(row.id, owner, user) }
                        if (result.phase != SynologyPhotoDeletionPhase.CONFIRMED) break
                    }
                }
            } catch (error: Exception) {
                // 尚未建立批次的预检失败保留固定确认清单，重试仍会重新检查权限和身份。
                if (!batchBegan && current(token)) mutable.update { it.copy(recordsPage = false, candidate = photos) }
                present(error, token)
            }
            finally {
                if (current(token)) {
                    try { reload(token) } catch (error: Exception) { present(error, token) }
                    mutable.update { it.copy(writing = false) }; startRecovery()
                }
            }
        }
        return worker
    }
    fun review(id: String): Job? {
        if (!active || !available || state.value.writing || state.value.checking || state.value.recovering) return null
        val token = generation
        mutable.update { it.copy(recovering = true, error = null) }
        worker = scope.launch {
            try {
                val user = identity()
                store!!.exclusive(owner!!, id) {
                    val row = withContext(Dispatchers.IO) { store.get(id, owner, user) }
                    for (entry in row.entries.filter { it.phase == SynologyPhotoDeletionPhase.SUBMITTED }) {
                        check(token)
                        withContext(Dispatchers.IO) { repository.reviewPhotoDeletion(entry) { next -> store.update(id, owner, user, next) } }
                        check(token); reload(token, user)
                    }
                }
            } catch (error: Exception) { present(error, token) }
            finally {
                if (current(token)) {
                    try { reload(token) } catch (error: Exception) { present(error, token) }
                    mutable.update { it.copy(recovering = false) }; startRecovery()
                }
            }
        }
        return worker
    }
    fun cancelRemaining(id: String): Job? = updateRecord {
        val user = identity(); store!!.cancelRemaining(id, owner!!, user)
    }
    fun discard(id: String): Job? = updateRecord {
        val user = identity(); store!!.discard(store.get(id, owner!!, user))
    }
    private fun updateRecord(action: suspend () -> Unit): Job? {
        if (!canOpen()) return null
        val token = generation
        mutable.update { it.copy(checking = true, error = null) }
        loader = scope.launch {
            try { withContext(Dispatchers.IO) { requireCurrent(); action() }; check(token); reload(token) }
            catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(checking = false) } }
        }
        return loader
    }
    suspend fun requireNoPending() {
        if (!available) return
        if (state.value.writing || state.value.checking || state.value.candidate != null)
            throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.BUSY)
        if (records(identity()).any { !it.finished }) throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.PENDING)
    }
    fun showRecords() {
        mutable.update { it.copy(visible = true, recordsPage = true) }
        if (!state.value.writing && !state.value.recovering) { cancelPreparation(); refreshRecords() }
    }
    fun refreshRecords(): Job? {
        if (!active || !available || state.value.writing || state.value.recovering || state.value.checking) return null
        val token = generation
        loader?.cancel(); mutable.update { it.copy(checking = true, error = null) }
        loader = scope.launch {
            try { reload(token); startRecovery() } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(checking = false) } }
        }
        return loader
    }
    private suspend fun identity(): Long {
        requireCurrent()
        if (!available || owner!!.profileId != repository.profileId) denied()
        return repository.photoEditIdentity().also { if (it <= 0) denied() }
    }
    private suspend fun records(user: Long): List<SynologyPhotoDeletionRecord> = withContext(Dispatchers.IO) { store!!.records(owner!!, user) }
    private suspend fun reload(token: Long, user: Long? = null) {
        val rows = records(user ?: identity()); check(token)
        mutable.update { it.copy(records = rows) }
        rows.flatMap { it.entries }.filter { it.phase == SynologyPhotoDeletionPhase.CONFIRMED }.forEach {
            if (applied.add(it.operationId)) onConfirmed(it)
        }
    }
    fun activate() { active = true; refreshRecords() }
    private fun startRecovery() {
        if (!active || recovery?.isActive == true || state.value.records.none { row -> row.entries.any { it.phase == SynologyPhotoDeletionPhase.SUBMITTED } }) return
        recovery = scope.launch {
            var attempts = 0
            while (active && isActive) {
                delay(if (attempts++ < 6) 2_000 else 15_000)
                val row = state.value.records.firstOrNull { record -> record.entries.any { it.phase == SynologyPhotoDeletionPhase.SUBMITTED } } ?: break
                review(row.id)?.join()
            }
        }
    }
    fun dismiss() {
        if (!state.value.writing && !state.value.recovering) cancelPreparation()
        mutable.update { it.copy(visible = false) }
    }
    private fun cancelPreparation() {
        draftGeneration++; loader?.cancel(); opening = null
        mutable.update { it.copy(candidate = null, resumeId = null, checking = false) }
    }
    fun deactivate() {
        active = false; generation++; cancelPreparation(); worker?.cancel(); recovery?.cancel(); recovery = null
        mutable.update { it.copy(visible = false, writing = false, recovering = false) }
    }
    fun revokeAccess() { deactivate(); mutable.value = SynologyPhotoDeletionState() }
    override fun close() { revokeAccess(); job.cancel() }
    private fun canOpen() = active && available && canStart() && !state.value.writing && !state.value.checking && !state.value.recovering
    private fun current(token: Long) = active && token == generation && job.isActive
    private fun check(token: Long) { requireCurrent(); if (!current(token)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
