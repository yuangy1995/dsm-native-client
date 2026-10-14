package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成传输验证生成与提示保存的范围、顺序及恢复，不提升真实 NAS 契约等级。 */
class SynologyPhotosCodecPromptRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private class Fixture {
        var administrator: JsonElement? = JsonPrimitive(true); var userId = 41L; var enabled = true; var home = true
        var wizard = obj("""{"prompt":[{"name":"new_codec_installed","show":true}]}""")
        var generationError: Exception? = null; var promptError: Exception? = null; var readError = false
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method in setOf("reindex", "reindex_all_user", "set") }
        fun repository(missing: String? = null) = SynologyPhotosRepository("codec", capabilities.filterKeys { it != missing }, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> JsonObject(obj("""{"enabled":$enabled,"id":$userId}""") + (administrator?.let { mapOf("is_admin" to it) } ?: emptyMap()))
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"none"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":false}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Browse.Category") -> obj("""{"list":[]}""")
                method in setOf("reindex", "reindex_all_user") -> { generationError?.let { throw it }; obj("{}") }
                cap.name.endsWith("Setting.Wizard") && method == "get" -> { if (readError) throw IOException("Synthetic read"); wizard }
                cap.name.endsWith("Setting.Wizard") && method == "set" -> {
                    promptError?.let { throw it }; wizard = obj("""{"prompt":[{"name":"new_codec_installed","show":false}]}"""); obj("{}")
                }
                else -> error("Unexpected synthetic call ${cap.name}.$method")
            }; after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun row(repo: SynologyPhotosRepository, generate: Boolean = true) = SynologyPhotoAlbumCheckpoint(
            profileId = repo.profileId, userId = 41, action = SynologyPhotoAlbumAction.CODEC_PROMPT,
            codecPrompt = SynologyPhotoCodecCheckpoint(repo.codecPrompt(), generate))
    }
    @Test fun `管理员全用户普通账号个人生成随后仅保存固定提示且每步先落盘`() = runBlocking {
        for (admin in listOf(true, false)) {
            val f = Fixture(); f.administrator = JsonPrimitive(admin); val repo = f.ready(); val row = f.row(repo)
            val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
            f.before = { call -> if (call in f.writes) {
                val value = saved.last().codecPrompt!!
                if (call.method == "set") { assertTrue(value.generationAcknowledged); assertEquals(1, value.promptAttempts); assertFalse(value.promptAcknowledged) }
                else { assertTrue(value.generationAttempted); assertFalse(value.generationAcknowledged); assertEquals(0, value.promptAttempts) }
            } }
            val done = repo.performPhotoAlbum(row) { saved += it; validatePhotoAlbumCheckpoint(it) }
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertTrue(done.finished); assertTrue(done.codecPrompt!!.promptClosed)
            assertEquals(listOf(if (admin) "reindex_all_user" else "reindex", "set"), f.writes.map { it.method })
            assertEquals(listOf("SYNO.Foto.Index", "SYNO.Foto.Setting.Wizard"), f.writes.map { it.api })
            assertEquals(mapOf("type" to "\"thumbnail\""), f.writes[0].fields)
            assertEquals(mapOf("prompt" to """[{"name":"new_codec_installed","show":false}]"""), f.writes[1].fields)
            assertTrue(f.calls.none { it.api.startsWith("SYNO.FotoTeam") || it.api.endsWith("Index") && it.method == "get" })
            repo.performPhotoAlbum(row) {}; assertEquals(2, f.writes.size)
        }
    }
    @Test fun `管理员无个人共享来源及H264仍可生成普通账号关闭个人只能稍后`() = runBlocking {
        val f = Fixture(); f.home = false; val repo = f.ready()
        assertTrue(repo.canRespondToCodecPrompt); assertTrue(repo.codecPrompt().canGenerate)
        assertTrue(repo.performPhotoAlbum(f.row(repo)) {}.finished)
        val g = Fixture(); g.home = false; g.administrator = JsonPrimitive(false); val api = g.ready()
        assertFalse(api.codecPrompt().canGenerate); reject { api.performPhotoAlbum(g.row(api)) {} }
        assertTrue(api.performPhotoAlbum(g.row(api, false)) {}.finished); assertEquals(listOf("set"), g.writes.map { it.method })
    }
    @Test fun `读取忽略其他提示缺目标是无提示且打开零写入`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        for (raw in listOf("""{"prompt":[]}""", """{"prompt":[{"name":"other","show":true}]}""",
            """{"prompt":[{"name":"other","show":true},{"name":"new_codec_installed","show":false}]}""")) {
            f.wizard = obj(raw); assertFalse(repo.codecPrompt().shouldShow); reject { repo.performPhotoAlbum(f.row(repo)) {} }
        }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `必需提示字段及重复目标缺管理员或非法管理员均拒绝不默认为普通账号`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        for (raw in listOf("{}", """{"prompt":null}""", """{"prompt":[{}]}""", """{"prompt":[{"name":"new_codec_installed","show":"true"}]}""",
            """{"prompt":[{"name":"new_codec_installed","show":true},{"name":"new_codec_installed","show":false}]}""")) {
            f.wizard = obj(raw); reject { repo.codecPrompt() }
        }
        for (admin in listOf(null, JsonNull, JsonPrimitive("true"), JsonPrimitive(1))) { f.administrator = admin; reject { repo.codecPrompt() } }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `确认后身份权限角色home或提示变化拒绝旧范围零写入`() = runBlocking {
        for (mode in 0..4) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            when (mode) { 0 -> f.userId = 42; 1 -> f.enabled = false; 2 -> f.administrator = JsonPrimitive(false); 3 -> f.home = false
                else -> f.wizard = obj("""{"prompt":[]}""") }
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `稍后只保存提示无Index能力仍可用`() = runBlocking {
        val f = Fixture(); val repo = f.repository("SYNO.Foto.Index"); assertFalse(repo.canRespondToCodecPrompt); repo.access()
        assertTrue(repo.canRespondToCodecPrompt); assertFalse(repo.canGenerateCodecPreviews)
        reject { repo.performPhotoAlbum(f.row(repo)) {} }
        assertTrue(repo.performPhotoAlbum(f.row(repo, false)) {}.finished); assertEquals(listOf("set"), f.writes.map { it.method })
    }
    @Test fun `生成明确拒绝不隐藏提示且以后已读也不能追认成功`() = runBlocking {
        for (code in listOf(100, 105, 119, 1200)) {
            val f = Fixture(); val repo = f.ready(); f.generationError = DsmFailure(code, "Synthetic", "Synthetic recovery")
            val row = repo.performPhotoAlbum(f.row(repo)) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertTrue(row.finished)
            assertTrue(row.codecPrompt!!.generationRejected); assertEquals(0, row.codecPrompt!!.promptAttempts)
            f.wizard = obj("""{"prompt":[]}"""); val cold = f.repository(); cold.access()
            assertEquals(row, cold.reviewPhotoAlbum(row) {}); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `丢失生成回执即使提示后来关闭冷恢复也只读且不可继续保存`() = runBlocking {
        for (error in listOf(IOException("Synthetic"), CancellationException(), DsmFailure(502, "Synthetic", "Synthetic", kind = DsmErrorKind.CONNECTION_FAILED),
            DsmFailure(null, "Synthetic", "Synthetic", kind = DsmErrorKind.INVALID_RESPONSE))) {
            val f = Fixture(); val repo = f.ready(); f.generationError = error
            val row = repo.performPhotoAlbum(f.row(repo)) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, row.phase)
            assertFalse(row.codecPrompt!!.generationAcknowledged); assertFalse(row.codecPrompt!!.generationRejected)
            f.wizard = obj("""{"prompt":[]}"""); val cold = f.repository(); cold.access()
            assertEquals(SynologyPhotoAlbumPhase.PENDING, cold.performPhotoAlbum(row) {}.phase)
            reject { cold.continueCodecPrompt(row) {} }; assertEquals(1, f.writes.size)
        }
    }
    @Test fun `生成接收保存明确失败跨冷启动保留部分成功显式继续只保存提示`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.promptError = DsmFailure(100, "Synthetic", "Synthetic recovery")
        val row = repo.performPhotoAlbum(f.row(repo)) {}; validatePhotoAlbumCheckpoint(row)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertFalse(row.finished); assertTrue(row.codecPrompt!!.canContinue)
        val cold = f.repository(); cold.access(); assertEquals(row, cold.performPhotoAlbum(row) {}); assertEquals(2, f.writes.size)
        f.promptError = null; val done = cold.continueCodecPrompt(row) { validatePhotoAlbumCheckpoint(it) }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertEquals(2, done.codecPrompt!!.promptAttempts)
        assertEquals(1, done.codecPrompt!!.promptRejections); assertTrue(done.codecPrompt!!.promptAcknowledged)
        assertEquals(listOf("reindex_all_user", "set", "set"), f.writes.map { it.method })
        cold.continueCodecPrompt(row) {}; assertEquals(3, f.writes.size)
    }
    @Test fun `继续关闭提示在途取消保留尝试事实且恢复不重复生成或保存`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.promptError = DsmFailure(105, "Synthetic", "Synthetic recovery")
        val original = repo.performPhotoAlbum(f.row(repo)) {}
        f.promptError = CancellationException("Synthetic cancelled transport")
        val result = repo.continueCodecPrompt(original) {}
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertFalse(result.finished)
        assertEquals(2, result.codecPrompt!!.promptAttempts)
        val cold = f.repository(); cold.access(); cold.reviewPhotoAlbum(result) {}
        assertEquals(1, f.writes.count { it.method == "reindex_all_user" }); assertEquals(2, f.writes.count { it.method == "set" })
    }
    @Test fun `继续保存再次拒绝保留单向事实新尝试不重复生成`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.promptError = DsmFailure(105, "Synthetic", "Synthetic recovery")
        var row = repo.performPhotoAlbum(f.row(repo)) {}
        repeat(3) { row = repo.continueCodecPrompt(row) { validatePhotoAlbumCheckpoint(it) } }
        assertEquals(4, row.codecPrompt!!.promptAttempts); assertEquals(4, row.codecPrompt!!.promptRejections)
        assertEquals(1, f.writes.count { it.method == "reindex_all_user" }); assertFalse(row.finished)
    }
    @Test fun `提示回执未知不重放提示也不生成只读观察关闭后完成`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.promptError = IOException("Synthetic lost receipt")
        val row = repo.performPhotoAlbum(f.row(repo)) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, row.phase); assertFalse(row.codecPrompt!!.canContinue)
        val cold = f.repository(); cold.access(); reject { cold.continueCodecPrompt(row) {} }; assertEquals(2, f.writes.size)
        f.wizard = obj("""{"prompt":[]}"""); val done = cold.reviewPhotoAlbum(row) {}
        assertTrue(done.finished); assertTrue(done.codecPrompt!!.generationAcknowledged); assertFalse(done.codecPrompt!!.promptAcknowledged)
    }
    @Test fun `提示保存回执成功但仍显示保持未决不能宣称生成完成`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.after = { if (it.method == "set") f.wizard = obj("""{"prompt":[{"name":"new_codec_installed","show":true}]}""") }
        val row = repo.performPhotoAlbum(f.row(repo)) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, row.phase)
        assertTrue(row.codecPrompt!!.promptAcknowledged); assertFalse(row.codecPrompt!!.canContinue); assertFalse(row.finished)
    }
    @Test fun `稍后回执丢失可由提示关闭确认明确拒绝不能被覆盖`() = runBlocking {
        for (explicit in listOf(true, false)) {
            val f = Fixture(); val repo = f.ready(); f.promptError = if (explicit) DsmFailure(105, "Synthetic", "Synthetic") else IOException("Synthetic")
            val row = repo.performPhotoAlbum(f.row(repo, false)) {}; f.wizard = obj("""{"prompt":[]}""")
            val result = repo.reviewPhotoAlbum(row) {}
            assertEquals(if (explicit) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.COMPLETED, result.phase)
            assertEquals(listOf("set"), f.writes.map { it.method })
        }
    }
    @Test fun `未发送中断只读结束生成接收提示未发中断只允许继续保存`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo).copy(phase = SynologyPhotoAlbumPhase.PENDING)
        val stopped = repo.performPhotoAlbum(row) {}; assertTrue(stopped.finished); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, stopped.phase)
        val cold = f.repository(); cold.access()
        val acknowledged = row.copy(codecPrompt = row.codecPrompt!!.copy(generationAttempted = true, generationAcknowledged = true))
        val partial = cold.performPhotoAlbum(acknowledged) {}; assertFalse(partial.finished); assertTrue(partial.codecPrompt!!.canContinue); assertTrue(f.writes.isEmpty())
        assertTrue(cold.continueCodecPrompt(partial) {}.finished); assertEquals(listOf("set"), f.writes.map { it.method })
    }
    @Test fun `保存尝试或回执失败均不发送下一步冷恢复不重放`() = runBlocking {
        for (stage in 0..2) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            var persisted = row
            try { repo.performPhotoAlbum(row) {
                val value = it.codecPrompt!!
                if (when (stage) { 0 -> value.generationAttempted; 1 -> value.generationAcknowledged; else -> value.promptAttempts > 0 }) throw IOException("Synthetic disk failure")
                persisted = it
            } } catch (_: IOException) {}
            assertEquals(if (stage == 0) 0 else 1, f.writes.size)
            val cold = f.repository(); cold.access(); cold.performPhotoAlbum(persisted) {}
            assertEquals(if (stage == 0) 0 else 1, f.writes.size)
        }
    }
    @Test fun `生成后访问代次变化阻止保存提示保留生成事实`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.after = { if (it.method == "reindex_all_user") repo.access() }
        val row = repo.performPhotoAlbum(f.row(repo)) {}; assertTrue(row.codecPrompt!!.generationAcknowledged)
        assertEquals(0, row.codecPrompt!!.promptAttempts); assertEquals(listOf("reindex_all_user"), f.writes.map { it.method })
    }
    @Test fun `继续前范围变化不追加写入提示在其他客户端关闭则读取结束`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.promptError = DsmFailure(105, "Synthetic", "Synthetic")
        val row = repo.performPhotoAlbum(f.row(repo)) {}; f.administrator = JsonPrimitive(false)
        reject { repo.continueCodecPrompt(row) {} }; assertFalse(row.finished); assertEquals(2, f.writes.size)
        f.wizard = obj("""{"prompt":[]}"""); val done = repo.continueCodecPrompt(row) {}; assertTrue(done.finished); assertEquals(2, f.writes.size)
    }
    @Test fun `缺Wizard无入口读取失败保留错误且无写入`() = runBlocking {
        val f = Fixture(); val repo = f.repository("SYNO.Foto.Setting.Wizard"); repo.access()
        assertFalse(repo.canRespondToCodecPrompt); reject { repo.codecPrompt() }
        val api = f.ready(); f.readError = true
        try { api.codecPrompt(); fail("Expected read failure") } catch (_: IOException) {}
        assertTrue(f.writes.isEmpty())
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private val capabilities = (listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Setting.Wizard", "Index").map { "SYNO.Foto.$it" to 1 } +
            listOf("SYNO.Foto.Browse.Category" to 3)).associate { (name, version) -> ApiCapability(name, "entry.cgi", 1, version, "JSON").let { name to it } }
    }
}
