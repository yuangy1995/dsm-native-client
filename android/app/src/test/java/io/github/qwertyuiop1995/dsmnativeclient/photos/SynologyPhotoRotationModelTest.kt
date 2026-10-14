package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosEditRepositoryTest.Fixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.time.LocalDate
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoRotationModelTest {
    private class Scenario {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val fixture = Fixture()
        val original = fixture.add().copy(orientation = 1, width = 640, height = 480, thumbnail = SynologyPhotoThumbnail(91, "same"))
            .also { fixture.values[it.id] = it }
        val preferences = MemoryPreferences()
        val store = SynologyPhotoEditStore(preferences)
        val owner = WorkspaceOwner("profile-a", "synthetic", "session")
        val pages = AtomicInteger(); val mediaReads = AtomicInteger()
        var nextMedia: (suspend () -> ByteArray)? = null
        val api = object : SynologyPhotosServing by fixture.repository {
            override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 3), SynologyPhotoDay(LocalDate.of(2020, 2, 1), 3))
            override suspend fun categories(space: SynologyPhotoSpace) = emptySet<SynologyPhotoCategory>()
            override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
                pages.incrementAndGet()
                val all = listOf(fixture.values.getValue(original.id), original.copy(id = original.id.copy(itemId = 92), filename = "second.jpg"),
                    original.copy(id = original.id.copy(itemId = 93), filename = "third.jpg"))
                return SynologyPhotoPage(all.drop(offset).take(limit), offset, minOf(offset + limit, all.size), offset + limit < all.size)
            }
            override suspend fun thumbnail(photo: SynologyPhoto, large: Boolean): ByteArray {
                mediaReads.incrementAndGet(); return nextMedia?.invoke() ?: byteArrayOf(photo.orientation!!.toByte())
            }
            override suspend fun details(photo: SynologyPhoto): SynologyPhoto =
                if (photo.id == original.id) fixture.repository.details(photo) else photo
        }
        val model = SynologyPhotosModel(api, scope, pageSize = 2, uploadOwner = owner, editStore = store)
        suspend fun ready() {
            model.activate(); await { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error)
            model.preview.open(model.state.value.items.first())!!.join()
            model.preview.imageReady(model.preview.state.value.image!!); assertTrue(model.canRotatePreview)
        }
        suspend fun close() { model.close(); scope.coroutineContext[Job]!!.cancelAndJoin() }
    }
    @Test fun `单次点击即时转向防连点并保留月份分页选择和日期分组`() = runBlocking {
        scenario { f ->
            f.ready(); val model = f.model; val photo = model.preview.state.value.photo!!
            model.edits!!.toggle(photo); val before = model.state.value
            model.thumbnail(photo); val reads = f.mediaReads.get()
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.fixture.before = { if (it.method == "set") { entered.complete(Unit); release.await() } }
            val work = model.rotatePreview()!!; entered.await()
            assertEquals(-90f, model.preview.state.value.rotationDegrees); assertNull(model.rotatePreview())
            assertTrue(model.edits!!.state.value.working); assertEquals(1, f.fixture.writes.size)
            release.complete(Unit); work.join(); await { !model.preview.state.value.loading }
            assertEquals(8, model.state.value.items.first().orientation)
            assertEquals(8, model.state.value.groups.first().items.first().orientation)
            assertEquals(8, model.edits!!.state.value.selected.single().orientation)
            assertTrue(model.edits!!.state.value.selecting); assertEquals(0f, model.preview.state.value.rotationDegrees)
            assertEquals(before.copy(items = model.state.value.items, groups = model.state.value.groups), model.state.value)
            assertEquals(1, f.pages.get()); model.thumbnail(model.state.value.items.first()); assertTrue(f.mediaReads.get() > reads)
            model.loadMore()!!.join(); assertEquals(3, model.state.value.items.size); assertEquals(2, f.pages.get())
        }
    }
    @Test fun `解码未完成加载中保存原件和无效媒体不允许旋转`() = runBlocking {
        scenario { f ->
            f.model.activate(); await { f.model.state.value.loaded && !f.model.state.value.loading }
            f.model.preview.open(f.original)!!.join(); assertFalse(f.model.canRotatePreview); assertNull(f.model.rotatePreview())
            f.model.preview.imageReady(f.model.preview.state.value.image!!); assertTrue(f.model.canRotatePreview)
            f.fixture.values[f.original.id] = f.original.copy(filename = "synthetic.webp")
            f.model.preview.open(f.fixture.values.getValue(f.original.id))!!.join()
            f.model.preview.imageReady(f.model.preview.state.value.image!!); assertNull(f.model.rotatePreview())
            assertTrue(f.fixture.writes.isEmpty())
        }
    }
    @Test fun `未知结果恢复清除临时角度仅回读且不全量刷新`() = runBlocking {
        scenario { f ->
            f.fixture.apply = false; f.ready(); val model = f.model
            model.rotatePreview()!!.join(); val row = model.edits!!.state.value.records.single()
            assertEquals(SynologyPhotoEditPhase.PENDING, row.checkpoint.phase); assertEquals(0f, model.preview.state.value.rotationDegrees)
            assertNull(model.rotatePreview()); assertFalse(model.canStartSlideshow); assertEquals(1, f.fixture.writes.size)
            f.fixture.values[f.original.id] = f.original.copy(orientation = 8, width = 480, height = 640)
            model.edits!!.resume(row.id)!!.join(); await { !model.preview.state.value.loading }
            assertEquals(SynologyPhotoEditPhase.COMPLETED, model.edits!!.state.value.records.single().checkpoint.phase)
            assertEquals(1, f.fixture.writes.size); assertEquals(1, f.pages.get()); assertEquals(8, model.state.value.items.first().orientation)
        }
    }
    @Test fun `明确失败恢复显示且不提供批量继续旋转入口`() = runBlocking {
        scenario { f ->
            f.fixture.apply = false; f.fixture.receipt = "{\"error_list\":[{\"id\":91,\"error\":105}]}"; f.ready()
            f.model.rotatePreview()!!.join(); val editor = f.model.edits!!; val record = editor.state.value.records.single()
            assertEquals(SynologyPhotoEditPhase.PARTIAL, record.checkpoint.phase)
            assertEquals(0f, f.model.preview.state.value.rotationDegrees); assertEquals(1, f.model.state.value.items.first().orientation)
            editor.continueRemaining(record.id); assertNull(editor.state.value.draft)
            assertNull(editor.resume(record.id)); assertEquals(1, f.fixture.writes.size); assertEquals(1, f.pages.get())
        }
    }
    @Test fun `旋转期间关闭或换图不被完成回调重新打开覆盖`() = runBlocking {
        for (close in listOf(true, false)) scenario { f ->
            f.ready(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.fixture.before = { if (it.method == "set") { entered.complete(Unit); release.await() } }
            val work = f.model.rotatePreview()!!; entered.await()
            if (close) f.model.preview.closePreview() else f.model.preview.adjacent(1)
            release.complete(Unit); work.join(); await { !f.model.preview.state.value.loading }
            assertEquals(if (close) null else 92L, f.model.preview.state.value.photo?.id?.itemId)
            assertEquals(0f, f.model.preview.state.value.rotationDegrees); assertEquals(8, f.model.state.value.items.first().orientation)
        }
    }
    @Test fun `撤权取消请求但提交事实留存冷恢复不继承内存回执`() = runBlocking {
        scenario { f ->
            f.ready(); val entered = CompletableDeferred<Unit>()
            f.fixture.before = { if (it.method == "set") { entered.complete(Unit); awaitCancellation() } }
            val work = f.model.rotatePreview()!!; entered.await(); f.model.revokeAccess(); work.join()
            assertNull(f.model.preview.state.value.photo); assertTrue(f.model.edits!!.state.value.records.isEmpty())
            val cold = SynologyPhotoEditStore(f.preferences).records(f.owner.copy(sessionGeneration = "new"), 41).single()
            assertEquals(SynologyPhotoEditPhase.PENDING, cold.checkpoint.phase)
            assertEquals(SynologyPhotoEdit.Rotation(1, 640, 480), cold.checkpoint.edit)
            val other = Fixture().ready(); other.values.putAll(f.fixture.values)
            assertEquals(SynologyPhotoEditPhase.PENDING, other.repository.performPhotoEdit(cold.checkpoint) {}.phase)
            assertTrue(other.writes.isEmpty())
        }
    }
    @Test fun `旧评分记录与新旋转记录同时可读且原快照不能改写`() = runBlocking {
        scenario { f ->
            val p = f.original
            fun row(edit: SynologyPhotoEdit) = SynologyPhotoEditRecord(owner = f.owner, checkpoint = SynologyPhotoEditCheckpoint(
                profileId = p.id.profileId, userId = 41, space = p.id.space, targets = listOf(SynologyPhotoEditTarget(p)), edit = edit))
            val old = row(SynologyPhotoEdit.Rating(3)); f.store.begin(old)
            val rotation = row(SynologyPhotoEdit.Rotation(1, 640, 480)); f.store.begin(rotation)
            val submitted = rotation.checkpoint.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = setOf(0))
            f.store.save(rotation.id, f.owner, 41, submitted)
            val records = SynologyPhotoEditStore(f.preferences).records(f.owner, 41)
            assertEquals(2, records.size); assertEquals(old, records.single { it.id == old.id })
            try { f.store.save(rotation.id, f.owner, 41, submitted.copy(edit = SynologyPhotoEdit.Rotation(8, 480, 640))); fail() }
            catch (_: SynologyPhotoEditFailure) { }
        }
    }
    @Test fun `刷新完成照片期间保持忙碌避免新操作与旧完成回调交错`() = runBlocking {
        scenario { f ->
            f.fixture.ready()
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val editor = SynologyPhotoEditModel(f.api, f.scope, f.store, f.owner, {}, { true },
                onRotationFinished = { row -> assertEquals(SynologyPhotoEditPhase.COMPLETED, row?.phase); entered.complete(Unit); release.await() }, onCompleted = {})
            try {
                val work = editor.rotate(f.original)!!; entered.await()
                assertTrue(editor.state.value.working)
                assertNull(editor.rotate(f.fixture.values.getValue(f.original.id)))
                release.complete(Unit); work.join(); assertFalse(editor.state.value.working)
                assertEquals(1, f.fixture.writes.size)
            } finally { release.complete(Unit); editor.close() }
        }
    }
    private suspend fun scenario(block: suspend (Scenario) -> Unit) { val f = Scenario(); try { block(f) } finally { f.close() } }
    private companion object { suspend fun await(predicate: () -> Boolean) { withTimeout(8_000) { while (!predicate()) delay(5) } } }
}
