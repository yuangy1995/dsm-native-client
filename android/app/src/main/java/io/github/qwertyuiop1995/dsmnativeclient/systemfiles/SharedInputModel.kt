package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.asDsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedUpload
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.data.files.isFileMutationPath
import io.github.qwertyuiop1995.dsmnativeclient.data.files.isNormalFileMountType
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class SharedInputState(
    val visible: Boolean = false, val batches: List<SharedBatch> = emptyList(), val copying: Boolean = false,
    val busy: Boolean = false, val profileId: String? = null, val owner: WorkspaceOwner? = null,
    val waitingForLogin: Boolean = false, val path: String = "", val folder: FileItem? = null,
    val locations: Loadable<FilePage> = Loadable.Idle, val loadingMore: Boolean = false, val filter: String = "",
    val failure: DsmFailure? = null, val notice: Int? = null, val conflicts: Set<String>? = null,
) {
    val batch get() = batches.firstOrNull()
    val canUpload get() = owner != null && folder?.let { it.canWrite && it.isDirectory &&
        isFileMutationPath(it.path) && isNormalFileMountType(it.mountPointType) &&
        it.path.split('/').none { part -> part == "#recycle" } } == true
}

/** 宿主拥有尚未选定 NAS 的分享草稿；选定后每次读取和提交固定原账号、原会话。 */
internal class SharedInputModel(
    private val scope: CoroutineScope, private val store: SharedInputStore, private val transfers: TransferStore,
    private val profiles: SecureProfileStore, private val source: (String) -> DsmRepository?,
    private val connect: (String) -> Boolean, private val enqueue: (String, List<PersistedUpload>) -> Unit,
) {
    private val _state = MutableStateFlow(SharedInputState())
    val state = _state.asStateFlow()
    private var generation = 0L
    private var job: Job? = null
    private fun drafts() = store.batches().filterNot { transfers.sharedUploadBatchExists(it.id) }
    init { reload() }

    private fun reload() {
        scope.launch(Dispatchers.IO) {
            try {
                store.reconcile(transfers)
                val drafts = drafts()
                _state.update { it.copy(batches = drafts, visible = it.visible || drafts.isNotEmpty()) }
            } catch (error: Exception) { _state.update { it.copy(notice = R.string.shared_storage_failed) } }
        }
    }
    fun receive(load: () -> List<SharedSource>): Boolean {
        if (_state.value.copying || _state.value.busy) {
            _state.update { it.copy(notice = R.string.shared_receive_busy, visible = true) }; return false
        }
        _state.update { it.copy(copying = true, visible = true, notice = null) }
        scope.launch(Dispatchers.IO) {
            try { store.receive(load()); _state.update { it.copy(batches = drafts()) } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { _state.update { it.copy(notice = R.string.shared_source_unavailable) } }
            finally { _state.update { it.copy(copying = false) } }
        }
        return true
    }
    fun invalidInput() { _state.update { it.copy(visible = true, notice = R.string.shared_source_unavailable) } }
    fun show() { _state.update { it.copy(visible = true) }; if (_state.value.profileId != null) retry() }
    fun hide() { if (!_state.value.busy && !_state.value.copying) _state.update { it.copy(visible = false, conflicts = null, notice = if (it.batches.isEmpty()) null else it.notice) } }
    fun filter(value: String) { _state.update { it.copy(filter = value) } }
    fun selectConnection(id: String) {
        if (_state.value.busy || _state.value.copying) return
        generation++; job?.cancel()
        _state.update { it.copy(profileId = id, owner = null, path = "", folder = null, filter = "",
            locations = Loadable.Idle, loadingMore = false, conflicts = null, failure = null, notice = null) }
        val repo = source(id)
        if (repo == null) {
            if (connect(id)) _state.update { it.copy(waitingForLogin = true, visible = false) }
            else _state.update { it.copy(notice = R.string.shared_connection_unavailable) }
        } else { _state.update { it.copy(owner = repo.owner) }; load("") }
    }
    fun connectionChanged() {
        val state = _state.value
        val id = state.profileId ?: return
        val repo = source(id)
        if (state.waitingForLogin && repo != null) {
            _state.update { it.copy(waitingForLogin = false, visible = true, owner = repo.owner) }; load("")
        } else if (state.owner != null && (repo?.owner != state.owner || !repo.filePermissionAccess.granted)) {
            generation++; job?.cancel(); job = null
            _state.update { it.copy(owner = null, folder = null, path = "", locations = Loadable.Idle,
                busy = false, loadingMore = false, conflicts = null, failure = if (repo?.owner != state.owner) workspaceChangedFailure() else sharedPermissionFailure()) }
        }
    }
    fun enter(item: FileItem) {
        val rows = (_state.value.locations as? Loadable.Ready)?.value?.items.orEmpty()
        if (!item.isDirectory || !item.canRead || item !in rows || _state.value.busy) return
        load(item.path)
    }
    fun up() { if (!_state.value.busy) load(_state.value.path.substringBeforeLast('/', "")) }
    fun retry() {
        if (_state.value.busy || _state.value.copying) return
        val id = _state.value.profileId ?: return
        if (source(id)?.owner != _state.value.owner || _state.value.owner == null) selectConnection(id) else load(_state.value.path)
    }
    fun more() {
        val current = _state.value
        val page = (current.locations as? Loadable.Ready)?.value ?: return
        if (!current.busy && !current.loadingMore && page.items.size < page.total) load(current.path, more = true)
    }
    private fun repository(): DsmRepository {
        val state = _state.value
        return state.profileId?.let(source)?.takeIf { it.owner != null && it.owner == state.owner }
            ?.also { it.requireCurrentOwner() } ?: throw workspaceChangedFailure()
    }
    private suspend fun access(repo: DsmRepository) {
        repo.requireCurrentOwner(); repo.refreshAccess(); repo.requireCurrentOwner()
        if (!repo.filePermissionAccess.granted) throw sharedPermissionFailure()
    }
    private fun load(path: String, more: Boolean = false) {
        val repo = runCatching(::repository).getOrElse { _state.update { it.copy(failure = it.failure ?: workspaceChangedFailure()) }; return }
        val previous = (_state.value.locations as? Loadable.Ready)?.value
        val epoch = ++generation; job?.cancel()
        _state.update { it.copy(path = path, folder = if (more) it.folder else null,
            locations = if (more) it.locations else Loadable.Loading, loadingMore = more, filter = if (more) it.filter else "", failure = null, conflicts = null) }
        job = scope.launch(Dispatchers.IO) {
            try {
                access(repo)
                val folder = if (path.isEmpty()) null else repo.fileInfo(path)?.takeIf { it.isDirectory && it.canRead } ?: throw sharedDestinationFailure()
                val offset = if (more) previous?.items?.size ?: 0 else 0
                val page = if (path.isEmpty()) repo.listShares(offset, 100) else repo.listDirectory(path, offset, 100, fileType = "dir")
                if (page.offset != offset || page.total < offset + page.items.size || page.items.isEmpty() && offset < page.total || page.items.map { it.path }.distinct().size != page.items.size ||
                    page.items.any { !it.isDirectory } || more && page.items.any { item -> previous?.items?.any { it.path == item.path } == true }) throw sharedDestinationFailure()
                repo.requireCurrentOwner()
                if (generation == epoch && _state.value.owner == repo.owner) _state.update { it.copy(folder = folder,
                    locations = Loadable.Ready(page.copy(items = if (more) previous!!.items + page.items else page.items, offset = 0)), loadingMore = false) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { if (generation == epoch) _state.update { it.copy(loadingMore = false,
                locations = if (more) it.locations else Loadable.Failed(error.asDsmFailure()), failure = if (more) error.asDsmFailure() else null) } }
        }
    }
    fun dismissConflict() { if (!_state.value.busy) _state.update { it.copy(conflicts = null) } }
    fun send(replace: Boolean = false) {
        val state = _state.value
        val batch = state.batch ?: return
        val destination = state.folder?.takeIf { state.canUpload } ?: return
        if (state.busy || state.copying || state.loadingMore || state.locations !is Loadable.Ready || replace && state.conflicts == null) return
        val repo = runCatching(::repository).getOrElse { _state.update { it.copy(failure = workspaceChangedFailure()) }; return }
        val epoch = ++generation; job?.cancel()
        _state.update { it.copy(busy = true, failure = null, notice = null) }
        job = scope.launch(Dispatchers.IO) {
            try {
                access(repo)
                if (profiles.session(repo.owner!!.profileId) == null) throw DsmFailure(null, "Sign in again to upload in the background", "Open the connection and sign in again.", kind = DsmErrorKind.NO_SAVED_SESSION)
                if (store.batches().none { it == batch }) throw workspaceStorageFailure()
                val fresh = repo.fileInfo(destination.path) ?: throw sharedDestinationFailure()
                if (!fresh.isDirectory || !fresh.canWrite || fresh.path != destination.path || fresh.mountPointType != destination.mountPointType) throw sharedDestinationFailure()
                val conflicts = repo.existingChildNames(destination.path, batch.files.map { it.name })
                if (conflicts.isNotEmpty() && (!replace || conflicts != state.conflicts)) {
                    if (generation == epoch) _state.update { it.copy(conflicts = conflicts) }
                    return@launch
                }
                val records = batch.files.map { file ->
                    if (store.entry(file.id) != file || !store.file(file.id).isFile || store.file(file.id).length() != file.bytes) throw sharedInputFailure()
                    PersistedUpload(id = file.id, profileId = repo.owner!!.profileId, sourceUri = store.uri(file.id), title = file.name,
                        contentType = file.mime, expectedBytes = file.bytes, destinationPath = destination.path, backupMode = false,
                        overwrite = replace && file.name in conflicts, ownsPersistedReadGrant = false)
                }
                repo.requireCurrentOwner(); currentCoroutineContext().ensureActive()
                withContext(NonCancellable) {
                    records.forEach { profiles.bindRecord(WorkspaceRecordKind.UPLOAD, it.id, repo.owner!!) }
                    repo.requireCurrentOwner()
                    val created = transfers.createSharedUploadsDurably(batch.id, records)
                    if (created) withContext(Dispatchers.Main.immediate) { enqueue(repo.owner!!.profileId, records) }
                    store.handedOff(batch)
                }
                val remaining = drafts()
                _state.update { if (generation == epoch) it.copy(batches = remaining, conflicts = null,
                    notice = R.string.shared_upload_queued, visible = remaining.isNotEmpty()) else it.copy(batches = remaining) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                // 已保存的任务只能从任务页恢复，不能因调度/草稿清理失败重新选择目标并重复发送。
                if (runCatching { transfers.sharedUploadBatchExists(batch.id) }.getOrDefault(false)) {
                    runCatching { store.reconcile(transfers) }
                    _state.update { it.copy(batches = it.batches.filterNot { row -> row.id == batch.id }) }
                }
                if (generation == epoch) _state.update { it.copy(failure = error.asDsmFailure(), conflicts = null) }
            }
            finally { if (generation == epoch) _state.update { it.copy(busy = false) } }
        }
    }
    fun discard() {
        val batch = _state.value.batch ?: return
        if (_state.value.busy || _state.value.copying) return
        _state.update { it.copy(busy = true) }
        scope.launch(Dispatchers.IO) {
            try {
                if (transfers.sharedUploadBatchExists(batch.id)) store.handedOff(batch) else store.discard(batch)
                _state.update { it.copy(batches = drafts(), conflicts = null) }
            } catch (error: Exception) { _state.update { it.copy(failure = error.asDsmFailure()) } }
            finally { _state.update { it.copy(busy = false, visible = it.batches.isNotEmpty()) } }
        }
    }
}

private fun sharedDestinationFailure() = DsmFailure(null, "The destination folder is unavailable", "Refresh the folders or choose another location.", kind = DsmErrorKind.UPLOAD_FAILED)
private fun sharedPermissionFailure() = DsmFailure(null, "Files are unavailable", "Sign in with an account that can use files.", kind = DsmErrorKind.PERMISSION_DENIED)
