package io.github.qwertyuiop1995.dsmnativeclient.downloads

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.network.OneShotRequestBody
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.util.concurrent.CopyOnWriteArrayList
import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test

class DownloadContractTest {
    @Test fun `链接创建固定v3无任务编号也保存接受回执且不认领列表`() = runBlocking {
        val fixture = DownloadProtocolFixture { fields, _ -> assertEquals("create", fields["method"]); "{\"success\":true}" }
        var saved = false; var accepted = false
        val result = fixture.repository().createDownloadResult("https://example.invalid/synthetic.iso", null,
            { source, request -> assertEquals(64, source.length); assertEquals(64, request.length); saved = true }, { assertTrue(saved); accepted = true })
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertTrue(accepted)
        assertEquals("3", fixture.fields.single()["version"]); assertTrue(fixture.requests.single().body!!.isOneShot())
    }
    @Test fun `链接v1或v2能力不降级提交`() = runBlocking {
        for (version in 1..2) {
            val f = DownloadProtocolFixture { _, _ -> error("不得发送") }
            assertEquals(MutationResultStatus.UNSUPPORTED, f.repository(version).createDownloadResult("https://example.invalid/file", null).status)
            assertTrue(f.requests.isEmpty())
        }
    }
    @Test fun `本机摘要保存失败零创建请求`() = runBlocking {
        val f = DownloadProtocolFixture { _, _ -> error("不得发送") }
        val result = f.repository().createDownloadResult("https://example.invalid/file", null, { _, _ -> throw storageError() })
        assertFalse(result.submitted); assertTrue(f.requests.isEmpty())
    }
    @Test fun `丢失创建回执保持同来源保护且其他来源可创建`() = runBlocking {
        val f = DownloadProtocolFixture { fields, _ -> if (fields["uri"]!!.endsWith("one")) throw IOException("synthetic disconnect") else "{\"success\":true}" }
        val repo = f.repository()
        assertTrue(repo.createDownloadResult("https://example.invalid/one", null).requiresRefresh)
        assertEquals(MutationErrorCategory.CONFLICT, repo.createDownloadResult("https://example.invalid/one", null).errorCategory)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.createDownloadResult("https://example.invalid/two", null).status)
        assertEquals(2, f.requests.size)
    }
    @Test fun `同内容任务文件改名仍同来源不同内容同大小不冲突密码空格原样`() = runBlocking {
        val fingerprints = mutableListOf<String>()
        val f = DownloadProtocolFixture { _, request ->
            assertTrue(request.body!!.isOneShot())
            val multipart = (request.body as OneShotRequestBody).delegate as MultipartBody
            val password = multipart.parts.single { it.headers?.get("Content-Disposition")?.contains("name=\"unzip_password\"") == true }
            assertEquals("  ", Buffer().also { password.body.writeTo(it) }.readUtf8())
            "{\"success\":true}"
        }
        val repo = f.repository()
        for ((name, contents) in listOf("one.torrent" to "one", "renamed.torrent" to "one", "one.torrent" to "two")) {
            val source = UploadSource(name, "application/octet-stream", 3, { contents.byteInputStream() })
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.createDownloadFromFileResult(source, unzipPassword = "  ",
                willSubmit = { sourceKey, _ -> fingerprints += sourceKey }).status)
        }
        assertEquals(fingerprints[0], fingerprints[1]); assertNotEquals(fingerprints[0], fingerprints[2])
    }
    @Test fun `任务文件密码控制字符在读取内容和请求前拒绝`() = runBlocking {
        val f = DownloadProtocolFixture { _, _ -> error("不得发送") }
        val source = UploadSource("test.torrent", null, 1, { error("不得读取") })
        assertFalse(f.repository().createDownloadFromFileResult(source, unzipPassword = "password\n").submitted)
        assertTrue(f.requests.isEmpty())
    }
    @Test fun `无total满页继续500项分页且短页才完整`() = runBlocking {
        val f = DownloadProtocolFixture { fields, _ ->
            assertEquals("500", fields["limit"]); assertEquals("detail,transfer", fields["additional"])
            val start = fields.getValue("offset").toInt()
            ok("{\"tasks\":[${(start until if (start == 0) 500 else 501).joinToString(",") { task(it.toString()) }}]}")
        }
        assertEquals(501, f.repository().listDownloads().size)
        assertEquals(listOf("0", "500"), f.fields.map { it["offset"] })
    }
    @Test fun `有total短页继续并拒绝重复编号漂移与坏容器`() = runBlocking {
        val good = DownloadProtocolFixture { fields, _ -> ok("{\"total\":2,\"tasks\":[${task(fields.getValue("offset"))}]}") }
        assertEquals(2, good.repository().listDownloads().size)
        for (second in listOf("{\"total\":3,\"tasks\":[${task("2")}]}", "{\"total\":2,\"tasks\":[${task("0")}]}", "{\"total\":2,\"tasks\":[]}")) {
            val f = DownloadProtocolFixture { fields, _ -> ok(if (fields["offset"] == "0") "{\"total\":2,\"tasks\":[${task("0") }]}" else second) }
            reject { f.repository().listDownloads() }
        }
    }
    @Test fun `详情独立getinfo匹配唯一编号且Tracker不显示口令路径`() = runBlocking {
        val f = DownloadProtocolFixture { fields, _ ->
            assertEquals("getinfo", fields["method"]); assertEquals("detail,transfer,file,tracker,peer", fields["additional"])
            ok("{\"tasks\":[{\"id\":\"one\",\"title\":\"Synthetic\",\"status\":\"downloading\",\"additional\":{\"tracker\":[{\"url\":\"https://user:password@tracker.example.invalid:8443/private/token?secret=123\"}]}}]}")
        }
        val task = f.repository().downloadTaskDetails("one")
        assertNull(task.size); assertEquals("https://tracker.example.invalid:8443", task.trackers.single().url)
        reject { f.repository().downloadTaskDetails("different") }
    }
    @Test fun `完成状态不冒充停止且继续后很快完成可确认`() = runBlocking {
        var finished = false
        val f = DownloadProtocolFixture { fields, _ -> if (fields["method"] == "resume") {
            finished = true; ok("""[{"id":"one","error":0}]""")
        } else ok("""{"tasks":[${task("one", if (finished) "finished" else "paused")}]}""") }
        val repo = f.repository()
        val original = repo.listDownloads().single()
        assertFalse(original.isCompleted)
        val result = repo.controlDownloadsResult(listOf(DownloadTaskMutationBaseline.from(original)), DownloadTaskMutationAction.RESUME)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertTrue(repo.listDownloads().single().isCompleted)
        assertEquals(1, f.fields.count { it["method"] == "resume" })
    }
    @Test fun `移除加forceComplete只计任务效果逐项严格回执`() = runBlocking {
        var removed = false
        val f = DownloadProtocolFixture { fields, _ -> when (fields["method"]) {
            "delete" -> { assertEquals("true", fields["force_complete"]); removed = true; ok("[{\"id\":\"one\",\"error\":0}]") }
            "list" -> ok("{\"tasks\":[${if (removed) "" else task("one")} ]}")
            else -> error("Unexpected")
        } }
        val repo = f.repository(); val baseline = DownloadTaskMutationBaseline.from(repo.listDownloads().single())
        val result = repo.controlDownloadsResult(listOf(baseline), DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(1, result.counts.succeeded); assertEquals(0, result.counts.unknown)
        assertEquals(1, f.fields.count { it["method"] == "delete" })
    }
    @Test fun `错编号重复回执或字符串错误不以状态变化冒充本次成功`() = runBlocking {
        for (receipt in listOf("[]", "[{\"id\":\"other\",\"error\":0}]", "[{\"id\":\"one\",\"error\":\"0\"}]", "[{\"id\":\"one\",\"error\":0},{\"id\":\"one\",\"error\":0}]")) {
            var paused = false
            val f = DownloadProtocolFixture { fields, _ -> if (fields["method"] == "pause") { paused = true; ok(receipt) } else ok("{\"tasks\":[${task("one", if (paused) "paused" else "downloading")}]}") }
            val repo = f.repository(); val baseline = DownloadTaskMutationBaseline.from(repo.listDownloads().single())
            assertTrue(repo.controlDownloadsResult(listOf(baseline), DownloadTaskMutationAction.PAUSE).requiresRefresh)
            assertEquals(1, f.fields.count { it["method"] == "pause" })
        }
    }
    @Test fun `设置当前管理员严格布尔字段缺失不发送默认值只提交实际差量`() = runBlocking {
        var limit = 12
        val f = DownloadProtocolFixture { fields, _ -> when (fields["method"]) {
            "getinfo" -> ok("{\"is_manager\":true}")
            "getconfig" -> if (fields["api"]!!.endsWith("Schedule")) ok("{\"enabled\":false}") else {
                assertEquals("2", fields["version"]); ok("{\"bt_max_download\":$limit,\"unzip_service_enabled\":\"false\"}") }
            "setserverconfig" -> { assertEquals(setOf("bt_max_download"), fields.keys - transportKeys); limit = fields.getValue("bt_max_download").toInt(); ok("{}") }
            else -> error("Unexpected")
        } }
        val repo = f.repository(); val original = repo.loadDownloadSettings()
        assertEquals(setOf("bt_max_download", "enabled"), original.availableFields); assertTrue(original.canManage)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.saveDownloadSettingsResult(original, original.copy(btDownloadLimitKb = 24)).status)
        assertEquals(1, f.fields.count { it["method"] == "setserverconfig" })
    }
    @Test fun `管理权限未知不得写且计划读取失败不阻断常规分区`() = runBlocking {
        val f = DownloadProtocolFixture { fields, _ -> when (fields["method"]) {
            "getinfo" -> ok("{\"is_manager\":\"true\"}")
            "getconfig" -> if (fields["api"]!!.endsWith("Schedule")) throw IOException("synthetic schedule unavailable") else ok("{\"bt_max_download\":10}")
            else -> error("不得写入")
        } }
        val repo = f.repository(); val original = repo.loadDownloadSettings()
        assertFalse(original.canManage); assertNotNull(original.scheduleFailure); assertEquals(setOf("bt_max_download"), original.availableFields)
        val result = repo.saveDownloadSettingsResult(original, original.copy(btDownloadLimitKb = 20))
        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status); assertFalse(result.submitted)
    }
    @Test fun `RSS编号整数双容器拒绝且更新必须同站点时间推进`() = runBlocking {
        var refreshed = false
        val f = DownloadProtocolFixture { fields, _ -> when (fields["method"]) {
            "refresh" -> { assertEquals("7", fields["id"]); refreshed = true; ok("{}") }
            else -> ok("{\"total\":1,\"offset\":0,\"sites\":[{\"id\":7,\"title\":\"Synthetic RSS\",\"url\":\"https://example.invalid/rss\",\"username\":\"synthetic\",\"is_updating\":false,\"last_update\":10}]}")
        } }
        val repo = f.repository(); assertEquals("7", repo.listDownloadRssSites().single().id)
        assertTrue(repo.refreshDownloadRssSiteResult("7").requiresRefresh); assertTrue(refreshed)
        val wrong = DownloadProtocolFixture { _, _ -> ok("{\"site\":[],\"total\":1,\"offset\":0,\"sites\":[]}") }
        reject { wrong.repository().listDownloadRssSites() }
    }
    @Test fun `RSS条目大小必须是十进制字符串并包含站点编号`() = runBlocking {
        val f = DownloadProtocolFixture { fields, _ -> assertEquals("7", fields["id"]); ok("{\"total\":1,\"offset\":0,\"feeds\":[{\"title\":\"Synthetic\",\"size\":\"4096\",\"time\":10,\"download_uri\":\"https://example.invalid/file\",\"external_link\":\"https://example.invalid/page\"}]}") }
        assertEquals(4096L, f.repository().listDownloadRssFeeds("7").single().size)
        val wrong = DownloadProtocolFixture { _, _ -> ok("{\"total\":1,\"offset\":0,\"feeds\":[{\"title\":\"Synthetic\",\"size\":4096,\"time\":10,\"download_uri\":\"https://example.invalid/file\",\"external_link\":\"https://example.invalid/page\"}]}") }
        reject { wrong.repository().listDownloadRssFeeds("7") }
    }
    @Test fun `修改目录固定v2保留名称空格并严格回执后读取位置`() = runBlocking {
        var destination = "old"
        val target = "/shared/ final "
        val f = DownloadProtocolFixture { fields, _ -> when (fields["api"] to fields["method"]) {
            "SYNO.FileStation.List" to "getinfo" -> ok("""{"files":[{"name":" final ","path":"$target","isdir":true,"additional":{"owner":"synthetic","perm":{"read":true,"write":true,"delete":false}}}]}""")
            "SYNO.DownloadStation.Task" to "edit" -> { assertEquals("2", fields["version"]); assertEquals("shared/ final ", fields["destination"]); destination = fields.getValue("destination"); ok("""[{"id":"one","error":0}]""") }
            else -> ok("""{"tasks":[${task("one").dropLast(1)},"additional":{"detail":{"destination":"$destination"}}}]}""")
        } }
        val repo = f.repository(); val original = DownloadTaskMutationBaseline.from(repo.listDownloads().single())
        var persisted = false; var accepted = false
        val result = repo.editDownloadDestinationResult(original, FileItem(target, " final ", true, owner = "synthetic", canRead = true, canWrite = true),
            { persisted = true }, { assertTrue(persisted); accepted = true })
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertTrue(accepted)
        assertEquals(1, f.fields.count { it["method"] == "edit" })
    }
    @Test fun `编辑不支持v2时不探测目录也不降级`() = runBlocking {
        val f = DownloadProtocolFixture { _, _ -> error("不得发送") }
        val baseline = DownloadTaskMutationBaseline("one", "http", "Synthetic", ResourceState.RUNNING, 10, "old", null)
        val result = f.repository(1).editDownloadDestinationResult(baseline, FileItem("/shared/new", "new", true, canWrite = true))
        assertEquals(MutationResultStatus.UNSUPPORTED, result.status); assertFalse(result.submitted); assertTrue(f.requests.isEmpty())
    }
    @Test fun `未知NAS错误不解除创建来源保护`() = runBlocking {
        val f = DownloadProtocolFixture { _, _ -> """{"success":false,"error":{"code":9999}}""" }
        val repo = f.repository()
        assertTrue(repo.createDownloadResult("https://example.invalid/one", null).requiresRefresh)
        assertEquals(MutationErrorCategory.CONFLICT, repo.createDownloadResult("https://example.invalid/one", null).errorCategory)
        assertEquals(1, f.requests.size)
    }
    @Test fun `HTTP和FTP必须同值不能顺序覆盖另一个原值`() = runBlocking {
        val f = DownloadProtocolFixture { fields, _ -> if (fields["method"] == "getinfo") ok("""{"is_manager":true}""")
            else if (fields["api"]!!.endsWith("Schedule")) ok("{}") else ok("""{"http_max_download":4,"ftp_max_download":4}""") }
        val repo = f.repository(); val original = repo.loadDownloadSettings()
        val result = repo.saveDownloadSettingsResult(original, original.copy(httpDownloadLimitKb = 8))
        assertEquals(MutationErrorCategory.VALIDATION, result.errorCategory); assertFalse(result.submitted)
        assertFalse(f.fields.any { it["method"] == "setserverconfig" })
    }
    private suspend fun reject(block: suspend () -> Any?) { try { block(); fail("Expected invalid response") } catch (_: DsmFailure) { } }
}

internal class DownloadProtocolFixture(private val response: (Map<String, String>, Request) -> String) : Interceptor {
    val requests = CopyOnWriteArrayList<Request>()
    val fields = CopyOnWriteArrayList<Map<String, String>>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val body = (request.body as? OneShotRequestBody)?.delegate ?: request.body
        val params = if (body is FormBody) (0 until body.size).associate { body.name(it) to body.value(it) }
            else request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() }
        requests += request; fields += params
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body(response(params, request).toResponseBody("application/json".toMediaType())).build()
    }
    fun repository(taskVersion: Int = 3, session: String = "session"): DsmRepository {
        val caps = listOf("SYNO.DownloadStation.Task", "SYNO.DownloadStation.Info", "SYNO.DownloadStation.Schedule", "SYNO.DownloadStation.RSS.Site", "SYNO.DownloadStation.RSS.Feed", "SYNO.FileStation.List")
            .associateWith { ApiCapability(it, "entry.cgi", 1, if (it.endsWith("Task")) taskVersion else if (it.endsWith("Info")) 2 else 1) }
        return authorizedRepository(NasProfile("synthetic-download", "Synthetic", "https://example.invalid", "synthetic"),
            DsmSession("synthetic-download", "synthetic-session"), DsmApiClient(OkHttpClient.Builder().addInterceptor(this).build()), caps)
            .also { it.bindOwner(WorkspaceOwner("synthetic-download", "identity", session)) {} }
    }
}
internal val transportKeys = setOf("api", "method", "version", "_sid", "SynoToken", "synotoken")
internal fun ok(data: String) = "{\"success\":true,\"data\":$data}"
internal fun task(id: String, status: String = "downloading") = "{\"id\":\"$id\",\"type\":\"http\",\"title\":\"Synthetic $id\",\"status\":\"$status\",\"size\":10}"
internal fun storageError() = DsmFailure(null, "Synthetic storage failure", "Synthetic recovery", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
