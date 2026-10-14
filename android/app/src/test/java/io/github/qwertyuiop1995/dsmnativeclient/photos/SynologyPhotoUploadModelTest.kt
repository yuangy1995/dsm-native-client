package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoUploadModelTest {
    @Test fun `选择只准备本地批次用户开始前没有NAS写入`() = runBlocking {
        fixture { f ->
            f.open()
            val draft = f.model.state.value.draft!!
            f.model.stage(draft) { listOf(SynologyPhotoUploadExecutionTest.source()) }!!.join()
            val row = f.model.state.value.selected!!
            assertTrue(f.api.writes.isEmpty()); assertFalse(row.finished)
            assertEquals(SynologyPhotoUploadDuplicate.RENAME, row.duplicate)
            f.model.start(row.id)!!.join()
            assertEquals(1, f.model.state.value.selected?.completedCount)
            assertEquals(1, f.api.writes.size)
        }
    }

    @Test fun `条件和冻结相册打开上传时选择实际图库而普通相册保留直接目标`() = runBlocking {
        fixture { f ->
            val album = SynologyPhotoCollection(71, "Synthetic album")
            for (value in listOf(album.copy(isConditional = true), album.copy(isFrozen = true))) {
                f.open(SynologyPhotoNavigation(album = value, section = SynologyPhotosSection.ALBUMS))
                assertEquals(SynologyPhotoUploadTarget.Timeline(SynologyPhotoSpace.PERSONAL), f.model.state.value.draft!!.target)
                assertEquals("", f.model.state.value.draft!!.targetName)
            }
            f.open(SynologyPhotoNavigation(album = album, section = SynologyPhotosSection.ALBUMS))
            assertEquals(SynologyPhotoUploadTarget.Album(71), f.model.state.value.draft!!.target)
            assertTrue(f.api.writes.isEmpty())
        }
    }

    @Test fun `选择器迟到结果不得改写已改变的目标`() = runBlocking {
        fixture { f ->
            f.open()
            assertTrue(f.model.preparePicker())
            f.model.selectTarget(SynologyPhotoUploadTarget.Album(71), "Synthetic album")
            var read = false
            assertNull(f.model.receiveSelection { read = true; listOf(SynologyPhotoUploadExecutionTest.source()) })
            assertFalse(read); assertTrue(f.model.state.value.records.isEmpty()); assertTrue(f.api.writes.isEmpty())
        }
    }

    @Test fun `上传中重新打开入口保留批次目标且重复开始被阻止`() = runBlocking {
        fixture { f ->
            f.open(SynologyPhotoNavigation(space = SynologyPhotoSpace.SHARED))
            f.model.stage(f.model.state.value.draft!!) { listOf(SynologyPhotoUploadExecutionTest.source()) }!!.join()
            val row = f.model.state.value.selected!!
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.api.beforeWrite = { entered.complete(Unit); release.await() }
            val task = f.model.start(row.id)!!
            entered.await()
            assertNull(f.model.start(row.id))
            f.model.dismiss(); f.model.open(SynologyPhotoNavigation(), f.api.access())
            assertNull(f.model.state.value.draft)
            assertEquals(row.id, f.model.state.value.selectedId)
            release.complete(Unit); task.join()
            assertEquals(SynologyPhotoUploadTarget.Timeline(SynologyPhotoSpace.SHARED), (f.api.writes.single() as SynologyPhotoUploadAction.Upload).target)
        }
    }

    @Test fun `关闭再打开只恢复记录没有自动开始或重传`() = runBlocking {
        fixture { f ->
            f.open()
            f.model.stage(f.model.state.value.draft!!) { listOf(SynologyPhotoUploadExecutionTest.source()) }!!.join()
            val id = f.model.state.value.selectedId!!
            f.api.stopAfterReceipt = true
            f.model.start(id)!!.join()
            assertTrue(f.model.state.value.selected!!.requiresReview)
            f.model.close()
            val restored = SynologyPhotoUploadModel(f.api, f.scope, SynologyPhotoUploadStore(f.preferences, f.root),
                SynologyPhotoUploadExecutionTest.owner.copy(sessionGeneration = "relogin"), {}, onCompleted = {})
            try {
                restored.showQueue(); restored.refreshRecords()?.join()
                await { restored.state.value.records.isNotEmpty() }
                assertEquals(1, f.api.writes.size)
                restored.selectBatch(id)
                f.api.stopAfterReceipt = false
                restored.start(id, reviewOnly = true)!!.join()
                assertTrue(restored.state.value.selected!!.finished); assertEquals(1, f.api.writes.size)
            } finally { restored.close() }
        }
    }

    @Test fun `撤权立即清除界面与迟到选择结果并保留已提交事实`() = runBlocking {
        fixture { f ->
            f.open()
            f.model.preparePicker()
            f.model.revokeAccess()
            assertNull(f.model.receiveSelection { listOf(SynologyPhotoUploadExecutionTest.source()) })
            assertFalse(f.model.state.value.visible)
            f.open()
            f.model.stage(f.model.state.value.draft!!) { listOf(SynologyPhotoUploadExecutionTest.source()) }!!.join()
            val id = f.model.state.value.selectedId!!
            val entered = CompletableDeferred<Unit>()
            f.api.beforeWrite = { entered.complete(Unit); awaitCancellation() }
            val task = f.model.start(id)!!; entered.await()
            f.model.revokeAccess(); task.join()
            assertFalse(f.model.state.value.visible); assertTrue(f.model.state.value.records.isEmpty())
            assertTrue(f.store.records(SynologyPhotoUploadExecutionTest.owner, 41).single().requiresReview)
        }
    }

    @Test fun `手动暂停后恢复只读检查并保留其余未开始项目`() = runBlocking {
        fixture { f ->
            f.open()
            f.model.stage(f.model.state.value.draft!!) { listOf(SynologyPhotoUploadExecutionTest.source(), SynologyPhotoUploadExecutionTest.source().copy(filename = "second.jpg")) }!!.join()
            val id = f.model.state.value.selectedId!!
            val entered = CompletableDeferred<Unit>()
            f.api.beforeWrite = { entered.complete(Unit); awaitCancellation() }
            val task = f.model.start(id)!!; entered.await(); f.model.pause(); task.join()
            assertFalse(f.model.state.value.working)
            f.model.refreshRecords()?.join()
            assertEquals(SynologyPhotoUploadPhase.PENDING, f.model.state.value.selected!!.entries.first().checkpoint?.phase)
            assertNull(f.model.state.value.selected!!.entries.last().checkpoint)
            f.model.start(id, reviewOnly = true)!!.join()
            assertTrue(f.api.writes.isEmpty()); assertEquals(1, f.api.reviews)
        }
    }

    @Test fun `已完成任务清除私有副本并从界面移除`() = runBlocking {
        fixture { f ->
            f.open()
            f.model.stage(f.model.state.value.draft!!) { listOf(SynologyPhotoUploadExecutionTest.source()) }!!.join()
            val row = f.model.state.value.selected!!
            f.model.start(row.id)!!.join()
            assertFalse(f.store.artifact(row.id, row.entries.single().id).exists())
            f.model.discard(row.id)!!.join()
            assertTrue(f.model.state.value.records.isEmpty()); assertNull(f.model.state.value.selectedId)
        }
    }

    @Test fun `系统授时拒绝不生成批次取消上传保留未知并释放租约`() = runBlocking {
        val root = Files.createTempDirectory("photo-execution-").toFile()
        val api = PhotoUploadServingFixture(); val store = SynologyPhotoUploadStore(MemoryPreferences(), root)
        val execution = io.github.qwertyuiop1995.dsmnativeclient.testing.ExecutionFixture().apply { denied = true }
        val model = SynologyPhotoUploadModel(api, this, store, SynologyPhotoUploadExecutionTest.owner, {}, executionHost = execution, onCompleted = {})
        try {
            model.open(SynologyPhotoNavigation(), api.access()); await { model.state.value.draft?.duplicate != null }
            model.stage(model.state.value.draft!!) { listOf(SynologyPhotoUploadExecutionTest.source()) }!!.join()
            assertTrue(model.state.value.records.isEmpty()); assertTrue(api.writes.isEmpty())
            execution.denied = false
            model.stage(model.state.value.draft!!) { listOf(SynologyPhotoUploadExecutionTest.source()) }!!.join()
            val id = model.state.value.selectedId!!; val entered = CompletableDeferred<Unit>()
            api.afterReceipt = { entered.complete(Unit); awaitCancellation() }
            val job = model.start(id)!!; entered.await(); execution.leases.last().expire(); job.join()
            assertTrue(model.state.value.selected!!.requiresReview); assertEquals(1, api.writes.size)
            assertTrue(execution.leases.all { it.finishes == 1 })
        } finally { model.close(); root.deleteRecursively() }
    }
    private class Fixture(val root: File) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val preferences = MemoryPreferences()
        val store = SynologyPhotoUploadStore(preferences, root)
        val api = PhotoUploadServingFixture()
        val model = SynologyPhotoUploadModel(api, scope, store, SynologyPhotoUploadExecutionTest.owner, {}, onCompleted = {})
        suspend fun open(navigation: SynologyPhotoNavigation = SynologyPhotoNavigation()) {
            model.open(navigation, api.access())
            await { !model.state.value.loading && model.state.value.draft?.duplicate != null }
        }
    }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val root = Files.createTempDirectory("photos-model-test-").toFile()
        val fixture = Fixture(root)
        try { block(fixture) } finally { fixture.model.close(); fixture.scope.coroutineContext[Job]!!.cancelAndJoin(); root.deleteRecursively() }
    }
    private companion object {
        suspend fun await(condition: () -> Boolean) { withTimeout(10_000) { while (!condition()) delay(10) } }
    }
}
