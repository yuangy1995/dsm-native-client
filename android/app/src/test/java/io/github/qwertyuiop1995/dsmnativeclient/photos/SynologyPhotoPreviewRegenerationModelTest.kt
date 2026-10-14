package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosPreviewRepositoryTest.Fixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.File
import java.time.*
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.junit.Assert.*
import org.junit.Test

/** 模型连接正式预检、逐项仓储和持久存储；网络、图片与生命周期边界为合成夹具。 */
class SynologyPhotoPreviewRegenerationModelTest {
    private class Scenario {
        val data = Fixture().apply { owner = owner.copy(profileId = "preview-model-${UUID.randomUUID()}") }
        val photo = data.photo(); val second = data.photo(52, "Second.jpg")
        var repository = data.repository()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(data.owner.profileId, "identity", "session")
        val store = SynologyPhotoAlbumStore(MemoryPreferences()); val editStore = SynologyPhotoEditStore(MemoryPreferences())
        val pauses = CopyOnWriteArrayList<Long>(); val ticks = Channel<Unit>(Channel.UNLIMITED)
        val updated = CopyOnWriteArrayList<SynologyPhotoEditTarget>()
        var current = true; var enabled = true; var pages = 0; var reviews = 0; var queueReads = 0
        var beforePrepare: suspend () -> Unit = {}; var before: suspend () -> Unit = {}
        val api = object : SynologyPhotosServing {
            override val profileId get() = data.owner.profileId
            override val canEditPhotos = true; override val canManageAlbums = true
            override suspend fun photoEditIdentity() = data.owner.userId
            override fun canRegeneratePreviews(space: SynologyPhotoSpace) = space in data.enabledSpaces
            override suspend fun pendingPreviewRegenerations(space: SynologyPhotoSpace): List<SynologyPhoto> { queueReads++; return repository.pendingPreviews(space) }
            override suspend fun preparePreviewRegeneration(photos: List<SynologyPhoto>, resuming: Boolean): SynologyPhotoAlbumCheckpoint {
                val row = repository.preparePreviews(photos, resuming); beforePrepare(); return row
            }
            override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) = repository.prepare(checkpoint)
            override suspend fun performPreviewRegeneration(checkpoint: SynologyPhotoAlbumCheckpoint, cache: File, save: (SynologyPhotoAlbumCheckpoint) -> Unit) = repository.perform(checkpoint, previewCache = cache, save = save)
            override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint { reviews++; return repository.review(checkpoint, save) }
            override suspend fun access() = SynologyPhotoAccess(data.enabledSpaces.toList(), "synthetic", data.owner.managesShared)
            override suspend fun categories(space: SynologyPhotoSpace) = emptySet<SynologyPhotoCategory>()
            override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 2), SynologyPhotoDay(LocalDate.of(2020, 2, 1), 2))
            override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
                pages++; val all = listOf(data.photos.getValue(photo.id), data.photos.getValue(second.id))
                return SynologyPhotoPage(all.drop(offset).take(limit), offset, minOf(offset + limit, all.size), offset + limit < all.size)
            }
            override suspend fun details(photo: SynologyPhoto) = data.photos.getValue(photo.id)
            override suspend fun thumbnail(photo: SynologyPhoto, large: Boolean) = byteArrayOf(if (photo.thumbnail?.revision == "new") 2 else 1)
            override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
        }
        fun newModel() = SynologyPhotoPreviewRegenerationModel(api, scope, store, owner,
            { if (!current) throw CancellationException() }, { enabled }, { before() }, { updated.addAll(it) },
            pause = { pauses += it; ticks.receive() })
        val model = newModel()
        fun root() = SynologyPhotosModel(api, scope, pageSize = 1, zone = ZoneOffset.UTC, uploadOwner = owner, albumStore = store, editStore = editStore)
        suspend fun open() { model.open(listOf(photo), data.cache); await { !model.state.value.loading } }
        suspend fun submit() { model.request()!!.join(); assertNotNull(model.state.value.confirmation); model.confirm()!!.join() }
        suspend fun close() { model.close(); scope.coroutineContext[Job]!!.cancelAndJoin(); assertTrue(data.cache.deleteRecursively()) }
    }
    @Test fun `打开选择预检返回取消均不写确认后才逐项执行`() = runBlocking { scenario { f ->
        f.open(); f.model.request()!!.join(); assertEquals(f.photo.id, f.model.state.value.confirmation!!.targets.single().id)
        f.model.cancelConfirmation(); assertNull(f.model.confirm()); assertTrue(f.data.writes.isEmpty()); assertTrue(f.store.records(f.owner, 41).isEmpty())
        f.submit(); assertEquals(listOf("set_regenerating", "regenerate_preview_by_nas"), f.data.writes)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, f.model.state.value.records.single().checkpoint.phase)
        assertEquals(listOf(f.photo.id), f.updated.map { it.id }); assertEquals(0, f.pages)
    } }
    @Test fun `队列进入不自动选择只继续显式选择的原件且不再次标记`() = runBlocking { scenario { f ->
        f.data.queue += listOf(f.photo.id, f.second.id); f.model.openQueue(SynologyPhotoSpace.PERSONAL, f.data.cache)
        await { !f.model.state.value.loading }; assertTrue(f.model.state.value.selected.isEmpty()); assertNull(f.model.request())
        f.model.search("Second"); assertEquals(listOf(f.second), f.model.state.value.filtered)
        f.model.toggle(f.second); f.submit()
        assertTrue(f.model.state.value.records.single().checkpoint.previews!!.resuming)
        assertEquals(listOf("regenerate_preview_by_nas"), f.data.writes); assertTrue(f.photo.id in f.data.queue); assertFalse(f.second.id in f.data.queue)
    } }
    @Test fun `队列切换来源和读取失败都清除旧选择空筛选不改选择`() = runBlocking { scenario { f ->
        f.data.queue += f.photo.id; f.model.openQueue(SynologyPhotoSpace.PERSONAL, f.data.cache); await { !f.model.state.value.loading }
        f.model.toggle(f.photo); f.model.search("missing"); assertTrue(f.model.state.value.filtered.isEmpty()); assertEquals(setOf(f.photo.id), f.model.state.value.selected)
        f.model.selectSpace(SynologyPhotoSpace.SHARED); await { !f.model.state.value.loading }
        assertTrue(f.model.state.value.photos.isEmpty()); assertTrue(f.model.state.value.selected.isEmpty())
        f.model.selectSpace(SynologyPhotoSpace.PERSONAL); await { !f.model.state.value.loading }; f.model.toggle(f.photo)
        f.data.readFailure = true; f.model.load()!!.join(); assertTrue(f.model.state.value.photos.isEmpty()); assertTrue(f.model.state.value.selected.isEmpty())
        assertNotNull(f.model.state.value.error); assertNull(f.model.request()); assertTrue(f.data.writes.isEmpty())
    } }
    @Test fun `一百项上限重复目标和不可用来源不会发起操作`() = runBlocking { scenario { f ->
        f.model.open(List(101) { f.photo }, f.data.cache); assertFalse(f.model.state.value.visible)
        f.model.open(listOf(f.photo, f.photo), f.data.cache); assertFalse(f.model.state.value.visible)
        f.data.enabledSpaces = emptySet(); f.model.open(listOf(f.photo), f.data.cache); assertFalse(f.model.state.value.visible)
        assertTrue(f.data.calls.isEmpty())
    } }
    @Test fun `预检后身份权限或原件变化不发送旧确认`() = runBlocking {
        for (change in 0..2) scenario { f ->
            f.open(); f.model.request()!!.join()
            when (change) { 0 -> f.data.owner = f.data.owner.copy(userId = 42); 1 -> f.data.manage = false; 2 -> f.data.photos[f.photo.id] = f.photo.copy(filename = "Changed.jpg") }
            f.model.confirm()!!.join(); assertTrue(f.data.writes.isEmpty()); assertNotNull(f.model.state.value.error)
            assertTrue(f.store.records(f.owner, f.data.owner.userId).isEmpty())
        }
    }
    @Test fun `连点确认刷新与换页在发送期间不能改变固定集合`() = runBlocking { scenario { f ->
        f.open(); f.model.request()!!.join(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.data.beforeWrite = { if (it == "regenerate_preview_by_nas") { entered.complete(Unit); release.await() } }
        val work = f.model.confirm()!!; entered.await(); assertNull(f.model.confirm()); assertNull(f.model.request()); assertNull(f.model.load())
        f.model.open(listOf(f.second), f.data.cache); assertEquals(listOf(f.photo), f.model.state.value.photos)
        f.model.dismiss(); assertFalse(f.model.state.value.visible); release.complete(Unit); work.join()
        assertFalse(f.model.state.value.visible); assertEquals(2, f.data.writes.size); assertEquals(1, f.updated.size)
    } }
    @Test fun `页面关闭后迟到预检不能重新显示确认或发写入`() = runBlocking { scenario { f ->
        f.open(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.beforePrepare = { withContext(NonCancellable) { entered.complete(Unit); release.await() } }
        val work = f.model.request()!!; entered.await(); f.model.dismiss(); release.complete(Unit); work.join()
        assertFalse(f.model.state.value.visible); assertNull(f.model.state.value.confirmation); assertTrue(f.data.writes.isEmpty())
    } }
    @Test fun `未知提交冷启动只读恢复禁止删除和重新发送最终差量更新一次`() = runBlocking { scenario { f ->
        f.data.eventFailure = true; f.open(); f.submit(); val pending = f.model.state.value.records.single()
        assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.checkpoint.phase); assertNull(f.model.discard(pending.id))
        f.model.dismiss(); f.repository = f.data.repository(); val cold = f.newModel()
        try {
            cold.openQueue(SynologyPhotoSpace.PERSONAL, f.data.cache); await { !cold.state.value.loading }
            assertTrue(cold.state.value.pending); cold.toggle(f.photo); assertNull(cold.request())
            cold.refresh()!!.join(); assertEquals(1, f.reviews); assertEquals(2, f.data.writes.size); assertTrue(f.updated.isEmpty())
            f.data.finish(f.photo.id); cold.refresh()!!.join(); assertEquals(2, f.data.writes.size); assertEquals(1, f.updated.size)
            assertNull(cold.resume(pending.id)); cold.discard(pending.id)!!.join(); assertTrue(f.store.records(f.owner, 41).isEmpty())
        } finally { cold.close() }
    } }
    @Test fun `明确失败记录保留逐项结果并允许清除新确认采用新身份基线`() = runBlocking { scenario { f ->
        f.data.nasSuccess = false; f.data.uploadSuccess = false; f.open(); f.submit()
        val row = f.model.state.value.records.single(); assertTrue(row.checkpoint.finished); assertTrue(row.checkpoint.previews!!.progress.single().failed)
        assertEquals(4, f.data.writes.size); f.model.discard(row.id)!!.join(); assertTrue(f.model.state.value.records.isEmpty())
        f.data.nasSuccess = true; f.model.request()!!.join(); assertNotEquals(row.id, f.model.state.value.confirmation!!.operationId)
    } }
    @Test fun `冷启动临时文件清理只覆盖本身份已保存操作不碰其他缓存`() = runBlocking { scenario { f ->
        f.data.eventFailure = true; f.open(); f.submit(); val id = f.model.state.value.records.single().id; f.model.dismiss()
        val owned = File(f.data.cache, "synology-photos-preview-$id-orphan").apply { mkdir(); File(this, "source").writeBytes(byteArrayOf(1)) }
        val other = File(f.data.cache, "synology-photos-preview-${UUID.randomUUID()}-other").apply { mkdir(); File(this, "source").writeBytes(byteArrayOf(2)) }
        val unrelated = File(f.data.cache, "another-feature").apply { writeBytes(byteArrayOf(3)) }
        f.open(); assertFalse(owned.exists()); assertTrue(other.exists()); assertTrue(unrelated.exists()); assertEquals(2, f.data.writes.size)
    } }
    @Test fun `缓存清理遇到同身份进行中任务保持文件并允许稍后重试`() = runBlocking { scenario { f ->
        f.data.eventFailure = true; f.open(); f.submit(); val id = f.model.state.value.records.single().id; f.model.dismiss()
        val owned = File(f.data.cache, "synology-photos-preview-$id-active").apply { mkdir(); File(this, "source").writeBytes(byteArrayOf(1)) }
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val work = f.scope.launch { f.store.exclusive(f.owner, id) { entered.complete(Unit); release.await() } }; entered.await()
        f.open(); assertTrue(owned.exists()); assertEquals(SynologyPhotoAlbumProblem.BUSY, (f.model.state.value.error as SynologyPhotoAlbumFailure).problem)
        release.complete(Unit); work.join(); f.model.load()!!.join(); assertFalse(owned.exists()); assertNull(f.model.state.value.error)
    } }
    @Test fun `轮询仅在前台未决记录每十五秒读取退出后停止`() = runBlocking { scenario { f ->
        f.model.activate(); f.open(); assertTrue(f.pauses.isEmpty()); f.data.eventFailure = true; f.submit()
        await { !f.model.state.value.loading && f.pauses.isNotEmpty() }; assertEquals(15_000L, f.pauses.last())
        f.ticks.send(Unit); await { f.reviews == 1 && !f.model.state.value.working && !f.model.state.value.loading }
        f.model.deactivate(); val reviews = f.reviews; f.ticks.send(Unit); delay(30); assertEquals(reviews, f.reviews)
        assertEquals(2, f.data.writes.size); assertTrue(f.model.state.value.pending)
    } }
    @Test fun `撤销访问取消在途但发送事实保留冷恢复不重发`() = runBlocking { scenario { f ->
        f.open(); f.model.request()!!.join(); val entered = CompletableDeferred<Unit>()
        f.data.beforeWrite = { if (it == "regenerate_preview_by_nas") { entered.complete(Unit); awaitCancellation() } }
        val work = f.model.confirm()!!; entered.await(); f.current = false; f.model.revokeAccess(); work.join()
        assertFalse(f.model.state.value.visible); assertTrue(f.model.state.value.records.isEmpty())
        val row = f.store.records(f.owner.copy(sessionGeneration = "new"), 41).single()
        assertEquals(SynologyPhotoAlbumPhase.PENDING, row.checkpoint.phase); assertTrue(row.checkpoint.previews!!.progress.single().unknownSubmission)
        f.current = true; f.repository = f.data.repository(); f.open(); f.model.resume(row.id)!!.join(); assertEquals(2, f.data.writes.size)
    } }
    @Test fun `根模型只刷新命中的预览缩略图并保留分页月份多选`() = runBlocking { scenario { f ->
        val root = f.root()
        try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; val before = root.state.value
            root.edits!!.toggle(before.items.single()); root.preview.open(before.items.single())!!.join(); assertArrayEquals(byteArrayOf(1), root.thumbnail(before.items.single()))
            val model = root.previewRegeneration!!; model.open(before.items, f.data.cache); await { !model.state.value.loading }
            model.request()!!.join(); model.confirm()!!.join(); await { !root.preview.state.value.loading }
            assertEquals("new", root.state.value.items.single().thumbnail!!.revision); assertEquals("new", root.edits!!.state.value.selected.single().thumbnail!!.revision)
            assertEquals(before.copy(items = root.state.value.items, groups = root.state.value.groups), root.state.value)
            assertArrayEquals(byteArrayOf(2), root.thumbnail(root.state.value.items.single())); assertArrayEquals(byteArrayOf(2), root.preview.state.value.image)
            assertEquals(1, f.pages); root.loadMore()!!.join(); assertEquals(2, root.state.value.items.size)
        } finally { root.close() }
    } }
    @Test fun `更新期间大图换到另一张不会被完成回调切回`() = runBlocking { scenario { f ->
        val root = f.root()
        try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.loadMore()!!.join(); root.preview.open(f.photo)!!.join()
            val model = root.previewRegeneration!!; model.open(listOf(f.photo), f.data.cache); await { !model.state.value.loading }; model.request()!!.join()
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.data.beforeWrite = { if (it == "regenerate_preview_by_nas") { entered.complete(Unit); release.await() } }
            val work = model.confirm()!!; entered.await(); root.preview.adjacent(1); await { !root.preview.state.value.loading }
            release.complete(Unit); work.join(); assertEquals(f.second.id, root.preview.state.value.photo!!.id)
            assertEquals("new", root.state.value.items.first().thumbnail!!.revision); assertEquals(2, f.pages)
        } finally { root.close() }
    } }
    @Test fun `冷未决预览阻止原件导出和新编辑但浏览仍可使用`() = runBlocking { scenario { f ->
        f.data.eventFailure = true; f.open(); f.submit(); f.model.dismiss(); val root = f.root()
        try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }
            assertEquals(1, root.state.value.items.size)
            try { root.previewRegeneration!!.requireNoPending(); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, error.problem) }
            root.edits!!.open(listOf(f.photo), SynologyPhotoSpace.PERSONAL)
            await { !root.edits!!.state.value.loading }
            root.edits!!.setEdit(SynologyPhotoEdit.Rating(3)); root.edits!!.save()!!.join()
            assertEquals(SynologyPhotoAlbumProblem.PENDING, (root.edits!!.state.value.error as SynologyPhotoAlbumFailure).problem)
            assertTrue(root.exports.open(SynologyPhotoExportRequest.Items(listOf(f.photo)), false))
            root.exports.prepare(SynologyPhotoDownloadFormat.ORIGINAL, f.data.cache)!!.join()
            assertEquals(SynologyPhotoAlbumProblem.PENDING, (root.exports.state.value.error as SynologyPhotoAlbumFailure).problem)
            root.albums!!.refreshRecords()!!.join(); assertTrue(root.albums!!.state.value.records.isEmpty())
            val albums = root.albums!!; albums.open(SynologyPhotoAlbumAction.CREATE); albums.setName("Synthetic new"); albums.save()!!.join()
            assertEquals(SynologyPhotoAlbumProblem.PENDING, (albums.state.value.error as SynologyPhotoAlbumFailure).problem)
            assertEquals(SynologyPhotoEditPhase.READY, f.editStore.records(f.owner, 41).single().checkpoint.phase); assertEquals(2, f.data.writes.size)
            assertTrue(f.store.records(f.owner, 41).single().checkpoint.submitted)
        } finally { root.close() }
    } }
    private suspend fun scenario(block: suspend (Scenario) -> Unit) { val f = Scenario(); try { withTimeout(10_000) { block(f) } } finally { f.close() } }
    companion object { private suspend fun await(test: () -> Boolean) { withTimeout(5_000) { while (!test()) delay(5) } } }
}
