package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.network.ChatRealtimeClient
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Chat 读取、轮询与实时连接的唯一生命周期所有者。
 *
 * UI 仍通过 [WorkspaceState] 读取同一份状态；本模型只持有读取 Job、实时连接、资料代次和
 * 本地已读叠加，避免兼容门面复制第二份 Chat 状态。
 */
internal class ChatFeatureModel(
    private val scope: CoroutineScope,
    private val workspace: MutableStateFlow<WorkspaceState?>,
    private val repositoryProvider: () -> DsmRepository?,
    private val localizedFailure: (DsmFailure) -> String,
) {
    private val jobOwner = ChatFeatureJobOwner()
    private val lifecycleLock = Any()
    private var realtimeClient: ChatRealtimeClient? = null
    private var realtimeConnected = false
    private var localReadMarkers: Map<String, ChatLocalReadMarker> = emptyMap()
    private val readRevisions = ChatReadResourceRevisions()

    fun loadModule(repository: DsmRepository) {
        val token = ensureSession(repository) ?: return
        startRealtime(repository, token)
        val conversation = workspace.value
            ?.takeIf { isSessionCurrent(repository, token) }
            ?.selectedConversation
        if (conversation != null) {
            loadMessages(repository, token, conversation, reset = true)
            return
        }
        workspace.update { current ->
            current?.takeIf { isSessionCurrent(repository, token) }
                ?.copy(conversations = Loadable.Loading) ?: current
        }
        jobOwner.launch(
            scope = scope,
            name = CONVERSATION_LOAD_JOB,
            token = token,
            block = { taskToken ->
                val revision = beginConversationRead(repository, taskToken) ?: return@launch null
                val result = captureLoadable { repository.chatConversations() }
                if (!isTaskCurrent(repository, taskToken)) {
                    return@launch ChatConversationLoadOutcome(revision, result)
                }
                ChatConversationLoadOutcome(revision, result)
            },
            onResult = { taskToken, value ->
                if (value == null || !isTaskCurrent(repository, taskToken)) return@launch
                if (value.result is Loadable.Ready) {
                    publishConversations(
                        repository,
                        taskToken,
                        value.result.value,
                        value.revision,
                        requireConversationListActive = false,
                    )
                } else {
                    publishConversationState(
                        repository,
                        taskToken,
                        value.revision,
                    ) { current -> current.copy(conversations = value.result) }
                }
            },
        )
        startConversationPolling(repository, token)
    }

    fun openConversation(conversation: ChatConversation) {
        val repository = repositoryProvider() ?: return
        val token = ensureSession(repository) ?: return
        jobOwner.cancel(REFRESH_JOB)
        val canonicalConversation = publishConversationOpen(repository, token, conversation) ?: return
        loadMessages(repository, token, canonicalConversation, reset = true)
        if (!isRealtimeConnected()) startMessagePolling(repository, token, canonicalConversation)
    }

    fun closeConversation() {
        val repository = repositoryProvider()
        jobOwner.cancel(REFRESH_JOB)
        synchronized(lifecycleLock) {
            // 返回会话列表会切换读取资源；连同列表读取一起失效，避免关闭前的实时列表
            // 在重新读取前迟到发布。
            readRevisions.invalidateAll()
            retryChatStatePublication(
                readCurrent = { workspace.value },
                prepare = { current ->
                    ChatStatePublication(
                        current.copy(
                            selectedConversation = null,
                            chatMessages = Loadable.Idle,
                            chatIsLoadingMore = false,
                        ),
                        Unit,
                    )
                },
                compareAndSet = workspace::compareAndSet,
                onPublished = {},
            )
        }
        if (repository == null) return
        val token = ensureSession(repository) ?: return
        jobOwner.launch(
            scope = scope,
            name = CONVERSATION_LOAD_JOB,
            token = token,
            block = { taskToken ->
                val revision = beginConversationRead(repository, taskToken) ?: return@launch null
                val result = suspendRunCatching { repository.chatConversations() }
                if (!isTaskCurrent(repository, taskToken)) return@launch null
                ChatConversationReadOutcome(revision, result.getOrNull())
            },
            onResult = { taskToken, outcome ->
                if (outcome == null || !isTaskCurrent(repository, taskToken)) return@launch
                outcome.conversations?.let {
                    publishConversations(
                        repository,
                        taskToken,
                        it,
                        outcome.revision,
                        requireConversationListActive = false,
                    )
                }
                if (!isRealtimeConnected()) {
                    startConversationPolling(repository, token, sourceToken = taskToken)
                }
            },
        )
    }

    fun loadOlderMessages() {
        val repository = repositoryProvider() ?: return
        val token = ensureSession(repository) ?: return
        val state = workspace.value ?: return
        val conversation = state.selectedConversation ?: return
        val page = (state.chatMessages as? Loadable.Ready)?.value ?: return
        if (!page.hasMore || state.chatIsLoadingMore) return
        loadMessages(repository, token, conversation, reset = false)
    }

    fun toggleConversationPin(conversationId: String) {
        if (conversationId.isBlank()) return
        workspace.update { state ->
            state ?: return@update state
            val pinned = if (conversationId in state.chatPinnedConversationIds) {
                state.chatPinnedConversationIds.filterNot { it == conversationId }
            } else {
                (listOf(conversationId) + state.chatPinnedConversationIds)
                    .distinct()
                    .take(MAX_PINNED_CHAT_CONVERSATIONS)
            }
            val conversations = (state.conversations as? Loadable.Ready)?.value
            state.copy(
                chatPinnedConversationIds = pinned,
                conversations = conversations?.let {
                    Loadable.Ready(applyChatConversationPreferences(it, pinned))
                } ?: state.conversations,
                selectedConversation = state.selectedConversation?.let {
                    if (it.id == conversationId) it.copy(isPinnedLocally = conversationId in pinned) else it
                },
            )
        }
    }

    fun clearLocalReadMarkers() {
        synchronized(lifecycleLock) {
            // 清除 marker 通常意味着资料即将切换；同时使正在读取的旧资源失效，防止它在
            // 清除后成功提交并重新写入与当前会话不对应的 marker。
            readRevisions.invalidateAll()
            localReadMarkers = emptyMap()
        }
    }

    fun stopForModuleExit() {
        // 离开 Chat 只终止当前读取/实时会话；本地已读叠加属于当前资料的 UI 状态，返回 Chat
        // 后仍需保留。递增代次可拒绝已停止客户端的迟到回调。
        jobOwner.invalidate(clearProfile = false)
        synchronized(lifecycleLock) {
            readRevisions.invalidateAll()
        }
        stopRealtimeClient()
    }

    fun clearForProfileSwitch() {
        stopForModuleExit()
        clearLocalReadMarkers()
    }

    private fun ensureSession(repository: DsmRepository): ChatFeatureToken? {
        if (repositoryProvider() !== repository) return null
        val profileId = workspace.value?.profile?.id ?: return null
        val session = jobOwner.ensureSession(profileId)
        if (session.changed) {
            stopRealtimeClient()
            synchronized(lifecycleLock) {
                readRevisions.invalidateAll()
                localReadMarkers = emptyMap()
            }
        }
        return session.token
    }

    private fun isSessionCurrent(repository: DsmRepository, token: ChatFeatureToken): Boolean =
        isSessionCurrent(repository, token, workspace.value)

    private fun isSessionCurrent(
        repository: DsmRepository,
        token: ChatFeatureToken,
        state: WorkspaceState?,
    ): Boolean = jobOwner.isCurrent(token) && repositoryProvider() === repository &&
        state?.profile?.id == token.profileId

    private fun isTaskCurrent(repository: DsmRepository, token: ChatTaskToken): Boolean =
        isTaskCurrent(repository, token, workspace.value)

    private fun isTaskCurrent(
        repository: DsmRepository,
        token: ChatTaskToken,
        state: WorkspaceState?,
    ): Boolean = jobOwner.isCurrent(token) && repositoryProvider() === repository &&
        state?.profile?.id == token.session.profileId

    private fun beginConversationRead(
        repository: DsmRepository,
        token: ChatTaskToken,
    ): Long? = synchronized(lifecycleLock) {
        val state = workspace.value
        if (!isTaskCurrent(repository, token, state)) {
            null
        } else {
            readRevisions.beginConversationRead()
        }
    }

    private fun beginMessageRead(
        repository: DsmRepository,
        token: ChatTaskToken,
        conversation: ChatConversation,
    ): Long? = synchronized(lifecycleLock) {
        val state = workspace.value
        if (!isTaskCurrent(repository, token, state) ||
            state?.selectedConversation?.id != conversation.id
        ) {
            null
        } else {
            readRevisions.beginMessageRead(conversation.id)
        }
    }

    private fun publishConversationOpen(
        repository: DsmRepository,
        token: ChatFeatureToken,
        requested: ChatConversation,
    ): ChatConversation? = synchronized(lifecycleLock) {
        var openedConversation: ChatConversation? = null
        retryChatStatePublication(
            readCurrent = { workspace.value },
            prepare = { current ->
                if (!isSessionCurrent(repository, token, current)) {
                    null
                } else {
                    val canonical = (current.conversations as? Loadable.Ready)
                        ?.value
                        ?.firstOrNull { it.id == requested.id }
                        ?: requested
                    val marker = canonical.toChatLocalReadMarker()
                    val markers = if (marker == null) {
                        localReadMarkers - canonical.id
                    } else {
                        localReadMarkers + (canonical.id to marker)
                    }
                    val conversations = (current.conversations as? Loadable.Ready)?.value
                    val next = current.copy(
                        selectedConversation = canonical.copy(unreadCount = 0),
                        chatMessages = Loadable.Loading,
                        chatIsLoadingMore = false,
                        conversations = conversations?.map { item ->
                            if (item.id == canonical.id) item.copy(unreadCount = 0) else item
                        }?.let { Loadable.Ready(it) } ?: current.conversations,
                    )
                    ChatStatePublication(next, ChatConversationOpenCommit(canonical, markers))
                }
            },
            compareAndSet = workspace::compareAndSet,
            onPublished = { commit ->
                readRevisions.invalidateMessageReads()
                localReadMarkers = commit.markers
                openedConversation = commit.conversation
            },
        )
        openedConversation
    }

    private fun publishConversationState(
        repository: DsmRepository,
        token: ChatTaskToken,
        revision: Long,
        requireConversationListActive: Boolean = false,
        transform: (WorkspaceState) -> WorkspaceState?,
    ) {
        synchronized(lifecycleLock) {
            retryChatStatePublication(
                readCurrent = { workspace.value },
                prepare = { current ->
                    if (!canPublishConversationRead(
                            repository,
                            token,
                            revision,
                            current,
                            requireConversationListActive,
                        )
                    ) {
                        null
                    } else {
                        transform(current)?.let { ChatStatePublication(it, Unit) }
                    }
                },
                compareAndSet = workspace::compareAndSet,
                onPublished = {},
            )
        }
    }

    private fun publishMessageState(
        repository: DsmRepository,
        token: ChatTaskToken,
        conversation: ChatConversation,
        revision: Long,
        transform: (WorkspaceState) -> WorkspaceState?,
    ) {
        synchronized(lifecycleLock) {
            retryChatStatePublication(
                readCurrent = { workspace.value },
                prepare = { current ->
                    if (!canPublishMessageRead(repository, token, conversation, revision, current)) {
                        null
                    } else {
                        transform(current)?.let { ChatStatePublication(it, Unit) }
                    }
                },
                compareAndSet = workspace::compareAndSet,
                onPublished = {},
            )
        }
    }

    private fun publishConversationFailureIfLoading(
        repository: DsmRepository,
        token: ChatTaskToken,
        revision: Long,
        requireConversationListActive: Boolean,
        error: Throwable,
    ) {
        publishConversationState(
            repository,
            token,
            revision,
            requireConversationListActive,
        ) { current ->
            if (current.conversations is Loadable.Loading) {
                current.copy(conversations = Loadable.Failed(error.asDsmFailure()))
            } else {
                current
            }
        }
    }

    private fun canPublishConversationRead(
        repository: DsmRepository,
        token: ChatTaskToken,
        revision: Long,
        state: WorkspaceState,
        requireConversationListActive: Boolean,
    ): Boolean = isTaskCurrent(repository, token, state) &&
        readRevisions.isCurrentConversationRead(revision) &&
        (!requireConversationListActive ||
            state.selectedModule == Module.CHAT && state.selectedConversation == null)

    private fun canPublishMessageRead(
        repository: DsmRepository,
        token: ChatTaskToken,
        conversation: ChatConversation,
        revision: Long,
        state: WorkspaceState,
    ): Boolean = isTaskCurrent(repository, token, state) &&
        readRevisions.isCurrentMessageRead(conversation.id, revision) &&
        state.selectedConversation?.id == conversation.id

    private fun loadMessages(
        repository: DsmRepository,
        token: ChatFeatureToken,
        conversation: ChatConversation,
        reset: Boolean,
    ) {
        jobOwner.launch(
            scope = scope,
            name = MESSAGE_LOAD_JOB,
            token = token,
            block = { taskToken ->
                val currentPage = (workspace.value?.chatMessages as? Loadable.Ready)?.value
                val offset = if (reset) 0 else currentPage?.nextOffset
                if (!reset && offset == null) {
                    null
                } else {
                    val revision = beginMessageRead(repository, taskToken, conversation)
                        ?: return@launch null
                    if (!reset) {
                        publishMessageState(repository, taskToken, conversation, revision) { current ->
                            current.copy(chatIsLoadingMore = true)
                        }
                    }
                    val outcome = ChatMessageLoadOutcome(
                        reset = reset,
                        revision = revision,
                        result = suspendRunCatching {
                            repository.chatMessages(conversation.id, checkNotNull(offset))
                        },
                    )
                    if (!isTaskCurrent(repository, taskToken)) return@launch null
                    outcome
                }
            },
            onResult = { taskToken, outcome ->
                if (outcome == null || !isTaskCurrent(repository, taskToken)) return@launch
                val page = outcome.result.getOrNull()
                if (page != null) {
                    publishMessageState(
                        repository,
                        taskToken,
                        conversation,
                        outcome.revision,
                    ) { current ->
                        val visible = (current.chatMessages as? Loadable.Ready)?.value
                        val merged = mergeChatMessagePage(
                            page,
                            visible,
                            current.chatOutgoingMessages[conversation.id].orEmpty(),
                        )
                        current.copy(
                            chatMessages = Loadable.Ready(merged),
                            chatIsLoadingMore = false,
                        )
                    }
                    return@launch
                }
                val error = outcome.result.exceptionOrNull() ?: return@launch
                publishMessageState(
                    repository,
                    taskToken,
                    conversation,
                    outcome.revision,
                ) { current ->
                    if (outcome.reset) {
                        current.copy(
                            chatMessages = Loadable.Failed(error.asDsmFailure()),
                            chatIsLoadingMore = false,
                        )
                    } else {
                        current.copy(
                            chatIsLoadingMore = false,
                            message = localizedFailure(error.asDsmFailure()),
                        )
                    }
                }
            },
        )
    }

    private suspend fun refreshLatestMessages(
        repository: DsmRepository,
        token: ChatTaskToken,
        conversation: ChatConversation,
    ) {
        if (!isTaskCurrent(repository, token)) return
        val revision = beginMessageRead(repository, token, conversation) ?: return
        val result = suspendRunCatching { repository.chatMessages(conversation.id, 0) }
        if (!isTaskCurrent(repository, token)) return
        val latest = result.getOrNull()
        if (latest == null) {
            val error = result.exceptionOrNull() ?: return
            publishMessageState(repository, token, conversation, revision) { current ->
                if (current.chatMessages is Loadable.Loading) {
                    current.copy(
                        chatMessages = Loadable.Failed(error.asDsmFailure()),
                        chatIsLoadingMore = false,
                    )
                } else {
                    current.copy(chatIsLoadingMore = false)
                }
            }
            return
        }
        publishMessageState(repository, token, conversation, revision) { current ->
            val existing = (current.chatMessages as? Loadable.Ready)?.value
            val page = if (existing == null) {
                mergeChatMessagePage(
                    latest,
                    null,
                    current.chatOutgoingMessages[conversation.id].orEmpty(),
                )
            } else {
                mergeChatMessagePage(
                    existing,
                    latest,
                    current.chatOutgoingMessages[conversation.id].orEmpty(),
                )
            }
            current.copy(
                chatMessages = Loadable.Ready(page),
                chatIsLoadingMore = false,
            )
        }
    }

    private fun publishConversations(
        repository: DsmRepository,
        token: ChatTaskToken,
        conversations: List<ChatConversation>,
        revision: Long,
        requireConversationListActive: Boolean,
    ) {
        synchronized(lifecycleLock) {
            retryChatStatePublication(
                readCurrent = { workspace.value },
                prepare = { state ->
                    if (!canPublishConversationRead(
                            repository,
                            token,
                            revision,
                            state,
                            requireConversationListActive,
                        )
                    ) {
                        null
                    } else {
                        val overlay = applyChatLocalReadOverlay(conversations, localReadMarkers)
                        val visible = applyChatConversationPreferences(
                            overlay.conversations,
                            state.chatPinnedConversationIds,
                        )
                        ChatStatePublication(state.withRefreshedChatConversations(visible), overlay.markers)
                    }
                },
                compareAndSet = workspace::compareAndSet,
                onPublished = { markers -> localReadMarkers = markers },
            )
        }
    }

    private fun startConversationPolling(
        repository: DsmRepository,
        token: ChatFeatureToken,
        sourceToken: ChatTaskToken? = null,
    ) {
        jobOwner.launch(
            scope = scope,
            name = REFRESH_JOB,
            token = token,
            sourceToken = sourceToken,
            block = { taskToken ->
                while (currentCoroutineContext().isActive) {
                    delay(CHAT_REFRESH_INTERVAL_MILLIS)
                    if (!isTaskCurrent(repository, taskToken)) break
                    val current = workspace.value
                    if (current?.selectedModule != Module.CHAT || current.selectedConversation != null
                    ) break
                    val revision = beginConversationRead(repository, taskToken) ?: break
                    val result = suspendRunCatching { repository.chatConversations() }
                    if (!isTaskCurrent(repository, taskToken)) break
                    val conversations = result.getOrNull()
                    if (conversations != null) {
                        publishConversations(
                            repository,
                            taskToken,
                            conversations,
                            revision,
                            requireConversationListActive = true,
                        )
                    } else {
                        result.exceptionOrNull()?.let { error ->
                            publishConversationFailureIfLoading(
                                repository,
                                taskToken,
                                revision,
                                requireConversationListActive = true,
                                error = error,
                            )
                        }
                    }
                }
            },
            onResult = { _, _ -> },
        )
    }

    private fun startMessagePolling(
        repository: DsmRepository,
        token: ChatFeatureToken,
        conversation: ChatConversation,
        sourceToken: ChatTaskToken? = null,
    ) {
        jobOwner.launch(
            scope = scope,
            name = REFRESH_JOB,
            token = token,
            sourceToken = sourceToken,
            block = { taskToken ->
                while (currentCoroutineContext().isActive) {
                    delay(CHAT_REFRESH_INTERVAL_MILLIS)
                    if (!isTaskCurrent(repository, taskToken)) break
                    val current = workspace.value
                    if (current?.selectedModule != Module.CHAT ||
                        current.selectedConversation?.id != conversation.id
                    ) break
                    refreshLatestMessages(repository, taskToken, conversation)
                }
            },
            onResult = { _, _ -> },
        )
    }

    private fun startRealtime(repository: DsmRepository, token: ChatFeatureToken) {
        synchronized(lifecycleLock) {
            if (realtimeClient != null) return
        }
        val client = repository.chatRealtimeClient(
            onConnectionChanged = { connected ->
                jobOwner.launch(
                    scope = scope,
                    name = REALTIME_CONNECTION_JOB,
                    token = token,
                    block = { taskToken ->
                        if (!isTaskCurrent(repository, taskToken)) return@launch connected
                        connected
                    },
                    onResult = { taskToken, currentConnected ->
                        if (!isTaskCurrent(repository, taskToken)) return@launch
                        val connectionUpdated = synchronized(lifecycleLock) {
                            if (!isTaskCurrent(repository, taskToken)) {
                                false
                            } else {
                                realtimeConnected = currentConnected
                                true
                            }
                        }
                        if (!connectionUpdated || !isTaskCurrent(repository, taskToken)) return@launch
                        if (currentConnected) {
                            jobOwner.cancel(REFRESH_JOB, sourceToken = taskToken)
                        } else {
                            if (!isTaskCurrent(repository, taskToken)) return@launch
                            val state = workspace.value
                            if (state?.selectedModule == Module.CHAT) {
                                state.selectedConversation?.let { conversation ->
                                    startMessagePolling(
                                        repository,
                                        token,
                                        conversation,
                                        sourceToken = taskToken,
                                    )
                                } ?: startConversationPolling(
                                    repository,
                                    token,
                                    sourceToken = taskToken,
                                )
                            }
                        }
                    },
                )
            },
            onContentChanged = {
                jobOwner.launch(
                    scope = scope,
                    name = REALTIME_REFRESH_JOB,
                    token = token,
                    block = { taskToken ->
                        delay(CHAT_REALTIME_COALESCE_MILLIS)
                        if (!isTaskCurrent(repository, taskToken)) return@launch
                        val state = workspace.value
                        if (state?.selectedModule != Module.CHAT) return@launch
                        state.selectedConversation?.let { conversation ->
                            refreshLatestMessages(repository, taskToken, conversation)
                        } ?: run {
                            val revision = beginConversationRead(repository, taskToken) ?: return@launch
                            val result = suspendRunCatching { repository.chatConversations() }
                            if (!isTaskCurrent(repository, taskToken)) return@launch
                            val conversations = result.getOrNull()
                            if (conversations != null) {
                                publishConversations(
                                    repository,
                                    taskToken,
                                    conversations,
                                    revision,
                                    requireConversationListActive = true,
                                )
                            } else {
                                result.exceptionOrNull()?.let { error ->
                                    publishConversationFailureIfLoading(
                                        repository,
                                        taskToken,
                                        revision,
                                        requireConversationListActive = true,
                                        error = error,
                                    )
                                }
                            }
                        }
                    },
                    onResult = { _, _ -> },
                )
            },
        )
        val accepted = synchronized(lifecycleLock) {
            if (isSessionCurrent(repository, token) && realtimeClient == null) {
                realtimeClient = client
                realtimeConnected = false
                true
            } else {
                false
            }
        }
        if (accepted) client.start(scope) else client.stop()
    }

    private fun isRealtimeConnected(): Boolean = synchronized(lifecycleLock) { realtimeConnected }

    private fun stopRealtimeClient() {
        val client = synchronized(lifecycleLock) {
            realtimeConnected = false
            realtimeClient.also { realtimeClient = null }
        }
        client?.stop()
    }

    private data class ChatMessageLoadOutcome(
        val reset: Boolean,
        val revision: Long,
        val result: Result<ChatMessagePage>,
    )

    private data class ChatConversationLoadOutcome(
        val revision: Long,
        val result: Loadable<List<ChatConversation>>,
    )

    private data class ChatConversationReadOutcome(
        val revision: Long,
        val conversations: List<ChatConversation>?,
    )

    private data class ChatConversationOpenCommit(
        val conversation: ChatConversation,
        val markers: Map<String, ChatLocalReadMarker>,
    )

    private companion object {
        const val CONVERSATION_LOAD_JOB = "conversation-load"
        const val MESSAGE_LOAD_JOB = "message-load"
        const val REFRESH_JOB = "refresh"
        const val REALTIME_CONNECTION_JOB = "realtime-connection"
        const val REALTIME_REFRESH_JOB = "realtime-refresh"
    }
}

/** 将当前可见消息、本地待发送消息与本次读取结果合并，分页字段始终来自本次结果。 */
internal fun mergeChatMessagePage(
    page: ChatMessagePage,
    visible: ChatMessagePage?,
    outgoing: List<ChatMessage>,
): ChatMessagePage = page.copy(
    messages = (page.messages + visible?.messages.orEmpty() + outgoing)
        .distinctBy(ChatMessage::id)
        .sortedBy(ChatMessage::createdAtEpochSeconds),
)

/** 会话列表与单会话消息分别使用单调 revision，防止不同读取任务相互覆盖。 */
internal class ChatReadResourceRevisions {
    private val lock = Any()
    private var nextRevision = 0L
    private var conversationRevision = 0L
    private val messageRevisions = mutableMapOf<String, Long>()

    fun beginConversationRead(): Long = synchronized(lock) {
        (++nextRevision).also { conversationRevision = it }
    }

    fun beginMessageRead(conversationId: String): Long = synchronized(lock) {
        (++nextRevision).also { messageRevisions[conversationId] = it }
    }

    fun isCurrentConversationRead(revision: Long): Boolean = synchronized(lock) {
        conversationRevision == revision
    }

    fun isCurrentMessageRead(conversationId: String, revision: Long): Boolean = synchronized(lock) {
        messageRevisions[conversationId] == revision
    }

    fun invalidateMessageReads() = synchronized(lock) {
        nextRevision += 1
        messageRevisions.clear()
    }

    fun invalidateAll() = synchronized(lock) {
        nextRevision += 1
        conversationRevision = nextRevision
        messageRevisions.clear()
    }
}

internal data class ChatStatePublication<State, Commit>(
    val state: State,
    val commit: Commit,
)

/**
 * 在调用方持有其生命周期锁时，以显式 CAS 重试发布状态；仅成功的尝试可以提交外部 marker。
 */
internal fun <State : Any, Commit> retryChatStatePublication(
    readCurrent: () -> State?,
    prepare: (State) -> ChatStatePublication<State, Commit>?,
    compareAndSet: (State, State) -> Boolean,
    onPublished: (Commit) -> Unit,
): Boolean {
    while (true) {
        val current = readCurrent() ?: return false
        val publication = prepare(current) ?: return false
        if (compareAndSet(current, publication.state)) {
            onPublished(publication.commit)
            return true
        }
    }
}

internal data class ChatFeatureToken(
    val profileId: String,
    val generation: Long,
)

internal data class ChatFeatureSession(
    val token: ChatFeatureToken,
    val changed: Boolean,
)

/** 某一类 Chat 读取任务的唯一身份；同名任务替换时仅新代次可以发布副作用。 */
internal data class ChatTaskToken(
    val session: ChatFeatureToken,
    val name: String,
    val taskGeneration: Long,
)

/** Chat 特性内所有读取 Job 的唯一所有者，拒绝过期资料的迟到发布。 */
internal class ChatFeatureJobOwner {
    private val lock = Any()
    private val generation = AtomicLong(0)
    private var activeProfileId: String? = null
    private val jobs = mutableMapOf<String, Job>()
    private val taskGenerations = mutableMapOf<String, Long>()

    fun ensureSession(profileId: String): ChatFeatureSession {
        val jobsToCancel: List<Job>
        val session: ChatFeatureSession
        synchronized(lock) {
            if (activeProfileId == profileId) {
                return ChatFeatureSession(
                    ChatFeatureToken(profileId, generation.get()),
                    changed = false,
                )
            }
            activeProfileId = profileId
            val nextGeneration = generation.incrementAndGet()
            jobsToCancel = jobs.values.toList()
            jobs.clear()
            taskGenerations.clear()
            session = ChatFeatureSession(
                ChatFeatureToken(profileId, nextGeneration),
                changed = true,
            )
        }
        jobsToCancel.forEach(Job::cancel)
        return session
    }

    fun invalidate(clearProfile: Boolean = true) {
        val jobsToCancel = synchronized(lock) {
            if (clearProfile) activeProfileId = null
            generation.incrementAndGet()
            jobs.values.toList().also {
                jobs.clear()
                taskGenerations.clear()
            }
        }
        jobsToCancel.forEach(Job::cancel)
    }

    fun isCurrent(token: ChatFeatureToken): Boolean = synchronized(lock) { isSessionCurrentLocked(token) }

    fun isCurrent(token: ChatTaskToken): Boolean = synchronized(lock) { isTaskCurrentLocked(token) }

    fun cancel(name: String, sourceToken: ChatTaskToken? = null) {
        val job = synchronized(lock) {
            if (sourceToken != null && !isTaskCurrentLocked(sourceToken)) return@synchronized null
            invalidateTaskLocked(name)
            jobs.remove(name)
        }
        job?.cancel()
    }

    fun <T> launch(
        scope: CoroutineScope,
        name: String,
        token: ChatFeatureToken,
        sourceToken: ChatTaskToken? = null,
        block: suspend (ChatTaskToken) -> T,
        onResult: (ChatTaskToken, T) -> Unit,
    ): Job? {
        val taskTokenAndPrevious = synchronized(lock) {
            if (!isSessionCurrentLocked(token) ||
                sourceToken != null && !isTaskCurrentLocked(sourceToken)
            ) return@synchronized null
            val taskToken = ChatTaskToken(
                session = token,
                name = name,
                taskGeneration = invalidateTaskLocked(name),
            )
            taskToken to jobs.remove(name)
        } ?: return null
        val (taskToken, previous) = taskTokenAndPrevious
        previous?.cancel()
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val value = block(taskToken)
            if (isCurrent(taskToken)) onResult(taskToken, value)
        }
        val accepted = synchronized(lock) {
            if (!isTaskCurrentLocked(taskToken)) {
                false
            } else {
                jobs[name] = job
                true
            }
        }
        if (!accepted) {
            synchronized(lock) {
                if (jobs[name] === job) jobs.remove(name)
            }
            job.cancel()
            return null
        }
        job.invokeOnCompletion {
            synchronized(lock) {
                if (jobs[name] === job) jobs.remove(name)
            }
        }
        job.start()
        return job
    }

    private fun isSessionCurrentLocked(token: ChatFeatureToken): Boolean =
        activeProfileId == token.profileId && generation.get() == token.generation

    private fun isTaskCurrentLocked(token: ChatTaskToken): Boolean =
        isSessionCurrentLocked(token.session) &&
            taskGenerations[token.name] == token.taskGeneration

    /** 先提升同名任务代次，再由调用方在锁外取消旧 Job。 */
    private fun invalidateTaskLocked(name: String): Long {
        val next = (taskGenerations[name] ?: 0) + 1
        taskGenerations[name] = next
        return next
    }
}
