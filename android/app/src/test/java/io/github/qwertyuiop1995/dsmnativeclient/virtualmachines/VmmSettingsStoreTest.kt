package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import org.junit.Assert.*
import org.junit.Test

class VmmSettingsStoreTest {
    private val preferences = MemoryPreferences(); private val store = VmmSettingsStore(preferences)
    private val owner = WorkspaceOwner("profile", "identity", "generation")
    private fun record(id: String = "record") = VmmSettingsActivity(id, owner, vmmDigest("target"), vmmDigest("old"), vmmDigest("new"), vmmDigest("configuration"), VmmSource.INTERNAL)
    @Test fun `只能按提交接受完成阶段且缺回执禁止完成`() {
        store.begin(record()); assertTrue(runCatching { store.checkpoint(owner, "record", VmmStage.ACCEPTED) }.isFailure)
        store.checkpoint(owner, "record", VmmStage.SUBMITTED)
        assertTrue(runCatching { store.checkpoint(owner, "record", VmmStage.VERIFIED) }.isFailure)
        assertTrue(runCatching { store.dismiss(owner, "record") }.isFailure)
        store.checkpoint(owner, "record", VmmStage.ACCEPTED); store.checkpoint(owner, "record", VmmStage.VERIFIED)
        assertTrue(runCatching { store.checkpoint(owner, "record", VmmStage.SUBMITTED) }.isFailure)
        store.dismiss(owner, "record"); assertTrue(store.records(owner).isEmpty())
    }
    @Test fun `重登录不能补记接受但可只读恢复已接受记录`() {
        store.begin(record()); store.checkpoint(owner, "record", VmmStage.SUBMITTED)
        val renewed = owner.copy(sessionGeneration = "renewed")
        assertTrue(runCatching { store.checkpoint(renewed, "record", VmmStage.ACCEPTED) }.isFailure)
        store.checkpoint(owner, "record", VmmStage.ACCEPTED); store.checkpoint(renewed, "record", VmmStage.VERIFIED)
        assertEquals(VmmStage.VERIFIED, store.records(renewed).single().stage)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty())
    }
    @Test fun `原ID及未结束新名称保护其他VM不被全局阻塞`() {
        store.begin(record()); assertTrue(runCatching { store.begin(record("second")) }.isFailure)
        assertTrue(runCatching { store.begin(record("second").copy(target = vmmDigest("other"))) }.isFailure)
        store.begin(record("second").copy(target = vmmDigest("other"), desiredName = vmmDigest("different")))
        assertEquals(2, store.records(owner).size)
    }
    @Test fun `损坏记录和落盘失败不可通过忽略记录解锁`() {
        preferences.commitSucceeds = false; assertTrue(runCatching { store.begin(record()) }.isFailure)
        preferences.commitSucceeds = true; assertTrue(runCatching { store.records(owner) }.isFailure)
        preferences.edit().putString("settings:broken", "{}").commit()
        assertTrue(runCatching { VmmSettingsStore(preferences).records(owner) }.isFailure)
    }
}
