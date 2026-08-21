package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatDeliveryState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatPoll
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatPollOption
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatMessageReadPolicyTest {
    @Test
    fun `HEAD 与 PAGINATION 仅废弃各自同会话旧代次`() {
        val revisions = ChatReadResourceRevisions()
        val firstHead = revisions.beginMessageRead("conversation-a", ChatMessageReadLane.HEAD)
        val pagination = revisions.beginMessageRead("conversation-a", ChatMessageReadLane.PAGINATION)
        val latestHead = revisions.beginMessageRead("conversation-a", ChatMessageReadLane.HEAD)

        assertFalse(revisions.isCurrentMessageRead("conversation-a", ChatMessageReadLane.HEAD, firstHead))
        assertTrue(revisions.isCurrentMessageRead("conversation-a", ChatMessageReadLane.HEAD, latestHead))
        assertTrue(revisions.isCurrentMessageRead("conversation-a", ChatMessageReadLane.PAGINATION, pagination))

        revisions.invalidateMessageReads()
        assertFalse(revisions.isCurrentMessageRead("conversation-a", ChatMessageReadLane.HEAD, latestHead))
        assertFalse(revisions.isCurrentMessageRead("conversation-a", ChatMessageReadLane.PAGINATION, pagination))
    }

    @Test
    fun `HEAD 最新服务端对象覆盖相同 ID 的置顶和投票字段且保留分页元数据`() {
        val existing = message(
            id = "message-x",
            time = 1,
            isPinned = false,
            pollVotes = 3,
        )
        val latest = existing.copy(
            isPinned = true,
            poll = checkNotNull(existing.poll).copy(
                options = listOf(ChatPollOption("option", "A", voteCount = 4)),
            ),
        )
        val result = reconcileChatMessagePage(
            metadataSource = page(existing, nextOffset = 50, hasMore = true),
            lowerPriority = listOf(existing),
            higherPriority = listOf(latest),
            outgoing = emptyList(),
        )

        val message = result.messages.single()
        assertTrue(message.isPinned)
        assertEquals(4, message.poll?.options?.single()?.voteCount)
        assertEquals(50, result.nextOffset)
        assertTrue(result.hasMore)
    }

    @Test
    fun `PAGINATION 边界重叠保留当前可见版本并采用历史分页元数据`() {
        val historical = message("message-x", 1, isPinned = false, pollVotes = 3)
        val visible = historical.copy(
            isPinned = true,
            poll = checkNotNull(historical.poll).copy(
                options = listOf(ChatPollOption("option", "A", voteCount = 4)),
            ),
        )
        val result = reconcileChatMessagePage(
            metadataSource = page(historical, nextOffset = null, hasMore = false),
            lowerPriority = listOf(historical),
            higherPriority = listOf(visible),
            outgoing = emptyList(),
        )

        val message = result.messages.single()
        assertTrue(message.isPinned)
        assertEquals(4, message.poll?.options?.single()?.voteCount)
        assertNull(result.nextOffset)
        assertFalse(result.hasMore)
    }

    @Test
    fun `服务端同 ID 确认对象获胜且只保留本地请求关联`() {
        val server = message(
            id = "message-x",
            time = 2,
            body = "来自服务端",
            isPinned = true,
            attachments = listOf(ChatAttachment("server-file", "server.jpg", "image/jpeg", 42)),
            pollVotes = 4,
        )
        val local = message(
            id = "message-x",
            time = 1,
            body = "本地旧正文",
            isPinned = false,
            attachments = listOf(ChatAttachment("local-file", "local.jpg", "image/jpeg", 1)),
            pollVotes = 1,
            clientRequestId = "request-x",
            deliveryState = ChatDeliveryState.SENDING,
            attachmentProgress = 0.5f,
        )
        val result = reconcileChatMessagePage(
            metadataSource = page(server),
            lowerPriority = emptyList(),
            higherPriority = listOf(server),
            outgoing = listOf(local),
        ).messages.single()

        assertEquals("来自服务端", result.body)
        assertTrue(result.isPinned)
        assertEquals("server-file", result.attachments.single().id)
        assertEquals(4, result.poll?.options?.single()?.voteCount)
        assertEquals(ChatDeliveryState.SENT, result.deliveryState)
        assertNull(result.attachmentProgress)
        assertEquals("request-x", result.clientRequestId)
    }

    @Test
    fun `同 clientRequestId 的服务端确认会移除临时重复消息`() {
        val confirmed = message("server-message", 2, clientRequestId = "request-x")
        val temporary = message(
            id = "local:request-x",
            time = 1,
            clientRequestId = "request-x",
            deliveryState = ChatDeliveryState.SENDING,
            attachmentProgress = 0.4f,
        )
        val result = reconcileChatMessagePage(
            metadataSource = page(confirmed),
            lowerPriority = emptyList(),
            higherPriority = listOf(confirmed),
            outgoing = listOf(temporary),
        )

        assertEquals(listOf("server-message"), result.messages.map(ChatMessage::id))
    }

    @Test
    fun `未对账的本地 SENDING 与 FAILED 消息保留最新状态和附件进度`() {
        val sending = message(
            id = "local:sending",
            time = 1,
            clientRequestId = "request-sending",
            deliveryState = ChatDeliveryState.SENDING,
            attachmentProgress = 0.75f,
        )
        val failed = message(
            id = "local:failed",
            time = 2,
            clientRequestId = "request-failed",
            deliveryState = ChatDeliveryState.FAILED,
            attachmentProgress = 0.25f,
        )
        val result = reconcileChatMessagePage(
            metadataSource = page(),
            lowerPriority = emptyList(),
            higherPriority = emptyList(),
            outgoing = listOf(
                sending.copy(attachmentProgress = 0.1f),
                sending,
                failed,
            ),
        ).messages.associateBy(ChatMessage::id)

        assertEquals(ChatDeliveryState.SENDING, result.getValue(sending.id).deliveryState)
        assertEquals(0.75f, result.getValue(sending.id).attachmentProgress)
        assertEquals(ChatDeliveryState.FAILED, result.getValue(failed.id).deliveryState)
        assertEquals(0.25f, result.getValue(failed.id).attachmentProgress)
    }

    @Test
    fun `无重叠的最新 HEAD 使用服务端新分页边界以桥接缺口`() {
        val existing = page(message("old", 1), nextOffset = null, hasMore = false)
        val latest = page(message("latest", 100), nextOffset = 50, hasMore = true)

        val result = reconcileHeadPage(
            existing = existing,
            latest = latest,
            outgoing = emptyList(),
        )

        assertEquals(listOf("old", "latest"), result.messages.map(ChatMessage::id))
        assertEquals(50, result.nextOffset)
        assertTrue(result.hasMore)
    }

    @Test
    fun `完整最新 HEAD 删除缺失的已确认消息但保留未确认 outgoing`() {
        val oldConfirmed = message("old-confirmed", 1)
        val pending = message(
            id = "local:pending",
            time = 2,
            deliveryState = ChatDeliveryState.SENDING,
            clientRequestId = "pending-request",
        )
        val failed = message(
            id = "local:failed",
            time = 3,
            deliveryState = ChatDeliveryState.FAILED,
            clientRequestId = "failed-request",
        )
        val latest = message("latest-confirmed", 4)

        val result = reconcileHeadPage(
            existing = page(oldConfirmed, nextOffset = 50, hasMore = true),
            latest = page(latest, nextOffset = null, hasMore = false),
            outgoing = listOf(pending, failed),
        )

        assertEquals(
            listOf("local:pending", "local:failed", "latest-confirmed"),
            result.messages.map(ChatMessage::id),
        )
        assertNull(result.nextOffset)
        assertFalse(result.hasMore)
    }

    @Test
    fun `完整最新 HEAD 仍以服务端新对象覆盖同 ID 已确认消息`() {
        val existing = message("same-id", 1, body = "旧正文", isPinned = false)
        val latest = message("same-id", 1, body = "新正文", isPinned = true)

        val result = reconcileHeadPage(
            existing = page(existing, nextOffset = 50, hasMore = true),
            latest = page(latest, nextOffset = null, hasMore = false),
            outgoing = emptyList(),
        ).messages.single()

        assertEquals("新正文", result.body)
        assertTrue(result.isPinned)
        assertEquals(ChatDeliveryState.SENT, result.deliveryState)
    }

    @Test
    fun `有已确认重叠的最新 HEAD 保留已加载历史分页边界`() {
        val existing = page(
            message("old", 1),
            message("overlap", 2, body = "旧正文"),
            nextOffset = 100,
            hasMore = true,
        )
        val latest = page(
            message("overlap", 2, body = "新正文"),
            message("latest", 3),
            nextOffset = 50,
            hasMore = true,
        )

        val result = reconcileHeadPage(
            existing = existing,
            latest = latest,
            outgoing = emptyList(),
        )

        assertEquals(100, result.nextOffset)
        assertTrue(result.hasMore)
        assertEquals("新正文", result.messages.single { it.id == "overlap" }.body)
    }

    @Test
    fun `本地未确认 outgoing 不会制造 HEAD 重叠`() {
        val pending = message(
            id = "local:shared",
            time = 1,
            deliveryState = ChatDeliveryState.SENDING,
            clientRequestId = "request-shared",
        )
        val existing = page(pending, nextOffset = null, hasMore = false)
        val latest = page(message("local:shared", 2), nextOffset = 50, hasMore = true)

        val result = reconcileHeadPage(
            existing = existing,
            latest = latest,
            outgoing = listOf(pending),
        )

        assertEquals(50, result.nextOffset)
        assertTrue(result.hasMore)
        assertEquals(ChatDeliveryState.SENT, result.messages.single().deliveryState)
    }

    private fun message(
        id: String,
        time: Long,
        body: String = id,
        isPinned: Boolean = false,
        attachments: List<ChatAttachment> = emptyList(),
        pollVotes: Int? = null,
        clientRequestId: String? = null,
        deliveryState: ChatDeliveryState = ChatDeliveryState.SENT,
        attachmentProgress: Float? = null,
    ) = ChatMessage(
        id = id,
        conversationId = "conversation-a",
        sender = ChatUser("user", "User", "user"),
        body = body,
        createdAtEpochSeconds = time,
        isMine = true,
        attachments = attachments,
        isPinned = isPinned,
        clientRequestId = clientRequestId,
        deliveryState = deliveryState,
        attachmentProgress = attachmentProgress,
        poll = pollVotes?.let { votes ->
            ChatPoll(
                id = "poll-$id",
                question = "Question",
                allowsMultipleSelection = false,
                isAnonymous = false,
                options = listOf(ChatPollOption("option", "A", voteCount = votes)),
            )
        },
    )

    private fun page(
        vararg messages: ChatMessage,
        nextOffset: Int? = null,
        hasMore: Boolean = false,
    ) = ChatMessagePage(messages.toList(), nextOffset, hasMore)
}
