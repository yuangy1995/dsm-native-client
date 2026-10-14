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

class ChatScheduleMutationResultTest {
    @Test fun `创建断线即使列表内容匹配也不认领或重放`() = runBlocking {
        val f = ChatProtocolFixture(); val draft = draft(f); f.schedules = "[${f.schedule(draft.atMillis!!, "later", "other-job")}]"
        f.write = { throw IOException("synthetic disconnect") }
        val action = f.prepare(draft); val result = f.execute(action)
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertNull(result.schedule); assertNull(result.checkpoint.remoteId)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `创建成功响应仍须按回执编号和内容回读确认`() = runBlocking {
        val f = ChatProtocolFixture(); val draft = draft(f)
        f.write = { f.schedules = "[${f.schedule(draft.atMillis!!, "later")}]"; receipt() }
        val result = f.execute(f.prepare(draft))
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase); assertEquals("schedule-1", result.schedule!!.id)
        assertEquals(draft.atMillis, result.schedule.sendAtEpochMillis); assertEquals(1, f.writes.size)
    }
    @Test fun `创建断线且回读为空保持已提交`() = runBlocking {
        val f = ChatProtocolFixture(); f.write = { throw IOException("synthetic disconnect") }
        val action = f.prepare(draft(f))
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `创建明确权限拒绝不回读且报告原失败`() = runBlocking {
        val f = ChatProtocolFixture(); f.write = { """{"success":false,"error":{"code":105}}""" }
        val result = f.execute(f.prepare(draft(f)))
        assertEquals(ChatActionPhase.REJECTED, result.checkpoint.phase)
        assertEquals(105, result.failure?.code); assertTrue(result.failure?.isExplicitApiRejection == true)
        assertEquals("create", f.requests.last().chatFields()["method"])
    }
    @Test fun `取消定时消息断线但回读已不存在时确认成功`() = runBlocking {
        val f = ChatProtocolFixture(); val action = deletion(f)
        f.write = { f.schedules = "[]"; throw IOException("synthetic disconnect") }
        assertEquals(ChatActionPhase.COMPLETED, f.execute(action).checkpoint.phase)
        assertTrue(f.repo.schedules(f.channelId).isEmpty())
        assertEquals(ChatActionPhase.COMPLETED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `取消定时消息断线且仍存在时保持已提交`() = runBlocking {
        val f = ChatProtocolFixture(); val action = deletion(f)
        f.write = { throw IOException("synthetic disconnect") }
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `删除定时消息的用户所见基线漂移时零写拒绝`() = runBlocking {
        val f = ChatProtocolFixture(); val time = validTime(); val action = deletion(f, time)
        f.schedules = "[${f.schedule(time, "changed")}]"
        val error = runCatching { f.execute(action) }.exceptionOrNull() as? DsmFailure
        assertEquals(DsmErrorKind.CHAT_ITEM_CHANGED, error?.kind); assertTrue(f.writes.isEmpty())
        assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `写前会话回读失败时不提交定时消息`() = runBlocking {
        val f = ChatProtocolFixture(); val action = f.prepare(draft(f))
        f.channelFailure = IOException("synthetic preflight failure")
        assertNotNull(runCatching { f.execute(action) }.exceptionOrNull()); assertTrue(f.writes.isEmpty())
        assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `非法输入缺能力及提交前取消均不写入`() = runBlocking {
        val f = ChatProtocolFixture()
        for (draft in listOf(draft(f).copy(text = " "), draft(f).copy(atMillis = System.currentTimeMillis()))) {
            assertTrue(runCatching { f.prepare(draft) }.exceptionOrNull() is IllegalArgumentException)
        }
        assertTrue(f.writes.isEmpty())
        val unsupported = ChatProtocolFixture(scheduleVersion = 2)
        assertTrue(runCatching { unsupported.prepare(draft(unsupported)) }.exceptionOrNull() is DsmFailure)
        assertTrue(unsupported.requests.isEmpty())
        val action = f.prepare(draft(f)); f.requests.clear()
        val job = launch { currentCoroutineContext().cancel(); f.execute(action) }; job.join()
        assertTrue(job.isCancelled); assertTrue(f.requests.isEmpty())
        assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `同一正文时间使用不同请求ID并发时仍拒绝重复创建`() = runBlocking {
        val f = ChatProtocolFixture(); val draft = draft(f); val action = f.prepare(draft)
        val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); f.schedules = "[${f.schedule(draft.atMillis!!, "later")}]"; receipt() }
        val first = async(Dispatchers.IO) { f.execute(action) }
        try {
            assertTrue(started.await(5, TimeUnit.SECONDS))
            val error = runCatching { f.prepare(draft, "request-2") }.exceptionOrNull() as? DsmFailure
            assertEquals(DsmErrorKind.WORKSPACE_BUSY, error?.kind); assertEquals(1, f.writes.size)
        } finally { release.countDown() }
        assertEquals(ChatActionPhase.COMPLETED, first.await().checkpoint.phase)
    }
    @Test fun `提交后取消保留提交记录且不强制回读或重放`() = runBlocking {
        val f = ChatProtocolFixture(); val action = f.prepare(draft(f)); val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); receipt() }
        val job = launch(Dispatchers.IO) { f.execute(action) }
        var count = 0
        try { assertTrue(started.await(5, TimeUnit.SECONDS)); count = f.requests.size; job.cancel() } finally { release.countDown() }
        job.join(); assertTrue(job.isCancelled); assertEquals(count, f.requests.size)
        assertEquals(ChatActionPhase.SUBMITTED, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    private fun validTime() = System.currentTimeMillis() + 3_600_000
    private fun receipt() = """{"success":true,"data":{"cronjob_id":"schedule-1"}}"""
    private fun draft(f: ChatProtocolFixture) = ChatActionDraft(ChatActionKind.SCHEDULE_CREATE, f.channelId, text = "later", atMillis = validTime())
    private suspend fun deletion(f: ChatProtocolFixture, time: Long = validTime()): ChatPreparedAction {
        f.schedules = "[${f.schedule(time, "later")}]"
        return f.prepare(ChatActionDraft(ChatActionKind.SCHEDULE_DELETE, f.channelId, schedule = f.repo.schedules(f.channelId).single()))
    }
}
