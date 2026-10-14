package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 纯合成资料；验证资料写入契约、权限与恢复，不作为真实 NAS 写入证据。 */
class SynologyPhotosEditRepositoryTest {
    internal data class Call(val api: String, val method: String, val fields: Map<String, String>, val version: Int)
    internal class Fixture(val caps: Map<String, ApiCapability> = capabilities()) {
        var home = true
        var shared = "management"
        var user = 41L
        var manage = true
        var view = true
        var albumOwner = 41L
        var albumType = "normal"
        var frozen = false
        var provider = 41L
        var receipt = "{}"
        var omitTags = false
        var apply = true
        var swapDimensions = true
        val values = mutableMapOf<SynologyPhotoId, SynologyPhoto>()
        val tagValues = mutableListOf(SynologyPhotoChoice(51, "Synthetic"))
        val calls = mutableListOf<Call>()
        var before: suspend (Call) -> Unit = {}
        var after: suspend (Call) -> Unit = {}
        val writes get() = calls.filter { it.method in setOf("set", "add_tag", "remove_tag", "create") }
        val repository = SynologyPhotosRepository("profile-a", caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields, cap.maxVersion)
            calls += call; before(call)
            val space = if (cap.name.startsWith("SYNO.FotoTeam")) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$user}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"$shared"}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
                cap.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":${fields["id"]},"additional":{"access_permission":{"view":$view,"manage":$manage,"upload":true}}}}""")
                cap.name.endsWith("Browse.Album") -> obj("""{"list":[{"id":71,"owner_user_id":$albumOwner,"type":"$albumType","freeze_album":$frozen}]}""")
                cap.name.endsWith("Browse.GeneralTag") && method == "create" -> {
                    val tag = SynologyPhotoChoice(52, Json.parseToJsonElement(fields.getValue("name")).jsonPrimitive.content)
                    tagValues += tag
                    buildJsonObject { put("tag", Json.encodeToJsonElement(tag)) }
                }
                cap.name.endsWith("Browse.GeneralTag") -> buildJsonObject { put("list", Json.encodeToJsonElement(tagValues)) }
                cap.name.endsWith("Browse.Item") && method == "get" -> {
                    val id = Json.parseToJsonElement(fields.getValue("id")).jsonArray.single().jsonPrimitive.long
                    val photo = if (fields["album_id"] != null) values.values.single { it.id.itemId == id }
                        else values[SynologyPhotoId("profile-a", space, id)]!!
                    buildJsonObject { put("list", buildJsonArray { add(encode(photo)) }) }
                }
                cap.name.endsWith("Browse.Item") -> {
                    if (apply) for (id in Json.parseToJsonElement(fields.getValue("id")).jsonArray.map { it.jsonPrimitive.long }) {
                        val key = SynologyPhotoId("profile-a", space, id)
                        val photo = values.getValue(key)
                        val tags = fields["tag"]?.let { Json.parseToJsonElement(it).jsonArray.map { it.jsonPrimitive.long } }.orEmpty()
                        val rotation = fields["rotate_action"] != null
                        values[key] = photo.copy(
                            orientation = if (rotation) SynologyPhotoEdit.Rotation(photo.orientation!!, photo.width, photo.height).expectedOrientation else photo.orientation,
                            width = if (rotation && swapDimensions) photo.height else photo.width,
                            height = if (rotation && swapDimensions) photo.width else photo.height,
                            rating = fields["rating"]?.toInt() ?: photo.rating,
                            description = fields["description"]?.let { Json.parseToJsonElement(it).jsonPrimitive.content } ?: photo.description,
                            takenAt = fields["time"]?.toDouble() ?: photo.takenAt,
                            tags = when (method) {
                                "add_tag" -> (photo.tags.orEmpty() + tags.map { id -> tagValues.single { it.id == id } }).distinctBy { it.id }
                                "remove_tag" -> photo.tags.orEmpty().filterNot { it.id in tags }
                                else -> photo.tags
                            })
                    }
                    obj(receipt)
                }
                else -> error("Unexpected synthetic request")
            }
            after(call); result
        })
        private fun encode(p: SynologyPhoto): JsonObject = buildJsonObject {
            put("id", p.id.itemId); put("filename", p.filename); put("filesize", p.sizeBytes); put("time", p.takenAt)
            put("indexed_time", p.indexedAt); put("folder_id", p.folderId); put("type", p.mediaType)
            p.albumContext?.let { put("owner_user_id", it.ownerUserId) }
            put("additional", buildJsonObject {
                p.orientation?.let { put("orientation", it) }; p.originalOrientation?.let { put("orientation_original", it) }
                if (p.width != null && p.height != null) put("resolution", buildJsonObject { put("width", p.width); put("height", p.height) })
                put("provider_user_id", provider); p.rating?.let { put("rating", it) }; p.description?.let { put("description", it) }
                if (!omitTags) p.tags?.let { put("tag", Json.encodeToJsonElement(it)) }
            })
        }
        fun add(space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL, id: Long = 91, album: SynologyPhotoAlbumContext? = null): SynologyPhoto =
            SynologyPhoto(SynologyPhotoId("profile-a", space, id), "synthetic-$id.jpg", 4, 1000.5, 900.0, 9, "photo",
                rating = 0, description = "", tags = emptyList(), albumContext = album).also { values[it.id] = it }
        suspend fun ready(): Fixture { repository.access(); calls.clear(); return this }
    }

    @Test fun `评分描述与日期只发送本次字段并回读真实值`() = runBlocking {
        for (edit in listOf(SynologyPhotoEdit.Rating(5), SynologyPhotoEdit.Description("测试\nText"), SynologyPhotoEdit.TakenAt(1234))) {
            val f = Fixture().ready(); val photo = f.add()
            val row = checkpoint(listOf(photo), edit)
            val states = mutableListOf<SynologyPhotoEditCheckpoint>()
            f.before = { if (it.method == "set") assertEquals(setOf(0), states.last().attempted) }
            val result = f.repository.performPhotoEdit(row) { states += it }
            assertEquals(SynologyPhotoEditPhase.COMPLETED, result.phase)
            assertEquals(setOf(0), result.completed)
            val sent = f.writes.single()
            assertEquals("SYNO.Foto.Browse.Item", sent.api); assertEquals(2, sent.version)
            assertEquals(2, sent.fields.size); assertEquals("[91]", sent.fields["id"])
            assertEquals(5, f.calls.last().version)
        }
    }

    @Test fun `混合来源评分按来源分组且同编号不串号`() = runBlocking {
        val f = Fixture().ready()
        val photos = listOf(f.add(), f.add(SynologyPhotoSpace.SHARED))
        val result = f.repository.performPhotoEdit(checkpoint(photos, SynologyPhotoEdit.Rating(3))) {}
        assertEquals(SynologyPhotoEditPhase.COMPLETED, result.phase)
        assertEquals(listOf("SYNO.Foto.Browse.Item", "SYNO.FotoTeam.Browse.Item"), f.writes.map { it.api })
        assertEquals(setOf(0, 1), result.completed)
    }

    @Test fun `混合描述标签与非管理混合评分在写前拒绝`() = runBlocking {
        for (edit in listOf(SynologyPhotoEdit.Description("value"), SynologyPhotoEdit.AddTags(listOf(51)), SynologyPhotoEdit.Rating(3))) {
            val f = Fixture().apply { shared = "entry" }.ready()
            failure { f.repository.performPhotoEdit(checkpoint(listOf(f.add(), f.add(SynologyPhotoSpace.SHARED)), edit)) {} }
            assertTrue(f.writes.isEmpty())
        }
    }

    @Test fun `共享上传权限不能编辑资料但manage目录允许`() = runBlocking {
        val f = Fixture().apply { shared = "entry"; manage = false }.ready()
        val row = checkpoint(listOf(f.add(SynologyPhotoSpace.SHARED)), SynologyPhotoEdit.Rating(2))
        failure { f.repository.performPhotoEdit(row) {} }; assertTrue(f.writes.isEmpty())
        f.manage = true
        assertTrue(f.repository.performPhotoEdit(row) {}.finished)
    }

    @Test fun `批量全量预检发现第二项变更时第一项也不写`() = runBlocking {
        val f = Fixture().ready(); val photos = listOf(f.add(), f.add(id = 92))
        f.values[photos[1].id] = photos[1].copy(filename = "changed.jpg")
        failure { f.repository.performPhotoEdit(checkpoint(photos, SynologyPhotoEdit.Rating(2))) {} }
        assertTrue(f.writes.isEmpty())
    }

    @Test fun `相册实际提供者可编辑且写参数无相册或口令`() = runBlocking {
        val f = Fixture().apply { albumOwner = 42 }.ready()
        val photo = f.add(album = SynologyPhotoAlbumContext(71, 42, 99))
        val result = f.repository.performPhotoEdit(checkpoint(listOf(photo), SynologyPhotoEdit.Rating(4))) {}
        assertTrue(result.finished)
        assertEquals(setOf("id", "rating"), f.writes.single().fields.keys)
        assertEquals("71", f.calls.first { it.method == "get" && it.api.endsWith("Browse.Item") }.fields["album_id"])
    }

    @Test fun `相册下载者无原来源与共享非管理不能编辑`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture().apply { when (mode) { 0 -> provider = 42; 1 -> home = false; 2 -> shared = "entry" } }.ready()
            val photo = f.add(if (mode == 2) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL,
                album = SynologyPhotoAlbumContext(71, if (mode == 2) 0 else 41, 41))
            failure { f.repository.performPhotoEdit(checkpoint(listOf(photo), SynologyPhotoEdit.Rating(2))) {} }
            assertTrue(f.writes.isEmpty())
        }
    }

    @Test fun `条件和冻结相册所有者保留原件编辑路径`() = runBlocking {
        for (condition in listOf(true, false)) {
            val f = Fixture().apply { provider = 42; albumType = if (condition) "condition" else "normal"; frozen = !condition }.ready()
            val photo = f.add(album = SynologyPhotoAlbumContext(71, 41))
            assertTrue(f.repository.performPhotoEdit(checkpoint(listOf(photo), SynologyPhotoEdit.Description("changed"))) {}.finished)
        }
    }

    @Test fun `相对时间固定原始目标且断网后的执行和恢复都不重放`() = runBlocking {
        val f = Fixture().ready(); val photos = listOf(f.add(), f.add(id = 92))
        f.after = { if (it.method == "set") throw IOException("synthetic connection loss") }
        var saved: SynologyPhotoEditCheckpoint? = null
        val row = checkpoint(photos, SynologyPhotoEdit.ShiftDates(60))
        val result = f.repository.performPhotoEdit(row) { saved = it }
        assertEquals(SynologyPhotoEditPhase.PARTIAL, result.phase)
        assertEquals(setOf(0), result.completed)
        assertEquals("1060", f.writes.single().fields["time"])
        f.repository.performPhotoEdit(row) {}; f.repository.reviewPhotoEdit(saved!!) {}
        assertEquals(1, f.writes.size)
        assertEquals(1000.5, f.values.getValue(photos[1].id).takenAt, 0.0)
    }

    @Test fun `未知写入保持pending并禁止换操作编号覆盖`() = runBlocking {
        val f = Fixture().apply { apply = false }.ready(); val photo = f.add()
        f.before = { if (it.method == "set") throw IOException("synthetic connection loss") }
        val row = checkpoint(listOf(photo), SynologyPhotoEdit.Rating(4))
        assertEquals(SynologyPhotoEditPhase.PENDING, f.repository.performPhotoEdit(row) {}.phase)
        f.repository.performPhotoEdit(row) {}
        failure { f.repository.performPhotoEdit(row.copy(operationId = UUID.randomUUID().toString())) {} }
        assertEquals(1, f.writes.size)
    }

    @Test fun `error_list不猜单项编号而以全部回读产生部分结果`() = runBlocking {
        val f = Fixture().apply { apply = false; receipt = """{"error_list":[{"error":105}]}""" }.ready()
        val photos = listOf(f.add(), f.add(id = 92))
        f.after = { if (it.method == "set") f.values[photos[0].id] = photos[0].copy(rating = 3) }
        val result = f.repository.performPhotoEdit(checkpoint(photos, SynologyPhotoEdit.Rating(3))) {}
        assertEquals(SynologyPhotoEditPhase.PARTIAL, result.phase)
        assertEquals(setOf(0), result.completed); assertEquals(setOf(0, 1), result.reportedFailures)
    }

    @Test fun `畸形回执后不猜失败而保留未知状态`() = runBlocking {
        val f = Fixture().apply { apply = false; receipt = """{"error_list":[1,2]}""" }.ready()
        val result = f.repository.performPhotoEdit(checkpoint(listOf(f.add()), SynologyPhotoEdit.Rating(2))) {}
        assertEquals(SynologyPhotoEditPhase.PENDING, result.phase); assertTrue(result.reportedFailures.isEmpty())
    }

    @Test fun `缺失标签与空标签不同且删除标签仅删除关联`() = runBlocking {
        val f = Fixture().ready(); val photo = f.add()
        f.omitTags = true
        val row = checkpoint(listOf(photo), SynologyPhotoEdit.RemoveTags(listOf(51)))
        val result = f.repository.performPhotoEdit(row) {}
        assertEquals(SynologyPhotoEditPhase.PENDING, result.phase)
        assertEquals("remove_tag", f.writes.single().method); assertEquals("[51]", f.writes.single().fields["tag"])
        f.omitTags = false
        assertEquals(SynologyPhotoEditPhase.COMPLETED, f.repository.reviewPhotoEdit(result) {}.phase)
        assertEquals(1, f.writes.size)
    }

    @Test fun `新建标签回执先保存再应用且能独立创建`() = runBlocking {
        for (withPhoto in listOf(true, false)) {
            val f = Fixture().ready(); var saved: SynologyPhotoEditCheckpoint? = null
            val row = checkpoint(if (withPhoto) listOf(f.add()) else emptyList(), SynologyPhotoEdit.CreateTag("New tag"))
            f.before = { if (it.method == "add_tag") { assertEquals(52L, saved!!.createdTag!!.id); assertEquals(setOf(0), saved!!.attempted) } }
            val result = f.repository.performPhotoEdit(row) { saved = it }
            assertEquals(SynologyPhotoEditPhase.COMPLETED, result.phase)
            assertEquals(52L, result.createdTag!!.id); assertEquals(if (withPhoto) 2 else 1, f.writes.size)
        }
    }

    @Test fun `创建标签丢失回执不按同名认领或重建`() = runBlocking {
        val f = Fixture().ready()
        f.after = { if (it.method == "create") throw IOException("synthetic") }
        val row = checkpoint(listOf(f.add()), SynologyPhotoEdit.CreateTag("New tag"))
        val result = f.repository.performPhotoEdit(row) {}
        assertNull(result.createdTag); assertEquals(SynologyPhotoEditPhase.PENDING, result.phase)
        f.repository.reviewPhotoEdit(result) {}; f.repository.performPhotoEdit(row) {}
        assertEquals(1, f.writes.size); assertEquals(2, f.tagValues.size)
    }

    @Test fun `创建回执保存失败后不应用且恢复仅回读已知编号`() = runBlocking {
        val f = Fixture().ready(); var row: SynologyPhotoEditCheckpoint? = null
        try {
            f.repository.performPhotoEdit(checkpoint(listOf(f.add()), SynologyPhotoEdit.CreateTag("New tag"))) {
                row = it; if (it.createdTag != null) throw IOException("synthetic storage full")
            }; fail()
        } catch (_: IOException) { }
        val restored = f.repository.reviewPhotoEdit(row!!) {}
        assertEquals(SynologyPhotoEditPhase.PARTIAL, restored.phase); assertEquals(1, f.writes.size)
    }

    @Test fun `保存提交边界失败零写且重启后未知记录只读`() = runBlocking {
        val f = Fixture().ready(); val photo = f.add(); val row = checkpoint(listOf(photo), SynologyPhotoEdit.Rating(4))
        try { f.repository.performPhotoEdit(row) { throw IOException("synthetic storage full") }; fail() } catch (_: IOException) { }
        assertTrue(f.writes.isEmpty())
        val fresh = Fixture().ready(); fresh.values[photo.id] = photo
        assertEquals(SynologyPhotoEditPhase.PENDING, fresh.repository.performPhotoEdit(row.copy(
            phase = SynologyPhotoEditPhase.SUBMITTING, attempted = setOf(0))) {}.phase)
        assertTrue(fresh.writes.isEmpty())
    }

    @Test fun `授权代次改变与其他账号禁止继续写入或恢复`() = runBlocking {
        val f = Fixture().ready(); val row = checkpoint(listOf(f.add()), SynologyPhotoEdit.Rating(2))
        var changed = false
        f.after = { if (it.api.endsWith("Browse.Folder") && !changed) { changed = true; f.repository.access() } }
        try { f.repository.performPhotoEdit(row) {}; fail() } catch (_: CancellationException) { }
        assertTrue(f.writes.isEmpty())
        f.after = {}; f.user = 42; f.repository.access()
        failure { f.repository.reviewPhotoEdit(row.copy(phase = SynologyPhotoEditPhase.PENDING, attempted = setOf(0))) {} }
        assertTrue(f.writes.isEmpty())
    }

    @Test fun `非法日期重复目标和未来格式不触发请求`() = runBlocking {
        val f = Fixture().ready(); val p = f.add(); val row = checkpoint(listOf(p), SynologyPhotoEdit.Rating(2))
        for (bad in listOf(row.copy(version = 2), row.copy(targets = row.targets + row.targets),
            row.copy(edit = SynologyPhotoEdit.Rating(6)), row.copy(edit = SynologyPhotoEdit.ShiftDates(Long.MAX_VALUE)),
            row.copy(edit = SynologyPhotoEdit.ShiftDates(-1001)), row.copy(edit = SynologyPhotoEdit.TakenAt(-1)),
            row.copy(edit = SynologyPhotoEdit.AddTags(listOf(51, 51))))) {
            failure { f.repository.performPhotoEdit(bad) {} }
        }
        assertTrue(f.calls.isEmpty())
    }

    @Test fun `恢复快照只保存必要身份且操作身份不能替换`() = runBlocking {
        val f = Fixture().ready(); val photo = f.add().copy(latitude = 30.0, longitude = 120.0, camera = "Private camera")
        val row = checkpoint(listOf(photo), SynologyPhotoEdit.Rating(3))
        val encoded = Json.encodeToString(row)
        assertFalse(encoded.contains("latitude")); assertFalse(encoded.contains("camera")); assertFalse(encoded.contains("passphrase"))
        val result = f.repository.performPhotoEdit(row) {}
        failure { f.repository.performPhotoEdit(result.copy(edit = SynologyPhotoEdit.Rating(4))) {} }
        assertEquals(1, f.writes.size)
    }

    companion object {
        private fun checkpoint(photos: List<SynologyPhoto>, edit: SynologyPhotoEdit) = SynologyPhotoEditCheckpoint(
            profileId = "profile-a", userId = 41, space = photos.firstOrNull()?.id?.space ?: SynologyPhotoSpace.PERSONAL,
            targets = photos.map(::SynologyPhotoEditTarget), edit = edit)
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private suspend fun failure(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) { } }
        private fun capabilities(): Map<String, ApiCapability> = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            mapOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
                "Browse.Item" to 5, "Browse.Folder" to 2, "Browse.Album" to 4, "Browse.GeneralTag" to 1).map { (suffix, version) ->
                val name = "$prefix.$suffix"; name to ApiCapability(name, "entry.cgi", 1, version, "JSON")
            }
        }.toMap()
    }
}
