package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成分组贯穿正式仓储；不存在真实照片或NAS写入。 */
class SynologyPhotosSimilarRepositoryTest {
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>) {
        val space get() = if (api.startsWith("SYNO.FotoTeam.")) shared else personal
        fun ids(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonArray.map { it.jsonPrimitive.long }
    }
    private class Fixture {
        var personalEnabled = true; var sharedEnabled = true; var global = true; var role = "management"; var folderManage = true
        var userId = 41L; var applyWrites = true; var writeError: Exception? = null
        var before: suspend (Call) -> Unit = {}; var transform: (Call, JsonObject) -> JsonObject = { _, data -> data }
        val groups = SynologyPhotoSpace.entries.associateWith<SynologyPhotoSpace, SynologyPhotoSimilarGroup?> { group(it) }.toMutableMap()
        val memberships = SynologyPhotoSpace.entries.associateWith { space -> (51L..53L).associateWith<Long, SynologyPhotoSimilarGroup?> { group(space) }.toMutableMap() }
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method in setOf("set_top_pick", "remove_item", "ungroup", "add_item") }
        fun repository(missing: String? = null, maximum: Int = 6) = SynologyPhotosRepository("similar", capabilities.filterKeys { it != missing }.mapValues { (_, cap) ->
            if (cap.name.endsWith("Browse.Item")) cap.copy(maxVersion = maximum) else cap
        }, { cap, method, fields ->
            val call = Call(cap.name, cap.maxVersion, method, fields); calls += call; before(call)
            val space = call.space
            val raw = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$userId}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"$role","enable_similar":$personalEnabled}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_similar":$global}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true,"enable_similar":$sharedEnabled}""")
                cap.name.endsWith("Browse.Category") -> obj("""{"list":[{"id":"similar"},{"id":"video"}]}""")
                cap.name.endsWith("Browse.SimilarTimeline") -> obj("""{"section":[{"list":[{"year":2026,"month":10,"day":1,"item_count":1}]}]}""")
                cap.name.endsWith("Browse.Similar") && method == "get_status" -> obj("""{"waiting_count":3,"similar_clustering_stage":"running","is_similar_hash_migration_done":true}""")
                cap.name.endsWith("Browse.Similar") && method == "get" -> list(listOfNotNull(groups[space]?.let(::rawGroup)))
                method in setOf("set_top_pick", "remove_item", "ungroup", "add_item") -> {
                    if (writeError is DsmFailure) throw writeError!!
                    if (applyWrites) {
                        val old = groups[space]
                        val next = when (method) {
                            "set_top_pick" -> old!!.copy(topPickId = fields.getValue("item_id").toLong())
                            "remove_item" -> old!!.photoIds.minus(call.ids("item_id").toSet()).let { ids ->
                                if (ids.size < 2) null else old.copy(photoIds = ids, topPickId = old.topPickId.takeIf { it in ids } ?: ids.first()) }
                            "ungroup" -> null
                            else -> group(space).copy(photoIds = call.ids("item_id"), topPickId = fields.getValue("top_pick").toLong())
                        }
                        groups[space] = next
                        memberships.getValue(space).keys.toList().forEach { id -> memberships.getValue(space)[id] = next?.takeIf { id in it.photoIds } }
                    }
                    writeError?.let { throw it }; obj("{}")
                }
                cap.name.endsWith("Browse.SimilarItem") && method == "list_similar" -> list(listOf(photo(51, groups[space])))
                cap.name.endsWith("Browse.SimilarItem") -> list(call.ids("id").reversed().map { photo(it, memberships.getValue(space)[it]) })
                cap.name.endsWith("Browse.Item") -> list(call.ids("id").reversed().map { photo(it) })
                cap.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"name":"/Synthetic","parent":8,"additional":{"access_permission":{"view":true,"manage":$folderManage}}}}""")
                else -> error("Unexpected synthetic request ${call.api}.${call.method}")
            }
            transform(call, raw)
        })
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun detail(repo: SynologyPhotosRepository, space: SynologyPhotoSpace = personal) = repo.similarGroupDetails(group(space))!!
        suspend fun change(repo: SynologyPhotosRepository, edit: SynologyPhotoSimilarEdit, space: SynologyPhotoSpace = personal,
            selected: List<Long> = when (edit) { SynologyPhotoSimilarEdit.TOP_PICK -> listOf(52); SynologyPhotoSimilarEdit.REMOVE -> listOf(53); else -> emptyList() }) =
            repo.prepareSimilarChange(detail(repo, space), edit, selected)
    }

    @Test fun `两来源分类月份分页完整详情状态使用实际版本及成员顺序`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) {
            val f = Fixture(); val repo = f.ready()
            assertTrue(SynologyPhotoCategory.SIMILAR in repo.categories(space)); assertTrue(repo.canManageSimilar(space))
            val query = SynologyPhotoQuery.Similar(1, 99)
            assertEquals(1, repo.timeline(space, query).size)
            val page = repo.photos(space, query, 4, 6); assertEquals(5, page.nextOffset); assertFalse(page.hasMore)
            val detail = repo.similarPhotos(page.items.single()); assertEquals(listOf(51L, 52L, 53L), detail.photos.map { it.id.itemId })
            assertTrue(detail.photos.all { it.similarGroup == detail.group }); assertEquals(detail.group, repo.details(detail.photos.first()).similarGroup)
            assertTrue(repo.similarStatus(space).running)
            val timeline = f.calls.single { it.method == "get_similar" }; assertEquals(1, timeline.version); assertEquals(mapOf("timeline_group_unit" to "\"day\""), timeline.fields)
            val pageCall = f.calls.single { it.method == "list_similar" }; assertEquals("4", pageCall.fields["offset"]); assertEquals("1", pageCall.fields["start_time"])
            assertTrue(f.calls.filter { it.api.contains("Browse.Similar") || it.api.endsWith("Browse.Item") }.all { it.space == space })
        }
    }
    @Test fun `所有分组写入精确参数持久尝试先于唯一提交且不删原件`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) for (edit in edits) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, edit, space); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
            f.before = { if (it.method in setOf("set_top_pick", "remove_item", "ungroup")) assertTrue(saved.last().similar!!.attempted) }
            val result = repo.performPhotoAlbum(row) { saved += it }
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertTrue(result.similar!!.confirmed)
            assertEquals(when (edit) {
                SynologyPhotoSimilarEdit.TOP_PICK -> mapOf("id" to "7", "item_id" to "52")
                SynologyPhotoSimilarEdit.REMOVE -> mapOf("id" to "7", "item_id" to "[53]")
                else -> mapOf("id" to "[7]")
            }, f.writes.single().fields)
            assertEquals(1, f.writes.single().version); assertEquals(space, f.writes.single().space)
            repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
            assertTrue(f.memberships.getValue(space).keys.containsAll(listOf(51L, 52L, 53L)))
            assertFalse(f.calls.any { it.method in setOf("delete", "delete_item") })
        }
    }
    @Test fun `分类缺显式识别设置缺能力共享entry与管理员关闭分别拒绝`() = runBlocking {
        for (mode in listOf("personal", "missing-setting", "team", "entry", "global", "cap")) {
            val f = Fixture(); when (mode) { "personal" -> f.personalEnabled = false; "team" -> f.sharedEnabled = false; "entry" -> f.role = "entry"; "global" -> f.global = false }
            if (mode == "missing-setting") f.transform = { c, raw -> if (c.api.endsWith("Setting.User")) JsonObject(raw - "enable_similar") else raw }
            val repo = f.repository(missing = "SYNO.Foto.Browse.SimilarTimeline".takeIf { mode == "cap" }); repo.access()
            val space = if (mode in setOf("entry", "team")) shared else personal
            assertFalse(SynologyPhotoCategory.SIMILAR in repo.categories(space)); assertFalse(repo.canManageSimilar(space))
            rejects { repo.photos(space, SynologyPhotoQuery.Similar(1, 99), 0, 10) }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `列表分组缺字段重复负数字符串计数和推荐越界全部拒绝`() = runBlocking {
        for (bad in listOf(
            obj("""{"id":7,"count":3,"top_pick":51,"item_id":[51,51,53]}"""),
            obj("""{"id":7,"count":2,"top_pick":51,"item_id":[51,52,53]}"""),
            obj("""{"id":7,"count":"3","top_pick":51,"item_id":[51,52,53]}"""),
            obj("""{"id":7,"count":3,"top_pick":99,"item_id":[51,52,53]}"""),
            obj("""{"id":7,"count":3,"top_pick":51,"item_id":[51,-2,53]}"""),
            obj("""{"id":7,"count":3,"top_pick":51,"item_id":["51",52,53]}"""),
            obj("""{"id":7,"count":1,"top_pick":51,"item_id":[51]}"""), obj("{}"))) {
            val f = Fixture(); val repo = f.ready(); f.transform = { c, raw -> if (c.method == "list_similar") list(listOf(JsonObject(photo(51) + ("similar" to bad)))) else raw }
            rejects { repo.photos(personal, SynologyPhotoQuery.Similar(1, 99), 0, 10) }
        }
    }
    @Test fun `完整详情缺件重复组编号不符和入口已移出均不能返回旧组`() = runBlocking {
        for (mode in listOf("missing", "duplicate", "wrong-group", "entry")) {
            val f = Fixture(); val repo = f.ready()
            f.transform = { c, raw -> when {
                c.api.endsWith("Browse.Item") && mode == "missing" -> list(listOf(photo(51), photo(52)))
                c.api.endsWith("Browse.Item") && mode == "duplicate" -> list(listOf(photo(51), photo(51), photo(53)))
                c.api.endsWith("Browse.Similar") && mode == "wrong-group" -> list(listOf(rawGroup(group(personal).copy(id = 8))))
                else -> raw
            } }
            if (mode == "entry") f.groups[personal] = group(personal).copy(photoIds = listOf(52, 53), topPickId = 52)
            rejects { repo.similarPhotos(target(51, personal).copy(similarGroup = group(personal))) }
        }
    }
    @Test fun `零及单成员有效组按解散处理非法或失败绝不当空`() = runBlocking {
        for (ids in listOf(emptyList<Long>(), listOf(51L))) {
            val f = Fixture(); val repo = f.ready(); f.transform = { c, raw -> if (c.api.endsWith("Browse.Similar")) list(listOf(obj("""{"id":7,"count":${ids.size},"top_pick":51,"item_id":${ids}}"""))) else raw }
            assertNull(repo.similarGroupDetails(group(personal)))
        }
        val f = Fixture(); val repo = f.ready(); f.transform = { c, raw -> if (c.api.endsWith("Browse.Similar")) obj("{}") else raw }
        rejects { repo.similarGroupDetails(group(personal)) }
        f.before = { if (it.api.endsWith("Browse.Similar")) throw IOException("synthetic") }
        rejects { repo.similarGroupDetails(group(personal)) }
    }
    @Test fun `状态字段严格解码未知stage不伪装运行零等待只在迁移未完显示`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        for (raw in listOf(obj("{}"), obj("""{"waiting_count":-1,"similar_clustering_stage":"running","is_similar_hash_migration_done":true}"""),
            obj("""{"waiting_count":0,"similar_clustering_stage":"","is_similar_hash_migration_done":true}"""),
            obj("""{"waiting_count":0,"similar_clustering_stage":"waiting","is_similar_hash_migration_done":"true"}"""))) {
            f.transform = { c, value -> if (c.method == "get_status") raw else value }; rejects { repo.similarStatus(personal) }
        }
        for (migration in listOf(true, false)) {
            f.transform = { c, value -> if (c.method == "get_status") obj("""{"waiting_count":0,"similar_clustering_stage":"future-stage","is_similar_hash_migration_done":$migration}""") else value }
            val state = repo.similarStatus(personal); assertEquals(!migration, state.visible); assertFalse(state.running)
        }
    }
    @Test fun `写前身份权限设置完整成员与归组变化均拒绝写入`() = runBlocking {
        for (mode in listOf("user", "setting", "folder", "filename", "size", "indexed", "folder-id", "type", "group", "membership")) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoSimilarEdit.UNGROUP)
            when (mode) { "user" -> f.userId++; "setting" -> f.personalEnabled = false; "folder" -> f.folderManage = false
                "group" -> f.groups[personal] = group(personal).copy(topPickId = 52)
                "membership" -> f.memberships.getValue(personal)[52] = group(personal).copy(id = 9)
                else -> f.transform = { c, raw -> if (c.api.endsWith("Browse.Item")) list(raw["list"]!!.jsonArray.map { entry ->
                    JsonObject(entry.jsonObject + when (mode) {
                        "filename" -> "filename" to JsonPrimitive("changed.jpg")
                        "size" -> "filesize" to JsonPrimitive(8)
                        "indexed" -> "indexed_time" to JsonPrimitive(8)
                        "folder-id" -> "folder_id" to JsonPrimitive(8)
                        else -> "type" to JsonPrimitive("video")
                    }) }) else raw }
            }
            rejects { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `写成功断线冷恢复只读确认不会重发`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoSimilarEdit.REMOVE)
        f.writeError = IOException("synthetic disconnect"); var saved = row
        val result = repo.performPhotoAlbum(row) { saved = it }; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
        val restarted = f.ready(); val recovered = restarted.reviewPhotoAlbum(saved) {}; assertTrue(recovered.similar!!.confirmed)
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `未知未生效请求恢复保持未决不换编号再次提交`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoSimilarEdit.UNGROUP)
        f.applyWrites = false; f.writeError = IOException("synthetic"); var saved = row
        val result = repo.performPhotoAlbum(row) { saved = it }; assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
        val restarted = f.repository(); restarted.access(); restarted.performPhotoAlbum(saved) {}; assertEquals(1, f.writes.size)
    }
    @Test fun `只有组消失成员仍归旧组或原件缺失都不能确认拆组`() = runBlocking {
        for (mode in listOf("membership", "missing", "identity")) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoSimilarEdit.UNGROUP)
            f.transform = { c, raw -> if (f.writes.isNotEmpty() && c.api.endsWith("Browse.SimilarItem")) when (mode) {
                "membership" -> list((51L..53L).map { photo(it, group(personal)) })
                "missing" -> list(listOf(photo(51), photo(52)))
                else -> list((51L..53L).map { JsonObject(photo(it) + ("filesize" to JsonPrimitive(9))) })
            } else raw }
            val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertFalse(result.similar!!.confirmed)
        }
    }
    @Test fun `移出剩一张或全移出仍检查全部原件`() = runBlocking {
        for (selected in listOf(listOf(51L, 52L), listOf(51L, 52L, 53L))) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoSimilarEdit.REMOVE, selected = selected)
            val result = repo.performPhotoAlbum(row) {}; assertNull(result.similar!!.resultingGroup); assertTrue(result.similar.confirmed)
            assertTrue(f.calls.any { it.api.endsWith("Browse.SimilarItem") && it.ids("id") == listOf(51L, 52L, 53L) })
        }
    }
    @Test fun `撤销移出和拆组恢复原成员推荐且同原操作不能重复撤销`() = runBlocking {
        for (edit in listOf(SynologyPhotoSimilarEdit.REMOVE, SynologyPhotoSimilarEdit.UNGROUP)) {
            val f = Fixture(); val repo = f.ready(); val original = repo.performPhotoAlbum(f.change(repo, edit)) {}
            val undo = repo.prepareSimilarUndo(original); val result = repo.performPhotoAlbum(undo) {}
            assertEquals(group(personal), result.similar!!.resultingGroup); assertEquals(2, f.writes.size)
            assertEquals(mapOf("id" to "7", "item_id" to "[51,52,53]", "top_pick" to "51"), f.writes.last().fields)
            rejects { repo.prepareSimilarUndo(original) }; repo.performPhotoAlbum(undo) {}; assertEquals(2, f.writes.size)
        }
    }
    @Test fun `撤销拒绝成员被移入另一组原结果改变及未确认的依据`() = runBlocking {
        for (mode in listOf("regrouped", "changed", "unconfirmed", "top-pick")) {
            val f = Fixture(); val repo = f.ready()
            val row = f.change(repo, if (mode == "top-pick") SynologyPhotoSimilarEdit.TOP_PICK else SynologyPhotoSimilarEdit.REMOVE)
            if (mode == "unconfirmed") { rejects { repo.prepareSimilarUndo(row) }; continue }
            val original = repo.performPhotoAlbum(row) {}
            if (mode == "regrouped") f.memberships.getValue(personal)[53] = group(personal).copy(id = 8)
            if (mode == "changed") f.groups[personal] = group(personal).copy(photoIds = listOf(51, 52), topPickId = 52)
            rejects { repo.prepareSimilarUndo(original) }; assertEquals(1, f.writes.size)
        }
    }
    @Test fun `跨授权代次读取丢弃且无法使用跨账号来源相册快照`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val original = target(51, personal).copy(similarGroup = group(personal))
        for (bad in listOf(original.copy(id = original.id.copy(profileId = "other")), original.copy(id = original.id.copy(space = shared)),
            original.copy(albumContext = SynologyPhotoAlbumContext(9, 41)), original.copy(id = original.id.copy(itemId = 99)))) rejects { repo.similarPhotos(bad) }
        var changed = false
        f.before = { if (!changed && it.api.endsWith("Browse.Similar")) { changed = true; repo.access() } }
        try { repo.similarPhotos(original); fail("Expected stale cancellation") } catch (_: CancellationException) {}
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `写前持久化失败或取消禁止发出写请求`() = runBlocking {
        for (cancel in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoSimilarEdit.UNGROUP)
            if (cancel) { f.before = { if (it.api.endsWith("Browse.Folder")) throw CancellationException() }; rejects { repo.performPhotoAlbum(row) {} } }
            else rejects { repo.performPhotoAlbum(row) { if (it.similar!!.attempted) throw IOException("storage") } }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `完整大组批量读取原件身份不按成员逐张发请求`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val group = group(personal).copy(photoIds = (1L..101L).toList(), topPickId = 1)
        f.groups[personal] = group
        f.memberships.getValue(personal).clear(); group.photoIds.forEach { f.memberships.getValue(personal)[it] = group }
        val detail = repo.similarGroupDetails(group)!!; f.calls.clear()
        val row = repo.prepareSimilarChange(detail, SynologyPhotoSimilarEdit.UNGROUP)
        assertEquals(101, row.targets.size)
        assertEquals(1, f.calls.count { it.api.endsWith("Browse.Item") }); assertEquals(1, f.calls.count { it.api.endsWith("Browse.Folder") })
        assertEquals(group.photoIds, f.calls.single { it.api.endsWith("Browse.Item") }.ids("id"))
    }
    @Test fun `撤销写入必须先登记同一已确认原操作冷恢复仍可只读核对`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val original = repo.performPhotoAlbum(f.change(repo, SynologyPhotoSimilarEdit.UNGROUP)) {}
        val undo = repo.prepareSimilarUndo(original)
        val restarted = f.repository(); restarted.access()
        rejects { restarted.performPhotoAlbum(undo) {} }; assertEquals(1, f.writes.size)
        restarted.prepareSimilarUndo(original)
        val done = restarted.performPhotoAlbum(undo) {}; assertTrue(done.similar!!.confirmed); assertEquals(2, f.writes.size)
    }
    @Test fun `明确拒绝不认领外部变化未发出记录可以结束但不重试写入`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoSimilarEdit.UNGROUP)
        f.writeError = DsmFailure(105, "Synthetic denied", "Synthetic recovery", kind = DsmErrorKind.PERMISSION_DENIED)
        val rejected = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, rejected.phase); assertTrue(rejected.similar!!.rejected)
        f.groups[personal] = null; f.memberships.getValue(personal).keys.toList().forEach { f.memberships.getValue(personal)[it] = null }
        val recovered = f.repository().also { it.access() }.reviewPhotoAlbum(rejected) {}; assertFalse(recovered.similar!!.confirmed); assertEquals(1, f.writes.size)
        val untried = row.copy(operationId = java.util.UUID.randomUUID().toString(), phase = SynologyPhotoAlbumPhase.PENDING)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, f.repository().also { it.access() }.reviewPhotoAlbum(untried) {}.phase)
        assertEquals(1, f.writes.size)
    }

    companion object {
        private val personal = SynologyPhotoSpace.PERSONAL; private val shared = SynologyPhotoSpace.SHARED
        private val edits = listOf(SynologyPhotoSimilarEdit.TOP_PICK, SynologyPhotoSimilarEdit.REMOVE, SynologyPhotoSimilarEdit.UNGROUP)
        private fun group(space: SynologyPhotoSpace) = SynologyPhotoSimilarGroup("similar", space, 7, listOf(51, 52, 53), 51)
        private fun target(id: Long, space: SynologyPhotoSpace) = SynologyPhoto(SynologyPhotoId("similar", space, id), "synthetic-$id.jpg", 3, 1.0, 2.0, 9, "photo")
        private fun rawGroup(group: SynologyPhotoSimilarGroup) = obj("""{"id":${group.id},"count":${group.photoIds.size},"top_pick":${group.topPickId},"item_id":${group.photoIds}}""")
        private fun photo(id: Long, group: SynologyPhotoSimilarGroup? = null): JsonObject = JsonObject(obj("""{"id":$id,"filename":"synthetic-$id.jpg","filesize":3,"time":1,"indexed_time":2,"folder_id":9,"type":"photo"}""") +
            ("similar" to (group?.let(::rawGroup) ?: JsonNull)))
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun list(values: List<JsonObject>) = buildJsonObject { put("list", JsonArray(values)) }
        private suspend fun rejects(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: Exception) {} }
        private val capabilities = buildMap { for (prefix in listOf("SYNO.Foto", "SYNO.FotoTeam")) for ((suffix, version) in mapOf(
            "UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1, "Browse.Category" to 3,
            "Browse.Similar" to 1, "Browse.SimilarItem" to 1, "Browse.SimilarTimeline" to 1, "Browse.Item" to 6, "Browse.Folder" to 2)) {
            val name = "$prefix.$suffix"; put(name, ApiCapability(name, "entry.cgi", 1, version, "JSON"))
        } }
    }
}
