package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.*

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatReminderRepositoryTest {
    @Test fun `提醒固定v1并在写后回读确认且请求ID不出站`() = runBlocking {
        val f = ChatProtocolFixture(); val time = System.currentTimeMillis() + 3_600_000
        f.posts = "[${f.post()}]"
        val original = requireNotNull(f.repo.message(f.channelId, "post-1"))
        val action = f.prepare(ChatActionDraft(ChatActionKind.REMINDER_SET, f.channelId, original = original, atMillis = time))
        f.requests.clear()
        f.write = { f.reminders = "[${f.reminder(time)}]"; """{"success":true}""" }
        val first = f.execute(action); val requestCount = f.requests.size
        val second = f.execute(action)
        assertEquals(ChatActionPhase.COMPLETED, first.checkpoint.phase)
        assertEquals(time, first.reminder!!.remindAtEpochMillis)
        assertEquals(first.checkpoint, second.checkpoint); assertEquals(requestCount, f.requests.size)
        val reminderFields = f.requests.map { it.chatFields() }.filter { it["api"] == "SYNO.Chat.Post.Reminder" }
        assertEquals(listOf("list", "set", "list"), reminderFields.map { it["method"] })
        assertEquals("1", reminderFields[1]["version"]); assertEquals(time.toString(), reminderFields[1]["remind_at"])
        assertTrue(reminderFields.flatMap { it.keys }.none { it.contains("request", true) })
    }

    @Test fun `提醒写入断线后只回读不自动重放`() = runBlocking {
        val f = ChatProtocolFixture(); val time = System.currentTimeMillis() + 7_200_000
        f.posts = "[${f.post()}]"
        val action = f.prepare(ChatActionDraft(ChatActionKind.REMINDER_SET, f.channelId,
            original = requireNotNull(f.repo.message(f.channelId, "post-1")), atMillis = time))
        f.requests.clear()
        f.write = { f.reminders = "[${f.reminder(time)}]"; throw IOException("synthetic disconnect") }
        val result = f.execute(action)
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase); assertEquals("post-1", result.reminder!!.messageId)
        assertEquals(listOf("list", "set", "list"), f.requests.map { it.chatFields() }
            .filter { it["api"] == "SYNO.Chat.Post.Reminder" }.map { it["method"] })
    }

    @Test fun `取消提醒前后回读且重复请求不再写入`() = runBlocking {
        val f = ChatProtocolFixture(); val time = System.currentTimeMillis() + 3_600_000
        f.reminders = "[${f.reminder(time, "synthetic-post")}]"
        val original = f.repo.reminders(f.channelId).single()
        val action = f.prepare(ChatActionDraft(ChatActionKind.REMINDER_DELETE, f.channelId, reminder = original))
        f.requests.clear()
        f.write = { f.reminders = "[]"; """{"success":true}""" }
        assertEquals(ChatActionPhase.COMPLETED, f.execute(action).checkpoint.phase)
        val count = f.requests.size
        assertEquals(ChatActionPhase.COMPLETED, f.execute(action).checkpoint.phase)
        assertEquals(count, f.requests.size)
        RequestFixtureAssertions.assertRequest(f.writes.single(), "chat/delete-reminder/synthetic-post/request.json")
        assertEquals(listOf("list", "delete", "list"), f.requests.map { it.chatFields() }
            .filter { it["api"] == "SYNO.Chat.Post.Reminder" }.map { it["method"] })
    }

    @Test
    fun `提醒请求层可编码公共 Fixture 的固定时间`() = runBlocking {
        val transport = ReminderInterceptor(body("""{"success":true,"data":{}}"""))
        val api = DsmApiClient(
            OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(transport).build(),
        )

        api.call(
            NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
            DsmSession("test", "synthetic-session", "synthetic-token"),
            ApiCapability("SYNO.Chat.Post.Reminder", "entry.cgi", 1, 1),
            "set",
            mapOf("post_id" to "synthetic-post", "remind_at" to "1774166400000"),
        )

        RequestFixtureAssertions.assertRequest(
            transport.requests.single(),
            "chat/set-reminder/synthetic-post/request.json",
        )
    }

    @Test
    fun `提醒能力版本不匹配时零请求拒绝`() = runBlocking {
        val transport = ReminderInterceptor()
        var thrown = false

        try {
            repository(transport, reminderVersion = 2).chatRepository.reminders("channel-1")
        } catch (_: Throwable) {
            thrown = true
        }

        assertTrue(thrown)
        assertTrue(transport.requests.isEmpty())
    }

    private fun repository(interceptor: ReminderInterceptor, reminderVersion: Int = 1) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build()),
        mapOf(
            "SYNO.Chat.Post.Reminder" to ApiCapability(
                "SYNO.Chat.Post.Reminder", "entry.cgi", reminderVersion, reminderVersion,
            ),
        ),
    )

    private fun body(value: String) = ReminderStep.Body(value)
}

private sealed interface ReminderStep {
    data class Body(val value: String) : ReminderStep
}

private class ReminderInterceptor(vararg steps: ReminderStep) : Interceptor {
    private val queue = ArrayDeque(steps.toList())
    val requests = CopyOnWriteArrayList<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return when (val step = queue.removeFirstOrNull() ?: error("Unexpected request")) {
            is ReminderStep.Body -> Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(step.value.toResponseBody())
                .build()
        }
    }
}
