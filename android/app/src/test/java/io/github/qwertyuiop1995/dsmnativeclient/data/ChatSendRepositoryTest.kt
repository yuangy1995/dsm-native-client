package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.ChatProtocolFixture
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.chatFields
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatDeliveryState
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ChatSendRepositoryTest {
    @Test fun `文字发送只提交会话和正文且不发送客户端请求ID`() = runBlocking {
        val f = ChatProtocolFixture("synthetic-channel")
        f.posts = "[${f.post("Synthetic message")}]"
        val action = f.prepare(ChatActionDraft(ChatActionKind.SEND, f.channelId, text = " Synthetic message "))
        val result = f.execute(action)
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertEquals("post-1", result.message!!.id)
        assertEquals("Synthetic message", result.message.body)
        assertEquals(ChatDeliveryState.SENT, result.message.deliveryState)
        RequestFixtureAssertions.assertRequest(f.writes.single(), "chat/send-text/synthetic-message/request.json")
        val fields = f.writes.single().chatFields()
        assertEquals("SYNO.Chat.Post", fields["api"]); assertEquals("create", fields["method"])
        assertEquals("5", fields["version"]); assertEquals(f.channelId, fields["channel_id"])
        assertEquals("Synthetic message", fields["message"])
        assertTrue(fields.keys.none { it.contains("request", ignoreCase = true) })
    }
    @Test fun `同一请求完成后重复执行只返回持久阶段且不重发`() = runBlocking {
        val f = ChatProtocolFixture(); f.posts = "[${f.post()}]"
        val action = f.prepare(ChatActionDraft(ChatActionKind.SEND, f.channelId, text = "hello"))
        val first = f.execute(action)
        val count = f.requests.size
        val second = f.execute(action)
        assertEquals(ChatActionPhase.COMPLETED, first.checkpoint.phase)
        assertEquals(first.checkpoint, second.checkpoint)
        assertEquals(count, f.requests.size); assertEquals(1, f.writes.size)
    }
    @Test fun `提交断线不会在执行器内自动重放`() = runBlocking {
        val f = ChatProtocolFixture(); f.write = { throw IOException("synthetic disconnect") }
        val action = f.prepare(ChatActionDraft(ChatActionKind.SEND, f.channelId, text = "hello"))
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.size); assertTrue(f.postReads.isEmpty())
    }
    @Test fun `空正文和超长正文预检拒绝且零写入`() = runBlocking {
        val f = ChatProtocolFixture()
        for (text in listOf(" ", "x".repeat(10_001))) {
            val error = runCatching { f.prepare(ChatActionDraft(ChatActionKind.SEND, f.channelId, text = text)) }.exceptionOrNull()
            assertTrue(error is IllegalArgumentException)
        }
        assertTrue(f.writes.isEmpty()); assertTrue(f.store.records(f.owner).isEmpty())
    }
    @Test fun `运行时能力不覆盖v5时零请求拒绝`() = runBlocking {
        val f = ChatProtocolFixture(maximumVersion = 4)
        assertNotNull(runCatching { f.prepare(ChatActionDraft(ChatActionKind.SEND, f.channelId, text = "hello")) }.exceptionOrNull())
        assertTrue(f.requests.isEmpty())
    }
}
