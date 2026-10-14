package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.time.LocalDate
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoManualFacesModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "manual-model-${UUID.randomUUID()}"
        override val canManageAlbums = true; override val canEditPhotos = true
        var identity = 41L; var enabled = true; var pending = false; var readError = false; var prepareError = false
        var beforeRead: suspend () -> Unit = {}; var beforePrepare: suspend () -> Unit = {}; var beforeWrite: suspend () -> Unit = {}
        val writes = CopyOnWriteArrayList<SynologyPhotoAlbumCheckpoint>(); val reviews = CopyOnWriteArrayList<String>()
        val received = CopyOnWriteArrayList<Map<String, ByteArray>>()
        val faces = CopyOnWriteArrayList(listOf(SynologyPhotoFaceSnapshot(71, 1, "Synthetic 1", SynologyPhotoFaceBounds(0.1, 0.2, 0.3, 0.4))))
        val people = CopyOnWriteArrayList((1L..3L).map { SynologyPhotoCollection(it, "Synthetic $it", count = 1, personVisible = it != 3L) })
        val photo = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 100, 1.0, 1.0, 9, "photo")
        override fun canEditPhotoFaces(photo: SynologyPhoto) = enabled && photo.mediaType != "video"
        override suspend fun photoEditIdentity() = identity
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(1970, 1, 1), 1))
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(listOf(photo), 0, 1, false)
        override suspend fun categories(space: SynologyPhotoSpace) = setOf(SynologyPhotoCategory.PEOPLE)
        override suspend fun details(photo: SynologyPhoto): SynologyPhoto = photo
        override suspend fun thumbnail(photo: SynologyPhoto, large: Boolean) = byteArrayOf(10, 20, 30)
        override suspend fun photoFaces(photo: SynologyPhoto): List<SynologyPhotoFaceRegion> {
            beforeRead(); if (readError) throw IOException("Synthetic read")
            if (!enabled) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
            return faces.map { SynologyPhotoFaceRegion(it, "synthetic") }
        }
        override suspend fun managementPeople(space: SynologyPhotoSpace, includingHidden: Boolean) =
            people.filter { includingHidden || it.personVisible != false }.map { it.copy(space = space) }
        override suspend fun prepareManualFaces(photo: SynologyPhoto, originals: List<SynologyPhotoFaceSnapshot>, changes: List<SynologyPhotoFaceChange>): SynologyPhotoAlbumCheckpoint {
            beforePrepare(); if (prepareError) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
            return SynologyPhotoAlbumCheckpoint(profileId = profileId, userId = identity, action = SynologyPhotoAlbumAction.EDIT_PHOTO_FACES,
                targets = listOf(SynologyPhotoEditTarget(photo)), manualFaces = SynologyPhotoManualFacesCheckpoint(originals, changes))
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) {
            if (prepareError) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        }
        override suspend fun performManualFaces(checkpoint: SynologyPhotoAlbumCheckpoint, images: Map<String, ByteArray>, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            var row = checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); save(row)
            writes += row; received += images.mapValues { it.value.copyOf() }; beforeWrite()
            var value = row.manualFaces!!
            val additions = value.changes.filterIsInstance<SynologyPhotoFaceChange.Add>()
            if (additions.isNotEmpty()) {
                value = value.copy(addAttempted = true); save(row.copy(manualFaces = value))
                val ids = additions.mapIndexed { index, face -> face.temporaryId to 800L + index }.toMap()
                value = value.copy(addAcknowledged = true, newIds = ids); save(row.copy(manualFaces = value))
                value = value.copy(uploadAttempted = ids.values.toSet()); save(row.copy(manualFaces = value))
                value = value.copy(uploaded = ids.values.toSet()); save(row.copy(manualFaces = value))
            }
            val changes = value.changes.filterNot { it is SynologyPhotoFaceChange.Add }
            value = value.copy(attempted = changes.map { it.key }.toSet()); save(row.copy(manualFaces = value))
            value = value.copy(acknowledged = value.attempted, personReceipts = changes.filterIsInstance<SynologyPhotoFaceChange.Reassign>().associate { it.key to (it.person?.id ?: 90L) })
            row = row.copy(manualFaces = value); save(row)
            return finish(row).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews += checkpoint.operationId; return finish(checkpoint).also(save)
        }
        private fun finish(row: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumCheckpoint {
            if (pending) return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
            val value = row.manualFaces!!
            value.changes.forEach { change ->
                when (change) {
                    is SynologyPhotoFaceChange.Add -> {
                        val id = value.newIds.getValue(change.temporaryId)
                        if (faces.none { it.id == id }) faces += SynologyPhotoFaceSnapshot(id, change.person?.id ?: 90, change.name, change.bounds)
                    }
                    is SynologyPhotoFaceChange.Remove -> faces.removeAll { it.id == change.original.id }
                    is SynologyPhotoFaceChange.Reassign -> faces.replaceAll { if (it.id == change.original.id) it.copy(personId = value.personReceipts.getValue(change.key), name = change.name) else it }
                }
            }
            return row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, manualFaces = value.copy(completed = value.changes.map { it.key }.toSet()))
        }
    }
    private class Fixture {
        val api = Api(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val preferences = MemoryPreferences(); val owner = WorkspaceOwner(api.profileId, "identity", "session"); val store = SynologyPhotoAlbumStore(preferences)
        val applied = CopyOnWriteArrayList<SynologyPhotoAlbumCheckpoint>(); val ticks = Channel<Unit>(Channel.UNLIMITED); val pauses = CopyOnWriteArrayList<Long>()
        var current = true; var canStart = true; var before: suspend () -> Unit = {}; var cropError = false
        val cropped = CopyOnWriteArrayList<ByteArray>()
        fun create(owner: WorkspaceOwner = this.owner) = SynologyPhotoManualFacesModel(api, scope, store, owner,
            { if (!current) throw CancellationException() }, { canStart }, { before() }, { applied += it },
            crop = { _, drafts ->
                if (cropError) throw IOException("Synthetic crop")
                drafts.filter { it.needsCrop }.associate { it.key to byteArrayOf(-1, -40, -1, 10, 20).also(cropped::add) }
            }, pause = { pauses += it; ticks.receive() })
        val model = create()
        suspend fun open(photo: SynologyPhoto = api.photo) { model.open(photo); await { !model.state.value.loading }; assertNull(model.state.value.error) }
        suspend fun newFace(name: String = "Synthetic new") { open(); model.add(); model.name(name) }
        suspend fun ready() = await { !model.state.value.loading && !model.state.value.working }
    }
    @Test fun `新增框生成裁剪直接保存回读后不能重复保存且图像摘要不落盘`() = runBlocking { fixture { f ->
        f.newFace(" New person "); assertTrue(f.model.state.value.canSave); f.model.save()!!.join(); f.ready()
        assertEquals(1, f.api.writes.size); assertNull(f.model.state.value.confirmation); assertEquals(1, f.applied.size)
        val row = f.model.state.value.records.single().checkpoint; val added = row.manualFaces!!.changes.single() as SynologyPhotoFaceChange.Add
        assertEquals("New person", added.name); assertEquals(setOf(added.temporaryId), f.api.received.single().keys)
        assertArrayEquals(byteArrayOf(-1, -40, -1, 10, 20), f.api.received.single().values.single())
        assertTrue(f.cropped.single().all { it == 0.toByte() }); assertFalse(f.model.state.value.canSave); assertNull(f.model.save())
        assertTrue(f.preferences.all.values.none { it.toString().contains("/9j/") }); assertEquals(2, f.model.state.value.drafts.size)
    } }
    @Test fun `移除及改归属需固定确认取消零写且不改变原件`() = runBlocking { fixture { f ->
        f.open(); f.model.remove(); f.model.save()!!.join(); val fixed = f.model.state.value.confirmation!!
        assertTrue(f.api.writes.isEmpty()); f.model.name("Ignored"); f.model.add(); assertEquals(1, f.model.state.value.drafts.size)
        f.model.cancelConfirmation(); assertTrue(f.api.writes.isEmpty()); f.model.remove(); f.model.person(2)
        f.model.save()!!.join(); assertTrue(f.model.state.value.confirmation!!.manualFaces!!.changes.single() is SynologyPhotoFaceChange.Reassign)
        f.model.confirm()!!.join(); f.ready(); assertEquals(2L, f.api.faces.single().personId)
        assertEquals(fixed.targets, f.api.writes.single().targets); assertTrue(f.cropped.isEmpty())
    } }
    @Test fun `调整已有框先新增及旧标记移除而归属不变`() = runBlocking { fixture { f ->
        f.open(); f.model.bounds(SynologyPhotoFaceBounds(0.2, 0.1, 0.2, 0.2)); f.model.save()!!.join()
        val changes = f.model.state.value.confirmation!!.manualFaces!!.changes
        assertEquals(2, changes.size); assertTrue(changes[0] is SynologyPhotoFaceChange.Add); assertTrue(changes[1] is SynologyPhotoFaceChange.Remove)
        assertEquals(1L, (changes[0] as SynologyPhotoFaceChange.Add).person!!.id); assertTrue(f.api.writes.isEmpty())
        f.model.confirm()!!.join(); f.ready(); assertEquals(800L, f.api.faces.single().id); assertEquals(1L, f.api.faces.single().personId)
    } }
    @Test fun `新增后移除没有变更恢复和空名称验证正常`() = runBlocking { fixture { f ->
        f.open(); assertFalse(f.model.state.value.canSave); f.model.add(); assertFalse(f.model.state.value.canSave)
        f.model.name("   "); assertFalse(f.model.state.value.canSave); f.model.name("Valid"); f.model.person(null)
        assertEquals("Valid", f.model.state.value.selectedDraft!!.name); assertTrue(f.model.state.value.canSave)
        f.model.remove(); assertFalse(f.model.state.value.canSave); f.model.remove(); assertTrue(f.model.state.value.canSave)
        f.model.person(3); assertEquals(3L, f.model.state.value.selectedDraft!!.person!!.id)
        f.model.name("Ignored"); assertEquals("Synthetic 3", f.model.state.value.selectedDraft!!.name)
    } }
    @Test fun `刷新错误保留名称和框且恢复相同照片后继续`() = runBlocking { fixture { f ->
        f.newFace(); val draft = f.model.state.value.drafts
        f.api.readError = true; f.model.load()!!.join(); assertFalse(f.model.state.value.loaded); assertEquals(draft, f.model.state.value.drafts)
        assertFalse(f.model.state.value.canSave); f.api.readError = false; f.model.load()!!.join()
        assertEquals(draft, f.model.state.value.drafts); assertTrue(f.model.state.value.canSave)
    } }
    @Test fun `刷新重新取得预览图片以恢复解码失败但不覆盖草稿`() = runBlocking { fixture { f ->
        f.newFace(); val image = f.model.state.value.image; val draft = f.model.state.value.drafts
        f.model.load()!!.join(); assertNotSame(image, f.model.state.value.image); assertEquals(draft, f.model.state.value.drafts)
        assertTrue(f.model.state.value.canSave)
    } }
    @Test fun `原标记改变不能静默覆盖草稿必须明确重新载入`() = runBlocking { fixture { f ->
        f.newFace(); val draft = f.model.state.value.drafts
        f.api.faces[0] = f.api.faces[0].copy(name = "Changed"); f.model.load()!!.join()
        assertEquals(SynologyPhotoFailureKind.TARGET_CHANGED, (f.model.state.value.error as SynologyPhotoFailure).kind)
        assertEquals(draft, f.model.state.value.drafts); assertFalse(f.model.state.value.canSave)
        f.model.load(restart = true)!!.join(); assertEquals(1, f.model.state.value.drafts.size); assertEquals("Changed", f.model.state.value.drafts.single().name)
    } }
    @Test fun `确认前权限撤销零写并保留草稿及清除裁剪图`() = runBlocking { fixture { f ->
        f.open(); f.model.bounds(SynologyPhotoFaceBounds(0.1, 0.1, 0.5, 0.5)); f.model.save()!!.join()
        val draft = f.model.state.value.drafts; f.api.prepareError = true; f.model.confirm()!!.join()
        assertTrue(f.api.writes.isEmpty()); assertEquals(draft, f.model.state.value.drafts); assertTrue(f.cropped.single().all { it == 0.toByte() })
        f.api.prepareError = false; f.model.save()!!.join(); f.model.confirm()!!.join(); assertEquals(1, f.api.writes.size)
    } }
    @Test fun `裁剪失败及写前冲突均零持久记录零请求`() = runBlocking { fixture { f ->
        f.newFace(); f.cropError = true; f.model.save()!!.join(); assertTrue(f.api.writes.isEmpty()); assertTrue(f.model.state.value.records.isEmpty())
        f.cropError = false; f.before = { throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING) }; f.model.save()!!.join()
        assertTrue(f.api.writes.isEmpty()); assertTrue(f.cropped.isEmpty()); assertTrue(f.model.state.value.canSave)
    } }
    @Test fun `提交期间双击和草稿编辑均不重复发送`() = runBlocking { fixture { f ->
        f.newFace(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { entered.complete(Unit); release.await() }; val work = f.model.save()!!; entered.await()
        val drafts = f.model.state.value.drafts; assertNull(f.model.save()); f.model.add(); f.model.name("Ignored"); f.model.remove()
        assertEquals(drafts, f.model.state.value.drafts); release.complete(Unit); work.join(); f.ready(); assertEquals(1, f.api.writes.size)
    } }
    @Test fun `未知结果只能只读刷新不能重发或清除`() = runBlocking { fixture { f ->
        f.newFace(); f.api.pending = true; f.model.save()!!.join(); val id = f.model.state.value.records.single().id
        assertTrue(f.model.state.value.pending); assertFalse(f.model.state.value.canSave); assertNull(f.model.discard(id)); assertNull(f.model.load(restart = true))
        f.model.resume(id)!!.join(); assertEquals(1, f.api.writes.size); assertEquals(1, f.api.reviews.size)
        f.api.pending = false; f.model.resume(id)!!.join(); f.ready(); assertFalse(f.model.state.value.pending); assertFalse(f.model.state.value.canSave)
        assertEquals(1, f.applied.size); f.model.discard(id)!!.join(); assertTrue(f.model.state.value.records.isEmpty())
    } }
    @Test fun `同身份新会话冷恢复只读且无需重新裁剪`() = runBlocking { fixture { f ->
        f.newFace(); f.api.pending = true; f.model.save()!!.join(); val id = f.model.state.value.records.single().id
        f.model.close(); val cold = f.create(f.owner.copy(sessionGeneration = "new-session"))
        try {
            cold.open(f.api.photo); await { !cold.state.value.loading }; assertTrue(cold.state.value.pending)
            f.cropError = true; f.api.pending = false; cold.resume(id)!!.join(); await { !cold.state.value.loading }
            assertEquals(1, f.api.writes.size); assertEquals(listOf(id), f.api.reviews.toList()); assertEquals(1, f.cropped.size)
        } finally { cold.close() }
    } }
    @Test fun `不同账号读取和恢复不认领旧记录`() = runBlocking { fixture { f ->
        f.newFace(); f.api.pending = true; f.model.save()!!.join(); val id = f.model.state.value.records.single().id
        f.api.identity = 42; f.model.resume(id)!!.join(); assertTrue(f.api.reviews.isEmpty()); assertTrue(f.model.state.value.records.isEmpty())
        assertEquals(1, f.store.records(f.owner, 41).size)
    } }
    @Test fun `慢读取在关闭及撤权后不能覆盖状态`() = runBlocking { fixture { f ->
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeRead = { withContext(NonCancellable) { entered.complete(Unit); release.await() } }
        f.model.open(f.api.photo); entered.await(); f.model.revokeAccess(); release.complete(Unit); delay(50)
        assertEquals(SynologyPhotoManualFacesState(), f.model.state.value); assertTrue(f.api.writes.isEmpty())
    } }
    @Test fun `前台轮询只读退后台停止并保留未决记录`() = runBlocking { fixture { f ->
        f.model.activate(); f.newFace(); f.api.pending = true; f.model.save()!!.join(); await { f.pauses.isNotEmpty() }
        f.ticks.send(Unit); await { f.api.reviews.size == 1 }; await { f.pauses.size == 2 }
        f.model.deactivate(); f.ticks.send(Unit); delay(50); assertEquals(1, f.api.reviews.size); assertEquals(1, f.api.writes.size)
        assertTrue(f.model.state.value.pending); assertEquals(listOf(15_000L, 15_000L), f.pauses.toList())
    } }
    @Test fun `不同照片和来源记录隔离且通用相册不展示手工记录`() = runBlocking { fixture { f ->
        f.newFace(); f.api.pending = true; f.model.save()!!.join(); f.model.dismiss()
        f.open(f.api.photo.copy(id = f.api.photo.id.copy(space = SynologyPhotoSpace.SHARED))); assertTrue(f.model.state.value.records.isEmpty())
        val root = SynologyPhotosModel(f.api, f.scope, uploadOwner = f.owner, albumStore = f.store)
        try {
            root.albums!!.refreshRecords()!!.join(); assertTrue(root.albums.state.value.records.isEmpty())
            val failure = runCatching { root.manualFaces!!.requireNoPending() }.exceptionOrNull()
            assertEquals(SynologyPhotoAlbumProblem.PENDING, (failure as SynologyPhotoAlbumFailure).problem)
        } finally { root.close() }
    } }
    @Test fun `人物内容只移除最后人脸对应照片且保留月份和分页`() = runBlocking { fixture { f ->
        f.open(); f.model.remove(); f.model.save()!!.join(); f.model.confirm()!!.join(); f.ready()
        val row = f.model.state.value.records.single().checkpoint
        val before = SynologyPhotosState(items = listOf(f.api.photo), navigation = SynologyPhotoNavigation(category = SynologyPhotoCategory.PEOPLE, categoryItem = f.api.people.first()))
        val state = MutableStateFlow(before); var removed = emptySet<SynologyPhotoId>()
        applyPhotoManualFacesChange(f.api, state, row, {}) { removed = it }
        assertEquals(setOf(f.api.photo.id), removed); assertTrue(state.value.items.isEmpty())
        assertEquals(before.selectedMonth, state.value.selectedMonth); assertEquals(before.paginationKey, state.value.paginationKey)
    } }
    @Test fun `人物内容仍有另一人脸时保留照片且新页面不接收迟到回读`() = runBlocking { fixture { f ->
        f.api.faces += f.api.faces.single().copy(id = 72); f.open(); f.model.remove(); f.model.save()!!.join(); f.model.confirm()!!.join(); f.ready()
        val row = f.model.state.value.records.single().checkpoint
        val before = SynologyPhotosState(items = listOf(f.api.photo), navigation = SynologyPhotoNavigation(category = SynologyPhotoCategory.PEOPLE, categoryItem = f.api.people.first()))
        val state = MutableStateFlow(before)
        applyPhotoManualFacesChange(f.api, state, row, {}) { fail("Must retain photo") }; assertEquals(listOf(f.api.photo), state.value.items)
        val other = before.copy(navigation = SynologyPhotoNavigation(space = SynologyPhotoSpace.SHARED))
        applyPhotoManualFacesChange(f.api, state, row, { state.value = other }) { fail("Must ignore previous view") }; assertEquals(other, state.value)
    } }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val fixture = Fixture()
        try { block(fixture) } finally { fixture.model.close(); fixture.scope.coroutineContext[Job]!!.cancelAndJoin() }
    }
    companion object { private suspend fun await(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(5) } } }
}
