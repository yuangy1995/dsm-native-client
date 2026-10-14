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
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoConceptModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "concept-model-${UUID.randomUUID()}"
        override val canEditPhotos = true; override val canManageAlbums = true
        @Volatile var enabled = true; @Volatile var identity = 41L; @Volatile var pending = false; @Volatile var rejected = false
        @Volatile var partial = false; @Volatile var readError = false; @Volatile var prepareError = false
        var beforeRead: suspend () -> Unit = {}; var beforeWrite: suspend () -> Unit = {}; var beforePrepare: suspend () -> Unit = {}
        val writes = CopyOnWriteArrayList<SynologyPhotoAlbumCheckpoint>(); val reviews = CopyOnWriteArrayList<String>()
        val pageReads = CopyOnWriteArrayList<Pair<SynologyPhotoQuery, Int>>()
        val concepts = CopyOnWriteArrayList((1L..3L).map { SynologyPhotoCollection(it, "Synthetic $it", count = 3,
            conceptVisible = it != 3L, conceptDisplayThreshold = 2, thumbnail = SynologyPhotoThumbnail(88, "original")) })
        val removed = mutableSetOf<Long>()
        override fun canManageConcepts(space: SynologyPhotoSpace, editingPhotos: Boolean) = enabled
        override suspend fun photoEditIdentity() = identity
        override suspend fun conceptThumbnail(concept: SynologyPhotoCollection) = byteArrayOf(1, 2, 3)
        override suspend fun managementConcepts(space: SynologyPhotoSpace): List<SynologyPhotoCollection> {
            beforeRead(); if (readError) throw IOException("Synthetic read")
            return concepts.map { it.copy(space = space) }
        }
        override suspend fun concept(id: Long, space: SynologyPhotoSpace) = managementConcepts(space).single { it.id == id }
        override suspend fun prepareConceptChange(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoConceptSnapshot>,
            photos: List<SynologyPhoto>, visible: Boolean?): SynologyPhotoAlbumCheckpoint {
            beforePrepare(); if (prepareError) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
            return SynologyPhotoAlbumCheckpoint(profileId = profileId, userId = identity, action = action, targets = photos.map(::SynologyPhotoEditTarget),
                concept = SynologyPhotoConceptCheckpoint(originals, visible))
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) {
            if (prepareError) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
        }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            var row = checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); save(row)
            row = row.copy(concept = row.concept!!.copy(attempted = true)); save(row); writes += row; beforeWrite()
            row = row.copy(concept = row.concept!!.copy(acknowledged = !rejected, rejected = rejected))
            return finish(row).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews += checkpoint.operationId; return finish(checkpoint).also(save)
        }
        private fun finish(row: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumCheckpoint {
            val value = row.concept!!
            if (value.rejected || !value.attempted) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
            if (pending) return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
            val removeIds = if (row.action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) row.targets.map { it.id.itemId }.let { if (partial) it.take(1) else it }.toSet() else emptySet()
            val ids = if (partial && row.action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) emptySet() else value.originals.map { it.id }.let { if (partial) it.take(1) else it }.toSet()
            val updated = value.originals.filter { it.id in ids || removeIds.isNotEmpty() }.map { when (row.action) {
                SynologyPhotoAlbumAction.SHOW_CONCEPTS -> it.copy(visible = value.visible)
                SynologyPhotoAlbumAction.COVER_CONCEPT -> it.copy(coverUnitId = row.targets.single().id.itemId, coverRevision = "new")
                else -> it.copy(count = it.count!! - removeIds.size)
            } }
            val result = row.copy(phase = if (partial) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.COMPLETED,
                concept = value.copy(completedIds = ids, removedPhotoIds = removeIds, updated = updated))
            removed += removeIds
            val values = applyPhotoConceptResult(concepts.map { it.copy(space = value.space) }, result)
            concepts.clear(); concepts.addAll(values.map { it.copy(space = SynologyPhotoSpace.PERSONAL) })
            return result
        }
        fun photo(id: Long = 51, space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL) = SynologyPhoto(SynologyPhotoId(profileId, space, id), "Synthetic-$id.jpg", 100,
            Instant.parse("2020-03-01T12:00:00Z").epochSecond.toDouble(), 1.0, 9, "photo")
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 3))
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            pageReads += query to offset
            val all = (51L..53L).filter { query !is SynologyPhotoQuery.Category || it !in removed }
            val items = all.drop(offset).take(limit).map { photo(it, space) }
            return SynologyPhotoPage(items, offset, offset + items.size, offset + items.size < all.size)
        }
        override suspend fun categories(space: SynologyPhotoSpace) = setOf(SynologyPhotoCategory.SUBJECTS)
        override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
        override suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int, space: SynologyPhotoSpace) =
            managementConcepts(space).filter { SynologyPhotoConceptSnapshot(it).appearsInList }.drop(offset).take(limit)
    }
    private class Fixture {
        val api = Api(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session"); val store = SynologyPhotoAlbumStore(MemoryPreferences())
        val thumbnails = SynologyPhotoThumbnailStore(scope); val ticks = Channel<Unit>(Channel.UNLIMITED); val pauses = CopyOnWriteArrayList<Long>()
        val applied = CopyOnWriteArrayList<SynologyPhotoAlbumCheckpoint>()
        var current = true; var canStart = true; var before: suspend () -> Unit = {}
        fun model() = SynologyPhotoConceptModel(api, scope, store, owner, { if (!current) throw CancellationException() }, thumbnails,
            { canStart }, { before() }, { row, _ -> applied += row }, pause = { pauses += it; ticks.receive() })
        val model = model()
        suspend fun open() { model.open(SynologyPhotoSpace.PERSONAL); await { !model.state.value.loading } }
        suspend fun openPhotos(action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS, photos: List<SynologyPhoto> = listOf(api.photo(51), api.photo(52))) {
            model.openPhotos(action, api.concepts.first(), photos); await { !model.state.value.loading }
        }
        fun root(pageSize: Int = 100) = SynologyPhotosModel(api, scope, pageSize = pageSize, zone = ZoneOffset.UTC, uploadOwner = owner, albumStore = store,
            editStore = SynologyPhotoEditStore(MemoryPreferences()))
    }
    @Test fun `显示隐藏搜索含隐藏项只保存发生变化的选择无额外确认`() = runBlocking { fixture { f ->
        f.open(); assertEquals(3, f.model.state.value.concepts.size)
        f.model.search("  3 "); assertEquals(listOf(3L), f.model.state.value.filtered.map { it.id })
        f.model.toggle(3); assertFalse(f.model.state.value.canSave)
        f.model.visibility(true); f.model.toggle(3); f.model.save()!!.join()
        assertNull(f.model.state.value.confirmation); assertEquals(listOf(3L), f.api.writes.single().concept!!.originals.map { it.id })
        assertTrue(f.api.writes.single().concept!!.visible!!); assertTrue(f.model.state.value.selected.isEmpty()); assertFalse(f.model.state.value.canSave)
        assertEquals(1, f.applied.size)
    } }
    @Test fun `封面直接保存后当前实际封面禁用重复保存`() = runBlocking { fixture { f ->
        f.openPhotos(SynologyPhotoAlbumAction.COVER_CONCEPT, listOf(f.api.photo()))
        f.model.save()!!.join(); assertNull(f.model.state.value.confirmation)
        assertEquals(51L, f.model.state.value.target!!.thumbnail!!.unitId); assertFalse(f.model.state.value.canSave)
        assertNull(f.model.save()); assertEquals(1, f.api.writes.size)
    } }
    @Test fun `移出固定照片与实际阈值需要确认取消零写且完成后不可重复`() = runBlocking { fixture { f ->
        f.openPhotos(); f.model.save()!!.join(); val checkpoint = f.model.state.value.confirmation!!
        assertEquals(3, checkpoint.concept!!.originals.single().count); assertEquals(2, checkpoint.concept.originals.single().displayThreshold)
        assertEquals(listOf(51L, 52L), checkpoint.targets.map { it.id.itemId }); assertTrue(f.api.writes.isEmpty())
        f.model.cancelConfirmation(); assertTrue(f.api.writes.isEmpty()); f.model.save()!!.join(); f.model.confirm()!!.join()
        assertEquals(1, f.api.writes.size); assertTrue(f.model.state.value.photos.isEmpty()); assertFalse(f.model.state.value.canSave)
        assertEquals(1, f.model.state.value.target!!.count)
    } }
    @Test fun `确认时重新预检变更失败不创建写入记录`() = runBlocking { fixture { f ->
        f.openPhotos(); f.model.save()!!.join(); f.api.prepareError = true; f.model.confirm()!!.join()
        assertNotNull(f.model.state.value.error); assertTrue(f.api.writes.isEmpty()); assertTrue(f.store.records(f.owner, 41).isEmpty())
    } }
    @Test fun `读取空错误刷新恢复和筛选无结果分别保留真实状态`() = runBlocking { fixture { f ->
        f.api.readError = true; f.open(); assertFalse(f.model.state.value.loaded); assertNotNull(f.model.state.value.error)
        f.api.readError = false; f.model.load()!!.join(); assertTrue(f.model.state.value.loaded)
        f.model.search("No match"); assertTrue(f.model.state.value.filtered.isEmpty()); assertEquals(3, f.model.state.value.concepts.size)
        f.api.concepts.clear(); f.model.load()!!.join(); assertTrue(f.model.state.value.loaded); assertTrue(f.model.state.value.concepts.isEmpty()); assertNull(f.model.state.value.error)
    } }
    @Test fun `无计数或阈值不允许移出封面不要求阈值`() = runBlocking { fixture { f ->
        f.api.concepts[0] = f.api.concepts[0].copy(conceptDisplayThreshold = null)
        f.openPhotos(); assertFalse(f.model.state.value.canSave); assertNull(f.model.save())
        f.model.dismiss(); f.openPhotos(SynologyPhotoAlbumAction.COVER_CONCEPT, listOf(f.api.photo())); assertTrue(f.model.state.value.canSave)
    } }
    @Test fun `来源权限相册混入空选择和多图封面入口均拒绝`() = runBlocking { fixture { f ->
        f.api.enabled = false; f.open(); assertFalse(f.model.state.value.visible)
        f.api.enabled = true
        for (photos in listOf(emptyList(), listOf(f.api.photo().copy(albumContext = SynologyPhotoAlbumContext(9, 41))),
            listOf(f.api.photo(space = SynologyPhotoSpace.SHARED)), listOf(f.api.photo(), f.api.photo()))) {
            f.model.openPhotos(SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS, f.api.concepts.first(), photos); assertFalse(f.model.state.value.visible)
        }
        f.model.openPhotos(SynologyPhotoAlbumAction.COVER_CONCEPT, f.api.concepts.first(), listOf(f.api.photo(51), f.api.photo(52)))
        assertFalse(f.model.state.value.visible); assertTrue(f.api.writes.isEmpty())
    } }
    @Test fun `选择上限100且切换显示目标清空选择保留搜索`() = runBlocking { fixture { f ->
        f.api.concepts.clear(); (1L..102L).forEach { f.api.concepts += SynologyPhotoCollection(it, "Synthetic $it", conceptVisible = true) }
        f.open(); (1L..102L).forEach(f.model::toggle); assertEquals(100, f.model.state.value.selected.size)
        f.model.search("Synthetic"); f.model.visibility(true); assertTrue(f.model.state.value.selected.isEmpty()); assertEquals("Synthetic", f.model.state.value.query)
    } }
    @Test fun `提交中重复点击返回空关闭窗口仍保留真实结果`() = runBlocking { fixture { f ->
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { entered.complete(Unit); release.await() }
        f.open(); f.model.toggle(1); val work = f.model.save()!!; entered.await()
        assertNull(f.model.save()); f.model.dismiss(); assertFalse(f.model.state.value.visible)
        release.complete(Unit); work.join(); assertEquals(1, f.api.writes.size); assertEquals(1, f.applied.size)
        assertTrue(f.store.records(f.owner, 41).single().checkpoint.finished)
    } }
    @Test fun `待决记录阻止同主题再次提交且冷恢复只读原编号`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(); f.model.toggle(1); f.model.save()!!.join(); val row = f.model.state.value.records.single()
        assertTrue(f.model.state.value.blockedByPending); assertNull(f.model.save()); assertNull(f.model.discard(row.id))
        f.model.dismiss(); val cold = f.model(); cold.open(SynologyPhotoSpace.PERSONAL); await { !cold.state.value.loading }
        f.api.pending = false; cold.resume(row.id)!!.join(); assertEquals(listOf(row.id), f.api.reviews.toList()); assertEquals(1, f.api.writes.size)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, cold.state.value.records.single().checkpoint.phase); cold.close()
    } }
    @Test fun `可见未决自动回读关闭和停用均停止轮询`() = runBlocking { fixture { f ->
        f.model.activate(); f.api.pending = true; f.open(); f.model.toggle(1); f.model.save()!!.join(); await { f.pauses.isNotEmpty() }
        f.ticks.send(Unit); await { f.api.reviews.size == 1 }; await { f.pauses.size >= 2 }
        f.model.deactivate(); f.ticks.send(Unit); delay(30); assertEquals(1, f.api.reviews.size)
        assertTrue(f.pauses.all { it == 15_000L }); assertEquals(1, f.api.writes.size)
    } }
    @Test fun `旧读取退出或新窗口后不得覆盖当前来源`() = runBlocking { fixture { f ->
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeRead = { entered.complete(Unit); withContext(NonCancellable) { release.await() } }
        f.model.open(SynologyPhotoSpace.PERSONAL); entered.await(); f.model.dismiss()
        f.api.beforeRead = {}; f.model.open(SynologyPhotoSpace.SHARED); await { !f.model.state.value.loading }
        release.complete(Unit); delay(30); assertEquals(SynologyPhotoSpace.SHARED, f.model.state.value.space)
        assertTrue(f.model.state.value.concepts.all { it.space == SynologyPhotoSpace.SHARED })
    } }
    @Test fun `部分结果只移除已完成照片并保留余项可再次明确操作`() = runBlocking { fixture { f ->
        f.api.partial = true; f.openPhotos(); f.model.save()!!.join(); f.model.confirm()!!.join()
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, f.model.state.value.records.single().checkpoint.phase)
        assertEquals(listOf(52L), f.model.state.value.photos.map { it.id.itemId }); assertEquals(2, f.model.state.value.target!!.count)
        assertTrue(f.model.state.value.canSave); assertEquals(setOf(51L), f.applied.single().concept!!.removedPhotoIds)
    } }
    @Test fun `同一存储其他功能忙和未决原件阻止真实写入`() = runBlocking { fixture { f ->
        f.before = { throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING) }
        f.open(); f.model.toggle(1); f.model.save()!!.join(); assertTrue(f.api.writes.isEmpty()); assertNotNull(f.model.state.value.error)
        f.before = {}; f.canStart = false; assertNull(f.model.save()); assertTrue(f.store.records(f.owner, 41).isEmpty())
    } }
    @Test fun `已确认主题结果更新完整列表并保留月份与其他来源`() {
        val api = Api(); val month = YearMonth.of(2020, 3); val target = api.concepts.first()
        val updated = SynologyPhotoConceptSnapshot(target).copy(visible = false)
        val row = SynologyPhotoAlbumCheckpoint(profileId = api.profileId, userId = 41, action = SynologyPhotoAlbumAction.SHOW_CONCEPTS,
            phase = SynologyPhotoAlbumPhase.COMPLETED, concept = SynologyPhotoConceptCheckpoint(listOf(SynologyPhotoConceptSnapshot(target)), false,
                attempted = true, completedIds = setOf(1), updated = listOf(updated)))
        val state = MutableStateFlow(SynologyPhotosState(navigation = SynologyPhotoNavigation(category = SynologyPhotoCategory.SUBJECTS),
            collections = listOf(target), hasMoreCollections = true, months = listOf(month), selectedMonth = month))
        val latest = applyPhotoConceptResult(api.concepts, row); assertEquals(1, applyPhotoConceptChange(state, row, latest) {})
        assertEquals(listOf(2L), state.value.collections.map { it.id }); assertFalse(state.value.hasMoreCollections); assertEquals(month, state.value.selectedMonth)
        val shared = state.value.copy(navigation = SynologyPhotoNavigation(space = SynologyPhotoSpace.SHARED, category = SynologyPhotoCategory.SUBJECTS))
        state.value = shared; applyPhotoConceptChange(state, row, latest) {}; assertEquals(shared, state.value)
    }
    @Test fun `根模型移出保留当前月份剩余照片关闭命中预览并修正下一页游标`() = runBlocking { fixture { f ->
        val root = f.root(2); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }
            root.selectSection(SynologyPhotosSection.ALBUMS); await { !root.state.value.loading && root.state.value.categories.isNotEmpty() }
            root.openCategory(SynologyPhotoCategory.SUBJECTS); await { !root.state.value.loading && root.state.value.collections.isNotEmpty() }
            root.openCollection(root.state.value.collections.first()); await { !root.state.value.loading && root.state.value.items.size == 2 }
            val month = root.state.value.selectedMonth; val photos = root.state.value.items; root.edits!!.selectMode(true); root.edits.toggle(photos.first())
            root.preview.open(photos.first()); await { !root.preview.state.value.loading }
            val concepts = root.concepts!!; concepts.openPhotos(SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS, root.state.value.navigation.categoryItem!!, listOf(photos.first()))
            await { !concepts.state.value.loading }; concepts.save()!!.join(); concepts.confirm()!!.join()
            assertEquals(month, root.state.value.selectedMonth); assertEquals(listOf(52L), root.state.value.items.map { it.id.itemId })
            assertNull(root.preview.state.value.photo); assertTrue(root.edits.state.value.selected.isEmpty()); assertEquals(2, root.state.value.navigation.categoryItem!!.count)
            root.loadMore()!!.join(); assertEquals(listOf(52L, 53L), root.state.value.items.map { it.id.itemId }); assertEquals(1, f.api.pageReads.last().second)
        } finally { root.close() }
    } }
    @Test fun `根模型移出后保留未命中预览且不会误删普通时间线原件`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }
            root.selectSection(SynologyPhotosSection.ALBUMS); await { !root.state.value.loading && root.state.value.categories.isNotEmpty() }
            root.openCategory(SynologyPhotoCategory.SUBJECTS); await { !root.state.value.loading && root.state.value.collections.isNotEmpty() }
            root.openCollection(root.state.value.collections.first()); await { !root.state.value.loading && root.state.value.items.size == 3 }
            root.preview.open(root.state.value.items.last()); await { !root.preview.state.value.loading }
            val concepts = root.concepts!!; concepts.openPhotos(SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS, root.state.value.navigation.categoryItem!!, listOf(root.state.value.items.first()))
            await { !concepts.state.value.loading }; concepts.save()!!.join(); concepts.confirm()!!.join()
            assertEquals(53L, root.preview.state.value.photo!!.id.itemId)
            concepts.dismiss(); root.selectSection(SynologyPhotosSection.TIMELINE); await { !root.state.value.loading && root.state.value.navigation.category == null }
            assertEquals(listOf(51L, 52L, 53L), root.state.value.items.map { it.id.itemId })
        } finally { root.close() }
    } }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val f = Fixture(); try { block(f) } finally { f.model.close(); f.thumbnails.close(); f.scope.cancel() }
    }
    private companion object {
        suspend fun await(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(5) } }
    }
}
