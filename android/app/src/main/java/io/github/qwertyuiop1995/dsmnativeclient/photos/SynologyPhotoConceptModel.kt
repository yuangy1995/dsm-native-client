package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoConceptState(
    val visible: Boolean = false, val space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL,
    val action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.SHOW_CONCEPTS,
    val target: SynologyPhotoCollection? = null, val concepts: List<SynologyPhotoCollection> = emptyList(),
    val photos: List<SynologyPhoto> = emptyList(), val selected: Set<Long> = emptySet(), val desiredVisibility: Boolean = false,
    val query: String = "", val loading: Boolean = false, val loaded: Boolean = false,
    val working: Boolean = false, val error: Throwable? = null,
    val confirmation: SynologyPhotoAlbumCheckpoint? = null, val records: List<SynologyPhotoAlbumRecord> = emptyList(),
) {
    val filtered: List<SynologyPhotoCollection> get() = concepts.filter { query.isBlank() || it.name.contains(query.trim(), ignoreCase = true) }
    val pending: Boolean get() = records.any { it.checkpoint.submitted && !it.checkpoint.finished }
    val blockedByPending: Boolean get() {
        val ids = if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) selected else setOfNotNull(target?.id)
        return records.any { it.checkpoint.submitted && !it.checkpoint.finished &&
            (it.checkpoint.concept!!.originals.any { original -> original.id in ids } || it.checkpoint.targets.any { old -> photos.any { it.id == old.id } }) }
    }
    val canSave: Boolean get() = visible && loaded && !loading && !working && confirmation == null && !blockedByPending && when (action) {
        SynologyPhotoAlbumAction.SHOW_CONCEPTS -> selected.isNotEmpty()
        SynologyPhotoAlbumAction.COVER_CONCEPT -> target != null && photos.size == 1 && target.thumbnail?.unitId != photos.single().id.itemId
        SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS -> target?.count?.let { it >= photos.size } == true && target.conceptDisplayThreshold != null && photos.isNotEmpty()
        else -> false
    }
}

/** 表单保留当前主题、固定照片选择与只读恢复记录。 */
internal class SynologyPhotoConceptModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val thumbnails: SynologyPhotoThumbnailStore,
    private val canStart: () -> Boolean, private val beforeWrite: suspend () -> Unit,
    private val onApplied: suspend (SynologyPhotoAlbumCheckpoint, List<SynologyPhotoCollection>?) -> Unit,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoConceptState()); val state = mutable.asStateFlow()
    private var generation = 0L; private var viewGeneration = 0L; private var active = false
    private var loader: Job? = null; private var worker: Job? = null; private var poller: Job? = null
    fun available(space: SynologyPhotoSpace, editingPhotos: Boolean = false) = repository.canManageConcepts(space, editingPhotos)
    suspend fun thumbnail(concept: SynologyPhotoCollection): ByteArray {
        requireCurrent()
        return thumbnails.loadConcept(owner.profileId, concept) { repository.conceptThumbnail(concept) }.also { requireCurrent() }
    }
    fun open(space: SynologyPhotoSpace, target: SynologyPhotoCollection? = null) {
        if (!allowed() || !available(space) || target?.space?.let { it != space } == true) return
        reset(); mutable.value = SynologyPhotoConceptState(visible = true, space = space, target = target,
            selected = setOfNotNull(target?.id), desiredVisibility = target?.conceptVisible == false)
        load()
    }
    fun openPhotos(action: SynologyPhotoAlbumAction, target: SynologyPhotoCollection, photos: List<SynologyPhoto>) {
        if (!allowed() || action !in setOf(SynologyPhotoAlbumAction.COVER_CONCEPT, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) ||
            !available(target.space, true) || photos.size !in 1..100 || photos.map { it.id }.distinct().size != photos.size ||
            photos.any { it.id.profileId != owner.profileId || it.id.space != target.space || it.albumContext != null } ||
            action == SynologyPhotoAlbumAction.COVER_CONCEPT && photos.size != 1) return
        reset(); mutable.value = SynologyPhotoConceptState(visible = true, space = target.space, action = action, target = target, photos = photos)
        load()
    }
    fun load(): Job? {
        val old = state.value
        if (!old.visible || old.loading || old.working || old.confirmation != null) return null
        val token = generation; val view = viewGeneration; mutable.update { it.copy(loading = true, error = null) }
        loader = scope.launch {
            try {
                reloadRecords(token, view)
                val values = if (old.action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) repository.managementConcepts(old.space)
                    else listOf(repository.concept(old.target!!.id, old.space))
                check(token, view)
                val target = old.target?.let { wanted -> values.singleOrNull { it.id == wanted.id } }
                if (old.action != SynologyPhotoAlbumAction.SHOW_CONCEPTS && target == null) changed()
                mutable.update { it.copy(concepts = values, target = target, loaded = true,
                    selected = it.selected.filter { id -> values.any { value -> value.id == id && value.conceptVisible != null && value.conceptVisible != it.desiredVisibility } }.toSet()) }
            } catch (error: Exception) { if (current(token, view) && error !is CancellationException) mutable.update { it.copy(loaded = false, error = error, concepts = emptyList()) } }
            finally { if (current(token, view)) { mutable.update { it.copy(loading = false) }; startPolling() } }
        }; return loader
    }
    fun search(value: String) { if (editable()) mutable.update { it.copy(query = value) } }
    fun visibility(value: Boolean) { if (editable() && state.value.action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) mutable.update { it.copy(desiredVisibility = value, selected = emptySet()) } }
    fun toggle(id: Long) {
        val value = state.value; val concept = value.concepts.singleOrNull { it.id == id } ?: return
        if (!editable() || concept.conceptVisible == null || concept.conceptVisible == value.desiredVisibility || value.action != SynologyPhotoAlbumAction.SHOW_CONCEPTS) return
        mutable.update { it.copy(selected = if (id in it.selected) it.selected - id else if (it.selected.size < 100) it.selected + id else it.selected) }
    }
    private fun editable() = state.value.visible && state.value.loaded && !state.value.loading && !state.value.working && state.value.confirmation == null
    private fun allowed() = job.isActive && canStart() && !state.value.working
    fun save(): Job? {
        val draft = state.value
        if (!allowed() || !draft.canSave) return null
        val originals = if (draft.action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) draft.concepts.filter { it.id in draft.selected } else listOf(draft.target!!)
        val id = UUID.randomUUID().toString(); val token = generation; val view = viewGeneration
        return perform(id) {
            beforeWrite()
            val checkpoint = repository.prepareConceptChange(draft.action, originals.map(::SynologyPhotoConceptSnapshot), draft.photos,
                draft.desiredVisibility.takeIf { draft.action == SynologyPhotoAlbumAction.SHOW_CONCEPTS }).copy(operationId = id)
            check(token, view)
            if (draft.action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) mutable.update { it.copy(confirmation = checkpoint) }
            else begin(checkpoint)
        }
    }
    fun cancelConfirmation() { if (!state.value.working) mutable.update { it.copy(confirmation = null) } }
    fun confirm(): Job? {
        val checkpoint = state.value.confirmation ?: return null
        if (!allowed()) return null
        mutable.update { it.copy(confirmation = null) }
        return perform(checkpoint.operationId) { beforeWrite(); repository.preparePhotoAlbum(checkpoint); begin(checkpoint) }
    }
    private suspend fun begin(checkpoint: SynologyPhotoAlbumCheckpoint) {
        requireCurrent(); currentCoroutineContext().ensureActive()
        val record = SynologyPhotoAlbumRecord(owner = owner, checkpoint = checkpoint)
        store.begin(record); execute(record)
    }
    fun resume(id: String): Job? {
        val record = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed() || !record.checkpoint.submitted || record.checkpoint.finished) return null
        return perform(id) { execute(store.get(id, owner, record.checkpoint.userId)) }
    }
    private fun perform(id: String, operation: suspend () -> Unit): Job {
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
    private suspend fun execute(record: SynologyPhotoAlbumRecord) {
        requireCurrent(); if (repository.photoEditIdentity() != record.checkpoint.userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        store.requireNoConflict(record); val token = generation
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); val saved = store.save(record.id, owner, record.checkpoint.userId, next)
            if (current(token)) mutable.update { it.copy(records = listOf(saved) + it.records.filterNot { old -> old.id == record.id }) }
        }
        val result = if (record.checkpoint.submitted) repository.reviewPhotoAlbum(record.checkpoint, ::save) else repository.performPhotoAlbum(record.checkpoint, ::save)
        requireCurrent(); if (!current(token) || !result.finished || result.concept!!.updated.isEmpty()) return
        val current = state.value; val values = applyPhotoConceptResult(current.concepts, result)
        onApplied(result, values.takeIf { current.loaded && current.action == SynologyPhotoAlbumAction.SHOW_CONCEPTS })
        mutable.update { it.copy(concepts = values, target = it.target?.let { target -> values.singleOrNull { value -> value.id == target.id } ?: target },
            selected = it.selected - result.concept.completedIds, photos = it.photos.filterNot { photo -> photo.id.itemId in result.concept.removedPhotoIds }) }
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any { it.checkpoint.action.isConcept && it.checkpoint.submitted && !it.checkpoint.finished })
            throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    private suspend fun reloadRecords(token: Long, view: Long = viewGeneration) {
        requireCurrent(); val records = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action.isConcept && it.checkpoint.concept!!.space == state.value.space } }
        check(token, view); mutable.update { it.copy(records = records) }
    }
    fun discard(id: String): Job? {
        val record = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working || record.checkpoint.submitted && !record.checkpoint.finished) return null
        val token = generation
        return scope.launch { try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(record) }; reloadRecords(token) } catch (error: Exception) { present(error, token) } }
    }
    private fun startPolling() {
        if (!active || !state.value.visible || poller?.isActive == true || !state.value.pending) return
        val token = generation; val view = viewGeneration
        poller = scope.launch {
            while (isActive && active && current(token, view) && state.value.visible && state.value.pending) {
                pause(15_000)
                if (!active || !current(token, view) || state.value.loading || state.value.working || state.value.confirmation != null) continue
                state.value.records.firstOrNull { it.checkpoint.submitted && !it.checkpoint.finished }?.let { resume(it.id)?.join() }
            }
        }
    }
    fun activate() { active = true; if (state.value.visible) { load(); startPolling() } }
    fun deactivate() { active = false; viewGeneration++; loader?.cancel(); poller?.cancel(); poller = null; mutable.update { it.copy(loading = false, confirmation = null) } }
    fun dismiss() { if (state.value.working) { poller?.cancel(); mutable.update { it.copy(visible = false) } } else { reset(); mutable.value = SynologyPhotoConceptState() } }
    private fun reset() { generation++; val wasActive = active; deactivate(); active = wasActive }
    private fun current(token: Long, view: Long = viewGeneration) = token == generation && view == viewGeneration && job.isActive
    private suspend fun check(token: Long, view: Long = viewGeneration) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token, view)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoConceptState() }
    override fun close() { revokeAccess(); job.cancel() }
}
