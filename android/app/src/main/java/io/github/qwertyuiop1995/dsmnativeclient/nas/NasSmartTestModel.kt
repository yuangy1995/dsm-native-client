package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasSmartConfirmation(val disk: NasStorageDisk, val baseline: NasDiskTestStatus, val action: NasSmartAction)
internal data class NasSmartState(val loaded: Boolean = false, val busy: Boolean = false, val disks: List<NasStorageDisk> = emptyList(),
    val statuses: Map<String, Loadable<NasDiskTestStatus>> = emptyMap(), val historyFailures: Map<String, DsmFailure> = emptyMap(),
    val confirmation: NasSmartConfirmation? = null, val record: NasSmartActivity? = null, val failure: DsmFailure? = null) {
    val blocked get() = !loaded || busy || confirmation != null || record?.pending == true || failure != null
}

/** 页面读取和启停只有一个所有者；记录跨进程保留，旧账号回调不发布到新工作区。 */
internal class NasSmartTestModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> NasSmartActivityStore, private val canStart: () -> Boolean = { true },
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(NasSmartState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (NasSmartState) -> NasSmartState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = NasSmartState() }
    private suspend fun stillCurrent(repo: DsmRepository) { repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo)) }
    private fun record(repo: DsmRepository) = store().records(requireNotNull(repo.owner)).let { it.firstOrNull { row -> row.pending } ?: it.firstOrNull() }
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                stillCurrent(repo)
                store().records(owner).filter { it.stage == NasSmartStage.PREPARED }.forEach { store().checkpoint(owner, it.id, NasSmartStage.CANCELLED) }
                val activity = record(repo)
                publish(repo) { it.copy(record = activity) }
                val recovered = if (activity?.pending == true) repo.nasSmart.recover(activity.identity) else null
                val disks = repo.nasSmart.disks()
                stillCurrent(repo)
                publish(repo) { old ->
                    val retained = disks.filter { disk -> old.disks.any { smartIdentity(it) == smartIdentity(disk) } }.map { it.id }.toSet()
                    old.copy(loaded = true, disks = disks, statuses = old.statuses.filterKeys { it in retained }, historyFailures = old.historyFailures.filterKeys { it in retained })
                }
                if (activity?.pending == true && recovered != null) {
                    val reading = recovered
                    stillCurrent(repo)
                    if (smartMatches(reading.status, activity.action)) store().checkpoint(owner, activity.id, NasSmartStage.VERIFIED)
                    applyReading(repo, reading, preserveHistory = true)
                }
                finish(repo)
            }
        }
    }
    fun load(disk: NasStorageDisk) = synchronized(lock) {
        val previous = bound; val repo = source() ?: return
        if (previous !== repo || !state.value.loaded || state.value.busy || state.value.record?.pending == true ||
            state.value.disks.none { smartIdentity(it) == smartIdentity(disk) }) return
        mutable.update { it.copy(confirmation = null, statuses = it.statuses + (disk.id to Loadable.Loading)) }
        launch(repo) {
            store().execute(requireNotNull(repo.owner)) {
                try { val reading = repo.nasSmart.read(disk, true); stillCurrent(repo); applyReading(repo, reading, false) }
                catch (error: Exception) {
                    publish(repo) { it.copy(statuses = it.statuses + (disk.id to Loadable.Failed(asFailure(error)))) }
                    throw error
                }
                finish(repo)
            }
        }
    }
    /** 由可见且处于前台的页面每四秒调用；不扫描未打开硬盘，也不恢复写入。 */
    fun pollRunning() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.blocked || !canStart()) return
        val running = state.value.disks.filter { (state.value.statuses[it.id] as? Loadable.Ready)?.value?.isRunning == true }
        if (running.isEmpty()) return
        launch(repo) {
            store().execute(requireNotNull(repo.owner)) {
                for (disk in running) {
                    try {
                        var reading = repo.nasSmart.read(disk, false)
                        if (!reading.status.isRunning) reading = repo.nasSmart.read(disk, true)
                        stillCurrent(repo); applyReading(repo, reading, reading.status.isRunning)
                    } catch (error: Exception) {
                        publish(repo) { it.copy(statuses = it.statuses + (disk.id to Loadable.Failed(asFailure(error)))) }
                        throw error
                    }
                }
                finish(repo)
            }
        }
    }
    fun request(disk: NasStorageDisk, type: NasDiskTestType?): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.blocked || !canStart() || !disk.supportsSmartTest ||
            state.value.disks.none { smartIdentity(it) == smartIdentity(disk) }) return false
        val baseline = (state.value.statuses[disk.id] as? Loadable.Ready)?.value ?: return false
        val action = NasSmartAction.from(type)
        if (baseline.diskId != disk.id || !smartCanStart(baseline, action)) return false
        try {
            if (store().records(requireNotNull(repo.owner)).any { it.pending }) { publish(repo) { it.copy(record = record(repo)) }; return false }
            mutable.update { it.copy(confirmation = NasSmartConfirmation(disk, baseline, action), failure = null) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun cancel() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm(expected: NasSmartConfirmation): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.busy || !state.value.loaded || state.value.record?.pending == true || state.value.failure != null ||
            state.value.confirmation != expected || !canStart()) return false
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                stillCurrent(repo)
                val activity = NasSmartActivity(UUID.randomUUID().toString(), owner, smartIdentity(expected.disk), expected.action)
                store().records(owner).filter { !it.pending }.forEach { store().dismiss(owner, it.id) }
                store().begin(activity)
                publish(repo) { it.copy(record = activity) }
                val reading = repo.nasSmart.perform(expected.disk, expected.baseline, expected.action) { stage ->
                    if (stage == NasSmartStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                    store().checkpoint(owner, activity.id, stage)
                }
                stillCurrent(repo)
                reading?.let { applyReading(repo, it, true) }
                finish(repo)
            }
        }; true
    }
    fun dismiss() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy || state.value.record?.pending == true) return
        try { state.value.record?.let { store().dismiss(requireNotNull(repo.owner), it.id) }; publish(repo) { it.copy(record = record(repo), failure = null) } }
        catch (error: Exception) { failed(repo, error) }
    }
    private fun applyReading(repo: DsmRepository, reading: NasSmartReading, preserveHistory: Boolean) = publish(repo) { old ->
        val previous = (old.statuses[reading.disk.id] as? Loadable.Ready)?.value
        val same = old.disks.any { smartIdentity(it) == smartIdentity(reading.disk) }
        val status = if (preserveHistory && same && previous?.isHistoryAvailable == true) reading.status.copy(lastQuickTest = previous.lastQuickTest,
            lastExtendedTest = previous.lastExtendedTest, lastResult = reading.status.lastResult ?: previous.lastResult, isHistoryAvailable = true) else reading.status
        old.copy(disks = old.disks.map { if (it.id == reading.disk.id) reading.disk else it }, statuses = old.statuses + (reading.disk.id to Loadable.Ready(status)),
            historyFailures = if (reading.historyFailure != null) old.historyFailures + (reading.disk.id to reading.historyFailure) else old.historyFailures - reading.disk.id)
    }
    private fun finish(repo: DsmRepository) { val activity = record(repo); publish(repo) { it.copy(busy = false, record = activity, failure = null) } }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) {
        mutable.update { it.copy(busy = true, failure = null) }
        job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } }
    }
    private fun asFailure(error: Exception) = error as? DsmFailure ?: DsmFailure(null, "Drive tests unavailable", "Refresh the drive status.", kind = DsmErrorKind.REQUEST_FAILED)
    private fun failed(repo: DsmRepository, error: Exception) {
        val activity = runCatching { record(repo) }.getOrNull()
        publish(repo) { it.copy(busy = false, confirmation = null, record = activity ?: it.record, failure = if (error is CancellationException) null else asFailure(error)) }
    }
}
