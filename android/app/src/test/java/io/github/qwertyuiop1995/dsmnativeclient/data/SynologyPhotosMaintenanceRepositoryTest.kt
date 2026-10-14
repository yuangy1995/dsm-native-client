package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成传输驱动正式仓储；计数为零不能代替缺失的维护回执。 */
class SynologyPhotosMaintenanceRepositoryTest {
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>)
    private class Fixture {
        var administrator = true; var userId = 41L; var enabled = true
        var user = obj("""{"enable_home_service":true,"team_space_permission":"management","ame_status":{"has_h264":true}}""")
        var team = obj("""{"enabled":true}""")
        var counts = obj("""{"basic":0,"thumbnail":0}""")
        var writeError: Exception? = null; var readError = false
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method == "reindex" }
        fun repository(missing: String? = null) = SynologyPhotosRepository("maintenance", capabilities.filterKeys { it != missing }, { cap, method, fields ->
            val call = Call(cap.name, cap.maxVersion, method, fields); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":$enabled,"is_admin":$administrator,"id":$userId}""")
                cap.name.endsWith("Setting.User") -> user
                cap.name.endsWith("Setting.TeamSpace") -> team
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Browse.Category") -> obj("""{"list":[]}""")
                method == "reindex" -> { writeError?.let { throw it }; obj("{}") }
                cap.name.endsWith("Index") && method == "get" -> { if (readError) throw IOException("Synthetic read"); counts }
                else -> error("Unexpected synthetic call ${cap.name}.$method")
            }; after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun row(repo: SynologyPhotosRepository, space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL,
            action: SynologyPhotoMaintenanceAction = SynologyPhotoMaintenanceAction.INDEX) = SynologyPhotoAlbumCheckpoint(
                profileId = repo.profileId, userId = 41, action = SynologyPhotoAlbumAction.MAINTAIN_LIBRARY,
                maintenance = SynologyPhotoMaintenanceCheckpoint(repo.maintenanceStatus(space), action))
    }
    @Test fun `未读取访问与当前来源关闭时不显示维护入口`() = runBlocking {
        val f = Fixture(); val repo = f.repository()
        assertFalse(repo.canMaintainLibrary(SynologyPhotoSpace.PERSONAL)); assertFalse(repo.canMaintainLibrary(SynologyPhotoSpace.SHARED))
        repo.access(); assertTrue(repo.canMaintainLibrary(SynologyPhotoSpace.PERSONAL)); assertTrue(repo.canMaintainLibrary(SynologyPhotoSpace.SHARED))
        f.user = JsonObject(f.user + ("enable_home_service" to JsonPrimitive(false))); repo.access()
        assertFalse(repo.canMaintainLibrary(SynologyPhotoSpace.PERSONAL)); assertTrue(repo.canMaintainLibrary(SynologyPhotoSpace.SHARED))
        f.team = obj("""{"enabled":false}"""); repo.access()
        assertFalse(repo.canMaintainLibrary(SynologyPhotoSpace.PERSONAL)); assertFalse(repo.canMaintainLibrary(SynologyPhotoSpace.SHARED))
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `两来源仅Index按来源路由身份设置统一Foto且发送固定type`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) for (action in SynologyPhotoMaintenanceAction.entries) {
            val f = Fixture(); val repo = f.ready(); assertTrue(repo.canMaintainLibrary(space))
            val row = f.row(repo, space, action)
            assertTrue(f.calls.all { it.version == 1 && it.fields.isEmpty() })
            assertTrue(f.calls.filter { !it.api.endsWith("Index") }.all { it.api.startsWith("SYNO.Foto.") })
            val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
            f.before = { if (it.method == "reindex") { assertTrue(saved.last().maintenance!!.attempted); assertFalse(saved.last().maintenance!!.acknowledged) } }
            val result = repo.performPhotoAlbum(row) { saved += it }
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertTrue(result.maintenance!!.acknowledged)
            assertEquals(mapOf("type" to JsonPrimitive(action.value).toString()), f.writes.single().fields)
            assertEquals(if (space == SynologyPhotoSpace.PERSONAL) "SYNO.Foto.Index" else "SYNO.FotoTeam.Index", f.writes.single().api)
            repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
        }
    }
    @Test fun `缺失非法负数小数字符串计数均读取失败不伪装空闲`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        for (raw in listOf("{}", """{"basic":0}""", """{"basic":-1,"thumbnail":0}""", """{"basic":0,"thumbnail":-1}""",
            """{"basic":"0","thumbnail":0}""", """{"basic":0.5,"thumbnail":0}""", """{"basic":0,"thumbnail":null}""")) {
            f.counts = obj(raw); reject { repo.maintenanceStatus(SynologyPhotoSpace.PERSONAL) }
        }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `预览只看NAS的H264支持未知或仅HEVC时索引仍可开始`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        for (ame in listOf<JsonElement?>(null, obj("{}"), obj("""{"has_hevc":true}"""), obj("""{"has_h264":false}"""))) {
            f.user = JsonObject(f.user - "ame_status" + if (ame == null) emptyMap() else mapOf("ame_status" to ame))
            val status = repo.maintenanceStatus(SynologyPhotoSpace.PERSONAL)
            assertTrue(status.canStart(SynologyPhotoMaintenanceAction.INDEX)); assertFalse(status.canStart(SynologyPhotoMaintenanceAction.PREVIEWS))
            reject { repo.performPhotoAlbum(f.row(repo, action = SynologyPhotoMaintenanceAction.PREVIEWS)) {} }
        }
        f.user = JsonObject(f.user + ("ame_status" to obj("""{"has_h264":"true"}""")))
        reject { repo.maintenanceStatus(SynologyPhotoSpace.PERSONAL) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `共享management不能代替管理员entry管理员可维护个人普通用户可维护`() = runBlocking {
        val f = Fixture(); f.administrator = false; val repo = f.ready()
        assertFalse(repo.canMaintainLibrary(SynologyPhotoSpace.SHARED)); reject { repo.maintenanceStatus(SynologyPhotoSpace.SHARED) }
        assertTrue(repo.maintenanceStatus(SynologyPhotoSpace.PERSONAL).canStart(SynologyPhotoMaintenanceAction.INDEX))
        f.administrator = true; f.user = JsonObject(f.user + ("team_space_permission" to JsonPrimitive("entry")))
        assertTrue(repo.maintenanceStatus(SynologyPhotoSpace.SHARED).canStart(SynologyPhotoMaintenanceAction.INDEX)); assertTrue(f.writes.isEmpty())
    }
    @Test fun `提交前撤销身份管理员home或共享状态都拒绝旧快照且零写入`() = runBlocking {
        for (mode in 0..6) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo, if (mode >= 3) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL)
            when (mode) {
                0 -> f.userId = 42
                1 -> f.enabled = false
                2 -> f.user = JsonObject(f.user + ("enable_home_service" to JsonPrimitive(false)))
                3 -> f.administrator = false
                4 -> f.team = obj("""{"enabled":false}""")
                5 -> f.user = JsonObject(f.user + ("team_space_permission" to JsonPrimitive("none")))
                else -> f.user = JsonObject(f.user + ("team_space_permission" to JsonPrimitive("future")))
            }; reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `仅对应计数要求空闲另一个阶段变化不拒绝索引`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.counts = obj("""{"basic":1,"thumbnail":0}""")
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        f.counts = obj("""{"basic":0,"thumbnail":20}""")
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row) {}.phase)
    }
    @Test fun `原始忙碌或身份被改的快照不能通过prepare`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); val value = row.maintenance!!
        for (changed in listOf(value.copy(original = value.original.copy(indexingCount = 3)), value.copy(original = value.original.copy(profileId = "other")),
            value.copy(original = value.original.copy(userId = 42)))) reject { repo.performPhotoAlbum(row.copy(maintenance = changed)) {} }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `明确接收后忙碌持续读取归零结束且冷恢复绝不重发`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        f.after = { if (it.method == "reindex") f.counts = obj("""{"basic":3,"thumbnail":0}""") }
        val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase); assertTrue(pending.maintenance!!.acknowledged)
        val cold = f.repository(); cold.access(); assertEquals(SynologyPhotoAlbumPhase.PENDING, cold.performPhotoAlbum(pending) {}.phase)
        f.counts = obj("""{"basic":0,"thumbnail":9}"""); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, cold.reviewPhotoAlbum(pending) {}.phase)
        assertEquals(1, f.writes.size)
    }
    @Test fun `回执丢失即使从正数归零与冷恢复也不能追认成功`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.writeError = IOException("Synthetic lost receipt")
        val pending = repo.performPhotoAlbum(row) {}; assertTrue(pending.maintenance!!.attempted); assertFalse(pending.maintenance!!.acknowledged)
        val cold = f.repository(); cold.access()
        for (count in listOf(3, 0)) {
            f.counts = obj("""{"basic":$count,"thumbnail":0}""")
            assertEquals(SynologyPhotoAlbumPhase.PENDING, cold.performPhotoAlbum(pending) {}.phase)
        }; assertEquals(1, f.writes.size)
    }
    @Test fun `明确拒绝含code100保持失败不被后续空闲计数覆盖`() = runBlocking {
        for (code in listOf(100, 105, 119, 1200)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.writeError = DsmFailure(code, "Synthetic", "Synthetic recovery")
            val rejected = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, rejected.phase)
            assertTrue(rejected.maintenance!!.rejected); assertFalse(rejected.maintenance!!.acknowledged)
            val cold = f.repository(); cold.access(); assertEquals(rejected, cold.reviewPhotoAlbum(rejected) {}); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `真实传输的网络HTTP错误和非法响应仍是未知不能当明确拒绝`() = runBlocking {
        for ((code, kind) in listOf(null to DsmErrorKind.CONNECTION_FAILED, 502 to DsmErrorKind.CONNECTION_FAILED,
            null to DsmErrorKind.INVALID_RESPONSE, null to DsmErrorKind.REQUEST_FAILED)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.writeError = DsmFailure(code, "Synthetic", "Synthetic recovery", kind = kind)
            val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
            assertFalse(pending.maintenance!!.rejected); assertFalse(pending.maintenance!!.acknowledged)
            repo.performPhotoAlbum(pending) {}; assertEquals(1, f.writes.size)
        }
    }
    @Test fun `接收后读取失败保留回执恢复只读可完成`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        f.after = { if (it.method == "reindex") f.readError = true }
        val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase); assertTrue(pending.maintenance!!.acknowledged)
        f.readError = false; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.reviewPhotoAlbum(pending) {}.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `取消或存储失败后不再发送维护`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.writeError = CancellationException()
        val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
        repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
        val g = Fixture(); val api = g.ready(); val value = g.row(api)
        try { api.performPhotoAlbum(value) { if (it.maintenance!!.attempted) throw IOException("Synthetic persistence failure") } } catch (_: IOException) {}
        assertTrue(g.writes.isEmpty()); api.performPhotoAlbum(value) {}; assertTrue(g.writes.isEmpty())
    }
    @Test fun `已保存但尚未尝试的中断记录只读结束不自动发请求`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo).copy(phase = SynologyPhotoAlbumPhase.PENDING)
        val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase)
        assertFalse(result.maintenance!!.attempted); assertTrue(f.writes.isEmpty())
    }
    @Test fun `缺当前来源接口不猜另一来源且读取失败无写入`() = runBlocking {
        val f = Fixture(); val repo = f.repository("SYNO.FotoTeam.Index"); repo.access()
        assertFalse(repo.canMaintainLibrary(SynologyPhotoSpace.SHARED)); assertTrue(repo.canMaintainLibrary(SynologyPhotoSpace.PERSONAL))
        reject { repo.maintenanceStatus(SynologyPhotoSpace.SHARED) }; assertTrue(f.calls.none { it.api.endsWith("Index") })
        f.readError = true; try { repo.maintenanceStatus(SynologyPhotoSpace.PERSONAL); fail("Expected read failure") } catch (_: IOException) {}
        assertTrue(f.writes.isEmpty())
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private val capabilities = (listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Index").map { "SYNO.Foto.$it" to 1 } +
            listOf("SYNO.FotoTeam.Index" to 1, "SYNO.Foto.Browse.Category" to 3)).associate { (name, version) -> ApiCapability(name, "entry.cgi", 1, version, "JSON").let { name to it } }
    }
}
