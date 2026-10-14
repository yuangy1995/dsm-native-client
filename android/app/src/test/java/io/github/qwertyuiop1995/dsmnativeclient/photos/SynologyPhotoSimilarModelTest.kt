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

class SynologyPhotoSimilarModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "similar-model-${UUID.randomUUID()}"
        override val canEditPhotos = true
        @Volatile var identity = 41L; @Volatile var pending = false; @Volatile var readError = false
        var beforePrepare: suspend () -> Unit = {}; var beforeWrite: suspend () -> Unit = {}
        val writes = CopyOnWriteArrayList<SynologyPhotoAlbumCheckpoint>(); val reviews = CopyOnWriteArrayList<String>()
        val prepared = CopyOnWriteArrayList<SynologyPhotoAlbumCheckpoint>()
        val pageReads = CopyOnWriteArrayList<Pair<SynologyPhotoQuery, Int>>()
        val groups = CopyOnWriteArrayList((1L..3L).map { SynologyPhotoSimilarGroup(profileId, SynologyPhotoSpace.PERSONAL, it,
            (it * 10..it * 10 + 2).toList(), it * 10) })
        override fun canManageSimilar(space: SynologyPhotoSpace) = true
        override suspend fun photoEditIdentity() = identity
        fun photo(id: Long) = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, id), "Synthetic-$id.jpg", 100,
            Instant.parse("2020-03-01T12:00:00Z").epochSecond.toDouble(), 1.0, 9, "photo", similarGroup = groups.firstOrNull { id in it.photoIds })
        fun representative(index: Int = 0) = photo(groups[index].topPickId)
        override suspend fun similarGroupDetails(group: SynologyPhotoSimilarGroup): SynologyPhotoSimilarDetail? {
            if (readError) throw IOException("Synthetic read")
            return groups.singleOrNull { it.id == group.id }?.let { SynologyPhotoSimilarDetail(it, it.photoIds.map(::photo)) }
        }
        override suspend fun similarPhotos(photo: SynologyPhoto) = similarGroupDetails(photo.similarGroup!!)!!
        override suspend fun similarStatus(space: SynologyPhotoSpace) = SynologyPhotoSimilarStatus(1, "running", true)
        override suspend fun prepareSimilarChange(detail: SynologyPhotoSimilarDetail, edit: SynologyPhotoSimilarEdit, selectedIds: List<Long>): SynologyPhotoAlbumCheckpoint {
            beforePrepare()
            return SynologyPhotoAlbumCheckpoint(profileId = profileId, userId = identity, action = SynologyPhotoAlbumAction.EDIT_SIMILAR,
                targets = detail.photos.map(::SynologyPhotoEditTarget), similar = SynologyPhotoSimilarCheckpoint(detail.group, edit, selectedIds))
        }
        override suspend fun prepareSimilarUndo(original: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumCheckpoint {
            beforePrepare(); val value = original.similar!!
            return original.copy(operationId = UUID.randomUUID().toString(), phase = SynologyPhotoAlbumPhase.READY,
                similar = SynologyPhotoSimilarCheckpoint(value.group, SynologyPhotoSimilarEdit.UNDO,
                    undo = SynologyPhotoSimilarUndo(original.operationId, value.edit, value.selectedIds, value.resultingGroup)))
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) { beforePrepare(); prepared += checkpoint }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            var row = checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); save(row)
            row = row.copy(similar = row.similar!!.copy(attempted = true)); save(row); writes += row; beforeWrite()
            return finish(row).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews += checkpoint.operationId; return finish(checkpoint).also(save)
        }
        private fun finish(row: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumCheckpoint {
            if (pending) return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
            val value = row.similar!!; val old = value.group
            val result = when (value.edit) {
                SynologyPhotoSimilarEdit.TOP_PICK -> old.copy(topPickId = value.selectedIds.single())
                SynologyPhotoSimilarEdit.REMOVE -> (old.photoIds - value.selectedIds.toSet()).takeIf { it.size >= 2 }?.let {
                    old.copy(photoIds = it, topPickId = old.topPickId.takeIf(it::contains) ?: it.first()) }
                SynologyPhotoSimilarEdit.UNGROUP -> null
                SynologyPhotoSimilarEdit.UNDO -> old
            }
            groups.removeAll { it.id == old.id }; result?.let { groups += it }
            return row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, similar = value.copy(confirmed = true, resultingGroup = result))
        }
        override suspend fun access() = SynologyPhotoAccess(listOf(SynologyPhotoSpace.PERSONAL), "synthetic", true)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 3))
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            pageReads += query to offset
            val all = groups.sortedBy { it.id }.map { photo(it.topPickId) }; val items = all.drop(offset).take(limit)
            return SynologyPhotoPage(items, offset, offset + items.size, offset + items.size < all.size)
        }
        override suspend fun categories(space: SynologyPhotoSpace) = setOf(SynologyPhotoCategory.SIMILAR)
        override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
    }
    private class Fixture {
        val api = Api(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session"); val store = SynologyPhotoAlbumStore(MemoryPreferences())
        val ticks = Channel<Unit>(Channel.UNLIMITED); val applied = CopyOnWriteArrayList<SynologyPhotoAlbumCheckpoint>()
        val exports = CopyOnWriteArrayList<List<SynologyPhoto>>(); val deletions = CopyOnWriteArrayList<List<SynologyPhoto>>()
        val previews = CopyOnWriteArrayList<SynologyPhoto>(); var current = true; var deleteAllowed = true
        fun model() = SynologyPhotoSimilarModel(api, scope, store, owner, { if (!current) throw CancellationException() }, { true }, {},
            { applied += it }, { previews += it }, { exports += it }, { deleteAllowed }, { deletions += it }, pause = { ticks.receive() })
        val model = model().also { it.activate() }
        suspend fun open() { model.open(api.representative()); await { !model.state.value.loading } }
        fun root(pageSize: Int = 2) = SynologyPhotosModel(api, scope, pageSize = pageSize, zone = ZoneOffset.UTC,
            uploadOwner = owner, albumStore = store, editStore = SynologyPhotoEditStore(MemoryPreferences()))
    }
    @Test fun `完整组可逐项预览且推荐直接一次保存清除选择`() = runBlocking { fixture { f ->
        f.open(); assertEquals(listOf(10L, 11L, 12L), f.model.state.value.detail!!.photos.map { it.id.itemId })
        f.model.preview(12); assertEquals(12L, f.previews.single().id.itemId)
        f.model.toggle(11); f.model.prepare(SynologyPhotoSimilarEdit.TOP_PICK)!!.join()
        assertTrue(f.model.state.value.confirmation.isEmpty()); assertEquals(1, f.api.writes.size)
        assertEquals(11L, f.model.state.value.detail!!.group.topPickId); assertTrue(f.model.state.value.selected.isEmpty())
        f.model.toggle(11); assertNull(f.model.prepare(SynologyPhotoSimilarEdit.TOP_PICK))
    } }
    @Test fun `移出固定选择需要确认且撤销绑定原记录不能重复`() = runBlocking { fixture { f ->
        f.open(); f.model.toggle(12); f.model.prepare(SynologyPhotoSimilarEdit.REMOVE)!!.join()
        assertTrue(f.api.writes.isEmpty()); f.model.toggle(11)
        assertEquals(listOf(12L), f.model.state.value.confirmation.single().similar!!.selectedIds)
        f.model.confirm()!!.join(); assertEquals(listOf(10L, 11L), f.model.state.value.detail!!.group.photoIds)
        val source = f.model.state.value.records.single(); assertTrue(f.model.canUndo(source)); f.model.undo(source.id)!!.join()
        assertEquals(2, f.api.writes.size); assertEquals(source.id, f.api.writes.last().similar!!.undo!!.operationId)
        assertEquals(listOf(10L, 11L, 12L), f.model.state.value.detail!!.group.photoIds)
        assertNull(f.model.undo(source.id)); assertFalse(f.model.canUndo(source))
    } }
    @Test fun `取消确认不持久化也不发送任何更改`() = runBlocking { fixture { f ->
        f.open(); f.model.prepare(SynologyPhotoSimilarEdit.UNGROUP)!!.join(); f.model.cancelConfirmation()
        assertTrue(f.api.writes.isEmpty()); assertTrue(f.store.records(f.owner, 41).isEmpty()); assertNull(f.model.confirm())
    } }
    @Test fun `拆组撤销后当前窗口完整成员恢复`() = runBlocking { fixture { f ->
        f.open(); f.model.prepare(SynologyPhotoSimilarEdit.UNGROUP)!!.join(); f.model.confirm()!!.join()
        assertTrue(f.model.state.value.dissolved); assertNull(f.model.state.value.detail)
        f.model.undo(f.model.state.value.records.single().id)!!.join()
        assertFalse(f.model.state.value.dissolved); assertEquals(3, f.model.state.value.detail!!.photos.size)
    } }
    @Test fun `整组导出跨组去重且没有分类写入`() = runBlocking { fixture { f ->
        val a = f.api.representative(); val b = f.api.representative(1)
        f.model.exportGroups(listOf(a, a, b))!!.join()
        assertEquals(listOf(10L, 11L, 12L, 20L, 21L, 22L), f.exports.single().map { it.id.itemId }); assertTrue(f.api.writes.isEmpty())
        f.open(); f.model.toggle(12); f.model.exportCurrent(); assertEquals(3, f.exports.last().size)
    } }
    @Test fun `保留所选只交付补集给原件删除且权限不满足无入口`() = runBlocking { fixture { f ->
        f.open(); assertFalse(f.model.canCleanUp); f.model.toggle(11); assertTrue(f.model.canCleanUp)
        f.model.cleanUp()!!.join(); assertEquals(listOf(10L, 12L), f.deletions.single().map { it.id.itemId }); assertTrue(f.api.writes.isEmpty())
        f.deleteAllowed = false; assertFalse(f.model.canCleanUp); assertNull(f.model.cleanUp())
    } }
    @Test fun `批次在第一写前全部落盘且未知停止后续冷启动只读恢复`() = runBlocking { fixture { f ->
        f.api.pending = true
        f.api.beforeWrite = { assertEquals(2, f.store.records(f.owner, 41).size) }
        f.model.prepareBatch(listOf(f.api.representative(), f.api.representative(1)))!!.join(); f.model.confirm()!!.join()
        val source = f.store.records(f.owner, 41).single { it.checkpoint.submitted }
        val waiting = f.store.records(f.owner, 41).single { !it.checkpoint.submitted }
        assertEquals(1, f.api.writes.size); assertNull(f.model.continueBatch(waiting.id)); assertFalse(f.model.canUndo(source))
        f.model.close(); val previousReviews = f.api.reviews.size; val restored = f.model().also { it.activate(); it.showRecords(SynologyPhotoSpace.PERSONAL) }
        try {
            await { f.api.reviews.size > previousReviews && !restored.state.value.loading && !restored.state.value.working }; assertEquals(1, f.api.writes.size)
            f.api.pending = false; restored.resume(source.id)!!.join(); assertEquals(1, f.api.writes.size)
            assertNull(restored.state.value.error)
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, f.store.get(source.id, f.owner, 41).checkpoint.phase)
            restored.continueBatch(waiting.id)!!.join(); assertEquals(waiting.id, restored.state.value.confirmation.single().operationId)
            restored.confirm()!!.join(); assertEquals(2, f.api.writes.size); assertEquals(waiting.id, f.api.writes.last().operationId)
        } finally { restored.close() }
    } }
    @Test fun `批次撤销逆序一次执行且来源记录仍保留`() = runBlocking { fixture { f ->
        f.model.prepareBatch(listOf(f.api.representative(), f.api.representative(1)))!!.join(); f.model.confirm()!!.join()
        assertEquals(listOf(1L, 2L), f.api.writes.map { it.similar!!.group.id })
        val original = f.model.state.value.records.first(); f.model.undo(original.id)!!.join()
        assertEquals(listOf(2L, 1L), f.api.writes.drop(2).map { it.similar!!.group.id }); assertEquals(4, f.store.records(f.owner, 41).size)
        assertNull(f.model.undo(original.id))
    } }
    @Test fun `明确取消剩余项不重新发送已提交项`() = runBlocking { fixture { f ->
        f.api.pending = true; f.model.prepareBatch(listOf(f.api.representative(), f.api.representative(1)))!!.join(); f.model.confirm()!!.join()
        val waiting = f.model.state.value.records.single { !it.checkpoint.submitted }; f.model.cancelRemaining(waiting.id)!!.join()
        assertEquals(1, f.api.writes.size); assertEquals(1, f.store.records(f.owner, 41).size); assertTrue(f.model.state.value.pending)
    } }
    @Test fun `读取失败不当解散且刷新能恢复`() = runBlocking { fixture { f ->
        f.api.readError = true; f.open(); assertNotNull(f.model.state.value.error); assertFalse(f.model.state.value.dissolved)
        f.api.readError = false; f.model.load()!!.join(); assertNotNull(f.model.state.value.detail); assertNull(f.model.state.value.error)
    } }
    @Test fun `后台期间预检返回不重新弹确认或发送`() = runBlocking { fixture { f ->
        f.open(); val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforePrepare = { started.complete(Unit); withContext(NonCancellable) { release.await() } }
        val job = f.model.prepare(SynologyPhotoSimilarEdit.UNGROUP)!!; started.await(); f.model.deactivate(); release.complete(Unit); job.join()
        assertTrue(f.model.state.value.confirmation.isEmpty()); assertTrue(f.api.writes.isEmpty()); assertTrue(f.store.records(f.owner, 41).isEmpty())
    } }
    @Test fun `撤销身份变化不能发送且离开页面停止识别轮询`() = runBlocking { fixture { f ->
        f.open(); f.current = false; f.model.prepare(SynologyPhotoSimilarEdit.UNGROUP)!!.join()
        assertTrue(f.api.writes.isEmpty()); f.current = true; f.model.browsing(SynologyPhotoSpace.PERSONAL)
        await { f.model.state.value.status != null }; f.model.browsing(null); assertNull(f.model.state.value.status)
    } }
    @Test fun `根模型推荐替换不改变月份分页仍按组数量前进`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            openCategory(root); val month = root.state.value.selectedMonth; val similar = root.similar!!
            similar.open(root.state.value.items.first()); await { !similar.state.value.loading }
            similar.toggle(11); similar.prepare(SynologyPhotoSimilarEdit.TOP_PICK)!!.join()
            assertNull(similar.state.value.error); assertEquals(listOf(11L, 20L), root.state.value.items.map { it.id.itemId })
            assertEquals(month, root.state.value.selectedMonth); similar.dismiss(); root.loadMore()!!.join()
            assertEquals(2, f.api.pageReads.last().second); assertEquals(listOf(11L, 20L, 30L), root.state.value.items.map { it.id.itemId })
        } finally { root.close() }
    } }
    @Test fun `根模型拆组只扣当前组且当前月份撤销恢复位置和分页`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            openCategory(root); val similar = root.similar!!; similar.open(root.state.value.items.first()); await { !similar.state.value.loading }
            similar.prepare(SynologyPhotoSimilarEdit.UNGROUP)!!.join(); similar.confirm()!!.join()
            assertEquals(listOf(20L), root.state.value.items.map { it.id.itemId }); val row = similar.state.value.records.single()
            similar.undo(row.id)!!.join(); assertEquals(listOf(10L, 20L), root.state.value.items.map { it.id.itemId })
            similar.dismiss(); root.loadMore()!!.join(); assertEquals(2, f.api.pageReads.last().second)
        } finally { root.close() }
    } }
    @Test fun `列表结果应用只替换当前来源已有组不影响普通时间线`() {
        val api = Api(); val group = api.groups.first(); val original = api.representative()
        val detail = SynologyPhotoSimilarDetail(group.copy(topPickId = 11), group.photoIds.map(api::photo))
        val state = SynologyPhotosState(navigation = SynologyPhotoNavigation(category = SynologyPhotoCategory.SIMILAR), items = listOf(original, api.representative(1)))
        assertEquals(listOf(11L, 20L), applyPhotoSimilarGroup(state, group, detail)!!.items.map { it.id.itemId })
        assertNull(applyPhotoSimilarGroup(state.copy(navigation = SynologyPhotoNavigation()), group, detail))
        assertNull(applyPhotoSimilarGroup(state.copy(items = emptyList()), group, detail))
        assertNull(applyPhotoSimilarGroup(state.copy(navigation = state.navigation.copy(space = SynologyPhotoSpace.SHARED)), group, detail))
    }
    @Test fun `撤销离开原查询不插入卡片且连续原件删除刷新最终组状态`() = runBlocking {
        val api = Api(); val group = api.groups.first(); val original = api.representative()
        val state = kotlinx.coroutines.flow.MutableStateFlow(SynologyPhotosState(
            navigation = SynologyPhotoNavigation(category = SynologyPhotoCategory.SIMILAR), items = listOf(original, api.representative(1))))
        var query: SynologyPhotoQuery = SynologyPhotoQuery.Similar(1, 100); var offset = 2
        val paged = state.value.items.mapTo(mutableSetOf()) { it.id }
        val application = SynologyPhotoSimilarApplication(api, state, { query }, paged, { offset }, { offset = it }, { 1 }, {}, {},
            { state.value = state.value.copy(items = it) }, {})
        val row = SynologyPhotoAlbumCheckpoint(profileId = api.profileId, userId = 41, action = SynologyPhotoAlbumAction.EDIT_SIMILAR,
            similar = SynologyPhotoSimilarCheckpoint(group, SynologyPhotoSimilarEdit.UNGROUP, confirmed = true))
        api.groups.remove(group); application.apply(row); assertEquals(1, offset)
        query = SynologyPhotoQuery.Similar(101, 200); api.groups += group
        application.apply(row.copy(similar = SynologyPhotoSimilarCheckpoint(group, SynologyPhotoSimilarEdit.UNDO,
            undo = SynologyPhotoSimilarUndo(row.operationId, SynologyPhotoSimilarEdit.UNGROUP, emptyList(), null))))
        assertEquals(listOf(20L), state.value.items.map { it.id.itemId }); assertEquals(1, offset)
        state.value = state.value.copy(items = listOf(original)); paged.clear(); paged += original.id; offset = 1
        api.groups.remove(group); api.groups += group.copy(photoIds = listOf(11, 12), topPickId = 11)
        application.originalDeleted(group); assertEquals(listOf(11L), state.value.items.map { it.id.itemId }); assertEquals(1, offset)
        api.groups.removeAll { it.id == group.id }; application.originalDeleted(group)
        assertTrue(state.value.items.isEmpty()); assertEquals(0, offset); assertTrue(paged.isEmpty())
    }
    private suspend fun openCategory(root: SynologyPhotosModel) {
        root.activate(); await { root.state.value.loaded && !root.state.value.loading }
        root.selectSection(SynologyPhotosSection.ALBUMS); await { !root.state.value.loading && root.state.value.categories.isNotEmpty() }
        root.openCategory(SynologyPhotoCategory.SIMILAR); await { !root.state.value.loading && root.state.value.items.size == 2 }
    }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.cancel() }
    }
    private companion object { suspend fun await(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(5) } } }
}
