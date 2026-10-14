package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.PackageControlContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class NasPackageControlUiTest {
    @get:Rule val rule = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun text(id: Int) = rule.onNodeWithText(context.getString(id))
    private val target = PackageInfo("synthetic-package", "Synthetic package", "1.0", ResourceState.STOPPED, null, true, false, true, listOf("synthetic-app"))
    private fun record(phase: PackageActivityPhase, accepted: Boolean = false) = PackageActivityRecord("synthetic-record", WorkspaceOwner("profile", "identity", "session"),
        PackageActivityKind.CONTROL, listOf(PackageActivityItem(target.id, "1.0", "1.0", phase, "START", accepted)), "a".repeat(64))
    @Test fun 未知与接受均不能清除或重复提交只允许刷新结果() {
        val state = mutableStateOf(NasPackageCenterState(installed = listOf(target), controlActions = PackageMutationOperation.entries.toSet(), activities = listOf(record(PackageActivityPhase.SUBMITTED))))
        var reads = 0; var writes = 0
        rule.setContent { LanStashTheme { PackageControlContent(state.value, true, { reads++ }, { _, _ -> writes++; true }, {}, { writes++; true }, { reads++ }, {}) } }
        text(R.string.pc_remove_record).assertDoesNotExist(); text(R.string.start).performScrollTo().assertIsNotEnabled()
        rule.onAllNodesWithText(context.getString(R.string.refresh))[0].performScrollTo().assertHeightIsAtLeast(48.dp).performClick()
        rule.runOnIdle { assertEquals(1, reads); assertEquals(0, writes); state.value = state.value.copy(activities = listOf(record(PackageActivityPhase.SUBMITTED, true))) }
        text(R.string.pc_control_pending).performScrollTo().assertIsDisplayed(); text(R.string.pc_remove_record).assertDoesNotExist()
        rule.runOnIdle { state.value = state.value.copy(activities = listOf(record(PackageActivityPhase.COMPLETED, true)), installed = listOf(target.copy(status = ResourceState.RUNNING, canStart = false, canStop = true))) }
        text(R.string.pc_control_started).performScrollTo().assertIsDisplayed(); text(R.string.pc_remove_record).assertIsEnabled()
        text(R.string.stop).performScrollTo().assertIsEnabled()
    }
    @Test fun 加载空内容错误正常内容及搜索为空保留恢复入口() {
        val state = mutableStateOf(NasPackageCenterState(installedLoading = true, busy = true))
        rule.setContent { LanStashTheme { PackageControlContent(state.value, true, {}, { _, _ -> false }, {}, { false }, {}, {}) } }
        text(R.string.packages_empty).assertDoesNotExist()
        rule.runOnIdle { state.value = NasPackageCenterState(installed = emptyList()) }; text(R.string.packages_empty).assertIsDisplayed()
        rule.runOnIdle { state.value = NasPackageCenterState(installedFailure = DsmFailure(null, "Synthetic", "", kind = DsmErrorKind.CONNECTION_FAILED)) }
        text(R.string.retry).assertIsEnabled(); text(R.string.packages_empty).assertDoesNotExist()
        rule.runOnIdle { state.value = NasPackageCenterState(installed = listOf(target), controlActions = PackageMutationOperation.entries.toSet()) }
        rule.onNodeWithText(target.name).assertIsDisplayed()
        rule.onNode(hasSetTextAction()).performTextInput("unmatched")
        text(R.string.pc_control_no_matches).assertIsDisplayed(); text(R.string.refresh).assertIsEnabled()
    }
    @Test fun 深色二倍字号三种危险确认可达并传递原动作() {
        val state = mutableStateOf(NasPackageCenterState(installed = listOf(target), controlConfirmation = NasPackageControlConfirmation(target, PackageMutationOperation.START)))
        var confirmed: PackageMutationOperation? = null
        rule.setContent { val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) { LanStashTheme(darkTheme = true) {
                PackageControlContent(state.value, true, {}, { _, _ -> false }, {}, { confirmed = it.action; true }, {}, {})
            } }
        }
        for ((action, label, impact) in listOf(Triple(PackageMutationOperation.START, R.string.start, R.string.start_package_impact),
            Triple(PackageMutationOperation.STOP, R.string.stop, R.string.stop_package_impact), Triple(PackageMutationOperation.UNINSTALL, R.string.uninstall, R.string.uninstall_package_impact))) {
            rule.runOnIdle { state.value = state.value.copy(controlConfirmation = NasPackageControlConfirmation(target, action)) }
            text(impact).performScrollTo().assertIsDisplayed()
            text(label).assertHeightIsAtLeast(48.dp).performClick(); rule.runOnIdle { assertEquals(action, confirmed) }
        }
        rule.onNodeWithText("synthetic-app").assertDoesNotExist()
    }
}
