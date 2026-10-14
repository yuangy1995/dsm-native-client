package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 真实仓储通道与完整分页，全部内容为合成资料。 */
class SynologyPhotosTemporaryRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = fields[key]?.let(Json::parseToJsonElement)
        fun id(key: String) = value(key)!!.let { if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long }
    }
    private data class Album(var name: String = "Synthetic share", var temporary: Boolean? = true, var shared: Boolean = true,
        var owner: Long = 41, var type: String = "normal", var frozen: Boolean = false,
        var privacy: String = "private", var password: Boolean = false, var expiration: Long = 0,
        val members: MutableList<SynologyPhoto> = mutableListOf())
    private class Fixture {
        val albums = mutableMapOf(71L to Album())
        val photos = mutableMapOf<Long, SynologyPhoto>()
        val calls = mutableListOf<Call>()
        var user = 41L; var home = true; var manage = true; var provider = 41L
        var createId: Long? = 72L; var copyId: Long? = 73L; var initialTemporary: Boolean? = true
        var initialPrivacy = "private"; var applyClose = true; var applyDelete = true; var repeatedPage = false
        var createFailure = false; var copyFailure = false; var closeFailure = false; var deleteFailure = false
        var before: suspend (Call) -> Unit = {}; var after: suspend (Call) -> Unit = {}
        val writes get() = calls.filter { it.method in setOf("create", "copy", "set_shared", "delete", "update") }
        fun photo(id: Long = 91) = SynologyPhoto(SynologyPhotoId("temporary-profile", SynologyPhotoSpace.PERSONAL, id),
            "synthetic-$id.jpg", 4, 1000.0, 900.0, 9, "photo").also { photos[id] = it }
        fun repository() = SynologyPhotosRepository("temporary-profile", capabilities(), { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call; before(call)
            val result = when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$user,"uid":1041}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"management"}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
                cap.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":${fields["id"]},"additional":{"access_permission":{"view":true,"manage":$manage,"download":true}}}}""")
                cap.name.endsWith("Browse.Album") && method == "get" -> buildJsonObject {
                    put("list", buildJsonArray { albums[call.id("id")]?.let { add(encode(call.id("id"), it)) } })
                }
                cap.name.endsWith("Browse.Item") && method == "get" -> buildJsonObject {
                    put("list", JsonArray(listOf(encode(photos.getValue(call.id("id"))))))
                }
                cap.name.endsWith("Browse.Item") && method == "list" -> buildJsonObject {
                    val source = albums.getValue(call.id("album_id")).members
                    val offset = if (repeatedPage) 0 else fields.getValue("offset").toInt()
                    put("list", JsonArray(source.drop(offset).take(fields.getValue("limit").toInt()).map(::encode)))
                }
                method == "create" -> {
                    val created = Album(name = call.value("name")!!.jsonPrimitive.content, temporary = initialTemporary, privacy = initialPrivacy)
                    call.value("item")!!.jsonArray.forEach { created.members += photos.getValue(it.jsonPrimitive.long) }
                    albums[72] = created
                    if (createFailure) throw IOException("synthetic unknown creation")
                    buildJsonObject { put("album", buildJsonObject { createId?.let { put("id", it) } }) }
                }
                method == "copy" -> {
                    val source = albums.getValue(call.id("source_album_id"))
                    albums[73] = source.copy(temporary = false, shared = false, members = source.members.toMutableList())
                    if (copyFailure) throw IOException("synthetic unknown copy")
                    buildJsonObject { put("album", buildJsonObject { copyId?.let { put("id", it) } }) }
                }
                method == "set_shared" -> {
                    if (applyClose) albums.getValue(call.id("album_id")).shared = call.value("enabled")!!.jsonPrimitive.boolean
                    if (closeFailure) throw IOException("synthetic unknown closure")
                    obj("""{"passphrase":"synthetic-secret"}""")
                }
                method == "delete" -> {
                    assertTrue(cap.name.endsWith("Browse.Album"))
                    if (applyDelete) albums.remove(call.id("id"))
                    if (deleteFailure) throw IOException("synthetic unknown cleanup")
                    obj("{}")
                }
                else -> error("Unexpected synthetic operation ${cap.name}.$method")
            }
            after(call); result
        })
        private fun encode(id: Long, a: Album) = buildJsonObject {
            put("id", id); put("name", a.name); put("owner_user_id", a.owner); put("type", a.type)
            put("freeze_album", a.frozen); a.temporary?.let { put("temporary_shared", it) }; put("shared", a.shared)
            put("additional", buildJsonObject { put("sharing_info", buildJsonObject {
                put("privacy_type", a.privacy); put("passphrase", "synthetic-secret"); put("sharing_link", "https://example.invalid/synthetic")
                put("enable_password", a.password); put("expiration", a.expiration); put("permission", JsonArray(emptyList()))
            }) })
        }
        private fun encode(p: SynologyPhoto) = buildJsonObject {
            put("id", p.id.itemId); put("filename", p.filename); put("filesize", p.sizeBytes); put("time", p.takenAt)
            put("indexed_time", p.indexedAt); put("folder_id", p.folderId); put("type", p.mediaType)
            put("owner_user_id", p.albumContext?.ownerUserId ?: 41); put("additional", buildJsonObject { put("provider_user_id", provider) })
        }
        suspend fun ready() = repository().also { it.access(); calls.clear() }
        fun create(list: List<SynologyPhoto> = listOf(photo())) = SynologyPhotoAlbumCheckpoint(profileId = "temporary-profile", userId = 41,
            action = SynologyPhotoAlbumAction.CREATE_TEMPORARY, name = "Synthetic new", targets = list.map(::SynologyPhotoEditTarget))
        suspend fun stop(repo: SynologyPhotosRepository, keep: Boolean = false, preserved: Long? = null): SynologyPhotoAlbumCheckpoint {
            val actual = repo.temporaryAlbum(71)
            return SynologyPhotoAlbumCheckpoint(profileId = "temporary-profile", userId = 41, action = SynologyPhotoAlbumAction.STOP_TEMPORARY,
                album = actual.album, temporary = SynologyPhotoTemporaryChange(actual.snapshot, keep, preserved))
        }
    }

    @Test fun `新建真实临时标记并完整核对选片与实际初始范围`() = runBlocking {
        val f = Fixture(); f.initialPrivacy = "public-view"; val repo = f.ready()
        val row = f.create(listOf(f.photo(), f.photo(92))); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { if (it.method == "create") assertEquals(SynologyPhotoAlbumPhase.SUBMITTING, saved.last().phase) }
        val result = repo.performPhotoAlbum(row) { saved += it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertEquals(setOf(0, 1), result.completed)
        assertEquals(SynologyPhotoLinkAccess.VIEW, result.temporaryCreatedSnapshot!!.sharing.access)
        assertEquals(mapOf("name" to "\"Synthetic new\"", "item" to "[91,92]", "shared" to "true"), f.writes.single().fields)
        val encoded = Json.encodeToString(result)
        assertFalse(encoded.contains("example.invalid")); assertFalse(encoded.contains("synthetic-secret")); assertFalse(result.toString().contains("Synthetic new"))
    }
    @Test fun `创建缺编号与失去回执不搜索同名且热冷恢复不重放`() = runBlocking {
        for (lost in listOf(false, true)) {
            val f = Fixture(); f.createId = null; f.createFailure = lost; val repo = f.ready()
            val row = repo.performPhotoAlbum(f.create()) {}
            assertFalse(row.finished); assertNull(row.createdAlbumId); assertEquals(1, f.writes.size)
            repo.performPhotoAlbum(row) {}; f.ready().reviewPhotoAlbum(Json.decodeFromString(Json.encodeToString(row))) {}
            assertEquals(0, f.writes.size) // ready 清空调用后仅恢复读取。
            assertTrue(f.albums.containsKey(72)); assertFalse(f.calls.any { it.api.endsWith("Browse.Album") && it.method == "list" })
        }
    }
    @Test fun `返回普通或未知临时标记缺成员错误所有者均不得认定创建完成`() = runBlocking {
        for (case in 0..4) {
            val f = Fixture(); val repo = f.ready(); val row = f.create()
            f.after = { if (it.method == "create") when (case) {
                0 -> f.albums.getValue(72).temporary = false
                1 -> f.albums.getValue(72).temporary = null
                2 -> f.albums.getValue(72).members.clear()
                3 -> f.albums.getValue(72).owner = 99
                4 -> f.albums.getValue(72).members[0] = f.albums.getValue(72).members[0].copy(indexedAt = 901.0)
            } }
            assertFalse(repo.performPhotoAlbum(row) {}.finished); assertEquals(listOf("create"), f.writes.map { it.method })
        }
    }
    @Test fun `空选择缺源权限与来源提供者不符都在创建前拒绝`() = runBlocking {
        for (case in 0..3) {
            val f = Fixture(); val repo = f.ready()
            val photo = f.photo().let { if (case == 2) it.copy(albumContext = SynologyPhotoAlbumContext(80, 41, 41)) else it }
            if (case == 1) f.manage = false
            if (case == 2) f.provider = 52
            if (case == 3) { f.home = false; repo.access() }
            reject { repo.performPhotoAlbum(f.create(if (case == 0) emptyList() else listOf(photo))) {} }
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `停止先关闭再删临时容器且不调用照片删除`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.albums.getValue(71).members += f.photo()
        val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        f.before = { if (it.method == "delete") { assertTrue(saved.last().temporaryDeleteAttempted); assertNotNull(saved.last().temporaryClosedRevision); assertFalse(f.albums.getValue(71).shared) } }
        val done = repo.performPhotoAlbum(f.stop(repo)) { saved += it }
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertEquals(listOf("set_shared", "delete"), f.writes.map { it.method })
        assertEquals(setOf(91L), f.photos.keys); assertFalse(f.albums.containsKey(71))
    }
    @Test fun `保留副本要求不同编号完整五百条以上成员且不保留临时共享标志`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); repeat(501) { f.albums.getValue(71).members += f.photo(1000L + it) }
        val done = repo.performPhotoAlbum(f.stop(repo, true)) {}
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertEquals(73L, done.createdAlbumId)
        assertEquals(listOf("copy", "set_shared", "delete"), f.writes.map { it.method }); assertEquals(501, f.albums.getValue(73).members.size)
        assertFalse(f.albums.getValue(73).shared); assertEquals(false, f.albums.getValue(73).temporary)
        assertTrue(f.calls.any { it.method == "list" && it.fields["offset"] == "500" && it.fields["album_id"] == "73" })
        assertEquals(mapOf("name" to "\"Synthetic share\"", "source_album_id" to "71"), f.writes.first().fields)
    }
    @Test fun `副本缺编号重复编号临时公开所有者成员不符均不关闭或清理来源`() = runBlocking {
        for (case in 0..6) {
            val f = Fixture(); val repo = f.ready(); f.albums.getValue(71).members += f.photo()
            if (case == 0) f.copyId = null
            if (case == 1) f.copyId = 71
            f.after = { if (it.method == "copy") when (case) {
                2 -> f.albums.getValue(73).temporary = true
                3 -> f.albums.getValue(73).shared = true
                4 -> f.albums.getValue(73).owner = 42
                5 -> f.albums.getValue(73).members.clear()
                6 -> f.albums.getValue(73).members[0] = f.albums.getValue(73).members[0].copy(filename = "changed.jpg")
            } }
            val result = repo.performPhotoAlbum(f.stop(repo, true)) {}
            assertFalse(result.finished); assertEquals(listOf("copy"), f.writes.map { it.method }); assertTrue(f.albums.getValue(71).shared)
        }
    }
    @Test fun `复制回执未知即使存在同名副本也不关闭来源`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.copyFailure = true
        val result = repo.performPhotoAlbum(f.stop(repo, true)) {}
        assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase); assertTrue(f.albums.getValue(71).shared)
        assertTrue(f.albums.containsKey(73)); repo.reviewPhotoAlbum(result) {}; assertEquals(listOf("copy"), f.writes.map { it.method })
    }
    @Test fun `来源在复制期间改变保留双方且停止入口可重新确认原副本`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.albums.getValue(71).members += f.photo()
        f.after = { if (it.method == "copy") f.albums.getValue(71).expiration = 2000 }
        val partial = repo.performPhotoAlbum(f.stop(repo, true)) {}
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, partial.phase); assertEquals(73L, partial.createdAlbumId)
        assertEquals(listOf("copy"), f.writes.map { it.method })
        val next = f.stop(repo, true, 73); val done = repo.performPhotoAlbum(next) {}
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertEquals(listOf("copy", "set_shared", "delete"), f.writes.map { it.method })
    }
    @Test fun `停止回执未知只读观察关闭即部分完成不自动删除`() = runBlocking {
        for (closed in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); f.closeFailure = true; f.applyClose = closed
            val result = repo.performPhotoAlbum(f.stop(repo)) {}
            assertEquals(if (closed) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.PENDING, result.phase)
            val again = f.ready(); again.reviewPhotoAlbum(result) {}; again.performPhotoAlbum(result) {}
            assertTrue(f.writes.isEmpty()); assertTrue(f.albums.containsKey(71))
        }
    }
    @Test fun `停止未生效不能删除且删除回执丢失依据原编号不存在确认`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); f.applyClose = false
        assertEquals(SynologyPhotoAlbumPhase.PENDING, repo.performPhotoAlbum(f.stop(repo)) {}.phase)
        assertEquals(listOf("set_shared"), f.writes.map { it.method })
        for (removed in listOf(false, true)) {
            val g = Fixture(); val r = g.ready(); g.deleteFailure = true; g.applyDelete = removed
            val row = r.performPhotoAlbum(g.stop(r)) {}
            assertEquals(if (removed) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING, row.phase)
            r.performPhotoAlbum(row) {}; assertEquals(2, g.writes.size)
        }
    }
    @Test fun `普通冻结他人临时相册不可进入清理而临时分享设置可用`() = runBlocking {
        for (case in 0..3) {
            val f = Fixture(); val repo = f.ready()
            when (case) { 0 -> f.albums.getValue(71).temporary = false; 1 -> f.albums.getValue(71).frozen = true
                2 -> f.albums.getValue(71).owner = 99; 3 -> f.albums.getValue(71).type = "condition" }
            reject { repo.temporaryAlbum(71) }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val repo = f.ready(); val actual = repo.albumSharing(71)
        assertTrue(actual.album.temporaryShare)
        val row = SynologyPhotoAlbumCheckpoint(profileId = "temporary-profile", userId = 41, action = SynologyPhotoAlbumAction.SHARE,
            album = actual.album, sharing = SynologyPhotoSharingChange(actual.snapshot, SynologyPhotoLinkAccess.DISABLED))
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, repo.performPhotoAlbum(row) {}.phase)
        assertTrue(f.albums.containsKey(71)); assertEquals(listOf("set_shared"), f.writes.map { it.method })
    }
    @Test fun `副本与来源在关闭后变化不清理旧容器`() = runBlocking {
        for (copyChanged in listOf(false, true)) {
            val f = Fixture(); val repo = f.ready(); f.albums.getValue(71).members += f.photo()
            f.after = { if (it.method == "set_shared") f.albums.getValue(if (copyChanged) 73 else 71).members.clear() }
            val result = repo.performPhotoAlbum(f.stop(repo, true)) {}
            assertNotEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
            assertEquals(listOf("copy", "set_shared"), f.writes.map { it.method }); assertTrue(f.albums.containsKey(71))
        }
    }
    @Test fun `完整成员分页重复和身份刷新失败均在写前拒绝`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); repeat(500) { f.albums.getValue(71).members += f.photo(1000L + it) }
        f.repeatedPage = true; reject { f.stop(repo) }; assertTrue(f.writes.isEmpty())
        f.repeatedPage = false; val row = f.stop(repo); f.user = 42; repo.access()
        reject { repo.performPhotoAlbum(row) {} }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `落盘失败不继续停止或删除且冷恢复不补写`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val initial = f.stop(repo, true)
        var saved = initial
        try { repo.performPhotoAlbum(initial) { if (it.createdAlbumId != null) throw IOException("synthetic disk full"); saved = it } }
        catch (_: IOException) {}
        assertEquals(listOf("copy"), f.writes.map { it.method }); assertTrue(f.albums.getValue(71).shared)
        f.ready().reviewPhotoAlbum(saved.copy(phase = SynologyPhotoAlbumPhase.PENDING)) {}
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `记录校验拒绝未确认副本的删除阶段和非法用途`() = runBlocking {
        val f = Fixture(); val repo = f.ready(); val row = f.stop(repo, true)
        for (bad in listOf(row.copy(temporaryDeleteAttempted = true), row.copy(temporaryClosedRevision = "bad"),
            row.copy(action = SynologyPhotoAlbumAction.DELETE), row.copy(temporary = row.temporary!!.copy(preservedCopyId = 71)),
            row.copy(temporaryCancelRequested = true), row.copy(createdAlbumId = 73))) reject { repo.performPhotoAlbum(bad) {} }
        assertTrue(f.writes.isEmpty())
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoFailure) {} }
        private fun capabilities() = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            mapOf("UserInfo" to 1, "Setting.User" to 1, "Setting.Admin" to 1, "Setting.TeamSpace" to 1,
                "Browse.Item" to 5, "Browse.Folder" to 2, "Browse.Album" to 4, "Browse.NormalAlbum" to 1, "Sharing.Passphrase" to 1).map { (suffix, version) ->
                val name = "$prefix.$suffix"; name to ApiCapability(name, "entry.cgi", 1, version, "JSON")
            }
        }.toMap()
    }
}
