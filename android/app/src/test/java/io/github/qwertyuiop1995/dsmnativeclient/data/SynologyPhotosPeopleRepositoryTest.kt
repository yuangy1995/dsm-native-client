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

/** 合成传输驱动正式人物仓储，覆盖身份、分页、精确请求和断网只读恢复。 */
class SynologyPhotosPeopleRepositoryTest {
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>) {
        val space get() = if (api.startsWith("SYNO.FotoTeam.")) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
        fun long(key: String) = fields.getValue(key).toLong()
        fun ids(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonArray.map { it.jsonPrimitive.long }
        fun text(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonPrimitive.content
    }
    private class Fixture {
        var userId = 41L; var enabled = true; var home = true; var role = "management"
        var personalRecognition = true; var sharedRecognition = true; var globalRecognition = true; var sharedEnabled = true
        var folderManage = true; var applyWrites = true; var writeError: Exception? = null; var receipt: JsonObject? = null
        var before: suspend (Call) -> Unit = {}; var transform: (Call, JsonObject) -> JsonObject = { _, raw -> raw }
        val people = SynologyPhotoSpace.entries.associateWith { space ->
            linkedMapOf(1L to person(1, "Synthetic A", 1), 2L to person(2, "Synthetic B", 1), 3L to person(3, "", 1, false))
        }
        val members = SynologyPhotoSpace.entries.associateWith { linkedMapOf(1L to listOf(51L), 2L to listOf(52L), 3L to listOf(53L)) }
        val faces = SynologyPhotoSpace.entries.associateWith { linkedMapOf(101L to (1L to 51L), 102L to (1L to 51L), 103L to (1L to 52L)) }
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method in setOf("set", "show", "merge", "delete_face", "separate", "set_cover") }
        fun repository(missing: String? = null, personVersion: Int = 2, media: SynologyPhotosMediaTransport? = null) = SynologyPhotosRepository("people", capabilities.filterKeys { it != missing }.mapValues { (_, cap) ->
            if (cap.name.endsWith("Browse.Person")) cap.copy(maxVersion = personVersion) else cap
        }, { cap, method, fields ->
            val call = Call(cap.name, cap.maxVersion, method, fields); calls += call; before(call)
            val entries = people.getValue(call.space); val media = members.getValue(call.space)
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":$enabled,"id":$userId}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"$role","enable_person":$personalRecognition}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_person":$globalRecognition}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$sharedEnabled,"enable_person":$sharedRecognition}""")
                cap.name.endsWith("Browse.Person") && method == "list" -> list(entries.values.filter { fields["show_hidden"] == "true" || it["show"] == JsonPrimitive(true) }
                    .drop(call.long("offset").toInt()).take(call.long("limit").toInt()))
                cap.name.endsWith("Browse.Person") && method == "get" -> list(call.ids("id").mapNotNull(entries::get))
                cap.name.endsWith("Browse.Person") && method == "list_face" -> list(faces.getValue(call.space).filter {
                    it.value.first == call.long("person_id") && it.value.second in call.ids("item_id")
                }.keys.map { obj("""{"id":$it,"additional":{"thumbnail":{"cache_key":"face-$it"}}}""") })
                cap.name.endsWith("Browse.Item") && method == "get" -> list(call.ids("id").map(::photo))
                method in setOf("delete_face", "separate", "set_cover") -> {
                    if (writeError is DsmFailure) throw writeError!!
                    val target = if (method == "separate") call.long("target_id").takeIf { it > 0 } ?: 90L else 0L
                    if (applyWrites) when (method) {
                        "delete_face" -> call.ids("face_id").forEach { faces.getValue(call.space).remove(it) }
                        "separate" -> { call.ids("face_id").forEach { id -> faces.getValue(call.space)[id] = target to faces.getValue(call.space).getValue(id).second }
                            entries[target] = person(target, call.text("name"), call.ids("face_id").size) }
                        "set_cover" -> { val id = call.long("id"); entries[id] = JsonObject(entries.getValue(id) + ("cover" to JsonPrimitive(701))) }
                    }
                    writeError?.let { throw it }
                    receipt ?: when (method) {
                        "separate" -> obj("""{"id":$target,"name":${fields.getValue("name")}}""")
                        "set_cover" -> obj("""{"id":${call.long("id")},"name":"Synthetic A","cover":701}""")
                        else -> obj("{}")
                    }
                }
                cap.name.endsWith("Browse.Timeline") -> if (media.getValue(call.long("person_id")).isEmpty()) obj("""{"section":[]}""")
                    else obj("""{"section":[{"list":[{"year":2026,"month":10,"day":1,"item_count":1}]}]}""")
                cap.name.endsWith("Browse.Item") -> list(media.getValue(call.long("person_id")).drop(call.long("offset").toInt()).take(call.long("limit").toInt()).map(::photo))
                cap.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"name":"/Synthetic","parent":8,"additional":{"access_permission":{"view":true,"manage":$folderManage}}}}""")
                method in setOf("set", "merge", "show") -> {
                    if (writeError is DsmFailure) throw writeError!!
                    if (applyWrites) when (method) {
                        "set" -> { val id = call.long("id"); val old = entries.getValue(id); val name = call.text("name")
                            entries[id] = JsonObject(old + ("name" to JsonPrimitive(name)) +
                                if (name.isEmpty() && old.getValue("item_count").jsonPrimitive.int < 2) mapOf("show" to JsonPrimitive(false)) else emptyMap()) }
                        "show" -> call.ids("id").forEach { id -> entries[id] = JsonObject(entries.getValue(id) + ("show" to JsonPrimitive(fields.getValue("show").toBoolean()))) }
                        "merge" -> { val target = call.long("target_id"); val sources = call.ids("merged_id")
                            media[target] = (listOf(target) + sources).flatMap { media.getValue(it) }.distinct()
                            entries[target] = person(target, call.text("name"), media.getValue(target).size)
                            sources.forEach { entries.remove(it); media.remove(it) } }
                    }
                    writeError?.let { throw it }
                    receipt ?: if (method == "set") obj("""{"id":${call.long("id")},"name":${fields.getValue("name")}}""") else obj("{}")
                }
                else -> error("Unexpected synthetic call ${call.api}.${call.method}")
            }
            transform(call, result)
        }, media = media)
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        suspend fun faceChange(repo: SynologyPhotosRepository, action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.REMOVE_PERSON_FACES,
            space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL, existing: Boolean = true,
            selectedIds: Set<Long> = setOf(101, 103)): SynologyPhotoAlbumCheckpoint {
            val people = repo.managementPeople(space); val original = SynologyPhotoPersonSnapshot(people.first { it.id == 1L })
            val photos = listOf(51L, 52L).map { SynologyPhotoEditTarget(SynologyPhotoId("people", space, it), "Synthetic-$it.jpg", 4, 1790812800.0, 1790812800.0, 9, "photo").photo() }
            val faces = repo.personFaces(1, photos).filter { it.id in selectedIds }
            val covering = action == SynologyPhotoAlbumAction.COVER_PERSON
            return repo.preparePersonFaces(action, original, if (covering) photos.take(1) else photos.filter { p -> faces.any { it.photoId == p.id } },
                if (covering) emptyList() else faces, if (action == SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES && existing) SynologyPhotoPersonSnapshot(people.first { it.id == 2L }) else null,
                (if (existing) "Synthetic B" else "Synthetic destination").takeIf { action == SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES })
        }
        suspend fun change(repo: SynologyPhotosRepository, action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.RENAME_PERSON,
            space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL, name: String = "Synthetic new", ids: List<Long> = if (action == SynologyPhotoAlbumAction.MERGE_PEOPLE) listOf(1, 2) else listOf(1),
            visible: Boolean = false): SynologyPhotoAlbumCheckpoint {
            val originals = repo.managementPeople(space, action == SynologyPhotoAlbumAction.SHOW_PEOPLE).filter { it.id in ids }.sortedBy { ids.indexOf(it.id) }.map(::SynologyPhotoPersonSnapshot)
            return repo.preparePeopleChange(action, originals, name.takeUnless { action == SynologyPhotoAlbumAction.SHOW_PEOPLE }, visible.takeIf { action == SynologyPhotoAlbumAction.SHOW_PEOPLE })
        }
    }
    @Test fun `名称显示与合并在两来源发送精确版本字段并持久尝试后才写`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) for (action in listOf(SynologyPhotoAlbumAction.RENAME_PERSON, SynologyPhotoAlbumAction.MERGE_PEOPLE, SynologyPhotoAlbumAction.SHOW_PEOPLE)) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, action, space)
            val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
            f.before = { if (it.method in setOf("set", "merge", "show")) assertTrue(saved.last().people!!.attempted) }
            val result = repo.performPhotoAlbum(row) { saved += it }
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
            val call = f.writes.single(); assertEquals(space, call.space)
            assertEquals(if (action == SynologyPhotoAlbumAction.MERGE_PEOPLE) 2 else 1, call.version)
            assertEquals(when (action) {
                SynologyPhotoAlbumAction.RENAME_PERSON -> mapOf("id" to "1", "name" to "\"Synthetic new\"")
                SynologyPhotoAlbumAction.MERGE_PEOPLE -> mapOf("target_id" to "1", "merged_id" to "[2]", "name" to "\"Synthetic new\"")
                else -> mapOf("id" to "[1]", "show" to "false")
            }, call.fields)
            assertEquals(row.people!!.originals.map { it.id }.toSet(), result.people!!.completedIds)
            repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
            assertTrue(f.calls.filter { it.api.contains("Setting.") || it.api.endsWith("UserInfo") }.all { it.api.startsWith("SYNO.Foto.") })
        }
    }
    @Test fun `完整显示管理含隐藏项严格分页且普通人物列表不强加隐藏参数`() = runBlocking {
        val f = Fixture(); val entries = f.people.getValue(SynologyPhotoSpace.PERSONAL); entries.clear()
        (1L..1001L).forEach { entries[it] = person(it, "Synthetic $it", 0, it % 2 == 0L) }
        val repo = f.ready(); assertEquals(1001, repo.managementPeople(SynologyPhotoSpace.PERSONAL, true).size)
        val pages = f.calls.filter { it.method == "list" }; assertEquals(listOf("0", "500", "1000"), pages.map { it.fields["offset"] })
        assertTrue(pages.all { it.fields["show_more"] == "true" && it.fields["show_hidden"] == "true" && it.fields["additional"] == "[\"thumbnail\"]" })
        f.calls.clear(); repo.categoryItems(SynologyPhotoCategory.PEOPLE, 0, 20)
        assertFalse(f.calls.single().fields.containsKey("show_hidden")); assertFalse(f.calls.single().fields.containsKey("show_more"))
    }
    @Test fun `人物封面读取保留person与unit类型且show可选只用于普通列表`() = runBlocking {
        val f = Fixture(); val entries = f.people.getValue(SynologyPhotoSpace.PERSONAL)
        entries[1] = JsonObject(entries.getValue(1) + ("additional" to obj("""{"thumbnail":{"cache_key":"person-r"}}""")))
        entries[2] = JsonObject(entries.getValue(2) + ("additional" to obj("""{"thumbnail":{"unit_id":92,"cache_key":"unit-r"}}""")))
        val repo = f.ready(); val people = repo.categoryItems(SynologyPhotoCategory.PEOPLE, 0, 20)
        assertEquals(SynologyPhotoPersonCover(1, "person-r", SynologyPhotoPersonCover.Type.PERSON), people[0].personCover)
        assertEquals(SynologyPhotoPersonCover(92, "unit-r", SynologyPhotoPersonCover.Type.UNIT), people[1].personCover)
        f.transform = { call, raw -> if (call.api.endsWith("Browse.Person")) list(raw.getValue("list").jsonArray.map { JsonObject(it.jsonObject - "show") }) else raw }
        assertTrue(repo.categoryItems(SynologyPhotoCategory.PEOPLE, 0, 20).all { it.personVisible == null })
        reject { repo.managementPeople(SynologyPhotoSpace.PERSONAL, true) }
    }
    @Test fun `封面只允许本代次已读取的来源人物与精确类型重新授权失效`() = runBlocking {
        val f = Fixture(); val requests = mutableListOf<Request>()
        val profile = NasProfile("people", "Synthetic", "https://nas.example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); requests += request
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic").header("Content-Type", "image/png")
                .body(byteArrayOf(1, 2, 3).toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), profile.address, http)
        val repo = f.repository(media = media); repo.access()
        val entries = f.people.getValue(SynologyPhotoSpace.PERSONAL)
        entries[1] = JsonObject(entries.getValue(1) + ("additional" to obj("""{"thumbnail":{"cache_key":"person-r"}}""")))
        val person = repo.categoryItems(SynologyPhotoCategory.PEOPLE, 0, 10).first()
        assertArrayEquals(byteArrayOf(1, 2, 3), repo.personThumbnail(person)); assertEquals(1, requests.size)
        for (forged in listOf(person.copy(id = 9), person.copy(space = SynologyPhotoSpace.SHARED),
            person.copy(personCover = person.personCover!!.copy(type = SynologyPhotoPersonCover.Type.UNIT)),
            person.copy(personCover = person.personCover!!.copy(revision = "changed")))) reject { repo.personThumbnail(forged) }
        assertEquals(1, requests.size); repo.access(); reject { repo.personThumbnail(person) }; assertEquals(1, requests.size)
        repo.categoryItems(SynologyPhotoCategory.PEOPLE, 0, 10); repo.personThumbnail(person); assertEquals(2, requests.size)
        f.personalRecognition = false; repo.access(); reject { repo.personThumbnail(person) }; assertEquals(2, requests.size)
    }
    @Test fun `资格按当前来源识别与版本区分共享entry不得管理`() = runBlocking {
        val f = Fixture(); val repo = f.repository(personVersion = 1)
        assertFalse(repo.canManagePeople(SynologyPhotoSpace.PERSONAL)); repo.access()
        assertTrue(repo.canManagePeople(SynologyPhotoSpace.PERSONAL)); assertFalse(repo.canManagePeople(SynologyPhotoSpace.PERSONAL, true))
        f.home = false; repo.access(); assertFalse(repo.canManagePeople(SynologyPhotoSpace.PERSONAL)); assertTrue(repo.canManagePeople(SynologyPhotoSpace.SHARED))
        f.role = "entry"; repo.access(); assertFalse(repo.canManagePeople(SynologyPhotoSpace.SHARED)); reject { repo.managementPeople(SynologyPhotoSpace.SHARED, true) }
        f.role = "management"; f.sharedRecognition = false; repo.access(); assertFalse(repo.canManagePeople(SynologyPhotoSpace.SHARED))
        f.home = true; f.personalRecognition = false; repo.access(); assertFalse(repo.canManagePeople(SynologyPhotoSpace.PERSONAL)); assertTrue(f.writes.isEmpty())
    }
    @Test fun `提交前复读账号全局个人共享权限防止旧资格写入`() = runBlocking {
        for (mode in 0..7) {
            val f = Fixture(); val repo = f.ready(); val space = if (mode >= 5) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
            val row = f.change(repo, space = space)
            when (mode) { 0 -> f.userId++; 1 -> f.enabled = false; 2 -> f.globalRecognition = false; 3 -> f.personalRecognition = false
                4 -> f.home = false; 5 -> f.role = "entry"; 6 -> f.sharedEnabled = false; else -> f.sharedRecognition = false }
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `名称计数显示快照变化与混来源重复人物均拒绝零写入`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.SHOW_PEOPLE)
            val fields = when (mode) { 0 -> mapOf("name" to JsonPrimitive("Changed")); 1 -> mapOf("item_count" to JsonPrimitive(3)); else -> mapOf("show" to JsonPrimitive(false)) }
            f.people.getValue(SynologyPhotoSpace.PERSONAL)[1] = JsonObject(f.people.getValue(SynologyPhotoSpace.PERSONAL).getValue(1) + fields)
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val repo = f.ready(); val originals = f.change(repo).people!!.originals
        reject { repo.preparePeopleChange(SynologyPhotoAlbumAction.MERGE_PEOPLE, originals + originals, "Merged") }
        reject { repo.preparePeopleChange(SynologyPhotoAlbumAction.MERGE_PEOPLE, originals + originals.single().copy(id = 2, space = SynologyPhotoSpace.SHARED), "Merged") }
        reject { repo.preparePeopleChange(SynologyPhotoAlbumAction.RENAME_PERSON, originals, originals.single().name) }
        reject { repo.preparePeopleChange(SynologyPhotoAlbumAction.SHOW_PEOPLE, originals, visible = true) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `合并前完整读取照片并核对目录权限和成员并集`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.folderManage = false
        reject { f.change(repo, SynologyPhotoAlbumAction.MERGE_PEOPLE) }; assertTrue(f.writes.isEmpty())
        f.folderManage = true; val row = f.change(repo, SynologyPhotoAlbumAction.MERGE_PEOPLE)
        assertEquals(setOf(51L, 52L), row.people!!.memberIds)
        f.members.getValue(SynologyPhotoSpace.PERSONAL)[2] = listOf(54)
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `合并完整照片分页超过500且重复页不能提交`() = runBlocking {
        val f = Fixture(); val p = SynologyPhotoSpace.PERSONAL
        f.members.getValue(p)[1] = (100L..699L).toList(); f.people.getValue(p)[1] = person(1, "Synthetic A", 600)
        val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.MERGE_PEOPLE)
        assertEquals(601, row.people!!.memberIds!!.size)
        assertTrue(f.calls.any { it.api.endsWith("Browse.Item") && it.fields["offset"] == "500" })
        f.transform = { call, raw -> if (call.api.endsWith("Browse.Item") && call.fields["offset"] == "500") list(listOf(photo(100))) else raw }
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `合并读取完整成员计数不符或分页人物重复均失败`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.people.getValue(SynologyPhotoSpace.PERSONAL)[1] = person(1, "Synthetic A", 2)
        reject { f.change(repo, SynologyPhotoAlbumAction.MERGE_PEOPLE) }
        f.transform = { call, raw -> if (call.api.endsWith("Browse.Person")) list(listOf(person(1, "A", 1), person(1, "A", 1))) else raw }
        reject { repo.managementPeople(SynologyPhotoSpace.PERSONAL, true) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `合并回执不代替目标名来源消失和完整成员核对`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.MERGE_PEOPLE)
            f.transform = { call, raw ->
                if (call.method == "merge") when (mode) {
                    0 -> f.people.getValue(call.space)[1] = person(1, "Wrong", 2)
                    1 -> f.people.getValue(call.space)[2] = person(2, "Synthetic B", 1)
                    else -> f.members.getValue(call.space)[1] = listOf(51)
                }; raw
            }
            val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
            assertTrue(result.people!!.acknowledged); assertTrue(result.people!!.completedIds.isEmpty()); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `丢失回执后名称合并显示可按固定身份结果只读恢复且从不重发`() = runBlocking {
        for (action in listOf(SynologyPhotoAlbumAction.RENAME_PERSON, SynologyPhotoAlbumAction.MERGE_PEOPLE, SynologyPhotoAlbumAction.SHOW_PEOPLE)) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, action); f.applyWrites = false; f.writeError = IOException("Synthetic lost receipt")
            val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
            val p = SynologyPhotoSpace.PERSONAL
            when (action) {
                SynologyPhotoAlbumAction.RENAME_PERSON -> f.people.getValue(p)[1] = person(1, "Synthetic new", 1)
                SynologyPhotoAlbumAction.MERGE_PEOPLE -> { f.people.getValue(p).remove(2); f.people.getValue(p)[1] = person(1, "Synthetic new", 2); f.members.getValue(p)[1] = listOf(51, 52) }
                else -> f.people.getValue(p)[1] = person(1, "Synthetic A", 1, false)
            }
            val cold = f.repository(); cold.access(); val result = cold.performPhotoAlbum(pending) {}
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertFalse(result.people!!.acknowledged); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `清空小人物名称需精确回执及列表缺席丢回执或错回执不认领`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, name = "")
            when (mode) { 1 -> f.writeError = IOException("Synthetic"); 2 -> f.receipt = obj("""{"id":2,"name":""}"""); 3 -> f.receipt = obj("""{"id":1,"name":"Wrong"}""") }
            val result = repo.performPhotoAlbum(row) {}
            assertEquals(if (mode == 0) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING, result.phase)
            assertEquals(if (mode == 0) setOf(1L) else emptySet<Long>(), result.people!!.removedIds)
            val cold = f.repository(); cold.access(); assertEquals(result, cold.performPhotoAlbum(result) {}); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `明确拒绝不会按随后出现的同名人物追认成功`() = runBlocking {
        for (code in listOf(100, 105, 119, 1200)) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo); f.writeError = DsmFailure(code, "Synthetic", "Synthetic recovery")
            val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(result.people!!.rejected)
            f.people.getValue(SynologyPhotoSpace.PERSONAL)[1] = person(1, "Synthetic new", 1)
            assertEquals(result, repo.performPhotoAlbum(result) {}); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `显示部分匹配仅明确回执可结束未知保持pending且缺项字段不当隐藏成功`() = runBlocking {
        for (mode in 0..4) {
            val f = Fixture(); val repo = f.ready(); val row = f.change(repo, SynologyPhotoAlbumAction.SHOW_PEOPLE, ids = listOf(1, 2))
            f.applyWrites = false; if (mode == 1) f.writeError = IOException("Synthetic")
            f.before = { if (it.method == "show") f.people.getValue(it.space)[1] = person(1, "Synthetic A", 1, false) }
            f.transform = { call, raw -> if (call.method == "get" && call.api.endsWith("Browse.Person") && f.writes.isNotEmpty()) when (mode) {
                2 -> list(listOf(person(1, "Synthetic A", 1, false)))
                3 -> list(listOf(person(1, "Synthetic A", 1, false), JsonObject(person(2, "Synthetic B", 1) - "show")))
                4 -> list(listOf(person(1, "Synthetic A", 1, false), JsonObject(person(2, "Synthetic B", 1) + ("show" to JsonPrimitive("false")))))
                else -> raw
            } else raw }
            val result = repo.performPhotoAlbum(row) {}
            assertEquals(if (mode == 0) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.PENDING, result.phase)
            assertEquals(if (mode == 0) setOf(1L) else emptySet<Long>(), result.people!!.completedIds); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `显示选择最多100项且必须全部有相反状态`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val originals = (1L..101L).map { SynologyPhotoPersonSnapshot(it, "Synthetic", 1, SynologyPhotoSpace.PERSONAL, true) }
        reject { repo.preparePeopleChange(SynologyPhotoAlbumAction.SHOW_PEOPLE, originals, visible = false) }
        reject { repo.preparePeopleChange(SynologyPhotoAlbumAction.SHOW_PEOPLE, originals.take(1).map { it.copy(visible = null) }, visible = false) }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `存储失败或取消不重发尚未尝试记录只读结束`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.change(repo)
        try { repo.performPhotoAlbum(row) { if (it.people!!.attempted) throw IOException("Synthetic storage") } } catch (_: IOException) {}
        assertTrue(f.writes.isEmpty()); repo.performPhotoAlbum(row) {}; assertTrue(f.writes.isEmpty())
        val g = Fixture(); val cold = g.ready(); val pending = g.change(cold).copy(phase = SynologyPhotoAlbumPhase.PENDING)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, cold.performPhotoAlbum(pending) {}.phase); assertTrue(g.writes.isEmpty())
        val h = Fixture(); val canceled = h.ready(); val ready = h.change(canceled); h.writeError = CancellationException()
        val result = canceled.performPhotoAlbum(ready) {}; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
        canceled.performPhotoAlbum(ready) {}; assertEquals(1, h.writes.size)
    }
    @Test fun `缺少合并接口与读取异常不降级到其他来源或动作`() = runBlocking {
        val f = Fixture(); val repo = f.repository(missing = "SYNO.FotoTeam.Browse.Person"); repo.access()
        assertFalse(repo.canManagePeople(SynologyPhotoSpace.SHARED)); assertTrue(repo.canManagePeople(SynologyPhotoSpace.PERSONAL, true))
        reject { f.change(repo, SynologyPhotoAlbumAction.MERGE_PEOPLE, SynologyPhotoSpace.SHARED) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `人脸按照片独立读取精确参数严格建立归属且不接受重复编号`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.faceChange(repo)
        val calls = f.calls.filter { it.method == "list_face" }
        assertTrue(calls.isNotEmpty()); assertTrue(calls.all { it.fields.keys == setOf("person_id", "item_id") && it.ids("item_id").size == 1 })
        assertEquals(listOf(51L, 52L), row.people!!.faces!!.selected.map { it.photoId.itemId })
        f.transform = { call, raw -> if (call.method == "list_face") list(listOf(obj("""{"id":101}"""))) else raw }
        reject { repo.personFaces(1, row.targets.map { it.photo() }) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `人脸移出归入已有新人物及封面在两来源请求精确且写前记录尝试`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) for (mode in 0..3) {
            val action = when (mode) { 0 -> SynologyPhotoAlbumAction.REMOVE_PERSON_FACES; 3 -> SynologyPhotoAlbumAction.COVER_PERSON; else -> SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES }
            val f = Fixture(); val repo = f.ready(); val row = f.faceChange(repo, action, space, mode != 2)
            val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
            f.before = { if (it.method in setOf("delete_face", "separate", "set_cover")) assertTrue(saved.last().people!!.attempted) }
            val result = repo.performPhotoAlbum(row) { saved += it }; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
            val call = f.writes.single(); assertEquals(space, call.space); assertEquals(1, call.version)
            assertEquals(when (mode) {
                0 -> mapOf("person_id" to "1", "face_id" to "[101,103]")
                3 -> mapOf("id" to "1", "photo_id" to "51")
                else -> mapOf("name" to if (mode == 2) "\"Synthetic destination\"" else "\"Synthetic B\"", "target_id" to if (mode == 2) "0" else "2", "face_id" to "[101,103]")
            }, call.fields)
            // 51中仍有102；只有52从当前人物详情移走，原件get继续可读。
            assertEquals(if (mode == 3) emptySet<Long>() else setOf(52L), result.people!!.faces!!.removedPhotoIds)
            if (mode == 3) assertEquals(701L, result.people.faces!!.coverReceipt)
            if (mode == 2) assertEquals(90L, result.people.faces!!.targetReceipt)
            repo.performPhotoAlbum(row) {}; assertEquals(1, f.writes.size)
            assertTrue(f.calls.none { it.method == "delete" })
        }
    }
    @Test fun `移出和归入已有目标丢回执冷恢复只回读新人物封面丢回执仍未知`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val action = when (mode) { 0 -> SynologyPhotoAlbumAction.REMOVE_PERSON_FACES; 3 -> SynologyPhotoAlbumAction.COVER_PERSON; else -> SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES }
            val row = f.faceChange(repo, action, existing = mode != 2); f.writeError = IOException("Synthetic lost receipt")
            // 首次提交回读失败，保证经过序列化和新仓储后才完成。
            f.transform = { call, raw -> if (f.writes.isNotEmpty() && call.method in setOf("list_face", "get")) throw IOException("Synthetic unavailable") else raw }
            val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
            f.transform = { _, raw -> raw }; f.writeError = null
            val cold = f.repository(); cold.access()
            val json = Json { encodeDefaults = true }; val restored = json.decodeFromString<SynologyPhotoAlbumCheckpoint>(json.encodeToString(SynologyPhotoAlbumCheckpoint.serializer(), pending))
            val result = cold.performPhotoAlbum(restored) {}
            assertEquals(if (mode < 2) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING, result.phase)
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `明确回执冷恢复保留新人物编号与不透明封面编号`() = runBlocking {
        for (action in listOf(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, SynologyPhotoAlbumAction.COVER_PERSON)) {
            val f = Fixture(); val repo = f.ready(); val row = f.faceChange(repo, action, existing = false)
            f.transform = { call, raw -> if (f.writes.isNotEmpty() && call.method == "get") throw IOException("Synthetic after receipt") else raw }
            val pending = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
            assertTrue(pending.people!!.acknowledged); f.transform = { _, raw -> raw }
            val cold = f.repository(); cold.access(); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, cold.performPhotoAlbum(pending) {}.phase)
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `原件身份或目标人脸归属照片变化不能误报成功`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val row = f.faceChange(repo, SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES)
            f.transform = { call, raw -> if (f.writes.isNotEmpty()) when {
                mode == 0 && call.api.endsWith("Browse.Item") && call.method == "get" -> list(raw.getValue("list").jsonArray.map { JsonObject(it.jsonObject + ("filesize" to JsonPrimitive(55))) })
                mode == 1 && call.method == "list_face" && call.long("person_id") == 2L -> list(emptyList())
                mode == 2 && call.method == "list_face" && call.long("person_id") == 2L -> list(listOf(obj("""{"id":${if (call.ids("item_id").single() == 51L) 103 else 101}}""")))
                mode == 3 && call.api.endsWith("Browse.Person") && call.method == "get" -> list(listOf(person(2, "Changed", 2)))
                else -> raw
            } else raw }
            val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
            assertTrue(result.people!!.completedIds.isEmpty()); assertTrue(result.people.faces!!.removedPhotoIds.isEmpty()); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `封面必须精确回执且回读不把照片编号猜成封面`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val row = f.faceChange(repo, SynologyPhotoAlbumAction.COVER_PERSON)
            f.receipt = when (mode) { 0 -> obj("{}"); 1 -> obj("""{"id":9,"cover":701}"""); 2 -> obj("""{"id":1,"cover":0}"""); else -> obj("""{"id":1,"cover":51}""") }
            val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
            assertEquals(1, f.writes.size); assertTrue(result.people!!.completedIds.isEmpty())
        }
    }
    @Test fun `新人物回执同名或编号错误不认领来源人脸仍在则不完成`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val row = f.faceChange(repo, SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, existing = false)
            f.receipt = when (mode) { 0 -> obj("{}"); 1 -> obj("""{"id":1,"name":"Synthetic destination"}"""); 2 -> obj("""{"id":90,"name":"Unexpected"}"""); else -> null }
            if (mode == 3) f.applyWrites = false
            val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
            assertEquals(1, f.writes.size); assertTrue(result.people!!.completedIds.isEmpty())
        }
    }
    @Test fun `提交前人物照片人脸与实际目录权限变化阻止写入`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) for (mode in 0..7) {
            val f = Fixture(); val repo = f.ready(); val row = f.faceChange(repo, SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, space)
            when (mode) {
                0 -> if (space == SynologyPhotoSpace.PERSONAL) f.folderManage = false else
                    f.transform = { call, raw -> if (call.api.endsWith("Browse.Folder")) obj("""{"folder":{"id":99,"name":"/Synthetic","parent":8}}""") else raw }
                1 -> f.people.getValue(space)[1] = person(1, "Changed", 1)
                2 -> f.people.getValue(space)[2] = person(2, "Changed", 1)
                3 -> f.faces.getValue(space)[101] = 2L to 51L
                4 -> f.userId = 99
                5 -> f.globalRecognition = false
                6 -> if (space == SynologyPhotoSpace.PERSONAL) f.home = false else f.role = "viewer"
                7 -> f.transform = { call, raw -> if (call.api.endsWith("Browse.Item") && call.method == "get") list(listOf(JsonObject(photo(51) + ("filename" to JsonPrimitive("Changed.jpg"))))) else raw }
            }
            reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `人脸明确拒绝不因后续相同状态改为成功`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.faceChange(repo)
        f.writeError = DsmFailure(105, "Synthetic denied", "Synthetic recovery", kind = DsmErrorKind.PERMISSION_DENIED)
        val result = repo.performPhotoAlbum(row) {}; assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(result.people!!.rejected)
        f.faces.getValue(SynologyPhotoSpace.PERSONAL).clear(); f.writeError = null
        val cold = f.repository(); cold.access(); val again = cold.reviewPhotoAlbum(result) {}
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, again.phase); assertTrue(again.people!!.completedIds.isEmpty()); assertEquals(1, f.writes.size)
    }
    @Test fun `人脸缩略图精确来源类型且伪造重授权与已移出身份失效`() = runBlocking {
        val f = Fixture(); val requests = mutableListOf<Request>(); val profile = NasProfile("people", "Synthetic", "https://nas.example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            requests += chain.request(); Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic").header("Content-Type", "image/png")
                .body(byteArrayOf(1, 2).toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), profile.address, http)
        for (space in SynologyPhotoSpace.entries) {
            val repo = f.repository(media = media); repo.access(); val row = f.faceChange(repo, space = space)
            val face = repo.personFaces(1, row.targets.map { it.photo() }).first()
            assertArrayEquals(byteArrayOf(1, 2), repo.faceThumbnail(face))
            val url = requests.last().url; assertEquals("/synofoto/api/v2/${if (space == SynologyPhotoSpace.SHARED) "t" else "p"}/Thumbnail/get", url.encodedPath)
            assertEquals("\"face\"", url.queryParameter("type")); assertEquals("101", url.queryParameter("id")); assertNull(url.queryParameter("size")); assertNull(url.queryParameter("album_id"))
            for (wrong in listOf(face.copy(id = 999), face.copy(personId = 2), face.copy(revision = "wrong"), face.copy(photoId = face.photoId.copy(itemId = 99)))) reject { repo.faceThumbnail(wrong) }
            f.faces.getValue(space).remove(101); repo.personFaces(1, row.targets.map { it.photo() }); reject { repo.faceThumbnail(face) }
            repo.access(); reject { repo.faceThumbnail(face) }
        }
        assertEquals(2, requests.size)
    }
    private suspend fun reject(block: suspend () -> Any?) { try { block(); fail("Expected Photos rejection") } catch (_: SynologyPhotoFailure) {} }
    private companion object {
        fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
        fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
        fun person(id: Long, name: String, count: Int, shown: Boolean = true) = obj("""{"id":$id,"name":${JsonPrimitive(name)},"item_count":$count,"show":$shown}""")
        fun photo(id: Long) = obj("""{"id":$id,"filename":"Synthetic-$id.jpg","filesize":4,"time":1790812800,"indexed_time":1790812800,"folder_id":9,"type":"photo"}""")
        val capabilities = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
                "Browse.Person" to 2, "Browse.Timeline" to 5, "Browse.Item" to 5, "Browse.Folder" to 2).map { (suffix, version) ->
                "$prefix.$suffix" to ApiCapability("$prefix.$suffix", "entry.cgi", 1, version, "JSON")
            }
        }.toMap()
    }
}
