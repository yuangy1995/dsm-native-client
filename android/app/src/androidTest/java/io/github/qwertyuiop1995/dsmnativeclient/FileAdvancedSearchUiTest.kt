package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.io.File
import java.io.IOException
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** 实际宿主、文件页、条件面板与原生日期窗口；任何未定义请求失败，不连接 NAS。 */
class FileAdvancedSearchUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val application = ApplicationProvider.getApplicationContext<Application>()
    private val store = SecureProfileStore(application)
    private val previous = store.lastProfileId()
    private val profile = NasProfile("search-ui-${UUID.randomUUID()}", "Search NAS", "https://synthetic.example.invalid", "synthetic")
    private lateinit var model: AppViewModel
    private val requests = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    @Volatile private var mode = "content"
    @Volatile private var folderGate: CountDownLatch? = null
    @Volatile private var folderFailure = false
    private var searchNumber = 0

    @Before fun prepare() {
        val owner = store.commitConnection(store.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic-session"), null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val form = request.body as FormBody
                val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
                requests += fields
                val response = if (fields["api"] == "SYNO.FileStation.Search") searchResponse(fields) else listResponse(fields)
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body("{\"success\":true,\"data\":$response}".toResponseBody("application/json".toMediaType())).build()
            }.build())
            val repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), api,
                listOf("SYNO.FileStation.List", "SYNO.FileStation.Search").associateWith { ApiCapability(it, "entry.cgi", 1, 2) })
            repo.bindOwner(owner) { store.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS,
                fileBrowser = FileBrowserState(path = "/synthetic"), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        awaitText("notes.txt")
    }

    @After fun clean() {
        folderGate?.countDown()
        compose.runOnIdle { model.fileSearch.invalidate(); store.removeProfile(profile.id); store.setLastProfileId(previous) }
    }

    @Test fun `高级条件多目录原生日期与重建后提交保留正文命中`() {
        openEditor()
        compose.onNodeWithTag("file_search_keyword").performTextInput("needle")
        compose.onNodeWithText(text(R.string.file_search_contents)).performClick()
        compose.onNodeWithTag("file_search_add_location").performScrollTo().performClick()
        awaitText("Archive"); compose.onNodeWithText("Archive").performClick()
        compose.waitUntil(10_000) { model.fileSearch.editor.value.locationPath == "/archive" && model.fileSearch.editor.value.locations is Loadable.Ready }
        compose.onNodeWithTag("file_search_choose_location").performClick()
        compose.onNodeWithText(text(R.string.show_files_only)).performScrollTo().performClick()
        compose.onNodeWithTag("file_search_extension").performScrollTo().performTextInput("pdf")
        compose.onNodeWithTag("file_search_minimum").performScrollTo().performTextInput("1.5")
        compose.onNodeWithText(text(R.string.file_search_mib)).performScrollTo().performClick()
        compose.onAllNodesWithText(text(R.string.file_search_after)).onFirst().performScrollTo().performClick()
        clickPlatformPositive(); clickPlatformPositive()
        compose.waitUntil(10_000) { model.fileSearch.editor.value.draft.request.modified.fromEpochSeconds != null }
        capture("search-options")
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("file_search_keyword").performScrollTo().assertTextContains("needle")
        assertEquals(listOf("/synthetic", "/archive"), model.fileSearch.editor.value.draft.request.folders)
        compose.onNodeWithTag("file_search_apply").performScrollTo().performClick()
        awaitText("Annual summary.pdf")
        compose.onNodeWithText(text(R.string.file_search_index_incomplete)).assertIsDisplayed()
        compose.onNodeWithText(application.getString(R.string.file_search_result_location, "/synthetic")).assertIsDisplayed()
        val start = synchronized(requests) { requests.single { it["api"] == "SYNO.FileStation.Search" && it["method"] == "start" } }
        assertEquals("file", start["filetype"]); assertEquals(FileTypeFilter.FILES, model.workspace.value?.fileBrowser?.typeFilter)
        assertEquals("true", start["search_content"]); assertEquals("advance", start["search_type"])
        assertEquals("[\"/synthetic\",\"/archive\"]", start["folder_path"])
        assertEquals("1572864", start["size_from"]); assertEquals("pdf", start["extension"])
        assertNotNull(start["mtime_from"])
        capture("search-content-results")
        compose.onNodeWithContentDescription(text(R.string.client_file_options)).performClick()
        compose.onNodeWithText(text(R.string.switch_to_grid)).performScrollTo().performClick()
        compose.onNodeWithText(application.getString(R.string.file_search_result_location, "/synthetic")).assertIsDisplayed()
        assertEquals(1, searchCalls().count { it["method"] == "start" })
        capture("search-content-grid")
    }

    @Test fun `搜索等待期间取消会返回目录且只清理原任务`() {
        mode = "waiting"; submit("slow")
        try { compose.waitUntil(10_000) { searchCalls().any { it["method"] == "list" } } } catch (failure: Throwable) {
            capture("search-not-started")
            throw AssertionError("方法=${searchCalls().map { it["method"] }} 页面=${model.workspace.value?.selectedModule} 查询=${model.workspace.value?.fileBrowser?.activeSearchQuery} 面板=${model.fileSearch.editor.value.visible} 状态=${model.workspace.value?.files}", failure)
        }
        compose.onNodeWithText(text(R.string.file_search_cancel)).assertIsDisplayed().performClick()
        awaitText("notes.txt")
        compose.waitUntil(10_000) { searchCalls().any { it["method"] == "clean" } }
        assertEquals(listOf("search-1"), searchCalls().filter { it["method"] == "stop" }.map { it["taskid"] })
        assertNull(model.workspace.value?.fileBrowser?.activeSearchQuery)
        mode = "content"; submit("new")
        awaitText("Annual summary.pdf")
        assertEquals(2, searchCalls().count { it["method"] == "start" })
        assertEquals(listOf("search-1"), searchCalls().filter { it["method"] == "stop" }.map { it["taskid"] })
    }

    @Test fun `网络错误有重试路径而真实空结果显示调整条件`() {
        mode = "failure"; submit("term")
        compose.waitUntil(10_000) { model.workspace.value?.files is Loadable.Failed }
        compose.onNodeWithText(text(R.string.no_file_search_results)).assertDoesNotExist()
        capture("search-error")
        mode = "empty"
        compose.onNodeWithText(text(R.string.retry)).performClick()
        awaitText(text(R.string.no_file_search_results))
        compose.onNodeWithText(text(R.string.file_search_index_incomplete)).assertDoesNotExist()
        capture("search-empty")
    }

    @Test fun `目录选择覆盖加载筛选空和真实空文件夹`() {
        openEditor(); folderGate = CountDownLatch(1)
        compose.onNodeWithTag("file_search_add_location").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.fileSearch.editor.value.locations is Loadable.Loading }
        compose.onNodeWithContentDescription(text(R.string.loading)).assertExists()
        capture("search-folders-loading")
        folderGate?.countDown(); awaitText("Archive")
        compose.onNodeWithText(text(R.string.file_search_filter_folders)).performTextInput("no match")
        awaitText(text(R.string.no_items_match_filter)); capture("search-folders-filtered-empty")
        compose.onNode(hasSetTextAction()).performTextClearance()
        compose.onNodeWithText("Archive").performClick()
        awaitText(text(R.string.file_search_no_folders))
        compose.onNodeWithTag("file_search_choose_location").assertIsEnabled()
        capture("search-folders-empty")
    }

    @Test fun `无效条件阻止提交且目录读取失败可以重试`() {
        openEditor()
        compose.onNodeWithTag("file_search_minimum").performScrollTo().performTextInput("3")
        compose.onNodeWithTag("file_search_maximum").performScrollTo().performTextInput("2")
        compose.onNodeWithTag("file_search_apply").performScrollTo().assertIsNotEnabled()
        assertTrue(searchCalls().isEmpty())
        compose.onNodeWithTag("file_search_maximum").performScrollTo().performTextReplacement("4")
        compose.onNodeWithTag("file_search_apply").performScrollTo().assertIsEnabled()
        folderFailure = true
        compose.onNodeWithTag("file_search_add_location").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.fileSearch.editor.value.locations is Loadable.Failed }
        capture("search-folders-error")
        folderFailure = false
        compose.onNodeWithText(text(R.string.retry)).performClick()
        awaitText("Archive")
    }

    @Test fun `正文缺少索引状态时显示不可用而不是文件名空结果`() {
        mode = "missing-index"; openEditor()
        compose.onNodeWithTag("file_search_keyword").performTextInput("needle")
        compose.onNodeWithText(text(R.string.file_search_contents)).performClick()
        compose.onNodeWithTag("file_search_apply").performScrollTo().performClick()
        awaitText(text(R.string.file_search_content_unavailable))
        assertEquals(1, searchCalls().count { it["method"] == "start" })
        assertEquals(0, searchCalls().count { it["method"] == "list" })
        compose.onNodeWithText(text(R.string.no_file_search_results)).assertDoesNotExist()
    }

    @Test fun regexSearchFiltersNativeResultsAndKeepsOriginalQuery() {
        mode = "regex"; submit("/^résumé\\.pdf$/i")
        awaitText("RÉSUMÉ.PDF")
        compose.onNodeWithText("unrelated.txt").assertDoesNotExist()
        assertEquals("*", searchCalls().single { it["method"] == "start" }["pattern"])
        compose.onNodeWithTag("file_search_query").assertTextContains("/^résumé\\.pdf$/i")
        capture("search-regex-results")
        compose.onNodeWithTag("file_search_query").performTextReplacement("/^résumé\\.pdf$/")
        compose.onNodeWithTag("file_search_query").performImeAction()
        awaitText(text(R.string.no_file_search_results))
        assertEquals(2, searchCalls().count { it["method"] == "start" })
        assertEquals(0, (model.workspace.value?.files as Loadable.Ready).value.total)
        capture("search-regex-empty")
    }

    @Test fun regexErrorsAreActionableAndRejectRequestsUntilCorrected() {
        mode = "regex"; openEditor()
        compose.onNodeWithTag("file_search_keyword").performTextReplacement("/[/")
        compose.onNodeWithText(text(R.string.file_search_invalid_regex), substring = true).assertExists()
        compose.onNodeWithTag("file_search_apply").performScrollTo().assertIsNotEnabled()
        assertTrue(searchCalls().isEmpty())
        compose.onNodeWithTag("file_search_keyword").performScrollTo().performTextReplacement("/résumé/i")
        compose.onNodeWithText(text(R.string.file_search_contents)).performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.file_search_content_regex), substring = true).assertExists()
        capture("search-regex-content-error")
        compose.onNodeWithTag("file_search_apply").performScrollTo().assertIsNotEnabled()
        assertTrue(searchCalls().isEmpty())
        compose.onNodeWithText(text(R.string.file_search_contents)).performScrollTo().performClick()
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        compose.onNodeWithTag("file_search_apply").performScrollTo().assertIsEnabled().performClick()
        awaitText("RÉSUMÉ.PDF")
        assertEquals(1, searchCalls().count { it["method"] == "start" })
    }

    private fun openEditor() {
        compose.onNodeWithContentDescription(text(R.string.client_file_options)).performClick()
        compose.onNodeWithText(text(R.string.file_search_advanced)).performClick()
        compose.onNodeWithTag("file_search_keyword").assertExists()
    }
    private fun submit(query: String) {
        openEditor(); compose.onNodeWithTag("file_search_keyword").performTextReplacement(query)
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        compose.onNodeWithTag("file_search_apply").performScrollTo().assertIsEnabled().performClick()
        compose.waitUntil(10_000) { !model.fileSearch.editor.value.visible }
        assertEquals(query, model.workspace.value?.fileBrowser?.activeSearchQuery)
    }
    private fun searchCalls() = synchronized(requests) { requests.filter { it["api"] == "SYNO.FileStation.Search" } }
    private fun text(resource: Int) = application.getString(resource)
    private fun awaitText(value: String) { compose.waitUntil(10_000) { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() } }
    private fun listResponse(fields: Map<String, String>): String = when (fields["method"]) {
        "getinfo" -> """{"files":[{"path":"/synthetic","name":"Shared files","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}]}"""
        "list_share" -> { if (folderFailure) throw IOException("Synthetic folder read failed"); check(folderGate?.await(5, TimeUnit.SECONDS) != false); """{"shares":[{"path":"/synthetic","name":"Shared files","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}},{"path":"/archive","name":"Archive","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}],"total":2,"offset":0}""" }
        "list" -> if (fields["filetype"] == "dir") """{"files":[],"total":0,"offset":0}"""
            else """{"files":[{"path":"/synthetic/notes.txt","name":"notes.txt","isdir":false,"size":8}],"total":1,"offset":0}"""
        else -> error("Unexpected synthetic file request")
    }
    private fun searchResponse(fields: Map<String, String>): String = when (fields["method"]) {
        "start" -> { searchNumber++; if (mode == "missing-index") """{"taskid":"search-$searchNumber"}""" else """{"taskid":"search-$searchNumber","has_not_index_share":true}""" }
        "list" -> when (mode) {
            "failure" -> throw IOException("Synthetic connection failure")
            "waiting" -> """{"finished":false,"files":[],"total":0,"offset":0}"""
            "empty" -> """{"finished":true,"files":[],"total":0,"offset":0}"""
            "regex" -> """{"finished":true,"files":[{"path":"/synthetic/one.pdf","name":"RÉSUMÉ.PDF","isdir":false,"size":100},{"path":"/synthetic/two.txt","name":"unrelated.txt","isdir":false,"size":50}],"total":2,"offset":0}"""
            else -> """{"finished":true,"files":[{"path":"/synthetic/summary.pdf","name":"Annual summary.pdf","isdir":false,"size":2097152}],"total":1,"offset":0}"""
        }
        "stop", "clean" -> "{}"
        else -> error("Unexpected synthetic search request")
    }
    private fun clickPlatformPositive() {
        var button: AccessibilityNodeInfo? = null
        compose.waitUntil(10_000) {
            button = InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.findAccessibilityNodeInfosByViewId("android:id/button1")?.firstOrNull()
            button != null
        }
        val previousWindow = requireNotNull(button).windowId
        assertTrue(requireNotNull(button).performAction(AccessibilityNodeInfo.ACTION_CLICK))
        compose.waitUntil(10_000) { InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.windowId?.let { it != previousWindow } == true }
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        InstrumentationRegistry.getInstrumentation().uiAutomation.waitForIdle(250, 3_000)
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val output = File(application.getExternalFilesDir(null), "file-search-review/$name.png")
        output.parentFile?.mkdirs(); output.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
