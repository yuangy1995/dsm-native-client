package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.api
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 原生页面 → 真实模型 → 加密活动记录 → 正式请求编码；仅响应端使用合成数据。 */
class NasWorkspaceUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("nas-ui-" + UUID.randomUUID(), "Synthetic NAS", "https://synthetic.example.invalid", "Current")
    private val fixture = NasWorkspaceFixture()
    private lateinit var model: AppViewModel
    private lateinit var owner: WorkspaceOwner

    @Before fun prepare() {
        val session = DsmSession(profile.id, "synthetic-session")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val access = WorkspaceAccessReader(fixture.capabilities,
                { DesktopAppPrivileges(DesktopApplication.entries.associateWith { true }, fixture.admin) },
                { error("Unexpected file access fallback") }, {})
            val repo = DsmRepository(profile, session, fixture.api, fixture.capabilities, access)
            runBlocking { repo.refreshAccess() }; repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.NAS_SETTINGS))
            model.selectNasSettingsTab(NasSettingsTab.SERVICES)
        }
        await { model.workspace.value?.nasSettings is Loadable.Ready }
        awaitText(text(R.string.remote_terminal))
        await { model.nasServices.state.value.values.none { it.busy } }
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") == "true") {
            val c = compose.activity.resources.configuration
            File(app.getExternalFilesDir(null), "nas-review/configuration.txt").also { it.parentFile?.mkdirs() }
                .writeText("locales=${c.locales.toLanguageTags()}\nfontScale=${c.fontScale}\nuiMode=${c.uiMode}\nwidthDp=${c.screenWidthDp}\nheightDp=${c.screenHeightDp}\n")
        }
    }
    @After fun clean() {
        if (::model.isInitialized) compose.runOnIdle {
            model.nasServices.clear(); model.nasRegion.clear(); model.nasDirectory.clear(); model.nasScheduledTasks.clear()
            model.packageCenter.clear(); model.nasPower.clear(); model.nasConnections.clear(); model.nasSmart.clear(); model.nasDdns.clear(); model.nasObservation.clear()
        }
        compose.waitForIdle()
        NasServiceActivityStore(app).removeProfile(profile.id); NasRegionActivityStore(app).removeProfile(profile.id)
        NasDirectoryActivityStore(app).removeProfile(profile.id); NasTaskActivityStore(app).removeProfile(profile.id)
        PackageActivityStore(app).removeProfile(profile.id); NasPowerActivityStore(app).removeProfile(profile.id)
        profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
    }

    @Test fun terminalCancelSaveAndUnknownRecoveryNeverResend() {
        editRow(R.string.remote_terminal); click(R.string.ssh_service); click(R.string.continue_action)
        capture("terminal-confirmation"); click(R.string.cancel)
        assertTrue(fixture.writes.isEmpty())
        click(R.string.continue_action); click(R.string.save)
        awaitService(NasServiceKind.TERMINAL)
        assertEquals(listOf(NasServiceStep.TERMINAL.api), fixture.writes.map { it.api })
        assertEquals(JsonPrimitive(true), fixture.writes.single().parameters["enable_ssh"])
        capture("terminal-saved"); click(R.string.done)
        fixture.loseTerminalReceipt = true
        editRow(R.string.remote_terminal); click(R.string.ssh_service); click(R.string.continue_action); click(R.string.save)
        await { model.nasServices.state.value.getValue(NasServiceKind.TERMINAL).let { !it.busy && it.record != null } }
        assertTrue(model.nasServices.state.value.getValue(NasServiceKind.TERMINAL).blocked)
        compose.runOnIdle { model.nasServices.clear(); model.nasServices.refresh(NasServiceKind.TERMINAL) }
        await { model.nasServices.state.value.getValue(NasServiceKind.TERMINAL).let { !it.busy && it.record != null } }
        assertTrue(model.nasServices.state.value.getValue(NasServiceKind.TERMINAL).blocked)
        assertEquals(2, fixture.writes.size)
        capture("terminal-unknown-restored")
    }

    @Test fun fileServicesAndProxyUseOnlyChangedGroups() {
        editRow(R.string.file_services); click(R.string.smb_service); click(R.string.continue_action); click(R.string.save)
        awaitService(NasServiceKind.FILES); assertEquals(NasServiceStep.SMB.api, fixture.writes.single().api)
        click(R.string.done)
        editRow(R.string.internet_proxy); click(R.string.use_internet_proxy)
        field(R.string.proxy_host).performTextReplacement("proxy.example.invalid")
        click(R.string.continue_action); click(R.string.save); awaitService(NasServiceKind.PROXY)
        assertEquals(listOf(NasServiceStep.SMB.api, NasServiceStep.PROXY.api), fixture.writes.map { it.api })
        capture("services-and-proxy-saved")
    }

    @Test fun regionChangesPersistOnlyAfterConfirmation() {
        open(NasSettingsTab.REGION_AND_TIME); click(R.string.edit)
        click(R.string.nas_region_date_ymd_dash); click(R.string.nas_region_date_ymd_slash)
        click(R.string.continue_action); assertTrue(fixture.writes.isEmpty()); capture("region-confirmation")
        fixture.region.field("second", JsonPrimitive(20))
        click(R.string.save)
        await { model.nasRegion.state.value.let { !it.busy && it.record?.terminal == true } }
        assertEquals(JsonPrimitive("Y/m/d"), fixture.writes.single().parameters["date_format"])
        // 手动模式契约要求携带时间，必须使用保存前最新读取值而不是打开表单时的旧时间。
        assertEquals(JsonPrimitive(20), fixture.writes.single().parameters["second"]); capture("region-saved")
    }

    @Test fun accountEditAndGroupCreationRoundTrip() {
        open(NasSettingsTab.ACCOUNT); awaitText("Synthetic")
        click(R.string.edit); field(R.string.nd_description).performTextReplacement("Synthetic edited account")
        click(R.string.nd_save_changes)
        await { model.nasDirectory.state.value.let { !it.busy && it.records.singleOrNull()?.terminal == true } }
        awaitText("Synthetic edited account"); assertEquals("set", fixture.writes.single().method)
        click(R.string.user_groups); click(R.string.nd_create_group)
        field(R.string.nd_name).performTextInput("SyntheticNewGroup"); click(R.string.create)
        assertEquals(1, fixture.writes.size); capture("directory-create-confirmation")
        dialogClick(R.string.create, R.string.nd_access_title)
        await { model.nasDirectory.state.value.let { !it.busy && it.records.size == 2 && it.records.all { record -> record.terminal } } }
        awaitText("SyntheticNewGroup"); capture("directory-created")
        assertEquals(listOf("set", "create"), fixture.writes.map { it.method })
    }

    @Test fun scheduledTaskDetailsCancelRunAndOutput() {
        open(NasSettingsTab.SCHEDULED_TASKS); awaitText("Synthetic task"); click(R.string.st_details)
        awaitText("echo synthetic"); click(R.string.st_run)
        capture("task-run-confirmation"); click(R.string.cancel); assertTrue(fixture.writes.isEmpty())
        click(R.string.st_run)
        compose.onAllNodes(hasText(text(R.string.st_run)) and hasClickAction()).onLast().performClick()
        await { model.nasScheduledTasks.state.value.let { !it.busy && it.records.singleOrNull()?.terminal == true } }
        assertEquals("run", fixture.writes.single().method)
        click(R.string.st_details); awaitText("echo synthetic")
        click(R.string.st_history); awaitText(text(R.string.st_view_output)); click(R.string.st_view_output)
        awaitText("synthetic output")
        compose.onNodeWithText("synthetic output").performScrollTo().assertIsDisplayed()
        capture("task-output")
    }

    @Test fun hardwarePowerRecoveryAndMemoryCompressionSaveWithoutReboot() {
        open(NasSettingsTab.HARDWARE_AND_POWER)
        editRow(R.string.hardware_settings); click(R.string.restart_after_power_failure); click(R.string.continue_action); click(R.string.save)
        awaitService(NasServiceKind.HARDWARE)
        assertEquals(NasServiceStep.POWER_RECOVERY.api, fixture.writes.single().api)
        editRow(R.string.nas_memory_compression); click(R.string.nas_memory_enabled); click(R.string.save_changes)
        assertEquals(1, fixture.writes.size); capture("memory-confirmation"); click(R.string.save_changes)
        awaitService(NasServiceKind.MEMORY_COMPRESSION)
        assertEquals(listOf(NasServiceStep.POWER_RECOVERY.api, NasServiceStep.ZRAM.api, NasServiceStep.REBOOT_REQUIRED.api), fixture.writes.map { it.api })
        assertFalse(fixture.writes.any { it.method in setOf("shutdown", "reboot") }); capture("hardware-memory-saved")
        click(R.string.nas_power_schedule_open); awaitText(text(R.string.nas_power_schedule_empty)); capture("power-schedule-empty")
    }

    @Test fun installedPackageStopCancelAndStartShareCurrentActivity() {
        fixture.packages.installed["Synthetic"] = "2.0"
        open(NasSettingsTab.PACKAGES); awaitText("Synthetic package")
        click(R.string.stop); capture("package-stop-confirmation"); click(R.string.cancel)
        assertTrue(fixture.writes.isEmpty()); click(R.string.stop)
        compose.onNode(hasText(text(R.string.stop)) and hasAnyAncestor(isDialog())).performClick()
        await { model.packageCenter.state.value.let { !it.busy && it.activities.singleOrNull()?.terminal == true } }
        assertFalse(fixture.packageRunning); capture("package-stopped")
        click(R.string.start)
        compose.onNode(hasText(text(R.string.start)) and hasAnyAncestor(isDialog())).performClick()
        await { model.packageCenter.state.value.let { !it.busy && it.activities.size == 2 && it.activities.all { record -> record.terminal } } }
        assertTrue(fixture.packageRunning); assertEquals(listOf("stop", "start"), fixture.writes.map { it.method }); capture("package-started")
    }

    @Test fun packageCatalogPlanRequiresExplicitInstallThenShowsActualVersion() {
        open(NasSettingsTab.PACKAGES); click(R.string.pc_catalog)
        await { model.packageCenter.state.value.catalog != null }
        click(R.string.pc_install); awaitText(text(R.string.pc_install_confirm))
        assertTrue(fixture.writes.isEmpty()); capture("package-install-plan")
        click(R.string.pc_install_confirm)
        await { model.packageCenter.state.value.progress?.phase == NasPackageInstallPhase.COMPLETED }
        assertEquals("2.0", fixture.packages.installed["Synthetic"])
        assertEquals(1, fixture.writes.count { it.method == "install" })
        capture("package-install-complete")
    }

    @Test fun securityChangesOnlyRequestedProtection() {
        open(NasSettingsTab.SECURITY); click(R.string.edit)
        click(R.string.auto_block); click(R.string.continue_action)
        assertTrue(fixture.writes.isEmpty()); capture("security-confirmation"); click(R.string.save)
        awaitService(NasServiceKind.SECURITY)
        assertEquals(listOf(NasServiceStep.AUTO_BLOCK.api), fixture.writes.map { it.api }); capture("security-saved")
    }

    @Test fun directoryLoadingEmptyReadErrorContentAndSearchEmptyStayDistinct() {
        open(NasSettingsTab.ACCOUNT); await { model.nasDirectory.state.value.accounts != null }
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.directory.onList = { entered.countDown(); check(release.await(15, TimeUnit.SECONDS)) }
        try {
            click(R.string.refresh); assertTrue(entered.await(5, TimeUnit.SECONDS))
            await { model.nasDirectory.state.value.loading }; progress().assertExists(); capture("directory-loading")
        } finally { release.countDown(); fixture.directory.onList = null }
        await { !model.nasDirectory.state.value.loading }
        fixture.directory.users = emptyList(); fixture.directory.groupRows = emptyList()
        click(R.string.refresh); await { model.nasDirectory.state.value.let { !it.loading && it.accounts?.isEmpty() == true } }
        awaitText(text(R.string.directory_management_empty)); capture("directory-empty")
        fixture.directory.readFailure = IOException("Synthetic read unavailable")
        click(R.string.refresh); await { model.nasDirectory.state.value.let { !it.loading && it.accountsFailure != null && it.groupsFailure != null } }
        compose.onNodeWithText(text(R.string.retry)).assertIsEnabled()
        compose.onNodeWithText(text(R.string.directory_management_empty)).assertDoesNotExist(); capture("directory-error")
        click(R.string.user_groups); compose.onNodeWithText(text(R.string.retry)).assertIsEnabled()
        fixture.directory.readFailure = null
        fixture.directory.users = listOf(io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasDirectoryFixture.user())
        fixture.directory.groupRows = listOf(io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasDirectoryFixture.group())
        click(R.string.retry); await { model.nasDirectory.state.value.let { !it.loading && it.groupsFailure == null } }
        awaitText("SyntheticGroup"); field(R.string.nd_search).performTextInput("unmatched")
        awaitText(text(R.string.nd_no_matches)); field(R.string.nd_search).performTextClearance()
        click(R.string.nas_accounts); awaitText("Synthetic"); field(R.string.nd_search).performTextInput("unmatched")
        awaitText(text(R.string.nd_no_matches)); hideKeyboard()
        compose.onNodeWithText(text(R.string.nd_no_matches)).performScrollTo().assertIsDisplayed(); capture("directory-filter-empty")
        assertTrue(fixture.writes.isEmpty())
    }

    @Test fun scheduledTasksFiveStatesAndDetailHistoryFailuresRecoverWithoutRunning() {
        open(NasSettingsTab.SCHEDULED_TASKS); awaitText("Synthetic task")
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.tasks.beforeRead = { entered.countDown(); check(release.await(15, TimeUnit.SECONDS)) }
        try {
            click(R.string.refresh); assertTrue(entered.await(5, TimeUnit.SECONDS)); progress().assertExists(); capture("task-loading")
        } finally { release.countDown(); fixture.tasks.beforeRead = null }
        await { !model.nasScheduledTasks.state.value.loading }
        fixture.tasks.rows = emptyList(); click(R.string.refresh)
        await { model.nasScheduledTasks.state.value.let { !it.loading && it.tasks?.isEmpty() == true } }
        awaitText(text(R.string.st_empty)); capture("task-empty")
        fixture.tasks.rows = listOf(io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasScheduledTaskFixture.row())
        fixture.tasks.readFailure = IOException("Synthetic read unavailable"); click(R.string.refresh)
        await { model.nasScheduledTasks.state.value.failure != null && !model.nasScheduledTasks.state.value.loading }
        compose.onNodeWithText(text(R.string.st_empty)).assertDoesNotExist()
        capture("task-list-error"); fixture.tasks.readFailure = null; click(R.string.refresh); awaitText("Synthetic task")
        field(R.string.st_search).performTextInput("unmatched"); awaitText(text(R.string.st_no_matches))
        field(R.string.st_search).performTextClearance(); click(R.string.nd_disabled_status); awaitText(text(R.string.st_no_matches))
        click(R.string.st_all); fixture.tasks.readFailure = IOException("Synthetic details unavailable"); click(R.string.st_details)
        await { model.nasScheduledTasks.state.value.detailFailure != null }
        compose.onNodeWithText(text(R.string.edit)).assertIsNotEnabled(); capture("task-detail-error")
        compose.runOnIdle { model.nasScheduledTasks.closeDetail() }
        fixture.tasks.readFailure = null; click(R.string.st_details); awaitText("echo synthetic")
        fixture.tasks.readFailure = IOException("Synthetic history unavailable"); click(R.string.st_history)
        await { model.nasScheduledTasks.state.value.resultsFailure != null }; capture("task-history-error")
        fixture.tasks.readFailure = null; fixture.tasks.history = emptyList(); click(R.string.st_history)
        awaitText(text(R.string.st_no_results))
        fixture.tasks.history = listOf(io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasScheduledTaskFixture.result())
        click(R.string.st_history); awaitText(text(R.string.st_view_output))
        fixture.tasks.readFailure = IOException("Synthetic output unavailable"); click(R.string.st_view_output)
        await { model.nasScheduledTasks.state.value.outputFailure != null }; capture("task-output-error")
        compose.runOnIdle { model.nasScheduledTasks.closeOutput() }
        fixture.tasks.readFailure = null; click(R.string.st_view_output); awaitText("synthetic output")
        assertTrue(fixture.writes.isEmpty())
    }

    @Test fun packageCatalogLoadingEmptyErrorAndFiltersUseActualReads() {
        open(NasSettingsTab.PACKAGES)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.packages.intercept = { if (it.api == "SYNO.Core.Package.Server") { entered.countDown(); check(release.await(15, TimeUnit.SECONDS)) }; null }
        try {
            packageTab(R.string.pc_catalog); assertTrue(entered.await(5, TimeUnit.SECONDS)); progress().assertExists(); capture("catalog-loading")
        } finally { release.countDown(); fixture.packages.intercept = null }
        await { !model.packageCenter.state.value.catalogLoading && model.packageCenter.state.value.catalog != null }
        fixture.packages.queue = emptyList(); click(R.string.refresh)
        await { !model.packageCenter.state.value.catalogLoading && model.packageCenter.state.value.catalog?.entries?.isEmpty() == true }
        awaitText(text(R.string.pc_catalog_empty)); capture("catalog-empty")
        fixture.packages.intercept = { if (it.api == "SYNO.Core.Package.Server") throw IOException("Synthetic catalog unavailable") else null }
        click(R.string.refresh); await { model.packageCenter.state.value.catalogFailure != null }
        compose.onNodeWithText(text(R.string.pc_catalog_empty)).assertDoesNotExist(); click(R.string.retry)
        await { !model.packageCenter.state.value.catalogLoading }; capture("catalog-error")
        fixture.packages.intercept = null; fixture.packages.queue = listOf("Synthetic"); click(R.string.retry)
        await { model.packageCenter.state.value.let { !it.catalogLoading && it.catalogFailure == null } }; awaitText("Synthetic package")
        field(R.string.pc_search).performTextInput("unmatched"); awaitText(text(R.string.pc_no_matches))
        field(R.string.pc_search).performTextClearance(); click(R.string.pc_updates); awaitText(text(R.string.pc_no_matches)); hideKeyboard()
        compose.onNodeWithText(text(R.string.pc_no_matches)).performScrollTo().assertIsDisplayed(); capture("catalog-filter-empty")
        assertTrue(fixture.writes.isEmpty())
    }

    @Test fun packagePreferencesSourcesErrorsAndEditsShowActualSavedRecords() {
        open(NasSettingsTab.PACKAGES)
        packageTab(R.string.pc_activity); awaitText(text(R.string.pc_activity_empty))
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.packages.intercept = { if (it.api == io.github.qwertyuiop1995.dsmnativeclient.data.nas.PACKAGE_SETTINGS) { entered.countDown(); check(release.await(15, TimeUnit.SECONDS)) }; null }
        try {
            packageTab(R.string.module_settings); assertTrue(entered.await(5, TimeUnit.SECONDS)); progress().assertExists(); capture("package-settings-loading")
        } finally { release.countDown(); fixture.packages.intercept = null }
        await { model.packageCenter.state.value.preferences != null && !model.packageCenter.state.value.preferencesLoading }
        fixture.packages.intercept = { if (it.api == io.github.qwertyuiop1995.dsmnativeclient.data.nas.PACKAGE_SETTINGS) throw IOException("Synthetic settings unavailable") else null }
        click(R.string.refresh); await { model.packageCenter.state.value.preferencesFailure != null }; capture("package-settings-error")
        fixture.packages.intercept = null; click(R.string.retry)
        await { !model.packageCenter.state.value.preferencesLoading && model.packageCenter.state.value.preferencesFailure == null }
        click(R.string.pc_email); click(R.string.save_changes)
        await { !model.packageCenter.state.value.busy && model.packageCenter.state.value.activities.singleOrNull()?.terminal == true }
        packageTab(R.string.pc_activity); awaitText(text(R.string.pc_completed)); capture("package-settings-saved")
        val sourceEntered = CountDownLatch(1); val sourceRelease = CountDownLatch(1)
        fixture.packages.intercept = { if (it.api == io.github.qwertyuiop1995.dsmnativeclient.data.nas.PACKAGE_FEED) { sourceEntered.countDown(); check(sourceRelease.await(15, TimeUnit.SECONDS)) }; null }
        try {
            packageTab(R.string.pc_sources); assertTrue(sourceEntered.await(5, TimeUnit.SECONDS)); progress().assertExists()
            compose.onNodeWithText(text(R.string.pc_sources_empty)).assertDoesNotExist(); capture("package-sources-loading")
        } finally { sourceRelease.countDown(); fixture.packages.intercept = null }
        awaitText(text(R.string.pc_sources_empty))
        fixture.packages.intercept = { if (it.api == io.github.qwertyuiop1995.dsmnativeclient.data.nas.PACKAGE_FEED) throw IOException("Synthetic sources unavailable") else null }
        click(R.string.refresh); await { model.packageCenter.state.value.sourcesFailure != null }; capture("package-sources-error")
        compose.onNodeWithText(text(R.string.pc_sources_empty)).assertDoesNotExist()
        fixture.packages.intercept = null; click(R.string.retry); await { model.packageCenter.state.value.sourcesFailure == null && !model.packageCenter.state.value.sourcesLoading }
        click(R.string.pc_add_source); field(R.string.pc_source_name).performTextInput("Synthetic feed")
        field(R.string.pc_source_address).performTextInput("https://example.invalid/feed")
        click(R.string.pc_source_trust); click(R.string.save_changes)
        await { model.packageCenter.state.value.sources?.size == 1 && !model.packageCenter.state.value.busy }
        awaitText("Synthetic feed"); capture("package-source-saved")
        packageTab(R.string.pc_activity); await { model.packageCenter.state.value.activities.size == 2 }
        assertTrue(model.packageCenter.state.value.activities.all { it.terminal }); assertEquals(2, fixture.writes.size)
    }

    private fun progress() = compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)).onFirst()
    private fun hideKeyboard() {
        compose.runOnIdle { androidx.core.view.WindowCompat.getInsetsController(compose.activity.window, compose.activity.window.decorView)
            .hide(androidx.core.view.WindowInsetsCompat.Type.ime()) }
        compose.waitForIdle()
    }
    private fun packageTab(id: Int) {
        val node = compose.onNode(hasText(text(id)) and isSelectable()); scroll(node); node.performClick(); compose.waitForIdle()
    }

    private fun text(id: Int) = compose.activity.getString(id)
    private fun field(id: Int) = compose.onNode(hasText(text(id)) and hasSetTextAction())
    private fun await(predicate: () -> Boolean) = compose.waitUntil(15_000, predicate)
    private fun awaitText(value: String) = await { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() }
    private fun open(tab: NasSettingsTab) {
        compose.runOnIdle { model.selectNasSettingsTab(tab) }
        await { model.workspace.value?.nasSettings is Loadable.Ready }
    }
    private fun awaitService(kind: NasServiceKind) = await { model.workspace.value?.nasSettings is Loadable.Ready &&
        model.nasServices.state.value.getValue(kind).let { !it.busy && it.record?.terminal == true } }
    private fun editRow(title: Int) {
        val node = compose.onNodeWithContentDescription(compose.activity.getString(R.string.nas_edit_settings_accessibility, text(title)), useUnmergedTree = true)
        scroll(node); node.assertIsEnabled().performClick()
    }
    private fun dialogClick(button: Int, title: Int) = compose.onNode(hasText(text(button)) and hasClickAction() and
        hasAnyAncestor(isDialog() and hasAnyDescendant(hasText(text(title))))).performClick()
    private fun click(id: Int) { val node = compose.onNodeWithText(text(id)); scroll(node); node.assertIsDisplayed().performClick() }
    private fun scroll(node: SemanticsNodeInteraction) {
        var parent = node.fetchSemanticsNode().parent
        var scrollable = false
        while (parent != null) { if (parent.config.contains(SemanticsActions.ScrollBy)) scrollable = true; parent = parent.parent }
        if (scrollable) node.performScrollTo()
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        // 对话框语义已更新时窗口仍可能尚未呈现；等待两帧再采集实际屏幕。
        val rendered = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            compose.activity.window.decorView.postOnAnimation {
                compose.activity.window.decorView.postOnAnimation { rendered.countDown() }
            }
        }
        check(rendered.await(2, TimeUnit.SECONDS))
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(app.getExternalFilesDir(null), "nas-review/$name.png").also { it.parentFile?.mkdirs() }.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
}
