package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoConditionModelTest {
    @Test fun `创建规则使用现有相册记录并保存固定原始值`() = runBlocking { fixture { f ->
        f.openCreate(); f.model.setName("Synthetic rules")
        f.rules.add("person", SynologyPhotoConditionOption(JsonPrimitive(7), "Synthetic person"))
        f.model.save()!!.join()
        val row = f.store.records(owner, 41).single().checkpoint
        assertEquals(SynologyPhotoAlbumAction.CREATE_CONDITION, row.action); assertTrue(row.finished)
        assertEquals("or", row.condition!!.fields["person_policy"]?.jsonPrimitive?.content)
        assertEquals(listOf(JsonPrimitive(7)), row.condition.values("person")); assertTrue(row.condition.names.isEmpty())
        assertEquals(1, f.api.writes)
    } }
    @Test fun `编辑加载完整原规则而修改仅改变选定条件`() = runBlocking { fixture { f ->
        f.model.open(SynologyPhotoAlbumAction.SET_CONDITION, albumId = 71); ready(f)
        val original = f.model.state.value.draft!!.originalCondition!!
        f.rules.add("keyword", SynologyPhotoConditionOption(JsonPrimitive("Synthetic keyword")))
        f.model.save()!!.join()
        val row = f.store.records(owner, 41).single().checkpoint
        assertEquals(original.fields, row.originalCondition!!.fields)
        assertEquals(original.fields["future"], row.condition!!.fields["future"])
        assertEquals(original.fields["person"], row.condition.fields["person"]); assertNull(row.name)
    } }
    @Test fun `规则读取失败不能保存重试读取成功后才可编辑`() = runBlocking { fixture { f ->
        f.api.failRead = true; f.model.open(SynologyPhotoAlbumAction.SET_CONDITION, albumId = 71); ready(f)
        assertNull(f.model.save()); assertFalse(f.rules.state.value.valid); assertEquals(0, f.api.writes)
        f.api.failRead = false; f.model.retryAccess(); ready(f)
        assertTrue(f.rules.state.value.valid); f.model.save()!!.join(); assertEquals(1, f.api.writes)
    } }
    @Test fun `来源切换隔离草稿并仅向实际共享管理者提供共享来源`() = runBlocking { fixture { f ->
        f.openCreate(); f.rules.add("camera", SynologyPhotoConditionOption(JsonPrimitive(9), "Synthetic camera"))
        f.rules.selectSource(SynologyPhotoSpace.SHARED)
        assertEquals(0L, f.rules.state.value.condition!!.fields["user_id"]?.jsonPrimitive?.long)
        assertTrue(f.rules.state.value.condition!!.values("camera").isEmpty())
        f.rules.add("person", SynologyPhotoConditionOption(JsonPrimitive(7)))
        f.rules.selectSource(SynologyPhotoSpace.PERSONAL)
        assertEquals(listOf(JsonPrimitive(9)), f.rules.state.value.condition!!.values("camera"))
        assertTrue(f.rules.state.value.condition!!.values("person").isEmpty())
        f.access = f.access.copy(canManageSharedSpace = false); f.openCreate()
        assertEquals(listOf(SynologyPhotoSpace.PERSONAL), f.rules.state.value.spaces)
        f.rules.selectSource(SynologyPhotoSpace.SHARED); assertEquals(SynologyPhotoSpace.PERSONAL, f.rules.state.value.condition!!.space)
    } }
    @Test fun `过期数量查询在修改后不能覆盖新条件和当前加载状态`() = runBlocking { fixture { f ->
        f.openCreate(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.counting = { entered.complete(Unit); withContext(NonCancellable) { release.await() }; 9 }
        val first = f.rules.preview()!!; entered.await()
        f.rules.values("rating", listOf(JsonPrimitive(4)))
        f.api.counting = { 2 }; f.rules.preview()!!.join(); release.complete(Unit); first.join()
        assertEquals(2L, f.rules.state.value.count); assertFalse(f.rules.state.value.counting)
        f.rules.values("rating", listOf(JsonPrimitive(3))); assertNull(f.rules.state.value.count)
    } }
    @Test fun `过期建议同词重试与切源不能覆盖最新结果`() = runBlocking { fixture { f ->
        f.openCreate(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.searching = { entered.complete(Unit); withContext(NonCancellable) { release.await() }; mapOf("camera" to listOf(SynologyPhotoConditionOption(JsonPrimitive(9)))) }
        val first = f.rules.search()!!; entered.await()
        f.rules.searchText(""); f.api.searching = { mapOf("person" to listOf(SynologyPhotoConditionOption(JsonPrimitive(7)))) }
        f.rules.search()!!.join(); release.complete(Unit); first.join()
        assertEquals(setOf("person"), f.rules.state.value.suggestions!!.keys); assertFalse(f.rules.state.value.searching)
        f.rules.selectSource(SynologyPhotoSpace.SHARED); assertNull(f.rules.state.value.suggestions)
    } }
    @Test fun `目录分页进入返回真实列表且切源不混用目录`() = runBlocking { fixture { f ->
        f.openCreate(); f.rules.loadFolders()!!.join()
        assertEquals(100, f.rules.state.value.folders.size); assertTrue(f.rules.state.value.moreFolders)
        f.rules.loadFolders()!!.join(); assertEquals(101, f.rules.state.value.folders.size); assertFalse(f.rules.state.value.moreFolders)
        val folder = f.rules.state.value.folders.first(); f.rules.enter(folder); await { !f.rules.state.value.foldersLoading }
        assertEquals(listOf(1L, 2L), f.rules.state.value.path.map { it.id }); assertTrue(f.rules.state.value.folders.isEmpty())
        f.rules.up(); await { !f.rules.state.value.foldersLoading }; assertEquals(100, f.rules.state.value.folders.size)
        f.rules.selectSource(SynologyPhotoSpace.SHARED); assertTrue(f.rules.state.value.path.isEmpty()); assertTrue(f.rules.state.value.folders.isEmpty())
        f.rules.loadFolders()!!.join(); assertTrue(f.rules.state.value.folders.all { it.space == SynologyPhotoSpace.SHARED })
    } }
    @Test fun `规则无效时不能查询数量或保存且移除最终关键词清理策略`() = runBlocking { fixture { f ->
        f.openCreate(); f.model.setName("Synthetic")
        f.rules.add("keyword", SynologyPhotoConditionOption(JsonPrimitive("abc"))); f.rules.remove("keyword", JsonPrimitive("abc"))
        assertFalse(f.rules.state.value.condition!!.fields.containsKey("keyword_policy"))
        f.rules.values("time", listOf(buildJsonObject { put("start_time", 9); put("end_time", 8) }))
        assertFalse(f.rules.state.value.valid); assertNull(f.rules.preview()); assertNull(f.model.save()); assertEquals(0, f.api.writes)
    } }
    @Test fun `恢复规则提交只回读且重置模型不保留旧来源输入`() = runBlocking { fixture { f ->
        f.openCreate(); f.model.setName("Synthetic"); f.api.pending = true; f.model.save()!!.join()
        val row = f.store.records(owner, 41).single(); f.model.close()
        val restored = SynologyPhotoAlbumModel(f.api, f.scope, f.store, owner, {}, { true }, sourceAccess = { f.access }, onCompleted = {})
        try {
            restored.showRecords(); await { restored.state.value.records.isNotEmpty() }
            f.api.pending = false; restored.resume(row.id)!!.join()
            assertTrue(restored.state.value.records.single().checkpoint.finished); assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
            assertNull(restored.conditions.state.value.condition)
        } finally { restored.close() }
    } }
    @Test fun `关闭来源权限时创建表单保留错误且不写记录`() = runBlocking { fixture { f ->
        f.access = f.access.copy(spaces = emptyList()); f.openCreate()
        assertNotNull(f.model.state.value.error); assertNull(f.rules.state.value.condition); assertNull(f.model.save())
        assertTrue(f.store.records(owner, 41).isEmpty())
    } }

    private class Fixture {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val api = Serving(); val store = SynologyPhotoAlbumStore(MemoryPreferences())
        var access = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true)
        val model = SynologyPhotoAlbumModel(api, scope, store, owner, {}, { true }, sourceAccess = { access }, onCompleted = {})
        val rules get() = model.conditions
        suspend fun openCreate() { model.open(SynologyPhotoAlbumAction.CREATE_CONDITION); ready(this) }
    }
    private class Serving : SynologyPhotosServing {
        override val profileId = owner.profileId; override val canManageAlbums = true; override val canManageConditionAlbums = true
        var writes = 0; var reviews = 0; var failRead = false; var pending = false
        var counting: suspend () -> Long = { 4 }; var searching: suspend () -> Map<String, List<SynologyPhotoConditionOption>> = { emptyMap() }
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic", true)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
        override suspend fun photoEditIdentity() = 41L
        override suspend fun albumAccess(id: Long) = SynologyPhotoAlbumAccess(SynologyPhotoAlbumSnapshot(id, "Synthetic", 41, "condition", false, false), true, false, true)
        override suspend fun albumCondition(id: Long): SynologyPhotoAlbumCondition {
            if (failRead) throw IOException("synthetic read failure")
            return SynologyPhotoAlbumCondition(Json.parseToJsonElement("""{"user_id":41,"person":[7],"person_policy":"and","future":[9,2]}""").jsonObject)
        }
        override suspend fun conditionSuggestions(keyword: String, space: SynologyPhotoSpace) = searching()
        override suspend fun conditionItemCount(condition: SynologyPhotoAlbumCondition) = counting()
        override suspend fun rootFolder(space: SynologyPhotoSpace) = SynologyPhotoCollection(1, "/", space = space)
        override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int): List<SynologyPhotoCollection> =
            if (parentId == 1L) (2L..102L).drop(offset).take(limit).map { SynologyPhotoCollection(it, "Synthetic-$it", 1, space = space) } else emptyList()
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); writes++; return settle(checkpoint).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; return settle(checkpoint).also(save)
        }
        private fun settle(row: SynologyPhotoAlbumCheckpoint) = row.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED,
            createdAlbumId = if (row.action.creates) 72 else null)
    }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.coroutineContext[Job]!!.cancelAndJoin() }
    }
    private companion object {
        val owner = WorkspaceOwner("condition-model", "identity", "session")
        suspend fun ready(f: Fixture) { await { !f.model.state.value.loading } }
        suspend fun await(predicate: () -> Boolean) { withTimeout(5000) { while (!predicate()) delay(5) } }
    }
}
