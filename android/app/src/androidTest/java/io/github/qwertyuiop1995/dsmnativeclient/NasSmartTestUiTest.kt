package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasSmartTestContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class NasSmartTestUiTest {
    @get:Rule val rule = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun text(id: Int) = rule.onNodeWithText(context.getString(id))
    private val disk = NasStorageDisk("synthetic-id", "synthetic-device", "Synthetic drive", "Synthetic model", "normal", "normal", null, true)
    private val idle = NasDiskTestStatus(disk.id, false, false, null, null, null, null, "normal", true)
    private fun record(stage: NasSmartStage) = NasSmartActivity("synthetic", WorkspaceOwner("profile", "identity", "session"), smartIdentity(disk), NasSmartAction.QUICK, stage)
    @Test fun 未知和接受均保持禁止关闭或重发状态刷新只读取() {
        val state = mutableStateOf(NasSmartState(loaded = true, disks = listOf(disk), statuses = mapOf(disk.id to Loadable.Ready(idle)), record = record(NasSmartStage.SUBMITTED)))
        var reads = 0; var writes = 0
        rule.setContent { LanStashTheme { Column(Modifier.verticalScroll(rememberScrollState())) {
            NasSmartTestContent(state.value, onRefresh = { reads++ }, onLoad = { reads++ }, onRequest = { _, _ -> writes++; true },
                onCancel = {}, onConfirm = { writes++; true }, onDismiss = {})
        } } }
        text(R.string.done).assertDoesNotExist(); text(R.string.quick_test).performScrollTo().assertIsNotEnabled()
        text(R.string.smart_refresh_drives).performScrollTo().assertHeightIsAtLeast(48.dp).performClick()
        rule.runOnIdle { assertEquals(1, reads); assertEquals(0, writes); state.value = state.value.copy(record = record(NasSmartStage.ACCEPTED)) }
        text(R.string.smart_activity_pending).performScrollTo().assertIsDisplayed(); text(R.string.done).assertDoesNotExist()
        rule.runOnIdle { state.value = state.value.copy(record = record(NasSmartStage.VERIFIED), statuses = mapOf(disk.id to Loadable.Ready(idle.copy(isRunning = true, runningType = NasDiskTestType.QUICK)))) }
        text(R.string.smart_activity_running).performScrollTo().assertIsDisplayed(); text(R.string.done).assertIsEnabled()
        text(R.string.stop_test).performScrollTo().assertIsEnabled(); rule.onNodeWithText("synthetic-device").assertDoesNotExist()
    }
    @Test fun 五态历史失败与筛选为空仍可恢复且不把错误当空闲() {
        val state = mutableStateOf(NasSmartState())
        rule.setContent { LanStashTheme { Column(Modifier.verticalScroll(rememberScrollState())) {
            NasSmartTestContent(state.value, onRefresh = {}, onLoad = {}, onRequest = { _, _ -> false }, onCancel = {}, onConfirm = { false }, onDismiss = {})
        } } }
        text(R.string.smart_test_empty_message).assertDoesNotExist()
        rule.runOnIdle { state.value = NasSmartState(loaded = true) }; text(R.string.smart_test_empty_message).assertIsDisplayed()
        val failure = DsmFailure(null, "Synthetic failure", "", kind = DsmErrorKind.INVALID_RESPONSE)
        rule.runOnIdle { state.value = NasSmartState(loaded = true, disks = listOf(disk), statuses = mapOf(disk.id to Loadable.Failed(failure))) }
        text(R.string.no_smart_test_running).assertDoesNotExist(); text(R.string.retry).performScrollTo().assertIsEnabled()
        rule.runOnIdle { state.value = state.value.copy(statuses = mapOf(disk.id to Loadable.Ready(idle.copy(isHistoryAvailable = false))), historyFailures = mapOf(disk.id to failure)) }
        text(R.string.no_smart_test_running).performScrollTo().assertIsDisplayed(); text(R.string.smart_history_failed).performScrollTo().assertIsDisplayed()
        rule.onNode(hasSetTextAction()).performScrollTo().performTextInput("No match")
        text(R.string.smart_no_matches).performScrollTo().assertIsDisplayed()
    }
    @Test fun 深色二倍字号三个风险确认均有具体操作且不展示设备标识() {
        val state = mutableStateOf(NasSmartState(loaded = true, disks = listOf(disk), confirmation = NasSmartConfirmation(disk, idle, NasSmartAction.QUICK)))
        var confirmed: NasSmartAction? = null
        rule.setContent { val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) { LanStashTheme(darkTheme = true) {
                Column(Modifier.verticalScroll(rememberScrollState())) { NasSmartTestContent(state.value, onRefresh = {}, onLoad = {}, onRequest = { _, _ -> false },
                    onCancel = {}, onConfirm = { confirmed = it.action; true }, onDismiss = {}) }
            } }
        }
        for ((action, label, impact) in listOf(Triple(NasSmartAction.QUICK, R.string.quick_test, R.string.quick_smart_test_impact),
            Triple(NasSmartAction.EXTENDED, R.string.extended_test, R.string.extended_smart_test_impact), Triple(NasSmartAction.STOP, R.string.stop_test, R.string.stop_smart_test_impact))) {
            rule.runOnIdle { state.value = state.value.copy(confirmation = NasSmartConfirmation(disk, idle, action)) }
            text(impact).assertIsDisplayed(); text(label).assertIsDisplayed().performClick(); rule.runOnIdle { assertEquals(action, confirmed) }
        }
        rule.onNodeWithText("synthetic-device").assertDoesNotExist()
    }
}
