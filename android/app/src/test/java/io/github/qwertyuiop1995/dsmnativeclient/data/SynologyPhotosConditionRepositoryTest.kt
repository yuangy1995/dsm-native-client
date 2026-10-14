package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import org.junit.Assert.*
import org.junit.Test

/** 合成条件与资料驱动实际仓储，不访问 NAS。 */
class SynologyPhotosConditionRepositoryTest {
    private data class Call(val api: String, val method: String, val values: Map<String, String>, val version: Int)
    private class Fixture {
        var user = 41L; var albumOwner = 41L; var home = true; var shared = "management"
        var frozen = false; var temporary = false; var type = "condition"; var folderView = true
        var name = "Synthetic rules"; var albumExists = true; var createId: Long? = 72
        var apply = true; var conditionReadFails = false; var count = 4L
        var rule = obj("""{"user_id":41,"item_type":[],"rating":[3]}""")
        var suggestions = obj("""{"camera":[{"id":9,"name":"Synthetic camera"}]}""")
        val calls = mutableListOf<Call>()
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val writes get() = calls.filter { it.method in setOf("create", "set_condition", "set_name", "delete", "add_item", "delete_item") }
        fun repository(caps: Map<String, ApiCapability> = capabilities()) = SynologyPhotosRepository("profile-a", caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields, cap.maxVersion); calls += call; before(call)
            fun long(key: String) = Json.parseToJsonElement(fields.getValue(key)).let { if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long }
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$user}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"$shared"}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
                cap.name.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"upload":true,"download":true}}""")
                cap.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":${long("id")},"additional":{"access_permission":{"view":$folderView}}}}""")
                cap.name.endsWith("Browse.Album") && method == "get" -> buildJsonObject {
                    put("list", buildJsonArray { if (albumExists) add(buildJsonObject {
                        put("id", long("id")); put("name", name); put("owner_user_id", albumOwner); put("type", type)
                        put("freeze_album", frozen); put("temporary_shared", temporary); put("passphrase", "synthetic-token")
                    }) })
                }
                cap.name.endsWith("Browse.Album") -> {
                    if (apply) when (method) {
                        "set_name" -> name = Json.parseToJsonElement(fields.getValue("name")).jsonPrimitive.content
                        "delete" -> albumExists = false
                        else -> error("Unexpected synthetic write")
                    }
                    obj("{}")
                }
                cap.name.endsWith("Browse.ConditionAlbum") -> when (method) {
                    "get" -> {
                        if (conditionReadFails) throw IOException("synthetic read failure")
                        buildJsonObject { put("list", buildJsonArray { add(buildJsonObject {
                            put("id", long("id")); put("additional", buildJsonObject { put("condition_object", buildJsonObject {
                                rule.forEach { (key, value) -> put(key, if (key in SynologyPhotoConditionCodec.references) JsonArray(value.jsonArray.map {
                                    buildJsonObject { put("id", it) } // 故意无名称，必须保留。
                                }) else value) }
                            }) })
                        }) }) }
                    }
                    "create", "set_condition" -> {
                        if (apply) {
                            rule = Json.parseToJsonElement(fields.getValue("condition")).jsonObject
                            if (method == "create") { name = Json.parseToJsonElement(fields.getValue("name")).jsonPrimitive.content; albumExists = true }
                        }
                        if (method == "create") buildJsonObject { put("album", buildJsonObject { createId?.let { put("id", it) } }) } else obj("{}")
                    }
                    "peek_item_count" -> obj("""{"count":$count}""")
                    "suggest" -> suggestions
                    else -> error("Unexpected synthetic method")
                }
                else -> error("Unexpected synthetic API")
            }
            after(call); result
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun edit(repository: SynologyPhotosRepository, next: SynologyPhotoAlbumCondition? = null) =
            SynologyPhotoAlbumCheckpoint(profileId = "profile-a", userId = user, action = SynologyPhotoAlbumAction.SET_CONDITION,
                album = repository.albumAccess(71).album, originalCondition = repository.albumCondition(71),
                condition = next ?: SynologyPhotoAlbumCondition(rule).withValues("rating", listOf(JsonPrimitive(5))))
        fun create(condition: SynologyPhotoAlbumCondition = SynologyPhotoAlbumCondition(rule)) = SynologyPhotoAlbumCheckpoint(
            profileId = "profile-a", userId = user, action = SynologyPhotoAlbumAction.CREATE_CONDITION, name = "New rules", condition = condition)
    }

    @Test fun `创建使用统一v3回执编号和完整规则回读`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val saves = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { if (it.method == "create") assertEquals(SynologyPhotoAlbumPhase.SUBMITTING, saves.last().phase) }
        val result = repo.performPhotoAlbum(f.create()) { saves += it }
        assertTrue(result.finished); assertEquals(72L, result.createdAlbumId)
        assertTrue(saves.any { it.createdAlbumId == 72L && !it.finished })
        assertEquals("SYNO.Foto.Browse.ConditionAlbum", f.writes.single().api); assertEquals(3, f.writes.single().version)
        assertEquals(setOf("name", "condition"), f.writes.single().values.keys)
        assertTrue(f.calls.any { it.method == "get" && it.api.endsWith("ConditionAlbum") && it.values["id"] == "[72]" })
    }
    @Test fun `编辑保留未知规则空数组顺序无名引用且名称独立`() = runBlocking {
        val f = Fixture().apply { rule = obj("""{"user_id":41,"item_type":[],"person":[7],"person_policy":"and","future":{"items":[9,2]},"empty":[],"flash":[{"legacy":true}]}""") }
        val repo = f.ready(); val original = repo.albumCondition(71)
        assertEquals(7L, original.names.getValue("person").single().value.jsonPrimitive.long)
        assertNull(original.names.getValue("person").single().name)
        val row = f.edit(repo, original.withValues("rating", listOf(JsonPrimitive(4))))
        assertTrue(repo.performPhotoAlbum(row) {}.finished)
        assertEquals("set_condition", f.writes.single().method); assertEquals(setOf("id", "condition"), f.writes.single().values.keys)
        assertEquals(original.fields["future"], f.rule["future"]); assertEquals(original.fields["empty"], f.rule["empty"])
        assertEquals(original.fields["flash"], f.rule["flash"]); assertEquals("Synthetic rules", f.name)
    }
    @Test fun `保存前完整旧规则和相册身份冲突零写`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val row = f.edit(repo)
            when (mode) { 0 -> f.rule = obj("""{"user_id":41,"rating":[1]}"""); 1 -> f.albumOwner = 42; 2 -> f.frozen = true; 3 -> f.name = "Changed elsewhere" }
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `条件相册改名删除可用但手工加入移出与临时冻结管理均拒绝`() = runBlocking {
        for (action in listOf(SynologyPhotoAlbumAction.RENAME, SynologyPhotoAlbumAction.DELETE)) {
            val f = Fixture(); val repo = f.ready()
            val row = SynologyPhotoAlbumCheckpoint(profileId = "profile-a", userId = 41, action = action,
                album = repo.albumAccess(71).album, name = "Renamed".takeIf { action == SynologyPhotoAlbumAction.RENAME })
            assertTrue(repo.performPhotoAlbum(row) {}.finished)
            assertEquals(1, f.writes.size)
        }
        for (mode in 0..2) {
            val f = Fixture().apply { frozen = mode == 0; temporary = mode == 1; albumOwner = if (mode == 2) 42 else 41 }
            val repo = f.ready(); reject { repo.albumCondition(71) }; assertTrue(f.writes.isEmpty())
        }
        for (action in listOf(SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE)) {
            val f = Fixture(); val repo = f.ready()
            val p = SynologyPhoto(SynologyPhotoId("profile-a", SynologyPhotoSpace.PERSONAL, 91), "synthetic.jpg", 4, 1000.0, 900.0, 9, "photo",
                albumContext = SynologyPhotoAlbumContext(71, 41, 41))
            reject { repo.performPhotoAlbum(SynologyPhotoAlbumCheckpoint(profileId = "profile-a", userId = 41, action = action,
                album = repo.albumAccess(71).album, targets = listOf(SynologyPhotoEditTarget(p)))) {} }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `共享来源需管理权限个人来源绑定当前用户与实际可见目录`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture().apply { shared = if (mode == 0) "entry" else "management"; home = mode != 1; folderView = mode != 3 }
            val repo = f.ready(); val condition = SynologyPhotoAlbumCondition(obj("""{"user_id":${if (mode == 0) 0 else if (mode == 2) 42 else 41},"folder_filter":[9]}"""))
            reject { repo.performPhotoAlbum(f.create(condition)) {} }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val repo = f.ready()
        val condition = SynologyPhotoAlbumCondition(obj("""{"user_id":0,"folder_filter":[9]}"""))
        assertTrue(repo.performPhotoAlbum(f.create(condition)) {}.finished)
        assertTrue(f.calls.any { it.api == "SYNO.FotoTeam.Browse.Folder" }); assertEquals(0L, f.rule["user_id"]?.jsonPrimitive?.long)
    }
    @Test fun `提交前撤权或切换会话拒绝写入`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        f.after = { if (it.api.endsWith("Browse.Folder")) { f.after = {}; f.home = false; repo.access() } }
        cancelled { repo.performPhotoAlbum(f.create(SynologyPhotoAlbumCondition(obj("""{"user_id":41,"folder_filter":[9]}""")))) {} }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `丢失创建编号不会按名称认领或重放`() = runBlocking {
        val f = Fixture().apply { createId = null }; val repo = f.ready(); val result = repo.performPhotoAlbum(f.create()) {}
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertNull(result.albumId)
        val restored = f.ready(); val before = f.calls.size
        assertFalse(restored.reviewPhotoAlbum(result) {}.finished); assertEquals(before, f.calls.size)
        assertFalse(restored.performPhotoAlbum(result) {}.finished); assertTrue(f.writes.isEmpty())
    }
    @Test fun `已知编号读失败冷恢复仅回读完整条件`() = runBlocking {
        val f = Fixture().apply { conditionReadFails = true }; val repo = f.ready()
        val result = repo.performPhotoAlbum(f.create()) {}
        assertEquals(72L, result.albumId); assertFalse(result.finished)
        f.conditionReadFails = false; val restored = f.ready()
        assertTrue(restored.reviewPhotoAlbum(result) {}.finished); assertTrue(f.writes.isEmpty())
    }
    @Test fun `回执成功但规则未变不会报告完成未知条件顺序也须匹配`() = runBlocking {
        val f = Fixture().apply { apply = false }; val repo = f.ready(); val row = f.edit(repo)
        val result = repo.performPhotoAlbum(row) {}; assertFalse(result.finished)
        assertFalse(repo.performPhotoAlbum(row) {}.finished); assertEquals(1, f.writes.size)
        f.rule = row.condition!!.fields
        assertTrue(repo.reviewPhotoAlbum(result) {}.finished)
        val a = SynologyPhotoAlbumCondition(obj("""{"rating":[3,1],"future":[9,2],"empty":[],"camera":[]}"""))
        val b = SynologyPhotoAlbumCondition(obj("""{"rating":[1,3],"future":[2,9],"empty":[]}"""))
        assertNotEquals(SynologyPhotoConditionCodec.canonical(a, 41), SynologyPhotoConditionCodec.canonical(b, 41))
        assertEquals(SynologyPhotoConditionCodec.canonical(a, 41), SynologyPhotoConditionCodec.canonical(b.withField("future", a.fields.getValue("future")), 41))
    }
    @Test fun `写提交后取消保留未决而不猜测编号`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val saves = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.after = { if (it.method == "create") throw CancellationException("synthetic interruption") }
        val row = repo.performPhotoAlbum(f.create()) { saves += it }
        assertEquals(SynologyPhotoAlbumPhase.PENDING, row.phase); assertNull(row.albumId)
        assertEquals(row, saves.last()); assertEquals(1, f.writes.size)
    }
    @Test fun `建议使用实际值地点同名末级归父范围原样保留`() = runBlocking {
        val f = Fixture().apply { suggestions = obj("""{"geocoding":[{"id":1,"name":"Region","children":[{"id":2,"name":"City","children":[{"id":3,"name":"City"}]}]}],"exposure_time_group":[{"start":{"num":1,"den":100},"end":0.02}],"person":[{"id":7,"name":"Synthetic person"}]}""") }
        val repo = f.ready(); val result = repo.conditionSuggestions("synthetic", SynologyPhotoSpace.SHARED)
        assertEquals(2L, result.getValue("geocoding").single().value.jsonPrimitive.long)
        assertEquals("Region, City", result.getValue("geocoding").single().name)
        assertEquals(f.suggestions["exposure_time_group"]?.jsonArray?.single(), result.getValue("exposure_time_group").single().value)
        val call = f.calls.last(); assertEquals("0", call.values["user_id"]); assertEquals(3, call.version)
        assertFalse(call.values.getValue("condition").contains("flash")); assertTrue(f.writes.isEmpty())
    }
    @Test fun `数量预览不得负数且读期间撤权不返回旧数据`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        assertEquals(4L, repo.conditionItemCount(SynologyPhotoAlbumCondition(f.rule)))
        f.count = -1; reject { repo.conditionItemCount(SynologyPhotoAlbumCondition(f.rule)) }
        f.after = { if (it.method == "suggest") { f.after = {}; f.user = 42; repo.access() } }
        cancelled { repo.conditionSuggestions("", SynologyPhotoSpace.PERSONAL) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `非法已知字段和策略在写前拒绝未知字段可保留`() = runBlocking {
        for (raw in listOf("{\"item_type\":[true]}", "{\"rating\":[6]}", "{\"rating\":true}", "{\"folder_filter\":[0]}",
            "{\"person\":[1]}", "{\"keyword\":[7],\"keyword_policy\":\"and\"}", "{\"time\":[{}]}",
            "{\"time\":[{\"start_time\":8,\"end_time\":7}]}", "{\"time\":[{\"start_time\":\"9\"}]}",
            "{\"focal_length_group\":[{\"start\":1}]}")) {
            val f = Fixture(); val repo = f.ready(); reject { repo.performPhotoAlbum(f.create(SynologyPhotoAlbumCondition(obj(raw)))) {} }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `记录序列化的科学计数法不能误判规则冲突或未完成`() = runBlocking {
        val f = Fixture().apply { rule = obj("""{"user_id":41,"item_type":[],"rating":[3],"exposure_time_group":[{"start":0.000125,"end":0.0005}]}""") }
        val repo = f.ready(); val row = f.edit(repo)
        val restored = Json.decodeFromString<SynologyPhotoAlbumCheckpoint>(Json.encodeToString(row))
        f.after = { if (it.method == "set_condition") f.rule = obj("""{"user_id":41,"item_type":[],"rating":[5],"exposure_time_group":[{"start":0.000125,"end":0.0005}]}""") }
        assertTrue(repo.performPhotoAlbum(restored) {}.finished)
        assertTrue(SynologyPhotoConditionCodec.matches(SynologyPhotoAlbumCondition(f.rule), restored.condition!!, 41))
        assertEquals(1, f.writes.size)
        val scientific = SynologyPhotoAlbumCondition(obj("""{"future":[1.25E-4,5E-4],"exposure_time_group":[{"start":5E-4,"end":1.25E-4}]}"""))
        val decimal = SynologyPhotoAlbumCondition(obj("""{"future":[0.000125,0.0005],"exposure_time_group":[{"start":0.0005,"end":0.000125}]}"""))
        assertTrue(SynologyPhotoConditionCodec.matches(scientific, decimal, 41))
        assertFalse(SynologyPhotoConditionCodec.matches(scientific, decimal.withField("future", JsonArray(decimal.values("future").reversed())), 41))
        assertFalse(SynologyPhotoConditionCodec.matches(scientific, decimal.withField("future", JsonArray(listOf(JsonPrimitive("0.000125"), JsonPrimitive(0.0005)))), 41))
    }
    @Test fun `旧媒体组合和数值范围保留而未知数组不能排序`() {
        val fields = obj("""{"user_id":41,"item_type":[-2,-1],"exposure_time_group":[{"start":{"num":1,"den":100},"end":0.2}],"future":[9,2]}""")
        val canonical = SynologyPhotoConditionCodec.canonical(SynologyPhotoAlbumCondition(fields), 41)
        assertEquals(setOf(JsonPrimitive(-1), JsonPrimitive(-2)), canonical["item_type"]!!.jsonArray.toSet())
        assertEquals(fields["exposure_time_group"], canonical["exposure_time_group"])
        assertEquals(fields["future"], canonical["future"])
    }
    @Test fun `错误条件来源引用与旧接口版本均不能进入写入`() = runBlocking {
        for (raw in listOf("""{"user_id":42}""", """{"user_id":41,"rating":[6]}""", """{"user_id":41,"person":["invalid"],"person_policy":"and"}""")) {
            val f = Fixture().apply { rule = obj(raw) }; val repo = f.ready()
            reject { repo.albumCondition(71) }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val caps = capabilities().mapValues { (key, value) -> if (key.endsWith("Browse.ConditionAlbum")) value.copy(maxVersion = 2) else value }
        val repo = f.repository(caps); repo.access(); assertFalse(repo.canManageConditionAlbums)
        reject { repo.performPhotoAlbum(f.create()) {} }; assertTrue(f.writes.isEmpty())
    }
    companion object {
        private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
        private suspend fun cancelled(block: suspend () -> Unit) { try { block(); fail("Expected cancellation") } catch (_: CancellationException) {} }
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private fun capabilities() = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            mapOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
                "Browse.Album" to 4, "Browse.NormalAlbum" to 1, "Browse.ConditionAlbum" to 3, "Browse.Folder" to 2, "Sharing.Passphrase" to 1).map { (suffix, version) ->
                val name = "$prefix.$suffix"; name to ApiCapability(name, "entry.cgi", 1, version, "JSON")
            }
        }.toMap()
    }
}
