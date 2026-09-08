package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ApprovedWorkspaceUiTest {
    @get:Rule val rule = createComposeRule()
    private val models = ViewModelStore()
    private fun text(id: Int) = InstrumentationRegistry.getInstrumentation().targetContext.getString(id)
    private fun model(state: WorkspaceState = ApprovedUiFixture.state()) = ApprovedUiFixture.model(state).also { models.put("model", it) }
    @After fun release() { models.clear() }

    @Test fun 首页空内容说明与有内容时的直接入口均可用() {
        var state by mutableStateOf(ApprovedUiFixture.state().copy(transfers = emptyList()))
        var recent by mutableStateOf(emptyList<String>())
        var path: String? = null
        var action: ClientEntryAction? = null
        rule.setContent { LanStashTheme { ClientHomeScreen(state, recent, { path = it }, {}, { action = it }) } }
        rule.onNodeWithText(text(R.string.client_recent_empty)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.client_no_active_tasks)).assertIsDisplayed()
        rule.runOnIdle { recent = listOf("/synthetic/work"); state = ApprovedUiFixture.state() }
        rule.onNodeWithText("work").performClick()
        rule.onNodeWithText(text(R.string.upload_file)).performClick()
        rule.runOnIdle { assertEquals("/synthetic/work", path); assertEquals(ClientEntryAction.UPLOAD, action) }
    }

    @Test fun 设备加载错误与正常数据均保留管理入口() {
        var state by mutableStateOf(ApprovedUiFixture.state().copy(nasSettings = Loadable.Loading))
        var retried = 0
        rule.setContent { LanStashTheme { ClientDeviceScreen(state, null, {}, {}, {}, { retried++ }) } }
        rule.onNode(hasProgressBarRangeInfo(androidx.compose.ui.semantics.ProgressBarRangeInfo.Indeterminate)).assertIsDisplayed()
        rule.runOnIdle { state = state.copy(nasSettings = Loadable.Failed(DsmFailure(null, "synthetic", "synthetic"))) }
        rule.onNodeWithText(text(R.string.client_device_status_unavailable)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.retry)).performClick()
        rule.runOnIdle { assertEquals(1, retried); state = ApprovedUiFixture.state() }
        rule.onNodeWithText("Demo device").assertIsDisplayed()
        rule.onNodeWithText(text(R.string.client_storage_category)).assertIsDisplayed()
        rule.runOnIdle { state = state.copy(nasSettings = Loadable.Ready((state.nasSettings as Loadable.Ready).value.copy(system = null, volumes = emptyList()))) }
        rule.onNodeWithText(text(R.string.client_device_status_unavailable)).assertIsDisplayed()
    }

    @Test fun 设备四个分类完整覆盖原十二个管理分区() {
        assertEquals(NasSettingsTab.entries.toSet(), DeviceCategory.entries.flatMap { it.tabs }.toSet())
        var category by mutableStateOf<DeviceCategory?>(null)
        var selected: NasSettingsTab? = null
        rule.setContent { LanStashTheme { ClientDeviceScreen(ApprovedUiFixture.state(), category, { category = it }, { selected = it }, {}, {}) } }
        rule.onNodeWithText(text(R.string.client_security_category)).performClick()
        rule.onNodeWithText(text(R.string.security)).performClick()
        rule.runOnIdle { assertEquals(NasSettingsTab.SECURITY, selected) }
    }

    @Test fun 首页导航不会绕过未完成文件操作() {
        val state = ApprovedUiFixture.state().copy(fileStationMutationState = FileStationMutationWorkspaceState(mutationInProgress = true))
        val model = model(state)
        model.requestClientModule(Module.FILES)
        rule.setContent { LanStashTheme { val value by model.workspace.collectAsState(); ClientWorkspace(requireNotNull(value), model) } }
        rule.onNodeWithContentDescription(text(R.string.client_home)).performClick()
        rule.runOnIdle { assertEquals(Module.FILES, model.workspace.value?.selectedModule) }
        rule.onNode(hasContentDescription(text(R.string.client_files)) and hasAnyAncestor(hasTestTag("client_bottom_navigation")))
            .assertIsSelected()
    }

    @Test fun 同业务模块的外部导航也能离开首页别名() {
        val model = model(ApprovedUiFixture.state(Module.SETTINGS))
        rule.setContent { LanStashTheme { val state by model.workspace.collectAsState(); ClientWorkspace(requireNotNull(state), model) } }
        rule.onNodeWithText(text(R.string.client_recent_access)).assertIsDisplayed()
        rule.runOnIdle { model.navigateTo(WorkspaceRoute.ModuleRoot(Module.SETTINGS)) }
        rule.onNodeWithText(text(R.string.language_title)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.client_recent_access)).assertDoesNotExist()
    }

    @Test fun 文件照片保持两个一级目的地() {
        val model = model()
        rule.setContent { LanStashTheme { val state by model.workspace.collectAsState(); ClientWorkspace(requireNotNull(state), model) } }
        rule.onNodeWithContentDescription(text(R.string.client_files)).performClick()
        rule.runOnIdle { assertEquals(Module.FILES, model.workspace.value?.selectedModule) }
        rule.onNodeWithContentDescription(text(R.string.client_photos)).performClick()
        rule.runOnIdle { assertEquals(Module.PHOTOS, model.workspace.value?.selectedModule) }
        rule.onNodeWithContentDescription(text(R.string.client_photo_backup)).assertIsDisplayed()
    }

    @Test fun 文件长按进入关联操作后可多选并清除选择() {
        val model = model()
        model.requestClientModule(Module.FILES)
        rule.setContent { LanStashTheme { val state by model.workspace.collectAsState(); ClientWorkspace(requireNotNull(state), model) } }
        rule.onNodeWithText("Notes.txt").performTouchInput { longClick() }
        rule.onNodeWithText(text(R.string.rename)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.select_item)).performScrollTo().performClick()
        rule.runOnIdle { assertEquals(setOf("/synthetic/notes.txt"), model.workspace.value!!.fileBrowser.selectedPaths) }
        rule.onNodeWithContentDescription(text(R.string.clear_selection)).performClick()
        rule.runOnIdle { assertTrue(model.workspace.value!!.fileBrowser.selectedPaths.isEmpty()) }
    }

    @Test fun 未保存编辑的外部设置请求必须等确认再同步页面() {
        val item = ApprovedUiFixture.files.last()
        val state = ApprovedUiFixture.state().copy(previewItem = item, previewOwner = PreviewOwner.FILES,
            preview = Loadable.Ready(FilePreviewContent.Text(item, "saved", truncated = false)), textPreviewDraft = "changed")
        val model = model(state)
        model.requestClientModule(Module.FILES)
        ApprovedUiFixture.setState(model, state)
        rule.setContent { LanStashTheme { val current by model.workspace.collectAsState(); ClientWorkspace(requireNotNull(current), model) } }
        // 窄屏预览占据整个窗口，外部导航仍须经过原控制层退出确认。
        rule.runOnIdle { assertEquals(WorkspaceNavigationResult.DEFERRED, model.requestClientModule(Module.SETTINGS)) }
        rule.onNodeWithText(text(R.string.discard_text_changes_title)).assertIsDisplayed()
        rule.runOnIdle { assertEquals("changed", model.workspace.value!!.textPreviewDraft); model.dismissPreviewDiscardConfirmation() }
        rule.runOnIdle { assertEquals("changed", model.workspace.value!!.textPreviewDraft) }
        rule.runOnIdle { model.requestClientModule(Module.SETTINGS) }
        rule.onNodeWithText(text(R.string.discard_changes)).performClick()
        rule.runOnIdle { assertNull(model.workspace.value!!.textPreviewDraft); assertEquals(Module.SETTINGS, model.workspace.value!!.selectedModule) }
        rule.onNodeWithText(text(R.string.language_title)).assertIsDisplayed()
    }

    @Test fun 任务中心的下载分区保留返回传输的路径() {
        val model = model()
        model.requestClientModule(Module.TRANSFERS)
        rule.setContent { LanStashTheme { val state by model.workspace.collectAsState(); ClientWorkspace(requireNotNull(state), model) } }
        rule.onNodeWithText(text(R.string.client_nas_downloads)).performClick()
        rule.runOnIdle { assertEquals(Module.DOWNLOADS, model.workspace.value!!.selectedModule) }
        rule.onNodeWithText(text(R.string.client_phone_transfers)).assertIsDisplayed().performClick()
        rule.runOnIdle { assertEquals(Module.TRANSFERS, model.workspace.value!!.selectedModule) }
        rule.onNodeWithText("Example photo.jpg").assertIsDisplayed()
    }

    @Test fun 文件搜索界面经过首页后仍保留且不污染照片() {
        val model = model()
        model.requestClientModule(Module.FILES)
        rule.setContent { LanStashTheme { val state by model.workspace.collectAsState(); ClientWorkspace(requireNotNull(state), model) } }
        rule.onNodeWithContentDescription(text(R.string.client_search)).performClick()
        rule.onNodeWithText(text(R.string.client_search_files)).assertIsDisplayed()
        rule.onNodeWithContentDescription(text(R.string.client_home)).performClick()
        rule.onNodeWithText(text(R.string.client_recent_access)).assertIsDisplayed()
        rule.onNodeWithContentDescription(text(R.string.client_files)).performClick()
        rule.onNodeWithText(text(R.string.client_search_files)).assertIsDisplayed()
        rule.onNodeWithContentDescription(text(R.string.client_photos)).performClick()
        rule.onNodeWithText(text(R.string.client_search_photos)).assertDoesNotExist()
    }

    @Test fun 会话搜索无匹配时说明恢复方式且关闭搜索恢复会话() {
        val model = model()
        model.requestClientModule(Module.CHAT)
        rule.setContent { LanStashTheme { val state by model.workspace.collectAsState(); ClientWorkspace(requireNotNull(state), model) } }
        rule.onNodeWithContentDescription(text(R.string.client_search)).performClick()
        rule.onNode(hasSetTextAction()).performTextInput("no-such-synthetic-conversation")
        rule.onNodeWithText(text(R.string.client_no_matching_conversations)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.client_search_recovery)).assertIsDisplayed()
        rule.onNodeWithContentDescription(text(R.string.close)).performClick()
        rule.onNodeWithText("Family").assertIsDisplayed()
        rule.onNodeWithText("Project team").assertIsDisplayed()
    }
}
