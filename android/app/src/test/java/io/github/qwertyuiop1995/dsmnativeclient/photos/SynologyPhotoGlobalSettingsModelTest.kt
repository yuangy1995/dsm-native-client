package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoGlobalSettingsCodec
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

class SynologyPhotoGlobalSettingsModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "global-model-${UUID.randomUUID()}"
        override val canEditPhotos = true
        override fun canManageSettings(kind: SynologyPhotoSettingsKind) = kind in setOf(SynologyPhotoSettingsKind.GLOBAL, SynologyPhotoSettingsKind.CACHE)
        var value = SynologyPhotoGlobalSettings(profileId, 41, SynologyPhotoGlobalSetting.entries.associateWith { true }, setOf("legacy"), true,
            SynologyPhotoRecognition.entries.associateWith { true }, SynologyPhotoRecognition.entries.associateWith { true }, true, true, SynologyPhotoSharedSettings.Role.MANAGEMENT)
        var cache = SynologyPhotoConversionCache(profileId, 41, 400, false)
        var cacheFailure = false; var settingsFailure = false; var pending = false; var partial = false; var writes = 0; var reviews = 0; var cacheReads = 0; var globalReads = 0
        var beforeRead: suspend (SynologyPhotoSettingsKind) -> Unit = {}; var beforeWrite: suspend () -> Unit = {}
        override suspend fun photoEditIdentity() = 41L
        override suspend fun photoSettings(kind: SynologyPhotoSettingsKind): SynologyPhotoSettings {
            beforeRead(kind)
            if (kind == SynologyPhotoSettingsKind.CACHE) { cacheReads++; if (cacheFailure) throw IOException("Synthetic cache"); return cache }
            globalReads++; if (settingsFailure) throw IOException("Synthetic global"); return value
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) = Unit
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); beforeWrite(); writes++
            val steps = SynologyPhotoGlobalSettingsCodec.steps(checkpoint.settings!!).map { it.kind }.toSet()
            val attempted = if (partial) setOf(steps.first()) else steps
            val progress = SynologyPhotoGlobalProgress(attempted, attempted, completed = if (pending) emptySet() else attempted)
            if (!pending) apply(checkpoint.settings.desired)
            return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else if (partial) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.COMPLETED,
                settings = checkpoint.settings.copy(attempted = true, rejected = partial && !pending, globalProgress = progress)).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; if (!pending) apply(checkpoint.settings!!.desired)
            val p = checkpoint.settings!!.globalProgress!!
            return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED,
                settings = checkpoint.settings.copy(globalProgress = p.copy(completed = if (pending) p.completed else p.attempted))).also(save)
        }
        private fun apply(desired: SynologyPhotoSettings) {
            when (desired) {
                is SynologyPhotoGlobalSettings -> value = if (partial) value.copy(values = desired.values) else desired
                is SynologyPhotoConversionCache -> cache = cache.copy(sizeBytes = 80)
                else -> error("Unexpected synthetic settings")
            }
        }
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true, supportsOriginalSizeJPEG = value.supportsOriginalJPEG)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 1))
        val photo = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 100, Instant.parse("2020-03-01T12:00:00Z").epochSecond.toDouble(), 1.0, 9, "photo")
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) =
            SynologyPhotoPage(if (offset == 0) listOf(photo.copy(id = photo.id.copy(space = space))) else emptyList(), offset, 1, false)
        override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
        override suspend fun categories(space: SynologyPhotoSpace) = if (value.values[SynologyPhotoGlobalSetting.PEOPLE] == true) setOf(SynologyPhotoCategory.PEOPLE) else emptySet()
        override suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int, space: SynologyPhotoSpace) = emptyList<SynologyPhotoCollection>()
    }
    private class Fixture {
        val api = Api(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session"); val preferences = MemoryPreferences(); val store = SynologyPhotoAlbumStore(preferences)
        val applied = CopyOnWriteArrayList<SynologyPhotoSettings>(); val pauses = CopyOnWriteArrayList<Long>(); val ticks = Channel<Unit>(Channel.UNLIMITED)
        fun model() = SynologyPhotoSettingsModel(api, scope, store, owner, {}, { true }, onApplied = { applied += it }, pause = { pauses += it; ticks.receive() })
        val model = model()
        suspend fun open() { model.open(SynologyPhotoSettingsKind.GLOBAL); await { !model.state.value.loading && !model.state.value.cacheLoading } }
        fun disablePeople() { model.edit(api.value.copy(values = api.value.values + (SynologyPhotoGlobalSetting.PEOPLE to false))) }
        fun root() = SynologyPhotosModel(api, scope, zone = ZoneOffset.UTC, uploadOwner = owner, albumStore = store, editStore = SynologyPhotoEditStore(MemoryPreferences()))
    }
    @Test fun `全局切换反悔恢复原来源值并按当前原值形成联动草稿`() = runBlocking { fixture { f ->
        f.open(); assertFalse(f.model.canSave); f.disablePeople()
        assertEquals(false, (f.model.state.value.desired as SynologyPhotoGlobalSettings).personalRecognition[SynologyPhotoRecognition.PEOPLE])
        f.model.edit((f.model.state.value.desired as SynologyPhotoGlobalSettings).copy(values = f.api.value.values))
        assertEquals(f.api.value, f.model.state.value.desired); assertFalse(f.model.canSave)
        f.api.value = f.api.value.copy(values = f.api.value.values + (SynologyPhotoGlobalSetting.PEOPLE to false)); f.open()
        assertTrue(f.model.canSave); assertEquals(false, (f.model.state.value.desired as SynologyPhotoGlobalSettings).sharedRecognition[SynologyPhotoRecognition.PEOPLE])
    } }
    @Test fun `缓存读取失败独立于表单重试实际读取且清理确认取消保留草稿`() = runBlocking { fixture { f ->
        f.api.cacheFailure = true; f.open(); assertNotNull(f.model.state.value.cacheError); assertNotNull(f.model.state.value.original)
        f.disablePeople(); assertTrue(f.model.canSave); f.model.clearCache(); assertNull(f.model.state.value.confirmation)
        f.api.cacheFailure = false; f.model.refreshCache()!!.join(); val desired = f.model.state.value.desired
        f.model.clearCache(); val confirmation = f.model.state.value.confirmation!!
        assertEquals(f.api.cache, confirmation.original); assertEquals(f.api.cache.copy(clearRequested = true), confirmation.desired)
        f.model.cancelConfirmation(); assertEquals(desired, f.model.state.value.desired); assertEquals(0, f.api.writes)
        f.model.clearCache(); f.model.confirm()!!.join(); assertEquals(1, f.api.writes); assertEquals(f.api.cache, f.applied.last())
        assertEquals(true, f.api.value.values[SynologyPhotoGlobalSetting.PEOPLE])
    } }
    @Test fun `全局修改一律具体确认取消零写入部分完成应用真实设置`() = runBlocking { fixture { f ->
        f.api.partial = true; f.open(); f.disablePeople(); assertNull(f.model.save()); assertNotNull(f.model.state.value.confirmation)
        f.model.cancelConfirmation(); assertNull(f.model.confirm()); assertEquals(0, f.api.writes)
        f.model.save(); f.model.confirm()!!.join(); val row = f.model.state.value.records.single().checkpoint
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertEquals(f.api.value, f.applied.last())
        assertEquals(true, (f.applied.last() as SynologyPhotoGlobalSettings).personalRecognition[SynologyPhotoRecognition.PEOPLE])
        assertEquals(false, (row.settings!!.desired as SynologyPhotoGlobalSettings).personalRecognition[SynologyPhotoRecognition.PEOPLE])
    } }
    @Test fun `成功或部分完成的实际读取结束前保持写入互斥`() = runBlocking { fixture { f ->
        f.api.partial = true; f.open(); f.disablePeople(); f.model.save()
        val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeRead = { if (it == SynologyPhotoSettingsKind.GLOBAL) { reached.complete(Unit); release.await() } }
        val saving = f.model.confirm()!!; reached.await(); assertTrue(f.model.state.value.working)
        assertNull(f.model.save()); f.model.clearCache(); assertNull(f.model.state.value.confirmation)
        try { f.model.requireNoPending(); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.BUSY, error.problem) }
        release.complete(Unit); saving.join(); assertFalse(f.model.state.value.working)
    } }
    @Test fun `未知保存关闭及重建存储后仅回读不重发`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(); f.disablePeople(); f.model.save(); f.model.confirm()!!.join(); f.model.dismiss()
        val cold = f.model(); try {
            cold.showRecords(); await { cold.state.value.records.isNotEmpty() }; val id = cold.state.value.records.single().id
            cold.resume(id)!!.join(); assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
            cold.discard(id)!!.join(); assertNotNull(cold.state.value.error)
            f.api.pending = false; cold.resume(id)!!.join(); assertTrue(cold.state.value.records.single().checkpoint.finished); assertEquals(1, f.api.writes)
        } finally { cold.close() }
    } }
    @Test fun `清理中五秒只读刷新离页停止返回恢复失败不覆盖全局草稿`() = runBlocking { fixture { f ->
        f.api.cache = f.api.cache.copy(clearing = true); f.open(); f.disablePeople(); val desired = f.model.state.value.desired
        f.model.activate(); await { f.pauses.isNotEmpty() && !f.model.state.value.cacheLoading }; assertEquals(5_000L, f.pauses.last())
        val reads = f.api.cacheReads; f.ticks.send(Unit); await { f.api.cacheReads > reads && f.pauses.size >= 2 }
        f.model.deactivate(); val stopped = f.api.cacheReads; delay(30); assertEquals(stopped, f.api.cacheReads)
        f.api.cacheFailure = true; f.model.activate(); await { !f.model.state.value.cacheLoading }; assertNotNull(f.model.state.value.cacheError)
        assertEquals(desired, f.model.state.value.desired); assertTrue(f.model.canSave); f.model.dismiss()
        val closed = f.api.cacheReads; delay(30); assertEquals(closed, f.api.cacheReads)
    } }
    @Test fun `未决记录十五秒仅回读页面关闭或撤权停止调度`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(); f.disablePeople(); f.model.save(); f.model.confirm()!!.join(); f.model.activate()
        await { f.pauses.isNotEmpty() }; assertEquals(15_000L, f.pauses.last()); f.ticks.send(Unit)
        await { f.api.reviews == 1 && !f.model.state.value.working }; assertEquals(1, f.api.writes)
        f.model.deactivate(); val reviewed = f.api.reviews; delay(30); assertEquals(reviewed, f.api.reviews)
        f.api.pending = false; f.model.activate(); await { f.pauses.size >= 2 }; f.ticks.send(Unit)
        await { f.model.state.value.records.single().checkpoint.finished && !f.model.state.value.working }; assertEquals(1, f.api.writes)
        f.model.revokeAccess(); assertFalse(f.model.state.value.visible); val count = f.api.reviews; delay(30); assertEquals(count, f.api.reviews)
    } }
    @Test fun `不可取消的迟到读取离页不应用返回后重新加载`() = runBlocking { fixture { f ->
        val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeRead = { if (it == SynologyPhotoSettingsKind.GLOBAL) { reached.complete(Unit); withContext(NonCancellable) { release.await() } } }
        f.model.activate(); f.model.open(SynologyPhotoSettingsKind.GLOBAL); reached.await(); f.model.deactivate(); release.complete(Unit)
        await { f.api.globalReads == 1 }; delay(30); assertNull(f.model.state.value.original); assertTrue(f.applied.isEmpty())
        f.api.beforeRead = {}; f.model.activate(); await { f.model.state.value.original != null }; assertEquals(2, f.api.globalReads)
    } }
    @Test fun `保存全局识别和JPEG不刷新个人历史月份多选且更新导出能力`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.jumpToMonth(YearMonth.of(2020, 3))!!.join()
            root.edits!!.selectMode(true); root.edits.toggle(f.api.photo); val before = root.state.value; val selected = root.edits.state.value.selected
            val model = root.settings!!; model.open(SynologyPhotoSettingsKind.GLOBAL); await { !model.state.value.loading && !model.state.value.cacheLoading }
            model.edit(f.api.value.copy(values = f.api.value.values + mapOf(SynologyPhotoGlobalSetting.PEOPLE to false, SynologyPhotoGlobalSetting.ORIGINAL_JPEG to false)))
            model.save(); model.confirm()!!.join()
            assertEquals(before.navigation, root.state.value.navigation); assertEquals(before.selectedMonth, root.state.value.selectedMonth)
            assertEquals(before.items, root.state.value.items); assertEquals(selected, root.edits.state.value.selected); assertFalse(root.state.value.access!!.supportsOriginalSizeJPEG)
        } finally { root.close() }
    } }
    @Test fun `只退出实际关闭的当前来源分类不影响其他月份和分类`() {
        val api = Api(); val after = api.value.applying(api.value.values + (SynologyPhotoGlobalSetting.PEOPLE to false))
        for (space in SynologyPhotoSpace.entries) {
            val before = SynologyPhotosState(access = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic"),
                navigation = SynologyPhotoNavigation(space = space, section = SynologyPhotosSection.ALBUMS, category = SynologyPhotoCategory.PEOPLE),
                categories = setOf(SynologyPhotoCategory.PEOPLE, SynologyPhotoCategory.TAGS), selectedMonth = YearMonth.of(2020, 3))
            val result = before.applyingPhotoSettings(after); assertNull(result.navigation.category); assertEquals(setOf(SynologyPhotoCategory.TAGS), result.categories)
            assertEquals(before.selectedMonth, result.selectedMonth)
            assertEquals(before.navigation, before.applyingPhotoSettings(api.value).navigation)
        }
    }
    @Test fun `全局恢复事实单向保存序列化账号隔离并拒绝伪造步骤`() {
        val f = Fixture(); try {
            val original = f.api.value; val desired = original.applying(original.values + (SynologyPhotoGlobalSetting.PEOPLE to false))
            val row = SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = f.owner.profileId, userId = 41,
                action = SynologyPhotoAlbumAction.SETTINGS, settings = SynologyPhotoSettingsCheckpoint(original, desired)))
            f.store.begin(row); val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); f.store.save(row.id, f.owner, 41, submitting)
            val p = SynologyPhotoGlobalProgress(setOf(SynologyPhotoGlobalStep.ADMIN), setOf(SynologyPhotoGlobalStep.ADMIN))
            val attempted = submitting.copy(settings = submitting.settings!!.copy(attempted = true, globalProgress = p)); f.store.save(row.id, f.owner, 41, attempted)
            reject { f.store.save(row.id, f.owner, 41, submitting) }
            reject { f.store.save(row.id, f.owner, 41, attempted.copy(settings = attempted.settings!!.copy(globalProgress = p.copy(acknowledged = emptySet())))) }
            val restored = SynologyPhotoAlbumStore(f.preferences).records(f.owner.copy(sessionGeneration = "new"), 41).single().checkpoint
            assertEquals(SynologyPhotoAlbumPhase.PENDING, restored.phase); assertEquals(p, restored.settings!!.globalProgress)
            assertTrue(f.store.records(f.owner.copy(identityRevision = "other"), 41).isEmpty()); assertTrue(f.store.records(f.owner, 42).isEmpty())
            reject { f.store.save(row.id, f.owner, 41, restored.copy(settings = restored.settings!!.copy(globalProgress = p.copy(attempted = setOf(SynologyPhotoGlobalStep.SHARED))))) }
            reject { f.store.save(row.id, f.owner, 41, restored.copy(settings = restored.settings!!.copy(globalProgress = p.copy(rejected = p.acknowledged)))) }
            reject { f.store.save(row.id, f.owner, 41, restored.copy(phase = SynologyPhotoAlbumPhase.COMPLETED)) }
        } finally { f.model.close(); f.scope.cancel() }
    }
    companion object {
        private suspend fun await(predicate: () -> Boolean) { withTimeout(5_000) { while (!predicate()) delay(5) } }
        private suspend fun fixture(block: suspend (Fixture) -> Unit) { val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.cancel() } }
        private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
    }
}
