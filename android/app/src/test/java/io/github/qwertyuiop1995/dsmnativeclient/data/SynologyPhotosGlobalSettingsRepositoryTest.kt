package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成响应驱动正式组合仓储；多步与缓存的恢复不能借别人的后续修改补发或认领。 */
class SynologyPhotosGlobalSettingsRepositoryTest {
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>)
    private class Fixture {
        var administrator = true; var id = 41L; var enabled = true
        var user = obj("""{"enable_home_service":true,"team_space_permission":"management","enable_person":true,"enable_concept":true,"enable_similar":true,"ame_status":{"has_hevc":true}}""")
        var admin = obj("""{"package_version":"synthetic","enable_person":true,"enable_concept":true,"enable_similar":true,"enable_user_sharing":true,"display_photo_info_to_guest":false,"enable_converted_original_jpeg":true,"exclude_extension":["legacy","jpg"]}""")
        var team = obj("""{"enabled":true,"enable_person":true,"enable_concept":true,"enable_similar":true}""")
        var status = obj("""{"status":"idle"}"""); var size = obj("""{"cache_size":400}""")
        var applyWrite: (Call) -> Boolean = { true }; var writeError: (Call) -> Exception? = { null }
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        var settingsError = false; var cacheError = false
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method in setOf("set", "clear_cache") }
        fun repository(missing: String? = null) = SynologyPhotosRepository("global-settings", capabilities.filterKeys { it != missing }, { cap, method, fields ->
            val call = Call(cap.name, cap.maxVersion, method, fields); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":$enabled,"is_admin":$administrator,"id":$id}""")
                method in setOf("set", "clear_cache") -> {
                    if (applyWrite(call)) when (cap.name) {
                        "SYNO.Foto.Setting.Admin" -> admin = JsonObject(admin + fields.mapValues { Json.parseToJsonElement(it.value) })
                        "SYNO.Foto.Setting.User" -> user = JsonObject(user + fields.mapValues { Json.parseToJsonElement(it.value) })
                        "SYNO.Foto.Setting.TeamSpace" -> team = JsonObject(team + fields.mapValues { Json.parseToJsonElement(it.value) })
                        "SYNO.Foto.Download" -> size = obj("""{"cache_size":0}""")
                        else -> error("Unexpected synthetic write")
                    }
                    writeError(call)?.let { throw it }; obj("{}")
                }
                cap.name.endsWith("Setting.User") -> user
                cap.name.endsWith("Setting.Admin") -> { if (settingsError) throw IOException("Synthetic settings read"); admin }
                cap.name.endsWith("Setting.TeamSpace") -> team
                method == "get_cache_status" -> { if (cacheError) throw IOException("Synthetic cache read"); status }
                method == "calculate_cache_size" -> size
                cap.name.endsWith("Browse.Category") -> obj("""{"list":[{"id":"person"},{"id":"concept"}]}""")
                else -> error("Unexpected synthetic call ${cap.name}.$method")
            }; after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun global(repo: SynologyPhotosRepository) = repo.photoSettings(SynologyPhotoSettingsKind.GLOBAL) as SynologyPhotoGlobalSettings
        suspend fun cache(repo: SynologyPhotosRepository) = repo.photoSettings(SynologyPhotoSettingsKind.CACHE) as SynologyPhotoConversionCache
        suspend fun row(repo: SynologyPhotosRepository, change: (SynologyPhotoGlobalSettings) -> SynologyPhotoGlobalSettings = {
            it.applying(it.values + (SynologyPhotoGlobalSetting.PEOPLE to false)) }): SynologyPhotoAlbumCheckpoint {
            val original = global(repo); return checkpoint(original, change(original))
        }
        suspend fun clear(repo: SynologyPhotosRepository): SynologyPhotoAlbumCheckpoint { val original = cache(repo); return checkpoint(original, original.copy(clearRequested = true)) }
        private fun checkpoint(original: SynologyPhotoSettings, desired: SynologyPhotoSettings) = SynologyPhotoAlbumCheckpoint(profileId = "global-settings", userId = 41,
            action = SynologyPhotoAlbumAction.SETTINGS, settings = SynologyPhotoSettingsCheckpoint(original, desired))
    }
    @Test fun `全局和缓存统一Foto路由版本参数管理员四类读取`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); assertTrue(repo.canManageSettings(SynologyPhotoSettingsKind.GLOBAL)); f.global(repo)
        assertEquals(listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace"), f.calls.map { it.api.removePrefix("SYNO.Foto.") })
        f.calls.clear(); assertEquals(400L, f.cache(repo).sizeBytes)
        assertEquals(listOf("me", "get_cache_status", "calculate_cache_size"), f.calls.map { it.method })
        assertTrue(f.calls.drop(1).all { it.api == "SYNO.Foto.Download" && it.version == 2 && it.fields.isEmpty() })
    }
    @Test fun `管理员和用户身份独立于共享管理角色撤回时零写入`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            when (mode) { 0 -> f.administrator = false; 1 -> f.id = 42; else -> f.enabled = false }
            reject { repo.performPhotoAlbum(row) {} }; reject { f.cache(repo) }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); f.administrator = false; val repo = f.ready()
        assertFalse(repo.canManageSettings(SynologyPhotoSettingsKind.GLOBAL)); assertFalse(repo.canManageSettings(SynologyPhotoSettingsKind.CACHE))
    }
    @Test fun `未知字段保留空值扩展名大小写且类型错误不猜默认`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val value = f.global(repo)
        assertEquals(setOf("legacy", "jpg"), value.excludedExtensions); assertTrue(value.supportsOriginalJPEG)
        f.admin = obj("""{"package_version":"synthetic"}"""); f.user = JsonObject(f.user - "ame_status")
        val unknown = f.global(repo); assertTrue(unknown.values.isEmpty()); assertNull(unknown.hasHEVC); assertNull(unknown.excludedExtensions)
        for (raw in listOf("""{"enable_person":"false"}""", """{"exclude_extension":[3]}""", """{"exclude_extension":"JPG"}""")) {
            f.admin = obj(raw); reject { f.global(repo) }
        }
        f.admin = obj("{}"); f.user = JsonObject(f.user + ("ame_status" to obj("""{"has_hevc":"true"}"""))); reject { f.global(repo) }
    }
    @Test fun `全局读取实际开启与关闭只更新已有来源识别类别`() = runBlocking {
        val f = Fixture(); f.admin = JsonObject(f.admin + ("enable_person" to JsonPrimitive(false))); val repo = f.ready()
        assertFalse(SynologyPhotoCategory.PEOPLE in repo.categories(SynologyPhotoSpace.SHARED))
        f.admin = JsonObject(f.admin + ("enable_person" to JsonPrimitive(true))); f.global(repo)
        assertTrue(SynologyPhotoCategory.PEOPLE in repo.categories(SynologyPhotoSpace.SHARED))
        f.team = JsonObject(f.team + ("enable_person" to JsonPrimitive(false))); f.global(repo)
        assertFalse(SynologyPhotoCategory.PEOPLE in repo.categories(SynologyPhotoSpace.SHARED)); assertTrue(f.writes.isEmpty())
    }
    @Test fun `关闭识别与JPEG按缓存全局个人共享顺序只提交差量并先存事实`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo) { it.applying(it.values + mapOf(SynologyPhotoGlobalSetting.PEOPLE to false, SynologyPhotoGlobalSetting.ORIGINAL_JPEG to false), setOf("legacy", "PNG")) }
        val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { call -> if (call.method in setOf("set", "clear_cache")) {
            val progress = saved.last().settings!!.globalProgress!!
            assertEquals(f.writes.size, progress.attempted.size); assertEquals(f.writes.size - 1, progress.acknowledged.size)
        } }
        val done = repo.performPhotoAlbum(row) { saved += it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        assertEquals(listOf("SYNO.Foto.Download", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.TeamSpace"), f.writes.map { it.api })
        assertTrue(f.writes.first().fields.isEmpty()); assertEquals(setOf("enable_person", "enable_converted_original_jpeg", "exclude_extension"), f.writes[1].fields.keys)
        assertTrue(f.writes.drop(2).all { it.fields == mapOf("enable_person" to "false") }); assertEquals(4, done.settings!!.globalProgress!!.completed.size)
        repo.performPhotoAlbum(row) {}; assertEquals(4, f.writes.size)
    }
    @Test fun `全局原本关闭仍联动已有识别而重新开启不自动开启来源`() = runBlocking {
        val f = Fixture(); f.admin = JsonObject(f.admin + ("enable_person" to JsonPrimitive(false))); val repo = f.ready()
        val original = f.global(repo); val row = f.row(repo) { it.applying(it.values) }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row) {}.phase)
        assertEquals(listOf("SYNO.Foto.Setting.User", "SYNO.Foto.Setting.TeamSpace"), f.writes.map { it.api })
        f.writes.let { assertEquals(2, it.size) }; val enabled = f.row(repo) { it.applying(it.values + (SynologyPhotoGlobalSetting.PEOPLE to true)) }
        repo.performPhotoAlbum(enabled) {}; assertEquals("SYNO.Foto.Setting.Admin", f.writes.last().api)
        assertEquals(false, f.global(repo).personalRecognition[SynologyPhotoRecognition.PEOPLE])
        assertEquals(original, original.applying(original.values + (SynologyPhotoGlobalSetting.PEOPLE to true)).copy(values = original.values))
    }
    @Test fun `未知扩展名允许保留移除新增只限候选且不能篡改联动身份和HEVC`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val original = f.global(repo); val row = f.row(repo)
        val invalid = listOf(original.applying(original.values, setOf("invented")), original.copy(administratorId = 42),
            original.copy(hasHEVC = false), original.copy(sharedEnabled = false), original.copy(personalRecognition = emptyMap()),
            original.copy(values = original.values - SynologyPhotoGlobalSetting.PEOPLE))
        invalid.forEach { reject { repo.performPhotoAlbum(row.copy(settings = SynologyPhotoSettingsCheckpoint(original, it))) {} } }
        val changed = f.row(repo) { it.applying(it.values, setOf("jpg", "PNG")) }; repo.performPhotoAlbum(changed) {}
        assertEquals(mapOf("exclude_extension" to "[\"PNG\",\"jpg\"]"), f.writes.single().fields)
    }
    @Test fun `保存前完整条件并发变化和缺缓存能力都拒绝旧草稿`() = runBlocking {
        for (mode in 0..4) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            when (mode) {
                0 -> f.user = JsonObject(f.user + ("ame_status" to obj("""{"has_hevc":false}""")))
                1 -> f.user = JsonObject(f.user + ("team_space_permission" to JsonPrimitive("entry")))
                2 -> f.team = JsonObject(f.team + ("enabled" to JsonPrimitive(false)))
                3 -> f.admin = JsonObject(f.admin + ("display_photo_info_to_guest" to JsonPrimitive(true)))
                else -> f.team = JsonObject(f.team - "enable_concept")
            }; reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val repo = f.repository("SYNO.Foto.Download"); repo.access()
        val row = f.row(repo) { it.applying(it.values + (SynologyPhotoGlobalSetting.ORIGINAL_JPEG to false)) }
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `缓存允许自然增长但清理中或空缓存不能再次提交`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.clear(repo); f.size = obj("""{"cache_size":600}""")
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row) {}.phase); assertEquals(1, f.writes.size)
        for (clearing in listOf(false, true)) {
            val g = Fixture(); val api = g.ready(); val next = g.clear(api)
            if (clearing) g.status = obj("""{"status":"processing"}""") else g.size = obj("""{"cache_size":0}""")
            reject { api.performPhotoAlbum(next) {} }; assertTrue(g.writes.isEmpty())
        }
    }
    @Test fun `缓存大小状态严格解码不将失败或未知类型当零`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        for (size in listOf("{}", """{"cache_size":-1}""", """{"cache_size":"0"}""", """{"cache_size":0.5}""")) { f.size = obj(size); reject { f.cache(repo) } }
        f.size = obj("""{"cache_size":0}""")
        for (status in listOf("{}", """{"status":""}""", """{"status":false}""")) { f.status = obj(status); reject { f.cache(repo) } }
        f.status = obj("""{"status":"unknown-finished"}"""); assertFalse(f.cache(repo).clearing)
    }
    @Test fun `缓存有回执仍等结束允许新缓存丢回执则必须结束且为零`() = runBlocking {
        for (ack in listOf(true, false)) {
            val f = Fixture(); val repo = f.ready(); val row = f.clear(repo)
            f.applyWrite = { false }; f.status = obj("""{"status":"processing"}""")
            // 提交前必须空闲，发送后才进入清理中。
            f.status = obj("""{"status":"idle"}"""); f.after = { if (it.method == "clear_cache") f.status = obj("""{"status":"processing"}""") }
            if (!ack) { f.writeError = { IOException("Synthetic missing receipt") }; f.before = { if (it.method == "clear_cache") f.status = obj("""{"status":"processing"}""") } }
            val pending = repo.performPhotoAlbum(row) {}; assertFalse(pending.finished)
            val cold = f.repository(); cold.access(); f.status = obj("""{"status":"idle"}""")
            val reviewed = cold.reviewPhotoAlbum(pending) {}; assertEquals(ack, reviewed.finished)
            if (!ack) { f.size = obj("""{"cache_size":0}"""); assertTrue(cold.reviewPhotoAlbum(reviewed) {}.finished) }
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `明确拒绝缓存即使后来为空也不能认领成功且无尝试不认领`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.clear(repo); f.applyWrite = { false }; f.writeError = { DsmFailure(105, "Synthetic", "Synthetic") }
        val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase)
        assertTrue(result.settings!!.globalProgress!!.completed.isEmpty()); f.size = obj("""{"cache_size":0}""")
        assertEquals(result, repo.reviewPhotoAlbum(result) {}); assertEquals(1, f.writes.size)
        val g = Fixture(); val api = g.ready(); val unsent = g.clear(api).copy(phase = SynologyPhotoAlbumPhase.PENDING)
        g.size = obj("""{"cache_size":0}"""); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, api.reviewPhotoAlbum(unsent) {}.phase); assertTrue(g.writes.isEmpty())
    }
    @Test fun `多步中断只读已尝试步骤未发送的目标相同仍不能算全部成功`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        f.applyWrite = { !it.api.endsWith("Setting.User") }; f.writeError = { if (it.api.endsWith("Setting.User")) IOException("Synthetic timeout") else null }
        val pending = repo.performPhotoAlbum(row) {}; assertFalse(pending.finished); assertEquals(2, f.writes.size)
        val cold = f.repository(); cold.access(); cold.performPhotoAlbum(pending) {}; assertEquals(2, f.writes.size)
        f.user = JsonObject(f.user + ("enable_person" to JsonPrimitive(false))); f.team = JsonObject(f.team + ("enable_person" to JsonPrimitive(false)))
        val partial = cold.reviewPhotoAlbum(pending) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, partial.phase)
        assertEquals(setOf(SynologyPhotoGlobalStep.ADMIN, SynologyPhotoGlobalStep.PERSONAL), partial.settings!!.globalProgress!!.completed)
        assertEquals(2, f.writes.size)
    }
    @Test fun `明确拒绝后停止后续步骤并保存部分结果`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        f.applyWrite = { !it.api.endsWith("Setting.User") }; f.writeError = { if (it.api.endsWith("Setting.User")) DsmFailure(105, "Synthetic", "Synthetic") else null }
        val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase)
        assertEquals(setOf(SynologyPhotoGlobalStep.ADMIN), result.settings!!.globalProgress!!.completed)
        assertEquals(setOf(SynologyPhotoGlobalStep.PERSONAL), result.settings.globalProgress!!.rejected); assertEquals(2, f.writes.size)
    }
    @Test fun `成功回执不能替代最终值此前部分匹配也不能掩盖后来并发更改`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.applyWrite = { !it.api.endsWith("Setting.TeamSpace") }
        val pending = repo.performPhotoAlbum(row) {}; assertFalse(pending.finished); assertEquals(2, pending.settings!!.globalProgress!!.completed.size)
        f.team = JsonObject(f.team + ("enable_person" to JsonPrimitive(false))); f.admin = JsonObject(f.admin + ("enable_person" to JsonPrimitive(true)))
        val next = repo.reviewPhotoAlbum(pending) {}; assertFalse(next.finished); assertEquals(3, f.writes.size)
    }
    @Test fun `落盘失败不发首步回执落盘失败不发后续且冷恢复只读`() = runBlocking {
        for (afterAck in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo); var last = row
            try { repo.performPhotoAlbum(row) {
                val p = it.settings!!.globalProgress!!
                if (if (afterAck) p.acknowledged.isNotEmpty() else p.attempted.isNotEmpty()) throw IOException("Synthetic storage")
                last = it
            } } catch (_: IOException) {}
            assertEquals(if (afterAck) 1 else 0, f.writes.size)
            val cold = f.repository(); cold.access(); cold.performPhotoAlbum(last) {}; assertEquals(if (afterAck) 1 else 0, f.writes.size)
        }
    }
    @Test fun `缓存读取失败不妨碍纯全局保存准备取消零写入`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.cacheError = true
        val row = f.row(repo) { it.applying(it.values + (SynologyPhotoGlobalSetting.GUEST_INFO to true)) }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row) {}.phase); assertEquals(1, f.writes.size)
        val g = Fixture(); val api = g.ready(); val next = g.row(api)
        g.before = { if (it.api.endsWith("Setting.Admin")) throw CancellationException() }
        try { api.performPhotoAlbum(next) {}; fail("Expected cancellation") } catch (_: CancellationException) {}
        assertTrue(g.writes.isEmpty())
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private val capabilities = (listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace").map { "SYNO.Foto.$it" to 1 } +
            listOf("SYNO.Foto.Download" to 2, "SYNO.Foto.Browse.Category" to 3, "SYNO.FotoTeam.Browse.Person" to 1, "SYNO.FotoTeam.Browse.Concept" to 1)).associate { (name, version) -> name to ApiCapability(name, "entry.cgi", 1, version, "JSON") }
    }
}
