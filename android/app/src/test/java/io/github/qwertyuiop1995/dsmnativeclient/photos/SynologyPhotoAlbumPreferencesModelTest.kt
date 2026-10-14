package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture.Companion.albumTarget
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture.Companion.displayTarget
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture.Companion.sortTarget
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture.Companion.obj
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 正式组合仓储与图库模型一起验证分页、导航、选择和持久恢复。 */
class SynologyPhotoAlbumPreferencesModelTest {
    private class Fixture {
        val nas = SynologyPhotoPreferenceFixture(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner("preference", "identity", "session"); val preferences = MemoryPreferences()
        val store = SynologyPhotoAlbumStore(preferences); val edits = SynologyPhotoEditStore(MemoryPreferences())
        fun root() = SynologyPhotosModel(nas.repository(), scope, pageSize = 2, uploadOwner = owner, albumStore = store, editStore = edits)
        val root = root(); val settings get() = root.settings!!
        suspend fun ready() { await { root.state.value.loaded && !root.state.value.loading }; assertNull(root.state.value.error) }
        suspend fun albums() { root.selectSection(SynologyPhotosSection.ALBUMS); ready() }
        suspend fun album() { albums(); root.openCollection(root.state.value.collections.first()); ready() }
        suspend fun open(target: SynologyPhotoSettingsTarget) { settings.open(target); await { !settings.state.value.loading }; assertNotNull(settings.state.value.desired); assertNull(settings.state.value.error) }
        suspend fun close() { root.close(); scope.coroutineContext[Job]!!.cancelAndJoin() }
    }
    @Test fun `相册列表首读偏好翻页固定参数且重开重新读取`() = runBlocking { fixture { f ->
        f.albums(); assertEquals(SynologyPhotoAlbumDisplay.ALL, f.root.state.value.albumDisplay)
        val saved = f.root.state.value.albumListSort; val reads = f.nas.calls.count { it.method == "get_album_list_order" }
        f.nas.order = JsonObject(f.nas.order + mapOf("album_list_sort_by" to JsonPrimitive("create_time"), "album_list_sort_direction" to JsonPrimitive("desc")))
        f.nas.display = obj("""{"album_display_type":"my_album"}""")
        f.root.loadMore()!!.join(); assertEquals(saved, f.root.state.value.albumListSort); assertEquals(reads, f.nas.calls.count { it.method == "get_album_list_order" })
        assertEquals(3, f.root.state.value.collections.size)
        f.nas.calls.filter { it.api.endsWith("Browse.Album") && it.method == "list" }.forEach { assertEquals("\"album_name\"", it.fields["sort_by"]); assertEquals("\"normal_share_with_me\"", it.fields["category"]) }
        f.root.refresh()!!.join(); assertEquals(SynologyPhotoAlbumDisplay.MINE, f.root.state.value.albumDisplay)
        assertEquals(SynologyPhotoAlbumListSort.Field.CREATED_TIME, f.root.state.value.albumListSort!!.field)
    } }
    @Test fun `相册排序保存重载同相册保留选择且后续页不被本地日期重排`() = runBlocking { fixture { f ->
        f.album(); assertEquals(listOf(1L, 2L), f.root.state.value.items.map { it.id.itemId }); assertEquals(SynologyPhotoSort(), f.root.state.value.albumSort)
        val navigation = f.root.state.value.navigation; val photo = f.root.state.value.items.first(); f.root.edits!!.selectMode(true); f.root.edits.toggle(photo)
        f.open(albumTarget); val value = f.settings.state.value.desired as SynologyPhotoAlbumSortSettings
        f.settings.edit(value.copy(sort = SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME, SynologyPhotoSort.Direction.DESCENDING)))
        f.settings.save()!!.join(); f.ready(); assertNull(f.settings.state.value.confirmation)
        assertEquals(navigation, f.root.state.value.navigation); assertEquals(listOf(photo), f.root.edits.state.value.selected)
        assertEquals(listOf(3L, 2L), f.root.state.value.items.map { it.id.itemId }); f.root.loadMore()!!.join()
        assertEquals(listOf(3L, 2L, 1L), f.root.state.value.items.map { it.id.itemId }); assertEquals(1, f.nas.writes.size)
        f.open(albumTarget); assertFalse(f.settings.canSave); assertEquals(SynologyPhotoSort.Field.FILENAME, (f.settings.state.value.original as SynologyPhotoAlbumSortSettings).sort.field)
    } }
    @Test fun `全部切我的独立保存重载相册列表并保持已读排序`() = runBlocking { fixture { f ->
        f.albums(); val navigation = f.root.state.value.navigation; val sort = f.root.state.value.albumListSort
        f.open(displayTarget); f.settings.edit(SynologyPhotoAlbumDisplaySettings(SynologyPhotoAlbumDisplay.MINE)); f.settings.save()!!.join(); f.ready()
        assertNull(f.settings.state.value.confirmation); assertEquals(navigation, f.root.state.value.navigation)
        assertEquals(sort, f.root.state.value.albumListSort); assertEquals(listOf(7L, 9L), f.root.state.value.collections.map { it.id })
        f.root.loadMore()!!.join(); assertFalse(f.root.state.value.hasMoreCollections)
        assertEquals(mapOf("album_display_type" to "\"my_album\""), f.nas.writes.single().fields)
    } }
    @Test fun `两个分享范围分别读取保存互不影响照片收集不读取偏好`() = runBlocking { fixture { f ->
        f.root.selectSection(SynologyPhotosSection.SHARING); f.ready(); assertEquals(SynologyPhotoAlbumListSort.Field.START_TIME, f.root.state.value.albumListSort!!.field)
        f.open(sortTarget(SynologyPhotoAlbumListScope.WITH_ME)); val value = f.settings.state.value.desired as SynologyPhotoAlbumListSortSettings
        f.settings.edit(value.copy(sort = value.sort.copy(field = SynologyPhotoAlbumListSort.Field.NAME))); f.settings.save()!!.join(); f.ready()
        assertEquals(SynologyPhotoShareScope.WITH_ME, f.root.state.value.navigation.shareScope)
        f.settings.dismiss(); f.root.selectShareScope(SynologyPhotoShareScope.WITH_OTHERS); f.ready()
        assertEquals(SynologyPhotoAlbumListSort.Field.SHARED_TIME, f.root.state.value.albumListSort!!.field)
        f.root.loadMore()!!.join(); assertEquals(3, f.root.state.value.sharing.size)
        val reads = f.nas.calls.count { it.method.startsWith("get_album_list") }
        f.root.selectShareScope(SynologyPhotoShareScope.REQUESTS); f.ready()
        assertEquals(reads, f.nas.calls.count { it.method.startsWith("get_album_list") }); assertNull(f.root.state.value.albumListSort); assertNull(f.root.state.value.albumDisplay)
        assertEquals(1, f.nas.writes.size)
    } }
    @Test fun `单项偏好读取失败不阻断图库另一项成功保留且重试可恢复`() = runBlocking { fixture { f ->
        f.nas.failMethods = setOf("get_album_list_order"); f.albums()
        assertEquals(setOf(SynologyPhotoSettingsKind.LIST_SORT), f.root.state.value.preferenceErrors.keys)
        assertNull(f.root.state.value.albumListSort); assertEquals(SynologyPhotoAlbumDisplay.ALL, f.root.state.value.albumDisplay); assertEquals(2, f.root.state.value.collections.size)
        f.settings.open(sortTarget(SynologyPhotoAlbumListScope.ALBUMS)); await { !f.settings.state.value.loading }; assertNull(f.settings.state.value.desired); assertNotNull(f.settings.state.value.error)
        f.nas.failMethods = emptySet(); f.settings.load()!!.join(); assertNotNull(f.settings.state.value.desired); f.settings.dismiss(); f.root.refresh()!!.join()
        assertTrue(f.root.state.value.preferenceErrors.isEmpty()); assertTrue(f.nas.writes.isEmpty())
    } }
    @Test fun `相册排序读取失败保持原降序浏览并可恢复不要求个人来源`() = runBlocking { fixture { f ->
        f.nas.home = false; f.nas.shared = false; f.nas.field("sort_by", JsonPrimitive("unknown")); f.album()
        assertTrue(f.root.state.value.access!!.spaces.isEmpty()); assertNull(f.root.state.value.albumSort)
        assertEquals(listOf(3L, 2L), f.root.state.value.items.map { it.id.itemId }); assertEquals(setOf(SynologyPhotoSettingsKind.ALBUM_SORT), f.root.state.value.preferenceErrors.keys)
        f.nas.field("sort_by", JsonPrimitive("filename")); f.root.refresh()!!.join()
        assertTrue(f.root.state.value.preferenceErrors.isEmpty()); assertEquals(listOf(1L, 2L), f.root.state.value.items.map { it.id.itemId })
    } }
    @Test fun `非当前范围保存不跳转或刷新无关图库`() = runBlocking { fixture { f ->
        f.albums(); f.open(sortTarget(SynologyPhotoAlbumListScope.ALBUMS)); val value = f.settings.state.value.desired as SynologyPhotoAlbumListSortSettings
        f.settings.edit(value.copy(sort = value.sort.copy(field = SynologyPhotoAlbumListSort.Field.TYPE)))
        f.root.selectSection(SynologyPhotosSection.TIMELINE); f.ready(); val reads = f.nas.calls.count { it.api.endsWith("UserInfo") }
        f.settings.save()!!.join(); assertEquals(reads, f.nas.calls.count { it.api.endsWith("UserInfo") }); assertEquals(SynologyPhotosSection.TIMELINE, f.root.state.value.navigation.section)
        assertTrue(f.settings.state.value.records.single().checkpoint.finished)
    } }
    @Test fun `旧偏好分页迟到不会混入保存后新一页`() = runBlocking { fixture { f ->
        f.albums(); val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.nas.before = { if (it.api.endsWith("Browse.Album") && it.method == "list" && it.fields["offset"] == "2") {
            reached.complete(Unit); withContext(NonCancellable) { release.await() }
        } }
        val paging = f.root.loadMore()!!; reached.await(); f.open(displayTarget)
        f.settings.edit(SynologyPhotoAlbumDisplaySettings(SynologyPhotoAlbumDisplay.MINE)); f.settings.save()!!.join(); f.ready()
        release.complete(Unit); paging.join(); assertEquals(listOf(7L, 9L), f.root.state.value.collections.map { it.id }); assertEquals(SynologyPhotoAlbumDisplay.MINE, f.root.state.value.albumDisplay)
        assertNull(f.root.state.value.error)
    } }
    @Test fun `草稿固定目标跨相册与跨范围修改无效且无变化不能保存`() = runBlocking { fixture { f ->
        f.albums(); f.open(sortTarget(SynologyPhotoAlbumListScope.ALBUMS)); val before = f.settings.state.value.desired as SynologyPhotoAlbumListSortSettings
        f.settings.edit(before.copy(scope = SynologyPhotoAlbumListScope.WITH_ME)); assertEquals(before, f.settings.state.value.desired)
        assertFalse(f.settings.canSave); assertNull(f.settings.save())
        f.open(albumTarget); val album = f.settings.state.value.desired as SynologyPhotoAlbumSortSettings; f.settings.edit(album.copy(albumId = 8)); assertEquals(album, f.settings.state.value.desired)
        assertTrue(f.nas.writes.isEmpty())
    } }
    @Test fun `未知保存冷恢复阻止重发完成仅刷新相应范围`() = runBlocking { fixture { f ->
        f.albums(); f.open(displayTarget); f.settings.edit(SynologyPhotoAlbumDisplaySettings(SynologyPhotoAlbumDisplay.MINE))
        f.nas.apply = false; f.nas.writeError = IOException("Synthetic missing receipt"); f.settings.save()!!.join()
        val id = f.settings.state.value.records.single().id; assertEquals(1, f.nas.writes.size)
        f.root.close(); val cold = f.root()
        try {
            cold.activate(); await { cold.state.value.loaded && !cold.state.value.loading }; cold.selectSection(SynologyPhotosSection.ALBUMS); await { cold.state.value.loaded && !cold.state.value.loading }
            val settings = cold.settings!!; settings.showRecords(); await { settings.state.value.records.isNotEmpty() }; settings.resume(id)!!.join()
            assertFalse(settings.state.value.records.single().checkpoint.finished); assertEquals(1, f.nas.writes.size)
            f.nas.display = obj("""{"album_display_type":"my_album"}"""); settings.resume(id)!!.join(); await { cold.state.value.loaded && !cold.state.value.loading }
            assertTrue(settings.state.value.records.single().checkpoint.finished); assertEquals(SynologyPhotoAlbumDisplay.MINE, cold.state.value.albumDisplay); assertEquals(1, f.nas.writes.size)
        } finally { cold.close() }
    } }
    @Test fun `未发送恢复重新核对目标原值且过期不生成新写入`() = runBlocking { fixture { f ->
        f.albums(); val repo = f.nas.repository(); repo.access(); val checkpoint = f.nas.row(repo, sortTarget(SynologyPhotoAlbumListScope.ALBUMS)) {
            (it as SynologyPhotoAlbumListSortSettings).copy(sort = it.sort.copy(field = SynologyPhotoAlbumListSort.Field.TYPE)) }
        val row = SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = checkpoint); f.store.begin(row)
        f.settings.showRecords(); await { f.settings.state.value.records.isNotEmpty() }; f.settings.resume(row.id)!!.join()
        assertTrue(f.settings.canSave); assertEquals(sortTarget(SynologyPhotoAlbumListScope.ALBUMS), f.settings.state.value.target)
        f.settings.showRecords(); await { f.settings.state.value.records.isNotEmpty() }; f.nas.order = JsonObject(f.nas.order + ("album_list_sort_by" to JsonPrimitive("create_time")))
        f.settings.resume(row.id)!!.join(); assertNull(f.settings.state.value.desired); assertNotNull(f.settings.state.value.error); assertTrue(f.nas.writes.isEmpty())
    } }
    @Test fun `目标类型序列化恢复原范围且原目标与尝试事实不可倒退`() {
        val owner = WorkspaceOwner("preference", "identity", "session")
        for ((original, desired) in listOf(
            SynologyPhotoAlbumSortSettings(7, SynologyPhotoSort()) to SynologyPhotoAlbumSortSettings(7, SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME)),
            SynologyPhotoAlbumListSortSettings(SynologyPhotoAlbumListScope.WITH_ME, SynologyPhotoAlbumListSort(SynologyPhotoAlbumListSort.Field.NAME, SynologyPhotoSort.Direction.ASCENDING)) to
                SynologyPhotoAlbumListSortSettings(SynologyPhotoAlbumListScope.WITH_ME, SynologyPhotoAlbumListSort(SynologyPhotoAlbumListSort.Field.TYPE, SynologyPhotoSort.Direction.DESCENDING)),
            SynologyPhotoAlbumDisplaySettings(SynologyPhotoAlbumDisplay.ALL) to SynologyPhotoAlbumDisplaySettings(SynologyPhotoAlbumDisplay.MINE))) {
            val prefs = MemoryPreferences(); val store = SynologyPhotoAlbumStore(prefs)
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.SETTINGS, settings = SynologyPhotoSettingsCheckpoint(original, desired)))
            store.begin(row); val submitted = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, settings = row.checkpoint.settings!!.copy(attempted = true)); store.save(row.id, owner, 41, submitted)
            val cold = SynologyPhotoAlbumStore(prefs).records(owner.copy(sessionGeneration = "new"), 41).single().checkpoint
            assertEquals(submitted.copy(phase = SynologyPhotoAlbumPhase.PENDING), cold)
            try { store.save(row.id, owner, 41, cold.copy(settings = cold.settings!!.copy(attempted = false))); fail("Expected rejection") } catch (_: SynologyPhotoAlbumFailure) {}
            try { store.save(row.id, owner, 41, cold.copy(settings = cold.settings!!.copy(original = desired, desired = original))); fail("Expected rejection") } catch (_: SynologyPhotoAlbumFailure) {}
        }
    }
    companion object {
        private suspend fun await(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(5) } }
        private suspend fun fixture(block: suspend (Fixture) -> Unit) { val f = Fixture(); try { f.root.activate(); f.ready(); block(f) } finally { f.close() } }
    }
}
