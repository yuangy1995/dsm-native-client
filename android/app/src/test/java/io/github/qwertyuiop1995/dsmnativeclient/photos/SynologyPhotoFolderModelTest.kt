package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoFolderCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoFolderModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "folder-model"
        override val canManageFolders = true
        val folders = mutableMapOf(1L to folder(1, 0, "/"), 9L to folder(9, 1, "/Synthetic"), 10L to folder(10, 9, "/Synthetic/Child"))
        var writes = 0; var reviews = 0; var pending = false; var failRead = false; var failPrepare = false
        var last: SynologyPhotoAlbumCheckpoint? = null
        var beforeWrite: suspend () -> Unit = {}; var beforeRead: suspend () -> Unit = {}
        val queries = mutableListOf<SynologyPhotoQuery>(); val directions = mutableListOf<SynologyPhotoSort.Direction>()
        override suspend fun access() = SynologyPhotoAccess(listOf(SynologyPhotoSpace.PERSONAL), "synthetic")
        override suspend fun photoEditIdentity() = 41L
        override suspend fun folderAccess(space: SynologyPhotoSpace, id: Long): SynologyPhotoFolderAccess {
            beforeRead(); if (failRead) throw IOException("Synthetic folder read")
            return folders.getValue(id)
        }
        override suspend fun rootFolder(space: SynologyPhotoSpace) = folders.getValue(1).collection()
        override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int, direction: SynologyPhotoSort.Direction): List<SynologyPhotoCollection> {
            directions += direction
            return folders.values.filter { it.folder.parentId == parentId }.map { it.collection() }.drop(offset).take(limit)
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) { if (failPrepare) throw IOException("Synthetic preflight") }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); beforeWrite(); writes++; last = checkpoint
            val operation = checkpoint.folder!!; var next = operation
            val target = folders.getValue(operation.target.id)
            when (checkpoint.action) {
                SynologyPhotoAlbumAction.CREATE_FOLDER -> {
                    folders[11] = folder(11, operation.target.id, SynologyPhotoFolderCodec.childPath(operation.target.path, operation.name!!)); next = operation.copy(createdFolderId = 11)
                }
                SynologyPhotoAlbumAction.RENAME_FOLDER -> folders[operation.target.id] = target.copy(folder = target.folder.copy(name = operation.name!!, path = SynologyPhotoFolderCodec.renamedPath(target.folder, operation.name)))
                SynologyPhotoAlbumAction.SORT_FOLDER -> folders[operation.target.id] = target.copy(sort = operation.sort!!, explicitSort = operation.sort)
                SynologyPhotoAlbumAction.COVER_FOLDER -> { next = operation.copy(coverAcknowledged = true); folders[operation.target.id] = target.copy(covers = listOf(SynologyPhotoFolderCover("new", sequence = 0))) }
                else -> error("Unexpected synthetic action")
            }
            return checkpoint.copy(folder = next, phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED).also(save)
        }
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            queries += query
            val id = (query as? SynologyPhotoQuery.Folder)?.id
            val photos = if (id != null && offset == 0) listOf(photo(id)) else emptyList()
            return SynologyPhotoPage(photos, offset, offset + photos.size, false)
        }
    }
    private class Fixture {
        val api = Api(); val preferences = MemoryPreferences(); val store = SynologyPhotoAlbumStore(preferences)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session")
        var allowed = true; var validOwner = true; var completions = 0
        fun model() = SynologyPhotoFolderModel(api, scope, store, owner, { if (!validOwner) throw CancellationException() }, { allowed }, onCompleted = { _, _ -> completions++ })
        val model = model()
        fun open(action: SynologyPhotoAlbumAction) = model.open(action, api.folders.getValue(9).collection())
    }
    @Test fun `名称校验普通保存按钮与新建实际编号记录`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoAlbumAction.CREATE_FOLDER); ready(f.model); assertFalse(f.model.canSave)
        f.model.name("a/b"); assertFalse(f.model.canSave); assertNull(f.model.save())
        f.model.name(" New "); f.model.save()!!.join()
        assertEquals("New", f.api.last!!.folder!!.name); assertEquals(11L, f.model.state.value.records.single().checkpoint.folder!!.createdFolderId)
        assertTrue(f.model.state.value.recordsPage); assertEquals(1, f.completions)
    } }
    @Test fun `最初读取失败和提交前断网可以重试且不保存假提交`() = runBlocking { fixture { f ->
        f.api.failRead = true; f.open(SynologyPhotoAlbumAction.RENAME_FOLDER); ready(f.model)
        assertNull(f.model.state.value.draft); assertFalse(f.model.canSave)
        f.api.failRead = false; f.model.load()!!.join(); f.model.name("Renamed")
        f.api.failPrepare = true; f.model.save()!!.join()
        assertTrue(f.store.records(f.owner, 41).isEmpty()); assertTrue(f.model.canSave); assertEquals(0, f.api.writes)
        f.api.failPrepare = false; f.model.save()!!.join(); assertEquals(1, f.api.writes)
    } }
    @Test fun `未知操作冷热刷新只读取且不清理未知记录`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(SynologyPhotoAlbumAction.CREATE_FOLDER); ready(f.model); f.model.name("New"); f.model.save()!!.join()
        val id = f.model.state.value.records.single().id
        f.model.resume(id)!!.join(); assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
        f.model.discard(id)!!.join(); assertEquals(1, f.store.records(f.owner, 41).size)
        val restored = f.model()
        try {
            restored.showRecords(); restored.refreshRecords()?.join(); await { restored.state.value.records.isNotEmpty() }
            f.api.pending = false; restored.resume(id)!!.join(); assertTrue(restored.state.value.records.single().checkpoint.finished)
            assertEquals(1, f.api.writes); assertEquals(2, f.api.reviews)
        } finally { restored.close() }
    } }
    @Test fun `未提交记录恢复回表单重新明确保存且不能关闭后自动写入`() = runBlocking { fixture { f ->
        val checkpoint = SynologyPhotoAlbumCheckpoint(profileId = f.owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE_FOLDER,
            folder = SynologyPhotoFolderCheckpoint(f.api.folders.getValue(9).folder, name = "Draft"))
        f.store.begin(SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = checkpoint))
        f.model.showRecords(); await { f.model.state.value.records.size == 1 }
        f.model.resume(checkpoint.operationId)!!.join(); assertEquals("Draft", f.model.state.value.draft!!.name); assertEquals(0, f.api.writes)
        f.model.name("Changed"); f.model.save()!!.join()
        assertEquals("Changed", f.api.last!!.folder!!.name); assertEquals(1, f.store.records(f.owner, 41).size)
    } }
    @Test fun `封面浏览子目录只改变候选来源始终保存原目录并保持实际排序`() = runBlocking { fixture { f ->
        val sort = SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME, SynologyPhotoSort.Direction.DESCENDING)
        f.api.folders[10] = f.api.folders.getValue(10).copy(sort = sort)
        f.open(SynologyPhotoAlbumAction.COVER_FOLDER); ready(f.model); await { !f.model.state.value.browsing }
        f.model.enter(f.model.state.value.children.single()); await { !f.model.state.value.browsing && f.model.state.value.path.size == 2 }
        assertEquals(SynologyPhotoQuery.Folder(10, sort), f.api.queries.last()); assertEquals(sort.direction, f.api.directions.last())
        f.model.select(f.model.state.value.photos.single()); f.model.save()!!.join()
        assertEquals(9L, f.api.last!!.folder!!.target.id); assertEquals(10L, f.api.last!!.folder!!.coverPhoto!!.folderId)
    } }
    @Test fun `封面浏览拒绝其他目标或来源路径选中项必须来自实际已读列表`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoAlbumAction.COVER_FOLDER); ready(f.model); await { !f.model.state.value.browsing }
        f.model.select(photo(10)); assertNull(f.model.state.value.draft!!.photo)
        val child = f.model.state.value.children.single()
        assertNull(f.model.browse(listOf(child)))
        assertNull(f.model.browse(f.model.state.value.path + child.copy(space = SynologyPhotoSpace.SHARED)))
        f.model.enter(child); await { !f.model.state.value.browsing && f.model.state.value.path.size == 2 }
        f.model.backTo(0); await { !f.model.state.value.browsing && f.model.state.value.path.size == 1 }
        assertEquals(9L, f.model.state.value.path.single().id)
    } }
    @Test fun `查看权限可排序但无管理不能改名或封面无创建权不能新建`() = runBlocking { fixture { f ->
        f.api.folders[9] = f.api.folders.getValue(9).copy(canCreate = false, canManage = false)
        for (action in listOf(SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoAlbumAction.RENAME_FOLDER, SynologyPhotoAlbumAction.COVER_FOLDER)) {
            f.open(action); ready(f.model); assertNull(f.model.state.value.draft); assertNotNull(f.model.state.value.error)
        }
        f.open(SynologyPhotoAlbumAction.SORT_FOLDER); ready(f.model)
        f.model.sort(SynologyPhotoSort(direction = SynologyPhotoSort.Direction.DESCENDING)); assertTrue(f.model.canSave)
        f.model.save()!!.join(); assertEquals(1, f.api.writes)
    } }
    @Test fun `关闭正在执行的表单保留互斥和操作事实并拒绝重复保存`() = runBlocking { fixture { f ->
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { started.complete(Unit); release.await() }
        f.open(SynologyPhotoAlbumAction.CREATE_FOLDER); ready(f.model); f.model.name("New")
        val worker = f.model.save()!!; started.await(); f.model.dismiss()
        assertFalse(f.model.state.value.visible); assertTrue(SynologyPhotoAlbumStore.isProfileBusy(f.owner.profileId)); assertNull(f.model.save())
        release.complete(Unit); worker.join(); assertEquals(1, f.api.writes); assertTrue(f.store.records(f.owner, 41).single().checkpoint.finished)
        assertFalse(SynologyPhotoAlbumStore.isProfileBusy(f.owner.profileId))
    } }
    @Test fun `冷恢复的未决目录阻止关联管理且账号改变不能读取旧记录`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(SynologyPhotoAlbumAction.CREATE_FOLDER); ready(f.model); f.model.name("New"); f.model.save()!!.join()
        try { f.model.requireNoPending(); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, error.problem) }
        assertTrue(f.store.records(f.owner.copy(identityRevision = "other"), 41).isEmpty())
        f.allowed = false; f.model.showRecords(); await { f.model.state.value.records.isNotEmpty() }; assertNull(f.model.resume(f.model.state.value.records.single().id))
    } }
    @Test fun `图库目录读取真实排序并在改名完成后留在原位置`() = runBlocking { fixture { f ->
        val sort = SynologyPhotoSort(SynologyPhotoSort.Field.FILESIZE, SynologyPhotoSort.Direction.DESCENDING)
        f.api.folders[9] = f.api.folders.getValue(9).copy(sort = sort)
        val library = SynologyPhotosModel(f.api, f.scope, albumStore = f.store, uploadOwner = f.owner)
        try {
            library.activate(); await { library.state.value.loaded }
            library.selectSection(SynologyPhotosSection.FOLDERS); await { library.state.value.loaded }
            library.openCollection(library.state.value.collections.single()); await { library.state.value.loaded }
            assertEquals(SynologyPhotoQuery.Folder(9, sort), f.api.queries.last()); assertEquals(sort.direction, f.api.directions.last())
            val location = library.state.value.navigation.locationKey; val items = library.state.value.items; val calls = f.api.queries.size
            val folders = library.folders!!; folders.open(SynologyPhotoAlbumAction.RENAME_FOLDER, library.state.value.navigation.folders.last()); ready(folders)
            folders.name("Renamed"); folders.save()!!.join()
            assertEquals(location, library.state.value.navigation.locationKey); assertEquals(items, library.state.value.items); assertEquals(calls, f.api.queries.size)
            assertEquals("Renamed", library.state.value.navigation.folders.last().name)
            assertEquals("/Renamed/Child", library.state.value.collections.single().path)
        } finally { library.close() }
    } }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) { val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.cancel() } }
    private suspend fun ready(model: SynologyPhotoFolderModel) = await { !model.state.value.loading }
    private suspend fun await(condition: () -> Boolean) = withTimeout(10_000) { while (!condition()) delay(5) }
    companion object {
        private fun folder(id: Long, parent: Long, path: String) = SynologyPhotoFolderAccess(
            SynologyPhotoFolderSnapshot(id, parent, path.substringAfterLast('/').ifEmpty { "/" }, path, SynologyPhotoSpace.PERSONAL), true, true, SynologyPhotoSort(), null)
        private fun photo(folder: Long) = SynologyPhoto(SynologyPhotoId("folder-model", SynologyPhotoSpace.PERSONAL, folder + 100), "Synthetic.jpg", 4, 1.0, 2.0, folder, "photo")
    }
}
