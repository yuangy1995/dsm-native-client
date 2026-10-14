package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatIdentityCodecTest {
    @Test fun `显示名等于登录名不能取得本人编辑发送身份`() = runBlocking {
        val f = ChatActionGateway()
        f.userData = obj("{\"users\":[{\"user_id\":\"2\",\"name\":\"tester\",\"nickname\":\"tester\"}]}")
        assertFalse(f.repo.users().single().isCurrent)
        try { f.repo.prepareAction(ChatActionDraft(ChatActionKind.SEND, "11", text = "test")); fail("Expected identity rejection") } catch (_: DsmFailure) {}
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `用户重复身份冲突本人标记与坏目录均拒绝写前判断`() = runBlocking {
        val f = ChatActionGateway()
        for (text in listOf("{}", "{\"users\":[{\"user_id\":\"1\"},{\"user_id\":\"1\"}]}",
            "{\"current_user_id\":\"1\",\"users\":[{\"user_id\":\"1\",\"is_current\":false}]}",
            "{\"current_user_id\":\"1\",\"users\":[{\"user_id\":\"1\"},{\"user_id\":\"2\",\"username\":\"tester\"}]}")) {
            f.userData = obj(text)
            try { f.repo.users(); fail("Expected invalid directory") } catch (_: DsmFailure) {}
        }
    }
    @Test fun `恢复身份读取失败不能将已关闭会话认领为成功`() = runBlocking {
        val f = ChatActionGateway(); f.repo.users(); f.userData = obj("{}"); f.channels.clear()
        val c = ChatActionCheckpoint("close", ChatActionKind.CLOSE, "11", "1", phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1)
        assertEquals(ChatActionPhase.SUBMITTED, f.repo.recoverAction(c) {}.checkpoint.phase)
    }
    @Test fun `坏投票仍显示原正文但不能编辑或参与且不伪造选项身份`() = runBlocking {
        val f = ChatActionGateway(); f.repo.users()
        f.posts["11"] = listOf(JsonObject(post("7", "11", "Question") + ("props" to obj("{\"vote\":{\"choices\":[{\"id\":\"a\"}]}}"))))
        val message = f.repo.messages("11").messages.single()
        assertEquals("Question", message.body); assertNull(message.poll); assertEquals("poll", message.kind)
        assertFalse(ChatEditingPolicy(true, null).permits(message))
        f.posts["11"] = listOf(JsonObject(post("7", "11", "Question") + ("props" to obj("{\"vote\":{\"choices\":[\"A\",\"B\"]}}"))))
        val poll = f.repo.messages("11").messages.single().poll!!
        assertEquals(listOf("A", "B"), poll.options.map { it.text }); assertFalse(poll.canVote)
    }
    @Test fun `成员重复身份不作为完整有效的加入回读`() = runBlocking {
        val f = ChatActionGateway(); f.members = listOf("1", "1")
        try { f.repo.conversationMembers("11"); fail("Expected duplicate rejection") } catch (_: DsmFailure) {}
    }
}
