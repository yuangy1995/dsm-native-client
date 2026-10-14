package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoFileValidation
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoFolderCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoFileDraft(val checkpoint: SynologyPhotoAlbumCheckpoint, val replaces: String? = null)
internal data class SynologyPhotoFileState(
    val visible: Boolean = false, val recordsPage: Boolean = false, val draft: SynologyPhotoFileDraft? = null,
    val loading: Boolean = false, val working: Boolean = false, val recovering: Boolean = false, val error: Throwable? = null,
    val path: List<SynologyPhotoCollection> = emptyList(), val children: List<SynologyPhotoCollection> = emptyList(),
    val browseSpace: SynologyPhotoSpace? = null,
    val folderAccess: SynologyPhotoFolderAccess? = null, val more: Boolean = false, val browsing: Boolean = false, val browseError: Throwable? = null,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val activeId: String? = null,
)

/** 选择清单在打开时冻结；后台完成只读回查随图库生命周期启停，不重放原写入。 */
internal class SynologyPhotoFileModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val sourceAccess: () -> SynologyPhotoAccess?,
    private val canStart: () -> Boolean, private val beforeWrite: suspend (SynologyPhotoAlbumCheckpoint) -> Unit = {},
    private val onCompleted: (SynologyPhotoAlbumCheckpoint) -> Unit,
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoFileState()); val state = mutable.asStateFlow()
    private var generation = 0L; private var browseGeneration = 0L; private var active = false
    private var loader: Job? = null; private var browser: Job? = null; private var worker: Job? = null
    private var recordLoader: Job? = null; private var recovery: Job? = null
    private var opening: SynologyPhotoAlbumCheckpoint? = null; private var replaces: String? = null
    val canTransfer: Boolean get() = repository.canTransferPhotos
    val canDelete: Boolean get() = repository.canDeleteFolders

    fun open(action: SynologyPhotoAlbumAction, photos: List<SynologyPhoto>, folders: List<SynologyPhotoCollection> = emptyList()) {
        if (!canOpen() || !action.isFileTask || action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS && !canDelete ||
            action != SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS && !canTransfer || photos.size + folders.size !in 1..100) return
        val space = folders.firstOrNull()?.space ?: photos.first().id.space
        val snapshots = folders.map { SynologyPhotoFolderSnapshot(it.id, it.parentId, it.name, it.path ?: "", it.space) }
        reset(); opening = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 0, action = action,
            targets = photos.map(::SynologyPhotoEditTarget), files = SynologyPhotoFileCheckpoint(space, snapshots))
        mutable.value = SynologyPhotoFileState(visible = true); load()
    }
    fun load(): Job? {
        val original = opening ?: return null
        if (state.value.working || state.value.loading || !state.value.visible) return null
        val token = generation; mutable.update { it.copy(loading = true, error = null, draft = null) }
        loader = scope.launch {
            try {
                requireCurrent()
                val user = repository.photoEditIdentity()
                if (replaces != null && original.userId != user) denied()
                val files = original.files!!
                if (files.space !in sourceAccess()?.spaces.orEmpty()) denied()
                val duplicate = if (original.action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS) null else files.duplicate ?: repository.transferDuplicate()
                val row = original.copy(userId = user, files = files.copy(duplicate = duplicate, destination = null))
                if (row.action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS) repository.preparePhotoAlbum(row)
                else {
                    if (row.targets.any { it.id.profileId != owner.profileId || it.id.space != files.space } ||
                        files.folders.any { it.space != files.space }) changed()
                    if (files.folders.isNotEmpty()) SynologyPhotoFileValidation.parent(files.folders)
                }
                check(token); mutable.update { it.copy(draft = SynologyPhotoFileDraft(row, replaces)) }
                if (row.action != SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS) browseRoot(files.space)
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return loader
    }
    val destinationSpaces: List<SynologyPhotoSpace> get() {
        val row = state.value.draft?.checkpoint ?: return emptyList()
        return sourceAccess()?.spaces.orEmpty().filter { row.action != SynologyPhotoAlbumAction.MOVE_ITEMS ||
            row.files!!.space != SynologyPhotoSpace.SHARED || it == SynologyPhotoSpace.SHARED }
    }
    fun duplicate(value: SynologyPhotoTransferDuplicate) {
        if (state.value.working || state.value.recovering) return
        mutable.update { state -> state.copy(error = null, draft = state.draft?.let { it.copy(checkpoint = it.checkpoint.copy(files = it.checkpoint.files!!.copy(duplicate = value))) }) }
    }
    fun browseRoot(space: SynologyPhotoSpace): Job? {
        if (space !in destinationSpaces || state.value.working || state.value.browsing) return null
        return browse(emptyList(), space)
    }
    fun browse(path: List<SynologyPhotoCollection> = state.value.path, space: SynologyPhotoSpace? = state.value.browseSpace, more: Boolean = false): Job? {
        val space = space ?: return null
        if (state.value.draft == null || state.value.working || state.value.browsing || space !in destinationSpaces) return null
        if (path.isNotEmpty() && (path.any { it.space != space } || more && path != state.value.path)) return null
        val token = generation; val browsing = ++browseGeneration
        val offset = if (more) state.value.children.size else 0
        mutable.update { it.copy(browsing = true, browseError = null, folderAccess = null, path = path, browseSpace = space,
            children = if (more) it.children else emptyList(), more = more && it.more) }
        browser = scope.launch {
            try {
                requireCurrent()
                val destinationPath = path.ifEmpty { listOf(repository.rootFolder(space)) }
                val target = destinationPath.last(); val actual = repository.folderAccess(space, target.id)
                if (target.path != null && target.path != actual.folder.path || target.parentId != null && target.parentId != actual.folder.parentId) changed()
                val children = repository.folders(space, target.id, offset, 100)
                if (children.size > 100 || children.any { it.space != space || it.parentId != target.id || it.path == null || !SynologyPhotoFolderCodec.validPath(it.path) } ||
                    (state.value.children + children).map { it.id }.distinct().size != offset + children.size) changed()
                check(token); if (browsing != browseGeneration) return@launch
                mutable.update { it.copy(path = destinationPath.dropLast(1) + actual.collection(), folderAccess = actual,
                    children = it.children + children, more = children.size == 100) }
            } catch (error: Exception) {
                if (error !is CancellationException && current(token) && browsing == browseGeneration) mutable.update { it.copy(browseError = error) }
            } finally { if (current(token) && browsing == browseGeneration) mutable.update { it.copy(browsing = false) } }
        }
        return browser
    }
    fun enter(folder: SynologyPhotoCollection) { if (folder in state.value.children) browse(state.value.path + folder) }
    fun backTo(index: Int) { if (index in 0 until state.value.path.lastIndex) browse(state.value.path.take(index + 1)) }
    val canSave: Boolean get() {
        val row = state.value.draft?.checkpoint ?: return false
        if (!canOpen() || state.value.loading || state.value.browsing || state.value.browseError != null) return false
        return row.action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS || state.value.folderAccess?.let {
            it.canUpload && SynologyPhotoFileValidation.accepts(row, it.folder)
        } == true
    }
    fun save(overwriteConfirmed: Boolean = false): Job? {
        val draft = state.value.draft ?: return null; if (!canSave) return null
        val input = draft.checkpoint
        if (input.files!!.duplicate == SynologyPhotoTransferDuplicate.OVERWRITE && !overwriteConfirmed) return null
        val checkpoint = input.copy(files = input.files.copy(destination = state.value.folderAccess?.folder.takeUnless { input.action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS }))
        return perform(checkpoint.operationId, false) {
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = checkpoint)
            beforeWrite(checkpoint); repository.preparePhotoAlbum(checkpoint)
            draft.replaces?.let { store.discard(store.get(it, owner, row.checkpoint.userId)) }
            store.begin(row); mutable.update { it.copy(draft = null, recordsPage = true) }
            execute(row)
        }
    }
    fun showRecords() {
        if (state.value.working || state.value.recovering) { mutable.update { it.copy(visible = true, recordsPage = true) }; return }
        reset(); mutable.update { it.copy(visible = true, recordsPage = true, draft = null, error = null) }; refreshRecords()
    }
    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!canOpen() || row.checkpoint.finished) return null
        if (!row.checkpoint.submitted) {
            reset(); opening = row.checkpoint.copy(operationId = java.util.UUID.randomUUID().toString()); replaces = row.id
            mutable.update { it.copy(visible = true, recordsPage = false, draft = null, error = null) }; return load()
        }
        return perform(id, true) { execute(store.get(id, owner, row.checkpoint.userId)) }
    }
    private fun perform(id: String, reviewing: Boolean, operation: suspend () -> SynologyPhotoAlbumCheckpoint): Job {
        val token = generation; mutable.update { it.copy(working = !reviewing, recovering = reviewing, activeId = id, error = null) }
        worker = scope.launch {
            var result: SynologyPhotoAlbumCheckpoint? = null
            try { result = withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); operation() } }; check(token) }
            catch (error: Exception) { present(error, token) }
            finally { if (current(token)) {
                try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { present(error, token) }
                if (current(token)) {
                    mutable.update { it.copy(working = false, recovering = false) }
                    result?.let(onCompleted); startRecovery()
                }
            } }
        }
        return worker!!
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != row.checkpoint.userId) denied()
        store.requireNoConflict(row)
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); store.save(row.id, owner, row.checkpoint.userId, next)
            mutable.update { it.copy(records = listOf(row.copy(checkpoint = next)) + it.records.filterNot { old -> old.id == row.id }) }
        }
        return if (row.checkpoint.submitted) repository.reviewPhotoAlbum(row.checkpoint, ::save) else repository.performPhotoAlbum(row.checkpoint, ::save)
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any { it.checkpoint.action.isFileTask && it.checkpoint.submitted && !it.checkpoint.finished })
            throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    fun refreshRecords(): Job? {
        if (state.value.working || state.value.recovering || recordLoader?.isActive == true) return null
        val token = generation
        recordLoader = scope.launch { try { reload(token); startRecovery() } catch (error: Exception) { present(error, token) } }
        return recordLoader
    }
    private suspend fun reload(token: Long) {
        requireCurrent(); val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action.isFileTask } }
        if (current(token)) mutable.update { it.copy(records = rows) }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working || state.value.recovering) return null
        val token = generation
        return scope.launch { try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reload(token) } catch (error: Exception) { present(error, token) } }
    }
    fun activate() { active = true; refreshRecords() }
    private fun startRecovery() {
        if (!active || recovery?.isActive == true || state.value.records.none { it.checkpoint.submitted && !it.checkpoint.finished && it.checkpoint.files?.taskId != null }) return
        recovery = scope.launch {
            var attempts = 0
            while (active && isActive) {
                delay(if (attempts++ < 6) 2_000 else 15_000)
                if (state.value.working || state.value.recovering) continue
                val pending = state.value.records.firstOrNull { it.checkpoint.submitted && !it.checkpoint.finished && it.checkpoint.files?.taskId != null } ?: break
                if (!canStart()) continue
                resume(pending.id)?.join()
            }
        }
    }
    fun deactivate() { active = false; recovery?.cancel(); recovery = null; if (state.value.recovering) worker?.cancel() }
    fun dismiss() { if (state.value.working || state.value.recovering) { mutable.update { it.copy(visible = false) }; return }; reset(); mutable.update { it.copy(visible = false, draft = null, error = null) } }
    private fun reset() { generation++; browseGeneration++; loader?.cancel(); browser?.cancel(); recordLoader?.cancel(); opening = null; replaces = null }
    private fun canOpen() = job.isActive && canStart() && !state.value.working && !state.value.recovering
    private fun current(token: Long) = token == generation && job.isActive
    private fun check(token: Long) { requireCurrent(); if (!current(token)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { deactivate(); reset(); worker?.cancel(); mutable.value = SynologyPhotoFileState() }
    override fun close() { revokeAccess(); job.cancel() }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
