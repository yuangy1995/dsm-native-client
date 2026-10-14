package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasPowerStage
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasPowerActionState(val loaded: Boolean = false, val busy: Boolean = false,
    val confirmation: NasPowerAction? = null, val record: NasPowerActivity? = null,
    val canRestore: Boolean = false, val failure: DsmFailure? = null) {
    val blocked get() = !loaded || busy || record?.blocks == true || failure?.kind == DsmErrorKind.LOCAL_STORAGE_FAILED
}

internal class NasPowerActionModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> NasPowerActivityStore, private val canStart: () -> Boolean = { true },
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(NasPowerActionState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (NasPowerActionState) -> NasPowerActionState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = NasPowerActionState() }
    /** 页面重开只恢复本地记录；接受/未知不会通过自动联网变成已完成。 */
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                repo.requireCurrentOwner()
                store().records(owner).filter { it.stage == NasPowerStage.PREPARED }.forEach { store().cancelPrepared(owner, it.id) }
                loaded(repo)
            }
        }
    }
    fun request(action: NasPowerAction): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.blocked || state.value.confirmation != null || !canStart()) return false
        try {
            if (store().records(requireNotNull(repo.owner)).any { it.blocks }) { loaded(repo); return false }
            mutable.update { it.copy(confirmation = action, failure = null) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun cancel() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm(expected: NasPowerAction): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.blocked || state.value.confirmation != expected || !canStart()) return false
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                repo.requireCurrentOwner()
                val record = NasPowerActivity(UUID.randomUUID().toString(), owner, expected, repo.nasPowerSessionDigest)
                store().records(owner).filter { !it.dismissed && !it.blocks }.forEach { store().dismiss(owner, it.id) }
                store().begin(record)
                publish(repo) { it.copy(record = record, canRestore = false) }
                repo.nasPower.perform(expected) { stage ->
                    // 写前要求当前归属；发送后的回执仍需落到原记录，不能因换账号丢失事实。
                    if (stage == NasPowerStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                    store().checkpoint(owner, record.id, stage)
                }
                loaded(repo)
            }
        }; true
    }
    /** 此调用只来自“设备与服务已恢复”的明确确认；新的 SID 与当前权限仍由程序检查。 */
    fun restore(expected: NasPowerActivity): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false; val value = state.value
        if (previous !== repo || value.busy || !value.canRestore || value.record != expected || !canStart()) return false
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                val record = store().records(owner).single { it.id == expected.id }
                if (record != expected || !record.needsRecovery || record.sessionDigest == repo.nasPowerSessionDigest) throw IllegalStateException("Power recovery changed")
                repo.nasPower.checkConnection()
                repo.requireCurrentOwner(); currentCoroutineContext().ensureActive()
                check(current(repo))
                store().restore(owner, record.id, repo.nasPowerSessionDigest)
                loaded(repo)
            }
        }; true
    }
    fun dismiss() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.blocked) return
        try {
            state.value.record?.let { store().dismiss(requireNotNull(repo.owner), it.id) }
            loaded(repo)
        } catch (error: Exception) { failed(repo, error) }
    }
    private fun loaded(repo: DsmRepository) {
        val records = store().records(requireNotNull(repo.owner)).filter { !it.dismissed }
        val record = records.firstOrNull { it.blocks } ?: records.firstOrNull()
        val canRestore = record?.needsRecovery == true && record.sessionDigest != repo.nasPowerSessionDigest
        publish(repo) { it.copy(loaded = true, busy = false, record = record, canRestore = canRestore, failure = null) }
    }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) {
        mutable.update { it.copy(busy = true, failure = null) }
        job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } }
    }
    private fun failed(repo: DsmRepository, error: Exception) {
        val record = runCatching { store().records(requireNotNull(repo.owner)).filter { !it.dismissed }.let { rows -> rows.firstOrNull { it.blocks } ?: rows.firstOrNull() } }.getOrNull()
        publish(repo) { it.copy(busy = false, confirmation = null, record = record ?: it.record,
            failure = if (error is CancellationException) null else error as? DsmFailure ?: DsmFailure(null,
                "Power action is unavailable", "Reconnect and check the NAS before trying again.", kind = DsmErrorKind.REQUEST_FAILED)) }
    }
}
