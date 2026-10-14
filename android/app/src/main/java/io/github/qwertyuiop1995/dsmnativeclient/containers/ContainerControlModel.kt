package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class ContainerControlConfirmation(val targets: List<ContainerControlTarget>, val action: ContainerAction)
internal data class ContainerControlState(val loaded: Boolean = false, val busy: Boolean = false, val targets: List<ContainerControlTarget> = emptyList(),
    val confirmation: ContainerControlConfirmation? = null, val record: ContainerControlActivity? = null, val failure: Exception? = null) {
    val blocked get() = !loaded || busy || confirmation != null || record?.pending == true || failure != null
}

/** 一次固定整批，逐项写前核对；错误停止后续项，重建只读取已发目标。 */
internal class ContainerControlModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> ContainerControlStore, private val canStart: () -> Boolean,
    private val onChanged: () -> Unit = {}, private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(ContainerControlState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (ContainerControlState) -> ContainerControlState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = ContainerControlState() }
    private suspend fun stillCurrent(repo: DsmRepository) { repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo)) }
    private fun record(repo: DsmRepository) = store().records(requireNotNull(repo.owner)).let { rows -> rows.firstOrNull { it.pending } ?: rows.firstOrNull() }
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                stillCurrent(repo)
                for (activity in store().records(owner)) for ((index, item) in activity.items.withIndex()) {
                    if (item.stage == ContainerStage.PREPARED) store().checkpoint(owner, activity.id, index, ContainerStage.CANCELLED)
                }
                val activity = record(repo)
                publish(repo) { it.copy(record = activity) }
                val targets = repo.containerManagement.controlTargets()
                stillCurrent(repo)
                if (activity != null) for ((index, item) in activity.items.withIndex()) {
                    if (item.stage !in setOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED)) continue
                    val target = targets.singleOrNull { containerDigest(it.id) == item.id }
                    val matches = if (activity.action == ContainerAction.DELETE) target == null
                        else target != null && containerIdentity(target) == item.identity && target.matches(activity.action, item.startedAt)
                    if (matches) store().checkpoint(owner, activity.id, index, ContainerStage.VERIFIED)
                }
                publish(repo) { it.copy(loaded = true, targets = targets) }
                finish(repo)
            }
        }
    }
    fun request(targets: List<ContainerControlTarget>, action: ContainerAction): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.blocked || !canStart() || targets.isEmpty() || targets.distinctBy { it.id }.size != targets.size ||
            targets.any { target -> !target.supports(action) || target !in state.value.targets }) return false
        try {
            if (store().records(requireNotNull(repo.owner)).any { it.pending }) { publish(repo) { it.copy(record = record(repo)) }; return false }
            mutable.update { it.copy(confirmation = ContainerControlConfirmation(targets.toList(), action), failure = null) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun cancel() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm(expected: ContainerControlConfirmation): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.busy || !state.value.loaded || state.value.record?.pending == true || state.value.failure != null ||
            state.value.confirmation != expected || !canStart()) return false
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                stillCurrent(repo)
                val activity = ContainerControlActivity(UUID.randomUUID().toString(), owner, expected.action, expected.targets.map {
                    ContainerControlItem(containerDigest(it.id), containerIdentity(it), containerDigest(it.name), it.startedAt)
                })
                store().records(owner).filter { !it.pending }.forEach { store().dismiss(owner, it.id) }
                store().begin(activity); publish(repo) { it.copy(record = activity) }
                try {
                    for ((index, target) in expected.targets.withIndex()) {
                        stillCurrent(repo)
                        repo.containerManagement.performControl(target, expected.action) { stage ->
                            if (stage == ContainerStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                            store().checkpoint(owner, activity.id, index, stage)
                        }
                        val item = store().records(owner).single { it.id == activity.id }.items[index]
                        if (item.stage != ContainerStage.VERIFIED) break
                    }
                } finally {
                    val saved = store().records(owner).single { it.id == activity.id }
                    saved.items.forEachIndexed { index, item -> if (item.stage == ContainerStage.PREPARED) store().checkpoint(owner, activity.id, index, ContainerStage.CANCELLED) }
                }
                stillCurrent(repo)
                val targets = repo.containerManagement.controlTargets()
                publish(repo) { it.copy(targets = targets) }
                finish(repo)
            }
            scope.launch { if (current(repo)) onChanged() }
        }; true
    }
    fun dismiss() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy || state.value.record?.pending == true) return
        try { state.value.record?.let { store().dismiss(requireNotNull(repo.owner), it.id) }; publish(repo) { it.copy(record = record(repo), failure = null) } }
        catch (error: Exception) { failed(repo, error) }
    }
    private fun finish(repo: DsmRepository) { val activity = record(repo); publish(repo) { it.copy(busy = false, record = activity, failure = null) } }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) {
        mutable.update { it.copy(busy = true, failure = null) }
        job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } }
    }
    private fun failed(repo: DsmRepository, error: Exception) {
        val activity = runCatching { record(repo) }.getOrNull()
        publish(repo) { it.copy(busy = false, confirmation = null, record = activity ?: it.record, failure = if (error is CancellationException) null else error) }
    }
}
