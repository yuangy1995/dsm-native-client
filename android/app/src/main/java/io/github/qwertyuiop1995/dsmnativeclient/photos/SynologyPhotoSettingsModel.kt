package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoSettingsCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoSettingsState(
    val visible: Boolean = false, val recordsPage: Boolean = false, val kind: SynologyPhotoSettingsKind? = null,
    val target: SynologyPhotoSettingsTarget? = null,
    val original: SynologyPhotoSettings? = null, val desired: SynologyPhotoSettings? = null,
    val confirmation: SynologyPhotoSettingsCheckpoint? = null,
    val loading: Boolean = false, val working: Boolean = false, val error: Throwable? = null,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val activeId: String? = null,
    val cache: SynologyPhotoConversionCache? = null, val cacheLoading: Boolean = false, val cacheError: Throwable? = null,
) {
    val change: SynologyPhotoSettingsCheckpoint? get() = original?.let { before -> desired?.let { SynologyPhotoSettingsCheckpoint(before, it) } }
    val canEdit: Boolean get() = original != null && !loading && !working && confirmation == null
}

/** 设置表单按固有目标独立读取；保存共用账号互斥与加密恢复，不重新发送已提交的设置。 */
internal class SynologyPhotoSettingsModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val canStart: () -> Boolean,
    private val beforeWrite: suspend () -> Unit = {}, private val onApplied: suspend (SynologyPhotoSettings) -> Unit = {},
    private val onSaved: suspend (SynologyPhotoSettings) -> Unit = {},
    private val pause: suspend (Long) -> Unit = { delay(it) },
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoSettingsState())
    val state = mutable.asStateFlow()
    private var generation = 0L; private var viewGeneration = 0L
    private var loader: Job? = null; private var worker: Job? = null; private var recordLoader: Job? = null
    private var reopening: SynologyPhotoAlbumRecord? = null
    private var operationId = UUID.randomUUID().toString()
    private var active = false; private var cacheLoader: Job? = null; private var poller: Job? = null
    fun available(kind: SynologyPhotoSettingsKind) = repository.canManageSettings(kind)
    private fun allowed() = job.isActive && canStart() && !state.value.working
    fun open(kind: SynologyPhotoSettingsKind) = open(SynologyPhotoSettingsTarget(kind))
    fun open(target: SynologyPhotoSettingsTarget) {
        if (!available(target.kind) || !allowed() || runCatching { io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoAlbumPreferenceCodec.validate(target) }.isFailure) return
        reset(); mutable.value = SynologyPhotoSettingsState(visible = true, kind = target.kind, target = target); load()
    }
    fun load(): Job? {
        val target = state.value.target ?: return null
        if (!state.value.visible || state.value.working || state.value.loading) return null
        val token = generation; val view = viewGeneration; val restored = reopening?.checkpoint?.settings
        mutable.update { it.copy(loading = true, original = null, desired = null, confirmation = null, error = null) }
        loader = scope.launch {
            try {
                requireCurrent(); val actual = repository.photoSettings(target); check(token)
                if (actual.target() != target) throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
                if (restored != null && restored.original != actual) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
                onApplied(actual); check(token)
                mutable.update { it.copy(original = actual, desired = restored?.desired ?: if (actual is SynologyPhotoGlobalSettings) actual.applying(actual.values) else actual,
                    cache = actual as? SynologyPhotoConversionCache) }
            } catch (error: Exception) { if (view == viewGeneration) present(error, token) }
            finally { if (current(token) && view == viewGeneration) {
                mutable.update { it.copy(loading = false) }; if (target.kind == SynologyPhotoSettingsKind.GLOBAL) refreshCache(); startPolling()
            } }
        }
        return loader
    }
    fun edit(value: SynologyPhotoSettings) {
        if (allowed() && state.value.canEdit && value.target() == state.value.target) mutable.update { it.copy(desired = if (value is SynologyPhotoGlobalSettings && it.original is SynologyPhotoGlobalSettings)
            it.original.applying(value.values, value.excludedExtensions) else value, error = null) }
    }
    val canSave: Boolean get() = allowed() && state.value.canEdit && state.value.change?.let {
        runCatching { SynologyPhotoSettingsCodec.validate(it) }.isSuccess
    } == true
    fun save(): Job? {
        if (!canSave) return null
        val value = state.value.change!!
        if (value.needsConfirmation) { mutable.update { it.copy(confirmation = value) }; return null }
        return submit(value)
    }
    fun changeSharedEnabled() {
        val original = state.value.original as? SynologyPhotoSharedSettings ?: return
        if (allowed() && state.value.canEdit && original.canToggle)
            mutable.update { it.copy(confirmation = SynologyPhotoSettingsCheckpoint(original, original.copy(enabled = !original.enabled))) }
    }
    fun clearCache() {
        val cache = state.value.cache ?: return
        if (allowed() && !state.value.loading && !state.value.cacheLoading && state.value.confirmation == null && cache.canClear)
            mutable.update { it.copy(confirmation = SynologyPhotoSettingsCheckpoint(cache, cache.copy(clearRequested = true))) }
    }
    fun cancelConfirmation() { mutable.update { it.copy(confirmation = null) } }
    fun confirm(): Job? {
        val value = state.value.confirmation ?: return null
        val sharedToggle = value.original is SynologyPhotoSharedSettings && value.desired is SynologyPhotoSharedSettings &&
            value.original.enabled != value.desired.enabled && value.original == state.value.original
        val cacheClear = value.original is SynologyPhotoConversionCache && value.original == state.value.cache && !state.value.cacheLoading
        if (!allowed() || value != state.value.change && !sharedToggle && !cacheClear || runCatching { SynologyPhotoSettingsCodec.validate(value) }.isFailure) return null
        return submit(value)
    }
    private fun submit(value: SynologyPhotoSettingsCheckpoint): Job {
        mutable.update { it.copy(confirmation = null) }
        return perform(operationId) {
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId,
                userId = repository.photoEditIdentity(), operationId = operationId, action = SynologyPhotoAlbumAction.SETTINGS, settings = value))
            beforeWrite(); repository.preparePhotoAlbum(row.checkpoint)
            reopening?.let { store.discard(store.get(it.id, owner, row.checkpoint.userId)) }
            store.begin(row)
            mutable.update { it.copy(recordsPage = true, original = null, desired = null) }
            execute(row)
        }
    }
    fun showRecords() {
        if (state.value.working) return
        reset(); mutable.value = SynologyPhotoSettingsState(visible = true, recordsPage = true); refreshRecords(); startPolling()
    }
    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed() || row.checkpoint.finished) return null
        if (!row.checkpoint.submitted) {
            reset(); reopening = row
            mutable.value = SynologyPhotoSettingsState(visible = true, kind = row.checkpoint.settings!!.original.kind, target = row.checkpoint.settings.original.target()); return load()
        }
        return perform(id) { execute(store.get(id, owner, row.checkpoint.userId)) }
    }
    private fun perform(id: String, operation: suspend () -> SynologyPhotoAlbumCheckpoint): Job {
        val token = generation; cacheLoader?.cancel(); mutable.update { it.copy(working = true, activeId = id, error = null, cacheLoading = false) }
        worker = scope.launch {
            var applied: SynologyPhotoSettings? = null
            try {
                val result = withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); operation() } }
                if (result.phase == SynologyPhotoAlbumPhase.COMPLETED || result.phase == SynologyPhotoAlbumPhase.PARTIAL && result.settings?.desired is SynologyPhotoGlobalSettings) {
                    val desired = result.settings!!.desired
                    applied = if (desired is SynologyPhotoSharedSettings || desired is SynologyPhotoGlobalSettings || desired is SynologyPhotoConversionCache) withContext(Dispatchers.IO) { repository.photoSettings(desired.target()) } else desired
                    check(token)
                }
            }
            catch (error: Exception) { present(error, token) }
            finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) { mutable.update { it.copy(working = false) }; startPolling() }
                }
            }
            if (current(token) && applied != null) {
                try { requireCurrent(); onApplied(applied); check(token); onSaved(applied) } catch (error: Exception) { present(error, token) }
            }
        }
        return worker!!
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != row.checkpoint.userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
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
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any {
            it.checkpoint.action == SynologyPhotoAlbumAction.SETTINGS && it.checkpoint.submitted && !it.checkpoint.finished
        }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    fun refreshRecords(): Job? {
        if (state.value.working || recordLoader?.isActive == true) return null
        val token = generation
        recordLoader = scope.launch { try { reload(token) } catch (error: Exception) { present(error, token) } }
        return recordLoader
    }
    private suspend fun reload(token: Long) {
        requireCurrent(); val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action == SynologyPhotoAlbumAction.SETTINGS } }
        check(token); mutable.update { it.copy(records = rows) }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working) return null
        val token = generation
        return scope.launch { try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reload(token) } catch (error: Exception) { present(error, token) } }
    }
    fun refreshCache(): Job? {
        if (!state.value.visible || state.value.working || state.value.cacheLoading || !available(SynologyPhotoSettingsKind.CACHE)) return null
        val token = generation; val view = viewGeneration; mutable.update { it.copy(cacheLoading = true, cacheError = null) }
        cacheLoader = scope.launch {
            try {
                requireCurrent(); val value = repository.photoSettings(SynologyPhotoSettingsKind.CACHE) as SynologyPhotoConversionCache
                check(token); mutable.update { it.copy(cache = value) }
            } catch (error: Exception) { if (error !is CancellationException && current(token) && view == viewGeneration) mutable.update { it.copy(cache = null, cacheError = error) } }
            finally { if (current(token) && view == viewGeneration) { mutable.update { it.copy(cacheLoading = false) }; startPolling() } }
        }
        return cacheLoader
    }
    private fun startPolling() {
        if (!active || !state.value.visible || poller?.isActive == true || !state.value.recordsPage && state.value.kind !in setOf(SynologyPhotoSettingsKind.GLOBAL, SynologyPhotoSettingsKind.CACHE)) return
        val token = generation
        poller = scope.launch {
            while (isActive && active && current(token) && state.value.visible) {
                pause(if (state.value.cache?.clearing == true && !state.value.recordsPage) 5_000 else 15_000)
                if (!active || !current(token) || !state.value.visible || state.value.working || state.value.confirmation != null) continue
                if (!state.value.recordsPage && state.value.cache?.clearing == true) refreshCache()?.join()
                if (state.value.recordsPage) {
                    refreshRecords()?.join()
                    state.value.records.firstOrNull { it.checkpoint.settings?.globalProgress != null && it.checkpoint.submitted && !it.checkpoint.finished }
                        ?.let { resume(it.id)?.join() }
                }
            }
        }
    }
    fun activate() { active = true; if (state.value.visible) {
        if (!state.value.recordsPage) { if (state.value.original == null) load() else if (state.value.kind in setOf(SynologyPhotoSettingsKind.GLOBAL, SynologyPhotoSettingsKind.CACHE)) refreshCache() }
        startPolling()
    } }
    fun deactivate() {
        active = false; viewGeneration++; poller?.cancel(); poller = null; cacheLoader?.cancel(); loader?.cancel(); recordLoader?.cancel()
        mutable.update { it.copy(cacheLoading = false, loading = false) }
    }
    fun dismiss() {
        if (state.value.working) { poller?.cancel(); cacheLoader?.cancel(); mutable.update { it.copy(visible = false, cacheLoading = false) }; return }
        reset(); mutable.value = SynologyPhotoSettingsState()
    }
    private fun reset() { generation++; loader?.cancel(); recordLoader?.cancel(); cacheLoader?.cancel(); poller?.cancel(); poller = null; reopening = null; operationId = UUID.randomUUID().toString() }
    private fun current(token: Long) = token == generation && job.isActive
    private suspend fun check(token: Long) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoSettingsState() }
    override fun close() { revokeAccess(); job.cancel() }
}
