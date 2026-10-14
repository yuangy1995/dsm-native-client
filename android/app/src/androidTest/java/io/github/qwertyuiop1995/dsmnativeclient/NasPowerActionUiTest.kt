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
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasPowerStage
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasPowerAction
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasPowerActionContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class NasPowerActionUiTest {
    @get:Rule val rule = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun text(id: Int) = rule.onNodeWithText(context.getString(id))
    private fun record(stage: NasPowerStage) = NasPowerActivity("synthetic", WorkspaceOwner("profile", "identity", "session"),
        NasPowerAction.REBOOT, "a".repeat(64), stage)
    @Test fun 接受与未知均保留且不能直接关闭或再次关机() {
        val value = mutableStateOf(NasPowerActionState(loaded = true, record = record(NasPowerStage.ACCEPTED)))
        rule.setContent { LanStashTheme { Column(Modifier.verticalScroll(rememberScrollState())) {
            NasPowerActionContent(value.value, true, {}, {}, {}, {})
        } } }
        text(R.string.reboot_accepted).assertIsDisplayed(); text(R.string.done).assertDoesNotExist()
        text(R.string.restart_nas).performScrollTo().assertIsNotEnabled()
        text(R.string.shut_down_nas).performScrollTo().assertIsNotEnabled()
        text(R.string.power_restore_title).assertDoesNotExist()
        rule.runOnIdle { value.value = value.value.copy(record = record(NasPowerStage.SUBMITTED)) }
        text(R.string.power_result_needs_device_check_title).performScrollTo().assertIsDisplayed()
        text(R.string.done).assertDoesNotExist(); text(R.string.restart_nas).assertIsNotEnabled()
    }
    @Test fun 新登录恢复与恢复后关闭在深色二倍字号可达且保留未知结果() {
        val value = mutableStateOf(NasPowerActionState(loaded = true, record = record(NasPowerStage.SUBMITTED), canRestore = true))
        var restored = 0; var dismissed = 0
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) {
                LanStashTheme(darkTheme = true) { Column(Modifier.verticalScroll(rememberScrollState())) {
                    NasPowerActionContent(value.value, true, {}, {}, { restored++ }, { dismissed++ })
                } }
            }
        }
        text(R.string.power_restore_title).performScrollTo().assertHeightIsAtLeast(48.dp).performClick()
        rule.runOnIdle { assertEquals(1, restored); value.value = value.value.copy(record = value.value.record!!.copy(restored = true), canRestore = false) }
        text(R.string.power_result_needs_device_check_title).performScrollTo().assertIsDisplayed()
        text(R.string.power_restored_message).performScrollTo().assertIsDisplayed()
        text(R.string.done).performScrollTo().assertHeightIsAtLeast(48.dp).performClick()
        text(R.string.restart_nas).performScrollTo().assertIsEnabled()
        rule.runOnIdle { assertEquals(1, dismissed) }
    }
}
