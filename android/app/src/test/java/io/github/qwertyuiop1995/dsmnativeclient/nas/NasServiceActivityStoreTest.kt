package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class NasServiceActivityStoreTest {
    private val preferences = MemoryPreferences(); private val store = NasServiceActivityStore(preferences)
    private val owner = WorkspaceOwner("synthetic-service", "identity", "session")
    private fun record(id: String = "record") = NasServiceRecord(id, owner, NasServiceKind.PROXY, listOf(NasServiceStepRecord(NasServiceStep.PROXY, "a".repeat(64))))
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) {} }
    @Test fun `记录只有摘要同账号跨会话可恢复其他账号隔离`() {
        store.begin(record()); assertEquals(1, store.records(owner.copy(sessionGeneration = "next")).size)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty())
        val raw = preferences.all.values.joinToString(); assertFalse(raw.contains("http_host")); assertFalse(raw.contains("http_port"))
        rejected { store.begin(record("duplicate")) }; rejected { store.discard(owner, "record") }
    }
    @Test fun `逐组阶段未知不可丢弃明确拒绝不能改成功`() {
        store.begin(record()); rejected { store.checkpoint(owner, "record", NasServiceCheckpoint(NasServiceStep.PROXY, NasServiceStage.VERIFIED)) }
        store.checkpoint(owner, "record", NasServiceCheckpoint(NasServiceStep.PROXY, NasServiceStage.SUBMITTED))
        rejected { store.discard(owner, "record") }
        store.checkpoint(owner, "record", NasServiceCheckpoint(NasServiceStep.PROXY, NasServiceStage.REJECTED))
        rejected { store.checkpoint(owner, "record", NasServiceCheckpoint(NasServiceStep.PROXY, NasServiceStage.VERIFIED)) }
        store.discard(owner, "record"); assertTrue(store.records(owner).isEmpty())
    }
    @Test fun `损坏和写入失败保持关闭不删除记录`() {
        preferences.edit().putString("service:bad", "{broken").commit(); rejected { store.records(owner) }; rejected { store.begin(record()) }
        assertEquals("{broken", preferences.getString("service:bad", null))
        val prefs = MemoryPreferences(); val failedStore = NasServiceActivityStore(prefs); prefs.commitSucceeds = false
        rejected { failedStore.begin(record()) }; prefs.commitSucceeds = true; rejected { failedStore.records(owner) }
    }
    @Test fun `同服务跨实例互斥且执行期间不能移除连接`() = runBlocking {
        store.execute(owner, NasServiceKind.PROXY) {
            rejected { store.removeProfile(owner.profileId) }
            try { NasServiceActivityStore(MemoryPreferences()).execute(owner, NasServiceKind.PROXY) { fail() }; fail() } catch (_: DsmFailure) {}
        }
        store.execute(owner, NasServiceKind.PROXY) { assertTrue(store.records(owner).isEmpty()) }
    }
}
