package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class SynologyPhotoAlbumPage { MANAGE, FORM, RECORDS }
internal data class SynologyPhotoAlbumDraft(
    val id: String = UUID.randomUUID().toString(), val action: SynologyPhotoAlbumAction,
    val photos: List<SynologyPhoto> = emptyList(), val albumId: Long? = null,
    val album: SynologyPhotoAlbumSnapshot? = null, val name: String = "",
    val originalCondition: SynologyPhotoAlbumCondition? = null,
    val frozen: SynologyPhotoFrozenAlbum? = null,
    val replacesRecordId: String? = null,
    val temporary: SynologyPhotoTemporarySnapshot? = null, val keepCopy: Boolean = false,
    val preservedCopyId: Long? = null,
)
internal data class SynologyPhotoAlbumState(
    val visible: Boolean = false, val page: SynologyPhotoAlbumPage = SynologyPhotoAlbumPage.RECORDS,
    val draft: SynologyPhotoAlbumDraft? = null, val albumId: Long? = null, val access: SynologyPhotoAlbumAccess? = null,
    val frozen: SynologyPhotoFrozenAlbum? = null,
    val sharedContext: Boolean = false,
    val temporaryPreparationId: String? = null, val temporaryCreationId: String? = null,
    val temporaryCancelRequested: Boolean = false,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val albums: List<SynologyPhotoCollection> = emptyList(),
    val moreAlbums: Boolean = true, val albumsLoading: Boolean = false,
    val loading: Boolean = false, val working: Boolean = false, val activeId: String? = null, val error: Throwable? = null,
)

/** 每次确认固定相册和原件快照；恢复页面只有只读刷新，部分失败由用户重新选择剩余项。 */
internal class SynologyPhotoAlbumModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val canStart: () -> Boolean,
    private val beforeWrite: suspend (List<SynologyPhoto>, Long?) -> Unit = { _, _ -> },
    private val sourceAccess: () -> SynologyPhotoAccess? = { null },
    private val onCompleted: (SynologyPhotoAlbumCheckpoint?) -> Unit,
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoAlbumState())
    val state = mutable.asStateFlow()
    val canManageConditions: Boolean get() = repository.canManageConditionAlbums
    val canManageSharing: Boolean get() = repository.canManageAlbumSharing
    val conditions = SynologyPhotoConditionModel(repository, scope, requireCurrent) {
        state.value.draft?.action?.editsCondition == true && !state.value.working && !state.value.loading
    }
    val sharing = SynologyPhotoSharingModel(repository, scope, requireCurrent) {
        state.value.draft?.action == SynologyPhotoAlbumAction.SHARE && !state.value.working && !state.value.loading
    }
    private var generation = 0L
    private var worker: Job? = null
    private var loader: Job? = null
    private var albumLoader: Job? = null
    private var recordLoader: Job? = null

    fun manage(id: Long, sharedContext: Boolean = false) {
        if (!canOpen()) return
        reset()
        mutable.update { it.copy(visible = true, page = SynologyPhotoAlbumPage.MANAGE, albumId = id, access = null, draft = null, sharedContext = sharedContext, error = null) }
        loadAccess(id); refreshRecords()
    }
    fun open(action: SynologyPhotoAlbumAction, photos: List<SynologyPhoto> = emptyList(), albumId: Long? = null, preservedCopyId: Long? = null) {
        if (!canOpen() || photos.size > 100 || photos.any { it.id.profileId != owner.profileId }) return
        reset()
        mutable.update { it.copy(visible = true, page = SynologyPhotoAlbumPage.FORM,
            draft = SynologyPhotoAlbumDraft(action = action, photos = photos.toList(), albumId = albumId, preservedCopyId = preservedCopyId, keepCopy = preservedCopyId != null),
            albumId = albumId, access = null, albums = emptyList(), moreAlbums = albumId == null, error = null) }
        if (albumId != null) loadAccess(albumId)
        else if (action == SynologyPhotoAlbumAction.ADD) loadAlbums()
        else if (action == SynologyPhotoAlbumAction.CREATE_CONDITION) loadConditionCreate()
        refreshRecords()
    }
    fun retryAccess() {
        if (state.value.draft?.action == SynologyPhotoAlbumAction.CREATE_CONDITION) loadConditionCreate()
        else state.value.albumId?.let(::loadAccess)
    }
    private fun conditionSpaces(): List<SynologyPhotoSpace> = sourceAccess()?.let { access ->
        access.spaces.filter { it == SynologyPhotoSpace.PERSONAL || access.canManageSharedSpace }
    }.orEmpty()
    private fun loadConditionCreate() {
        loader?.cancel(); val token = generation
        mutable.update { it.copy(loading = true, error = null) }
        loader = scope.launch {
            try {
                requireCurrent()
                if (!canManageConditions) throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
                val user = repository.photoEditIdentity()
                if (current(token)) conditions.initialize(user, conditionSpaces())
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
    }
    private fun loadAccess(id: Long) {
        loader?.cancel()
        if (state.value.draft?.action == SynologyPhotoAlbumAction.SHARE) sharing.reset()
        val token = generation
        mutable.update { it.copy(loading = true, access = null, frozen = null, error = null) }
        loader = scope.launch {
            try {
                requireCurrent()
                val access = repository.albumAccess(id)
                if (!current(token)) return@launch
                mutable.update { it.copy(access = access) }
                val action = state.value.draft?.action
                if (action == SynologyPhotoAlbumAction.SHARE) {
                    val shared = repository.albumSharing(id)
                    if (shared.album != access.album) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
                    if (current(token)) sharing.initialize(shared)
                }
                val temporary = if (action == SynologyPhotoAlbumAction.STOP_TEMPORARY) repository.temporaryAlbum(id) else null
                if (temporary != null && temporary.album != access.album) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
                val frozen = if (action?.restoresFrozen == true || action == null && access.isOwner && access.album.recoverable) repository.frozenAlbum(id) else null
                val condition = when (action) {
                    SynologyPhotoAlbumAction.SET_CONDITION -> repository.albumCondition(id)
                    SynologyPhotoAlbumAction.REBUILD_FROZEN -> frozen?.rebuildCondition
                    else -> null
                }
                if (condition != null) {
                    val user = repository.photoEditIdentity()
                    if (current(token)) conditions.initialize(user, conditionSpaces(), condition)
                }
                if (frozen != null && frozen.album != access.album) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
                if (current(token)) mutable.update { state -> state.copy(access = access, frozen = frozen,
                    draft = state.draft?.copy(album = access.album, frozen = frozen, temporary = temporary?.snapshot,
                        originalCondition = condition.takeIf { action == SynologyPhotoAlbumAction.SET_CONDITION },
                        name = if (action in setOf(SynologyPhotoAlbumAction.RENAME, SynologyPhotoAlbumAction.REBUILD_FROZEN)) access.album.name else state.draft.name)) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
    }
    fun selectAlbum(id: Long) {
        val draft = state.value.draft ?: return
        if (state.value.working || draft.action != SynologyPhotoAlbumAction.ADD || state.value.albums.none { it.id == id }) return
        mutable.update { it.copy(albumId = id, draft = draft.copy(albumId = id, album = null), error = null) }
        loadAccess(id)
    }
    fun setName(name: String) { if (!state.value.working) mutable.update { it.copy(draft = it.draft?.copy(name = name), error = null) } }
    fun setKeepCopy(keep: Boolean) {
        if (!state.value.working && state.value.draft?.preservedCopyId == null)
            mutable.update { it.copy(draft = it.draft?.copy(keepCopy = keep)) }
    }
    fun dismiss() {
        sharing.clearPassword()
        // 先关闭再开始异步清理，快速失败后的恢复提示不能被迟到的关闭覆盖。
        mutable.update { it.copy(visible = false) }
        if (state.value.temporaryCreationId != null && state.value.working) cancelTemporaryCreation()
        else if (state.value.temporaryPreparationId != null && !state.value.working) cleanupPreparation(state.value.temporaryPreparationId!!)
    }
    fun cancelTemporaryCreation() {
        val id = state.value.temporaryCreationId ?: return
        mutable.update { it.copy(temporaryCancelRequested = true) }
        val token = generation
        scope.launch {
            try { withContext(Dispatchers.IO) { requireCurrent(); store.requestTemporaryCancellation(id, owner) } }
            catch (error: Exception) { present(error, token) }
        }
    }
    fun configureTemporary(id: String) {
        val row = state.value.records.firstOrNull { it.id == id }?.checkpoint ?: return
        if (!row.finished || row.action != SynologyPhotoAlbumAction.CREATE_TEMPORARY || row.createdAlbumId == null || !canOpen()) return
        open(SynologyPhotoAlbumAction.SHARE, albumId = row.createdAlbumId)
        mutable.update { it.copy(temporaryPreparationId = id) }
    }
    fun stopTemporaryRecord(id: String) {
        val row = state.value.records.firstOrNull { it.id == id }?.checkpoint ?: return
        if (!row.finished || state.value.working) return
        open(SynologyPhotoAlbumAction.STOP_TEMPORARY, albumId = row.album?.id ?: row.createdAlbumId,
            preservedCopyId = (row.createdAlbumId ?: row.temporary?.preservedCopyId).takeIf { row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY })
    }
    private fun cleanupPreparation(id: String, allowSharingChanges: Boolean = false): Job? {
        if (!canOpen()) return null
        val token = generation
        mutable.update { it.copy(working = true, draft = null, page = SynologyPhotoAlbumPage.RECORDS, temporaryPreparationId = null, error = null) }
        worker = scope.launch {
            var result: SynologyPhotoAlbumCheckpoint? = null
            try { withContext(Dispatchers.IO) {
                requireCurrent()
                store.requestTemporaryCancellation(id, owner)
                val creation = store.get(id, owner, repository.photoEditIdentity())
                val checkpoint = creation.checkpoint
                val expected = checkpoint.temporaryCreatedSnapshot ?: throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
                val actual = repository.temporaryAlbum(checkpoint.createdAlbumId!!)
                if (actual.album.name != checkpoint.name || actual.album.ownerUserId != checkpoint.userId ||
                    actual.snapshot.membersDigest != expected.membersDigest || actual.snapshot.itemCount != expected.itemCount ||
                    !allowSharingChanges && actual.snapshot.sharing != expected.sharing) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
                val next = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(
                    profileId = owner.profileId, userId = checkpoint.userId, action = SynologyPhotoAlbumAction.STOP_TEMPORARY,
                    album = actual.album, temporary = SynologyPhotoTemporaryChange(actual.snapshot, false)))
                store.exclusive(owner, next.id) {
                    requireCurrent(); store.begin(next)
                    if (current(token)) mutable.update { it.copy(activeId = next.id) }
                    result = execute(next, token)
                    if (result?.phase == SynologyPhotoAlbumPhase.COMPLETED) store.discard(store.get(id, owner, checkpoint.userId))
                }
            } } catch (error: Exception) { present(error, token); if (current(token)) mutable.update { it.copy(visible = true) } }
            finally { finish(token, result) }
        }
        return worker
    }
    fun showRecords() {
        if (!state.value.working) reset()
        mutable.update { it.copy(visible = true, page = SynologyPhotoAlbumPage.RECORDS, draft = null, error = null) }
        refreshRecords()
    }
    fun loadAlbums(): Job? {
        if (state.value.albumsLoading || !state.value.moreAlbums || state.value.working) return null
        val token = generation
        mutable.update { it.copy(albumsLoading = true) }
        albumLoader = scope.launch {
            try {
                requireCurrent()
                val page = repository.addableAlbums(state.value.albums.size, 100)
                if (current(token)) {
                    val seen = state.value.albums.mapTo(mutableSetOf()) { it.id }
                    if (page.size > 100 || page.any { it.id <= 0 || !seen.add(it.id) }) throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
                    mutable.update { it.copy(albums = it.albums + page, moreAlbums = page.size == 100, error = null) }
                }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(albumsLoading = false) } }
        }
        return albumLoader
    }
    fun save(): Job? {
        val draft = state.value.draft ?: return null
        if (!canStart() || state.value.working || state.value.loading ||
            !draft.action.creates && draft.album == null || draft.action.editsCondition && !conditions.state.value.valid ||
            draft.action.restoresFrozen && draft.frozen == null || draft.action == SynologyPhotoAlbumAction.REBUILD_FROZEN && draft.frozen?.canRebuild != true ||
            draft.action == SynologyPhotoAlbumAction.SHARE && !sharing.state.value.valid ||
            draft.action == SynologyPhotoAlbumAction.STOP_TEMPORARY && draft.temporary == null) return null
        val condition = conditions.state.value.condition.takeIf { draft.action.editsCondition }
        val sharingChange = sharing.state.value.change.takeIf { draft.action == SynologyPhotoAlbumAction.SHARE }
        val password = sharing.state.value.password.takeIf { sharingChange?.password == SynologyPhotoSharingPassword.SET }
        sharing.clearPassword()
        val token = generation
        mutable.update { it.copy(working = true, activeId = draft.id, error = null,
            temporaryCreationId = draft.id.takeIf { draft.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY }, temporaryCancelRequested = false) }
        worker = scope.launch {
            var result: SynologyPhotoAlbumCheckpoint? = null
            try {
                withContext(Dispatchers.IO) {
                    requireCurrent()
                    val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(
                        profileId = owner.profileId, userId = repository.photoEditIdentity(), operationId = draft.id,
                        action = draft.action, album = draft.album,
                        name = draft.name.takeIf { draft.action.createsAlbum || draft.action == SynologyPhotoAlbumAction.RENAME },
                        frozenSnapshot = draft.frozen?.snapshot.takeIf { draft.action.restoresFrozen },
                        sharing = sharingChange,
                        temporary = draft.temporary?.let { SynologyPhotoTemporaryChange(it, draft.keepCopy, draft.preservedCopyId) },
                        condition = condition?.copy(names = emptyMap()), originalCondition = draft.originalCondition?.copy(names = emptyMap()),
                        targets = draft.photos.map(::SynologyPhotoEditTarget)))
                    store.exclusive(owner, row.id) {
                        requireCurrent(); currentCoroutineContext().ensureActive()
                        draft.replacesRecordId?.let { id -> store.discard(store.get(id, owner, row.checkpoint.userId)) }
                        store.begin(row)
                        if (current(token)) mutable.update { it.copy(draft = null, page = SynologyPhotoAlbumPage.RECORDS) }
                        result = execute(row, token, password)
                    }
                }
            } catch (error: Exception) { present(error, token) }
            finally { finish(token, result, allowTemporaryCleanup = true) }
        }
        return worker
    }
    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!canStart() || state.value.working || row.checkpoint.finished) return null
        if (!row.checkpoint.submitted && row.checkpoint.sharing?.password == SynologyPhotoSharingPassword.SET) {
            open(SynologyPhotoAlbumAction.SHARE, albumId = row.checkpoint.albumId)
            mutable.update { it.copy(draft = it.draft?.copy(replacesRecordId = id)) }
            return loader
        }
        val token = generation
        mutable.update { it.copy(working = true, activeId = id, error = null) }
        worker = scope.launch {
            var result: SynologyPhotoAlbumCheckpoint? = null
            try { withContext(Dispatchers.IO) { store.exclusive(owner, id) { result = execute(row, token) } } }
            catch (error: Exception) { present(error, token) }
            finally { finish(token, result) }
        }
        return worker
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord, token: Long, password: String? = null): SynologyPhotoAlbumCheckpoint {
        requireCurrent()
        if (repository.photoEditIdentity() != row.checkpoint.userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        val current = store.get(row.id, owner, row.checkpoint.userId)
        if (!current.checkpoint.submitted) {
            store.requireNoConflict(current)
            beforeWrite(current.checkpoint.targets.map { it.photo() }, current.checkpoint.albumId)
        }
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent()
            val saved = store.save(row.id, owner, row.checkpoint.userId, next.copy(temporaryCancelRequested = next.temporaryCancelRequested ||
                state.value.temporaryCreationId == row.id && state.value.temporaryCancelRequested))
            if (current(token)) mutable.update { it.copy(records = listOf(saved) + it.records.filterNot { old -> old.id == row.id }) }
        }
        return if (current.checkpoint.submitted) repository.reviewPhotoAlbum(current.checkpoint, ::save)
            else if (current.checkpoint.action == SynologyPhotoAlbumAction.SHARE) repository.performPhotoSharing(current.checkpoint, password, ::save)
            else repository.performPhotoAlbum(current.checkpoint, ::save)
    }
    fun continueRemaining(id: String) {
        val row = state.value.records.firstOrNull { it.id == id }?.checkpoint ?: return
        if (row.phase != SynologyPhotoAlbumPhase.PARTIAL || state.value.working) return
        val remaining = row.targets.filterIndexed { index, _ -> index !in row.completed }.map { it.photo() }
        if (remaining.isNotEmpty()) open(row.action, remaining, row.albumId)
    }
    suspend fun requireNoPending(photo: SynologyPhoto? = null, albumId: Long? = null) {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }
        if (rows.any { it.checkpoint.submitted && !it.checkpoint.finished &&
                (it.checkpoint.action.isPeople || it.checkpoint.action.isBackground || it.checkpoint.action == SynologyPhotoAlbumAction.SETTINGS || it.checkpoint.action == SynologyPhotoAlbumAction.SHARE_FOLDER || it.checkpoint.action.isFileTask || it.checkpoint.action.isFolder || albumId != null && (it.checkpoint.action.isRequest || albumId in it.checkpoint.affectedAlbumIds) || photo != null &&
                    (it.checkpoint.targets.any { target -> target.id == photo.id } || photo.albumContext?.albumId in it.checkpoint.affectedAlbumIds)) })
            throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    fun refreshRecords(): Job? {
        if (!job.isActive || state.value.working || recordLoader?.isActive == true) return null
        val token = generation
        recordLoader = scope.launch { try { reload(token) } catch (error: Exception) { present(error, token) } }
        return recordLoader
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
    private suspend fun finish(token: Long, row: SynologyPhotoAlbumCheckpoint?, allowTemporaryCleanup: Boolean = false) {
        val preparation = state.value.temporaryPreparationId
        if (current(token)) {
            try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { present(error, token) }
            if (current(token)) {
                val creation = row?.let { finished -> state.value.records.firstOrNull { it.id == finished.operationId }?.checkpoint }
                val cancelled = creation?.temporaryCancelRequested == true || state.value.temporaryCancelRequested
                mutable.update { it.copy(working = false, temporaryCreationId = null, temporaryCancelRequested = false) }
                onCompleted(row)
                if (creation?.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY && creation.phase == SynologyPhotoAlbumPhase.COMPLETED) {
                    if (cancelled) {
                        if (allowTemporaryCleanup) cleanupPreparation(creation.operationId)
                    } else configureTemporary(creation.operationId)
                } else if (preparation != null && row?.action == SynologyPhotoAlbumAction.SHARE && row.phase == SynologyPhotoAlbumPhase.COMPLETED) {
                    if (row.sharing?.access == SynologyPhotoLinkAccess.DISABLED) cleanupPreparation(preparation, allowSharingChanges = true)
                    else {
                        try {
                            withContext(Dispatchers.IO) { requireCurrent(); store.discard(store.get(preparation, owner, row.userId)) }
                            mutable.update { it.copy(temporaryPreparationId = null) }; reload(token)
                        } catch (error: Exception) { present(error, token) }
                    }
                }
            }
        }
    }
    private suspend fun reload(token: Long) {
        requireCurrent()
        val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }
        if (current(token)) mutable.update { it.copy(records = rows.filterNot { record -> record.checkpoint.action.isConcept || record.checkpoint.action.isPeople || record.checkpoint.action == SynologyPhotoAlbumAction.EDIT_PHOTO_FACES || record.checkpoint.action == SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW || record.checkpoint.action == SynologyPhotoAlbumAction.REGENERATE_PREVIEWS || record.checkpoint.action == SynologyPhotoAlbumAction.CODEC_PROMPT || record.checkpoint.action == SynologyPhotoAlbumAction.MAINTAIN_LIBRARY || record.checkpoint.action.isBackground || record.checkpoint.action == SynologyPhotoAlbumAction.SETTINGS || record.checkpoint.action == SynologyPhotoAlbumAction.SHARE_FOLDER || record.checkpoint.action.isRequest || record.checkpoint.action.isFolder || record.checkpoint.action.isFileTask }) }
    }
    private fun canOpen(): Boolean = job.isActive && canStart() && !state.value.working
    private fun reset() { generation++; conditions.reset(); sharing.reset(); loader?.cancel(); albumLoader?.cancel(); recordLoader?.cancel(); mutable.update { it.copy(loading = false, albumsLoading = false, activeId = null, temporaryPreparationId = null, temporaryCreationId = null, temporaryCancelRequested = false) } }
    private fun current(token: Long) = token == generation && job.isActive
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoAlbumState() }
    override fun close() { revokeAccess(); job.cancel() }
}
