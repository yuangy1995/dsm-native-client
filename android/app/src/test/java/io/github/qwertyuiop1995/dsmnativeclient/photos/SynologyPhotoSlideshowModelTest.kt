package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneOffset
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SynologyPhotoSlideshowModelTest {
    private class Fixture : SynologyPhotosServing {
        override val profileId = "slideshow"
        override val canEditPhotos = true
        var spaces: List<SynologyPhotoSpace> = SynologyPhotoSpace.entries
        var all = (1L..5).map(::photo)
        data class Call(val space: SynologyPhotoSpace, val query: SynologyPhotoQuery, val offset: Int)
        val calls = mutableListOf<Call>()
        val mediaCalls = mutableListOf<SynologyPhotoId>()
        val sources = mutableListOf<Source>()
        var page: (suspend (SynologyPhotoQuery, Int, Int) -> SynologyPhotoPage)? = null
        var detail: suspend (SynologyPhoto) -> SynologyPhoto = { it }
        var source: suspend () -> Source = { Source().also { sources += it } }
        override suspend fun access() = SynologyPhotoAccess(spaces, "synthetic")
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) =
            listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 2), SynologyPhotoDay(LocalDate.of(2020, 2, 1), 3))
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            calls += Call(space, query, offset)
            page?.let { return it(query, offset, limit) }
            val items = all.drop(offset).take(limit).map {
                it.copy(id = it.id.copy(space = space), albumContext = if (query is SynologyPhotoQuery.Album) SynologyPhotoAlbumContext(query.id, if (space == SynologyPhotoSpace.SHARED) 0 else 41) else null)
            }
            return SynologyPhotoPage(items, offset, offset + items.size, offset + items.size < all.size)
        }
        override suspend fun details(photo: SynologyPhoto) = detail(photo).also { mediaCalls += it.id }
        override suspend fun thumbnail(photo: SynologyPhoto, large: Boolean) = byteArrayOf(1, 2, 3)
        override suspend fun videoSource(photo: SynologyPhoto) = source()
        override suspend fun photoEditIdentity() = 41L
        override suspend fun rootFolder(space: SynologyPhotoSpace) = SynologyPhotoCollection(7, "Synthetic", sort = sort)
        override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
        override suspend fun categories(space: SynologyPhotoSpace) = emptySet<SynologyPhotoCategory>()
        override suspend fun albums(offset: Int, limit: Int) = if (offset == 0) listOf(SynologyPhotoCollection(7, "Synthetic")) else emptyList()
    }
    private class Source : RandomAccessMediaSource {
        var closed = false
        override val size = 3L
        override fun readAt(position: Long, buffer: ByteArray, offset: Int, length: Int) = -1
        override fun close() { closed = true }
    }
    @Test fun `相似组播放完整成员循环而不调用分类分页`() = runTest {
        val repo = Fixture(); val model = SynologyPhotoSlideshowModel(repo, this, 2)
        val group = SynologyPhotoSimilarGroup(repo.profileId, personal, 7, listOf(1, 2, 3), 1)
        val members = (1L..3L).map { photo(it).copy(similarGroup = group) }
        model.startGroup(SynologyPhotoSimilarDetail(group, members), members[1]); runCurrent(); model.pause()
        assertEquals(2L, model.currentId()); assertTrue(model.previewComplete)
        model.move(1); runCurrent(); assertEquals(3L, model.currentId())
        model.move(1); runCurrent(); assertEquals(1L, model.currentId())
        model.move(-1); runCurrent(); assertEquals(3L, model.currentId())
        assertTrue(repo.calls.isEmpty()); assertEquals(listOf(1L, 2L, 3L), model.previewItems.map { it.id.itemId }); model.stop()
    }
    @Test fun `自动预览刷新当前项保持暂停与分页范围且旧媒体回调失效`() = runTest {
        val repo = Fixture(); val model = SynologyPhotoSlideshowModel(repo, this, 2)
        model.start(personal, timeline, photo(1)); runCurrent(); model.move(1); runCurrent(); model.pause()
        val old = model.state.value.mediaToken; val calls = repo.calls.toList(); val photos = model.previewItems.map { it.id }
        val current = model.preview.state.value.photo!!
        repo.detail = { it.copy(thumbnail = SynologyPhotoThumbnail(152, "updated")) }
        val task = SynologyPhotoAutomaticPreviewTask(repo.profileId, personal, 152, current.filename, 0, true, false, source = SynologyPhotoEditTarget(current))
        model.previewsUpdated(task); runCurrent()
        assertEquals(current.id, model.preview.state.value.photo!!.id); assertEquals("updated", model.preview.state.value.photo!!.thumbnail!!.revision)
        assertFalse(model.state.value.playing); assertEquals(calls, repo.calls); assertEquals(photos, model.previewItems.map { it.id }); assertFalse(model.previewComplete)
        assertNotEquals(old, model.state.value.mediaToken); model.mediaReady(old); assertFalse(model.state.value.ready); model.stop()
    }
    @Test fun `照片等待真实显示回调再计时三秒且下一张重新等待`() = runTest {
        val repo = Fixture(); val model = SynologyPhotoSlideshowModel(repo, this, 2)
        model.start(personal, timeline, photo(1)); runCurrent(); advanceTimeBy(30_000); runCurrent()
        assertEquals(1L, model.currentId()); assertTrue(repo.calls.isEmpty())
        model.mediaReady(model.state.value.mediaToken); advanceTimeBy(2_999); runCurrent(); assertEquals(1L, model.currentId())
        advanceTimeBy(1); runCurrent(); assertEquals(2L, model.currentId()); assertFalse(model.state.value.ready)
        advanceTimeBy(30_000); runCurrent(); assertEquals(2L, model.currentId()); model.stop()
    }
    @Test fun `暂停取消倒计时继续从当前照片重新计时`() = runTest {
        val model = SynologyPhotoSlideshowModel(Fixture(), this, 2)
        model.start(personal, timeline, photo(1)); runCurrent(); model.mediaReady(model.state.value.mediaToken)
        advanceTimeBy(2_000); model.pause(); advanceTimeBy(30_000); runCurrent(); assertEquals(1L, model.currentId())
        model.togglePlaying(); advanceTimeBy(2_999); runCurrent(); assertEquals(1L, model.currentId())
        advanceTimeBy(1); runCurrent(); assertEquals(2L, model.currentId()); model.stop()
    }
    @Test fun `视频不使用图片计时结束才推进且迟到重复回调无效`() = runTest {
        val repo = Fixture().apply { all = listOf(photo(1).copy(mediaType = "video"), photo(2)) }
        val model = SynologyPhotoSlideshowModel(repo, this, 2)
        model.start(personal, timeline, repo.all.first()); runCurrent(); val old = model.state.value.mediaToken
        model.mediaReady(old); advanceTimeBy(60_000); runCurrent(); assertEquals(1L, model.currentId())
        model.videoFinished(old); runCurrent(); assertEquals(2L, model.currentId()); assertTrue(repo.sources.single().closed)
        model.videoFinished(old); model.mediaFailed(old, IOException()); model.mediaReady(old); runCurrent()
        assertNull(model.state.value.error); assertFalse(model.state.value.ready); assertEquals(2L, model.currentId()); model.stop()
    }
    @Test fun `暂停时结束的视频继续播放时才进入下一项`() = runTest {
        val model = SynologyPhotoSlideshowModel(Fixture(), this, 2)
        model.start(personal, timeline, photo(1).copy(mediaType = "video")); runCurrent(); model.pause()
        model.videoFinished(model.state.value.mediaToken); runCurrent(); assertEquals(1L, model.currentId())
        model.togglePlaying(); runCurrent(); assertEquals(2L, model.currentId()); model.stop()
    }
    @Test fun `从中间项开始按需补页首尾循环不重复请求`() = runTest {
        val repo = Fixture(); val model = SynologyPhotoSlideshowModel(repo, this, 2)
        model.start(personal, timeline, photo(4)); runCurrent(); model.pause(); model.move(1); runCurrent()
        assertEquals(5L, model.currentId()); assertEquals(listOf(0, 2, 4), repo.calls.map { it.offset })
        model.move(1); runCurrent(); assertEquals(1L, model.currentId()); model.move(-1); runCurrent(); assertEquals(5L, model.currentId())
        assertEquals(3, repo.calls.size); model.stop()
    }
    @Test fun `第一项向前必须读取末页才循环到最后一项`() = runTest {
        val repo = Fixture(); val model = SynologyPhotoSlideshowModel(repo, this, 2)
        model.start(personal, timeline, photo(1)); runCurrent(); model.move(-1); runCurrent()
        assertEquals(5L, model.currentId()); assertEquals(listOf(0, 2, 4), repo.calls.map { it.offset }); model.stop()
    }
    @Test fun `加载与解码失败暂停重试生成新媒体代次且不跳过项目`() = runTest {
        val repo = Fixture().apply { detail = { throw IOException("Synthetic detail") } }
        val model = SynologyPhotoSlideshowModel(repo, this, 2)
        model.start(personal, timeline, photo(1)); runCurrent()
        assertNotNull(model.state.value.error); assertFalse(model.state.value.playing)
        repo.detail = { it }; val old = model.state.value.mediaToken; model.retry(); runCurrent()
        assertEquals(1L, model.currentId()); assertNull(model.state.value.error); assertNotEquals(old, model.state.value.mediaToken)
        model.mediaFailed(model.state.value.mediaToken, IOException("Synthetic decode")); runCurrent()
        assertNotNull(model.state.value.error); model.retry(); runCurrent(); assertNull(model.state.value.error)
        assertFalse(model.state.value.playing); model.stop()
    }
    @Test fun `分页失败停在当前照片且只重试失败页`() = runTest {
        val repo = Fixture().apply { page = { _, offset, _ ->
            if (offset == 2) throw IOException("Synthetic page")
            SynologyPhotoPage(listOf(photo(1), photo(2)), 0, 2, true)
        } }
        val model = SynologyPhotoSlideshowModel(repo, this, 2)
        model.start(personal, timeline, photo(2)); runCurrent(); model.move(1); runCurrent()
        assertEquals(2L, model.currentId()); assertFalse(model.state.value.playing); assertNotNull(model.state.value.error)
        repo.page = null; model.retry(); runCurrent(); assertEquals(3L, model.currentId())
        assertEquals(listOf(0, 2, 2), repo.calls.map { it.offset }); assertNull(model.state.value.error); model.stop()
    }
    @Test fun `游标数量重复身份和来源错误均暂停不接受错误页`() = runTest {
        val invalid = listOf(
            SynologyPhotoPage(listOf(photo(1)), 1, 2, false),
            SynologyPhotoPage(listOf(photo(1)), 0, 4, false),
            SynologyPhotoPage((1L..3).map(::photo), 0, 3, false),
            SynologyPhotoPage(emptyList(), 0, 0, true),
            SynologyPhotoPage(listOf(photo(1), photo(1)), 0, 2, false),
            SynologyPhotoPage(listOf(photo(1).copy(id = photo(1).id.copy(profileId = "other"))), 0, 1, false),
            SynologyPhotoPage(listOf(photo(1).copy(id = photo(1).id.copy(space = SynologyPhotoSpace.SHARED))), 0, 1, false),
            SynologyPhotoPage(listOf(photo(1).copy(albumContext = SynologyPhotoAlbumContext(7, 41))), 0, 1, false),
        )
        invalid.forEach { page ->
            val model = SynologyPhotoSlideshowModel(Fixture().apply { this.page = { _, _, _ -> page } }, this, 2)
            model.start(personal, timeline, photo(1)); runCurrent(); model.move(1); runCurrent()
            assertTrue(model.state.value.error is SynologyPhotoFailure); assertEquals(1L, model.currentId()); model.stop()
        }
    }
    @Test fun `跨页重复与当前照片消失不能静默循环`() = runTest {
        for (duplicate in listOf(true, false)) {
            val repo = Fixture().apply { page = { _, offset, _ ->
                if (duplicate && offset == 0) SynologyPhotoPage(listOf(photo(1), photo(2)), 0, 2, true)
                else SynologyPhotoPage(listOf(photo(2)), offset, offset + 1, false)
            } }
            val model = SynologyPhotoSlideshowModel(repo, this, 2)
            model.start(personal, timeline, photo(if (duplicate) 2 else 1)); runCurrent(); model.move(1); runCurrent()
            assertNotNull(model.state.value.error); assertFalse(model.state.value.playing); model.stop()
        }
    }
    @Test fun `补页时重复按键不并行读取停止后迟到页无效`() = runTest {
        val gate = CompletableDeferred<Unit>()
        val repo = Fixture().apply { page = { _, _, _ ->
            withContext(NonCancellable) { gate.await() }; SynologyPhotoPage(listOf(photo(1), photo(2)), 0, 2, false)
        } }
        val model = SynologyPhotoSlideshowModel(repo, this, 2)
        model.start(personal, timeline, photo(1)); runCurrent(); model.move(1); runCurrent()
        assertNull(model.move(1)); assertEquals(1, repo.calls.size); model.stop()
        model.start(personal, timeline, photo(4)); runCurrent(); gate.complete(Unit); runCurrent()
        assertEquals(4L, model.currentId()); assertNull(model.state.value.error); model.stop()
    }
    @Test fun `停止关闭已加载媒体及迟到源并取消自动推进`() = runTest {
        val gate = CompletableDeferred<Unit>(); val late = Source()
        val repo = Fixture().apply { source = { withContext(NonCancellable) { gate.await() }; late } }
        val model = SynologyPhotoSlideshowModel(repo, this, 2)
        model.start(personal, timeline, photo(1).copy(mediaType = "video")); runCurrent(); model.stop()
        gate.complete(Unit); runCurrent(); assertTrue(late.closed); assertFalse(model.state.value.active)
        repo.source = { Source().also { repo.sources += it } }
        model.start(personal, timeline, photo(1).copy(mediaType = "video")); runCurrent(); model.stop()
        assertTrue(repo.sources.single().closed); advanceTimeBy(60_000); runCurrent(); assertTrue(repo.calls.isEmpty())
    }
    @Test fun `相册固定上下文不把相册观看限制为个人目录访问`() = runTest {
        val repo = Fixture().apply { spaces = emptyList() }
        SynologyPhotosModel(repo, this, 2).use { root ->
            root.activate(); runCurrent(); root.openCollection(root.state.value.collections.single()); runCurrent()
            assertTrue(root.canStartSlideshow); val gallery = root.state.value
            root.startSlideshow(); runCurrent(); root.slideshow.move(1); runCurrent()
            assertEquals(2L, root.slideshow.currentId()); assertEquals(gallery, root.state.value)
            assertEquals(SynologyPhotoAlbumContext(7, 41), root.slideshow.preview.state.value.photo!!.albumContext)
        }
    }
    @Test fun `相册错误编号所有者和命名空间不接受`() = runTest {
        val first = photo(1).copy(albumContext = SynologyPhotoAlbumContext(7, 41))
        val invalid = listOf(first.copy(albumContext = null), first.copy(albumContext = SynologyPhotoAlbumContext(8, 41)),
            first.copy(albumContext = SynologyPhotoAlbumContext(7, -1)), first.copy(albumContext = SynologyPhotoAlbumContext(7, 0)))
        invalid.forEach { bad ->
            val repo = Fixture().apply { page = { _, _, _ -> SynologyPhotoPage(listOf(bad), 0, 1, false) } }
            val model = SynologyPhotoSlideshowModel(repo, this, 2)
            assertNull(model.start(personal, SynologyPhotoQuery.Album(7), bad))
            model.start(personal, SynologyPhotoQuery.Album(7), first); runCurrent(); model.move(1); runCurrent()
            assertNotNull(model.state.value.error); model.stop()
        }
    }
    @Test fun `月份跳转后仍用完整查询且保留图库月份选择已读范围`() = runTest {
        val repo = Fixture(); val owner = WorkspaceOwner("slideshow", "synthetic", "session")
        val edits = SynologyPhotoEditStore(MemoryPreferences())
        SynologyPhotosModel(repo, this, 2, ZoneOffset.UTC, uploadOwner = owner, editStore = edits).use { root ->
            root.activate(); runCurrent(); val original = repo.calls.first().query
            root.jumpToMonth(YearMonth.of(2020, 2)); runCurrent()
            assertNotEquals(original, repo.calls.last().query)
            root.edits!!.selectMode(true); root.edits.toggle(root.state.value.items.first())
            val gallery = root.state.value; val selected = root.edits.state.value.selected
            root.preview.open(gallery.items.last()); runCurrent(); root.startSlideshow(); runCurrent()
            root.slideshow.move(1); runCurrent()
            assertNull(root.preview.state.value.photo); assertEquals(3L, root.slideshow.currentId())
            assertEquals(original, repo.calls.last().query); assertEquals(gallery, root.state.value)
            assertEquals(selected, root.edits.state.value.selected)
            root.slideshow.stop(); root.loadMore(); runCurrent(); assertEquals(gallery.items + listOf(photo(3), photo(4)), root.state.value.items)
        }
    }
    @Test fun `目录排序搜索筛选与分类查询所有分页保持完整值`() = runTest {
        val filter = SynologyPhotoFilter(mediaType = 1, personId = 9)
        val queries = listOf(SynologyPhotoQuery.Folder(7, sort), SynologyPhotoQuery.Album(7, sort),
            SynologyPhotoQuery.Search("synthetic", 20, 40), SynologyPhotoQuery.Filtered(filter, 20, 40),
            SynologyPhotoQuery.Category(SynologyPhotoCategory.TAGS, 9, 20, 40), SynologyPhotoQuery.Recent)
        queries.forEach { query ->
            val repo = Fixture(); val model = SynologyPhotoSlideshowModel(repo, this, 2)
            val first = photo(1).copy(albumContext = if (query is SynologyPhotoQuery.Album) SynologyPhotoAlbumContext(7, 41) else null)
            model.start(personal, query, first); runCurrent(); model.move(-1); runCurrent()
            assertEquals(listOf(0, 2, 4), repo.calls.map { it.offset }); assertTrue(repo.calls.all { it.query == query && it.space == personal })
            model.stop()
        }
    }
    @Test fun `图库退出撤权关闭及刷新均停止幻灯片`() = runTest {
        for (action in 0..3) {
            val repo = Fixture().apply { all = listOf(photo(1).copy(mediaType = "video")) }
            SynologyPhotosModel(repo, this, 2).use { root ->
                assertFalse(root.canStartSlideshow); root.activate(); runCurrent(); root.startSlideshow(); runCurrent()
                val source = repo.sources.single()
                when (action) { 0 -> root.deactivate(); 1 -> root.revokeAccess(); 2 -> root.close(); else -> root.refresh() }
                runCurrent(); assertFalse(root.slideshow.state.value.active); assertTrue(source.closed)
                advanceTimeBy(60_000); runCurrent(); assertNull(root.slideshow.preview.state.value.photo)
            }
        }
    }
    private fun SynologyPhotoSlideshowModel.currentId() = preview.state.value.photo?.id?.itemId
    companion object {
        private val personal = SynologyPhotoSpace.PERSONAL
        private val timeline = SynologyPhotoQuery.Timeline(0, Long.MAX_VALUE)
        private val sort = SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME, SynologyPhotoSort.Direction.DESCENDING)
        private fun photo(id: Long) = SynologyPhoto(SynologyPhotoId("slideshow", personal, id), "Synthetic$id.jpg", 10, 1.0, 1.0, 7, "photo")
    }
}
