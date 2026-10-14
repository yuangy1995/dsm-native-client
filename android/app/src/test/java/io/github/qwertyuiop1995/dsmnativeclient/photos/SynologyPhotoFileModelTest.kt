package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.validatePhotoAlbumCheckpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoFileModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "file-model"
        override val canTransferPhotos = true
        override val canDeleteFolders = true
        var duplicate = SynologyPhotoTransferDuplicate.SKIP
        var failDefault = false; var failBrowse = false; var failPrepare = false; var pending = false; var knownId = true
        var writes = 0; var reviews = 0; var prepares = 0; var user = 41L
        var accessed = false; var prematureIdentityReads = 0; var identityReads = 0
        var beforeAccess: suspend () -> Unit = {}
        var last: SynologyPhotoAlbumCheckpoint? = null
        var beforeWrite: suspend () -> Unit = {}
        var beforeBrowse: suspend () -> Unit = {}
        var apply = false; var folderDeleted = false
        val photoRows = mutableListOf(photo(SynologyPhotoSpace.PERSONAL))
        override suspend fun access(): SynologyPhotoAccess { beforeAccess(); accessed = true; return SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic") }
        override suspend fun photoEditIdentity(): Long { identityReads++; if (!accessed) prematureIdentityReads++; return user }
        override suspend fun transferDuplicate(): SynologyPhotoTransferDuplicate { if (failDefault) throw IOException("Synthetic settings"); return duplicate }
        override suspend fun rootFolder(space: SynologyPhotoSpace) = folder(1, 0, "/", space)
        override suspend fun folderAccess(space: SynologyPhotoSpace, id: Long) = SynologyPhotoFolderAccess(
            snapshot(when (id) { 1L -> folder(1, 0, "/", space); 9L -> folder(9, 1, "/Source", space); 10L -> folder(10, 9, "/Source/Child", space); else -> folder(20, 1, "/Dest", space) }),
            true, true, SynologyPhotoSort(), null, canUpload = true)
        override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int): List<SynologyPhotoCollection> {
            beforeBrowse(); if (failBrowse) throw IOException("Synthetic target folders")
            val rows = when (parentId) {
                1L -> listOf(folder(9, 1, "/Source", space), folder(20, 1, "/Dest", space))
                9L -> if (folderDeleted && space == SynologyPhotoSpace.PERSONAL) emptyList() else listOf(folder(10, 9, "/Source/Child", space))
                else -> emptyList()
            }
            return rows.drop(offset).take(limit)
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) {
            prepares++; validatePhotoAlbumCheckpoint(checkpoint); if (failPrepare) throw IOException("Synthetic preflight")
        }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); beforeWrite(); writes++; last = checkpoint
            val files = checkpoint.files!!
            if (apply && checkpoint.action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS) {
                photoRows.removeAll { photo -> checkpoint.targets.any { it.id == photo.id } }; folderDeleted = true
            }
            val row = checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING, files = files.copy(taskId = 91L.takeIf { knownId },
                total = 3L.takeIf { knownId }, targetVerified = knownId && files.destination != null))
            save(row)
            return if (pending || !knownId) row else completed(row).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; return if (pending || checkpoint.files!!.taskId == null) checkpoint else completed(checkpoint).also(save)
        }
        private fun completed(row: SynologyPhotoAlbumCheckpoint) = row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED,
            files = row.files!!.copy(result = SynologyPhotoFileResult(3, 0, 0, 0)))
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            val rows = photoRows.map { it.copy(id = it.id.copy(space = space)) }.filter { query !is SynologyPhotoQuery.Folder || it.folderId == query.id }
            val page = rows.drop(offset).take(limit)
            return SynologyPhotoPage(page, offset, offset + page.size, offset + page.size < rows.size)
        }
    }
    private class Fixture {
        val api = Api(); val store = SynologyPhotoAlbumStore(MemoryPreferences())
        val owner = WorkspaceOwner(api.profileId, "identity", "session"); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var validOwner = true; var allowed = true; var beforeWrites = 0
        val completions = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        fun create() = SynologyPhotoFileModel(api, scope, store, owner, { if (!validOwner) throw CancellationException() },
            { SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic") }, { allowed }, beforeWrite = { beforeWrites++ }, onCompleted = { completions += it })
        val model = create()
        fun root(pageSize: Int = 100) = SynologyPhotosModel(api, scope, pageSize = pageSize, uploadOwner = owner,
            requireUploadOwner = { if (!validOwner) throw CancellationException() }, albumStore = store,
            editStore = SynologyPhotoEditStore(MemoryPreferences()))
        fun open(action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.COPY_ITEMS, space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL) =
            model.open(action, listOf(photo(space)), listOf(folder(10, 9, "/Source/Child", space)))
        suspend fun destination() {
            ready(model); model.enter(model.state.value.children.first { it.id == 20L }); ready(model)
        }
    }

    @Test fun `移动复制读取真实默认及目标目录固定清单明确保存`() = runBlocking { fixture { f ->
        f.open(); f.destination(); assertTrue(f.model.canSave)
        f.model.save()!!.join()
        assertEquals(1, f.api.writes); assertEquals(1, f.beforeWrites); assertEquals(20L, f.api.last!!.files!!.destination!!.id)
        assertTrue(f.model.state.value.recordsPage); assertNull(f.model.state.value.draft)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, f.store.records(f.owner, 41).single().checkpoint.phase)
    } }
    @Test fun `图库首次启动等待访问完成再恢复文件任务记录`() = runBlocking { fixture { f ->
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeAccess = { started.complete(Unit); release.await() }
        f.root().use { root ->
            root.activate(); started.await(); delay(50)
            assertEquals(0, f.api.identityReads); assertEquals(0, f.api.prematureIdentityReads)
            release.complete(Unit); await { root.state.value.loaded && f.api.identityReads > 0 }
            assertEquals(0, f.api.prematureIdentityReads); assertNull(root.files!!.state.value.error)
        }
    } }
    @Test fun `替换必须单独确认取消及重复点击不额外写入`() = runBlocking { fixture { f ->
        f.api.duplicate = SynologyPhotoTransferDuplicate.OVERWRITE; f.open(); f.destination()
        assertNull(f.model.save()); assertEquals(0, f.api.writes)
        val submitted = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { submitted.complete(Unit); release.await() }
        val job = f.model.save(overwriteConfirmed = true)!!; submitted.await()
        assertNull(f.model.save(overwriteConfirmed = true)); f.model.dismiss(); assertFalse(f.model.state.value.visible)
        release.complete(Unit); job.join(); assertEquals(1, f.api.writes)
        assertEquals(SynologyPhotoTransferDuplicate.OVERWRITE, f.api.last!!.files!!.duplicate)
    } }
    @Test fun `混合删除打开先预检确认取消零写入重新确认才删除`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS); ready(f.model)
        assertTrue(f.model.canSave); assertEquals(1, f.api.prepares); assertTrue(f.model.state.value.path.isEmpty())
        f.model.dismiss(); assertEquals(0, f.api.writes); assertTrue(f.store.records(f.owner, 41).isEmpty())
        f.open(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS); ready(f.model); f.model.save()!!.join()
        assertEquals(1, f.api.writes); assertNull(f.api.last!!.files!!.destination)
    } }
    @Test fun `默认规则读取失败可重试且不会悄悄选择覆盖`() = runBlocking { fixture { f ->
        f.api.failDefault = true; f.open(); ready(f.model)
        assertNotNull(f.model.state.value.error); assertNull(f.model.state.value.draft); assertFalse(f.model.canSave)
        f.api.failDefault = false; f.model.load()!!.join(); f.destination()
        assertEquals(SynologyPhotoTransferDuplicate.SKIP, f.model.state.value.draft!!.checkpoint.files!!.duplicate)
    } }
    @Test fun `选择来源失败保留所选来源且重试不误用之前的目录`() = runBlocking { fixture { f ->
        f.open(); f.destination(); f.api.failBrowse = true
        f.model.browseRoot(SynologyPhotoSpace.SHARED)!!.join()
        assertFalse(f.model.canSave); assertNull(f.model.state.value.folderAccess); assertTrue(f.model.state.value.path.isEmpty())
        assertEquals(SynologyPhotoSpace.SHARED, f.model.state.value.browseSpace)
        f.api.failBrowse = false; f.model.browse()!!.join()
        assertEquals(SynologyPhotoSpace.SHARED, f.model.state.value.path.single().space)
    } }
    @Test fun `提交前失败保留表单不登记已发送修改后可重试`() = runBlocking { fixture { f ->
        f.open(); f.destination(); f.api.failPrepare = true; f.model.save()!!.join()
        assertTrue(f.model.canSave); assertTrue(f.store.records(f.owner, 41).isEmpty()); assertEquals(0, f.api.writes)
        f.api.failPrepare = false; f.model.save()!!.join(); assertEquals(1, f.api.writes)
    } }
    @Test fun `同空间原位置不可提交共享移动只显示共享目标`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoAlbumAction.MOVE_ITEMS, SynologyPhotoSpace.SHARED); ready(f.model)
        assertEquals(listOf(SynologyPhotoSpace.SHARED), f.model.destinationSpaces)
        assertNull(f.model.browseRoot(SynologyPhotoSpace.PERSONAL))
        f.model.enter(f.model.state.value.children.first { it.id == 9L }); ready(f.model)
        assertFalse(f.model.canSave); assertNull(f.model.save()); assertEquals(0, f.api.writes)
    } }
    @Test fun `未知任务冷热恢复只读不能清除未决记录`() = runBlocking { fixture { f ->
        f.api.knownId = false; f.open(); f.destination(); f.model.save()!!.join()
        val id = f.model.state.value.records.single().id
        f.model.resume(id)!!.join(); f.model.discard(id)!!.join()
        assertEquals(1, f.store.records(f.owner, 41).size); assertEquals(1, f.api.writes)
        val restored = f.create()
        try {
            restored.showRecords(); await { restored.state.value.records.isNotEmpty() }
            restored.resume(id)!!.join(); assertEquals(2, f.api.reviews); assertEquals(1, f.api.writes)
        } finally { restored.close() }
    } }
    @Test fun `已知未决任务在图库活跃时自动只读恢复结束后停止`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(); f.destination(); f.model.save()!!.join()
        f.model.activate(); f.api.pending = false
        await { f.model.state.value.records.single().checkpoint.finished }
        assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
        assertEquals(1, f.completions.count { it.finished })
        f.model.deactivate()
    } }
    @Test fun `未发送记录只恢复表单重新选择后新操作替换旧记录`() = runBlocking { fixture { f ->
        f.open(); f.destination()
        val draft = f.model.state.value.draft!!.checkpoint
        val input = draft.copy(files = draft.files!!.copy(destination = f.model.state.value.folderAccess!!.folder))
        f.store.begin(SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = input))
        f.model.showRecords(); await { f.model.state.value.records.isNotEmpty() }
        f.model.resume(input.operationId)!!.join(); f.destination()
        assertEquals(0, f.api.writes); assertNotEquals(input.operationId, f.model.state.value.draft!!.checkpoint.operationId)
        f.model.save()!!.join(); assertEquals(1, f.api.writes)
        assertEquals(f.api.last!!.operationId, f.store.records(f.owner, 41).single().id)
    } }
    @Test fun `已提交事实阻止新操作恢复不重发且账号撤销不采纳晚到读取`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(); f.destination(); f.model.save()!!.join()
        try { f.model.requireNoPending(); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, error.problem) }
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeBrowse = { started.complete(Unit); withContext(NonCancellable) { release.await() } }
        f.model.open(SynologyPhotoAlbumAction.COPY_ITEMS, listOf(photo(SynologyPhotoSpace.PERSONAL)), listOf(folder(10, 9, "/Source/Child", SynologyPhotoSpace.PERSONAL)))
        started.await(); f.validOwner = false; f.model.revokeAccess(); release.complete(Unit)
        await { !f.model.state.value.loading && !f.model.state.value.browsing }
        assertNull(f.model.state.value.draft); assertFalse(f.model.state.value.visible); assertEquals(1, f.api.writes)
        assertEquals(1, f.store.records(f.owner, 41).size)
    } }
    @Test fun `只读恢复不要求重新接受覆盖且保留最初策略`() = runBlocking { fixture { f ->
        f.api.duplicate = SynologyPhotoTransferDuplicate.OVERWRITE; f.api.pending = true
        f.open(); f.destination(); f.model.save(true)!!.join()
        f.api.duplicate = SynologyPhotoTransferDuplicate.SKIP; f.api.pending = false
        val id = f.model.state.value.records.single().id; f.model.resume(id)!!.join()
        assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
        assertEquals(SynologyPhotoTransferDuplicate.OVERWRITE, f.model.state.value.records.single().checkpoint.files!!.duplicate)
    } }
    @Test fun `混合删除从原父目录局部移除并修正下一页偏移不漏照片`() = runBlocking { fixture { f ->
        f.api.apply = true
        f.api.photoRows += (22L..23L).map { photo(SynologyPhotoSpace.PERSONAL).copy(id = SynologyPhotoId(f.api.profileId, SynologyPhotoSpace.PERSONAL, it), filename = "Synthetic$it.jpg") }
        f.root(1).use { root ->
            openSource(root)
            assertEquals(listOf(21L), root.state.value.items.map { it.id.itemId }); assertTrue(root.state.value.hasMore)
            val files = root.files!!
            files.open(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS, root.state.value.items, root.state.value.collections); ready(files); files.save()!!.join()
            assertEquals(9L, root.state.value.navigation.folders.last().id); assertTrue(root.state.value.items.isEmpty()); assertTrue(root.state.value.collections.isEmpty())
            root.loadMore()!!.join()
            assertFalse(root.state.value.hasMoreCollections); assertTrue(root.state.value.items.isEmpty())
            root.loadMore()!!.join()
            assertEquals(listOf(22L), root.state.value.items.map { it.id.itemId }); assertTrue(root.state.value.hasMore)
        }
    } }
    @Test fun `恢复结束不移除其他来源的同编号照片和文件夹`() = runBlocking { fixture { f ->
        f.api.pending = true
        f.root().use { root ->
            openSource(root); val files = root.files!!
            files.open(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS, root.state.value.items, root.state.value.collections); ready(files); files.save()!!.join()
            val id = files.state.value.records.single().id
            root.selectSpace(SynologyPhotoSpace.SHARED); await { root.state.value.loaded && !root.state.value.loading }
            root.openCollection(root.state.value.collections.first { it.id == 9L }); await { root.state.value.loaded && !root.state.value.loading }
            f.api.pending = false; files.resume(id)!!.join()
            assertEquals(SynologyPhotoSpace.SHARED, root.state.value.navigation.space)
            assertEquals(listOf(21L), root.state.value.items.map { it.id.itemId }); assertEquals(listOf(10L), root.state.value.collections.map { it.id })
        }
    } }
    @Test fun `处理期间进入所选目录回读后返回存活父级而不跳时间线`() = runBlocking { fixture { f ->
        f.api.pending = true
        f.root().use { root ->
            openSource(root); val files = root.files!!
            files.open(SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS, root.state.value.items, root.state.value.collections); ready(files); files.save()!!.join()
            val id = files.state.value.records.single().id
            root.openCollection(root.state.value.collections.single()); await { root.state.value.loaded && !root.state.value.loading }
            assertEquals(10L, root.state.value.navigation.folders.last().id)
            files.resume(id)!!.join(); await { root.state.value.loaded && !root.state.value.loading }
            assertEquals(SynologyPhotosSection.FOLDERS, root.state.value.navigation.section); assertEquals(9L, root.state.value.navigation.folders.last().id)
        }
    } }

    companion object {
        private fun folder(id: Long, parent: Long, path: String, space: SynologyPhotoSpace) = SynologyPhotoCollection(id,
            path.substringAfterLast('/').ifEmpty { "/" }, parentId = parent, path = path, space = space)
        private fun snapshot(folder: SynologyPhotoCollection) = SynologyPhotoFolderSnapshot(folder.id, folder.parentId, folder.name, folder.path!!, folder.space)
        private fun photo(space: SynologyPhotoSpace) = SynologyPhoto(SynologyPhotoId("file-model", space, 21), "Synthetic.jpg", 4, 20.0, 30.0, 9, "photo")
        private suspend fun ready(model: SynologyPhotoFileModel) = await { !model.state.value.loading && !model.state.value.browsing }
        private suspend fun openSource(model: SynologyPhotosModel) {
            model.activate(); await { model.state.value.loaded && !model.state.value.loading }
            model.selectSection(SynologyPhotosSection.FOLDERS); await { model.state.value.loaded && !model.state.value.loading }
            model.openCollection(model.state.value.collections.first { it.id == 9L }); await { model.state.value.loaded && !model.state.value.loading }
        }
        private suspend fun await(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(10) } }
        private suspend fun fixture(block: suspend (Fixture) -> Unit) {
            val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.cancel() }
        }
    }
}
