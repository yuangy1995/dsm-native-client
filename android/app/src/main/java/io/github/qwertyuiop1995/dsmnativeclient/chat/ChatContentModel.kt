package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.pinnedMessages
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal interface ChatContentSource {
    val identity: Any
    suspend fun search(query: String, channelId: String?, offset: Int): ChatSearchPage
    suspend fun message(channel: String, id: String, thread: String?): ChatMessage?
    suspend fun replies(channel: String, root: String, before: String?): ChatMessagePage
    suspend fun pinned(channel: String): List<ChatMessage>
    suspend fun editingPolicy(): ChatEditingPolicy
    suspend fun markRead(channel: String, id: String): ChatConversation
    suspend fun markThreadRead(channel: String, root: String, id: String)
}

internal class DsmChatContentSource(private val repository: DsmRepository) : ChatContentSource {
    override val identity: Any get() = repository
    override suspend fun search(query: String, channelId: String?, offset: Int) = repository.chatRepository.search(query, channelId, offset)
    override suspend fun message(channel: String, id: String, thread: String?) = repository.chatRepository.message(channel, id, thread)
    override suspend fun replies(channel: String, root: String, before: String?) = repository.chatRepository.messages(channel, before, threadId = root)
    override suspend fun pinned(channel: String) = repository.chatRepository.pinnedMessages(channel)
    override suspend fun editingPolicy() = repository.chatRepository.editingPolicy()
    override suspend fun markRead(channel: String, id: String) = repository.chatRepository.markRead(channel, id)
    override suspend fun markThreadRead(channel: String, root: String, id: String) = repository.chatRepository.markThreadRead(channel, root, id)
}

internal data class ChatThreadContent(val root: ChatMessage, val replies: ChatMessagePage)
internal enum class ChatContentPanel { SEARCH, THREAD, PINNED, EDIT }
internal data class ChatContentState(
    val panel: ChatContentPanel? = null,
    val query: String = "",
    val searchChannelId: String? = null,
    val search: Loadable<ChatSearchPage> = Loadable.Idle,
    val searchLoadingMore: Boolean = false,
    val channelId: String? = null,
    val thread: Loadable<ChatThreadContent> = Loadable.Idle,
    val threadLoadingMore: Boolean = false,
    val reply: String = "",
    val pinned: Loadable<List<ChatMessage>> = Loadable.Idle,
    val editing: Loadable<ChatMessage> = Loadable.Idle,
    val editText: String = "",
    val failure: DsmFailure? = null,
)

/** 搜索、线程、公告与可见已读各自持有读取代次，互不改变主历史的分页游标。 */
internal class ChatContentModel(
    private val scope: CoroutineScope,
    private val workspace: MutableStateFlow<WorkspaceState?>,
    private val sourceProvider: () -> ChatContentSource?,
    private val actions: ChatActionModel,
) {
    private val mutable = MutableStateFlow(ChatContentState())
    val state = mutable.asStateFlow()
    private var identity: Any? = null
    private var revision = 0L
    private var job: Job? = null
    @Volatile private var visible = false
    private var readJob: Job? = null
    private val readTimes = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private var pendingVisible: Pair<ChatMessage, Boolean>? = null
    private var threadAnchor: ChatMessage? = null

    fun hasSeen(message: ChatMessage): Boolean = visible && workspace.value?.selectedModule == Module.CHAT &&
        workspace.value?.selectedConversation?.id == message.conversationId &&
        (readTimes[message.conversationId] ?: 0) >= message.createdAtEpochMillis

    private fun source(): ChatContentSource? = sourceProvider()?.also {
        if (identity !== it.identity) { clear(); identity = it.identity }
    }
    fun clear() {
        revision++; job?.cancel(); readJob?.cancel(); job = null; readJob = null
        identity = null; pendingVisible = null; threadAnchor = null; readTimes.clear(); mutable.value = ChatContentState()
    }
    private fun current(source: ChatContentSource, token: Long) = token == revision && sourceProvider()?.identity === source.identity
    fun setVisible(value: Boolean) {
        visible = value
        if (!value) { readJob?.cancel(); readJob = null; pendingVisible = null }
    }
    fun close() { revision++; job?.cancel(); threadAnchor = null; mutable.update { it.copy(panel = null, failure = null) } }
    fun openSearch(channel: String? = null) {
        source() ?: return
        revision++; job?.cancel()
        mutable.value = ChatContentState(panel = ChatContentPanel.SEARCH, searchChannelId = channel)
    }
    fun updateQuery(text: String) {
        if (text.length > 500) return
        revision++; job?.cancel()
        mutable.update { it.copy(query = text, search = Loadable.Idle, searchLoadingMore = false, failure = null) }
    }
    fun search(more: Boolean = false) {
        val source = source() ?: return
        val input = state.value
        if (input.panel != ChatContentPanel.SEARCH || input.query.isBlank() || input.searchLoadingMore) return
        val prior = (input.search as? Loadable.Ready)?.value
        val offset = if (more) prior?.nextOffset ?: return else 0
        val token = ++revision; job?.cancel()
        mutable.update { it.copy(search = if (more) it.search else Loadable.Loading, searchLoadingMore = more, failure = null) }
        job = scope.launch {
            suspendRunCatching { source.search(input.query.trim(), input.searchChannelId, offset) }.onSuccess { page ->
                if (current(source, token)) mutable.update { it.copy(search = Loadable.Ready(if (more && prior != null)
                    page.copy(messages = (prior.messages + page.messages).distinctBy { message -> message.conversationId to message.id }) else page), searchLoadingMore = false) }
            }.onFailure { error -> if (current(source, token)) mutable.update { it.copy(search = if (more) it.search else Loadable.Failed(error.asDsmFailure()),
                searchLoadingMore = false, failure = if (more) error.asDsmFailure() else null) } }
        }
    }
    fun openThread(message: ChatMessage) {
        if (message.deliveryState != ChatDeliveryState.SENT || message.id.startsWith("local:") || message.isEncrypted) return
        val source = source() ?: return
        val rootId = message.threadId ?: message.id
        threadAnchor = message
        val token = ++revision; job?.cancel()
        mutable.value = ChatContentState(panel = ChatContentPanel.THREAD, channelId = message.conversationId, thread = Loadable.Loading)
        job = scope.launch {
            suspendRunCatching {
                val root = source.message(message.conversationId, rootId, null) ?: throw changedChatContent()
                ChatThreadContent(root, source.replies(root.conversationId, root.id, null))
            }.onSuccess { content -> if (current(source, token)) mutable.update { it.copy(thread = Loadable.Ready(content)) } }
                .onFailure { error -> if (current(source, token)) mutable.update { it.copy(thread = Loadable.Failed(error.asDsmFailure())) } }
        }
    }
    fun retryThread() {
        if (state.value.panel == ChatContentPanel.THREAD) threadAnchor?.let(::openThread)
    }
    fun loadOlderReplies() {
        val source = source() ?: return
        val input = state.value
        val thread = (input.thread as? Loadable.Ready)?.value ?: return
        val before = thread.replies.previousCursor ?: return
        if (input.panel != ChatContentPanel.THREAD || input.threadLoadingMore || !thread.replies.hasMore) return
        val token = revision
        mutable.update { it.copy(threadLoadingMore = true, failure = null) }
        job = scope.launch {
            suspendRunCatching { source.replies(thread.root.conversationId, thread.root.id, before) }.onSuccess { page ->
                if (current(source, token)) mutable.update { it.copy(thread = Loadable.Ready(thread.copy(replies = page.copy(
                    messages = (page.messages + thread.replies.messages).distinctBy { row -> row.id }.sortedBy { row -> row.createdAtEpochMillis }))), threadLoadingMore = false) }
            }.onFailure { error -> if (current(source, token)) mutable.update { it.copy(threadLoadingMore = false, failure = error.asDsmFailure()) } }
        }
    }
    fun updateReply(text: String) { if (text.length <= 10_000) mutable.update { it.copy(reply = text) } }
    fun sendReply() {
        val input = state.value
        val root = (input.thread as? Loadable.Ready)?.value?.root ?: return
        if (input.reply.isBlank()) return
        actions.request(ChatActionDraft(ChatActionKind.REPLY, root.conversationId, original = root, text = input.reply))?.let {
            mutable.update { if (it.reply == input.reply) it.copy(reply = "") else it }
        }
    }
    fun openPinned(channel: String) {
        val source = source() ?: return
        val token = ++revision; job?.cancel()
        mutable.value = ChatContentState(panel = ChatContentPanel.PINNED, channelId = channel, pinned = Loadable.Loading)
        job = scope.launch {
            suspendRunCatching { source.pinned(channel) }.onSuccess { rows -> if (current(source, token)) mutable.update { it.copy(pinned = Loadable.Ready(rows)) } }
                .onFailure { error -> if (current(source, token)) mutable.update { it.copy(pinned = Loadable.Failed(error.asDsmFailure())) } }
        }
    }
    fun edit(message: ChatMessage) {
        val source = source() ?: return
        val token = ++revision; job?.cancel()
        mutable.value = ChatContentState(panel = ChatContentPanel.EDIT, channelId = message.conversationId, editing = Loadable.Loading)
        job = scope.launch {
            suspendRunCatching {
                val fresh = source.message(message.conversationId, message.id, message.threadId) ?: throw changedChatContent()
                if (fresh.contentDigest() != message.contentDigest() || !source.editingPolicy().permits(fresh)) throw changedChatContent()
                fresh
            }.onSuccess { fresh -> if (current(source, token)) mutable.update { it.copy(editing = Loadable.Ready(fresh), editText = fresh.body) } }
                .onFailure { error -> if (current(source, token)) mutable.update { it.copy(editing = Loadable.Failed(error.asDsmFailure())) } }
        }
    }
    fun updateEdit(text: String) { if (text.length <= 10_000) mutable.update { it.copy(editText = text) } }
    fun saveEdit() {
        val input = state.value
        val original = (input.editing as? Loadable.Ready)?.value ?: return
        if (input.editText.isBlank()) return
        actions.request(ChatActionDraft(ChatActionKind.EDIT, original.conversationId, original = original, text = input.editText))
    }
    fun changed(outcome: ChatActionOutcome) {
        val input = state.value
        val c = outcome.checkpoint
        if (c.phase != ChatActionPhase.COMPLETED || input.channelId != c.channelId) return
        if (input.panel == ChatContentPanel.EDIT && (input.editing as? Loadable.Ready)?.value?.id == c.messageId) close()
        if (input.panel == ChatContentPanel.PINNED && c.kind in setOf(ChatActionKind.PIN, ChatActionKind.UNPIN, ChatActionKind.DELETE)) openPinned(c.channelId)
        val thread = (input.thread as? Loadable.Ready)?.value
        if (thread != null && outcome.message != null) mutable.update { it.copy(thread = Loadable.Ready(thread.copy(
            root = if (thread.root.id == outcome.message.id) outcome.message else thread.root,
            replies = thread.replies.copy(messages = (thread.replies.messages.filterNot { row -> row.id == outcome.message.id } +
                listOfNotNull(outcome.message.takeIf { row -> row.threadId == thread.root.id && row.id != thread.root.id })).sortedBy { row -> row.createdAtEpochMillis })))) }
    }

    fun markVisible(message: ChatMessage, thread: Boolean = false) {
        val source = source() ?: return
        val state = workspace.value ?: return
        if (!visible || state.selectedModule != Module.CHAT || message.id.startsWith("local:") || message.deliveryState != ChatDeliveryState.SENT || message.isEncrypted) return
        if (thread) {
            val current = (this.state.value.thread as? Loadable.Ready)?.value ?: return
            if (this.state.value.panel != ChatContentPanel.THREAD || current.root.conversationId != message.conversationId || current.replies.messages.none { it.id == message.id }) return
        } else if (this.state.value.panel != null || state.selectedConversation?.id != message.conversationId ||
            (state.chatMessages as? Loadable.Ready)?.value?.messages?.none { it.id == message.id } != false) return
        val key = if (thread) "${message.conversationId}:${message.threadId}" else message.conversationId
        if ((readTimes[key] ?: 0) >= message.createdAtEpochMillis) return
        pendingVisible = message to thread
        if (readJob?.isActive == true) return
        readJob = scope.launch {
            while (visible && sourceProvider()?.identity === source.identity) {
                val (latest, inThread) = pendingVisible ?: break; pendingVisible = null
                val latestKey = if (inThread) "${latest.conversationId}:${latest.threadId}" else latest.conversationId
                if ((readTimes[latestKey] ?: 0) >= latest.createdAtEpochMillis) continue
                suspendRunCatching {
                    if (inThread) { source.markThreadRead(latest.conversationId, requireNotNull(latest.threadId), latest.id); null }
                    else source.markRead(latest.conversationId, latest.id)
                }.onSuccess { conversation ->
                    if (visible && sourceProvider()?.identity === source.identity) {
                        readTimes[latestKey] = latest.createdAtEpochMillis
                        if (conversation != null) workspace.update { old -> if (old == null) old else old.copy(
                            selectedConversation = if (old.selectedConversation?.id == conversation.id) conversation else old.selectedConversation,
                            conversations = (old.conversations as? Loadable.Ready)?.value?.map { row -> if (row.id == conversation.id) conversation.copy(isPinnedLocally = row.isPinnedLocally) else row }
                                ?.let { Loadable.Ready(it) } ?: old.conversations) }
                    }
                }
            }
        }
    }
}

private fun changedChatContent() = DsmFailure(null, "This message has changed", "Refresh and select it again.", kind = DsmErrorKind.CHAT_ITEM_CHANGED)
