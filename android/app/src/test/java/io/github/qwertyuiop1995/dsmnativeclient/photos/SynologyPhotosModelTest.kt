package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File
import java.io.IOException
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneOffset
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
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
        val sourceCalls = mutableListOf<SynologyPhotoSpace>()
        var filterReply: suspend (SynologyPhotoSpace) -> SynologyPhotoFilterOptions = { throw IOException("synthetic options failure") }
        var page: suspend (SynologyPhotoQuery, Int, Int) -> SynologyPhotoPage = { _, offset, limit ->
            SynologyPhotoPage((offset + 1L..offset + limit.toLong()).map(::photo), offset, offset + limit, true)
        }
        var details: suspend (SynologyPhoto) -> SynologyPhoto = { it }
        var source: suspend (SynologyPhoto) -> RandomAccessMediaSource = { Source() }
        var original: suspend (SynologyPhoto, File) -> Unit = { _, file -> file.writeBytes(byteArrayOf(1, 2, 3, 4)) }
        var writes = 0
        var reviews = 0
        var deletion: suspend () -> SynologyPhotoDeletionPhase = { SynologyPhotoDeletionPhase.SUBMITTED }
        var review: suspend () -> SynologyPhotoDeletionPhase = { SynologyPhotoDeletionPhase.CONFIRMED }
        var folderPages: suspend (Long, Int) -> List<SynologyPhotoCollection> = { parent, _ ->
            if (parent == 5L) listOf(SynologyPhotoCollection(6, "Trips", parentId = 5)) else emptyList()
        }
        val sharingOffsets = mutableListOf<Int>()
        var sharedPage: suspend (Int, Int) -> List<SynologyPhotoSharedEntry> = { _, _ -> listOf(SynologyPhotoSharedEntry("7", "Shared album", 7)) }
        override suspend fun access() = SynologyPhotoAccess(spaces, "fixture")
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?): List<SynologyPhotoDay> {
            timelineCalls += query
            return days
        }
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            sourceCalls += space
            pageCalls += query to offset
            return page(query, offset, limit).let { result -> result.copy(items = result.items.map { photo ->
                photo.copy(id = photo.id.copy(space = space), albumContext = if (query is SynologyPhotoQuery.Album) SynologyPhotoAlbumContext(query.id, if (space == SynologyPhotoSpace.PERSONAL) 41 else 0) else null)
            }) }
        }
        override suspend fun rootFolder(space: SynologyPhotoSpace) = SynologyPhotoCollection(5, "/", parentId = 0)
        override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int) = folderPages(parentId, offset).map { it.copy(space = space) }
        override suspend fun categories(space: SynologyPhotoSpace) = SynologyPhotoCategory.entries.toSet()
        override suspend fun albums(offset: Int, limit: Int) = if (offset == 0) listOf(SynologyPhotoCollection(7, "Album")) else emptyList()
        override suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int, space: SynologyPhotoSpace) = listOf(SynologyPhotoCollection(8, "Category"))
        override suspend fun sharedEntries(scope: SynologyPhotoShareScope, offset: Int, limit: Int): List<SynologyPhotoSharedEntry> {
            sharingOffsets += offset; return sharedPage(offset, limit)
        }
        override suspend fun filterOptions(space: SynologyPhotoSpace): SynologyPhotoFilterOptions = filterReply(space)
        override suspend fun details(photo: SynologyPhoto) = details.invoke(photo)
        override suspend fun thumbnail(photo: SynologyPhoto, large: Boolean) = byteArrayOf(1, 2)
        override suspend fun videoSource(photo: SynologyPhoto) = source(photo)
        override suspend fun downloadOriginal(photo: SynologyPhoto, destination: File, progress: (Long, Long) -> Unit) {
            original(photo, destination)
            progress(4, 4)
        }
        override suspend fun prepareDeletion(photo: SynologyPhoto) = Unit
        override suspend fun photoEditIdentity() = 41L
        override suspend fun performPhotoDeletion(photo: SynologyPhoto, checkpoint: SynologyPhotoDeletionCheckpoint,
            save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint {
            val sent = checkpoint.copy(phase = SynologyPhotoDeletionPhase.SUBMITTED); save(sent); writes++
            val phase = try { deletion() } catch (_: CancellationException) { SynologyPhotoDeletionPhase.SUBMITTED }
            return sent.copy(phase = phase).also(save)
        }
        override suspend fun reviewPhotoDeletion(checkpoint: SynologyPhotoDeletionCheckpoint,
            save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint {
            reviews++; return checkpoint.copy(phase = review()).also(save)
        }
    }
    private class Source : RandomAccessMediaSource {
        var closed = false
        override val size = 4L
        override fun readAt(position: Long, buffer: ByteArray, offset: Int, length: Int) = -1
        override fun close() { closed = true }
    }
    @Test fun `收集标题搜索保持请求列表无匹配时继续后续页清除不重读`() = runTest {
        val fixture = Fixture().apply { sharedPage = { offset, limit ->
            (offset until minOf(offset + limit, 5)).map { SynologyPhotoSharedEntry("synthetic-$it", if (it == 4) "Target" else "Other $it") }
        } }
        SynologyPhotosModel(fixture, this, pageSize = 2).use { model ->
            model.activate(); advanceUntilIdle(); model.selectSection(SynologyPhotosSection.SHARING); advanceUntilIdle()
            model.selectShareScope(SynologyPhotoShareScope.REQUESTS); advanceUntilIdle(); fixture.sharingOffsets.clear(); fixture.pageCalls.clear()
            model.search("target"); advanceUntilIdle()
            assertTrue(model.state.value.navigation.isRequests); assertEquals(listOf("Target"), model.state.value.visibleSharing.map { it.title })
            assertEquals(listOf(2, 4), fixture.sharingOffsets); assertTrue(fixture.pageCalls.isEmpty())
            model.search("missing"); advanceUntilIdle(); assertTrue(model.state.value.empty)
            model.search(""); advanceUntilIdle(); assertEquals(5, model.state.value.visibleSharing.size); assertEquals(2, fixture.sharingOffsets.size)
        }
    }
    @Test fun `收集搜索后续页错误保留已读结果与重试位置`() = runTest {
        val fixture = Fixture().apply { sharedPage = { offset, _ ->
            if (offset > 0) throw IOException("Synthetic page")
            listOf(SynologyPhotoSharedEntry("one", "Other one"), SynologyPhotoSharedEntry("two", "Other two"))
        } }
        SynologyPhotosModel(fixture, this, pageSize = 2).use { model ->
            model.activate(); advanceUntilIdle(); model.selectSection(SynologyPhotosSection.SHARING); advanceUntilIdle()
            model.selectShareScope(SynologyPhotoShareScope.REQUESTS); advanceUntilIdle(); model.search("Target"); advanceUntilIdle()
            assertNotNull(model.state.value.error); assertEquals(2, model.state.value.sharing.size)
            fixture.sharedPage = { _, _ -> listOf(SynologyPhotoSharedEntry("three", "Target")) }
            model.loadMore(); advanceUntilIdle(); assertNull(model.state.value.error)
            assertEquals(2, fixture.sharingOffsets.last()); assertEquals("Target", model.state.value.visibleSharing.single().title)
        }
    }

    @Test fun `来源切换后相同目录编号不接受旧来源的点击快照`() = runTest {
        val fixture = Fixture().apply { spaces = SynologyPhotoSpace.entries }
        SynologyPhotosModel(fixture, this).use { model ->
            model.activate(); advanceUntilIdle()
            model.selectSection(SynologyPhotosSection.FOLDERS); advanceUntilIdle()
            val old = model.state.value.collections.single()
            model.selectSpace(SynologyPhotoSpace.SHARED); advanceUntilIdle()
            assertEquals(old.id, model.state.value.collections.single().id)
            assertNotEquals(old.space, model.state.value.collections.single().space)
            val before = fixture.pageCalls.size
            model.openCollection(old); advanceUntilIdle()
            assertEquals(before, fixture.pageCalls.size)
            assertEquals(5L, model.state.value.navigation.folders.single().id)
            model.openCollection(model.state.value.collections.single()); advanceUntilIdle()
            assertEquals(SynologyPhotoQuery.Folder(6), fixture.pageCalls.last().first)
            assertEquals(SynologyPhotoSpace.SHARED, fixture.sourceCalls.last())
        }
    }

    @Test fun `共享单来源可直接读取切换双来源后分页搜索均保留来源`() = runTest {
        val fixture = Fixture().apply { spaces = listOf(SynologyPhotoSpace.SHARED) }
        SynologyPhotosModel(fixture, this, pageSize = 2).use { model ->
            model.activate(); advanceUntilIdle()
            assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space)
            assertTrue(model.state.value.items.all { it.id.space == SynologyPhotoSpace.SHARED })
            model.search("shared"); advanceUntilIdle(); model.loadMore()?.join()
            assertTrue(fixture.sourceCalls.all { it == SynologyPhotoSpace.SHARED })
            fixture.spaces = SynologyPhotoSpace.entries
            model.refresh()?.join()
            model.selectSpace(SynologyPhotoSpace.PERSONAL); advanceUntilIdle()
            assertTrue(model.state.value.items.all { it.id.space == SynologyPhotoSpace.PERSONAL })
            assertEquals("", model.state.value.navigation.keyword)
            assertEquals(SynologyPhotoSpace.PERSONAL, fixture.sourceCalls.last())
            fixture.spaces = listOf(SynologyPhotoSpace.SHARED)
            model.refresh()?.join()
            assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space)
        }
    }

    @Test fun `切换来源取消筛选候选并拒绝旧来源迟到结果`() = runTest {
        val fixture = Fixture().apply { spaces = SynologyPhotoSpace.entries }
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        fixture.filterReply = { space ->
            if (space == SynologyPhotoSpace.PERSONAL) withContext(NonCancellable) {
                entered.complete(Unit); release.await(); SynologyPhotoFilterOptions(people = listOf(SynologyPhotoChoice(1, "old")))
            } else SynologyPhotoFilterOptions(people = listOf(SynologyPhotoChoice(2, "shared")))
        }
        SynologyPhotosModel(fixture, this).use { model ->
            model.activate(); advanceUntilIdle()
            model.loadFilterOptions(); entered.await()
            model.selectSpace(SynologyPhotoSpace.SHARED); runCurrent()
            model.loadFilterOptions()?.join()
            release.complete(Unit); advanceUntilIdle()
            assertEquals(listOf(2L), model.state.value.options.people.map { it.id })
            assertFalse(model.state.value.optionsLoading)
        }
    }

    @Test fun `仅相册授权仍可打开分享相册而不能进入时间线和搜索`() = runTest {
        val fixture = Fixture().apply { spaces = emptyList() }
        SynologyPhotosModel(fixture, this, pageSize = 2).use { model ->
            model.activate(); advanceUntilIdle()
            model.selectSection(SynologyPhotosSection.TIMELINE); model.search("unavailable"); advanceUntilIdle()
            assertTrue(fixture.pageCalls.isEmpty())
            model.openCollection(model.state.value.collections.single()); advanceUntilIdle()
            assertNull(model.state.value.error)
            assertTrue(model.state.value.items.all { it.albumContext?.albumId == 7L })
            model.selectSection(SynologyPhotosSection.SHARING); advanceUntilIdle()
            model.openSharedAlbum(model.state.value.sharing.single()); advanceUntilIdle()
            assertNull(model.state.value.error)
            assertEquals(SynologyPhotoQuery.Album(7), fixture.pageCalls.last().first)
        }
    }

    @Test fun `撤销授权清除图库并保留已提交删除供恢复后回查`() = runTest {
        val fixture = Fixture().apply { canDeleteOriginals = true }
        val owner = WorkspaceOwner(fixture.profileId, "identity", "session")
        val store = SynologyPhotoDeletionStore(MemoryPreferences())
        SynologyPhotosModel(fixture, this, uploadOwner = owner, deletionStore = store).use { model ->
            model.activate(); advanceUntilIdle(); deletionReady(model.deletion)
            val target = model.state.value.items.first()
            model.deletion.prepare(target)!!.join(); model.deletion.confirm()!!.join()
            assertTrue(model.deletion.state.value.pending!!.entries.single().target.matches(target))
            model.revokeAccess(); advanceUntilIdle()
            assertTrue(model.state.value.items.isEmpty()); assertTrue(model.state.value.groups.isEmpty())
            assertEquals(SynologyPhotoDeletionPhase.SUBMITTED, store.records(owner, 41).single().entries.single().phase)
            assertTrue(model.deletion.state.value.records.isEmpty())
            model.activate(); runCurrent(); deletionReady(model.deletion)
            model.deletion.review(store.records(owner, 41).single().id)?.join()
            assertEquals(1, fixture.writes); assertEquals(1, fixture.reviews)
            assertNull(model.deletion.state.value.pending)
        }
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

    @Test fun `没有原来源时显示相册且空时间线不触发项目查询`() = runTest {
        val fixture = Fixture()
        fixture.spaces = emptyList()
        SynologyPhotosModel(fixture, this).use { model ->
            model.activate(); advanceUntilIdle()
            assertNull(model.state.value.error)
            assertEquals(SynologyPhotosSection.ALBUMS, model.state.value.navigation.section)
            assertEquals(listOf(7L), model.state.value.collections.map { it.id })
            assertTrue(fixture.pageCalls.isEmpty())
            fixture.spaces = listOf(SynologyPhotoSpace.PERSONAL)
            fixture.days = emptyList()
            model.refresh()?.join()
            model.selectSection(SynologyPhotosSection.TIMELINE); advanceUntilIdle()
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
        val export = SynologyPhotoExportModel(fixture, this)
        try {
            export.open(SynologyPhotoExportRequest.Items(listOf(photo(1))))
            export.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)?.join()
            val file = export.state.value.file!!
            assertTrue(file.exists())
            export.deactivate(preservePicker = true)
            assertEquals(file, export.state.value.file)
            export.deactivate(false)
            advanceUntilIdle()
            assertNull(export.state.value.file)
            withContext(Dispatchers.IO) { repeat(100) { if (!file.exists()) return@withContext; delay(2) } }
            assertFalse(file.exists())
        } finally { export.deactivate(false); cache.deleteRecursively() }
    }

    @Test fun `页面离开时删除不确定状态保留且只允许核对`() = runTest {
        val fixture = Fixture().apply { canDeleteOriginals = true }
        val entered = CompletableDeferred<Unit>()
        fixture.deletion = { entered.complete(Unit); awaitCancellation() }
        var confirmed = 0
        val owner = WorkspaceOwner(fixture.profileId, "identity", "session")
        val store = SynologyPhotoDeletionStore(MemoryPreferences())
        SynologyPhotoDeletionModel(fixture, this, store, owner, onConfirmed = { confirmed++ }).use { deletion ->
            deletion.activate(); deletionReady(deletion)
            deletion.prepare(photo(1))!!.join(); deletion.confirm(); entered.await()
            assertNull(deletion.confirm())
            deletion.deactivate(); advanceUntilIdle()
            val row = store.records(owner, 41).single()
            assertTrue(row.entries.single().target.matches(photo(1)))
            assertEquals(SynologyPhotoDeletionPhase.SUBMITTED, row.entries.single().phase)
            assertNull(deletion.prepare(photo(2))); assertNull(deletion.review(row.id))
            deletion.activate(); deletionReady(deletion); deletion.review(row.id)!!.join()
            assertEquals("write count", 1, fixture.writes); assertEquals("review count", 1, fixture.reviews); assertEquals("confirmed callback count", 1, confirmed)
            assertNull(deletion.state.value.pending)
        }
    }
    @Test fun `原件删除保留历史月份并修正原照片分页偏移`() = runTest {
        val fixture = Fixture().apply { canDeleteOriginals = true; days = listOf(
            SynologyPhotoDay(LocalDate.of(2025, 2, 1), 3), SynologyPhotoDay(LocalDate.of(2025, 1, 1), 3)) }
        val remaining = mutableListOf(1L, 2L, 3L)
        fixture.page = { _, offset, limit -> SynologyPhotoPage(remaining.drop(offset).take(limit).map(::photo), offset,
            offset + minOf(limit, remaining.size - offset), offset + limit < remaining.size) }
        fixture.deletion = { remaining.remove(1L); SynologyPhotoDeletionPhase.CONFIRMED }
        val owner = WorkspaceOwner(fixture.profileId, "paging", "session")
        SynologyPhotosModel(fixture, this, pageSize = 2, uploadOwner = owner, deletionStore = SynologyPhotoDeletionStore(MemoryPreferences())).use { model ->
            model.activate(); advanceUntilIdle(); deletionReady(model.deletion)
            val month = YearMonth.of(2025, 1); model.jumpToMonth(month)!!.join(); deletionReady(model.deletion)
            val reads = fixture.timelineCalls.size
            model.deletion.prepare(model.state.value.items.first())!!.join(); model.deletion.confirm()!!.join()
            assertEquals(month, model.state.value.selectedMonth); assertEquals(reads, fixture.timelineCalls.size)
            assertEquals(listOf(2L), model.state.value.items.map { it.id.itemId })
            model.loadMore()!!.join()
            assertEquals(1, fixture.pageCalls.last().second); assertEquals(listOf(2L, 3L), model.state.value.items.map { it.id.itemId })
            assertEquals(month, model.state.value.selectedMonth); assertEquals(reads, fixture.timelineCalls.size)
        }
    }
    @Test fun `个人原件完成不删除共享同编号照片也不切换当前来源`() = runTest {
        val fixture = Fixture().apply { canDeleteOriginals = true; spaces = SynologyPhotoSpace.entries; deletion = { SynologyPhotoDeletionPhase.CONFIRMED } }
        val owner = WorkspaceOwner(fixture.profileId, "space", "session")
        SynologyPhotosModel(fixture, this, pageSize = 2, uploadOwner = owner, deletionStore = SynologyPhotoDeletionStore(MemoryPreferences())).use { model ->
            model.activate(); advanceUntilIdle(); deletionReady(model.deletion)
            model.selectSpace(SynologyPhotoSpace.SHARED); advanceUntilIdle(); deletionReady(model.deletion)
            val shared = model.state.value.items
            model.deletion.prepare(photo(1))!!.join(); model.deletion.confirm()!!.join()
            assertEquals(shared, model.state.value.items)
            assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space)
        }
    }

    private suspend fun deletionReady(model: SynologyPhotoDeletionModel) = withContext(Dispatchers.Default) {
        withTimeout(5_000) { while (model.state.value.checking || model.state.value.recovering) delay(2) }
    }

    private companion object {
        fun photo(id: Long) = SynologyPhoto(SynologyPhotoId("profile-a", SynologyPhotoSpace.PERSONAL, id), "sample-$id.heic", 4,
            1735689600.0, 1735776000.0, 5, "photo", SynologyPhotoThumbnail(id + 1000, "revision"))
    }
}
