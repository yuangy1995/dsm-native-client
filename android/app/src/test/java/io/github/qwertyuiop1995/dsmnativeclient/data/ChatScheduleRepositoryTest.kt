package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ChatScheduleRepositoryTest {
    @Test fun `纯文字定时消息固定v1且同一完成记录不重复创建`() = runBlocking {
        val f = ChatProtocolFixture("synthetic-channel"); val time = 1_800_000_000_000L
        val action = f.prepare(ChatActionDraft(ChatActionKind.SCHEDULE_CREATE, f.channelId,
            text = " Synthetic scheduled message ", atMillis = time))
        f.write = { f.schedules = "[${f.schedule(time, "Synthetic scheduled message", "job-1")}]"
            """{"success":true,"data":{"cronjob_id":"job-1"}}""" }
        val first = f.execute(action); val count = f.requests.size
        assertEquals(ChatActionPhase.COMPLETED, first.checkpoint.phase); assertEquals("job-1", first.schedule!!.id)
        assertEquals(first.checkpoint, f.execute(action).checkpoint); assertEquals(count, f.requests.size)
        RequestFixtureAssertions.assertRequest(f.writes.single(), "chat/create-scheduled-message/synthetic-message/request.json")
        val fields = f.writes.single().chatFields()
        assertEquals("1", fields["version"]); assertEquals(time.toString(), fields["send_at"])
        assertTrue(fields.keys.none { it.contains("request", true) })
    }
    @Test fun `定时消息创建断线即使相同内容也不认领或重放`() = runBlocking {
        val f = ChatProtocolFixture(); val time = System.currentTimeMillis() + 7_200_000
        f.schedules = "[${f.schedule(time, "稍后见", "other-job")}]"
        f.write = { throw IOException("synthetic disconnect") }
        val action = f.prepare(ChatActionDraft(ChatActionKind.SCHEDULE_CREATE, f.channelId, text = "稍后见", atMillis = time))
        val result = f.execute(action)
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertNull(result.schedule)
        assertNull(result.checkpoint.remoteId)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `取消定时消息前后回读并确认消失`() = runBlocking {
        val f = ChatProtocolFixture(); val time = System.currentTimeMillis() + 3_600_000
        f.schedules = "[${f.schedule(time, "稍后见", "synthetic-job")}]"
        val action = f.prepare(ChatActionDraft(ChatActionKind.SCHEDULE_DELETE, f.channelId, schedule = f.repo.schedules(f.channelId).single()))
        f.requests.clear()
        f.write = { f.schedules = "[]"; """{"success":true}""" }
        assertEquals(ChatActionPhase.COMPLETED, f.execute(action).checkpoint.phase)
        assertEquals(listOf("list", "delete", "list"), f.requests.map { it.chatFields() }
            .filter { it["api"] == "SYNO.Chat.Post.Schedule" }.map { it["method"] })
        RequestFixtureAssertions.assertRequest(f.writes.single(), "chat/delete-scheduled-message/synthetic-message/request.json")
        assertEquals("synthetic-job", f.writes.single().chatFields()["cronjob_id"])
    }
}
