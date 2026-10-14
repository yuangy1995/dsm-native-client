package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.time.*
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoMaintenanceModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "maintenance-model-${UUID.randomUUID()}"
        override val canEditPhotos = true; override val canManageAlbums = true
        var enabled = true; var identity = 41L; var index = 0L; var previews = 0L; var h264 = true
        var writes = 0; var reviews = 0; var reads = 0; var photoReads = 0; var pending = false; var receipt = true
        var failRead = false; var failPrepare = false
        var beforeRead: suspend () -> Unit = {}; var beforeWrite: suspend () -> Unit = {}
        override fun canMaintainLibrary(space: SynologyPhotoSpace) = enabled
        override suspend fun photoEditIdentity() = identity
        override suspend fun maintenanceStatus(space: SynologyPhotoSpace): SynologyPhotoMaintenanceStatus {
            beforeRead(); reads++; if (failRead) throw IOException("Synthetic read")
            return SynologyPhotoMaintenanceStatus(profileId, identity, space, index, previews, h264)
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) {
            if (failPrepare) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
        }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
            val value = checkpoint.maintenance!!.copy(attempted = true)
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, maintenance = value)); writes++; beforeWrite()
            return checkpoint.copy(phase = if (pending || !receipt) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED,
                maintenance = value.copy(acknowledged = receipt)).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++
            return checkpoint.copy(phase = if (pending || !checkpoint.maintenance!!.acknowledged) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED).also(save)
        }
        val photo = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 100,
            Instant.parse("2020-03-01T12:00:00Z").epochSecond.toDouble(), 1.0, 9, "photo")
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 1))
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            photoReads++
            return SynologyPhotoPage(if (offset == 0) listOf(photo.copy(id = photo.id.copy(space = space))) else emptyList(), offset, if (offset == 0) 1 else offset, false)
        }
        override suspend fun categories(space: SynologyPhotoSpace) = emptySet<SynologyPhotoCategory>()
        override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
    }
    private class Fixture {
        val api = Api(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session"); val store = SynologyPhotoAlbumStore(MemoryPreferences())
        val pauses = CopyOnWriteArrayList<Long>(); val ticks = Channel<Unit>(Channel.UNLIMITED)
        var current = true; var canStart = true; var before: suspend () -> Unit = {}
        fun model() = SynologyPhotoMaintenanceModel(api, scope, store, owner,
            { if (!current) throw CancellationException() }, { canStart }, { before() }, pause = { pauses += it; ticks.receive() })
        val model = model()
        suspend fun open(space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL) { model.open(space); await { !model.state.value.loading } }
        suspend fun submit() { model.request(SynologyPhotoMaintenanceAction.INDEX); model.confirm()!!.join() }
        fun root() = SynologyPhotosModel(api, scope, zone = ZoneOffset.UTC, uploadOwner = owner, albumStore = store,
            editStore = SynologyPhotoEditStore(MemoryPreferences()))
    }
    @Test fun `进入读取取消确认均零写且按钮按对应计数与预览能力限制`() = runBlocking { fixture { f ->
        f.api.previews = 3; f.api.h264 = false; f.open(); assertEquals(0, f.api.writes)
        f.model.request(SynologyPhotoMaintenanceAction.PREVIEWS); assertNull(f.model.state.value.confirmation)
        f.model.request(SynologyPhotoMaintenanceAction.INDEX); assertNotNull(f.model.state.value.confirmation)
        f.model.cancelConfirmation(); assertNull(f.model.confirm()); assertEquals(0, f.api.writes)
        f.api.index = 2; f.model.load()!!.join(); f.model.request(SynologyPhotoMaintenanceAction.INDEX); assertNull(f.model.state.value.confirmation)
    } }
    @Test fun `确认固定共享来源与动作重复确认只写一次`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoSpace.SHARED); f.model.request(SynologyPhotoMaintenanceAction.PREVIEWS)
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { entered.complete(Unit); release.await() }; val job = f.model.confirm()!!; entered.await()
        assertNull(f.model.confirm()); f.model.request(SynologyPhotoMaintenanceAction.INDEX); assertNull(f.model.state.value.confirmation)
        f.model.open(SynologyPhotoSpace.PERSONAL); assertEquals(SynologyPhotoSpace.SHARED, f.model.state.value.space)
        assertTrue(f.model.state.value.working); release.complete(Unit); job.join()
        val value = f.store.records(f.owner, 41).single().checkpoint.maintenance!!
        assertEquals(SynologyPhotoSpace.SHARED, value.original.space); assertEquals(SynologyPhotoMaintenanceAction.PREVIEWS, value.action); assertEquals(1, f.api.writes)
    } }
    @Test fun `预检变化零写且自动状态读取不清除失败`() = runBlocking { fixture { f ->
        f.model.activate(); f.open(); f.api.failPrepare = true; f.submit(); await { !f.model.state.value.loading }
        assertEquals(0, f.api.writes); assertTrue(f.store.records(f.owner, 41).isEmpty()); assertNotNull(f.model.state.value.error)
        f.api.failPrepare = false; f.model.load()!!.join(); assertNull(f.model.state.value.error); assertNotNull(f.model.state.value.status)
    } }
    @Test fun `读取失败不显示旧空闲或允许写入重试恢复`() = runBlocking { fixture { f ->
        f.open(); f.api.failRead = true; f.model.load()!!.join(); assertNull(f.model.state.value.status); assertNotNull(f.model.state.value.error)
        f.model.request(SynologyPhotoMaintenanceAction.INDEX); assertNull(f.model.confirm()); assertEquals(0, f.api.writes)
        f.api.failRead = false; f.model.load()!!.join(); assertNull(f.model.state.value.error); assertNotNull(f.model.state.value.status)
    } }
    @Test fun `无回执冷恢复只读取不删除不新建全来源互斥`() = runBlocking { fixture { f ->
        f.open(); f.api.receipt = false; f.submit(); f.model.dismiss()
        val cold = f.model(); try {
            cold.open(SynologyPhotoSpace.SHARED); await { !cold.state.value.loading }; val row = cold.state.value.records.single()
            assertTrue(cold.state.value.pending); assertNull(cold.discard(row.id)); cold.request(SynologyPhotoMaintenanceAction.INDEX); assertNull(cold.confirm())
            cold.resume(row.id)!!.join(); assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews); assertTrue(cold.state.value.pending)
            try { cold.requireNoPending(); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, error.problem) }
        } finally { cold.close() }
    } }
    @Test fun `十五秒前台轮询后台关闭与撤权停止读取`() = runBlocking { fixture { f ->
        f.api.pending = true; f.model.activate(); f.open(); f.submit(); await { !f.model.state.value.loading && f.pauses.isNotEmpty() }
        assertEquals(15_000L, f.pauses.last()); f.ticks.send(Unit); await { f.api.reviews == 1 && !f.model.state.value.working && !f.model.state.value.loading }
        f.model.deactivate(); val reads = f.api.reads; delay(40); assertEquals(reads, f.api.reads)
        f.api.pending = false; f.model.activate(); await { !f.model.state.value.loading && f.pauses.size >= 2 }; f.ticks.send(Unit)
        await { f.model.state.value.records.single().checkpoint.finished && !f.model.state.value.working }
        assertEquals(1, f.api.writes); f.model.dismiss(); val after = f.api.reads; delay(40); assertEquals(after, f.api.reads)
        f.model.open(SynologyPhotoSpace.PERSONAL); await { !f.model.state.value.loading }; f.model.revokeAccess(); assertFalse(f.model.state.value.visible)
    } }
    @Test fun `离页迟到读取不覆盖返回后的新来源`() = runBlocking { fixture { f ->
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); var first = true
        f.api.beforeRead = { if (first) { first = false; entered.complete(Unit); withContext(NonCancellable) { release.await() } } }
        f.model.open(SynologyPhotoSpace.PERSONAL); entered.await(); f.model.dismiss(); f.model.open(SynologyPhotoSpace.SHARED)
        await { !f.model.state.value.loading }; release.complete(Unit); await { f.api.reads == 2 }; delay(30)
        assertEquals(SynologyPhotoSpace.SHARED, f.model.state.value.status!!.space); assertEquals(0, f.api.writes)
    } }
    @Test fun `提交后关闭页面仍保存结果不重新开页或重复发送`() = runBlocking { fixture { f ->
        f.open(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { entered.complete(Unit); release.await() }; f.model.request(SynologyPhotoMaintenanceAction.INDEX)
        val job = f.model.confirm()!!; entered.await(); f.model.dismiss(); assertFalse(f.model.state.value.visible)
        release.complete(Unit); job.join(); assertFalse(f.model.state.value.visible); assertTrue(f.store.records(f.owner, 41).single().checkpoint.finished)
        assertEquals(1, f.api.writes)
    } }
    @Test fun `撤销会话后的迟到结果不能写记录或恢复界面`() = runBlocking { fixture { f ->
        f.open(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { entered.complete(Unit); withContext(NonCancellable) { release.await() } }; f.model.request(SynologyPhotoMaintenanceAction.INDEX)
        val job = f.model.confirm()!!; entered.await(); f.current = false; f.model.revokeAccess(); release.complete(Unit); job.join()
        assertFalse(f.model.state.value.visible); assertTrue(f.model.state.value.records.isEmpty())
        val row = f.store.records(f.owner, 41).single().checkpoint; assertTrue(row.maintenance!!.attempted); assertFalse(row.maintenance!!.acknowledged); assertFalse(row.finished)
    } }
    @Test fun `未发送记录冷启动不补发可清除且其他账号不可见`() = runBlocking { fixture { f ->
        val row = SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = f.api.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.MAINTAIN_LIBRARY, maintenance = SynologyPhotoMaintenanceCheckpoint(f.api.maintenanceStatus(SynologyPhotoSpace.PERSONAL), SynologyPhotoMaintenanceAction.INDEX)))
        f.store.begin(row); f.open(); assertNull(f.model.resume(row.id)); assertEquals(0, f.api.writes)
        f.model.discard(row.id)!!.join(); assertTrue(f.store.records(f.owner, 41).isEmpty())
        f.store.begin(row); f.api.identity = 42; f.model.load()!!.join(); assertTrue(f.model.state.value.records.isEmpty())
    } }
    @Test fun `两来源维护保存均保留历史月份照片和多选且不重复加载图库`() = runBlocking { fixture { f ->
        for (space in SynologyPhotoSpace.entries) {
            val root = f.root(); try {
                root.activate(); await { root.state.value.loaded && !root.state.value.loading }
                if (space == SynologyPhotoSpace.SHARED) { root.selectSpace(space); await { !root.state.value.loading } }
                root.jumpToMonth(YearMonth.of(2020, 3))!!.join(); root.edits!!.selectMode(true); root.edits.toggle(root.state.value.items.single())
                val old = root.state.value; val selected = root.edits.state.value.selected; val reads = f.api.photoReads
                val model = root.maintenance!!; model.open(space); await { !model.state.value.loading }
                model.request(SynologyPhotoMaintenanceAction.INDEX); model.confirm()!!.join()
                assertEquals(old.items, root.state.value.items); assertEquals(old.selectedMonth, root.state.value.selectedMonth)
                assertEquals(selected, root.edits.state.value.selected); assertEquals(reads, f.api.photoReads)
            } finally { root.close() }
        }
    } }
    @Test fun `冷恢复未决维护阻止相册创建而普通浏览可继续`() = runBlocking { fixture { f ->
        f.open(); f.api.receipt = false; f.submit(); f.model.dismiss()
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; assertTrue(root.state.value.items.isNotEmpty())
            root.albums!!.refreshRecords()?.join(); assertTrue(root.albums.state.value.records.isEmpty())
            val albums = root.albums!!; albums.open(SynologyPhotoAlbumAction.CREATE); albums.setName("Synthetic new")
            albums.save()!!.join(); assertEquals(1, f.api.writes)
            assertEquals(SynologyPhotoAlbumProblem.PENDING, (albums.state.value.error as SynologyPhotoAlbumFailure).problem)
        } finally { root.close() }
    } }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) { val f = Fixture(); try { withTimeout(8_000) { block(f) } } finally { f.model.close(); f.scope.cancel() } }
    companion object {
        private suspend fun await(condition: () -> Boolean) { withTimeout(4_000) { while (!condition()) delay(5) } }
    }
}
