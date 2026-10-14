package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.*
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
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasConnectionContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class NasConnectionUiTest {
    @get:Rule val rule = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun text(id: Int) = rule.onNodeWithText(context.getString(id))
    private val row = ActiveConnection("synthetic", "Synthetic account", "SMB", "Synthetic client", null, false,
        processId = "synthetic-pid", type = "SMB", canDisconnect = true)
    private fun record(stage: NasConnectionStage) = NasConnectionActivity("synthetic", WorkspaceOwner("profile", "identity", "session"), connectionIdentity(row), stage)
    @Test fun 接受和未知均不能关闭结果或重复断开且刷新只触发读取() {
        val state = mutableStateOf(NasConnectionState(loaded = true, directory = NasConnectionDirectory(listOf(row), true), record = record(NasConnectionStage.ACCEPTED)))
        var reads = 0; var writes = 0
        rule.setContent { LanStashTheme { NasConnectionContent(state.value, onRequestDisconnect = { writes++; true }, onCancelRequest = {},
            onConfirmRequest = { writes++; true }, onRefresh = { reads++ }, onDismissResult = {}) } }
        text(R.string.done).assertDoesNotExist(); text(R.string.disconnect_connection).performScrollTo().assertIsNotEnabled()
        text(R.string.refresh_connections).assertHeightIsAtLeast(48.dp).performClick()
        rule.runOnIdle { assertEquals(1, reads); assertEquals(0, writes); state.value = state.value.copy(record = record(NasConnectionStage.SUBMITTED)) }
        text(R.string.connection_feedback_check_title).performScrollTo().assertIsDisplayed(); text(R.string.done).assertDoesNotExist()
        rule.runOnIdle { state.value = state.value.copy(record = record(NasConnectionStage.VERIFIED), directory = NasConnectionDirectory(emptyList(), true)) }
        text(R.string.connection_feedback_disconnected_title).performScrollTo().assertIsDisplayed(); text(R.string.done).assertIsEnabled()
    }
    @Test fun 部分目录搜索空状态与未知当前连接风险在深色二倍字体可达() {
        val state = mutableStateOf(NasConnectionState(loaded = true, directory = NasConnectionDirectory(listOf(row), false)))
        rule.setContent { val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) { LanStashTheme(darkTheme = true) {
                NasConnectionContent(state.value, onRequestDisconnect = { true }, onCancelRequest = {}, onConfirmRequest = { true }, onRefresh = {}, onDismissResult = {})
            } }
        }
        text(R.string.connection_partial_list).assertIsDisplayed(); text(R.string.disconnect_connection).performScrollTo().assertIsNotEnabled()
        rule.onNode(hasSetTextAction()).performTextInput("No match")
        text(R.string.connection_no_matches).performScrollTo().assertIsDisplayed()
        rule.onNode(hasSetTextAction()).performTextClearance()
        rule.runOnIdle { state.value = state.value.copy(confirmation = row.copy(isCurrentKnown = false)) }
        rule.onNodeWithText(context.getString(R.string.disconnect_connection_app_risk), substring = true).assertIsDisplayed()
        text(R.string.disconnect_current_connection).assertIsDisplayed(); rule.onNodeWithText("synthetic-pid").assertDoesNotExist()
    }
}
