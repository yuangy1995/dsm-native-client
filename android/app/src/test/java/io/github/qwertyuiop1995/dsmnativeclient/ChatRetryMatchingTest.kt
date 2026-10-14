package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ChatRetryMatchingTest {
    @Test fun `恢复只接受回执编号和本人原内容不以时间相近认领`() = runBlocking {
        for (variant in listOf("matching", "other-id", "other-text", "other-author")) {
            val f = ChatProtocolFixture()
            f.posts = "[${f.post(if (variant == "other-text") "different" else "hello", id = if (variant == "other-id") "other-post" else "post-1")
                .let { if (variant == "other-author") it.replace("\"creator_id\":\"1\"", "\"creator_id\":\"2\"") else it }}]"
            val action = f.prepare(ChatActionDraft(ChatActionKind.SEND, f.channelId, text = "hello"))
            val result = f.execute(action)
            assertEquals(variant, if (variant == "matching") ChatActionPhase.COMPLETED else ChatActionPhase.SUBMITTED, result.checkpoint.phase)
            assertEquals("post-1", f.postReads.single().chatFields()["post_id"])
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `无回执时无论消息时间有效与否都不会把相同正文认领`() = runBlocking {
        for (time in listOf(0L, System.currentTimeMillis())) {
            val f = ChatProtocolFixture()
            f.posts = "[${f.post().replace("1700000000000", time.toString())}]"
            f.write = { """{"success":true,"data":{}}""" }
            val action = f.prepare(ChatActionDraft(ChatActionKind.SEND, f.channelId, text = "hello"))
            assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
            assertTrue(f.postReads.isEmpty()); assertEquals(1, f.writes.size)
        }
    }
}
