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

class SynologyPhotoCodecPromptModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "codec-model-${UUID.randomUUID()}"
        override val canEditPhotos = true; override val canManageAlbums = true
        override var canRespondToCodecPrompt = true; override var canGenerateCodecPreviews = true
        var identity = 41L; var administrator = true; var home = true; var show = true
        var writes = 0; var continuations = 0; var reviews = 0; var reads = 0; var photoReads = 0
        var receipt = true; var promptRejected = false; var failRead = false; var failPrepare = false
        var beforeRead: suspend () -> Unit = {}; var beforeWrite: suspend () -> Unit = {}
        override suspend fun photoEditIdentity() = identity
        override suspend fun codecPrompt(): SynologyPhotoCodecPrompt {
            val result = SynologyPhotoCodecPrompt(profileId, identity, administrator, show, home)
            beforeRead(); reads++; if (failRead) throw IOException("Synthetic read"); return result
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) {
            if (failPrepare) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
        }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            val value = checkpoint.codecPrompt!!; save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
            var next = value.copy(generationAttempted = value.generate, promptAttempts = if (value.generate) 0 else 1)
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, codecPrompt = next)); writes++; beforeWrite()
            if (value.generate) next = next.copy(generationAcknowledged = receipt, promptAttempts = if (receipt) 1 else 0)
            if (!value.generate || receipt) next = next.copy(promptRejections = if (promptRejected) 1 else 0, promptAcknowledged = !promptRejected, promptClosed = !promptRejected)
            if (next.promptClosed) show = false
            return checkpoint.copy(phase = when { next.promptClosed -> SynologyPhotoAlbumPhase.COMPLETED; next.canContinue -> SynologyPhotoAlbumPhase.PARTIAL; else -> SynologyPhotoAlbumPhase.PENDING }, codecPrompt = next).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; val value = checkpoint.codecPrompt!!
            return if (!show && (value.generationAcknowledged || !value.generate)) checkpoint.copy(phase = SynologyPhotoAlbumPhase.COMPLETED,
                codecPrompt = value.copy(promptClosed = true)).also(save) else checkpoint.also(save)
        }
        override suspend fun continueCodecPrompt(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            continuations++; show = false
            val value = checkpoint.codecPrompt!!
            return checkpoint.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, codecPrompt = value.copy(promptAttempts = value.promptAttempts + 1,
                promptAcknowledged = true, promptClosed = true)).also(save)
        }
        val photo = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 100,
            Instant.parse("2020-03-01T12:00:00Z").epochSecond.toDouble(), 1.0, 9, "photo")
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 1))
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            photoReads++; return SynologyPhotoPage(if (offset == 0) listOf(photo.copy(id = photo.id.copy(space = space))) else emptyList(), offset, if (offset == 0) 1 else offset, false)
        }
        override suspend fun categories(space: SynologyPhotoSpace) = emptySet<SynologyPhotoCategory>()
        override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
    }
    private class Fixture {
        val api = Api(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session"); val store = SynologyPhotoAlbumStore(MemoryPreferences())
        val pauses = CopyOnWriteArrayList<Long>(); val ticks = Channel<Unit>(Channel.UNLIMITED)
        var current = true; var canStart = true; var before: suspend () -> Unit = {}
        fun model() = SynologyPhotoCodecPromptModel(api, scope, store, owner,
            { if (!current) throw CancellationException() }, { canStart }, { before() }, pause = { pauses += it; ticks.receive() })
        val model = model()
        suspend fun open() { model.open(); await { !model.state.value.loading } }
        suspend fun submit() { model.requestGeneration(); model.confirm()!!.join() }
        fun root() = SynologyPhotosModel(api, scope, zone = ZoneOffset.UTC, uploadOwner = owner, albumStore = store, editStore = SynologyPhotoEditStore(MemoryPreferences()))
    }
    @Test fun `打开与取消零写生成冻结管理员范围稍后无需额外确认`() = runBlocking { fixture { f ->
        f.open(); f.model.requestGeneration(); assertTrue(f.model.state.value.confirmation!!.isAdministrator)
        f.model.cancelConfirmation(); assertNull(f.model.confirm()); assertEquals(0, f.api.writes)
        f.model.later()!!.join(); assertNull(f.model.state.value.confirmation)
        assertFalse(f.store.records(f.owner, 41).single().checkpoint.codecPrompt!!.generate); assertEquals(1, f.api.writes)
    } }
    @Test fun `无提示或普通账号无个人来源或缺生成能力不允许生成`() = runBlocking { fixture { f ->
        f.api.show = false; f.open(); f.model.requestGeneration(); assertNull(f.model.confirm()); assertNull(f.model.later())
        f.api.show = true; f.api.administrator = false; f.api.home = false; f.model.load()!!.join()
        assertFalse(f.model.canGenerate); f.model.requestGeneration(); assertNull(f.model.confirm())
        f.api.administrator = true; f.model.load()!!.join(); assertTrue(f.model.canGenerate)
        f.api.canGenerateCodecPreviews = false; assertFalse(f.model.canGenerate); f.model.later()!!.join(); assertEquals(1, f.api.writes)
    } }
    @Test fun `连点确认与稍后只发送一次且写入中不切换页面`() = runBlocking { fixture { f ->
        f.open(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { entered.complete(Unit); release.await() }; f.model.requestGeneration(); val job = f.model.confirm()!!; entered.await()
        assertNull(f.model.confirm()); assertNull(f.model.later()); f.model.open(); assertTrue(f.model.state.value.working)
        release.complete(Unit); job.join(); assertEquals(1, f.api.writes)
    } }
    @Test fun `预检失败保留错误未创建记录刷新可恢复`() = runBlocking { fixture { f ->
        f.model.activate(); f.open(); f.api.failPrepare = true; f.submit(); await { !f.model.state.value.loading }
        assertEquals(0, f.api.writes); assertTrue(f.store.records(f.owner, 41).isEmpty()); assertNotNull(f.model.state.value.error)
        f.api.failPrepare = false; f.model.load()!!.join(); assertNull(f.model.state.value.error)
    } }
    @Test fun `读取失败清除旧提示不允许操作但可重试`() = runBlocking { fixture { f ->
        f.open(); f.api.failRead = true; f.model.load()!!.join(); assertNull(f.model.state.value.prompt); assertNotNull(f.model.state.value.error)
        f.model.requestGeneration(); assertNull(f.model.confirm()); assertNull(f.model.later()); assertEquals(0, f.api.writes)
        f.api.failRead = false; f.model.load()!!.join(); assertNull(f.model.state.value.error); assertNotNull(f.model.state.value.prompt)
    } }
    @Test fun `部分成功冷启动只读不能清除不能新生成显式继续仅保存提示`() = runBlocking { fixture { f ->
        f.open(); f.api.promptRejected = true; f.submit(); f.model.dismiss()
        val cold = f.model(); try {
            cold.open(); await { !cold.state.value.loading }; val row = cold.state.value.records.single()
            assertTrue(cold.state.value.pending); assertNull(cold.discard(row.id)); cold.requestGeneration(); assertNull(cold.confirm()); assertNull(cold.later())
            cold.resume(row.id)!!.join(); assertEquals(1, f.api.writes); assertEquals(0, f.api.continuations)
            cold.continuePrompt(row.id)!!.join(); assertEquals(1, f.api.writes); assertEquals(1, f.api.continuations); assertFalse(cold.state.value.pending)
            cold.discard(row.id)!!.join(); assertTrue(f.store.records(f.owner, 41).isEmpty())
        } finally { cold.close() }
    } }
    @Test fun `生成结果未知冷恢复不能继续保存或删除也不重放`() = runBlocking { fixture { f ->
        f.open(); f.api.receipt = false; f.submit(); f.model.dismiss(); val cold = f.model()
        try {
            cold.open(); await { !cold.state.value.loading }; val row = cold.state.value.records.single()
            assertNull(cold.continuePrompt(row.id)); assertNull(cold.discard(row.id)); cold.resume(row.id)!!.join()
            assertEquals(1, f.api.writes); assertTrue(cold.state.value.pending)
            try { cold.requireNoPending(); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, error.problem) }
        } finally { cold.close() }
    } }
    @Test fun `仅未决时十五秒前台只读轮询后台与关闭停止`() = runBlocking { fixture { f ->
        f.model.activate(); f.open(); assertTrue(f.pauses.isEmpty()); f.api.promptRejected = true; f.submit()
        await { !f.model.state.value.loading && f.pauses.isNotEmpty() }; assertEquals(15_000L, f.pauses.last())
        f.ticks.send(Unit); await { f.api.reviews == 1 && !f.model.state.value.working && !f.model.state.value.loading }
        assertEquals(0, f.api.continuations); f.model.deactivate(); val reads = f.api.reads; delay(40); assertEquals(reads, f.api.reads)
        f.api.show = false; f.model.activate(); await { !f.model.state.value.loading && f.pauses.size >= 2 }; f.ticks.send(Unit)
        await { !f.model.state.value.pending && !f.model.state.value.working }; assertEquals(1, f.api.writes)
        f.model.dismiss(); val after = f.api.reads; delay(40); assertEquals(after, f.api.reads)
    } }
    @Test fun `离页迟到提示不能覆盖返回后新状态`() = runBlocking { fixture { f ->
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); var first = true
        f.api.beforeRead = { if (first) { first = false; entered.complete(Unit); withContext(NonCancellable) { release.await() } } }
        f.model.open(); entered.await(); f.model.dismiss(); f.api.show = false; f.model.open(); await { !f.model.state.value.loading }
        release.complete(Unit); await { f.api.reads == 2 }; delay(30); assertFalse(f.model.state.value.prompt!!.shouldShow); assertEquals(0, f.api.writes)
    } }
    @Test fun `发送后关闭页面仍记录结果撤权后的迟到结果不落盘`() = runBlocking { fixture { f ->
        f.open(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { entered.complete(Unit); release.await() }; f.model.requestGeneration(); val job = f.model.confirm()!!; entered.await()
        f.model.dismiss(); release.complete(Unit); job.join(); assertFalse(f.model.state.value.visible); assertTrue(f.store.records(f.owner, 41).single().checkpoint.finished)
        f.api.show = true; f.open(); val enteredAgain = CompletableDeferred<Unit>(); val releaseAgain = CompletableDeferred<Unit>()
        f.api.beforeWrite = { enteredAgain.complete(Unit); withContext(NonCancellable) { releaseAgain.await() } }
        f.model.requestGeneration(); val pending = f.model.confirm()!!; enteredAgain.await(); f.current = false; f.model.revokeAccess(); releaseAgain.complete(Unit); pending.join()
        assertTrue(f.model.state.value.records.isEmpty()); assertFalse(f.model.state.value.visible)
        val row = f.store.records(f.owner, 41).single { !it.checkpoint.finished }.checkpoint; assertTrue(row.codecPrompt!!.generationAttempted); assertFalse(row.codecPrompt!!.generationAcknowledged)
    } }
    @Test fun `生成和稍后均保留历史月份原件多选与分页不刷新图库`() = runBlocking { fixture { f ->
        for (generate in listOf(true, false)) {
            f.api.show = true; val root = f.root(); try {
                root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.jumpToMonth(YearMonth.of(2020, 3))!!.join()
                root.edits!!.selectMode(true); root.edits.toggle(root.state.value.items.single())
                val old = root.state.value; val selected = root.edits.state.value.selected; val reads = f.api.photoReads
                val model = root.codecPrompt!!; model.open(); await { !model.state.value.loading }
                if (generate) { model.requestGeneration(); model.confirm()!!.join() } else model.later()!!.join()
                assertEquals(old.items, root.state.value.items); assertEquals(old.selectedMonth, root.state.value.selectedMonth)
                assertEquals(selected, root.edits.state.value.selected); assertEquals(reads, f.api.photoReads)
            } finally { root.close() }
        }
    } }
    @Test fun `部分成功冷启动阻止相册创建且普通浏览可用恢复记录不混入相册`() = runBlocking { fixture { f ->
        f.open(); f.api.promptRejected = true; f.submit(); f.model.dismiss(); val root = f.root()
        try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; assertTrue(root.state.value.items.isNotEmpty())
            root.albums!!.refreshRecords()?.join(); assertTrue(root.albums.state.value.records.isEmpty())
            val albums = root.albums!!; albums.open(SynologyPhotoAlbumAction.CREATE); albums.setName("Synthetic new"); albums.save()!!.join()
            assertEquals(1, f.api.writes); assertEquals(SynologyPhotoAlbumProblem.PENDING, (albums.state.value.error as SynologyPhotoAlbumFailure).problem)
        } finally { root.close() }
    } }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) { val f = Fixture(); try { withTimeout(8_000) { block(f) } } finally { f.model.close(); f.scope.cancel() } }
    companion object {
        private suspend fun await(condition: () -> Boolean) { withTimeout(4_000) { while (!condition()) delay(5) } }
    }
}
