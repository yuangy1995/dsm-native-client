package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ChatDraftStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private val owner = WorkspaceOwner("test", "revision", "session")
    @Test fun `移除连接只清理该连接草稿批次和私有副本`() = runTest {
        val directory = temporary.newFolder(); val store = ChatDraftStore(MemoryPreferences(), directory)
        val other = owner.copy(profileId = "another")
        val draft = ChatActionDraft(ChatActionKind.ATTACHMENT, "11", attachment = UploadSource("test.bin", null, 1, { byteArrayOf(1).inputStream() }))
        store.saveAction(owner, "first", draft); store.saveAction(other, "second", draft)
        store.saveComposer(owner, "11", "first"); store.saveComposer(other, "11", "other")
        store.saveBatch(ChatBatchRecord(owner, "batch", ChatActionKind.DELETE, listOf("first")))
        store.removeProfile(owner.profileId)
        assertTrue(store.actions(owner).isEmpty()); assertTrue(store.composers(owner).isEmpty()); assertTrue(store.batches(owner).isEmpty())
        assertEquals(1, store.actions(other).size); assertEquals("other", store.composers(other)["11"])
        assertEquals(1, directory.listFiles()!!.size)
    }
    @Test fun `附件使用私有固定副本恢复不依赖原选择器`() = runTest {
        val preferences = MemoryPreferences(); val directory = temporary.newFolder(); val store = ChatDraftStore(preferences, directory)
        var bytes = byteArrayOf(1, 2, 3)
        val saved = store.saveAction(owner, "test", ChatActionDraft(ChatActionKind.ATTACHMENT, "11", text = "synthetic",
            attachment = UploadSource("test.bin", "application/octet-stream", 3, { bytes.inputStream() })))
        bytes = byteArrayOf(4)
        val reopened = ChatDraftStore(preferences, directory)
        val source = reopened.draft(checkNotNull(reopened.action(owner, "test"))).attachment!!
        assertArrayEquals(byteArrayOf(1, 2, 3), source.openInputStream().use { it.readBytes() })
        assertEquals("test.bin", source.displayName)
        assertNull(reopened.action(owner.copy(identityRevision = "another"), "test"))
        assertEquals(saved, reopened.action(owner.copy(sessionGeneration = "new"), "test"))
        reopened.removeAction(owner, "test"); assertTrue(directory.listFiles()!!.isEmpty())
    }
    @Test fun `附件长度变化不会留下半个草稿文件`() = runTest {
        val directory = temporary.newFolder(); val store = ChatDraftStore(MemoryPreferences(), directory)
        try { store.saveAction(owner, "test", ChatActionDraft(ChatActionKind.ATTACHMENT, "11",
            attachment = UploadSource("test.bin", null, 2, { byteArrayOf(1, 2, 3).inputStream() }))); fail("Expected length rejection") } catch (_: DsmFailure) {}
        assertTrue(directory.listFiles()!!.isEmpty()); assertTrue(store.actions(owner).isEmpty())
    }
    @Test fun `草稿按账号与会话隔离并可删除`() {
        val store = ChatDraftStore(MemoryPreferences(), temporary.newFolder())
        store.saveComposer(owner, "11", "first"); store.saveComposer(owner, "12", "second")
        store.saveComposer(owner.copy(identityRevision = "another"), "11", "other")
        assertEquals(mapOf("11" to "first", "12" to "second"), store.composers(owner))
        store.saveComposer(owner, "11", ""); assertEquals(mapOf("12" to "second"), store.composers(owner))
    }
    @Test fun `存储失败和坏记录必须报告而不假装空草稿`() {
        val preferences = MemoryPreferences(); val store = ChatDraftStore(preferences, temporary.newFolder())
        preferences.commitSucceeds = false
        try { store.saveComposer(owner, "11", "text"); fail("Expected storage failure") } catch (_: DsmFailure) {}
        preferences.edit().putString("action:broken", "{broken").apply()
        try { store.actions(owner); fail("Expected corrupt record failure") } catch (_: DsmFailure) {}
        assertEquals("{broken", preferences.getString("action:broken", null))
    }
}
