package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatPollRepositoryTest {
    @Test fun `无附件投票固定v1且按编号回读`() = runBlocking {
        val f = ChatProtocolFixture("synthetic-channel")
        val options = listOf("First choice", "Second choice")
        f.posts = "[${f.poll("Synthetic question?", options)}]"
        val action = f.prepare(ChatActionDraft(ChatActionKind.POLL_CREATE, f.channelId,
            text = " Synthetic question? ", options = options, multiple = true))
        val result = f.execute(action)
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertEquals("vote-1", result.message!!.poll!!.id)
        assertEquals(options, result.message.poll!!.options.map { it.text })
        assertEquals("post-1", f.postReads.single().chatFields()["post_id"])
        RequestFixtureAssertions.assertRequest(f.writes.single(), "chat/create-poll/synthetic-poll/request.json")
        val fields = f.writes.single().chatFields()
        assertEquals("1", fields["version"])
        assertEquals(Json.parseToJsonElement("""[{"text":"First choice"},{"text":"Second choice"}]"""), Json.parseToJsonElement(fields.getValue("choices")))
        assertEquals(Json.parseToJsonElement("""{"add_option":false,"anonymous":false,"multiple":true,"expire_at":0}"""), Json.parseToJsonElement(fields.getValue("options")))
    }
    @Test fun `投票创建断线即使内容相同也不认领或重放`() = runBlocking {
        val f = ChatProtocolFixture(); f.posts = "[${f.poll("问题", listOf("A", "B"), multiple = false, anonymous = true)}]"
        f.write = { throw IOException("synthetic disconnect") }
        val action = f.prepare(ChatActionDraft(ChatActionKind.POLL_CREATE, f.channelId,
            text = "问题", options = listOf("A", "B"), anonymous = true))
        val result = f.execute(action)
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertNull(result.message)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.size); assertTrue(f.postReads.isEmpty())
    }
    @Test fun `忽略大小写后重复的投票选项预检拒绝且零写入`() = runBlocking {
        val f = ChatProtocolFixture()
        val result = runCatching { f.prepare(ChatActionDraft(ChatActionKind.POLL_CREATE, f.channelId,
            text = "问题", options = listOf("A", "a"))) }
        assertTrue(result.exceptionOrNull() is IllegalArgumentException)
        assertTrue(f.writes.isEmpty()); assertTrue(f.store.records(f.owner).isEmpty())
    }
}
