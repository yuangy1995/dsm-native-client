package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
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
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** 当前持久操作记录的结果、刷新、恢复与可访问性；旧统一 MutationResult 已不参与产品。 */
class VirtualMachineMutationFeedbackTest {
    @get:Rule val rule = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val owner = WorkspaceOwner("profile", "identity", "session")
    private fun text(id: Int) = context.getString(id)
    private fun button(id: Int) = rule.onNode(hasText(text(id)) and hasClickAction()).performScrollTo()
    private fun setting(stage: VmmStage) = VmmSettingsActivity("settings", owner, vmmDigest("id"), vmmDigest("name"),
        vmmDigest("new"), vmmDigest("desired"), VmmSource.PUBLIC, stage)
    private fun creation(stage: VmmCreationStage): VmmCreationActivity {
        val plan = creationUiState(name = "Synthetic VM").plan!!
        return VmmCreationActivity(owner, VmmCreationSnapshot("creation", plan, emptySet(), "{}", null), VmmCreationProgress(stage))
    }
    @Composable private fun Content(content: @Composable () -> Unit) {
        LanStashTheme { Column(Modifier.verticalScroll(rememberScrollState())) { content() } }
    }
    @Test fun 当前设置各阶段有独立反馈且不混淆未发送与完成() {
        var stage by mutableStateOf(VmmStage.PREPARED)
        rule.setContent { Content { VmmSettingsRecords(VmmSettingsState(records = listOf(setting(stage))), emptyList(), {}, {}) } }
        val labels = mapOf(VmmStage.PREPARED to R.string.vm_not_sent, VmmStage.CANCELLED to R.string.vm_not_sent,
            VmmStage.SUBMITTED to R.string.vm_result_unavailable, VmmStage.ACCEPTED to R.string.vm_processing,
            VmmStage.REJECTED to R.string.vm_rejected, VmmStage.VERIFIED to R.string.vm_settings_saved)
        labels.forEach { (value, label) ->
            rule.runOnIdle { stage = value }
            rule.onNodeWithText(text(label), substring = true).assertIsDisplayed()
            if (value in setOf(VmmStage.PREPARED, VmmStage.SUBMITTED, VmmStage.ACCEPTED)) button(R.string.refresh).assertExists()
            else button(R.string.close).assertExists()
        }
    }
    @Test fun 未确认批次逐项展示且不可移除原记录() {
        var refreshed = 0; var dismissed = 0
        val record = VmmTaskClearActivity("cleanup", owner, listOf(VmmStage.VERIFIED, VmmStage.SUBMITTED, VmmStage.CANCELLED).mapIndexed { index, stage ->
            VmmTaskClearItem(vmmDigest("task-$index"), vmmDigest("response-$index"), stage)
        })
        rule.setContent { LanStashTheme { VmmTaskRecords(VmmTaskState(cleanups = listOf(record)), { refreshed++ }, { _, _ -> dismissed++ }, {}) } }
        for ((index, label) in listOf(R.string.vm_task_cleared, R.string.vm_result_unavailable, R.string.vm_not_sent).withIndex()) {
            rule.onNodeWithText(context.getString(R.string.vm_item_status, context.getString(R.string.virtual_machine_task_number, index + 1), text(label))).performScrollTo().assertIsDisplayed()
        }
        button(R.string.refresh).assertHeightIsAtLeast(48.dp).performClick()
        rule.onNodeWithText(text(R.string.vm_task_dismiss)).assertDoesNotExist()
        assertEquals(1, refreshed); assertEquals(0, dismissed)
    }
    @Test fun 创建各阶段保留原配置且只有尚未发送后续步骤可继续() {
        var stage by mutableStateOf(VmmCreationStage.CREATE_SENT)
        rule.setContent { Content { VmmCreationRecords(VmmCreationState(records = listOf(creation(stage))), {}, {}, {}) } }
        val labels = mapOf(VmmCreationStage.CREATE_SENT to R.string.vm_result_unavailable,
            VmmCreationStage.CREATING to R.string.vm_creation_creating, VmmCreationStage.CREATED to R.string.vm_creation_continue_settings,
            VmmCreationStage.CONFIGURED to R.string.vm_creation_continue_power, VmmCreationStage.PARTIAL to R.string.vm_creation_partial,
            VmmCreationStage.REJECTED to R.string.vm_rejected, VmmCreationStage.COMPLETE to R.string.vm_creation_complete)
        labels.forEach { (value, label) ->
            rule.runOnIdle { stage = value }
            rule.onNodeWithText("Synthetic VM").assertIsDisplayed()
            rule.onNodeWithText(text(label)).assertIsDisplayed()
            if (value.canContinue) button(R.string.continue_action).assertIsEnabled()
            else rule.onNodeWithText(text(R.string.continue_action)).assertDoesNotExist()
        }
    }
    @Test fun 已确认成功使用礼貌通知并允许移除记录() {
        var dismissed = 0
        rule.setContent { Content { VmmSettingsRecords(VmmSettingsState(records = listOf(setting(VmmStage.VERIFIED))), emptyList(), {}, { dismissed++ }) } }
        rule.onNode(SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite)).assertIsDisplayed()
        button(R.string.close).assertHeightIsAtLeast(48.dp).performClick(); assertEquals(1, dismissed)
    }
    @Test fun 创建准备失败保留错误恢复按钮且不误报成功() {
        var retried = 0
        rule.setContent { LanStashTheme { VmmCreationSheet(creationUiState(name = "Draft").copy(failure = IOException()), {}, {}, { retried++ }, {}, {}) } }
        rule.onNodeWithText(text(R.string.vm_read_failed)).assertIsDisplayed()
        button(R.string.refresh).performClick(); assertEquals(1, retried)
        button(R.string.virtual_machine_next_step).assertIsNotEnabled()
        rule.onNodeWithText(text(R.string.vm_creation_complete)).assertDoesNotExist()
    }
    @Test fun 设置准备失败保留草稿且恢复前禁止保存() {
        var retried = 0
        val baseline = VmmSettings("id", "shutdown", VmmSource.PUBLIC, VmmConfiguration("Original", "", 2, 2048, null, 1))
        val state = VmmSettingsState(editor = true, baseline = baseline, draft = VmmSettingsDraft.from(baseline.configuration).copy(name = "Updated"), failure = IOException())
        rule.setContent { LanStashTheme { VmmSettingsSheet(state, {}, {}, { retried++ }, {}) } }
        rule.onNodeWithText("Updated").assertExists()
        button(R.string.save_changes).assertIsNotEnabled()
        button(R.string.refresh).performClick(); assertEquals(1, retried)
    }
    @Test fun 异常与刷新失败在深色两倍字体下保持原记录和恢复入口() {
        var refreshed = 0
        rule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
                LanStashTheme(darkTheme = true) { Column(Modifier.verticalScroll(rememberScrollState())) {
                    VmmCreationRecords(VmmCreationState(records = listOf(creation(VmmCreationStage.CREATE_SENT)), failure = IOException()), { refreshed++ }, {}, {})
                } }
            }
        }
        rule.onNodeWithText(text(R.string.vm_read_failed)).performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(text(R.string.vm_result_unavailable)).performScrollTo().assertIsDisplayed()
        rule.onAllNodes(hasText(text(R.string.refresh)) and hasClickAction()).onLast().performScrollTo().assertHeightIsAtLeast(48.dp).performClick()
        rule.onNodeWithText(text(R.string.close)).assertDoesNotExist(); assertEquals(1, refreshed)
    }
}
