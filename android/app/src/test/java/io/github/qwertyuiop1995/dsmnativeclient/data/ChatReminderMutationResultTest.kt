package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class ChatReminderMutationResultTest {
    @Test fun `设置提交断线但回读匹配时确认成功且不重放`() = runBlocking {
        val f = fixture(); val time = validTime(); val action = f.prepare(draft(f, time))
        f.write = { f.reminders = "[${f.reminder(time)}]"; throw IOException("synthetic disconnect") }
        val result = f.execute(action)
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertEquals(time, result.reminder!!.remindAtEpochMillis); assertEquals(1, f.writes.size)
    }
    @Test fun `设置提交断线且回读不匹配时保持已提交`() = runBlocking {
        val f = fixture(); val action = f.prepare(draft(f))
        f.write = { throw IOException("synthetic disconnect") }
        val result = f.execute(action)
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.size)
    }
    @Test fun `设置明确权限拒绝不回读且报告原失败`() = runBlocking {
        val f = fixture(); val action = f.prepare(draft(f))
        f.write = { """{"success":false,"error":{"code":105}}""" }
        val result = f.execute(action)
        assertEquals(ChatActionPhase.REJECTED, result.checkpoint.phase)
        assertEquals(105, result.failure?.code); assertTrue(result.failure?.isExplicitApiRejection == true)
        assertEquals("set", f.requests.last().chatFields()["method"])
    }
    @Test fun `成功响应但回读失败时保持已提交`() = runBlocking {
        val f = fixture(); val action = f.prepare(draft(f))
        f.write = { f.reminderFailure = IOException("synthetic readback failure"); """{"success":true}""" }
        val result = f.execute(action)
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertNotNull(result.failure)
        assertEquals(1, f.writes.size)
    }
    @Test fun `删除提交断线但回读已不存在时确认成功且不重放`() = runBlocking {
        val f = fixture(); val action = deletion(f)
        f.write = { f.reminders = "[]"; throw IOException("synthetic disconnect") }
        assertEquals(ChatActionPhase.COMPLETED, f.execute(action).checkpoint.phase)
        assertTrue(f.repo.reminders(f.channelId).isEmpty())
        assertEquals(ChatActionPhase.COMPLETED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.size)
    }
    @Test fun `删除提交断线且提醒仍存在时保持已提交`() = runBlocking {
        val f = fixture(); val action = deletion(f)
        f.write = { throw IOException("synthetic disconnect") }
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.size)
    }
    @Test fun `删除提醒的用户所见基线漂移时零写拒绝`() = runBlocking {
        val f = fixture(); val time = validTime(); val action = deletion(f, time)
        f.reminders = "[${f.reminder(time + 1_000)}]"
        val error = runCatching { f.execute(action) }.exceptionOrNull() as? DsmFailure
        assertEquals(DsmErrorKind.CHAT_ITEM_CHANGED, error?.kind)
        assertTrue(f.writes.isEmpty()); assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `写前回读失败时不提交提醒变更`() = runBlocking {
        val f = fixture(); val action = f.prepare(draft(f))
        f.reminderFailure = IOException("synthetic preflight failure")
        assertNotNull(runCatching { f.execute(action) }.exceptionOrNull())
        assertTrue(f.writes.isEmpty()); assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `非法时间缺能力与提交前取消不写入`() = runBlocking {
        val f = fixture()
        assertTrue(runCatching { f.prepare(draft(f, System.currentTimeMillis())) }.exceptionOrNull() is IllegalArgumentException)
        assertTrue(f.writes.isEmpty())
        val unsupported = ChatProtocolFixture(reminderVersion = 2)
        assertTrue(runCatching { unsupported.prepare(ChatActionDraft(ChatActionKind.REMINDER_DELETE, unsupported.channelId,
            reminder = ChatReminder("reminder-1", "post-1", validTime()))) }.exceptionOrNull() is DsmFailure)
        assertTrue(unsupported.requests.isEmpty())
        val action = f.prepare(draft(f)); f.requests.clear()
        val job = launch { currentCoroutineContext().cancel(); f.execute(action) }; job.join()
        assertTrue(job.isCancelled); assertTrue(f.requests.isEmpty())
        assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `同一消息使用不同请求ID并发时仍拒绝重复提交`() = runBlocking {
        val f = fixture(); val time = validTime(); val draft = draft(f, time); val action = f.prepare(draft)
        val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); f.reminders = "[${f.reminder(time)}]"; """{"success":true}""" }
        val first = async(Dispatchers.IO) { f.execute(action) }
        try {
            assertTrue(started.await(5, TimeUnit.SECONDS))
            val error = runCatching { f.prepare(draft, "request-2") }.exceptionOrNull() as? DsmFailure
            assertEquals(DsmErrorKind.WORKSPACE_BUSY, error?.kind)
            assertEquals(1, f.writes.size)
        } finally { release.countDown() }
        assertEquals(ChatActionPhase.COMPLETED, first.await().checkpoint.phase)
    }
    @Test fun `提交后取消保留提交记录并仅在后续恢复时回读`() = runBlocking {
        val f = fixture(); val action = f.prepare(draft(f)); val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); """{"success":true}""" }
        val job = launch(Dispatchers.IO) { f.execute(action) }
        var count = 0
        try { assertTrue(started.await(5, TimeUnit.SECONDS)); count = f.requests.size; job.cancel() } finally { release.countDown() }
        job.join(); assertTrue(job.isCancelled); assertEquals(count, f.requests.size)
        assertEquals(ChatActionPhase.SUBMITTED, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    private fun fixture() = ChatProtocolFixture().also { it.posts = "[${it.post()}]" }
    private fun validTime() = System.currentTimeMillis() + 3_600_000
    private suspend fun draft(f: ChatProtocolFixture, time: Long = validTime()) = ChatActionDraft(ChatActionKind.REMINDER_SET,
        f.channelId, original = requireNotNull(f.repo.message(f.channelId, "post-1")), atMillis = time)
    private suspend fun deletion(f: ChatProtocolFixture, time: Long = validTime()): ChatPreparedAction {
        f.reminders = "[${f.reminder(time)}]"
        return f.prepare(ChatActionDraft(ChatActionKind.REMINDER_DELETE, f.channelId, reminder = f.repo.reminders(f.channelId).single()))
    }
}
