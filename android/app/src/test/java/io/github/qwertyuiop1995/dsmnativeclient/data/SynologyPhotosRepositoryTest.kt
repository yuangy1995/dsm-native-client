package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import java.time.LocalDate
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 合成响应复现已记录的 Photos 契约，不包含真实 NAS、账号或媒体。 */
class SynologyPhotosRepositoryTest {
    private data class Request(val capability: ApiCapability, val method: String, val fields: Map<String, String>)
    private class Fixture(enabled: Boolean = true, capabilities: Map<String, ApiCapability> = capabilities(), deletion: Boolean = false) {
        val requests = mutableListOf<Request>()
        var userEnabled = enabled
        var homeEnabled = true
        var reply: suspend (Request) -> JsonObject = { obj("""{"list":[]}""") }
        val repository = SynologyPhotosRepository("profile-a", capabilities, { capability, method, fields ->
            val request = Request(capability, method, fields)
            requests += request
            when (capability.name) {
                "SYNO.Foto.UserInfo" -> obj("""{"enabled":$userEnabled}""")
                "SYNO.Foto.Setting.User" -> obj("""{"enable_home_service":$homeEnabled,"team_space_permission":"unknown"}""")
                "SYNO.Foto.Setting.Admin" -> obj("""{"package_version":"fixture"}""")
                "SYNO.Foto.Setting.TeamSpace" -> obj("""{"enabled":true}""")
                else -> reply(request)
            }
        }, canDeleteOriginals = deletion)
        suspend fun ready(): SynologyPhotosRepository = repository.also { it.access(); requests.clear() }
    }

    @Test fun `访问授权只允许明确启用的个人空间且不猜测共享权限`() = runTest {
        val fixture = Fixture()
        assertEquals(listOf(SynologyPhotoSpace.PERSONAL), fixture.repository.access().spaces)
        assertEquals(listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace"),
            fixture.requests.map { it.capability.name.removePrefix("SYNO.Foto.") })
        fixture.homeEnabled = false
        assertTrue(fixture.repository.access().spaces.isEmpty())
        failure(SynologyPhotoFailureKind.PERMISSION) { fixture.repository.photos(SynologyPhotoSpace.PERSONAL, query, 0, 2) }
    }

    @Test fun `未启用套件和共享空间不能偷偷回退文件扫描`() = runTest {
        val fixture = Fixture(enabled = false)
        failure(SynologyPhotoFailureKind.PERMISSION) { fixture.repository.access() }
        assertEquals(1, fixture.requests.size)
        fixture.userEnabled = true
        val repository = fixture.ready()
        failure(SynologyPhotoFailureKind.PERMISSION) { repository.timeline(SynologyPhotoSpace.SHARED) }
        assertTrue(fixture.requests.isEmpty())
    }

    @Test fun `能力必须包含明确版本JSON格式及本机安全路径`() = runTest {
        val key = "SYNO.Foto.Browse.Item"
        val bad = listOf(
            capabilities().getValue(key).copy(minVersion = 5),
            capabilities().getValue(key).copy(maxVersion = 3),
            capabilities().getValue(key).copy(requestFormat = ""),
            capabilities().getValue(key).copy(name = "SYNO.FileStation.List"),
            capabilities().getValue(key).copy(path = "https://other.example.invalid/entry.cgi"),
            capabilities().getValue(key).copy(path = "../entry.cgi"),
            capabilities().getValue(key).copy(path = "entry.cgi?_sid=secret"),
        )
        for (capability in bad) {
            val fixture = Fixture(capabilities = capabilities() + (key to capability))
            val repository = fixture.ready()
            failure(SynologyPhotoFailureKind.UNAVAILABLE) { repository.photos(SynologyPhotoSpace.PERSONAL, query, 0, 2) }
            assertTrue(fixture.requests.isEmpty())
        }
    }

    @Test fun `原始分页游标不使用total且未知媒体不按扩展名过滤`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        fixture.reply = { obj("""{"total":99999,"list":[${item(11)},${item(12, type = "future-media") }]}""") }
        val page = repository.photos(SynologyPhotoSpace.PERSONAL, query, 20, 2)
        assertEquals(22, page.nextOffset)
        assertTrue(page.hasMore)
        assertEquals("future-media", page.items.last().mediaType)
        assertEquals(SynologyPhotoId("profile-a", SynologyPhotoSpace.PERSONAL, 11), page.items.first().id)
        assertEquals(91L, page.items.first().thumbnail?.unitId)
        val request = fixture.requests.single()
        assertEquals(4, request.capability.maxVersion)
        assertEquals("list", request.method)
        assertEquals("20", request.fields["offset"])
        assertEquals("2", request.fields["limit"])
        assertEquals("[\"thumbnail\",\"resolution\",\"orientation\",\"video_convert\",\"video_meta\",\"address\"]", request.fields["additional"])
        fixture.reply = { obj("""{"list":[]}""") }
        val last = repository.photos(SynologyPhotoSpace.PERSONAL, query, 22, 2)
        assertFalse(last.hasMore)
        assertEquals(22, last.nextOffset)
    }

    @Test fun `缺失列表重复身份错误类型和超过页长都不是空图库`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        val invalid = listOf("{}", """{"list":null}""", """{"list":[${item(1)},${item(1)}]}""",
            """{"list":[${item(1)},${item(2)},${item(3)}]}""", """{"list":[${item(0)}]}""",
            """{"list":[${item(1).replace("\"filesize\":4", "\"filesize\":-1")}]}""")
        for (json in invalid) {
            fixture.reply = { obj(json) }
            failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.photos(SynologyPhotoSpace.PERSONAL, query, 0, 2) }
        }
        for ((offset, limit) in listOf(-1 to 1, 0 to 0, 0 to 501, Int.MAX_VALUE to 2)) {
            failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.photos(SynologyPhotoSpace.PERSONAL, query, offset, limit) }
        }
    }

    @Test fun `按日聚合严格校验日期且搜索使用全库接口`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        fixture.reply = { obj("""{"section":[{"list":[{"year":2024,"month":2,"day":29,"item_count":12345}]}]}""") }
        assertEquals(listOf(SynologyPhotoDay(LocalDate.of(2024, 2, 29), 12345)), repository.timeline(SynologyPhotoSpace.PERSONAL))
        assertEquals("\"day\"", fixture.requests.single().fields["timeline_group_unit"])
        fixture.reply = { obj("""{"section":[{"list":[{"year":2025,"month":2,"day":29,"item_count":1}]}]}""") }
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.timeline(SynologyPhotoSpace.PERSONAL) }
        fixture.reply = { request -> if (request.method == "get_search_timeline") obj("""{"section":[]}""") else obj("""{"list":[]}""") }
        val search = SynologyPhotoQuery.Search("旅行 \"sun\"", 1, 999)
        repository.timeline(SynologyPhotoSpace.PERSONAL, search)
        repository.photos(SynologyPhotoSpace.PERSONAL, search, 100, 100)
        val calls = fixture.requests.takeLast(2)
        assertEquals(listOf(2, 1), calls.map { it.capability.maxVersion })
        assertTrue(calls.all { it.capability.name == "SYNO.Foto.Search.Search" })
        assertEquals(JsonPrimitive(search.keyword).toString(), calls.last().fields["keyword"])
        assertEquals("100", calls.last().fields["offset"])
    }

    @Test fun `十二类筛选编码使用数字身份与分数对象而非标签文案`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        val filter = SynologyPhotoFilter(1, 10, 20, 21, 22, 23, 4, 24, 25, 26, 27,
            SynologyPhotoFocalRange(0, 35), SynologyPhotoExposureRange(SynologyPhotoFraction(1, 1000), SynologyPhotoFraction(1, 10)))
        repository.photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Filtered(filter, 0, 999), 0, 100)
        val request = fixture.requests.single()
        assertEquals(2, request.capability.maxVersion)
        assertEquals("list_with_filter", request.method)
        val expected = mapOf("item_type" to "[1]", "person" to "[21]", "geocoding" to "[22]", "general_tag" to "[23]",
            "rating" to "[4]", "camera" to "[24]", "lens" to "[25]", "iso" to "[26]", "aperture" to "[27]",
            "person_policy" to "\"or\"", "general_tag_policy" to "\"or\"",
            "time" to "[{\"start_time\":10,\"end_time\":20}]",
            "focal_length_group" to "[{\"start\":0,\"end\":35}]",
            "exposure_time_group" to "[{\"start\":{\"num\":1,\"den\":1000},\"end\":{\"num\":1,\"den\":10}}]")
        expected.forEach { (key, value) -> assertEquals(key, value, request.fields[key]) }
        for (invalid in listOf(filter.copy(startTime = null), filter.copy(rating = 6), filter.copy(personId = 0), filter.copy(mediaType = 2))) {
            failure(SynologyPhotoFailureKind.INVALID_RESPONSE) {
                repository.photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Filtered(invalid, 0, 999), 0, 100)
            }
        }
    }

    @Test fun `筛选候选来自NAS并保存层级与未封顶区间`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        fixture.reply = { obj("""{"person":[{"id":21,"name":"Person"}],"geocoding":[{"id":22,"name":"Place","level":1,"children":[{"id":23,"name":"City","level":2}]}],"camera":[{"id":24,"name":"Camera"}],"focal_length_group":[{"start":35,"end":0}],"exposure_time_group":[{"start":{"num":0,"den":1},"end":{"num":1,"den":30}}]}""") }
        val options = repository.filterOptions()
        assertEquals(23L, options.locations.single().children.single().id)
        assertEquals(24L, options.cameras.single().id)
        assertEquals(0, options.focalRanges.single().end)
        assertEquals(0, options.exposureRanges.single().start.num)
        val settings = obj(fixture.requests.single().fields.getValue("setting"))
        assertEquals(12, settings.size)
        assertTrue(settings.values.all { it == JsonPrimitive(true) })
    }

    @Test fun `目录权限父身份相册和分类分别使用对应Photos接口`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        fixture.reply = { request -> when {
            request.method == "get" && request.capability.name.endsWith("Folder") -> obj("""{"folder":{"id":5,"name":"/","parent":0,"additional":{"access_permission":{"view":true}}}}""")
            request.capability.name.endsWith("Folder") -> obj("""{"list":[{"id":6,"name":"/Photos/Trips","parent":5}]}""")
            request.capability.name.endsWith("Category") -> obj("""{"list":[{"id":"recently_added"},{"id":"person"},{"id":"concept"},{"id":"geocoding"},{"id":"general_tag"},{"id":"video"},{"id":"not-observed"}]}""")
            else -> obj("""{"list":[]}""")
        } }
        assertEquals(5L, repository.rootFolder(SynologyPhotoSpace.PERSONAL).id)
        assertEquals("Trips", repository.folders(SynologyPhotoSpace.PERSONAL, 5, 0, 100).single().name)
        assertEquals(SynologyPhotoCategory.entries.toSet(), repository.categories())
        repository.albums(0, 100)
        assertEquals("\"normal_share_with_me\"", fixture.requests.last().fields["category"])
        repository.photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Album(7), 0, 100)
        assertEquals("7", fixture.requests.last().fields["album_id"])
        assertEquals("\"desc\"", fixture.requests.last().fields["sort_direction"])
        repository.photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Folder(6), 0, 100)
        assertEquals("\"asc\"", fixture.requests.last().fields["sort_direction"])
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.folders(SynologyPhotoSpace.PERSONAL, 99, 0, 100) }
    }

    @Test fun `分享只读返回既有相册且仅复制安全HTTPS收集链接`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        fixture.reply = { request -> if (request.capability.name.endsWith("PhotoRequest")) obj("""{"list":[{"passphrase":"a","subject":"Safe","sharing_link":"https://photos.example.invalid/r/a"},{"passphrase":"b","subject":"Unsafe","sharing_link":"https://account:secret@photos.example.invalid/r/b"},{"passphrase":"c","subject":"Local","sharing_link":"file:///photos"}]}""") else obj("""{"list":[{"id":7,"name":"Existing album"}]}""") }
        val values = repository.sharedEntries(SynologyPhotoShareScope.REQUESTS, 0, 10)
        assertNotNull(values.first().url)
        assertTrue(values.drop(1).all { it.url == null })
        assertEquals(7L, repository.sharedEntries(SynologyPhotoShareScope.WITH_ME, 0, 10).single().albumId)
        assertEquals("list_shared_with_me_album", fixture.requests.last().method)
        repository.sharedEntries(SynologyPhotoShareScope.WITH_OTHERS, 0, 10)
        assertEquals("\"shared\"", fixture.requests.last().fields["category"])
        assertTrue(fixture.requests.none { it.method in setOf("create", "set", "delete") })
    }

    @Test fun `详情只接收同一Photos身份并完整保留元数据`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        fixture.reply = { obj("""{"list":[${item(11, extra = ",\"exif\":{\"camera\":\"Synthetic camera\",\"iso\":\"200\"},\"gps\":{\"latitude\":12.5,\"longitude\":-34.5},\"rating\":4,\"video_meta\":{\"duration\":1.5}")}]}""") }
        val detail = repository.details(photo())
        assertEquals("Synthetic camera", detail.camera)
        assertEquals("200", detail.iso)
        assertEquals(12.5, detail.latitude!!, 0.0)
        assertEquals(1.5, detail.duration!!, 0.0)
        assertEquals(4, detail.rating)
        fixture.reply = { obj("""{"list":[${item(12)}]}""") }
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.details(photo()) }
        failure(SynologyPhotoFailureKind.PERMISSION) { repository.details(photo().copy(id = photo().id.copy(profileId = "other"))) }
    }

    @Test fun `实况视频单元不能被照片ID或缩略图ID替代`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        fixture.reply = { obj("""{"list":[{"id_item":11,"unit":[{"id":91,"live_type":"image"},{"id":93,"live_type":"video","additional":{"video_convert":[{"quality":"medium"},{"quality":"orig_h264"}]}}]}]}""") }
        val request = repository.videoRequest(photo(type = "live"))
        assertEquals("SYNO.Foto.Streaming", request.first.name)
        assertEquals("93", request.second.second["id"])
        assertEquals("\"unit\"", request.second.second["type"])
        assertEquals("\"orig_h264\"", request.second.second["quality"])
        assertEquals("true", request.second.second["use_mov"])
        assertEquals("[11]", fixture.requests.single().fields["id_item"])
        fixture.reply = { obj("""{"list":[{"id_item":11,"unit":[{"id":93,"live_type":"video","additional":{"video_convert":[{"quality":"raw"},{"quality":"high"}]}}]}]}""") }
        val raw = repository.videoRequest(photo(type = "live"))
        assertEquals("SYNO.Foto.Download", raw.first.name)
        assertEquals(mapOf("unit_id" to "[93]"), raw.second.second)
        fixture.reply = { obj("""{"list":[{"id_item":12,"unit":[{"id":93,"live_type":"video"}]}]}""") }
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.videoRequest(photo(type = "live")) }
    }

    @Test fun `普通视频只选择已声明质量且原件以item身份读取`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        fixture.reply = { obj("""{"list":[{"id":11,"type":"video","additional":{"video_convert":[]}}]}""") }
        assertEquals(mapOf("item_id" to "[11]"), repository.videoRequest(photo(type = "video")).second.second)
        fixture.reply = { obj("""{"list":[{"id":11,"type":"video","additional":{"video_convert":[{"quality":"mobile"},{"quality":"low"}]}}]}""") }
        assertEquals("\"low\"", repository.videoRequest(photo(type = "video")).second.second["quality"])
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.videoRequest(photo(type = "photo")) }
    }

    @Test fun `刷新授权期间迟到的图库响应不能写回`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        val entered = CompletableDeferred<Unit>()
        val resume = CompletableDeferred<Unit>()
        fixture.reply = { entered.complete(Unit); resume.await(); obj("""{"list":[${item(11)}]}""") }
        val old = async { repository.photos(SynologyPhotoSpace.PERSONAL, query, 0, 2) }
        entered.await()
        fixture.homeEnabled = false
        repository.access()
        resume.complete(Unit)
        try { old.await(); fail("迟到响应被错误接受") } catch (_: CancellationException) { }
    }

    @Test fun `默认关闭删除且不发送危险请求`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        failure(SynologyPhotoFailureKind.DELETION_UNVERIFIED) { repository.deletePhoto(photo(), UUID.randomUUID()) }
        assertTrue(fixture.requests.isEmpty())
        assertFalse(repository.canDeleteOriginals)
    }

    @Test fun `删除确认前复查快照和权限发生变化时零写入`() = runTest {
        for (mode in listOf("changed", "denied")) {
            val fixture = Fixture(deletion = true)
            val repository = fixture.ready()
            fixture.reply = { request -> when {
                request.capability.name.endsWith("Item") -> obj("""{"list":[${item(if (mode == "changed") 12 else 11)}]}""")
                else -> obj("""{"folder":{"id":5,"additional":{"access_permission":{"view":true,"manage":false}}}}""")
            } }
            try { repository.deletePhoto(photo(), UUID.randomUUID()); fail("错误允许删除") } catch (_: SynologyPhotoFailure) { }
            assertTrue(fixture.requests.none { it.method == "delete" })
        }
    }

    @Test fun `删除不确定时仅核对不重复提交直到显式空列表确认`() = runTest {
        val fixture = Fixture(deletion = true)
        val repository = fixture.ready()
        var deleted = false
        var empty = false
        fixture.reply = { request -> when {
            request.method == "delete" -> { deleted = true; throw IOException("synthetic connection loss") }
            request.capability.name.endsWith("Folder") -> obj("""{"folder":{"id":5,"additional":{"access_permission":{"view":true,"manage":true}}}}""")
            empty -> obj("""{"list":[]}""")
            deleted -> obj("{}")
            else -> obj("""{"list":[${item(11)}]}""")
        } }
        val operation = UUID.randomUUID()
        assertEquals(SynologyPhotoDeletionResult.PENDING_REVIEW, repository.deletePhoto(photo(), operation))
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.reviewDeletion(photo()) }
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.deletePhoto(photo(), UUID.randomUUID()) }
        assertEquals(1, fixture.requests.count { it.method == "delete" })
        empty = true
        assertEquals(SynologyPhotoDeletionResult.CONFIRMED, repository.reviewDeletion(photo()))
        assertEquals(SynologyPhotoDeletionResult.CONFIRMED, repository.deletePhoto(photo(), operation))
        assertEquals(1, fixture.requests.count { it.method == "delete" })
        val write = fixture.requests.single { it.method == "delete" }
        assertEquals(mapOf("item_id" to "[11]", "folder_id" to "[]"), write.fields)
    }

    @Test fun `同一删除操作不能改成另一目标快照`() = runTest {
        val fixture = Fixture(deletion = true)
        val repository = fixture.ready()
        fixture.reply = { request -> when {
            request.capability.name.endsWith("Folder") -> obj("""{"folder":{"id":5,"additional":{"access_permission":{"view":true,"manage":true}}}}""")
            request.method == "delete" -> throw IOException("synthetic loss")
            else -> obj("""{"list":[${item(11)}]}""")
        } }
        val operation = UUID.randomUUID()
        repository.deletePhoto(photo(), operation)
        failure(SynologyPhotoFailureKind.TARGET_CHANGED) { repository.deletePhoto(photo().copy(sizeBytes = 99), operation) }
        failure(SynologyPhotoFailureKind.TARGET_CHANGED) { repository.deletePhoto(photo(12), operation) }
        assertEquals(1, fixture.requests.count { it.method == "delete" })
    }

    private suspend fun failure(kind: SynologyPhotoFailureKind, action: suspend () -> Any?) {
        try { action(); fail("Expected $kind") } catch (error: SynologyPhotoFailure) { assertEquals(kind, error.kind) }
    }

    private companion object {
        val query = SynologyPhotoQuery.Timeline(1, 999)
        fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        fun item(id: Long, type: String = "photo", extra: String = "") = """{"id":$id,"filename":"sample.heic","filesize":4,"time":100.25,"indexed_time":101.75,"folder_id":5,"type":"$type","additional":{"thumbnail":{"unit_id":91,"cache_key":"revision"}$extra}}"""
        fun photo(id: Long = 11, type: String = "photo") = SynologyPhotosCodec.photo(obj(item(id, type)), "profile-a", SynologyPhotoSpace.PERSONAL)
        fun capabilities(): Map<String, ApiCapability> = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline",
            "Browse.Item", "Browse.Folder", "Browse.Album", "Browse.Category", "Browse.RecentlyAdded", "Browse.Person", "Browse.Concept",
            "Browse.Geocoding", "Browse.GeneralTag", "Browse.Unit", "Search.Search", "Search.Filter", "Sharing.Misc", "PhotoRequest",
            "Download", "Streaming", "BackgroundTask.File").associate { suffix ->
            val name = "SYNO.Foto.$suffix"
            name to ApiCapability(name, "entry.cgi", 1, 5, "JSON")
        }
    }
}
