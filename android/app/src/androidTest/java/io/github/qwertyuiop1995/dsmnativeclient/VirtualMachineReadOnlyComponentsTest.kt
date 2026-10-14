package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineDiskController
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineHardware
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineNetworkInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineNetworkModel
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTaskCenterState
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VirtualMachineReadOnlyDetailContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VirtualMachineTaskCenterContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VIRTUAL_MACHINE_DETAIL_SCROLL_TEST_TAG
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VIRTUAL_MACHINE_TASKS_SCROLL_TEST_TAG
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.text.NumberFormat
import org.junit.Rule
import org.junit.Test

class VirtualMachineReadOnlyComponentsTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 官方硬件详情展示磁盘网卡配置且不暴露任何标识() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                VirtualMachineReadOnlyDetailContent(
                    stateLabel = "Stopped",
                    hardware = hardware(),
                    hardwareAvailable = true,
                    onRetry = {},
                    actions = {},
                )
            }
        }

        val size = context.getString(
            R.string.virtual_machine_disk_size_mib,
            NumberFormat.getIntegerInstance().format(10_240),
        )
        rule.onNodeWithText(context.getString(R.string.virtual_machine_hardware_configuration))
            .assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(
                R.string.virtual_machine_disk_summary,
                size,
                context.getString(R.string.virtual_machine_hardware_virtio),
                context.getString(R.string.virtual_machine_space_reclamation_enabled),
            ),
        ).assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(
                R.string.virtual_machine_network_interface_summary,
                "Default Network",
                context.getString(R.string.virtual_machine_network_model_e1000),
            ),
        ).performScrollTo().assertIsDisplayed()
        listOf("private-machine-id", "private-disk-id", "private-network-id", "private-nic-id")
            .forEach { privateValue ->
                rule.onNodeWithText(privateValue, substring = true).assertDoesNotExist()
            }
    }

    @Test
    fun 硬件分区失败只显示局部说明并提供48dp刷新入口() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var refreshCount = 0
        rule.setContent {
            LanStashTheme {
                VirtualMachineReadOnlyDetailContent(
                    stateLabel = "Running",
                    hardware = null,
                    hardwareAvailable = false,
                    onRetry = { refreshCount += 1 },
                    actions = { Text("Existing actions remain") },
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_hardware_unavailable_message))
            .assertIsDisplayed()
        rule.onNodeWithText("Existing actions remain").performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.refresh))
            .assertHeightIsAtLeast(48.dp)
            .performClick()
        rule.runOnIdle { check(refreshCount == 1) }
    }

    @Test
    fun 任务中心只展示普通进度且隐藏内部状态和任务标识() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val tasks = listOf(
            VirtualMachineTask("private-task-a", false, 40),
            VirtualMachineTask("private-task-b", true, 100),
        )
        rule.setContent {
            LanStashTheme {
                VirtualMachineTaskCenterContent(
                    tasks = tasks,
                    state = VirtualMachineTaskCenterState.AVAILABLE,
                    onRetry = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_task_number, 1))
            .assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(
                R.string.virtual_machine_task_summary_with_progress,
                context.getString(R.string.virtual_machine_task_in_progress),
                context.getString(R.string.virtual_machine_task_progress, 40),
            ),
        ).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_task_summary_with_progress,
            context.getString(R.string.virtual_machine_task_finished), context.getString(R.string.virtual_machine_task_progress, 100)))
            .assertIsDisplayed()
        listOf("private-task", "internal_create", "internal_import").forEach { hidden ->
            rule.onNodeWithText(hidden, substring = true).assertDoesNotExist()
        }
    }

    @Test
    fun 合法空任务中心说明下一步并允许刷新() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var refreshCount = 0
        rule.setContent {
            LanStashTheme {
                VirtualMachineTaskCenterContent(
                    tasks = emptyList(),
                    state = VirtualMachineTaskCenterState.AVAILABLE,
                    onRetry = { refreshCount += 1 },
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_tasks_empty_title))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_tasks_empty_message))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.refresh))
            .assertHeightIsAtLeast(48.dp)
            .performClick()
        rule.runOnIdle { check(refreshCount == 1) }
    }

    @Test
    fun `轮询失败保留上次任务并提供48dp重试`() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var retryCount = 0
        rule.setContent {
            LanStashTheme {
                VirtualMachineTaskCenterContent(
                    tasks = listOf(VirtualMachineTask("private-task", false, 40)),
                    state = VirtualMachineTaskCenterState.AVAILABLE,
                    onRetry = {},
                    refreshFailure = DsmFailure(null, "Synthetic", "Retry"),
                    onRetryPolling = { retryCount += 1; true },
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_task_number, 1))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_tasks_refresh_failed))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.retry))
            .assertHeightIsAtLeast(48.dp)
            .performClick()
        rule.runOnIdle { check(retryCount == 1) }
    }

    @Test
    fun 任务异常说明恢复路径并向读屏实时报告() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var state by mutableStateOf(VirtualMachineTaskCenterState.INVALID_RESPONSE)
        rule.setContent {
            LanStashTheme {
                VirtualMachineTaskCenterContent(emptyList(), state, onRetry = {})
            }
        }

        rule.onNode(
            SemanticsMatcher.expectValue(
                SemanticsProperties.LiveRegion,
                LiveRegionMode.Assertive,
            ),
        ).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_tasks_invalid_message))
            .assertIsDisplayed()
        rule.runOnIdle { state = VirtualMachineTaskCenterState.LOAD_FAILED }
        rule.onNodeWithText(context.getString(R.string.virtual_machine_tasks_load_failed_message))
            .assertIsDisplayed()
        rule.runOnIdle { state = VirtualMachineTaskCenterState.CAPABILITY_UNAVAILABLE }
        rule.onNodeWithText(
            context.getString(R.string.virtual_machine_tasks_capability_unavailable_message),
        ).assertIsDisplayed()
    }

    @Test
    fun 深色两倍字体小屏可滚动查看完整硬件和既有动作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                LanStashTheme(darkTheme = true) {
                    Box(Modifier.size(width = 320.dp, height = 320.dp)) {
                        VirtualMachineReadOnlyDetailContent(
                            stateLabel = "Stopped",
                            hardware = hardware(),
                            hardwareAvailable = true,
                            onRetry = {},
                            actions = {
                                TextButton(onClick = {}, modifier = Modifier.size(160.dp, 48.dp)) {
                                    Text(context.getString(R.string.close))
                                }
                            },
                        )
                    }
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_network_interfaces))
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithTag(VIRTUAL_MACHINE_DETAIL_SCROLL_TEST_TAG).performScrollToNode(
            hasText(context.getString(R.string.close)),
        )
        rule.onNodeWithText(context.getString(R.string.close))
            .assertIsDisplayed()
            .assertHeightIsAtLeast(48.dp)
    }

    @Test
    fun 深色两倍字体小屏任务列表可滚动到末项() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val tasks = (1..12).map { index ->
            VirtualMachineTask("private-$index", index == 12, index * 8)
        }
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                LanStashTheme(darkTheme = true) {
                    Box(Modifier.size(width = 320.dp, height = 320.dp)) {
                        VirtualMachineTaskCenterContent(
                            tasks = tasks,
                            state = VirtualMachineTaskCenterState.AVAILABLE,
                            onRetry = {},
                        )
                    }
                }
            }
        }

        val lastTask = context.getString(R.string.virtual_machine_task_number, 12)
        rule.onNodeWithTag(VIRTUAL_MACHINE_TASKS_SCROLL_TEST_TAG).performScrollToNode(
            hasText(lastTask),
        )
        rule.onNodeWithText(lastTask).assertIsDisplayed()
    }

    private fun hardware() = VirtualMachineHardware(
        machineId = "private-machine-id",
        disks = listOf(
            VirtualMachineDisk(
                id = "private-disk-id",
                sizeMiB = 10_240,
                controller = VirtualMachineDiskController.VIRTIO,
                spaceReclamationEnabled = true,
            ),
        ),
        networkInterfaces = listOf(
            VirtualMachineNetworkInterface(
                id = "private-nic-id",
                networkId = "private-network-id",
                networkName = "Default Network",
                model = VirtualMachineNetworkModel.E1000,
            ),
        ),
    )
}
