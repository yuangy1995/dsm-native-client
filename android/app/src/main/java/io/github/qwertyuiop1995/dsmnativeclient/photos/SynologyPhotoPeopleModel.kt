package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoPeopleState(
    val visible: Boolean = false, val space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL,
    val action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.SHOW_PEOPLE,
    val target: SynologyPhotoCollection? = null, val people: List<SynologyPhotoCollection> = emptyList(),
    val photos: List<SynologyPhoto> = emptyList(), val faces: List<SynologyPhotoPersonFace> = emptyList(),
    val selectedFaces: Set<Long> = emptySet(), val destination: Long? = null,
    val name: String = "", val desiredVisibility: Boolean = false, val selected: Set<Long> = emptySet(), val query: String = "",
    val loading: Boolean = false, val loaded: Boolean = false, val working: Boolean = false, val error: Throwable? = null,
    val confirmation: SynologyPhotoAlbumCheckpoint? = null, val records: List<SynologyPhotoAlbumRecord> = emptyList(),
) {
    val pending: Boolean get() = records.any { it.checkpoint.submitted && !it.checkpoint.finished }
    val choices: List<SynologyPhotoCollection> get() = people.filter { action !in setOf(SynologyPhotoAlbumAction.MERGE_PEOPLE, SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES) || it.id != target?.id }
    val filtered: List<SynologyPhotoCollection> get() = choices.filter { query.isBlank() || it.name.contains(query.trim(), ignoreCase = true) }
    val blockedByPending: Boolean get() {
        val ids = selected + setOfNotNull(destination) + listOfNotNull(target?.id).takeIf { action != SynologyPhotoAlbumAction.SHOW_PEOPLE }.orEmpty()
        return records.any { it.checkpoint.submitted && !it.checkpoint.finished && (it.checkpoint.people!!.originals.any { person -> person.id in ids } || it.checkpoint.people.faces?.targetReceipt in ids ||
            it.checkpoint.targets.any { old -> photos.any { it.id == old.id } }) }
    }
    val canSave: Boolean get() = visible && loaded && !loading && !working && confirmation == null && !blockedByPending && when (action) {
        SynologyPhotoAlbumAction.REMOVE_PERSON_FACES -> target != null && selectedFaces.isNotEmpty()
        SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES -> target != null && selectedFaces.isNotEmpty() && (destination == null || choices.any { it.id == destination })
        SynologyPhotoAlbumAction.COVER_PERSON -> target != null && photos.size == 1 && faces.isNotEmpty()
        SynologyPhotoAlbumAction.RENAME_PERSON -> target != null && name.trim() != target.name
        SynologyPhotoAlbumAction.MERGE_PEOPLE -> target != null && selected.isNotEmpty()
        SynologyPhotoAlbumAction.SHOW_PEOPLE -> selected.isNotEmpty()
        else -> false
    }
}

/** 人物表单固定当前来源和目标；提交结果只读恢复，页面刷新不改变未提交的名称。 */
internal class SynologyPhotoPeopleModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val thumbnails: SynologyPhotoThumbnailStore,
    private val canStart: () -> Boolean, private val beforeWrite: suspend () -> Unit,
    private val onApplied: suspend (SynologyPhotoAlbumCheckpoint, List<SynologyPhotoCollection>?) -> Unit,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoPeopleState()); val state = mutable.asStateFlow()
    private var generation = 0L; private var viewGeneration = 0L; private var active = false; private var nameInitialized = false; private var facesInitialized = false
    private var loader: Job? = null; private var worker: Job? = null; private var poller: Job? = null
    fun available(space: SynologyPhotoSpace, merging: Boolean = false) = repository.canManagePeople(space, merging)
    suspend fun thumbnail(person: SynologyPhotoCollection): ByteArray {
        requireCurrent()
        return thumbnails.loadPerson(owner.profileId, person) { repository.personThumbnail(person) }.also { requireCurrent() }
    }
    fun facesAvailable(space: SynologyPhotoSpace) = repository.canManagePersonFaces(space)
    suspend fun faceThumbnail(face: SynologyPhotoPersonFace): ByteArray {
        requireCurrent()
        if (face !in state.value.faces) changed()
        return thumbnails.loadFace(face) { repository.faceThumbnail(face) }.also { requireCurrent() }
    }
    fun openFaces(action: SynologyPhotoAlbumAction, target: SynologyPhotoCollection, photos: List<SynologyPhoto>) {
        if (!allowed() || !action.isPersonFaces || !facesAvailable(target.space) || photos.size !in 1..100 ||
            photos.map { it.id }.distinct().size != photos.size || photos.any { it.id.profileId != owner.profileId || it.id.space != target.space || it.albumContext != null } ||
            action == SynologyPhotoAlbumAction.COVER_PERSON && photos.size != 1) return
        reset(); mutable.value = SynologyPhotoPeopleState(visible = true, space = target.space, action = action, target = target, photos = photos)
        load()
    }
    fun toggleFace(id: Long) {
        if (editable() && state.value.faces.any { it.id == id }) mutable.update { it.copy(selectedFaces = if (id in it.selectedFaces) it.selectedFaces - id else it.selectedFaces + id) }
    }
    fun destination(id: Long?) {
        val value = state.value
        if (!editable() || value.action != SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES || id != null && value.choices.none { it.id == id }) return
        mutable.update { it.copy(destination = id, name = id?.let { target -> value.choices.single { it.id == target }.name }.orEmpty()) }
    }
    private fun allowed() = job.isActive && canStart() && !state.value.working
    fun open(action: SynologyPhotoAlbumAction, space: SynologyPhotoSpace, target: SynologyPhotoCollection? = null) {
        if (!allowed() || (!action.isPeople || action.isPersonFaces) || !available(space, action == SynologyPhotoAlbumAction.MERGE_PEOPLE) ||
            action != SynologyPhotoAlbumAction.SHOW_PEOPLE && (target == null || target.space != space)) return
        reset(); mutable.value = SynologyPhotoPeopleState(visible = true, space = space, action = action, target = target,
            name = target?.name.orEmpty(), desiredVisibility = target?.personVisible == false,
            selected = setOfNotNull(target?.id).takeIf { action == SynologyPhotoAlbumAction.SHOW_PEOPLE }.orEmpty())
        load()
    }
    fun load(): Job? {
        val old = state.value
        if (!old.visible || old.loading || old.working || old.confirmation != null) return null
        val token = generation; val view = viewGeneration
        mutable.update { it.copy(loading = true, error = null) }
        loader = scope.launch {
            try {
                reloadRecords(token, view)
                val people = repository.managementPeople(old.space, old.action == SynologyPhotoAlbumAction.SHOW_PEOPLE)
                val faces = if (old.action.isPersonFaces && old.photos.isNotEmpty()) repository.personFaces(old.target!!.id, old.photos) else emptyList()
                check(token, view)
                val target = old.target?.let { selected -> people.singleOrNull { it.id == selected.id } }
                if (old.action != SynologyPhotoAlbumAction.SHOW_PEOPLE && target == null) changed()
                mutable.update { current -> current.copy(people = people, target = target,
                    name = if (!nameInitialized && old.action in setOf(SynologyPhotoAlbumAction.RENAME_PERSON, SynologyPhotoAlbumAction.MERGE_PEOPLE)) target?.name.orEmpty() else current.name,
                    selected = current.selected.filter { id -> people.any { it.id == id && eligible(it, current) } }.toSet(), loaded = true,
                    faces = faces, selectedFaces = faces.map { it.id }.toSet().let { if (facesInitialized) it.intersect(current.selectedFaces) else it }) }
                nameInitialized = true; facesInitialized = true
            } catch (error: Exception) { if (current(token, view) && error !is CancellationException) mutable.update { it.copy(error = error, loaded = false, people = emptyList(), faces = emptyList()) } }
            finally { if (current(token, view)) { mutable.update { it.copy(loading = false) }; startPolling() } }
        }; return loader
    }
    fun name(value: String) { if (editable()) mutable.update { it.copy(name = value) } }
    fun search(value: String) { if (editable()) mutable.update { it.copy(query = value) } }
    fun visibility(value: Boolean) {
        if (!editable() || state.value.action != SynologyPhotoAlbumAction.SHOW_PEOPLE) return
        mutable.update { it.copy(desiredVisibility = value, selected = emptySet()) }
    }
    fun toggle(id: Long) {
        val value = state.value; val person = value.people.singleOrNull { it.id == id } ?: return
        if (!editable() || !eligible(person, value)) return
        val limit = if (value.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) 99 else 100
        mutable.update { it.copy(selected = if (id in it.selected) it.selected - id else if (it.selected.size < limit) it.selected + id else it.selected) }
    }
    private fun eligible(person: SynologyPhotoCollection, state: SynologyPhotoPeopleState): Boolean = when (state.action) {
        SynologyPhotoAlbumAction.MERGE_PEOPLE -> person.id != state.target?.id
        SynologyPhotoAlbumAction.SHOW_PEOPLE -> person.personVisible != null && person.personVisible != state.desiredVisibility
        else -> false
    }
    private fun editable() = state.value.visible && state.value.loaded && !state.value.loading && !state.value.working && state.value.confirmation == null
    fun save(): Job? {
        val draft = state.value
        if (!allowed() || !draft.canSave) return null
        val originals = if (draft.action == SynologyPhotoAlbumAction.RENAME_PERSON) listOf(draft.target!!)
            else (if (draft.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) listOf(draft.target!!) else emptyList()) + draft.people.filter { it.id in draft.selected }
        val id = UUID.randomUUID().toString(); val token = generation; val view = viewGeneration
        return perform(id) {
            beforeWrite()
            val checkpoint = (if (draft.action.isPersonFaces) {
                val selectedFaces = draft.faces.filter { it.id in draft.selectedFaces }
                repository.preparePersonFaces(draft.action, SynologyPhotoPersonSnapshot(draft.target!!),
                    draft.photos.filter { photo -> draft.action == SynologyPhotoAlbumAction.COVER_PERSON || selectedFaces.any { it.photoId == photo.id } },
                    selectedFaces.takeUnless { draft.action == SynologyPhotoAlbumAction.COVER_PERSON }.orEmpty(),
                    draft.destination?.let { id -> SynologyPhotoPersonSnapshot(draft.choices.single { it.id == id }) },
                    (draft.destination?.let { id -> draft.choices.single { it.id == id }.name } ?: draft.name.trim()).takeIf { draft.action == SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES })
            } else repository.preparePeopleChange(draft.action, originals.map(::SynologyPhotoPersonSnapshot),
                draft.name.trim().takeUnless { draft.action == SynologyPhotoAlbumAction.SHOW_PEOPLE },
                draft.desiredVisibility.takeIf { draft.action == SynologyPhotoAlbumAction.SHOW_PEOPLE })).copy(operationId = id)
            check(token, view)
            val risk = draft.action in setOf(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, SynologyPhotoAlbumAction.MERGE_PEOPLE) ||
                draft.action == SynologyPhotoAlbumAction.RENAME_PERSON && checkpoint.people!!.name == "" && draft.target?.count?.let { it < 2 } == true
            if (risk) mutable.update { it.copy(confirmation = checkpoint) }
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
        if (result.finished && result.people!!.completedIds.isNotEmpty()) {
            val people = try { repository.managementPeople(result.people.space, state.value.action == SynologyPhotoAlbumAction.SHOW_PEOPLE) }
                catch (error: Exception) { if (error is CancellationException) throw error; present(error, token); null }
            requireCurrent(); if (!current(token)) return
            onApplied(result, people)
            mutable.update { current ->
                val updated = people ?: applyPhotoPeopleResult(current.people, result)
                current.copy(people = updated, target = current.target?.let { target -> updated.singleOrNull { it.id == target.id } },
                    selected = current.selected - result.people.completedIds,
                    selectedFaces = current.selectedFaces - result.people.faces?.selected.orEmpty().map { it.id }.toSet(),
                    faces = current.faces.filterNot { face -> result.people.faces?.selected.orEmpty().any { it.id == face.id } },
                    photos = current.photos.filterNot { it.id.itemId in result.people.faces?.removedPhotoIds.orEmpty() })
            }
        }
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any {
            it.checkpoint.action.isPeople && it.checkpoint.submitted && !it.checkpoint.finished
        }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    private suspend fun reloadRecords(token: Long, view: Long = viewGeneration) {
        requireCurrent(); val records = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action.isPeople && it.checkpoint.people!!.space == state.value.space } }
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
    fun dismiss() { if (state.value.working) { poller?.cancel(); mutable.update { it.copy(visible = false) } } else { reset(); mutable.value = SynologyPhotoPeopleState() } }
    private fun reset() { generation++; nameInitialized = false; facesInitialized = false; val wasActive = active; deactivate(); active = wasActive }
    private fun current(token: Long, view: Long = viewGeneration) = token == generation && view == viewGeneration && job.isActive
    private suspend fun check(token: Long, view: Long = viewGeneration) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token, view)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoPeopleState() }
    override fun close() { revokeAccess(); job.cancel() }
}
