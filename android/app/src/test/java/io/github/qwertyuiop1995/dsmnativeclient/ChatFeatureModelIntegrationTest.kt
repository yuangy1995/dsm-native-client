package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatFeatureModelIntegrationTest {
    @Test
    fun `分页与实时 HEAD 并行时保留历史消息并由分页收回 loading`() = runTest {
        val fixture = Fixture(testScheduler)
        try {
            openReadyConversation(fixture)

            fixture.feature.loadOlderMessages()
            runCurrent()
            val pagination = fixture.source.request("conversation-a", 2)
            assertTrue(fixture.state().chatIsLoadingMore)

            fixture.source.realtime.fireContentChanged()
            advanceTimeBy(CHAT_REALTIME_COALESCE_MILLIS)
            runCurrent()
            val realtimeHead = fixture.source.request("conversation-a", 0, occurrence = 1)
            realtimeHead.response.complete(page(message("A", 1), message("B", 2), message("C", 3)))
            runCurrent()

            assertEquals(listOf("A", "B", "C"), fixture.messageIds())
            assertEquals(2, fixture.page().nextOffset)
            assertTrue(fixture.page().hasMore)
            assertTrue(fixture.state().chatIsLoadingMore)

            pagination.response.complete(page(message("older", 0), nextOffset = null, hasMore = false))
            runCurrent()

            assertEquals(listOf("older", "A", "B", "C"), fixture.messageIds())
            assertFalse(fixture.state().chatIsLoadingMore)
            assertEquals(null, fixture.page().nextOffset)
            assertFalse(fixture.page().hasMore)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `HEAD 失败不能提前清除执行中的分页 loading`() = runTest {
        val fixture = Fixture(testScheduler)
        try {
            openReadyConversation(fixture)
            fixture.feature.loadOlderMessages()
            runCurrent()
            val pagination = fixture.source.request("conversation-a", 2)

            fixture.source.realtime.fireContentChanged()
            advanceTimeBy(CHAT_REALTIME_COALESCE_MILLIS)
            runCurrent()
            val realtimeHead = fixture.source.request("conversation-a", 0, occurrence = 1)
            realtimeHead.response.completeExceptionally(IllegalStateException("head failed"))
            runCurrent()

            assertEquals(listOf("A", "B"), fixture.messageIds())
            assertTrue(fixture.state().chatIsLoadingMore)

            pagination.response.complete(page(message("older", 0), nextOffset = null, hasMore = false))
            runCurrent()

            assertEquals(listOf("older", "A", "B"), fixture.messageIds())
            assertFalse(fixture.state().chatIsLoadingMore)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `实时 HEAD 同 ID 更新会经 Feature 流程覆盖当前消息版本`() = runTest {
        val fixture = Fixture(testScheduler)
        try {
            fixture.feature.loadModule()
            runCurrent()
            fixture.feature.openConversation(fixture.conversationA)
            runCurrent()
            fixture.source.request("conversation-a", 0).response.complete(
                page(message("A", 1, body = "旧正文", isPinned = false), nextOffset = 2, hasMore = true),
            )
            runCurrent()

            fixture.source.realtime.fireContentChanged()
            advanceTimeBy(CHAT_REALTIME_COALESCE_MILLIS)
            runCurrent()
            fixture.source.request("conversation-a", 0, occurrence = 1).response.complete(
                page(message("A", 1, body = "服务端新正文", isPinned = true)),
            )
            runCurrent()

            val updated = fixture.page().messages.single()
            assertEquals("服务端新正文", updated.body)
            assertTrue(updated.isPinned)
            assertEquals(2, fixture.page().nextOffset)
            assertTrue(fixture.page().hasMore)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `分页完成时 offset 已改变不能重复发布或清理当前 loading`() = runTest {
        val fixture = Fixture(testScheduler)
        try {
            openReadyConversation(fixture)
            fixture.feature.loadOlderMessages()
            fixture.feature.loadOlderMessages()
            runCurrent()
            assertEquals(1, fixture.source.requestCount("conversation-a", 2))
            val oldPagination = fixture.source.request("conversation-a", 2)

            // 模拟同一分页分道的新所有者已经发布了下一页标记；旧请求只能静默退出。
            fixture.workspace.update { current ->
                current?.copy(
                    chatMessages = Loadable.Ready(
                        fixture.page().copy(nextOffset = 4, hasMore = true),
                    ),
                    chatIsLoadingMore = true,
                )
            }
            oldPagination.response.complete(page(message("older", 0), nextOffset = null, hasMore = false))
            runCurrent()

            assertEquals(listOf("A", "B"), fixture.messageIds())
            assertEquals(4, fixture.page().nextOffset)
            assertTrue(fixture.state().chatIsLoadingMore)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `切换会话后旧 HEAD 与 PAGINATION 均不能污染新会话`() = runTest {
        val fixture = Fixture(testScheduler)
        try {
            openReadyConversation(fixture)
            fixture.feature.loadOlderMessages()
            runCurrent()
            val oldPagination = fixture.source.request("conversation-a", 2)

            fixture.source.realtime.fireContentChanged()
            advanceTimeBy(CHAT_REALTIME_COALESCE_MILLIS)
            runCurrent()
            val oldHead = fixture.source.request("conversation-a", 0, occurrence = 1)

            fixture.feature.openConversation(fixture.conversationB)
            runCurrent()
            val newHead = fixture.source.request("conversation-b", 0)
            newHead.response.complete(page(message("B-current", 10, conversationId = "conversation-b")))
            runCurrent()

            oldHead.response.complete(page(message("A-late", 4)))
            oldPagination.response.complete(page(message("A-older", 0), nextOffset = null, hasMore = false))
            runCurrent()

            assertEquals("conversation-b", fixture.state().selectedConversation?.id)
            assertEquals(listOf("B-current"), fixture.messageIds())
            assertFalse(fixture.state().chatIsLoadingMore)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `切换资料后旧 HEAD 与 PAGINATION 都不能发布或清理新状态`() = runTest {
        val fixture = Fixture(testScheduler)
        try {
            openReadyConversation(fixture)
            fixture.feature.loadOlderMessages()
            runCurrent()
            val oldPagination = fixture.source.request("conversation-a", 2)

            fixture.source.realtime.fireContentChanged()
            advanceTimeBy(CHAT_REALTIME_COALESCE_MILLIS)
            runCurrent()
            val oldHead = fixture.source.request("conversation-a", 0, occurrence = 1)

            fixture.workspace.value = workspace("profile-b").copy(
                selectedConversation = fixture.conversationB,
                chatMessages = Loadable.Ready(
                    page(message("B-current", 10, conversationId = "conversation-b")),
                ),
                chatIsLoadingMore = false,
            )
            fixture.feature.clearForProfileSwitch()
            oldHead.response.complete(page(message("A-late", 4)))
            oldPagination.response.complete(page(message("A-older", 0), nextOffset = null, hasMore = false))
            runCurrent()

            assertEquals("profile-b", fixture.state().profile.id)
            assertEquals("conversation-b", fixture.state().selectedConversation?.id)
            assertEquals(listOf("B-current"), fixture.messageIds())
            assertFalse(fixture.state().chatIsLoadingMore)
        } finally {
            fixture.close()
        }
    }

    private fun TestScope.openReadyConversation(fixture: Fixture) {
        fixture.feature.loadModule()
        runCurrent()
        fixture.feature.openConversation(fixture.conversationA)
        runCurrent()
        fixture.source.request("conversation-a", 0).response.complete(
            page(message("A", 1), message("B", 2), nextOffset = 2, hasMore = true),
        )
        runCurrent()
    }

    private class Fixture(scheduler: kotlinx.coroutines.test.TestCoroutineScheduler) {
        private val dispatcher = StandardTestDispatcher(scheduler)
        private val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val conversationA = conversation("conversation-a")
        val conversationB = conversation("conversation-b")
        val source = FakeChatFeatureDataSource(listOf(conversationA, conversationB))
        val workspace = MutableStateFlow<WorkspaceState?>(workspace("profile-a"))
        val feature = ChatFeatureModel(
            scope = scope,
            workspace = workspace,
            repositoryProvider = { null },
            localizedFailure = { "读取失败" },
            sourceProvider = { source },
        )

        fun state(): WorkspaceState = checkNotNull(workspace.value)

        fun page(): ChatMessagePage = (state().chatMessages as Loadable.Ready).value

        fun messageIds(): List<String> = page().messages.map(ChatMessage::id)

        fun close() = scope.cancel()
    }

    private class FakeChatFeatureDataSource(
        private val availableConversations: List<ChatConversation>,
    ) : ChatFeatureDataSource {
        override val identity: Any = Any()
        private val requests = mutableListOf<MessageRequest>()
        lateinit var realtime: FakeRealtimeConnection
            private set

        override suspend fun conversations(): List<ChatConversation> = availableConversations

        override suspend fun messages(conversationId: String, offset: Int): ChatMessagePage {
            val request = MessageRequest(conversationId, offset)
            requests += request
            return request.response.await()
        }

        override fun realtimeConnection(
            onConnectionChanged: (Boolean) -> Unit,
            onContentChanged: () -> Unit,
        ): ChatFeatureRealtimeConnection = FakeRealtimeConnection(
            onConnectionChanged,
            onContentChanged,
        ).also { realtime = it }

        fun request(conversationId: String, offset: Int, occurrence: Int = 0): MessageRequest =
            requests.filter { it.conversationId == conversationId && it.offset == offset }[occurrence]

        fun requestCount(conversationId: String, offset: Int): Int =
            requests.count { it.conversationId == conversationId && it.offset == offset }
    }

    private class FakeRealtimeConnection(
        private val onConnectionChanged: (Boolean) -> Unit,
        private val onContentChanged: () -> Unit,
    ) : ChatFeatureRealtimeConnection {
        private var started = false

        override fun start(scope: CoroutineScope) {
            started = true
        }

        override fun stop() {
            onConnectionChanged(false)
        }

        fun fireContentChanged() {
            check(started)
            onContentChanged()
        }
    }

    private data class MessageRequest(
        val conversationId: String,
        val offset: Int,
        val response: CompletableDeferred<ChatMessagePage> = CompletableDeferred(),
    )

    private companion object {
        fun workspace(profileId: String): WorkspaceState = WorkspaceState(
            profile = NasProfile(profileId, "NAS", "https://example.invalid", "user"),
            selectedModule = Module.CHAT,
        )

        fun conversation(id: String): ChatConversation = ChatConversation(
            id = id,
            title = id,
            kind = ConversationKind.DIRECT,
        )

        fun message(
            id: String,
            time: Long,
            conversationId: String = "conversation-a",
            body: String = id,
            isPinned: Boolean = false,
        ): ChatMessage =
            ChatMessage(
                id = id,
                conversationId = conversationId,
                sender = ChatUser("user", "User", "user"),
                body = body,
                createdAtEpochSeconds = time,
                isMine = false,
                isPinned = isPinned,
            )

        fun page(
            vararg messages: ChatMessage,
            nextOffset: Int? = 2,
            hasMore: Boolean = true,
        ): ChatMessagePage = ChatMessagePage(messages.toList(), nextOffset, hasMore)
    }
}
