package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class VmmCreationDiskDraft(val size: String = "20", val image: String? = null)
internal data class VmmCreationDraft(val step: Int = 0, val preset: VmmCreationPreset = VmmCreationPreset.GENERAL,
    val name: String = "", val description: String = "", val cpu: String = "1", val memory: String = "1024", val startup: Int = 0,
    val storage: String? = null, val disks: List<VmmCreationDiskDraft> = listOf(VmmCreationDiskDraft()),
    val networks: List<String?> = listOf(null), val uefi: Boolean = true, val iso: String? = null, val powerOn: Boolean = false) {
    val source get() = if (preset == VmmCreationPreset.GENERAL) VmmSource.PUBLIC else VmmSource.INTERNAL
    val basicsValid get() = validVmmSettingsName(name) && description.length <= 1024 && startup in 0..2
    val hardwareValid get() = cpu.toIntOrNull() in 1..64 && memory.toIntOrNull() in 128..1_048_576 &&
        disks.isNotEmpty() && disks.all { it.image != null || it.size.toIntOrNull() in (if (source == VmmSource.INTERNAL) 10 else 1)..1_048_576 }
    fun plan(resources: VmmCreationResources?): VmmCreationPlan? {
        if (resources == null || source != resources.source || !basicsValid || !hardwareValid) return null
        val selected = resources.storages.singleOrNull { it.ref.id == storage } ?: return null
        val diskPlans = disks.map { disk -> VmmCreationDisk(disk.size.toIntOrNull() ?: 20,
            disk.image?.let { id -> resources.images.singleOrNull { it.ref.id == id && it.type == "disk" }?.ref ?: return null }) }
        val networkPlans = networks.map { id -> id?.let { resources.networks.singleOrNull { it.id == id } ?: return null } }
        val selectedIso = iso?.let { id -> resources.images.singleOrNull { it.ref.id == id && it.storage == selected.ref.id && it.host == selected.host } ?: return null }
        return VmmCreationPlan(preset, VmmConfiguration(name, description, cpu.toInt(), memory.toInt(), if (source == VmmSource.INTERNAL) 256 else null, startup),
            selected, diskPlans, networkPlans, uefi, selectedIso, powerOn).takeIf { it.valid() }
    }
    override fun toString() = "VmmCreationDraft($preset)"
}
internal data class VmmCreationState(val loaded: Boolean = false, val busy: Boolean = false, val editor: Boolean = false,
    val sources: List<VmmSource> = emptyList(), val resources: VmmCreationResources? = null, val draft: VmmCreationDraft? = null,
    val powerAvailable: Boolean = false, val records: List<VmmCreationActivity> = emptyList(), val reviewId: String? = null, val activeId: String? = null, val failure: Exception? = null) {
    val plan get() = draft?.plan(resources)
    val canCreate get() = !busy && failure == null && plan != null && (!plan!!.powerOn || powerAvailable)
    val protectedIds get() = records.filter { it.pending }.mapNotNull { it.progress.guest?.let(::vmmDigest) }.toSet()
    fun protectedAssets(kind: VmmAssetKind) = records.filter { it.pending }.flatMap { record ->
        if (kind == VmmAssetKind.NETWORK) record.snapshot.plan.networks.mapNotNull { it?.id }
        else record.snapshot.plan.disks.mapNotNull { it.image?.id } + listOfNotNull(record.snapshot.plan.iso?.ref?.id)
    }.map(::vmmDigest).toSet()
    val review get() = records.singleOrNull { it.id == reviewId }
}

internal class VmmCreationModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> VmmCreationStore, private val canStart: (VmmCreationPlan?) -> Boolean,
    private val onChanged: () -> Unit = {}, private val dispatcher: CoroutineDispatcher = Dispatchers.IO, private val pollAttempts: Int = 120) {
    private val mutable = MutableStateFlow(VmmCreationState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (VmmCreationState) -> VmmCreationState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    private suspend fun stillCurrent(repo: DsmRepository) { repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo)) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = VmmCreationState() }
    private fun records(repo: DsmRepository) = store().records(requireNotNull(repo.owner))
    private fun checkpoint(repo: DsmRepository, id: String, progress: VmmCreationProgress) {
        repo.requireCurrentOwner(); check(current(repo)); store().checkpoint(requireNotNull(repo.owner), id, progress)
        publish(repo) { it.copy(records = records(repo)) }
    }
    private suspend fun recover(repo: DsmRepository): Exception? {
        var failure: Exception? = null
        for (record in records(repo).filter { it.pending }) {
            stillCurrent(repo)
            try {
                if (record.progress.stage == VmmCreationStage.PREPARED) checkpoint(repo, record.id, record.progress.copy(stage = VmmCreationStage.CANCELLED))
                else repo.virtualMachineManagement.resumeCreation(record.snapshot, record.progress) { checkpoint(repo, record.id, it) }
            } catch (error: Exception) {
                vmmRethrowCritical(error); if (error is VmmFailure && error.problem == VmmProblem.STORAGE) throw error
                if (failure == null) failure = error
            }
        }
        stillCurrent(repo)
        publish(repo) { it.copy(loaded = true, sources = repo.virtualMachineManagement.creationSources(), records = records(repo)) }
        return failure
    }
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        launch(repo) { val failure = store().execute(requireNotNull(repo.owner), wait = true) { stillCurrent(repo); recover(repo) }; finish(repo, failure) }
    }
    fun open(): Boolean = synchronized(lock) {
        val repo = source() ?: return false
        if (state.value.busy || state.value.editor || state.value.reviewId != null || !allowed(repo, null)) return false
        val sources = repo.virtualMachineManagement.creationSources(); val source = sources.firstOrNull() ?: return false
        mutable.update { it.copy(editor = true, sources = sources, resources = null, draft = VmmCreationDraft(preset = if (source == VmmSource.PUBLIC) VmmCreationPreset.GENERAL else VmmCreationPreset.LINUX)) }
        loadEditor(repo); true
    }
    fun retryEditor() = synchronized(lock) { val repo = source() ?: return; if (state.value.editor && !state.value.busy) loadEditor(repo) }
    private fun loadEditor(repo: DsmRepository) {
        val source = state.value.draft?.source ?: return
        launch(repo) {
            store().execute(requireNotNull(repo.owner), wait = true) {
                stillCurrent(repo)
                val resources = repo.virtualMachineManagement.creationResources(source)
                stillCurrent(repo)
                publish(repo) { it.copy(resources = resources, powerAvailable = repo.virtualMachineManagement.creationCanPowerOn(source),
                    draft = it.draft?.let { draft -> draft.copy(storage = draft.storage?.takeIf { id -> resources.storages.any { it.ref.id == id } } ?: resources.storages.firstOrNull()?.ref?.id) }) }
            }; finish(repo)
        }
    }
    fun change(draft: VmmCreationDraft) = synchronized(lock) {
        val repo = source() ?: return
        val old = state.value.draft ?: return
        if (!state.value.editor || state.value.busy || state.value.failure != null || draft.step !in 0..2 || draft.source !in state.value.sources) return
        if (draft.step > old.step && (draft.step != old.step + 1 || old.step == 0 && !old.basicsValid || old.step == 1 && !old.hardwareValid)) return
        if (draft.source != old.source) {
            mutable.update { it.copy(resources = null, draft = draft.copy(step = 0, storage = null, iso = null, disks = listOf(VmmCreationDiskDraft()), networks = listOf(null), powerOn = false)) }
            loadEditor(repo)
        } else mutable.update { it.copy(draft = if (old.storage != draft.storage) draft.copy(iso = null) else draft) }
    }
    fun close() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(editor = false, resources = null, draft = null, reviewId = null, failure = null) } }
    private fun allowed(repo: DsmRepository, plan: VmmCreationPlan?) = try { canStart(plan) } catch (error: Exception) { failed(repo, error); false }
    fun create(): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false; val plan = state.value.plan ?: return false
        if (previous !== repo || !state.value.editor || !state.value.canCreate || !allowed(repo, plan)) return false
        launch(repo) {
            val owner = requireNotNull(repo.owner); val id = UUID.randomUUID().toString()
            publish(repo) { it.copy(activeId = id) }
            try {
                store().execute(owner) {
                    stillCurrent(repo); if (!allowed(repo, plan)) vmmConflict()
                    repo.virtualMachineManagement.createGuest(plan, id, prepared = { snapshot ->
                        repo.requireCurrentOwner(); check(current(repo)); store().begin(VmmCreationActivity(owner, snapshot))
                    }, checkpoint = { checkpoint(repo, id, it) }, pollAttempts = pollAttempts)
                }
            } finally {
                records(repo).singleOrNull { it.id == id && it.progress.stage == VmmCreationStage.PREPARED }?.let {
                    store().checkpoint(owner, id, it.progress.copy(stage = VmmCreationStage.CANCELLED))
                }
                publish(repo) { it.copy(editor = false, resources = null, draft = null, activeId = null, records = records(repo)) }
                scope.launch { if (current(repo)) onChanged() }
            }
            finish(repo)
        }; true
    }
    fun review(id: String): Boolean = synchronized(lock) {
        val repo = source() ?: return false
        if (state.value.busy || state.value.editor || records(repo).none { it.id == id && it.progress.stage.canContinue }) return false
        publish(repo) { it.copy(reviewId = id, records = records(repo), failure = null) }; true
    }
    fun continueCreation(): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false; val review = state.value.review ?: return false
        if (previous !== repo || state.value.busy || !review.progress.stage.canContinue || !allowed(repo, review.snapshot.plan)) return false
        launch(repo) {
            publish(repo) { it.copy(activeId = review.id) }
            try {
                store().execute(requireNotNull(repo.owner)) {
                    stillCurrent(repo); if (!allowed(repo, review.snapshot.plan)) vmmConflict()
                    val record = records(repo).single { it.id == review.id }
                    if (record != review) vmmConflict()
                    repo.virtualMachineManagement.resumeCreation(record.snapshot, record.progress, allowWrite = true, pollAttempts = pollAttempts) { checkpoint(repo, record.id, it) }
                }
            } finally { publish(repo) { it.copy(reviewId = null, activeId = null) }; scope.launch { if (current(repo)) onChanged() } }
            finish(repo)
        }; true
    }
    fun hasPending(): Boolean = synchronized(lock) {
        val repo = source() ?: return true
        try { state.value.busy || state.value.editor || state.value.reviewId != null || records(repo).any { it.pending } }
        catch (error: Exception) { failed(repo, error); true }
    }
    fun dismiss(id: String) = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        try { store().dismiss(requireNotNull(repo.owner), id); publish(repo) { it.copy(records = records(repo), failure = null) } }
        catch (error: Exception) { failed(repo, error) }
    }
    private fun finish(repo: DsmRepository, failure: Exception? = null) = publish(repo) { it.copy(busy = false, loaded = true, sources = repo.virtualMachineManagement.creationSources(), records = records(repo), failure = failure) }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) { mutable.update { it.copy(busy = true, failure = null) }; job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } } }
    private fun failed(repo: DsmRepository, error: Exception) {
        val activities = runCatching { records(repo) }.getOrNull()
        publish(repo) { it.copy(busy = false, sources = repo.virtualMachineManagement.creationSources(), records = activities ?: it.records, failure = if (error is CancellationException) null else error) }
    }
}
