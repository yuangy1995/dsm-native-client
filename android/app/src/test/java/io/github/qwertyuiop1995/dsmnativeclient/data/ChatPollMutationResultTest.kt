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

class ChatPollMutationResultTest {
    @Test fun `创建断线即使近期投票匹配也保持已提交`() = runBlocking {
        val f = ChatProtocolFixture(); f.posts = "[${f.poll(id = "other-post")}]"
        f.write = { throw IOException("synthetic disconnect") }
        val action = f.prepare(draft(f)); val result = f.execute(action)
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertNull(result.message); assertNull(result.checkpoint.remoteId)
        assertEquals(1, f.writes.size); assertTrue(f.postReads.isEmpty())
    }
    @Test fun `创建成功仍须按回执编号回读完整投票`() = runBlocking {
        val f = ChatProtocolFixture(); f.posts = "[${f.poll()}]"
        val result = f.execute(f.prepare(draft(f)))
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase); assertNotNull(result.message!!.poll)
        assertEquals("post-1", f.postReads.single().chatFields()["post_id"]); assertEquals(1, f.writes.size)
    }
    @Test fun `创建断线且回读为空时保持已提交且不重放`() = runBlocking {
        val f = ChatProtocolFixture(); f.write = { throw IOException("synthetic disconnect") }
        val action = f.prepare(draft(f))
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.size)
    }
    @Test fun `创建明确权限拒绝报告原失败且不回读`() = runBlocking {
        val f = ChatProtocolFixture(); f.write = { """{"success":false,"error":{"code":105}}""" }
        val result = f.execute(f.prepare(draft(f)))
        assertEquals(ChatActionPhase.REJECTED, result.checkpoint.phase)
        assertEquals(105, result.failure?.code); assertTrue(result.failure?.isExplicitApiRejection == true)
        assertTrue(f.postReads.isEmpty())
    }
    @Test fun `写前会话回读失败时不提交投票`() = runBlocking {
        val f = ChatProtocolFixture(); val action = f.prepare(draft(f))
        f.channelFailure = IOException("synthetic preflight failure")
        assertNotNull(runCatching { f.execute(action) }.exceptionOrNull()); assertTrue(f.writes.isEmpty())
        assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `提交后回读失败保存编号并可在新实例只读恢复`() = runBlocking {
        val f = ChatProtocolFixture(); val action = f.prepare(draft(f)); f.readFailure = IOException("synthetic readback failure")
        val result = f.execute(action)
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertEquals("post-1", result.checkpoint.remoteId)
        assertNotNull(result.failure)
        f.readFailure = null; f.posts = "[${f.poll()}]"
        assertEquals(ChatActionPhase.COMPLETED, DsmChatRepository(f.repo.gateway).recoverAction(result.checkpoint) { f.store.save(f.owner, it) }.checkpoint.phase)
        assertEquals(1, f.writes.size)
    }
    @Test fun `非法选项缺能力与提交前取消均不写入`() = runBlocking {
        val f = ChatProtocolFixture()
        assertTrue(runCatching { f.prepare(draft(f).copy(options = listOf("Same", "same"))) }.exceptionOrNull() is IllegalArgumentException)
        assertTrue(f.writes.isEmpty())
        val unavailable = ChatProtocolFixture(voteVersion = 2)
        assertTrue(runCatching { unavailable.prepare(draft(unavailable)) }.exceptionOrNull() is DsmFailure)
        assertTrue(unavailable.requests.isEmpty())
        val action = f.prepare(draft(f)); f.requests.clear()
        val job = launch { currentCoroutineContext().cancel(); f.execute(action) }; job.join()
        assertTrue(job.isCancelled); assertTrue(f.requests.isEmpty())
        assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `同一投票使用不同请求ID并发时仍拒绝重复创建`() = runBlocking {
        val f = ChatProtocolFixture(); f.posts = "[${f.poll()}]"; val draft = draft(f); val action = f.prepare(draft)
        val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); """{"success":true,"data":{"post_id":"post-1"}}""" }
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
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); """{"success":true,"data":{"post_id":"post-1"}}""" }
        val job = launch(Dispatchers.IO) { f.execute(action) }
        var count = 0
        try { assertTrue(started.await(5, TimeUnit.SECONDS)); count = f.requests.size; job.cancel() } finally { release.countDown() }
        job.join(); assertTrue(job.isCancelled); assertEquals(count, f.requests.size)
        assertEquals(ChatActionPhase.SUBMITTED, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    private fun draft(f: ChatProtocolFixture) = ChatActionDraft(ChatActionKind.POLL_CREATE, f.channelId,
        text = "Question?", options = listOf("First", "Second"), multiple = true)
}
