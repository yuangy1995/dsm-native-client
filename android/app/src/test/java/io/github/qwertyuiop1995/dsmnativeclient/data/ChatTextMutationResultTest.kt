package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class ChatTextMutationResultTest {
    @Test fun `提交断线即使近期文字匹配也不认领其他消息`() = runBlocking {
        val f = ChatProtocolFixture(); f.posts = "[${f.post(id = "other-post")}]"
        f.write = { throw IOException("synthetic disconnect") }
        val result = f.execute(f.prepare(draft(f)))
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase)
        assertNull(result.checkpoint.remoteId); assertNull(result.message)
        assertEquals(1, f.writes.size); assertTrue(f.postReads.isEmpty())
    }
    @Test fun `提交断线且无消息保持已提交可只读恢复`() = runBlocking {
        val f = ChatProtocolFixture(); f.write = { throw IOException("synthetic disconnect") }
        val result = f.execute(f.prepare(draft(f)))
        val cold = DsmChatRepository(f.repo.gateway).recoverAction(result.checkpoint) { f.store.save(f.owner, it) }
        assertEquals(ChatActionPhase.SUBMITTED, cold.checkpoint.phase)
        assertEquals(1, f.writes.size); assertTrue(f.postReads.isEmpty())
    }
    @Test fun `响应缺少消息ID即使内容相同也保持已提交`() = runBlocking {
        val f = ChatProtocolFixture(); f.posts = "[${f.post()}]"
        f.write = { """{"success":true,"data":{}}""" }
        val result = f.execute(f.prepare(draft(f)))
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase)
        assertTrue(result.checkpoint.acknowledged); assertNull(result.message)
        assertTrue(f.postReads.isEmpty()); assertEquals(1, f.writes.size)
    }
    @Test fun `明确权限拒绝保留拒绝阶段且不回读或重发`() = runBlocking {
        val f = ChatProtocolFixture(); f.write = { """{"success":false,"error":{"code":105}}""" }
        val action = f.prepare(draft(f)); val result = f.execute(action)
        assertEquals(ChatActionPhase.REJECTED, result.checkpoint.phase)
        assertEquals(105, result.failure?.code)
        assertTrue(result.failure?.isExplicitApiRejection == true)
        assertEquals(ChatActionPhase.REJECTED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.size); assertTrue(f.postReads.isEmpty())
    }
    @Test fun `已收到编号但回读失败时保存原编号供新实例恢复`() = runBlocking {
        val f = ChatProtocolFixture(); f.readFailure = IOException("synthetic readback failure")
        val result = f.execute(f.prepare(draft(f)))
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase)
        assertEquals("post-1", result.checkpoint.remoteId); assertNotNull(result.failure)
        f.readFailure = null; f.posts = "[${f.post()}]"
        val restored = DsmChatRepository(f.repo.gateway).recoverAction(result.checkpoint) { f.store.save(f.owner, it) }
        assertEquals(ChatActionPhase.COMPLETED, restored.checkpoint.phase)
        assertTrue(f.postReads.all { it.chatFields()["post_id"] == "post-1" })
        assertEquals(1, f.writes.size)
    }
    @Test fun `非法输入缺能力及提交前取消均不写入`() = runBlocking {
        val f = ChatProtocolFixture()
        assertTrue(runCatching { f.prepare(draft(f).copy(text = " ")) }.exceptionOrNull() is IllegalArgumentException)
        assertTrue(f.writes.isEmpty())
        val unavailable = ChatProtocolFixture(maximumVersion = 4)
        assertTrue(runCatching { unavailable.prepare(draft(unavailable)) }.exceptionOrNull() is DsmFailure)
        assertTrue(unavailable.requests.isEmpty())
        val cancelled = ChatProtocolFixture(); val action = cancelled.prepare(draft(cancelled)); cancelled.requests.clear()
        val worker = launch { currentCoroutineContext().cancel(); cancelled.execute(action) }
        worker.join()
        assertTrue(worker.isCancelled); assertTrue(cancelled.requests.isEmpty())
        assertEquals(ChatActionPhase.READY, cancelled.store.get(cancelled.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `同一请求发送中由正式持久执行锁拒绝重复提交`() = runBlocking {
        val f = ChatProtocolFixture(); f.posts = "[${f.post()}]"
        val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); """{"success":true,"data":{"post_id":"post-1"}}""" }
        val action = f.prepare(draft(f)); val first = async(Dispatchers.IO) { f.execute(action) }
        try {
            assertTrue(started.await(5, TimeUnit.SECONDS))
            assertTrue(runCatching { f.execute(action) }.exceptionOrNull() is DsmFailure)
            assertEquals(1, f.writes.size)
        } finally { release.countDown() }
        assertEquals(ChatActionPhase.COMPLETED, first.await().checkpoint.phase)
    }
    @Test fun `提交后取消保留已提交记录且不强制回读或重放`() = runBlocking {
        val f = ChatProtocolFixture(); val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); """{"success":true,"data":{"post_id":"post-1"}}""" }
        val action = f.prepare(draft(f)); val worker = launch(Dispatchers.IO) { f.execute(action) }
        try { assertTrue(started.await(5, TimeUnit.SECONDS)); worker.cancel() } finally { release.countDown() }
        worker.join()
        assertTrue(worker.isCancelled)
        assertEquals(ChatActionPhase.SUBMITTED, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
        assertEquals(1, f.writes.size); assertTrue(f.postReads.isEmpty())
    }
    private fun draft(f: ChatProtocolFixture) = ChatActionDraft(ChatActionKind.SEND, f.channelId, text = "hello")
}
