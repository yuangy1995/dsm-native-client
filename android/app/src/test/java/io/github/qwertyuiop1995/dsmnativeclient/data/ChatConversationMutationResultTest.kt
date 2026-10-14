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

class ChatConversationMutationResultTest {
    @Test fun `单聊创建断线但列表双方身份匹配时确认成功且不重放`() = runBlocking {
        val f = fixture(); f.write = { f.channels = f.directChannel(); throw IOException("synthetic disconnect") }
        val action = f.prepare(direct()); val result = f.execute(action)
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase); assertEquals("27", result.conversation!!.id)
        assertEquals(ChatActionPhase.COMPLETED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `单聊成功响应仍须列表回读确认`() = runBlocking {
        val f = fixture(); f.write = { """{"success":true,"data":{"channel_id":"27"}}""" }
        val result = f.execute(f.prepare(direct()))
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase)
        assertEquals("27", result.checkpoint.remoteId); assertNull(result.conversation)
    }
    @Test fun `单聊明确权限拒绝报告原失败且不回读`() = runBlocking {
        val f = fixture(); f.write = { """{"success":false,"error":{"code":105}}""" }
        val result = f.execute(f.prepare(direct()))
        assertEquals(ChatActionPhase.REJECTED, result.checkpoint.phase)
        assertEquals(105, result.failure?.code); assertTrue(result.failure?.isExplicitApiRejection == true)
        assertEquals("initiate", f.requests.last().chatFields()["method"])
    }
    @Test fun `单聊写前列表失败时不提交`() = runBlocking {
        val f = fixture(); val action = f.prepare(direct()); f.channelFailure = IOException("synthetic preflight failure")
        assertNotNull(runCatching { f.execute(action) }.exceptionOrNull()); assertTrue(f.writes.isEmpty())
        assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `非法输入缺能力及提交前取消均零请求关闭`() = runBlocking {
        val f = fixture()
        assertTrue(runCatching { f.prepare(group().copy(text = "", memberIds = listOf("2"))) }.exceptionOrNull() is IllegalArgumentException)
        assertTrue(f.requests.isEmpty())
        val unsupported = ChatProtocolFixture(anonymousVersion = 1)
        assertTrue(runCatching { unsupported.prepare(direct()) }.exceptionOrNull() is DsmFailure); assertTrue(unsupported.requests.isEmpty())
        val action = f.prepare(direct()); f.requests.clear()
        val job = launch { currentCoroutineContext().cancel(); f.execute(action) }; job.join()
        assertTrue(job.isCancelled); assertTrue(f.requests.isEmpty())
        assertEquals(ChatActionPhase.READY, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
    }
    @Test fun `同一单聊使用不同请求ID并发时仍拒绝重复创建`() = runBlocking {
        val f = fixture(); val action = f.prepare(direct()); val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); f.channels = f.directChannel(); """{"success":true,"data":{"channel_id":"27"}}""" }
        val first = async(Dispatchers.IO) { f.execute(action) }
        try {
            assertTrue(started.await(5, TimeUnit.SECONDS))
            val error = runCatching { f.prepare(direct(), "request-2") }.exceptionOrNull() as? DsmFailure
            assertEquals(DsmErrorKind.WORKSPACE_BUSY, error?.kind); assertEquals(1, f.writes.size)
        } finally { release.countDown() }
        assertEquals(ChatActionPhase.COMPLETED, first.await().checkpoint.phase)
    }
    @Test fun `单聊提交后取消保留提交记录且不强制回读或重放`() = runBlocking {
        val f = fixture(); val action = f.prepare(direct()); val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); """{"success":true,"data":{"channel_id":"27"}}""" }
        val job = launch(Dispatchers.IO) { f.execute(action) }; var count = 0
        try { assertTrue(started.await(5, TimeUnit.SECONDS)); count = f.requests.size; job.cancel() } finally { release.countDown() }
        job.join(); assertTrue(job.isCancelled); assertEquals(count, f.requests.size)
        assertEquals(ChatActionPhase.SUBMITTED, f.store.get(f.owner, action.checkpoint.id).checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `群聊邀请断线且成员不完整时保留原群聊和已加入阶段`() = runBlocking {
        val f = groupFixture(completeMembers = false); val action = f.prepare(group()); val result = f.execute(action)
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertNotNull(result.conversation)
        assertEquals("42", result.checkpoint.remoteId); assertEquals(ChatGroupStep.COMPLETED, result.checkpoint.group!!.join)
        assertEquals(ChatGroupStep.SUBMITTED, result.checkpoint.group.invite)
        val count = f.writes.size
        val restored = DsmChatRepository(f.repo.gateway).continueGroupAction(result.checkpoint) { f.store.save(f.owner, it) }
        assertEquals(ChatActionPhase.SUBMITTED, restored.checkpoint.phase); assertEquals(count, f.writes.size)
        assertEquals(1, f.writes.count { it.chatFields()["method"] == "invite" })
    }
    @Test fun `群聊邀请断线但成员回读完整时确认成功`() = runBlocking {
        val f = groupFixture(completeMembers = true); val result = f.execute(f.prepare(group()))
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertEquals(setOf("1", "2", "3"), result.conversation!!.memberIds.toSet())
        assertEquals(1, f.writes.count { it.chatFields()["method"] == "invite" })
    }
    @Test fun `群聊创建提交后取消保留未知且不继续加入或邀请`() = runBlocking {
        val f = fixture(); val action = f.prepare(group()); val started = CountDownLatch(1); val release = CountDownLatch(1)
        f.write = { started.countDown(); check(release.await(5, TimeUnit.SECONDS)); """{"success":true,"data":{"channel_id":"42"}}""" }
        val job = launch(Dispatchers.IO) { f.execute(action) }; var count = 0
        try { assertTrue(started.await(5, TimeUnit.SECONDS)); count = f.requests.size; job.cancel() } finally { release.countDown() }
        job.join(); assertTrue(job.isCancelled); assertEquals(count, f.requests.size)
        val c = f.store.get(f.owner, action.checkpoint.id).checkpoint
        assertEquals(ChatActionPhase.SUBMITTED, c.phase)
        assertEquals(ChatGroupStep.READY, c.group!!.join); assertEquals(ChatGroupStep.READY, c.group.invite)
        assertEquals(listOf("create"), f.writes.map { it.chatFields()["method"] })
    }
    private fun fixture() = ChatProtocolFixture().also { it.channels = "[]" }
    private fun direct() = ChatActionDraft(ChatActionKind.DIRECT, "new", memberIds = listOf("2"))
    private fun group() = ChatActionDraft(ChatActionKind.GROUP, "new", text = "Group", memberIds = listOf("2", "3"))
    private fun groupFixture(completeMembers: Boolean) = fixture().also { f ->
        f.members = emptyList()
        f.write = { request -> when (request.chatFields()["method"]) {
            "create" -> """{"success":true,"data":{"channel_id":"42"}}"""
            "join" -> { f.members = listOf("1"); f.channels = f.groupChannel(); """{"success":true}""" }
            "invite" -> {
                f.members = if (completeMembers) listOf("1", "2", "3") else listOf("1", "2")
                f.channels = f.groupChannel(); throw IOException("synthetic invite disconnect")
            }
            else -> error("Unexpected synthetic group write")
        } }
    }
}
