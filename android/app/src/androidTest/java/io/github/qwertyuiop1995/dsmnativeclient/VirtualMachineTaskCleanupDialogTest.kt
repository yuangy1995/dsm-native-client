package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.unit.Density
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTaskCenterState
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VirtualMachineTaskCenterContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VirtualMachineTaskCleanupConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VmmTaskRecords
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class VirtualMachineTaskCleanupDialogTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 已完成任务显示清理入口并触发确认请求() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var requests = 0
        rule.setContent {
            LanStashTheme {
                VirtualMachineTaskCenterContent(
                    tasks = listOf(task("finished", true), task("running", false)),
                    state = VirtualMachineTaskCenterState.AVAILABLE,
                    onRetry = {},
                    onClearFinished = { requests++; true },
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_clear_finished_tasks))
            .assertIsDisplayed()
            .performClick()
        rule.runOnIdle { assertEquals(1, requests) }
    }

    @Test
    fun 只有进行中任务时不显示清理入口() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                VirtualMachineTaskCenterContent(
                    tasks = listOf(task("running", false)),
                    state = VirtualMachineTaskCenterState.AVAILABLE,
                    onRetry = {},
                )
            }
        }

        rule.onAllNodesWithText(context.getString(R.string.virtual_machine_clear_finished_tasks))
            .assertCountEquals(0)
    }

    @Test
    fun 清理确认框明确数量且确认和取消互斥() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var confirmed = 0
        var dismissed = 0
        rule.setContent {
            LanStashTheme {
                VirtualMachineTaskCleanupConfirmationDialog(
                    taskCount = 2,
                    onConfirm = { confirmed++; true },
                    onDismiss = { dismissed++; true },
                )
            }
        }

        rule.onNodeWithText(
            context.resources.getQuantityString(
                R.plurals.virtual_machine_clear_finished_tasks_message,
                2,
                2,
            ),
        ).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_clear_finished_tasks))
            .performClick()
        rule.runOnIdle {
            assertEquals(1, confirmed)
            assertEquals(0, dismissed)
        }
    }

    @Test
    fun 两倍字体下确认框仍显示主要操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) {
                LanStashTheme {
                    VirtualMachineTaskCleanupConfirmationDialog(
                        taskCount = 3,
                        onConfirm = { true },
                        onDismiss = { true },
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_clear_finished_tasks_title))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_clear_finished_tasks))
            .assertIsDisplayed()
    }

    @Test
    fun 清理结果使用无问号反馈标题() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val owner = WorkspaceOwner("profile", "identity", "session")
        val record = VmmTaskClearActivity("cleanup", owner, listOf(VmmTaskClearItem(vmmDigest("task"), vmmDigest("data"), VmmStage.VERIFIED)))
        rule.setContent { LanStashTheme { VmmTaskRecords(VmmTaskState(cleanups = listOf(record)), {}, { _, _ -> }, {}) } }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_task_cleanup_feedback_title), substring = true)
            .assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.virtual_machine_clear_finished_tasks_title))
            .assertCountEquals(0)
    }

    private fun task(token: String, finished: Boolean) = VirtualMachineTask(
        id = "local-$token",
        isFinished = finished,
        progressPercent = if (finished) 100 else 40,
        taskToken = token,
    )
}
