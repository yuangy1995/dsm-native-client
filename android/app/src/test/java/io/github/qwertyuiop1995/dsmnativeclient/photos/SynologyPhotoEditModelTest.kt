package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoEditModelTest {
    @Test fun `目录与照片共用百项上限并按网格目录优先选择清空时一同复位`() = runBlocking {
        fixture { f ->
            val folders = (10L..109L).map { SynologyPhotoCollection(it, "Child$it", parentId = 9, path = "/Source/Child$it") }
            f.model.selectLoaded(listOf(f.api.photo), folders)
            assertEquals(100, f.model.state.value.selectedFolders.size); assertTrue(f.model.state.value.selected.isEmpty())
            f.model.toggle(f.api.photo)
            assertEquals(SynologyPhotoEditProblem.LIMIT, (f.model.state.value.error as SynologyPhotoEditFailure).problem)
            f.model.toggleFolder(folders.last()); f.model.toggle(f.api.photo)
            assertEquals(99, f.model.state.value.selectedFolders.size); assertEquals(listOf(f.api.photo), f.model.state.value.selected)
            f.model.toggleFolder(folders.first().copy(id = 999, parentId = 20, path = "/Other/Child999"))
            assertEquals(99, f.model.state.value.selectedFolders.size)
            f.model.selectMode(false); assertFalse(f.model.state.value.selecting)
            assertTrue(f.model.state.value.selected.isEmpty()); assertTrue(f.model.state.value.selectedFolders.isEmpty())
        }
    }
    @Test fun `多选保存前零写且重复保存被阻止`() = runBlocking {
        fixture { f ->
            f.model.toggle(f.api.photo)
            f.model.open(f.model.state.value.selected, SynologyPhotoSpace.PERSONAL); ready(f)
            assertEquals(0, f.api.writes)
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.api.beforeWrite = { entered.complete(Unit); release.await() }
            val task = f.model.save()!!; entered.await()
            assertTrue(SynologyPhotoEditStore.isProfileBusy(owner.profileId)); assertNull(f.model.save())
            release.complete(Unit); task.join()
            assertTrue(f.model.state.value.records.single().checkpoint.finished)
            assertFalse(f.model.state.value.selecting); assertEquals(1, f.api.writes)
            assertFalse(SynologyPhotoEditStore.isProfileBusy(owner.profileId))
        }
    }
    @Test fun `详情读取失败保留错误且不能保存默认空资料`() = runBlocking {
        fixture { f ->
            f.api.failDetails = true; f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL)
            await { !f.model.state.value.loading }
            assertFalse(f.model.state.value.detailsReady); assertNotNull(f.model.state.value.error)
            assertNull(f.model.save()); assertEquals(0, f.api.writes)
            f.api.failDetails = false; f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL); ready(f)
            f.model.save()!!.join(); assertEquals(1, f.api.writes)
        }
    }
    @Test fun `关闭重开只恢复记录且已提交继续只调用回读`() = runBlocking {
        fixture { f ->
            f.api.pending = true; f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL); ready(f)
            f.model.save()!!.join(); val id = f.model.state.value.records.single().id
            f.model.close()
            val restored = SynologyPhotoEditModel(f.api, f.scope, SynologyPhotoEditStore(f.preferences), owner.copy(sessionGeneration = "new"), {}, { true }, onCompleted = {})
            try {
                restored.showRecords(); await { restored.state.value.records.isNotEmpty() }
                assertEquals(1, f.api.writes)
                f.api.pending = false; restored.resume(id)!!.join()
                assertTrue(restored.state.value.records.single().checkpoint.finished)
                assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
            } finally { restored.close() }
        }
    }
    @Test fun `撤权取消在途请求清空界面且保存提交事实`() = runBlocking {
        fixture { f ->
            val entered = CompletableDeferred<Unit>()
            f.api.beforeWrite = { entered.complete(Unit); awaitCancellation() }
            f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL); ready(f)
            val task = f.model.save()!!; entered.await(); f.model.revokeAccess(); task.join()
            assertFalse(f.model.state.value.visible); assertTrue(f.model.state.value.records.isEmpty())
            assertEquals(SynologyPhotoEditPhase.PENDING, f.store.records(owner, 41).single().checkpoint.phase)
            assertFalse(SynologyPhotoEditStore.isProfileBusy(owner.profileId))
        }
    }
    @Test fun `部分日期继续仅用原始未完成项而不再次偏移完成项`() = runBlocking {
        fixture { f ->
            val second = f.api.photo.copy(id = f.api.photo.id.copy(itemId = 92), takenAt = 2000.0)
            val checkpoint = SynologyPhotoEditCheckpoint(profileId = owner.profileId, userId = 41, space = SynologyPhotoSpace.PERSONAL,
                targets = listOf(f.api.photo, second).map(::SynologyPhotoEditTarget), edit = SynologyPhotoEdit.ShiftDates(60))
            val row = SynologyPhotoEditRecord(owner = owner, checkpoint = checkpoint)
            f.store.begin(row); f.store.save(row.id, owner, 41, checkpoint.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = setOf(0)))
            f.store.save(row.id, owner, 41, checkpoint.copy(phase = SynologyPhotoEditPhase.PARTIAL, attempted = setOf(0), completed = setOf(0)))
            f.model.refreshRecords()!!.join(); f.model.continueRemaining(row.id)
            val draft = f.model.state.value.draft!!
            assertEquals(listOf(second.id), draft.photos.map { it.id }); assertEquals(2000.0, draft.photos.single().takenAt, 0.0)
            assertEquals(SynologyPhotoEdit.ShiftDates(60), draft.edit); assertNotEquals(row.id, draft.id)
        }
    }
    @Test fun `其他身份不加载记录且百张选择上限明确`() = runBlocking {
        fixture { f ->
            f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL); ready(f); f.model.save()!!.join()
            assertTrue(f.store.records(owner.copy(identityRevision = "other-account"), 41).isEmpty())
            assertTrue(f.store.records(owner, 42).isEmpty())
            val photos = (1L..101L).map { f.api.photo.copy(id = f.api.photo.id.copy(itemId = it)) }
            f.model.selectLoaded(photos); assertEquals(100, f.model.state.value.selected.size)
            f.model.toggle(photos.last()); assertEquals(100, f.model.state.value.selected.size)
            assertEquals(SynologyPhotoEditProblem.LIMIT, (f.model.state.value.error as SynologyPhotoEditFailure).problem)
        }
    }
    @Test fun `损坏或未来记录不能当作空队列开始写入`() = runBlocking {
        for (raw in listOf("invalid", """{"version":2}""")) fixture { f ->
            f.preferences.edit().putString("photos_edit_v1_broken", raw).commit()
            f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL); ready(f)
            f.model.save()!!.join()
            assertEquals(SynologyPhotoEditProblem.STORAGE, (f.model.state.value.error as SynologyPhotoEditFailure).problem)
            assertEquals(0, f.api.writes); assertEquals(raw, f.preferences.getString("photos_edit_v1_broken", null))
        }
    }
    @Test fun `未完成记录不可清除且相同原件不能创建第二次修改`() = runBlocking {
        fixture { f ->
            f.api.pending = true; f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL); ready(f); f.model.save()!!.join()
            val id = f.model.state.value.records.single().id
            f.model.discard(id)!!.join(); assertEquals(1, f.model.state.value.records.size)
            f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL); ready(f); f.model.save()!!.join()
            assertEquals(SynologyPhotoEditProblem.PENDING, (f.model.state.value.error as SynologyPhotoEditFailure).problem)
            assertEquals(1, f.api.writes)
        }
    }
    @Test fun `移除已完成记录不发送NAS请求`() = runBlocking {
        fixture { f ->
            f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL); ready(f); f.model.save()!!.join()
            f.model.discard(f.model.state.value.records.single().id)!!.join()
            assertTrue(f.model.state.value.records.isEmpty()); assertEquals(1, f.api.writes)
        }
    }
    @Test fun `其他写任务运行时不能启动编辑`() = runBlocking {
        fixture { f ->
            f.allowed = false; f.model.open(listOf(f.api.photo), SynologyPhotoSpace.PERSONAL)
            assertFalse(f.model.state.value.visible); assertNull(f.model.save()); assertEquals(0, f.api.writes)
        }
    }
    @Test fun `尚未加载界面记录时删除仍读取持久编辑保护`() = runBlocking {
        fixture { f ->
            val row = pending(f)
            assertTrue(f.model.state.value.records.isEmpty())
            val deletion = SynologyPhotoDeletionModel(f.api, f.scope, SynologyPhotoDeletionStore(MemoryPreferences()), owner, beforeWrite = f.model::requireNoPending) {}
            deletion.activate(); withTimeout(5_000) { while (deletion.state.value.checking) delay(2) }
            deletion.prepare(f.api.photo)!!.join()
            assertNull(deletion.state.value.candidate)
            assertEquals(SynologyPhotoEditProblem.PENDING, (deletion.state.value.error as SynologyPhotoEditFailure).problem)
            assertEquals(0, f.api.deletes); assertEquals(row.id, f.store.records(owner, 41).single().id)
        }
    }
    @Test fun `删除确认之前再次检查未完成编辑而不只依赖按钮状态`() = runBlocking {
        fixture { f ->
            val deletion = SynologyPhotoDeletionModel(f.api, f.scope, SynologyPhotoDeletionStore(MemoryPreferences()), owner, beforeWrite = f.model::requireNoPending) {}
            deletion.activate(); withTimeout(5_000) { while (deletion.state.value.checking) delay(2) }
            deletion.prepare(f.api.photo)!!.join(); assertNotNull(deletion.state.value.candidate)
            pending(f)
            deletion.confirm()!!.join()
            assertEquals(0, f.api.deletes); assertNull(deletion.state.value.pending)
            assertEquals(SynologyPhotoEditProblem.PENDING, (deletion.state.value.error as SynologyPhotoEditFailure).problem)
        }
    }

    private fun pending(f: Fixture): SynologyPhotoEditRecord {
        val row = SynologyPhotoEditRecord(owner = owner, checkpoint = SynologyPhotoEditCheckpoint(profileId = owner.profileId,
            userId = 41, space = SynologyPhotoSpace.PERSONAL, targets = listOf(SynologyPhotoEditTarget(f.api.photo)), edit = SynologyPhotoEdit.Rating(4)))
        f.store.begin(row); f.store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = setOf(0)))
        return row
    }

    private class Fixture {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val preferences = MemoryPreferences()
        val store = SynologyPhotoEditStore(preferences)
        val api = EditServing()
        var allowed = true
        val model = SynologyPhotoEditModel(api, scope, store, owner, {}, { allowed }, onCompleted = {})
    }
    private class EditServing : SynologyPhotosServing {
        override val profileId = owner.profileId
        override val canEditPhotos = true
        override val canDeleteOriginals = true
        val photo = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, 91), "synthetic.jpg", 4, 1000.0, 900.0, 9, "photo", rating = 2, description = "Synthetic")
        var failDetails = false
        var pending = false
        var writes = 0
        var reviews = 0
        var deletes = 0
        var beforeWrite: suspend () -> Unit = {}
        override suspend fun access() = SynologyPhotoAccess(listOf(SynologyPhotoSpace.PERSONAL), "synthetic")
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
        override suspend fun photoEditIdentity() = 41L
        override suspend fun prepareDeletion(photo: SynologyPhoto) = Unit
        override suspend fun performPhotoDeletion(photo: SynologyPhoto, checkpoint: SynologyPhotoDeletionCheckpoint,
            save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint {
            val sent = checkpoint.copy(phase = SynologyPhotoDeletionPhase.SUBMITTED); save(sent); deletes++
            return sent.copy(phase = SynologyPhotoDeletionPhase.CONFIRMED).also(save)
        }
        override suspend fun details(photo: SynologyPhoto): SynologyPhoto { if (failDetails) throw IOException("synthetic"); return this.photo }
        override suspend fun performPhotoEdit(checkpoint: SynologyPhotoEditCheckpoint, save: (SynologyPhotoEditCheckpoint) -> Unit): SynologyPhotoEditCheckpoint {
            val submitted = checkpoint.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = checkpoint.targets.indices.toSet())
            save(submitted); beforeWrite(); writes++
            return settle(submitted).also(save)
        }
        override suspend fun reviewPhotoEdit(checkpoint: SynologyPhotoEditCheckpoint, save: (SynologyPhotoEditCheckpoint) -> Unit): SynologyPhotoEditCheckpoint {
            reviews++; return settle(checkpoint).also(save)
        }
        private fun settle(row: SynologyPhotoEditCheckpoint) = row.copy(phase = if (pending) SynologyPhotoEditPhase.PENDING else SynologyPhotoEditPhase.COMPLETED,
            completed = if (pending) emptySet() else row.attempted)
    }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val f = Fixture()
        try { block(f) } finally { f.model.close(); f.scope.coroutineContext[Job]!!.cancelAndJoin() }
    }
    private companion object {
        val owner = WorkspaceOwner("profile-edit", "identity-edit", "session-edit")
        suspend fun ready(f: Fixture) { await { !f.model.state.value.loading && f.model.state.value.detailsReady } }
        suspend fun await(block: () -> Boolean) { withTimeout(10_000) { while (!block()) delay(10) } }
    }
}
