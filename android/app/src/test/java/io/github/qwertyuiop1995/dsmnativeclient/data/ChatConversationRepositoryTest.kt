package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.*

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatConversationRepositoryTest {
    @Test fun `首次单聊固定v2且创建前后查重`() = runBlocking {
        val f = ChatProtocolFixture(); f.channels = "[]"
        f.write = { f.channels = f.directChannel(); """{"success":true,"data":{"channel_id":"27"}}""" }
        val action = f.prepare(ChatActionDraft(ChatActionKind.DIRECT, "new", memberIds = listOf("2")))
        val first = f.execute(action); val count = f.requests.size
        assertEquals(ChatActionPhase.COMPLETED, first.checkpoint.phase)
        assertEquals("27", first.conversation!!.id); assertEquals(ConversationKind.DIRECT, first.conversation.kind)
        assertEquals(first.checkpoint, f.execute(action).checkpoint); assertEquals(count, f.requests.size)
        val fields = f.writes.single().chatFields()
        assertEquals("SYNO.Chat.Channel.Anonymous", fields["api"]); assertEquals("2", fields["version"])
        assertEquals("initiate", fields["method"]); assertEquals("[\"2\"]", fields["user_ids"])
        assertEquals("false", fields["encrypted"]); assertEquals("[]", fields["channel_key_encs"])
        assertTrue(fields.keys.none { it.contains("request", true) })
    }

    @Test fun `已有单聊直接复用且不提交写请求`() = runBlocking {
        val f = ChatProtocolFixture(); f.channels = f.directChannel()
        val result = f.execute(f.prepare(ChatActionDraft(ChatActionKind.DIRECT, "new", memberIds = listOf("2"))))
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertEquals("27", result.conversation!!.id); assertTrue(f.writes.isEmpty())
    }

    @Test fun `私人群聊按v1创建加入邀请并复查成员`() = runBlocking {
        val f = groupFixture()
        val action = f.prepare(ChatActionDraft(ChatActionKind.GROUP, "new", text = " 项目组 ", memberIds = listOf("3", "2")))
        val result = f.execute(action)
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertEquals("42", result.conversation!!.id); assertEquals(ConversationKind.GROUP, result.conversation.kind)
        assertEquals(listOf("1", "2", "3"), result.conversation.memberIds)
        val fields = f.writes.map { it.chatFields() }
        assertEquals(listOf("create", "join", "invite"), fields.map { it["method"] })
        assertTrue(fields.all { it["version"] == "1" })
        assertEquals("项目组", fields[0]["name"]); assertEquals("private", fields[0]["type"])
        assertEquals("[\"2\",\"3\"]", fields[2]["user_ids"]); assertEquals("[]", fields[2]["channel_key_encs"])
        assertTrue(f.requests.any { it.chatFields()["api"] == "SYNO.Chat.Channel.Member" && it.chatFields()["method"] == "get" })
    }

    @Test fun `单聊能力不覆盖v2时零请求拒绝`() = runBlocking {
        val f = ChatProtocolFixture(anonymousVersion = 1)
        assertThrows { f.prepare(ChatActionDraft(ChatActionKind.DIRECT, "new", memberIds = listOf("2"))) }
        assertTrue(f.requests.isEmpty())
    }

    @Test fun `建群邀请断线不会自动重放`() = runBlocking {
        val f = groupFixture(inviteFailure = true)
        val action = f.prepare(ChatActionDraft(ChatActionKind.GROUP, "new", text = "项目组", memberIds = listOf("2", "3")))
        val result = f.execute(action)
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase)
        assertEquals(ChatGroupStep.COMPLETED, result.checkpoint.group!!.join)
        assertEquals(ChatGroupStep.SUBMITTED, result.checkpoint.group.invite)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.count { it.chatFields()["method"] == "invite" })
    }

    @Test fun `明确拒绝后的继续沿原群聊邀请且不重复创建`() = runBlocking {
        val f = groupFixture(inviteRejected = true)
        val action = f.prepare(ChatActionDraft(ChatActionKind.GROUP, "new", text = "项目组", memberIds = listOf("2", "3")))
        val result = f.execute(action)
        assertEquals(ChatGroupStep.REJECTED, result.checkpoint.group!!.invite)
        f.write = { f.members = listOf("1", "2", "3"); f.channels = f.groupChannel("项目组"); """{"success":true}""" }
        val next = f.store.execute(action.checkpoint.id) { f.repo.continueGroupAction(result.checkpoint) { f.store.save(f.owner, it) } }
        assertEquals(ChatActionPhase.COMPLETED, next.checkpoint.phase); assertEquals("42", next.conversation!!.id)
        assertEquals(1, f.writes.count { it.chatFields()["method"] == "create" })
        assertEquals(2, f.writes.count { it.chatFields()["method"] == "invite" })
        assertEquals("[\"2\",\"3\"]", f.writes.last().chatFields()["user_ids"])
    }

    @Test
    fun `Chat 会话请求层符合四份公共 Fixture`() = runBlocking {
        val transport = ChatConversationInterceptor(
            body("""{"success":true,"data":{}}"""),
            body("""{"success":true,"data":{}}"""),
            body("""{"success":true,"data":{}}"""),
            body("""{"success":true,"data":{}}"""),
        )
        val profile = NasProfile("test", "Test", "https://nas.example.invalid", "operator")
        val session = DsmSession("test", "test-session", "test-token")
        val api = DsmApiClient(
            OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(transport).build(),
        )

        api.call(
            profile, session, ApiCapability("SYNO.Chat.Channel.Anonymous", "entry.cgi", 1, 2),
            "initiate",
            mapOf("user_ids" to "[\"synthetic-user\"]", "encrypted" to "false", "channel_key_encs" to "[]"),
        )
        api.call(
            profile, session, ApiCapability("SYNO.Chat.Channel.Named", "entry.cgi", 1, 1),
            "create", mapOf("name" to "Synthetic group", "type" to "private"),
        )
        api.call(
            profile, session, ApiCapability("SYNO.Chat.Channel.Named", "entry.cgi", 1, 1),
            "join", mapOf("channel_id" to "synthetic-channel"),
        )
        api.call(
            profile, session, ApiCapability("SYNO.Chat.Channel.Named", "entry.cgi", 1, 1),
            "invite",
            mapOf(
                "channel_id" to "synthetic-channel",
                "user_ids" to "[\"synthetic-member-a\",\"synthetic-member-b\"]",
                "channel_key_encs" to "[]",
            ),
        )

        listOf(
            "chat/open-direct/synthetic-user/request.json",
            "chat/create-private-group/synthetic-group/request.json",
            "chat/join-private-group/synthetic-group/request.json",
            "chat/invite-private-group/synthetic-members/request.json",
        ).forEachIndexed { index, fixture ->
            RequestFixtureAssertions.assertRequest(transport.requests[index], fixture)
        }
    }

    private fun groupFixture(inviteFailure: Boolean = false, inviteRejected: Boolean = false) = ChatProtocolFixture().also { f ->
        f.channels = "[]"; f.members = emptyList()
        f.write = { request ->
            when (request.chatFields()["method"]) {
                "create" -> """{"success":true,"data":{"channel_id":"42"}}"""
                "join" -> { f.members = listOf("1"); f.channels = f.groupChannel("项目组"); """{"success":true}""" }
                "invite" -> when {
                    inviteFailure -> throw IOException("synthetic disconnect")
                    inviteRejected -> """{"success":false,"error":{"code":105}}"""
                    else -> { f.members = listOf("1", "2", "3"); f.channels = f.groupChannel("项目组"); """{"success":true}""" }
                }
                else -> error("Unexpected synthetic group write")
            }
        }
    }

    private fun body(value: String) = ChatConversationStep.Body(value)

    private suspend fun assertThrows(block: suspend () -> Unit) {
        var thrown = false
        try {
            block()
        } catch (_: Throwable) {
            thrown = true
        }
        assertTrue(thrown)
    }
}

private sealed interface ChatConversationStep {
    data class Body(val value: String) : ChatConversationStep
}

private class ChatConversationInterceptor(vararg steps: ChatConversationStep) : Interceptor {
    private val queue = ArrayDeque(steps.toList())
    val requests = CopyOnWriteArrayList<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return when (val step = queue.removeFirstOrNull() ?: error("Unexpected request")) {
            is ChatConversationStep.Body -> Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(step.value.toResponseBody("application/json".toMediaType()))
                .build()
        }
    }

}
