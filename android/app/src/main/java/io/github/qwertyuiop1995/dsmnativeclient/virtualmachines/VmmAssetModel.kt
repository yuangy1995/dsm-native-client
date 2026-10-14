package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class VmmAssetConfirmation(val kind: VmmAssetKind, val action: VmmAssetAction,
    val networks: List<VmmNetwork> = emptyList(), val images: List<VmmImage> = emptyList(), val newName: String? = null)
internal data class VmmAssetState(val busy: Boolean = false, val networks: VmmNetworkInventory? = null, val images: VmmImageInventory? = null,
    val confirmation: VmmAssetConfirmation? = null, val records: List<VmmAssetActivity> = emptyList(), val failure: Exception? = null) {
    val blocked get() = busy || confirmation != null || failure != null
    fun protectedIds(kind: VmmAssetKind) = records.filter { it.kind == kind }.flatMap { it.items }.filter { it.pending }.map { it.id }.toSet()
}

/** 网络与映像沿同一逐项回执语义；恢复只读原来源，不自动续批或覆盖占用。 */
internal class VmmAssetModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> VmmAssetStore, private val canStart: (VmmAssetConfirmation) -> Boolean,
    private val onChanged: () -> Unit = {}, private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(VmmAssetState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (VmmAssetState) -> VmmAssetState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = VmmAssetState() }
    private suspend fun stillCurrent(repo: DsmRepository) { repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo)) }
    private fun records(repo: DsmRepository) = store().records(requireNotNull(repo.owner))
    private suspend fun read(repo: DsmRepository, kind: VmmAssetKind) {
        when (kind) {
            VmmAssetKind.NETWORK -> { val value = repo.virtualMachineManagement.networkInventory(); stillCurrent(repo); publish(repo) { it.copy(networks = value) } }
            VmmAssetKind.IMAGE -> { val value = repo.virtualMachineManagement.imageInventory(); stillCurrent(repo); publish(repo) { it.copy(images = value) } }
        }
    }
    fun refresh(kind: VmmAssetKind) = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner, wait = true) {
                stillCurrent(repo)
                for (activity in records(repo)) for ((index, item) in activity.items.withIndex()) {
                    if (item.stage == VmmStage.PREPARED) store().checkpoint(owner, activity.id, index, VmmStage.CANCELLED)
                }
                publish(repo) { it.copy(records = records(repo)) }
                read(repo, kind)
                for (activity in records(repo).filter { it.kind == kind }) for ((index, item) in activity.items.withIndex()) {
                    if (item.stage != VmmStage.ACCEPTED) continue
                    val verified = when (kind) {
                        VmmAssetKind.NETWORK -> repo.virtualMachineManagement.recoverNetwork(item.id, requireNotNull(item.topology), item.desiredName)
                        VmmAssetKind.IMAGE -> repo.virtualMachineManagement.recoverImage(item.id, item.source)
                    }
                    stillCurrent(repo)
                    if (verified) store().checkpoint(owner, activity.id, index, VmmStage.VERIFIED)
                }
                finish(repo)
            }
        }
    }
    private fun allowed(repo: DsmRepository, confirmation: VmmAssetConfirmation): Boolean = try { canStart(confirmation) } catch (error: Exception) { failed(repo, error); false }
    fun saveNetworkName(target: VmmNetwork, name: String): Boolean = synchronized(lock) {
        if (!requestNetworks(listOf(target), name)) return false
        confirm(requireNotNull(state.value.confirmation))
    }
    fun requestNetworks(targets: List<VmmNetwork>, newName: String? = null): Boolean = request(VmmAssetConfirmation(VmmAssetKind.NETWORK,
        if (newName == null) VmmAssetAction.DELETE else VmmAssetAction.RENAME, networks = targets, newName = newName))
    fun requestImages(targets: List<VmmImage>): Boolean = request(VmmAssetConfirmation(VmmAssetKind.IMAGE, VmmAssetAction.DELETE, images = targets))
    private fun request(confirmation: VmmAssetConfirmation): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.blocked || !allowed(repo, confirmation)) return false
        val valid = when (confirmation.kind) {
            VmmAssetKind.NETWORK -> state.value.networks?.let { inventory -> !inventory.frozen && confirmation.networks.isNotEmpty() &&
                confirmation.networks.all { it in inventory.networks } && confirmation.networks.distinctBy { it.id }.size == confirmation.networks.size &&
                (confirmation.newName == null || confirmation.networks.size == 1 && validVmmNetworkName(confirmation.newName) && confirmation.newName != confirmation.networks.single().name) } == true
            VmmAssetKind.IMAGE -> state.value.images?.let { inventory -> !inventory.frozen && confirmation.images.isNotEmpty() &&
                confirmation.images.all { it in inventory.images && it.canDelete } && confirmation.images.distinctBy { it.id }.size == confirmation.images.size } == true
        }
        if (!valid) return false
        try {
            val ids = confirmation.networks.map { vmmDigest(it.id) } + confirmation.images.map { vmmDigest(it.id) }
            if (records(repo).filter { it.kind == confirmation.kind }.flatMap { it.items }.any { it.pending && it.id in ids }) return false
            mutable.update { it.copy(confirmation = confirmation, failure = null) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun cancel() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm(expected: VmmAssetConfirmation): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.busy || state.value.failure != null || state.value.confirmation != expected || !allowed(repo, expected)) return false
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                stillCurrent(repo); if (!allowed(repo, expected)) vmmConflict()
                val items = when (expected.kind) {
                    VmmAssetKind.NETWORK -> expected.networks.map { VmmAssetItem(vmmDigest(it.id), it.identity, vmmDigest(it.name), VmmSource.INTERNAL,
                        it.topology, expected.newName?.let(::vmmDigest), it.guests.map { guest -> vmmDigest(guest.id) }.toSet()) }
                    VmmAssetKind.IMAGE -> expected.images.map { VmmAssetItem(vmmDigest(it.id), it.identity, vmmDigest(requireNotNull(it.name)), it.source) }
                }
                val activity = VmmAssetActivity(UUID.randomUUID().toString(), owner, expected.kind, expected.action, items)
                records(repo).filter { !it.pending }.forEach { store().dismiss(owner, it.id) }
                store().begin(activity); publish(repo) { it.copy(records = records(repo)) }
                try {
                    for (index in items.indices) {
                        stillCurrent(repo)
                        val checkpoint: (VmmStage) -> Unit = { stage ->
                            if (stage == VmmStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                            store().checkpoint(owner, activity.id, index, stage)
                        }
                        when (expected.kind) {
                            VmmAssetKind.NETWORK -> repo.virtualMachineManagement.mutateNetwork(expected.networks[index], expected.newName, checkpoint)
                            VmmAssetKind.IMAGE -> repo.virtualMachineManagement.deleteImage(expected.images[index], checkpoint)
                        }
                        if (records(repo).single { it.id == activity.id }.items[index].stage != VmmStage.VERIFIED) break
                    }
                } finally {
                    records(repo).single { it.id == activity.id }.items.forEachIndexed { index, item ->
                        if (item.stage == VmmStage.PREPARED) store().checkpoint(owner, activity.id, index, VmmStage.CANCELLED)
                    }
                }
                read(repo, expected.kind); finish(repo)
            }
            scope.launch { if (current(repo)) onChanged() }
        }; true
    }
    fun dismiss() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        try { records(repo).filter { !it.pending }.forEach { store().dismiss(requireNotNull(repo.owner), it.id) }; publish(repo) { it.copy(records = records(repo), failure = null) } }
        catch (error: Exception) { failed(repo, error) }
    }
    private fun finish(repo: DsmRepository) { val saved = records(repo); publish(repo) { it.copy(busy = false, records = saved, failure = null) } }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) { mutable.update { it.copy(busy = true, failure = null) }; job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } } }
    private fun failed(repo: DsmRepository, error: Exception) {
        val saved = runCatching { records(repo) }.getOrNull()
        publish(repo) { it.copy(busy = false, confirmation = null, records = saved ?: it.records, failure = if (error is CancellationException) null else error) }
    }
}
