package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.time.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoSharedSettingsModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "shared-model"
        override val canEditPhotos = true
        override fun canManageSettings(kind: SynologyPhotoSettingsKind) = kind == SynologyPhotoSettingsKind.SHARED
        var value = SynologyPhotoSharedSettings(profileId, 41, true, true, SynologyPhotoSharedSettings.Role.MANAGEMENT, null,
            mapOf(SynologyPhotoSharedSetting.PEOPLE to true, SynologyPhotoSharedSetting.PUBLIC_ROOT to false), mapOf(SynologyPhotoSharedSetting.PEOPLE to true))
        var appliedValue: ((SynologyPhotoSharedSettings) -> SynologyPhotoSharedSettings) = { it }
        var pending = false; var readFailure = false; var writes = 0; var reviews = 0; var categoryFailure = false
        var beforeRead: suspend () -> Unit = {}; var beforeWrite: suspend () -> Unit = {}
        override suspend fun photoEditIdentity() = 41L
        override suspend fun photoSettings(kind: SynologyPhotoSettingsKind): SynologyPhotoSettings {
            beforeRead(); if (readFailure) throw IOException("Synthetic read"); return value
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) = Unit
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); beforeWrite(); writes++
            if (!pending) value = appliedValue(checkpoint.settings!!.desired as SynologyPhotoSharedSettings)
            return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED,
                settings = checkpoint.settings!!.copy(attempted = true)).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; if (!pending) value = appliedValue(checkpoint.settings!!.desired as SynologyPhotoSharedSettings)
            return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED).also(save)
        }
        override suspend fun access() = SynologyPhotoAccess(buildList { if (value.personalEnabled) add(SynologyPhotoSpace.PERSONAL); if (value.canAccess) add(SynologyPhotoSpace.SHARED) }, "synthetic", value.canAccess)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 1))
        val photo = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 100,
            Instant.parse("2020-03-01T12:00:00Z").epochSecond.toDouble(), 1.0, 9, "photo")
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) =
            SynologyPhotoPage(if (offset == 0) listOf(photo.copy(id = photo.id.copy(space = space))) else emptyList(), offset, 1, false)
        override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
        override suspend fun categories(space: SynologyPhotoSpace): Set<SynologyPhotoCategory> {
            if (categoryFailure) throw IOException("Synthetic categories")
            return if (space == SynologyPhotoSpace.PERSONAL || value.values[SynologyPhotoSharedSetting.PEOPLE] == true) setOf(SynologyPhotoCategory.PEOPLE) else emptySet()
        }
        override suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int, space: SynologyPhotoSpace) = emptyList<SynologyPhotoCollection>()
    }
    private class Fixture {
        val api = Api(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session"); val prefs = MemoryPreferences(); val store = SynologyPhotoAlbumStore(prefs)
        val applied = mutableListOf<SynologyPhotoSettings>(); var before: suspend () -> Unit = {}
        fun model() = SynologyPhotoSettingsModel(api, scope, store, owner, {}, { true }, { before() }, { applied += it })
        val model = model()
        suspend fun open() { model.open(SynologyPhotoSettingsKind.SHARED); await { !model.state.value.loading } }
        fun root() = SynologyPhotosModel(api, scope, zone = ZoneOffset.UTC, uploadOwner = owner, albumStore = store, editStore = SynologyPhotoEditStore(MemoryPreferences()))
    }
    @Test fun `启停固定原快照确认取消不改变草稿也不写入`() = runBlocking { fixture { f ->
        f.open(); val draft = f.api.value.copy(values = f.api.value.values + (SynologyPhotoSharedSetting.PEOPLE to false))
        f.model.edit(draft); f.model.changeSharedEnabled(); val confirmation = f.model.state.value.confirmation!!
        assertEquals(f.api.value, confirmation.original); assertEquals(f.api.value.copy(enabled = false), confirmation.desired)
        f.model.cancelConfirmation(); assertNull(f.model.confirm()); assertEquals(draft, f.model.state.value.desired); assertEquals(0, f.api.writes)
        f.model.changeSharedEnabled(); f.model.confirm()!!.join(); assertEquals(1, f.api.writes); assertFalse(f.api.value.enabled)
        assertEquals(true, f.api.value.values[SynologyPhotoSharedSetting.PEOPLE])
    } }
    @Test fun `普通识别直接保存公开权限变更需要确认且最后图库不可停用`() = runBlocking { fixture { f ->
        f.open(); f.model.edit(f.api.value.copy(values = f.api.value.values + (SynologyPhotoSharedSetting.PEOPLE to false)))
        f.model.save()!!.join(); assertNull(f.model.state.value.confirmation); assertEquals(1, f.api.writes)
        f.open(); f.model.edit(f.api.value.copy(values = f.api.value.values + (SynologyPhotoSharedSetting.PUBLIC_ROOT to true)))
        assertNull(f.model.save()); assertNotNull(f.model.state.value.confirmation); f.model.confirm()!!.join(); assertEquals(2, f.api.writes)
        f.api.value = f.api.value.copy(personalEnabled = false); f.open(); f.model.changeSharedEnabled(); assertNull(f.model.state.value.confirmation)
    } }
    @Test fun `启停回读应用真实默认值而非旧草稿`() = runBlocking { fixture { f ->
        f.api.value = f.api.value.copy(enabled = false)
        f.api.appliedValue = { it.copy(values = it.values + (SynologyPhotoSharedSetting.PEOPLE to false)) }
        f.open(); f.model.changeSharedEnabled(); f.model.confirm()!!.join()
        assertEquals(f.api.value, f.applied.last()); assertTrue((f.applied.last() as SynologyPhotoSharedSettings).enabled)
        assertEquals(false, (f.applied.last() as SynologyPhotoSharedSettings).values[SynologyPhotoSharedSetting.PEOPLE])
    } }
    @Test fun `保存中双击关闭和未知冷恢复不重新发送`() = runBlocking { fixture { f ->
        val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.pending = true; f.api.beforeWrite = { reached.complete(Unit); release.await() }
        f.open(); f.model.changeSharedEnabled(); val job = f.model.confirm()!!; reached.await()
        assertNull(f.model.confirm()); assertNull(f.model.save()); f.model.dismiss(); release.complete(Unit); job.join(); assertEquals(1, f.api.writes)
        val cold = f.model(); try {
            cold.showRecords(); await { cold.state.value.records.isNotEmpty() }; val id = cold.state.value.records.single().id
            cold.resume(id)!!.join(); assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
            cold.discard(id)!!.join(); assertNotNull(cold.state.value.error)
            f.api.pending = false; cold.resume(id)!!.join(); assertEquals(1, f.api.writes); assertTrue(cold.state.value.records.single().checkpoint.finished)
            cold.discard(id)!!.join(); assertTrue(f.store.records(f.owner, 41).isEmpty())
        } finally { cold.close() }
    } }
    @Test fun `成功后的真实设置读取结束前保持互斥`() = runBlocking { fixture { f ->
        f.open(); val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeRead = { reached.complete(Unit); release.await() }
        f.model.changeSharedEnabled(); val job = f.model.confirm()!!; reached.await()
        assertTrue(f.model.state.value.working); assertNull(f.model.save())
        try { f.model.requireNoPending(); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.BUSY, error.problem) }
        release.complete(Unit); job.join(); assertFalse(f.model.state.value.working); assertEquals(1, f.api.writes)
    } }
    @Test fun `读取错误重试迟到读取关闭和其他未决操作不产生写入`() = runBlocking { fixture { f ->
        f.api.readFailure = true; f.open(); assertNotNull(f.model.state.value.error); assertNull(f.model.state.value.desired)
        f.api.readFailure = false; f.model.load()!!.join(); f.before = { throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING) }
        f.model.changeSharedEnabled(); f.model.confirm()!!.join(); assertNotNull(f.model.state.value.error); assertEquals(0, f.api.writes)
        assertTrue(f.store.records(f.owner, 41).isEmpty())
        val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.model.dismiss(); f.api.beforeRead = { reached.complete(Unit); withContext(NonCancellable) { release.await() } }
        f.model.open(SynologyPhotoSettingsKind.SHARED); reached.await(); f.model.dismiss(); release.complete(Unit); delay(30)
        assertFalse(f.model.state.value.visible); assertNull(f.model.state.value.desired)
    } }
    @Test fun `共享设置保存保留个人历史月份和照片选择`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.jumpToMonth(YearMonth.of(2020, 3))!!.join()
            root.edits!!.selectMode(true); root.edits.toggle(f.api.photo)
            val before = root.state.value; val selected = root.edits.state.value.selected; val settings = root.settings!!
            settings.open(SynologyPhotoSettingsKind.SHARED); await { !settings.state.value.loading }; settings.changeSharedEnabled(); settings.confirm()!!.join()
            assertEquals(before.navigation, root.state.value.navigation); assertEquals(before.selectedMonth, root.state.value.selectedMonth)
            assertEquals(before.items, root.state.value.items); assertEquals(selected, root.edits.state.value.selected)
            assertFalse(SynologyPhotoSpace.SHARED in root.state.value.access!!.spaces)
        } finally { root.close() }
    } }
    @Test fun `停用当前共享来源离开并清除旧来源选择`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.selectSpace(SynologyPhotoSpace.SHARED); await { !root.state.value.loading }
            root.edits!!.selectMode(true); root.edits.toggle(root.state.value.items.single())
            val settings = root.settings!!; settings.open(SynologyPhotoSettingsKind.SHARED); await { !settings.state.value.loading }
            settings.changeSharedEnabled(); settings.confirm()!!.join(); await { !root.state.value.loading }
            assertEquals(SynologyPhotoSpace.PERSONAL, root.state.value.navigation.space); assertTrue(root.edits.state.value.selected.isEmpty())
            assertFalse(SynologyPhotoSpace.SHARED in root.state.value.access!!.spaces)
        } finally { root.close() }
    } }
    @Test fun `关闭当前共享分类回相册首页且不影响个人分类`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) fixture { f ->
            val root = f.root(); try {
                root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.selectSpace(space); await { !root.state.value.loading }
                root.selectSection(SynologyPhotosSection.ALBUMS); await { !root.state.value.loading }; root.openCategory(SynologyPhotoCategory.PEOPLE); await { !root.state.value.loading }
                val settings = root.settings!!; settings.open(SynologyPhotoSettingsKind.SHARED); await { !settings.state.value.loading }
                settings.edit(f.api.value.copy(values = f.api.value.values + (SynologyPhotoSharedSetting.PEOPLE to false))); settings.save()!!.join(); await { !root.state.value.loading }
                assertEquals(if (space == SynologyPhotoSpace.SHARED) null else SynologyPhotoCategory.PEOPLE, root.state.value.navigation.category)
            } finally { root.close() }
        }
    }
    @Test fun `共享角色改为普通访问退出仅管理者可见分类`() {
        val f = Fixture(); try {
            val state = SynologyPhotosState(access = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true),
                navigation = SynologyPhotoNavigation(space = SynologyPhotoSpace.SHARED, section = SynologyPhotosSection.ALBUMS, category = SynologyPhotoCategory.PEOPLE),
                categories = setOf(SynologyPhotoCategory.PEOPLE))
            val updated = state.applyingPhotoSettings(f.api.value.copy(role = SynologyPhotoSharedSettings.Role.ENTRY))
            assertNull(updated.navigation.category); assertFalse(updated.access!!.canManageSharedSpace); assertTrue(updated.categories.isEmpty())
        } finally { f.model.close(); f.scope.cancel() }
    }
    @Test fun `共享设置存储固定管理员值及单向尝试记录旧记录可读`() {
        val f = Fixture(); try {
            val original = f.api.value
            val row = SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = f.owner.profileId, userId = 41,
                action = SynologyPhotoAlbumAction.SETTINGS, settings = SynologyPhotoSettingsCheckpoint(original, original.copy(enabled = false))))
            f.store.begin(row); assertEquals(row, SynologyPhotoAlbumStore(f.prefs).records(f.owner, 41).single())
            val attempted = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, settings = row.checkpoint.settings!!.copy(attempted = true))
            f.store.save(row.id, f.owner, 41, attempted)
            val cold = SynologyPhotoAlbumStore(f.prefs).records(f.owner.copy(sessionGeneration = "new"), 41).single()
            assertEquals(SynologyPhotoAlbumPhase.PENDING, cold.checkpoint.phase)
            try { f.store.save(row.id, f.owner, 41, cold.checkpoint.copy(settings = cold.checkpoint.settings!!.copy(attempted = false))); fail() } catch (_: SynologyPhotoAlbumFailure) {}
            assertTrue(f.store.records(f.owner.copy(identityRevision = "new"), 41).isEmpty())
            assertTrue(f.store.records(f.owner, 42).isEmpty())
        } finally { f.model.close(); f.scope.cancel() }
    }
    companion object {
        private suspend fun await(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(5) } }
        private suspend fun fixture(block: suspend (Fixture) -> Unit) { val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.coroutineContext[Job]!!.cancelAndJoin() } }
    }
}
