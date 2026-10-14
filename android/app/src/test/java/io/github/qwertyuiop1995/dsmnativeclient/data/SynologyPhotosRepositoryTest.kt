package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import java.time.LocalDate
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
        var teamPermission = "unknown"
        var teamEnabled = true
        var userFlags = ""
        var adminFlags = ""
        var teamFlags = ""
        var reply: suspend (Request) -> JsonObject = { obj("""{"list":[]}""") }
        val repository = SynologyPhotosRepository("profile-a", capabilities, { capability, method, fields ->
            val request = Request(capability, method, fields)
            requests += request
            when (capability.name) {
                "SYNO.Foto.UserInfo" -> obj("""{"enabled":$userEnabled,"id":41}""")
                "SYNO.Foto.Setting.User" -> obj("""{"enable_home_service":$homeEnabled,"team_space_permission":"$teamPermission"$userFlags}""")
                "SYNO.Foto.Setting.Admin" -> obj("""{"package_version":"fixture"$adminFlags}""")
                "SYNO.Foto.Setting.TeamSpace" -> obj("""{"enabled":$teamEnabled$teamFlags}""")
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

    @Test fun `月份窗口与日期筛选取交集且无交集不发送请求`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        val filter = SynologyPhotoFilter(startTime = 100, endTime = 900)
        repository.photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Filtered(filter, 200, 800), 0, 100)
        assertEquals("[{\"start_time\":200,\"end_time\":800}]", fixture.requests.single().fields["time"])
        val count = fixture.requests.size
        val empty = repository.photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Filtered(filter, 1000, 1200), 0, 100)
        assertTrue(empty.items.isEmpty())
        assertFalse(empty.hasMore)
        assertEquals(count, fixture.requests.size)
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
        val fixture = Fixture().apply { userFlags = ",\"enable_similar\":true" }
        val repository = fixture.ready()
        fixture.reply = { request -> when {
            request.method == "get" && request.capability.name.endsWith("Folder") -> obj("""{"folder":{"id":5,"name":"/","parent":0,"additional":{"access_permission":{"view":true}}}}""")
            request.capability.name.endsWith("Folder") -> obj("""{"list":[{"id":6,"name":"/Photos/Trips","parent":5}]}""")
            request.capability.name.endsWith("Category") -> obj("""{"list":[{"id":"recently_added"},{"id":"person"},{"id":"concept"},{"id":"geocoding"},{"id":"general_tag"},{"id":"video"},{"id":"similar"},{"id":"not-observed"}]}""")
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
        failure(SynologyPhotoFailureKind.DELETION_UNVERIFIED) { repository.performPhotoDeletion(photo(), deletionCheckpoint()) {} }
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
            try { repository.performPhotoDeletion(photo(), deletionCheckpoint()) {}; fail("错误允许删除") } catch (_: SynologyPhotoFailure) { }
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
        var checkpoint = deletionCheckpoint()
        assertEquals(SynologyPhotoDeletionPhase.SUBMITTED, repository.performPhotoDeletion(photo(), checkpoint) { checkpoint = it }.phase)
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.reviewPhotoDeletion(checkpoint) { checkpoint = it } }
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.performPhotoDeletion(photo(), checkpoint) { checkpoint = it } }
        assertEquals(1, fixture.requests.count { it.method == "delete" })
        empty = true
        assertEquals(SynologyPhotoDeletionPhase.CONFIRMED, repository.reviewPhotoDeletion(checkpoint) { checkpoint = it }.phase)
        assertEquals(SynologyPhotoDeletionPhase.CONFIRMED, repository.performPhotoDeletion(photo(), checkpoint) { checkpoint = it }.phase)
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
        val checkpoint = deletionCheckpoint()
        repository.performPhotoDeletion(photo(), checkpoint) {}
        failure(SynologyPhotoFailureKind.TARGET_CHANGED) {
            val changed = photo().copy(sizeBytes = 99)
            repository.performPhotoDeletion(changed, checkpoint.copy(target = SynologyPhotoDeletionTarget(changed))) {}
        }
        failure(SynologyPhotoFailureKind.TARGET_CHANGED) { repository.performPhotoDeletion(photo(12), checkpoint.copy(target = SynologyPhotoDeletionTarget(photo(12)))) {} }
        assertEquals(1, fixture.requests.count { it.method == "delete" })
    }

    @Test fun `共享来源仅接受已启用且明确entry或management而不猜测未知权限`() = runTest {
        val fixture = Fixture().apply { homeEnabled = false }
        for (permission in listOf("none", "unknown", "entry", "management")) {
            fixture.teamPermission = permission
            val access = fixture.repository.access()
            assertEquals(if (permission in setOf("entry", "management")) listOf(SynologyPhotoSpace.SHARED) else emptyList<SynologyPhotoSpace>(), access.spaces)
            assertEquals(permission == "management", access.canManageSharedSpace)
        }
        fixture.teamEnabled = false
        assertTrue(fixture.repository.access().spaces.isEmpty())
    }

    @Test fun `共享时间线目录搜索分类和筛选使用已发现的来源能力`() = runTest {
        val fixture = Fixture().apply { homeEnabled = false; teamPermission = "management" }
        val repository = fixture.ready()
        fixture.reply = { request -> when {
            request.capability.name.endsWith("Timeline") || request.method == "get_search_timeline" -> obj("""{"section":[]}""")
            request.capability.name.endsWith("Category") -> obj("""{"list":[{"id":"person"},{"id":"concept"},{"id":"geocoding"},{"id":"video"}]}""")
            request.capability.name.endsWith("Search.Filter") -> obj("""{"person":[],"geocoding":[]}""")
            request.capability.name.endsWith("Folder") && request.method == "get" -> obj("""{"folder":{"id":5,"name":"/","parent":0}}""")
            request.capability.name.endsWith("Item") -> obj("""{"list":[${item(11)}]}""")
            else -> obj("""{"list":[]}""")
        } }
        val shared = SynologyPhotoSpace.SHARED
        repository.timeline(shared)
        repository.timeline(shared, SynologyPhotoQuery.Search("sample", 1, 9))
        assertEquals(shared, repository.photos(shared, query, 0, 2).items.single().id.space)
        assertEquals(shared, repository.rootFolder(shared).space)
        repository.folders(shared, 5, 0, 2)
        assertEquals(setOf(SynologyPhotoCategory.LOCATIONS, SynologyPhotoCategory.VIDEOS), repository.categories(shared))
        repository.categoryItems(SynologyPhotoCategory.LOCATIONS, 0, 2, shared)
        repository.filterOptions(shared)
        assertTrue(fixture.requests.all { it.capability.name.startsWith("SYNO.FotoTeam.") || it.capability.name == "SYNO.Foto.Browse.Category" })
        assertTrue(fixture.requests.none { it.capability.name == "SYNO.FotoTeam.Browse.Category" })
    }

    @Test fun `共享entry目录逐项查看且不授予全局分类管理权限`() = runTest {
        val fixture = Fixture().apply { teamPermission = "entry" }
        val repository = fixture.ready()
        assertTrue(repository.categories(SynologyPhotoSpace.SHARED).isEmpty())
        failure(SynologyPhotoFailureKind.PERMISSION) { repository.categoryItems(SynologyPhotoCategory.LOCATIONS, 0, 2, SynologyPhotoSpace.SHARED) }
        assertTrue(fixture.requests.isEmpty())
        fixture.reply = { obj("""{"folder":{"id":5,"name":"/","parent":0,"additional":{"access_permission":{"view":false}}}}""") }
        failure(SynologyPhotoFailureKind.PERMISSION) { repository.rootFolder(SynologyPhotoSpace.SHARED) }
        fixture.reply = { obj("""{"person":[],"geocoding":[]}""") }
        repository.filterOptions(SynologyPhotoSpace.SHARED)
        assertEquals("SYNO.FotoTeam.Search.Filter", fixture.requests.last().capability.name)
    }

    @Test fun `识别设置关闭会收回对应分类且共享还需实际版本能力`() = runTest {
        val fixture = Fixture().apply { teamPermission = "management"; teamFlags = ",\"enable_person\":true,\"enable_concept\":true"; adminFlags = ",\"enable_person\":false" }
        val repository = fixture.ready()
        fixture.reply = { obj("""{"list":[{"id":"person"},{"id":"concept"}]}""") }
        assertEquals(setOf(SynologyPhotoCategory.SUBJECTS), repository.categories(SynologyPhotoSpace.PERSONAL))
        assertEquals(setOf(SynologyPhotoCategory.SUBJECTS), repository.categories(SynologyPhotoSpace.SHARED))
        failure(SynologyPhotoFailureKind.PERMISSION) { repository.categoryItems(SynologyPhotoCategory.PEOPLE, 0, 2) }
        val unavailable = Fixture(capabilities = capabilities() - "SYNO.FotoTeam.Browse.Concept").apply { teamPermission = "management"; teamFlags = ",\"enable_concept\":true" }
        unavailable.reply = fixture.reply
        assertTrue(unavailable.ready().categories(SynologyPhotoSpace.SHARED).isEmpty())
    }

    @Test fun `没有原来源权限也可从相册读取混合来源且详情保持相册授权`() = runTest {
        val fixture = Fixture().apply { homeEnabled = false; teamPermission = "none" }
        val repository = fixture.ready()
        fixture.reply = { request ->
            if (request.method == "get") obj("""{"list":[${item(12).replace("\"folder_id\":5", "\"folder_id\":5,\"owner_user_id\":0")}]}""")
            else obj("""{"list":[${item(11).replace("\"folder_id\":5", "\"folder_id\":5,\"owner_user_id\":42")},${item(12).replace("\"folder_id\":5", "\"folder_id\":5,\"owner_user_id\":0")}]}""")
        }
        val photos = repository.photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Album(7), 0, 2).items
        assertEquals(listOf(SynologyPhotoSpace.PERSONAL, SynologyPhotoSpace.SHARED), photos.map { it.id.space })
        assertEquals(listOf(42L, 0L), photos.map { it.albumContext!!.ownerUserId })
        assertEquals(photos.last().albumContext, repository.details(photos.last()).albumContext)
        assertTrue(fixture.requests.all { it.capability.name == "SYNO.Foto.Browse.Item" && it.fields["album_id"] == "7" })
        assertFalse(repository.canDelete(photos.first()))
        assertFalse(repository.canDelete(photos.last()))
        fixture.requests.clear()
        failure(SynologyPhotoFailureKind.PERMISSION) { repository.details(photos.last().copy(albumContext = null)) }
        assertTrue(fixture.requests.isEmpty())
    }

    @Test fun `相册缺失所有者负值或详情所有者变化都拒绝且不回退来源`() = runTest {
        val fixture = Fixture()
        val repository = fixture.ready()
        for (owner in listOf("", ",\"owner_user_id\":-1", ",\"owner_user_id\":\"0\"")) {
            fixture.reply = { obj("""{"list":[${item(11).replace("\"folder_id\":5", "\"folder_id\":5$owner")}]}""") }
            failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Album(7), 0, 2) }
        }
        val photo = photo().copy(albumContext = SynologyPhotoAlbumContext(7, 42))
        fixture.reply = { obj("""{"list":[${item(11).replace("\"folder_id\":5", "\"folder_id\":5,\"owner_user_id\":43")}]}""") }
        failure(SynologyPhotoFailureKind.INVALID_RESPONSE) { repository.details(photo) }
        fixture.requests.clear()
        fixture.reply = { throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION) }
        failure(SynologyPhotoFailureKind.PERMISSION) { repository.details(photo) }
        assertEquals(1, fixture.requests.size)
        assertEquals("7", fixture.requests.single().fields["album_id"])
    }

    @Test fun `相册影片和实况选源保留album而共享原来源使用FotoTeam`() = runTest {
        val fixture = Fixture().apply { teamPermission = "entry" }
        val repository = fixture.ready()
        fixture.reply = { obj("""{"list":[${item(11, "video", ",\"video_convert\":[{\"quality\":\"high\"}]")}]}""") }
        val video = photo(type = "video").copy(id = photo().id.copy(space = SynologyPhotoSpace.SHARED))
        val shared = repository.videoRequest(video)
        assertEquals("SYNO.FotoTeam.Streaming", shared.first.name)
        assertFalse(shared.second.second.containsKey("album_id"))
        val album = repository.videoRequest(video.copy(albumContext = SynologyPhotoAlbumContext(7, 0)))
        assertEquals("SYNO.Foto.Streaming", album.first.name)
        assertEquals("7", album.second.second["album_id"])
        fixture.reply = { obj("""{"list":[{"id_item":11,"unit":[{"id":88,"live_type":"video","additional":{"video_convert":[]}}]}]}""") }
        val live = repository.videoRequest(video.copy(mediaType = "live", albumContext = SynologyPhotoAlbumContext(9, 0)))
        assertEquals("SYNO.Foto.Download", live.first.name)
        assertEquals(mapOf("unit_id" to "[88]", "album_id" to "9"), live.second.second)
        assertEquals("9", fixture.requests.last().fields["album_id"])
    }

    @Test fun `共享删除按实际原命名空间预检而贡献权不能删除他人原件`() = runTest {
        val fixture = Fixture(deletion = true).apply { teamPermission = "management" }
        val repository = fixture.ready()
        val foreign = photo().copy(albumContext = SynologyPhotoAlbumContext(7, 42, 41))
        assertFalse(repository.canDelete(foreign))
        failure(SynologyPhotoFailureKind.PERMISSION) { repository.prepareDeletion(foreign) }
        assertTrue(fixture.requests.isEmpty())
        val shared = photo().copy(id = photo().id.copy(space = SynologyPhotoSpace.SHARED))
        assertTrue(repository.canDelete(shared))
        fixture.reply = { request -> if (request.capability.name.endsWith("Item")) obj("""{"list":[${item(11)}]}""")
            else obj("""{"folder":{"id":5}}""") }
        repository.prepareDeletion(shared)
        assertTrue(fixture.requests.all { it.capability.name.startsWith("SYNO.FotoTeam.") })
        assertTrue(fixture.requests.none { it.method == "delete" })
    }

    @Test fun `文件夹读取独立回退用户排序且共享分页保留字段方向与原游标`() = runTest {
        val fixture = Fixture().apply { teamPermission = "entry"; userFlags = ",\"item_sort_by\":\"filesize\",\"sort_direction\":\"desc\"" }
        val repository = fixture.ready()
        fixture.reply = { request -> if (request.method == "get") obj("""{"folder":{"id":5,"parent":1,"name":"/Synthetic","sort_by":"future","sort_direction":"asc","additional":{"access_permission":{"view":true}}}}""") else obj("""{"list":[]}""") }
        val access = repository.folderAccess(SynologyPhotoSpace.SHARED, 5)
        assertEquals(SynologyPhotoSort(SynologyPhotoSort.Field.FILESIZE, SynologyPhotoSort.Direction.ASCENDING), access.sort)
        assertNull(access.explicitSort); assertFalse(access.canManage)
        repository.photos(SynologyPhotoSpace.SHARED, SynologyPhotoQuery.Folder(5, access.sort), 200, 100)
        val photos = fixture.requests.last(); assertEquals("SYNO.FotoTeam.Browse.Item", photos.capability.name)
        assertEquals("\"filesize\"", photos.fields["sort_by"]); assertEquals("\"asc\"", photos.fields["sort_direction"])
        assertEquals("200", photos.fields["offset"]); assertEquals("100", photos.fields["limit"]); assertEquals("5", photos.fields["folder_id"])
        repository.folders(SynologyPhotoSpace.SHARED, 5, 100, 100, SynologyPhotoSort.Direction.DESCENDING)
        val folders = fixture.requests.last(); assertEquals("SYNO.FotoTeam.Browse.Folder", folders.capability.name)
        assertEquals("\"filename\"", folders.fields["sort_by"]); assertEquals("\"desc\"", folders.fields["sort_direction"])
    }

    @Test fun `默认排序字段与方向分别回退且账号刷新不保留上个用户偏好`() = runTest {
        val fixture = Fixture().apply { userFlags = ",\"item_sort_by\":\"filename\",\"sort_direction\":\"desc\"" }
        val repository = fixture.ready()
        fixture.reply = { obj("""{"folder":{"id":5,"parent":0,"name":"/","sort_by":"item_type","additional":{"access_permission":{"view":true}}}}""") }
        assertEquals(SynologyPhotoSort(SynologyPhotoSort.Field.ITEM_TYPE, SynologyPhotoSort.Direction.DESCENDING), repository.folderAccess(SynologyPhotoSpace.PERSONAL, 5).sort)
        fixture.userFlags = ""; repository.access()
        assertEquals(SynologyPhotoSort(SynologyPhotoSort.Field.ITEM_TYPE, SynologyPhotoSort.Direction.ASCENDING), repository.folderAccess(SynologyPhotoSpace.PERSONAL, 5).sort)
    }

    private suspend fun failure(kind: SynologyPhotoFailureKind, action: suspend () -> Any?) {
        try { action(); fail("Expected $kind") } catch (error: SynologyPhotoFailure) { assertEquals(kind, error.kind) }
    }

    private companion object {
        val query = SynologyPhotoQuery.Timeline(1, 999)
        fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        fun item(id: Long, type: String = "photo", extra: String = "") = """{"id":$id,"filename":"sample.heic","filesize":4,"time":100.25,"indexed_time":101.75,"folder_id":5,"type":"$type","additional":{"thumbnail":{"unit_id":91,"cache_key":"revision"}$extra}}"""
        fun deletionCheckpoint(photo: SynologyPhoto = photo()) = SynologyPhotoDeletionCheckpoint(userId = 41, target = SynologyPhotoDeletionTarget(photo))
        fun photo(id: Long = 11, type: String = "photo") = SynologyPhotosCodec.photo(obj(item(id, type)), "profile-a", SynologyPhotoSpace.PERSONAL)
        fun capabilities(): Map<String, ApiCapability> = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline",
            "Browse.Item", "Browse.Folder", "Browse.Album", "Browse.Category", "Browse.RecentlyAdded", "Browse.Person", "Browse.Concept",
            "Browse.Geocoding", "Browse.GeneralTag", "Browse.Unit", "Browse.Similar", "Browse.SimilarItem", "Browse.SimilarTimeline", "Search.Search", "Search.Filter", "Sharing.Misc", "PhotoRequest",
            "Download", "Streaming", "BackgroundTask.File").associate { suffix ->
            val name = "SYNO.Foto.$suffix"
            name to ApiCapability(name, "entry.cgi", 1, 5, "JSON")
        }.let { personal -> personal + personal.values.filter { it.name !in setOf("SYNO.Foto.Browse.Album", "SYNO.Foto.Browse.Category") }.associate {
            val name = it.name.replace("SYNO.Foto.", "SYNO.FotoTeam.")
            name to it.copy(name = name)
        } }
    }
}
