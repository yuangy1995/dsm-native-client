package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerAction
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import org.junit.Assert.*
import org.junit.Test

class ContainerControlStoreTest {
    private val preferences = MemoryPreferences(); private val store = ContainerControlStore(preferences)
    private val owner = WorkspaceOwner("synthetic-profile", "synthetic-identity", "synthetic-generation")
    private fun record() = ContainerControlActivity("synthetic-record", owner, ContainerAction.START,
        listOf(ContainerControlItem(containerDigest("sensitive-id"), containerDigest("sensitive-identity"), containerDigest("Sensitive name"), null)))
    @Test fun `记录只保留摘要新实例与新会话读取同身份`() {
        store.begin(record()); store.checkpoint(owner, record().id, 0, ContainerStage.SUBMITTED)
        val encoded = preferences.all.toString(); assertFalse(encoded.contains("Sensitive name")); assertFalse(encoded.contains("sensitive-id"))
        val renewed = owner.copy(sessionGeneration = "new-generation")
        assertEquals(ContainerStage.SUBMITTED, ContainerControlStore(preferences).records(renewed).single().items.single().stage)
    }
    @Test fun `跨代次不能伪造接受但可以只读完成未知项`() {
        store.begin(record()); store.checkpoint(owner, record().id, 0, ContainerStage.SUBMITTED)
        val renewed = owner.copy(sessionGeneration = "new-generation")
        assertTrue(runCatching { store.checkpoint(renewed, record().id, 0, ContainerStage.ACCEPTED) }.isFailure)
        store.checkpoint(renewed, record().id, 0, ContainerStage.VERIFIED)
        store.dismiss(renewed, record().id); assertTrue(store.records(owner).isEmpty())
    }
    @Test fun `未知项不能清理终态不能被后来的状态覆盖`() {
        store.begin(record()); assertTrue(runCatching { store.dismiss(owner, record().id) }.isFailure)
        store.checkpoint(owner, record().id, 0, ContainerStage.SUBMITTED); store.checkpoint(owner, record().id, 0, ContainerStage.REJECTED)
        assertTrue(runCatching { store.checkpoint(owner, record().id, 0, ContainerStage.VERIFIED) }.isFailure)
    }
    @Test fun `损坏与提交失败持续阻止覆盖`() {
        preferences.edit().putString("control:broken", "not-json").commit()
        assertTrue(runCatching { store.records(owner) }.isFailure); assertTrue(runCatching { store.begin(record()) }.isFailure)
        preferences.edit().remove("control:broken").commit(); assertTrue(runCatching { store.begin(record()) }.isFailure)
    }
}
