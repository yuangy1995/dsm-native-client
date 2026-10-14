package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import org.junit.Assert.*
import org.junit.Test

class ContainerNetworkStoreTest {
    private val preferences = MemoryPreferences(); private val store = ContainerNetworkStore(preferences)
    private val owner = WorkspaceOwner("synthetic-profile", "identity", "generation")
    private val draft = ContainerNetworkDraft("Sensitive-network", true, "192.0.2.0/24", "", "192.0.2.1")
    private fun record() = ContainerNetworkActivity("synthetic-record", owner, ContainerNetworkOperation.CREATE, listOf(ContainerNetworkItem(draft.identity())))
    @Test fun `名称地址只存摘要未知不可清理同名操作互斥`() {
        store.begin(record()); assertFalse(preferences.all.toString().contains("Sensitive-network")); assertFalse(preferences.all.toString().contains("192.0.2"))
        assertTrue(runCatching { store.begin(record().copy(id = "second")) }.isFailure); assertTrue(runCatching { store.dismiss(owner, record().id) }.isFailure)
    }
    @Test fun `新代次只读恢复不能添加接受事实`() {
        store.begin(record()); store.checkpoint(owner, record().id, 0, ContainerStage.SUBMITTED); val new = owner.copy(sessionGeneration = "fresh")
        assertTrue(runCatching { store.checkpoint(new, record().id, 0, ContainerStage.ACCEPTED) }.isFailure)
        store.checkpoint(new, record().id, 0, ContainerStage.VERIFIED); assertFalse(store.records(new).single().items.single().accepted)
    }
    @Test fun `已拒绝不可被后来的网络覆盖损坏记录不覆盖`() {
        store.begin(record()); store.checkpoint(owner, record().id, 0, ContainerStage.SUBMITTED); store.checkpoint(owner, record().id, 0, ContainerStage.REJECTED)
        assertTrue(runCatching { store.checkpoint(owner, record().id, 0, ContainerStage.VERIFIED) }.isFailure)
        preferences.edit().putString("network:broken", "bad-json").commit(); assertTrue(runCatching { store.records(owner) }.isFailure)
    }
}
