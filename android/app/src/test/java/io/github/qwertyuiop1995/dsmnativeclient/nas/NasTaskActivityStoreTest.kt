package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class NasTaskActivityStoreTest {
    private val preferences = MemoryPreferences()
    private val store = NasTaskActivityStore(preferences)
    private val owner = WorkspaceOwner("synthetic-tasks", "identity", "session")
    private fun record(id: String = "record") = taskRecord(id, owner, NasTaskChange(NasTaskAction.CREATE,
        original = NasTaskDraft(owner = "Private account"), desired = NasTaskDraft(name = "Private task", owner = "Private account", script = "Private script", notificationEmails = "private@example.invalid")), listOf(10))
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: Exception) { } }
    @Test fun `记录只保存身份摘要恢复跨会话但隔离其他账号`() {
        store.begin(record()); val raw = preferences.all.values.joinToString()
        assertFalse(raw.contains("Private")); assertFalse(raw.contains("private@example.invalid"))
        assertEquals(1, store.records(owner.copy(sessionGeneration = "next")).size)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty())
        assertEquals(listOf(10L), store.records(owner).single().existingIds)
    }
    @Test fun `创建运行接受必须单独落盘未知不能删除或重发`() {
        store.begin(record()); rejected { store.begin(record("other")) }; rejected { store.discard(owner, "record") }
        rejected { store.checkpoint(owner, "record", NasTaskStage.COMPLETED) }
        store.checkpoint(owner, "record", NasTaskStage.ACCEPTED); rejected { store.checkpoint(owner, "record", NasTaskStage.REJECTED) }
        store.checkpoint(owner, "record", NasTaskStage.COMPLETED); store.discard(owner, "record")
        store.begin(record().copy(action = NasTaskAction.RUN, taskId = 10, existingIds = emptyList()))
        rejected { store.checkpoint(owner, "record", NasTaskStage.COMPLETED) }; assertFalse(store.records(owner).single().terminal)
    }
    @Test fun `明确拒绝可移除损坏记录保持证据写入失败持续关闭`() {
        store.begin(record()); store.checkpoint(owner, "record", NasTaskStage.REJECTED); store.discard(owner, "record")
        preferences.edit().putString("scheduled:bad", "{broken").commit(); rejected { store.records(owner) }; rejected { store.begin(record()) }
        assertEquals("{broken", preferences.getString("scheduled:bad", null))
        val failedPreferences = MemoryPreferences(); val failedStore = NasTaskActivityStore(failedPreferences)
        failedPreferences.commitSucceeds = false; rejected { failedStore.begin(record()) }; failedPreferences.commitSucceeds = true
        rejected { failedStore.records(owner) }
    }
    @Test fun `同连接跨实例互斥执行期间不可移除连接`() = runBlocking {
        store.execute(owner) {
            rejected { store.removeProfile(owner.profileId) }
            try { NasTaskActivityStore(MemoryPreferences()).execute(owner) { fail() }; fail() } catch (_: NasTaskFailure) { }
        }
        store.execute(owner) { assertTrue(store.records(owner).isEmpty()) }
    }
}
