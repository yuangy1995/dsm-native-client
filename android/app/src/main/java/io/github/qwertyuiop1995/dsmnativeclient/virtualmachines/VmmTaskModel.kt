package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageImport
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal enum class VmmTaskAction { IMPORT, CLEANUP }
internal data class VmmTaskState(val busy: Boolean = false, val loaded: Boolean = false,
    val imports: List<VmmImportActivity> = emptyList(), val cleanups: List<VmmTaskClearActivity> = emptyList(),
    val confirmation: List<VmmTaskTarget>? = null, val nothingToClear: Boolean = false, val failure: Exception? = null) {
    val active get() = busy || confirmation != null
    val protectedImages get() = imports.filter { it.pending }.mapNotNull { it.progress.image }.toSet()
}

/** 导入只跟踪一次创建；清理按项持久化，冷启动不续写未发送项。 */
internal class VmmTaskModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> VmmTaskStore, private val canStart: (VmmTaskAction) -> Boolean,
    private val onChanged: () -> Unit = {}, private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val pollAttempts: Int = 30, private val pollDelay: Long = 1_000) {
    private val mutable = MutableStateFlow(VmmTaskState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private suspend fun stillCurrent(repo: DsmRepository) { repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo)) }
    private fun publish(repo: DsmRepository, change: (VmmTaskState) -> VmmTaskState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = VmmTaskState() }
    private fun imports(repo: DsmRepository) = store().imports(requireNotNull(repo.owner))
    private fun cleanups(repo: DsmRepository) = store().cleanups(requireNotNull(repo.owner))
    private fun saved(repo: DsmRepository) { val imports = imports(repo); val cleanups = cleanups(repo); publish(repo) { it.copy(imports = imports, cleanups = cleanups) } }
    private fun allowed(repo: DsmRepository, action: VmmTaskAction) = try { canStart(action) } catch (error: Exception) { failed(repo, error); false }
    fun protectsImage(id: String, name: String?): Boolean {
        val repo = source() ?: return true
        return try { imports(repo).any { it.pending && (it.progress.image == vmmDigest(id) || name?.let { n -> vmmDigest(n.lowercase(Locale.ROOT)) } == it.snapshot.nameKey) } }
        catch (error: Exception) { failed(repo, error); true }
    }
    fun conflictsWithImport(name: String): Boolean {
        val repo = source() ?: return true
        return try { imports(repo).any { it.pending && it.snapshot.nameKey == vmmDigest(name.lowercase(Locale.ROOT)) } }
        catch (error: Exception) { failed(repo, error); true }
    }
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.active) return
        launch(repo) {
            store().execute(requireNotNull(repo.owner), wait = true) {
                stillCurrent(repo); cancelPrepared(repo); saved(repo)
                var failure: Exception? = null
                for (record in imports(repo).filter { it.progress.stage == VmmStage.ACCEPTED }) try {
                    recover(repo, record)
                } catch (error: Exception) { critical(error); failure = failure ?: error }
                val accepted = cleanups(repo).flatMap { it.items }.any { it.stage == VmmStage.ACCEPTED }
                if (accepted) try {
                    val present = repo.virtualMachineManagement.taskIds().map(::vmmDigest).toSet(); stillCurrent(repo)
                    for (record in cleanups(repo)) record.items.forEachIndexed { index, item ->
                        if (item.stage == VmmStage.ACCEPTED && item.id !in present) store().checkpoint(requireNotNull(repo.owner), record.id, index, VmmStage.VERIFIED)
                    }
                } catch (error: Exception) { critical(error); failure = failure ?: error }
                saved(repo); publish(repo) { it.copy(busy = false, loaded = true, failure = failure) }
            }
        }
    }
    private fun critical(error: Exception) { vmmRethrowCritical(error); if (error is io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure && error.kind == io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.PERMISSION_DENIED) throw error; if (error is VmmFailure && error.problem == VmmProblem.STORAGE) throw error }
    private fun cancelPrepared(repo: DsmRepository) {
        val owner = requireNotNull(repo.owner)
        imports(repo).filter { it.progress.stage == VmmStage.PREPARED }.forEach { store().checkpoint(owner, it.id, it.progress.copy(stage = VmmStage.CANCELLED)) }
        for (record in cleanups(repo)) record.items.forEachIndexed { index, item -> if (item.stage == VmmStage.PREPARED) store().checkpoint(owner, record.id, index, VmmStage.CANCELLED) }
    }
    private suspend fun recover(repo: DsmRepository, record: VmmImportActivity) {
        val progress = repo.virtualMachineManagement.recoverImport(record.snapshot, record.progress); stillCurrent(repo)
        if (progress != record.progress) store().checkpoint(requireNotNull(repo.owner), record.id, progress)
    }
    fun startImport(target: VirtualMachineImageImport): Boolean = synchronized(lock) {
        val repo = source() ?: return false
        if (state.value.active || !allowed(repo, VmmTaskAction.IMPORT) || conflictsWithImport(target.imageName)) return false
        launch(repo) {
            val owner = requireNotNull(repo.owner); val id = UUID.randomUUID().toString()
            store().execute(owner) {
                stillCurrent(repo); if (!allowed(repo, VmmTaskAction.IMPORT)) vmmConflict()
                repo.importNasVmmImage(target, prepared = { snapshot ->
                    repo.requireCurrentOwner(); check(current(repo)); store().begin(VmmImportActivity(id, owner, snapshot)); saved(repo)
                }, checkpoint = { progress ->
                    if (progress.stage == VmmStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                    store().checkpoint(owner, id, progress); saved(repo)
                })
                for (attempt in 0 until pollAttempts) {
                    stillCurrent(repo)
                    val record = imports(repo).single { it.id == id }
                    recover(repo, record); saved(repo)
                    if (!imports(repo).single { it.id == id }.pending) break
                    if (attempt + 1 < pollAttempts) delay(pollDelay)
                }
                finish(repo)
            }
            changed(repo)
        }; true
    }
    private fun eligible(repo: DsmRepository, targets: List<VmmTaskTarget>): List<VmmTaskTarget> {
        val pending = imports(repo).filter { it.pending }
        // 丢失创建回执时无法识别原任务，不允许清走可能用于后续人工恢复的记录。
        if (pending.any { it.progress.task == null }) return emptyList()
        val protected = pending.mapNotNull { it.progress.task }.toSet()
        val clearing = cleanups(repo).flatMap { it.items }.filter { it.pending }.map { it.id }.toSet()
        return targets.filter { it.finished && it.token !in protected && it.id !in clearing }
    }
    fun requestCleanup(): Boolean = synchronized(lock) {
        val repo = source() ?: return false
        if (state.value.active || !allowed(repo, VmmTaskAction.CLEANUP)) return false
        launch(repo) {
            store().execute(requireNotNull(repo.owner)) {
                stillCurrent(repo); if (!allowed(repo, VmmTaskAction.CLEANUP)) vmmConflict()
                val targets = eligible(repo, repo.virtualMachineManagement.taskTargets()); stillCurrent(repo)
                saved(repo); publish(repo) { it.copy(busy = false, confirmation = targets.takeIf { rows -> rows.isNotEmpty() }, nothingToClear = targets.isEmpty(), failure = null) }
            }
        }; true
    }
    fun cancelCleanup() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirmCleanup(expected: List<VmmTaskTarget>): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.busy || state.value.confirmation != expected || expected.isEmpty() || !allowed(repo, VmmTaskAction.CLEANUP)) return false
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                stillCurrent(repo)
                if (!allowed(repo, VmmTaskAction.CLEANUP) || eligible(repo, expected) != expected) vmmConflict()
                val activity = VmmTaskClearActivity(UUID.randomUUID().toString(), owner, expected.map { VmmTaskClearItem(it.id, it.identity) })
                store().begin(activity); saved(repo)
                try {
                    for ((index, target) in expected.withIndex()) {
                        stillCurrent(repo)
                        if (!allowed(repo, VmmTaskAction.CLEANUP)) vmmConflict()
                        repo.virtualMachineManagement.clearTask(target) { stage ->
                            if (stage == VmmStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                            store().checkpoint(owner, activity.id, index, stage); saved(repo)
                        }
                        if (cleanups(repo).single { it.id == activity.id }.items[index].stage != VmmStage.VERIFIED) break
                    }
                } finally {
                    cleanups(repo).single { it.id == activity.id }.items.forEachIndexed { index, item ->
                        if (item.stage == VmmStage.PREPARED) store().checkpoint(owner, activity.id, index, VmmStage.CANCELLED)
                    }
                }
                finish(repo)
            }
            changed(repo)
        }; true
    }
    fun dismiss(id: String, action: VmmTaskAction) = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.active) return
        try {
            if (action == VmmTaskAction.IMPORT) store().dismissImport(requireNotNull(repo.owner), id) else store().dismissCleanup(requireNotNull(repo.owner), id)
            saved(repo); publish(repo) { it.copy(failure = null) }
        } catch (error: Exception) { failed(repo, error) }
    }
    private fun changed(repo: DsmRepository) { scope.launch { if (current(repo)) onChanged() } }
    private fun finish(repo: DsmRepository) { saved(repo); publish(repo) { it.copy(busy = false, loaded = true, failure = null) } }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) { mutable.update { it.copy(busy = true, nothingToClear = false, failure = null) }; job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } } }
    private fun failed(repo: DsmRepository, error: Exception) {
        val records = runCatching { imports(repo) to cleanups(repo) }.getOrNull()
        publish(repo) { it.copy(busy = false, imports = records?.first ?: it.imports, cleanups = records?.second ?: it.cleanups, confirmation = null, failure = if (error is CancellationException) null else error) }
    }
}
