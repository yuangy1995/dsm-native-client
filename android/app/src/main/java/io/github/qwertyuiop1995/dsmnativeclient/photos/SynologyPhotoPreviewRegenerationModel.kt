package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoPreviewRegenerationState(
    val visible: Boolean = false, val queue: Boolean = false,
    val space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL,
    val photos: List<SynologyPhoto> = emptyList(), val selected: Set<SynologyPhotoId> = emptySet(),
    val query: String = "", val loading: Boolean = false, val working: Boolean = false,
    val confirmation: SynologyPhotoAlbumCheckpoint? = null, val error: Throwable? = null,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val activeId: String? = null,
) {
    val pending get() = records.any { it.checkpoint.submitted && !it.checkpoint.finished }
    val filtered get() = photos.filter { it.filename.contains(query, ignoreCase = true) }
}

/** 手动预览确认绑定固定原件；恢复记录和前台轮询始终只读。 */
internal class SynologyPhotoPreviewRegenerationModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val canStart: () -> Boolean,
    private val beforeWrite: suspend () -> Unit,
    private val onUpdated: suspend (List<SynologyPhotoEditTarget>) -> Unit,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoPreviewRegenerationState()); val state = mutable.asStateFlow()
    private var generation = 0L; private var viewGeneration = 0L; private var active = false
    private var loader: Job? = null; private var worker: Job? = null; private var poller: Job? = null
    private var cache: File? = null
    fun available(space: SynologyPhotoSpace) = repository.canRegeneratePreviews(space)
    private fun allowed() = job.isActive && canStart() && !state.value.working
    fun open(photos: List<SynologyPhoto>, cache: File) {
        if (!allowed() || photos.isEmpty() || photos.size > 100 || photos.any { !available(it.id.space) } || photos.map { it.id }.distinct().size != photos.size) return
        reset(); this.cache = cache
        mutable.value = SynologyPhotoPreviewRegenerationState(visible = true, space = photos.first().id.space,
            photos = photos.toList(), selected = photos.map { it.id }.toSet())
        load()
    }
    fun openQueue(space: SynologyPhotoSpace, cache: File) {
        if (!allowed() || !available(space)) return
        reset(); this.cache = cache; mutable.value = SynologyPhotoPreviewRegenerationState(visible = true, queue = true, space = space); load()
    }
    fun selectSpace(space: SynologyPhotoSpace) {
        if (!state.value.queue || state.value.space == space || state.value.loading || state.value.confirmation != null) return
        cache?.let { openQueue(space, it) }
    }
    fun search(value: String) { if (!state.value.working && state.value.confirmation == null) mutable.update { it.copy(query = value) } }
    fun toggle(photo: SynologyPhoto) {
        val value = state.value
        if (value.loading || value.working || value.pending || value.confirmation != null || photo !in value.photos) return
        mutable.update { it.copy(selected = if (photo.id in it.selected) it.selected - photo.id else if (it.selected.size < 100) it.selected + photo.id else it.selected) }
    }
    fun refresh(): Job? {
        val pending = state.value.records.firstOrNull { it.checkpoint.submitted && !it.checkpoint.finished }
        return if (pending != null) resume(pending.id) else load()
    }
    fun load(clearError: Boolean = true): Job? {
        if (!state.value.visible || state.value.loading || state.value.working || state.value.confirmation != null) return null
        val token = generation; val view = viewGeneration; val value = state.value
        mutable.update { it.copy(loading = true, error = if (clearError) null else it.error) }
        loader = scope.launch {
            try {
                reloadRecords(token, view)
                // 清理仅限本身份持久记录的独立临时目录，持有写互斥，避免碰到进行中的转换。
                withContext(Dispatchers.IO) { state.value.records.forEach { row -> store.exclusive(owner, row.id) { requireCurrent(); cleanCache(row.id) } } }
                if (value.queue) {
                    val photos = repository.pendingPreviewRegenerations(value.space); check(token, view)
                    mutable.update { it.copy(photos = photos, selected = it.selected.intersect(photos.map { photo -> photo.id }.toSet())) }
                }
            } catch (error: Exception) {
                if (error !is CancellationException && current(token, view)) mutable.update { it.copy(error = error,
                    photos = if (value.queue) emptyList() else it.photos, selected = if (value.queue) emptySet() else it.selected) }
            } finally { if (current(token, view)) { mutable.update { it.copy(loading = false) }; startPolling() } }
        }; return loader
    }
    fun request(): Job? {
        val value = state.value
        if (!allowed() || value.loading || value.pending || value.confirmation != null || value.selected.isEmpty()) return null
        val token = generation; val view = viewGeneration; mutable.update { it.copy(loading = true, error = null) }
        loader = scope.launch {
            try {
                requireCurrent(); beforeWrite()
                val row = repository.preparePreviewRegeneration(value.photos.filter { it.id in value.selected }, value.queue)
                check(token, view); mutable.update { it.copy(confirmation = row) }
            } catch (error: Exception) { if (error !is CancellationException && current(token, view)) mutable.update { it.copy(error = error) } }
            finally { if (current(token, view)) mutable.update { it.copy(loading = false) } }
        }; return loader
    }
    fun cancelConfirmation() { mutable.update { it.copy(confirmation = null) }; startPolling() }
    fun confirm(): Job? {
        val row = state.value.confirmation ?: return null
        if (!allowed() || cache == null) return null
        mutable.update { it.copy(confirmation = null) }
        return perform(row.operationId) {
            beforeWrite(); repository.preparePhotoAlbum(row)
            val record = SynologyPhotoAlbumRecord(owner = owner, checkpoint = row); store.begin(record); execute(record)
        }
    }
    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed() || row.checkpoint.finished || !row.checkpoint.submitted) return null
        return perform(id) { cleanCache(id); execute(store.get(id, owner, row.checkpoint.userId)) }
    }
    private fun perform(id: String, operation: suspend () -> SynologyPhotoAlbumCheckpoint): Job {
        val token = generation; val previous = state.value.records.firstOrNull { it.id == id }?.checkpoint?.completed.orEmpty()
        mutable.update { it.copy(working = true, activeId = id, error = null) }
        worker = scope.launch {
            try {
                val result = withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); operation() } }
                if (current(token)) onUpdated((result.completed - previous).sorted().map { result.targets[it] })
            } catch (error: Exception) { present(error, token) }
            finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reloadRecords(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) { mutable.update { it.copy(working = false) }; if (active && state.value.visible) load(clearError = false) }
                }
            }
        }; return worker!!
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != row.checkpoint.userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        store.requireNoConflict(row); val token = generation
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); val saved = store.save(row.id, owner, row.checkpoint.userId, next)
            if (current(token)) mutable.update { it.copy(records = listOf(saved) + it.records.filterNot { old -> old.id == row.id }) }
        }
        return if (row.checkpoint.submitted) repository.reviewPhotoAlbum(row.checkpoint, ::save)
        else repository.performPreviewRegeneration(row.checkpoint, cache!!, ::save)
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (records().any { it.checkpoint.submitted && !it.checkpoint.finished }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    private suspend fun records() = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action == SynologyPhotoAlbumAction.REGENERATE_PREVIEWS } }
    private suspend fun reloadRecords(token: Long, view: Long = viewGeneration) {
        requireCurrent(); val rows = records(); check(token, view); mutable.update { it.copy(records = rows) }
    }
    private fun cleanCache(id: String) {
        val files = cache?.listFiles { file -> file.name.startsWith("synology-photos-preview-$id-") } ?: return
        files.forEach { if (Files.isSymbolicLink(it.toPath())) Files.delete(it.toPath()) else if (!it.deleteRecursively()) throw IOException("Photo preview temporary cleanup failed") }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working || row.checkpoint.submitted && !row.checkpoint.finished) return null
        val token = generation; return scope.launch {
            try { withContext(Dispatchers.IO) { requireCurrent(); store.exclusive(owner, id) { cleanCache(id) }; store.discard(row) }; reloadRecords(token) }
            catch (error: Exception) { present(error, token) }
        }
    }
    private fun startPolling() {
        if (!active || !state.value.visible || !state.value.pending || poller?.isActive == true) return
        val token = generation; val view = viewGeneration
        poller = scope.launch {
            while (isActive && active && current(token, view) && state.value.visible && state.value.pending) {
                pause(15_000)
                if (!active || !current(token, view) || state.value.working || state.value.loading || state.value.confirmation != null) continue
                state.value.records.firstOrNull { it.checkpoint.submitted && !it.checkpoint.finished }?.let { resume(it.id)?.join() }
            }
        }
    }
    fun activate() { active = true; if (state.value.visible) { load(); startPolling() } }
    fun deactivate() { active = false; viewGeneration++; loader?.cancel(); poller?.cancel(); poller = null; mutable.update { it.copy(loading = false, confirmation = null) } }
    fun dismiss() {
        if (state.value.working) { poller?.cancel(); mutable.update { it.copy(visible = false) }; return }
        reset(); mutable.value = SynologyPhotoPreviewRegenerationState()
    }
    private fun reset() { generation++; val wasActive = active; deactivate(); active = wasActive }
    private fun current(token: Long, view: Long = viewGeneration) = token == generation && view == viewGeneration && job.isActive
    private suspend fun check(token: Long, view: Long = viewGeneration) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token, view)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoPreviewRegenerationState(); cache = null }
    override fun close() { revokeAccess(); job.cancel() }
}
