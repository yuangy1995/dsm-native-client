package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoManualFacesState(
    val photo: SynologyPhoto? = null, val visible: Boolean = false, val image: ByteArray? = null,
    val originals: List<SynologyPhotoFaceSnapshot> = emptyList(), val drafts: List<SynologyPhotoFaceDraft> = emptyList(),
    val people: List<SynologyPhotoCollection> = emptyList(), val selected: String? = null, val query: String = "",
    val drawing: Boolean = false, val loading: Boolean = false, val loaded: Boolean = false, val working: Boolean = false,
    val draftSubmitted: Boolean = false, val confirmation: SynologyPhotoAlbumCheckpoint? = null, val error: Throwable? = null,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(),
) {
    val pending: Boolean get() = records.any { it.checkpoint.submitted && !it.checkpoint.finished }
    val editable: Boolean get() = visible && loaded && !loading && !working && !pending && !draftSubmitted && confirmation == null
    val canSave: Boolean get() = editable && image != null && drafts.any { it.changed } && drafts.all { it.valid } &&
        drafts.sumOf { if (!it.changed) 0 else if (it.resized && !it.removed) 2 else 1 } <= 100
    val selectedDraft: SynologyPhotoFaceDraft? get() = drafts.singleOrNull { it.key == selected }
    val filteredPeople: List<SynologyPhotoCollection> get() = people.filter { query.isBlank() || it.name.contains(query.trim(), ignoreCase = true) }
}

/** 当前照片草稿与图片仅保留内存；所有已发送步骤只通过既有加密记录只读恢复。 */
internal class SynologyPhotoManualFacesModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner, private val requireCurrent: () -> Unit,
    private val canStart: () -> Boolean, private val beforeWrite: suspend () -> Unit,
    private val onApplied: suspend (SynologyPhotoAlbumCheckpoint) -> Unit,
    private val crop: suspend (ByteArray, List<SynologyPhotoFaceDraft>) -> Map<String, ByteArray> = SynologyPhotoFaceEditing::crops,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoManualFacesState()); val state = mutable.asStateFlow()
    private var generation = 0L; private var viewGeneration = 0L; private var active = false; private var initialized = false
    private var loader: Job? = null; private var worker: Job? = null; private var poller: Job? = null
    private var images: Map<String, ByteArray> = emptyMap()
    fun available(photo: SynologyPhoto) = repository.canEditPhotoFaces(photo)
    fun open(photo: SynologyPhoto) {
        if (!allowed() || !available(photo) || photo.id.profileId != owner.profileId) return
        reset(); mutable.value = SynologyPhotoManualFacesState(visible = true, photo = photo); load()
    }
    fun load(restart: Boolean = false): Job? {
        val old = state.value; val photo = old.photo ?: return null
        if (!old.visible || old.loading || old.working || old.confirmation != null || restart && old.pending) return null
        val token = generation; val view = viewGeneration
        mutable.update { it.copy(loading = true, error = null) }
        loader = scope.launch {
            try {
                reloadRecords(token, view)
                val latest = repository.details(photo)
                if (!SynologyPhotoEditTarget(photo).matches(latest, includeTime = true)) changed()
                val faces = repository.photoFaces(latest).map { it.face }
                val people = repository.managementPeople(photo.id.space, true)
                val bytes = repository.thumbnail(latest, large = true)
                check(token, view)
                val rebase = !initialized || restart || old.draftSubmitted && !state.value.pending
                if (!rebase && (faces.size != old.originals.size || old.originals.any { original -> faces.none(original::matches) })) changed()
                mutable.update { current -> current.copy(photo = latest, people = people, image = bytes, loaded = true,
                    originals = if (rebase) faces else current.originals,
                    drafts = if (rebase) SynologyPhotoFaceEditing.drafts(faces, photo.id.space) else current.drafts,
                    selected = if (rebase) faces.firstOrNull()?.let { "face-${it.id}" } else current.selected,
                    draftSubmitted = if (rebase) false else current.draftSubmitted, drawing = false) }
                initialized = true
            } catch (error: Exception) { if (current(token, view) && error !is CancellationException) mutable.update { it.copy(error = error, loaded = false) } }
            finally { if (current(token, view)) { mutable.update { it.copy(loading = false) }; startPolling() } }
        }; return loader
    }
    fun select(key: String) { if (state.value.editable && state.value.drafts.any { it.key == key }) mutable.update { it.copy(selected = key, query = "", drawing = false) } }
    fun draw(value: Boolean) { if (state.value.editable) mutable.update { it.copy(drawing = value) } }
    fun add(bounds: SynologyPhotoFaceBounds = SynologyPhotoFaceBounds(0.35, 0.35, 0.3, 0.3)) {
        if (!state.value.editable || !bounds.valid || state.value.drafts.count { !it.removed } >= 50) return
        val key = UUID.randomUUID().toString()
        mutable.update { it.copy(drafts = it.drafts + SynologyPhotoFaceDraft(key, null, bounds, null, ""), selected = key, query = "", drawing = false) }
    }
    fun bounds(bounds: SynologyPhotoFaceBounds) { if (bounds.valid) edit { it.copy(bounds = bounds) } }
    fun name(value: String) = edit { if (it.person == null) it.copy(name = value) else it }
    fun person(id: Long?) {
        if (state.value.selectedDraft?.person?.id == id) return
        val target = id?.let { value -> state.value.people.singleOrNull { it.id == value } ?: return }
        edit { it.copy(person = target?.let(::SynologyPhotoPersonSnapshot), name = target?.name.orEmpty()) }
    }
    fun search(value: String) { if (state.value.editable) mutable.update { it.copy(query = value) } }
    fun remove() = edit { it.copy(removed = !it.removed) }
    private fun edit(change: (SynologyPhotoFaceDraft) -> SynologyPhotoFaceDraft) {
        if (state.value.editable) mutable.update { value -> value.copy(drafts = value.drafts.map { if (it.key == value.selected) change(it) else it }) }
    }
    fun save(): Job? {
        val draft = state.value
        if (!allowed() || !draft.canSave) return null
        val id = UUID.randomUUID().toString(); val token = generation; val view = viewGeneration
        return perform(id) {
            beforeWrite(); clearImages()
            val cropped = crop(draft.image!!, draft.drafts)
            try { check(token, view) } catch (error: Exception) { cropped.values.forEach { it.fill(0) }; throw error }
            images = cropped
            val checkpoint = repository.prepareManualFaces(draft.photo!!, draft.originals,
                SynologyPhotoFaceEditing.changes(draft.drafts, images)).copy(operationId = id)
            check(token, view)
            if (checkpoint.manualFaces!!.changes.any { it !is SynologyPhotoFaceChange.Add }) mutable.update { it.copy(confirmation = checkpoint) }
            else begin(checkpoint)
        }
    }
    fun cancelConfirmation() { if (!state.value.working) { mutable.update { it.copy(confirmation = null) }; clearImages() } }
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
                if (current(token) && state.value.confirmation == null) clearImages()
                if (current(token)) {
                    try { withContext(NonCancellable) { reloadRecords(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) {
                        mutable.update { it.copy(working = false) }
                        if (state.value.draftSubmitted && !state.value.pending) load()
                        startPolling()
                    }
                }
            }
        }; return worker!!
    }
    private suspend fun execute(record: SynologyPhotoAlbumRecord) {
        requireCurrent(); if (repository.photoEditIdentity() != record.checkpoint.userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        store.requireNoConflict(record); val token = generation
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); val saved = store.save(record.id, owner, record.checkpoint.userId, next)
            if (current(token)) mutable.update { it.copy(draftSubmitted = it.draftSubmitted || next.submitted,
                records = listOf(saved) + it.records.filterNot { old -> old.id == record.id }) }
        }
        val result = if (record.checkpoint.submitted) repository.reviewPhotoAlbum(record.checkpoint, ::save)
            else repository.performManualFaces(record.checkpoint, images, ::save)
        check(token)
        if (result.finished && result.manualFaces!!.completed.isNotEmpty()) onApplied(result)
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any {
            it.checkpoint.action == SynologyPhotoAlbumAction.EDIT_PHOTO_FACES && it.checkpoint.submitted && !it.checkpoint.finished
        }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    private suspend fun reloadRecords(token: Long, view: Long = viewGeneration) {
        requireCurrent(); val photo = state.value.photo
        val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter {
            it.checkpoint.action == SynologyPhotoAlbumAction.EDIT_PHOTO_FACES && it.checkpoint.targets.single().id == photo?.id
        } }
        check(token, view); mutable.update { it.copy(records = rows) }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working || row.checkpoint.submitted && !row.checkpoint.finished) return null
        val token = generation
        return scope.launch { try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reloadRecords(token) } catch (error: Exception) { present(error, token) } }
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
    fun deactivate() { active = false; viewGeneration++; loader?.cancel(); poller?.cancel(); poller = null; cancelConfirmation(); mutable.update { it.copy(loading = false) } }
    fun dismiss() { if (state.value.working) mutable.update { it.copy(visible = false, image = null) } else { reset(); mutable.value = SynologyPhotoManualFacesState() } }
    private fun reset() { generation++; initialized = false; val wasActive = active; deactivate(); active = wasActive; clearImages() }
    private fun clearImages() { images.values.forEach { it.fill(0) }; images = emptyMap() }
    private fun allowed() = job.isActive && canStart() && !state.value.working
    private fun current(token: Long, view: Long = viewGeneration) = token == generation && view == viewGeneration && job.isActive
    private suspend fun check(token: Long, view: Long = viewGeneration) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token, view)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoManualFacesState() }
    override fun close() { revokeAccess(); job.cancel() }
}
