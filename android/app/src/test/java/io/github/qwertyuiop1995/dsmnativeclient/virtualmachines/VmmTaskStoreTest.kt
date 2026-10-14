package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class VmmTaskStoreTest {
    private val preferences = MemoryPreferences(); private val store = VmmTaskStore(preferences)
    private val owner = WorkspaceOwner("synthetic", "identity", "generation")
    private fun import() = VmmImportActivity(UUID.randomUUID().toString(), owner, VmmImportSnapshot(vmmDigest("Private name"), vmmDigest("private name"), "disk", setOf(vmmDigest("old-image"))))
    private fun cleanup() = VmmTaskClearActivity(UUID.randomUUID().toString(), owner, listOf(VmmTaskClearItem(vmmDigest("private-task"), vmmDigest("private-response"))))
    @Test fun `导入仅保存摘要和任务标识同身份冷恢复可完成不同身份不可读取`() {
        val record = import(); store.begin(record)
        store.checkpoint(owner, record.id, VmmImportProgress(VmmStage.SUBMITTED))
        store.checkpoint(owner, record.id, VmmImportProgress(VmmStage.ACCEPTED, "task-1"))
        val next = VmmTaskStore(preferences); val renewed = owner.copy(sessionGeneration = "next")
        val saved = next.imports(renewed).single(); assertEquals("task-1", saved.progress.task)
        assertTrue(next.imports(owner.copy(identityRevision = "other")).isEmpty())
        for (secret in listOf("Private name", "private name", "old-image")) assertFalse(preferences.all.toString().contains(secret))
        next.checkpoint(renewed, record.id, saved.progress.copy(stage = VmmStage.VERIFIED, image = vmmDigest("new-image")))
        next.dismissImport(renewed, record.id); assertTrue(next.imports(owner).isEmpty())
    }
    @Test fun `缺回执不可跨登录补造接受不可跳成功或移除`() {
        val record = import(); store.begin(record); store.checkpoint(owner, record.id, VmmImportProgress(VmmStage.SUBMITTED))
        assertTrue(runCatching { store.checkpoint(owner.copy(sessionGeneration = "next"), record.id, VmmImportProgress(VmmStage.ACCEPTED, "task")) }.isFailure)
        assertTrue(runCatching { store.checkpoint(owner, record.id, VmmImportProgress(VmmStage.VERIFIED, "task", vmmDigest("new"))) }.isFailure)
        assertTrue(runCatching { store.dismissImport(owner, record.id) }.isFailure)
        assertTrue(runCatching { store.begin(import()) }.isFailure)
    }
    @Test fun `逐项清理记录严格阶段并保护重复任务`() {
        val record = cleanup(); store.begin(record)
        assertTrue(runCatching { store.begin(cleanup()) }.isFailure)
        store.checkpoint(owner, record.id, 0, VmmStage.SUBMITTED)
        assertTrue(runCatching { store.checkpoint(owner, record.id, 0, VmmStage.VERIFIED) }.isFailure)
        assertTrue(runCatching { store.dismissCleanup(owner, record.id) }.isFailure)
        store.checkpoint(owner, record.id, 0, VmmStage.ACCEPTED)
        val next = VmmTaskStore(preferences); val renewed = owner.copy(sessionGeneration = "next")
        next.checkpoint(renewed, record.id, 0, VmmStage.VERIFIED); next.dismissCleanup(renewed, record.id)
        assertTrue(next.cleanups(owner).isEmpty()); assertFalse(preferences.all.toString().contains("private-task"))
    }
    @Test fun `记录损坏落盘失败和原任务变更都不能绕过保护`() {
        val record = import(); store.begin(record); store.checkpoint(owner, record.id, VmmImportProgress(VmmStage.SUBMITTED)); store.checkpoint(owner, record.id, VmmImportProgress(VmmStage.ACCEPTED, "task"))
        assertTrue(runCatching { store.checkpoint(owner, record.id, VmmImportProgress(VmmStage.ACCEPTED, "another")) }.isFailure)
        preferences.commitSucceeds = false
        assertTrue(runCatching { store.checkpoint(owner, record.id, VmmImportProgress(VmmStage.VERIFIED, "task", vmmDigest("new"))) }.isFailure)
        preferences.commitSucceeds = true; assertTrue(runCatching { store.imports(owner) }.isFailure)
        preferences.edit().putString("clear:broken", "{}").commit(); assertTrue(runCatching { VmmTaskStore(preferences).cleanups(owner) }.isFailure)
    }
    @Test fun `未发送恢复取消并与其他VMM操作共用锁`() = runBlocking {
        val record = import(); store.begin(record)
        store.checkpoint(owner.copy(sessionGeneration = "next"), record.id, VmmImportProgress(VmmStage.CANCELLED))
        val other = VmmAssetStore(MemoryPreferences())
        store.execute(owner) { assertTrue(runCatching { other.execute(owner) {} }.isFailure); assertTrue(runCatching { store.removeProfile(owner.profileId) }.isFailure) }
        store.removeProfile(owner.profileId); assertTrue(store.imports(owner).isEmpty())
    }
}
