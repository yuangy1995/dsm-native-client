package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.util.concurrent.Executors
import org.junit.Assert.*
import org.junit.Test

class FolderUploadPlanStoreTest {
    private val preferences = MemoryPreferences()
    private val store = TransferStore(preferences)
    private val task = PersistedUpload("folder-task", "profile-a", "content://fixture/tree/root", "Root ",
        expectedBytes = 3, destinationPath = "/synthetic", sourceTreeUri = "content://fixture/tree/root",
        backupMode = false, mirrorDirectories = true, workId = "worker-a")
    private val plan = FolderUploadPlan(taskId = task.id, profileId = task.profileId, treeUri = task.sourceUri,
        destinationPath = task.destinationPath, entries = listOf(
            FolderUploadEntry(FolderUploadSource("root", task.sourceUri, "Root ", true)),
            FolderUploadEntry(FolderUploadSource("empty", "content://fixture/empty", "Root /Empty", true)),
            FolderUploadEntry(FolderUploadSource("file", "content://fixture/file", "Root /a.txt ", false, "text/plain", 3)),
        ))

    @Test fun `独立计划跨实例保留根空目录与未裁剪来源并兼容旧上传`() {
        val legacy = task.copy(id = "legacy", sourceUri = "content://fixture/legacy", sourceTreeUri = null, mirrorDirectories = false)
        store.upsert(legacy)
        assertTrue(store.createFolderUploadDurably(task, plan))
        val restored = TransferStore(preferences)
        assertEquals(plan, restored.folderUploadPlan(task.id))
        assertEquals(legacy, restored.upload(legacy.id))
        assertNull(restored.folderUploadPlan(legacy.id))
        assertEquals(3, plan.totalBytes)
        assertEquals("Root ", plan.rootName)
    }

    @Test fun `提交阶段与任务未定标记在同一次保存中更新`() {
        assertTrue(store.createFolderUploadDurably(task, plan))
        val saved = store.updateFolderUploadPlan(task.id, "worker-a") {
            it.copy(entries = it.entries.map { entry -> if (entry.source.id == "file") entry.copy(state = FolderUploadEntryState.SUBMITTING) else entry })
        }
        assertTrue(checkNotNull(store.upload(task.id)).requiresRefresh)
        assertTrue(checkNotNull(saved).requiresRefresh)
        assertEquals(FolderUploadEntryState.UNRESOLVED, saved.recoveringInterruptedEntries().entries.last().state)
        assertEquals(FolderUploadEntryState.PENDING, saved.recoveringInterruptedEntries().entries.first().state)
    }

    @Test fun `跨实例并发建立相同来源目标仅一个成功且保留其他账号`() {
        val executor = Executors.newFixedThreadPool(2)
        try {
            val outcomes = (1..2).map { number -> executor.submit<Boolean> {
                val id = "task-$number"
                TransferStore(preferences).createFolderUploadDurably(task.copy(id = id), plan.copy(taskId = id))
            } }.map { it.get() }
            assertEquals(1, outcomes.count { it })
            assertTrue(store.createFolderUploadDurably(task.copy(id = "other-account", profileId = "profile-b"), plan.copy(taskId = "other-account", profileId = "profile-b")))
            assertEquals(1, store.uploads("profile-a").size)
            assertEquals(1, store.uploads("profile-b").size)
        } finally { executor.shutdownNow() }
    }

    @Test fun `换执行器和目标后旧写入不能覆盖计划`() {
        assertTrue(store.createFolderUploadDurably(task, plan))
        store.upsert(task.copy(workId = "worker-b"))
        assertNull(store.updateFolderUploadPlan(task.id, "worker-a") { error("旧执行器不得进入转换") })
        assertEquals(plan, store.folderUploadPlan(task.id))
        store.upsert(task.copy(profileId = "profile-b"))
        assertThrows(IOException::class.java) { store.folderUploadPlan(task.id) }
    }

    @Test fun `恢复不能更换来源或扩大目录范围`() {
        assertTrue(store.createFolderUploadDurably(task, plan))
        assertThrows(IllegalArgumentException::class.java) {
            store.updateFolderUploadPlan(task.id, "worker-a") {
                it.copy(entries = it.entries + FolderUploadEntry(FolderUploadSource("extra", "content://fixture/new", "Root /new.txt", false)))
            }
        }
        assertEquals(plan, store.folderUploadPlan(task.id))
    }

    @Test fun `提交后未知的终态任务不能清理而完成任务同时移除计划`() {
        assertTrue(store.createFolderUploadDurably(task, plan))
        store.updateFolderUploadPlan(task.id, "worker-a") {
            it.copy(entries = it.entries.map { entry -> entry.copy(state = FolderUploadEntryState.UNRESOLVED) })
        }
        store.updateUpload(task.id) { it.copy(state = TransferState.FAILED) }
        store.removeTerminal(task.profileId)
        assertNotNull(store.folderUploadPlan(task.id))
        store.updateFolderUploadPlan(task.id, "worker-a") {
            it.copy(entries = it.entries.map { entry -> entry.copy(state = FolderUploadEntryState.SUCCEEDED, completedBytes = entry.source.bytes) })
        }
        store.updateUpload(task.id) { it.copy(state = TransferState.SUCCEEDED) }
        store.removeTerminal(task.profileId)
        assertNull(store.upload(task.id))
        assertNull(store.folderUploadPlan(task.id))
    }

    @Test fun `保存失败不能返回可入队或可继续提交的结果`() {
        preferences.commitSucceeds = false
        assertFalse(store.createFolderUploadDurably(task, plan))
        assertThrows(IOException::class.java) { store.updateFolderUploadPlan(task.id, "worker-a") { it } }
    }

    @Test fun `计划损坏不能降级成普通文件上传`() {
        assertTrue(store.createFolderUploadDurably(task, plan))
        val key = preferences.all.keys.single { it.startsWith("folder_upload_plan_v1_") }
        preferences.edit().putString(key, "{").commit()
        assertThrows(IOException::class.java) { store.folderUploadPlan(task.id) }
        assertNotNull(store.upload(task.id))
    }
}
