package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.time.*
import java.util.Locale
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoSettingsModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "settings-model"
        override val canManageAlbums = true
        override val canEditPhotos = true
        override fun canManageSettings(kind: SynologyPhotoSettingsKind) = kind.userSetting
        var automatic = SynologyPhotoAutomaticPreviewSettings(true)
        var display = defaultDisplay
        var duplicates = SynologyPhotoDuplicateSettings(SynologyPhotoUploadDuplicate.IGNORE, SynologyPhotoTransferDuplicate.SKIP)
        var recognition = SynologyPhotoRecognitionSettings(true, mapOf(SynologyPhotoRecognition.PEOPLE to true), mapOf(SynologyPhotoRecognition.PEOPLE to true))
        var failCategories = false
        var pending = false; var failRead = false; var failPrepare = false; var writes = 0; var reviews = 0; var reads = 0
        var beforeRead: suspend () -> Unit = {}; var beforeWrite: suspend () -> Unit = {}; var last: SynologyPhotoAlbumCheckpoint? = null
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true, display)
        override suspend fun photoEditIdentity() = 41L
        override suspend fun photoSettings(kind: SynologyPhotoSettingsKind): SynologyPhotoSettings {
            reads++; beforeRead(); if (failRead) throw IOException("Synthetic read")
            return when (kind) { SynologyPhotoSettingsKind.AUTOMATIC_PREVIEWS -> automatic; SynologyPhotoSettingsKind.DISPLAY -> display; SynologyPhotoSettingsKind.DUPLICATES -> duplicates; SynologyPhotoSettingsKind.RECOGNITION -> recognition; else -> error("Unsupported fixture target") }
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) { if (failPrepare) throw IOException("Synthetic preflight") }
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); beforeWrite(); writes++; last = checkpoint
            val next = checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED,
                settings = checkpoint.settings!!.copy(attempted = true)).also(save)
            if (!pending) apply(next.settings!!.desired)
            return next
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED).also {
                save(it); if (!pending) apply(it.settings!!.desired)
            }
        }
        private fun apply(value: SynologyPhotoSettings) { when (value) { is SynologyPhotoAutomaticPreviewSettings -> automatic = value; is SynologyPhotoDisplaySettings -> display = value; is SynologyPhotoDuplicateSettings -> duplicates = value; is SynologyPhotoRecognitionSettings -> recognition = value; else -> error("Unsupported fixture value") } }
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 2), 1), SynologyPhotoDay(LocalDate.of(2020, 3, 1), 1))
        val photos = listOf(2L to "2020-03-02T12:30:00Z", 1L to "2020-03-01T11:30:00Z").map { (id, date) ->
            SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, id), "Synthetic$id.jpg", 100, Instant.parse(date).epochSecond.toDouble(), Instant.parse(date).epochSecond.toDouble(), 9, "photo") }
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) =
            SynologyPhotoPage(photos.drop(offset).take(limit), offset, minOf(offset + limit, photos.size), offset + limit < photos.size)
        override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
        override suspend fun categories(space: SynologyPhotoSpace): Set<SynologyPhotoCategory> {
            if (failCategories) throw IOException("Synthetic category failure")
            return setOf(SynologyPhotoCategory.VIDEOS) + if (space == SynologyPhotoSpace.SHARED || recognition.personal[SynologyPhotoRecognition.PEOPLE] == true) setOf(SynologyPhotoCategory.PEOPLE) else emptySet()
        }
        override suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int, space: SynologyPhotoSpace) = emptyList<SynologyPhotoCollection>()
    }
    private class Fixture {
        val api = Api(); val preferences = MemoryPreferences(); val store = SynologyPhotoAlbumStore(preferences)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); val owner = WorkspaceOwner(api.profileId, "identity", "session")
        var allowed = true; var current = true; var before: suspend () -> Unit = {}; val applied = mutableListOf<SynologyPhotoSettings>()
        fun model() = SynologyPhotoSettingsModel(api, scope, store, owner, { if (!current) throw CancellationException() }, { allowed }, { before() }, { applied += it })
        val model = model()
        suspend fun open(kind: SynologyPhotoSettingsKind = SynologyPhotoSettingsKind.DISPLAY) { model.open(kind); await { !model.state.value.loading } }
        fun editDisplay() { model.edit(api.display.copy(showInfo = !api.display.showInfo)) }
    }
    @Test fun `打开各表单只读无变化零写入`() = runBlocking { fixture { f ->
        for (kind in SynologyPhotoSettingsKind.entries.filter { it.userSetting }) { f.open(kind); assertEquals(kind, f.model.state.value.desired!!.kind); assertFalse(f.model.canSave); assertNull(f.model.save()); f.model.dismiss() }
        assertEquals(0, f.api.writes); assertTrue(f.store.records(f.owner, 41).isEmpty())
    } }
    @Test fun `自动预览开关直接保存并应用无需额外确认`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoSettingsKind.AUTOMATIC_PREVIEWS)
        f.model.edit(SynologyPhotoAutomaticPreviewSettings(false)); assertTrue(f.model.canSave); f.model.save()!!.join()
        assertNull(f.model.state.value.confirmation); assertEquals(1, f.api.writes)
        assertEquals(SynologyPhotoAutomaticPreviewSettings(false), f.applied.last()); assertFalse(f.api.automatic.enabled)
    } }
    @Test fun `显示与识别直接保存并实际应用只有一次写入`() = runBlocking { fixture { f ->
        f.open(); f.editDisplay(); assertTrue(f.model.canSave); f.model.save()!!.join()
        assertNull(f.model.state.value.confirmation); assertTrue(f.model.state.value.records.single().checkpoint.finished); assertFalse((f.applied.last() as SynologyPhotoDisplaySettings).showInfo)
        f.open(SynologyPhotoSettingsKind.RECOGNITION); f.model.edit(f.api.recognition.copy(personal = mapOf(SynologyPhotoRecognition.PEOPLE to false)))
        f.model.save()!!.join(); assertEquals(2, f.api.writes); assertFalse((f.applied.last() as SynologyPhotoRecognitionSettings).personal[SynologyPhotoRecognition.PEOPLE]!!)
    } }
    @Test fun `新增覆盖默认需固定确认取消保持草稿且零写入`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoSettingsKind.DUPLICATES); val desired = f.api.duplicates.copy(transfer = SynologyPhotoTransferDuplicate.OVERWRITE)
        f.model.edit(desired); assertNull(f.model.save()); assertNotNull(f.model.state.value.confirmation)
        f.model.edit(f.api.duplicates); assertEquals(desired, f.model.state.value.desired)
        f.model.cancelConfirmation(); assertNull(f.model.confirm()); assertEquals(0, f.api.writes); assertEquals(desired, f.model.state.value.desired)
        f.model.save(); f.model.confirm()!!.join(); assertEquals(1, f.api.writes); assertEquals(desired, f.api.last!!.settings!!.desired)
    } }
    @Test fun `仅上传规则变化或从覆盖退回跳过不追加确认`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoSettingsKind.DUPLICATES); f.model.edit(f.api.duplicates.copy(upload = SynologyPhotoUploadDuplicate.RENAME)); f.model.save()!!.join()
        f.api.duplicates = f.api.duplicates.copy(transfer = SynologyPhotoTransferDuplicate.OVERWRITE)
        f.open(SynologyPhotoSettingsKind.DUPLICATES); f.model.edit(f.api.duplicates.copy(transfer = SynologyPhotoTransferDuplicate.SKIP)); f.model.save()!!.join()
        assertEquals(2, f.api.writes); assertNull(f.model.state.value.confirmation)
    } }
    @Test fun `未知识别项不可保存与其他类型不能替换当前表单`() = runBlocking { fixture { f ->
        f.open(SynologyPhotoSettingsKind.RECOGNITION); f.model.edit(f.api.display); assertEquals(f.api.recognition, f.model.state.value.desired)
        f.model.edit(f.api.recognition.copy(personal = f.api.recognition.personal + (SynologyPhotoRecognition.SIMILAR to true)))
        assertFalse(f.model.canSave); assertNull(f.model.save()); assertEquals(0, f.api.writes)
    } }
    @Test fun `读失败可重试预检失败保留草稿且不生成假记录`() = runBlocking { fixture { f ->
        f.api.failRead = true; f.open(); assertNotNull(f.model.state.value.error); assertNull(f.model.state.value.desired)
        f.api.failRead = false; f.model.load()!!.join(); f.editDisplay(); f.api.failPrepare = true; f.model.save()!!.join()
        assertNotNull(f.model.state.value.error); assertNotNull(f.model.state.value.desired); assertTrue(f.store.records(f.owner, 41).isEmpty()); assertEquals(0, f.api.writes)
        f.api.failPrepare = false; f.model.save()!!.join(); assertEquals(1, f.api.writes)
    } }
    @Test fun `迟到读取关闭撤权均不能恢复表单`() = runBlocking { fixture { f ->
        val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeRead = { reached.complete(Unit); withContext(NonCancellable) { release.await() } }
        f.model.open(SynologyPhotoSettingsKind.DISPLAY); reached.await(); f.model.dismiss(); release.complete(Unit); delay(50)
        assertFalse(f.model.state.value.visible); assertNull(f.model.state.value.original)
        f.api.beforeRead = {}; f.open(); f.editDisplay(); f.current = false; f.model.revokeAccess()
        assertFalse(f.model.state.value.visible); assertNull(f.model.save()); assertEquals(0, f.api.writes)
    } }
    @Test fun `保存中防重复操作和关闭保留后台结果`() = runBlocking { fixture { f ->
        val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { reached.complete(Unit); release.await() }; f.open(); f.editDisplay(); val save = f.model.save()!!; reached.await()
        assertNull(f.model.save()); f.model.open(SynologyPhotoSettingsKind.DUPLICATES); assertEquals(SynologyPhotoSettingsKind.DISPLAY, f.model.state.value.kind)
        f.model.dismiss(); assertFalse(f.model.state.value.visible); release.complete(Unit); save.join()
        assertEquals(1, f.api.writes); assertTrue(f.store.records(f.owner, 41).single().checkpoint.finished)
    } }
    @Test fun `未决记录重启只能回读不重发完成后可清除`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(); f.editDisplay(); f.model.save()!!.join(); val id = f.model.state.value.records.single().id
        val cold = f.model(); try {
            cold.showRecords(); await { cold.state.value.records.isNotEmpty() }; cold.resume(id)!!.join(); assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
            cold.discard(id)!!.join(); assertNotNull(cold.state.value.error); assertEquals(1, f.store.records(f.owner, 41).size)
            f.api.pending = false; cold.resume(id)!!.join(); assertEquals(1, f.api.writes); cold.discard(id)!!.join(); assertTrue(f.store.records(f.owner, 41).isEmpty())
        } finally { cold.close() }
    } }
    @Test fun `未发送恢复重新读取原值过期草稿不覆盖`() = runBlocking { fixture { f ->
        val row = SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = f.owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.SETTINGS, settings = SynologyPhotoSettingsCheckpoint(f.api.display, f.api.display.copy(showInfo = false))))
        f.store.begin(row); f.model.showRecords(); await { f.model.state.value.records.isNotEmpty() }; f.model.resume(row.id)!!.join()
        assertFalse((f.model.state.value.desired as SynologyPhotoDisplaySettings).showInfo); assertTrue(f.model.canSave)
        f.model.showRecords(); await { f.model.state.value.records.isNotEmpty() }; f.api.display = f.api.display.copy(clock = SynologyPhotoDisplaySettings.Clock.TWELVE)
        f.model.resume(row.id)!!.join(); assertNull(f.model.state.value.desired); assertNotNull(f.model.state.value.error); assertEquals(0, f.api.writes)
    } }
    @Test fun `未决其他功能阻止写入且无账号时不进入`() = runBlocking { fixture { f ->
        f.allowed = false; f.model.open(SynologyPhotoSettingsKind.DISPLAY); assertFalse(f.model.state.value.visible)
        f.allowed = true; f.open(); f.editDisplay(); f.before = { throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING) }
        f.model.save()!!.join(); assertEquals(0, f.api.writes); assertTrue(f.store.records(f.owner, 41).isEmpty())
    } }
    @Test fun `生产根应用分组日期保留月份查询照片选择且未决隔离相册`() = runBlocking { fixture { f ->
        val root = SynologyPhotosModel(f.api, f.scope, zone = ZoneOffset.UTC, uploadOwner = f.owner, albumStore = f.store, editStore = SynologyPhotoEditStore(MemoryPreferences()))
        try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.jumpToMonth(YearMonth.of(2020, 3))!!.join(); await { !root.state.value.loading && !root.state.value.loadingMore }
            root.edits!!.selectMode(true); root.edits.toggle(f.api.photos.first())
            val before = root.state.value; val selected = root.edits.state.value.selected
            val settings = root.settings!!; settings.open(SynologyPhotoSettingsKind.DISPLAY); await { !settings.state.value.loading }
            settings.edit(f.api.display.copy(grouping = SynologyPhotoDisplaySettings.Grouping.MONTH, date = SynologyPhotoDisplaySettings.Date.DAY_DOT)); settings.save()!!.join()
            assertEquals(before.navigation, root.state.value.navigation); assertEquals(before.selectedMonth, root.state.value.selectedMonth)
            assertEquals(before.items, root.state.value.items); assertEquals(1, root.state.value.groups.size); assertEquals(selected, root.edits.state.value.selected)
            settings.open(SynologyPhotoSettingsKind.DISPLAY); await { !settings.state.value.loading }; settings.edit(f.api.display.copy(showInfo = false)); f.api.pending = true; settings.save()!!.join()
            try { root.albums!!.requireNoPending(); fail() } catch (e: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, e.problem) }
            root.albums!!.refreshRecords()!!.join(); assertTrue(root.albums.state.value.records.isEmpty())
        } finally { root.close() }
    } }
    @Test fun `关闭当前个人分类回相册首页而共享分类留在原位置`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) fixture { f ->
            val root = SynologyPhotosModel(f.api, f.scope, uploadOwner = f.owner, albumStore = f.store)
            try {
                root.activate(); await { root.state.value.loaded && !root.state.value.loading }
                root.selectSpace(space); await { !root.state.value.loading }; root.selectSection(SynologyPhotosSection.ALBUMS); await { !root.state.value.loading }
                root.openCategory(SynologyPhotoCategory.PEOPLE); await { !root.state.value.loading }; assertEquals(SynologyPhotoCategory.PEOPLE, root.state.value.navigation.category)
                val settings = root.settings!!; settings.open(SynologyPhotoSettingsKind.RECOGNITION); await { !settings.state.value.loading }
                settings.edit(f.api.recognition.copy(personal = mapOf(SynologyPhotoRecognition.PEOPLE to false))); settings.save()!!.join(); await { !root.state.value.loading }
                assertEquals(if (space == SynologyPhotoSpace.PERSONAL) null else SynologyPhotoCategory.PEOPLE, root.state.value.navigation.category)
            } finally { root.close() }
        }
    }
    @Test fun `分类读取失败不阻断识别设置读取与成功保存`() = runBlocking { fixture { f ->
        val root = SynologyPhotosModel(f.api, f.scope, uploadOwner = f.owner, albumStore = f.store)
        try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }
            f.api.failCategories = true; root.selectSection(SynologyPhotosSection.ALBUMS); await { !root.state.value.loading }
            assertNotNull(root.state.value.categoriesError)
            val settings = root.settings!!; settings.open(SynologyPhotoSettingsKind.RECOGNITION); await { !settings.state.value.loading }
            assertNotNull(settings.state.value.desired); assertNull(settings.state.value.error)
            settings.edit(f.api.recognition.copy(personal = mapOf(SynologyPhotoRecognition.PEOPLE to false))); settings.save()!!.join()
            assertTrue(settings.state.value.records.single().checkpoint.finished); assertNull(settings.state.value.error)
            assertNotNull(root.state.value.categoriesError); assertEquals(1, f.api.writes)
        } finally { root.close() }
    } }
    @Test fun `公历跨年九种日期月分组和十二小时使用当前区域格式`() {
        val instant = Instant.parse("2019-12-31T23:07:00Z")
        for (date in SynologyPhotoDisplaySettings.Date.entries) {
            val value = defaultDisplay.copy(date = date)
            val text = SynologyPhotoDisplayFormat.timestamp(value, Locale.US, ZoneOffset.UTC).format(instant)
            assertTrue(text.contains("2019")); assertTrue(text.endsWith("23:07")); assertFalse(text.contains("2020"))
            val twelve = SynologyPhotoDisplayFormat.timestamp(value.copy(clock = SynologyPhotoDisplaySettings.Clock.TWELVE), Locale.US, ZoneOffset.UTC).format(instant)
            assertTrue(twelve.endsWith("11:07 PM"))
            val month = SynologyPhotoDisplayFormat.date(value.copy(grouping = SynologyPhotoDisplaySettings.Grouping.MONTH), Locale.US).format(LocalDate.of(2019, 12, 31))
            assertFalse(month.contains("31")); assertTrue(month.contains("12")); assertTrue(month.contains("2019"))
        }
    }
    companion object {
        private val defaultDisplay = SynologyPhotoDisplaySettings(SynologyPhotoDisplaySettings.Grouping.DAY, SynologyPhotoDisplaySettings.Date.YEAR_DASH,
            SynologyPhotoDisplaySettings.Clock.TWENTY_FOUR, SynologyPhotoSort(), true)
        private suspend fun await(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(5) } }
        private suspend fun fixture(block: suspend (Fixture) -> Unit) {
            val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.coroutineContext[Job]!!.cancelAndJoin() }
        }
    }
}
