package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosEditRepositoryTest.Fixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** 所有请求与原件均为合成数据，验证正式仓储的旋转语义和不可重放边界。 */
class SynologyPhotosRotationRepositoryTest {
    @Test fun `八种方向个人共享及原尺寸和交换尺寸均保持单次写入`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) for (orientation in 1..8) for (swap in listOf(true, false)) {
            val f = Fixture().apply { swapDimensions = swap }.ready(); val p = f.photo(space, orientation)
            val states = mutableListOf<SynologyPhotoEditCheckpoint>()
            f.before = { if (it.method == "set") assertEquals(setOf(0), states.last().attempted) }
            val row = f.repository.performPhotoEdit(row(p)) { states += it }
            assertEquals(SynologyPhotoEditPhase.COMPLETED, row.phase)
            assertEquals(listOf(8, 5, 6, 7, 4, 1, 2, 3)[orientation - 1], f.values[p.id]!!.orientation)
            val call = f.writes.single(); assertEquals(2, call.version)
            assertEquals(if (space == SynologyPhotoSpace.PERSONAL) "SYNO.Foto.Browse.Item" else "SYNO.FotoTeam.Browse.Item", call.api)
            assertEquals(mapOf("id" to "[91]", "rotate_action" to "\"counter_clockwise\""), call.fields)
            f.repository.performPhotoEdit(row) {}; f.repository.reviewPhotoEdit(row) {}
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `丢失回执冷热恢复仅按方向与交换尺寸读取且不重复旋转`() = runBlocking {
        for (swap in listOf(true, false)) {
            val f = Fixture().apply { swapDimensions = swap }.ready(); val p = f.photo()
            f.after = { if (it.method == "set") throw IOException("Synthetic lost receipt") }
            val result = f.repository.performPhotoEdit(row(p)) {}
            val expected = if (swap) SynologyPhotoEditPhase.COMPLETED else SynologyPhotoEditPhase.PENDING
            assertEquals(expected, result.phase)
            f.repository.performPhotoEdit(result) {}; assertEquals(1, f.writes.size)
            val cold = Fixture().ready(); cold.values.putAll(f.values)
            val restored = Json.decodeFromString<SynologyPhotoEditCheckpoint>(Json.encodeToString(result))
            assertEquals(expected, cold.repository.performPhotoEdit(restored) {}.phase)
            assertTrue(cold.writes.isEmpty())
        }
    }
    @Test fun `内存成功回执允许稍晚出现预期方向但冷恢复不能继承回执`() = runBlocking {
        val f = Fixture().apply { apply = false; swapDimensions = false }.ready(); val p = f.photo()
        val waiting = f.repository.performPhotoEdit(row(p)) {}; assertEquals(SynologyPhotoEditPhase.PENDING, waiting.phase)
        f.values[p.id] = p.copy(orientation = 8)
        val cold = Fixture().ready(); cold.values.putAll(f.values)
        val encoded = Json.encodeToString(waiting)
        assertFalse(encoded.contains("acknowledged", ignoreCase = true))
        assertEquals(SynologyPhotoEditPhase.PENDING, cold.repository.reviewPhotoEdit(Json.decodeFromString(encoded)) {}.phase)
        assertEquals(SynologyPhotoEditPhase.COMPLETED, f.repository.reviewPhotoEdit(waiting) {}.phase)
        assertTrue(cold.writes.isEmpty()); assertEquals(1, f.writes.size)
    }
    @Test fun `明确拒绝不会因碰巧出现预期方向被认作成功`() = runBlocking {
        for (receipt in listOf("{\"error_list\":[{\"id\":91,\"error\":105}]}", "{}")) {
            val f = Fixture().apply { this.receipt = receipt }.ready(); val p = f.photo()
            if (receipt == "{}") f.after = { if (it.method == "set") throw DsmFailure(105, "Synthetic", "Synthetic recovery") }
            val result = f.repository.performPhotoEdit(row(p)) {}
            assertEquals(SynologyPhotoEditPhase.PARTIAL, result.phase); assertTrue(result.completed.isEmpty())
            assertEquals(setOf(0), result.reportedFailures)
            val cold = Fixture().ready(); cold.values.putAll(f.values)
            assertEquals(SynologyPhotoEditPhase.PARTIAL, cold.repository.reviewPhotoEdit(result) {}.phase)
            assertEquals(1, f.writes.size); assertTrue(cold.writes.isEmpty())
        }
    }
    @Test fun `支持媒体与扩展名只按官方范围且不从文件名猜方向`() = runBlocking {
        val f = Fixture().ready(); val p = f.photo()
        for (type in listOf("photo", "live", "motion_photo", "burst")) assertTrue(p.copy(mediaType = type).supportsRotation)
        for (bad in listOf(p.copy(mediaType = "video"), p.copy(mediaType = "video360"), p.copy(mediaType = "photo360"),
            p.copy(filename = "Synthetic.GIF"), p.copy(filename = "Synthetic.WeBp"), p.copy(orientation = null), p.copy(orientation = 0), p.copy(orientation = 9))) {
            assertFalse(bad.supportsRotation)
            failure { f.repository.performPhotoEdit(row(bad)) {} }
        }
        assertTrue(p.copy(filename = "Synthetic.gif.jpg").supportsRotation)
        failure { f.repository.performPhotoEdit(row(p).copy(targets = listOf(SynologyPhotoEditTarget(p), SynologyPhotoEditTarget(p.copy(id = p.id.copy(itemId = 92)))))) {} }
        failure { f.repository.performPhotoEdit(row(p).copy(edit = SynologyPhotoEdit.Rotation(1, 0, 480))) {} }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `写前照片身份方向或分辨率改变均拒绝`() = runBlocking {
        val changes: List<(SynologyPhoto) -> SynologyPhoto> = listOf(
            { it.copy(filename = "replaced.jpg") }, { it.copy(sizeBytes = 99) }, { it.copy(takenAt = 123.0) },
            { it.copy(indexedAt = 456.0) }, { it.copy(folderId = 7) }, { it.copy(mediaType = "live") },
            { it.copy(orientation = 2) }, { it.copy(width = 321) }, { it.copy(height = 123) })
        for (change in changes) {
            val f = Fixture().ready(); val p = f.photo(); f.values[p.id] = change(p)
            failure { f.repository.performPhotoEdit(row(p)) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `成功回执不放宽身份或任意尺寸旧方向`() = runBlocking {
        val changes: List<(SynologyPhoto) -> SynologyPhoto> = listOf(
            { it.copy(filename = "replaced.jpg") }, { it.copy(sizeBytes = 99) }, { it.copy(takenAt = 123.0) },
            { it.copy(indexedAt = 456.0) }, { it.copy(folderId = 7) }, { it.copy(mediaType = "live") },
            { it.copy(orientation = 1) }, { it.copy(width = 321, height = 123) })
        for (change in changes) {
            val f = Fixture().ready(); val p = f.photo()
            f.after = { if (it.method == "set") f.values[p.id] = change(f.values.getValue(p.id)) }
            val result = f.repository.performPhotoEdit(row(p)) {}
            assertFalse(result.finished); assertTrue(result.completed.isEmpty()); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `目录管理和相册实际本人贡献独立检查且写入保留原来源`() = runBlocking {
        val denied = Fixture().apply { manage = false }.ready(); val p = denied.photo()
        failure { denied.repository.performPhotoEdit(row(p)) {} }; assertTrue(denied.writes.isEmpty())
        for (space in SynologyPhotoSpace.entries) {
            val owner = if (space == SynologyPhotoSpace.SHARED) 0L else 99L
            val f = Fixture().apply { provider = 41; albumOwner = owner }.ready()
            val photo = f.photo(space).copy(albumContext = SynologyPhotoAlbumContext(71, owner, 41)).also { f.values[it.id] = it }
            assertEquals(SynologyPhotoEditPhase.COMPLETED, f.repository.performPhotoEdit(row(photo)) {}.phase)
            assertEquals(if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam.Browse.Item" else "SYNO.Foto.Browse.Item", f.writes.single().api)
            assertTrue(f.calls.filter { it.method == "get" && it.api.endsWith("Browse.Item") }.all { it.fields["album_id"] == "71" })
            assertNull(f.writes.single().fields["album_id"])
        }
        val disabled = Fixture().apply { home = false }.ready()
        val unavailable = disabled.photo().copy(albumContext = SynologyPhotoAlbumContext(71, 41, 41)).also { disabled.values[it.id] = it }
        failure { disabled.repository.performPhotoEdit(row(unavailable)) {} }; assertTrue(disabled.writes.isEmpty())
        val other = Fixture().apply { provider = 42; albumOwner = 99 }.ready()
        val foreign = other.photo().copy(albumContext = SynologyPhotoAlbumContext(71, 99, 42)).also { other.values[it.id] = it }
        failure { other.repository.performPhotoEdit(row(foreign)) {} }; assertTrue(other.writes.isEmpty())
        val shared = Fixture().apply { shared = "entry" }.ready()
        val team = shared.photo(SynologyPhotoSpace.SHARED).copy(albumContext = SynologyPhotoAlbumContext(71, 0, 41)).also { shared.values[it.id] = it }
        failure { shared.repository.performPhotoEdit(row(team)) {} }; assertTrue(shared.writes.isEmpty())
    }
    @Test fun `写前存储失败零写且恢复的提交记录只能读取`() = runBlocking {
        val f = Fixture().ready(); val p = f.photo(); val draft = row(p)
        try { f.repository.performPhotoEdit(draft) { throw IOException("Synthetic storage failure") }; fail() } catch (_: IOException) { }
        assertTrue(f.writes.isEmpty())
        val cold = Fixture().ready(); cold.values.putAll(f.values)
        assertEquals(SynologyPhotoEditPhase.PENDING, cold.repository.performPhotoEdit(draft.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = setOf(0))) {}.phase)
        assertTrue(cold.writes.isEmpty())
    }
    @Test fun `取消丢回执之后不重发且其他账号不能恢复`() = runBlocking {
        val f = Fixture().ready(); val p = f.photo(); val entered = CompletableDeferred<Unit>()
        f.after = { if (it.method == "set") { entered.complete(Unit); awaitCancellation() } }
        var persisted = row(p)
        val work = launch { f.repository.performPhotoEdit(persisted) { persisted = it } }
        entered.await(); work.cancelAndJoin()
        assertTrue(persisted.submitted); assertEquals(1, f.writes.size)
        val cold = Fixture().ready(); cold.values.putAll(f.values)
        assertEquals(SynologyPhotoEditPhase.COMPLETED, cold.repository.performPhotoEdit(persisted) {}.phase)
        cold.user = 42; cold.repository.access()
        failure { cold.repository.reviewPhotoEdit(persisted) {} }; assertTrue(cold.writes.isEmpty())
    }
    @Test fun `实况转向改变后不播放原方向动态组件`() {
        val p = SynologyPhoto(SynologyPhotoId("profile-a", SynologyPhotoSpace.PERSONAL, 91), "synthetic.jpg", 4, 1.0, 1.0, 9, "live", orientation = 1)
        assertTrue(p.canPlayMotion); assertTrue(p.copy(originalOrientation = 1).canPlayMotion)
        assertFalse(p.copy(originalOrientation = 1, orientation = 8).canPlayMotion)
        assertFalse(p.copy(mediaType = "photo").canPlayMotion)
    }
    private fun Fixture.photo(space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL, orientation: Int = 1) =
        add(space).copy(orientation = orientation, width = 640, height = 480).also { values[it.id] = it }
    private fun row(p: SynologyPhoto) = SynologyPhotoEditCheckpoint(profileId = p.id.profileId, userId = 41, space = p.id.space,
        targets = listOf(SynologyPhotoEditTarget(p)), edit = SynologyPhotoEdit.Rotation(p.orientation ?: 0, p.width, p.height))
    private suspend fun failure(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) { } }
}
