package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class ChatActionItem(
    val id: String,
    val kind: ChatActionKind,
    val channelId: String,
    val checkpoint: ChatActionCheckpoint? = null,
    val draft: ChatActionDraft? = null,
    val busy: Boolean = false,
    val confirmation: Boolean = false,
    val failure: DsmFailure? = null,
    val progress: Float? = null,
) {
    val canEdit get() = !busy && checkpoint?.phase != ChatActionPhase.SUBMITTED && checkpoint?.phase != ChatActionPhase.COMPLETED
    val canContinueGroup get() = !busy && checkpoint?.phase == ChatActionPhase.SUBMITTED && checkpoint.group?.canContinue == true
    val canRefresh get() = !busy && checkpoint?.phase == ChatActionPhase.SUBMITTED
}

internal data class ChatActionsState(val items: List<ChatActionItem> = emptyList(), val focusedId: String? = null,
    val restoring: Boolean = false, val storageFailure: DsmFailure? = null) {
    val focused get() = items.firstOrNull { it.id == focusedId }
}

/** 所有Chat写入及冷启动恢复的唯一所有者；页面退出不把未明结果转成可重发。 */
internal class ChatActionModel(
    private val scope: CoroutineScope,
    private val workspace: MutableStateFlow<WorkspaceState?>,
    private val sourceProvider: () -> ChatActionSource?,
    private val storeProvider: () -> ChatActionStore,
    private val draftsProvider: () -> ChatDraftStore,
    private val onConversation: (ChatConversation) -> Unit,
    private val onChanged: (ChatActionOutcome) -> Unit,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val lock = Any()
    private val mutable = MutableStateFlow(ChatActionsState())
    val state = mutable.asStateFlow()
    private var identity: Any? = null
    private var owner: WorkspaceOwner? = null
    private var generation = 0L
    private val jobs = mutableMapOf<String, Job>()
    private val prepared = mutableMapOf<String, ChatPreparedAction>()
    private val draftJobs = mutableMapOf<String, Job>()
    private var restored = false

    private fun bind(source: ChatActionSource) = synchronized(lock) {
        if (identity !== source.identity || owner?.hasSameIdentity(source.owner) != true) {
            jobs.values.forEach(Job::cancel); jobs.clear(); prepared.clear()
            draftJobs.values.forEach(Job::cancel); draftJobs.clear()
            identity = source.identity; owner = source.owner; generation++; restored = false
            mutable.value = ChatActionsState()
        }
        generation
    }
    private fun current(source: ChatActionSource, token: Long): Boolean = synchronized(lock) {
        generation == token && identity === source.identity && sourceProvider()?.let {
            it.identity === source.identity && it.owner.hasSameIdentity(source.owner)
        } == true && workspace.value?.profile?.id == source.owner.profileId
    }
    fun clear() = synchronized(lock) {
        generation++; jobs.values.forEach(Job::cancel); jobs.clear(); prepared.clear()
        draftJobs.values.forEach(Job::cancel); draftJobs.clear()
        identity = null; owner = null; restored = false; mutable.value = ChatActionsState()
    }
    fun isBusy(vararg kinds: ChatActionKind): Boolean = state.value.items.any { it.kind in kinds && (it.busy || it.confirmation) }
    fun focus(id: String?) { mutable.update { it.copy(focusedId = id) } }

    suspend fun saveUnsent(draft: ChatActionDraft, expectedOwner: WorkspaceOwner): String? {
        val source = sourceProvider()?.takeIf { it.owner.hasSameIdentity(expectedOwner) } ?: return null
        val token = bind(source)
        val id = UUID.randomUUID().toString()
        val saved = withContext(dispatcher) { draftsProvider().saveAction(source.owner, id, draft) }
        if (!current(source, token)) return null
        mutable.update { it.copy(items = it.items + ChatActionItem(id, draft.kind, draft.channelId, draft = draftsProvider().draft(saved))) }
        return id
    }

    fun updateComposer(channel: String, text: String) {
        if (text.length > 10_000) return
        val source = sourceProvider() ?: return
        val token = bind(source)
        workspace.update { if (it != null && current(source, token)) it.copy(chatDrafts = it.chatDrafts + (channel to text)) else it }
        synchronized(lock) {
            draftJobs.remove(channel)?.cancel()
            draftJobs[channel] = scope.launch(dispatcher) {
                delay(300)
                try { draftsProvider().saveComposer(source.owner, channel, text) }
                catch (error: Exception) { if (error !is CancellationException && current(source, token)) mutable.update { it.copy(storageFailure = error.asDsmFailure()) } }
            }
        }
    }

    fun restore() {
        val source = sourceProvider() ?: return
        val token = bind(source)
        synchronized(lock) { if (restored || state.value.restoring) return; mutable.update { it.copy(restoring = true) } }
        launch("restore", source, token) {
            try {
                val rows = storeProvider().records(source.owner)
                val draftStore = draftsProvider()
                val savedDrafts = draftStore.actions(source.owner).associateBy { it.id }
                val composers = draftStore.composers(source.owner)
                if (!current(source, token)) return@launch
                workspace.update { if (it != null && current(source, token)) it.copy(chatDrafts = composers + it.chatDrafts) else it }
                mutable.update { old -> old.copy(items = old.items + rows.filter { row ->
                    old.items.none { it.id == row.checkpoint.id }
                }.map { row -> row.checkpoint.let { c ->
                    val loaded = runCatching { savedDrafts[c.id]?.let(draftStore::draft) }
                    ChatActionItem(c.id, c.kind, c.channelId, c, draft = loaded.getOrNull(), failure = loaded.exceptionOrNull()?.asDsmFailure())
                } } + savedDrafts.values.filter { draft -> rows.none { it.checkpoint.id == draft.id } && old.items.none { it.id == draft.id } }.map { saved ->
                    val loaded = runCatching { draftStore.draft(saved) }
                    ChatActionItem(saved.id, saved.kind, saved.channelId, draft = loaded.getOrNull(), failure = loaded.exceptionOrNull()?.asDsmFailure())
                }, storageFailure = null) }
                synchronized(lock) { restored = true }
                // 启动只读取已有动作，不调用创建、上传或群聊续作。
                state.value.items.filter { it.checkpoint?.phase == ChatActionPhase.SUBMITTED }.forEach { item ->
                    currentCoroutineContext().ensureActive()
                    runExisting(source, token, item.id, continueGroup = false)
                }
            } catch (error: Exception) {
                if (error !is CancellationException && current(source, token)) mutable.update { it.copy(storageFailure = error.asDsmFailure()) }
            } finally { if (current(source, token)) mutable.update { it.copy(restoring = false) } }
        }
    }

    fun request(draft: ChatActionDraft, confirm: Boolean = false, id: String = UUID.randomUUID().toString(), focus: Boolean = true,
        savedDraft: Boolean = false): String? {
        val source = sourceProvider() ?: return null
        val token = bind(source)
        val initial = workspace.value ?: return null
        if (initial.selectedModule != Module.CHAT) return null
        if (state.value.storageFailure != null) { focus("all"); return null }
        synchronized(lock) {
            // 同一点击在预检期间也互斥；落盘后的冲突另由存储校验完整目标。
            if (state.value.items.any { it.id == id || it.busy && it.kind == draft.kind && it.channelId == draft.channelId &&
                    it.draft?.original?.id == draft.original?.id }) return null
            mutable.update { it.copy(items = it.items + ChatActionItem(id, draft.kind, draft.channelId, draft = draft, busy = true),
                focusedId = if (!focus || draft.kind in outgoingKinds) it.focusedId else id) }
        }
        launch(id, source, token) {
            try {
                val durable = if (savedDraft) requireNotNull(draftsProvider().action(source.owner, id)) else draftsProvider().saveAction(source.owner, id, draft)
                val durableDraft = draftsProvider().draft(durable)
                update(source, token, id) { it.copy(draft = durableDraft) }
                val action = source.prepare(durableDraft, id)
                currentCoroutineContext().ensureActive()
                if (!current(source, token) || workspace.value?.selectedModule != Module.CHAT ||
                    workspace.value?.selectedConversation?.id != initial.selectedConversation?.id) throw CancellationException()
                storeProvider().begin(ChatActionRecord(owner = source.owner, checkpoint = action.checkpoint))
                synchronized(lock) { prepared[id] = action }
                update(source, token, id) { it.copy(checkpoint = action.checkpoint, draft = action.draft, confirmation = confirm, busy = !confirm) }
                if (!confirm) executePrepared(source, token, action)
            } catch (error: Exception) { failure(source, token, id, error) }
        }
        return id
    }

    fun confirm(id: String): Boolean {
        val source = sourceProvider() ?: return false
        val token = bind(source)
        val item = state.value.items.firstOrNull { it.id == id && it.confirmation && !it.busy } ?: return false
        val action = synchronized(lock) { prepared[id] } ?: return false
        update(source, token, id) { it.copy(confirmation = false, busy = true) }
        launch(id, source, token) { try { executePrepared(source, token, action) } catch (error: Exception) { failure(source, token, item.id, error) } }
        return true
    }

    /** 明确继续一个已保存但尚未提交的动作；重新预检不能改变其原始目标。 */
    fun resumeReady(id: String): Boolean {
        val source = sourceProvider() ?: return false
        val token = bind(source)
        val item = state.value.items.firstOrNull { it.id == id } ?: return false
        if (item.busy || item.checkpoint?.submitted == true) return false
        val draft = item.draft ?: return false
        update(source, token, id) { it.copy(busy = true, confirmation = false, failure = null) }
        launch(id, source, token) {
            try {
                val action = source.prepare(draft, id)
                if (!current(source, token)) throw CancellationException()
                if (item.checkpoint == null) storeProvider().begin(ChatActionRecord(owner = source.owner, checkpoint = action.checkpoint))
                else if (!item.checkpoint.sameOperation(action.checkpoint)) throw DsmFailure(null, "This message has changed", "Refresh and select it again.", kind = DsmErrorKind.CHAT_ITEM_CHANGED)
                update(source, token, id) { it.copy(checkpoint = action.checkpoint) }
                executePrepared(source, token, action)
            } catch (error: Exception) { failure(source, token, id, error) }
        }
        return true
    }

    fun retryRejected(id: String): Boolean {
        val item = state.value.items.firstOrNull { it.id == id && !it.busy && it.checkpoint?.phase == ChatActionPhase.REJECTED } ?: return false
        val draft = item.draft ?: return false
        return request(draft, confirm = draft.kind in setOf(ChatActionKind.DELETE, ChatActionKind.CLOSE,
            ChatActionKind.REMINDER_DELETE, ChatActionKind.SCHEDULE_DELETE)) != null
    }

    private suspend fun executePrepared(source: ChatActionSource, token: Long, action: ChatPreparedAction) {
        val id = action.checkpoint.id
        val store = storeProvider()
        store.execute(id) {
            if (!current(source, token)) throw CancellationException()
            val checkpoint = state.value.items.firstOrNull { it.id == id }?.checkpoint ?: action.checkpoint
            store.requireNoConflict(ChatActionRecord(owner = source.owner, checkpoint = checkpoint))
            addOutgoing(source, token, action)
            val outcome = source.execute(action, checkpoint, { sent, total ->
                update(source, token, id) { it.copy(progress = if (total > 0) (sent.toFloat() / total).coerceIn(0f, 1f) else null) }
            }, saver(source, token))
            complete(source, token, outcome)
        }
    }

    fun refresh(id: String, continueGroup: Boolean = false): Boolean {
        val source = sourceProvider() ?: return false
        val token = bind(source)
        synchronized(lock) {
            val item = state.value.items.firstOrNull { it.id == id } ?: return false
            if (item.busy || if (continueGroup) !item.canContinueGroup else !item.canRefresh) return false
            update(source, token, id) { it.copy(busy = true, failure = null) }
        }
        launch(id, source, token) { runExisting(source, token, id, continueGroup) }
        return true
    }

    private suspend fun runExisting(source: ChatActionSource, token: Long, id: String, continueGroup: Boolean) {
        try {
            val store = storeProvider()
            store.execute(id) {
                if (!current(source, token)) return@execute
                val inMemory = state.value.items.firstOrNull { it.id == id }?.checkpoint ?: return@execute
                // 回执落盘失败时，当前进程仍保留准确编号；先补存，绝不用旧磁盘记录覆盖它。
                val saved = store.get(source.owner, id).checkpoint
                if (inMemory != saved) store.save(source.owner, inMemory)
                update(source, token, id) { it.copy(busy = true, failure = null) }
                val result = if (continueGroup) source.continueGroup(inMemory, saver(source, token))
                    else source.recover(inMemory, saver(source, token))
                complete(source, token, result)
            }
        } catch (error: Exception) { failure(source, token, id, error) }
    }

    private fun saver(source: ChatActionSource, token: Long): (ChatActionCheckpoint) -> Unit = { checkpoint ->
        storeProvider().save(source.owner, checkpoint)
        update(source, token, checkpoint.id) { it.copy(checkpoint = checkpoint) }
    }

    private fun complete(source: ChatActionSource, token: Long, outcome: ChatActionOutcome) {
        val c = outcome.checkpoint
        update(source, token, c.id) { it.copy(checkpoint = c, busy = false, confirmation = false, failure = outcome.failure, progress = null) }
        if (!current(source, token)) return
        val openCreated = workspace.value?.let { it.selectedModule == Module.CHAT && it.chatNewConversationVisible } == true
        workspace.update { state ->
            if (state == null || !current(source, token)) state else applyChatActionOutcome(state, outcome)
        }
        if (c.phase == ChatActionPhase.COMPLETED) {
            synchronized(lock) { prepared.remove(c.id) }
            try { draftsProvider().removeAction(source.owner, c.id) }
            catch (error: Exception) { update(source, token, c.id) { it.copy(failure = error.asDsmFailure()) } }
            scope.launch { if (current(source, token)) { if (openCreated) outcome.conversation?.let(onConversation); onChanged(outcome) } }
        }
    }

    private fun failure(source: ChatActionSource, token: Long, id: String, error: Exception) {
        if (!current(source, token)) return
        val item = state.value.items.firstOrNull { it.id == id } ?: return
        // 取消和磁盘故障都不能抹除已经写出的阶段。仅无记录且无提交的预检可以直接取消。
        val checkpoint = item.checkpoint ?: runCatching { storeProvider().get(source.owner, id).checkpoint }.getOrNull()
        update(source, token, id) { it.copy(checkpoint = checkpoint, busy = false, confirmation = false,
            failure = if (error is CancellationException) null else error.asDsmFailure()) }
        if (checkpoint != null) workspace.update { state ->
            if (state == null || !current(source, token)) state else applyChatActionOutcome(state, ChatActionOutcome(checkpoint))
        }
    }

    /** 关闭结果只收起面板；未明动作继续保留，不能经关闭/重试旁路重复发送。 */
    fun dismiss(id: String): Boolean {
        val item = state.value.items.firstOrNull { it.id == id } ?: return false
        if (item.busy || item.confirmation) return false
        mutable.update { if (it.focusedId == id) it.copy(focusedId = null) else it }
        return true
    }
    fun cancel(id: String): Boolean {
        val item = state.value.items.firstOrNull { it.id == id } ?: return false
        synchronized(lock) { jobs[id]?.cancel() }
        if (item.confirmation) return discard(id)
        return true
    }
    fun discard(id: String): Boolean {
        val source = sourceProvider() ?: return false
        val token = bind(source)
        val item = state.value.items.firstOrNull { it.id == id } ?: return false
        if (item.busy || item.checkpoint?.phase == ChatActionPhase.SUBMITTED) return false
        try {
            item.checkpoint?.let { storeProvider().discard(source.owner, id) }
            draftsProvider().removeAction(source.owner, id)
            if (!current(source, token)) return false
            synchronized(lock) { prepared.remove(id) }
            mutable.update { it.copy(items = it.items.filterNot { row -> row.id == id }, focusedId = it.focusedId.takeUnless { focused -> focused == id }) }
            workspace.update { state -> state?.takeIf { current(source, token) }?.let { current ->
                current.chatOutgoingMessages.values.flatten().firstOrNull { it.clientRequestId == id }
                    ?.let { removeLocalChatMessage(current, it) } ?: current } ?: state }
            return true
        } catch (error: Exception) { failure(source, token, id, error); return false }
    }

    private fun addOutgoing(source: ChatActionSource, token: Long, action: ChatPreparedAction) {
        if (action.draft.kind !in outgoingKinds || !current(source, token)) return
        val c = action.checkpoint
        val sourceFile = action.draft.attachment
        val local = ChatMessage("local:${c.id}", c.channelId, null, action.draft.text,
            System.currentTimeMillis() / 1000, isMine = true, clientRequestId = c.id,
            deliveryState = ChatDeliveryState.SENDING, threadId = c.threadId,
            attachments = sourceFile?.let { listOf(ChatAttachment("local-file:${c.id}", it.displayName, it.contentType, it.contentLength)) }.orEmpty())
        workspace.update { state ->
            if (state == null || !current(source, token)) state else state.copy(
                chatOutgoingMessages = state.chatOutgoingMessages + (c.channelId to
                    (state.chatOutgoingMessages[c.channelId].orEmpty().filterNot { it.clientRequestId == c.id } + local)),
                chatDrafts = if (state.chatDrafts[c.channelId]?.trim() == action.draft.text && c.kind != ChatActionKind.REPLY)
                    state.chatDrafts - c.channelId else state.chatDrafts)
        }
        if (c.kind != ChatActionKind.REPLY && workspace.value?.chatDrafts?.get(c.channelId).isNullOrEmpty()) {
            synchronized(lock) { draftJobs.remove(c.channelId)?.cancel() }
            draftsProvider().saveComposer(source.owner, c.channelId, "")
        }
    }
    private fun update(source: ChatActionSource, token: Long, id: String, transform: (ChatActionItem) -> ChatActionItem) {
        if (current(source, token)) mutable.update { it.copy(items = it.items.map { row -> if (row.id == id) transform(row) else row }) }
    }
    private fun launch(id: String, source: ChatActionSource, token: Long, block: suspend () -> Unit) {
        val job = scope.launch(dispatcher, start = CoroutineStart.LAZY) {
            try { block() } finally { synchronized(lock) { if (current(source, token)) jobs.remove(id) } }
        }
        synchronized(lock) { jobs[id] = job }; job.start()
    }
    companion object { val outgoingKinds = setOf(ChatActionKind.SEND, ChatActionKind.ATTACHMENT, ChatActionKind.REPLY) }
}

internal fun applyChatActionOutcome(state: WorkspaceState, outcome: ChatActionOutcome): WorkspaceState {
    val c = outcome.checkpoint
    val completed = c.phase == ChatActionPhase.COMPLETED
    val local = state.chatOutgoingMessages[c.channelId].orEmpty().firstOrNull { it.clientRequestId == c.id }
    val replacement = if (completed) outcome.message?.copy(clientRequestId = c.id)
        else local?.copy(deliveryState = ChatDeliveryState.FAILED, attachmentProgress = null)
    val outgoing = state.chatOutgoingMessages[c.channelId].orEmpty().filterNot {
        it.clientRequestId == c.id || completed && c.kind == ChatActionKind.DELETE && it.id == c.messageId }
    val page = (state.chatMessages as? Loadable.Ready)?.value
    val messages = page?.messages?.filterNot { it.id == local?.id || completed &&
        (it.id == outcome.message?.id || c.kind == ChatActionKind.DELETE && it.id == c.messageId) }.orEmpty()
    val nextMessages = if (completed && outcome.message != null && (outcome.message.threadId == null || outcome.message.threadId == outcome.message.id))
        (messages + outcome.message).sortedBy { it.createdAtEpochMillis } else messages
    return state.copy(
        chatOutgoingMessages = state.chatOutgoingMessages + (c.channelId to (outgoing + listOfNotNull(replacement))),
        chatMessages = if (page != null && state.selectedConversation?.id == c.channelId) Loadable.Ready(page.copy(messages = nextMessages)) else state.chatMessages,
        chatNewConversationVisible = if (completed && c.kind in setOf(ChatActionKind.DIRECT, ChatActionKind.GROUP)) false else state.chatNewConversationVisible,
        chatPollComposerVisible = if (completed && c.kind == ChatActionKind.POLL_CREATE && state.selectedConversation?.id == c.channelId) false else state.chatPollComposerVisible,
        chatScheduleComposerVisible = if (completed && c.kind == ChatActionKind.SCHEDULE_CREATE && state.selectedConversation?.id == c.channelId) false else state.chatScheduleComposerVisible,
    )
}
