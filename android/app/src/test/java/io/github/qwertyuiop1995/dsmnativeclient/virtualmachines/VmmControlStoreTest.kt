package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import org.junit.Assert.*
import org.junit.Test

class VmmControlStoreTest {
    private val preferences = MemoryPreferences(); private val store = VmmControlStore(preferences)
    private val owner = WorkspaceOwner("synthetic-profile", "synthetic-identity", "synthetic-generation")
    private fun record() = VmmControlActivity("synthetic-record", owner, VmmAction.START,
        listOf(VmmControlItem(vmmDigest("sensitive-id"), vmmDigest("sensitive-identity"), vmmDigest("Sensitive name"), VmmSource.PUBLIC)))
    @Test fun `摘要跨实例跨会话恢复且账号隔离`() {
        store.begin(record()); store.checkpoint(owner, record().id, 0, VmmStage.SUBMITTED)
        val encoded = preferences.all.toString(); assertFalse(encoded.contains("Sensitive name")); assertFalse(encoded.contains("sensitive-id"))
        assertEquals(VmmStage.SUBMITTED, VmmControlStore(preferences).records(owner.copy(sessionGeneration = "new")).single().items.single().stage)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty())
    }
    @Test fun `缺回执与明确拒绝均不能因外部变化认领完成`() {
        store.begin(record()); store.checkpoint(owner, record().id, 0, VmmStage.SUBMITTED)
        assertTrue(runCatching { store.checkpoint(owner, record().id, 0, VmmStage.VERIFIED) }.isFailure)
        assertTrue(runCatching { store.dismiss(owner, record().id) }.isFailure)
        store.checkpoint(owner, record().id, 0, VmmStage.REJECTED)
        assertTrue(runCatching { store.checkpoint(owner, record().id, 0, VmmStage.VERIFIED) }.isFailure)
    }
    @Test fun `新代次不能伪造旧回执已接受可以只读完成`() {
        store.begin(record()); store.checkpoint(owner, record().id, 0, VmmStage.SUBMITTED)
        val renewed = owner.copy(sessionGeneration = "new")
        assertTrue(runCatching { store.checkpoint(renewed, record().id, 0, VmmStage.ACCEPTED) }.isFailure)
        store.checkpoint(owner, record().id, 0, VmmStage.ACCEPTED); store.checkpoint(renewed, record().id, 0, VmmStage.VERIFIED)
        store.dismiss(renewed, record().id); assertTrue(store.records(owner).isEmpty())
    }
    @Test fun `损坏记录与失败保存持续保护不可覆盖`() {
        preferences.edit().putString("control:broken", "not-json").commit()
        assertTrue(runCatching { store.records(owner) }.isFailure); preferences.edit().clear().commit()
        assertTrue(runCatching { store.begin(record()) }.isFailure)
        val next = VmmControlStore(preferences); preferences.commitSucceeds = false
        assertTrue(runCatching { next.begin(record()) }.isFailure); preferences.commitSucceeds = true
        assertTrue(runCatching { next.records(owner) }.isFailure)
    }
}
