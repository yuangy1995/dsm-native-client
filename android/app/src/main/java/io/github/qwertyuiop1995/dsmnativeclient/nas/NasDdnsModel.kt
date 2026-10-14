package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.DdnsMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasDdnsState(val current: NasDdnsDirectory? = null, val original: NasDdnsDirectory? = null,
    val draft: NasDdnsDraft? = null, val confirmation: NasDdnsPlan? = null,
    val busy: Boolean = false, val saving: Boolean = false, val operation: DdnsMutationOperation? = null,
    val record: NasDdnsRecordActivity? = null, val result: MutationResult? = null, val failure: DsmFailure? = null) {
    val blocked get() = busy || record?.blocks == true || failure?.kind == DsmErrorKind.LOCAL_STORAGE_FAILED
}
internal class NasDdnsModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> NasDdnsActivityStore, private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(NasDdnsState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null; private var job: Job? = null
    private fun source(): DsmRepository? = synchronized(lock) {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }; repo.requireCurrentOwner(); repo
    }
    private fun current(repo: DsmRepository) = repository() === repo && bound === repo
    private fun publish(repo: DsmRepository, change: (NasDdnsState) -> NasDdnsState) = synchronized(lock) { if (current(repo)) mutable.update(change) }
    fun clear() = synchronized(lock) { job?.cancel(); job = null; bound = null; mutable.value = NasDdnsState() }
    fun leave() = synchronized(lock) { mutable.update { it.copy(original = null, draft = null, confirmation = null) } }
    fun begin(draft: NasDdnsDraft): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false; val value = state.value
        if (previous !== repo || value.blocked || value.current == null) return false
        val target = draft.originalProviderId?.let { id -> value.current.records.singleOrNull { it.providerId == id } }
        if (draft.originalProviderId != null && (target == null || target.providerId != draft.providerId)) return false
        try {
            value.record?.let { store().dismiss(requireNotNull(repo.owner), it.id) }
            mutable.value = value.copy(original = value.current, draft = draft.copy(password = ""), confirmation = null,
                result = null, record = null, operation = null, failure = null); true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun draft(value: NasDdnsDraft) = synchronized(lock) {
        source() ?: return; if (!state.value.blocked && state.value.draft != null && state.value.confirmation == null)
            mutable.update { it.copy(draft = value, result = null, failure = null) }
    }
    fun prepare(operation: DdnsMutationOperation, target: NasDdnsRecord? = null): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false; val value = state.value
        if (previous !== repo || value.blocked) return false
        val original = if (operation in setOf(DdnsMutationOperation.SAVE, DdnsMutationOperation.TEST)) value.original else value.current
        if (original == null) return false
        try {
            val plan = repo.nasDdns.plan(operation, original, value.draft.takeIf { operation in setOf(DdnsMutationOperation.SAVE, DdnsMutationOperation.TEST) }, target)
            value.record?.let { store().dismiss(requireNotNull(repo.owner), it.id) }
            mutable.value = value.copy(confirmation = plan, record = null, result = null, operation = operation, failure = null); true
        } catch (error: Exception) { failed(repo, error); false }
    }
    fun cancelConfirmation() = synchronized(lock) { if (!state.value.busy) mutable.update { it.copy(confirmation = null) } }
    fun confirm(expected: NasDdnsPlan): Boolean = synchronized(lock) {
        val previous = bound; val repo = source() ?: return false; val value = state.value
        if (previous !== repo || value.blocked || value.confirmation !== expected) return false
        mutable.value = value.copy(draft = value.draft?.copy(password = ""), confirmation = null, operation = expected.operation)
        launch(repo, true) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                val record = NasDdnsRecordActivity(UUID.randomUUID().toString(), owner, expected.operation,
                    providerDigest = (expected.draft?.providerId ?: expected.target?.providerId)?.let(::packageDigest),
                    targetDigest = when (expected.operation) {
                        DdnsMutationOperation.SAVE -> ddnsDigest(ddnsCore(requireNotNull(expected.draft)))
                        DdnsMutationOperation.ADDRESS_REFRESH -> ddnsProviderSet(expected.original)
                        else -> null
                    }, requiresAcceptance = expected.requiresAcceptance)
                repo.requireCurrentOwner(); store().begin(record)
                val outcome = repo.nasDdns.perform(expected) { store().checkpoint(owner, record.id, it.stage) }
                val saved = store().records(owner).single { it.id == record.id }
                val result = outcome.result
                publish(repo) { it.copy(current = outcome.current, busy = false, saving = false, result = result, record = saved,
                    original = it.original.takeUnless { result.submitted && expected.operation != DdnsMutationOperation.TEST },
                    draft = it.draft.takeUnless { result.submitted && expected.operation != DdnsMutationOperation.TEST }) }
            }
        }; true
    }
    fun refresh() = synchronized(lock) {
        val repo = source() ?: return
        if (state.value.busy) return
        launch(repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                val current = repo.nasDdns.load()
                for (record in store().records(owner).filter { !it.terminal }) {
                    if (record.stage == NasServiceStage.PREPARED) store().checkpoint(owner, record.id, NasServiceStage.CANCELLED)
                    else if (!record.requiresAcceptance || record.accepted) {
                        val match = when (record.operation) {
                            DdnsMutationOperation.TEST -> record.accepted
                            DdnsMutationOperation.ADDRESS_REFRESH -> ddnsProviderSet(current) == record.targetDigest
                            DdnsMutationOperation.SAVE -> current.records.any { packageDigest(it.providerId) == record.providerDigest && ddnsDigest(ddnsCore(it)) == record.targetDigest }
                            DdnsMutationOperation.DELETE -> current.records.none { packageDigest(it.providerId) == record.providerDigest }
                        }
                        if (match) store().checkpoint(owner, record.id, NasServiceStage.VERIFIED)
                    }
                }
                val records = store().records(owner).filter { !it.dismissed }; val latest = records.firstOrNull { it.blocks } ?: records.firstOrNull()
                publish(repo) { it.copy(current = current, busy = false, saving = false, record = latest, operation = latest?.operation, result = latest?.result(), failure = null) }
            }
        }
    }
    fun dismiss(discard: Boolean = false) = synchronized(lock) {
        val repo = source() ?: return; val value = state.value
        if (value.blocked) return
        try {
            value.record?.let { store().dismiss(requireNotNull(repo.owner), it.id) }
            mutable.value = value.copy(record = null, result = null, failure = null, operation = null,
                draft = value.draft.takeUnless { discard }, original = value.original.takeUnless { discard })
        } catch (error: Exception) { failed(repo, error) }
    }
    private fun launch(repo: DsmRepository, saving: Boolean = false, block: suspend () -> Unit) {
        mutable.update { it.copy(busy = true, saving = saving, failure = null) }
        job = scope.launch(dispatcher) { try { block() } catch (error: Exception) {
            if (error is CancellationException) publish(repo) { it.copy(busy = false, saving = false) } else failed(repo, error)
        } }
    }
    private fun failed(repo: DsmRepository, error: Exception) {
        val records = runCatching { store().records(requireNotNull(repo.owner)).filter { !it.dismissed } }.getOrNull().orEmpty()
        val latest = records.firstOrNull { it.blocks } ?: records.firstOrNull()
        publish(repo) { it.copy(busy = false, saving = false, current = null, confirmation = null, record = latest ?: it.record,
            result = latest?.result() ?: it.result, operation = latest?.operation ?: it.operation,
            draft = it.draft?.copy(password = ""), failure = error as? DsmFailure ?: DsmFailure(null, "DDNS is unavailable", "Reconnect and refresh DDNS settings.", kind = DsmErrorKind.REQUEST_FAILED)) }
    }
}
