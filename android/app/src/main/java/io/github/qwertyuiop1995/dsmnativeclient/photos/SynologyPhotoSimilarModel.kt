package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoSimilarState(
    val visible: Boolean = false, val space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL,
    val original: SynologyPhoto? = null, val detail: SynologyPhotoSimilarDetail? = null,
    val selected: Set<Long> = emptySet(), val loading: Boolean = false, val loaded: Boolean = false,
    val dissolved: Boolean = false, val working: Boolean = false, val error: Throwable? = null,
    val confirmation: List<SynologyPhotoAlbumCheckpoint> = emptyList(), val records: List<SynologyPhotoAlbumRecord> = emptyList(),
    val status: SynologyPhotoSimilarStatus? = null,
) {
    val pending: Boolean get() = records.any { it.checkpoint.submitted && !it.checkpoint.finished }
    val canEdit: Boolean get() = detail != null && !loading && !working && confirmation.isEmpty() && !pending
}

/** 单组与多组共享原操作记录；多组依序执行，未知停止后续，冷启动不自动发送未开始项。 */
internal class SynologyPhotoSimilarModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit,
    private val canStart: () -> Boolean, private val beforeWrite: suspend () -> Unit,
    private val onApplied: suspend (SynologyPhotoAlbumCheckpoint) -> Unit,
    private val onPreview: (SynologyPhoto) -> Unit,
    private val onExport: (List<SynologyPhoto>) -> Unit,
    private val canDelete: (SynologyPhoto) -> Boolean,
    private val onDelete: (List<SynologyPhoto>) -> Unit,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoSimilarState()); val state = mutable.asStateFlow()
    private var generation = 0L; private var viewGeneration = 0L; private var active = false
    private var loader: Job? = null; private var worker: Job? = null; private var poller: Job? = null
    private var browsing: SynologyPhotoSpace? = null
    private val recoveryAttempts = mutableMapOf<String, Int>()
    fun available(space: SynologyPhotoSpace) = repository.canManageSimilar(space)
    val canCleanUp: Boolean get() = state.value.let { value -> value.canEdit && value.detail!!.photos.all(canDelete) &&
        value.selected.isNotEmpty() && value.detail.photos.count { it.id.itemId !in value.selected } in 1..100 }
    fun open(photo: SynologyPhoto) {
        if (!allowed() || photo.id.profileId != owner.profileId || photo.similarGroup == null || photo.albumContext != null) return
        resetView(); mutable.value = SynologyPhotoSimilarState(visible = true, space = photo.id.space, original = photo)
        load()
    }
    fun showRecords(space: SynologyPhotoSpace) {
        if (!allowed()) return
        resetView(); mutable.value = SynologyPhotoSimilarState(visible = true, space = space)
        load()
    }
    fun load(): Job? {
        val old = state.value
        if (!old.visible || old.loading || old.working || old.confirmation.isNotEmpty()) return null
        val token = generation; val view = viewGeneration
        mutable.update { it.copy(loading = true, error = null) }
        loader = scope.launch {
            try {
                reloadRecords(token, view)
                val detail = old.original?.let { repository.similarGroupDetails(it.similarGroup ?: changed()) }
                check(token, view)
                mutable.update { it.copy(detail = detail, loaded = true, dissolved = old.original != null && detail == null,
                    selected = it.selected.intersect(detail?.group?.photoIds.orEmpty().toSet())) }
            } catch (error: Exception) { if (current(token, view) && error !is CancellationException) mutable.update { it.copy(error = error, detail = null, loaded = false) } }
            finally { if (current(token, view)) { mutable.update { it.copy(loading = false) }; startPolling() } }
        }; return loader
    }
    fun toggle(id: Long) {
        if (!state.value.canEdit || id !in state.value.detail!!.group.photoIds) return
        mutable.update { it.copy(selected = if (id in it.selected) it.selected - id else it.selected + id) }
    }
    fun preview(id: Long) { state.value.detail?.photos?.singleOrNull { it.id.itemId == id }?.let(onPreview) }
    fun prepare(edit: SynologyPhotoSimilarEdit): Job? {
        val draft = state.value; val detail = draft.detail ?: return null
        if (!allowed() || !draft.canEdit || !available(detail.group.space) || edit == SynologyPhotoSimilarEdit.UNDO) return null
        val selected = if (edit == SynologyPhotoSimilarEdit.UNGROUP) emptyList() else detail.group.photoIds.filter { it in draft.selected }
        if (edit == SynologyPhotoSimilarEdit.TOP_PICK && (selected.size != 1 || selected.single() == detail.group.topPickId) ||
            edit == SynologyPhotoSimilarEdit.REMOVE && selected.isEmpty()) return null
        val guard = interactiveGuard()
        return perform {
            beforeWrite()
            val row = repository.prepareSimilarChange(detail, edit, selected); guard()
            if (edit == SynologyPhotoSimilarEdit.TOP_PICK) beginAndRun(listOf(row))
            else mutable.update { it.copy(confirmation = listOf(row)) }
        }
    }
    fun prepareBatch(photos: List<SynologyPhoto>): Job? {
        if (!allowed() || photos.isEmpty() || photos.any { it.id.profileId != owner.profileId || it.albumContext != null || it.similarGroup == null } ||
            photos.map { it.id.space }.distinct().size != 1 || !available(photos.first().id.space)) return null
        val representatives = photos.distinctBy { it.similarGroup!!.id }
        if (representatives.size !in 1..100) return null
        resetView(); mutable.value = SynologyPhotoSimilarState(visible = true, space = photos.first().id.space)
        val guard = interactiveGuard()
        return perform {
            beforeWrite()
            val rows = representatives.map { photo -> repository.prepareSimilarChange(repository.similarPhotos(photo), SynologyPhotoSimilarEdit.UNGROUP) }
            guard(); mutable.update { it.copy(confirmation = ordered(rows), loaded = true) }
        }
    }
    fun cancelConfirmation() { if (!state.value.working) mutable.update { it.copy(confirmation = emptyList()) } }
    fun confirm(): Job? {
        val rows = state.value.confirmation
        if (!allowed() || rows.isEmpty()) return null
        mutable.update { it.copy(confirmation = emptyList()) }
        val guard = interactiveGuard()
        return perform { beforeWrite(); rows.forEach { repository.preparePhotoAlbum(it) }; guard(); beginAndRun(rows) }
    }
    fun resume(id: String): Job? {
        val record = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed() || !record.checkpoint.submitted || record.checkpoint.finished) return null
        recoveryAttempts.remove(id)
        return perform(id) { execute(store.get(id, owner, record.checkpoint.userId)) }
    }
    fun continueBatch(id: String): Job? {
        val record = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed()) return null
        val batch = batchRecords(record)
        if (batch.any { it.checkpoint.submitted && !it.checkpoint.finished }) return null
        val waiting = batch.filter { !it.checkpoint.submitted }
        if (waiting.isEmpty()) return null
        val guard = interactiveGuard()
        return perform {
            beforeWrite()
            for (row in waiting) {
                row.checkpoint.similar!!.undo?.let { undo -> repository.prepareSimilarUndo(store.get(undo.operationId, owner, row.checkpoint.userId).checkpoint) }
                repository.preparePhotoAlbum(row.checkpoint)
            }
            guard(); mutable.update { it.copy(confirmation = waiting.map { row -> row.checkpoint }) }
        }
    }
    fun undo(id: String): Job? {
        val record = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed()) return null
        if (!canUndo(record)) return null
        val original = batchRecords(record).filter { it.checkpoint.similar!!.canUndo }.reversed()
        if (original.isEmpty() || original.any { source -> state.value.records.any { it.checkpoint.similar?.undo?.operationId == source.id } }) return null
        val guard = interactiveGuard()
        return perform {
            beforeWrite()
            val rows = original.map { repository.prepareSimilarUndo(it.checkpoint) }
            guard(); beginAndRun(ordered(rows))
        }
    }
    fun cancelRemaining(id: String): Job? {
        val record = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed()) return null
        return perform { batchRecords(record).filter { !it.checkpoint.submitted && it.checkpoint.similar?.undo == null }.forEach { store.discard(it) } }
    }
    fun exportGroups(photos: List<SynologyPhoto>): Job? {
        if (!allowed() || photos.isEmpty() || photos.any { it.id.profileId != owner.profileId || it.similarGroup == null || it.albumContext != null }) return null
        val guard = interactiveGuard()
        return perform {
            val members = photos.distinctBy { it.id.space to it.similarGroup!!.id }.flatMap { repository.similarPhotos(it).photos }.distinctBy { it.id }
            guard(); mutable.update { it.copy(working = false) }; onExport(members)
        }
    }
    fun exportCurrent() { state.value.detail?.photos?.takeIf { it.isNotEmpty() && !state.value.working }?.let(onExport) }
    fun cleanUp(): Job? {
        val value = state.value; val detail = value.detail ?: return null
        if (!allowed() || !canCleanUp) return null
        val deleting = detail.photos.filter { it.id.itemId !in value.selected }; val guard = interactiveGuard()
        return perform {
            beforeWrite()
            // 借用同一完整分组预检；不会提交分组变更。删除清单仍交既有原件确认与逐项恢复。
            repository.prepareSimilarChange(detail, SynologyPhotoSimilarEdit.UNGROUP)
            guard(); mutable.update { it.copy(working = false) }; onDelete(deleting)
        }
    }
    fun originalDeleted(id: SynologyPhotoId) {
        if (state.value.detail?.group?.let { it.profileId == id.profileId && it.space == id.space && id.itemId in it.photoIds } == true) {
            viewGeneration++; loader?.cancel(); mutable.update { it.copy(loading = false) }; load()
        }
    }
    fun canUndo(record: SynologyPhotoAlbumRecord): Boolean = record.checkpoint.similar?.canUndo == true &&
        batchRecords(record).all { it.checkpoint.finished } &&
        batchRecords(record).none { source -> state.value.records.any { it.checkpoint.similar?.undo?.operationId == source.id } }
    private fun batchRecords(record: SynologyPhotoAlbumRecord): List<SynologyPhotoAlbumRecord> {
        val order = record.checkpoint.similar!!.batchOrder
        return if (order.isEmpty()) listOf(record) else order.mapNotNull { id -> state.value.records.singleOrNull { it.id == id } }
    }
    private fun ordered(rows: List<SynologyPhotoAlbumCheckpoint>): List<SynologyPhotoAlbumCheckpoint> =
        if (rows.size < 2) rows else rows.map { it.copy(similar = it.similar!!.copy(batchOrder = rows.map { row -> row.operationId })) }
    private suspend fun beginAndRun(rows: List<SynologyPhotoAlbumCheckpoint>) {
        requireCurrent(); currentCoroutineContext().ensureActive()
        val existing = store.records(owner, rows.first().userId)
        val new = rows.filter { row -> existing.none { it.id == row.operationId } }.map { SynologyPhotoAlbumRecord(owner = owner, checkpoint = it) }
        if (new.isNotEmpty() && new.size != rows.size) changed()
        if (new.size > 1) store.beginSimilarBatch(new) else new.singleOrNull()?.let(store::begin)
        for (row in rows) {
            if (!active) break
            val result = execute(store.get(row.operationId, owner, row.userId))
            if (result.phase != SynologyPhotoAlbumPhase.COMPLETED) break
        }
    }
    private fun perform(id: String = UUID.randomUUID().toString(), operation: suspend () -> Unit): Job {
        val token = generation; mutable.update { it.copy(working = true, error = null) }
        worker = scope.launch {
            try { withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); operation() } } }
            catch (error: Exception) { present(error, token) }
            finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reloadRecords(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) { mutable.update { it.copy(working = false) }; startPolling() }
                }
            }
        }; return worker!!
    }
    private suspend fun execute(record: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != record.checkpoint.userId) denied()
        store.requireNoConflict(record); val token = generation
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); val saved = store.save(record.id, owner, record.checkpoint.userId, next)
            if (current(token)) mutable.update { it.copy(records = listOf(saved) + it.records.filterNot { old -> old.id == record.id }) }
        }
        val result = if (record.checkpoint.submitted) repository.reviewPhotoAlbum(record.checkpoint, ::save) else repository.performPhotoAlbum(record.checkpoint, ::save)
        requireCurrent()
        if (current(token) && result.similar!!.confirmed) {
            onApplied(result)
            if (state.value.original?.similarGroup?.id == result.similar.group.id && state.value.space == result.similar.group.space) {
                mutable.update { it.copy(detail = null, selected = emptySet(), dissolved = result.similar.resultingGroup == null) }
                result.similar.resultingGroup?.let { group ->
                    val detail = repository.similarGroupDetails(group)
                    if (current(token)) mutable.update { it.copy(detail = detail, dissolved = detail == null) }
                }
            }
        }
        return result
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any { it.checkpoint.similar != null && it.checkpoint.submitted && !it.checkpoint.finished })
            throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    private suspend fun reloadRecords(token: Long, view: Long = viewGeneration) {
        requireCurrent(); val space = state.value.space
        val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.similar?.group?.space == space } }
        check(token, view); mutable.update { it.copy(records = rows) }
    }
    fun browsing(space: SynologyPhotoSpace?) { if (browsing != space) { browsing = space; poller?.cancel(); poller = null; mutable.update { it.copy(status = null) }; startPolling() } }
    private fun startPolling() {
        if (!active || poller?.isActive == true || browsing == null && !state.value.visible) return
        val token = generation; val view = viewGeneration
        poller = scope.launch {
            while (isActive && active && current(token, view)) {
                browsing?.let { space ->
                    try { val status = repository.similarStatus(space); check(token, view); if (browsing == space) mutable.update { it.copy(status = status) } }
                    catch (error: Exception) { if (error is CancellationException) throw error; if (current(token, view)) mutable.update { it.copy(status = null) } }
                }
                if (state.value.visible && !state.value.loading && !state.value.working && state.value.confirmation.isEmpty()) {
                    state.value.records.firstOrNull { it.checkpoint.submitted && !it.checkpoint.finished && recoveryAttempts.getOrDefault(it.id, 0) < 3 }?.let { record ->
                        val attempts = recoveryAttempts.getOrDefault(record.id, 0)
                        if (allowed()) perform(record.id) { execute(store.get(record.id, owner, record.checkpoint.userId)) }.join()
                        recoveryAttempts[record.id] = attempts + 1
                    }
                }
                pause(15_000)
            }
        }
    }
    fun activate() { active = true; if (state.value.visible) load(); startPolling() }
    fun deactivate() { active = false; viewGeneration++; loader?.cancel(); poller?.cancel(); poller = null; mutable.update { it.copy(loading = false, confirmation = emptyList()) } }
    fun dismiss() { if (!state.value.working) { resetView(); mutable.update { SynologyPhotoSimilarState(status = it.status) }; startPolling() } }
    private fun resetView() { generation++; viewGeneration++; loader?.cancel(); poller?.cancel(); poller = null; recoveryAttempts.clear() }
    private fun interactiveGuard(): suspend () -> Unit {
        val token = generation; val view = viewGeneration
        return { check(token, view); if (!active) throw CancellationException() }
    }
    private fun allowed() = job.isActive && active && canStart() && !state.value.working
    private fun current(token: Long, view: Long = viewGeneration) = token == generation && view == viewGeneration && job.isActive
    private suspend fun check(token: Long, view: Long = viewGeneration) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token, view)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    fun revokeAccess() { deactivate(); resetView(); worker?.cancel(); browsing = null; mutable.value = SynologyPhotoSimilarState() }
    override fun close() { revokeAccess(); job.cancel() }
}
