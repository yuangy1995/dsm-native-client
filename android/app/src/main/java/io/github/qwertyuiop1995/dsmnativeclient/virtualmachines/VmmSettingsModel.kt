package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class VmmSettingsDraft(val name: String, val description: String?, val cpu: String?, val memory: String?, val priority: Int?, val startup: Int?) {
    fun configuration() = VmmConfiguration(name, description, cpu?.toIntOrNull(), memory?.toIntOrNull(), priority, startup)
    companion object { fun from(value: VmmConfiguration) = VmmSettingsDraft(value.name, value.description, value.cpu?.toString(), value.memoryMiB?.toString(), value.priority, value.startup) }
}
internal data class VmmSettingsState(val loaded: Boolean = false, val busy: Boolean = false, val editor: Boolean = false,
    val target: String? = null, val baseline: VmmSettings? = null, val draft: VmmSettingsDraft? = null,
    val records: List<VmmSettingsActivity> = emptyList(), val failure: Exception? = null) {
    val protectedIds get() = records.filter { it.pending }.map { it.target }.toSet()
    val canSave get() = !busy && failure == null && baseline != null && draft != null && baseline.validChange(draft.configuration())
}

internal class VmmSettingsModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> VmmSettingsStore, private val canStart: (String) -> Boolean,
    private val onChanged: () -> Unit = {}, private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(VmmSettingsState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (VmmSettingsState) -> VmmSettingsState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = VmmSettingsState() }
    private suspend fun stillCurrent(repo: DsmRepository) { repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo)) }
    private fun records(repo: DsmRepository) = store().records(requireNotNull(repo.owner))
    private suspend fun recover(repo: DsmRepository) {
        val owner = requireNotNull(repo.owner)
        for (record in records(repo)) {
            stillCurrent(repo)
            if (record.stage == VmmStage.PREPARED) store().checkpoint(owner, record.id, VmmStage.CANCELLED)
            if (record.stage == VmmStage.ACCEPTED && repo.virtualMachineManagement.recoverSettings(record.target, record.desired, record.source))
                store().checkpoint(owner, record.id, VmmStage.VERIFIED)
        }
        stillCurrent(repo)
        publish(repo) { it.copy(loaded = true, records = records(repo)) }
    }
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        launch(repo) {
            store().execute(requireNotNull(repo.owner), wait = true) { stillCurrent(repo); recover(repo) }
            finish(repo)
        }
    }
    fun open(id: String): Boolean = synchronized(lock) {
        val repo = source() ?: return false
        if (state.value.busy || state.value.editor || !validVmmId(id) || !allowed(repo, id)) return false
        mutable.update { it.copy(editor = true, target = id, baseline = null, draft = null) }
        loadEditor(repo, id); true
    }
    fun retryEditor() = synchronized(lock) {
        val repo = source() ?: return
        val id = state.value.target ?: return
        if (!state.value.editor || state.value.busy) return
        loadEditor(repo, id)
    }
    private fun loadEditor(repo: DsmRepository, id: String) = launch(repo) {
        store().execute(requireNotNull(repo.owner), wait = true) {
            stillCurrent(repo); recover(repo)
            if (records(repo).any { it.pending && it.target == vmmDigest(id) } || !allowed(repo, id)) vmmConflict()
            val baseline = repo.virtualMachineManagement.settings(id)
            stillCurrent(repo)
            publish(repo) { it.copy(baseline = baseline, draft = VmmSettingsDraft.from(baseline.configuration)) }
        }
        finish(repo)
    }
    fun change(draft: VmmSettingsDraft) = synchronized(lock) {
        if (state.value.editor && !state.value.busy && state.value.baseline != null && state.value.failure == null) mutable.update { it.copy(draft = draft) }
    }
    fun close() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(editor = false, target = null, baseline = null, draft = null) } }
    private fun allowed(repo: DsmRepository, id: String): Boolean = try { canStart(id) } catch (error: Exception) { failed(repo, error); false }
    fun save(): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        val baseline = state.value.baseline ?: return false; val desired = state.value.draft?.configuration() ?: return false
        if (previous !== repo || !state.value.editor || !state.value.canSave || !allowed(repo, baseline.id)) return false
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                stillCurrent(repo)
                if (!allowed(repo, baseline.id)) vmmConflict()
                val source = baseline.writeSource(desired)
                val activity = VmmSettingsActivity(UUID.randomUUID().toString(), owner, vmmDigest(baseline.id),
                    vmmDigest(baseline.configuration.name.lowercase()), vmmDigest(desired.name.lowercase()), desired.digest(source), source)
                store().begin(activity)
                try {
                    repo.virtualMachineManagement.saveSettings(baseline, desired) { stage ->
                        repo.requireCurrentOwner(); check(current(repo)); store().checkpoint(owner, activity.id, stage)
                    }
                } finally {
                    if (records(repo).single { it.id == activity.id }.stage == VmmStage.PREPARED) store().checkpoint(owner, activity.id, VmmStage.CANCELLED)
                    publish(repo) { it.copy(editor = false, target = null, baseline = null, draft = null) }
                }
                stillCurrent(repo); finish(repo)
            }
            scope.launch { if (current(repo)) onChanged() }
        }; true
    }
    fun hasPending(id: String? = null): Boolean = synchronized(lock) {
        val repo = source() ?: return true
        try { state.value.busy || state.value.editor || records(repo).any { it.pending && (id == null || it.target == vmmDigest(id)) } }
        catch (error: Exception) { failed(repo, error); true }
    }
    fun dismiss() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        try { records(repo).filter { !it.pending }.forEach { store().dismiss(requireNotNull(repo.owner), it.id) }; publish(repo) { it.copy(records = records(repo), failure = null) } }
        catch (error: Exception) { failed(repo, error) }
    }
    private fun finish(repo: DsmRepository) = publish(repo) { it.copy(busy = false, records = records(repo), failure = null) }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) {
        mutable.update { it.copy(busy = true, failure = null) }
        job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } }
    }
    private fun failed(repo: DsmRepository, error: Exception) {
        val activities = runCatching { records(repo) }.getOrNull()
        publish(repo) { it.copy(busy = false, records = activities ?: it.records, failure = if (error is CancellationException) null else error) }
    }
}
