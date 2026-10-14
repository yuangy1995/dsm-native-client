package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasRegionEditorState(val original: NasRegionSettings? = null, val draft: NasRegionSettings? = null,
    val current: NasRegionSettings? = null, val busy: Boolean = false, val saving: Boolean = false,
    val result: MutationResult? = null, val failure: DsmFailure? = null, val record: NasRegionRecord? = null) {
    val blocked get() = busy || record?.terminal == false || failure?.kind == DsmErrorKind.LOCAL_STORAGE_FAILED
    val canSynchronize get() = !busy && failure?.kind != DsmErrorKind.LOCAL_STORAGE_FAILED && current?.isNetworkTimeEnabled == true &&
        (record?.terminal != false || record.canStartNewSync)
}

internal class NasRegionSettingsModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> NasRegionActivityStore, private val onChanged: () -> Unit = {},
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(NasRegionEditorState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? = synchronized(lock) {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        repo.requireCurrentOwner(); repo
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, block: (NasRegionEditorState) -> NasRegionEditorState) = synchronized(lock) { if (current(repo)) mutable.update(block) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = NasRegionEditorState() }
    fun begin(): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.blocked) return false
        val value = state.value.current ?: return false
        mutable.update { it.copy(original = value, draft = value.copy(manualDateTime = null), result = null, failure = null) }; true
    }
    fun draft(value: NasRegionSettings?) = synchronized(lock) {
        source() ?: return
        if (!state.value.blocked) mutable.update { it.copy(draft = value, original = it.original.takeIf { value != null }) }
    }
    fun dismiss(discard: Boolean = false) = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.blocked) return
        try {
            state.value.record?.let { store().discard(requireNotNull(repo.owner), it.id) }
            mutable.update { it.copy(result = null, failure = null, record = null,
                draft = it.draft.takeUnless { discard }, original = it.original.takeUnless { discard }) }
        } catch (error: Exception) { failed(repo, error) }
    }
    fun save(synchronizeOnly: Boolean = false, confirmed: NasRegionSettings? = null): Boolean = synchronized(lock) {
        val repo = source() ?: return false; val value = state.value
        if (if (synchronizeOnly) !value.canSynchronize || confirmed !== value.current else value.blocked) return false
        // 独立校时也绑定打开确认框时的快照，不能在确认后换成新的服务器。
        val original = if (synchronizeOnly) confirmed else value.original
        val desired = if (synchronizeOnly) confirmed else value.draft
        if (original == null || desired == null) return false
        launch(repo, saving = true) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                val plan = repo.nasRegion.plan(original, desired, synchronizeOnly)
                val record = NasRegionRecord(UUID.randomUUID().toString(), owner, regionDigest(plan.desired),
                    plan.steps.map { NasRegionStepRecord(it) }, plan.desired.manualDateTime?.regionSeconds().takeIf { plan.editsClock })
                repo.requireCurrentOwner(); store().begin(record)
                val result = repo.nasRegion.save(plan) { store().checkpoint(owner, record.id, it) }
                val saved = store().records(owner).single { it.id == record.id }
                val latest = if (result.submitted) runCatching { repo.nasRegion.load() }.getOrNull() else value.current
                publish(repo) { it.copy(busy = false, saving = false, current = latest, record = saved, result = result,
                    original = it.original.takeUnless { result.submitted }, draft = it.draft.takeUnless { result.submitted }) }
            }
            if (current(repo)) onChanged()
        }; true
    }
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                val records = store().records(owner)
                val actual = repo.nasRegion.load()
                for (record in records.filter { !it.terminal }) {
                    for (step in record.steps) {
                        if (step.stage == NasServiceStage.PREPARED) {
                            store().checkpoint(owner, record.id, NasRegionCheckpoint(step.step, NasServiceStage.CANCELLED)); continue
                        }
                        if (step.stage !in setOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED, NasServiceStage.VERIFIED)) continue
                        val matches = regionDigest(actual) == record.targetDigest && when (step.step) {
                            NasRegionStep.CONFIGURATION -> record.manualTargetSeconds == null || step.accepted && regionClockMatches(actual, record.manualTargetSeconds)
                            NasRegionStep.SYNCHRONIZATION -> step.accepted
                        }
                        if (matches && step.stage != NasServiceStage.VERIFIED) store().checkpoint(owner, record.id, NasRegionCheckpoint(step.step, NasServiceStage.VERIFIED))
                        if (!matches && step.stage == NasServiceStage.VERIFIED) store().checkpoint(owner, record.id, NasRegionCheckpoint(step.step, NasServiceStage.SUBMITTED))
                    }
                }
                val latest = store().records(owner).filter { it.supersededBy == null }.let { list -> list.firstOrNull { !it.terminal } ?: list.firstOrNull() }
                publish(repo) { it.copy(busy = false, saving = false, current = actual, record = latest, result = latest?.result(), failure = null) }
            }
        }
    }
    private fun launch(repo: DsmRepository, saving: Boolean = false, block: suspend () -> Unit) {
        mutable.update { it.copy(busy = true, saving = saving, failure = null) }
        job = scope.launch(dispatcher) {
            try { block() } catch (error: Exception) {
                if (error !is CancellationException) failed(repo, error)
                else publish(repo) { it.copy(busy = false, saving = false) }
            }
        }
    }
    private fun failed(repo: DsmRepository, error: Exception) {
        val record = runCatching { store().records(requireNotNull(repo.owner)).filter { it.supersededBy == null }.let { list -> list.firstOrNull { !it.terminal } ?: list.firstOrNull() } }.getOrNull()
        publish(repo) { it.copy(busy = false, saving = false, current = null, record = record ?: it.record, result = record?.result() ?: it.result,
            original = it.original.takeUnless { record?.result()?.submitted == true }, draft = it.draft.takeUnless { record?.result()?.submitted == true },
            failure = error as? DsmFailure ?: DsmFailure(null, "Region settings could not be loaded", "Reconnect and refresh settings.", kind = DsmErrorKind.REQUEST_FAILED)) }
    }
}
