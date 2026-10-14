package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatReadRepositoryTest {
    @Test
    fun `会话读取使用已记录的用户和频道list方法`() = runBlocking {
        val transport = ChatReadInterceptor(
            """{"success":true,"data":{"users":[{"user_id":"u-1","nickname":"合成用户"}]}}""",
            """{"success":true,"data":{"channels":[{"channel_id":"c-1","type":"anonymous","members":[{"user_id":"u-1"}],"unread":2,"last_post":{"message":"合成摘要","create_at":1700000000000}}]}}""",
        )

        val conversations = repository(transport).chatConversations()

        assertEquals(1, conversations.size)
        assertEquals("c-1", conversations.single().id)
        assertEquals("合成用户", conversations.single().title)
        assertEquals(1_700_000_000L, conversations.single().latestAtEpochSeconds)
        assertEquals(listOf("SYNO.Chat.User", "SYNO.Chat.Channel"), transport.requests.map { it.fields()["api"] })
        assertEquals(listOf("list", "list"), transport.requests.map { it.fields()["method"] })
    }

    @Test
    fun `消息分页保留字符串标识过滤空辅助记录并解析附件`() = runBlocking {
        val transport = ChatReadInterceptor(
            """{"success":true,"data":{"total":3,"posts":[{"post_id":"p-2","channel_id":"c-1","message":"","create_at":1700000002},{"post_id":"p-1","channel_id":"c-1","message":"你好 👋","creator":{"user_id":"u-1","nickname":"合成用户"},"create_at":1700000001,"is_mine":false,"files":[{"file_id":"f-1","file_name":"合成.txt","size":12}]}]}}""",
        )

        val page = repository(transport).chatMessages("c-1", before = null, limit = 2)

        assertEquals(listOf("p-1"), page.messages.map { it.id })
        assertEquals("合成用户", page.messages.single().sender?.displayName)
        assertEquals("f-1", page.messages.single().attachments.single().id)
        assertTrue(page.hasMore)
        assertEquals("p-1", page.previousCursor)
        assertFalse(page.messages.single().isMine)
        val fields = transport.requests.single().fields()
        assertEquals("SYNO.Chat.Post", fields["api"])
        assertEquals("list", fields["method"])
        assertEquals("c-1", fields["channel_id"])
        assertEquals("2", fields["prev_count"])
        assertEquals("0", fields["thread_id"])
        assertEquals("5", fields["version"])
        assertFalse(fields.containsKey("offset"))
        assertFalse(fields.containsKey("limit"))
    }

    @Test
    fun `消息缺少本人标记时使用用户目录与当前账号安全回填`() = runBlocking {
        val transport = ChatReadInterceptor(
            """{"success":true,"data":{"current_user_id":"current-id","users":[{"user_id":"current-id","username":"tester"}]}}""",
            """{"success":true,"data":{"posts":[{"post_id":"p-1","channel_id":"c-1","message":"hello","creator_id":"current-id","create_at":1700000001}]}}""",
        )
        val repo = repository(transport)

        val users = repo.chatUsers()
        val message = repo.chatMessages("c-1").messages.single()

        assertTrue(users.single().isCurrent)
        assertTrue(message.isMine)
    }

    private fun repository(interceptor: Interceptor): DsmRepository {
        val capabilities = listOf(
            ApiCapability("SYNO.Chat.User", "entry.cgi", 1, 3),
            ApiCapability("SYNO.Chat.Channel", "entry.cgi", 1, 5),
            ApiCapability("SYNO.Chat.Post", "entry.cgi", 1, 8),
        ).associateBy(ApiCapability::name)
        return authorizedRepository(
            NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
            DsmSession("test", "test-session", "test-token"),
            DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build()),
            capabilities,
        )
    }
}

private class ChatReadInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                (pending.removeFirstOrNull() ?: error("缺少合成聊天响应"))
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private fun Request.fields(): Map<String, String> {
    val form = body as FormBody
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
