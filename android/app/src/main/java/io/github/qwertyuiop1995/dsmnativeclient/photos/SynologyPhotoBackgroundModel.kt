package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class SynologyPhotoBackgroundFilter { ALL, ACTIVE, FINISHED }
internal data class SynologyPhotoBackgroundState(
    val visible: Boolean = false, val recordsPage: Boolean = false, val loaded: Boolean = false,
    val filter: SynologyPhotoBackgroundFilter = SynologyPhotoBackgroundFilter.ALL,
    val tasks: List<SynologyPhotoBackgroundTask> = emptyList(), val loading: Boolean = false, val listError: Throwable? = null,
    val confirmation: SynologyPhotoAlbumCheckpoint? = null, val preparing: Boolean = false,
    val working: Boolean = false, val reviewing: Boolean = false, val error: Throwable? = null,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val activeId: String? = null,
    val errorTask: SynologyPhotoBackgroundTask? = null, val errorsLoading: Boolean = false,
    val errors: List<SynologyPhotoBackgroundError> = emptyList(), val errorsFailure: Throwable? = null,
    val navigating: Boolean = false,
) {
    val visibleTasks: List<SynologyPhotoBackgroundTask> get() = tasks.filter { task -> when (filter) {
        SynologyPhotoBackgroundFilter.ALL -> true
        SynologyPhotoBackgroundFilter.ACTIVE -> task.snapshot.status in setOf(SynologyPhotoBackgroundStatus.WAITING, SynologyPhotoBackgroundStatus.PROCESSING, SynologyPhotoBackgroundStatus.ABORTING)
        SynologyPhotoBackgroundFilter.FINISHED -> task.snapshot.status == SynologyPhotoBackgroundStatus.DONE
    } }
    val hasPending: Boolean get() = records.any { it.checkpoint.submitted && !it.checkpoint.finished }
}

/** 页面刷新与NAS任务分离；关闭只停止读取，控制回执丢失后仅恢复原操作。 */
internal class SynologyPhotoBackgroundModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val canStart: () -> Boolean,
    private val beforeWrite: suspend () -> Unit = {}, private val onCompleted: () -> Unit = {},
    private val onOpenTarget: suspend (List<SynologyPhotoCollection>) -> Unit = {},
    private val pause: suspend (Long) -> Unit = { delay(it) },
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoBackgroundState()); val state = mutable.asStateFlow()
    private var active = false; private var generation = 0L; private var viewGeneration = 0L; private var detailGeneration = 0L
    private var loader: Job? = null; private var poller: Job? = null; private var preparer: Job? = null
    private var worker: Job? = null; private var recordLoader: Job? = null; private var details: Job? = null; private var navigator: Job? = null
    val canControl: Boolean get() = active && canStart() && !state.value.working && !state.value.preparing &&
        !state.value.navigating && !state.value.hasPending && state.value.confirmation == null

    fun open() {
        if (!active || !job.isActive) return
        mutable.update { it.copy(visible = true, recordsPage = false) }; refresh(); startPolling()
    }
    fun filter(value: SynologyPhotoBackgroundFilter) { mutable.update { it.copy(filter = value) } }
    fun refresh(): Job? {
        if (!active || !state.value.visible || state.value.recordsPage || loader?.isActive == true) return null
        val token = generation; val view = viewGeneration; mutable.update { it.copy(loading = true, listError = null) }
        loader = scope.launch {
            try {
                requireCurrent(); val rows = repository.backgroundTasks(); checkView(token, view)
                if (rows.any { it.profileId != owner.profileId } || rows.map { it.id }.distinct().size != rows.size) changed()
                mutable.update { it.copy(tasks = rows, loaded = true) }
                reload(token)
            } catch (error: Exception) {
                if (error !is CancellationException && currentView(token, view)) mutable.update { it.copy(listError = error) }
            } finally { if (currentView(token, view)) mutable.update { it.copy(loading = false) } }
        }
        return loader
    }
    private fun startPolling() {
        if (poller?.isActive == true || !active || !state.value.visible) return
        poller = scope.launch {
            while (isActive && active && state.value.visible) {
                pause(3_000)
                if (!state.value.working && !state.value.preparing && state.value.confirmation == null && canStart()) {
                    state.value.records.firstOrNull { it.checkpoint.submitted && !it.checkpoint.finished }?.let { review(it.id)?.join() }
                }
                if (!state.value.recordsPage && !state.value.working && state.value.confirmation == null) refresh()?.join()
            }
        }
    }
    fun prepareStop(task: SynologyPhotoBackgroundTask): Job? = prepare(SynologyPhotoAlbumAction.STOP_TASK, listOf(task))
    fun prepareClear(tasks: List<SynologyPhotoBackgroundTask>): Job? = prepare(SynologyPhotoAlbumAction.CLEAR_TASKS, tasks)
    private fun prepare(action: SynologyPhotoAlbumAction, tasks: List<SynologyPhotoBackgroundTask>): Job? {
        if (!canControl || tasks.isEmpty() || tasks.any { candidate -> state.value.tasks.none { it.sameIdentity(candidate) } } ||
            (if (action == SynologyPhotoAlbumAction.STOP_TASK) tasks.size != 1 || !tasks.single().snapshot.canStop else tasks.any { !it.snapshot.canClear })) return null
        val token = generation; val view = viewGeneration
        val row = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = tasks.first().userId, action = action,
            background = SynologyPhotoBackgroundCheckpoint(tasks.map { it.snapshot.copy() }))
        mutable.update { it.copy(preparing = true, error = null) }
        preparer = scope.launch {
            try {
                requireCurrent(); if (tasks.any { it.profileId != owner.profileId || it.userId != row.userId } || repository.photoEditIdentity() != row.userId) denied()
                beforeWrite(); withContext(Dispatchers.IO) { store.requireNoConflict(SynologyPhotoAlbumRecord(owner = owner, checkpoint = row)) }
                repository.preparePhotoAlbum(row); checkView(token, view)
                mutable.update { it.copy(confirmation = row) }
            } catch (error: Exception) { if (currentView(token, view)) present(error, token) }
            finally { if (currentView(token, view)) mutable.update { it.copy(preparing = false) } }
        }
        return preparer
    }
    fun cancelConfirmation() { if (!state.value.working) mutable.update { it.copy(confirmation = null) } }
    fun confirm(): Job? {
        val checkpoint = state.value.confirmation ?: return null
        if (!active || !canStart() || state.value.working || state.value.preparing || state.value.hasPending) return null
        mutable.update { it.copy(confirmation = null) }
        return perform(checkpoint.operationId, false) {
            requireCurrent(); beforeWrite()
            repository.preparePhotoAlbum(checkpoint)
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = checkpoint)
            store.begin(row); execute(row)
        }
    }
    fun showRecords() {
        if (!active) return
        stopReads(); mutable.update { it.copy(visible = true, recordsPage = true, confirmation = null) }
        refreshRecords(); startPolling()
    }
    fun showTasks() { mutable.update { it.copy(recordsPage = false) }; refresh() }
    fun review(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!active || !canStart() || state.value.working || !row.checkpoint.submitted || row.checkpoint.finished) return null
        return perform(id, true) { execute(store.get(id, owner, row.checkpoint.userId)) }
    }
    private fun perform(id: String, reviewing: Boolean, operation: suspend () -> SynologyPhotoAlbumCheckpoint): Job {
        val token = generation; mutable.update { it.copy(working = true, reviewing = reviewing, activeId = id, error = null) }
        worker = scope.launch {
            var result: SynologyPhotoAlbumCheckpoint? = null
            try { result = withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); operation() } } }
            catch (error: Exception) { present(error, token) }
            finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) mutable.update { it.copy(working = false, reviewing = false) }
                }
            }
            if (current(token)) {
                if (result?.finished == true) onCompleted()
                refresh()
            }
        }
        return worker!!
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != row.checkpoint.userId) denied()
        store.requireNoConflict(row)
        val token = generation
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); val saved = store.save(row.id, owner, row.checkpoint.userId, next)
            if (current(token)) mutable.update { it.copy(records = listOf(saved) + it.records.filterNot { old -> old.id == row.id }) }
        }
        return if (row.checkpoint.submitted) repository.reviewPhotoAlbum(row.checkpoint, ::save) else repository.performPhotoAlbum(row.checkpoint, ::save)
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        store.requireNoPendingBackground(owner, repository::photoEditIdentity, requireCurrent)
    }
    fun refreshRecords(): Job? {
        if (state.value.working || recordLoader?.isActive == true) return null
        val token = generation
        recordLoader = scope.launch { try { reload(token) } catch (error: Exception) { present(error, token) } }
        return recordLoader
    }
    private suspend fun reload(token: Long) {
        requireCurrent()
        val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action.isBackground } }
        check(token); mutable.update { it.copy(records = rows) }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working || row.checkpoint.submitted && !row.checkpoint.finished) return null
        val token = generation
        return scope.launch { try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reload(token) } catch (error: Exception) { present(error, token) } }
    }
    fun openErrors(task: SynologyPhotoBackgroundTask): Job? {
        if (!active || task.errors == 0L || state.value.tasks.none { it.sameIdentity(task) }) return null
        closeErrors(); mutable.update { it.copy(errorTask = task) }; return loadErrors()
    }
    fun loadErrors(): Job? {
        val task = state.value.errorTask ?: return null
        if (!active || details?.isActive == true) return null
        val token = generation; val detail = detailGeneration
        mutable.update { it.copy(errorsLoading = true, errorsFailure = null) }
        details = scope.launch {
            try {
                requireCurrent(); val values = repository.backgroundTaskErrors(task); check(token)
                if (detail == detailGeneration) mutable.update { it.copy(errors = values) }
            } catch (error: Exception) {
                if (error !is CancellationException && current(token) && detail == detailGeneration) mutable.update { it.copy(errorsFailure = error) }
            } finally { if (current(token) && detail == detailGeneration) mutable.update { it.copy(errorsLoading = false) } }
        }
        return details
    }
    fun closeErrors() { detailGeneration++; details?.cancel(); details = null; mutable.update { it.copy(errorTask = null, errors = emptyList(), errorsLoading = false, errorsFailure = null) } }
    fun openTarget(task: SynologyPhotoBackgroundTask): Job? {
        if (!canControl || !task.canOpenTarget || state.value.tasks.none { it.sameIdentity(task) }) return null
        val token = generation; val view = viewGeneration; mutable.update { it.copy(navigating = true, error = null) }
        navigator = scope.launch {
            try {
                requireCurrent(); val path = repository.backgroundTaskTarget(task); checkView(token, view)
                if (!active || !canStart()) throw CancellationException()
                onOpenTarget(path); checkView(token, view); dismiss()
            } catch (error: Exception) { if (currentView(token, view)) present(error, token) }
            finally { if (currentView(token, view)) mutable.update { it.copy(navigating = false) } }
        }
        return navigator
    }
    fun activate() { active = true; refreshRecords(); if (state.value.visible) { refresh(); startPolling() } }
    fun deactivate() {
        active = false; stopReads()
        if (state.value.reviewing) worker?.cancel()
    }
    private fun stopReads() {
        viewGeneration++
        poller?.cancel(); poller = null; loader?.cancel(); loader = null; preparer?.cancel(); navigator?.cancel(); recordLoader?.cancel(); closeErrors()
        mutable.update { it.copy(loading = false, preparing = false, navigating = false, confirmation = null) }
    }
    fun dismiss() { stopReads(); mutable.update { it.copy(visible = false) } }
    private fun current(token: Long) = token == generation && job.isActive
    private suspend fun check(token: Long) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token)) throw CancellationException() }
    private fun currentView(token: Long, view: Long) = current(token) && active && view == viewGeneration
    private suspend fun checkView(token: Long, view: Long) { check(token); if (!currentView(token, view)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { deactivate(); generation++; worker?.cancel(); mutable.value = SynologyPhotoBackgroundState() }
    override fun close() { revokeAccess(); job.cancel() }
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
}

/** 能力临时缺失不消除已发送事实；入口未创建时仍须读取同一份持久记录。 */
internal suspend fun SynologyPhotoAlbumStore.requireNoPendingBackground(owner: WorkspaceOwner?, identity: suspend () -> Long, requireCurrent: () -> Unit) {
    if (owner == null) return
    requireCurrent()
    if (withContext(Dispatchers.IO) { records(owner, identity()) }.any {
        it.checkpoint.action.isBackground && it.checkpoint.submitted && !it.checkpoint.finished
    }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    currentCoroutineContext().ensureActive(); requireCurrent()
}
