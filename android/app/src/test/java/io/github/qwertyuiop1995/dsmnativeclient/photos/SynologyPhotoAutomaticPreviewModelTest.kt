package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosAutomaticPreviewFixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.File
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.junit.Assert.*
import org.junit.Test

/** 正式组合根、媒体请求、持久存储及调度；网络与编解码使用明确合成夹具。 */
class SynologyPhotoAutomaticPreviewModelTest {
    private class Scenario {
        val data = SynologyPhotosAutomaticPreviewFixture()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner("auto-root", "identity", "session")
        val store = SynologyPhotoAlbumStore(MemoryPreferences())
        var current = true; var canRun = true; var settingsVisible = false; var now = 10_000L
        var support = data.support; var before: suspend () -> Unit = {}
        val updated = mutableListOf<SynologyPhotoAutomaticPreviewTask>()
        val ticks = Channel<Unit>(Channel.UNLIMITED); val waits = mutableListOf<Long>()
        var view = SynologyPhotoAutomaticPreviewView(listOf(data.photo()), data.photo(), data.space, listOf(data.space), false, true, true)
        var model: SynologyPhotoAutomaticPreviewModel? = null
        fun api() = object : SynologyPhotosServing by data.repository {
            override suspend fun performAutomaticPreview(checkpoint: SynologyPhotoAlbumCheckpoint, cache: File, save: (SynologyPhotoAlbumCheckpoint) -> Unit) =
                data.repository.performAutomaticPreview(checkpoint, cache) { data.save(it); save(it) }
            override suspend fun reviewAutomaticPreview(checkpoint: SynologyPhotoAlbumCheckpoint, cache: File, save: (SynologyPhotoAlbumCheckpoint) -> Unit) =
                data.repository.reviewAutomaticPreview(checkpoint, cache) { data.save(it); save(it) }
        }
        fun create(api: SynologyPhotosServing = api()) = SynologyPhotoAutomaticPreviewModel(api, scope, store, owner, data.cache,
            { if (!current) throw CancellationException() }, { canRun }, { settingsVisible }, { view }, { before() }, { updated += it },
            support = { support }, wait = { waits += it; ticks.receive() }, now = { now }).also { model = it; it.activate() }
        suspend fun run() { model!!.process()!!.join() }
        fun rows() = store.records(owner, 41)
        suspend fun close() { model?.close(); scope.coroutineContext[Job]!!.cancelAndJoin(); data.close() }
    }
    @Test fun `一周期一次真实上传完成定向刷新与同单元来源去重`() = runBlocking { scenario { f ->
        val model = f.create(); f.run(); assertEquals(1, f.data.uploadBodies.size); assertEquals(1, f.updated.size)
        assertTrue(f.rows().isEmpty()); assertFalse(model.state.value.visible)
        f.view = f.view.copy(current = null); f.run(); assertEquals(1, f.data.uploadBodies.size); f.data.clean()
    } }
    @Test fun `未知上传指数间隔只读恢复不受关闭和暂停阻断`() = runBlocking { scenario { f ->
        f.data.unknownUpload = true; f.data.receivedThumbs = f.data.thumbs.mapValues { byteArrayOf(0) }
        val model = f.create(); f.run(); assertTrue(model.state.value.pending); assertEquals(1, f.data.conversionCount)
        model.pause(); f.data.enabled = false; model.applySettings(SynologyPhotoAutomaticPreviewSettings(false)); f.run()
        val reads = f.data.requests.size; f.run(); assertEquals(reads, f.data.requests.size)
        f.now += 5_000; f.run(); val second = f.data.requests.size; f.now += 5_000; f.run(); assertEquals(second, f.data.requests.size)
        f.data.receivedThumbs = f.data.thumbs; f.now += 5_000; f.run()
        assertFalse(model.state.value.pending); assertEquals(1, f.data.uploadBodies.size); assertEquals(1, f.data.conversionCount); assertEquals(1, f.updated.size)
    } }
    @Test fun `未知上传重启后仍只读且不按候选消失认领`() = runBlocking { scenario { f ->
        f.data.unknownUpload = true; f.data.receivedThumbs = f.data.thumbs.mapValues { byteArrayOf(0) }; f.create(); f.run()
        f.model!!.close(); f.data.cold(); f.data.backgroundPresent = false; f.data.enabled = false
        val cold = f.create(); f.run(); assertTrue(cold.state.value.pending); assertEquals(1, f.data.uploadBodies.size)
        f.data.receivedThumbs = f.data.thumbs; f.now += 5_000; f.run(); assertFalse(cold.state.value.pending); assertEquals(1, f.data.conversionCount)
    } }
    @Test fun `取消转换删除缓存未发出任何写入继续后重新领取`() = runBlocking { scenario { f ->
        val entered = CompletableDeferred<Unit>(); f.data.convertHook = { entered.complete(Unit); awaitCancellation() }
        val model = f.create(); val work = model.process()!!; entered.await(); model.pause(); work.join()
        assertTrue(f.data.uploadBodies.isEmpty()); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, f.rows().single().checkpoint.phase); f.data.clean()
        f.data.convertHook = {}; model.resume(); await { !model.state.value.working && f.data.uploadBodies.size == 1 }
        assertEquals(2, f.data.conversionCount); assertEquals(1, f.data.uploadBodies.size)
    } }
    @Test fun `手动管理互斥取消自动转换并等待清理后才放行`() = runBlocking { scenario { f ->
        val entered = CompletableDeferred<Unit>(); f.data.convertHook = { entered.complete(Unit); awaitCancellation() }
        val model = f.create(); val work = model.process()!!; entered.await()
        withTimeout(5_000) { f.store.exclusive(f.owner, "manual-operation") {
            model.requireNoPending(); f.data.clean(); assertTrue(f.data.uploadBodies.isEmpty())
        } }
        work.join(); assertFalse(model.state.value.working); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, f.rows().single().checkpoint.phase)
    } }
    @Test fun `已发出上传的未知记录取消后仍阻止其他写入`() = runBlocking { scenario { f ->
        f.data.unknownUpload = true; f.data.receivedThumbs = f.data.thumbs.mapValues { byteArrayOf(0) }
        val model = f.create(); f.run()
        try { model.requireNoPending(); fail("Expected pending") } catch (e: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, e.problem) }
        assertTrue(f.rows().single().checkpoint.automaticPreview!!.uploadAttempted); assertEquals(1, f.data.uploadBodies.size)
    } }
    @Test fun `冷启动未发送草稿丢弃不执行且只清理自身操作目录`() = runBlocking { scenario { f ->
        val row = f.data.row(); f.store.begin(SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = row))
        val owned = File(f.data.cache, "synology-photos-automatic-preview-${row.operationId}-old").apply { mkdir(); File(this, "source").writeText("Synthetic") }
        val unrelated = File(f.data.cache, "synology-photos-automatic-preview-other-old").apply { mkdir() }
        f.data.enabled = false; f.create(); f.run(); assertFalse(owned.exists()); assertTrue(unrelated.exists()); assertTrue(f.rows().isEmpty()); assertEquals(0, f.data.conversionCount)
        unrelated.delete()
    } }
    @Test fun `冷启动中断但无写入事实只能只读收尾不转换`() = runBlocking { scenario { f ->
        val row = f.data.row(); f.store.begin(SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = row))
        f.store.save(row.operationId, f.owner, 41, row.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        f.data.enabled = false; f.create(); f.run(); assertTrue(f.rows().isEmpty()); assertEquals(0, f.data.conversionCount); assertTrue(f.data.uploadBodies.isEmpty())
    } }
    @Test fun `设置打开暂停关闭与无设备能力均不领取`() = runBlocking { scenario { f ->
        val model = f.create(); f.settingsVisible = true; f.run(); assertNull(model.state.value.enabled)
        f.settingsVisible = false; model.pause(); f.run(); assertNull(model.state.value.enabled)
        model.close(); f.support = SynologyPhotoPreviewConversionSupport(false, false, false); f.create(); f.run()
        assertFalse(f.model!!.state.value.supported!!); assertEquals(0, f.data.conversionCount)
        f.model!!.close(); f.support = f.data.support; f.data.enabled = false; f.create(); f.run(); assertEquals(false, f.model!!.state.value.enabled)
        assertEquals(0, f.data.conversionCount)
    } }
    @Test fun `每次领任务重新读远端开关预检后关闭也不执行`() = runBlocking { scenario { f ->
        f.create(); f.before = { f.data.enabled = false }; f.run(); assertEquals(0, f.data.conversionCount); assertTrue(f.data.uploadBodies.isEmpty())
        assertNotNull(f.model!!.state.value.error)
    } }
    @Test fun `网格二秒稳定后才读可见照片`() = runBlocking { scenario { f ->
        f.view = f.view.copy(current = null); f.data.backgroundPresent = false
        val model = f.create(); model.setVisible(setOf(f.data.photo().id)); f.run()
        assertFalse(f.data.calls.any { it.api.endsWith("Browse.Item") }); assertEquals(0, f.data.conversionCount)
        f.now += 2_000; f.run(); assertEquals(1, f.data.conversionCount); assertEquals(1, f.data.uploadBodies.size)
    } }
    @Test fun `前置未决其他操作拒绝零自动写入`() = runBlocking { scenario { f ->
        f.before = { throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING) }; f.create(); f.run()
        assertEquals(0, f.data.conversionCount); assertNull(f.model!!.state.value.error); assertTrue(f.rows().isEmpty())
    } }
    @Test fun `离开页面取消迟到读取不能恢复状态或上传`() = runBlocking { scenario { f ->
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.data.readHook = { api, _ -> if (api == "Setting.User") { entered.complete(Unit); withContext(NonCancellable) { release.await() } } }
        val model = f.create(); val work = model.process()!!; entered.await(); model.revokeAccess(); release.complete(Unit); work.join()
        assertEquals(SynologyPhotoAutomaticPreviewState(), model.state.value); assertEquals(0, f.data.conversionCount); assertNull(model.process())
    } }
    @Test fun `存储失败不转换不发送上传`() = runBlocking { scenario { f ->
        f.before = { throw IOException("Synthetic storage unavailable") }; f.create(); f.run()
        assertNotNull(f.model!!.state.value.error); assertEquals(0, f.data.conversionCount); assertTrue(f.data.uploadBodies.isEmpty())
    } }
    @Test fun `明确上传拒绝不重复领取显式继续才重试`() = runBlocking { scenario { f ->
        f.data.uploadResponse = "{\"success\":false,\"error\":{\"code\":105}}"; val model = f.create(); f.run()
        assertNotNull(model.state.value.error); f.run(); assertEquals(1, f.data.uploadBodies.size); assertTrue(f.rows().isEmpty())
        f.data.uploadResponse = "{\"success\":true}"; model.resume(); await { f.data.uploadBodies.size == 2 && !model.state.value.working }
        assertEquals(2, f.data.conversionCount)
    } }
    @Test fun `并发唤醒仅运行同一个操作`() = runBlocking { scenario { f ->
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.data.convertHook = { entered.complete(Unit); release.await() }; val model = f.create(); val work = model.process()!!; entered.await()
        repeat(5) { assertNull(model.process()) }; release.complete(Unit); work.join(); assertEquals(1, f.data.uploadBodies.size)
    } }
    @Test fun `后面的普通照片优先于当前高成本格式且普通找到后停止读取`() = runBlocking { scenario { f ->
        val photos = (1L..7L).map { f.data.photo().copy(id = f.data.photo().id.copy(itemId = it)) }
        f.view = f.view.copy(photos = photos, current = photos[2])
        val reads = mutableListOf<Long>(); val chosen = mutableListOf<Long>()
        f.create(object : SynologyPhotosServing by f.api() {
            override suspend fun automaticPreviewTasks(photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport): List<SynologyPhotoAutomaticPreviewTask> {
                reads += photo.id.itemId
                return listOf(SynologyPhotoAutomaticPreviewTask(profileId, photo.id.space, photo.id.itemId, photo.filename, 0, true, false,
                    priority = if (photo.id.itemId == 4L) SynologyPhotoAutomaticPreviewPriority.STANDARD else SynologyPhotoAutomaticPreviewPriority.HEVC_OR_LIVE_VIDEO))
            }
            override suspend fun prepareAutomaticPreview(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport): SynologyPhotoAlbumCheckpoint {
                chosen += task.unitId; throw IOException("Synthetic stop before execution")
            }
        })
        f.run(); assertEquals(listOf(3L, 4L), reads); assertEquals(listOf(4L), chosen); assertTrue(f.data.uploadBodies.isEmpty())
    } }
    @Test fun `实况视频仅在当前预览中领取网格和邻居不领取`() = runBlocking { scenario { f ->
        val live = f.data.photo().copy(mediaType = "live")
        f.view = f.view.copy(photos = listOf(live), current = null)
        var chosen = 0
        val model = f.create(object : SynologyPhotosServing by f.api() {
            override suspend fun automaticPreviewTasks(photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport) = listOf(
                SynologyPhotoAutomaticPreviewTask(profileId, photo.id.space, 152, "Synthetic.mov", 1, false, true))
            override suspend fun automaticPreviewTasks(space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport) = emptyList<SynologyPhotoAutomaticPreviewTask>()
            override suspend fun prepareAutomaticPreview(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport): SynologyPhotoAlbumCheckpoint {
                chosen++; throw IOException("Synthetic stop before execution")
            }
        })
        model.setVisible(setOf(live.id)); f.now += 2_000; f.run(); assertEquals(0, chosen)
        f.view = f.view.copy(current = live); f.run(); assertEquals(1, chosen)
    } }
    @Test fun `后台先当前来源且共享entry不扫描全库`() = runBlocking { scenario { f ->
        f.view = f.view.copy(current = null, space = SynologyPhotoSpace.SHARED, spaces = SynologyPhotoSpace.entries)
        val scans = mutableListOf<SynologyPhotoSpace>()
        f.create(object : SynologyPhotosServing by f.api() {
            override fun canGenerateAutomaticPreviews(space: SynologyPhotoSpace) = true
            override suspend fun automaticPreviewTasks(space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport): List<SynologyPhotoAutomaticPreviewTask> { scans += space; return emptyList() }
        })
        f.run(); assertEquals(listOf(SynologyPhotoSpace.PERSONAL), scans)
        scans.clear(); f.view = f.view.copy(managesShared = true); f.run(); assertEquals(listOf(SynologyPhotoSpace.SHARED, SynologyPhotoSpace.PERSONAL), scans)
    } }
    @Test fun `生产根自动更新只替换目标保持月份导航与选择`() = runBlocking { scenario { f ->
        var pages = 0; var details = 0
        val api = object : SynologyPhotosServing by f.api() {
            override val canEditPhotos = true
            override suspend fun categories(space: SynologyPhotoSpace) = emptySet<SynologyPhotoCategory>()
            override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(java.time.LocalDate.of(1970, 1, 1), 1))
            override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
                pages++; return SynologyPhotoPage(if (offset == 0) listOf(f.data.photo()) else emptyList(), offset, 1, false)
            }
            override suspend fun details(photo: SynologyPhoto): SynologyPhoto { details++; return photo.copy(thumbnail = SynologyPhotoThumbnail(151, "fresh")) }
        }
        val root = SynologyPhotosModel(api, f.scope, uploadOwner = f.owner, albumStore = f.store, editStore = SynologyPhotoEditStore(MemoryPreferences()),
            automaticPreviewCache = f.data.cache, automaticPreviewSupport = { f.support })
        try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }
            root.edits!!.selectMode(true); root.edits.toggle(f.data.photo())
            val before = root.state.value; val selected = root.edits.state.value.selected; val beforePages = pages
            root.automaticPreviews!!.process()!!.join()
            assertEquals(1, f.data.uploadBodies.size); assertEquals(1, details); assertEquals(beforePages, pages)
            assertEquals(before.navigation, root.state.value.navigation); assertEquals(before.selectedMonth, root.state.value.selectedMonth)
            assertEquals(selected.map { it.copy(thumbnail = SynologyPhotoThumbnail(151, "fresh")) }, root.edits.state.value.selected)
            assertEquals(before.items.map { it.copy(thumbnail = SynologyPhotoThumbnail(151, "fresh")) }, root.state.value.items)
            root.deactivate(); assertNull(root.automaticPreviews.process())
        } finally { root.close() }
    } }
    private suspend fun scenario(block: suspend (Scenario) -> Unit) {
        val f = Scenario(); try { f.data.ready(); block(f) } finally { f.close() }
    }
    companion object { private suspend fun await(block: () -> Boolean) { withTimeout(5_000) { while (!block()) delay(10) } } }
}
