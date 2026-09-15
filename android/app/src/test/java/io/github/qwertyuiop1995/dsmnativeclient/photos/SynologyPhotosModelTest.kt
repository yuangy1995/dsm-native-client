package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File
import java.io.IOException
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneOffset
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SynologyPhotosModelTest {
    private class Fixture : SynologyPhotosServing {
        override val profileId = "profile-a"
        override var canDeleteOriginals = false
        var spaces = listOf(SynologyPhotoSpace.PERSONAL)
        var days = listOf(SynologyPhotoDay(LocalDate.of(2025, 1, 1), 10_000))
        val pageCalls = mutableListOf<Pair<SynologyPhotoQuery, Int>>()
        val timelineCalls = mutableListOf<SynologyPhotoQuery?>()
        var page: suspend (SynologyPhotoQuery, Int, Int) -> SynologyPhotoPage = { _, offset, limit ->
            SynologyPhotoPage((offset + 1L..offset + limit.toLong()).map(::photo), offset, offset + limit, true)
        }
        var details: suspend (SynologyPhoto) -> SynologyPhoto = { it }
        var source: suspend (SynologyPhoto) -> RandomAccessMediaSource = { Source() }
        var original: suspend (SynologyPhoto, File) -> Unit = { _, file -> file.writeBytes(byteArrayOf(1, 2, 3, 4)) }
        var writes = 0
        var reviews = 0
        var deletion: suspend () -> SynologyPhotoDeletionResult = { SynologyPhotoDeletionResult.PENDING_REVIEW }
        var review: suspend () -> SynologyPhotoDeletionResult = { SynologyPhotoDeletionResult.CONFIRMED }
        var folderPages: suspend (Long, Int) -> List<SynologyPhotoCollection> = { parent, _ ->
            if (parent == 5L) listOf(SynologyPhotoCollection(6, "Trips", parentId = 5)) else emptyList()
        }
        override suspend fun access() = SynologyPhotoAccess(spaces, "fixture")
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?): List<SynologyPhotoDay> {
            timelineCalls += query
            return days
        }
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            pageCalls += query to offset
            return page(query, offset, limit)
        }
        override suspend fun rootFolder(space: SynologyPhotoSpace) = SynologyPhotoCollection(5, "/", parentId = 0)
        override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int) = folderPages(parentId, offset)
        override suspend fun categories() = SynologyPhotoCategory.entries.toSet()
        override suspend fun albums(offset: Int, limit: Int) = if (offset == 0) listOf(SynologyPhotoCollection(7, "Album")) else emptyList()
        override suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int) = listOf(SynologyPhotoCollection(8, "Category"))
        override suspend fun sharedEntries(scope: SynologyPhotoShareScope, offset: Int, limit: Int) = listOf(SynologyPhotoSharedEntry("7", "Shared album", 7))
        override suspend fun filterOptions(): SynologyPhotoFilterOptions = throw IOException("synthetic options failure")
        override suspend fun details(photo: SynologyPhoto) = details.invoke(photo)
        override suspend fun thumbnail(photo: SynologyPhoto, large: Boolean) = byteArrayOf(1, 2)
        override suspend fun videoSource(photo: SynologyPhoto) = source(photo)
        override suspend fun downloadOriginal(photo: SynologyPhoto, destination: File, progress: (Long, Long) -> Unit) {
            original(photo, destination)
            progress(4, 4)
        }
        override suspend fun prepareDeletion(photo: SynologyPhoto) = Unit
        override suspend fun deletePhoto(photo: SynologyPhoto, operationId: UUID): SynologyPhotoDeletionResult { writes++; return deletion() }
        override suspend fun reviewDeletion(photo: SynologyPhoto): SynologyPhotoDeletionResult { reviews++; return review() }
    }
    private class Source : RandomAccessMediaSource {
        var closed = false
        override val size = 4L
        override fun readAt(position: Long, buffer: ByteArray, offset: Int, length: Int) = -1
        override fun close() { closed = true }
    }

    @Test fun `初始万张聚合只读取一页并按原始偏移加载下一页`() = runTest {
        val fixture = Fixture()
        SynologyPhotosModel(fixture, this).use { model ->
            model.activate(); advanceUntilIdle()
            assertEquals(100, model.state.value.items.size)
            assertEquals(listOf(0), fixture.pageCalls.map { it.second })
            assertEquals(listOf(YearMonth.of(2025, 1)), model.state.value.months)
            model.loadMore()?.join()
            assertEquals(listOf(0, 100), fixture.pageCalls.map { it.second })
            assertEquals(200, model.state.value.items.size)
            assertEquals(200, model.state.value.groups.sumOf { it.items.size })
        }
    }

    @Test fun `跨页重叠按原始条数推进而重复整页停止自动重试`() = runTest {
        val fixture = Fixture()
        fixture.page = { _, offset, _ -> when (offset) {
            0 -> SynologyPhotoPage(listOf(photo(1), photo(2)), 0, 2, true)
            2 -> SynologyPhotoPage(listOf(photo(2), photo(3)), 2, 4, true)
            else -> SynologyPhotoPage(listOf(photo(2), photo(3)), 4, 6, true)
        } }
        SynologyPhotosModel(fixture, this, pageSize = 2).use { model ->
            model.activate(); advanceUntilIdle()
            model.loadMore()?.join()
            assertEquals(listOf(1L, 2L, 3L), model.state.value.items.map { it.id.itemId })
            model.loadMore()?.join()
            assertNotNull(model.state.value.error)
            assertNull(model.loadMore(automatic = true))
            assertEquals(listOf(0, 2, 4), fixture.pageCalls.map { it.second })
            assertEquals(3, model.state.value.items.size)
        }
    }

    @Test fun `缺少权限和空聚合不会触发文件扫描或项目查询`() = runTest {
        val fixture = Fixture()
        fixture.spaces = emptyList()
        SynologyPhotosModel(fixture, this).use { model ->
            model.activate(); advanceUntilIdle()
            assertNotNull(model.state.value.error)
            assertTrue(fixture.pageCalls.isEmpty())
            fixture.spaces = listOf(SynologyPhotoSpace.PERSONAL)
            fixture.days = emptyList()
            model.refresh()?.join()
            assertTrue(model.state.value.loaded)
            assertTrue(model.state.value.empty)
            assertTrue(fixture.pageCalls.isEmpty())
        }
    }

    @Test fun `切换搜索会取消旧导航并忽略不合作的迟到响应`() = runTest {
        val fixture = Fixture()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        fixture.page = { query, offset, _ ->
            if (query is SynologyPhotoQuery.Search) SynologyPhotoPage(listOf(photo(9)), offset, offset + 1, false)
            else withContext(NonCancellable) { entered.complete(Unit); release.await(); SynologyPhotoPage(listOf(photo(1)), offset, offset + 1, false) }
        }
        SynologyPhotosModel(fixture, this).use { model ->
            model.activate(); entered.await()
            model.search("  sunset  "); runCurrent()
            assertEquals("sunset", model.state.value.navigation.keyword)
            assertEquals(listOf(9L), model.state.value.items.map { it.id.itemId })
            release.complete(Unit); advanceUntilIdle()
            assertEquals(listOf(9L), model.state.value.items.map { it.id.itemId })
            assertEquals("sunset", (fixture.timelineCalls.last() as SynologyPhotoQuery.Search).keyword)
        }
    }

    @Test fun `月份跳转完整插入较新月份且保留较旧分页独立游标`() = runTest {
        val fixture = Fixture()
        fixture.days = listOf(1, 2, 3).map { SynologyPhotoDay(LocalDate.of(2025, it, 1), 9999) }
        val feb = LocalDate.of(2025, 2, 1).atStartOfDay(ZoneOffset.UTC).toEpochSecond()
        val march = LocalDate.of(2025, 3, 1).atStartOfDay(ZoneOffset.UTC).toEpochSecond()
        fixture.page = { query, offset, _ ->
            query as SynologyPhotoQuery.Timeline
            val ids = when {
                query.start >= feb -> when (offset) { 0 -> listOf(10L, 11L); 2 -> listOf(12L); else -> emptyList() }
                query.end < feb -> if (offset == 0) listOf(1L, 2L) else listOf(3L)
                else -> listOf(20L, 21L)
            }
            SynologyPhotoPage(ids.map { photo(it).copy(takenAt = if (it >= 10 && it < 20) feb.toDouble() else march.toDouble()) }, offset, offset + ids.size, ids.size == 2)
        }
        SynologyPhotosModel(fixture, this, 2, ZoneOffset.UTC).use { model ->
            model.activate(); advanceUntilIdle()
            model.jumpToMonth(YearMonth.of(2025, 1))?.join()
            assertTrue(model.state.value.hasPrevious)
            model.loadPrevious()?.join()
            assertEquals(listOf(10L, 11L, 12L, 1L, 2L), model.state.value.items.map { it.id.itemId })
            model.loadMore()?.join()
            assertEquals(2, fixture.pageCalls.last().second)
            assertTrue((fixture.pageCalls.last().first as SynologyPhotoQuery.Timeline).end < feb)
            assertEquals(listOf(10L, 11L, 12L, 1L, 2L, 3L), model.state.value.items.map { it.id.itemId })
        }
    }

    @Test fun `筛选月份窗口保留全部候选条件并交集原始日期`() = runTest {
        val start = LocalDate.of(2025, 1, 15).atStartOfDay(ZoneOffset.UTC).toEpochSecond()
        val end = LocalDate.of(2025, 3, 15).atStartOfDay(ZoneOffset.UTC).toEpochSecond()
        val filter = SynologyPhotoFilter(personId = 2, locationId = 3, cameraId = 4, rating = 5, startTime = start, endTime = end)
        val original = SynologyPhotoQuery.Filtered(filter, 0, Long.MAX_VALUE)
        val monthEnd = LocalDate.of(2025, 3, 1).atStartOfDay(ZoneOffset.UTC).toEpochSecond() - 1
        val constrained = SynologyPhotoWindows.constrain(original, end = monthEnd) as SynologyPhotoQuery.Filtered
        assertEquals(filter.copy(endTime = monthEnd), constrained.filter)
        assertEquals(start, constrained.start)
        assertEquals(monthEnd, constrained.end)
        assertNull(SynologyPhotoWindows.constrain(original, end = start - 1))
        val search = SynologyPhotoQuery.Search("all-library", start, end)
        assertEquals("all-library", (SynologyPhotoWindows.constrain(search, end = monthEnd) as SynologyPhotoQuery.Search).keyword)
    }

    @Test fun `目录相册分享与真实分类导航不会互相复用游标`() = runTest {
        val fixture = Fixture()
        SynologyPhotosModel(fixture, this, pageSize = 2).use { model ->
            model.activate(); advanceUntilIdle()
            model.selectSection(SynologyPhotosSection.FOLDERS); advanceUntilIdle()
            assertEquals(listOf(5L), model.state.value.navigation.folders.map { it.id })
            model.openCollection(model.state.value.collections.single()); advanceUntilIdle()
            assertEquals(SynologyPhotoQuery.Folder(6), fixture.pageCalls.last().first)
            assertTrue(model.goBack()); advanceUntilIdle()
            assertEquals(SynologyPhotoQuery.Folder(5), fixture.pageCalls.last().first)
            model.selectSection(SynologyPhotosSection.ALBUMS); advanceUntilIdle()
            model.openCollection(model.state.value.collections.single()); advanceUntilIdle()
            assertEquals(SynologyPhotoQuery.Album(7), fixture.pageCalls.last().first)
            model.selectSection(SynologyPhotosSection.ALBUMS); advanceUntilIdle()
            model.openCategory(SynologyPhotoCategory.SUBJECTS); advanceUntilIdle()
            model.openCollection(model.state.value.collections.single()); advanceUntilIdle()
            assertEquals(SynologyPhotoCategory.SUBJECTS, (fixture.pageCalls.last().first as SynologyPhotoQuery.Category).category)
            model.selectShareScope(SynologyPhotoShareScope.WITH_ME); advanceUntilIdle()
            model.openSharedAlbum(model.state.value.sharing.single()); advanceUntilIdle()
            assertEquals(SynologyPhotoQuery.Album(7), fixture.pageCalls.last().first)
            assertEquals(0, fixture.pageCalls.last().second)
        }
    }

    @Test fun `候选加载失败不清空已加载图库`() = runTest {
        val fixture = Fixture()
        SynologyPhotosModel(fixture, this, 2).use { model ->
            model.activate(); advanceUntilIdle()
            val items = model.state.value.items
            model.loadFilterOptions()?.join()
            assertNotNull(model.state.value.optionsError)
            assertNull(model.state.value.error)
            assertEquals(items, model.state.value.items)
            model.deactivate(); advanceUntilIdle()
            assertFalse(model.state.value.loaded)
            assertEquals(0, model.thumbnails.cost())
        }
    }

    @Test fun `不同账号身份即使来自服务端也不能进入图库`() = runTest {
        val fixture = Fixture()
        fixture.page = { _, offset, _ -> SynologyPhotoPage(listOf(photo(1).copy(id = photo(1).id.copy(profileId = "profile-b"))), offset, offset + 1, false) }
        SynologyPhotosModel(fixture, this).use { model ->
            model.activate(); advanceUntilIdle()
            assertNotNull(model.state.value.error)
            assertTrue(model.state.value.items.isEmpty())
        }
    }

    @Test fun `上一张迟到的视频源会关闭而不会替换当前大图`() = runTest {
        val fixture = Fixture()
        val oldSource = Source()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        fixture.source = { withContext(NonCancellable) { entered.complete(Unit); release.await(); oldSource } }
        val preview = SynologyPhotoPreviewModel(fixture, this) { listOf(photo(1), photo(2)) }
        preview.open(photo(1).copy(mediaType = "video")); entered.await()
        preview.open(photo(2))?.join()
        release.complete(Unit); advanceUntilIdle()
        assertTrue(oldSource.closed)
        assertEquals(2L, preview.state.value.photo?.id?.itemId)
        assertNull(preview.state.value.source)
        assertArrayEquals(byteArrayOf(1, 2), preview.state.value.image)
        preview.deactivate()
    }

    @Test fun `系统保存选择器暂停页面保留已校验原件但退出账号清理`() = runTest {
        val fixture = Fixture()
        val cache = java.nio.file.Files.createTempDirectory("photos-model-test-").toFile()
        val preview = SynologyPhotoPreviewModel(fixture, this) { listOf(photo(1)) }
        try {
            preview.prepareExport(photo(1), cache)?.join()
            val file = preview.state.value.exportFile!!
            assertTrue(file.exists())
            preview.deactivate(preservePreparedExport = true)
            assertEquals(file, preview.state.value.exportFile)
            preview.deactivate()
            advanceUntilIdle()
            assertNull(preview.state.value.exportFile)
            withContext(Dispatchers.IO) { repeat(100) { if (!file.exists()) return@withContext; delay(2) } }
            assertFalse(file.exists())
        } finally { preview.deactivate(); cache.deleteRecursively() }
    }

    @Test fun `页面离开时删除不确定状态保留且只允许核对`() = runTest {
        val fixture = Fixture().apply { canDeleteOriginals = true }
        val entered = CompletableDeferred<Unit>()
        fixture.deletion = { entered.complete(Unit); awaitCancellation() }
        var confirmed = 0
        val deletion = SynologyPhotoDeletionModel(fixture, this) { confirmed++ }
        deletion.prepare(photo(1))?.join()
        deletion.confirm()
        entered.await()
        assertNull(deletion.confirm())
        deletion.deactivate(); advanceUntilIdle()
        assertEquals(photo(1), deletion.state.value.pending)
        assertNull(deletion.prepare(photo(2)))
        deletion.review()?.join()
        assertEquals(1, fixture.writes)
        assertEquals(1, fixture.reviews)
        assertEquals(1, confirmed)
        assertNull(deletion.state.value.pending)
    }

    private companion object {
        fun photo(id: Long) = SynologyPhoto(SynologyPhotoId("profile-a", SynologyPhotoSpace.PERSONAL, id), "sample-$id.heic", 4,
            1735689600.0, 1735776000.0, 5, "photo", SynologyPhotoThumbnail(id + 1000, "revision"))
    }
}
