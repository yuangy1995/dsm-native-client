package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoBackgroundStoreTest {
    private val owner = WorkspaceOwner("background-profile", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = SynologyPhotoAlbumStore(preferences)
    private fun task(id: Long = 91, done: Boolean = false) = SynologyPhotoBackgroundSnapshot(id, "copy",
        if (done) SynologyPhotoBackgroundStatus.DONE else SynologyPhotoBackgroundStatus.PROCESSING, 10, 100.5, 20, 0)
    private fun row(clearing: Boolean = false, tasks: List<SynologyPhotoBackgroundSnapshot> = listOf(task(done = clearing))) = SynologyPhotoAlbumRecord(
        owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = if (clearing) SynologyPhotoAlbumAction.CLEAR_TASKS else SynologyPhotoAlbumAction.STOP_TASK,
            background = SynologyPhotoBackgroundCheckpoint(tasks)))
    private fun pending(record: SynologyPhotoAlbumRecord, attempted: Set<Long>): SynologyPhotoAlbumRecord {
        store.begin(record)
        store.save(record.id, owner, 41, record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        return store.save(record.id, owner, 41, record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING,
            background = record.checkpoint.background!!.copy(attempted = attempted)))
    }

    @Test fun `固定任务身份和尝试结果不能回退冷恢复不丢失原范围`() {
        val record = pending(row(true, listOf(task(91, true), task(92, true))), setOf(91))
        val before = record.checkpoint
        for (value in listOf(before.background!!.copy(attempted = emptySet()), before.background.copy(tasks = listOf(task(91, true))),
            before.background.copy(tasks = before.background.tasks.map { it.copy(createdAt = 101.5) }),
            before.background.copy(completed = setOf(92)))) {
            failure { store.save(record.id, owner, 41, before.copy(background = value)) }
        }
        val completed = store.save(record.id, owner, 41, before.copy(background = before.background!!.copy(completed = setOf(91)), phase = SynologyPhotoAlbumPhase.PARTIAL))
        failure { store.save(record.id, owner, 41, before) }
        assertEquals(completed.checkpoint, SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single().checkpoint)
        assertTrue(SynologyPhotoAlbumStore(preferences).records(owner.copy(identityRevision = "other"), 41).isEmpty())
    }

    @Test fun `原搬移未决可停止同一任务并独立恢复但不能先清理`() {
        val file = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.COPY_ITEMS, files = SynologyPhotoFileCheckpoint(SynologyPhotoSpace.PERSONAL,
                folders = listOf(SynologyPhotoFolderSnapshot(10, 1, "Source", "/Source", SynologyPhotoSpace.PERSONAL)),
                destination = SynologyPhotoFolderSnapshot(20, 1, "Target", "/Target", SynologyPhotoSpace.SHARED), duplicate = SynologyPhotoTransferDuplicate.SKIP)))
        store.begin(file); store.save(file.id, owner, 41, file.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        val waiting = store.save(file.id, owner, 41, file.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING,
            files = file.checkpoint.files!!.copy(taskId = 91, total = 10, targetVerified = true)))
        failure { store.begin(row(true)) }
        failure { store.begin(row(tasks = listOf(task(92)))) }
        val control = pending(row(), setOf(91))
        store.requireNoConflict(waiting)
        assertEquals(2, store.records(owner, 41).size)
        failure { store.begin(file.copy(checkpoint = file.checkpoint.copy(operationId = java.util.UUID.randomUUID().toString()))) }
        store.save(file.id, owner, 41, waiting.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PARTIAL,
            files = waiting.checkpoint.files!!.copy(result = SynologyPhotoFileResult(2, 0, 0, 0))))
        store.save(control.id, owner, 41, control.checkpoint.copy(phase = SynologyPhotoAlbumPhase.COMPLETED,
            background = control.checkpoint.background!!.copy(completed = setOf(91))))
        store.begin(row(true))
        assertEquals(3, store.records(owner, 41).size)
    }

    @Test fun `未决控制不允许丢弃或借改动作与照片写绕过互斥`() {
        val record = pending(row(), setOf(91))
        failure { store.discard(record) }
        failure { store.save(record.id, owner, 41, record.checkpoint.copy(action = SynologyPhotoAlbumAction.CLEAR_TASKS,
            background = record.checkpoint.background!!.copy(tasks = listOf(task(done = true))))) }
        val album = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic album"))
        failure { store.begin(album) }
        assertEquals(record, store.get(record.id, owner, 41))
    }

    private fun failure(block: () -> Unit) { try { block(); fail("Expected storage or conflict rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}
