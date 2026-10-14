package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成接口覆盖相册真实通道；不使用真实账号、共享链接或 NAS。 */
class SynologyPhotosSharingRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = fields[key]?.let(Json::parseToJsonElement)
    }
    private class Fixture {
        var user = 41L; var uid: JsonPrimitive? = JsonPrimitive(1041); var home = true
        var raw = obj("""{"id":71,"name":"Synthetic album","owner_user_id":41,"type":"normal","freeze_album":false,"temporary_shared":false,"shared":true,"additional":{"sharing_info":{"passphrase":"synthetic-private-passphrase","privacy_type":"public-download","sharing_link":"https://example.invalid/synthetic","enable_password":true,"expiration":1700000000,"permission":[{"type":"user","id":51,"name":"Synthetic existing","role":"download"},{"type":"group","id":"51","name":"Synthetic legacy","role":"future-role"},{"type":"public","role":"download"}]}}}""")
        var candidateList = array("""[{"type":"user","id":1041,"name":"Synthetic self"},{"type":"user","id":41,"name":"Synthetic other"},{"type":"user","id":52,"name":"Synthetic new"},{"type":"group","id":52,"name":"Synthetic group"}]""")
        var closeError: Exception? = null; var updateError: Exception? = null; var enableError: Exception? = null
        var applyClose = true; var applyUpdate = true; var applyEnable = true; var closeReceipt = true
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val calls = mutableListOf<Call>()
        val writes get() = calls.filter { it.method in setOf("set_shared", "update") }
        fun field(key: String, value: JsonElement?) { raw = JsonObject(if (value == null) raw - key else raw + (key to value)) }
        fun info(key: String, value: JsonElement?) {
            val original = raw.getValue("additional").jsonObject.getValue("sharing_info").jsonObject
            field("additional", buildJsonObject { put("sharing_info", JsonObject(if (value == null) original - key else original + (key to value))) })
        }
        fun repository() = SynologyPhotosRepository("profile-sharing", capabilities(), { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> buildJsonObject { put("enabled", true); put("id", user); uid?.let { put("uid", it) } }
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"management"}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
                cap.name.endsWith("Browse.Album") && method == "get" -> buildJsonObject { put("list", JsonArray(listOf(raw))) }
                method == "list_user_group" -> buildJsonObject { put("list", candidateList) }
                method == "set_shared" -> {
                    val enabled = call.value("enabled")!!.jsonPrimitive.boolean
                    if (enabled && applyEnable || !enabled && applyClose) field("shared", JsonPrimitive(enabled))
                    (if (enabled) enableError else closeError)?.let { throw it }
                    if (!enabled && closeReceipt) obj("""{"passphrase":"synthetic-private-passphrase"}""") else obj("{}")
                }
                method == "update" -> {
                    if (applyUpdate) {
                        call.value("password")?.let { info("enable_password", JsonPrimitive(it.jsonPrimitive.content.isNotEmpty())) }
                        call.value("expiration")?.let { info("expiration", it) }
                        call.value("permission")?.jsonArray?.forEach { entry ->
                            val change = entry.jsonObject; val member = change.getValue("member").jsonObject
                            val remove = change.getValue("action").jsonPrimitive.content == "delete"
                            if (member.getValue("type").jsonPrimitive.content == "public") info("privacy_type", JsonPrimitive(
                                if (remove) "private" else "public-${change.getValue("role").jsonPrimitive.content}"))
                            val original = raw.getValue("additional").jsonObject.getValue("sharing_info").jsonObject["permission"] as? JsonArray ?: JsonArray(emptyList())
                            val remaining = original.filter { old -> old.jsonObject["type"] != member["type"] || old.jsonObject["id"] != member["id"] }
                            info("permission", JsonArray(remaining + if (remove) emptyList() else listOf(JsonObject(member + mapOf("name" to JsonPrimitive("Synthetic member"), "role" to change.getValue("role"))))))
                        }
                    }
                    updateError?.let { throw it }; obj("{}")
                }
                else -> error("Unexpected synthetic operation: ${cap.name}.$method")
            }
            after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun row(repo: SynologyPhotosRepository, target: SynologyPhotoLinkAccess = SynologyPhotoLinkAccess.INVITED,
            password: SynologyPhotoSharingPassword = SynologyPhotoSharingPassword.UNCHANGED,
            expiration: Long? = null, members: List<SynologyPhotoShareGrant>? = null): SynologyPhotoAlbumCheckpoint {
            val state = repo.albumSharing(71)
            return SynologyPhotoAlbumCheckpoint(profileId = "profile-sharing", userId = 41, action = SynologyPhotoAlbumAction.SHARE,
                album = state.album, sharing = SynologyPhotoSharingChange(state.snapshot, target, members, expiration, password))
        }
    }

    @Test fun `打开只读解析原成员保护和安全链接不生成链接`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val state = repo.albumSharing(71)
        assertEquals(SynologyPhotoLinkAccess.DOWNLOAD, state.snapshot.access)
        assertEquals(listOf("download", "future-role"), state.snapshot.members!!.map { it.role })
        assertTrue(state.snapshot.members[1].id.value.isString); assertFalse(state.snapshot.members[0].id.value.isString)
        assertEquals(true, state.snapshot.hasPassword); assertEquals(1700000000L, state.snapshot.expiration)
        for (url in listOf("https://name:password@example.invalid/x", "file:///x", "javascript:test", "https:///missing", "invalid")) {
            f.info("sharing_link", JsonPrimitive(url)); assertNull(repo.albumSharing(71).url)
        }
        f.field("shared", JsonPrimitive(false)); f.info("privacy_type", JsonPrimitive("future"))
        assertEquals(SynologyPhotoLinkAccess.DISABLED, repo.albumSharing(71).snapshot.access)
        f.field("shared", JsonPrimitive(true)); reject { repo.albumSharing(71) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `未知成员结构不可编辑但单独停止分享不会丢弃成员`() = runBlocking {
        val f = Fixture(); f.info("permission", array("""[{"type":"future","id":1,"role":"view"}]"""))
        f.closeReceipt = false
        val repo = f.ready(); assertNull(repo.albumSharing(71).snapshot.members)
        val done = repo.performPhotoAlbum(f.row(repo, SynologyPhotoLinkAccess.DISABLED)) {}
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        assertEquals(1, f.writes.size); assertEquals(JsonPrimitive(false), f.writes.single().value("enabled"))
    }
    @Test fun `候选排除DSM本人uid而非Photos用户id且保留编号类型`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val recipients = repo.sharingRecipients()
        assertFalse(recipients.any { it.id.value == JsonPrimitive(1041) })
        assertTrue(recipients.any { it.id.value == JsonPrimitive(41) })
        assertEquals(2, recipients.count { it.id.value == JsonPrimitive(52) })
        assertEquals(mapOf("team_space_sharable_list" to "false"), f.calls.last().fields)
        f.uid = null; repo.access(); reject { repo.sharingRecipients() }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `只读摘要稳定比较数字且不保存姓名链接口令`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val before = repo.albumSharing(71)
        f.info("expiration", JsonPrimitive(1700000000.0))
        assertEquals(before.snapshot, repo.albumSharing(71).snapshot)
        val serialized = Json.encodeToString(f.row(repo))
        for (secret in listOf("Synthetic existing", "Synthetic legacy", "example.invalid", "synthetic-private-passphrase")) assertFalse(serialized.contains(secret))
        assertFalse(before.toString().contains("example.invalid"))
    }
    @Test fun `同范围已有链接和关闭空操作均为零写入`() = runBlocking {
        for (closed in listOf(false, true)) {
            val f = Fixture(); f.field("shared", JsonPrimitive(!closed)); val repo = f.ready()
            val done = repo.performPhotoAlbum(f.row(repo, if (closed) SynologyPhotoLinkAccess.DISABLED else SynologyPhotoLinkAccess.DOWNLOAD)) {}
            assertTrue(done.sharingNoChanges); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `同范围缺少链接仍尝试关闭取得并开启且必须回读可用链接`() = runBlocking {
        val f = Fixture(); f.info("sharing_link", null); val repo = f.ready()
        var row = repo.performPhotoAlbum(f.row(repo, SynologyPhotoLinkAccess.DOWNLOAD)) {}
        assertEquals(listOf("set_shared", "set_shared"), f.writes.map { it.method }); assertFalse(row.finished)
        f.info("sharing_link", JsonPrimitive("https://example.invalid/new"))
        row = repo.reviewPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, row.phase)
        assertEquals(2, f.writes.size)
    }
    @Test fun `成员差量密码有效期依序关闭更新保存再开启`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val state = repo.albumSharing(71)
        val desired = listOf(state.snapshot.members!![1], SynologyPhotoShareGrant(SynologyPhotoShareMemberId("user", JsonPrimitive(52)), "upload"))
        val row = f.row(repo, SynologyPhotoLinkAccess.VIEW, SynologyPhotoSharingPassword.SET, 1800000000L, desired)
        val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { call -> when {
            call.method == "update" -> assertTrue(saved.last().sharingUpdateAttempted)
            call.method == "set_shared" && call.value("enabled") == JsonPrimitive(true) -> {
                assertTrue(saved.last().sharingUpdateAcknowledged); assertTrue(saved.last().sharingEnableAttempted)
            }
        } }
        val password = "  合成 only 🔑  "
        val done = repo.performPhotoSharing(row, password) { saved += it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        assertEquals(listOf("set_shared", "update", "set_shared"), f.writes.map { it.method })
        val update = f.writes[1]
        assertEquals(password, update.value("password")!!.jsonPrimitive.content)
        assertEquals(1800000000L, update.value("expiration")!!.jsonPrimitive.long)
        val changes = update.value("permission")!!.jsonArray
        assertEquals(3, changes.size); assertEquals("delete", changes[0].jsonObject.getValue("action").jsonPrimitive.content)
        assertNull(changes[0].jsonObject["role"]); assertEquals(JsonPrimitive(51), changes[0].jsonObject.getValue("member").jsonObject["id"])
        assertFalse(changes.any { it.jsonObject["role"] == JsonPrimitive("future-role") })
        saved.forEach { assertFalse(Json.encodeToString(it).contains(password)) }
        val count = f.writes.size; repo.performPhotoSharing(row, password) {}; assertEquals(count, f.writes.size)
    }
    @Test fun `未改密码期限完全省略并保留未知期限原值`() = runBlocking {
        val f = Fixture(); f.info("expiration", JsonPrimitive("future-expiration")); val repo = f.ready()
        val row = f.row(repo); assertNull(row.sharing!!.original.expiration)
        val done = repo.performPhotoAlbum(row) {}; assertTrue(done.finished)
        val update = f.writes.single { it.method == "update" }
        assertEquals(setOf("passphrase", "permission"), update.fields.keys)
    }
    @Test fun `普通条件和已有冻结分享沿所有权允许但条件新增上传权限拒绝`() = runBlocking {
        for (type in listOf("normal", "condition")) for (frozen in listOf(false, true)) {
            val f = Fixture(); f.field("type", JsonPrimitive(type)); f.field("freeze_album", JsonPrimitive(frozen)); val repo = f.ready()
            assertTrue(repo.performPhotoAlbum(f.row(repo)) {}.finished)
        }
        val f = Fixture(); f.field("type", JsonPrimitive("condition")); val repo = f.ready()
        val state = repo.albumSharing(71); val old = state.snapshot.members!!
        val row = f.row(repo, members = old + SynologyPhotoShareGrant(SynologyPhotoShareMemberId("user", JsonPrimitive(52)), "upload"))
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `新增成员必须在实际候选中且本人和重复身份零写入`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val existing = repo.albumSharing(71).snapshot.members!!
            val member = SynologyPhotoShareGrant(SynologyPhotoShareMemberId("user", JsonPrimitive(if (mode == 0) 999 else if (mode == 1) 1041 else 52)), "view")
            val members = existing + member + if (mode == 2) listOf(member) else emptyList()
            val row = f.row(repo, members = members)
            if (mode == 3) f.after = { call -> if (call.method == "list_user_group") f.info("expiration", JsonPrimitive(9)) }
            val result = runCatching { repo.performPhotoAlbum(row) {} }
            if (mode != 3) assertTrue(result.isFailure) else assertFalse(result.getOrThrow().finished)
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `原相册或分享修订变化及来源权限失效零写入`() = runBlocking {
        for (mode in 0..6) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            when (mode) {
                0 -> f.field("name", JsonPrimitive("Changed")); 1 -> f.field("owner_user_id", JsonPrimitive(42))
                2 -> f.info("expiration", JsonPrimitive(9)); 3 -> f.info("enable_password", JsonPrimitive(false))
                4 -> f.info("privacy_type", JsonPrimitive("private")); 5 -> f.field("temporary_shared", JsonPrimitive(true))
                6 -> { f.home = false; repo.access() }
            }
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `设置密码没有内存输入时不发送且空格有效`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo, password = SynologyPhotoSharingPassword.SET)
        reject { repo.performPhotoAlbum(row) {} }; reject { repo.performPhotoSharing(row, "") {} }; assertTrue(f.writes.isEmpty())
        val done = repo.performPhotoSharing(row, " ") {}; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        assertEquals(" ", f.writes.single { it.method == "update" }.value("password")!!.jsonPrimitive.content)
    }
    @Test fun `关闭未生效或缺少口令不得更新或开启`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture(); if (mode == 0) f.applyClose = false else if (mode == 1) f.closeReceipt = false else f.closeError = IOException("synthetic")
            val repo = f.ready(); val row = repo.performPhotoAlbum(f.row(repo)) {}
            assertEquals(if (mode == 0) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.PARTIAL, row.phase)
            assertEquals(1, f.writes.size); assertFalse(row.sharingEnableAttempted)
        }
    }
    @Test fun `更新未生效或保护成员范围不符绝不扩大访问`() = runBlocking {
        for (mode in 0..4) {
            val f = Fixture(); val repo = f.ready()
            val desired = repo.albumSharing(71).snapshot.members!!.map { it.copy(role = if (it.role == "download") "view" else it.role) }
            val row = f.row(repo, password = SynologyPhotoSharingPassword.REMOVE, expiration = 0, members = desired)
            if (mode == 0) f.applyUpdate = false else f.after = { call -> if (call.method == "update") when (mode) {
                1 -> f.info("enable_password", JsonPrimitive(true)); 2 -> f.info("expiration", JsonPrimitive(1))
                3 -> f.info("permission", JsonArray(emptyList())); 4 -> f.info("privacy_type", JsonPrimitive("public-download"))
            } }
            val done = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, done.phase)
            assertTrue(done.sharingUpdateAcknowledged); assertFalse(done.sharingEnableAttempted)
            assertEquals(listOf("set_shared", "update"), f.writes.map { it.method })
        }
    }
    @Test fun `未知换密回执不凭已有保护追认新密码或继续开启`() = runBlocking {
        for (disabled in listOf(false, true)) {
            val f = Fixture(); f.updateError = IOException("synthetic"); val repo = f.ready()
            val row = f.row(repo, if (disabled) SynologyPhotoLinkAccess.DISABLED else SynologyPhotoLinkAccess.INVITED, SynologyPhotoSharingPassword.SET)
            val done = repo.performPhotoSharing(row, "synthetic-new-password") {}
            assertFalse(done.sharingUpdateAcknowledged); assertFalse(done.sharingEnableAttempted)
            assertEquals(if (disabled) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.PARTIAL, done.phase)
            val cold = f.ready(); val restored = cold.reviewPhotoAlbum(done) {}
            assertEquals(done.phase, restored.phase); assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `清除密码只在明确false时确认即使回执丢失`() = runBlocking {
        val f = Fixture(); f.updateError = IOException("synthetic"); val repo = f.ready()
        val row = f.row(repo, SynologyPhotoLinkAccess.DISABLED, SynologyPhotoSharingPassword.REMOVE)
        val done = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        assertEquals("", f.writes.single { it.method == "update" }.value("password")!!.jsonPrimitive.content)
    }
    @Test fun `开启回执未知只读核实且不自动重放任何阶段`() = runBlocking {
        for (applied in listOf(false, true)) {
            val f = Fixture(); f.applyEnable = applied; f.enableError = IOException("synthetic"); val repo = f.ready()
            val row = repo.performPhotoAlbum(f.row(repo)) {}
            assertTrue(row.sharingEnableAttempted)
            assertEquals(if (applied) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING, row.phase)
            val cold = f.ready(); val reviewed = cold.performPhotoAlbum(row) {}
            assertEquals(row.phase, reviewed.phase); assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `阶段保存失败停止后续写入冷恢复只读`() = runBlocking {
        for (stage in 0..2) {
            val f = Fixture(); val repo = f.ready(); var saved: SynologyPhotoAlbumCheckpoint? = null
            val row = f.row(repo, password = SynologyPhotoSharingPassword.SET)
            try {
                repo.performPhotoSharing(row, "synthetic-password") { next ->
                    if (when (stage) { 0 -> next.sharingUpdateAttempted; 1 -> next.sharingUpdateAcknowledged; else -> next.sharingEnableAttempted }) throw IOException("synthetic storage")
                    saved = next
                }
                fail("Storage failure must be reported")
            } catch (_: IOException) { }
            assertEquals(if (stage == 0) listOf("set_shared") else listOf("set_shared", "update"), f.writes.map { it.method })
            assertNotNull(saved); val cold = f.ready(); val restored = cold.reviewPhotoAlbum(saved!!) {}
            assertEquals(SynologyPhotoAlbumPhase.PARTIAL, restored.phase); assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `读取或关闭后账号代次变化不继续共享写入`() = runBlocking {
        for (onClose in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            f.after = { call -> if (if (onClose) call.method == "set_shared" else call.api.endsWith("Browse.Album") && call.method == "get") {
                f.after = {}; f.user = 42; repo.access()
            } }
            runCatching { repo.performPhotoAlbum(row) {} }
            assertEquals(if (onClose) 1 else 0, f.writes.size)
        }
    }
    @Test fun `本地日末按夏令时短日长日计算`() {
        val zone = ZoneId.of("America/New_York")
        for ((day, hours) in listOf(LocalDate.of(2026, 3, 8) to 23, LocalDate.of(2026, 11, 1) to 25))
            assertEquals(hours * 3600L, photoSharingExpiration(day, zone) + 1 - day.atStartOfDay(zone).toEpochSecond())
    }
    companion object {
        private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
        private fun array(raw: String) = Json.parseToJsonElement(raw).jsonArray
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private fun capabilities() = mapOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
            "Browse.Album" to 4, "Sharing.Passphrase" to 1, "Sharing.Misc" to 2).map { (suffix, version) ->
            val name = "SYNO.Foto.$suffix"; name to ApiCapability(name, "entry.cgi", 1, version, "JSON")
        }.toMap()
    }
}
