package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.reminders
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*

internal interface ChatNoticeSource {
    val identity: Any
    val owner: WorkspaceOwner
    suspend fun authorize()
    suspend fun conversations(): List<ChatConversation>
    suspend fun latest(channel: String): ChatMessage?
    suspend fun reminders(channel: String): List<ChatReminder>
}
internal class DsmChatNoticeSource(private val repo: DsmRepository) : ChatNoticeSource {
    override val identity: Any get() = repo
    override val owner get() = requireNotNull(repo.owner)
    override suspend fun authorize() {
        repo.requireCurrentOwner(); repo.refreshAccess(); repo.requireCurrentOwner()
        if (!repo.availability().allows(Module.CHAT)) throw workspaceChangedFailure()
    }
    override suspend fun conversations() = repo.chatConversations()
    override suspend fun latest(channel: String) = repo.chatMessages(channel, limit = 1).messages.maxByOrNull { it.createdAtEpochMillis }
    override suspend fun reminders(channel: String) = repo.chatRepository.reminders(channel)
}
internal data class ChatNoticeState(val enabled: Boolean = false, val allowed: Boolean = true,
    val changing: Boolean = false, val syncing: Boolean = false, val error: Int? = null)

/** 实时事件与一分钟补读串行合并；只有当前前台工作区领取新消息，不建立第二条实时连接。 */
internal class ChatNoticeModel(private val scope: CoroutineScope, private val store: ChatNoticeStore,
    private val profiles: SecureProfileStore, private val driver: ChatNoticeDriving,
    private val source: () -> ChatNoticeSource?, private val seen: (ChatMessage) -> Boolean,
    private val observe: (Boolean) -> Unit, private val now: () -> Long = System::currentTimeMillis,
    private val refreshMillis: Long = 60_000) {
    private val mutable = MutableStateFlow(ChatNoticeState(enabled = store.enabled()))
    val state = mutable.asStateFlow()
    @Volatile private var foreground = false
    @Volatile private var generation = 0L
    private var job: Job? = null
    private var settingsJob: Job? = null
    private val signals = Channel<Unit>(Channel.CONFLATED)
    private var activeScope: ChatNoticeScope? = null
    private var needsReminderSync = true
    fun changed() { needsReminderSync = true; contentChanged() }
    fun contentChanged() { signals.trySend(Unit) }
    fun connectionChanged() { if (foreground && !state.value.changing) start() }
    fun setEnabled(value: Boolean) {
        if (state.value.changing) return
        stop()
        mutable.update { it.copy(changing = true, error = null) }
        settingsJob = scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    if (value && !driver.allowed()) return@withContext
                    store.setEnabled(value)
                    if (!value) store.scopes().forEach { row -> store.remove(row); driver.remove(row) }
                }
                mutable.update { it.copy(enabled = store.enabled(), allowed = driver.allowed(), changing = false,
                    error = if (value && !driver.allowed()) R.string.chat_notices_denied else null) }
                start()
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                mutable.update { it.copy(changing = false, error = R.string.chat_notices_failed) }
            }
        }
    }
    fun foreground(value: Boolean) {
        synchronized(ChatNoticeStore.lock) { foreground = value }
        if (!value) stop() else if (!state.value.changing) {
            mutable.update { it.copy(enabled = store.enabled(), allowed = driver.allowed()) }
            start()
        }
    }
    fun revoke(profileId: String? = activeScope?.owner?.profileId ?: source()?.owner?.profileId) {
        stop()
        activeScope = null
        if (profileId != null) scope.launch(Dispatchers.IO + NonCancellable) {
            runCatching { store.scopes().filter { it.owner.profileId == profileId }.forEach { row -> store.remove(row); driver.remove(row) } }
        }
    }
    fun clear() { synchronized(ChatNoticeStore.lock) { foreground = false }; stop(); activeScope = null }
    private fun stop() { synchronized(ChatNoticeStore.lock) { generation++ }; job?.cancel(); job = null; observe(false); mutable.update { it.copy(syncing = false) } }
    private fun start() {
        if (job?.isActive == true || !foreground || !state.value.enabled || !state.value.allowed || state.value.changing) return
        val origin = source() ?: return
        val token = ++generation
        job = scope.launch {
            var baseline: Map<String, Long>? = null
            val startedAt = now() / 1000
            var lastReminderSync = 0L
            try {
                withContext(Dispatchers.IO) {
                    store.scopes().filter { runCatching { profiles.requireCurrentOwner(it.owner) }.isFailure }
                        .forEach { store.remove(it); driver.remove(it) }
                }
                while (isActive && current(origin, token)) {
                    mutable.update { it.copy(syncing = true) }
                    try {
                        val values = withContext(Dispatchers.IO) { origin.authorize(); origin.conversations() }
                        if (!current(origin, token)) break
                        observe(true)
                        val noticeScope = withContext(Dispatchers.IO) { store.scope(origin.owner) }
                        if (!current(origin, token)) break
                        activeScope = noticeScope
                        val previous = baseline
                        baseline = values.mapNotNull { row -> row.latestAtEpochSeconds?.let { row.id to it } }.toMap()
                        val syncReminders = previous == null || needsReminderSync || now() - lastReminderSync >= 60_000
                        if (syncReminders) { needsReminderSync = false; lastReminderSync = now() }
                        var reminderFailure = false
                        var limited = false
                        withContext(Dispatchers.IO) {
                            store.retainChannels(noticeScope, values.filterNot { it.isEncrypted }.map { it.id }.toSet())
                            for (conversation in values.filterNot { it.isEncrypted }) {
                                ensureCurrent(origin, token)
                                val after = previous?.get(conversation.id) ?: startedAt
                                if (previous != null && conversation.unreadCount > 0 && (conversation.latestAtEpochSeconds ?: 0) > after) {
                                    // 只读实际最新消息，不用预览文字或未读计数猜测发送者。
                                    try {
                                        val message = origin.latest(conversation.id)
                                        ensureCurrent(origin, token)
                                        if (message != null && message.conversationId == conversation.id && !message.isMine && !message.isEncrypted &&
                                            message.createdAtEpochSeconds > after && !seen(message)) {
                                            driver.route(noticeScope, conversation.id)?.let { route -> synchronized(ChatNoticeStore.lock) {
                                                if (current(origin, token) && !seen(message)) driver.incoming(noticeScope, route)
                                            } }
                                        }
                                    } catch (error: Exception) { if (error is CancellationException) throw error }
                                }
                                if (!syncReminders) continue
                                try {
                                    val reminders = origin.reminders(conversation.id)
                                    ensureCurrent(origin, token)
                                    val route = if (reminders.isEmpty()) store.reminders(noticeScope.id).firstOrNull { it.conversation == conversation.id }?.route
                                        else driver.route(noticeScope, conversation.id)
                                    if (route != null) store.sync(noticeScope, conversation.id, reminders, route, now())
                                } catch (error: Exception) { if (error is CancellationException) throw error; reminderFailure = true }
                            }
                            ensureCurrent(origin, token)
                            val reminders = store.reminders(noticeScope.id)
                            limited = reminders.count { !it.delivered } > 50
                            driver.reconcile(noticeScope, reminders)
                        }
                        if (current(origin, token)) mutable.update { it.copy(error = when {
                            reminderFailure || !syncReminders && it.error == R.string.chat_notices_sync_failed -> R.string.chat_notices_sync_failed
                            limited -> R.string.chat_notices_limit
                            else -> null
                        }) }
                    } catch (error: Exception) {
                        if (error is CancellationException) throw error
                        if (current(origin, token)) mutable.update { it.copy(error = R.string.chat_notices_sync_failed) }
                    } finally { if (token == generation) mutable.update { it.copy(syncing = false) } }
                    withTimeoutOrNull(refreshMillis) { signals.receive(); delay(350) }
                }
            } finally { if (token == generation) { observe(false); mutable.update { it.copy(syncing = false) } } }
        }
    }
    private fun current(origin: ChatNoticeSource, token: Long): Boolean = token == generation && foreground && store.enabled() &&
        source()?.identity === origin.identity && runCatching { profiles.requireCurrentOwner(origin.owner) }.isSuccess
    private fun ensureCurrent(origin: ChatNoticeSource, token: Long) { if (!current(origin, token)) throw CancellationException() }
}
