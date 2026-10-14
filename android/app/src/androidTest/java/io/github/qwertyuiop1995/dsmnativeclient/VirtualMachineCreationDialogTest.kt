package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** 保留旧向导的交互验收，直接使用当前产品表单与结构化草稿。 */
class VirtualMachineCreationDialogTest {
    @get:Rule val rule = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun text(id: Int) = context.getString(id)
    private fun field(id: Int) = rule.onNode(hasText(text(id)) and hasSetTextAction())
    private fun button(id: Int) = rule.onNode(hasText(text(id)) and hasClickAction()).performScrollTo()

    @Test fun 分步选择资源后提交稳定配置() {
        var state by mutableStateOf(creationUiState())
        var submitted: VmmCreationPlan? = null
        rule.setContent { LanStashTheme { VmmCreationSheet(state, { state = state.copy(draft = it) }, { submitted = state.plan }, {}, {}, {}) } }
        field(R.string.virtual_machine_name).performTextInput("Synthetic VM")
        button(R.string.virtual_machine_next_step).performClick()
        field(R.string.virtual_machine_cpu).assertIsDisplayed()
        button(R.string.virtual_machine_empty_disk).assertHeightIsAtLeast(48.dp).performClick()
        rule.onNode(hasText("Synthetic disk image") and hasClickAction()).assertHeightIsAtLeast(48.dp).performClick()
        button(R.string.virtual_machine_next_step).performClick()
        button(R.string.virtual_machine_disconnected_network).assertHeightIsAtLeast(48.dp).performClick()
        rule.onNode(hasText("Synthetic network") and hasClickAction()).assertHeightIsAtLeast(48.dp).performClick()
        rule.onNodeWithText("Synthetic VM").performScrollTo().assertIsDisplayed()
        button(R.string.create).performClick()
        rule.runOnIdle {
            assertEquals("Synthetic VM", submitted?.configuration?.name)
            assertEquals("storage-1", submitted?.storage?.ref?.id)
            assertEquals("network-1", submitted?.networks?.single()?.id)
            assertEquals("image-1", submitted?.disks?.single()?.image?.id)
        }
    }

    @Test fun 创建字段错误可感知且步骤向读屏报告() {
        var state by mutableStateOf(creationUiState())
        rule.setContent { LanStashTheme { VmmCreationSheet(state, { state = state.copy(draft = it) }, {}, {}, {}, {}) } }
        rule.onNode(hasText(context.getString(R.string.virtual_machine_creation_step, 1, 3)) and
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite)).assertIsDisplayed()
        button(R.string.virtual_machine_next_step).assertHeightIsAtLeast(48.dp).assertIsNotEnabled()
        field(R.string.virtual_machine_name).performTextInput("x".repeat(65))
        rule.onNode(hasText(text(R.string.virtual_machine_name_invalid)) and
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Assertive)).assertIsDisplayed()
        button(R.string.virtual_machine_next_step).assertIsNotEnabled()
    }

    @Test fun 启动选项与立即启动整行保留状态及48dp触控入口() {
        var state by mutableStateOf(creationUiState(name = "Synthetic VM"))
        rule.setContent { LanStashTheme { VmmCreationSheet(state, { state = state.copy(draft = it) }, {}, {}, {}, {}) } }
        button(R.string.vm_startup_off).assertHeightIsAtLeast(48.dp).performClick()
        rule.onNode(hasText(text(R.string.vm_startup_on)) and hasClickAction()).assertHeightIsAtLeast(48.dp).performClick()
        rule.runOnIdle { assertEquals(2, state.draft!!.startup); state = state.copy(draft = state.draft!!.copy(step = 2)) }
        rule.onNode(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Switch) and
            SemanticsMatcher.expectValue(SemanticsProperties.ToggleableState, ToggleableState.Off))
            .performScrollTo().assertHeightIsAtLeast(48.dp).performClick()
        rule.runOnIdle { assertTrue(state.draft!!.powerOn); assertEquals(2, state.plan!!.configuration.startup) }
    }

    @Test fun 没有存储时说明原因并禁用创建() {
        var state by mutableStateOf(creationUiState().let { it.copy(resources = it.resources!!.copy(storages = emptyList())) })
        rule.setContent { LanStashTheme { VmmCreationSheet(state, { state = state.copy(draft = it) }, {}, {}, {}, {}) } }
        field(R.string.virtual_machine_name).performTextInput("Synthetic VM")
        button(R.string.virtual_machine_next_step).performClick()
        button(R.string.virtual_machine_next_step).performClick()
        rule.onNodeWithText(text(R.string.virtual_machine_no_storage)).performScrollTo().assertIsDisplayed()
        button(R.string.create).assertIsNotEnabled()
    }

    @Test fun 常规设置使用稳定标识并提交结构化值() {
        var state by mutableStateOf(settingsUiState())
        var submitted: VmmConfiguration? = null
        var target: String? = null
        rule.setContent { LanStashTheme { VmmSettingsSheet(state, { state = state.copy(draft = it) }, {
            submitted = state.draft!!.configuration(); target = state.target
        }, {}, {}) } }
        field(R.string.virtual_machine_name).performTextReplacement("Updated VM")
        button(R.string.vm_startup_off).performClick()
        rule.onNode(hasText(text(R.string.vm_startup_on)) and hasClickAction()).performClick()
        button(R.string.save_changes).assertHeightIsAtLeast(48.dp).performClick()
        rule.runOnIdle {
            assertEquals("guest-1", target)
            assertEquals(VmmConfiguration("Updated VM", "Old description", 2, 2048, null, 2), submitted)
        }
    }

    @Test fun 设置字段错误使用断言式提示并阻止保存() {
        var state by mutableStateOf(settingsUiState().let { it.copy(draft = it.draft!!.copy(cpu = "0")) })
        rule.setContent { LanStashTheme { VmmSettingsSheet(state, { state = state.copy(draft = it) }, {}, {}, {}) } }
        rule.onNode(hasText(text(R.string.virtual_machine_cpu_range)) and
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Assertive)).performScrollTo().assertIsDisplayed()
        button(R.string.save_changes).assertHeightIsAtLeast(48.dp).assertIsNotEnabled()
    }

    @Test fun 深色两倍字体下可滚动到创建配置摘要() {
        var state by mutableStateOf(creationUiState())
        rule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
                LanStashTheme(darkTheme = true) { VmmCreationSheet(state, { state = state.copy(draft = it) }, {}, {}, {}, {}) }
            }
        }
        field(R.string.virtual_machine_name).performTextInput("Large text VM")
        button(R.string.virtual_machine_next_step).performClick()
        repeat(2) { button(R.string.virtual_machine_add_disk).assertHeightIsAtLeast(48.dp).performClick() }
        for (number in 2..3) rule.onNodeWithText(context.getString(R.string.virtual_machine_remove_disk_number, number)).performScrollTo().assertHeightIsAtLeast(48.dp)
        button(R.string.virtual_machine_next_step).performClick()
        repeat(2) { button(R.string.virtual_machine_add_network).assertHeightIsAtLeast(48.dp).performClick() }
        for (number in 2..3) rule.onNodeWithText(context.getString(R.string.virtual_machine_remove_network_number, number)).performScrollTo().assertHeightIsAtLeast(48.dp)
        rule.onNodeWithText("Large text VM").performScrollTo().assertIsDisplayed()
        button(R.string.create).assertHeightIsAtLeast(48.dp).assertIsDisplayed()
        rule.runOnIdle { assertEquals(3, state.plan!!.disks.size); assertEquals(3, state.plan!!.networks.size) }
    }

    @Test fun 创建草稿与步骤重建后保留且不重放确认() {
        val restoration = StateRestorationTester(rule)
        var state by mutableStateOf(creationUiState())
        var confirmCount = 0
        restoration.setContent { LanStashTheme { VmmCreationSheet(state, { state = state.copy(draft = it) }, { confirmCount++ }, {}, {}, {}) } }
        field(R.string.virtual_machine_name).performTextInput("Restored VM")
        button(R.string.virtual_machine_next_step).performClick()
        restoration.emulateSavedInstanceStateRestore()
        rule.onNode(hasText(context.getString(R.string.virtual_machine_creation_step, 2, 3)) and
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite)).assertIsDisplayed()
        rule.runOnIdle { assertEquals("Restored VM", state.draft!!.name); assertEquals(0, confirmCount) }
    }

    @Test fun 设置草稿重建后保留且不重放确认() {
        val restoration = StateRestorationTester(rule)
        var state by mutableStateOf(settingsUiState())
        var confirmCount = 0
        restoration.setContent { LanStashTheme { VmmSettingsSheet(state, { state = state.copy(draft = it) }, { confirmCount++ }, {}, {}) } }
        field(R.string.virtual_machine_name).performTextReplacement("Restored settings")
        restoration.emulateSavedInstanceStateRestore()
        rule.onNodeWithText("Restored settings").assertIsDisplayed()
        rule.runOnIdle { assertEquals(0, confirmCount) }
    }

    @Test fun 生命周期确认重建后保留且不重放请求() {
        val restoration = StateRestorationTester(rule)
        val target = VmmControlTarget("guest-1", "Synthetic VM", "running", setOf(VmmAction.SHUTDOWN))
        val state = VmmControlState(loaded = true, confirmation = VmmControlConfirmation(listOf(target), VmmAction.SHUTDOWN))
        var confirmCount = 0
        restoration.setContent { LanStashTheme { VmmControlsContent(state, {}, { _, _ -> true }, { confirmCount++; true }, {}, {}) } }
        restoration.emulateSavedInstanceStateRestore()
        rule.onNodeWithText("Synthetic VM").assertIsDisplayed()
        rule.onNodeWithText(text(R.string.vm_stop_risk)).performScrollTo().assertIsDisplayed()
        button(R.string.vm_stop).assertIsDisplayed()
        rule.runOnIdle { assertEquals(0, confirmCount) }
    }

    @Test fun 创建确认接收后立即禁用以阻止双击() {
        var state by mutableStateOf(creationUiState(step = 2, name = "Single request"))
        var confirmCount = 0
        rule.setContent { LanStashTheme { VmmCreationSheet(state, { state = state.copy(draft = it) }, {
            if (!state.busy) { state = state.copy(busy = true); confirmCount++ }
        }, {}, {}, {}) } }
        button(R.string.create).performClick()
        button(R.string.create).assertIsNotEnabled().performClick()
        rule.runOnIdle { assertEquals(1, confirmCount) }
    }

    private fun settingsUiState(): VmmSettingsState {
        val baseline = VmmSettings("guest-1", "shutdown", VmmSource.PUBLIC, VmmConfiguration("Old name", "Old description", 2, 2048, null, 0))
        return VmmSettingsState(editor = true, target = baseline.id, baseline = baseline, draft = VmmSettingsDraft.from(baseline.configuration))
    }
}

internal fun creationUiState(step: Int = 0, name: String = "") = VmmCreationState(
    editor = true, powerAvailable = true, sources = listOf(VmmSource.PUBLIC),
    draft = VmmCreationDraft(step = step, name = name, storage = "storage-1"),
    resources = VmmCreationResources(VmmSource.PUBLIC,
        listOf(VmmCreationStorage(VmmCreationRef("storage-1", "Synthetic storage"))),
        listOf(VmmCreationRef("network-1", "Synthetic network")),
        listOf(VmmCreationImage(VmmCreationRef("image-1", "Synthetic disk image"), "disk")), true, true),
)
