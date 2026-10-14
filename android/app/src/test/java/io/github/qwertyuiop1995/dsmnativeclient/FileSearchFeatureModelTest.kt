package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class FileSearchFeatureModelTest {
    private val profile = NasProfile("search-model", "NAS", "https://synthetic.example.invalid", "synthetic")
    private var current = WorkspaceState(profile, selectedModule = Module.FILES, fileBrowser = FileBrowserState(path = "/share", searchQuery = "name"))
    private val requests = mutableListOf<Map<String, String>>()
    private var response: (Map<String, String>) -> String = { fields ->
        when (fields["method"]) {
            "list_share" -> """{"shares":[{"path":"/share","name":"share","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}],"total":1,"offset":0}"""
            "list" -> """{"files":[{"path":"/share/sub","name":"sub","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}],"total":1,"offset":0}"""
            else -> error("Unexpected synthetic method")
        }
    }
    private val repository = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val form = request.body as FormBody
            val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
            synchronized(requests) { requests += fields }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body("{\"success\":true,\"data\":${response(fields)}}".toResponseBody("application/json".toMediaType())).build()
        }.build()), listOf("SYNO.FileStation.List", "SYNO.FileStation.Search").associateWith { ApiCapability(it, "entry.cgi", 1, 2) })
    private var activeRepository: DsmRepository? = repository
    private var submissions = 0
    private fun feature(scope: CoroutineScope) = FileSearchFeatureModel(scope, { activeRepository }, { current },
        { current = current.copy(fileBrowser = it) }) { current = current.copy(fileBrowser = it); submissions++ }

    @Test fun `编辑草稿不请求NAS且关闭不修改已应用条件`() = runTest {
        val feature = feature(this); feature.open()
        feature.edit { it.copy(request = it.request.copy(searchesContents = true, extension = "pdf")) }
        assertNull(current.fileBrowser.searchRequest); assertEquals(0, submissions)
        feature.close(); assertFalse(feature.editor.value.visible); assertTrue(requests.isEmpty())
        feature.open(); assertFalse(feature.editor.value.draft.request.searchesContents)
    }

    @Test fun `应用全部条件保留工作区原目录而重置只改变草稿`() = runTest {
        val feature = feature(this); feature.open()
        feature.edit { it.copy(request = it.request.copy(folders = listOf("/share", "/other"), searchesContents = true, owner = "owner"), minimumSize = "1.5", sizeUnit = FileSearchSizeUnit.MIB) }
        feature.apply()
        assertEquals("/share", current.fileBrowser.path)
        assertEquals(1_572_864L, current.fileBrowser.searchRequest?.minimumBytes)
        assertEquals(listOf("/share", "/other"), current.fileBrowser.searchRequest?.folders)
        assertEquals(1, submissions); assertFalse(feature.editor.value.visible)
        feature.open(); feature.reset()
        assertTrue(requireNotNull(current.fileBrowser.searchRequest).searchesContents)
        assertFalse(feature.editor.value.draft.request.searchesContents)
    }

    @Test fun `高级类型和既有类型筛选保持同一条件不会隐藏有效结果`() = runTest {
        current = current.copy(fileBrowser = current.fileBrowser.copy(typeFilter = FileTypeFilter.FOLDERS))
        val feature = feature(this); feature.open()
        assertEquals(FileSearchKind.DIRECTORY, feature.editor.value.draft.request.kind)
        feature.edit { it.copy(request = it.request.copy(kind = FileSearchKind.FILE)) }; feature.apply()
        assertEquals(FileTypeFilter.FILES, current.fileBrowser.typeFilter)
        assertEquals(FileSearchKind.FILE, current.fileBrowser.searchRequest?.kind)
        val changed = current.fileBrowser.changeFilter(FileTypeFilter.ALL)
        assertEquals(FileSearchKind.ALL, changed.searchRequest?.kind)
        assertEquals(FileTypeFilter.ALL, changed.typeFilter)
    }

    @Test fun `关键词编辑不执行请求清空搜索才恢复目录`() = runTest {
        val feature = feature(this)
        feature.updateQuery("new draft"); assertEquals(0, submissions)
        feature.submitQuery(); assertEquals("new draft", current.fileBrowser.activeSearchQuery); assertEquals(1, submissions)
        feature.clearSearch(); assertNull(current.fileBrowser.activeSearchQuery); assertNull(current.fileBrowser.searchRequest); assertEquals("/share", current.fileBrowser.path)
    }

    @Test fun `更换Repository后旧面板不能应用到新连接`() = runTest {
        val feature = feature(this); feature.open(); feature.edit { it.copy(request = it.request.copy(name = "old")) }
        activeRepository = null; feature.apply()
        assertEquals(0, submissions); assertEquals("name", current.fileBrowser.searchQuery); assertFalse(feature.editor.value.visible)
    }

    @Test fun `大小转换拒绝负数溢出非数字与反向区间`() {
        val request = FileSearchRequest(listOf("/share"))
        assertEquals(1_572_864L, FileSearchDraft(request, "1.5", "", FileSearchSizeUnit.MIB).resolved()?.minimumBytes)
        for (invalid in listOf("-1", "NaN", "1e5", "9223372036854775808")) assertNull(FileSearchDraft(request, invalid).resolved())
        assertNull(FileSearchDraft(request, "3", "2").resolved())
        assertNull(FileSearchDraft(request.copy(modified = FileSearchTimeRange(5, 4))).resolved())
        assertNull(FileSearchDraft(request.copy(searchesContents = true)).resolved())
        assertEquals(0L, FileSearchDraft(request, "0").resolved()?.minimumBytes)
    }

    @Test fun `目录选择来自真实仓储并且筛选不发额外请求`() = runBlocking {
        val feature = feature(this); feature.open(); feature.openLocations()
        withTimeout(5_000) { while (feature.editor.value.locations !is Loadable.Ready) delay(10) }
        val share = (feature.editor.value.locations as Loadable.Ready).value.single()
        feature.filterLocations("not found"); assertEquals(1, requests.size)
        feature.enterLocation(share)
        withTimeout(5_000) { while (feature.editor.value.locations !is Loadable.Ready) delay(10) }
        feature.addLocation()
        assertEquals(listOf("/share"), feature.editor.value.draft.request.folders)
        assertFalse(feature.editor.value.locationsVisible); assertEquals(0, submissions)
        assertEquals(listOf("list_share", "list"), requests.map { it["method"] })
    }

    @Test fun `范围分页返回旧偏移时拒绝不完整的共享范围`() = runBlocking {
        response = { """{"shares":[{"path":"/share","name":"share","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}],"offset":0,"total":2}""" }
        val feature = feature(this); feature.open(); feature.openLocations()
        withTimeout(5_000) { while (feature.editor.value.locations !is Loadable.Failed) delay(10) }
        assertEquals(DsmErrorKind.FILE_SEARCH_INCOMPLETE, (feature.editor.value.locations as Loadable.Failed).error.kind)
        assertEquals(listOf("0", "1"), requests.map { it["offset"] })
        assertEquals(0, submissions)
    }

    @Test fun `根目录无效正则不会枚举共享文件夹`() = runBlocking {
        val failure = runCatching { feature(this).search(repository, FileBrowserState(activeSearchQuery = "/[/")) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.FILE_SEARCH_INVALID_REGEX, failure.kind); assertTrue(requests.isEmpty())
    }

    @Test fun `正则编辑先纠正错误再按原条件提交`() = runTest {
        val feature = feature(this); feature.open()
        feature.edit { it.copy(request = it.request.copy(name = "/[/")) }; feature.apply()
        assertTrue(feature.editor.value.visible); assertEquals(0, submissions)
        feature.edit { it.copy(request = it.request.copy(name = "/report/i", searchesContents = true)) }; feature.apply()
        assertEquals(0, submissions)
        feature.edit { it.copy(request = it.request.copy(searchesContents = false)) }; feature.apply()
        assertEquals(1, submissions); assertEquals("/report/i", current.fileBrowser.activeSearchQuery)
        assertEquals("/report/i", current.fileBrowser.searchRequest?.name); assertTrue(requests.isEmpty())
    }

    @Test fun `根目录普通搜索使用当前账号完整共享范围`() = runBlocking {
        response = { fields -> when (fields["method"]) {
            "list_share" -> """{"shares":[{"path":"/share","name":"share","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}},{"path":"/other","name":"other","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}],"offset":0,"total":2}"""
            "start" -> """{"taskid":"root"}"""
            "list" -> """{"files":[],"finished":true,"total":0,"offset":0}"""
            "clean" -> "{}"
            else -> error("Unexpected method")
        } }
        val result = feature(this).search(repository, FileBrowserState(activeSearchQuery = "term"))
        assertTrue(result.page.items.isEmpty())
        assertEquals("[\"/share\",\"/other\"]", requests.single { it["method"] == "start" }["folder_path"])
    }
}
