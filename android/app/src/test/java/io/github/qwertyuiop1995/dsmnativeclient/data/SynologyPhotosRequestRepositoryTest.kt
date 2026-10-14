package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 使用实际 Photos 仓储，记录均为合成数据。 */
class SynologyPhotosRequestRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = fields.getValue(key).let(Json::parseToJsonElement)
    }
    private class Fixture {
        val entries = linkedMapOf<String, JsonObject>()
        val calls = mutableListOf<Call>()
        var albums = listOf(album(71, 41, false), album(72, 42, true, "synthetic-album-secret"))
        var user = 41L; var home = true; var team = "management"
        var folderPath = "/Synthetic destination"; var upload = true; var view = true
        var loseReceipt = false; var missingId = false; var applyWrite = true; var repeatedPage = false
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val writes get() = calls.filter { it.method in setOf("create", "update", "delete") }
        fun repository() = SynologyPhotosRepository("request-profile", capabilities(), { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$user,"uid":1041}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"$team"}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
                cap.name.endsWith("Browse.Folder") -> buildJsonObject { put("folder", buildJsonObject {
                    put("id", fields["id"]?.toLong() ?: 1); put("name", if (fields["id"] == "9") folderPath else "/"); put("parent", 0)
                    put("additional", obj("""{"access_permission":{"view":$view,"upload":$upload,"manage":false}}"""))
                }) }
                cap.name.endsWith("Browse.NormalAlbum") -> JsonObject(mapOf("list" to JsonArray(albums.drop(fields.getValue("offset").toInt()).take(500))))
                method == "list" -> JsonObject(mapOf("list" to JsonArray(entries.values.drop(if (repeatedPage) 0 else fields.getValue("offset").toInt()).take(500))))
                method == "create" -> {
                    val raw = record("synthetic-created", SynologyPhotoRequestSettings()).toMutableMap()
                    fields.mapValues { Json.parseToJsonElement(it.value) }.forEach { (k, v) -> if (k != "passphrase") raw[k] = v }
                    raw["folder_id"] = JsonPrimitive(19)
                    if (applyWrite) entries["synthetic-created"] = JsonObject(raw)
                    if (loseReceipt) throw IOException("Synthetic lost receipt")
                    if (missingId) obj("{}") else JsonObject(raw)
                }
                method == "update" -> {
                    val id = call.value("passphrase").jsonPrimitive.content
                    if (applyWrite) {
                        val raw = entries.getValue(id).toMutableMap()
                        fields.mapValues { Json.parseToJsonElement(it.value) }.forEach { (k, v) -> raw[k] = v }
                        if (fields.containsKey("album_id")) raw.remove("album_passphrase")
                        if (fields.containsKey("album_passphrase")) raw.remove("album_id")
                        entries[id] = JsonObject(raw)
                    }
                    if (loseReceipt) throw IOException("Synthetic lost receipt")
                    obj("{}")
                }
                method == "delete" -> {
                    assertEquals("SYNO.Foto.PhotoRequest", cap.name)
                    if (applyWrite) call.value("passphrase").jsonArray.forEach { entries.remove(it.jsonPrimitive.content) }
                    if (loseReceipt) throw IOException("Synthetic lost receipt")
                    obj("{}")
                }
                else -> error("Unexpected synthetic operation")
            }
            after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        fun add(id: String = "synthetic-request", settings: SynologyPhotoRequestSettings = existing()): String {
            entries[id] = record(id, settings); return id
        }
        fun row(action: SynologyPhotoAlbumAction, change: SynologyPhotoRequestChange) = SynologyPhotoAlbumCheckpoint(
            profileId = "request-profile", userId = 41, action = action, request = SynologyPhotoRequestCodec.checkpoint(action, change))
    }
    @Test fun `创建使用明确空口令真实回执和目录核对且持久记录不含秘密`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val settings = defaults().copy(albumPassphrase = "synthetic-album-secret")
        val change = SynologyPhotoRequestChange(settings = settings); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { if (it.method == "create") assertEquals(SynologyPhotoAlbumPhase.SUBMITTING, saved.last().phase) }
        val row = repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, change), change) { saved += it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, row.phase)
        assertEquals("\"\"", f.writes.single().fields["passphrase"])
        assertEquals("\"synthetic-album-secret\"", f.writes.single().fields["album_passphrase"])
        assertFalse(f.writes.single().fields.containsKey("album_id")); assertFalse(f.writes.single().fields.containsKey("folder_id"))
        val serialized = Json.encodeToString(row)
        for (secret in listOf("synthetic-created", "synthetic-album-secret", "Synthetic title", "/PhotoRequest", "example.invalid")) assertFalse(serialized.contains(secret))
        assertTrue(saved.any { it.request?.targetDigest != null && it.phase == SynologyPhotoAlbumPhase.PENDING })
    }
    @Test fun `收集创建在途取消保留未知记录且冷恢复不重发`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val change = SynologyPhotoRequestChange(settings = defaults())
        f.before = { if (it.method == "create") throw CancellationException("Synthetic cancelled transport") }
        val result = repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, change), change) {}
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertFalse(result.finished)
        assertEquals(1, f.writes.size)
        val cold = f.repository(); cold.access(); cold.reviewPhotoAlbum(result) {}
        assertEquals(1, f.writes.size)
    }
    @Test fun `创建丢失或缺编号回执不按同名认领且冷热恢复均不写`() = runBlocking {
        for (lost in listOf(false, true)) {
            val f = Fixture(); f.loseReceipt = lost; f.missingId = !lost; val repo = f.ready()
            val change = SynologyPhotoRequestChange(settings = defaults())
            val row = repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, change), change) {}
            assertFalse(row.finished); assertNull(row.request!!.targetDigest)
            repo.performPhotoRequest(row, change) {}; assertEquals(1, f.writes.size)
            f.ready().reviewPhotoAlbum(Json.decodeFromString(Json.encodeToString(row))) {}; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `已知创建编号缺有效链接或实际设置不匹配不完成`() = runBlocking {
        for (field in listOf("sharing_link", "subject", "is_folder_valid", "folder_home_path")) {
            val f = Fixture(); val repo = f.ready()
            f.after = { if (it.method == "create") f.entries["synthetic-created"] = JsonObject(f.entries.getValue("synthetic-created") +
                (field to if (field == "is_folder_valid") JsonPrimitive(false) else JsonPrimitive("changed"))) }
            val change = SynologyPhotoRequestChange(settings = defaults())
            val row = repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, change), change) {}
            assertNotNull(row.request!!.targetDigest); assertFalse(row.finished)
            repo.reviewPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
        }
    }
    @Test fun `修改只发差量删除相册使用负一并保留未修改的精确大小`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val id = f.add(settings = existing().copy(albumPassphrase = "synthetic-album-secret", sizeLimit = 1_048_577))
        val original = repo.photoRequest(id); val change = SynologyPhotoRequestChange(original, original.settings.copy(description = "new", albumPassphrase = null))
        val result = repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.UPDATE_REQUEST, change), change) {}
        assertTrue(result.finished)
        assertEquals(mapOf("description" to "\"new\"", "album_id" to "-1", "passphrase" to "\"$id\""), f.writes.single().fields)
    }
    @Test fun `修改来源即使路径相同也同时发送来源路径且贡献相册优先`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val old = repo.photoRequest(f.add())
        val change = SynologyPhotoRequestChange(old, old.settings.copy(space = SynologyPhotoSpace.SHARED, albumPassphrase = "synthetic-album-secret"))
        assertTrue(repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.UPDATE_REQUEST, change), change) {}.finished)
        val fields = f.writes.single().fields
        assertEquals("\"shared_space\"", fields["library"]); assertEquals("\"/Synthetic destination\"", fields["folder_home_path"])
        assertFalse(fields.containsKey("album_id")); assertNotNull(fields["album_passphrase"])
    }
    @Test fun `删除允许旧目录失效但必须精确原快照且只删收集链接`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val id = f.add()
        f.entries[id] = JsonObject(f.entries.getValue(id) + ("is_folder_valid" to JsonPrimitive(false))); f.upload = false
        val original = repo.photoRequest(id); val change = SynologyPhotoRequestChange(original)
        f.loseReceipt = true
        assertTrue(repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.DELETE_REQUEST, change), change) {}.finished)
        assertEquals("[\"synthetic-request\"]", f.writes.single().fields["passphrase"])
        assertFalse(f.calls.any { it.api.endsWith("Browse.Folder") })
    }
    @Test fun `删除完整分页缺失才成功重复页和读取失败都保留未知`() = runBlocking {
        for (case in 0..2) {
            val f = Fixture(); val repo = f.ready(); repeat(501) { f.add("synthetic-$it") }
            val old = repo.photoRequest("synthetic-500"); val change = SynologyPhotoRequestChange(old)
            f.after = { if (it.method == "delete") { if (case == 1) f.repeatedPage = true; if (case == 2) f.before = { call -> if (call.method == "list") throw IOException("Synthetic read") } } }
            val row = repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.DELETE_REQUEST, change), change) {}
            assertEquals(case == 0, row.finished); assertEquals(1, f.writes.size)
            if (case == 0) assertTrue(f.calls.count { it.method == "list" && it.fields["offset"] == "500" } >= 3)
        }
    }
    @Test fun `共享entry默认目录禁止已有可上传目录允许并且完整路径必须匹配`() = runBlocking {
        val f = Fixture(); f.home = false; f.team = "entry"; val repo = f.ready()
        for (settings in listOf(defaults().copy(space = SynologyPhotoSpace.SHARED), existing().copy(space = SynologyPhotoSpace.SHARED, folderPath = "/changed"))) {
            val change = SynologyPhotoRequestChange(settings = settings)
            reject { repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, change), change) {} }
        }
        assertTrue(f.writes.isEmpty())
        val settings = existing().copy(space = SynologyPhotoSpace.SHARED)
        val change = SynologyPhotoRequestChange(settings = settings)
        repo.preparePhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, change), change)
        f.upload = false; reject { repo.preparePhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, change), change) }
    }
    @Test fun `权限撤销或账号改变在写前拒绝跨账号操作`() = runBlocking {
        for (case in 0..1) {
            val f = Fixture(); val repo = f.ready(); val change = SynologyPhotoRequestChange(settings = existing())
            if (case == 0) { f.view = false }
            else { f.user = 42; repo.access() }
            reject { repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, change), change) {} }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `原请求快照或候选相册变化拒绝覆盖`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val old = repo.photoRequest(f.add())
        val change = SynologyPhotoRequestChange(old, old.settings.copy(subject = "New"))
        f.entries[old.id] = record(old.id, old.settings.copy(description = "Someone else"))
        reject { repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.UPDATE_REQUEST, change), change) {} }
        val create = SynologyPhotoRequestChange(settings = defaults().copy(albumId = 999))
        reject { repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, create), create) {} }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `相册候选完整分页核对并区分本人贡献和冻结`() = runBlocking {
        val f = Fixture(); f.albums = (1L..501L).map { album(it, 41, false) } + album(502, 42, true, "synthetic-target") +
            JsonObject(album(503, 41, false) + ("freeze_album" to JsonPrimitive(true)))
        val repo = f.ready(); val result = repo.photoRequestAlbums()
        assertEquals(502, result.size); assertEquals(501L, result[500].albumId); assertNull(result.last().albumId)
        assertEquals("synthetic-target", result.last().passphrase)
        val call = f.calls.first(); assertEquals("\"addable\"", call.fields["category"]); assertEquals("\"album_name\"", call.fields["sort_by"])
        f.albums = listOf(album(71, 42, true)); reject { repo.photoRequestAlbums() }
        f.albums = listOf(album(71, 41, true), album(71, 41, true)); reject { repo.photoRequestAlbums() }
    }
    @Test fun `未知修改只读恢复可以确认但不重发`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val old = repo.photoRequest(f.add()); val change = SynologyPhotoRequestChange(old, old.settings.copy(subject = "Edited"))
        f.loseReceipt = true; f.applyWrite = false
        val row = repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.UPDATE_REQUEST, change), change) {}
        assertFalse(row.finished); repo.performPhotoRequest(row, change) {}; assertEquals(1, f.writes.size)
        f.entries[old.id] = record(old.id, change.settings!!)
        assertTrue(f.ready().reviewPhotoAlbum(Json.decodeFromString(Json.encodeToString(row))) {}.finished)
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `保存阶段失败阻止请求和记录回执后的持久化失败不再写`() = runBlocking {
        for (after in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val change = SynologyPhotoRequestChange(settings = defaults()); var saved: SynologyPhotoAlbumCheckpoint? = null
            try {
                repo.performPhotoRequest(f.row(SynologyPhotoAlbumAction.CREATE_REQUEST, change), change) { row ->
                    if (!after || row.request?.targetDigest != null) throw IOException("Synthetic storage")
                    saved = row
                }; fail("Expected storage failure")
            } catch (_: IOException) {}
            assertEquals(if (after) 1 else 0, f.writes.size)
            if (saved != null) { f.ready().reviewPhotoAlbum(saved!!.copy(phase = SynologyPhotoAlbumPhase.PENDING)) {}; assertTrue(f.writes.isEmpty()) }
        }
    }
    @Test fun `字段校验遵循UTF16大小区间和默认路径规则`() {
        assertEquals("/PhotoRequest/_a_b_", SynologyPhotoRequestSettings.defaultFolderPath(" .a:b. "))
        assertEquals("/PhotoRequest/_", SynologyPhotoRequestSettings.defaultFolderPath("@eaDir"))
        for (bad in listOf(defaults().copy(subject = "x "), defaults().copy(subject = "😀".repeat(26)), defaults().copy(description = "x".repeat(101)),
            defaults().copy(sizeLimit = 1), defaults().copy(sizeLimit = 3_145_728_001), defaults().copy(expiration = -1), defaults().copy(albumId = 1, albumPassphrase = "secret"))) {
            try { SynologyPhotoRequestCodec.validate(bad); fail("Expected field rejection") } catch (_: SynologyPhotoFailure) {}
        }
        SynologyPhotoRequestCodec.validate(defaults().copy(subject = "😀".repeat(25), sizeLimit = 3_145_728_000))
    }
    @Test fun `零差量不发送写入持久记录非法字段与错误用途被拒绝`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val old = repo.photoRequest(f.add()); val change = SynologyPhotoRequestChange(old, old.settings)
        val row = f.row(SynologyPhotoAlbumAction.UPDATE_REQUEST, change)
        assertTrue(repo.performPhotoRequest(row, change) {}.finished); assertTrue(f.writes.isEmpty())
        for (bad in listOf(row.copy(name = "raw name"), row.copy(request = row.request!!.copy(targetDigest = "raw secret")),
            row.copy(action = SynologyPhotoAlbumAction.CREATE), row.copy(request = row.request.copy(settingsDigest = null)), row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))) {
            reject { repo.reviewPhotoAlbum(bad) {} }
        }
    }
    companion object {
        private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
        private fun defaults() = SynologyPhotoRequestSettings(subject = "Synthetic title", folderPath = "/PhotoRequest/Synthetic title")
        private fun existing() = defaults().copy(folderId = 9, folderPath = "/Synthetic destination")
        private fun record(id: String, settings: SynologyPhotoRequestSettings) = JsonObject(SynologyPhotoRequestCodec.parameters(settings) + mapOf(
            "passphrase" to JsonPrimitive(id), "is_folder_valid" to JsonPrimitive(true), "folder_id" to JsonPrimitive(settings.folderId ?: 19),
            "sharing_link" to JsonPrimitive("https://example.invalid/collection")))
        private fun album(id: Long, owner: Long, shared: Boolean, secret: String? = null) = buildJsonObject {
            put("id", id); put("owner_user_id", owner); put("name", "Synthetic album $id"); put("shared", shared)
            secret?.let { put("additional", buildJsonObject { put("sharing_info", buildJsonObject { put("passphrase", it) }) }) }
        }
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private fun capabilities() = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            mapOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
                "Browse.Folder" to 2, "Browse.Album" to 4, "Browse.NormalAlbum" to 1, "PhotoRequest" to 1).map { (suffix, version) ->
                val name = "$prefix.$suffix"; name to ApiCapability(name, "entry.cgi", 1, version, "JSON")
            }
        }.toMap()
    }
}
