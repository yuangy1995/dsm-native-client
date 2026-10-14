package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoDeletionModelTest {
    private class Serving : SynologyPhotosServing {
        override val profileId = "deletion-model"
        override val canDeleteOriginals = true
        val writes = mutableListOf<Long>(); val reviews = mutableListOf<Long>(); val preparations = mutableListOf<Long>()
        val originals = (1L..4L).associateWith { photo(it) }.toMutableMap()
        var preflight: suspend (SynologyPhoto) -> Unit = {}
        var execute: suspend (SynologyPhoto) -> SynologyPhotoDeletionPhase = { SynologyPhotoDeletionPhase.CONFIRMED }
        var read: suspend (SynologyPhotoDeletionCheckpoint) -> SynologyPhotoDeletionPhase = { SynologyPhotoDeletionPhase.SUBMITTED }
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic")
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
        override suspend fun photoEditIdentity() = 41L
        override suspend fun prepareDeletion(photo: SynologyPhoto) { preparations += photo.id.itemId; preflight(photo) }
        override suspend fun deletionTarget(checkpoint: SynologyPhotoDeletionCheckpoint): SynologyPhoto {
            val photo = originals[checkpoint.target.id.itemId] ?: throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
            if (!checkpoint.target.matches(photo)) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
            return photo
        }
        override suspend fun performPhotoDeletion(photo: SynologyPhoto, checkpoint: SynologyPhotoDeletionCheckpoint,
            save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint {
            val sent = checkpoint.copy(phase = SynologyPhotoDeletionPhase.SUBMITTED); save(sent); writes += photo.id.itemId
            val result = try { execute(photo) } catch (error: Exception) {
                if (error is DsmFailure && error.code == 105) { save(sent.copy(phase = SynologyPhotoDeletionPhase.REJECTED)); throw error }
                return sent
            }
            return sent.copy(phase = result).also(save)
        }
        override suspend fun reviewPhotoDeletion(checkpoint: SynologyPhotoDeletionCheckpoint,
            save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint {
            reviews += checkpoint.target.id.itemId
            return checkpoint.copy(phase = read(checkpoint)).also(save)
        }
    }
    private class Fixture(val preferences: MemoryPreferences = MemoryPreferences(), val api: Serving = Serving()) : AutoCloseable {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session")
        val store = SynologyPhotoDeletionStore(preferences)
        val applied = mutableListOf<Long>()
        var current = true; var allowed = true
        val model = SynologyPhotoDeletionModel(api, scope, store, owner,
            requireCurrent = { if (!current) throw CancellationException() }, canStart = { allowed },
            onConfirmed = { applied += it.target.id.itemId })
        suspend fun ready() { model.activate(); settled() }
        suspend fun settled() = withTimeout(5_000) { while (model.state.value.checking || model.state.value.recovering || model.state.value.writing) delay(2) }
        override fun close() { model.close(); runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() } }
    }
    @Test fun `固定清单取消零写入确认逐项完成并可移除本地记录`() = runBlocking {
        Fixture().use { f ->
            f.ready(); val list = mutableListOf(photo(1), photo(2))
            f.model.prepare(list)!!.join(); list.clear()
            assertEquals(listOf(1L, 2L), f.model.state.value.candidate!!.map { it.id.itemId })
            f.model.cancelCandidate(); assertTrue(f.api.writes.isEmpty()); assertTrue(f.store.records(f.owner, 41).isEmpty())
            f.model.prepare(listOf(photo(1), photo(2)))!!.join(); f.model.confirm()!!.join()
            assertEquals(listOf(1L, 2L), f.api.writes); assertEquals(listOf(1L, 2L), f.applied)
            val record = f.model.state.value.records.single(); assertTrue(record.finished)
            f.model.discard(record.id)!!.join(); assertTrue(f.model.state.value.records.isEmpty()); assertEquals(2, f.api.writes.size)
        }
    }
    @Test fun `整批预检失败和确认后权限变化都保持零删除`() = runBlocking {
        Fixture().use { f ->
            f.ready(); f.api.preflight = { if (it.id.itemId == 2L) throw SynologyPhotoFailure(SynologyPhotoFailureKind.DELETE_DENIED) }
            f.model.prepare(listOf(photo(1), photo(2)))!!.join()
            assertNull(f.model.state.value.candidate); assertTrue(f.api.writes.isEmpty())
            f.api.preflight = {}; f.model.retry()!!.join(); assertNotNull(f.model.state.value.candidate)
            f.api.preflight = { throw SynologyPhotoFailure(SynologyPhotoFailureKind.DELETE_DENIED) }
            f.model.confirm()!!.join()
            assertTrue(f.api.writes.isEmpty()); assertTrue(f.store.records(f.owner, 41).isEmpty())
            assertEquals(listOf(photo(1), photo(2)), f.model.state.value.candidate)
            assertFalse(f.model.state.value.recordsPage)
            f.api.preflight = {}; f.model.confirm()!!.join(); assertEquals(listOf(1L, 2L), f.api.writes)
        }
    }
    @Test fun `写前存储失败不发送请求损坏记录也不能开始新删除`() = runBlocking {
        Fixture().use { f ->
            f.ready(); f.model.prepare(photo(1))!!.join(); f.preferences.commitSucceeds = false
            f.model.confirm()!!.join(); assertTrue(f.api.writes.isEmpty())
            assertEquals(SynologyPhotoDeletionProblem.STORAGE, (f.model.state.value.error as SynologyPhotoDeletionFailure).problem)
        }
        val bad = MemoryPreferences().apply { edit().putString("photos_deletion_v1_broken", "corrupt").commit() }
        Fixture(bad).use { f ->
            f.ready(); assertNotNull(f.model.state.value.error)
            try { f.model.requireNoPending(); fail() } catch (error: SynologyPhotoDeletionFailure) { assertEquals(SynologyPhotoDeletionProblem.STORAGE, error.problem) }
            f.model.prepare(photo(1))!!.join(); assertNull(f.model.state.value.candidate); assertTrue(f.api.writes.isEmpty())
            assertEquals("corrupt", bad.getString("photos_deletion_v1_broken", null))
        }
    }
    @Test fun `部分完成遇未知停止后续项并保留三种状态`() = runBlocking {
        Fixture().use { f ->
            f.ready(); f.api.execute = { if (it.id.itemId == 2L) SynologyPhotoDeletionPhase.SUBMITTED else SynologyPhotoDeletionPhase.CONFIRMED }
            f.model.prepare(listOf(photo(1), photo(2), photo(3)))!!.join(); f.model.confirm()!!.join()
            assertEquals(listOf(1L, 2L), f.api.writes); assertEquals(listOf(1L), f.applied)
            assertEquals(listOf(SynologyPhotoDeletionPhase.CONFIRMED, SynologyPhotoDeletionPhase.SUBMITTED, SynologyPhotoDeletionPhase.PREPARED), f.model.state.value.records.single().entries.map { it.phase })
            try { f.model.requireNoPending(); fail() } catch (error: SynologyPhotoDeletionFailure) { assertEquals(SynologyPhotoDeletionProblem.PENDING, error.problem) }
        }
    }
    @Test fun `明确拒绝停止后续项且不误记未知`() = runBlocking {
        Fixture().use { f ->
            f.ready(); f.api.execute = { throw DsmFailure(105, "Synthetic denial", "Request access") }
            f.model.prepare(listOf(photo(1), photo(2)))!!.join(); f.model.confirm()!!.join()
            assertEquals(listOf(1L), f.api.writes); assertTrue(f.applied.isEmpty())
            assertEquals(listOf(SynologyPhotoDeletionPhase.REJECTED, SynologyPhotoDeletionPhase.PREPARED), f.model.state.value.records.single().entries.map { it.phase })
            assertEquals(105, (f.model.state.value.error as DsmFailure).code)
        }
    }
    @Test fun `冷恢复只查询已提交项剩余重新读取并明确确认才继续`() = runBlocking {
        val preferences = MemoryPreferences(); val api = Serving()
        Fixture(preferences, api).use { f ->
            f.ready(); api.execute = { SynologyPhotoDeletionPhase.SUBMITTED }
            f.model.prepare(listOf(photo(1), photo(2)))!!.join(); f.model.confirm()!!.join()
        }
        Fixture(preferences, api).use { f ->
            f.ready(); val id = f.model.state.value.records.single().id
            assertEquals(listOf(1L), api.writes)
            api.read = { SynologyPhotoDeletionPhase.CONFIRMED }; f.model.review(id)!!.join()
            assertEquals(listOf(1L), api.writes); assertEquals(listOf(1L), api.reviews)
            f.model.resume(id)!!.join(); assertEquals(listOf(photo(2)), f.model.state.value.candidate)
            assertEquals(listOf(1L), api.writes)
            api.execute = { SynologyPhotoDeletionPhase.CONFIRMED }; f.model.confirm()!!.join()
            assertEquals(listOf(1L, 2L), api.writes); assertTrue(f.model.state.value.records.single().finished)
        }
    }
    @Test fun `恢复时原件变化拒绝继续但允许取消剩余`() = runBlocking {
        Fixture().use { f ->
            val row = SynologyPhotoDeletionRecord(owner = f.owner, userId = 41, entries = listOf(SynologyPhotoDeletionCheckpoint(userId = 41, target = SynologyPhotoDeletionTarget(photo(1)))))
            f.store.begin(row); f.api.originals[1] = photo(1).copy(filename = "changed.jpg")
            f.ready(); f.model.resume(row.id)!!.join(); assertNull(f.model.state.value.candidate)
            assertEquals(SynologyPhotoFailureKind.TARGET_CHANGED, (f.model.state.value.error as SynologyPhotoFailure).kind)
            f.model.showRecords(); f.settled(); f.model.cancelRemaining(row.id)!!.join()
            assertTrue(f.model.state.value.records.single().finished); assertTrue(f.api.writes.isEmpty())
        }
    }
    @Test fun `取消剩余不取消已提交删除也不解除其防重保护`() = runBlocking {
        Fixture().use { f ->
            f.ready(); f.api.execute = { SynologyPhotoDeletionPhase.SUBMITTED }
            f.model.prepare(listOf(photo(1), photo(2)))!!.join(); f.model.confirm()!!.join()
            val id = f.model.state.value.records.single().id
            f.model.cancelRemaining(id)!!.join()
            assertEquals(listOf(SynologyPhotoDeletionPhase.SUBMITTED, SynologyPhotoDeletionPhase.CANCELLED), f.model.state.value.records.single().entries.map { it.phase })
            assertEquals(listOf(1L), f.api.writes)
            f.model.prepare(photo(3))!!.join(); assertNull(f.model.state.value.candidate)
            assertEquals(SynologyPhotoDeletionProblem.PENDING, (f.model.state.value.error as SynologyPhotoDeletionFailure).problem)
        }
    }
    @Test fun `离开后迟到回执只保存旧批次不删除后续或更新新页面`() = runBlocking {
        Fixture().use { f ->
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.ready(); f.api.execute = { withContext(NonCancellable) { entered.complete(Unit); release.await() }; SynologyPhotoDeletionPhase.CONFIRMED }
            f.model.prepare(listOf(photo(1), photo(2)))!!.join(); val task = f.model.confirm()!!
            entered.await(); assertNull(f.model.confirm()); f.model.deactivate(); f.current = false
            release.complete(Unit); task.join()
            assertEquals(listOf(1L), f.api.writes); assertTrue(f.applied.isEmpty())
            assertEquals(listOf(SynologyPhotoDeletionPhase.CONFIRMED, SynologyPhotoDeletionPhase.PREPARED), f.store.records(f.owner, 41).single().entries.map { it.phase })
            assertFalse(f.model.state.value.visible); assertFalse(f.model.state.value.writing)
        }
    }
    @Test fun `其他任务运行和超过固定清单上限不能打开删除`() = runBlocking {
        Fixture().use { f ->
            f.ready(); f.allowed = false; assertNull(f.model.prepare(photo(1))); assertFalse(f.model.state.value.visible)
            f.allowed = true
            for (photos in listOf(emptyList(), listOf(photo(1), photo(1)), (1L..101L).map(::photo))) {
                assertNull(f.model.prepare(photos)); assertEquals(SynologyPhotoDeletionProblem.LIMIT, (f.model.state.value.error as SynologyPhotoDeletionFailure).problem)
            }
            assertTrue(f.api.writes.isEmpty())
        }
    }
    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun `自动恢复只读取离开停止重进继续且长等待降频`() = runBlocking {
        val scheduler = TestCoroutineScheduler()
        val timerScope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(scheduler))
        val api = Serving(); val owner = WorkspaceOwner(api.profileId, "auto", "session"); val store = SynologyPhotoDeletionStore(MemoryPreferences())
        val row = SynologyPhotoDeletionRecord(owner = owner, userId = 41, entries = listOf(SynologyPhotoDeletionCheckpoint(userId = 41, target = SynologyPhotoDeletionTarget(photo(1)))))
        store.begin(row); store.update(row.id, owner, 41, row.entries.single().copy(phase = SynologyPhotoDeletionPhase.SUBMITTED))
        SynologyPhotoDeletionModel(api, timerScope, store, owner, onConfirmed = {}).use { model ->
            suspend fun settled() = withTimeout(5_000) {
                do { scheduler.runCurrent(); delay(1) } while (model.state.value.checking || model.state.value.recovering)
                scheduler.runCurrent()
            }
            model.activate(); scheduler.runCurrent(); settled()
            repeat(6) { scheduler.advanceTimeBy(2_000); scheduler.runCurrent(); settled() }
            assertEquals(6, api.reviews.size); assertTrue(api.writes.isEmpty())
            scheduler.advanceTimeBy(14_999); scheduler.runCurrent(); assertEquals(6, api.reviews.size)
            scheduler.advanceTimeBy(1); scheduler.runCurrent(); settled(); assertEquals(7, api.reviews.size)
            model.deactivate(); scheduler.advanceTimeBy(30_000); scheduler.runCurrent(); assertEquals(7, api.reviews.size)
            model.activate(); scheduler.runCurrent(); settled(); api.read = { SynologyPhotoDeletionPhase.CONFIRMED }
            scheduler.advanceTimeBy(2_000); scheduler.runCurrent(); settled()
            assertTrue(model.state.value.records.single().finished); assertTrue(api.writes.isEmpty())
        }
        timerScope.cancel(); scheduler.runCurrent()
    }
    companion object {
        private fun photo(id: Long) = SynologyPhoto(SynologyPhotoId("deletion-model", SynologyPhotoSpace.PERSONAL, id), "photo-$id.jpg", 4, 1000.0, 1001.0, 9, "photo")
    }
}
