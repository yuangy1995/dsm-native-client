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
            block = { captureLoadable { repository.chatConversations() } },
            onResult = { value ->
                if (!isSessionCurrent(repository, token)) return@launch
                if (value is Loadable.Ready) {
                    publishConversations(repository, token, value.value, requireConversationListActive = false)
                } else {
                    workspace.update { current ->
                        current?.takeIf { isSessionCurrent(repository, token) }
                            ?.copy(conversations = value) ?: current
                    }
                }
            },
        )
        startConversationPolling(repository, token)
    }

    fun openConversation(conversation: ChatConversation) {
        val repository = repositoryProvider() ?: return
        val token = ensureSession(repository) ?: return
        jobOwner.cancel(REFRESH_JOB)
        val canonicalConversation = (workspace.value?.conversations as? Loadable.Ready)
            ?.value
            ?.firstOrNull { it.id == conversation.id }
            ?: conversation
        synchronized(lifecycleLock) {
            val marker = canonicalConversation.toChatLocalReadMarker()
            localReadMarkers = if (marker == null) {
                localReadMarkers - canonicalConversation.id
            } else {
                localReadMarkers + (canonicalConversation.id to marker)
            }
        }
        workspace.update { state ->
            state?.takeIf { isSessionCurrent(repository, token) }?.let { current ->
                val conversations = (current.conversations as? Loadable.Ready)?.value
                current.copy(
                    selectedConversation = canonicalConversation.copy(unreadCount = 0),
                    chatMessages = Loadable.Loading,
                    chatIsLoadingMore = false,
                    conversations = conversations?.map { item ->
                        if (item.id == conversation.id) item.copy(unreadCount = 0) else item
                    }?.let { Loadable.Ready(it) } ?: current.conversations,
                )
            } ?: state
        }
        loadMessages(repository, token, canonicalConversation, reset = true)
        if (!isRealtimeConnected()) startMessagePolling(repository, token, canonicalConversation)
    }

    fun closeConversation() {
        val repository = repositoryProvider()
        jobOwner.cancel(REFRESH_JOB)
        workspace.update { current ->
            current?.copy(
                selectedConversation = null,
                chatMessages = Loadable.Idle,
                chatIsLoadingMore = false,
            )
        }
        if (repository == null) return
        val token = ensureSession(repository) ?: return
        jobOwner.launch(
            scope = scope,
            name = CONVERSATION_LOAD_JOB,
            token = token,
            block = { suspendRunCatching { repository.chatConversations() }.getOrNull() },
            onResult = { conversations ->
                if (!isSessionCurrent(repository, token)) return@launch
                conversations?.let {
                    publishConversations(repository, token, it, requireConversationListActive = false)
                }
                if (!isRealtimeConnected()) startConversationPolling(repository, token)
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
            localReadMarkers = emptyMap()
        }
    }

    fun stopForModuleExit() {
        // 离开 Chat 只终止当前读取/实时会话；本地已读叠加属于当前资料的 UI 状态，返回 Chat
        // 后仍需保留。递增代次可拒绝已停止客户端的迟到回调。
        jobOwner.invalidate(clearProfile = false)
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
            clearLocalReadMarkers()
        }
        return session.token
    }

    private fun isSessionCurrent(repository: DsmRepository, token: ChatFeatureToken): Boolean =
        jobOwner.isCurrent(token) && repositoryProvider() === repository &&
            workspace.value?.profile?.id == token.profileId

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
            block = {
                val currentPage = (workspace.value?.chatMessages as? Loadable.Ready)?.value
                val offset = if (reset) 0 else currentPage?.nextOffset
                if (!reset && offset == null) {
                    null
                } else {
                    if (!reset) workspace.update { it?.copy(chatIsLoadingMore = true) }
                    ChatMessageLoadOutcome(
                        reset = reset,
                        currentPage = currentPage,
                        result = suspendRunCatching {
                            repository.chatMessages(conversation.id, checkNotNull(offset))
                        },
                    )
                }
            },
            onResult = { outcome ->
                if (outcome == null || !isSessionCurrent(repository, token)) return@launch
                val page = outcome.result.getOrNull()
                if (page != null) {
                    workspace.update { current ->
                        if (current?.selectedConversation?.id != conversation.id) return@update current
                        val merged = if (outcome.reset || outcome.currentPage == null) {
                            page.copy(
                                messages = (page.messages +
                                    current.chatOutgoingMessages[conversation.id].orEmpty())
                                    .distinctBy(ChatMessage::id)
                                    .sortedBy(ChatMessage::createdAtEpochSeconds),
                            )
                        } else {
                            page.copy(
                                messages = (page.messages + outcome.currentPage.messages)
                                    .distinctBy(ChatMessage::id)
                                    .sortedBy(ChatMessage::createdAtEpochSeconds),
                            )
                        }
                        current.copy(chatMessages = Loadable.Ready(merged), chatIsLoadingMore = false)
                    }
                    return@launch
                }
                val error = outcome.result.exceptionOrNull() ?: return@launch
                workspace.update { current ->
                    if (current?.selectedConversation?.id != conversation.id) return@update current
                    if (outcome.reset) {
                        current.copy(chatMessages = Loadable.Failed(error.asDsmFailure()))
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
        token: ChatFeatureToken,
        conversation: ChatConversation,
    ) {
        if (!isSessionCurrent(repository, token)) return
        val latest = suspendRunCatching { repository.chatMessages(conversation.id, 0) }.getOrNull() ?: return
        if (!isSessionCurrent(repository, token)) return
        workspace.update { current ->
            if (current?.selectedConversation?.id != conversation.id) return@update current
            val existing = (current.chatMessages as? Loadable.Ready)?.value ?: return@update current
            current.copy(
                chatMessages = Loadable.Ready(
                    existing.copy(
                        messages = (existing.messages + latest.messages)
                            .distinctBy(ChatMessage::id)
                            .sortedBy(ChatMessage::createdAtEpochSeconds),
                    ),
                ),
            )
        }
    }

    private fun publishConversations(
        repository: DsmRepository,
        token: ChatFeatureToken,
        conversations: List<ChatConversation>,
        requireConversationListActive: Boolean,
    ) {
        if (!isSessionCurrent(repository, token)) return
        workspace.update { state ->
            if (state == null || !isSessionCurrent(repository, token) ||
                requireConversationListActive &&
                (state.selectedModule != Module.CHAT || state.selectedConversation != null)
            ) return@update state
            val overlay = synchronized(lifecycleLock) {
                applyChatLocalReadOverlay(conversations, localReadMarkers).also {
                    localReadMarkers = it.markers
                }
            }
            val visible = applyChatConversationPreferences(
                overlay.conversations,
                state.chatPinnedConversationIds,
            )
            state.withRefreshedChatConversations(visible)
        }
    }

    private fun startConversationPolling(repository: DsmRepository, token: ChatFeatureToken) {
        jobOwner.launch(
            scope = scope,
            name = REFRESH_JOB,
            token = token,
            block = {
                while (currentCoroutineContext().isActive) {
                    delay(CHAT_REFRESH_INTERVAL_MILLIS)
                    val current = workspace.value
                    if (!isSessionCurrent(repository, token) ||
                        current?.selectedModule != Module.CHAT || current.selectedConversation != null
                    ) break
                    suspendRunCatching { repository.chatConversations() }.getOrNull()?.let { conversations ->
                        publishConversations(
                            repository,
                            token,
                            conversations,
                            requireConversationListActive = true,
                        )
                    }
                }
            },
            onResult = {},
        )
    }

    private fun startMessagePolling(
        repository: DsmRepository,
        token: ChatFeatureToken,
        conversation: ChatConversation,
    ) {
        jobOwner.launch(
            scope = scope,
            name = REFRESH_JOB,
            token = token,
            block = {
                while (currentCoroutineContext().isActive) {
                    delay(CHAT_REFRESH_INTERVAL_MILLIS)
                    val current = workspace.value
                    if (!isSessionCurrent(repository, token) ||
                        current?.selectedModule != Module.CHAT ||
                        current.selectedConversation?.id != conversation.id
                    ) break
                    refreshLatestMessages(repository, token, conversation)
                }
            },
            onResult = {},
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
                    block = { connected },
                    onResult = { currentConnected ->
                        if (!isSessionCurrent(repository, token)) return@launch
                        synchronized(lifecycleLock) { realtimeConnected = currentConnected }
                        if (currentConnected) {
                            jobOwner.cancel(REFRESH_JOB)
                        } else {
                            val state = workspace.value
                            if (state?.selectedModule == Module.CHAT) {
                                state.selectedConversation?.let { conversation ->
                                    startMessagePolling(repository, token, conversation)
                                } ?: startConversationPolling(repository, token)
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
                    block = {
                        delay(CHAT_REALTIME_COALESCE_MILLIS)
                        if (!isSessionCurrent(repository, token)) return@launch
                        val state = workspace.value
                        if (state?.selectedModule != Module.CHAT) return@launch
                        state.selectedConversation?.let { conversation ->
                            refreshLatestMessages(repository, token, conversation)
                        } ?: suspendRunCatching { repository.chatConversations() }
                            .getOrNull()
                            ?.let { conversations ->
                                publishConversations(
                                    repository,
                                    token,
                                    conversations,
                                    requireConversationListActive = true,
                                )
                            }
                    },
                    onResult = {},
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
        val currentPage: ChatMessagePage?,
        val result: Result<ChatMessagePage>,
    )

    private companion object {
        const val CONVERSATION_LOAD_JOB = "conversation-load"
        const val MESSAGE_LOAD_JOB = "message-load"
        const val REFRESH_JOB = "refresh"
        const val REALTIME_CONNECTION_JOB = "realtime-connection"
        const val REALTIME_REFRESH_JOB = "realtime-refresh"
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

/** Chat 特性内所有读取 Job 的唯一所有者，拒绝过期资料的迟到发布。 */
internal class ChatFeatureJobOwner {
    private val lock = Any()
    private val generation = AtomicLong(0)
    private var activeProfileId: String? = null
    private val jobs = mutableMapOf<String, Job>()

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
            jobs.values.toList().also { jobs.clear() }
        }
        jobsToCancel.forEach(Job::cancel)
    }

    fun isCurrent(token: ChatFeatureToken): Boolean = synchronized(lock) {
        activeProfileId == token.profileId && generation.get() == token.generation
    }

    fun cancel(name: String) {
        val job = synchronized(lock) { jobs.remove(name) }
        job?.cancel()
    }

    fun <T> launch(
        scope: CoroutineScope,
        name: String,
        token: ChatFeatureToken,
        block: suspend () -> T,
        onResult: (T) -> Unit,
    ): Job? {
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val value = block()
            if (isCurrent(token)) onResult(value)
        }
        val previous = synchronized(lock) {
            if (!isCurrent(token)) return@synchronized null
            jobs.put(name, job)
        }
        if (!isCurrent(token)) {
            synchronized(lock) {
                if (jobs[name] === job) jobs.remove(name)
            }
            job.cancel()
            return null
        }
        previous?.cancel()
        job.invokeOnCompletion {
            synchronized(lock) {
                if (jobs[name] === job) jobs.remove(name)
            }
        }
        job.start()
        return job
    }
}
