package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosDeletionRepositoryTest {
    private data class Request(val suffix: String, val method: String, val fields: Map<String, JsonElement>, val space: SynologyPhotoSpace?)
    private class Fixture {
        var owner = SynologyPhotosMutationAccess("deletion-profile", 41, 1, false)
        var enabled = true; var conflicting = false; var view = true; var manage = true
        var allowed = SynologyPhotoSpace.entries.toSet()
        var itemBody: String? = null
        val present = mutableSetOf(SynologyPhotoSpace.PERSONAL to 11L, SynologyPhotoSpace.SHARED to 11L)
        val calls = mutableListOf<Request>()
        val saves = mutableListOf<SynologyPhotoDeletionCheckpoint>()
        var readHook: suspend (Request) -> Unit = {}
        var writeHook: suspend (Request) -> JsonObject = { request ->
            present.remove(request.space!! to request.fields.getValue("item_id").jsonArray.single().jsonPrimitive.long)
            obj("{}")
        }
        fun repository() = SynologyPhotosDeletionRepository(identity = { owner }, checkAccess = { expected, space ->
            if (expected != owner) throw CancellationException()
            if (space != null && space !in allowed) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        }, capability = { suffix, version, space -> ApiCapability("SYNO.${if (space == SynologyPhotoSpace.SHARED) "FotoTeam" else "Foto"}.$suffix",
            "entry.cgi", version, version, "JSON") }, read = { suffix, methodVersion, method, fields, space ->
            val request = Request(suffix, method, fields, space); calls += request; readHook(request)
            when (suffix) {
                "Browse.Item" -> {
                    assertEquals(5, methodVersion)
                    val id = fields.getValue("id").jsonArray.single().jsonPrimitive.long
                    itemBody?.let(::obj) ?: obj(if ((space to id) in present) """{"list":[${item(id)}]}""" else """{"list":[]}""")
                }
                "Browse.Folder" -> obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":$view,"manage":$manage,"upload":true}}}}""")
                else -> error("Unexpected synthetic read")
            }
        }, write = { suffix, version, method, fields, space ->
            assertEquals(1, version)
            val request = Request(suffix, method, fields, space); calls += request; writeHook(request)
        }, photoPending = { conflicting }, enabled = { enabled })
        fun checkpoint(photo: SynologyPhoto = photo()) = SynologyPhotoDeletionCheckpoint(userId = 41, target = SynologyPhotoDeletionTarget(photo))
        fun save(row: SynologyPhotoDeletionCheckpoint) { saves += row }
        val writes: List<Request> get() = calls.filter { it.method == "delete" }
    }
    @Test fun `原件预检读取最小身份无相册或详情参数`() = runTest {
        val f = Fixture(); val photo = photo().copy(albumContext = SynologyPhotoAlbumContext(51, 41, 42))
        f.itemBody = """{"list":[${item(11, "\"additional\":{\"exif\":false,\"gps\":\"broken\",\"thumbnail\":{}}") }]}"""
        f.repository().prepare(photo)
        assertEquals(2, f.calls.size)
        assertEquals(mapOf("id" to JsonArray(listOf(JsonPrimitive(11)))), f.calls.first().fields)
        assertTrue(f.calls.all { it.space == SynologyPhotoSpace.PERSONAL }); assertTrue(f.writes.isEmpty())
    }
    @Test fun `关闭能力和其他操作冲突不发送删除`() = runTest {
        for (disabled in listOf(true, false)) {
            val f = Fixture().apply { enabled = !disabled; conflicting = !disabled }
            failure { f.repository().perform(photo(), f.checkpoint(), f::save) }
            assertTrue(f.writes.isEmpty()); assertTrue(f.saves.isEmpty())
        }
    }
    @Test fun `个人及共享都先保存提交阶段再按原命名空间删除单项`() = runTest {
        for (space in SynologyPhotoSpace.entries) {
            val f = Fixture(); val photo = photo(space = space); val row = f.checkpoint(photo)
            val original = f.writeHook
            f.writeHook = { request -> assertEquals(SynologyPhotoDeletionPhase.SUBMITTED, f.saves.single().phase); original(request) }
            val result = f.repository().perform(photo, row, f::save)
            assertEquals(SynologyPhotoDeletionPhase.CONFIRMED, result.phase)
            assertEquals(listOf(SynologyPhotoDeletionPhase.SUBMITTED, SynologyPhotoDeletionPhase.CONFIRMED), f.saves.map { it.phase })
            assertEquals(space, f.writes.single().space)
            assertEquals(mapOf("item_id" to JsonArray(listOf(JsonPrimitive(11))), "folder_id" to JsonArray(emptyList())), f.writes.single().fields)
            assertTrue(f.calls.filter { it.suffix == "Browse.Item" }.all { it.space == space && "album_id" !in it.fields })
        }
    }
    @Test fun `同步记录失败零危险请求`() = runTest {
        val f = Fixture()
        try { f.repository().perform(photo(), f.checkpoint()) { throw IOException("synthetic storage failure") }; fail() } catch (_: IOException) {}
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `共享管理者例外不扩张到个人且上传权不是删除管理权`() = runTest {
        for (manager in listOf(false, true)) {
            val f = Fixture().apply { manage = false; owner = owner.copy(managesShared = manager) }
            failure { f.repository().prepare(photo()) }
            val shared = photo(space = SynologyPhotoSpace.SHARED)
            if (manager) { f.view = false; f.repository().prepare(shared) } else failure { f.repository().prepare(shared) }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `贡献权不能代替他人原件所有者且错误账号空间零请求`() = runTest {
        val f = Fixture(); val repository = f.repository()
        for (photo in listOf(photo().copy(albumContext = SynologyPhotoAlbumContext(51, 99, 41)),
            photo().copy(id = photo().id.copy(profileId = "other")))) failure { repository.prepare(photo) }
        failure { repository.perform(photo(), f.checkpoint().copy(userId = 42), f::save) }
        f.allowed = emptySet(); failure { repository.prepare(photo()) }
        assertTrue(f.calls.isEmpty()); assertTrue(f.saves.isEmpty())
    }
    @Test fun `预检期间权限代次改变停止删除`() = runTest {
        val f = Fixture(); f.readHook = { if (it.suffix == "Browse.Item") f.owner = f.owner.copy(generation = 2) }
        try { f.repository().perform(photo(), f.checkpoint(), f::save); fail() } catch (_: CancellationException) {}
        assertTrue(f.writes.isEmpty()); assertTrue(f.saves.isEmpty())
    }
    @Test fun `明确权限与会话拒绝保存拒绝同一操作不会重发`() = runTest {
        for (code in listOf(105, 106, 107, 119)) {
            val f = Fixture(); val repository = f.repository(); val row = f.checkpoint()
            f.writeHook = { throw DsmFailure(code, "Synthetic denial", "Sign in again") }
            repeat(2) {
                try { repository.perform(photo(), row, f::save); fail() } catch (error: DsmFailure) { assertEquals(code, error.code) }
            }
            assertEquals(1, f.writes.size); assertEquals(SynologyPhotoDeletionPhase.REJECTED, f.saves.last().phase)
            assertFalse(repository.pending(photo().id))
        }
    }
    @Test fun `网络取消和未知错误保留已提交记录只允许读取`() = runTest {
        for (error in listOf(IOException("synthetic loss"), CancellationException(), DsmFailure(117, "Unknown", "Retry later"))) {
            val f = Fixture(); val repository = f.repository(); val row = f.checkpoint()
            f.writeHook = { throw error }
            val result = repository.perform(photo(), row, f::save)
            assertEquals(SynologyPhotoDeletionPhase.SUBMITTED, result.phase)
            assertTrue(repository.pending(photo().id))
            assertEquals(SynologyPhotoDeletionPhase.SUBMITTED, repository.perform(photo(), row, f::save).phase)
            assertEquals(1, f.writes.size)
            assertEquals(SynologyPhotoDeletionPhase.SUBMITTED, f.repository().review(result, f::save).phase)
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `已提交冷恢复只有成功空列表确认且不依赖内存或回执`() = runTest {
        val f = Fixture(); val row = f.checkpoint().copy(phase = SynologyPhotoDeletionPhase.SUBMITTED)
        f.present.clear()
        assertEquals(SynologyPhotoDeletionPhase.CONFIRMED, f.repository().review(row, f::save).phase)
        assertTrue(f.writes.isEmpty()); assertEquals(1, f.calls.size)
        assertEquals(SynologyPhotoDeletionPhase.CONFIRMED, f.saves.single().phase)
    }
    @Test fun `错误权限畸形非空和替换后的原件均不能冒充删除成功`() = runTest {
        val f = Fixture(); val row = f.checkpoint().copy(phase = SynologyPhotoDeletionPhase.SUBMITTED)
        for (body in listOf("{}", """{"list":[${item(12)}]}""", """{"list":[${item(11).replace("sample.jpg", "replaced.jpg")}]}""",
            """{"list":[${item(11)},${item(11)}]}""")) {
            f.itemBody = body; failure { f.repository().review(row, f::save) }
        }
        f.readHook = { throw DsmFailure(105, "Denied", "Request access") }
        try { f.repository().review(row, f::save); fail() } catch (_: DsmFailure) {}
        assertTrue(f.saves.isEmpty()); assertTrue(f.writes.isEmpty())
    }
    @Test fun `未发送恢复取得实际照片并核对所有原件字段但不能直接回查完成`() = runTest {
        val f = Fixture(); val repository = f.repository(); val row = f.checkpoint()
        assertTrue(row.target.matches(repository.target(row)))
        failure { repository.review(row, f::save) }
        f.itemBody = """{"list":[${item(11).replace("100.25", "101.25")}]}"""
        failure { repository.target(row) }
        failure { repository.target(row.copy(phase = SynologyPhotoDeletionPhase.SUBMITTED)) }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `同一操作和未决同一原件都不能改换身份或重复发送`() = runTest {
        val f = Fixture(); val repository = f.repository(); val row = f.checkpoint()
        f.writeHook = { throw IOException("synthetic loss") }
        repository.perform(photo(), row, f::save)
        val changed = photo().copy(sizeBytes = 8)
        failure { repository.perform(changed, row.copy(target = SynologyPhotoDeletionTarget(changed)), f::save) }
        failure { repository.perform(photo(), f.checkpoint(), f::save) }
        assertEquals(1, f.writes.size)
    }
    @Test fun `结果读取过程中撤权不保存完成旧响应`() = runTest {
        val f = Fixture(); val row = f.checkpoint().copy(phase = SynologyPhotoDeletionPhase.SUBMITTED)
        f.present.clear(); f.readHook = { f.owner = f.owner.copy(generation = 2) }
        try { f.repository().review(row, f::save); fail() } catch (_: CancellationException) {}
        assertTrue(f.saves.isEmpty()); assertTrue(f.writes.isEmpty())
    }
    private suspend fun failure(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
    companion object {
        private fun photo(space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL) = SynologyPhoto(
            SynologyPhotoId("deletion-profile", space, 11), "sample.jpg", 4, 100.25, 101.75, 9, "photo")
        private fun item(id: Long, extra: String = "") = """{"id":$id,"filename":"sample.jpg","filesize":4,"time":100.25,"indexed_time":101.75,"folder_id":9,"type":"photo"${if (extra.isEmpty()) "" else ",$extra"}}"""
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
    }
}
