package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.PackageMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasPackageControlConfirmation(val target: PackageInfo, val action: PackageMutationOperation)
internal data class NasPackageCenterState(
    val catalog: NasPackageCatalog? = null, val catalogLoading: Boolean = false, val catalogFailure: Exception? = null,
    val preferences: NasPackagePreferences? = null, val preferencesLoading: Boolean = false, val preferencesFailure: Exception? = null,
    val sources: List<NasPackageSource>? = null, val sourcesLoading: Boolean = false, val sourcesFailure: Exception? = null,
    val plan: NasPackageInstallPlan? = null, val progress: NasPackageProgress? = null,
    val busy: Boolean = false, val failure: Exception? = null, val activities: List<PackageActivityRecord> = emptyList(),
    val fileName: String? = null, val fileCopying: Boolean = false,
    val installed: List<PackageInfo>? = null, val installedLoading: Boolean = false, val installedFailure: Exception? = null,
    val controlConfirmation: NasPackageControlConfirmation? = null,
    val controlActions: Set<PackageMutationOperation> = emptySet(),
)

/** 页面只提交明确按钮动作；与原连接绑定，读取取消或迟到结果不污染下一连接。 */
internal class NasPackageCenterModel(
    private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val activityStore: () -> PackageActivityStore, private val inputDirectory: () -> File,
    private val onChanged: () -> Unit, private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val pollMillis: Long = 2_000, private val canStart: () -> Boolean = { true },
) {
    private val mutable = MutableStateFlow(NasPackageCenterState())
    val state = mutable.asStateFlow()
    private var bound: DsmRepository? = null
    private val jobs = mutableMapOf<String, Job>()
    private val lock = Any()
    private var generation = 0L
    private var localFile: File? = null
    private var uploadSource: UploadSource? = null
    val selectionToken get() = generation
    val isActive get() = state.value.busy || state.value.fileCopying || state.value.progress?.phase in setOf(NasPackageInstallPhase.DOWNLOADING, NasPackageInstallPhase.INSTALLING)
    private fun source(): DsmRepository? = synchronized(lock) {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo
            val owner = requireNotNull(repo.owner)
            repo.packageCenter.recoveryPending = { activityStore().records(owner).any { !it.terminal } }
        }
        try { repo.requireCurrentOwner(); repo } catch (error: Exception) {
            mutable.update { it.copy(failure = error, controlConfirmation = null) }; null
        }
    }
    private fun current(repo: DsmRepository) = bound === repo && repository() === repo
    fun clear() = synchronized(lock) {
        generation++; jobs.values.toList().forEach(Job::cancel); jobs.clear(); bound = null
        localFile?.delete(); localFile = null; uploadSource = null; mutable.value = NasPackageCenterState()
    }
    fun restore() { val repo = source() ?: return; launch("restore", repo) {
        val owner = requireNotNull(repo.owner)
        activityStore().records(owner).filter { !isActive && !it.terminal && it.id != repo.packageCenter.job?.id }.forEach {
            activityStore().interruptPreparation(owner, it.id)
        }
        publish(repo)
    } }
    fun loadInstalled() {
        val repo = source() ?: return
        if (state.value.busy) return
        action(repo) {
            mutable.update { it.copy(installedLoading = true, installedFailure = null, controlConfirmation = null) }
            try {
                val owner = requireNotNull(repo.owner)
                val pending = activityStore().records(owner).singleOrNull { it.kind == PackageActivityKind.CONTROL && !it.terminal }
                val rows = if (pending != null) recoverControl(repo, pending) else repo.packageCenter.controlInstalled()
                if (current(repo)) mutable.update { it.copy(installed = rows,
                    controlActions = PackageMutationOperation.entries.filter { repo.packageCenter.supportsControl(it) }.toSet()) }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (current(repo)) mutable.update { it.copy(installedFailure = error) }
            } finally { if (current(repo)) mutable.update { it.copy(installedLoading = false) } }
        }
    }
    fun requestControl(target: PackageInfo, action: PackageMutationOperation): Boolean {
        val repo = source() ?: return false
        val value = state.value
        if (!canStart() || isActive || value.installedLoading || value.installedFailure != null || value.failure != null ||
            value.controlConfirmation != null || value.installed?.none { it == target } != false || !target.allowsControl(action) ||
            !repo.packageCenter.supportsControl(action)) return false
        try { requireIdleRecords(repo) } catch (error: Exception) { mutable.update { it.copy(failure = error) }; return false }
        mutable.update { it.copy(controlConfirmation = NasPackageControlConfirmation(target, action)) }; return true
    }
    fun cancelControl() { mutable.update { it.copy(controlConfirmation = null) } }
    fun confirmControl(expected: NasPackageControlConfirmation): Boolean {
        val repo = source() ?: return false
        val value = state.value
        if (!canStart() || isActive || value.controlConfirmation != expected || value.installedFailure != null || value.failure != null ||
            value.installed?.none { it == expected.target } != false) return false
        mutable.update { it.copy(controlConfirmation = null) }
        action(repo) {
            requireIdleRecords(repo)
            val observer = observer(repo, PackageActivityKind.CONTROL,
                listOf(PackageActivityItem(expected.target.id, expected.target.version, expected.target.version, step = expected.action.controlStep().name)),
                expectedDigest = packageInstallationDigest(expected.target))
            val rows = repo.packageCenter.performControl(UUID.randomUUID().toString(), expected.target, expected.action, observer)
            if (current(repo) && rows != null) mutable.update { it.copy(installed = rows) }
            if (current(repo)) onChanged()
        }
        return true
    }
    private suspend fun recoverControl(repo: DsmRepository, record: PackageActivityRecord): List<PackageInfo> {
        val owner = requireNotNull(repo.owner)
        val stored = activityStore().get(owner, record.id)
        val item = stored.items.single()
        if (item.phase == PackageActivityPhase.READY) {
            activityStore().completeRecovered(owner, stored.id, emptySet())
            return repo.packageCenter.controlInstalled()
        }
        val action = PackageMutationOperation.valueOf(item.step)
        val rows = repo.packageCenter.recoverControl(action)
        if (item.phase == PackageActivityPhase.SUBMITTED && packageControlMatches(rows, item.packageId, stored.expectedDigest, action)) {
            activityStore().completeRecovered(owner, stored.id, setOf(0))
            repo.packageCenter.preferencePending = false
        }
        return rows
    }
    fun catalog() {
        val repo = source() ?: return
        launch("catalog", repo, onFailure = { error -> mutable.update { it.copy(catalogLoading = false, catalogFailure = error) } }) {
            mutable.update { it.copy(catalogLoading = true, catalogFailure = null) }
            val data = repo.packageCenter.catalog()
            if (current(repo)) mutable.update { it.copy(catalog = data, catalogLoading = false) }
        }
    }
    fun preferences() {
        val repo = source() ?: return
        launch("preferences", repo, onFailure = { error -> mutable.update { it.copy(preferencesLoading = false, preferencesFailure = error) } }) {
            mutable.update { it.copy(preferencesLoading = true, preferencesFailure = null) }
            val data = repo.packageCenter.preferences()
            if (current(repo)) mutable.update { it.copy(preferences = data, preferencesLoading = false) }
        }
    }
    fun sources() {
        val repo = source() ?: return
        launch("sources", repo, onFailure = { error -> mutable.update { it.copy(sourcesLoading = false, sourcesFailure = error) } }) {
            mutable.update { it.copy(sourcesLoading = true, sourcesFailure = null) }
            val data = repo.packageCenter.sources()
            if (current(repo)) mutable.update { it.copy(sources = data, sourcesLoading = false) }
        }
    }
    fun prepare(entries: List<NasPackageEntry>) {
        val repo = source() ?: return
        action(repo) {
            requireIdleRecords(repo)
            val plan = repo.packageCenter.prepare(entries.map { it.id })
            if (current(repo)) mutable.update { it.copy(plan = plan) }
        }
    }
    fun updateInstalled(packageId: String) {
        val repo = source() ?: return
        action(repo) {
            requireIdleRecords(repo)
            val catalog = repo.packageCenter.catalog()
            val entry = catalog.entries.singleOrNull { it.packageId == packageId && it.updateAvailable } ?: packageFailure(NasPackageProblem.CHANGED)
            val plan = repo.packageCenter.prepare(listOf(entry.id))
            if (current(repo)) mutable.update { it.copy(catalog = catalog, plan = plan) }
        }
    }
    fun dismissPlan() {
        if (state.value.busy && state.value.progress == null) synchronized(lock) { jobs["action"]?.cancel() }
        mutable.update { it.copy(plan = null, failure = null) }
    }
    fun start(volumes: Map<String, String>, startAfterInstall: Boolean) {
        val repo = source() ?: return; val plan = state.value.plan ?: return
        action(repo) {
            requireIdleRecords(repo)
            val observer = observer(repo, PackageActivityKind.INSTALL, plan.items.map { PackageActivityItem(it.entry.packageId, it.entry.installedVersion, it.entry.version) })
            val progress = repo.packageCenter.start(plan.id, volumes, startAfterInstall, observer)
            if (current(repo)) mutable.update { it.copy(plan = null, progress = progress) }
            monitor(repo, progress)
        }
    }
    fun configure(volume: String, startAfterInstall: Boolean, licenseAccepted: Boolean, values: Map<String, kotlinx.serialization.json.JsonPrimitive>) {
        val repo = source() ?: return; val progress = state.value.progress ?: return
        action(repo) {
            val next = repo.packageCenter.configure(progress.id, volume, startAfterInstall, licenseAccepted, values)
            if (current(repo)) mutable.update { it.copy(progress = next) }
            monitor(repo, next)
        }
    }
    fun cancel() {
        val repo = source() ?: return; val progress = state.value.progress ?: return
        action(repo) {
            synchronized(lock) { jobs.remove("monitor") }?.cancelAndJoin()
            val next = repo.packageCenter.cancel(progress.id)
            if (current(repo)) mutable.update { it.copy(progress = next) }
            monitor(repo, next)
        }
    }
    fun refreshProgress() {
        val repo = source() ?: return; val progress = state.value.progress ?: return
        action(repo) {
            synchronized(lock) { jobs.remove("monitor") }?.cancelAndJoin()
            val next = repo.packageCenter.advance(progress.id)
            if (current(repo)) mutable.update { it.copy(progress = next) }
            monitor(repo, next)
        }
    }
    private fun monitor(repo: DsmRepository, progress: NasPackageProgress) {
        if (progress.phase !in setOf(NasPackageInstallPhase.DOWNLOADING, NasPackageInstallPhase.INSTALLING)) { if (progress.phase == NasPackageInstallPhase.COMPLETED) onChanged(); return }
        launch("monitor", repo) {
            while (current(repo)) {
                delay(pollMillis)
                val next = repo.packageCenter.advance(progress.id)
                if (!current(repo)) break
                mutable.update { it.copy(progress = next) }; publish(repo)
                if (next.phase !in setOf(NasPackageInstallPhase.DOWNLOADING, NasPackageInstallPhase.INSTALLING)) {
                    if (next.phase == NasPackageInstallPhase.COMPLETED) onChanged()
                    break
                }
            }
        }
    }
    fun savePreferences(desired: NasPackagePreferences) {
        val repo = source() ?: return; val original = state.value.preferences ?: return
        action(repo) {
            requireIdleRecords(repo)
            val id = UUID.randomUUID().toString()
            val next = repo.packageCenter.savePreferences(id, original, desired,
                observer(repo, PackageActivityKind.SETTINGS, listOf(PackageActivityItem()), expectedDigest = preferencesDigest(desired)))
            if (current(repo)) mutable.update { it.copy(preferences = next) }
        }
    }
    fun saveSource(original: NasPackageSource?, desired: NasPackageSource?) {
        val repo = source() ?: return
        action(repo) {
            requireIdleRecords(repo)
            val normalized = desired?.let(::normalizedPackageSource)
            val observer = observer(repo, PackageActivityKind.SOURCE, listOf(PackageActivityItem()),
                expectedDigest = normalized?.let(::sourceDigest).orEmpty(), sourceAddressDigest = normalized?.url?.let(::packageDigest).orEmpty(),
                previousAddressDigest = original?.url?.let(::packageDigest).orEmpty())
            val next = repo.packageCenter.saveSource(UUID.randomUUID().toString(), original, normalized, observer)
            if (current(repo)) mutable.update { it.copy(sources = next) }
        }
    }
    fun chooseFile(token: Long, resolve: suspend () -> UploadSource): Boolean {
        val repo = source() ?: return false
        if (token != generation || isActive) return false
        return launch("file", repo, onFailure = { error -> mutable.update { it.copy(fileCopying = false, failure = error) } }) {
            mutable.update { it.copy(fileCopying = true, failure = null) }
            var copy: File? = null
            try {
                val source = resolve()
                if (!source.displayName.endsWith(".spk", true) || source.contentLength <= 0) packageFailure(NasPackageProblem.INVALID_FILE)
                val directory = inputDirectory().also { check(it.mkdirs() || it.isDirectory) }
                copy = File(directory, "${UUID.randomUUID()}.spk")
                var count = 0L
                source.openInputStream().use { input -> copy.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val size = input.read(buffer); if (size < 0) break
                        count += size; if (count > source.contentLength) packageFailure(NasPackageProblem.INVALID_FILE)
                        output.write(buffer, 0, size)
                    }
                } }
                if (count != source.contentLength) packageFailure(NasPackageProblem.INVALID_FILE)
                if (!current(repo) || token != generation) return@launch
                localFile?.delete(); localFile = copy
                val owned = copy
                uploadSource = source.copy(openInputStream = { owned.inputStream() })
                mutable.update { it.copy(fileName = source.displayName, fileCopying = false) }; copy = null
            } finally { copy?.delete() }
        }
    }
    fun clearFile() { if (isActive) return; localFile?.delete(); localFile = null; uploadSource = null; mutable.update { it.copy(fileName = null) } }
    fun upload() {
        val repo = source() ?: return; val source = uploadSource ?: return
        action(repo) {
            requireIdleRecords(repo)
            try {
                val progress = repo.packageCenter.upload(source, observer(repo, PackageActivityKind.INSTALL, listOf(PackageActivityItem())))
                if (current(repo)) mutable.update { it.copy(progress = progress) }
            } finally { localFile?.delete(); localFile = null; uploadSource = null; if (current(repo)) mutable.update { it.copy(fileName = null) } }
        }
    }
    fun review(record: PackageActivityRecord) {
        val repo = source() ?: return
        if (state.value.progress?.id == record.id && !record.terminal) { refreshProgress(); return }
        action(repo) {
            val owner = requireNotNull(repo.owner); val stored = activityStore().get(owner, record.id)
            if (stored.kind == PackageActivityKind.CONTROL) {
                val rows = recoverControl(repo, stored)
                if (current(repo)) mutable.update { it.copy(installed = rows, installedFailure = null) }
                return@action
            }
            repo.refreshAccess()
            val completed = when (stored.kind) {
                PackageActivityKind.CONTROL -> error("Control recovery is handled above")
                PackageActivityKind.SETTINGS -> if (preferencesDigest(repo.packageCenter.preferences()) == stored.expectedDigest) setOf(0) else emptySet()
                PackageActivityKind.SOURCE -> {
                    val sources = repo.packageCenter.sources()
                    val matches = (stored.expectedDigest.isEmpty() || sources.any { sourceDigest(it) == stored.expectedDigest }) &&
                        (stored.previousAddressDigest.isEmpty() || stored.previousAddressDigest == stored.sourceAddressDigest || sources.none { packageDigest(it.url) == stored.previousAddressDigest })
                    if (matches) setOf(0) else emptySet()
                }
                PackageActivityKind.INSTALL -> {
                    val installed = repo.packageCenter.installed()
                    stored.items.mapIndexedNotNull { index, item -> index.takeIf {
                        item.phase == PackageActivityPhase.SUBMITTED && item.step == NasPackageWriteStep.INSTALL.name &&
                            (item.accepted || item.originalVersion != item.version) && installed.any {
                                it.id == item.packageId && it.version == item.version && it.status.lowercase() in setOf("running", "stopped", "active", "inactive")
                            }
                    } }.toSet()
                }
            }
            activityStore().completeRecovered(owner, stored.id, completed)
            if (activityStore().get(owner, stored.id).terminal) { repo.packageCenter.preferencePending = false; onChanged() }
        }
    }
    fun discard(id: String) { val repo = source() ?: return; action(repo) { activityStore().discard(requireNotNull(repo.owner), id) } }
    fun dismissFailure() { mutable.update { it.copy(failure = null) } }
    private fun observer(repo: DsmRepository, kind: PackageActivityKind, items: List<PackageActivityItem>, expectedDigest: String = "",
        sourceAddressDigest: String = "", previousAddressDigest: String = ""): NasPackageObserver {
        var started = false
        val owner = requireNotNull(repo.owner)
        return { event ->
            if (kind != PackageActivityKind.CONTROL || event.stage == NasPackageWriteStage.WILL_SUBMIT) {
                if (!current(repo)) throw CancellationException()
                repo.requireCurrentOwner()
            }
            if (!started) {
                if (event.stage != NasPackageWriteStage.WILL_SUBMIT) packageFailure()
                activityStore().begin(PackageActivityRecord(event.operationId, owner, kind, items, expectedDigest, sourceAddressDigest, previousAddressDigest)); started = true
            }
            activityStore().checkpoint(owner, event)
            publish(repo)
        }
    }
    private fun requireIdleRecords(repo: DsmRepository) {
        if (activityStore().records(requireNotNull(repo.owner)).any { !it.terminal }) packageFailure(NasPackageProblem.BUSY)
    }
    private fun publish(repo: DsmRepository) {
        val rows = activityStore().records(requireNotNull(repo.owner))
        if (current(repo)) mutable.update { it.copy(activities = rows) }
    }
    private fun action(repo: DsmRepository, block: suspend () -> Unit) {
        if (state.value.busy) return
        launch("action", repo) {
            mutable.update { it.copy(busy = true, failure = null, controlConfirmation = null) }
            try { activityStore().execute(requireNotNull(repo.owner)) { block() } }
            finally { if (current(repo)) { mutable.update { it.copy(busy = false) }; publish(repo) } }
        }
    }
    private fun launch(key: String, repo: DsmRepository, onFailure: ((Exception) -> Unit)? = null, block: suspend () -> Unit): Boolean = synchronized(lock) {
        if (jobs[key]?.isActive == true) return false
        val job = scope.launch(dispatcher, start = CoroutineStart.LAZY) {
            try { block() } catch (_: CancellationException) { }
            catch (error: Exception) { if (current(repo)) { if (onFailure != null) onFailure(error) else mutable.update { it.copy(failure = error,
                progress = repo.packageCenter.job?.progress ?: it.progress) } } }
        }
        jobs[key] = job
        job.invokeOnCompletion { synchronized(lock) { if (jobs[key] === job) jobs.remove(key) } }
        job.start(); true
    }
}
