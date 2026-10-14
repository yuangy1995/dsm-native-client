package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody

/** 仅合成主题与照片，正式仓储贯穿读取、权限、持久提交及冷恢复。 */
class SynologyPhotosConceptRepositoryTest {
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>) {
        val space get() = if (api.startsWith("SYNO.FotoTeam.")) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
        fun long(key: String) = fields.getValue(key).toLong()
        fun ids(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonArray.map { it.jsonPrimitive.long }
    }
    private class Fixture {
        var userId = 41L; var enabled = true; var home = true; var role = "management"
        var personalRecognition = true; var sharedRecognition = true; var globalRecognition = true; var sharedEnabled = true
        var folderManage = true; var applyWrites = true; var onlyFirst = false; var writeError: Exception? = null
        var before: suspend (Call) -> Unit = {}; var transform: (Call, JsonObject) -> JsonObject = { _, raw -> raw }
        val concepts = SynologyPhotoSpace.entries.associateWith {
            linkedMapOf(1L to concept(1, 3), 2L to concept(2, 1), 3L to concept(3, 0, false))
        }
        val members = SynologyPhotoSpace.entries.associateWith { linkedMapOf(1L to listOf(51L, 52L, 53L), 2L to listOf(54L), 3L to emptyList()) }
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method in setOf("set_visibility", "set_cover", "hide_item") }
        fun repository(missing: String? = null, version: Int = 2, media: SynologyPhotosMediaTransport? = null) = SynologyPhotosRepository("concepts",
            capabilities.filterKeys { it != missing }.mapValues { (_, cap) -> if (cap.name.endsWith("Browse.Concept")) cap.copy(maxVersion = version) else cap },
            { cap, method, fields ->
                val call = Call(cap.name, cap.maxVersion, method, fields); calls += call; before(call)
                val entries = concepts.getValue(call.space); val items = members.getValue(call.space)
                val raw = when {
                    cap.name.endsWith("UserInfo") -> obj("""{"enabled":$enabled,"id":$userId}""")
                    cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"$role","enable_concept":$personalRecognition}""")
                    cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_concept":$globalRecognition}""")
                    cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$sharedEnabled,"enable_concept":$sharedRecognition}""")
                    cap.name.endsWith("Browse.Concept") && method == "list" -> list(entries.values.filter { fields["show_hidden"] == "true" || it["visibility"] == JsonPrimitive(true) }
                        .drop(call.long("offset").toInt()).take(call.long("limit").toInt()))
                    cap.name.endsWith("Browse.Concept") && method == "get" -> list(call.ids("id").mapNotNull(entries::get))
                    method in setOf("set_visibility", "set_cover", "hide_item") -> {
                        if (writeError is DsmFailure) throw writeError!!
                        if (applyWrites) when (method) {
                            "set_visibility" -> call.ids("id").let { if (onlyFirst) it.take(1) else it }.forEach { id ->
                                entries[id] = JsonObject(entries.getValue(id) + ("visibility" to JsonPrimitive(fields.getValue("visibility").toBoolean()))) }
                            "set_cover" -> { val id = call.long("id"); entries[id] = JsonObject(entries.getValue(id) +
                                ("additional" to obj("""{"thumbnail":{"unit_id":${call.long("photo_id")},"cache_key":"new-cover"}}"""))) }
                            "hide_item" -> { val id = call.long("id"); val selected = call.ids("item_id").let { if (onlyFirst) it.take(1) else it }
                                items[id] = items.getValue(id) - selected.toSet()
                                entries[id] = JsonObject(entries.getValue(id) + ("item_count" to JsonPrimitive(items.getValue(id).size))) }
                        }
                        writeError?.let { throw it }; obj("{}")
                    }
                    cap.name.endsWith("Browse.Timeline") -> if (items.getValue(call.long("concept_id")).isEmpty()) obj("""{"section":[]}""")
                        else obj("""{"section":[{"list":[{"year":2026,"month":10,"day":1,"item_count":1}]}]}""")
                    cap.name.endsWith("Browse.Item") && method == "get" -> list(call.ids("id").map(::photo))
                    cap.name.endsWith("Browse.Item") -> list(items.getValue(call.long("concept_id")).drop(call.long("offset").toInt()).take(call.long("limit").toInt()).map(::photo))
                    cap.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"name":"/Synthetic","parent":8,"additional":{"access_permission":{"view":true,"manage":$folderManage}}}}""")
                    else -> error("Unexpected synthetic call ${call.api}.${call.method}")
                }
                transform(call, raw)
            }, media = media)
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun change(repo: SynologyPhotosRepository, action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.SHOW_CONCEPTS,
            space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL, ids: List<Long> = if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) listOf(1, 2) else listOf(1),
            photoIds: List<Long> = if (action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) listOf(51, 52) else listOf(51)): SynologyPhotoAlbumCheckpoint {
            val originals = repo.managementConcepts(space).filter { it.id in ids }.map(::SynologyPhotoConceptSnapshot)
            return repo.prepareConceptChange(action, originals, if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) emptyList() else photoIds.map { target(it, space).photo() },
                false.takeIf { action == SynologyPhotoAlbumAction.SHOW_CONCEPTS })
        }
    }
    @Test fun `两来源三种管理精确版本字段及持久尝试先于唯一写入`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) for (action in actions) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, action, space); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
            f.before = { if (it.method in setOf("set_visibility", "set_cover", "hide_item")) assertTrue(saved.last().concept!!.attempted) }
            val result = repo.performPhotoAlbum(row) { saved += it }
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertEquals(row.concept!!.originals.map { it.id }.toSet(), result.concept!!.completedIds)
            val call = f.writes.single(); assertEquals(space, call.space)
            assertEquals(if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) 2 else 1, call.version)
            assertEquals(when (action) {
                SynologyPhotoAlbumAction.SHOW_CONCEPTS -> mapOf("id" to "[1,2]", "visibility" to "false")
                SynologyPhotoAlbumAction.COVER_CONCEPT -> mapOf("id" to "1", "photo_id" to "51")
                else -> mapOf("id" to "1", "item_id" to "[51,52]")
            }, call.fields)
            repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
            assertFalse(f.calls.any { it.method == "delete" || it.method == "delete_item" })
            assertTrue(f.calls.filter { it.api.contains("Setting.") || it.api.endsWith("UserInfo") }.all { it.api.startsWith("SYNO.Foto.") })
            if (action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) assertEquals(setOf(51L, 52L), result.concept.removedPhotoIds)
        }
    }
    @Test fun `管理含隐藏主题完整分页普通列表保留缩略图显示与实际阈值`() = runBlocking {
        val f = Fixture(); val entries = f.concepts.getValue(personal); entries.clear()
        (1L..1001L).forEach { entries[it] = concept(it, 3, it % 2 == 0L) }
        val repo = f.ready(); assertEquals(1001, repo.managementConcepts(personal).size)
        val pages = f.calls.filter { it.method == "list" }; assertEquals(listOf("0", "500", "1000"), pages.map { it.fields["offset"] })
        assertTrue(pages.all { it.fields["show_hidden"] == "true" && it.fields["additional"] == "[\"thumbnail\"]" && "show_more" !in it.fields })
        f.calls.clear(); val values = repo.categoryItems(SynologyPhotoCategory.SUBJECTS, 0, 20)
        assertFalse(f.calls.single().fields.containsKey("show_hidden")); assertEquals(2, values.first().conceptDisplayThreshold)
        assertEquals(SynologyPhotoThumbnail(88, "cover-r"), values.first().thumbnail); assertTrue(values.all { it.conceptVisible == true })
    }
    @Test fun `主题编号分页重复无效布尔与负阈值拒绝不当成隐藏`() = runBlocking {
        for (field in listOf("missing", "string", "integer", "threshold", "duplicate")) {
            val f = Fixture(); val repo = f.ready()
            f.transform = { call, raw -> if (call.api.endsWith("Browse.Concept")) {
                val first = raw.getValue("list").jsonArray.first().jsonObject
                list(when (field) {
                    "missing" -> listOf(JsonObject(first - "visibility"))
                    "string" -> listOf(JsonObject(first + ("visibility" to JsonPrimitive("false"))))
                    "integer" -> listOf(JsonObject(first + ("visibility" to JsonPrimitive(0))))
                    "threshold" -> listOf(JsonObject(first + ("display_threshold" to JsonPrimitive(-1))))
                    else -> listOf(first, first)
                })
            } else raw }
            reject { repo.managementConcepts(personal) }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val repo = f.ready()
        f.transform = { c, raw -> if (c.api.endsWith("Browse.Concept")) list(raw.getValue("list").jsonArray.map { JsonObject(it.jsonObject - "visibility") }) else raw }
        assertNull(repo.categoryItems(SynologyPhotoCategory.SUBJECTS, 0, 20).first().conceptVisible)
    }
    @Test fun `能力按来源主题资格和版本决定共享entry不得管理`() = runBlocking {
        val f = Fixture(); val repo = f.repository(); assertFalse(repo.canManageConcepts(personal)); repo.access()
        assertTrue(repo.canManageConcepts(personal, true)); assertTrue(repo.canManageConcepts(SynologyPhotoSpace.SHARED, true))
        f.personalRecognition = false; repo.access(); assertFalse(repo.canManageConcepts(personal)); assertTrue(repo.canManageConcepts(SynologyPhotoSpace.SHARED))
        f.role = "entry"; repo.access(); assertFalse(repo.canManageConcepts(SynologyPhotoSpace.SHARED)); reject { repo.managementConcepts(SynologyPhotoSpace.SHARED) }
        val low = f.repository(version = 1); low.access(); assertFalse(low.canManageConcepts(personal))
        f.personalRecognition = true; f.role = "management"
        val limited = f.repository(missing = "SYNO.Foto.Browse.Timeline"); limited.access()
        assertTrue(limited.canManageConcepts(personal)); assertFalse(limited.canManageConcepts(personal, true)); assertTrue(f.writes.isEmpty())
    }
    @Test fun `提交前复读账号识别空间与管理权限变化均为零写入`() = runBlocking {
        for (mode in 0..7) {
            val f = Fixture(); val repo = f.ready(); val space = if (mode >= 5) SynologyPhotoSpace.SHARED else personal
            val row = f.change(repo, space = space)
            when (mode) { 0 -> f.userId++; 1 -> f.enabled = false; 2 -> f.home = false; 3 -> f.personalRecognition = false
                4 -> f.globalRecognition = false; 5 -> f.role = "entry"; 6 -> f.sharedRecognition = false; else -> f.sharedEnabled = false }
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `显示只核对名称和原显示而封面移除复核完整主题快照`() = runBlocking {
        for (field in listOf("name", "visibility", "item_count", "display_threshold", "additional")) for (action in actions) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, action)
            val entries = f.concepts.getValue(personal)
            entries[1] = JsonObject(entries.getValue(1) + (field to when (field) {
                "name" -> JsonPrimitive("Changed"); "visibility" -> JsonPrimitive(false); "item_count" -> JsonPrimitive(4)
                "display_threshold" -> JsonPrimitive(4); else -> obj("""{"thumbnail":{"unit_id":89,"cache_key":"changed"}}""")
            }))
            if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS && field !in setOf("name", "visibility")) {
                repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
            } else { reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty()) }
        }
    }
    @Test fun `移除要求实际数量阈值而空值不得猜测默认`() = runBlocking {
        for (field in listOf("item_count", "display_threshold", "visibility")) {
            val f = Fixture(); val repo = f.ready(); val entries = f.concepts.getValue(personal)
            entries[1] = JsonObject(entries.getValue(1) - field)
            reject { f.change(repo, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS)
        assertTrue(row.concept!!.originals.single().count!! - row.targets.size < row.concept.originals.single().displayThreshold!!)
    }
    @Test fun `完整主题成员超过500页且跨来源相册非成员或身份变化均拒绝`() = runBlocking {
        val f = Fixture(); val p = f.concepts.getValue(personal); p[1] = concept(1, 601)
        f.members.getValue(personal)[1] = (51L..651L).toList()
        val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS, photoIds = listOf(651))
        assertTrue(f.calls.any { it.api.endsWith("Browse.Item") && it.fields["offset"] == "500" })
        f.transform = { call, raw -> if (call.api.endsWith("Browse.Item") && call.fields["offset"] == "500") list(listOf(photo(51))) else raw }
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        val second = Fixture(); val other = second.ready(); val c = second.change(other, SynologyPhotoAlbumAction.COVER_CONCEPT)
        for (target in listOf(c.targets.single().copy(id = c.targets.single().id.copy(space = SynologyPhotoSpace.SHARED)),
            c.targets.single().copy(id = c.targets.single().id.copy(itemId = 999)), c.targets.single().copy(filename = "Changed.jpg"),
            c.targets.single().copy(albumContext = SynologyPhotoAlbumContext(3, 41)))) reject { other.performPhotoAlbum(c.copy(targets = listOf(target))) {} }
        second.folderManage = false; reject { other.performPhotoAlbum(c) {} }; assertTrue(second.writes.isEmpty())
    }
    @Test fun `原目录权限不能由共享管理贡献或主题权限替代`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.COVER_CONCEPT, space)
            f.folderManage = false
            if (space == personal) reject { repo.performPhotoAlbum(row) {} }
            else {
                // 共享管理者沿用既有目录管理规则，但实时降为entry不得继续。
                f.role = "entry"; reject { repo.performPhotoAlbum(row) {} }
            }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `写后丢回执可由精确状态完成但空回执本身不能成功`() = runBlocking {
        for (action in actions) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, action); f.writeError = IOException("Synthetic lost reply")
            val completed = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, completed.phase)
            assertFalse(completed.concept!!.acknowledged); assertEquals(1, f.writes.size)
            val empty = Fixture(); val e = empty.ready(); val unknown = empty.change(e, action); empty.applyWrites = false
            val pending = e.performPhotoAlbum(unknown) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
            assertTrue(pending.concept!!.acknowledged); assertEquals(1, empty.writes.size)
        }
    }
    @Test fun `未知结果冷恢复只读同编号且完成后也不再提交`() = runBlocking {
        for (action in actions) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, action)
            f.transform = { c, raw -> if (f.writes.isNotEmpty() && c.method == "get" && c.api.endsWith("Browse.Concept")) throw IOException("Synthetic offline") else raw }
            val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
            f.transform = { _, raw -> raw }; val cold = f.repository(); cold.access()
            val completed = cold.performPhotoAlbum(pending) {}; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, completed.phase)
            assertEquals(row.operationId, completed.operationId); cold.reviewPhotoAlbum(completed) {}; assertEquals(1, f.writes.size)
        }
    }
    @Test fun `主题缺项缺布尔或移除计数不符与原件丢失保持未知`() = runBlocking {
        for (mode in 0..6) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS)
            f.transform = { c, raw -> if (f.writes.isEmpty()) raw else when {
                c.api.endsWith("Browse.Concept") && c.method == "get" -> {
                    val first = raw.getValue("list").jsonArray.first().jsonObject
                    when (mode) {
                        0 -> list(emptyList()); 1 -> list(listOf(JsonObject(first - "visibility")))
                        2 -> list(listOf(JsonObject(first - "display_threshold")))
                        3 -> list(listOf(JsonObject(first + ("item_count" to JsonPrimitive(2)))))
                        else -> raw
                    }
                }
                c.api.endsWith("Browse.Item") && c.method == "get" -> when (mode) {
                    4 -> list(emptyList()); 5 -> list(listOf(JsonObject(photo(c.ids("id").single()) + ("filename" to JsonPrimitive("Changed.jpg")))))
                    6 -> throw IOException("Synthetic original unreadable"); else -> raw
                }
                else -> raw
            } }
            val pending = repo.performPhotoAlbum(row) {}; assertEquals("mode $mode", SynologyPhotoAlbumPhase.PENDING, pending.phase)
            assertTrue(pending.concept!!.removedPhotoIds.isEmpty()); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `全部移出允许空成员但必须get仍有实际零计数和原件`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS, photoIds = listOf(51, 52, 53))
        val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
        assertEquals(setOf(51L, 52L, 53L), result.concept!!.removedPhotoIds)
        assertFalse(SynologyPhotoConceptSnapshot(repo.concept(1, personal)).appearsInList)
        assertTrue(f.calls.filter { it.api.endsWith("Browse.Item") && it.method == "get" }.flatMap { it.ids("id") }.containsAll(listOf(51L, 52L, 53L)))
    }
    @Test fun `仅部分匹配需要明确回执而未知部分不提前终结`() = runBlocking {
        for (action in listOf(SynologyPhotoAlbumAction.SHOW_CONCEPTS, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS)) for (ack in listOf(true, false)) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, action); f.onlyFirst = true
            if (!ack) f.writeError = IOException("Synthetic lost reply")
            val result = repo.performPhotoAlbum(row) {}; assertEquals(if (ack) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.PENDING, result.phase)
            val ids = if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) result.concept!!.completedIds else result.concept!!.removedPhotoIds
            assertEquals(if (ack) setOf(if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) 1L else 51L) else emptySet<Long>(), ids)
            repo.reviewPhotoAlbum(result) {}; assertEquals(1, f.writes.size)
        }
    }
    @Test fun `明确拒绝不因其他客户端后来产生相同结果改成功`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo)
        f.writeError = DsmFailure(105, "Synthetic denied", "Synthetic recovery", kind = DsmErrorKind.PERMISSION_DENIED)
        val rejected = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, rejected.phase); assertTrue(rejected.concept!!.rejected)
        f.concepts.getValue(personal).replaceAll { _, value -> JsonObject(value + ("visibility" to JsonPrimitive(false))) }
        val cold = f.repository(); cold.access(); val again = cold.performPhotoAlbum(rejected) {}
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, again.phase); assertTrue(again.concept!!.completedIds.isEmpty()); assertEquals(1, f.writes.size)
    }
    @Test fun `未发送的提交中记录恢复为未完成且不自动写入`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo).copy(phase = SynologyPhotoAlbumPhase.PENDING)
        val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(f.writes.isEmpty())
    }
    @Test fun `封面必须精确选中Item编号不能认领旧封面或其他编号`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.COVER_CONCEPT)
        f.transform = { c, raw -> if (f.writes.isNotEmpty() && c.api.endsWith("Browse.Concept")) list(listOf(concept(1, 3))) else raw }
        val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
        f.transform = { _, raw -> raw }; val done = repo.reviewPhotoAlbum(pending) {}; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
        assertEquals(1, f.writes.size)
    }
    @Test fun `跨授权代次读取不得写入或缓存到新会话`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo)
        var replaced = false
        f.before = { c -> if (!replaced && c.api.endsWith("Browse.Concept") && c.method == "get") {
            replaced = true; repo.access()
        } }
        try { repo.performPhotoAlbum(row) {}; fail("Expected stale authorization cancellation") } catch (_: CancellationException) {}
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `封面请求绑定实际主题来源编号版本且重新授权后失效`() = runBlocking {
        val f = Fixture(); val requests = mutableListOf<Request>(); val profile = NasProfile("concepts", "Synthetic", "https://nas.example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            requests += chain.request(); Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
                .header("Content-Type", "image/png").body(byteArrayOf(1, 2).toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), profile.address, http)
        for (space in SynologyPhotoSpace.entries) {
            val repo = f.repository(media = media); repo.access(); val concept = repo.categoryItems(SynologyPhotoCategory.SUBJECTS, 0, 20, space).first()
            assertArrayEquals(byteArrayOf(1, 2), repo.conceptThumbnail(concept))
            val url = requests.last().url; assertEquals("/synofoto/api/v2/${if (space == personal) "p" else "t"}/Thumbnail/get", url.encodedPath)
            assertEquals("88", url.queryParameter("id")); assertEquals("\"unit\"", url.queryParameter("type")); assertNull(url.queryParameter("album_id"))
            for (bad in listOf(concept.copy(id = 99), concept.copy(space = if (space == personal) SynologyPhotoSpace.SHARED else personal),
                concept.copy(thumbnail = concept.thumbnail!!.copy(revision = "changed")), concept.copy(thumbnail = concept.thumbnail!!.copy(unitId = 99)))) reject { repo.conceptThumbnail(bad) }
            repo.access(); reject { repo.conceptThumbnail(concept) }
        }
        assertEquals(2, requests.size)
    }
    private suspend fun reject(block: suspend () -> Any?) { try { block(); fail("Expected Photos rejection") } catch (_: SynologyPhotoFailure) {} }
    private companion object {
        val personal = SynologyPhotoSpace.PERSONAL
        val actions = listOf(SynologyPhotoAlbumAction.SHOW_CONCEPTS, SynologyPhotoAlbumAction.COVER_CONCEPT, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS)
        fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
        fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
        fun concept(id: Long, count: Int, visible: Boolean = true) = obj("""{"id":$id,"name":"Synthetic $id","item_count":$count,"visibility":$visible,"display_threshold":2,"additional":{"thumbnail":{"unit_id":88,"cache_key":"cover-r"}}}""")
        fun photo(id: Long) = obj("""{"id":$id,"filename":"Synthetic-$id.jpg","filesize":4,"time":1790812800,"indexed_time":1790812800,"folder_id":9,"type":"photo"}""")
        fun target(id: Long, space: SynologyPhotoSpace) = SynologyPhotoEditTarget(SynologyPhotoId("concepts", space, id), "Synthetic-$id.jpg", 4, 1790812800.0, 1790812800.0, 9, "photo")
        val capabilities = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
                "Browse.Concept" to 2, "Browse.Timeline" to 5, "Browse.Item" to 5, "Browse.Folder" to 2).map { (suffix, version) ->
                "$prefix.$suffix" to ApiCapability("$prefix.$suffix", "entry.cgi", 1, version, "JSON")
            }
        }.toMap()
    }
}
