package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture.Companion.albumTarget
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture.Companion.displayTarget
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture.Companion.sortTarget
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture.Companion.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoPreferenceFixture.Companion.list
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosAlbumPreferencesRepositoryTest {
    @Test fun `相册读取唯一数组查看权限无需本人来源或原件管理`() = runBlocking {
        val f = SynologyPhotoPreferenceFixture(); f.home = false; f.shared = false; f.field("owner_user_id", JsonPrimitive(42)); val repo = f.ready()
        assertEquals(SynologyPhotoAlbumSortSettings(7, SynologyPhotoSort()), repo.photoSettings(albumTarget))
        assertEquals("[7]", f.calls.first().fields["id"]); assertEquals(4, f.calls.first().version)
        assertTrue(f.calls.any { it.method == "get_permission" }); assertFalse(f.calls.any { it.api.startsWith("SYNO.FotoTeam") })
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(f.row(repo)) {}.phase)
        assertEquals(mapOf("id" to "7", "sort_by" to "\"filename\"", "sort_direction" to "\"asc\""), f.writes.single().fields)
        assertEquals(1, f.writes.single().version)
    }
    @Test fun `首次缺省允许拍摄升序但未知字段和非字符串必须报错`() = runBlocking {
        for (value in listOf(null, JsonNull, JsonPrimitive(""))) {
            val f = SynologyPhotoPreferenceFixture(); f.field("sort_by", value); f.field("sort_direction", value)
            assertEquals(SynologyPhotoAlbumSortSettings(7, SynologyPhotoSort()), f.ready().photoSettings(albumTarget))
        }
        for ((field, bad) in listOf("sort_by" to JsonPrimitive("unknown"), "sort_direction" to JsonPrimitive("unknown"), "sort_by" to JsonPrimitive(1))) {
            val f = SynologyPhotoPreferenceFixture(); f.field(field, bad); reject { f.ready().photoSettings(albumTarget) }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `四字段双方向读写并且保存前先持久尝试事实`() = runBlocking {
        for (field in SynologyPhotoSort.Field.entries) for (direction in SynologyPhotoSort.Direction.entries) {
            val f = SynologyPhotoPreferenceFixture(); f.field("sort_direction", JsonPrimitive(if (direction == SynologyPhotoSort.Direction.ASCENDING) "desc" else "asc"))
            val repo = f.ready(); val row = f.row(repo) { (it as SynologyPhotoAlbumSortSettings).copy(sort = SynologyPhotoSort(field, direction)) }
            val saves = mutableListOf<SynologyPhotoAlbumCheckpoint>()
            f.before = { if (it.method == "set_order") assertTrue(saves.last().settings!!.attempted) }
            assertTrue(repo.performPhotoAlbum(row) { saves += it }.finished); repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
            assertEquals(field.value, Json.parseToJsonElement(f.writes.single().fields.getValue("sort_by")).jsonPrimitive.content)
        }
    }
    @Test fun `写后字段缺失不得用首次默认值冒充成功`() = runBlocking {
        val f = SynologyPhotoPreferenceFixture(); f.field("sort_direction", JsonPrimitive("desc")); val repo = f.ready()
        val row = f.row(repo) { (it as SynologyPhotoAlbumSortSettings).copy(sort = SynologyPhotoSort()) }
        f.after = { if (it.method == "set_order") { f.field("sort_by", null); f.field("sort_direction", null) } }
        val pending = repo.performPhotoAlbum(row) {}; assertFalse(pending.finished)
        assertFalse(repo.reviewPhotoAlbum(pending) {}.finished); assertEquals(1, f.writes.size)
        f.field("sort_by", JsonPrimitive("takentime")); f.field("sort_direction", JsonPrimitive("asc")); assertTrue(repo.reviewPhotoAlbum(pending) {}.finished)
    }
    @Test fun `相册身份错误重复结果和撤回查看权限均拒绝`() = runBlocking {
        for (raw in listOf(list(emptyList()), list(listOf(obj("""{"id":8}"""))), list(listOf(obj("""{"id":7}"""), obj("""{"id":7}"""))))) {
            val f = SynologyPhotoPreferenceFixture(); f.albumOverride = raw; reject { f.ready().photoSettings(albumTarget) }
        }
        val f = SynologyPhotoPreferenceFixture(); f.field("owner_user_id", JsonPrimitive(42)); val repo = f.ready(); val row = f.row(repo); f.permitted = false
        try { repo.performPhotoAlbum(row) {}; fail("Expected permission rejection") } catch (_: DsmFailure) {}
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `列表三范围字段严格且每次只提交选定范围两字段`() = runBlocking {
        for (scope in SynologyPhotoAlbumListScope.entries) for (field in scope.fields) {
            val f = SynologyPhotoPreferenceFixture(); val repo = f.ready(); val original = repo.photoSettings(sortTarget(scope)) as SynologyPhotoAlbumListSortSettings
            val direction = if (original.sort.direction == SynologyPhotoSort.Direction.ASCENDING) SynologyPhotoSort.Direction.DESCENDING else SynologyPhotoSort.Direction.ASCENDING
            val row = f.row(repo, sortTarget(scope)) { original.copy(sort = SynologyPhotoAlbumListSort(field, direction)) }
            val previous = f.order
            assertTrue(repo.performPhotoAlbum(row) {}.finished)
            val call = f.writes.single(); assertEquals("set_album_list_order", call.method); assertEquals(2, call.version)
            assertEquals(setOf(scope.value + "_sort_by", scope.value + "_sort_direction"), call.fields.keys)
            assertEquals(previous.filterKeys { !it.startsWith(scope.value + "_") }, f.order.filterKeys { !it.startsWith(scope.value + "_") })
        }
    }
    @Test fun `列表未知缺少与跨范围字段不能伪装默认偏好`() = runBlocking {
        for (scope in SynologyPhotoAlbumListScope.entries) for (value in listOf<JsonElement?>(null, JsonPrimitive(2), JsonPrimitive("unknown"), JsonPrimitive(if (scope == SynologyPhotoAlbumListScope.ALBUMS) "share_modify_time" else "create_time"))) {
            val f = SynologyPhotoPreferenceFixture(); val key = scope.value + "_sort_by"; f.order = JsonObject(if (value == null) f.order - key else f.order + (key to value))
            reject { f.ready().photoSettings(sortTarget(scope)) }; assertTrue(f.writes.isEmpty())
        }
        val f = SynologyPhotoPreferenceFixture(); val repo = f.ready(); val row = f.row(repo, sortTarget(SynologyPhotoAlbumListScope.WITH_ME)) {
            (it as SynologyPhotoAlbumListSortSettings).copy(sort = it.sort.copy(field = SynologyPhotoAlbumListSort.Field.CREATED_TIME)) }
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `全部我的严格读取单独保存不写排序和共享权限`() = runBlocking {
        val f = SynologyPhotoPreferenceFixture(); val repo = f.ready(); val originalOrder = f.order
        val row = f.row(repo, displayTarget) { SynologyPhotoAlbumDisplaySettings(SynologyPhotoAlbumDisplay.MINE) }
        assertTrue(repo.performPhotoAlbum(row) {}.finished); assertEquals(3, f.writes.single().version)
        assertEquals(mapOf("album_display_type" to "\"my_album\""), f.writes.single().fields); assertEquals(originalOrder, f.order)
        for (value in listOf("{}", "{\"album_display_type\":\"unknown\"}", "{\"album_display_type\":true}")) {
            f.display = obj(value); reject { repo.photoSettings(displayTarget) }
        }
    }
    @Test fun `能力版本分离不依赖个人设置写能力`() = runBlocking {
        for (range in listOf(1..1, 2..2, 3..3, 4..4, 1..4)) {
            val f = SynologyPhotoPreferenceFixture(); val key = "SYNO.Foto.Browse.Album"
            f.capabilities = f.capabilities + (key to ApiCapability(key, "entry.cgi", range.first, range.last, "JSON"))
            val repo = f.ready()
            assertEquals(1 in range && 4 in range, repo.canManageSettings(SynologyPhotoSettingsKind.ALBUM_SORT))
            assertEquals(2 in range, repo.canManageSettings(SynologyPhotoSettingsKind.LIST_SORT))
            assertEquals(3 in range, repo.canManageSettings(SynologyPhotoSettingsKind.LIST_DISPLAY))
        }
    }
    @Test fun `两次预检发现偏好变化零写不覆盖网页修改`() = runBlocking {
        for (second in listOf(false, true)) {
            val f = SynologyPhotoPreferenceFixture(); val repo = f.ready(); val row = f.row(repo)
            if (!second) f.field("sort_direction", JsonPrimitive("desc")) else {
                var reads = 0; f.after = { if (it.method == "get" && it.api.endsWith("Browse.Album") && ++reads == 1) f.field("sort_direction", JsonPrimitive("desc")) }
            }
            if (second) assertTrue(repo.performPhotoAlbum(row) {}.settings!!.rejected) else reject { repo.performPhotoAlbum(row) {} }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `未知回执冷恢复只读不重发且部分匹配不完成`() = runBlocking {
        for (target in listOf(albumTarget, sortTarget(SynologyPhotoAlbumListScope.WITH_ME), displayTarget)) {
            val f = SynologyPhotoPreferenceFixture(); val repo = f.ready(); val row = f.row(repo, target) { when (it) {
                is SynologyPhotoAlbumSortSettings -> it.copy(sort = it.sort.copy(field = SynologyPhotoSort.Field.FILENAME))
                is SynologyPhotoAlbumListSortSettings -> it.copy(sort = it.sort.copy(field = SynologyPhotoAlbumListSort.Field.NAME))
                else -> SynologyPhotoAlbumDisplaySettings(SynologyPhotoAlbumDisplay.MINE)
            } }
            f.apply = false; f.writeError = IOException("Synthetic missing receipt")
            val pending = repo.performPhotoAlbum(row) {}; assertFalse(pending.finished)
            val cold = f.repository(); cold.access(); cold.performPhotoAlbum(pending) {}; assertEquals(1, f.writes.size)
            val fields = f.writes.single().fields.mapValues { Json.parseToJsonElement(it.value) }
            when (target.kind) { SynologyPhotoSettingsKind.ALBUM_SORT -> f.album = JsonObject(f.album + fields.filterKeys { it != "id" }); SynologyPhotoSettingsKind.LIST_SORT -> f.order = JsonObject(f.order + fields); else -> f.display = JsonObject(fields) }
            assertTrue(cold.reviewPhotoAlbum(pending) {}.finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `账号变化存储失败和明确拒绝保持原保护`() = runBlocking {
        val f = SynologyPhotoPreferenceFixture(); val repo = f.ready(); val row = f.row(repo); f.userId = 42; repo.access()
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        f.userId = 41; repo.access()
        try { repo.performPhotoAlbum(row) { if (it.settings!!.attempted) throw IOException("Synthetic storage failure") } } catch (_: IOException) {}
        assertTrue(f.writes.isEmpty()); repo.performPhotoAlbum(row) {}; assertTrue(f.writes.isEmpty())
        val g = SynologyPhotoPreferenceFixture(); val api = g.ready(); val next = g.row(api); g.apply = false; g.writeError = DsmFailure(105, "Synthetic", "Synthetic")
        val rejected = api.performPhotoAlbum(next) {}; assertTrue(rejected.settings!!.rejected); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, rejected.phase)
    }
    @Test fun `列表相册分页携带固定选择收集不接受排序`() = runBlocking {
        val f = SynologyPhotoPreferenceFixture(); val repo = f.ready(); val sort = SynologyPhotoAlbumListSort(SynologyPhotoAlbumListSort.Field.TYPE, SynologyPhotoSort.Direction.DESCENDING)
        for (offset in listOf(0, 2)) repo.albums(offset, 2, SynologyPhotoAlbumDisplay.MINE, sort)
        f.calls.takeLast(2).forEach { assertEquals("\"normal\"", it.fields["category"]); assertEquals("\"album_type\"", it.fields["sort_by"]); assertEquals("\"desc\"", it.fields["sort_direction"]) }
        for (scope in listOf(SynologyPhotoShareScope.WITH_ME, SynologyPhotoShareScope.WITH_OTHERS)) {
            repo.sharedEntries(scope, 0, 2, sort); assertEquals("\"album_type\"", f.calls.last().fields["sort_by"])
        }
        val before = f.calls.size; reject { repo.sharedEntries(SynologyPhotoShareScope.REQUESTS, 0, 2, sort) }; assertEquals(before, f.calls.size)
        repo.sharedEntries(SynologyPhotoShareScope.REQUESTS, 0, 2); assertEquals(setOf("offset", "limit"), f.calls.last().fields.keys)
        repo.sharedEntries(SynologyPhotoShareScope.WITH_OTHERS, 0, 2); assertEquals("\"share_modify_time\"", f.calls.last().fields["sort_by"])
        repo.albums(0, 2); assertEquals("\"normal_share_with_me\"", f.calls.last().fields["category"]); assertFalse(f.calls.last().fields.containsKey("sort_by"))
    }
    @Test fun `相册照片全部分页固定四字段方向且统一Foto和相册上下文`() = runBlocking {
        val f = SynologyPhotoPreferenceFixture(); f.home = false; val repo = f.ready()
        for (offset in listOf(0, 2)) {
            val page = repo.photos(SynologyPhotoSpace.SHARED, SynologyPhotoQuery.Album(7, SynologyPhotoSort(SynologyPhotoSort.Field.FILESIZE)), offset, 2)
            assertEquals("SYNO.Foto.Browse.Item", f.calls.last().api); assertEquals("7", f.calls.last().fields["album_id"])
            assertEquals("\"filesize\"", f.calls.last().fields["sort_by"]); assertEquals("\"asc\"", f.calls.last().fields["sort_direction"])
            assertTrue(page.items.all { it.albumContext?.albumId == 7L && it.id.space == SynologyPhotoSpace.PERSONAL })
        }
        repo.photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Album(7), 0, 2); assertEquals("\"desc\"", f.calls.last().fields["sort_direction"])
    }
    @Test fun `目标不可换相册或范围普通适配器不可默默忽略新参数`() = runBlocking {
        val f = SynologyPhotoPreferenceFixture(); val repo = f.ready(); val row = f.row(repo)
        reject { repo.performPhotoAlbum(row.copy(settings = row.settings!!.copy(desired = SynologyPhotoAlbumSortSettings(8, SynologyPhotoSort())))) {} }
        reject { repo.photoSettings(SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.LIST_SORT)) }
        reject { repo.photoSettings(SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.DISPLAY, albumId = 7)) }
        assertTrue(f.writes.isEmpty())
        val old = object : SynologyPhotosServing {
            override val profileId = "old"
            override suspend fun access() = SynologyPhotoAccess(emptyList(), "synthetic", false)
            override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
            override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
            override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
        }
        assertTrue(old.albums(0, 2, null, null).isEmpty()); reject { old.albums(0, 2, SynologyPhotoAlbumDisplay.MINE, null) }
        reject { old.photoSettings(albumTarget) }
    }
    private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
}
