package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test

/** 仅合成资料，驱动正式 Photos 仓储和认证媒体传输；不访问真实 NAS。 */
class SynologyPhotosManualFacesRepositoryTest {
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>) {
        fun ids(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonArray.map { it.jsonPrimitive.long }
        fun text(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonPrimitive.content
    }
    private class Fixture(val space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL) {
        var enabled = true; var role = "management"; var recognition = true; var folderManage = true; var user = 41L
        var filename = "Synthetic.jpg"; var context: SynologyPhotoAlbumContext? = null; var albumType = "normal"; var frozen = false
        var writeError: Exception? = null; var uploadError = false; var uploadRejected = false; var applyUpload = true
        var receipt: JsonObject? = null; var returned = listOf(901L); var before: suspend (Call) -> Unit = {}; var onUpload: () -> Unit = {}
        val calls = mutableListOf<Call>(); val mediaRequests = mutableListOf<Request>(); val events = mutableListOf<String>()
        val faces = linkedMapOf(101L to SynologyPhotoFaceRegion(SynologyPhotoFaceSnapshot(101, 1, "Original", bounds), "old"))
        val names = linkedMapOf(1L to "Original", 2L to "Destination")
        val uploaded = mutableMapOf<Long, ByteArray>(); val saves = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        val photo get() = SynologyPhotoEditTarget(SynologyPhotoId("manual", space, 51), "Synthetic.jpg", 4, 1.0, 2.0, 9, "photo", context).photo()
        val writes get() = calls.filter { it.method in setOf("add_face", "delete_face", "separate") }
        fun save(row: SynologyPhotoAlbumCheckpoint) { validatePhotoAlbumCheckpoint(row); saves += row }
        fun repository(missing: String? = null): SynologyPhotosRepository {
            val profile = NasProfile("manual", "Synthetic", "https://nas.example.invalid", "tester")
            val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); mediaRequests += request
                val bytes: ByteArray; val type: String
                if (request.method == "POST") {
                    val body = request.body!!.let { Buffer().apply { it.writeTo(this) }.readByteArray() }
                    val raw = body.decodeToString()
                    fun field(name: String) = Regex("name=\"$name\"\\r\\n(?:[^\\r\\n]+\\r\\n)*\\r\\n([^\\r\\n]*)").find(raw)!!.groupValues[1]
                    val id = field("face_id").toLong()
                    events += "upload-$id"; onUpload()
                    assertTrue(saves.last().manualFaces!!.uploadAttempted.contains(id))
                    assertTrue(request.body!!.isOneShot()); assertEquals("/webapi/face.cgi", request.url.encodedPath)
                    assertEquals("id=synthetic-session", request.header("Cookie")); assertEquals("synthetic-token", request.header("X-SYNO-TOKEN"))
                    assertEquals(0, request.url.querySize)
                    assertEquals("SYNO.${if (space == SynologyPhotoSpace.SHARED) "FotoTeam" else "Foto"}.Upload.Face", field("api"))
                    assertEquals("1", field("version")); assertEquals("upload", field("method"))
                    assertTrue(raw.contains("name=\"file\"; filename=\"face.jpg\"\r\nContent-Type: image/jpeg"))
                    assertTrue(body.asList().windowed(jpeg.size).any { it == jpeg.asList() })
                    if (applyUpload && !uploadRejected) {
                        uploaded[id] = jpeg
                        faces[id]?.let { faces[id] = it.copy(revision = "new-$id") }
                    }
                    if (uploadError) throw IOException("Synthetic lost upload acknowledgement")
                    type = "application/json"; bytes = (if (uploadRejected) "{\"success\":false,\"error\":{\"code\":400}}" else "{\"success\":true}").encodeToByteArray()
                } else { bytes = uploaded[request.url.queryParameter("id")!!.toLong()] ?: byteArrayOf(1); type = "image/jpeg" }
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
                    .header("Content-Type", type).body(bytes.toResponseBody(type.toMediaType())).build()
            }.build()
            val transport = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), profile.address, http)
            return SynologyPhotosRepository("manual", capabilities.filterKeys { it != missing }, { cap, method, fields ->
                val call = Call(cap.name, cap.maxVersion, method, fields); calls += call; before(call)
                when {
                    cap.name.endsWith("UserInfo") -> obj("""{"enabled":$enabled,"id":$user}""")
                    cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"$role","enable_person":$recognition}""")
                    cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_person":$recognition}""")
                    cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true,"enable_person":$recognition}""")
                    cap.name.endsWith("Browse.Item") && method == "get" -> list(listOf(obj("""{"id":51,"filename":${JsonPrimitive(filename)},"filesize":4,"time":1,"indexed_time":2,"folder_id":9,"type":"photo","owner_user_id":${context?.ownerUserId ?: 41},"additional":{"provider_user_id":${context?.providerUserId ?: 41}}}""")))
                    cap.name.endsWith("Browse.Item") && method == "list_face" -> {
                        assertEquals(6, call.version); assertEquals("51", fields["id_item"]); assertEquals("[\"thumbnail\"]", fields["additional"])
                        list(faces.values.map(::faceJson))
                    }
                    cap.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"name":"/Synthetic","parent":8,"additional":{"access_permission":{"view":true,"manage":$folderManage}}}}""")
                    cap.name.endsWith("Browse.Album") -> list(listOf(obj("""{"id":8,"owner_user_id":${context!!.ownerUserId},"type":"$albumType","freeze_album":$frozen}""")))
                    cap.name.endsWith("Browse.Person") && method == "get" -> list(call.ids("id").mapNotNull { id -> names[id]?.let { obj("""{"id":$id,"name":${JsonPrimitive(it)}}""") } })
                    method == "add_face" -> {
                        events += method; assertTrue(saves.last().manualFaces!!.addAttempted); assertEquals(3, call.version)
                        if (writeError is DsmFailure) throw writeError!!
                        val additions = Json.parseToJsonElement(fields.getValue("face")).jsonArray
                        val receipts = additions.mapIndexedNotNull { index, raw ->
                            val id = returned.getOrNull(index) ?: return@mapIndexedNotNull null
                            val value = raw.jsonObject; val person = value["person_id"]?.jsonPrimitive?.long ?: 90L
                            val name = value["name"]?.jsonPrimitive?.content ?: names.getValue(person)
                            val face = obj("""{"face_id":$id,"person_id":$person,"name":${JsonPrimitive(name)},"face_bounding_box":${value.getValue("face_bounding_box")}}""")
                            faces[id] = SynologyPhotoManualFacesCodec.faces(list(listOf(face))).single()
                            obj("""{"face_id":$id,"face_id_temp":${value.getValue("face_id_temp")}}""")
                        }
                        writeError?.let { throw it }; receipt ?: list(receipts)
                    }
                    method in setOf("delete_face", "separate") -> {
                        events += method; assertEquals(1, call.version)
                        val id = call.ids("face_id").single(); assertTrue("old-$id" in saves.last().manualFaces!!.attempted)
                        if (writeError is DsmFailure) throw writeError!!
                        val target = fields["target_id"]?.toLong() ?: 90L
                        if (method == "delete_face") { assertEquals(faces.getValue(id).face.personId.toString(), fields["person_id"]); faces.remove(id) }
                        else faces.getValue(id).let { faces[id] = it.copy(face = it.face.copy(personId = target, name = call.text("name"))) }
                        writeError?.let { throw it }
                        receipt ?: if (method == "delete_face") obj("{}") else obj("""{"id":$target,"name":${fields.getValue("name")}}""")
                    }
                    else -> error("Unexpected synthetic call ${call.api}.${call.method}")
                }
            }, media = transport)
        }
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        fun add(temp: String = "draft-1", existing: Boolean = true) = SynologyPhotoFaceChange.Add(temp,
            bounds.copy(x = 0.4), if (existing) SynologyPhotoPersonSnapshot(2, "Destination", 1, space) else null,
            if (existing) "Destination" else "New synthetic", SynologyPhotoManualFacesCodec.digest(jpeg))
        suspend fun row(repo: SynologyPhotosRepository, changes: List<SynologyPhotoFaceChange> = listOf(add(), SynologyPhotoFaceChange.Remove(original))) =
            repo.prepareManualFaces(photo, repo.photoFaces(photo).map { it.face }, changes)
    }

    @Test fun `两来源新增先上传再移除旧框并保持原件精确路由与逐步事实`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) {
            val f = Fixture(space); val repo = f.ready(); assertTrue(repo.canEditPhotoFaces(f.photo)); val row = f.row(repo)
            val done = repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save)
            assertEquals("Events=${f.events}, uploadAttempts=${done.manualFaces!!.uploadAttempted}, receipts=${done.manualFaces!!.newIds}",
                SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertEquals(listOf("add_face", "upload-901", "delete_face"), f.events)
            assertEquals(setOf("new-draft-1", "old-101"), done.manualFaces!!.completed); assertEquals(setOf(901L), f.faces.keys)
            assertTrue(f.writes.all { it.api.startsWith(if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam." else "SYNO.Foto.") })
            val fields = f.writes.first().fields; assertEquals(setOf("id_item", "face"), fields.keys)
            val face = Json.parseToJsonElement(fields.getValue("face")).jsonArray.single().jsonObject
            assertEquals(setOf("face_id_temp", "face_bounding_box", "person_id"), face.keys)
            assertEquals("Synthetic.jpg", repo.details(f.photo).filename)
            repo.performManualFaces(row, emptyMap(), f::save); assertEquals(3, f.events.size)
        }
    }
    @Test fun `新人物新增按name且单脸重新归入省略target_id并保留明确人物回执`() = runBlocking {
        for (adding in listOf(true, false)) {
            val f = Fixture(); val repo = f.ready()
            val change = if (adding) f.add(existing = false) else SynologyPhotoFaceChange.Reassign(original, null, "New synthetic")
            val row = f.row(repo, listOf(change)); val done = repo.performManualFaces(row, if (adding) mapOf("draft-1" to jpeg) else emptyMap(), f::save)
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
            if (adding) assertFalse(Json.parseToJsonElement(f.writes.single().fields.getValue("face")).jsonArray.single().jsonObject.containsKey("person_id"))
            else { assertFalse(f.writes.single().fields.containsKey("target_id")); assertEquals(90L, done.manualFaces!!.personReceipts[change.key]) }
        }
    }
    @Test fun `重新归入丢回执只有既有人物编号可只读恢复新人物不得按同名认领`() = runBlocking {
        for (existing in listOf(true, false)) {
            val f = Fixture(); val repo = f.ready(); val change = SynologyPhotoFaceChange.Reassign(original,
                if (existing) SynologyPhotoPersonSnapshot(2, "Destination", 1, f.space) else null, if (existing) "Destination" else "New synthetic")
            val row = f.row(repo, listOf(change)); f.writeError = IOException("Synthetic lost reply")
            val result = repo.performManualFaces(row, emptyMap(), f::save)
            assertEquals(if (existing) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING, result.phase)
            val cold = f.repository(); cold.access(); assertEquals(result.phase, cold.reviewPhotoAlbum(result, f::save).phase); assertEquals(1, f.writes.size)
        }
    }
    @Test fun `新增丢回执和非法回执均不按同名坐标猜编号且禁止上传和删除`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            when (mode) {
                0 -> f.writeError = IOException("Synthetic missing receipt")
                1 -> f.receipt = obj("""{"list":[{"face_id":101,"face_id_temp":"draft-1"}]}""")
                2 -> f.receipt = obj("""{"list":[{"face_id":901,"face_id_temp":"other"}]}""")
                3 -> f.receipt = obj("""{"list":[{"face_id":901,"face_id_temp":"draft-1"},{"face_id":902,"face_id_temp":"draft-1"}]}""")
            }
            val result = repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save)
            assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertTrue(result.manualFaces!!.newIds.isEmpty())
            val cold = f.repository(); cold.access(); cold.performManualFaces(result, emptyMap(), f::save)
            assertEquals(listOf("add_face"), f.events); assertTrue(101L in f.faces)
        }
    }
    @Test fun `部分新增回执只上传已知编号并保留全部旧框`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo, listOf(f.add(), f.add("draft-2"), SynologyPhotoFaceChange.Remove(original)))
        val result = repo.performManualFaces(row, mapOf("draft-1" to jpeg, "draft-2" to jpeg), f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertEquals(setOf("new-draft-1"), result.manualFaces!!.completed)
        assertEquals(setOf("new-draft-2", "old-101"), result.manualFaces!!.failed); assertEquals(listOf("add_face", "upload-901"), f.events)
        assertTrue(101L in f.faces)
    }
    @Test fun `裁剪上传丢回执按明确新编号的相同摘要恢复但不补发旧框删除`() = runBlocking {
        for (matching in listOf(true, false)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.uploadError = true
            f.onUpload = { if (!matching) f.applyUpload = false }
            val result = repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save)
            assertEquals(if (matching) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.PENDING, result.phase)
            assertTrue(101L in f.faces); assertEquals(listOf("add_face", "upload-901"), f.events)
            f.uploadError = false; val cold = f.repository(); cold.access(); cold.reviewPhotoAlbum(result, f::save)
            assertEquals(2, f.events.size)
        }
    }
    @Test fun `上传明确拒绝可结束为部分失败且后续同图不能追认为成功`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.uploadRejected = true
        val result = repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(result.manualFaces!!.completed.isEmpty())
        f.faces[901] = f.faces.getValue(901).copy(revision = "later"); f.uploaded[901] = jpeg
        val cold = f.repository(); cold.access(); assertEquals(result, cold.reviewPhotoAlbum(result, f::save)); assertTrue(101L in f.faces)
    }
    @Test fun `上传响应丢失且缩略图摘要不同保持未知直至只读获取相同图片`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.uploadError = true
        f.before = { if (it.method == "list_face" && 901L in f.uploaded) f.uploaded[901] = jpeg + 7 }
        val result = repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertEquals(emptySet<String>(), result.manualFaces!!.completed)
        assertTrue(f.mediaRequests.any { it.method == "GET" && it.url.queryParameter("id") == "901" })
        f.before = {}; f.uploaded[901] = jpeg
        val cold = f.repository(); cold.access(); val recovered = cold.reviewPhotoAlbum(result, f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, recovered.phase); assertEquals(setOf("new-draft-1"), recovered.manualFaces!!.completed)
        assertEquals(listOf("add_face", "upload-901"), f.events); assertTrue(101L in f.faces)
    }
    @Test fun `新增后授权代次变化丢弃旧回执且不上传不删除不重发`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        f.before = { if (it.method == "add_face") repo.access() }
        val result = repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertTrue(result.manualFaces!!.newIds.isEmpty())
        f.before = {}; val cold = f.repository(); cold.access(); cold.reviewPhotoAlbum(result, f::save)
        assertEquals(listOf("add_face"), f.events); assertTrue(f.mediaRequests.isEmpty()); assertTrue(101L in f.faces)
    }
    @Test fun `新增明确拒绝结束失败不会因后来同名人脸出现而成功`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
        f.writeError = DsmFailure(400, "Synthetic rejected", "Synthetic recovery", kind = DsmErrorKind.PERMISSION_DENIED)
        val result = repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(result.manualFaces!!.addRejected)
        assertEquals(setOf("new-draft-1", "old-101"), result.manualFaces!!.failed); assertTrue(result.manualFaces!!.completed.isEmpty())
        f.faces[901] = SynologyPhotoFaceRegion(original.copy(id = 901, personId = 2, name = "Destination", bounds = f.add().bounds), "later")
        val cold = f.repository(); cold.access(); assertEquals(result, cold.reviewPhotoAlbum(result, f::save)); assertEquals(1, f.events.size)
    }
    @Test fun `写前人物照片权限身份和识别状态变化均零写入`() = runBlocking {
        for (mode in 0..5) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            when (mode) {
                0 -> f.folderManage = false
                1 -> f.names[2] = "Changed"
                2 -> f.filename = "Changed.jpg"
                3 -> f.user = 99
                4 -> f.recognition = false
                5 -> f.faces[101] = f.faces.getValue(101).copy(face = original.copy(bounds = bounds.copy(x = 0.3)))
            }
            reject { repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save) }; assertTrue(f.writes.isEmpty()); assertTrue(f.mediaRequests.isEmpty())
        }
        val f = Fixture(SynologyPhotoSpace.SHARED); val repo = f.ready(); val row = f.row(repo); f.role = "viewer"
        reject { repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save) }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `上传后目录权限撤销停止旧框删除恢复只读且不重复上传`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.row(repo); f.onUpload = { f.folderManage = false }
        val result = repo.performManualFaces(row, mapOf("draft-1" to jpeg), f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(101L in f.faces)
        f.folderManage = true; val cold = f.repository(); cold.access(); cold.reviewPhotoAlbum(result, f::save)
        assertEquals(listOf("add_face", "upload-901"), f.events)
    }
    @Test fun `裁剪缺失或摘要不匹配在开始提交之前拒绝`() = runBlocking {
        for (images in listOf(emptyMap(), mapOf("draft-1" to byteArrayOf(1, 2)), mapOf("draft-1" to (jpeg + 2)))) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo)
            reject { repo.performManualFaces(row, images, f::save) }; assertTrue(f.saves.isEmpty()); assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `持久化失败不发送对应写请求也不继续后续步骤`() = runBlocking {
        for (stage in listOf("start", "add", "receipt", "upload")) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo); var failed = false
            try { repo.performManualFaces(row, mapOf("draft-1" to jpeg)) { next ->
                val v = next.manualFaces!!
                if (!failed && when (stage) { "start" -> !v.addAttempted; "add" -> v.addAttempted; "receipt" -> v.addAcknowledged; else -> v.uploadAttempted.isNotEmpty() }) {
                    failed = true; throw IOException("Synthetic persistence failure")
                }
                f.save(next)
            } } catch (_: IOException) { }
            assertTrue(failed); assertEquals(if (stage in setOf("start", "add")) emptyList<String>() else listOf("add_face"), f.events)
            assertTrue(101L in f.faces)
        }
    }
    @Test fun `移除丢回执只有原件仍相同且该脸消失才能完成`() = runBlocking {
        for (changed in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); val row = f.row(repo, listOf(SynologyPhotoFaceChange.Remove(original)))
            f.writeError = IOException("Synthetic lost reply"); f.before = { if (changed && it.method == "delete_face") f.filename = "Changed.jpg" }
            val result = repo.performManualFaces(row, emptyMap(), f::save)
            assertEquals(if (changed) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED, result.phase)
            assertEquals(listOf("delete_face"), f.events)
        }
    }
    @Test fun `相册来源仅个人提供者或条件冻结拥有者与共享管理者具备资格`() = runBlocking {
        for (mode in 0..5) {
            val f = Fixture(if (mode == 5) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL)
            f.context = SynologyPhotoAlbumContext(8, if (mode == 5) 0 else if (mode == 4) 99 else 41, if (mode == 0) 41 else 99)
            f.albumType = if (mode == 2 || mode == 4) "condition" else "normal"; f.frozen = mode == 3
            val repo = f.ready()
            if (mode in setOf(1, 4)) reject { f.row(repo) } else assertEquals(1, f.row(repo).targets.size)
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `缺能力视频与错误来源不会开放手工编辑`() = runBlocking {
        val f = Fixture(); val repo = f.ready()
        assertFalse(repo.canEditPhotoFaces(f.photo.copy(mediaType = "video"))); assertFalse(repo.canEditPhotoFaces(f.photo.copy(id = f.photo.id.copy(profileId = "other"))))
        for (suffix in listOf("Browse.Item", "Browse.Person", "Upload.Face")) {
            val missing = f.repository("SYNO.Foto.$suffix"); missing.access(); assertFalse(missing.canEditPhotoFaces(f.photo))
        }
    }
    private suspend fun reject(block: suspend () -> Any?) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
    private companion object {
        val jpeg = byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 1, 2, 3)
        val bounds = SynologyPhotoFaceBounds(0.1, 0.2, 0.2, 0.3)
        val original = SynologyPhotoFaceSnapshot(101, 1, "Original", bounds)
        fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
        fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
        fun faceJson(region: SynologyPhotoFaceRegion): JsonObject {
            val face = region.face; val b = face.bounds
            return obj("""{"face_id":${face.id},"person_id":${face.personId},"name":${JsonPrimitive(face.name)},"face_bounding_box":{"top_left":{"x":${b.x},"y":${b.y}},"bottom_right":{"x":${b.x + b.width},"y":${b.y + b.height}}}${region.revision?.let { ",\"additional\":{\"thumbnail\":{\"cache_key\":${JsonPrimitive(it)}}}" } ?: ""}}""")
        }
        val capabilities = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
                "Browse.Person" to 3, "Browse.Item" to 6, "Browse.Folder" to 2, "Browse.Album" to 4, "Upload.Face" to 1).map { (suffix, version) ->
                "$prefix.$suffix" to ApiCapability("$prefix.$suffix", if (suffix == "Upload.Face") "face.cgi" else "entry.cgi", 1, version, "JSON")
            }
        }.toMap()
    }
}
