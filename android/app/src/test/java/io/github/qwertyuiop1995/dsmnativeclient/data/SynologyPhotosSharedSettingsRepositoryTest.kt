package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成接口驱动正式仓储，管理员身份与共享角色分别验证。 */
class SynologyPhotosSharedSettingsRepositoryTest {
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>)
    private class Fixture {
        var administrator = true; var userId = 41L; var accessEnabled = true
        var user = obj("""{"enable_home_service":true,"team_space_permission":"management"}""")
        var admin = obj("""{"package_version":"synthetic","enable_person":true,"enable_concept":true,"enable_similar":false}""")
        var team = obj("""{"enabled":true,"enable_person":true,"enable_concept":false,"enable_similar":true,"allow_root_folder_public":false}""")
        var applyWrite = true; var writeError: Exception? = null; var readError = false
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method in setOf("set", "set_enable") }
        fun repository(missing: String? = null) = SynologyPhotosRepository("shared-settings", capabilities.filterKeys { it != missing }, { cap, method, fields ->
            val call = Call(cap.name, cap.maxVersion, method, fields); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":$accessEnabled,"is_admin":$administrator,"id":$userId}""")
                cap.name == "SYNO.Foto.Setting.User" && method == "get" -> user
                cap.name == "SYNO.Foto.Setting.Admin" && method == "get" -> admin
                cap.name == "SYNO.Foto.Setting.TeamSpace" && method == "get" -> { if (readError) throw IOException("Synthetic read"); team }
                cap.name == "SYNO.Foto.Setting.TeamSpace" && method in setOf("set", "set_enable") -> {
                    if (applyWrite) team = JsonObject(team + fields.mapValues { Json.parseToJsonElement(it.value) })
                    writeError?.let { throw it }; obj("{}")
                }
                cap.name.endsWith("Browse.Category") -> obj("""{"list":[{"id":"person"},{"id":"concept"},{"id":"general_tag"}]}""")
                else -> error("Unexpected synthetic call ${cap.name}.$method")
            }
            after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun settings(repo: SynologyPhotosRepository) = repo.photoSettings(SynologyPhotoSettingsKind.SHARED) as SynologyPhotoSharedSettings
        suspend fun row(repo: SynologyPhotosRepository, change: (SynologyPhotoSharedSettings) -> SynologyPhotoSharedSettings = {
            it.copy(values = it.values + (SynologyPhotoSharedSetting.PEOPLE to false)) }): SynologyPhotoAlbumCheckpoint {
            val before = settings(repo)
            return SynologyPhotoAlbumCheckpoint(profileId = repo.profileId, userId = userId, action = SynologyPhotoAlbumAction.SETTINGS,
                settings = SynologyPhotoSettingsCheckpoint(before, change(before)))
        }
    }
    @Test fun `只用统一Foto读取管理员和完整设置个人关闭仍可读`() = runBlocking {
        val f = Fixture(); f.user = JsonObject(f.user + ("enable_home_service" to JsonPrimitive(false))); val repo = f.ready()
        assertTrue(repo.canManageSettings(SynologyPhotoSettingsKind.SHARED)); val settings = f.settings(repo)
        assertFalse(settings.canToggle); assertTrue(settings.canAccess)
        assertEquals(listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace"), f.calls.map { it.api.removePrefix("SYNO.Foto.") })
        assertTrue(f.calls.all { it.version == 1 }); assertTrue(f.writes.isEmpty())
    }
    @Test fun `management不能代替管理员且撤权或更换当前用户拒绝零写入`() = runBlocking {
        val f = Fixture(); f.administrator = false; val repo = f.ready()
        assertFalse(repo.canManageSettings(SynologyPhotoSettingsKind.SHARED)); reject { f.settings(repo) }; assertTrue(f.writes.isEmpty())
        for (mode in 0..2) {
            val g = Fixture(); val api = g.ready(); val row = g.row(api)
            when (mode) { 0 -> g.administrator = false; 1 -> g.userId = 42; else -> g.accessEnabled = false }
            reject { api.performPhotoAlbum(row) {} }; assertTrue(g.writes.isEmpty())
        }
    }
    @Test fun `未知字段不补false已知全局关闭只读全部未知仍能查看状态`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.admin = JsonObject(f.admin - "enable_concept")
        val value = f.settings(repo)
        assertFalse(SynologyPhotoSharedSetting.SUBJECTS in value.values)
        assertEquals(setOf(SynologyPhotoSharedSetting.PEOPLE, SynologyPhotoSharedSetting.PUBLIC_ROOT), value.editable)
        f.team = obj("""{"enabled":true}"""); assertTrue(f.settings(repo).values.isEmpty())
        f.team = obj("""{"enabled":true,"enable_person":"false"}"""); reject { f.settings(repo) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `普通保存差量字段提交前已保存尝试事实不调用启停`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { if (it.method == "set") { assertTrue(saved.last().settings!!.attempted); assertEquals(SynologyPhotoAlbumPhase.SUBMITTING, saved.last().phase) } }
        val done = repo.performPhotoAlbum(row) { saved += it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        assertEquals(mapOf("enable_person" to "false"), f.writes.single().fields); assertEquals("SYNO.Foto.Setting.TeamSpace", f.writes.single().api)
        repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
        assertFalse(SynologyPhotoCategory.PEOPLE in repo.categories(SynologyPhotoSpace.SHARED))
    }
    @Test fun `最后图库禁止关闭共享文件夹停用原因不禁止尝试启用`() = runBlocking {
        val f = Fixture(); f.user = JsonObject(f.user + ("enable_home_service" to JsonPrimitive(false))); val repo = f.ready()
        reject { repo.performPhotoAlbum(f.row(repo) { it.copy(enabled = false) }) {} }; assertTrue(f.writes.isEmpty())
        f.team = JsonObject(f.team + mapOf("enabled" to JsonPrimitive(false), "team_space_disabled_by_share_folder_disabled" to JsonPrimitive(true)))
        val row = f.row(repo) { it.copy(enabled = true) }; assertTrue(repo.performPhotoAlbum(row) {}.finished)
        assertEquals("set_enable", f.writes.single().method); assertEquals(mapOf("enabled" to "true"), f.writes.single().fields)
    }
    @Test fun `普通保存拒绝全局锁定新字段身份篡改与混合启停`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); val original = row.settings!!.original as SynologyPhotoSharedSettings
        val invalid = listOf(original.copy(values = original.values + (SynologyPhotoSharedSetting.SIMILAR to false)),
            original.copy(values = original.values - SynologyPhotoSharedSetting.PEOPLE), original.copy(administratorId = 42),
            original.copy(global = original.global + (SynologyPhotoSharedSetting.PEOPLE to false)),
            original.copy(enabled = false, values = original.values + (SynologyPhotoSharedSetting.PEOPLE to false)))
        invalid.forEach { reject { repo.performPhotoAlbum(row.copy(settings = row.settings.copy(desired = it))) {} } }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `完整快照以及第二次准备变化均拒绝旧草稿`() = runBlocking {
        for (second in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            fun change() { f.team = JsonObject(f.team + ("allow_root_folder_public" to JsonPrimitive(true))) }
            if (second) { var reads = 0; f.after = { if (it.api.endsWith("Setting.TeamSpace") && it.method == "get" && ++reads == 1) change() } }
            else change()
            if (second) assertTrue(repo.performPhotoAlbum(row) {}.settings!!.rejected) else reject { repo.performPhotoAlbum(row) {} }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `启停允许套件更新默认值并以真实状态更新访问`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo) { it.copy(enabled = false) }
        f.after = { if (it.method == "set_enable") f.team = JsonObject(f.team + mapOf("enable_person" to JsonPrimitive(false), "enable_concept" to JsonPrimitive(true))) }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row) {}.phase)
        val actual = f.settings(repo); assertFalse(actual.canAccess); assertEquals(true, actual.values[SynologyPhotoSharedSetting.SUBJECTS])
        reject { repo.categories(SynologyPhotoSpace.SHARED) }; assertEquals(mapOf("enabled" to "false"), f.writes.single().fields)
    }
    @Test fun `启停回读身份角色或个人条件变化不能追认`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo) { it.copy(enabled = false) }
            f.after = { if (it.method == "set_enable") when (mode) {
                0 -> f.userId = 42; 1 -> f.user = JsonObject(f.user + ("team_space_permission" to JsonPrimitive("entry")))
                else -> f.user = JsonObject(f.user + ("enable_home_service" to JsonPrimitive(false)))
            } }
            assertFalse(repo.performPhotoAlbum(row) {}.finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `普通回读必须完整目标及条件相等`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            f.after = { if (it.method == "set") when (mode) {
                0 -> f.team = JsonObject(f.team - "enable_concept")
                1 -> f.admin = JsonObject(f.admin + ("enable_person" to JsonPrimitive(false)))
                else -> f.team = JsonObject(f.team + ("allow_root_folder_public" to JsonPrimitive(true)))
            } }
            assertFalse(repo.performPhotoAlbum(row) {}.finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `丢回执冷恢复只读启停或普通设置均不重发`() = runBlocking {
        for (toggle in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo) { if (toggle) it.copy(enabled = false) else it.copy(values = it.values + (SynologyPhotoSharedSetting.PEOPLE to false)) }
            f.applyWrite = false; f.writeError = IOException("Synthetic missing receipt")
            val pending = repo.performPhotoAlbum(row) {}; assertFalse(pending.finished)
            val cold = f.repository(); cold.access(); assertFalse(cold.performPhotoAlbum(pending) {}.finished); assertEquals(1, f.writes.size)
            f.team = JsonObject(f.team + f.writes.single().fields.mapValues { Json.parseToJsonElement(it.value) })
            assertTrue(cold.reviewPhotoAlbum(pending) {}.finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `明确拒绝不因之后别人改成目标而误报成功`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.applyWrite = false; f.writeError = DsmFailure(105, "Synthetic", "Synthetic recovery")
        val rejected = repo.performPhotoAlbum(row) {}; assertTrue(rejected.settings!!.rejected); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, rejected.phase)
        f.team = JsonObject(f.team + ("enable_person" to JsonPrimitive(false))); assertEquals(rejected, repo.reviewPhotoAlbum(rejected) {})
        assertEquals(1, f.writes.size)
    }
    @Test fun `读取失败和未知共享角色不生成写入`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.readError = true
        try { f.settings(repo); fail("Expected read failure") } catch (_: IOException) {}
        f.readError = false; f.user = JsonObject(f.user + ("team_space_permission" to JsonPrimitive("future")))
        reject { f.settings(repo) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `尝试事实持久失败不发送且取消准备不发送`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        try { repo.performPhotoAlbum(row) { if (it.settings!!.attempted) throw IOException("Synthetic store") } } catch (_: IOException) {}
        assertTrue(f.writes.isEmpty()); repo.performPhotoAlbum(row) {}; assertTrue(f.writes.isEmpty())
        val g = Fixture(); val api = g.ready(); val next = g.row(api)
        g.before = { if (it.api.endsWith("Setting.Admin")) throw CancellationException() }
        try { api.performPhotoAlbum(next) {}; fail("Expected cancellation") } catch (_: CancellationException) {}
        assertTrue(g.writes.isEmpty())
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private val capabilities = (listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace").map { "SYNO.Foto.$it" to 1 } +
            listOf("SYNO.Foto.Browse.Category" to 3, "SYNO.FotoTeam.Browse.Person" to 1, "SYNO.FotoTeam.Browse.Concept" to 1)).associate { (name, version) ->
            name to ApiCapability(name, "entry.cgi", 1, version, "JSON") }
    }
}
