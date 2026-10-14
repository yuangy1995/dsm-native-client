package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoCodecPromptState(
    val visible: Boolean = false,
    val prompt: SynologyPhotoCodecPrompt? = null, val loading: Boolean = false, val working: Boolean = false,
    val confirmation: SynologyPhotoCodecPrompt? = null, val error: Throwable? = null,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val activeId: String? = null,
) {
    val pending: Boolean get() = records.any { it.checkpoint.submitted && !it.checkpoint.finished }
}

/** 新格式提示独立读取与恢复，只有用户明确继续时才再次保存已拒绝的提示。 */
internal class SynologyPhotoCodecPromptModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val canStart: () -> Boolean,
    private val beforeWrite: suspend () -> Unit,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoCodecPromptState()); val state = mutable.asStateFlow()
    private var generation = 0L; private var viewGeneration = 0L; private var active = false
    private var loader: Job? = null; private var worker: Job? = null; private var poller: Job? = null
    val available: Boolean get() = repository.canRespondToCodecPrompt
    val canGenerate: Boolean get() = repository.canGenerateCodecPreviews && state.value.prompt?.canGenerate == true
    private fun allowed() = job.isActive && canStart() && !state.value.working
    fun open() {
        if (!allowed() || !available) return
        reset(); mutable.value = SynologyPhotoCodecPromptState(visible = true); load()
    }
    fun load(clearError: Boolean = true): Job? {
        if (!state.value.visible || state.value.loading || state.value.working || state.value.confirmation != null) return null
        val token = generation; val view = viewGeneration
        mutable.update { it.copy(loading = true, error = if (clearError) null else it.error) }
        loader = scope.launch {
            try {
                requireCurrent(); reloadRecords(token, view)
                val value = repository.codecPrompt(); check(token, view); mutable.update { it.copy(prompt = value) }
            } catch (error: Exception) { if (error !is CancellationException && current(token, view)) mutable.update { it.copy(prompt = null, error = error) } }
            finally { if (current(token, view)) { mutable.update { it.copy(loading = false) }; startPolling() } }
        }; return loader
    }
    fun requestGeneration() {
        val value = state.value.prompt ?: return
        if (!ready() || !canGenerate) return
        mutable.update { it.copy(confirmation = value) }
    }
    private fun ready() = allowed() && state.value.visible && !state.value.loading && !state.value.pending &&
        state.value.confirmation == null && state.value.prompt?.shouldShow == true
    fun cancelConfirmation() { mutable.update { it.copy(confirmation = null) } }
    fun confirm(): Job? {
        val value = state.value.confirmation ?: return null
        if (!allowed() || !canGenerate || value != state.value.prompt) return null
        mutable.update { it.copy(confirmation = null) }
        return submit(value, true)
    }
    fun later(): Job? {
        if (!ready()) return null
        return submit(state.value.prompt!!, false)
    }
    private fun submit(value: SynologyPhotoCodecPrompt, generate: Boolean): Job {
        val id = UUID.randomUUID().toString()
        return perform(id) {
            beforeWrite(); val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(
                profileId = owner.profileId, userId = repository.photoEditIdentity(), operationId = id,
                action = SynologyPhotoAlbumAction.CODEC_PROMPT, codecPrompt = SynologyPhotoCodecCheckpoint(value, generate)))
            repository.preparePhotoAlbum(row.checkpoint); store.begin(row); execute(row)
        }
    }
    fun continuePrompt(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed() || row.checkpoint.codecPrompt?.canContinue != true) return null
        return perform(id) { beforeWrite(); execute(store.get(id, owner, row.checkpoint.userId), continuePrompt = true) }
    }
    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed() || row.checkpoint.finished || !row.checkpoint.submitted) return null
        return perform(id) { execute(store.get(id, owner, row.checkpoint.userId)) }
    }
    private fun perform(id: String, operation: suspend () -> SynologyPhotoAlbumCheckpoint): Job {
        val token = generation; mutable.update { it.copy(working = true, activeId = id, error = null) }
        worker = scope.launch {
            try { withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); operation() } } }
            catch (error: Exception) { present(error, token) }
            finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reloadRecords(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) {
                        mutable.update { it.copy(working = false) }
                        if (active && state.value.visible) load(clearError = false)
                    }
                }
            }
        }; return worker!!
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord, continuePrompt: Boolean = false): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != row.checkpoint.userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        store.requireNoConflict(row); val token = generation
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); val saved = store.save(row.id, owner, row.checkpoint.userId, next)
            if (current(token)) mutable.update { it.copy(records = listOf(saved) + it.records.filterNot { old -> old.id == row.id }) }
        }
        return if (continuePrompt) repository.continueCodecPrompt(row.checkpoint, ::save)
        else if (row.checkpoint.submitted) repository.reviewPhotoAlbum(row.checkpoint, ::save) else repository.performPhotoAlbum(row.checkpoint, ::save)
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any {
            it.checkpoint.action == SynologyPhotoAlbumAction.CODEC_PROMPT && it.checkpoint.submitted && !it.checkpoint.finished
        }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    private suspend fun reloadRecords(token: Long, view: Long = viewGeneration) {
        requireCurrent(); val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action == SynologyPhotoAlbumAction.CODEC_PROMPT } }
        check(token, view); mutable.update { it.copy(records = rows) }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working || row.checkpoint.submitted && !row.checkpoint.finished) return null
        val token = generation; return scope.launch {
            try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reloadRecords(token) }
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
                val row = state.value.records.firstOrNull { it.checkpoint.submitted && !it.checkpoint.finished }
                if (row != null) resume(row.id)?.join() else load()?.join()
            }
        }
    }
    fun activate() { active = true; if (state.value.visible) { load(); startPolling() } }
    fun deactivate() { active = false; viewGeneration++; loader?.cancel(); poller?.cancel(); poller = null; mutable.update { it.copy(loading = false) } }
    fun dismiss() {
        if (state.value.working) { poller?.cancel(); mutable.update { it.copy(visible = false) }; return }
        reset(); mutable.value = SynologyPhotoCodecPromptState()
    }
    private fun reset() { generation++; val wasActive = active; deactivate(); active = wasActive }
    private fun current(token: Long, view: Long = viewGeneration) = token == generation && view == viewGeneration && job.isActive
    private suspend fun check(token: Long, view: Long = viewGeneration) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token, view)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoCodecPromptState() }
    override fun close() { revokeAccess(); job.cancel() }
}
