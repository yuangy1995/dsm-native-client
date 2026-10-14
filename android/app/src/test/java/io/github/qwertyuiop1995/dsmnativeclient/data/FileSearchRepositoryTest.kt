package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileSearchRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class FileSearchRepositoryTest {
    private val normal = FileSearchRequest(listOf("/synthetic"), name = "report")
    private fun data(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun file(id: Int, name: String = "$id.txt") = """{"path":"/synthetic/$id.txt","name":"$name","isdir":false}"""
    private fun page(items: List<String>, total: Int = items.size, offset: Int = 0, finished: Boolean = true) =
        data("""{"finished":$finished,"total":$total,"offset":$offset,"files":[${items.joinToString(",")}]}""")
    private val start = data("""{"taskid":"synthetic-search"}""")
    private val empty = data("{}")

    @Test fun `高级条件经过真实适配器符合共享请求样例`() = runBlocking {
        val requests = mutableListOf<Request>()
        val repo = repository(requests, ArrayDeque(listOf(start, page(listOf(file(1))), empty)))
        val dates = FileSearchTimeRange(100, 200)
        val request = FileSearchRequest(listOf("/synthetic/a", "/synthetic/b"), name = "*.txt", recursive = false,
            extension = "txt,md", kind = FileSearchKind.FILE, minimumBytes = 1_048_576, maximumBytes = 2_097_152,
            modified = dates, created = dates, accessed = dates, owner = "synthetic-owner", group = "synthetic-group")
        assertEquals(1, repo.searchWithReport(request).page.items.size)
        RequestFixtureAssertions.assertRequest(requests.first(), "file-station/search/synthetic-advanced/request.json")
        assertEquals(listOf("start", "list", "clean"), requests.map { fields(it)["method"] })
        assertTrue(requests.all { fields(it)["version"] == "2" })
    }

    @Test fun `正文请求符合共享样例且不按文件名丢弃命中`() = runBlocking {
        val requests = mutableListOf<Request>()
        val repo = repository(requests, ArrayDeque(listOf(data("""{"taskid":"content","has_not_index_share":true}"""), page(listOf(file(1, "Different.docx"))), empty)))
        val result = repo.searchWithReport(normal.copy(name = "synthetic content", searchesContents = true))
        assertEquals("Different.docx", result.page.items.single().name)
        assertEquals(FileSearchIndexCoverage.INCOMPLETE, result.indexCoverage)
        RequestFixtureAssertions.assertRequest(requests.first(), "file-station/search/synthetic-content/request.json")
    }

    @Test fun `版本不足在发送请求前拒绝`() = runBlocking {
        val requests = mutableListOf<Request>()
        val failure = runCatching { repository(requests, ArrayDeque(), maximumVersion = 1).searchWithReport(normal) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, failure.kind); assertTrue(requests.isEmpty())
    }

    @Test fun `未结束的空结果必须继续等待并完整分页后才清理`() = runTest {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        val first = (0 until 500).map { file(it) }
        val pending = ArrayDeque(listOf(start, page(emptyList(), finished = false), page(first, total = 501), page(listOf(file(500)), 501, 500), empty))
        val result = DsmFileSearchRepository({ method, parameters -> calls += method to parameters; pending.removeFirst() }, pollDelayMillis = 1).search(normal)
        assertEquals(501, result.page.items.size); assertEquals(501, result.page.total)
        assertEquals(listOf("start", "list", "list", "list", "clean"), calls.map { it.first })
        assertEquals(listOf("0", "0", "500"), calls.filter { it.first == "list" }.map { it.second["offset"] })
    }

    @Test fun `重复路径去重不改变下一页原始偏移`() = runTest {
        val offsets = mutableListOf<String?>()
        val first = (0 until 499).map { file(it) } + file(0)
        val responses = ArrayDeque(listOf(start, page(first, 501), page(listOf(file(500)), 501, 500), empty))
        val result = DsmFileSearchRepository({ method, parameters -> if (method == "list") offsets += parameters["offset"]; responses.removeFirst() }).search(normal)
        assertEquals(listOf("0", "500"), offsets); assertEquals(500, result.page.items.size)
        assertEquals("/synthetic/500.txt", result.page.items.last().path)
    }

    @Test fun `完成后仍缺页不得返回已有的部分结果`() = runTest {
        val calls = mutableListOf<String>()
        val responses = ArrayDeque(listOf(start, page(listOf(file(0)), 2), page(emptyList(), 2, 1), empty, empty))
        val failure = runCatching { DsmFileSearchRepository({ method, _ -> calls += method; responses.removeFirst() }).search(normal) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.FILE_SEARCH_INCOMPLETE, failure.kind)
        assertEquals(listOf("start", "list", "list", "stop", "clean"), calls)
    }

    @Test fun `缺少结束状态总数或文件数组不能冒充空结果`() = runTest {
        for (malformed in listOf("""{"total":0,"files":[]}""", """{"finished":true,"files":[]}""", """{"finished":true,"total":0}""")) {
            val calls = mutableListOf<String>()
            val values = ArrayDeque(listOf(start, data(malformed), empty, empty))
            val failure = runCatching { DsmFileSearchRepository({ method, _ -> calls += method; values.removeFirst() }).search(normal) }.exceptionOrNull() as DsmFailure
            assertEquals(DsmErrorKind.FILE_SEARCH_INCOMPLETE, failure.kind); assertEquals(listOf("start", "list", "stop", "clean"), calls)
        }
    }

    @Test fun `正文索引状态缺失或字符串布尔时拒绝且不降级重搜`() = runTest {
        for (invalid in listOf("", ",\"has_not_index_share\":\"true\"")) {
            val calls = mutableListOf<String>()
            val values = ArrayDeque(listOf(data("{\"taskid\":\"content\"$invalid}"), empty, empty))
            val failure = runCatching { DsmFileSearchRepository({ method, _ -> calls += method; values.removeFirst() }).search(normal.copy(searchesContents = true)) }.exceptionOrNull() as DsmFailure
            assertEquals(DsmErrorKind.FILE_CONTENT_SEARCH_UNAVAILABLE, failure.kind)
            assertEquals(listOf("start", "stop", "clean"), calls)
        }
    }

    @Test fun `正文索引完整与真正零结果分别保留`() = runTest {
        val responses = ArrayDeque(listOf(data("""{"taskid":"content","has_not_index_share":false}"""), page(emptyList()), empty))
        val result = DsmFileSearchRepository({ _, _ -> responses.removeFirst() }).search(normal.copy(searchesContents = true))
        assertTrue(result.page.items.isEmpty()); assertEquals(FileSearchIndexCoverage.COMPLETE, result.indexCoverage)
    }

    @Test fun `取消只停止和清理本次任务`() = runTest {
        val reading = CompletableDeferred<Unit>()
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        val repo = DsmFileSearchRepository({ method, parameters ->
            calls += method to parameters
            when (method) {
                "start" -> start
                "list" -> { reading.complete(Unit); awaitCancellation() }
                else -> empty
            }
        })
        val task = launch { repo.search(normal) }
        reading.await(); task.cancelAndJoin()
        assertEquals(listOf("start", "list", "stop", "clean"), calls.map { it.first })
        assertTrue(calls.drop(1).all { it.second["taskid"] == "synthetic-search" })
    }

    @Test fun `轮询超时会结束并清理而不是永久等待`() = runTest {
        val calls = mutableListOf<String>()
        val repo = DsmFileSearchRepository({ method, _ -> calls += method; when (method) { "start" -> start; "list" -> page(emptyList(), finished = false); else -> empty } }, timeoutMillis = 10, pollDelayMillis = 1)
        val failure = runCatching { repo.search(normal) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.FILE_SEARCH_TIMED_OUT, failure.kind)
        assertEquals(listOf("stop", "clean"), calls.takeLast(2)); assertEquals(1, calls.count { it == "start" })
    }

    @Test fun `权限拒绝保留失败不会返回空搜索结果`() = runTest {
        val denied = DsmFailure(105, "Denied", "", kind = DsmErrorKind.PERMISSION_DENIED)
        val calls = mutableListOf<String>()
        val failure = runCatching { DsmFileSearchRepository({ method, _ -> calls += method; when (method) { "start" -> start; "list" -> throw denied; else -> empty } }).search(normal) }.exceptionOrNull()
        assertSame(denied, failure); assertEquals(listOf("start", "list", "stop", "clean"), calls)
    }

    @Test fun `非法条件不访问NAS`() = runTest {
        val invalid = listOf(normal.copy(folders = emptyList()), normal.copy(folders = listOf("/a/../b")), normal.copy(minimumBytes = 2, maximumBytes = 1), normal.copy(modified = FileSearchTimeRange(2, 1)), normal.copy(name = " ", searchesContents = true))
        invalid.forEach { value ->
            val failure = runCatching { DsmFileSearchRepository({ _, _ -> error("非法条件不能请求") }).search(value) }.exceptionOrNull() as DsmFailure
            assertEquals(DsmErrorKind.FILE_SEARCH_INVALID_CONDITIONS, failure.kind)
        }
    }

    @Test fun `正则通过真实适配器查询所有名称并仅保留命中文件及原路径`() = runBlocking {
        val requests = mutableListOf<Request>()
        val repo = repository(requests, ArrayDeque(listOf(start, page(listOf(file(1, "REPORT.pdf"), file(2, "report.txt"), file(3, "Other.pdf"))), empty)))
        val result = repo.searchWithReport(normal.copy(name = "/^report\\.pdf$/i", recursive = false, extension = "pdf", minimumBytes = 10))
        assertEquals(listOf("/synthetic/1.txt"), result.page.items.map { it.path })
        assertEquals(1, result.page.total); assertEquals(0, result.page.offset)
        val fields = fields(requests.first())
        assertEquals("*", fields["pattern"]); assertEquals("false", fields["recursive"])
        assertEquals("pdf", fields["extension"]); assertEquals("10", fields["size_from"])
        assertFalse(fields.containsKey("search_content"))
        assertEquals(listOf("start", "list", "clean"), requests.map { fields(it)["method"] })
    }

    @Test fun `正则读取完整分页后才筛选不会丢掉末页命中`() = runTest {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        val responses = ArrayDeque(listOf(start, page((0 until 500).map { file(it) }, 501), page(listOf(file(500, "报告.pdf")), 501, 500), empty))
        val result = DsmFileSearchRepository({ method, parameters -> calls += method to parameters; responses.removeFirst() }).search(normal.copy(name = "/报告/"))
        assertEquals(listOf("报告.pdf"), result.page.items.map { it.name }); assertEquals(1, result.page.total)
        assertEquals(listOf("0", "500"), calls.filter { it.first == "list" }.map { it.second["offset"] })
    }

    @Test fun `有效正则没有匹配时返回真实零结果`() = runTest {
        val responses = ArrayDeque(listOf(start, page(listOf(file(1, "REPORT.pdf"))), empty))
        val result = DsmFileSearchRepository({ _, _ -> responses.removeFirst() }).search(normal.copy(name = "/report/"))
        assertEquals(0, result.page.total); assertTrue(result.page.items.isEmpty())
    }

    @Test fun `无效正则及正文正则组合在NAS请求前拒绝`() = runTest {
        val invalid = listOf(normal.copy(name = "/[/") to DsmErrorKind.FILE_SEARCH_INVALID_REGEX,
            normal.copy(name = "/report/i", searchesContents = true) to DsmErrorKind.FILE_CONTENT_SEARCH_REGEX)
        invalid.forEach { (request, kind) ->
            val failure = runCatching { DsmFileSearchRepository({ _, _ -> error("不能发送请求") }).search(request) }.exceptionOrNull() as DsmFailure
            assertEquals(kind, failure.kind)
        }
    }

    private fun repository(requests: MutableList<Request>, responses: ArrayDeque<JsonObject>, maximumVersion: Int = 2): DsmRepository {
        val api = DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request(); requests += request
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body("{\"success\":true,\"data\":${responses.removeFirst()}}".toResponseBody("application/json".toMediaType())).build()
        }.build())
        return authorizedRepository(NasProfile("search", "NAS", "https://synthetic.example.invalid", "synthetic"), DsmSession("search", "synthetic-session", "synthetic-token"), api,
            mapOf("SYNO.FileStation.Search" to ApiCapability("SYNO.FileStation.Search", "entry.cgi", 1, maximumVersion)))
    }
    private fun fields(request: Request) = (request.body as FormBody).let { form -> (0 until form.size).associate { form.name(it) to form.value(it) } }
}
