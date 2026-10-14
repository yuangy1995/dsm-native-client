package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class NasDirectoryActivityStoreTest {
    private val preferences = MemoryPreferences()
    private val store = NasDirectoryActivityStore(preferences)
    private val owner = WorkspaceOwner("synthetic", "identity", "session")
    private fun record(id: String = "record", ack: Boolean = false) = directoryRecord(id, owner, NasDirectoryChange(
        NasDirectoryKind.ACCOUNT, if (ack) NasDirectoryAction.CREATE else NasDirectoryAction.EDIT, "synthetic-name",
        "synthetic-description", "synthetic@example.invalid", password = if (ack) "synthetic-password" else ""))
    @Test fun `原账号恢复且名称邮箱组关系密码不持久化`() {
        store.begin(record(ack = true)); store.checkpoint(owner, "record", NasDirectoryStage.ACCEPTED)
        val raw = preferences.all.values.joinToString()
        for (value in listOf("synthetic-name", "synthetic-description", "synthetic@example.invalid", "synthetic-password")) assertFalse(raw.contains(value))
        assertTrue(NasDirectoryActivityStore(preferences).records(owner.copy(sessionGeneration = "next")).single().accepted)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty()); assertTrue(store.records(owner.copy(profileId = "other")).isEmpty())
    }
    @Test fun `未知记录不能删除或再次提交且改密须有接受回执`() {
        store.begin(record(ack = true)); rejected { store.discard(owner, "record") }; rejected { store.begin(record("other")) }
        rejected { store.checkpoint(owner, "record", NasDirectoryStage.COMPLETED) }; rejected { store.checkpoint(owner, "record", NasDirectoryStage.SUBMITTED) }
        store.checkpoint(owner, "record", NasDirectoryStage.ACCEPTED); rejected { store.checkpoint(owner, "record", NasDirectoryStage.REJECTED) }
        store.checkpoint(owner, "record", NasDirectoryStage.COMPLETED); store.discard(owner, "record"); assertTrue(store.records(owner).isEmpty())
    }
    @Test fun `明确拒绝可以移除但损坏不能清掉证据`() {
        store.begin(record()); store.checkpoint(owner, "record", NasDirectoryStage.REJECTED); store.discard(owner, "record")
        preferences.edit().putString("directory:bad", "{broken").commit(); rejected { store.records(owner) }; rejected { store.begin(record()) }
        assertEquals("{broken", preferences.getString("directory:bad", null))
    }
    @Test fun `落盘失败保持保护跨实例互斥`() = runBlocking {
        preferences.commitSucceeds = false; rejected { store.begin(record()) }; preferences.commitSucceeds = true; rejected { store.records(owner) }
        val separate = NasDirectoryActivityStore(MemoryPreferences())
        separate.execute(owner) {
            rejected { separate.removeProfile(owner.profileId) }
            try { NasDirectoryActivityStore(MemoryPreferences()).execute(owner) { fail() }; fail() } catch (_: NasDirectoryFailure) { }
        }
    }
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: Exception) { } }
}
