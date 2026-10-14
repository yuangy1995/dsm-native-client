package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.CrossNasTransferEndpoint
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.background.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class CrossNasTransferViewState(
    val visible: Boolean = false, val records: Loadable<List<CrossNasTransferRecord>> = Loadable.Idle,
    val selectedId: String? = null, val busy: Boolean = false, val reading: Boolean = false,
    val completedBytes: Long = 0, val totalBytes: Long = 0,
    val confirmRemoval: Boolean = false, val failure: DsmFailure? = null,
) { val selected get() = (records as? Loadable.Ready)?.value?.singleOrNull { it.id == selectedId } }

/** 跨 NAS 操作仍属于原工作区；页面刷新只读取清单/结果，继续与删源均需明确操作。 */
internal class CrossNasTransferFeatureModel(
    private val scope: CoroutineScope, private val store: CrossNasTransferStore,
    private val source: () -> CrossNasTransferEndpoint?,
    private val resolveTarget: suspend (WorkspaceOwner) -> CrossNasTransferEndpoint,
    private val allowed: () -> Boolean, private val onBusy: (Boolean) -> Unit,
    private val onCreated: () -> Unit, private val onSourceChanged: () -> Unit,
    private val queue: CrossNasTransferQueue = CrossNasTransferQueue(store),
    private val profileForOwner: (WorkspaceOwner) -> NasProfile? = { null },
    private val execution: WorkspaceExecution? = null,
) {
    private val _state = MutableStateFlow(CrossNasTransferViewState())
    val state = _state.asStateFlow()
    private var bound: CrossNasTransferEndpoint? = null
    private var job: Job? = null
    private var generation = 0L
    private var executionLease: WorkspaceExecutionLease? = null
    fun connectionProfile(owner: WorkspaceOwner): NasProfile? = profileForOwner(owner)
    fun activate() {
        val endpoint = source()?.takeIf { allowed() } ?: return
        if (bound?.owner == endpoint.owner) return
        invalidate(); bound = endpoint; loadRecords()
    }
    fun show(id: String? = null) {
        activate(); if (current() == null || _state.value.busy) return
        _state.update { it.copy(visible = true, selectedId = id, confirmRemoval = false, failure = null) }
        loadRecords()
    }
    fun dismiss() { if (!_state.value.busy) _state.update { it.copy(visible = false, selectedId = null, confirmRemoval = false, failure = null) } }
    fun backToList() { if (!_state.value.busy) _state.update { it.copy(selectedId = null, confirmRemoval = false, failure = null) } }
    fun start(target: CrossNasTransferEndpoint, items: List<FileItem>, destination: FileItem,
        move: Boolean, sourceName: String, targetName: String): Boolean {
        activate(); val endpoint = current() ?: return false
        if (_state.value.busy) return false
        _state.update { it.copy(visible = true, selectedId = null) }
        launchOperation(endpoint) { changed ->
            val row = queue.create(endpoint, target, items, destination, move, sourceName, targetName)
            if (current() === endpoint) {
                _state.update { it.copy(visible = true, selectedId = row.id) }; onCreated()
            }
            changed(row)
            queue.copy(row.id, endpoint, target, onProgress = progressFor(endpoint), onChanged = changed)
        }
        return true
    }
    fun continueCopy() {
        val endpoint = current() ?: return
        val row = _state.value.selected?.takeIf { it.canContinueCopy } ?: return
        if (_state.value.busy || _state.value.reading) return
        launchOperation(endpoint) { changed -> queue.copy(row.id, endpoint, resolveTarget(row.targetOwner), progressFor(endpoint), changed) }
    }
    fun requestRemoval() {
        if (current() != null && !_state.value.busy && !_state.value.reading && _state.value.selected?.canRemoveSource == true)
            _state.update { it.copy(confirmRemoval = true, failure = null) }
    }
    fun dismissRemoval() { _state.update { it.copy(confirmRemoval = false) } }
    fun confirmRemoval() {
        val endpoint = current() ?: return
        val row = _state.value.selected?.takeIf { it.canRemoveSource } ?: return
        if (!_state.value.confirmRemoval || _state.value.busy || _state.value.reading) return
        launchOperation(endpoint) { changed ->
            queue.removeSource(row.id, endpoint, resolveTarget(row.targetOwner), confirmed = true, onChanged = changed)
        }
    }
    fun keepOriginals() {
        val endpoint = current() ?: return
        val row = _state.value.selected?.takeIf { it.canRemoveSource } ?: return
        if (_state.value.busy || _state.value.reading) return
        launchOperation(endpoint) { changed -> changed(withContext(Dispatchers.IO) { store.keepOriginals(row) }) }
    }
    fun pause() { if (_state.value.busy) job?.cancel() }
    fun refresh() {
        val endpoint = current() ?: return
        if (_state.value.busy || _state.value.reading) return
        val row = _state.value.selected
        if (row == null) { loadRecords(); return }
        job?.cancel(); val epoch = ++generation
        _state.update { it.copy(reading = true, failure = null, confirmRemoval = false) }
        job = scope.launch {
            try {
                val result = suspendRunCatching { queue.review(row.id, endpoint, resolveTarget(row.targetOwner)) }
                val rows = readRows(endpoint)
                if (!isCurrent(endpoint, epoch)) return@launch
                _state.update { it.copy(records = rows, reading = false, failure = result.exceptionOrNull()?.asDsmFailure()) }
            } finally { if (isCurrent(endpoint, epoch)) _state.update { it.copy(reading = false) } }
        }
    }
    fun authorizationChanged() { if (bound != null && current() == null) invalidate() }
    fun invalidate() {
        generation++; job?.cancel(); job = null; bound = null
        if (_state.value.busy) onBusy(false)
        _state.value = CrossNasTransferViewState()
    }
    private fun loadRecords() {
        val endpoint = current() ?: return
        if (_state.value.busy) return
        job?.cancel(); val epoch = ++generation
        _state.update { it.copy(records = Loadable.Loading, reading = true, failure = null) }
        job = scope.launch {
            val rows = readRows(endpoint)
            if (isCurrent(endpoint, epoch)) _state.update { it.copy(records = rows, reading = false) }
        }
    }
    private suspend fun readRows(endpoint: CrossNasTransferEndpoint): Loadable<List<CrossNasTransferRecord>> = try {
        Loadable.Ready(withContext(Dispatchers.IO) { store.records(endpoint.owner) })
    } catch (cancelled: CancellationException) { throw cancelled }
    catch (error: Exception) { Loadable.Failed(error.asDsmFailure()) }
    private fun launchOperation(endpoint: CrossNasTransferEndpoint,
        operation: suspend ((CrossNasTransferRecord) -> Unit) -> Unit) {
        job?.cancel(); val epoch = ++generation
        _state.update { it.copy(busy = true, reading = false, confirmRemoval = false, completedBytes = 0, totalBytes = 0, failure = null) }
        onBusy(true)
        job = scope.launch {
            var failure: DsmFailure? = null
            var lease: WorkspaceExecutionLease? = null
            try {
                lease = execution?.begin(endpoint.owner, WorkspaceExecutionActivity.CROSS_NAS); executionLease = lease
                operation { row ->
                if (isCurrent(endpoint, epoch)) _state.update { old ->
                    val rows = (old.records as? Loadable.Ready)?.value.orEmpty()
                    old.copy(records = Loadable.Ready((rows.filterNot { it.id == row.id } + row).sortedByDescending { it.createdAtSeconds }))
                }
            } } catch (_: CancellationException) { /* 取消保留原记录；只在用户再次操作后继续。 */ }
            catch (error: Exception) { failure = error.asDsmFailure() }
            finally {
                lease?.finish(); if (executionLease === lease) executionLease = null
                withContext(NonCancellable) {
                    val rows = readRows(endpoint)
                    if (generation == epoch && bound === endpoint) {
                        if (current() === endpoint) {
                            _state.update { it.copy(busy = false, records = rows, failure = failure) }
                            onSourceChanged()
                        } else { bound = null; _state.value = CrossNasTransferViewState() }
                        onBusy(false)
                    }
                }
            }
        }
    }
    private fun progressFor(endpoint: CrossNasTransferEndpoint): (Long, Long) -> Unit {
        val epoch = generation
        return { completed, total -> if (isCurrent(endpoint, epoch)) _state.update {
            executionLease?.update(completed, total)
            if (it.busy) it.copy(completedBytes = completed, totalBytes = total) else it
        } }
    }
    private fun current(): CrossNasTransferEndpoint? = bound?.takeIf { allowed() && source()?.owner == it.owner }
    private fun isCurrent(endpoint: CrossNasTransferEndpoint, epoch: Long) = generation == epoch && current() === endpoint
}

/** 仅原身份可恢复目标连接；重新登录允许新会话，改账号后不得继续旧任务。 */
internal suspend fun resolveCrossNasTarget(owner: WorkspaceOwner,
    store: io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore,
    repositories: MutableMap<String, io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository>,
    restore: suspend (NasProfile, DsmSession) -> io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository,
): io.github.qwertyuiop1995.dsmnativeclient.data.RepositoryCrossNasTransferEndpoint {
    val profile = store.profileForOwner(owner) ?: throw io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure()
    val cached = repositories[profile.id]?.takeIf { it.owner?.hasSameIdentity(owner) == true && runCatching { it.requireCurrentOwner() }.isSuccess }
    val repo = cached ?: run {
        val session = store.session(profile.id) ?: throw DsmFailure(null, "Sign in to the destination again",
            "Connect to the original destination and retry.", true, DsmErrorKind.NO_SAVED_SESSION)
        restore(profile, session).also { repositories[profile.id] = it }
    }
    if (repo.owner?.hasSameIdentity(owner) != true) throw io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure()
    return io.github.qwertyuiop1995.dsmnativeclient.data.RepositoryCrossNasTransferEndpoint(repo)
}
