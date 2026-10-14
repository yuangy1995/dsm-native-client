package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成 FolderPermission 接口驱动正式 Photos 仓储；不连接真实 NAS。 */
class SynologyPhotosFolderSharingRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = fields[key]?.let(Json::parseToJsonElement)
    }
    private class Fixture {
        var user = 41L; var uid: JsonPrimitive? = JsonPrimitive(1041); var management = true; var home = false
        var raw = obj("""{"id":9,"name":"/Synthetic","parent":1,"shared":true,"additional":{"sharing_info":{"privacy_type":"public-download","sharing_link":"https://example.invalid/folder","enable_password":false,"permission":[{"type":"user","id":51,"name":"Synthetic existing","role":"download"},{"type":"group","id":"51","name":"Synthetic legacy","role":"future-role"}]}}}""")
        var parent = obj("""{"id":1,"name":"/","parent":0,"shared":true}""")
        var candidates = arr("""[{"type":"user","id":1041,"name":"Synthetic self"},{"type":"user","id":41,"name":"Synthetic other"},{"type":"user","id":52,"name":"Synthetic new"},{"type":"group","id":52,"name":"Synthetic group"}]""")
        var config = false; var generatedLink = "https://example.invalid/folder"
        var updateError: Exception? = null; var configError: Exception? = null
        var applyUpdate = true; var applyConfig = true; var failRead = false
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val calls = mutableListOf<Call>()
        val writes get() = calls.filter { it.method in setOf("update", "set_config") }
        fun field(key: String, value: JsonElement?) { raw = JsonObject(if (value == null) raw - key else raw + (key to value)) }
        fun info(key: String, value: JsonElement?) {
            val original = raw.getValue("additional").jsonObject.getValue("sharing_info").jsonObject
            field("additional", buildJsonObject { put("sharing_info", JsonObject(if (value == null) original - key else original + (key to value))) })
        }
        fun repository(profile: String = "folder-sharing", missing: String? = null) = SynologyPhotosRepository(profile, capabilities().filterKeys { it != missing }, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> buildJsonObject { put("enabled", true); put("id", user); uid?.let { put("uid", it) } }
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"${if (management) "management" else "entry"}"}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
                cap.name == "SYNO.FotoTeam.Browse.Folder" && method == "get" -> {
                    if (failRead) throw IOException("Synthetic folder read")
                    buildJsonObject { put("folder", if (call.value("id") == raw["id"]) raw else parent) }
                }
                cap.name == "SYNO.FotoTeam.Sharing.FolderPermission" && method == "get_config" -> buildJsonObject { put("set_to_subfolder", config) }
                cap.name == "SYNO.FotoTeam.Sharing.FolderPermission" && method == "get_folder_link" -> buildJsonObject { put("folder_link", generatedLink) }
                cap.name == "SYNO.Foto.Sharing.Misc" && method == "list_user_group" -> buildJsonObject { put("list", candidates) }
                cap.name == "SYNO.FotoTeam.Sharing.FolderPermission" && method == "update" -> {
                    if (applyUpdate) {
                        val access = call.value("privacy_type")!!.jsonPrimitive.content
                        field("shared", JsonPrimitive(access != "management")); info("privacy_type", JsonPrimitive(access))
                        call.value("password")?.let { info("enable_password", JsonPrimitive(it.jsonPrimitive.content.isNotEmpty())) }
                        call.value("permission")?.jsonArray?.let { changes ->
                            val grants = raw.getValue("additional").jsonObject.getValue("sharing_info").jsonObject["permission"] as? JsonArray ?: JsonArray(emptyList())
                            var updated = grants.toList()
                            changes.forEach { item ->
                                val change = item.jsonObject
                                updated = updated.filterNot { old -> old.jsonObject["id"] == change["id"] && old.jsonObject["type"] == change["type"] }
                                if (change["action"] == JsonPrimitive("update")) updated += JsonObject(change.filterKeys { it != "action" } + ("name" to JsonPrimitive("Synthetic saved")))
                            }
                            info("permission", JsonArray(updated))
                        }
                    }
                    updateError?.let { throw it }; obj("{}")
                }
                cap.name == "SYNO.FotoTeam.Sharing.FolderPermission" && method == "set_config" -> {
                    if (applyConfig) config = call.value("set_to_subfolder")!!.jsonPrimitive.boolean
                    configError?.let { throw it }; obj("{}")
                }
                else -> error("Unexpected synthetic operation: ${cap.name}.$method")
            }
            after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun row(repo: SynologyPhotosRepository, access: SynologyPhotoFolderLinkAccess = SynologyPhotoFolderLinkAccess.VIEW,
            password: SynologyPhotoSharingPassword = SynologyPhotoSharingPassword.UNCHANGED, apply: Boolean = config,
            members: List<SynologyPhotoShareGrant>? = null, folder: SynologyPhotoFolderSnapshot = target): SynologyPhotoAlbumCheckpoint {
            val original = repo.folderSharing(folder).snapshot
            return SynologyPhotoAlbumCheckpoint(profileId = repo.profileId, userId = user, action = SynologyPhotoAlbumAction.SHARE_FOLDER,
                folderSharing = SynologyPhotoFolderSharingCheckpoint(SynologyPhotoFolderSharingChange(original, access, members, password, apply)))
        }
    }

    @Test fun `共享管理读取四范围且个人未启用不阻断无额外写入`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); assertTrue(repo.canManageFolderSharing)
        for (access in SynologyPhotoFolderLinkAccess.entries) {
            f.field("shared", JsonPrimitive(access != SynologyPhotoFolderLinkAccess.MANAGEMENT)); f.info("privacy_type", JsonPrimitive(access.value))
            val state = repo.folderSharing(target)
            assertEquals(access, state.snapshot.access); assertEquals(listOf("download", "future-role"), state.snapshot.members!!.map { it.role })
            assertFalse(state.snapshot.hasPassword!!); assertEquals("https://example.invalid/folder", state.url)
        }
        assertTrue(f.writes.isEmpty()); assertFalse(f.calls.any { it.method == "get_folder_link" || it.method == "set_shared" })
        assertTrue(f.calls.filter { it.api.endsWith("Browse.Folder") }.all { it.api.startsWith("SYNO.FotoTeam") })
    }
    @Test fun `仅未共享且无链接读取实际目录链接不调用开启接口`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.info("sharing_link", null)
        reject { repo.folderSharing(target) }; assertFalse(f.calls.any { it.method == "get_folder_link" })
        f.field("shared", JsonPrimitive(false)); assertNotNull(repo.folderSharing(target).url)
        assertEquals(mapOf("folder_id" to "9"), f.calls.single { it.method == "get_folder_link" }.fields)
        for (url in listOf("https://name:secret@example.invalid/x", "file:///x", "javascript:test", "https:///missing", "")) {
            f.generatedLink = url; reject { repo.folderSharing(target) }
        }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `根更深个人目录与entry账号不可使用权限入口`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        for (folder in listOf(target.copy(name = "/", path = "/"), target.copy(name = "Deep", path = "/Synthetic/Child/Deep"), target.copy(space = SynologyPhotoSpace.PERSONAL)))
            reject { repo.folderSharing(folder) }
        f.management = false; repo.access(); reject { repo.folderSharing(target) }; reject { repo.folderSharingRecipients() }
        assertTrue(f.writes.isEmpty()); assertFalse(f.calls.any { it.api.endsWith("Browse.Folder") })
    }
    @Test fun `目录与父目录编号路径共享标志均不可猜测`() = runBlocking {
        for (mode in 0..6) {
            val f = Fixture(); val repo = f.ready()
            when (mode) {
                0 -> f.field("id", JsonPrimitive(8)); 1 -> f.field("name", JsonPrimitive("/Renamed")); 2 -> f.field("parent", JsonPrimitive(2))
                3 -> f.field("shared", null); 4 -> f.parent = obj("""{"id":2,"name":"/","shared":true}""")
                5 -> f.parent = obj("""{"id":1,"name":"/Other","shared":true}"""); 6 -> f.parent = obj("""{"id":1,"name":"/"}""")
            }
            reject { repo.folderSharing(target) }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `第二层父未共享只读且隐藏默认项不能改写`() = runBlocking {
        val f = Fixture(); f.field("name", JsonPrimitive("/Parent/Synthetic")); f.parent = obj("""{"id":1,"name":"/Parent","shared":false}""")
        val folder = target.copy(path = "/Parent/Synthetic"); val repo = f.ready()
        val state = repo.folderSharing(folder); assertTrue(state.snapshot.inheritsManagementOnly)
        reject { repo.performPhotoAlbum(f.row(repo, folder = folder)) {} }
        f.parent = obj("""{"id":1,"name":"/Parent","shared":true}""")
        reject { repo.performPhotoAlbum(f.row(repo, folder = folder, apply = true)) {} }
        assertTrue(f.writes.isEmpty()); assertTrue(repo.performPhotoAlbum(f.row(repo, folder = folder)) {}.finished)
    }
    @Test fun `未知成员和保护标志保留未知而非清空并保留未改角色`() = runBlocking {
        for (raw in listOf<JsonElement?>(null, JsonPrimitive("future"), arr("""[{"type":"future","id":1,"role":"view"}]"""))) {
            val f = Fixture(); f.info("permission", raw); f.info("enable_password", null); val repo = f.ready()
            val state = repo.folderSharing(target); assertNull(state.snapshot.members); assertNull(state.snapshot.hasPassword)
            reject { repo.performPhotoAlbum(f.row(repo, members = emptyList())) {} }
            val done = repo.performPhotoAlbum(f.row(repo)) {}; assertTrue(done.finished)
            assertFalse(f.writes.single().fields.containsKey("permission")); assertFalse(f.writes.single().fields.containsKey("password"))
        }
    }
    @Test fun `共享候选排除系统uid保留用户群组和数字字符串身份`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val candidates = repo.folderSharingRecipients()
        assertFalse(candidates.any { it.id.value == JsonPrimitive(1041) }); assertTrue(candidates.any { it.id.value == JsonPrimitive(41) })
        assertEquals(2, candidates.count { it.id.value == JsonPrimitive(52) })
        assertEquals(mapOf("team_space_sharable_list" to "true"), f.calls.last().fields)
        f.uid = null; repo.access(); reject { repo.folderSharingRecipients() }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `完整修订含归属与原始权限但恢复不含成员姓名链接和密码`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.info("numeric_extension", JsonPrimitive(9)); val original = repo.folderSharing(target).snapshot
        f.info("numeric_extension", JsonPrimitive(9.0)); assertEquals(original, repo.folderSharing(target).snapshot)
        val other = f.repository("other-profile"); other.access(); assertNotEquals(original.revision, other.folderSharing(target).snapshot.revision)
        f.info("custom", JsonPrimitive("future-field")); assertNotEquals(original.revision, repo.folderSharing(target).snapshot.revision)
        val raw = Json.encodeToString(f.row(repo))
        for (secret in listOf("Synthetic existing", "Synthetic legacy", "example.invalid", "future-field")) assertFalse(raw.contains(secret))
    }
    @Test fun `扁平成员变更保留原删除角色且所有保留项发送update`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val original = repo.folderSharing(target).snapshot.members!!
        val desired = listOf(original[1], SynologyPhotoShareGrant(SynologyPhotoShareMemberId("user", JsonPrimitive(52)), "manage"))
        val row = f.row(repo, members = desired); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        val done = repo.performPhotoAlbum(row) { saved += it; validatePhotoAlbumCheckpoint(it) }; assertTrue(done.finished)
        val changes = f.writes.single().value("permission")!!.jsonArray
        assertEquals(3, changes.size)
        assertEquals(obj("""{"id":51,"type":"user","role":"download","action":"delete"}"""), changes[0])
        assertEquals(obj("""{"id":"51","type":"group","role":"future-role","action":"update"}"""), changes[1])
        assertEquals(obj("""{"id":52,"type":"user","role":"manage","action":"update"}"""), changes[2])
        assertTrue(saved.any { it.folderSharing!!.updateAcknowledged })
    }
    @Test fun `未改变名单不发送权限数组且四种新增角色均可保存`() = runBlocking {
        for (role in listOf("view", "download", "upload", "manage")) {
            val f = Fixture(); val repo = f.ready(); val old = repo.folderSharing(target).snapshot.members!!
            val desired = old.map { if (it.id.value == JsonPrimitive(51)) it.copy(role = role) else it }
            val done = repo.performPhotoAlbum(f.row(repo, members = desired)) {}; assertTrue(done.finished)
            assertEquals(role != "download", f.writes.single().fields.containsKey("permission"))
        }
    }
    @Test fun `新成员必须为实际候选且本人重复未知新角色零写入`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val old = repo.folderSharing(target).snapshot.members!!
            val added = SynologyPhotoShareGrant(SynologyPhotoShareMemberId("user", JsonPrimitive(if (mode == 0) 999 else if (mode == 1) 1041 else 52)), if (mode == 3) "future" else "view")
            reject { repo.performPhotoAlbum(f.row(repo, members = old + added + if (mode == 2) listOf(added) else emptyList())) {} }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `密码三态保持省略移除空串设置完整Unicode且回执先于默认保存`() = runBlocking {
        for (mode in SynologyPhotoSharingPassword.entries) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo, password = mode, apply = true)
            val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
            f.before = { call -> if (call.method == "update") assertTrue(saved.last().folderSharing!!.updateAttempted)
                else if (call.method == "set_config") { assertTrue(saved.last().folderSharing!!.updateAcknowledged); assertTrue(saved.last().folderSharing!!.configAttempted) } }
            val password = "  合成🔑  "
            val done = repo.performPhotoFolderSharing(row, password.takeIf { mode == SynologyPhotoSharingPassword.SET }) { saved += it }
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertEquals(listOf("update", "set_config"), f.writes.map { it.method })
            assertEquals(when (mode) { SynologyPhotoSharingPassword.UNCHANGED -> null; SynologyPhotoSharingPassword.REMOVE -> JsonPrimitive(""); SynologyPhotoSharingPassword.SET -> JsonPrimitive(password) }, f.writes[0].value("password"))
            saved.forEach { assertFalse(Json.encodeToString(it).contains(password)) }
        }
    }
    @Test fun `未提供内存密码不能发出请求空格密码保持原样`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo, password = SynologyPhotoSharingPassword.SET)
        reject { repo.performPhotoAlbum(row) {} }; reject { repo.performPhotoFolderSharing(row, "") {} }; assertTrue(f.writes.isEmpty())
        assertTrue(repo.performPhotoFolderSharing(row, " ") {}.finished); assertEquals(JsonPrimitive(" "), f.writes.single().value("password"))
    }
    @Test fun `预检原状态任何变化拒绝且候选读取之后再检测并发修改`() = runBlocking {
        for (mode in 0..5) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            when (mode) {
                0 -> f.field("name", JsonPrimitive("/Changed")); 1 -> f.info("enable_password", JsonPrimitive(true)); 2 -> f.info("custom", JsonPrimitive("new"))
                3 -> f.config = true; 4 -> f.parent = obj("""{"id":1,"name":"/","shared":false}"""); 5 -> { f.management = false; repo.access() }
            }
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val repo = f.ready(); val old = repo.folderSharing(target).snapshot.members!!
        val row = f.row(repo, members = old + SynologyPhotoShareGrant(SynologyPhotoShareMemberId("user", JsonPrimitive(52)), "view"))
        f.after = { if (it.method == "list_user_group") f.info("custom", JsonPrimitive("changed after candidates")) }
        val done = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, done.phase); assertTrue(done.folderSharing!!.rejected)
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `接口缺失不借用相册权限接口且失去代次停止后续请求`() = runBlocking {
        val f = Fixture(); val repo = f.repository(missing = "SYNO.FotoTeam.Sharing.FolderPermission"); repo.access()
        assertFalse(repo.canManageFolderSharing); reject { repo.folderSharing(target) }
        val current = f.ready(); val row = f.row(current, apply = true)
        f.after = { if (it.method == "update") { f.after = {}; f.management = false; current.access() } }
        val pending = current.performPhotoAlbum(row) {}; assertFalse(pending.finished); assertTrue(pending.folderSharing!!.updateAcknowledged)
        assertEquals(listOf("update"), f.writes.map { it.method })
    }
    @Test fun `丢失密码或子目录回执不能凭顶层匹配追认完成`() = runBlocking {
        for (password in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); f.updateError = IOException("Synthetic missing receipt")
            val row = f.row(repo, password = if (password) SynologyPhotoSharingPassword.SET else SynologyPhotoSharingPassword.UNCHANGED, apply = !password)
            val done = repo.performPhotoFolderSharing(row, "Synthetic secret".takeIf { password }) {}
            assertEquals(SynologyPhotoAlbumPhase.PENDING, done.phase); assertFalse(done.folderSharing!!.updateAcknowledged); assertFalse(done.folderSharing.configAttempted)
            val count = f.writes.size; val cold = f.repository(); cold.access(); assertFalse(cold.performPhotoAlbum(done) {}.finished)
            assertEquals(count, f.writes.size)
        }
    }
    @Test fun `普通权限丢回执只读结果确认并且重复调用绝不重放`() = runBlocking {
        for (applied in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); f.applyUpdate = applied; f.updateError = IOException("Synthetic missing receipt")
            val input = f.row(repo); val row = repo.performPhotoAlbum(input) {}
            assertEquals(applied, row.finished); assertEquals(1, f.writes.size)
            val cold = f.repository(); cold.access(); cold.performPhotoAlbum(row) {}; repo.performPhotoAlbum(input) {}
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `默认保存失败明确部分完成而不重发权限或默认设置`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.applyConfig = false; f.configError = IOException("Synthetic config failure")
        val row = repo.performPhotoAlbum(f.row(repo, apply = true)) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase)
        assertTrue(row.folderSharing!!.updateAcknowledged); assertTrue(row.folderSharing.configAttempted)
        val cold = f.repository(); cold.access(); assertEquals(row, cold.reviewPhotoAlbum(row) {})
        assertEquals(2, f.writes.size)
    }
    @Test fun `明确权限拒绝结束记录读取失败保留未知事实`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.applyUpdate = false; f.updateError = DsmFailure(105, "Synthetic denied", "Synthetic recovery")
        val rejected = repo.performPhotoAlbum(f.row(repo)) {}; assertTrue(rejected.folderSharing!!.rejected); assertTrue(rejected.finished)
        val g = Fixture(); val current = g.ready(); val row = g.row(current)
        g.after = { if (it.method == "update") g.failRead = true }
        val pending = current.performPhotoAlbum(row) {}; assertFalse(pending.finished); assertTrue(pending.folderSharing!!.updateAcknowledged)
        g.failRead = false; val cold = g.repository(); cold.access(); assertTrue(cold.reviewPhotoAlbum(pending) {}.finished); assertEquals(1, g.writes.size)
    }
    @Test fun `写前存储失败零写回执存储失败不得继续默认设置`() = runBlocking {
        for (ack in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo, apply = true)
            runCatching { repo.performPhotoAlbum(row) { if (!ack || it.folderSharing!!.updateAcknowledged) throw IOException("Synthetic storage failure") } }
            assertEquals(if (ack) 1 else 0, f.writes.size); assertFalse(f.writes.any { it.method == "set_config" })
        }
    }
    @Test fun `冷恢复未尝试写入只结束原记录而不能提交原意图`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo).copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        val done = repo.performPhotoAlbum(row) {}; assertTrue(done.finished); assertTrue(done.folderSharing!!.rejected); assertTrue(f.writes.isEmpty())
    }
    companion object {
        private val target = SynologyPhotoFolderSnapshot(9, 1, "Synthetic", "/Synthetic", SynologyPhotoSpace.SHARED)
        private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
        private fun arr(raw: String) = Json.parseToJsonElement(raw).jsonArray
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected folder permission rejection") } catch (_: SynologyPhotoFailure) {} }
        private fun capabilities() = (mapOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1, "Sharing.Misc" to 1)
            .map { (suffix, version) -> "SYNO.Foto.$suffix" to version } + listOf("SYNO.FotoTeam.Browse.Folder" to 2, "SYNO.FotoTeam.Sharing.FolderPermission" to 1))
            .associate { (name, version) -> name to ApiCapability(name, "entry.cgi", 1, version, "JSON") }
    }
}
