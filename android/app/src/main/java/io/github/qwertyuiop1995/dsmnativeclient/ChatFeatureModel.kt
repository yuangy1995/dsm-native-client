package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
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
    private val sourceProvider: () -> ChatFeatureDataSource? = {
        repositoryProvider()?.let(::DsmRepositoryChatFeatureDataSource)
    },
) {
    private val jobOwner = ChatFeatureJobOwner()
    private val lifecycleLock = Any()
    private var realtimeClient: ChatFeatureRealtimeConnection? = null
    private var realtimeConnected = false
    private var localReadMarkers: Map<String, ChatLocalReadMarker> = emptyMap()
    private val readRevisions = ChatReadResourceRevisions()

    fun loadModule(repository: DsmRepository) {
        if (repositoryProvider() !== repository) return
        val source = sourceProvider()?.takeIf { it.identity === repository } ?: return
        loadModule(source)
    }

    /** 供内部适配器调用的模块入口，生产路径仍经由现有 DsmRepository 入口。 */
    internal fun loadModule() {
        sourceProvider()?.let(::loadModule)
    }

    private fun loadModule(source: ChatFeatureDataSource) {
        val token = ensureSession(source) ?: return
        startRealtime(source, token)
        val conversation = workspace.value
            ?.takeIf { isSessionCurrent(source, token) }
            ?.selectedConversation
        if (conversation != null) {
            loadMessages(source, token, conversation, ChatMessageReadLane.HEAD)
            return
        }
        workspace.update { current ->
            current?.takeIf { isSessionCurrent(source, token) }
                ?.copy(conversations = Loadable.Loading) ?: current
        }
        jobOwner.launch(
            scope = scope,
            name = CONVERSATION_LOAD_JOB,
            token = token,
            block = { taskToken ->
                val revision = beginConversationRead(source, taskToken) ?: return@launch null
                val result = captureLoadable { source.conversations() }
                if (!isTaskCurrent(source, taskToken)) {
                    return@launch ChatConversationLoadOutcome(revision, result)
                }
                ChatConversationLoadOutcome(revision, result)
            },
            onResult = { taskToken, value ->
                if (value == null || !isTaskCurrent(source, taskToken)) return@launch
                if (value.result is Loadable.Ready) {
                    publishConversations(
                        source,
                        taskToken,
                        value.result.value,
                        value.revision,
                        requireConversationListActive = false,
                    )
                } else {
                    publishConversationState(
                        source,
                        taskToken,
                        value.revision,
                    ) { current -> current.copy(conversations = value.result) }
                }
            },
        )
        startConversationPolling(source, token)
    }

    fun openConversation(conversation: ChatConversation) {
        val source = sourceProvider() ?: return
        val token = ensureSession(source) ?: return
        jobOwner.cancel(REFRESH_JOB)
        val canonicalConversation = publishConversationOpen(source, token, conversation) ?: return
        loadMessages(source, token, canonicalConversation, ChatMessageReadLane.HEAD)
        if (!isRealtimeConnected()) startMessagePolling(source, token, canonicalConversation)
    }

    fun closeConversation() {
        val source = sourceProvider()
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
        if (source == null) return
        val token = ensureSession(source) ?: return
        jobOwner.launch(
            scope = scope,
            name = CONVERSATION_LOAD_JOB,
            token = token,
            block = { taskToken ->
                val revision = beginConversationRead(source, taskToken) ?: return@launch null
                val result = suspendRunCatching { source.conversations() }
                if (!isTaskCurrent(source, taskToken)) return@launch null
                ChatConversationReadOutcome(revision, result.getOrNull())
            },
            onResult = { taskToken, outcome ->
                if (outcome == null || !isTaskCurrent(source, taskToken)) return@launch
                outcome.conversations?.let {
                    publishConversations(
                        source,
                        taskToken,
                        it,
                        outcome.revision,
                        requireConversationListActive = false,
                    )
                }
                if (!isRealtimeConnected()) {
                    startConversationPolling(source, token, sourceToken = taskToken)
                }
            },
        )
    }

    fun loadOlderMessages() {
        val source = sourceProvider() ?: return
        val token = ensureSession(source) ?: return
        val state = workspace.value ?: return
        val conversation = state.selectedConversation ?: return
        val page = (state.chatMessages as? Loadable.Ready)?.value ?: return
        if (!page.hasMore || state.chatIsLoadingMore) return
        val expectedOffset = page.nextOffset ?: return
        loadMessages(source, token, conversation, ChatMessageReadLane.PAGINATION, expectedOffset)
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
            workspace.update { current -> current?.copy(chatIsLoadingMore = false) ?: current }
        }
        stopRealtimeClient()
    }

    fun clearForProfileSwitch() {
        stopForModuleExit()
        clearLocalReadMarkers()
    }

    private fun ensureSession(source: ChatFeatureDataSource): ChatFeatureToken? {
        if (sourceProvider()?.identity !== source.identity) return null
        val profileId = workspace.value?.profile?.id ?: return null
        val session = jobOwner.ensureSession(profileId)
        if (session.changed) {
            stopRealtimeClient()
            synchronized(lifecycleLock) {
                readRevisions.invalidateAll()
                localReadMarkers = emptyMap()
                workspace.update { current -> current?.copy(chatIsLoadingMore = false) ?: current }
            }
        }
        return session.token
    }

    private fun isSessionCurrent(source: ChatFeatureDataSource, token: ChatFeatureToken): Boolean =
        isSessionCurrent(source, token, workspace.value)

    private fun isSessionCurrent(
        source: ChatFeatureDataSource,
        token: ChatFeatureToken,
        state: WorkspaceState?,
    ): Boolean = jobOwner.isCurrent(token) && sourceProvider()?.identity === source.identity &&
        state?.profile?.id == token.profileId

    private fun isTaskCurrent(source: ChatFeatureDataSource, token: ChatTaskToken): Boolean =
        isTaskCurrent(source, token, workspace.value)

    private fun isTaskCurrent(
        source: ChatFeatureDataSource,
        token: ChatTaskToken,
        state: WorkspaceState?,
    ): Boolean = jobOwner.isCurrent(token) && sourceProvider()?.identity === source.identity &&
        state?.profile?.id == token.session.profileId

    private fun beginConversationRead(
        source: ChatFeatureDataSource,
        token: ChatTaskToken,
    ): Long? = synchronized(lifecycleLock) {
        val state = workspace.value
        if (!isTaskCurrent(source, token, state)) {
            null
        } else {
            readRevisions.beginConversationRead()
        }
    }

    private fun beginMessageRead(
        source: ChatFeatureDataSource,
        token: ChatTaskToken,
        conversation: ChatConversation,
        lane: ChatMessageReadLane,
    ): Long? = synchronized(lifecycleLock) {
        val state = workspace.value
        if (!isTaskCurrent(source, token, state) ||
            state?.selectedConversation?.id != conversation.id
        ) {
            null
        } else {
            readRevisions.beginMessageRead(conversation.id, lane)
        }
    }

    private fun publishConversationOpen(
        source: ChatFeatureDataSource,
        token: ChatFeatureToken,
        requested: ChatConversation,
    ): ChatConversation? = synchronized(lifecycleLock) {
        var openedConversation: ChatConversation? = null
        retryChatStatePublication(
            readCurrent = { workspace.value },
            prepare = { current ->
                if (!isSessionCurrent(source, token, current)) {
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
        source: ChatFeatureDataSource,
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
                            source,
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
        source: ChatFeatureDataSource,
        token: ChatTaskToken,
        conversation: ChatConversation,
        lane: ChatMessageReadLane,
        revision: Long,
        transform: (WorkspaceState) -> WorkspaceState?,
    ): Boolean = synchronized(lifecycleLock) {
        retryChatStatePublication(
                readCurrent = { workspace.value },
                prepare = { current ->
                    if (!canPublishMessageRead(source, token, conversation, lane, revision, current)) {
                        null
                    } else {
                        transform(current)?.let { ChatStatePublication(it, Unit) }
                    }
                },
                compareAndSet = workspace::compareAndSet,
                onPublished = {},
        )
    }

    private fun publishConversationFailureIfLoading(
        source: ChatFeatureDataSource,
        token: ChatTaskToken,
        revision: Long,
        requireConversationListActive: Boolean,
        error: Throwable,
    ) {
        publishConversationState(
            source,
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
        source: ChatFeatureDataSource,
        token: ChatTaskToken,
        revision: Long,
        state: WorkspaceState,
        requireConversationListActive: Boolean,
    ): Boolean = isTaskCurrent(source, token, state) &&
        readRevisions.isCurrentConversationRead(revision) &&
        (!requireConversationListActive ||
            state.selectedModule == Module.CHAT && state.selectedConversation == null)

    private fun canPublishMessageRead(
        source: ChatFeatureDataSource,
        token: ChatTaskToken,
        conversation: ChatConversation,
        lane: ChatMessageReadLane,
        revision: Long,
        state: WorkspaceState,
    ): Boolean = isTaskCurrent(source, token, state) &&
        readRevisions.isCurrentMessageRead(conversation.id, lane, revision) &&
        state.selectedConversation?.id == conversation.id

    private fun loadMessages(
        source: ChatFeatureDataSource,
        token: ChatFeatureToken,
        conversation: ChatConversation,
        lane: ChatMessageReadLane,
        expectedOffset: Int? = null,
    ) {
        val offset = when (lane) {
            ChatMessageReadLane.HEAD -> 0
            ChatMessageReadLane.PAGINATION -> expectedOffset ?: return
        }
        jobOwner.launch(
            scope = scope,
            name = lane.jobOwnerName,
            token = token,
            block = { taskToken ->
                val revision = beginMessageRead(source, taskToken, conversation, lane)
                    ?: return@launch null
                if (lane == ChatMessageReadLane.PAGINATION) {
                    val ownsLoading = publishMessageState(
                        source,
                        taskToken,
                        conversation,
                        lane,
                        revision,
                    ) { current ->
                        val currentPage = (current.chatMessages as? Loadable.Ready)?.value
                        if (currentPage?.nextOffset != offset || !currentPage.hasMore ||
                            current.chatIsLoadingMore
                        ) {
                            null
                        } else {
                            current.copy(chatIsLoadingMore = true)
                        }
                    }
                    if (!ownsLoading) return@launch null
                }
                val outcome = ChatMessageLoadOutcome(
                    lane = lane,
                    revision = revision,
                    expectedOffset = expectedOffset,
                    result = suspendRunCatching { source.messages(conversation.id, offset) },
                )
                if (!isTaskCurrent(source, taskToken)) return@launch null
                outcome
            },
            onResult = { taskToken, outcome ->
                if (outcome == null || !isTaskCurrent(source, taskToken)) return@launch
                val page = outcome.result.getOrNull()
                if (page != null) {
                    publishMessageState(
                        source,
                        taskToken,
                        conversation,
                        outcome.lane,
                        outcome.revision,
                    ) { current ->
                        val visible = (current.chatMessages as? Loadable.Ready)?.value
                        val outgoing = current.chatOutgoingMessages[conversation.id].orEmpty()
                        when (outcome.lane) {
                            ChatMessageReadLane.HEAD -> {
                                val metadataSource = visible ?: page
                                val merged = reconcileChatMessagePage(
                                    metadataSource = metadataSource,
                                    lowerPriority = visible?.messages.orEmpty(),
                                    higherPriority = page.messages,
                                    outgoing = outgoing,
                                )
                                current.copy(chatMessages = Loadable.Ready(merged))
                            }
                            ChatMessageReadLane.PAGINATION -> {
                                if (visible == null || visible.nextOffset != outcome.expectedOffset) {
                                    null
                                } else {
                                    val merged = reconcileChatMessagePage(
                                        metadataSource = page,
                                        lowerPriority = page.messages,
                                        higherPriority = visible.messages,
                                        outgoing = outgoing,
                                    )
                                    current.copy(
                                        chatMessages = Loadable.Ready(merged),
                                        chatIsLoadingMore = false,
                                    )
                                }
                            }
                        }
                    }
                    return@launch
                }
                val error = outcome.result.exceptionOrNull() ?: return@launch
                publishMessageState(
                    source,
                    taskToken,
                    conversation,
                    outcome.lane,
                    outcome.revision,
                ) { current ->
                    when (outcome.lane) {
                        ChatMessageReadLane.HEAD -> current.copy(
                            chatMessages = Loadable.Failed(error.asDsmFailure()),
                        )
                        ChatMessageReadLane.PAGINATION -> current.copy(
                            chatIsLoadingMore = false,
                            message = localizedFailure(error.asDsmFailure()),
                        )
                    }
                }
            },
        )
    }

    private suspend fun refreshLatestMessages(
        source: ChatFeatureDataSource,
        token: ChatTaskToken,
        conversation: ChatConversation,
    ) {
        if (!isTaskCurrent(source, token)) return
        val revision = beginMessageRead(source, token, conversation, ChatMessageReadLane.HEAD) ?: return
        val result = suspendRunCatching { source.messages(conversation.id, 0) }
        if (!isTaskCurrent(source, token)) return
        val latest = result.getOrNull()
        if (latest == null) {
            val error = result.exceptionOrNull() ?: return
            publishMessageState(
                source,
                token,
                conversation,
                ChatMessageReadLane.HEAD,
                revision,
            ) { current ->
                if (current.chatMessages is Loadable.Loading) {
                    current.copy(chatMessages = Loadable.Failed(error.asDsmFailure()))
                } else {
                    current
                }
            }
            return
        }
        publishMessageState(
            source,
            token,
            conversation,
            ChatMessageReadLane.HEAD,
            revision,
        ) { current ->
            val existing = (current.chatMessages as? Loadable.Ready)?.value
            val page = reconcileChatMessagePage(
                metadataSource = existing ?: latest,
                lowerPriority = existing?.messages.orEmpty(),
                higherPriority = latest.messages,
                outgoing = current.chatOutgoingMessages[conversation.id].orEmpty(),
            )
            current.copy(chatMessages = Loadable.Ready(page))
        }
    }

    private fun publishConversations(
        source: ChatFeatureDataSource,
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
                            source,
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
        source: ChatFeatureDataSource,
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
                    if (!isTaskCurrent(source, taskToken)) break
                    val current = workspace.value
                    if (current?.selectedModule != Module.CHAT || current.selectedConversation != null
                    ) break
                    val revision = beginConversationRead(source, taskToken) ?: break
                    val result = suspendRunCatching { source.conversations() }
                    if (!isTaskCurrent(source, taskToken)) break
                    val conversations = result.getOrNull()
                    if (conversations != null) {
                        publishConversations(
                            source,
                            taskToken,
                            conversations,
                            revision,
                            requireConversationListActive = true,
                        )
                    } else {
                        result.exceptionOrNull()?.let { error ->
                            publishConversationFailureIfLoading(
                                source,
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
        source: ChatFeatureDataSource,
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
                    if (!isTaskCurrent(source, taskToken)) break
                    val current = workspace.value
                    if (current?.selectedModule != Module.CHAT ||
                        current.selectedConversation?.id != conversation.id
                    ) break
                    refreshLatestMessages(source, taskToken, conversation)
                }
            },
            onResult = { _, _ -> },
        )
    }

    private fun startRealtime(source: ChatFeatureDataSource, token: ChatFeatureToken) {
        synchronized(lifecycleLock) {
            if (realtimeClient != null) return
        }
        val client = source.realtimeConnection(
            onConnectionChanged = { connected ->
                jobOwner.launch(
                    scope = scope,
                    name = REALTIME_CONNECTION_JOB,
                    token = token,
                    block = { taskToken ->
                        if (!isTaskCurrent(source, taskToken)) return@launch connected
                        connected
                    },
                    onResult = { taskToken, currentConnected ->
                        if (!isTaskCurrent(source, taskToken)) return@launch
                        val connectionUpdated = synchronized(lifecycleLock) {
                            if (!isTaskCurrent(source, taskToken)) {
                                false
                            } else {
                                realtimeConnected = currentConnected
                                true
                            }
                        }
                        if (!connectionUpdated || !isTaskCurrent(source, taskToken)) return@launch
                        if (currentConnected) {
                            jobOwner.cancel(REFRESH_JOB, sourceToken = taskToken)
                        } else {
                            if (!isTaskCurrent(source, taskToken)) return@launch
                            val state = workspace.value
                            if (state?.selectedModule == Module.CHAT) {
                                state.selectedConversation?.let { conversation ->
                                    startMessagePolling(
                                        source,
                                        token,
                                        conversation,
                                        sourceToken = taskToken,
                                    )
                                } ?: startConversationPolling(
                                    source,
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
                        if (!isTaskCurrent(source, taskToken)) return@launch
                        val state = workspace.value
                        if (state?.selectedModule != Module.CHAT) return@launch
                        state.selectedConversation?.let { conversation ->
                            refreshLatestMessages(source, taskToken, conversation)
                        } ?: run {
                            val revision = beginConversationRead(source, taskToken) ?: return@launch
                            val result = suspendRunCatching { source.conversations() }
                            if (!isTaskCurrent(source, taskToken)) return@launch
                            val conversations = result.getOrNull()
                            if (conversations != null) {
                                publishConversations(
                                    source,
                                    taskToken,
                                    conversations,
                                    revision,
                                    requireConversationListActive = true,
                                )
                            } else {
                                result.exceptionOrNull()?.let { error ->
                                    publishConversationFailureIfLoading(
                                        source,
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
            if (isSessionCurrent(source, token) && realtimeClient == null) {
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
        val lane: ChatMessageReadLane,
        val revision: Long,
        val expectedOffset: Int?,
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
        const val REFRESH_JOB = "refresh"
        const val REALTIME_CONNECTION_JOB = "realtime-connection"
        const val REALTIME_REFRESH_JOB = "realtime-refresh"
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
