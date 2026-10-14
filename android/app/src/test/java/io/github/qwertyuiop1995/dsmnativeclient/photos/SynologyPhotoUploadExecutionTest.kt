package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

internal class PhotoUploadServingFixture : SynologyPhotosServing {
    override val profileId = "profile-a"
    override val canUploadPhotos = true
    var user = 41L
    var stopAfterReceipt = false
    var beforeWrite: suspend () -> Unit = {}
    var afterReceipt: suspend () -> Unit = {}
    var beforePrepare: suspend () -> Unit = {}
    val writes = mutableListOf<SynologyPhotoUploadAction>()
    val bodies = mutableListOf<List<Byte>>()
    var reviews = 0
    override suspend fun access() = SynologyPhotoAccess(listOf(SynologyPhotoSpace.PERSONAL, SynologyPhotoSpace.SHARED), "synthetic")
    override suspend fun uploadIdentity() = user
    override suspend fun uploadDuplicatePolicy() = SynologyPhotoUploadDuplicate.RENAME
    override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
    override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
    override suspend fun rootFolder(space: SynologyPhotoSpace) = SynologyPhotoCollection(9, "/", space = space)
    override suspend fun addableAlbums(offset: Int, limit: Int) = listOf(SynologyPhotoCollection(71, "Synthetic album"))
    override suspend fun prepareUploadTarget(target: SynologyPhotoUploadTarget) { beforePrepare() }
    override suspend fun performPhotoUpload(checkpoint: SynologyPhotoUploadCheckpoint, source: File?,
        save: (SynologyPhotoUploadCheckpoint) -> Unit, progress: (Long, Long) -> Unit): SynologyPhotoUploadCheckpoint {
        assertFalse(checkpoint.submitted)
        save(checkpoint.copy(phase = SynologyPhotoUploadPhase.SUBMITTING))
        beforeWrite()
        writes += checkpoint.action
        val received = when (val action = checkpoint.action) {
            is SynologyPhotoUploadAction.CreateFolder -> checkpoint.copy(phase = SynologyPhotoUploadPhase.PENDING, folderId = 90L + writes.size)
            is SynologyPhotoUploadAction.Upload -> {
                val bytes = source!!.readBytes(); bodies += bytes.toList(); progress(bytes.size.toLong(), action.size)
                checkpoint.copy(phase = SynologyPhotoUploadPhase.PENDING, itemId = 90L + writes.size)
            }
        }
        save(received)
        afterReceipt()
        return if (stopAfterReceipt) received else reviewPhotoUpload(received, save)
    }
    override suspend fun reviewPhotoUpload(checkpoint: SynologyPhotoUploadCheckpoint, save: (SynologyPhotoUploadCheckpoint) -> Unit): SynologyPhotoUploadCheckpoint {
        assertTrue(checkpoint.submitted); reviews++
        if (stopAfterReceipt || checkpoint.itemId == null && checkpoint.folderId == null) return checkpoint
        return checkpoint.copy(phase = SynologyPhotoUploadPhase.COMPLETED).also(save)
    }
}

class SynologyPhotoUploadExecutionTest {
    @Test fun `先复制全部原件再上传且外部文件变化不改变队列内容`() = runBlocking {
        fixture { f ->
            var content = byteArrayOf(1, 2, 3, 4)
            val sources = listOf(SynologyPhotoLocalSource("synthetic.jpg", 4, 10, open = { ByteArrayInputStream(content) }))
            val row = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, sources, false)
            assertTrue(f.api.writes.isEmpty())
            assertEquals(listOf(row.entries.single().id), f.store.directory(row.id).listFiles()!!.map { it.name })
            content = byteArrayOf(9, 8, 7, 6)
            val completed = f.execution.run(row.id, 41) { _, _, _, _ -> }
            assertTrue(completed.finished)
            assertEquals(listOf(byteArrayOf(1, 2, 3, 4).toList()), f.api.bodies)
            assertEquals(1, completed.completedCount)
        }
    }

    @Test fun `目录导入逐层使用已确认编号而相册导入自动平铺`() = runBlocking {
        fixture { f ->
            val row = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME,
                listOf(source("root/sub"), source("root")), true)
            assertEquals(SynologyPhotoUploadTarget.Folder(SynologyPhotoSpace.PERSONAL, 9), row.target)
            assertEquals(listOf("root", "root/sub"), row.folders)
            assertTrue(f.execution.run(row.id, 41) { _, _, _, _ -> }.finished)
            assertEquals(SynologyPhotoUploadAction.CreateFolder(SynologyPhotoSpace.PERSONAL, 9, "root"), f.api.writes[0])
            assertEquals(SynologyPhotoUploadAction.CreateFolder(SynologyPhotoSpace.PERSONAL, 91, "sub"), f.api.writes[1])
            assertEquals(SynologyPhotoUploadTarget.Folder(SynologyPhotoSpace.PERSONAL, 92), (f.api.writes[2] as SynologyPhotoUploadAction.Upload).target)
            val album = f.execution.stage(41, SynologyPhotoUploadTarget.Album(71), "Synthetic album", SynologyPhotoUploadDuplicate.IGNORE,
                listOf(source("root/sub")), true)
            assertTrue(album.folders.isEmpty()); assertEquals("", album.entries.single().relativeFolder)
            assertTrue(f.execution.run(album.id, 41) { _, _, _, _ -> }.finished)
            assertEquals(SynologyPhotoUploadTarget.Album(71), (f.api.writes.last() as SynologyPhotoUploadAction.Upload).target)
        }
    }

    @Test fun `未知目录创建暂停子目录和原件恢复只读后才继续`() = runBlocking {
        fixture { f ->
            val row = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source("root/sub")), true)
            f.api.stopAfterReceipt = true
            val pending = f.execution.run(row.id, 41) { _, _, _, _ -> }
            assertTrue(pending.requiresReview); assertEquals(1, f.api.writes.size)
            val newStore = SynologyPhotoUploadStore(f.preferences, f.root)
            val recovered = newStore.records(owner, 41).single()
            assertEquals(pending, recovered)
            f.api.stopAfterReceipt = false
            val execution = SynologyPhotoUploadExecution(f.api, newStore, owner)
            val reviewed = execution.run(row.id, 41, reviewOnly = true) { _, _, _, _ -> }
            assertFalse(reviewed.requiresReview); assertFalse(reviewed.finished); assertEquals(1, f.api.writes.size)
            assertTrue(execution.run(row.id, 41) { _, _, _, _ -> }.finished)
            assertEquals(3, f.api.writes.size)
        }
    }

    @Test fun `无回执的跨进程恢复永不重新上传`() = runBlocking {
        fixture { f ->
            val row = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source()), false)
            val entry = row.entries.single()
            val checkpoint = SynologyPhotoUploadCheckpoint(profileId = "profile-a", userId = 41, action = row.fileAction(entry), phase = SynologyPhotoUploadPhase.SUBMITTING)
            f.store.saveFile(row.id, owner, 41, entry.id, checkpoint)
            val reopened = SynologyPhotoUploadStore(f.preferences, f.root)
            val restored = reopened.records(owner, 41).single()
            assertEquals(SynologyPhotoUploadPhase.PENDING, restored.entries.single().checkpoint?.phase)
            val executor = SynologyPhotoUploadExecution(f.api, reopened, owner)
            assertTrue(executor.run(row.id, 41) { _, _, _, _ -> }.requiresReview)
            assertTrue(f.api.writes.isEmpty()); assertEquals(1, f.api.reviews)
            expect(SynologyPhotoUploadProblem.PENDING) { reopened.discard(restored) }
            expect(SynologyPhotoUploadProblem.PENDING) { f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source()), false) }
        }
    }

    @Test fun `同一身份重新登录保留记录但账号目标版本及Photos用户隔离`() = runBlocking {
        fixture { f ->
            val row = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source()), false)
            assertEquals(listOf(row), f.store.records(owner.copy(sessionGeneration = "new-session"), 41))
            assertTrue(f.store.records(owner.copy(identityRevision = "different-account"), 41).isEmpty())
            assertTrue(f.store.records(owner.copy(profileId = "profile-b"), 41).isEmpty())
            assertTrue(f.store.records(owner, 42).isEmpty())
            f.api.user = 42
            try { f.execution.run(row.id, 41) { _, _, _, _ -> }; fail() } catch (_: SynologyPhotoFailure) { }
            assertTrue(f.api.writes.isEmpty())
            val raw = f.preferences.all.values.joinToString()
            assertFalse(raw.contains(f.root.absolutePath)); assertFalse(raw.contains("content://")); assertFalse(raw.contains("passphrase"))
        }
    }

    @Test fun `固定清单拒绝重定向目标与已提交状态回退`() = runBlocking {
        fixture { f ->
            val row = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source()), false)
            val entry = row.entries.single()
            val pending = SynologyPhotoUploadCheckpoint(profileId = "profile-a", userId = 41, action = row.fileAction(entry), phase = SynologyPhotoUploadPhase.SUBMITTING)
            expect(SynologyPhotoUploadProblem.STORAGE) {
                f.store.saveFile(row.id, owner, 41, entry.id, pending.copy(action = (pending.action as SynologyPhotoUploadAction.Upload).copy(target = SynologyPhotoUploadTarget.Album(71))))
            }
            f.store.saveFile(row.id, owner, 41, entry.id, pending)
            f.store.saveFile(row.id, owner, 41, entry.id, pending.copy(phase = SynologyPhotoUploadPhase.PENDING, itemId = 91))
            expect(SynologyPhotoUploadProblem.STORAGE) { f.store.saveFile(row.id, owner, 41, entry.id, pending) }
        }
    }

    @Test fun `读取失败长度变化和取消不会创建上传任务或留下半份媒体`() = runBlocking {
        fixture { f ->
            val bad = listOf(source().copy(size = 10), source().copy(size = 2), source().copy(filename = "../bad.jpg"),
                source().copy(open = { throw java.io.IOException() }), source().copy(open = { throw CancellationException() }))
            for (source in bad) {
                try { f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source), false); fail() } catch (_: Exception) { }
                assertTrue(f.store.records(owner, 41).isEmpty())
                assertTrue(f.root.listFiles().orEmpty().isEmpty())
            }
            assertTrue(f.api.writes.isEmpty())
        }
    }

    @Test fun `复制期归属变化拒绝任务且清理副本`() = runBlocking {
        fixture { f ->
            var checks = 0
            val execution = SynologyPhotoUploadExecution(f.api, f.store, owner) { if (++checks >= 3) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION) }
            try { execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source()), false); fail() }
            catch (_: SynologyPhotoFailure) { }
            assertTrue(f.root.listFiles().orEmpty().isEmpty()); assertTrue(f.api.writes.isEmpty())
        }
    }

    @Test fun `清除完成记录删除私有副本而任务创建时间不会被重建`() = runBlocking {
        fixture { f ->
            val row = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source()), false)
            val completed = f.execution.run(row.id, 41) { _, _, _, _ -> }
            val reopened = SynologyPhotoUploadStore(f.preferences, f.root)
            assertEquals(row.createdAtSeconds, reopened.records(owner, 41).single().createdAtSeconds)
            reopened.discard(completed)
            assertFalse(reopened.directory(row.id).exists()); assertTrue(reopened.records(owner, 41).isEmpty())
        }
    }

    @Test fun `同账号并发队列拒绝且取消后释放运行锁`() = runBlocking {
        fixture { f ->
            val one = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source()), false)
            val two = f.execution.stage(41, SynologyPhotoUploadTarget.Album(71), "Synthetic", SynologyPhotoUploadDuplicate.RENAME, listOf(source()), false)
            val entered = CompletableDeferred<Unit>()
            f.api.beforeWrite = { entered.complete(Unit); awaitCancellation() }
            val task = launch { f.execution.run(one.id, 41) { _, _, _, _ -> } }
            entered.await()
            expect(SynologyPhotoUploadProblem.BUSY) { f.execution.run(two.id, 41) { _, _, _, _ -> } }
            assertTrue(SynologyPhotoUploadStore.isProfileBusy("profile-a"))
            task.cancelAndJoin()
            assertFalse(SynologyPhotoUploadStore.isProfileBusy("profile-a"))
            f.api.beforeWrite = {}
            assertTrue(f.execution.run(two.id, 41) { _, _, _, _ -> }.finished)
        }
    }

    @Test fun `提前建立的第二批也不能在第一批未知后重传同一原件`() = runBlocking {
        fixture { f ->
            val first = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.RENAME, listOf(source()), false)
            val second = f.execution.stage(41, timeline, "", SynologyPhotoUploadDuplicate.IGNORE, listOf(source()), false)
            f.api.stopAfterReceipt = true
            assertTrue(f.execution.run(first.id, 41) { _, _, _, _ -> }.requiresReview)
            val reopened = SynologyPhotoUploadExecution(f.api, SynologyPhotoUploadStore(f.preferences, f.root), owner.copy(sessionGeneration = "new-session"))
            expect(SynologyPhotoUploadProblem.PENDING) { reopened.run(second.id, 41) { _, _, _, _ -> } }
            assertEquals(1, f.api.writes.size)
        }
    }

    private class Fixture(val root: File) {
        val preferences = MemoryPreferences()
        val store = SynologyPhotoUploadStore(preferences, root)
        val api = PhotoUploadServingFixture()
        val execution = SynologyPhotoUploadExecution(api, store, owner)
    }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val root = Files.createTempDirectory("photos-queue-test-").toFile()
        try { block(Fixture(root)) } finally { root.deleteRecursively() }
    }
    private suspend fun expect(problem: SynologyPhotoUploadProblem, block: suspend () -> Unit) {
        try { block(); fail("应拒绝不安全状态") } catch (error: SynologyPhotoUploadFailure) { assertEquals(problem, error.problem) }
    }
    companion object {
        internal val owner = WorkspaceOwner("profile-a", "identity-a", "session-a")
        internal val timeline = SynologyPhotoUploadTarget.Timeline(SynologyPhotoSpace.PERSONAL)
        internal fun source(folder: String = "") = SynologyPhotoLocalSource("synthetic.jpg", 4, 10, folder) { ByteArrayInputStream(byteArrayOf(1, 2, 3, 4)) }
    }
}
