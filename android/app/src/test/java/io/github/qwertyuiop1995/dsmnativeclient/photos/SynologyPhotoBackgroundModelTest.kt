package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.validatePhotoAlbumCheckpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoBackgroundModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "background-${UUID.randomUUID()}"
        var supportsTasks = true; var supportsFolders = false
        override val canControlBackgroundTasks get() = supportsTasks
        override val canManageFolders get() = supportsFolders
        var user = 41L; var reads = 0; var prepares = 0; var writes = 0; var reviews = 0
        var failRead = false; var failPrepare = false; var pending = false
        var beforeRead: suspend () -> Unit = {}; var beforePrepare: suspend () -> Unit = {}
        var beforeWrite: suspend () -> Unit = {}; var beforeErrors: suspend () -> Unit = {}; var beforeTarget: suspend () -> Unit = {}
        val tasks = CopyOnWriteArrayList<SynologyPhotoBackgroundTask>()
        fun task(id: Long = 91, status: SynologyPhotoBackgroundStatus = SynologyPhotoBackgroundStatus.PROCESSING) =
            SynologyPhotoBackgroundTask(profileId, 41, SynologyPhotoBackgroundSnapshot(id, "copy", status, 10, 100.5, 20, 0),
                if (status == SynologyPhotoBackgroundStatus.DONE) 10 else 2, 1, 0, 0)
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic")
        override suspend fun photoEditIdentity() = user
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
        override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
        override suspend fun folderAccess(space: SynologyPhotoSpace, id: Long) = SynologyPhotoFolderAccess(
            SynologyPhotoFolderSnapshot(id, if (id == 1L) 0 else 1, if (id == 1L) "/" else "Target", if (id == 1L) "/" else "/Target", space),
            true, true, SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME), null)
        override suspend fun backgroundTasks(): List<SynologyPhotoBackgroundTask> { reads++; val result = tasks.toList(); beforeRead(); if (failRead) throw IOException("Synthetic read"); return result }
        override suspend fun backgroundTaskErrors(task: SynologyPhotoBackgroundTask): List<SynologyPhotoBackgroundError> {
            beforeErrors(); return listOf(SynologyPhotoBackgroundError(SynologyPhotoBackgroundError.Kind.ITEM, task.id, SynologyPhotoBackgroundError.Reason.SPACE))
        }
        override suspend fun backgroundTaskTarget(task: SynologyPhotoBackgroundTask): List<SynologyPhotoCollection> {
            beforeTarget(); return listOf(SynologyPhotoCollection(1, "/", parentId = 0, path = "/", space = SynologyPhotoSpace.SHARED),
                SynologyPhotoCollection(20, "Target", parentId = 1, path = "/Target", space = SynologyPhotoSpace.SHARED))
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) {
            prepares++; validatePhotoAlbumCheckpoint(checkpoint); beforePrepare()
            if (failPrepare) throw IOException("Synthetic preflight")
        }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
            val attempted = checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING,
                background = checkpoint.background!!.copy(attempted = checkpoint.background.tasks.map { it.id }.toSet()))
            save(attempted); writes++; beforeWrite()
            val result = attempted.copy(phase = SynologyPhotoAlbumPhase.PENDING); save(result)
            return if (pending) result else completed(result).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; return if (pending) checkpoint else completed(checkpoint).also(save)
        }
        private fun completed(row: SynologyPhotoAlbumCheckpoint) = row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED,
            background = row.background!!.copy(completed = row.background.attempted))
    }
    private class Fixture {
        val api = Api(); val prefs = MemoryPreferences(); val store = SynologyPhotoAlbumStore(prefs)
        val owner = WorkspaceOwner(api.profileId, "identity", "session")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); val ticks = Channel<Unit>(Channel.UNLIMITED)
        var current = true; var allowed = true; var guards = 0; var completions = 0
        var opened: List<SynologyPhotoCollection>? = null
        fun create() = SynologyPhotoBackgroundModel(api, scope, store, owner, { if (!current) throw CancellationException() },
            { allowed }, beforeWrite = { guards++ }, onCompleted = { completions++ }, onOpenTarget = { opened = it }, pause = { ticks.receive() })
        val model = create()
        init { api.tasks += api.task() }
        suspend fun open() { model.activate(); model.open(); await { model.state.value.loaded && !model.state.value.loading } }
        suspend fun prepare() { model.prepareStop(api.tasks.first())!!.join(); assertNotNull(model.state.value.confirmation) }
        fun readyRecord(): SynologyPhotoAlbumRecord = SynologyPhotoAlbumRecord(owner = owner,
            checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.STOP_TASK,
                background = SynologyPhotoBackgroundCheckpoint(listOf(api.tasks.first().snapshot))))
    }

    @Test fun `加载空内容筛选未知状态失败重试均保留真实状态`() = runBlocking { fixture { f ->
        f.api.tasks += f.api.task(92, SynologyPhotoBackgroundStatus.DONE)
        f.api.tasks += f.api.task(93, SynologyPhotoBackgroundStatus.UNKNOWN)
        f.open(); assertEquals(3, f.model.state.value.visibleTasks.size)
        f.model.filter(SynologyPhotoBackgroundFilter.ACTIVE); assertEquals(listOf(91L), f.model.state.value.visibleTasks.map { it.id })
        f.model.filter(SynologyPhotoBackgroundFilter.FINISHED); assertEquals(listOf(92L), f.model.state.value.visibleTasks.map { it.id })
        f.api.tasks.removeIf { it.id == 92L }; f.model.refresh()!!.join(); assertTrue(f.model.state.value.visibleTasks.isEmpty()); assertEquals(2, f.model.state.value.tasks.size)
        f.api.failRead = true; f.model.refresh()!!.join(); assertNotNull(f.model.state.value.listError); assertEquals(2, f.model.state.value.tasks.size)
        f.api.failRead = false; f.api.tasks.clear(); f.model.refresh()!!.join(); assertNull(f.model.state.value.listError); assertTrue(f.model.state.value.tasks.isEmpty())
    } }
    @Test fun `确认取消不写重复确认被合并页面关闭后已发送操作仍保存`() = runBlocking { fixture { f ->
        f.open(); f.prepare(); f.model.cancelConfirmation(); assertEquals(0, f.api.writes); assertTrue(f.store.records(f.owner, 41).isEmpty())
        f.prepare(); val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { started.complete(Unit); release.await() }
        val job = f.model.confirm()!!; started.await(); assertNull(f.model.confirm()); f.model.dismiss()
        release.complete(Unit); job.join()
        assertEquals(1, f.api.writes); assertEquals(3, f.guards); assertEquals(1, f.completions)
        assertTrue(f.store.records(f.owner, 41).single().checkpoint.finished); assertFalse(f.model.state.value.visible)
    } }
    @Test fun `确认前重新预检失败不登记已发送账号更换和持久化失败零写入`() = runBlocking { fixture { f ->
        f.open(); f.prepare(); f.api.failPrepare = true; f.model.confirm()!!.join()
        assertTrue(f.store.records(f.owner, 41).isEmpty()); assertEquals(0, f.api.writes); assertNotNull(f.model.state.value.error)
        f.api.failPrepare = false; f.api.user = 42; f.model.prepareStop(f.api.tasks.first())!!.join()
        assertNull(f.model.state.value.confirmation); assertEquals(SynologyPhotoFailureKind.PERMISSION, (f.model.state.value.error as SynologyPhotoFailure).kind)
        f.api.user = 41; f.prepare(); f.prefs.commitSucceeds = false; f.model.confirm()!!.join(); assertEquals(0, f.api.writes)
        assertEquals(SynologyPhotoAlbumProblem.STORAGE, (f.model.state.value.error as SynologyPhotoAlbumFailure).problem)
    } }
    @Test fun `未决结果冷热恢复只读不能丢弃最终读取结束才放行`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(); f.prepare(); f.model.confirm()!!.join()
        val id = f.model.state.value.records.single().id
        assertNull(f.model.discard(id)); assertFalse(f.model.canControl)
        try { f.model.requireNoPending(); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, error.problem) }
        f.model.close(); f.create().use { restored ->
            restored.activate(); restored.showRecords(); await { restored.state.value.hasPending }
            restored.review(id)!!.join(); assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
            f.api.pending = false; restored.review(id)!!.join(); restored.requireNoPending()
            assertEquals(1, f.api.writes); assertEquals(2, f.api.reviews); assertTrue(restored.canControl)
            restored.discard(id)!!.join(); assertTrue(f.store.records(f.owner, 41).isEmpty())
        }
    } }
    @Test fun `打开页面才轮询关闭后不读不停止NAS重新激活恢复读取`() = runBlocking { fixture { f ->
        f.open(); val before = f.api.reads; f.ticks.send(Unit); await { f.api.reads == before + 1 && !f.model.state.value.loading }
        f.model.dismiss(); f.ticks.send(Unit); delay(50); assertEquals(before + 1, f.api.reads); assertEquals(0, f.api.writes); f.ticks.tryReceive()
        f.model.open(); await { f.api.reads == before + 2 && !f.model.state.value.loading }
        f.model.deactivate(); val paused = f.api.reads; delay(50); assertEquals(paused, f.api.reads)
        f.model.activate(); await { f.api.reads > paused }; assertEquals(0, f.api.writes)
    } }
    @Test fun `操作记录页面自动只读恢复且未发送记录绝不自动执行`() = runBlocking { fixture { f ->
        val ready = f.readyRecord(); f.store.begin(ready)
        f.model.activate(); f.model.showRecords(); await { f.model.state.value.records.size == 1 }
        f.ticks.send(Unit); delay(50); assertEquals(0, f.api.writes); assertEquals(0, f.api.reviews)
        f.store.save(ready.id, f.owner, 41, ready.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        f.store.save(ready.id, f.owner, 41, ready.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING,
            background = ready.checkpoint.background!!.copy(attempted = setOf(91))))
        f.model.refreshRecords()!!.join(); f.ticks.send(Unit); await { f.model.state.value.records.single().checkpoint.finished }
        assertEquals(1, f.api.reviews); assertEquals(0, f.api.writes); assertEquals(0, f.api.reads)
    } }
    @Test fun `旧预检在切换记录页后晚到不会重开确认`() = runBlocking { fixture { f ->
        f.open(); val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforePrepare = { started.complete(Unit); withContext(NonCancellable) { release.await() } }
        val job = f.model.prepareStop(f.api.tasks.first())!!; started.await(); f.model.showRecords(); release.complete(Unit); job.join()
        assertTrue(f.model.state.value.recordsPage); assertNull(f.model.state.value.confirmation); assertFalse(f.model.state.value.preparing); assertEquals(0, f.api.writes)
    } }
    @Test fun `关闭后重开加载不接纳旧列表且撤销账号清空所有状态`() = runBlocking { fixture { f ->
        f.open(); val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeRead = { started.complete(Unit); withContext(NonCancellable) { release.await() } }
        val old = f.model.refresh()!!; started.await(); f.model.dismiss(); f.api.beforeRead = {}; f.api.tasks.clear(); f.model.open()
        await { f.model.state.value.loaded && !f.model.state.value.loading }; release.complete(Unit); old.join()
        assertTrue(f.model.state.value.tasks.isEmpty())
        f.current = false; f.model.revokeAccess(); assertEquals(SynologyPhotoBackgroundState(), f.model.state.value); assertEquals(0, f.api.writes)
    } }
    @Test fun `失败详情关闭或改选后晚到不串行且可重试`() = runBlocking { fixture { f ->
        f.api.tasks += f.api.task(92); f.open()
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeErrors = { started.complete(Unit); withContext(NonCancellable) { release.await() } }
        val old = f.model.openErrors(f.api.tasks.first())!!; started.await(); f.model.closeErrors()
        f.api.beforeErrors = { throw IOException("Synthetic detail") }; f.model.openErrors(f.api.tasks.last())!!.join()
        assertNotNull(f.model.state.value.errorsFailure); f.api.beforeErrors = {}; f.model.loadErrors()!!.join()
        release.complete(Unit); old.join(); assertEquals(92L, f.model.state.value.errors.single().itemId); assertNull(f.model.state.value.errorsFailure)
    } }
    @Test fun `目标目录读取失败保留页面关闭晚到不导航成功才关闭`() = runBlocking { fixture { f ->
        f.api.tasks.clear(); f.api.tasks += f.api.task(status = SynologyPhotoBackgroundStatus.DONE); f.open()
        f.api.beforeTarget = { throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION) }; f.model.openTarget(f.api.tasks.single())!!.join()
        assertTrue(f.model.state.value.visible); assertNull(f.opened); assertNotNull(f.model.state.value.error)
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeTarget = { started.complete(Unit); withContext(NonCancellable) { release.await() } }
        val old = f.model.openTarget(f.api.tasks.single())!!; started.await(); f.model.dismiss(); release.complete(Unit); old.join(); assertNull(f.opened)
        f.api.beforeTarget = {}; f.model.open(); await { !f.model.state.value.loading }
        f.model.openTarget(f.api.tasks.single())!!.join(); assertEquals(listOf(1L, 20L), f.opened!!.map { it.id }); assertFalse(f.model.state.value.visible)
    } }
    @Test fun `清理固定确认范围不包含随后完成的任务且禁用期间不允许确认`() = runBlocking { fixture { f ->
        f.api.tasks.clear(); f.api.tasks += f.api.task(status = SynologyPhotoBackgroundStatus.DONE); f.open()
        f.model.prepareClear(f.api.tasks.toList())!!.join(); f.api.tasks += f.api.task(92, SynologyPhotoBackgroundStatus.DONE)
        f.allowed = false; assertNull(f.model.confirm()); assertEquals(0, f.api.writes)
        f.allowed = true; f.model.confirm()!!.join()
        assertEquals(listOf(91L), f.store.records(f.owner, 41).single().checkpoint.background!!.tasks.map { it.id })
    } }
    @Test fun `编辑权限已消失时旧未决编辑仍从存储阻止后台控制`() = runBlocking { fixture { f ->
        val edits = SynologyPhotoEditStore(MemoryPreferences())
        val target = SynologyPhotoEditTarget(SynologyPhoto(SynologyPhotoId(f.api.profileId, SynologyPhotoSpace.PERSONAL, 21), "Synthetic.jpg", 4, 20.0, 30.0, 9, "photo"))
        val row = SynologyPhotoEditRecord(owner = f.owner, checkpoint = SynologyPhotoEditCheckpoint(profileId = f.api.profileId, userId = 41,
            space = SynologyPhotoSpace.PERSONAL, targets = listOf(target), edit = SynologyPhotoEdit.Rating(3)))
        edits.begin(row); edits.save(row.id, f.owner, 41, row.checkpoint.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = setOf(0)))
        edits.save(row.id, f.owner, 41, row.checkpoint.copy(phase = SynologyPhotoEditPhase.PENDING, attempted = setOf(0)))
        SynologyPhotosModel(f.api, f.scope, uploadOwner = f.owner, albumStore = f.store, editStore = edits).use { root ->
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; assertNull(root.edits)
            val tasks = root.background!!; tasks.open(); await { tasks.state.value.loaded && !tasks.state.value.loading }
            tasks.prepareStop(f.api.tasks.single())!!.join(); assertNull(tasks.state.value.confirmation)
            assertEquals(SynologyPhotoAlbumProblem.PENDING, (tasks.state.value.error as SynologyPhotoAlbumFailure).problem); assertEquals(0, f.api.writes)
        }
    } }
    @Test fun `目标目录补充排序和封面不改变身份正常关闭任务中心`() = runBlocking { fixture { f ->
        f.api.supportsFolders = true; f.api.tasks.clear(); f.api.tasks += f.api.task(status = SynologyPhotoBackgroundStatus.DONE)
        SynologyPhotosModel(f.api, f.scope, uploadOwner = f.owner, albumStore = f.store).use { root ->
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }
            val tasks = root.background!!; tasks.open(); await { tasks.state.value.loaded && !tasks.state.value.loading }
            tasks.openTarget(f.api.tasks.single())!!.join()
            assertNull(tasks.state.value.error); assertFalse(tasks.state.value.visible); assertEquals(SynologyPhotoSpace.SHARED, root.state.value.navigation.space)
            assertEquals(listOf(1L, 20L), root.state.value.navigation.folders.map { it.id })
            assertEquals(SynologyPhotoSort.Field.FILENAME, root.state.value.navigation.folders.last().sort!!.field)
        }
    } }
    @Test fun `后台控制能力消失仍由持久未决记录阻止新的导出`() = runBlocking { fixture { f ->
        val row = f.readyRecord(); f.store.begin(row); f.store.save(row.id, f.owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        f.store.save(row.id, f.owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING, background = row.checkpoint.background!!.copy(attempted = setOf(91))))
        f.api.supportsTasks = false
        val cache = java.nio.file.Files.createTempDirectory("background-export-").toFile()
        try { SynologyPhotosModel(f.api, f.scope, uploadOwner = f.owner, albumStore = f.store).use { root ->
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; assertNull(root.background)
            assertTrue(root.exports.open(SynologyPhotoExportRequest.Archive(SynologyPhotoArchiveTarget.Folder(9, SynologyPhotoSpace.PERSONAL), "Synthetic")))
            root.exports.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)!!.join()
            assertEquals(SynologyPhotoAlbumProblem.PENDING, (root.exports.state.value.error as SynologyPhotoAlbumFailure).problem)
            assertEquals(0, f.api.writes); assertTrue(cache.listFiles()!!.isEmpty())
        } } finally { cache.deleteRecursively() }
    } }

    companion object {
        private suspend fun await(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(10) } }
        private suspend fun fixture(block: suspend (Fixture) -> Unit) {
            val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.cancel(); f.ticks.close() }
        }
    }
}
