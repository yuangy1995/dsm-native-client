package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

internal sealed interface ContainerNetworkConfirmation {
    data class Create(val draft: ContainerNetworkDraft) : ContainerNetworkConfirmation
    data class Delete(val targets: List<ContainerNetworkEntry>) : ContainerNetworkConfirmation
}
internal data class ContainerNetworkState(val loaded: Boolean = false, val busy: Boolean = false, val networks: List<ContainerNetworkEntry> = emptyList(),
    val draft: ContainerNetworkDraft? = null, val confirmation: ContainerNetworkConfirmation? = null,
    val activities: List<ContainerNetworkActivity> = emptyList(), val failure: Exception? = null)

/** 创建未知只认同名对象已存在；删除未知只认原 ID 已消失，均不会重发或续跑批次。 */
internal class ContainerNetworkModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> ContainerNetworkStore, private val canStart: () -> Boolean, private val onChanged: () -> Unit = {},
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(ContainerNetworkState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (ContainerNetworkState) -> ContainerNetworkState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = ContainerNetworkState() }
    private suspend fun stillCurrent(repo: DsmRepository) { repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo)) }
    private fun records(repo: DsmRepository) = store().records(requireNotNull(repo.owner))
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        mutable.update { it.copy(confirmation = null) }
        launch(repo) { val owner = requireNotNull(repo.owner); store().execute(owner) {
            val networks = repo.containerManagement.networkDefinitions(); stillCurrent(repo)
            for (record in records(repo)) for ((index, item) in record.items.withIndex()) {
                if (item.stage == ContainerStage.PREPARED) store().checkpoint(owner, record.id, index, ContainerStage.CANCELLED)
                else if (item.pending) {
                    val matches = if (record.operation == ContainerNetworkOperation.DELETE) networks.none { containerDigest(it.id) == item.target.id }
                        else networks.any { if (item.accepted) item.target.matches(it) else containerDigest(it.name) == item.target.name }
                    if (matches) store().checkpoint(owner, record.id, index, ContainerStage.VERIFIED)
                }
            }
            publish(repo) { it.copy(loaded = true, networks = networks) }; finish(repo)
        } }
    }
    fun openCreate(): Boolean = synchronized(lock) {
        val previous = bound; source() ?: return false
        if (previous !== bound || !state.value.loaded || state.value.busy || state.value.confirmation != null || !canStart()) return false
        mutable.update { it.copy(draft = ContainerNetworkDraft(), failure = null) }; true
    }
    fun edit(draft: ContainerNetworkDraft) = synchronized(lock) { if (!state.value.busy && state.value.confirmation == null && state.value.draft != null) mutable.update { it.copy(draft = draft) } }
    fun closeEditor() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(draft = null, confirmation = null) } }
    fun requestCreate(): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false; val draft = state.value.draft ?: return false
        if (previous !== repo || state.value.busy || state.value.confirmation != null || draft.issue != null || !canStart()) return false
        try {
            if (state.value.networks.any { it.name == draft.name } || records(repo).any { row -> row.items.any { it.pending && it.target.overlaps(draft.identity()) } }) containerConflict()
            mutable.update { it.copy(confirmation = ContainerNetworkConfirmation.Create(draft), failure = null) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun requestDelete(targets: List<ContainerNetworkEntry>): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || !state.value.loaded || state.value.busy || state.value.confirmation != null || !canStart() || targets.isEmpty() ||
            targets.distinctBy { it.id }.size != targets.size || targets.any { !it.canDelete || it !in state.value.networks }) return false
        try {
            if (records(repo).any { row -> row.items.any { old -> old.pending && targets.any { old.target.overlaps(it.identity()) } } }) containerConflict()
            mutable.update { it.copy(confirmation = ContainerNetworkConfirmation.Delete(targets.toList()), failure = null) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun cancel() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm(expected: ContainerNetworkConfirmation): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.busy || state.value.confirmation != expected || !canStart() ||
            expected is ContainerNetworkConfirmation.Create && expected.draft != state.value.draft) return false
        mutable.update { it.copy(confirmation = null, draft = null) }
        launch(repo) { val owner = requireNotNull(repo.owner); store().execute(owner) {
            stillCurrent(repo)
            val record = when (expected) {
                is ContainerNetworkConfirmation.Create -> ContainerNetworkActivity(UUID.randomUUID().toString(), owner, ContainerNetworkOperation.CREATE, listOf(ContainerNetworkItem(expected.draft.identity())))
                is ContainerNetworkConfirmation.Delete -> ContainerNetworkActivity(UUID.randomUUID().toString(), owner, ContainerNetworkOperation.DELETE, expected.targets.map { ContainerNetworkItem(it.identity()) })
            }
            store().begin(record)
            fun checkpoint(index: Int, stage: ContainerStage) {
                if (stage == ContainerStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                store().checkpoint(owner, record.id, index, stage)
            }
            try {
                when (expected) {
                    is ContainerNetworkConfirmation.Create -> repo.containerManagement.createNetwork(expected.draft) { checkpoint(0, it) }
                    is ContainerNetworkConfirmation.Delete -> for ((index, target) in expected.targets.withIndex()) {
                        stillCurrent(repo); repo.containerManagement.deleteNetwork(target) { checkpoint(index, it) }
                        if (records(repo).single { it.id == record.id }.items[index].stage != ContainerStage.VERIFIED) break
                    }
                }
            } finally {
                records(repo).single { it.id == record.id }.items.forEachIndexed { index, item -> if (item.stage == ContainerStage.PREPARED) checkpoint(index, ContainerStage.CANCELLED) }
            }
            val networks = repo.containerManagement.networkDefinitions(); stillCurrent(repo)
            publish(repo) { it.copy(networks = networks, loaded = true) }; finish(repo)
        }; scope.launch { if (current(repo)) onChanged() } }; true
    }
    fun dismiss(id: String) = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        try { store().dismiss(requireNotNull(repo.owner), id); publish(repo) { it.copy(activities = records(repo), failure = null) } }
        catch (error: Exception) { failed(repo, error) }
    }
    private fun finish(repo: DsmRepository) { val activities = records(repo); publish(repo) { it.copy(busy = false, activities = activities, failure = null) } }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) {
        mutable.update { it.copy(busy = true, failure = null) }
        job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } }
    }
    private fun failed(repo: DsmRepository, error: Exception) {
        val activities = runCatching { records(repo) }.getOrNull()
        publish(repo) { it.copy(busy = false, confirmation = null, activities = activities ?: it.activities, failure = if (error is CancellationException) null else error) }
    }
}
