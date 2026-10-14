package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成成员和两层目录驱动正式仓储，不读取或修改真实NAS账号。 */
class SynologyPhotosSharedMembersRepositoryTest {
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>)
    private class Fixture {
        var admin = true; var id = 41L; var enabled = true; var role = "management"
        var members = listOf(member(41, "self", "management", true), member(50, "test-member", "entry", false), member(2, "administrators", "management", true, "group"))
        var candidates = listOf(recipient(41, "self"), recipient(50, "test-member"), recipient(60, "new-member"), recipient(2, "administrators", "group"))
        val folders = linkedMapOf(2L to folder(2, 1, "/first", "view"), 3L to folder(3, 2, "/first/child", "view"), 4L to folder(4, 1, "/public", null, "public-download"))
        var directArray = true; var candidatesError = false
        var applyWrite: (Call) -> Boolean = { true }; var writeError: (Call) -> Exception? = { null }; var before: suspend (Call) -> Unit = {}
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method in setOf("update_permission", "update_all_by_member", "update_by_member") }
        fun repository(missing: String? = null) = SynologyPhotosRepository("shared-members", capabilities.filterKeys { it != missing }, { cap, method, fields ->
            val call = Call(cap.name, cap.maxVersion, method, fields); calls += call; before(call)
            when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$id,"is_admin":$admin}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"$role","enable_person":true,"enable_concept":true,"enable_similar":true}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_person":true,"enable_concept":true,"enable_similar":true}""")
                method == "update_permission" || method == "update_all_by_member" || method == "update_by_member" -> {
                    if (applyWrite(call)) apply(call)
                    writeError(call)?.let { throw it }; obj("{}")
                }
                method == "list_permission" -> JsonObject(mapOf((if (directArray) "_array" else "list") to JsonArray(members)))
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$enabled,"enable_person":true,"enable_concept":true,"enable_similar":true}""")
                method == "list_user_group" -> { if (candidatesError) throw IOException("Synthetic candidate failure"); JsonObject(mapOf("list" to JsonArray(candidates))) }
                cap.name.endsWith("Browse.Folder") && method == "get" -> JsonObject(mapOf("folder" to if (fields["id"] == null) obj("""{"id":1,"name":"/","parent":0}""") else folders[fields.getValue("id").toLong()]!!))
                cap.name.endsWith("Browse.Folder") && method == "list" -> {
                    val parent = fields.getValue("id").toLong(); val offset = fields.getValue("offset").toInt()
                    JsonObject(mapOf("list" to JsonArray(folders.values.filter { it.getValue("parent").jsonPrimitive.long == parent }.drop(offset).take(200))))
                }
                else -> error("Unexpected synthetic call ${cap.name}.$method")
            }
        })
        private fun apply(call: Call) {
            if (call.method == "update_permission") {
                Json.parseToJsonElement(call.fields.getValue("list")).jsonArray.forEach { entry ->
                    val change = entry.jsonObject; val old = members.firstOrNull { sameId(it, change) }
                    members = members.filterNot { sameId(it, change) }
                    if (change.getValue("action").jsonPrimitive.content != "delete") members += JsonObject(change - "action" + ("name" to (old?.get("name") ?: candidates.first { sameId(it, change) }.getValue("name"))))
                }; return
            }
            val permission = Json.parseToJsonElement(call.fields.getValue("permission")).jsonObject
            val member = (permission["member"] as? JsonObject) ?: permission
            fun set(folderId: Long, role: String?) {
                val raw = folders[folderId]!!; val additional = raw.getValue("additional").jsonObject; val sharing = additional.getValue("sharing_info").jsonObject
                val grants = sharing.getValue("permission").jsonArray.filterNot { sameId(it.jsonObject, member) }.toMutableList()
                if (role != null) grants += buildJsonObject { put("id", member.getValue("id")); put("type", member.getValue("type")); put("role", role) }
                folders[folderId] = JsonObject(raw + ("additional" to JsonObject(additional + ("sharing_info" to JsonObject(sharing + ("permission" to JsonArray(grants)))))))
            }
            if (call.method == "update_all_by_member") {
                val batch = SynologyPhotoMemberFolderBatch(SynologyPhotoFolderMemberRole.from(permission.getValue("role").jsonPrimitive.content)!!,
                    permission.getValue("action").jsonPrimitive.content == "check_all")
                folders.keys.toList().forEach { folderId ->
                    val grants = folders[folderId]!!.getValue("additional").jsonObject.getValue("sharing_info").jsonObject.getValue("permission").jsonArray
                    set(folderId, batch.applying(grants.firstOrNull { sameId(it.jsonObject, member) }?.jsonObject?.get("role")?.jsonPrimitive?.content))
                }
            } else permission.getValue("list").jsonArray.forEach { entry ->
                val value = entry.jsonObject; val folderId = value.getValue("folder_id").jsonPrimitive.long
                val role = value["role"]?.jsonPrimitive?.content; set(folderId, role)
                if (role == null && folders[folderId]!!.getValue("additional").jsonObject.getValue("sharing_info").jsonObject.getValue("privacy_type").jsonPrimitive.content == "private")
                    folders.values.filter { it.getValue("parent").jsonPrimitive.long == folderId }.forEach { set(it.getValue("id").jsonPrimitive.long, null) }
            }
        }
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun checkpoint(repo: SynologyPhotosRepository, directories: Boolean = false): SynologyPhotoAlbumCheckpoint {
            val original = repo.sharedMembers().snapshot
            val desired = original.members.map { if (it.id == target) it.copy(autoBackup = true) else it }
            val edits = if (directories) listOf(SynologyPhotoMemberFolderEdit(target, repo.sharedMemberFolders(target).map { it.snapshot })
                .withBatch(SynologyPhotoMemberFolderBatch(SynologyPhotoFolderMemberRole.UPLOAD, true))) else emptyList()
            return SynologyPhotoAlbumCheckpoint(profileId = "shared-members", userId = 41, action = SynologyPhotoAlbumAction.SHARED_MEMBERS,
                sharedMembers = SynologyPhotoSharedMembersCheckpoint(original, desired, edits))
        }
    }
    @Test fun `直接数组与候选本人保留路由参数类型正确`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); assertTrue(repo.canManageSharedMembers)
        val actual = repo.sharedMembers(); assertEquals(3, actual.members.size); assertTrue(actual.members.last().grant.protected)
        assertEquals(4, repo.sharedMemberCandidates().size)
        val calls = f.calls.filter { it.method in setOf("list_permission", "list_user_group") }
        assertTrue(calls.all { it.api.startsWith("SYNO.Foto.") && it.version == 1 && it.fields.isEmpty() })
        f.directArray = false; reject { repo.sharedMembers() }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `成员数字与字符串身份分离未知角色与保护群组不能改写`() = runBlocking {
        val f = Fixture(); f.members = f.members + obj("""{"id":"50","type":"user","name":"string-id","permission":"future","auto_backup":false}""")
        val repo = f.ready(); val row = f.checkpoint(repo)
        assertEquals(4, row.sharedMembers!!.original.members.size)
        for (remove in listOf(row.sharedMembers.original.members.last().id, row.sharedMembers.original.members[2].id)) {
            reject { repo.performPhotoAlbum(row.copy(sharedMembers = row.sharedMembers.copy(desired = row.sharedMembers.desired.filterNot { it.id == remove }))) {} }
        }
        val done = repo.performPhotoAlbum(row) {}; assertTrue(done.finished); assertEquals(1, f.writes.size)
        val sent = Json.parseToJsonElement(f.writes.single().fields.getValue("list")).jsonArray.single().jsonObject
        assertEquals(JsonPrimitive(50), sent["id"]); assertEquals(setOf("action", "type", "id", "permission", "auto_backup"), sent.keys)
    }
    @Test fun `删除携带原角色与备份只发实际差量`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo); val value = row.sharedMembers!!
        val done = repo.performPhotoAlbum(row.copy(sharedMembers = value.copy(desired = value.original.members.filterNot { it.id == target }))) {}
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        assertEquals(JsonArray(listOf(obj("""{"id":50,"type":"user","action":"delete","permission":"entry","auto_backup":false}"""))), Json.parseToJsonElement(f.writes.single().fields.getValue("list")))
    }
    @Test fun `新增复查真实候选候选失败不影响旧成员`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo); f.candidatesError = true
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row) {}.phase)
        val next = f.checkpoint(repo); val value = next.sharedMembers!!
        val added = SynologyPhotoSharedMemberGrant(SynologyPhotoShareMemberId("user", JsonPrimitive(60)), "entry", false)
        f.candidatesError = false; f.candidates = f.candidates.filterNot { it["id"] == JsonPrimitive(60) }
        reject { repo.performPhotoAlbum(next.copy(sharedMembers = value.copy(desired = value.original.members + added))) {} }
        assertEquals(1, f.writes.size)
    }
    @Test fun `候选中的系统管理员群组仍不能作为新成员提交`() = runBlocking {
        val f = Fixture(); f.members = f.members.filterNot { it["type"] == JsonPrimitive("group") }
        val repo = f.ready(); val row = f.checkpoint(repo); val value = row.sharedMembers!!
        val protected = SynologyPhotoSharedMemberGrant(SynologyPhotoShareMemberId("group", JsonPrimitive(2)), "management", true)
        reject { repo.performPhotoAlbum(row.copy(sharedMembers = value.copy(desired = value.original.members + protected))) {} }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `DSM管理员身份共享启用并发名单缺能力均拒绝零写入`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo)
            when (mode) { 0 -> f.admin = false; 1 -> f.id = 42; 2 -> f.enabled = false; else -> f.members = f.members + member(70, "concurrent", "entry", false) }
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val repo = f.repository("SYNO.FotoTeam.Sharing.FolderBatchPermission"); repo.access(); assertFalse(repo.canManageSharedMembers)
        val row = f.checkpoint(repo, true); reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `完整两层分页包含超过二百目录且未读取第三层`() = runBlocking {
        val f = Fixture(); f.folders.clear()
        repeat(202) { f.folders[it + 2L] = folder(it + 2L, 1, "/folder-$it", "view") }
        f.folders[500] = folder(500, 2, "/folder-0/child", "view"); f.folders[600] = folder(600, 500, "/folder-0/child/deeper", "view")
        val repo = f.ready(); val result = repo.sharedMemberFolders(target); assertEquals(203, result.size)
        val rootPages = f.calls.filter { it.method == "list" && it.fields["id"] == "1" }
        assertEquals(listOf("0", "200"), rootPages.map { it.fields["offset"] })
        assertTrue(rootPages.all { it.api == "SYNO.FotoTeam.Browse.Folder" && it.version == 2 && it.fields["limit"] == "200" && it.fields["additional"] == "[\"sharing_info\"]" })
        assertFalse(f.calls.any { it.method == "list" && it.fields["id"] == "500" })
    }
    @Test fun `重复目录父身份或权限在扫描期间变化拒绝旧快照`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo, true)
        f.folders[2] = folder(2, 1, "/renamed", "view"); reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        val g = Fixture(); val api = g.ready()
        g.before = { if (it.method == "get" && it.fields["id"] == "2") g.folders[2] = folder(2, 1, "/first", "download") }
        reject { api.sharedMemberFolders(target) }; assertTrue(g.writes.isEmpty())
    }
    @Test fun `成员批量单目录按序发送先持久化尝试及回执`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo, true); val value = row.sharedMembers!!
        val edit = value.folders.single().withRole(value.folders.single().original.first(), SynologyPhotoFolderMemberRole.MANAGE)
        val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { if (it.method in setOf("update_permission", "update_all_by_member", "update_by_member")) {
            assertEquals(f.writes.size, saved.last().sharedMembers!!.attempted.size); assertEquals(f.writes.size - 1, saved.last().sharedMembers!!.acknowledged.size)
        } }
        val done = repo.performPhotoAlbum(row.copy(sharedMembers = value.copy(folders = listOf(edit)))) { saved += it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertEquals(setOf(0, 1, 2), done.sharedMembers!!.completed)
        assertEquals(listOf("update_permission", "update_all_by_member", "update_by_member"), f.writes.map { it.method })
        assertEquals(setOf("permission"), f.writes.last().fields.keys)
        repo.performPhotoAlbum(done) {}; assertEquals(3, f.writes.size)
    }
    @Test fun `公开下限等价未知未改权限不阻断单项批量则拒绝`() = runBlocking {
        val f = Fixture(); f.folders[3] = folder(3, 2, "/first/child", "future")
        val repo = f.ready(); val all = repo.sharedMemberFolders(target).map { it.snapshot }
        val edit = SynologyPhotoMemberFolderEdit(target, all)
        assertEquals(edit, edit.withBatch(SynologyPhotoMemberFolderBatch(SynologyPhotoFolderMemberRole.MANAGE, true)))
        assertFalse(edit.withRole(all.first { it.id == 4L }, SynologyPhotoFolderMemberRole.VIEW).canSave)
        val changed = edit.withRole(all.first(), SynologyPhotoFolderMemberRole.DOWNLOAD)
        assertTrue(changed.canSave)
        val row = f.checkpoint(repo); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row.copy(sharedMembers = row.sharedMembers!!.copy(folders = listOf(changed)))) {}.phase)
    }
    @Test fun `私有父撤权清除子草稿删除不传role且最后检查子权限`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val all = repo.sharedMemberFolders(target).map { it.snapshot }
        val edit = SynologyPhotoMemberFolderEdit(target, all).withRole(all.first { it.id == 3L }, SynologyPhotoFolderMemberRole.UPLOAD).withRole(all.first { it.id == 2L }, null)
        assertEquals(listOf(2L), edit.changes.map { it.folderId }); assertNull(edit.expectedRole(all.first { it.id == 3L }))
        val row = f.checkpoint(repo); val done = repo.performPhotoAlbum(row.copy(sharedMembers = row.sharedMembers!!.copy(folders = listOf(edit)))) {}
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        val list = Json.parseToJsonElement(f.writes.last().fields.getValue("permission")).jsonObject.getValue("list").jsonArray
        assertEquals(setOf("folder_id", "action"), list.single().jsonObject.keys)
    }
    @Test fun `未知回执冷恢复只读成员已完成目录未尝试只能部分完成`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo, true)
        f.writeError = { IOException("Synthetic receipt loss") }
        val partial = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, partial.phase)
        assertEquals(setOf(0), partial.sharedMembers!!.completed); assertEquals(1, f.writes.size)
        val cold = f.repository(); cold.access(); cold.performPhotoAlbum(partial) {}; assertEquals(1, f.writes.size)
    }
    @Test fun `未知未生效保持pending重启不重发后来实际匹配才结束`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo); f.applyWrite = { false }; f.writeError = { IOException("Synthetic timeout") }
        val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
        val cold = f.repository(); cold.access(); assertEquals(SynologyPhotoAlbumPhase.PENDING, cold.performPhotoAlbum(pending) {}.phase)
        f.members = f.members.map { if (it["id"] == JsonPrimitive(50)) JsonObject(it + ("auto_backup" to JsonPrimitive(true))) else it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, cold.reviewPhotoAlbum(pending) {}.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `结构化失败仍读取真实结果允许已生效而不能补发后续`() = runBlocking {
        for (applied in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo, true)
            f.applyWrite = { applied }; f.writeError = { DsmFailure(400, "Synthetic", "Synthetic") }
            val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase)
            assertEquals(if (applied) setOf(0) else emptySet<Int>(), result.sharedMembers!!.completed)
            assertEquals(setOf(0), result.sharedMembers.rejected); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `批量后单项失败按实际覆盖区分全部与部分且不重发`() = runBlocking {
        for (applied in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo, true); val value = row.sharedMembers!!
            val edit = value.folders.single().withRole(value.folders.single().original.first(), SynologyPhotoFolderMemberRole.MANAGE)
            f.writeError = { if (it.method == "update_by_member") DsmFailure(400, "Synthetic", "Synthetic") else null }
            f.applyWrite = { it.method != "update_by_member" || applied }
            val done = repo.performPhotoAlbum(row.copy(sharedMembers = value.copy(folders = listOf(edit)))) {}
            assertEquals(if (applied) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PARTIAL, done.phase)
            assertEquals(if (applied) setOf(0, 1, 2) else setOf(0, 1), done.sharedMembers!!.completed)
            assertEquals(setOf(2), done.sharedMembers.rejected)
            repo.performPhotoAlbum(done) {}; assertEquals(3, f.writes.size)
        }
    }
    @Test fun `前次匹配不能掩盖后次成员并发改变`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo, true)
        f.applyWrite = { it.method == "update_permission" }
        val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
        assertEquals(setOf(0), pending.sharedMembers!!.completed)
        f.members = f.members.map { if (it["id"] == JsonPrimitive(50)) JsonObject(it + ("auto_backup" to JsonPrimitive(false))) else it }
        f.folders.keys.toList().forEach { id -> val raw = f.folders[id]!!; f.folders[id] = folder(id, raw.getValue("parent").jsonPrimitive.long, raw.getValue("name").jsonPrimitive.content, "upload", if (id == 4L) "public-download" else "private") }
        assertEquals(SynologyPhotoAlbumPhase.PENDING, repo.reviewPhotoAlbum(pending) {}.phase); assertEquals(2, f.writes.size)
    }
    @Test fun `本人角色变化最终读取实际设置不从改动群组猜权限`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo)
        f.before = { if (it.method == "update_permission") f.role = "entry" }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row) {}.phase)
        assertEquals(SynologyPhotoSharedSettings.Role.ENTRY, (repo.photoSettings(SynologyPhotoSettingsKind.SHARED) as SynologyPhotoSharedSettings).role)
        assertTrue(f.calls.any { it.api == "SYNO.Foto.Setting.User" }); assertEquals(1, f.writes.size)
    }
    @Test fun `发送前存储失败零写回执存储失败停止后续且恢复不重发`() = runBlocking {
        for (ack in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.checkpoint(repo, true); var saved = row
            try { repo.performPhotoAlbum(row) { next ->
                val progress = next.sharedMembers!!
                if (if (ack) progress.acknowledged.isNotEmpty() else progress.attempted.isNotEmpty()) throw IOException("Synthetic storage failure")
                saved = next
            } } catch (_: IOException) {}
            assertEquals(if (ack) 1 else 0, f.writes.size)
            val cold = f.repository(); cold.access(); cold.performPhotoAlbum(saved) {}; assertEquals(if (ack) 1 else 0, f.writes.size)
        }
    }
    companion object {
        private val target = SynologyPhotoShareMemberId("user", JsonPrimitive(50))
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun sameId(a: JsonObject, b: JsonObject) = a["id"] == b["id"] && a["type"] == b["type"]
        private fun recipient(id: Long, name: String, type: String = "user") = buildJsonObject { put("id", id); put("name", name); put("type", type) }
        private fun member(id: Long, name: String, role: String, backup: Boolean, type: String = "user") = JsonObject(recipient(id, name, type) + mapOf("permission" to JsonPrimitive(role), "auto_backup" to JsonPrimitive(backup)))
        private fun folder(id: Long, parent: Long, name: String, role: String?, privacy: String = "private") = buildJsonObject {
            put("id", id); put("parent", parent); put("name", name); put("additional", buildJsonObject { put("sharing_info", buildJsonObject {
                put("privacy_type", privacy); put("permission", JsonArray(if (role == null) emptyList() else listOf(obj("""{"type":"user","id":50,"role":"$role"}"""))))
            }) })
        }
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private val capabilities = (listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Sharing.Misc").map { "SYNO.Foto.$it" to 1 } +
            listOf("SYNO.FotoTeam.Browse.Folder" to 2, "SYNO.FotoTeam.Sharing.FolderBatchPermission" to 1)).associate { (name, version) -> name to ApiCapability(name, "entry.cgi", 1, version, "JSON") }
    }
}
