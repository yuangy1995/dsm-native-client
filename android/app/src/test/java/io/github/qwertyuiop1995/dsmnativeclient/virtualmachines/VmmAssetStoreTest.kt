package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class VmmAssetStoreTest {
    private val preferences = MemoryPreferences(); private val store = VmmAssetStore(preferences)
    private val owner = WorkspaceOwner("synthetic", "identity", "generation")
    private fun record() = VmmAssetActivity("record", owner, VmmAssetKind.NETWORK, VmmAssetAction.RENAME,
        listOf(VmmAssetItem(vmmDigest("network-id"), vmmDigest("network-identity"), vmmDigest("Private network name"), VmmSource.INTERNAL,
            vmmDigest("private-topology"), vmmDigest("New network name"), setOf(vmmDigest("guest-id")))))
    @Test fun `记录摘要关联和阶段跨实例恢复不保留原字段`() {
        store.begin(record()); store.checkpoint(owner, "record", 0, VmmStage.SUBMITTED); store.checkpoint(owner, "record", 0, VmmStage.ACCEPTED)
        val raw = preferences.all.toString(); for (value in listOf("Private network name", "New network name", "private-topology", "guest-id")) assertFalse(raw.contains(value))
        val renewed = owner.copy(sessionGeneration = "new"); val next = VmmAssetStore(preferences)
        assertEquals(VmmStage.ACCEPTED, next.records(renewed).single().items.single().stage)
        next.checkpoint(renewed, "record", 0, VmmStage.VERIFIED); next.dismiss(renewed, "record"); assertTrue(next.records(renewed).isEmpty())
    }
    @Test fun `未知不可清理不能伪造完成已拒绝不回退`() {
        store.begin(record()); store.checkpoint(owner, "record", 0, VmmStage.SUBMITTED)
        assertTrue(runCatching { store.dismiss(owner, "record") }.isFailure)
        assertTrue(runCatching { store.checkpoint(owner, "record", 0, VmmStage.VERIFIED) }.isFailure)
        store.checkpoint(owner, "record", 0, VmmStage.REJECTED)
        assertTrue(runCatching { store.checkpoint(owner, "record", 0, VmmStage.ACCEPTED) }.isFailure)
    }
    @Test fun `独立记录文件执行和移除共用工作区锁`() = runBlocking {
        val controls = VmmControlStore(MemoryPreferences())
        store.execute(owner) {
            assertTrue(runCatching { controls.execute(owner) {} }.isFailure)
            assertTrue(runCatching { controls.removeProfile(owner.profileId) }.isFailure)
        }
        controls.execute(owner) {}; store.removeProfile(owner.profileId)
    }
    @Test fun `跨页只读刷新等待当前执行结束后重新检查归属`() = runBlocking {
        val controls = VmmControlStore(MemoryPreferences()); var read = false
        lateinit var reader: Deferred<Unit>
        store.execute(owner) {
            reader = async(start = CoroutineStart.UNDISPATCHED) { controls.execute(owner, wait = true) { read = true } }
            assertFalse(read)
        }
        withTimeout(2_000) { reader.await() }; assertTrue(read)
    }
    @Test fun `同对象与同目标名称不能绕过保护不同对象可独立操作`() {
        store.begin(record())
        assertTrue(runCatching { store.begin(record().copy(id = "second")) }.isFailure)
        assertTrue(runCatching { store.begin(record().copy(id = "second", items = listOf(record().items.single().copy(id = vmmDigest("other-id"))))) }.isFailure)
        store.begin(record().copy(id = "second", items = listOf(record().items.single().copy(id = vmmDigest("other-id"), desiredName = vmmDigest("Other name")))))
        assertEquals(2, store.records(owner).size)
    }
}
