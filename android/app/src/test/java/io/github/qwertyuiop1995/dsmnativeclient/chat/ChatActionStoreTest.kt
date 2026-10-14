package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ChatActionStoreTest {
    private val owner = WorkspaceOwner("synthetic", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = ChatActionStore(preferences)
    private fun checkpoint(id: String = "request") = ChatActionCheckpoint(id, ChatActionKind.SEND, "11", "1", desiredDigest = chatTextDigest("synthetic body"))
    private fun begin(c: ChatActionCheckpoint = checkpoint()) = c.also { store.begin(ChatActionRecord(owner = owner, checkpoint = it)) }
    @Test fun `同身份重登恢复原回执不同身份与NAS不可读`() {
        val c = begin().copy(phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1, remoteId = "71", acknowledged = true)
        store.save(owner, c)
        assertEquals(c, ChatActionStore(preferences).records(owner.copy(sessionGeneration = "new")).single().checkpoint)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty())
        assertTrue(store.records(owner.copy(profileId = "other")).isEmpty())
    }
    @Test fun `持久记录没有正文名称凭据与文件路径`() {
        begin(); val contents = preferences.all.values.joinToString()
        assertFalse(contents.contains("synthetic body")); assertFalse(contents.contains("password")); assertFalse(contents.contains("https://"))
        assertTrue(contents.contains(chatTextDigest("synthetic body")))
    }
    @Test fun `未知不能删除改对象降级或替换远端身份`() {
        val c = begin().copy(phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1, remoteId = "71", acknowledged = true)
        store.save(owner, c)
        reject { store.discard(owner, c.id) }
        for (bad in listOf(c.copy(channelId = "12"), c.copy(remoteId = "72"), c.copy(remoteId = null), c.copy(acknowledged = false),
            c.copy(phase = ChatActionPhase.READY), c.copy(submittedAtMillis = 2))) reject { store.save(owner, bad) }
        assertEquals(c, store.records(owner).single().checkpoint)
    }
    @Test fun `同草稿跨实例互斥其他会话和账号可继续`() {
        begin(); val second = ChatActionStore(preferences)
        reject { second.begin(ChatActionRecord(owner = owner, checkpoint = checkpoint("duplicate"))) }
        second.begin(ChatActionRecord(owner = owner, checkpoint = checkpoint("channel").copy(channelId = "12")))
        second.begin(ChatActionRecord(owner = owner.copy(identityRevision = "other"), checkpoint = checkpoint("other")))
        assertEquals(2, store.records(owner).size)
    }
    @Test fun `相同消息编辑投票删除与关闭互斥`() {
        val a = checkpoint().copy(kind = ChatActionKind.EDIT, messageId = "71")
        begin(a)
        for (b in listOf(a.copy(id = "delete", kind = ChatActionKind.DELETE),
            a.copy(id = "vote", kind = ChatActionKind.VOTE), checkpoint("close").copy(kind = ChatActionKind.CLOSE))) {
            reject { store.begin(ChatActionRecord(owner = owner, checkpoint = b)) }
        }
    }
    @Test fun `明确拒绝结束后可另起操作完成记录不可改写`() {
        val c = begin().copy(phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1)
        store.save(owner, c); val finished = c.copy(phase = ChatActionPhase.REJECTED); store.save(owner, finished)
        begin(checkpoint("retry")); reject { store.save(owner, finished.copy(phase = ChatActionPhase.SUBMITTED)) }
        store.discard(owner, c.id); assertEquals("retry", store.records(owner).single().checkpoint.id)
    }
    @Test fun `写前记录不能直接跳到成功`() {
        val c = begin(); reject { store.save(owner, c.copy(phase = ChatActionPhase.COMPLETED)) }
        store.discard(owner, c.id); assertTrue(store.records(owner).isEmpty())
    }
    @Test fun `坏记录保留原件并关闭新写`() {
        preferences.edit().putString("action:broken", "{broken").commit()
        reject { store.records(owner) }; reject { begin() }
        assertEquals("{broken", preferences.getString("action:broken", null))
    }
    @Test fun `保存失败向上传递而非当作成功`() {
        preferences.commitSucceeds = false; reject { begin() }
    }
    @Test fun `连接清理隔离其他账号并拒绝运行中的操作`() = runBlocking {
        val c = begin()
        val other = owner.copy(profileId = "other")
        store.begin(ChatActionRecord(owner = other, checkpoint = checkpoint("other-request")))
        store.execute(c.id) { reject { store.removeProfile(owner.profileId) } }
        store.removeProfile(owner.profileId)
        assertTrue(store.records(owner).isEmpty()); assertEquals(1, store.records(other).size)
    }
    @Test fun `执行中的同编号不能被另一个模型抢先恢复`() = runBlocking {
        val c = begin()
        store.execute(c.id) {
            try { ChatActionStore(preferences).execute(c.id) { fail("Must not enter") }; fail("Expected busy") } catch (_: DsmFailure) {}
            reject { store.discard(owner, c.id) }
        }
        store.discard(owner, c.id)
    }
    private fun reject(block: () -> Any?) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) {} }
}
