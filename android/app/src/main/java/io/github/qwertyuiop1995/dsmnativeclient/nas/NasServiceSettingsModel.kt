package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasServiceEditorState(val current: NasServiceValue? = null, val loaded: Boolean = false, val original: NasServiceValue? = null, val draft: NasServiceValue? = null,
    val busy: Boolean = false, val saving: Boolean = false, val result: MutationResult? = null, val failure: DsmFailure? = null, val record: NasServiceRecord? = null,
    val needsAssociation: Boolean = false, val canAssociate: Boolean = false) {
    val blocked get() = busy || needsAssociation || record?.terminal == false || failure?.kind == DsmErrorKind.LOCAL_STORAGE_FAILED
}
/** 编辑原值和持久恢复由本模型唯一拥有；换账号清除表单，已提交记录保留在原账号。 */
internal class NasServiceSettingsModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> NasServiceActivityStore, private val onChanged: () -> Unit = {},
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(NasServiceKind.entries.associateWith { NasServiceEditorState() }); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private val jobs = mutableMapOf<NasServiceKind, Job>()
    private fun source(): DsmRepository? = synchronized(lock) {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        repo.requireCurrentOwner(); repo
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, kind: NasServiceKind, block: (NasServiceEditorState) -> NasServiceEditorState) = synchronized(lock) { if (current(repo)) update(kind, block) }
    private fun update(kind: NasServiceKind, block: (NasServiceEditorState) -> NasServiceEditorState) { mutable.update { it + (kind to block(it.getValue(kind))) } }
    fun clear() = synchronized(lock) {
        jobs.values.toList().forEach(Job::cancel); jobs.clear(); bound = null
        mutable.value = NasServiceKind.entries.associateWith { NasServiceEditorState() }
    }
    fun begin(value: NasServiceValue): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo) return false
        if (state.value.getValue(value.kind).blocked) return false
        update(value.kind) { it.copy(original = value, draft = value, result = null, failure = null) }; true
    }
    fun draft(kind: NasServiceKind, value: NasServiceValue?) = synchronized(lock) {
        source() ?: return
        if (!state.value.getValue(kind).blocked && (value == null || value.kind == kind)) update(kind) {
            it.copy(draft = value, original = it.original.takeIf { value != null })
        }
    }
    fun dismiss(kind: NasServiceKind, discard: Boolean = false) = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.getValue(kind).blocked) return
        try {
            state.value.getValue(kind).record?.let { store().discard(requireNotNull(repo.owner), it.id) }
            update(kind) { it.copy(result = null, failure = null, record = null,
                original = it.original.takeUnless { discard }, draft = it.draft.takeUnless { discard }) }
        } catch (error: Exception) { failed(repo, kind, error) }
    }
    fun save(kind: NasServiceKind): Boolean = synchronized(lock) {
        val repo = source() ?: return false; val value = state.value.getValue(kind)
        if (value.blocked || value.original == null || value.draft == null) return false
        launch(repo, kind, saving = true) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner, kind) {
                if (store().records(owner).any { it.kind == kind && !it.terminal }) serviceConflict()
                val plan = repo.nasServices.plan(value.original, value.draft)
                val id = UUID.randomUUID().toString()
                val record = NasServiceRecord(id, owner, kind, plan.steps.map { NasServiceStepRecord(it, serviceDigest(it, plan.desired.groups().getValue(it)), requiresTask = it == NasServiceStep.FIREWALL && plan.requiresFirewallTask) },
                    targetId = (plan.desired as? NasServiceValue.Ethernet)?.settings?.id,
                    accountDigest = repo.nasAccountDigest.takeIf { kind == NasServiceKind.ETHERNET })
                repo.requireCurrentOwner(); store().begin(record)
                val result = repo.nasServices.save(plan) { store().checkpoint(owner, id, it) }
                val saved = store().records(owner).single { it.id == id }
                publish(repo, kind) { it.copy(busy = false, saving = false, record = saved, result = result,
                    original = it.original.takeUnless { result.submitted },
                    draft = it.draft.takeUnless { result.submitted }) }
            }
            if (kind in independentServiceKinds) refresh(kind, notify = false)
            if (current(repo)) onChanged()
        }; true
    }
    fun continuePendingStep(record: NasServiceRecord): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false; val kind = record.kind
        val value = state.value.getValue(kind)
        if (previous !== repo || value.blocked || value.draft != null || value.record != record || record.continuationStep == null) return false
        launch(repo, kind, saving = true) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner, kind) {
                if (store().records(owner).singleOrNull { it.id == record.id } != record || store().records(owner).any { it.kind == kind && !it.terminal }) serviceConflict()
                val current = repo.nasServices.load(kind)
                val step = record.continuationStep ?: serviceConflict()
                val first = if (step == NasServiceStep.LED_UPDATE) NasServiceStep.LED_BRIGHTNESS else NasServiceStep.ZRAM
                val target = record.steps.single { it.step == first }.targetDigest
                if (current.groups()[first]?.let { serviceDigest(first, it) } != target) serviceConflict()
                val plan = repo.nasServices.plan(current, current, continuation = step)
                repo.requireCurrentOwner(); store().prepareContinuation(owner, record.id)
                repo.nasServices.save(plan) { store().checkpoint(owner, record.id, it) }
                val saved = store().records(owner).single { it.id == record.id }
                publish(repo, kind) { it.copy(busy = false, saving = false, record = saved, result = saved.result(), original = null, draft = null) }
            }
            if (kind in independentServiceKinds) refresh(kind, notify = false)
            if (current(repo)) onChanged()
        }; true
    }
    fun load() { NasServiceKind.entries.forEach { refresh(it, notify = false) } }
    fun refresh(kind: NasServiceKind, notify: Boolean = true, associate: NasServiceRecord? = null) = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.getValue(kind).busy) return
        launch(repo, kind) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner, kind) {
                if (associate != null) {
                    if (kind != NasServiceKind.ETHERNET || state.value.getValue(kind).record != associate) serviceConflict()
                    repo.requireCurrentOwner(); store().associateEthernet(owner, repo.nasAccountDigest, associate.id)
                }
                val records = store().records(owner).filter { it.kind == kind }
                val pending = records.firstOrNull { !it.terminal && !it.accessibleTo(owner) }
                if (pending != null) {
                    publish(repo, kind) { it.copy(busy = false, saving = false, record = pending, result = pending.result(), failure = null,
                        needsAssociation = true, canAssociate = pending.canAssociate(owner, repo.nasAccountDigest), original = null, draft = null) }
                    return@execute
                }
                for (record in records.filter { !it.terminal }) {
                    // 准备中退出从未提交，恢复时取消；余下未知组只能读取，不能补发。
                    for (step in record.steps.filter { it.stage == NasServiceStage.PREPARED }) store().checkpoint(owner, record.id, NasServiceCheckpoint(step.step, NasServiceStage.CANCELLED))
                    // 先读取原任务终态，再读取配置，避免任务刚完成时使用更早的快照。
                    for (step in record.steps.filter { it.requiresTask && it.stage in setOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED) }) {
                        var task = step.task
                        if (task != null && task.outcome == null) {
                            repo.nasServices.firewallTaskStatus(task.id)?.let { outcome ->
                                task = task!!.copy(outcome = outcome)
                                store().checkpoint(owner, record.id, NasServiceCheckpoint(step.step, step.stage, task))
                            }
                        }
                        if (task?.outcome == false) store().checkpoint(owner, record.id, NasServiceCheckpoint(step.step, NasServiceStage.REJECTED))
                    }
                    val steps = store().records(owner).single { it.id == record.id }.steps
                    val actual = if (steps.any { it.stage in setOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED, NasServiceStage.VERIFIED) }) repo.nasServices.load(kind, record.targetId).groups() else emptyMap()
                    for (step in steps.filter { it.stage in setOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED, NasServiceStage.VERIFIED) }) {
                        val matches = (!step.step.requiresAcceptance || step.accepted) && (!step.requiresTask || step.task?.outcome == true) && actual[step.step]?.let { serviceDigest(step.step, it) } == step.targetDigest
                        if (matches && step.stage != NasServiceStage.VERIFIED) store().checkpoint(owner, record.id, NasServiceCheckpoint(step.step, NasServiceStage.VERIFIED))
                        if (!matches && step.stage == NasServiceStage.VERIFIED) store().checkpoint(owner, record.id, NasServiceCheckpoint(step.step, NasServiceStage.SUBMITTED))
                    }
                }
                val currentValue = if (kind in independentServiceKinds) repo.nasServices.load(kind) else null
                val updated = store().records(owner).filter { it.kind == kind }
                val latest = updated.firstOrNull { !it.terminal } ?: updated.firstOrNull()
                publish(repo, kind) { it.copy(busy = false, saving = false, record = latest, result = latest?.result(), failure = null, needsAssociation = false, canAssociate = false, current = currentValue ?: it.current, loaded = true) }
            }
            if (notify && current(repo)) onChanged()
        }
    }
    fun associateEthernet(record: NasServiceRecord): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        val value = state.value.getValue(NasServiceKind.ETHERNET)
        if (previous !== repo || value.busy || !value.needsAssociation || !value.canAssociate || value.record != record) return false
        refresh(NasServiceKind.ETHERNET, associate = record); true
    }
    private fun launch(repo: DsmRepository, kind: NasServiceKind, saving: Boolean = false, block: suspend () -> Unit) {
        update(kind) { it.copy(busy = true, saving = saving, failure = null) }
        jobs[kind] = scope.launch(dispatcher) {
            try { block() } catch (error: Exception) {
                if (error !is CancellationException) failed(repo, kind, error)
                else publish(repo, kind) { it.copy(busy = false, saving = false) }
            }
        }
    }
    private fun failed(repo: DsmRepository, kind: NasServiceKind, error: Exception) {
        val record = runCatching { store().records(requireNotNull(repo.owner)).filter { it.kind == kind }.let { records -> records.firstOrNull { !it.terminal } ?: records.firstOrNull() } }.getOrNull()
        publish(repo, kind) { it.copy(busy = false, saving = false, record = record ?: it.record,
            result = record?.result() ?: it.result,
            needsAssociation = record?.let { saved -> !saved.terminal && !saved.accessibleTo(requireNotNull(repo.owner)) } == true,
            canAssociate = record?.canAssociate(requireNotNull(repo.owner), repo.nasAccountDigest) == true,
            loaded = true, original = it.original.takeUnless { record?.result()?.submitted == true }, draft = it.draft.takeUnless { record?.result()?.submitted == true }, failure = error as? DsmFailure ?: DsmFailure(null, "Service settings could not be saved", "Refresh settings and try again.", kind = DsmErrorKind.REQUEST_FAILED)) }
    }
}

private val independentServiceKinds = setOf(NasServiceKind.MEMORY_COMPRESSION, NasServiceKind.POWER_SCHEDULE)
