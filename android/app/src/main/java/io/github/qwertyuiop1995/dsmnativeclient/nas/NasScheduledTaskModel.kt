package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasScheduledTaskState(
    val tasks: List<NasScheduledTask>? = null, val loading: Boolean = false, val busy: Boolean = false,
    val failure: Exception? = null, val canCreate: Boolean = false, val records: List<NasTaskRecord> = emptyList(),
    val selected: NasScheduledTask? = null, val detail: NasTaskDraft? = null, val detailLoading: Boolean = false,
    val detailFailure: Exception? = null, val editor: NasTaskDraft? = null, val confirmation: NasTaskChange? = null,
    val results: List<NasTaskResult>? = null, val resultsLoading: Boolean = false, val resultsFailure: Exception? = null,
    val selectedResult: NasTaskResult? = null, val output: NasTaskOutput? = null, val outputLoading: Boolean = false, val outputFailure: Exception? = null,
) { val writable get() = !loading && !busy && records.none { !it.terminal } && (failure as? DsmFailure)?.kind != DsmErrorKind.LOCAL_STORAGE_FAILED }
internal class NasScheduledTaskModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> NasTaskActivityStore, private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(NasScheduledTaskState()); val state = mutable.asStateFlow()
    private var bound: DsmRepository? = null
    private val jobs = mutableMapOf<String, Job>(); private val lock = Any(); private val selectionVersion = AtomicLong()
    private fun source(): DsmRepository? = synchronized(lock) {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo; val owner = requireNotNull(repo.owner)
            repo.scheduledTasks.recoveryPending = { store().records(owner).any { !it.terminal } }
        }
        repo.requireCurrentOwner(); repo
    }
    private fun current(repo: DsmRepository) = bound === repo && repository() === repo
    fun clear() = synchronized(lock) { selectionVersion.incrementAndGet(); jobs.values.toList().forEach(Job::cancel); jobs.clear(); bound = null; mutable.value = NasScheduledTaskState() }
    fun load() {
        val repo = source() ?: return; if (state.value.busy) return
        mutable.update { it.copy(loading = true, failure = null, canCreate = repo.scheduledTasks.canCreate) }
        launch("load", repo) { reload(repo) }
    }
    private suspend fun reload(repo: DsmRepository) {
        val rows = repo.scheduledTasks.tasks(); val records = store().records(requireNotNull(repo.owner))
        if (current(repo)) mutable.update { it.copy(tasks = rows, records = records, loading = false) }
    }
    fun inspect(task: NasScheduledTask) {
        val repo = source() ?: return; if (state.value.busy || state.value.tasks?.any { it.sameIdentity(task) } != true) return
        val version = selectionVersion.incrementAndGet()
        synchronized(lock) { listOf("results", "output").forEach { jobs.remove(it)?.cancel() } }
        mutable.update { it.copy(selected = task, detail = null, detailLoading = true, detailFailure = null,
            editor = null, results = null, resultsLoading = false, resultsFailure = null, selectedResult = null, output = null, outputLoading = false, outputFailure = null) }
        launch("detail", repo, version) {
            val value = repo.scheduledTasks.inspect(task)
            if (current(repo) && selectionVersion.get() == version) mutable.update { it.copy(detail = value, detailLoading = false) }
        }
    }
    fun closeDetail() { if (!state.value.busy) leavePage() }
    fun leavePage() {
        selectionVersion.incrementAndGet()
        synchronized(lock) { listOf("detail", "results", "output").forEach { jobs.remove(it)?.cancel() } }
        mutable.update { it.copy(selected = null, detail = null, detailLoading = false, detailFailure = null, editor = null, confirmation = null,
            results = null, resultsLoading = false, resultsFailure = null, selectedResult = null, output = null, outputLoading = false, outputFailure = null) }
    }
    fun create() {
        val repo = source() ?: return; if (!state.value.writable || !repo.scheduledTasks.canCreate) return
        closeDetail(); mutable.update { it.copy(editor = repo.scheduledTasks.newDraft()) }
    }
    fun edit() { val value = state.value; if (value.writable && value.selected?.canEdit == true && value.detail != null) mutable.update { it.copy(editor = value.detail) } }
    fun closeEditor() { if (!state.value.busy) mutable.update { it.copy(editor = null, confirmation = null) } }
    fun save(desired: NasTaskDraft) {
        val value = state.value; val original = value.editor ?: return; if (!value.writable) return
        mutable.update { it.copy(confirmation = NasTaskChange(if (original.id == null) NasTaskAction.CREATE else NasTaskAction.SAVE, value.selected, original, desired)) }
    }
    fun request(action: NasTaskAction) {
        val value = state.value; val task = value.selected ?: return; if (!value.writable) return
        val original = if (action == NasTaskAction.ENABLE || action == NasTaskAction.RUN && task.type == "script") value.detail ?: return else null
        if (action !in setOf(NasTaskAction.ENABLE, NasTaskAction.DISABLE, NasTaskAction.RUN, NasTaskAction.DELETE)) return
        mutable.update { it.copy(confirmation = NasTaskChange(action, task, original)) }
    }
    fun cancelConfirmation() { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm() {
        val repo = source() ?: return; val change = state.value.confirmation ?: return
        if (!state.value.writable) return
        mutable.update { it.copy(busy = true, failure = null) }
        launch("action", repo) {
            val owner = requireNotNull(repo.owner); val id = UUID.randomUUID().toString()
            store().execute(owner) { repo.scheduledTasks.change(change) { event ->
                if (event.stage == NasTaskStage.SUBMITTED) {
                    repo.requireCurrentOwner(); store().begin(taskRecord(id, owner, change, event.existingIds))
                    if (current(repo)) mutable.update { it.copy(editor = null, confirmation = null, selected = null, detail = null, results = null, selectedResult = null, output = null) }
                    selectionVersion.incrementAndGet()
                } else store().checkpoint(owner, id, event.stage)
            } }
            reload(repo)
        }
    }
    fun results() {
        val repo = source() ?: return; val task = state.value.selected ?: return; val version = selectionVersion.get()
        closeOutput()
        mutable.update { it.copy(resultsLoading = true, resultsFailure = null) }
        launch("results", repo, version) {
            val values = repo.scheduledTasks.results(task)
            if (current(repo) && selectionVersion.get() == version) mutable.update { it.copy(results = values, resultsLoading = false) }
        }
    }
    fun output(result: NasTaskResult) {
        val repo = source() ?: return; val task = state.value.selected ?: return; val version = selectionVersion.get()
        if (state.value.results?.contains(result) != true) return
        mutable.update { it.copy(selectedResult = result, output = null, outputLoading = true, outputFailure = null) }
        launch("output", repo, version) {
            val value = repo.scheduledTasks.output(task, result)
            if (current(repo) && selectionVersion.get() == version && state.value.selectedResult == result) mutable.update { it.copy(output = value, outputLoading = false) }
        }
    }
    fun closeOutput() { synchronized(lock) { jobs.remove("output")?.cancel() }; mutable.update { it.copy(selectedResult = null, output = null, outputLoading = false, outputFailure = null) } }
    fun dismissFailure() { mutable.update { it.copy(failure = null) } }
    fun review(id: String) {
        val repo = source() ?: return; if (state.value.busy) return
        mutable.update { it.copy(busy = true, failure = null) }
        launch("action", repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                val record = store().records(owner).singleOrNull { it.id == id } ?: return@execute
                if (!record.terminal) {
                    repo.refreshAccess()
                    val completed = if (record.action == NasTaskAction.RUN) record.accepted else {
                        val rows = repo.scheduledTasks.tasks()
                        when (record.action) {
                            NasTaskAction.DELETE -> rows.none { it.id == record.taskId }
                            NasTaskAction.DISABLE -> rows.singleOrNull { it.id == record.taskId }?.let {
                                it.enabled == false && packageDigest(taskTargetFields(it).toString()) == record.targetDigest
                            } == true
                            else -> {
                                val candidates = if (record.action == NasTaskAction.CREATE) {
                                    if (record.accepted) rows.filter { it.id !in record.existingIds && taskCreationTarget(it.name, it.owner) == record.targetDigest } else emptyList()
                                } else rows.filter { it.id == record.taskId && taskRealOwnerDigest(it.realOwner) == record.selectorDigest }
                                val task = candidates.singleOrNull()?.takeIf { it.type == "script" }
                                task != null && packageDigest(taskSavedFields(repo.scheduledTasks.draft(task)).toString()) == record.fieldsDigest
                            }
                        }
                    }
                    if (completed) store().checkpoint(owner, id, NasTaskStage.COMPLETED)
                }
            }
            reload(repo)
        }
    }
    fun discard(id: String) { val repo = source() ?: return; if (!state.value.busy) launch("discard", repo) { store().discard(requireNotNull(repo.owner), id); publish(repo) } }
    private fun publish(repo: DsmRepository) { val values = store().records(requireNotNull(repo.owner)); if (current(repo)) mutable.update { it.copy(records = values) } }
    private fun launch(key: String, repo: DsmRepository, selection: Long? = null, block: suspend () -> Unit) = synchronized(lock) {
        jobs.remove(key)?.cancel()
        val job = scope.launch(dispatcher, start = CoroutineStart.LAZY) {
            try { block() } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (current(repo) && (selection == null || selectionVersion.get() == selection)) mutable.update { when (key) {
                    "detail" -> it.copy(detailLoading = false, detailFailure = error)
                    "results" -> it.copy(resultsLoading = false, resultsFailure = error)
                    "output" -> it.copy(outputLoading = false, outputFailure = error)
                    else -> it.copy(failure = error, loading = false, confirmation = if (key == "action") null else it.confirmation)
                } }
            } finally {
                if (current(repo)) {
                    if (key in setOf("action", "load", "discard")) try { publish(repo) } catch (error: Exception) { mutable.update { it.copy(failure = error) } }
                    if (key == "action") mutable.update { it.copy(busy = false) }
                }
            }
        }
        jobs[key] = job; job.invokeOnCompletion { synchronized(lock) { if (jobs[key] === job) jobs.remove(key) } }; job.start()
    }
}
