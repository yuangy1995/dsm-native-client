package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 全部为合成资料；实际仓储与参数经过执行，不表示 NAS 已验收。 */
class SynologyPhotosAlbumRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, String>, val version: Int)
    private class Fixture {
        var home = true; var shared = "management"; var user = 41L
        var manage = true; var download = true; var view = true; var contribute = true
        var albumOwner = 41L; var provider = 41L; var frozen = false; var type = "normal"
        var albumName = "Synthetic album"; var albumExists = true; var cover: Long? = null
        var apply = true; var receipt = "{}"; var listFailed = false; var repeatedPage = false
        var createId: Long? = 72
        val values = mutableMapOf<SynologyPhotoId, SynologyPhoto>()
        val memberIds = mutableSetOf<SynologyPhotoId>()
        val calls = mutableListOf<Call>()
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val writes get() = calls.filter { it.method in setOf("create", "set_name", "delete", "add_item", "delete_item", "set_cover") }
        val repository = SynologyPhotosRepository("profile-a", capabilities(), { cap, method, fields ->
            val call = Call(cap.name, method, fields, cap.maxVersion); calls += call; before(call)
            fun id(key: String) = Json.parseToJsonElement(fields.getValue(key)).let { if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long }
            fun text(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonPrimitive.content
            val space = if (cap.name.startsWith("SYNO.FotoTeam")) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$user}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"$shared"}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
                cap.name.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"upload":$contribute,"download":$download}}""")
                cap.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":${fields["id"]},"additional":{"access_permission":{"view":$view,"manage":$manage,"download":$download,"upload":true}}}}""")
                cap.name.endsWith("Browse.Album") && method == "get" -> {
                    if (listFailed) throw IOException("synthetic read failure")
                    buildJsonObject { put("list", buildJsonArray { if (albumExists) add(album(id("id"))) }) }
                }
                cap.name.endsWith("Browse.Album") -> {
                    if (apply) when (method) {
                        "set_name" -> albumName = text("name")
                        "delete" -> albumExists = false
                        "set_cover" -> cover = id("id_item")
                        else -> error("Unexpected album write")
                    }
                    obj(receipt)
                }
                cap.name.endsWith("Browse.NormalAlbum") -> {
                    val ids = Json.parseToJsonElement(fields.getValue("item")).jsonArray.map { it.jsonPrimitive.long }
                    if (apply) when (method) {
                        "create" -> { albumExists = true; albumName = text("name"); memberIds.clear(); memberIds += values.keys.filter { it.itemId in ids } }
                        "add_item" -> memberIds += values.keys.filter { it.itemId in ids }
                        "delete_item" -> memberIds.removeAll { it.itemId in ids }
                        else -> error("Unexpected membership write")
                    }
                    if (method == "create") buildJsonObject { put("album", buildJsonObject { createId?.let { put("id", it) } }) } else obj(receipt)
                }
                cap.name.endsWith("Browse.Item") && method == "get" -> {
                    val value = if (fields["album_id"] != null) values.values.single { it.id.itemId == id("id") }
                        else values.getValue(SynologyPhotoId("profile-a", space, id("id")))
                    buildJsonObject { put("list", buildJsonArray { add(encode(value)) }) }
                }
                cap.name.endsWith("Browse.Item") && method == "list" -> {
                    if (listFailed) throw IOException("synthetic list failure")
                    val offset = if (repeatedPage) 0 else fields.getValue("offset").toInt()
                    val list = memberIds.toList().drop(offset).take(fields.getValue("limit").toInt()).map { values.getValue(it) }
                    buildJsonObject { put("list", buildJsonArray { list.forEach { add(encode(it)) } }) }
                }
                else -> error("Unexpected synthetic request")
            }
            after(call); result
        })
        private fun album(id: Long) = buildJsonObject {
            put("id", id); put("name", albumName); put("type", type); put("owner_user_id", albumOwner)
            put("freeze_album", frozen); put("temporary_shared", false); put("passphrase", "synthetic-token")
            put("additional", buildJsonObject { cover?.let { put("thumbnail", buildJsonObject { put("unit_id", it); put("cache_key", "synthetic-revision") }) } })
        }
        private fun encode(p: SynologyPhoto) = buildJsonObject {
            put("id", p.id.itemId); put("filename", p.filename); put("filesize", p.sizeBytes); put("time", p.takenAt)
            put("indexed_time", p.indexedAt); put("folder_id", p.folderId); put("type", p.mediaType)
            put("owner_user_id", p.albumContext?.ownerUserId ?: if (p.id.space == SynologyPhotoSpace.SHARED) 0L else user)
            put("additional", buildJsonObject { put("provider_user_id", provider) })
        }
        fun add(id: Long = 91, space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL, context: SynologyPhotoAlbumContext? = null): SynologyPhoto =
            SynologyPhoto(SynologyPhotoId("profile-a", space, id), "synthetic-$id.jpg", 4, 1000.0, 900.0, 9, "photo", albumContext = context).also { values[it.id] = it }
        suspend fun row(action: SynologyPhotoAlbumAction, photos: List<SynologyPhoto> = emptyList(), name: String? = null) =
            SynologyPhotoAlbumCheckpoint(profileId = "profile-a", userId = user, action = action, name = name,
                album = if (action == SynologyPhotoAlbumAction.CREATE) null else repository.albumAccess(71).album, targets = photos.map(::SynologyPhotoEditTarget))
        suspend fun ready(): Fixture { repository.access(); calls.clear(); return this }
    }

    @Test fun `空相册和选择照片创建均固定返回编号并完整核对成员`() = runBlocking {
        for (empty in listOf(true, false)) {
            val f = Fixture().ready(); val photos = if (empty) emptyList() else listOf(f.add())
            val row = f.row(SynologyPhotoAlbumAction.CREATE, photos, "New 相册")
            val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
            f.before = { if (it.method == "create") assertEquals(SynologyPhotoAlbumPhase.SUBMITTING, saved.last().phase) }
            val result = f.repository.performPhotoAlbum(row) { saved += it }
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertEquals(72L, result.createdAlbumId)
            assertEquals(setOf("name", "item"), f.writes.single().fields.keys)
            assertEquals("SYNO.Foto.Browse.NormalAlbum", f.writes.single().api)
            assertTrue(f.calls.any { it.method == "list" && it.fields["album_id"] == "72" })
            assertTrue(saved.any { it.createdAlbumId == 72L && !it.finished })
        }
    }
    @Test fun `没有原空间时空创建改名和删除仍可用且删除不动原件`() = runBlocking {
        for (action in listOf(SynologyPhotoAlbumAction.CREATE, SynologyPhotoAlbumAction.RENAME, SynologyPhotoAlbumAction.DELETE)) {
            val f = Fixture().apply { home = false; shared = "none" }.ready(); f.add()
            val row = f.row(action, name = if (action != SynologyPhotoAlbumAction.DELETE) "Changed" else null)
            assertTrue(f.repository.performPhotoAlbum(row) {}.finished)
            assertEquals(1, f.values.size)
            assertFalse(f.calls.any { it.api.contains("BackgroundTask") || it.api.endsWith("Browse.Folder") })
        }
    }
    @Test fun `所有者加入与移出仅改变关系使用id和item`() = runBlocking {
        val f = Fixture().ready(); val photo = f.add(context = SynologyPhotoAlbumContext(71, 41, 41))
        for (action in listOf(SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE)) {
            assertTrue(f.repository.performPhotoAlbum(f.row(action, listOf(photo))) {}.finished)
            assertEquals(setOf("id", "item"), f.writes.last().fields.keys)
            assertEquals("[91]", f.writes.last().fields["item"])
        }
        assertTrue(f.memberIds.isEmpty()); assertEquals(1, f.values.size)
    }
    @Test fun `贡献者实际权限和提供者决定移出而非原件所有者`() = runBlocking {
        val f = Fixture().apply { albumOwner = 42; home = false; shared = "none" }.ready()
        val photo = f.add(context = SynologyPhotoAlbumContext(71, 42, 99)); f.memberIds += photo.id
        val row = f.row(SynologyPhotoAlbumAction.REMOVE, listOf(photo))
        assertTrue(f.repository.performPhotoAlbum(row) {}.finished)
        assertEquals(setOf("passphrase", "item"), f.writes.single().fields.keys)
        assertEquals("\"synthetic-token\"", f.writes.single().fields["passphrase"])
        assertFalse(Json.encodeToString(row).contains("synthetic-token"))
        assertFalse(f.calls.any { it.api.endsWith("Browse.Folder") })
    }
    @Test fun `只读者和其他提供者不能移出且非所有者不能改名删除封面`() = runBlocking {
        for (action in listOf(SynologyPhotoAlbumAction.REMOVE, SynologyPhotoAlbumAction.RENAME, SynologyPhotoAlbumAction.DELETE, SynologyPhotoAlbumAction.COVER)) {
            val f = Fixture().apply { albumOwner = 42; provider = 42 }.ready()
            val photo = f.add(context = SynologyPhotoAlbumContext(71, 42, 41)); f.memberIds += photo.id
            val row = f.row(action, if (action in listOf(SynologyPhotoAlbumAction.REMOVE, SynologyPhotoAlbumAction.COVER)) listOf(photo) else emptyList(),
                if (action == SynologyPhotoAlbumAction.RENAME) "New" else null)
            failure { f.repository.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture().apply { albumOwner = 42; contribute = false }.ready()
        failure { f.repository.performPhotoAlbum(f.row(SynologyPhotoAlbumAction.ADD, listOf(f.add()))) {} }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `相册间添加使用源album读取和实际provider且不删源相册`() = runBlocking {
        val f = Fixture().apply { albumOwner = 42 }.ready()
        val photo = f.add(context = SynologyPhotoAlbumContext(73, 42, 99))
        val result = f.repository.performPhotoAlbum(f.row(SynologyPhotoAlbumAction.ADD, listOf(photo))) {}
        assertTrue(result.finished)
        assertTrue(f.calls.any { it.method == "get" && it.fields["album_id"] == "73" })
        assertEquals("add_item", f.writes.single().method)
        assertFalse(f.writes.single().fields.containsKey("source_album_id"))
    }
    @Test fun `原空间关闭或提供者不符时禁止相册间添加`() = runBlocking {
        for (closed in listOf(true, false)) {
            val f = Fixture().apply { home = !closed; provider = if (closed) 41 else 42 }.ready()
            val row = f.row(SynologyPhotoAlbumAction.CREATE, listOf(f.add(context = SynologyPhotoAlbumContext(73, 42, 41))), "New")
            failure { f.repository.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `共享源允许view加download但upload不能代替读取且全部预检才写`() = runBlocking {
        val f = Fixture().apply { shared = "entry"; manage = false }.ready()
        val first = f.add(); val second = f.add(92, SynologyPhotoSpace.SHARED)
        val row = f.row(SynologyPhotoAlbumAction.CREATE, listOf(first, second), "Mixed")
        f.download = false
        failure { f.repository.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        f.download = true; f.manage = true
        assertTrue(f.repository.performPhotoAlbum(row) {}.finished)
        assertEquals("[91,92]", f.writes.single().fields["item"])
        assertEquals("SYNO.Foto.Browse.NormalAlbum", f.writes.single().api)
    }
    @Test fun `混合来源同裸编号与混合贡献非管理权在写前拒绝`() = runBlocking {
        val f = Fixture().ready()
        failure { f.repository.performPhotoAlbum(f.row(SynologyPhotoAlbumAction.CREATE, listOf(f.add(), f.add(space = SynologyPhotoSpace.SHARED)), "New")) {} }
        assertTrue(f.writes.isEmpty())
        val other = Fixture().apply { shared = "entry" }.ready()
        val photos = listOf(other.add(context = SynologyPhotoAlbumContext(73, 41)), other.add(92, SynologyPhotoSpace.SHARED, SynologyPhotoAlbumContext(73, 0)))
        failure { other.repository.performPhotoAlbum(other.row(SynologyPhotoAlbumAction.CREATE, photos, "New")) {} }
        assertTrue(other.writes.isEmpty())
    }
    @Test fun `封面必须是实际成员且回读封面编号和原件身份`() = runBlocking {
        val f = Fixture().ready(); val photo = f.add(context = SynologyPhotoAlbumContext(71, 41))
        val row = f.row(SynologyPhotoAlbumAction.COVER, listOf(photo))
        failure { f.repository.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        f.memberIds += photo.id
        assertTrue(f.repository.performPhotoAlbum(row) {}.finished)
        assertEquals(mapOf("id" to "71", "id_item" to "91"), f.writes.single().fields)
        assertEquals(91L, f.repository.albumAccess(71).thumbnail?.unitId)
    }
    @Test fun `条件及冻结相册封面仍按成员身份保存且不改自动归集规则`() = runBlocking {
        for (isFrozen in listOf(false, true)) {
            val f = Fixture().apply { type = "condition"; frozen = isFrozen }.ready()
            val photo = f.add(context = SynologyPhotoAlbumContext(71, 41)); f.memberIds += photo.id
            assertTrue(f.repository.albumAccess(71).canManage); assertFalse(f.repository.albumAccess(71).canContribute)
            assertTrue(f.repository.performPhotoAlbum(f.row(SynologyPhotoAlbumAction.COVER, listOf(photo))) {}.finished)
            assertEquals("set_cover", f.writes.single().method); assertEquals(setOf(photo.id), f.memberIds)
            assertEquals(91L, f.repository.albumAccess(71).thumbnail?.unitId)
        }
    }
    @Test fun `冻结普通或条件相册不能通过成员操作手动增删照片`() = runBlocking {
        for (type in listOf("normal", "condition")) for (action in listOf(SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE)) {
            val f = Fixture().apply { this.type = type; frozen = true }.ready()
            val photo = f.add(context = SynologyPhotoAlbumContext(71, 41)); f.memberIds += photo.id
            failure { f.repository.performPhotoAlbum(f.row(action, listOf(photo))) {} }
            assertTrue(f.writes.isEmpty()); assertEquals(setOf(photo.id), f.memberIds)
        }
    }
    @Test fun `名称角色冻结或相册类型改变时旧快照拒绝写入`() = runBlocking {
        for (mode in 0..3) {
            val f = Fixture().ready(); val row = f.row(SynologyPhotoAlbumAction.RENAME, name = "New")
            when (mode) { 0 -> f.albumName = "Other"; 1 -> f.albumOwner = 42; 2 -> f.frozen = true; 3 -> f.type = "condition" }
            failure { f.repository.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `创建丢失编号不按同名认领也不重新提交`() = runBlocking {
        val f = Fixture().apply { createId = null }.ready()
        val row = f.row(SynologyPhotoAlbumAction.CREATE, name = "Same")
        val saved = f.repository.performPhotoAlbum(row) {}
        assertEquals(SynologyPhotoAlbumPhase.PENDING, saved.phase); assertNull(saved.createdAlbumId)
        f.repository.reviewPhotoAlbum(saved) {}; f.repository.performPhotoAlbum(row) {}
        failure { f.repository.performPhotoAlbum(row.copy(operationId = UUID.randomUUID().toString())) {} }
        assertEquals(1, f.writes.size)
    }
    @Test fun `部分回执错误不猜编号按实际成员得出完成子集`() = runBlocking {
        val f = Fixture().apply { apply = false; receipt = """{"error_list":[{"opaque":true}]}""" }.ready()
        val photos = listOf(f.add(), f.add(92)); f.after = { if (it.method == "add_item") f.memberIds += photos[0].id }
        val result = f.repository.performPhotoAlbum(f.row(SynologyPhotoAlbumAction.ADD, photos)) {}
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertEquals(setOf(0), result.completed)
        f.repository.reviewPhotoAlbum(result) {}; assertEquals(1, f.writes.size)
    }
    @Test fun `未知畸形回执和读取失败保留pending且不会误报删除成功`() = runBlocking {
        for (deletion in listOf(true, false)) {
            val f = Fixture().apply { apply = false; receipt = """{"error_list":{}}""" }.ready()
            val row = if (deletion) f.row(SynologyPhotoAlbumAction.DELETE) else f.row(SynologyPhotoAlbumAction.ADD, listOf(f.add()))
            f.after = { if (it.method == "delete") f.listFailed = true }
            val result = f.repository.performPhotoAlbum(row) {}
            assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
            try { f.repository.reviewPhotoAlbum(result) {} } catch (_: IOException) { }
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `原件变更身份撤销和写前保存失败都不发送请求`() = runBlocking {
        val f = Fixture().ready(); val photo = f.add()
        val row = f.row(SynologyPhotoAlbumAction.CREATE, listOf(photo), "New")
        f.values[photo.id] = photo.copy(filename = "changed.jpg")
        failure { f.repository.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
        f.values[photo.id] = photo
        try { f.repository.performPhotoAlbum(row) { throw IOException("synthetic storage failure") }; fail() } catch (_: IOException) { }
        assertTrue(f.writes.isEmpty())
        f.repository.performPhotoAlbum(row) {}; assertTrue(f.writes.isEmpty())
        val other = Fixture().ready(); val another = other.row(SynologyPhotoAlbumAction.CREATE, name = "New")
        other.user = 42; other.repository.access()
        failure { other.repository.performPhotoAlbum(another) {} }; assertTrue(other.writes.isEmpty())
    }
    @Test fun `完整分页核对移出并拒绝重复分页不是读取一次就认定缺失`() = runBlocking {
        val f = Fixture().ready()
        repeat(501) { f.memberIds += f.add(1000L + it, context = SynologyPhotoAlbumContext(71, 41)).id }
        val photo = f.values.values.last()
        val result = f.repository.performPhotoAlbum(f.row(SynologyPhotoAlbumAction.REMOVE, listOf(photo))) {}
        assertTrue(result.finished)
        assertEquals(listOf("0", "500"), f.calls.filter { it.method == "list" }.map { it.fields["offset"] })
        val other = Fixture().apply { apply = false; repeatedPage = true }.ready()
        repeat(500) { other.memberIds += other.add(1000L + it, context = SynologyPhotoAlbumContext(71, 41)).id }
        val pending = other.repository.performPhotoAlbum(other.row(SynologyPhotoAlbumAction.REMOVE, listOf(other.values.values.first()))) {}
        assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
    }
    @Test fun `旧操作恢复不重放且当前格式拒绝未来版本和非法状态`() = runBlocking {
        val f = Fixture().ready(); val row = f.row(SynologyPhotoAlbumAction.CREATE, name = "New")
        for (bad in listOf(row.copy(version = 2), row.copy(createdAlbumId = 72), row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED), row.copy(operationId = "invalid"))) {
            failure { f.repository.performPhotoAlbum(bad) {} }
        }
        val restored = Json.decodeFromString<SynologyPhotoAlbumCheckpoint>(Json.encodeToString(row.copy(phase = SynologyPhotoAlbumPhase.PENDING)))
        assertEquals(SynologyPhotoAlbumPhase.PENDING, f.repository.performPhotoAlbum(restored) {}.phase)
        assertTrue(f.writes.isEmpty())
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private suspend fun failure(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) { } }
        private fun capabilities() = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            mapOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
                "Browse.Item" to 5, "Browse.Folder" to 2, "Browse.Album" to 4, "Browse.NormalAlbum" to 1, "Sharing.Passphrase" to 1).map { (suffix, version) ->
                val name = "$prefix.$suffix"; name to ApiCapability(name, "entry.cgi", 1, version, "JSON")
            }
        }.toMap()
    }
}
