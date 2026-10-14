package io.github.qwertyuiop1995.dsmnativeclient

import android.view.KeyEvent
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import java.io.IOException
import org.junit.*
import org.junit.Assert.*

/** 当前产品组件的加载、错误、空内容、筛选为空和正常交互矩阵。 */
class VmmManagementUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun text(id: Int) = context.getString(id)
    private fun field(id: Int) = compose.onNode(hasText(text(id)) and hasSetTextAction())
    private fun button(id: Int) = compose.onNode(hasText(text(id)) and hasClickAction())
    private fun progress() = compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)).onFirst().assertExists()
    private fun scrollButton(id: Int) = button(id).performScrollTo()
    @Composable private fun Theme(content: @Composable () -> Unit) {
        CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) { LanStashTheme(darkTheme = true, content = content) }
    }
    @Test fun controlsFiveStatesAndTargetAccessibility() {
        var state by mutableStateOf(VmmControlState(busy = true)); var refreshed = 0
        val target = VmmControlTarget("hidden-guest-id", "Synthetic VM", "shutdown", setOf(VmmAction.START, VmmAction.DELETE))
        compose.setContent { Theme { VmmControlsContent(state, { refreshed++ }, { _, _ -> true }, { true }, {}, {}) } }
        progress(); compose.runOnIdle { state = state.copy(busy = false, failure = IOException()) }
        compose.onNodeWithText(text(R.string.vm_read_failed)).assertExists()
        compose.onNodeWithContentDescription(text(R.string.refresh)).performClick(); assertEquals(1, refreshed)
        compose.runOnIdle { state = VmmControlState(loaded = true) }; compose.onNodeWithText(text(R.string.vm_empty)).assertExists()
        compose.runOnIdle { state = state.copy(targets = listOf(target)) }
        compose.onNodeWithContentDescription(target.name).assertExists(); field(R.string.vm_search).performTextInput("missing")
        compose.onNodeWithText(text(R.string.vm_no_matches)).assertExists(); compose.onNode(hasText("missing") and hasSetTextAction()).performTextClearance()
        compose.onNode(hasText(target.name) and hasClickAction()).performClick(); scrollButton(R.string.vm_start).assertHeightIsAtLeast(48.dp).assertIsEnabled()
        compose.onNodeWithText(target.id).assertDoesNotExist()
    }
    @Test fun networksFiveStatesAndFrozenProtection() = assets(VmmAssetKind.NETWORK)
    @Test fun imagesFiveStatesAndFrozenProtection() = assets(VmmAssetKind.IMAGE)
    private fun assets(kind: VmmAssetKind) {
        var state by mutableStateOf(VmmAssetState(busy = true))
        val network = VmmNetwork("hidden-network", "Synthetic network", "private", "hidden-host", 0, emptyList(), emptyList())
        val image = VmmImage("hidden-image", "Synthetic image", "disk", VmmSource.PUBLIC)
        compose.setContent { Theme { VmmAssetsContent(state, kind, onRefresh = {}, onNetworks = { _, _ -> true }, onRename = { _, _ -> true }, onImages = { true }, onConfirm = { true }, onCancel = {}, onDismiss = {}) } }
        progress(); compose.runOnIdle { state = state.copy(busy = false, failure = IOException()) }; compose.onNodeWithText(text(R.string.vm_read_failed)).assertExists()
        compose.runOnIdle { state = VmmAssetState(networks = VmmNetworkInventory(false, emptyList()), images = VmmImageInventory(VmmSource.PUBLIC, false, emptyList())) }
        compose.onNodeWithText(text(if (kind == VmmAssetKind.NETWORK) R.string.vm_network_empty else R.string.vm_image_empty)).assertExists()
        compose.runOnIdle { state = state.copy(networks = VmmNetworkInventory(false, listOf(network)), images = VmmImageInventory(VmmSource.PUBLIC, false, listOf(image))) }
        val label = if (kind == VmmAssetKind.NETWORK) network.name else image.name!!
        val search = if (kind == VmmAssetKind.NETWORK) R.string.vm_network_search else R.string.vm_image_search
        field(search).performTextInput("missing"); compose.onNodeWithText(text(R.string.vm_assets_no_matches)).assertExists(); compose.onNode(hasText("missing") and hasSetTextAction()).performTextClearance()
        compose.onNodeWithContentDescription(label).assertExists()
        compose.runOnIdle { state = state.copy(networks = state.networks!!.copy(frozen = true), images = state.images!!.copy(frozen = true)) }
        compose.onNodeWithContentDescription(label).assertIsNotEnabled(); compose.onNodeWithText(text(R.string.vm_assets_busy)).assertExists()
        compose.onNodeWithText("hidden-host").assertDoesNotExist()
    }
    @Test fun settingsLoadingErrorMissingFieldsAndRunningHardware() {
        var state by mutableStateOf(VmmSettingsState(editor = true, busy = true)); var retries = 0
        compose.setContent { Theme { VmmSettingsSheet(state, { state = state.copy(draft = it) }, {}, { retries++ }, {}) } }
        progress(); compose.runOnIdle { state = state.copy(busy = false, failure = IOException()) }
        button(R.string.refresh).performScrollTo().performClick(); assertEquals(1, retries)
        compose.runOnIdle {
            val baseline = VmmSettings("hidden-id", "running", VmmSource.PUBLIC, VmmConfiguration("Synthetic", null, 2, 1024, null, 1))
            state = VmmSettingsState(editor = true, baseline = baseline, draft = VmmSettingsDraft.from(baseline.configuration))
        }
        compose.onNodeWithText(text(R.string.virtual_machine_description)).assertIsNotEnabled(); compose.onNodeWithText(text(R.string.virtual_machine_cpu)).assertIsNotEnabled(); compose.onNodeWithText(text(R.string.virtual_machine_memory_mib)).assertIsNotEnabled()
        field(R.string.virtual_machine_name).performScrollTo().performTextReplacement("Renamed")
        scrollButton(R.string.save_changes).assertHeightIsAtLeast(48.dp).assertIsEnabled()
        compose.onNodeWithText("hidden-id").assertDoesNotExist()
    }
    @Test fun creationLoadingErrorEmptyStorageAndSystemBackPreservesDraft() {
        var state by mutableStateOf(VmmCreationState(editor = true, busy = true)); var closed = 0
        compose.setContent { Theme { VmmCreationSheet(state, { state = state.copy(draft = it) }, {}, {}, { closed++ }, {}) } }
        progress(); compose.runOnIdle { state = state.copy(busy = false, failure = IOException()) }; compose.onNodeWithText(text(R.string.vm_read_failed)).assertExists()
        compose.runOnIdle { state = VmmCreationState(editor = true, sources = listOf(VmmSource.PUBLIC),
            resources = VmmCreationResources(VmmSource.PUBLIC, emptyList(), emptyList(), emptyList(), true, true), draft = VmmCreationDraft(step = 2, name = "Synthetic draft")) }
        compose.onNodeWithText(text(R.string.virtual_machine_no_storage)).assertExists(); scrollButton(R.string.create).assertIsNotEnabled()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK); compose.waitForIdle()
        compose.runOnIdle { assertEquals(1, state.draft!!.step); assertEquals("Synthetic draft", state.draft!!.name); assertEquals(0, closed) }
        field(R.string.virtual_machine_cpu).performScrollTo().assertExists()
    }
    @Test fun taskRecordsLoadingEmptyErrorUnknownAndCompletedRemainReadable() {
        val owner = WorkspaceOwner("profile", "identity", "session"); var state by mutableStateOf(VmmTaskState(busy = true)); var refreshed = 0; var dismissed = 0
        compose.setContent { Theme { VmmTaskRecords(state, { refreshed++ }, { _, _ -> dismissed++ }, {}) } }
        progress(); compose.runOnIdle { state = VmmTaskState(loaded = true) }; compose.onNodeWithText(text(R.string.vm_task_activity_empty)).assertExists()
        compose.runOnIdle { state = state.copy(failure = IOException()) }; button(R.string.refresh).performScrollTo().performClick(); assertEquals(1, refreshed)
        val record = VmmImportActivity("local-record", owner, VmmImportSnapshot(vmmDigest("Private name"), vmmDigest("private name"), "disk", emptySet()), VmmImportProgress(VmmStage.SUBMITTED))
        compose.runOnIdle { state = VmmTaskState(imports = listOf(record)) }; compose.onNodeWithText(text(R.string.vm_result_unavailable), substring = true).assertExists()
        button(R.string.vm_task_dismiss).assertDoesNotExist(); button(R.string.refresh).performScrollTo().assertHeightIsAtLeast(48.dp)
        compose.runOnIdle { state = state.copy(imports = listOf(record.copy(progress = VmmImportProgress(VmmStage.VERIFIED, "private-task", vmmDigest("private-image"))))) }
        compose.onNodeWithText(text(R.string.virtual_machine_image_imported), substring = true).assertExists(); button(R.string.vm_task_dismiss).performScrollTo().performClick(); assertEquals(1, dismissed)
        for (value in listOf("Private name", "private-task", "private-image")) compose.onNodeWithText(value, substring = true).assertDoesNotExist()
        compose.runOnIdle { state = VmmTaskState(cleanups = listOf(VmmTaskClearActivity("local-cleanup", owner, listOf(VmmTaskClearItem(vmmDigest("task"), vmmDigest("response"), VmmStage.VERIFIED))))) }
        compose.onNodeWithText(text(R.string.virtual_machine_task_cleanup_feedback_title), substring = true).assertExists()
        compose.onNodeWithText(text(R.string.virtual_machine_clear_finished_tasks_title), substring = true).assertDoesNotExist()
        compose.onNodeWithText(context.getString(R.string.virtual_machine_task_number, 1), substring = true).assertExists()
        compose.onNodeWithText(context.getString(R.string.vm_item_number, 1), substring = true).assertDoesNotExist()
    }
}
