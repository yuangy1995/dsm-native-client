package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasConnectionState(val loaded: Boolean = false, val busy: Boolean = false,
    val directory: NasConnectionDirectory? = null, val confirmation: ActiveConnection? = null,
    val record: NasConnectionActivity? = null, val failure: DsmFailure? = null) {
    val blocked get() = !loaded || busy || directory?.complete != true || record?.pending == true || failure != null
}

internal class NasConnectionModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> NasConnectionActivityStore, private val canStart: () -> Boolean = { true },
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(NasConnectionState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        return try { repo.requireCurrentOwner(); repo } catch (error: Exception) { failed(repo, error); null }
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (NasConnectionState) -> NasConnectionState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = NasConnectionState() }
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                repo.requireCurrentOwner()
                store().records(owner).filter { it.stage == NasConnectionStage.PREPARED }.forEach { store().checkpoint(owner, it.id, NasConnectionStage.CANCELLED) }
                val record = currentRecord(repo)
                publish(repo) { it.copy(record = record) }
                val directory = if (record?.pending == true) repo.nasConnections.recover() else repo.nasConnections.read()
                repo.requireCurrentOwner(); currentCoroutineContext().ensureActive(); check(current(repo))
                if (record?.pending == true && connectionAbsent(record.identity, directory)) store().checkpoint(owner, record.id, NasConnectionStage.VERIFIED)
                loaded(repo, directory)
            }
        }
    }
    fun request(original: ActiveConnection): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.blocked || state.value.confirmation != null || !canStart() || !original.canDisconnect ||
            state.value.directory?.rows?.singleOrNull { it.id == original.id } != original) return false
        try {
            if (store().records(requireNotNull(repo.owner)).any { it.pending }) { publish(repo) { it.copy(record = currentRecord(repo)) }; return false }
            mutable.update { it.copy(confirmation = original, failure = null) }; true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun cancel() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm(expected: ActiveConnection): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false
        if (previous !== repo || state.value.blocked || state.value.confirmation != expected || !canStart()) return false
        mutable.update { it.copy(confirmation = null) }
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                repo.requireCurrentOwner()
                val record = NasConnectionActivity(UUID.randomUUID().toString(), owner, connectionIdentity(expected))
                store().records(owner).filter { !it.pending }.forEach { store().dismiss(owner, it.id) }
                store().begin(record)
                publish(repo) { it.copy(record = record) }
                val directory = repo.nasConnections.disconnect(expected) { stage ->
                    if (stage == NasConnectionStage.SUBMITTED) { repo.requireCurrentOwner(); check(current(repo)) }
                    store().checkpoint(owner, record.id, stage)
                }
                loaded(repo, directory)
            }
        }; true
    }
    fun dismiss() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy || state.value.record?.pending == true) return
        try {
            state.value.record?.let { store().dismiss(requireNotNull(repo.owner), it.id) }
            publish(repo) { it.copy(record = currentRecord(repo), failure = null) }
        } catch (error: Exception) { failed(repo, error) }
    }
    private fun currentRecord(repo: DsmRepository) = store().records(requireNotNull(repo.owner)).let { rows -> rows.firstOrNull { it.pending } ?: rows.firstOrNull() }
    private fun loaded(repo: DsmRepository, directory: NasConnectionDirectory?) {
        val record = currentRecord(repo)
        publish(repo) { it.copy(loaded = true, busy = false, directory = directory ?: it.directory, record = record, failure = null) }
    }
    private fun launch(repo: DsmRepository, block: suspend () -> Unit) {
        mutable.update { it.copy(busy = true, failure = null) }
        job = scope.launch(dispatcher) { try { block() } catch (error: Exception) { failed(repo, error) } }
    }
    private fun failed(repo: DsmRepository, error: Exception) {
        val record = runCatching { currentRecord(repo) }.getOrNull()
        publish(repo) { it.copy(busy = false, confirmation = null, record = record ?: it.record,
            failure = if (error is CancellationException) null else error as? DsmFailure ?: DsmFailure(null,
                "Connections unavailable", "Refresh connections or sign in again.", kind = DsmErrorKind.REQUEST_FAILED)) }
    }
}
