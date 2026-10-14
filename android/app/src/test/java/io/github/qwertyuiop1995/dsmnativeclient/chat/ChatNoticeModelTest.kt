package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import java.util.Collections

class ChatNoticeModelTest {
    private val profiles = SecureProfileStore(MemoryPreferences())
    private val store = ChatNoticeStore(MemoryPreferences())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val profile = NasProfile("synthetic-notices", "Synthetic", "https://synthetic.invalid", "test")
    private val session = DsmSession(profile.id, "synthetic-session")
    private lateinit var origin: Source
    private var current: Source? = null
    private var seen = false
    private var clock = 100_000L
    private var observing = false
    private lateinit var model: ChatNoticeModel
    private val driver = Driver()
    private val c = ChatConversation("channel", "Synthetic chat", ConversationKind.GROUP, unreadCount = 1, latestAtEpochSeconds = 90)
    @Before fun prepare() {
        val owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false, persistSession = true)
        origin = Source(owner); current = origin
        model = ChatNoticeModel(scope, store, profiles, driver, { current }, { seen }, { observing = it }, { clock })
    }
    @After fun close() { model.clear(); scope.cancel() }
    private suspend fun waitFor(test: () -> Boolean) { withTimeout(5_000) { while (!test()) delay(5) } }
    private suspend fun enabled() {
        origin.values = listOf(c); model.foreground(true); model.setEnabled(true)
        waitFor { origin.reminderCalls > 0 && !model.state.value.syncing && !model.state.value.changing }
    }
    private suspend fun refresh() {
        val before = origin.calls; model.changed(); waitFor { origin.calls > before && !model.state.value.syncing }
    }
    private fun newer(id: String = "message", at: Long = 101, mine: Boolean = false, encrypted: Boolean = false): ChatMessage {
        origin.values = listOf(c.copy(latestAtEpochSeconds = at))
        return ChatMessage(id, c.id, null, "Not stored or displayed", at, mine, isEncrypted = encrypted).also { origin.message = it }
    }
    @Test fun `默认关闭启用先建基线旧未读不显示实时后新消息才提醒`() = runBlocking {
        assertFalse(store.enabled()); model.foreground(true); delay(20); assertEquals(0, origin.calls)
        enabled(); assertTrue(observing); assertTrue(driver.incoming.isEmpty())
        newer(); refresh(); assertEquals(1, driver.incoming.size)
        refresh(); assertEquals(1, driver.incoming.size)
        val route = profiles.opaqueWorkspaceRoute(driver.incoming.single().second)!!
        assertEquals(OpaqueWorkspaceTarget.ChatConversation(c.id), route.target); assertEquals(profile.id, route.profileId)
    }
    @Test fun `本人加密可见以及错误会话消息不通知`() = runBlocking {
        enabled(); newer(mine = true); refresh(); assertTrue(driver.incoming.isEmpty())
        newer(at = 102, encrypted = true); refresh(); assertTrue(driver.incoming.isEmpty())
        seen = true; newer(at = 103); refresh(); assertTrue(driver.incoming.isEmpty())
        seen = false; origin.message = newer(at = 104).copy(conversationId = "another"); refresh(); assertTrue(driver.incoming.isEmpty())
        origin.values = listOf(c.copy(isEncrypted = true, latestAtEpochSeconds = 105)); refresh(); assertTrue(driver.incoming.isEmpty())
    }
    @Test fun `后台和恢复只重建基线不补发离开期间消息`() = runBlocking {
        enabled(); model.foreground(false); assertFalse(observing); val reads = origin.calls
        newer(); model.changed(); delay(40); assertEquals(reads, origin.calls)
        model.foreground(true); waitFor { origin.calls > reads && !model.state.value.syncing }; assertTrue(driver.incoming.isEmpty())
        newer(at = 102); refresh(); assertEquals(1, driver.incoming.size)
    }
    @Test fun `迟到消息遇到退出或换仓储不得显示且不得串账号`() = runBlocking {
        enabled(); newer(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        origin.latestHook = { entered.complete(Unit); withContext(NonCancellable) { release.await() } }
        model.changed(); entered.await(); model.foreground(false); profiles.signOut(origin.owner); release.complete(Unit)
        delay(40); assertTrue(driver.incoming.isEmpty()); assertFalse(observing)
    }
    @Test fun `拒绝系统通知不启用也不启动网络和实时连接`() = runBlocking {
        driver.permitted = false; model.foreground(true); model.setEnabled(true)
        waitFor { !model.state.value.changing }; assertFalse(store.enabled()); assertEquals(R.string.chat_notices_denied, model.state.value.error)
        assertEquals(0, origin.calls); assertFalse(observing)
    }
    @Test fun `提醒建立改期删除和显式关闭沿相同本机记录收口`() = runBlocking {
        origin.reminderValues = listOf(ChatReminder("r", "m", 200_000))
        enabled(); val row = store.reminders().single(); assertEquals(200_000, row.reminder.remindAtEpochMillis)
        origin.reminderValues = listOf(ChatReminder("r", "m", 300_000)); refresh()
        val changed = store.reminders().single(); assertNotEquals(row.id, changed.id); assertNull(store.reminder(row.id))
        origin.reminderValues = emptyList(); refresh(); assertTrue(store.reminders().isEmpty())
        origin.reminderValues = listOf(ChatReminder("r", "m", 400_000)); refresh()
        model.setEnabled(false); waitFor { !model.state.value.changing }; assertFalse(store.enabled())
        assertTrue(store.reminders().isEmpty()); assertTrue(store.scopes().isEmpty()); assertFalse(observing)
    }
    @Test fun `提醒读取失败保留已同步计划而完整空列表才删除`() = runBlocking {
        origin.reminderValues = listOf(ChatReminder("r", "m", 200_000)); enabled()
        val row = store.reminders().single(); origin.failReminders = true; refresh()
        assertEquals(row, store.reminders().single()); assertEquals(R.string.chat_notices_sync_failed, model.state.value.error)
        val calls = origin.calls; model.contentChanged(); waitFor { origin.calls > calls && !model.state.value.syncing }
        assertEquals(R.string.chat_notices_sync_failed, model.state.value.error)
        origin.failReminders = false; origin.values = emptyList(); refresh(); assertTrue(store.reminders().isEmpty())
    }
    @Test fun `实时消息事件不反复全量读取提醒而显式提醒操作会刷新`() = runBlocking {
        enabled(); val before = origin.reminderCalls; newer(); model.contentChanged()
        waitFor { driver.incoming.isNotEmpty() && !model.state.value.syncing }; assertEquals(before, origin.reminderCalls)
        refresh(); assertEquals(before + 1, origin.reminderCalls)
    }
    @Test fun `Chat撤权立即停止后续读取并清理原账号提醒`() = runBlocking {
        origin.reminderValues = listOf(ChatReminder("r", "m", 200_000)); enabled()
        model.revoke(profile.id); current = null
        waitFor { store.scopes().isEmpty() }; assertFalse(observing); assertTrue(store.reminders().isEmpty())
    }
    @Test fun `超过系统安排数量显示实际限制且仍保留已确认记录`() = runBlocking {
        origin.reminderValues = (1..51).map { ChatReminder("r$it", "m$it", 200_000L + it) }
        enabled(); assertEquals(51, store.reminders().size); assertEquals(R.string.chat_notices_limit, model.state.value.error)
    }
    private inner class Source(override val owner: WorkspaceOwner) : ChatNoticeSource {
        override val identity: Any get() = this
        @Volatile var calls = 0
        @Volatile var reminderCalls = 0
        var values = emptyList<ChatConversation>()
        var message: ChatMessage? = null
        var reminderValues = emptyList<ChatReminder>()
        var failReminders = false
        var latestHook: suspend () -> Unit = {}
        override suspend fun authorize() { profiles.requireCurrentOwner(owner) }
        override suspend fun conversations(): List<ChatConversation> { calls++; return values }
        override suspend fun latest(channel: String): ChatMessage? { latestHook(); return message }
        override suspend fun reminders(channel: String): List<ChatReminder> { reminderCalls++; if (failReminders) error("synthetic failure"); return reminderValues }
    }
    private inner class Driver : ChatNoticeDriving {
        var permitted = true
        val incoming = Collections.synchronizedList(mutableListOf<Pair<ChatNoticeScope, String>>())
        override fun allowed() = permitted
        override fun route(scope: ChatNoticeScope, conversation: String) = profiles.issueOpaqueWorkspaceTarget(scope.owner.profileId, OpaqueWorkspaceTarget.ChatConversation(conversation), scope.owner)
        override fun incoming(scope: ChatNoticeScope, route: String) { incoming += scope to route }
        override fun reconcile(scope: ChatNoticeScope, reminders: List<ChatLocalReminder>) {}
        override fun remove(scope: ChatNoticeScope) {}
    }
}
