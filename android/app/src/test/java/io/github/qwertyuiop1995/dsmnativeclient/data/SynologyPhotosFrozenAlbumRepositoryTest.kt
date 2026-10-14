package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成冻结快照覆盖真实仓储的创建、解冻与删旧时序；不访问真实 NAS。 */
class SynologyPhotosFrozenAlbumRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, String>, val version: Int) {
        val id: Long? get() = fields["id"]?.let { Json.parseToJsonElement(it) }?.let {
            if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long
        }
    }
    private class Fixture {
        var user = 41L; var sharedPermission = "management"; var folderReadable = true
        var old: JsonObject? = obj("""{"id":71,"name":"Synthetic frozen","owner_user_id":41,"type":"condition","freeze_album":true,"temporary_shared":false,"item_count":4,"shared":true,"cant_migrate_condition":{"recently_add":[7],"people":[9]},"additional":{"condition_object":{"user_id":41,"item_type":[],"rating":[{"id":3,"name":"Synthetic rating"}],"folder_filter":[{"id":9}],"future":[9,2]},"sharing_info":{"privacy_type":"public-view","passphrase":"synthetic-secret","sharing_link":"https://example.invalid/synthetic"}}}""")
        var created: JsonObject? = null
        var newRule = obj("""{"user_id":41,"item_type":[],"rating":[5]}""")
        var receiptId: Long? = 72
        var applyUnfreeze = true; var applyDelete = true
        var createError: Exception? = null; var deleteError: Exception? = null
        val calls = mutableListOf<Call>()
        val writes get() = calls.filter { it.method in setOf("create", "set_unfreeze", "delete", "set_name") }
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        fun repository() = SynologyPhotosRepository("profile-frozen", capabilities(), { cap, method, fields ->
            val call = Call(cap.name, method, fields, cap.maxVersion); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$user}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"$sharedPermission"}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
                cap.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":$folderReadable}}}}""")
                cap.name.endsWith("Browse.Album") && method == "get" -> buildJsonObject { put("list", buildJsonArray {
                    (if (call.id == 71L) old else created?.takeIf { call.id == 72L })?.let { add(it) }
                }) }
                cap.name.endsWith("Browse.Album") && method == "delete" -> {
                    assertEquals(71L, call.id); if (applyDelete) old = null
                    deleteError?.let { throw it }; obj("{}")
                }
                cap.name.endsWith("Browse.Album") && method == "set_name" -> {
                    old = JsonObject(old!! + ("name" to Json.parseToJsonElement(fields.getValue("name")))); obj("{}")
                }
                cap.name.endsWith("Browse.NormalAlbum") && method == "set_unfreeze" -> {
                    if (applyUnfreeze) old = JsonObject(old!! + mapOf("freeze_album" to JsonPrimitive(false), "type" to JsonPrimitive("normal")))
                    obj("{}")
                }
                cap.name.endsWith("Browse.ConditionAlbum") && method == "create" -> {
                    newRule = Json.parseToJsonElement(fields.getValue("condition")).jsonObject
                    created = buildJsonObject {
                        put("id", 72); put("owner_user_id", 41); put("name", Json.parseToJsonElement(fields.getValue("name")))
                        put("type", "condition"); put("freeze_album", false); put("temporary_shared", false); put("shared", false); put("item_count", 3)
                    }
                    createError?.let { throw it }
                    buildJsonObject { put("album", buildJsonObject { receiptId?.let { put("id", it) } }) }
                }
                cap.name.endsWith("Browse.ConditionAlbum") && method == "get" -> buildJsonObject {
                    assertEquals(72L, call.id)
                    put("list", buildJsonArray { add(buildJsonObject { put("id", 72); put("additional", buildJsonObject {
                        put("condition_object", buildJsonObject { newRule.forEach { (key, value) ->
                            put(key, if (key in SynologyPhotoConditionCodec.references) JsonArray(value.jsonArray.map { buildJsonObject { put("id", it) } }) else value)
                        } })
                    }) }) })
                }
                else -> error("Unexpected synthetic operation: ${cap.name}.$method")
            }
            after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun row(repo: SynologyPhotosRepository, rebuild: Boolean = false): SynologyPhotoAlbumCheckpoint {
            val frozen = repo.frozenAlbum(71)
            return SynologyPhotoAlbumCheckpoint(profileId = "profile-frozen", userId = 41,
                action = if (rebuild) SynologyPhotoAlbumAction.REBUILD_FROZEN else SynologyPhotoAlbumAction.UNFREEZE,
                album = frozen.album, frozenSnapshot = frozen.snapshot,
                name = "New synthetic".takeIf { rebuild }, condition = SynologyPhotoAlbumCondition(newRule).takeIf { rebuild })
        }
        fun oldField(key: String, value: JsonElement?) { old = JsonObject(if (value == null) old!! - key else old!! + (key to value)) }
        fun oldAdditional(key: String, value: JsonElement) { oldField("additional", JsonObject(old!!.getValue("additional").jsonObject + (key to value))) }
        fun newField(key: String, value: JsonElement?) { created = JsonObject(if (value == null) created!! - key else created!! + (key to value)) }
    }

    @Test fun `冻结读取只提示不可迁移字段并保留可支持无名引用`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val frozen = repo.frozenAlbum(71)
        assertTrue(frozen.canRebuild); assertTrue(frozen.snapshot.shared)
        assertEquals(setOf("recently_add", "people", "future"), frozen.unsupportedKeys)
        assertEquals(listOf(JsonPrimitive(9)), frozen.rebuildCondition!!.values("folder_filter"))
        assertNull(frozen.rebuildCondition.names.getValue("folder_filter").single().name)
        assertFalse(frozen.rebuildCondition.fields.containsKey("future"))
        assertFalse(frozen.rebuildCondition.fields.containsKey("people"))
        assertEquals(setOf("sharing_info", "thumbnail", "condition_object"), Json.parseToJsonElement(f.calls.last().fields.getValue("additional")).jsonArray.map { it.jsonPrimitive.content }.toSet())
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `仅共享来源或无效旧规则仍能保存普通相册且不读取目录`() = runBlocking {
        for (rule in listOf("""{"user_id":0}""", """{"user_id":42,"rating":[]} """, """{"user_id":41,"rating":"invalid"}""")) {
            val f = Fixture(); f.oldAdditional("condition_object", obj(rule)); f.folderReadable = false
            val repo = f.ready(); assertFalse(repo.frozenAlbum(71).canRebuild)
            val done = repo.performPhotoAlbum(f.row(repo)) {}
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
            assertEquals("SYNO.Foto.Browse.NormalAlbum", f.writes.single().api)
            assertEquals(1, f.writes.single().version); assertEquals(mapOf("id" to "71"), f.writes.single().fields)
            assertFalse(f.calls.any { it.api.endsWith("Browse.Folder") })
        }
    }
    @Test fun `缺失关键冻结元数据或其他所有者不能取得可写快照`() = runBlocking {
        for (key in listOf("item_count", "cant_migrate_condition", "shared", "freeze_album", "additional")) {
            val f = Fixture(); f.oldField(key, null); val repo = f.ready()
            reject { repo.frozenAlbum(71) }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); f.oldField("owner_user_id", JsonPrimitive(42)); val repo = f.ready()
        reject { repo.frozenAlbum(71) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `普通恢复必须明确未冻结且原名称数量所有者匹配`() = runBlocking {
        for (mode in 0..5) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            f.after = { if (it.method == "set_unfreeze") when (mode) {
                0 -> f.oldField("freeze_album", null); 1 -> f.oldField("freeze_album", JsonPrimitive(true))
                2 -> f.oldField("type", JsonPrimitive("condition")); 3 -> f.oldField("name", JsonPrimitive("Changed"))
                4 -> f.oldField("item_count", JsonPrimitive(5)); 5 -> f.oldField("owner_user_id", JsonPrimitive(42))
            } }
            var pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
            pending = repo.reviewPhotoAlbum(pending) {}; assertFalse(pending.finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `提交前旧名称数量规则不可迁移条件和共享变化一律零写`() = runBlocking {
        for (mode in 0..5) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo, true)
            changeOld(f, mode)
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `新编号持久化与新规则回读均先于旧容器单次删除`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo, true); val saves = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { call -> if (call.method == "delete") {
            assertEquals(72L, saves.last().createdAlbumId); assertTrue(saves.last().frozenDeletionAttempted)
            assertTrue(f.calls.any { it.method == "get" && it.api.endsWith("ConditionAlbum") })
        } }
        val done = repo.performPhotoAlbum(row) { saves += it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertNull(f.old)
        assertEquals(listOf("create", "delete"), f.writes.map { it.method })
        assertEquals(setOf("name", "condition"), f.writes.first().fields.keys)
        assertEquals(mapOf("id" to "[71]"), f.writes.last().fields)
        assertEquals(setOf(71L, 72L), done.affectedAlbumIds)
        assertTrue(saves.any { it.createdAlbumId == 72L && !it.frozenDeletionAttempted })
    }
    @Test fun `新相册身份名称条件或分享不匹配绝不删除旧相册`() = runBlocking {
        for (mode in 0..6) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo, true)
            f.after = { if (it.method == "create") when (mode) {
                0 -> f.newField("name", JsonPrimitive("Wrong")); 1 -> f.newField("owner_user_id", JsonPrimitive(42))
                2 -> f.newField("freeze_album", JsonPrimitive(true)); 3 -> f.newField("shared", JsonPrimitive(true))
                4 -> f.newField("shared", null); 5 -> f.newRule = obj("""{"user_id":41,"rating":[1]}""")
                6 -> f.newField("type", JsonPrimitive("normal"))
            } }
            val result = repo.performPhotoAlbum(row) {}; assertFalse(result.finished); assertNotNull(f.old)
            assertEquals(listOf("create"), f.writes.map { it.method })
        }
    }
    @Test fun `新相册完成但旧快照变化返回保留两者的部分完成`() = runBlocking {
        for (mode in 0..5) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo, true)
            f.after = { if (it.method == "create") changeOld(f, mode) }
            val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase)
            assertNotNull(f.old); assertNotNull(f.created); assertFalse(result.frozenDeletionAttempted)
            assertEquals(listOf("create"), f.writes.map { it.method })
        }
    }
    @Test fun `创建丢失回执或旧编号回执均不按名称认领也不重放`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture().apply { if (mode == 0) createError = IOException("synthetic"); if (mode == 1) receiptId = null; if (mode == 2) receiptId = 71 }
            val repo = f.ready(); val result = repo.performPhotoAlbum(f.row(repo, true)) {}
            assertNull(result.createdAlbumId); assertFalse(result.finished)
            val cold = f.ready(); assertFalse(cold.reviewPhotoAlbum(result) {}.finished)
            assertTrue(f.writes.isEmpty()); assertFalse(f.calls.any { it.method == "list" })
            assertNotNull(f.old); assertNotNull(f.created)
        }
    }
    @Test fun `删除结果未知只读刷新旧相册消失后才完成`() = runBlocking {
        val f = Fixture().apply { applyDelete = false; deleteError = IOException("synthetic") }
        val repo = f.ready(); var row = repo.performPhotoAlbum(f.row(repo, true)) {}
        assertTrue(row.frozenDeletionAttempted); assertFalse(row.frozenDeletionRejected); assertFalse(row.finished)
        row = repo.reviewPhotoAlbum(row) {}; assertFalse(row.finished); assertEquals(2, f.writes.size)
        f.old = null; row = repo.reviewPhotoAlbum(row) {}
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, row.phase); assertEquals(2, f.writes.size)
    }
    @Test fun `删除明确拒绝保留旧相册并停止为部分完成`() = runBlocking {
        val f = Fixture().apply { applyDelete = false; deleteError = DsmFailure(105, "Synthetic rejection", "Synthetic recovery", kind = DsmErrorKind.PERMISSION_DENIED) }
        val repo = f.ready(); val done = repo.performPhotoAlbum(f.row(repo, true)) {}
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, done.phase); assertTrue(done.frozenDeletionRejected)
        assertNotNull(f.old); assertEquals(2, f.writes.size)
        repo.reviewPhotoAlbum(done) {}; assertEquals(2, f.writes.size)
    }
    @Test fun `新编号已保存后进程中断的冷恢复只读并保留旧相册`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); var saved: SynologyPhotoAlbumCheckpoint? = null
        try { repo.performPhotoAlbum(f.row(repo, true)) { saved = it; if (it.createdAlbumId != null) throw IOException("synthetic interruption") }; fail() }
        catch (_: IOException) {}
        assertNotNull(saved!!.createdAlbumId); assertFalse(saved!!.frozenDeletionAttempted)
        val cold = f.ready(); val restored = cold.reviewPhotoAlbum(saved!!) {}
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, restored.phase); assertTrue(f.writes.isEmpty()); assertNotNull(f.old)
    }
    @Test fun `删除尝试保存失败绝不发送旧容器删除`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); var saved: SynologyPhotoAlbumCheckpoint? = null
        repo.performPhotoAlbum(f.row(repo, true)) { if (it.frozenDeletionAttempted) throw IOException("synthetic storage failure"); saved = it }
        assertEquals(listOf("create"), f.writes.map { it.method }); assertFalse(saved!!.frozenDeletionAttempted)
        val cold = f.ready(); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, cold.reviewPhotoAlbum(saved!!) {}.phase)
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `重建来源目录权限仍校验普通恢复不需要这些权限`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo, true).copy(condition = SynologyPhotoAlbumCondition(obj("""{"user_id":0,"folder_filter":[9]}""")))
        f.folderReadable = false; reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        assertTrue(repo.performPhotoAlbum(f.row(repo)) {}.finished)
    }
    @Test fun `读取旧状态时切换账号不得继续创建`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo, true)
        f.after = { if (it.method == "get" && it.api.endsWith("Browse.Album")) { f.after = {}; f.user = 42; repo.access() } }
        try { repo.performPhotoAlbum(row) {}; fail() } catch (_: CancellationException) {}
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `冻结相册仍允许本人重命名与删除但不开放条件原位编辑`() = runBlocking {
        for (action in listOf(SynologyPhotoAlbumAction.RENAME, SynologyPhotoAlbumAction.DELETE)) {
            val f = Fixture(); val repo = f.ready(); val access = repo.albumAccess(71)
            assertTrue(access.canManage); assertFalse(access.canContribute)
            val done = repo.performPhotoAlbum(SynologyPhotoAlbumCheckpoint(profileId = "profile-frozen", userId = 41,
                action = action, album = access.album, name = "Renamed".takeIf { action == SynologyPhotoAlbumAction.RENAME })) {}
            assertTrue(done.finished); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `摘要按数字含义比较但保持未知数组顺序且不泄露分享内容`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        f.oldAdditional("condition_object", obj("""{"user_id":41,"future":[0.000125,2]}"""))
        val before = repo.frozenAlbum(71)
        f.oldAdditional("condition_object", obj("""{"future":[1.25E-4,2.0],"user_id":41}"""))
        assertEquals(before.snapshot, repo.frozenAlbum(71).snapshot)
        f.oldAdditional("condition_object", obj("""{"user_id":41,"future":[2,0.000125]}"""))
        assertNotEquals(before.snapshot, repo.frozenAlbum(71).snapshot)
        assertFalse(before.snapshot.toString().contains("synthetic-secret")); assertEquals(64, before.snapshot.stateDigest.length)
    }
    companion object {
        private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private fun changeOld(f: Fixture, mode: Int) { when (mode) {
            0 -> f.oldField("name", JsonPrimitive("Changed")); 1 -> f.oldField("item_count", JsonPrimitive(5))
            2 -> f.oldAdditional("condition_object", obj("""{"user_id":41,"rating":[{"id":1}]}"""))
            3 -> f.oldField("cant_migrate_condition", obj("""{"recently_add":[8]}"""))
            4 -> f.oldAdditional("sharing_info", obj("""{"privacy_type":"public-download"}"""))
            5 -> f.oldField("shared", JsonPrimitive(false))
        } }
        private fun capabilities() = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            mapOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
                "Browse.Album" to 4, "Browse.NormalAlbum" to 1, "Browse.ConditionAlbum" to 3, "Browse.Folder" to 2).map { (suffix, version) ->
                val name = "$prefix.$suffix"; name to ApiCapability(name, "entry.cgi", 1, version, "JSON")
            }
        }.toMap()
    }
}
