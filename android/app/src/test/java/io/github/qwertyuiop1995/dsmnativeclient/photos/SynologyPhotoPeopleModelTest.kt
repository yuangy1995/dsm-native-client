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

class SynologyPhotoPeopleModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "people-model-${UUID.randomUUID()}"
        override val canEditPhotos = true; override val canManageAlbums = true
        @Volatile var enabled = true; @Volatile var identity = 41L; @Volatile var pending = false; @Volatile var rejected = false
        @Volatile var readError = false; @Volatile var prepareError = false
        var beforeRead: suspend () -> Unit = {}; var beforeWrite: suspend () -> Unit = {}; var beforePrepare: suspend () -> Unit = {}
        val writes = CopyOnWriteArrayList<SynologyPhotoAlbumCheckpoint>(); val reviews = CopyOnWriteArrayList<String>(); val photoReads = CopyOnWriteArrayList<SynologyPhotoQuery>()
        val people = CopyOnWriteArrayList((1L..3L).map { SynologyPhotoCollection(it, "Synthetic $it", count = 1, personVisible = it != 3L) })
        override fun canManagePeople(space: SynologyPhotoSpace, merging: Boolean) = enabled
        override fun canManagePersonFaces(space: SynologyPhotoSpace) = enabled
        override suspend fun personFaces(personId: Long, photos: List<SynologyPhoto>) = photos.flatMap { p ->
            listOf(SynologyPhotoPersonFace(p.id.itemId * 2, personId, p.id, "synthetic"), SynologyPhotoPersonFace(p.id.itemId * 2 + 1, personId, p.id, "synthetic"))
        }
        override suspend fun faceThumbnail(face: SynologyPhotoPersonFace) = byteArrayOf(1, 2, 3)
        override suspend fun preparePersonFaces(action: SynologyPhotoAlbumAction, original: SynologyPhotoPersonSnapshot,
            photos: List<SynologyPhoto>, faces: List<SynologyPhotoPersonFace>, target: SynologyPhotoPersonSnapshot?, name: String?): SynologyPhotoAlbumCheckpoint {
            beforePrepare(); if (prepareError) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
            return SynologyPhotoAlbumCheckpoint(profileId = profileId, userId = identity, action = action, targets = photos.map(::SynologyPhotoEditTarget),
                people = SynologyPhotoPeopleCheckpoint(listOfNotNull(original, target), name = name, faces = SynologyPhotoPersonFacesCheckpoint(faces.map { it.snapshot() })))
        }
        override suspend fun personThumbnail(person: SynologyPhotoCollection) = byteArrayOf(1, 2, 3)
        override suspend fun photoEditIdentity() = identity
        override suspend fun managementPeople(space: SynologyPhotoSpace, includingHidden: Boolean): List<SynologyPhotoCollection> {
            beforeRead(); if (readError) throw IOException("Synthetic read")
            return people.filter { includingHidden || it.personVisible == true }.map { it.copy(space = space) }
        }
        override suspend fun preparePeopleChange(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoPersonSnapshot>, name: String?, visible: Boolean?): SynologyPhotoAlbumCheckpoint {
            beforePrepare(); if (prepareError) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
            return SynologyPhotoAlbumCheckpoint(profileId = profileId, userId = identity, action = action,
                people = SynologyPhotoPeopleCheckpoint(originals, name, visible, setOf(51L, 52L).takeIf { action == SynologyPhotoAlbumAction.MERGE_PEOPLE }))
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) {
            if (prepareError) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
        }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            var row = checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); save(row)
            row = row.copy(people = row.people!!.copy(attempted = true)); save(row); writes += row; beforeWrite()
            row = row.copy(people = row.people!!.copy(acknowledged = !rejected, rejected = rejected,
                nameReceipt = !rejected && row.action == SynologyPhotoAlbumAction.RENAME_PERSON,
                faces = row.people!!.faces?.let { faces -> if (rejected) faces else when (row.action) {
                    SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES -> faces.copy(targetReceipt = row.people!!.originals.getOrNull(1)?.id ?: 90)
                    SynologyPhotoAlbumAction.COVER_PERSON -> faces.copy(coverReceipt = 701)
                    else -> faces
                } }))
            return finish(row).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews += checkpoint.operationId; return finish(checkpoint).also(save)
        }
        private fun finish(row: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumCheckpoint {
            if (row.people!!.rejected) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
            if (pending) return row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
            val value = row.people; val ids = value.originals.map { it.id }.toSet()
            val removed = when (row.action) {
                SynologyPhotoAlbumAction.MERGE_PEOPLE -> ids - value.originals.first().id
                SynologyPhotoAlbumAction.RENAME_PERSON -> ids.takeIf { value.name == "" && value.originals.single().count!! < 2 }.orEmpty()
                else -> emptySet()
            }
            val result = row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, people = value.copy(completedIds = ids, removedIds = removed,
                faces = value.faces?.let { faces -> faces.copy(removedPhotoIds = row.targets.filter { target ->
                    faces.selected.count { it.photoId == target.id } == 2
                }.map { it.id.itemId }.toSet()) }))
            val updated = applyPhotoPeopleResult(people.map { it.copy(space = value.space) }, result)
            people.clear(); people.addAll(updated.map { it.copy(space = SynologyPhotoSpace.PERSONAL) })
            return result
        }
        val photo = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 100,
            Instant.parse("2020-03-01T12:00:00Z").epochSecond.toDouble(), 1.0, 9, "photo")
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 1))
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
            photoReads += query
            return SynologyPhotoPage(if (offset == 0) listOf(photo.copy(id = photo.id.copy(space = space))) else emptyList(), offset, if (offset == 0) 1 else offset, false)
        }
        override suspend fun categories(space: SynologyPhotoSpace) = setOf(SynologyPhotoCategory.PEOPLE)
        override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
        override suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int, space: SynologyPhotoSpace) =
            managementPeople(space, false).drop(offset).take(limit)
    }
    private class Fixture {
        val api = Api(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session"); val store = SynologyPhotoAlbumStore(MemoryPreferences())
        val thumbnails = SynologyPhotoThumbnailStore(scope); val ticks = Channel<Unit>(Channel.UNLIMITED); val pauses = CopyOnWriteArrayList<Long>()
        val applied = CopyOnWriteArrayList<SynologyPhotoAlbumCheckpoint>()
        var current = true; var canStart = true; var before: suspend () -> Unit = {}
        fun model() = SynologyPhotoPeopleModel(api, scope, store, owner, { if (!current) throw CancellationException() }, thumbnails,
            { canStart }, { before() }, { row, _ -> applied += row }, pause = { pauses += it; ticks.receive() })
        val model = model()
        suspend fun open(action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.RENAME_PERSON, target: SynologyPhotoCollection? = api.people.first()) {
            model.open(action, target?.space ?: SynologyPhotoSpace.PERSONAL, target); await { !model.state.value.loading }
        }
        fun root() = SynologyPhotosModel(api, scope, zone = ZoneOffset.UTC, uploadOwner = owner, albumStore = store,
            editStore = SynologyPhotoEditStore(MemoryPreferences()))
    }
    @Test fun `普通改名直接保存没有额外确认且完成后不能重复保存`() = runBlocking { fixture { f ->
        f.open(); f.model.name(" New name "); assertTrue(f.model.state.value.canSave)
        f.model.save()!!.join(); assertEquals(1, f.api.writes.size); assertNull(f.model.state.value.confirmation)
        assertEquals("New name", f.api.writes.single().people!!.name); assertEquals("New name", f.model.state.value.target!!.name)
        assertFalse(f.model.state.value.canSave); assertNull(f.model.save()); assertEquals(1, f.applied.size)
    } }
    @Test fun `清空小组需具体确认取消零写大组直接保存`() = runBlocking { fixture { f ->
        f.open(); f.model.name(""); f.model.save()!!.join(); assertNotNull(f.model.state.value.confirmation); assertTrue(f.api.writes.isEmpty())
        f.model.cancelConfirmation(); assertTrue(f.api.writes.isEmpty()); f.model.save()!!.join(); f.model.confirm()!!.join()
        assertEquals(setOf(1L), f.model.state.value.records.single().checkpoint.people!!.removedIds)
        assertNull(f.model.state.value.target); assertFalse(f.model.state.value.canSave)
        f.model.dismiss(); f.api.people[0] = f.api.people[0].copy(count = 2); f.open(); f.model.name(""); f.model.save()!!.join()
        assertNull(f.model.state.value.confirmation); assertEquals(2, f.api.writes.size)
    } }
    @Test fun `合并固定目标选其他分组风险确认期间名称选择不可修改`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoAlbumAction.MERGE_PEOPLE); assertEquals(listOf(2L), f.model.state.value.choices.map { it.id })
        f.model.toggle(1); assertTrue(f.model.state.value.selected.isEmpty()); f.model.toggle(2); f.model.name("Merged")
        f.model.save()!!.join(); val frozen = f.model.state.value.confirmation!!; assertTrue(f.api.writes.isEmpty())
        f.model.name("Changed"); f.model.toggle(2); assertEquals(frozen, f.model.state.value.confirmation)
        f.model.confirm()!!.join(); assertEquals(listOf(1L, 2L), f.api.writes.single().people!!.originals.map { it.id })
        assertEquals("Merged", f.model.state.value.target!!.name); assertEquals(2, f.model.state.value.target!!.count)
        assertEquals(listOf(1L), f.model.state.value.people.map { it.id }); assertFalse(f.model.state.value.canSave)
    } }
    @Test fun `搜索和同一显示目标只允许选择有变化的人物且切换目标清空选择`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoAlbumAction.SHOW_PEOPLE, null); assertEquals(3, f.model.state.value.people.size)
        f.model.toggle(3); assertTrue(f.model.state.value.selected.isEmpty()); f.model.toggle(1); f.model.toggle(2)
        f.model.search("2"); assertEquals(listOf(2L), f.model.state.value.filtered.map { it.id }); assertEquals(2, f.model.state.value.selected.size)
        f.model.visibility(true); assertTrue(f.model.state.value.selected.isEmpty()); f.model.toggle(3)
        f.model.save()!!.join(); assertEquals(listOf(3L), f.api.writes.single().people!!.originals.map { it.id }); assertEquals(true, f.api.writes.single().people!!.visible)
        assertEquals("2", f.model.state.value.query); assertNull(f.model.state.value.confirmation)
    } }
    @Test fun `显示选择100个与合并99个来源上限都可取消已选`() = runBlocking { fixture { f ->
        f.api.people.clear(); f.api.people.addAll((1L..130L).map { SynologyPhotoCollection(it, "Synthetic $it", count = 1, personVisible = true) })
        f.open(SynologyPhotoAlbumAction.SHOW_PEOPLE, null); (1L..130L).forEach(f.model::toggle)
        assertEquals(100, f.model.state.value.selected.size); f.model.toggle(1); f.model.toggle(101); assertEquals(100, f.model.state.value.selected.size)
        f.model.dismiss(); f.open(SynologyPhotoAlbumAction.MERGE_PEOPLE); (1L..130L).forEach(f.model::toggle)
        assertEquals(99, f.model.state.value.selected.size); assertFalse(1L in f.model.state.value.selected)
    } }
    @Test fun `错误空列表与搜索空不冒充正在加载重新读取可恢复`() = runBlocking { fixture { f ->
        f.api.readError = true; f.open(); assertFalse(f.model.state.value.loaded); assertNotNull(f.model.state.value.error); assertFalse(f.model.state.value.canSave)
        f.api.readError = false; f.model.load()!!.join(); assertTrue(f.model.state.value.loaded); assertNull(f.model.state.value.error)
        f.model.dismiss(); f.api.people.clear(); f.open(SynologyPhotoAlbumAction.SHOW_PEOPLE, null)
        assertTrue(f.model.state.value.loaded); assertTrue(f.model.state.value.people.isEmpty()); assertFalse(f.model.state.value.canSave)
        f.api.people += SynologyPhotoCollection(9, "Synthetic", count = 1, personVisible = true); f.model.load()!!.join(); f.model.search("Absent")
        assertTrue(f.model.state.value.filtered.isEmpty()); assertFalse(f.model.state.value.people.isEmpty()); assertTrue(f.api.writes.isEmpty())
    } }
    @Test fun `刷新失败重试保留已输入名称与合并选择`() = runBlocking { fixture { f ->
        for (action in listOf(SynologyPhotoAlbumAction.RENAME_PERSON, SynologyPhotoAlbumAction.MERGE_PEOPLE)) {
            f.open(action); f.model.name("Unsaved name")
            if (action == SynologyPhotoAlbumAction.MERGE_PEOPLE) f.model.toggle(2)
            val selected = f.model.state.value.selected
            f.api.readError = true; f.model.load()!!.join()
            assertFalse(f.model.state.value.loaded); assertFalse(f.model.state.value.canSave)
            assertEquals("Unsaved name", f.model.state.value.name)
            f.api.readError = false; f.model.load()!!.join()
            assertTrue(f.model.state.value.loaded); assertNull(f.model.state.value.error)
            assertEquals("Unsaved name", f.model.state.value.name); assertEquals(selected, f.model.state.value.selected)
            assertTrue(f.model.state.value.canSave); assertTrue(f.api.writes.isEmpty()); f.model.dismiss()
        }
    } }
    @Test fun `预检失败保存失败与权限关闭均不发写且保留用户名称`() = runBlocking { fixture { f ->
        f.open(); f.model.name("New"); f.api.prepareError = true; f.model.save()!!.join()
        assertTrue(f.api.writes.isEmpty()); assertNotNull(f.model.state.value.error); assertEquals("New", f.model.state.value.name)
        f.api.prepareError = false; f.before = { throw IOException("Synthetic before write") }; f.model.save()!!.join(); assertTrue(f.api.writes.isEmpty())
        f.model.dismiss(); f.api.enabled = false; f.open(); assertFalse(f.model.state.value.visible)
    } }
    @Test fun `按钮重复点击和确认重复点击不会写两次`() = runBlocking { fixture { f ->
        val gate = CompletableDeferred<Unit>(); f.api.beforeWrite = { gate.await() }; f.open(); f.model.name("New")
        val worker = f.model.save()!!; await { f.api.writes.size == 1 }; assertNull(f.model.save()); assertNull(f.model.confirm())
        f.model.name("Changed"); f.model.open(SynologyPhotoAlbumAction.SHOW_PEOPLE, SynologyPhotoSpace.SHARED)
        gate.complete(Unit); worker.join(); assertEquals(1, f.api.writes.size); assertEquals("New", f.api.writes.single().people!!.name)
    } }
    @Test fun `确认前目标变化重新预检拒绝零写`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoAlbumAction.MERGE_PEOPLE); f.model.toggle(2); f.model.save()!!.join(); f.api.prepareError = true
        f.model.confirm()!!.join(); assertTrue(f.api.writes.isEmpty()); assertNotNull(f.model.state.value.error)
    } }
    @Test fun `已缓存的人物封面仍检查当前账号授权`() = runBlocking { fixture { f ->
        val person = f.api.people.first(); assertArrayEquals(byteArrayOf(1, 2, 3), f.model.thumbnail(person)); assertEquals(3, f.thumbnails.cost())
        f.current = false
        try { f.model.thumbnail(person); fail("Expected owner rejection") } catch (_: CancellationException) {}
    } }
    @Test fun `关闭页面与授权失效使迟到读取不能写回界面`() = runBlocking { fixture { f ->
        val gate = CompletableDeferred<Unit>(); val entered = CompletableDeferred<Unit>(); f.api.beforeRead = { entered.complete(Unit); gate.await() }
        f.model.open(SynologyPhotoAlbumAction.SHOW_PEOPLE, SynologyPhotoSpace.PERSONAL); entered.await(); f.model.dismiss(); gate.complete(Unit)
        delay(20); assertFalse(f.model.state.value.visible); assertTrue(f.model.state.value.people.isEmpty())
        f.api.beforeRead = {}; f.current = false; f.open(); assertFalse(f.model.state.value.loaded); assertTrue(f.api.writes.isEmpty())
    } }
    @Test fun `离开期间尚未完成的预检不会在后台创建写操作`() = runBlocking { fixture { f ->
        f.open(); f.model.name("New"); val entered = CompletableDeferred<Unit>(); val gate = CompletableDeferred<Unit>()
        f.api.beforePrepare = { entered.complete(Unit); gate.await() }; val worker = f.model.save()!!; entered.await(); f.model.deactivate(); gate.complete(Unit); worker.join()
        assertTrue(f.api.writes.isEmpty()); assertTrue(f.store.records(f.owner, 41).isEmpty()); assertFalse(f.model.state.value.working)
    } }
    @Test fun `未知结果冷恢复仅review且不自动保存同名修改`() = runBlocking { fixture { f ->
        f.open(); f.model.name("New"); f.api.pending = true; f.model.save()!!.join(); val id = f.model.state.value.records.single().id
        assertTrue(f.model.state.value.pending); assertFalse(f.model.state.value.canSave); f.model.dismiss()
        val cold = f.model(); try {
            cold.open(SynologyPhotoAlbumAction.SHOW_PEOPLE, SynologyPhotoSpace.PERSONAL); await { !cold.state.value.loading }
            cold.resume(id)!!.join(); assertEquals(1, f.api.reviews.size); assertEquals(1, f.api.writes.size)
            f.api.pending = false; cold.resume(id)!!.join(); assertFalse(cold.state.value.pending); assertEquals(1, f.api.writes.size)
        } finally { cold.close() }
    } }
    @Test fun `自动恢复只在可见且活动时轮询并在完成后停止`() = runBlocking { fixture { f ->
        f.model.activate(); f.open(); f.model.name("New"); f.api.pending = true; f.model.save()!!.join(); await { f.pauses.isNotEmpty() }
        assertEquals(15_000L, f.pauses.first()); f.ticks.send(Unit); await { f.api.reviews.size == 1 }; await { f.pauses.size >= 2 }
        f.model.deactivate(); f.ticks.send(Unit); delay(30); assertEquals(1, f.api.reviews.size)
        f.api.pending = false; f.model.activate(); await { !f.model.state.value.loading }; f.ticks.send(Unit); await { !f.model.state.value.pending }
        val reads = f.api.reviews.size; f.ticks.send(Unit); delay(30); assertEquals(reads, f.api.reviews.size); assertEquals(1, f.api.writes.size)
    } }
    @Test fun `仅已完成或未提交记录能移除且明确拒绝可以重新保存`() = runBlocking { fixture { f ->
        f.open(); f.model.name("New"); f.api.pending = true; f.model.save()!!.join(); val record = f.model.state.value.records.single()
        assertNull(f.model.discard(record.id)); f.api.pending = false; f.model.resume(record.id)!!.join(); f.model.discard(record.id)!!.join()
        assertTrue(f.model.state.value.records.isEmpty())
        f.model.name("Another"); f.api.rejected = true; f.model.save()!!.join(); assertTrue(f.model.state.value.canSave)
    } }
    @Test fun `未决相同人物阻止新意图不同人物可以编辑`() = runBlocking { fixture { f ->
        f.open(); f.model.name("New"); f.api.pending = true; f.model.save()!!.join(); f.model.dismiss()
        f.open(target = f.api.people[1]); f.model.name("Other"); assertTrue(f.model.state.value.canSave); f.model.save()!!.join(); assertEquals(2, f.api.writes.size)
    } }
    @Test fun `根模型显示修改保留月份照片选择导航不重新读取照片`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.jumpToMonth(YearMonth.of(2020, 3))!!.join()
            root.edits!!.selectMode(true); root.edits.toggle(root.state.value.items.single())
            val old = root.state.value; val selected = root.edits.state.value.selected; val reads = f.api.photoReads.size
            val model = root.people!!; model.open(SynologyPhotoAlbumAction.SHOW_PEOPLE, SynologyPhotoSpace.PERSONAL); await { !model.state.value.loading }
            model.toggle(1); model.save()!!.join(); assertEquals(old, root.state.value); assertEquals(selected, root.edits.state.value.selected); assertEquals(reads, f.api.photoReads.size)
        } finally { root.close() }
    } }
    @Test fun `根人物列表局部刷新合并和隐藏结果不退回时间轴`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.selectSection(SynologyPhotosSection.ALBUMS)
            await { !root.state.value.loading }; root.openCategory(SynologyPhotoCategory.PEOPLE); await { !root.state.value.loading }
            val navigation = root.state.value.navigation; val model = root.people!!
            model.open(SynologyPhotoAlbumAction.MERGE_PEOPLE, SynologyPhotoSpace.PERSONAL, root.state.value.collections.first()); await { !model.state.value.loading }
            model.toggle(2); model.name("Merged"); model.save()!!.join(); model.confirm()!!.join()
            assertEquals(navigation, root.state.value.navigation); assertEquals(listOf("Merged"), root.state.value.collections.map { it.name })
            assertFalse(root.state.value.hasMoreCollections)
        } finally { root.close() }
    } }
    @Test fun `局部应用只改命中来源并保留已打开小组照片与月份`() {
        val api = Api(); val person = api.people.first(); val value = SynologyPhotoPeopleCheckpoint(listOf(SynologyPhotoPersonSnapshot(person)), name = "",
            attempted = true, acknowledged = true, nameReceipt = true, completedIds = setOf(1), removedIds = setOf(1))
        val row = SynologyPhotoAlbumCheckpoint(profileId = api.profileId, userId = 41, action = SynologyPhotoAlbumAction.RENAME_PERSON,
            phase = SynologyPhotoAlbumPhase.COMPLETED, people = value)
        val old = SynologyPhotosState(navigation = SynologyPhotoNavigation(section = SynologyPhotosSection.ALBUMS, category = SynologyPhotoCategory.PEOPLE, categoryItem = person),
            items = listOf(api.photo), selectedMonth = YearMonth.of(2020, 3)); val state = MutableStateFlow(old)
        assertNull(applyPhotoPeopleChange(state, row, emptyList())); assertEquals("", state.value.navigation.categoryItem!!.name)
        assertEquals(old.items, state.value.items); assertEquals(old.selectedMonth, state.value.selectedMonth)
        state.value = old.copy(navigation = old.navigation.copy(space = SynologyPhotoSpace.SHARED)); val shared = state.value
        assertNull(applyPhotoPeopleChange(state, row, emptyList())); assertEquals(shared, state.value)
    }
    @Test fun `人脸打开固定照片与人物默认全选且拒绝混合相册和无权限`() = runBlocking { fixture { f ->
        val photos = listOf(f.api.photo, f.api.photo.copy(id = f.api.photo.id.copy(itemId = 52)))
        f.model.openFaces(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, f.api.people.first(), photos); await { !f.model.state.value.loading }
        assertEquals(photos, f.model.state.value.photos); assertEquals(setOf(102L, 103L, 104L, 105L), f.model.state.value.selectedFaces)
        assertTrue(f.model.state.value.canSave); f.model.dismiss()
        for (bad in listOf(photos.map { it.copy(albumContext = SynologyPhotoAlbumContext(9, 41)) }, photos + photos.first(), photos.map { it.copy(id = it.id.copy(space = SynologyPhotoSpace.SHARED)) })) {
            f.model.openFaces(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, f.api.people.first(), bad); assertFalse(f.model.state.value.visible)
        }
        f.api.enabled = false; f.model.openFaces(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, f.api.people.first(), photos); assertFalse(f.model.state.value.visible)
    } }
    @Test fun `人脸移出取消不写确认固定所选人脸且每个照片快照只存一次`() = runBlocking { fixture { f ->
        f.model.openFaces(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, f.api.people.first(), listOf(f.api.photo)); await { !f.model.state.value.loading }
        f.model.toggleFace(103); f.model.save()!!.join(); val confirmation = f.model.state.value.confirmation!!
        assertEquals(listOf(102L), confirmation.people!!.faces!!.selected.map { it.id }); assertEquals(1, confirmation.targets.size)
        f.model.toggleFace(103); assertEquals(setOf(102L), f.model.state.value.selectedFaces)
        f.model.cancelConfirmation(); assertTrue(f.api.writes.isEmpty()); f.model.save()!!.join(); f.model.confirm()!!.join()
        assertEquals(1, f.api.writes.size); assertTrue(f.model.state.value.selectedFaces.isEmpty()); assertFalse(f.model.state.value.canSave)
    } }
    @Test fun `归入新人物保留输入错误重试与已有目标名称沿用当前值`() = runBlocking { fixture { f ->
        f.model.openFaces(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, f.api.people.first(), listOf(f.api.photo)); await { !f.model.state.value.loading }
        f.model.name("New name"); f.model.toggleFace(103); f.api.readError = true; f.model.load()!!.join(); assertFalse(f.model.state.value.canSave)
        f.api.readError = false; f.model.load()!!.join(); assertEquals("New name", f.model.state.value.name); assertEquals(setOf(102L), f.model.state.value.selectedFaces)
        f.model.save()!!.join(); assertEquals("New name", f.model.state.value.confirmation!!.people!!.name); f.model.cancelConfirmation()
        f.model.destination(2); f.model.name("Should not rename existing"); f.model.save()!!.join()
        val row = f.model.state.value.confirmation!!; assertEquals(listOf(1L, 2L), row.people!!.originals.map { it.id }); assertEquals("Synthetic 2", row.people.name)
        f.model.confirm()!!.join(); assertEquals(1, f.api.writes.size)
    } }
    @Test fun `封面只有单张照片可提交且普通保存不追加确认`() = runBlocking { fixture { f ->
        val duplicate = f.api.photo.copy(id = f.api.photo.id.copy(itemId = 52))
        f.model.openFaces(SynologyPhotoAlbumAction.COVER_PERSON, f.api.people.first(), listOf(f.api.photo, duplicate)); assertFalse(f.model.state.value.visible)
        f.model.openFaces(SynologyPhotoAlbumAction.COVER_PERSON, f.api.people.first(), listOf(f.api.photo)); await { !f.model.state.value.loading }
        f.model.save()!!.join(); assertNull(f.model.state.value.confirmation); assertEquals(1, f.api.writes.size)
        assertEquals(701L, f.model.state.value.records.single().checkpoint.people!!.faces!!.coverReceipt)
        f.model.load()!!.join(); assertNull(f.model.state.value.error)
    } }
    @Test fun `人脸确认前权限变化保留选择且零写入`() = runBlocking { fixture { f ->
        f.model.openFaces(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, f.api.people.first(), listOf(f.api.photo)); await { !f.model.state.value.loading }
        f.model.save()!!.join(); f.api.prepareError = true; f.model.confirm()!!.join()
        assertTrue(f.api.writes.isEmpty()); assertEquals(setOf(102L, 103L), f.model.state.value.selectedFaces); assertNotNull(f.model.state.value.error)
    } }
    @Test fun `人脸未知冷恢复只读并保留未决人脸阻止重复保存`() = runBlocking { fixture { f ->
        f.model.openFaces(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, f.api.people.first(), listOf(f.api.photo)); await { !f.model.state.value.loading }
        f.model.name("New"); f.api.pending = true; f.model.save()!!.join(); f.model.confirm()!!.join()
        assertFalse(f.model.state.value.canSave); val id = f.model.state.value.records.single().id; f.model.dismiss()
        val cold = f.model(); try {
            cold.openFaces(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, f.api.people.first(), listOf(f.api.photo)); await { !cold.state.value.loading }
            assertFalse(cold.state.value.canSave); cold.resume(id)!!.join(); assertEquals(1, f.api.writes.size)
            f.api.pending = false; cold.resume(id)!!.join(); assertFalse(cold.state.value.pending); assertEquals(1, f.api.writes.size)
        } finally { cold.close() }
    } }
    @Test fun `根人物移出仅移走已无该人物的照片并保留月份和其他选择`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.selectSection(SynologyPhotosSection.ALBUMS); await { !root.state.value.loading }
            root.openCategory(SynologyPhotoCategory.PEOPLE); await { !root.state.value.loading }; root.openCollection(root.state.value.collections.first()); await { !root.state.value.loading }
            val original = root.state.value; val photo = original.items.single(); root.edits!!.selectMode(true); root.edits.toggle(photo)
            val model = root.people!!; model.openFaces(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, original.navigation.categoryItem!!, listOf(photo)); await { !model.state.value.loading }
            model.toggleFace(103); model.save()!!.join(); model.confirm()!!.join()
            assertEquals(original.items, root.state.value.items); assertEquals(listOf(photo), root.edits.state.value.selected)
            model.dismiss(); model.openFaces(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, original.navigation.categoryItem!!, listOf(photo)); await { !model.state.value.loading }
            model.save()!!.join(); model.confirm()!!.join()
            assertTrue(root.state.value.items.isEmpty()); assertTrue(root.edits.state.value.selected.isEmpty()); assertEquals(original.months, root.state.value.months)
            assertEquals(original.selectedMonth, root.state.value.selectedMonth)
            assertEquals(original.navigation.copy(categoryItem = original.navigation.categoryItem!!.copy(count = 0)), root.state.value.navigation)
        } finally { root.close() }
    } }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) { val f = Fixture(); try { withTimeout(10_000) { block(f) } } finally { f.model.close(); f.thumbnails.close(); f.scope.cancel() } }
    private companion object { suspend fun await(condition: () -> Boolean) { withTimeout(4_000) { while (!condition()) delay(5) } } }
}
