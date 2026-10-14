package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.downloads.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch

/** 真实页面驱动工作区模型和受保护记录，不替换产品的提交或结果处理。 */
class DownloadWorkspaceUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("downloads-ui-" + UUID.randomUUID(), "Synthetic Downloads NAS", "https://synthetic.example.invalid", "synthetic")
    private val fixture = DownloadWorkspaceFixture()
    private lateinit var model: AppViewModel
    private lateinit var owner: WorkspaceOwner

    @Before fun prepare() {
        val session = DsmSession(profile.id, "synthetic-session")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val access = WorkspaceAccessReader(fixture.capabilities,
                { DesktopAppPrivileges(mapOf(DesktopApplication.DOWNLOADS to true, DesktopApplication.FILES to true), false) },
                { error("Unexpected synthetic fallback") }, {})
            val repo = DsmRepository(profile, session, fixture.api, fixture.capabilities, access)
            runBlocking { repo.refreshAccess() }; repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS,
                supportsDownloadSettings = true, supportsDownloadSchedule = true, supportsDownloadTaskDestinationEditing = true,
                supportsDownloadRss = true, supportsDownloadBtSearch = true))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.DOWNLOADS))
        }
        awaitText("Synthetic alpha")
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") == "true") {
            val c = compose.activity.resources.configuration
            File(app.getExternalFilesDir(null), "download-review/configuration.txt").also { it.parentFile?.mkdirs() }
                .writeText("locales=${c.locales.toLanguageTags()}\nfontScale=${c.fontScale}\nuiMode=${c.uiMode}\nwidthDp=${c.screenWidthDp}\nheightDp=${c.screenHeightDp}\n")
        }
    }
    @After fun clean() {
        fixture.detailsGate?.countDown()
        if (::model.isInitialized) compose.runOnIdle { model.downloadCreation.clear(); model.downloadActions.clear() }
        compose.waitForIdle()
        DownloadActionStore(app).removeProfile(profile.id)
        profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
    }

    @Test fun linkAcceptanceAndUnknownRestoreNeverResend() {
        openCreate()
        field(R.string.url_or_magnet).performTextInput("https://download.example.invalid/accepted.iso")
        click(R.string.create_task)
        awaitRecords { it.singleOrNull()?.steps?.singleOrNull()?.phase == DownloadActionPhase.COMPLETED }
        compose.onNodeWithText(text(R.string.download_action_accepted)).assertIsDisplayed()
        assertEquals("3", fixture.writes("create").single()["version"])
        capture("download-create-accepted"); back()
        fixture.loseCreationReceipt = true
        openCreate(); field(R.string.url_or_magnet).performTextInput("https://download.example.invalid/unknown.iso")
        click(R.string.create_task)
        awaitRecords { it.size == 2 && it.any { record -> record.steps.single().phase == DownloadActionPhase.SUBMITTED } }
        compose.runOnIdle { model.downloadActions.clear(); model.downloadActions.show() }
        awaitRecords { it.size == 2 }
        click(R.string.refresh)
        awaitRecords { it.any { record -> record.steps.single().phase == DownloadActionPhase.SUBMITTED } }
        compose.onNodeWithText(text(R.string.download_action_unknown_creation)).performScrollTo().assertIsDisplayed()
        assertEquals(2, fixture.writes("create").size)
        capture("download-create-unknown-restored")
    }

    @Test fun taskFileSelectionStagesPasswordAndRequiresExplicitSubmit() {
        openCreate()
        val bytes = "d4:infod4:name4:testee".encodeToByteArray()
        // 输入沿用系统选择后的正式私有复制流程；本用例不替代系统文档提供者验收。
        compose.runOnIdle { assertTrue(model.downloadCreation.chooseFile { UploadSource("synthetic.torrent",
            "application/x-bittorrent", bytes.size.toLong(), { ByteArrayInputStream(bytes) }) }) }
        awaitText("synthetic.torrent")
        assertTrue(fixture.writes("create").isEmpty())
        field(R.string.download_creation_password).performTextInput("  synthetic password  ")
        capture("download-file-staged"); click(R.string.create_task)
        awaitRecords { it.singleOrNull()?.terminal == true }
        assertEquals("  synthetic password  ", fixture.writes("create").single()["unzip_password"])
        assertEquals("1", fixture.writes("create").single()["version"])
        assertFalse(kotlinx.serialization.json.Json.encodeToString(DownloadActionRecord.serializer(), DownloadActionStore(app).records(owner).single()).contains("synthetic password"))
        assertFalse(model.downloadCreation.state.value.visible)
    }

    @Test fun batchUnknownStopsAndRestoresBeforeExplicitContinue() {
        fixture.ignorePause = true
        compose.onNodeWithText("Synthetic alpha").performTouchInput { longClick() }
        compose.onNodeWithText("Synthetic beta").performClick()
        click(R.string.pause)
        awaitRecords { it.singleOrNull()?.steps?.map { step -> step.phase } == listOf(DownloadActionPhase.SUBMITTED, DownloadActionPhase.READY) }
        compose.onNodeWithText(text(R.string.download_action_continue)).performScrollTo().assertIsNotEnabled()
        assertEquals(listOf("a"), fixture.writes("pause").map { it["id"] })
        fixture.pauseFirst(); fixture.ignorePause = false
        compose.runOnIdle { model.downloadActions.clear(); model.downloadActions.show() }
        awaitRecords { it.singleOrNull()?.steps?.size == 2 }
        assertEquals(1, fixture.writes("pause").size)
        click(R.string.refresh)
        awaitRecords { it.singleOrNull()?.steps?.first()?.phase == DownloadActionPhase.COMPLETED }
        capture("download-batch-remaining"); click(R.string.download_action_continue)
        awaitRecords { it.singleOrNull()?.terminal == true }
        assertEquals(listOf("a", "b"), fixture.writes("pause").map { it["id"] })
    }

    @Test fun removeConfirmationCancelAndEndMoveUseTaskOnlyResult() {
        taskOptions("Synthetic alpha", R.string.remove_task_and_files)
        compose.onNodeWithText(text(R.string.download_delete_files_risk_summary)).assertIsDisplayed()
        assertTrue(fixture.writes("delete").isEmpty())
        capture("download-end-confirmation"); click(R.string.cancel)
        assertTrue(fixture.writes("delete").isEmpty())
        taskOptions("Synthetic alpha", R.string.remove_task_and_files); click(R.string.confirm_remove_task_and_files)
        awaitRecords { it.singleOrNull()?.terminal == true }
        assertEquals("true", fixture.writes("delete").single()["force_complete"])
        assertEquals(1, model.downloadActions.state.value.records.single().steps.size)
        compose.onNodeWithText(text(R.string.download_delete_files_verification_notice)).assertIsDisplayed()
    }

    @Test fun settingsSaveOnlyChangedFieldsAndRespectManager() {
        options(R.string.download_settings_title)
        awaitText(text(R.string.download_default_folder))
        field(R.string.download_http_ftp_limit).performScrollTo().performTextReplacement("240")
        click(R.string.download_schedule_enabled)
        compose.onNodeWithText(text(R.string.download_schedule_enabled)).assertIsOn()
        compose.runOnIdle {
            assertTrue(model.workspace.value!!.downloadSettingsState.draft!!.scheduleEnabled)
            assertEquals("240", model.workspace.value!!.downloadSettingsState.draft!!.httpDownload)
        }
        capture("download-settings-before-save")
        click(R.string.save_changes)
        awaitRecords { it.singleOrNull()?.terminal == true }
        val write = fixture.writes("setserverconfig").single()
        assertEquals("240", write["http_max_download"]); assertEquals("240", write["ftp_max_download"])
        assertFalse("bt_max_download" in write); assertFalse("default_destination" in write)
        assertEquals("true", fixture.writes("setconfig").single()["enabled"])
        capture("download-settings-results"); back()
        fixture.manager = false
        options(R.string.download_settings_title); awaitText(text(R.string.download_settings_read_only))
        compose.onNodeWithText(text(R.string.download_default_folder)).assertIsNotEnabled()
        compose.onNodeWithText(text(R.string.save_changes)).performScrollTo().assertIsNotEnabled()
        capture("download-settings-read-only")
    }

    @Test fun destinationSelectionWritesV2AndReadsActualLocation() {
        taskOptions("Synthetic alpha", R.string.change_download_destination)
        awaitText("incoming")
        assertTrue(fixture.writes("edit").isEmpty())
        click(R.string.open)
        awaitText(text(R.string.no_subfolders))
        compose.onNodeWithText(text(R.string.use_this_folder)).assertIsEnabled()
        capture("download-destination-selection")
        click(R.string.use_this_folder)
        awaitRecords { it.singleOrNull()?.steps?.singleOrNull()?.phase == DownloadActionPhase.COMPLETED }
        val write = fixture.writes("edit").single()
        assertEquals("a", write["id"]); assertEquals("2", write["version"]); assertEquals("incoming", write["destination"])
        assertTrue(fixture.calls.any { it["api"] == "SYNO.FileStation.List" && it["method"] == "getinfo" })
        capture("download-destination-result")
    }

    @Test fun detailsLoadingErrorRetryAndTrackerOrigin() {
        fixture.detailsGate = CountDownLatch(1)
        compose.onNodeWithText("Synthetic alpha").performClick()
        awaitText(text(R.string.download_details_loading)); capture("download-details-loading")
        fixture.failDetails = true; fixture.detailsGate!!.countDown(); fixture.detailsGate = null
        awaitText(text(R.string.retry)); capture("download-details-error")
        fixture.failDetails = false; click(R.string.retry)
        awaitText(text(R.string.download_detail_files)); clickDetails(R.string.download_detail_files)
        awaitText("synthetic.bin"); clickDetails(R.string.download_detail_trackers)
        awaitText("https://tracker.example.invalid")
        compose.onNodeWithText("secret", substring = true).assertDoesNotExist()
        compose.onNodeWithText("announce", substring = true).assertDoesNotExist()
        capture("download-details-trackers")
    }

    @Test fun rssRefreshAndBtResultsEnterSameUnsubmittedForm() {
        options(R.string.download_discovery); awaitText("Synthetic subscription")
        compose.onNodeWithText("Synthetic subscription").performClick(); awaitText("Synthetic RSS item")
        click(R.string.download_rss_refresh)
        awaitRecords { it.singleOrNull()?.terminal == true }
        assertEquals("6", fixture.writes("refresh").single()["id"]); back()
        compose.onNodeWithContentDescription(text(R.string.download_discovery_create_task)).performClick()
        awaitText(text(R.string.url_or_magnet)); assertTrue(fixture.writes("create").isEmpty())
        field(R.string.url_or_magnet).assertTextContains("https://download.example.invalid/rss.torrent")
        capture("download-rss-create-form"); back()
        options(R.string.download_discovery); click(R.string.download_discovery_bt_search)
        field(R.string.download_bt_keyword).performTextInput("synthetic")
        click(R.string.download_bt_search_action); awaitText("Synthetic BT item")
        assertEquals("synthetic-search", fixture.writes("clean").single()["taskid"])
        compose.onNodeWithContentDescription(text(R.string.download_discovery_create_task)).performClick()
        awaitText(text(R.string.url_or_magnet)); field(R.string.url_or_magnet).assertTextContains("magnet:?xt=urn:btih:synthetic")
        assertTrue(fixture.writes("create").isEmpty()); capture("download-bt-create-form")
    }

    private fun text(id: Int) = compose.activity.getString(id)
    private fun field(id: Int) = compose.onNode(hasText(text(id)) and hasSetTextAction())
    private fun click(id: Int) {
        val node = compose.onNodeWithText(text(id), substring = false)
        var parent = node.fetchSemanticsNode().parent
        var scrollable = false
        while (parent != null) { if (parent.config.contains(SemanticsActions.ScrollBy)) scrollable = true; parent = parent.parent }
        if (scrollable) node.performScrollTo()
        node.assertIsDisplayed().performClick()
    }
    private fun back() = compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick()
    private fun clickDetails(id: Int) = compose.onNode(hasText(text(id)) and hasAnyAncestor(hasTestTag("download_details"))).performClick()
    private fun awaitText(value: String) { compose.waitUntil(10_000) { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() } }
    private fun openCreate() { compose.onNodeWithContentDescription(text(R.string.add_download)).performClick(); awaitText(text(R.string.url_or_magnet)) }
    private fun options(id: Int) { compose.onNodeWithContentDescription(text(R.string.download_settings_title)).performClick(); click(id) }
    private fun taskOptions(title: String, id: Int) {
        compose.onNodeWithContentDescription(compose.activity.getString(R.string.download_task_action_description, text(R.string.task_actions), title)).performClick(); click(id)
    }
    private fun awaitRecords(predicate: (List<DownloadActionRecord>) -> Boolean) {
        compose.waitUntil(10_000) { model.downloadActions.state.value.let { it.busy.isEmpty() && !it.restoring && predicate(it.records) } }
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val file = File(app.getExternalFilesDir(null), "download-review/$name.png")
        file.parentFile?.mkdirs(); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
