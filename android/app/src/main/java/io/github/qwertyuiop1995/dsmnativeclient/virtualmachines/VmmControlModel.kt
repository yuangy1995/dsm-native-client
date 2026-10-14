package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class VmmControlConfirmation(val targets: List<VmmControlTarget>, val action: VmmAction)
internal data class VmmControlState(val loaded: Boolean = false, val busy: Boolean = false, val targets: List<VmmControlTarget> = emptyList(),
    val confirmation: VmmControlConfirmation? = null, val records: List<VmmControlActivity> = emptyList(), val failure: Exception? = null) {
    val record get() = records.firstOrNull { it.pending } ?: records.firstOrNull()
    val protectedIds get() = records.flatMap { it.items }.filter { it.pending }.map { it.id }.toSet()
    val blocked get() = !loaded || busy || confirmation != null || failure != null
}

/** 一次固定整批，逐项写前核对；错误停止后续项，重建只读取已发目标。 */
internal class VmmControlModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> VmmControlStore, private val canStart: (List<VmmControlTarget>) -> Boolean,
    private val onChanged: () -> Unit = {}, private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(VmmControlState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (VmmControlState) -> VmmControlState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = VmmControlState() }
    private suspend fun stillCurrent(repo: DsmRepository) { repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo)) }
    private fun records(repo: DsmRepository) = store().records(requireNotNull(repo.owner))
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner, wait = true) {
                stillCurrent(repo)
                for (activity in store().records(owner)) for ((index, item) in activity.items.withIndex()) {
                    if (item.stage == VmmStage.PREPARED) store().checkpoint(owner, activity.id, index, VmmStage.CANCELLED)
                }
                val activities = records(repo)
                publish(repo) { it.copy(records = activities) }
                val targets = repo.virtualMachineManagement.controlTargets()
                stillCurrent(repo)
                for (activity in activities) for ((index, item) in activity.items.withIndex()) {
                    if (item.stage != VmmStage.ACCEPTED) continue
                    val matches = repo.virtualMachineManagement.recoverControl(item.id, item.identity, activity.action, item.source)
                    if (matches) store().checkpoint(owner, activity.id, index, VmmStage.VERIFIED)
                }
                publish(repo) { it.copy(loaded = true, targets = targets) }
                finish(repo)
            }
        }
    }
    private fun allowed(repo: DsmRepository, targets: List<VmmControlTarget>): Boolean = try { canStart(targets) } catch (error: Exception) { failed(repo, error); false }
    fun request(targets: List<VmmControlTarget>, action: VmmAction): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.blocked || !allowed(repo, targets) || targets.isEmpty() || targets.distinctBy { it.id }.size != targets.size ||
            targets.any { target -> !target.supports(action) || target !in state.value.targets }) return false
        try {
            if (records(repo).flatMap { it.items }.any { it.pending && targets.any { target -> vmmDigest(target.id) == it.id } }) { publish(repo) { it.copy(records = records(repo)) }; return false }
            mutable.update { it.copy(confirmation = VmmControlConfirmation(targets.toList(), action), failure = null) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun cancel() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm(expected: VmmControlConfirmation): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.busy || !state.value.loaded || state.value.failure != null ||
            state.value.confirmation != expected || !allowed(repo, expected.targets)) return false
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                stillCurrent(repo)
                if (!allowed(repo, expected.targets)) vmmConflict()
                val activity = VmmControlActivity(UUID.randomUUID().toString(), owner, expected.action, expected.targets.map {
                    VmmControlItem(vmmDigest(it.id), vmmIdentity(it), vmmDigest(it.name), repo.virtualMachineManagement.controlSource(expected.action))
                })
                store().records(owner).filter { !it.pending }.forEach { store().dismiss(owner, it.id) }
                store().begin(activity); publish(repo) { it.copy(records = records(repo)) }
                try {
                    for ((index, target) in expected.targets.withIndex()) {
                        stillCurrent(repo)
                        repo.virtualMachineManagement.performControl(target, expected.action, activity.items[index].source) { stage ->
                            if (stage == VmmStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                            store().checkpoint(owner, activity.id, index, stage)
                        }
                        val item = store().records(owner).single { it.id == activity.id }.items[index]
                        if (item.stage != VmmStage.VERIFIED) break
                    }
                } finally {
                    val saved = store().records(owner).single { it.id == activity.id }
                    saved.items.forEachIndexed { index, item -> if (item.stage == VmmStage.PREPARED) store().checkpoint(owner, activity.id, index, VmmStage.CANCELLED) }
                }
                stillCurrent(repo)
                val targets = repo.virtualMachineManagement.controlTargets()
                publish(repo) { it.copy(targets = targets) }
                finish(repo)
            }
            scope.launch { if (current(repo)) onChanged() }
        }; true
    }
    fun hasPending(targetId: String? = null): Boolean = synchronized(lock) {
        val repo = source() ?: return true
        try { state.value.busy || state.value.confirmation != null || records(repo).flatMap { it.items }.any { it.pending && (targetId == null || it.id == vmmDigest(targetId)) } }
        catch (error: Exception) { failed(repo, error); true }
    }
    fun dismiss() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        try { records(repo).filter { !it.pending }.forEach { store().dismiss(requireNotNull(repo.owner), it.id) }; publish(repo) { it.copy(records = records(repo), failure = null) } }
        catch (error: Exception) { failed(repo, error) }
    }
    private fun finish(repo: DsmRepository) { val activities = records(repo); publish(repo) { it.copy(busy = false, records = activities, failure = null) } }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) {
        mutable.update { it.copy(busy = true, failure = null) }
        job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } }
    }
    private fun failed(repo: DsmRepository, error: Exception) {
        val activities = runCatching { records(repo) }.getOrNull()
        publish(repo) { it.copy(busy = false, confirmation = null, records = activities ?: it.records, failure = if (error is CancellationException) null else error) }
    }
}
