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

internal data class SynologyPhotoAutomaticPreviewState(
    val enabled: Boolean? = null, val supported: Boolean? = null, val paused: Boolean = false,
    val working: Boolean = false, val task: SynologyPhotoAutomaticPreviewTask? = null,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val error: Throwable? = null,
) {
    val pending: Boolean get() = records.any { it.checkpoint.submitted && !it.checkpoint.finished }
    val visible: Boolean get() = task != null || pending || enabled == true && (paused || error != null)
}

/** 仅前台领取；取消等待落盘和缓存清理，任何冷记录都只读恢复。 */
internal class SynologyPhotoAutomaticPreviewModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val cache: File, private val requireCurrent: () -> Unit,
    private val canRun: () -> Boolean, private val settingsVisible: () -> Boolean,
    private val view: () -> SynologyPhotoAutomaticPreviewView,
    private val beforeClaim: suspend () -> Unit,
    private val onUpdated: suspend (SynologyPhotoAutomaticPreviewTask) -> Unit,
    private val support: () -> SynologyPhotoPreviewConversionSupport = SynologyPhotosVideoConverter::support,
    private val wait: suspend (Long) -> Unit = { delay(it) },
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoAutomaticPreviewState()); val state = mutable.asStateFlow()
    private var active = false; private var generation = 0L
    private var poller: Job? = null; private var operation: Job? = null; private var visibleWake: Job? = null
    private var deviceSupport: SynologyPhotoPreviewConversionSupport? = null
    private var visible = emptySet<SynologyPhotoId>(); private var visibleAt = 0L
    private var reviewAt = 0L; private var reviewAttempts = 0; private var progress = 0L
    private val completed = mutableListOf<SynologyPhotoAutomaticPreviewTask>()
    private val failed = mutableListOf<SynologyPhotoAutomaticPreviewTask>()

    fun setVisible(ids: Set<SynologyPhotoId>) {
        if (visible == ids) return
        visible = ids.toSet(); visibleAt = now() + 2_000
        visibleWake?.cancel()
        if (active) visibleWake = scope.launch { delay(2_000); process()?.join() }
    }
    fun applySettings(value: SynologyPhotoAutomaticPreviewSettings) {
        mutable.update { it.copy(enabled = value.enabled, error = null) }
        if (!value.enabled) operation?.cancel()
    }
    fun pause() { mutable.update { it.copy(paused = true) }; operation?.cancel() }
    fun refresh() { reviewAt = 0; process() }
    fun resume() { failed.clear(); mutable.update { it.copy(paused = false, error = null) }; reviewAt = 0; process() }
    fun activate() {
        active = true
        if (poller?.isActive == true) return
        poller = scope.launch {
            var delayMillis = 5_000L
            while (isActive && active) {
                wait(delayMillis)
                val before = progress; process()?.join()
                delayMillis = if (before != progress) 100 else 5_000
            }
        }
    }
    fun process(): Job? {
        if (!active || !job.isActive || operation?.isActive == true || !canRun()) return null
        val token = generation
        operation = scope.launch {
            var task: SynologyPhotoAutomaticPreviewTask? = null
            try {
                check(token); reload(token)
                consumeFinished(token)
                val pending = state.value.records.firstOrNull { it.checkpoint.submitted && !it.checkpoint.finished }
                if (pending != null) {
                    if (now() < reviewAt) return@launch
                    reviewAt = now() + minOf(60_000, 5_000L shl minOf(4, reviewAttempts++))
                    task = pending.checkpoint.automaticPreview!!.task
                    mutable.update { it.copy(working = true, task = task) }
                    execute(pending, token, recovery = true)
                    consumeFinished(token); return@launch
                }
                if (state.value.paused || settingsVisible()) return@launch
                val available = deviceSupport ?: withContext(Dispatchers.IO) { support() }.also { deviceSupport = it }
                check(token); mutable.update { it.copy(supported = available.available) }
                if (!available.available) return@launch
                val enabled = repository.automaticPreviewEnabled(); check(token)
                mutable.update { it.copy(enabled = enabled) }
                if (!enabled || !claimAllowed()) return@launch
                beforeClaim(); check(token)
                task = candidate(available, token) ?: return@launch
                if (!claimAllowed()) return@launch
                val row = repository.prepareAutomaticPreview(task, available); check(token)
                if (!claimAllowed()) return@launch
                mutable.update { it.copy(working = true, task = task) }
                execute(SynologyPhotoAlbumRecord(owner = owner, checkpoint = row), token, recovery = false)
                consumeFinished(token)
            } catch (error: Exception) {
                if (error !is CancellationException && current(token) && !(error is SynologyPhotoAlbumFailure && error.problem in setOf(SynologyPhotoAlbumProblem.BUSY, SynologyPhotoAlbumProblem.PENDING))) {
                    task?.let { if (failed.none(it::sameMedia)) { failed += it; progress++ } }
                    mutable.update { it.copy(error = error) }
                }
            } finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { if (current(token)) mutable.update { it.copy(error = error) } }
                    mutable.update { it.copy(working = false, task = null) }
                }
            }
        }
        return operation
    }
    private fun claimAllowed() = active && canRun() && !settingsVisible() && !state.value.paused && state.value.enabled == true
    private suspend fun candidate(support: SynologyPhotoPreviewConversionSupport, token: Long): SynologyPhotoAutomaticPreviewTask? {
        val snapshot = view(); val candidates = mutableListOf<SynologyPhotoAutomaticPreviewTask>()
        fun accept(task: SynologyPhotoAutomaticPreviewTask) = (task.needsThumbnail || task.needsVideo) && (completed + failed).none(task::sameMedia)
        if (now() >= visibleAt) for (photo in snapshot.ordered(visible)) {
            if (!repository.canGenerateAutomaticPreviews(photo.id.space)) continue
            try {
                val tasks = repository.automaticPreviewTasks(photo, support); check(token)
                candidates += tasks.filter { accept(it) && (photo.mediaType != "live" || photo.id == snapshot.current?.id || !it.video) }
            } catch (error: Exception) { check(token); if (error is CancellationException) throw error; mutable.update { it.copy(error = error) } }
            if (candidates.any { it.priority == SynologyPhotoAutomaticPreviewPriority.STANDARD }) break
        }
        for (space in (listOf(snapshot.space) + snapshot.spaces).distinct()) {
            if (candidates.isNotEmpty()) break
            if (space !in snapshot.spaces || space == SynologyPhotoSpace.SHARED && !snapshot.managesShared || !repository.canGenerateAutomaticPreviews(space)) continue
            try { candidates += repository.automaticPreviewTasks(space, support).filter(::accept); check(token) }
            catch (error: Exception) { check(token); if (error is CancellationException) throw error; mutable.update { it.copy(error = error) } }
        }
        return candidates.minByOrNull { it.priority.ordinal }
    }
    private suspend fun execute(record: SynologyPhotoAlbumRecord, token: Long, recovery: Boolean) {
        withContext(Dispatchers.IO) { store.automaticExclusive(owner, record.id) {
            check(token)
            if (!recovery) { if (!claimAllowed()) return@automaticExclusive; beforeClaim(); check(token); store.begin(record) }
            val actual = store.get(record.id, owner, repository.photoEditIdentity())
            store.requireNoConflict(actual); cleanCache(actual.id)
            fun save(next: SynologyPhotoAlbumCheckpoint) {
                requireCurrent(); store.save(actual.id, owner, actual.checkpoint.userId, next)
            }
            try {
                if (recovery) repository.reviewAutomaticPreview(actual.checkpoint, cache, ::save)
                else repository.performAutomaticPreview(actual.checkpoint, cache, ::save)
            } finally {
                // 尚未产生任何写入事实的中止可本地结束；已有上传或损坏标记事实必须保留。
                withContext(NonCancellable) {
                    requireCurrent()
                    val latest = store.get(actual.id, owner, actual.checkpoint.userId).checkpoint
                    if (latest.submitted && !latest.finished && !latest.automaticPreview!!.uploadAttempted && latest.automaticPreview.failureKind == null)
                        repository.reviewAutomaticPreview(latest, cache, ::save)
                    cleanCache(actual.id)
                }
            }
        } }
        check(token); reload(token)
    }
    private suspend fun consumeFinished(token: Long) {
        for (record in state.value.records.filter { it.checkpoint.finished || !it.checkpoint.submitted }) {
            val row = record.checkpoint; val task = row.automaticPreview!!.task
            withContext(Dispatchers.IO) {
                store.automaticExclusive(owner, record.id) { check(token); cleanCache(record.id) }
                requireCurrent(); store.discard(store.get(record.id, owner, row.userId))
            }
            check(token)
            if (row.phase == SynologyPhotoAlbumPhase.COMPLETED && completed.none(task::sameMedia)) {
                completed += task; progress++; mutable.update { it.copy(error = null) }; onUpdated(task)
            } else if (row.finished && (row.automaticPreview.uploadAttempted || row.automaticPreview.failureKind != null) && failed.none(task::sameMedia)) {
                failed += task; progress++; mutable.update { it.copy(error = SynologyPhotoFailure(SynologyPhotoFailureKind.MEDIA)) }
            }
        }
        reload(token)
    }
    private suspend fun reload(token: Long) {
        requireCurrent()
        val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action == SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW } }
        check(token); mutable.update { it.copy(records = rows) }
    }
    private fun cleanCache(id: String) {
        cache.listFiles { file -> file.name.startsWith("synology-photos-automatic-preview-$id-") }?.forEach {
            if (Files.isSymbolicLink(it.toPath())) Files.delete(it.toPath())
            else if (!it.deleteRecursively()) throw IOException("Photo automatic preview cleanup failed")
        }
    }
    suspend fun requireNoPending() {
        operation?.cancelAndJoin()
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any {
            it.checkpoint.action == SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW && it.checkpoint.submitted && !it.checkpoint.finished
        }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    fun deactivate() {
        active = false; generation++; poller?.cancel(); poller = null; operation?.cancel(); visibleWake?.cancel()
        mutable.update { it.copy(working = false, task = null) }
    }
    fun revokeAccess() { deactivate(); visible = emptySet(); completed.clear(); failed.clear(); mutable.value = SynologyPhotoAutomaticPreviewState() }
    private fun current(token: Long) = token == generation && job.isActive
    private suspend fun check(token: Long) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token)) throw CancellationException() }
    override fun close() { revokeAccess(); job.cancel() }
}
