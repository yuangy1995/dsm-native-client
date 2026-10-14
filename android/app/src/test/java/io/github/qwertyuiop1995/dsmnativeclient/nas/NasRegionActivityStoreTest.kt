package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class NasRegionActivityStoreTest {
    private val preferences = MemoryPreferences(); private val store = NasRegionActivityStore(preferences)
    private val owner = WorkspaceOwner("synthetic-region", "identity", "session")
    private fun record(id: String = "record", manual: Boolean = false, syncOnly: Boolean = false) = NasRegionRecord(id, owner, "a".repeat(64),
        if (syncOnly) listOf(NasRegionStepRecord(NasRegionStep.SYNCHRONIZATION)) else listOf(NasRegionStepRecord(NasRegionStep.CONFIGURATION)),
        if (manual) 1234 else null)
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) {} }
    @Test fun `摘要记录隔离账号跨会话读取未决不能丢弃或重复保存`() {
        store.begin(record()); assertEquals(1, store.records(owner.copy(sessionGeneration = "next")).size)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty())
        rejected { store.begin(record("second")) }; rejected { store.discard(owner, "record") }
        assertFalse(preferences.all.values.joinToString().contains("server"))
    }
    @Test fun `手动改时和校时没有接受回执无法标记完成且拒绝不可改成功`() {
        for (sync in listOf(false, true)) {
            val prefs = MemoryPreferences(); val target = NasRegionActivityStore(prefs); val record = record(manual = !sync, syncOnly = sync)
            target.begin(record); val step = record.steps.single().step
            target.checkpoint(owner, record.id, NasRegionCheckpoint(step, NasServiceStage.SUBMITTED))
            rejected { target.checkpoint(owner, record.id, NasRegionCheckpoint(step, NasServiceStage.VERIFIED)) }
            target.checkpoint(owner, record.id, NasRegionCheckpoint(step, NasServiceStage.REJECTED))
            rejected { target.checkpoint(owner, record.id, NasRegionCheckpoint(step, NasServiceStage.VERIFIED)) }
            target.discard(owner, record.id); assertTrue(target.records(owner).isEmpty())
        }
    }
    @Test fun `只在显式新校时保留并取代未知校时历史`() {
        store.begin(record(syncOnly = true)); store.checkpoint(owner, "record", NasRegionCheckpoint(NasRegionStep.SYNCHRONIZATION, NasServiceStage.SUBMITTED))
        rejected { store.begin(record("save")) }
        store.begin(record("new-sync", syncOnly = true))
        assertEquals("new-sync", store.records(owner).single { it.id == "record" }.supersededBy)
        assertEquals(NasServiceStage.SUBMITTED, store.records(owner).single { it.id == "record" }.steps.single().stage)
        rejected { store.checkpoint(owner, "record", NasRegionCheckpoint(NasRegionStep.SYNCHRONIZATION, NasServiceStage.ACCEPTED)) }
    }
    @Test fun `落盘失败损坏和跨实例互斥保护记录`() = runBlocking {
        preferences.commitSucceeds = false; rejected { store.begin(record()) }; preferences.commitSucceeds = true; rejected { store.records(owner) }
        val prefs = MemoryPreferences(); prefs.edit().putString("region:bad", "{broken").commit()
        rejected { NasRegionActivityStore(prefs).records(owner) }; assertEquals("{broken", prefs.getString("region:bad", null))
        val clean = NasRegionActivityStore(MemoryPreferences())
        clean.execute(owner) {
            rejected { clean.removeProfile(owner.profileId) }
            try { NasRegionActivityStore(MemoryPreferences()).execute(owner) { fail() }; fail() } catch (_: DsmFailure) {}
        }
    }
}
