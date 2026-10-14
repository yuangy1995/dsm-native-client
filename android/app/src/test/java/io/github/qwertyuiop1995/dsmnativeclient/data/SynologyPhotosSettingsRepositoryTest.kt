package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 通过正式组合仓储检查请求、回读与重启恢复；全部内容为合成数据。 */
class SynologyPhotosSettingsRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private class Fixture {
        var user = obj("""{"auto_generate_thumbnail":true,"enable_home_service":true,"team_space_permission":"management","timeline_group_unit":"day","date_format":"YYYY-MM-DD","time_format":"24","item_sort_by":"takentime","sort_direction":"asc","show_item_info_in_lightbox":true,"upload_default_action":"ignore","copy_move_default_action":"skip","enable_person":true,"enable_concept":false,"enable_similar":true}""")
        var admin = obj("""{"package_version":"synthetic","enable_person":true,"enable_concept":true,"enable_similar":false}""")
        var owner = 41L; var enabled = true; var apply = true; var failRead = false; var writeError: Exception? = null
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method == "set" }
        var folder = obj("""{"id":9,"name":"/Synthetic","parent":1,"additional":{"access_permission":{"view":true,"manage":true,"download":true}}}""")
        fun field(key: String, value: JsonElement?) { user = JsonObject(if (value == null) user - key else user + (key to value)) }
        fun repository() = SynologyPhotosRepository("settings", capabilities, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":$enabled,"id":$owner}""")
                cap.name == "SYNO.Foto.Setting.User" && method == "get" -> { if (failRead) throw IOException("Synthetic read failure"); user }
                cap.name == "SYNO.Foto.Setting.User" && method == "set" -> {
                    if (apply) user = JsonObject(user + fields.mapValues { Json.parseToJsonElement(it.value) })
                    writeError?.let { throw it }; obj("{}")
                }
                cap.name.endsWith("Setting.Admin") -> admin
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true,"enable_person":true,"enable_concept":true}""")
                cap.name.endsWith("Browse.Folder") -> buildJsonObject { put("folder", folder) }
                cap.name.endsWith("Browse.Category") -> obj("""{"list":[{"id":"person"},{"id":"concept"},{"id":"general_tag"}]}""")
                cap.name.endsWith("Browse.Timeline") -> obj("""{"list":[]}""")
                else -> error("Unexpected synthetic call ${cap.name}.$method")
            }
            after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun row(repo: SynologyPhotosRepository, kind: SynologyPhotoSettingsKind = SynologyPhotoSettingsKind.DISPLAY,
            change: (SynologyPhotoSettings) -> SynologyPhotoSettings = { (it as SynologyPhotoDisplaySettings).copy(showInfo = false) }): SynologyPhotoAlbumCheckpoint {
            val value = repo.photoSettings(kind)
            return SynologyPhotoAlbumCheckpoint(profileId = repo.profileId, userId = owner, action = SynologyPhotoAlbumAction.SETTINGS,
                settings = SynologyPhotoSettingsCheckpoint(value, change(value)))
        }
    }
    @Test fun `个人设置从自身Foto读取且个人关闭不阻断显示重复设置`() = runBlocking {
        val f = Fixture(); f.field("enable_home_service", JsonPrimitive(false)); val repo = f.ready()
        SynologyPhotoSettingsKind.entries.filter { it.userSetting }.forEach { assertTrue(repo.canManageSettings(it)); assertEquals(it, repo.photoSettings(it).kind) }
        assertEquals(4, f.calls.count { it.api == "SYNO.Foto.Setting.User" && it.method == "get" })
        assertEquals(1, f.calls.count { it.api == "SYNO.Foto.Setting.Admin" }); assertTrue(f.writes.isEmpty())
        assertFalse(f.calls.any { it.api.startsWith("SYNO.FotoTeam") })
        val row = f.row(repo); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row) {}.phase)
    }
    @Test fun `显示严格读取六项未知字段不阻断访问也不能保存猜测值`() = runBlocking {
        for ((key, bad) in listOf("timeline_group_unit" to JsonPrimitive("year"), "date_format" to JsonPrimitive("YYYY-DD-MM"),
            "time_format" to JsonPrimitive(24), "item_sort_by" to JsonPrimitive("unknown"), "sort_direction" to JsonPrimitive("unknown"),
            "show_item_info_in_lightbox" to JsonPrimitive("false"))) {
            for (value in listOf(bad, null)) {
                val f = Fixture(); val repo = f.ready(); f.field(key, value)
                reject { repo.photoSettings(SynologyPhotoSettingsKind.DISPLAY) }
                // 访问可继续按既有排序回退；设置表单绝不使用回退值保存。
                assertNull(repo.access().displaySettings)
                assertTrue(f.writes.isEmpty())
            }
        }
    }
    @Test fun `九种日期大小写规范化十二二十四小时与日月枚举均接受`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        for (date in SynologyPhotoDisplaySettings.Date.entries) for (clock in SynologyPhotoDisplaySettings.Clock.entries) for (group in SynologyPhotoDisplaySettings.Grouping.entries) {
            f.field("date_format", JsonPrimitive(date.value.uppercase())); f.field("time_format", JsonPrimitive(clock.value)); f.field("timeline_group_unit", JsonPrimitive(group.value))
            val actual = repo.photoSettings(SynologyPhotoSettingsKind.DISPLAY) as SynologyPhotoDisplaySettings
            assertEquals(date, actual.date); assertEquals(clock, actual.clock); assertEquals(group, actual.grouping)
        }
    }
    @Test fun `只写改变字段并在请求前持久提交事实完成后再次保存不重发`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { if (it.method == "set") { assertEquals(SynologyPhotoAlbumPhase.SUBMITTING, saved.last().phase); assertTrue(saved.last().settings!!.attempted) } }
        val done = repo.performPhotoAlbum(row) { saved += it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        assertEquals(mapOf("show_item_info_in_lightbox" to "false"), f.writes.single().fields)
        repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
    }
    @Test fun `显示六字段全部改动只有六个参数不会混入个人权限或重复规则`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo) { SynologyPhotoDisplaySettings(
            SynologyPhotoDisplaySettings.Grouping.MONTH, SynologyPhotoDisplaySettings.Date.DAY_DOT, SynologyPhotoDisplaySettings.Clock.TWELVE,
            SynologyPhotoSort(SynologyPhotoSort.Field.FILESIZE, SynologyPhotoSort.Direction.DESCENDING), false) }
        assertTrue(repo.performPhotoAlbum(row) {}.finished)
        assertEquals(setOf("timeline_group_unit", "date_format", "time_format", "item_sort_by", "sort_direction", "show_item_info_in_lightbox"), f.writes.single().fields.keys)
        assertEquals("\"dd.mm.yyyy\"", f.writes.single().fields["date_format"])
    }
    @Test fun `预检完整快照变化与二次预检变化都不覆盖其他客户端`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.field("time_format", JsonPrimitive("12"))
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        val g = Fixture(); val api = g.ready(); val next = g.row(api)
        var reads = 0
        g.after = { if (it.api.endsWith("Setting.User") && it.method == "get" && ++reads == 1) g.field("time_format", JsonPrimitive("12")) }
        val rejected = api.performPhotoAlbum(next) {}; assertTrue(rejected.settings!!.rejected); assertTrue(rejected.finished); assertTrue(g.writes.isEmpty())
    }
    @Test fun `相同值以及不同设置类型拒绝零写`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        for (change in listOf(row.settings!!.copy(desired = row.settings.original), row.settings.copy(desired = SynologyPhotoDuplicateSettings(SynologyPhotoUploadDuplicate.IGNORE, SynologyPhotoTransferDuplicate.SKIP))))
            reject { repo.performPhotoAlbum(row.copy(settings = change)) {} }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `丢回执按完整目标回读重启后只读不重发`() = runBlocking {
        for (applied in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.apply = applied; f.writeError = IOException("Synthetic missing receipt")
            val result = repo.performPhotoAlbum(row) {}; assertEquals(applied, result.finished)
            val cold = f.repository(); cold.access(); cold.performPhotoAlbum(result) {}; assertEquals(1, f.writes.size)
            if (!applied) { f.field("show_item_info_in_lightbox", JsonPrimitive(false)); assertTrue(cold.reviewPhotoAlbum(result) {}.finished) }
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `仅部分字段应用或回读缺字段不冒充完成`() = runBlocking {
        for (missing in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo) { (it as SynologyPhotoDisplaySettings).copy(showInfo = false, clock = SynologyPhotoDisplaySettings.Clock.TWELVE) }
            f.after = { if (it.method == "set") f.field("time_format", if (missing) null else JsonPrimitive("24")) }
            val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertTrue(result.settings!!.attempted)
            if (missing) reject { repo.reviewPhotoAlbum(result) {} } else assertFalse(repo.reviewPhotoAlbum(result) {}.finished)
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `明确拒绝结束而断网和未知错误保留未决`() = runBlocking {
        for (code in listOf(105, 106, 107, 119, 999)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.apply = false; f.writeError = DsmFailure(code, "Synthetic", "Synthetic recovery")
            val done = repo.performPhotoAlbum(row) {}; assertEquals(code != 999, done.finished); assertEquals(code != 999, done.settings!!.rejected)
        }
    }
    @Test fun `存储写前失败零请求且恢复不再尝试`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        try { repo.performPhotoAlbum(row) { if (it.settings!!.attempted) throw IOException("Synthetic storage failure") } } catch (_: IOException) {}
        assertTrue(f.writes.isEmpty()); repo.performPhotoAlbum(row) {}; assertTrue(f.writes.isEmpty())
    }
    @Test fun `更换Photos用户或撤回会话拒绝旧记录`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.owner = 42; repo.access()
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        f.owner = 41; repo.access(); f.after = { if (it.method == "set") { f.after = {}; f.owner = 42; repo.access() } }
        val pending = repo.performPhotoAlbum(row) {}; assertFalse(pending.finished); assertTrue(pending.settings!!.attempted)
        reject { repo.reviewPhotoAlbum(pending) {} }; assertEquals(1, f.writes.size)
    }
    @Test fun `重复策略严格枚举差量保存且后续上传复制读取新默认`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo, SynologyPhotoSettingsKind.DUPLICATES) {
            SynologyPhotoDuplicateSettings(SynologyPhotoUploadDuplicate.RENAME, SynologyPhotoTransferDuplicate.OVERWRITE) }
        assertTrue(repo.performPhotoAlbum(row) {}.finished)
        assertEquals(mapOf("upload_default_action" to "\"rename\"", "copy_move_default_action" to "\"overwrite\""), f.writes.single().fields)
        assertEquals(SynologyPhotoTransferDuplicate.OVERWRITE, repo.transferDuplicate()); assertEquals(SynologyPhotoUploadDuplicate.RENAME, repo.uploadDuplicatePolicy())
        f.field("copy_move_default_action", JsonPrimitive("rename")); reject { repo.photoSettings(SynologyPhotoSettingsKind.DUPLICATES) }
        f.field("copy_move_default_action", null); reject { repo.photoSettings(SynologyPhotoSettingsKind.DUPLICATES) }
    }
    @Test fun `识别只有两侧已知全局开启且个人开启才可修改`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.field("enable_concept", null)
        val value = repo.photoSettings(SynologyPhotoSettingsKind.RECOGNITION) as SynologyPhotoRecognitionSettings
        assertEquals(setOf(SynologyPhotoRecognition.PEOPLE, SynologyPhotoRecognition.SIMILAR), value.known)
        assertEquals(setOf(SynologyPhotoRecognition.PEOPLE), value.editable)
        for (changed in listOf(value.copy(personal = value.personal + (SynologyPhotoRecognition.SIMILAR to false)),
            value.copy(personal = value.personal + (SynologyPhotoRecognition.SUBJECTS to true)), value.copy(global = value.global + (SynologyPhotoRecognition.PEOPLE to false)),
            value.copy(personalEnabled = false))) reject { repo.performPhotoAlbum(f.row(repo, SynologyPhotoSettingsKind.RECOGNITION) { changed }) {} }
        assertTrue(f.writes.isEmpty())
        f.field("enable_home_service", JsonPrimitive(false)); val disabled = repo.photoSettings(SynologyPhotoSettingsKind.RECOGNITION) as SynologyPhotoRecognitionSettings
        assertTrue(disabled.editable.isEmpty()); reject { repo.performPhotoAlbum(f.row(repo, SynologyPhotoSettingsKind.RECOGNITION) { disabled.copy(personal = disabled.personal + (SynologyPhotoRecognition.PEOPLE to false)) }) {} }
    }
    @Test fun `识别仅写变动布尔字段更新个人分类而不改变共享分类`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        assertTrue(SynologyPhotoCategory.PEOPLE in repo.categories(SynologyPhotoSpace.PERSONAL))
        val shared = repo.categories(SynologyPhotoSpace.SHARED)
        val row = f.row(repo, SynologyPhotoSettingsKind.RECOGNITION) { (it as SynologyPhotoRecognitionSettings).copy(personal = it.personal + (SynologyPhotoRecognition.PEOPLE to false)) }
        assertTrue(repo.performPhotoAlbum(row) {}.finished)
        assertEquals(mapOf("enable_person" to "false"), f.writes.single().fields)
        assertFalse(SynologyPhotoCategory.PEOPLE in repo.categories(SynologyPhotoSpace.PERSONAL)); assertEquals(shared, repo.categories(SynologyPhotoSpace.SHARED))
        reject { repo.categoryItems(SynologyPhotoCategory.PEOPLE, 0, 10, SynologyPhotoSpace.PERSONAL) }
        val query = SynologyPhotoQuery.Category(SynologyPhotoCategory.PEOPLE, 9, 0, 100)
        reject { repo.timeline(SynologyPhotoSpace.PERSONAL, query) }; reject { repo.photos(SynologyPhotoSpace.PERSONAL, query, 0, 10) }
    }
    @Test fun `识别回读全局个人条件或已知字段变化不能追认`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo, SynologyPhotoSettingsKind.RECOGNITION) { (it as SynologyPhotoRecognitionSettings).copy(personal = it.personal + (SynologyPhotoRecognition.PEOPLE to false)) }
            f.after = { if (it.method == "set") when (mode) {
                0 -> f.field("enable_home_service", JsonPrimitive(false)); 1 -> f.field("enable_similar", null)
                2 -> f.admin = JsonObject(f.admin + ("enable_person" to JsonPrimitive(false)))
                else -> f.admin = JsonObject(f.admin - "enable_similar")
            } }
            assertFalse(repo.performPhotoAlbum(row) {}.finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `缺少识别字段保持未知且全部未知可读不写`() = runBlocking {
        val f = Fixture(); SynologyPhotoRecognition.entries.forEach { f.field(it.field, null) }; f.admin = obj("""{"package_version":"synthetic"}""")
        val repo = f.ready(); val value = repo.photoSettings(SynologyPhotoSettingsKind.RECOGNITION) as SynologyPhotoRecognitionSettings
        assertTrue(value.known.isEmpty()); assertTrue(value.editable.isEmpty())
        assertTrue(SynologyPhotoCategory.PEOPLE in repo.categories(SynologyPhotoSpace.PERSONAL)); assertTrue(f.writes.isEmpty())
    }
    @Test fun `默认排序保存应用后续无显式目录但保留显式排序`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val sort = SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME, SynologyPhotoSort.Direction.DESCENDING)
        assertTrue(repo.performPhotoAlbum(f.row(repo) { (it as SynologyPhotoDisplaySettings).copy(sort = sort) }) {}.finished)
        assertEquals(sort, repo.folderAccess(SynologyPhotoSpace.PERSONAL, 9).sort)
        f.folder = JsonObject(f.folder + mapOf("sort_by" to JsonPrimitive("filesize"), "sort_direction" to JsonPrimitive("asc")))
        assertEquals(SynologyPhotoSort(SynologyPhotoSort.Field.FILESIZE), repo.folderAccess(SynologyPhotoSpace.PERSONAL, 9).sort)
    }
    @Test fun `自动开关严格布尔读取且只写单字段无需重复确认`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo, SynologyPhotoSettingsKind.AUTOMATIC_PREVIEWS) { SynologyPhotoAutomaticPreviewSettings(false) }
        assertFalse(row.settings!!.needsConfirmation)
        val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { if (it.method == "set") assertTrue(saved.last().settings!!.attempted) }
        assertTrue(repo.performPhotoAlbum(row) { saved += it }.finished)
        assertEquals(mapOf("auto_generate_thumbnail" to "false"), f.writes.single().fields)
        assertEquals(SynologyPhotoAutomaticPreviewSettings(false), repo.photoSettings(SynologyPhotoSettingsKind.AUTOMATIC_PREVIEWS))
        for (bad in listOf(null, JsonNull, JsonPrimitive("true"), JsonPrimitive(1))) {
            f.field("auto_generate_thumbnail", bad); reject { repo.photoSettings(SynologyPhotoSettingsKind.AUTOMATIC_PREVIEWS) }
        }
        assertEquals(1, f.writes.size)
    }
    @Test fun `自动开关丢回执仅按当前值恢复冷启动不重发`() = runBlocking {
        for (applied in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo, SynologyPhotoSettingsKind.AUTOMATIC_PREVIEWS) { SynologyPhotoAutomaticPreviewSettings(false) }
            f.apply = applied; f.writeError = IOException("Synthetic lost receipt")
            val result = repo.performPhotoAlbum(row) {}; assertEquals(applied, result.finished)
            val cold = f.repository(); cold.access(); cold.performPhotoAlbum(result) {}; assertEquals(1, f.writes.size)
            if (!applied) { f.field("auto_generate_thumbnail", JsonPrimitive(false)); assertTrue(cold.reviewPhotoAlbum(result) {}.finished) }
        }
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private val capabilities = (mapOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
            "Browse.Folder" to 2, "Browse.Category" to 3, "Browse.Person" to 1, "Browse.Concept" to 1, "Browse.Timeline" to 5)
            .map { (key, version) -> "SYNO.Foto.$key" to version } + listOf("SYNO.FotoTeam.Browse.Person" to 1, "SYNO.FotoTeam.Browse.Concept" to 1))
            .associate { (name, version) -> name to ApiCapability(name, "entry.cgi", 1, version, "JSON") }
    }
}
