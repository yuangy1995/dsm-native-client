package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.asDsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

internal data class ChatBatchItem(val record: ChatBatchRecord, val busy: Boolean = false, val confirmation: Boolean = false,
    val failure: DsmFailure? = null)
internal data class ChatBatchesState(val items: List<ChatBatchItem> = emptyList(), val focusedId: String? = null, val failure: DsmFailure? = null) {
    val focused get() = items.firstOrNull { it.record.id == focusedId }
}

/** 批量只负责顺序与确认；每项仍由同一个动作模型保存、执行和恢复。 */
internal class ChatBatchModel(private val scope: CoroutineScope, private val actions: ChatActionModel,
    private val sourceProvider: () -> ChatActionSource?, private val drafts: () -> ChatDraftStore,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(ChatBatchesState())
    val state = mutable.asStateFlow()
    private var identity: Any? = null
    private var revision = 0L
    private var job: Job? = null
    private fun source(): ChatActionSource? = sourceProvider()?.also { if (identity !== it.identity) { clear(); identity = it.identity } }
    private fun current(source: ChatActionSource, token: Long) = revision == token && sourceProvider()?.identity === source.identity
    fun clear() { revision++; job?.cancel(); job = null; identity = null; mutable.value = ChatBatchesState() }
    fun focus(id: String?) { mutable.update { it.copy(focusedId = id) }; if (id != null) actions.focus(null) }
    fun restore() {
        val source = source() ?: return
        if (state.value.items.isNotEmpty()) return
        val token = revision
        job = scope.launch {
            try {
                val records = withContext(dispatcher) { drafts().batches(source.owner) }
                if (current(source, token)) mutable.update { it.copy(items = records.map(::ChatBatchItem)) }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (current(source, token)) mutable.update { it.copy(failure = error.asDsmFailure()) }
            }
        }
    }
    fun request(values: List<ChatActionDraft>): Boolean {
        val source = source() ?: return false
        if (values.isEmpty() || values.any { it.kind != values.first().kind } ||
            values.first().kind !in setOf(ChatActionKind.FORWARD, ChatActionKind.DELETE, ChatActionKind.CLOSE) || state.value.items.any { it.busy } || actions.state.value.storageFailure != null) return false
        val record = ChatBatchRecord(source.owner, UUID.randomUUID().toString(), values.first().kind, values.map { UUID.randomUUID().toString() })
        val token = revision
        mutable.update { it.copy(items = it.items + ChatBatchItem(record, busy = true), focusedId = record.id) }
        actions.focus(null)
        job = scope.launch {
            try {
                withContext(dispatcher) {
                    values.zip(record.actionIds).forEach { (draft, id) -> drafts().saveAction(source.owner, id, draft) }
                    drafts().saveBatch(record)
                }
                if (!current(source, token)) return@launch
                var failure: DsmFailure? = null
                values.zip(record.actionIds).forEach { (draft, id) ->
                    if (actions.request(draft, confirm = true, id = id, focus = false, savedDraft = true) == null) throw busyFailure()
                    actions.state.first { it.items.any { item -> item.id == id && !item.busy } }
                    if (!current(source, token)) return@launch
                    val item = actions.state.value.items.single { it.id == id }
                    if (item.failure != null || item.checkpoint == null) failure = failure ?: item.failure ?: busyFailure()
                }
                update(record.id) { it.copy(busy = false, confirmation = true, failure = failure) }
            } catch (error: Exception) { if (current(source, token)) update(record.id) { it.copy(busy = false, failure = error.asDsmFailure()) } }
        }
        return true
    }
    fun continueBatch(id: String): Boolean {
        val source = source() ?: return false
        val batch = state.value.items.firstOrNull { it.record.id == id && !it.busy } ?: return false
        val items = batch.record.actionIds.map { actionId -> actions.state.value.items.firstOrNull { it.id == actionId } }
        if (items.any { it == null || it.busy || it.checkpoint?.phase == ChatActionPhase.SUBMITTED }) return false
        val token = revision
        update(id) { it.copy(busy = true, confirmation = false, failure = null) }
        job = scope.launch {
            try {
                for (actionId in batch.record.actionIds) {
                    if (!current(source, token)) return@launch
                    val item = actions.state.value.items.firstOrNull { it.id == actionId } ?: throw busyFailure()
                    if (item.checkpoint?.finished == true) continue
                    if (!(if (item.confirmation) actions.confirm(actionId) else actions.resumeReady(actionId))) throw busyFailure()
                    val after = actions.state.first { flow -> flow.items.any { row -> row.id == actionId && !row.busy } }.items.single { it.id == actionId }
                    if (after.checkpoint?.phase != ChatActionPhase.COMPLETED) break
                }
                if (current(source, token)) update(id) { it.copy(busy = false) }
            } catch (error: Exception) { if (current(source, token)) update(id) { it.copy(busy = false, failure = error.asDsmFailure()) } }
        }
        return true
    }
    fun discard(id: String): Boolean {
        val source = source() ?: return false
        val batch = state.value.items.firstOrNull { it.record.id == id && !it.busy } ?: return false
        val items = batch.record.actionIds.mapNotNull { actionId -> actions.state.value.items.firstOrNull { it.id == actionId } }
        if (items.any { it.busy || it.checkpoint?.phase == ChatActionPhase.SUBMITTED }) return false
        if (items.any { !actions.discard(it.id) }) return false
        return try { drafts().removeBatch(source.owner, id)
            mutable.update { it.copy(items = it.items.filterNot { row -> row.record.id == id }, focusedId = null) }; true
        } catch (error: Exception) { update(id) { it.copy(failure = error.asDsmFailure()) }; false }
    }
    private fun update(id: String, transform: (ChatBatchItem) -> ChatBatchItem) { mutable.update { it.copy(items = it.items.map { row -> if (row.record.id == id) transform(row) else row }) } }
    private fun busyFailure() = DsmFailure(null, "Some chat actions are not ready", "Refresh their status and try again.", kind = DsmErrorKind.WORKSPACE_BUSY)
}
