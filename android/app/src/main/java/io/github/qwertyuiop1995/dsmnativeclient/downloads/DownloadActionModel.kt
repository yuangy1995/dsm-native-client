package io.github.qwertyuiop1995.dsmnativeclient.downloads

import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.downloads.downloadCreationKey
import io.github.qwertyuiop1995.dsmnativeclient.data.downloads.downloadDestination
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class DownloadActionConfirmation(val record: DownloadActionRecord, val titles: List<String>)
internal data class DownloadActionsState(
    val records: List<DownloadActionRecord> = emptyList(),
    val busy: Set<String> = emptySet(),
    val confirmation: DownloadActionConfirmation? = null,
    val failure: DsmFailure? = null,
    val visible: Boolean = false,
    val restoring: Boolean = false,
)

/** 下载写入的唯一编排；队列只推进明确结束项，未知项恢复永远只读。 */
internal class DownloadActionModel(
    private val scope: CoroutineScope,
    private val repository: () -> DsmRepository?,
    private val store: () -> DownloadActionStore,
    private val onChanged: () -> Unit,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutable = MutableStateFlow(DownloadActionsState())
    val state = mutable.asStateFlow()
    private var bound: DsmRepository? = null
    private var restored = false
    private val jobs = mutableMapOf<String, Job>()
    private val lock = Any()
    private fun source(): DsmRepository? = synchronized(lock) {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        repo
    }
    private fun current(repo: DsmRepository) = bound === repo && repository() === repo
    fun clear() = synchronized(lock) {
        jobs.values.toList().forEach(Job::cancel); jobs.clear(); bound = null; restored = false; mutable.value = DownloadActionsState()
    }
    fun show(visible: Boolean = true) { if (visible && source() == null) return; mutable.update { it.copy(visible = visible, failure = null) }; if (visible) restore() }
    fun restore() {
        val repo = source() ?: return
        synchronized(lock) { if (restored || state.value.restoring) return; mutable.update { it.copy(restoring = true) } }
        launch("restore", repo) {
            val rows = store().records(requireNotNull(repo.owner))
            if (current(repo)) { restored = true; mutable.update { it.copy(records = rows, restoring = false) } }
        }
    }
    fun requestTasks(tasks: List<DownloadTask>, kind: DownloadActionKind, destination: FileItem? = null): Boolean {
        val repo = source() ?: return false
        if (tasks.isEmpty() || tasks.map { it.id }.distinct().size != tasks.size || state.value.confirmation != null ||
            kind !in setOf(DownloadActionKind.PAUSE, DownloadActionKind.RESUME, DownloadActionKind.REMOVE, DownloadActionKind.END_AND_MOVE, DownloadActionKind.EDIT)) return false
        val path = destination?.let { downloadDestination(it.path) }
        if (kind == DownloadActionKind.EDIT && (path == null || destination?.isDirectory != true || !destination.canWrite)) return false
        val steps = tasks.map { task -> DownloadActionStep(kind, task.id, downloadTaskDigest(task),
            original = buildMap { put("status", task.status.name); task.destination?.let { put("destination", downloadDestination(it) ?: it) } },
            desired = if (path == null) emptyMap() else mapOf("destination" to path)) }
        val record = DownloadActionRecord(UUID.randomUUID().toString(), requireNotNull(repo.owner), steps)
        if (kind in setOf(DownloadActionKind.REMOVE, DownloadActionKind.END_AND_MOVE)) {
            mutable.update { it.copy(confirmation = DownloadActionConfirmation(record, tasks.map { task -> task.title }), failure = null) }
        } else start(record, repo)
        return true
    }
    fun cancelConfirmation() { mutable.update { it.copy(confirmation = null) } }
    fun confirm(): Boolean {
        val repo = source() ?: return false
        val confirmation = state.value.confirmation ?: return false
        if (!confirmation.record.owner.hasSameIdentity(requireNotNull(repo.owner))) return false
        mutable.update { it.copy(confirmation = null) }
        start(confirmation.record, repo)
        return true
    }
    fun requestSettings(original: DownloadSettings, desired: DownloadSettings): Boolean {
        val repo = source() ?: return false
        val before = downloadSettingsParameters(original)
        val after = downloadSettingsParameters(desired, false)
        val delta = after.filter { (key, value) -> key in before && before[key] != value }
        if (delta.isEmpty() || !original.canManage) return false
        val steps = listOf(DownloadActionKind.SETTINGS, DownloadActionKind.SCHEDULE).mapNotNull { kind ->
            val keys = if (kind == DownloadActionKind.SETTINGS) DOWNLOAD_BASIC_SETTING_FIELDS else DOWNLOAD_SCHEDULE_SETTING_FIELDS
            val changes = delta.filterKeys { it in keys }.toMutableMap()
            if (changes.isEmpty()) null else {
                if (changes.keys.any { it in setOf("http_max_download", "ftp_max_download") }) {
                    changes["http_max_download"] = desired.httpDownloadLimitKb.toString()
                    changes["ftp_max_download"] = desired.ftpDownloadLimitKb.toString()
                }
                DownloadActionStep(kind, kind.name, downloadCreationKey("settings", kind.name),
                    original = before.filterKeys { it in changes }, desired = changes)
            }
        }
        start(DownloadActionRecord(UUID.randomUUID().toString(), requireNotNull(repo.owner), steps), repo)
        return true
    }
    fun requestRss(site: DownloadRssSite): Boolean {
        val repo = source() ?: return false
        if (site.isUpdating || site.lastUpdatedAtEpochSeconds == null) return false
        start(DownloadActionRecord(UUID.randomUUID().toString(), requireNotNull(repo.owner), listOf(
            DownloadActionStep(DownloadActionKind.RSS, site.id, downloadRssDigest(site), original = mapOf("updated_at" to site.lastUpdatedAtEpochSeconds.toString())))), repo)
        return true
    }
    fun createLink(uri: String, destination: String?): Boolean = create(DownloadActionKind.CREATE_LINK) { repo, before, accepted ->
        repo.createDownloadResult(uri, destination, before, accepted)
    }
    fun createFile(source: UploadSource, destination: String?, password: String?, cleanup: () -> Unit = {}): Boolean =
        create(DownloadActionKind.CREATE_FILE, cleanup) { repo, before, accepted -> repo.createDownloadFromFileResult(source, destination, password, before, accepted) }

    private fun create(kind: DownloadActionKind, cleanup: () -> Unit = {},
        operation: suspend (DsmRepository, (String, String) -> Unit, () -> Unit) -> MutationResult,
    ): Boolean {
        val repo = source() ?: return false
        val owner = requireNotNull(repo.owner)
        val id = UUID.randomUUID().toString()
        launch(id, repo) {
            try {
                var created = false
                val result = operation(repo, { sourceKey, requestKey ->
                    if (!current(repo)) throw CancellationException()
                    val step = DownloadActionStep(kind, sourceKey, sourceKey, desired = mapOf("request_digest" to requestKey))
                    store().begin(DownloadActionRecord(id, owner, listOf(step))); created = true
                    save(owner, id, 0, step.copy(phase = DownloadActionPhase.SUBMITTED))
                }, {
                    val step = store().get(owner, id).steps.single()
                    save(owner, id, 0, step.copy(accepted = true, phase = DownloadActionPhase.COMPLETED))
                })
                if (created) finish(owner, id, 0, result)
                else if (current(repo)) mutable.update { it.copy(failure = downloadResultFailure(result)) }
                publish(repo)
            } finally { cleanup() }
        }
        return true
    }
    private fun start(record: DownloadActionRecord, repo: DsmRepository) {
        mutable.update { it.copy(visible = true, failure = null) }
        launch(record.id, repo) { store().begin(record); execute(record.id, repo); publish(repo) }
    }
    fun continuePending(id: String): Boolean {
        val repo = source() ?: return false
        val record = state.value.records.firstOrNull { it.id == id } ?: return false
        if (id in state.value.busy || record.steps.any { it.phase == DownloadActionPhase.SUBMITTED } || record.steps.none { it.phase == DownloadActionPhase.READY }) return false
        launch(id, repo) { execute(id, repo); publish(repo) }; return true
    }
    fun refresh(id: String): Boolean {
        val repo = source() ?: return false
        if (id in state.value.busy) return false
        launch(id, repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(id) {
                val record = store().get(owner, id)
                for ((index, step) in record.steps.withIndex()) {
                    if (step.phase != DownloadActionPhase.SUBMITTED) continue
                    val phase = review(repo, step)
                    if (phase != step.phase) {
                        save(owner, id, index, step.copy(phase = phase))
                        if (step.kind == DownloadActionKind.RSS) repo.acknowledgeDownloadRssRefresh(step.target)
                    }
                }
            }
            publish(repo)
        }; return true
    }
    fun cancelPending(id: String): Boolean {
        val repo = source() ?: return false
        if (id in state.value.busy) return false
        launch(id, repo) {
            val owner = requireNotNull(repo.owner)
            store().get(owner, id).steps.forEachIndexed { index, step ->
                if (step.phase == DownloadActionPhase.READY) save(owner, id, index, step.copy(phase = DownloadActionPhase.CANCELLED))
            }
            publish(repo)
        }; return true
    }
    fun discard(id: String): Boolean {
        val repo = source() ?: return false
        if (id in state.value.busy) return false
        launch(id, repo) { store().discard(requireNotNull(repo.owner), id); publish(repo) }; return true
    }
    private suspend fun execute(id: String, repo: DsmRepository) = store().execute(id) {
        val owner = requireNotNull(repo.owner)
        for (index in store().get(owner, id).steps.indices) {
            currentCoroutineContext().ensureActive()
            if (!current(repo)) return@execute
            val step = store().get(owner, id).steps[index]
            if (step.phase == DownloadActionPhase.SUBMITTED) break
            if (step.phase != DownloadActionPhase.READY) continue
            val before = { save(owner, id, index, step.copy(phase = DownloadActionPhase.SUBMITTED)) }
            val accepted = { save(owner, id, index, store().get(owner, id).steps[index].copy(accepted = true)) }
            try {
                val result = submit(repo, step, before, accepted)
                finish(owner, id, index, result)
            } catch (failure: DsmFailure) {
                val latest = store().get(owner, id).steps[index]
                if (latest.phase == DownloadActionPhase.READY) save(owner, id, index, latest.copy(phase = DownloadActionPhase.REJECTED, error = failure.kind.name))
                else throw failure
            }
            if (store().get(owner, id).steps[index].phase == DownloadActionPhase.SUBMITTED) break
        }
    }
    private suspend fun submit(repo: DsmRepository, step: DownloadActionStep, before: () -> Unit, accepted: () -> Unit): MutationResult {
        if (step.kind == DownloadActionKind.RSS) return repo.refreshDownloadRssSiteResult(step.target, { site ->
            if (downloadRssDigest(site) != step.identityDigest || site.lastUpdatedAtEpochSeconds.toString() != step.original["updated_at"]) changed()
            before()
        }, accepted)
        if (step.kind in setOf(DownloadActionKind.SETTINGS, DownloadActionKind.SCHEDULE)) {
            val original = repo.loadDownloadSettings()
            val values = downloadSettingsParameters(original)
            if (step.original.any { values[it.key] != it.value }) changed()
            return repo.saveDownloadSettingsResult(original, applySettings(original, step.desired),
                if (step.kind == DownloadActionKind.SETTINGS) DownloadSettingsPartition.BASIC else DownloadSettingsPartition.SCHEDULE,
                { before() }, { accepted() })
        }
        val task = repo.activeDownloadTasksForMutation().singleOrNull { it.id == step.target } ?: changed()
        if (downloadTaskDigest(task) != step.identityDigest || task.status.name != step.original["status"] ||
            (downloadDestination(task.destination) ?: task.destination) != step.original["destination"]) changed()
        val baseline = DownloadTaskMutationBaseline.from(task)
        return if (step.kind == DownloadActionKind.EDIT) {
            val path = step.desired.getValue("destination")
            val directory = repo.fileInfo("/$path") ?: changed()
            repo.editDownloadDestinationResult(baseline, directory, before, accepted)
        } else repo.controlDownloadsResult(listOf(baseline), when (step.kind) {
            DownloadActionKind.PAUSE -> DownloadTaskMutationAction.PAUSE
            DownloadActionKind.RESUME -> DownloadTaskMutationAction.RESUME
            DownloadActionKind.REMOVE -> DownloadTaskMutationAction.REMOVE_TASK
            DownloadActionKind.END_AND_MOVE -> DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES
            else -> changed()
        }, before, accepted)
    }
    private suspend fun review(repo: DsmRepository, step: DownloadActionStep): DownloadActionPhase {
        fun phase(matches: Boolean) = if (matches) DownloadActionPhase.COMPLETED else DownloadActionPhase.SUBMITTED
        return when (step.kind) {
            DownloadActionKind.CREATE_LINK, DownloadActionKind.CREATE_FILE -> { repo.listDownloads(); DownloadActionPhase.SUBMITTED }
            DownloadActionKind.SETTINGS, DownloadActionKind.SCHEDULE -> {
                val values = downloadSettingsParameters(repo.loadDownloadSettings()); phase(step.desired.all { values[it.key] == it.value })
            }
            DownloadActionKind.RSS -> {
                val site = repo.listDownloadRssSites().singleOrNull { it.id == step.target }
                if (site == null || downloadRssDigest(site) != step.identityDigest) DownloadActionPhase.REJECTED else phase(!site.isUpdating &&
                    (site.lastUpdatedAtEpochSeconds ?: 0) > (step.original["updated_at"]?.toLongOrNull() ?: Long.MAX_VALUE))
            }
            else -> {
                val task = repo.activeDownloadTasksForMutation().singleOrNull { it.id == step.target }
                if (task == null) {
                    if (step.kind in setOf(DownloadActionKind.REMOVE, DownloadActionKind.END_AND_MOVE)) DownloadActionPhase.COMPLETED else DownloadActionPhase.REJECTED
                } else if (downloadTaskDigest(task) != step.identityDigest) DownloadActionPhase.REJECTED
                else phase(when (step.kind) {
                    DownloadActionKind.PAUSE -> task.status == ResourceState.PAUSED
                    DownloadActionKind.RESUME -> task.isCompleted || task.status in setOf(ResourceState.RUNNING, ResourceState.WAITING)
                    DownloadActionKind.EDIT -> downloadDestination(task.destination) == step.desired["destination"]
                    else -> false
                })
            }
        }
    }
    private fun finish(owner: WorkspaceOwner, id: String, index: Int, result: MutationResult) {
        val step = store().get(owner, id).steps[index]
        if (step.terminal) return
        val phase = when {
            result.status == MutationResultStatus.CONFIRMED_SUCCESS -> DownloadActionPhase.COMPLETED
            result.requiresRefresh || result.counts.unknown > 0 -> DownloadActionPhase.SUBMITTED
            result.status == MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> DownloadActionPhase.CANCELLED
            else -> DownloadActionPhase.REJECTED
        }
        save(owner, id, index, step.copy(phase = phase, error = result.errorCategory?.name))
    }
    private fun save(owner: WorkspaceOwner, id: String, index: Int, step: DownloadActionStep) = store().save(owner, id, index, step)
    private fun publish(repo: DsmRepository) {
        val rows = store().records(requireNotNull(repo.owner))
        if (current(repo)) { mutable.update { it.copy(records = rows) }; onChanged() }
    }
    private fun launch(id: String, repo: DsmRepository, block: suspend () -> Unit): Unit = synchronized(lock) {
        if (id in jobs) return
        mutable.update { it.copy(busy = it.busy + id, failure = null) }
        val job = scope.launch(dispatcher, start = CoroutineStart.LAZY) {
            try { block() }
            catch (_: CancellationException) { }
            catch (error: Exception) { if (current(repo)) mutable.update { it.copy(failure = error.asDsmFailure()) } }
            finally {
                synchronized(lock) { jobs.remove(id) }
                if (current(repo)) mutable.update { it.copy(busy = it.busy - id, restoring = false) }
            }
        }
        jobs[id] = job; job.start(); Unit
    }
    private fun changed(): Nothing = throw DsmFailure(null, "This download has changed", "Refresh Download Station and try again.", kind = DsmErrorKind.CHANGE_NOT_CONFIRMED)
}

internal fun applySettings(value: DownloadSettings, changes: Map<String, String>): DownloadSettings = value.copy(
    defaultDestination = changes["default_destination"] ?: value.defaultDestination,
    emuleEnabled = changes["emule_enabled"]?.toBooleanStrict() ?: value.emuleEnabled,
    autoExtractEnabled = changes["unzip_service_enabled"]?.toBooleanStrict() ?: value.autoExtractEnabled,
    btDownloadLimitKb = changes["bt_max_download"]?.toInt() ?: value.btDownloadLimitKb,
    btUploadLimitKb = changes["bt_max_upload"]?.toInt() ?: value.btUploadLimitKb,
    httpDownloadLimitKb = changes["http_max_download"]?.toInt() ?: value.httpDownloadLimitKb,
    ftpDownloadLimitKb = changes["ftp_max_download"]?.toInt() ?: value.ftpDownloadLimitKb,
    nzbDownloadLimitKb = changes["nzb_max_download"]?.toInt() ?: value.nzbDownloadLimitKb,
    emuleDownloadLimitKb = changes["emule_max_download"]?.toInt() ?: value.emuleDownloadLimitKb,
    emuleUploadLimitKb = changes["emule_max_upload"]?.toInt() ?: value.emuleUploadLimitKb,
    scheduleEnabled = changes["enabled"]?.toBooleanStrict() ?: value.scheduleEnabled,
    emuleScheduleEnabled = changes["schedule_emule_enabled"]?.toBooleanStrict() ?: value.emuleScheduleEnabled,
)
private fun downloadResultFailure(result: MutationResult) = DsmFailure(null, "The download request could not be started",
    "Review the source and destination, then try again.", kind = when (result.errorCategory) {
        MutationErrorCategory.CONFLICT -> DsmErrorKind.WORKSPACE_BUSY
        MutationErrorCategory.PERMISSION -> DsmErrorKind.PERMISSION_DENIED
        MutationErrorCategory.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
        else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
    })
