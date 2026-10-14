package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoRequestCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoRequestModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "request-model"
        override val canManageAlbums = true
        override val canManagePhotoRequests = true
        var access = SynologyPhotoAccess(listOf(SynologyPhotoSpace.PERSONAL, SynologyPhotoSpace.SHARED), "synthetic")
        var value = SynologyPhotoRequest("synthetic-secret", profileId, SynologyPhotoRequestSettings("Synthetic", "description",
            folderId = 9, folderPath = "/Synthetic", sizeLimit = 1_048_577), true, url = "https://example.invalid/collection")
        var candidates = listOf(SynologyPhotoRequestAlbum(71, name = "Private album", shared = false),
            SynologyPhotoRequestAlbum(passphrase = "synthetic-contributor", name = "Shared album", shared = true, sourceAlbumId = 72))
        var writes = 0; var reviews = 0; var pending = false; var failRead = false; var missing = false; var lastChange: SynologyPhotoRequestChange? = null
        var beforeWrite: suspend () -> Unit = {}; var beforeRead: suspend () -> Unit = {}
        override suspend fun access() = access
        override suspend fun photoEditIdentity() = 41L
        override suspend fun photoRequest(id: String): SynologyPhotoRequest { beforeRead(); if (failRead) throw IOException("Synthetic read"); return value }
        override suspend fun restoredPhotoRequest(checkpoint: SynologyPhotoAlbumCheckpoint) = value.takeUnless { missing }
        override suspend fun photoRequestAlbums() = candidates
        override suspend fun preparePhotoRequest(checkpoint: SynologyPhotoAlbumCheckpoint, change: SynologyPhotoRequestChange) { if (failRead) throw IOException("Synthetic preflight") }
        override suspend fun performPhotoRequest(checkpoint: SynologyPhotoAlbumCheckpoint, change: SynologyPhotoRequestChange, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); beforeWrite(); writes++; lastChange = change
            change.settings?.let { value = value.copy(settings = it, isFolderValid = true) }
            return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED,
                request = checkpoint.request!!.copy(targetDigest = SynologyPhotoRequestCodec.hash(value.id))).also(save)
        }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); beforeWrite(); writes++
            return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED,
                createdAlbumId = 73).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++
            return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED).also(save)
        }
        override suspend fun rootFolder(space: SynologyPhotoSpace) = SynologyPhotoCollection(1, "/", space = space, path = "/")
        override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int) =
            if (parentId == 1L) listOf(SynologyPhotoCollection(9, "Synthetic", 1, space = space, path = "/Synthetic")) else emptyList()
        override suspend fun photoRequestFolder(space: SynologyPhotoSpace, id: Long) = SynologyPhotoCollection(id, "Synthetic", 1, space = space, path = "/Synthetic")
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
    }
    private class Fixture {
        val api = Api(); val preferences = MemoryPreferences(); val store = SynologyPhotoAlbumStore(preferences)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session")
        var allowed = true; var validOwner = true
        fun model() = SynologyPhotoRequestModel(api, scope, store, owner, { if (!validOwner) throw CancellationException() }, { api.access }, { allowed }, onCompleted = {})
        val model = model()
    }
    @Test fun `打开编辑保留精确字节大小未改字段和纯读取行为`() = runBlocking { fixture { f ->
        f.model.open(f.api.value.id); ready(f.model)
        assertEquals(0, f.api.writes); assertFalse(f.model.canSave)
        f.model.description("new description"); f.model.save()!!.join()
        assertEquals(1_048_577L, f.api.lastChange!!.settings!!.sizeLimit)
        assertNull(f.model.state.value.draft); assertTrue(f.model.state.value.records.single().checkpoint.finished)
        assertFalse(f.preferences.all.values.toString().contains("synthetic-secret"))
        assertFalse(f.preferences.all.values.toString().contains("description"))
    } }
    @Test fun `共享entry需选择可上传目录切换来源丢弃旧目录不丢其他字段`() = runBlocking { fixture { f ->
        f.api.access = f.api.access.copy(spaces = listOf(SynologyPhotoSpace.SHARED))
        f.model.open(); ready(f.model); f.model.subject("New")
        assertFalse(f.model.state.value.draft!!.usesDefaultFolder); assertFalse(f.model.canSave)
        f.model.folders()!!.join(); val folder = f.model.state.value.folders.single()
        f.model.folders(f.model.state.value.folderPath + folder)!!.join(); f.model.chooseFolder()!!.join()
        assertEquals("/Synthetic", f.model.state.value.draft!!.settings.folderPath); assertTrue(f.model.canSave)
        f.api.access = f.api.access.copy(spaces = listOf(SynologyPhotoSpace.PERSONAL, SynologyPhotoSpace.SHARED))
        f.model.changeSpace(SynologyPhotoSpace.PERSONAL)
        assertNull(f.model.state.value.draft!!.settings.folderId); assertTrue(f.model.state.value.draft!!.usesDefaultFolder)
        assertEquals("New", f.model.state.value.draft!!.settings.subject)
    } }
    @Test fun `失效目录阻止编辑但不阻止明确删除`() = runBlocking { fixture { f ->
        f.api.value = f.api.value.copy(isFolderValid = false)
        f.model.open(f.api.value.id); ready(f.model); f.model.subject("Edited"); assertFalse(f.model.canSave)
        f.model.open(f.api.value.id, delete = true); ready(f.model); assertTrue(f.model.canSave)
        f.model.save()!!.join(); assertNull(f.api.lastChange!!.settings); assertEquals(1, f.api.writes)
        assertEquals(SynologyPhotoAlbumAction.DELETE_REQUEST, f.model.state.value.records.single().checkpoint.action)
    } }
    @Test fun `写入中双击被阻止且同账号互斥结束后释放`() = runBlocking { fixture { f ->
        val entered = CompletableDeferred<Unit>(); val released = CompletableDeferred<Unit>()
        f.api.beforeWrite = { entered.complete(Unit); released.await() }
        f.model.open(); ready(f.model); f.model.subject("New"); val task = f.model.save()!!; entered.await()
        assertNull(f.model.save()); assertTrue(SynologyPhotoAlbumStore.isProfileBusy(f.owner.profileId))
        released.complete(Unit); task.join(); assertEquals(1, f.api.writes); assertFalse(SynologyPhotoAlbumStore.isProfileBusy(f.owner.profileId))
    } }
    @Test fun `未知提交冷恢复只读且不能清除记录`() = runBlocking { fixture { f ->
        f.api.pending = true; f.model.open(); ready(f.model); f.model.subject("New"); f.model.save()!!.join()
        val id = f.model.state.value.records.single().id
        f.model.discard(id)!!.join(); assertEquals(1, f.store.records(f.owner, 41).size)
        f.model.close(); val restored = f.model()
        try {
            restored.showRecords(); await { restored.state.value.records.isNotEmpty() }
            restored.resume(id)!!.join(); assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
            f.api.pending = false; restored.resume(id)!!.join(); assertTrue(restored.state.value.records.single().checkpoint.finished)
            assertEquals(1, f.api.writes); assertTrue(f.store.records(f.owner.copy(identityRevision = "other"), 41).isEmpty())
        } finally { restored.close() }
    } }
    @Test fun `未发送恢复重建可编辑草稿必须再次确认不恢复明文`() = runBlocking { fixture { f ->
        val change = SynologyPhotoRequestChange(f.api.value, f.api.value.settings.copy(subject = "Unsent"))
        val row = SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = f.owner.profileId,
            userId = 41, action = SynologyPhotoAlbumAction.UPDATE_REQUEST, request = SynologyPhotoRequestCodec.checkpoint(SynologyPhotoAlbumAction.UPDATE_REQUEST, change)))
        f.store.begin(row); f.model.showRecords(); await { f.model.state.value.records.isNotEmpty() }
        f.model.resume(row.id)!!.join(); assertEquals(0, f.api.writes); assertFalse(f.model.canSave)
        assertEquals("Synthetic", f.model.state.value.draft!!.settings.subject)
        f.model.subject("Explicit edit"); f.model.save()!!.join()
        assertEquals(1, f.api.writes); assertEquals(1, f.store.records(f.owner, 41).size)
        assertNotEquals(row.id, f.model.state.value.records.single().id)
    } }
    @Test fun `创建完成后对象缺失不能恢复为新建表单`() = runBlocking { fixture { f ->
        f.model.open(); ready(f.model); f.model.subject("New"); f.model.save()!!.join()
        val row = f.model.state.value.records.single(); assertTrue(row.checkpoint.finished)
        f.api.missing = true; f.model.reopen(row)!!.join()
        assertNull(f.model.state.value.draft); assertNull(f.model.state.value.result); assertNotNull(f.model.state.value.error); assertEquals(1, f.api.writes)
    } }
    @Test fun `未发送删除恢复保留删除后果表单再次确认前不写`() = runBlocking { fixture { f ->
        val change = SynologyPhotoRequestChange(f.api.value)
        val row = SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = f.owner.profileId,
            userId = 41, action = SynologyPhotoAlbumAction.DELETE_REQUEST, request = SynologyPhotoRequestCodec.checkpoint(SynologyPhotoAlbumAction.DELETE_REQUEST, change)))
        f.store.begin(row); f.model.showRecords(); await { f.model.state.value.records.isNotEmpty() }
        f.model.resume(row.id)!!.join(); assertTrue(f.model.state.value.draft!!.deleting); assertEquals(0, f.api.writes)
        f.model.save()!!.join(); assertNull(f.api.lastChange!!.settings); assertEquals(1, f.api.writes)
    } }
    @Test fun `表单新建相册只有确认编号才选中未知刷新不重建`() = runBlocking { fixture { f ->
        f.model.open(); ready(f.model); f.model.selectAlbums()!!.join(); f.model.albumName("New album")
        f.api.pending = true; f.model.createAlbum()!!.join()
        assertNull(f.model.state.value.draft!!.settings.albumId); assertNotNull(f.model.state.value.pendingAlbum); assertNull(f.model.createAlbum())
        f.model.reviewAlbum()!!.join(); assertEquals(1, f.api.writes)
        f.api.pending = false; f.model.reviewAlbum()!!.join()
        assertEquals(73L, f.model.state.value.draft!!.settings.albumId); assertNull(f.model.state.value.pendingAlbum)
        assertEquals(SynologyPhotoRequestPage.FORM, f.model.state.value.page); assertEquals(1, f.api.writes)
    } }
    @Test fun `贡献相册与文件夹快捷入口来自实际候选和完整路径`() = runBlocking { fixture { f ->
        f.model.open(albumId = 72); ready(f.model)
        assertEquals("synthetic-contributor", f.model.state.value.draft!!.settings.albumPassphrase); assertNull(f.model.state.value.draft!!.settings.albumId)
        f.model.open(folder = SynologyPhotoCollection(9, "Synthetic", path = "/Synthetic")); ready(f.model)
        assertFalse(f.model.state.value.draft!!.usesDefaultFolder); assertEquals(9L, f.model.state.value.draft!!.settings.folderId)
        f.model.open(folder = SynologyPhotoCollection(9, "Synthetic", path = "/changed")); ready(f.model)
        assertNotNull(f.model.state.value.error); assertNull(f.model.save()); assertEquals(0, f.api.writes)
    } }
    @Test fun `撤权或关闭不接受迟到读取读取失败可以重试`() = runBlocking { fixture { f ->
        val entered = CompletableDeferred<Unit>(); val released = CompletableDeferred<Unit>()
        f.api.beforeRead = { entered.complete(Unit); withContext(NonCancellable) { released.await() } }
        f.model.open(f.api.value.id); entered.await(); f.model.revokeAccess(); released.complete(Unit)
        await { !f.model.state.value.loading }; delay(30); assertNull(f.model.state.value.draft); assertFalse(f.model.state.value.visible)
        f.api.beforeRead = {}; f.api.failRead = true; f.model.open(f.api.value.id); ready(f.model)
        assertNotNull(f.model.state.value.error); assertNull(f.model.save())
        f.api.failRead = false; f.model.load()!!.join(); assertNotNull(f.model.state.value.draft); assertNull(f.model.state.value.error)
    } }
    @Test fun `同页字段校验支持UTF16限额范围以及旧大小未编辑保持`() = runBlocking { fixture { f ->
        f.model.open(); ready(f.model); f.model.subject("😀".repeat(26)); assertFalse(f.model.canSave)
        f.model.subject("New"); f.model.limitsSize(true); f.model.size("3001"); assertFalse(f.model.canSave)
        f.model.size("25"); assertTrue(f.model.canSave); f.model.description("x".repeat(101)); assertFalse(f.model.canSave)
        f.model.description(""); f.model.save()!!.join(); assertEquals(25L * 1_048_576, f.api.lastChange!!.settings!!.sizeLimit)
    } }
    @Test fun `提交前网络失败保留草稿恢复网络后无需改字即可重试`() = runBlocking { fixture { f ->
        f.model.open(); ready(f.model); f.model.subject("Synthetic retry"); f.api.failRead = true
        f.model.save()!!.join(); assertNotNull(f.model.state.value.error); assertNotNull(f.model.state.value.draft)
        assertTrue(f.model.canSave); assertEquals(0, f.api.writes); assertTrue(f.store.records(f.owner, 41).isEmpty())
        f.api.failRead = false; f.model.save()!!.join(); assertEquals(1, f.api.writes); assertTrue(f.model.state.value.records.single().checkpoint.finished)
    } }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.coroutineContext[Job]!!.cancelAndJoin() }
    }
    private suspend fun ready(model: SynologyPhotoRequestModel) = await { !model.state.value.loading }
    private suspend fun await(condition: () -> Boolean) = withTimeout(5_000) { while (!condition()) delay(5) }
}
