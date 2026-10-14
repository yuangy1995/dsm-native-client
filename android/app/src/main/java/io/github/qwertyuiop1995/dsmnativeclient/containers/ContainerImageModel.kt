package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal sealed interface ContainerImageConfirmation {
    data class Pull(val repository: String, val tag: String) : ContainerImageConfirmation
    data class Delete(val targets: List<ContainerImageEntry>) : ContainerImageConfirmation
}
internal data class ContainerImageState(val loaded: Boolean = false, val busy: Boolean = false, val images: List<ContainerImageEntry> = emptyList(),
    val confirmation: ContainerImageConfirmation? = null, val activities: List<ContainerImageActivity> = emptyList(),
    val readings: Map<String, ContainerImagePullReading> = emptyMap(), val failure: Exception? = null, val usageAvailable: Boolean = true)

/** 下载只追踪原 task_id；页面离开停止轮询，NAS 下载不被冒充取消。 */
internal class ContainerImageModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> ContainerImageStore, private val canStart: () -> Boolean, private val onChanged: () -> Unit = {},
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(ContainerImageState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (ContainerImageState) -> ContainerImageState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = ContainerImageState() }
    private suspend fun stillCurrent(repo: DsmRepository) { repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo)) }
    private fun records(repo: DsmRepository) = store().records(requireNotNull(repo.owner))
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        mutable.update { it.copy(confirmation = null) }
        launch(repo) { store().execute(requireNotNull(repo.owner)) {
            for (record in records(repo)) {
                if (record.stage == ContainerStage.PREPARED) store().checkpoint(requireNotNull(repo.owner), record.id, ContainerStage.CANCELLED)
                else if (record.pending) review(repo, record)
            }
            loadImages(repo); finish(repo)
        } }
    }
    fun poll() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy || state.value.confirmation != null || !canStart()) return
        val tasks = state.value.activities.filter { it.operation == ContainerImageOperation.PULL && it.pending && it.task != null }
        if (tasks.isEmpty()) return
        launch(repo) {
            val completed = store().execute(requireNotNull(repo.owner)) {
                for (record in tasks) { stillCurrent(repo); review(repo, record) }
                val completed = records(repo).any { it.id in tasks.map { row -> row.id } && it.stage == ContainerStage.VERIFIED }
                if (completed) loadImages(repo)
                finish(repo)
                completed
            }
            if (completed) scope.launch { if (current(repo)) onChanged() }
        }
    }
    fun requestPull(repository: String, tag: String): Boolean = synchronized(lock) {
        val repo = source() ?: return false
        if (state.value.busy || state.value.confirmation != null || !canStart() || !validImageTarget(repository, tag)) return false
        try {
            val reference = containerDigest(imageReference(repository, tag))
            if (records(repo).any { it.pending && (it.reference == reference || it.targets.any { target -> target.reference == reference }) }) containerConflict()
            mutable.update { it.copy(confirmation = ContainerImageConfirmation.Pull(repository, tag), failure = null, activities = records(repo)) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun requestDelete(targets: List<ContainerImageEntry>): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.busy || state.value.confirmation != null || !state.value.loaded || !canStart() ||
            targets.isEmpty() || targets.distinctBy { it.id }.size != targets.size || targets.any { !it.canDelete || it !in state.value.images }) return false
        try {
            val draft = ContainerImageActivity("draft", requireNotNull(repo.owner), ContainerImageOperation.DELETE, targets = targets.map { it.identity() })
            if (records(repo).any { it.pending && it.overlaps(draft) }) containerConflict()
            mutable.update { it.copy(confirmation = ContainerImageConfirmation.Delete(targets.toList()), failure = null) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun cancel() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm(expected: ContainerImageConfirmation): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.busy || state.value.confirmation != expected || !canStart()) return false
        mutable.update { it.copy(confirmation = null) }
        launch(repo) { val owner = requireNotNull(repo.owner); store().execute(owner) {
            stillCurrent(repo)
            val id = UUID.randomUUID().toString()
            when (expected) {
                is ContainerImageConfirmation.Pull -> {
                    val plan = repo.containerManagement.prepareImagePull(expected.repository, expected.tag)
                    stillCurrent(repo)
                    store().begin(ContainerImageActivity(id, owner, ContainerImageOperation.PULL, reference = plan.reference, baselineIds = plan.baselineIds))
                    repo.containerManagement.startImagePull(plan) { stage, task ->
                        if (stage == ContainerStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                        store().checkpoint(owner, id, stage, task)
                    }
                    review(repo, records(repo).single { it.id == id })
                }
                is ContainerImageConfirmation.Delete -> {
                    store().begin(ContainerImageActivity(id, owner, ContainerImageOperation.DELETE, targets = expected.targets.map { it.identity() }))
                    val removed = repo.containerManagement.deleteImages(expected.targets) { stage ->
                        if (stage == ContainerStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                        store().checkpoint(owner, id, stage)
                    }
                    store().reviewDelete(owner, id, removed)
                }
            }
            stillCurrent(repo); loadImages(repo); finish(repo)
        }; scope.launch { if (current(repo)) onChanged() } }; true
    }
    fun dismiss(id: String) = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        try { store().dismiss(requireNotNull(repo.owner), id); publish(repo) { it.copy(activities = records(repo), readings = it.readings - id, failure = null) } }
        catch (error: Exception) { failed(repo, error) }
    }
    private suspend fun review(repo: DsmRepository, record: ContainerImageActivity) {
        if (!record.pending || record.stage == ContainerStage.PREPARED) return
        stillCurrent(repo); val owner = requireNotNull(repo.owner)
        if (record.operation == ContainerImageOperation.DELETE) {
            val removed = repo.containerManagement.removedImages(record.targets); stillCurrent(repo); store().reviewDelete(owner, record.id, removed)
        } else if (record.task != null) {
            val result = repo.containerManagement.readImagePull(requireNotNull(record.reference), record.task)
            stillCurrent(repo)
            if (result.failed) store().checkpoint(owner, record.id, ContainerStage.REJECTED)
            else if (result.finished) store().checkpoint(owner, record.id, ContainerStage.VERIFIED)
            publish(repo) { it.copy(readings = it.readings + (record.id to result)) }
        }
    }
    private suspend fun loadImages(repo: DsmRepository) {
        val images = repo.containerManagement.imageDefinitions()
        val used = try { repo.containerManagement.imageUsage(images) } catch (error: Exception) {
            if (error is CancellationException || error is DsmFailure && error.kind in setOf(DsmErrorKind.TLS_UNTRUSTED, DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.AUTHENTICATION_FAILED, DsmErrorKind.WORKSPACE_CHANGED)) throw error
            null
        }
        stillCurrent(repo); publish(repo) { it.copy(images = used ?: images, loaded = true, usageAvailable = used != null) }
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
