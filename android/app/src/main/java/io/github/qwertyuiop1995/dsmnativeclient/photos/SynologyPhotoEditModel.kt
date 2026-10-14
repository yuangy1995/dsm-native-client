package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoEditDraft(
    val id: String = UUID.randomUUID().toString(), val photos: List<SynologyPhoto>, val space: SynologyPhotoSpace,
    val edit: SynologyPhotoEdit = SynologyPhotoEdit.Rating(photos.singleOrNull()?.rating ?: 0),
)
internal data class SynologyPhotoEditState(
    val visible: Boolean = false, val selecting: Boolean = false, val selected: List<SynologyPhoto> = emptyList(),
    val selectedFolders: List<SynologyPhotoCollection> = emptyList(),
    val draft: SynologyPhotoEditDraft? = null, val records: List<SynologyPhotoEditRecord> = emptyList(),
    val tags: List<SynologyPhotoChoice> = emptyList(), val moreTags: Boolean = true,
    val loading: Boolean = false, val tagsLoading: Boolean = false, val working: Boolean = false,
    val detailsReady: Boolean = true,
    val activeId: String? = null, val error: Throwable? = null,
    val rotationId: String? = null, val rotationPhoto: SynologyPhotoId? = null,
)

/** 单张/多张编辑与加密恢复队列；已提交记录的“刷新”只读，不重新执行写入。 */
internal class SynologyPhotoEditModel(
    private val repository: SynologyPhotosServing,
    parent: CoroutineScope,
    private val store: SynologyPhotoEditStore,
    private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit,
    private val canStart: () -> Boolean,
    private val beforeWrite: suspend (List<SynologyPhoto>) -> Unit = {},
    private val onRotationFinished: suspend (SynologyPhotoEditCheckpoint?) -> Unit = {},
    private val onCompleted: () -> Unit,
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoEditState())
    val state = mutable.asStateFlow()
    private var worker: Job? = null
    private var loader: Job? = null
    private var tagsJob: Job? = null
    private var recordJob: Job? = null
    private var generation = 0L

    fun selectMode(value: Boolean) {
        if (!state.value.working) mutable.update { it.copy(selecting = value, selected = emptyList(), selectedFolders = emptyList(), error = null) }
    }
    fun toggle(photo: SynologyPhoto) {
        if (state.value.working || photo.id.profileId != owner.profileId) return
        val selected = state.value.selected
        val existing = selected.any { it.id == photo.id }
        if (!existing && selected.size + state.value.selectedFolders.size >= 100) {
            mutable.update { it.copy(error = SynologyPhotoEditFailure(SynologyPhotoEditProblem.LIMIT)) }; return
        }
        if (!existing && state.value.selectedFolders.any { it.space != photo.id.space || it.parentId != photo.folderId || photo.albumContext != null }) return
        mutable.update { it.copy(selecting = true, selected = if (existing) selected.filterNot { p -> p.id == photo.id } else selected + photo, error = null) }
    }
    fun toggleFolder(folder: SynologyPhotoCollection) {
        if (state.value.working || folder.path == null || folder.path == "/" || folder.parentId == null || folder.parentId <= 0) return
        val selected = state.value.selectedFolders
        val existing = selected.any { it.id == folder.id && it.space == folder.space }
        if (!existing && selected.size + state.value.selected.size >= 100) {
            mutable.update { it.copy(error = SynologyPhotoEditFailure(SynologyPhotoEditProblem.LIMIT)) }; return
        }
        if (!existing && (selected.any { it.space != folder.space || it.parentId != folder.parentId } ||
                state.value.selected.any { it.id.space != folder.space || it.folderId != folder.parentId || it.albumContext != null })) return
        mutable.update { it.copy(selecting = true, selectedFolders = if (existing) selected.filterNot { f -> f.id == folder.id && f.space == folder.space } else selected + folder, error = null) }
    }
    fun selectLoaded(photos: List<SynologyPhoto>, folders: List<SynologyPhotoCollection> = emptyList()) {
        if (!state.value.working) mutable.update { it.copy(selecting = true, selectedFolders = folders.take(100), selected = photos.take(100 - minOf(100, folders.size)), error = null) }
    }
    fun blocks(photo: SynologyPhoto): Boolean = state.value.working || state.value.records.any {
        it.checkpoint.submitted && !it.checkpoint.finished && it.checkpoint.targets.any { target -> target.id == photo.id }
    }
    suspend fun requireNoPending(photo: SynologyPhoto? = null) {
        if (state.value.working) throw SynologyPhotoEditFailure(SynologyPhotoEditProblem.BUSY)
        requireCurrent()
        val user = repository.photoEditIdentity()
        val rows = withContext(Dispatchers.IO) { store.records(owner, user) }
        if (rows.any { it.checkpoint.submitted && !it.checkpoint.finished && (photo == null || it.checkpoint.targets.any { target -> target.id == photo.id }) })
            throw SynologyPhotoEditFailure(SynologyPhotoEditProblem.PENDING)
    }

    fun open(photos: List<SynologyPhoto>, space: SynologyPhotoSpace) {
        if (!job.isActive || !canStart() || photos.size > 100 || photos.map { it.id }.distinct().size != photos.size ||
            photos.any { it.id.profileId != owner.profileId }) return
        if (state.value.working) { mutable.update { it.copy(visible = true) }; return }
        generation++; loader?.cancel(); tagsJob?.cancel(); recordJob?.cancel()
        val token = generation
        val draft = SynologyPhotoEditDraft(photos = photos.toList(), space = space,
            edit = if (photos.isEmpty()) SynologyPhotoEdit.CreateTag("") else SynologyPhotoEdit.Rating(photos.singleOrNull()?.rating ?: 0))
        mutable.update { it.copy(visible = true, draft = draft, activeId = null, tags = emptyList(), moreTags = true,
            loading = photos.size == 1, detailsReady = photos.size != 1, tagsLoading = false, error = null) }
        if (photos.size == 1) loader = scope.launch {
            try {
                requireCurrent()
                val current = repository.details(photos.single())
                if (!SynologyPhotoEditTarget(photos.single()).matches(current, includeTime = true)) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
                if (current(token)) mutable.update { it.copy(detailsReady = true, draft = draft.copy(photos = listOf(current), edit = SynologyPhotoEdit.Rating(current.rating ?: 0))) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        refreshRecords()
    }
    fun dismiss() { mutable.update { it.copy(visible = false) } }
    fun showRecords() { mutable.update { it.copy(visible = true, draft = null, error = null) }; refreshRecords() }
    fun setEdit(edit: SynologyPhotoEdit) {
        if (state.value.working || state.value.loading) return
        mutable.update { it.copy(draft = it.draft?.copy(edit = edit), error = null) }
    }
    fun loadTags(): Job? {
        val draft = state.value.draft ?: return null
        if (!state.value.moreTags || state.value.tagsLoading || state.value.working) return null
        val token = generation
        mutable.update { it.copy(tagsLoading = true, error = null) }
        tagsJob = scope.launch {
            try {
                requireCurrent()
                val offset = state.value.tags.size
                val page = repository.photoTags(draft.space, offset, 100)
                if (!current(token) || state.value.draft?.id != draft.id) return@launch
                val known = state.value.tags.mapTo(mutableSetOf()) { it.id }
                if (page.size > 100 || page.map { it.id }.distinct().size != page.size || page.any { it.id <= 0 || !known.add(it.id) })
                    throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
                mutable.update { it.copy(tags = it.tags + page, moreTags = page.size == 100) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(tagsLoading = false) } }
        }
        return tagsJob
    }

    fun save(): Job? {
        val draft = state.value.draft ?: return null
        if (!canStart() || state.value.working || state.value.loading || !state.value.detailsReady) return null
        return saveDraft(draft)
    }

    fun rotate(photo: SynologyPhoto): Job? {
        if (!job.isActive || !repository.canEditPhotos || !photo.supportsRotation || photo.id.profileId != owner.profileId ||
            !canStart() || state.value.working || state.value.loading || blocks(photo)) return null
        val draft = SynologyPhotoEditDraft(photos = listOf(photo), space = photo.id.space,
            edit = SynologyPhotoEdit.Rotation(photo.orientation!!, photo.width, photo.height))
        return saveDraft(draft)
    }

    fun removeSelection(ids: Set<SynologyPhotoId>) { mutable.update { it.copy(selected = it.selected.filterNot { photo -> photo.id in ids }) } }
    fun updatePhoto(photo: SynologyPhoto) {
        mutable.update { it.copy(selected = it.selected.map { old ->
            if (SynologyPhotoEditTarget(old).matches(photo, includeTime = true)) photo else old
        }) }
    }

    private fun saveDraft(draft: SynologyPhotoEditDraft): Job? {
        val rotation = draft.edit is SynologyPhotoEdit.Rotation
        val token = generation
        mutable.update { it.copy(working = true, error = null, activeId = draft.id,
            rotationId = if (rotation) draft.id else null, rotationPhoto = if (rotation) draft.photos.single().id else null) }
        worker = scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    requireCurrent()
                    val user = repository.photoEditIdentity()
                    val checkpoint = SynologyPhotoEditCheckpoint(profileId = owner.profileId, userId = user, operationId = draft.id,
                        space = draft.space, targets = draft.photos.map(::SynologyPhotoEditTarget), edit = draft.edit)
                    val row = SynologyPhotoEditRecord(owner = owner, checkpoint = checkpoint)
                    store.exclusive(owner, row.id) {
                        requireCurrent(); currentCoroutineContext().ensureActive()
                        store.begin(row)
                        if (current(token) && !rotation) mutable.update { it.copy(draft = null, selecting = false, selected = emptyList(), selectedFolders = emptyList()) }
                        execute(row, token)
                    }
                }
            } catch (error: Exception) { present(error, token) }
            finally { finish(token, rotation) }
        }
        return worker
    }

    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!canStart() || state.value.working || row.checkpoint.finished) return null
        val token = generation
        val rotation = row.checkpoint.edit is SynologyPhotoEdit.Rotation
        mutable.update { it.copy(working = true, activeId = id, draft = null, error = null,
            rotationId = if (rotation) id else null, rotationPhoto = if (rotation) row.checkpoint.targets.single().id else null) }
        worker = scope.launch {
            try { withContext(Dispatchers.IO) { store.exclusive(owner, id) { execute(row, token) } } }
            catch (error: Exception) { present(error, token) }
            finally { finish(token, rotation) }
        }
        return worker
    }

    private suspend fun execute(row: SynologyPhotoEditRecord, token: Long) {
        requireCurrent()
        if (repository.photoEditIdentity() != row.checkpoint.userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        val current = store.get(row.id, owner, row.checkpoint.userId)
        if (!current.checkpoint.submitted) {
            store.requireNoConflict(current)
            beforeWrite(current.checkpoint.targets.map { it.photo() })
        }
        fun save(next: SynologyPhotoEditCheckpoint) {
            requireCurrent()
            val saved = store.save(row.id, owner, row.checkpoint.userId, next)
            if (current(token)) mutable.update { it.copy(records = listOf(saved) + it.records.filterNot { old -> old.id == row.id }) }
        }
        if (current.checkpoint.submitted) repository.reviewPhotoEdit(current.checkpoint, ::save)
        else repository.performPhotoEdit(current.checkpoint, ::save)
    }

    /** 部分完成的重试由用户明确发起；仅保留未完成项，日期仍从原始快照推导。 */
    fun continueRemaining(id: String) {
        val row = state.value.records.firstOrNull { it.id == id } ?: return
        if (state.value.working || row.checkpoint.phase != SynologyPhotoEditPhase.PARTIAL || row.checkpoint.edit is SynologyPhotoEdit.Rotation) return
        val value = row.checkpoint
        val remaining = value.targets.filterIndexed { index, _ -> index !in value.completed }.map { it.photo() }
        if (remaining.isEmpty()) return
        generation++; loader?.cancel(); tagsJob?.cancel(); recordJob?.cancel()
        val edit = if (value.edit is SynologyPhotoEdit.CreateTag) SynologyPhotoEdit.AddTags(listOf(value.createdTag?.id ?: return)) else value.edit
        mutable.update { it.copy(draft = SynologyPhotoEditDraft(photos = remaining, space = remaining.first().id.space, edit = edit),
            visible = true, loading = false, detailsReady = true, tagsLoading = false, tags = emptyList(), moreTags = true, error = null) }
        if (edit is SynologyPhotoEdit.AddTags || edit is SynologyPhotoEdit.RemoveTags) loadTags()
    }
    fun refreshRecords(): Job? {
        if (!job.isActive || state.value.working || recordJob?.isActive == true) return null
        val token = generation
        recordJob = scope.launch { try { reload(token) } catch (error: Exception) { present(error, token) } }
        return recordJob
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working) return null
        val token = generation
        return scope.launch {
            try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reload(token) }
            catch (error: Exception) { present(error, token) }
        }
    }
    private suspend fun finish(token: Long, rotation: Boolean) {
        if (current(token)) {
            val completedId = state.value.activeId
            if (!rotation) mutable.update { it.copy(working = false) }
            try {
                try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { present(error, token) }
                if (current(token)) {
                    if (rotation) onRotationFinished(state.value.records.firstOrNull { it.id == completedId }?.checkpoint)
                    else onCompleted()
                }
            } finally {
                if (rotation && current(token)) mutable.update { it.copy(working = false) }
            }
        }
    }
    private suspend fun reload(token: Long) {
        requireCurrent()
        val user = repository.photoEditIdentity()
        val records = withContext(Dispatchers.IO) { store.records(owner, user) }
        if (current(token)) mutable.update { it.copy(records = records) }
    }
    private fun current(token: Long) = token == generation && job.isActive
    private fun present(error: Exception, token: Long) {
        if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) }
    }
    fun revokeAccess() {
        generation++; worker?.cancel(); loader?.cancel(); tagsJob?.cancel(); recordJob?.cancel()
        mutable.value = SynologyPhotoEditState()
    }
    override fun close() { revokeAccess(); job.cancel() }
}
