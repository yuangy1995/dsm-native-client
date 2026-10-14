package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class ChatContentModelTest {
    @get:Rule val temporary = TemporaryFolder()
    private val channel = ChatConversation("11", "Synthetic", ConversationKind.GROUP, unreadCount = 3)
    private val root = ChatMessage("71", "11", null, "root", 10, true)
    private val reply = ChatMessage("72", "11", null, "reply", 20, true, threadId = "71")
    private inner class Source : ChatContentSource {
        override val identity = Any()
        val searchCalls = mutableListOf<Triple<String, String?, Int>>()
        val reads = mutableListOf<String>(); val threadReads = mutableListOf<String>()
        var searchGate: CompletableDeferred<ChatSearchPage>? = null
        var failure = false; var editAllowed = true
        var threadFailure = false
        override suspend fun search(query: String, channelId: String?, offset: Int): ChatSearchPage {
            searchCalls += Triple(query, channelId, offset)
            return searchGate?.await() ?: ChatSearchPage(listOf(if (offset == 0) root else reply), if (offset == 0) 50 else null, 2)
        }
        override suspend fun message(channel: String, id: String, thread: String?): ChatMessage {
            if (threadFailure) error("Synthetic thread failure")
            return if (id == root.id) root else reply
        }
        override suspend fun replies(channel: String, root: String, before: String?) = ChatMessagePage(listOf(reply), null, false)
        override suspend fun pinned(channel: String) = listOf(root.copy(isPinned = true))
        override suspend fun editingPolicy() = ChatEditingPolicy(editAllowed, null)
        override suspend fun markRead(channel: String, id: String): ChatConversation {
            reads += id
            if (failure) error("Synthetic failure")
            return this@ChatContentModelTest.channel.copy(unreadCount = 2, lastViewedAtEpochMillis = root.createdAtEpochMillis)
        }
        override suspend fun markThreadRead(channel: String, root: String, id: String) { threadReads += id }
    }
    private inner class Fixture(val scope: TestScope) {
        val source = Source(); var active: ChatContentSource? = source
        val workspace = MutableStateFlow<WorkspaceState?>(WorkspaceState(NasProfile("test", "NAS", "https://example.invalid", "user"), selectedModule = Module.CHAT,
            selectedConversation = channel, conversations = Loadable.Ready(listOf(channel)), chatMessages = Loadable.Ready(ChatMessagePage(listOf(root), "older", true))))
        val actions = ChatActionModel(scope, workspace, { null }, { ChatActionStore(MemoryPreferences()) },
            { ChatDraftStore(MemoryPreferences(), temporary.newFolder()) }, {}, {}, StandardTestDispatcher(scope.testScheduler))
        val model = ChatContentModel(scope, workspace, { active }, actions)
    }
    @Test fun `搜索范围与offset独立于主历史游标`() = runTest {
        val f = Fixture(this); f.model.openSearch("11"); f.model.updateQuery("hello"); f.model.search(); advanceUntilIdle()
        f.model.search(more = true); advanceUntilIdle()
        assertEquals(listOf(Triple("hello", "11", 0), Triple("hello", "11", 50)), f.source.searchCalls)
        assertEquals(listOf("71", "72"), (f.model.state.value.search as Loadable.Ready).value.messages.map { it.id })
        assertEquals("older", (f.workspace.value!!.chatMessages as Loadable.Ready).value.previousCursor)
    }
    @Test fun `改词清除旧搜索并拒绝迟到结果`() = runTest {
        val f = Fixture(this); f.source.searchGate = CompletableDeferred()
        f.model.openSearch(); f.model.updateQuery("old"); f.model.search(); runCurrent()
        f.model.updateQuery("new"); f.source.searchGate!!.complete(ChatSearchPage(listOf(root), null, 1)); advanceUntilIdle()
        assertEquals("new", f.model.state.value.query); assertEquals(Loadable.Idle, f.model.state.value.search)
    }
    @Test fun `换账号不发布旧搜索结果`() = runTest {
        val f = Fixture(this); f.source.searchGate = CompletableDeferred()
        f.model.openSearch(); f.model.updateQuery("query"); f.model.search(); runCurrent(); f.active = null; f.model.clear()
        f.source.searchGate!!.complete(ChatSearchPage(listOf(root), null, 1)); advanceUntilIdle()
        assertNull(f.model.state.value.panel)
    }
    @Test fun `线程从回复定位原根且不重置主历史`() = runTest {
        val f = Fixture(this); f.model.openThread(reply); advanceUntilIdle()
        val thread = (f.model.state.value.thread as Loadable.Ready).value
        assertEquals("71", thread.root.id); assertEquals(listOf("72"), thread.replies.messages.map { it.id })
        assertEquals(listOf(root), (f.workspace.value!!.chatMessages as Loadable.Ready).value.messages)
    }
    @Test fun `未在前台和不在可见历史的消息均不推进已读`() = runTest {
        val f = Fixture(this); f.model.markVisible(root); advanceUntilIdle(); assertTrue(f.source.reads.isEmpty())
        f.model.setVisible(true); f.model.markVisible(reply); advanceUntilIdle(); assertTrue(f.source.reads.isEmpty())
        f.model.markVisible(root); advanceUntilIdle(); assertEquals(listOf("71"), f.source.reads)
        assertEquals(2, f.workspace.value!!.selectedConversation!!.unreadCount)
    }
    @Test fun `线程失败重试重新读取原线程并保留主历史`() = runTest {
        val f = Fixture(this); f.source.threadFailure = true
        f.model.openThread(reply); advanceUntilIdle(); assertTrue(f.model.state.value.thread is Loadable.Failed)
        f.source.threadFailure = false; f.model.retryThread(); advanceUntilIdle()
        assertEquals("71", (f.model.state.value.thread as Loadable.Ready).value.root.id)
        assertEquals(ChatContentPanel.THREAD, f.model.state.value.panel)
        assertEquals("older", (f.workspace.value!!.chatMessages as Loadable.Ready).value.previousCursor)
    }
    @Test fun `已读失败保留未读数重复可见可重试`() = runTest {
        val f = Fixture(this); f.source.failure = true; f.model.setVisible(true); f.model.markVisible(root); advanceUntilIdle()
        assertEquals(3, f.workspace.value!!.selectedConversation!!.unreadCount)
        f.source.failure = false; f.model.markVisible(root); advanceUntilIdle()
        assertEquals(2, f.source.reads.size); assertEquals(2, f.workspace.value!!.selectedConversation!!.unreadCount)
    }
    @Test fun `已同步的位置不重复提交且搜索弹层不推进主页已读`() = runTest {
        val f = Fixture(this); f.model.setVisible(true); f.model.markVisible(root); advanceUntilIdle()
        f.model.markVisible(root); advanceUntilIdle(); assertEquals(1, f.source.reads.size)
        f.model.openSearch(); f.model.markVisible(root.copy(id = "73", createdAtEpochSeconds = 30)); advanceUntilIdle()
        assertEquals(1, f.source.reads.size)
    }
    @Test fun `线程只同步实际可见回复且不能把根当作回复`() = runTest {
        val f = Fixture(this); f.model.setVisible(true); f.model.openThread(reply); advanceUntilIdle()
        f.model.markVisible(root, thread = true); advanceUntilIdle(); assertTrue(f.source.threadReads.isEmpty())
        f.model.markVisible(reply, thread = true); advanceUntilIdle(); assertEquals(listOf("72"), f.source.threadReads)
        assertTrue(f.source.reads.isEmpty())
    }
    @Test fun `编辑先读取服务端策略禁用时保留明确错误`() = runTest {
        val f = Fixture(this); f.source.editAllowed = false
        f.model.edit(root); advanceUntilIdle()
        assertTrue(f.model.state.value.editing is Loadable.Failed)
        assertEquals("", f.model.state.value.editText)
    }
    @Test fun `公告读取独立且关闭后不改变主历史`() = runTest {
        val f = Fixture(this); f.model.openPinned("11"); advanceUntilIdle()
        assertEquals(listOf("71"), (f.model.state.value.pinned as Loadable.Ready).value.map { it.id })
        f.model.close(); assertNull(f.model.state.value.panel)
        assertEquals("older", (f.workspace.value!!.chatMessages as Loadable.Ready).value.previousCursor)
    }
}
