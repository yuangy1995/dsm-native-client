package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferTask
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatBytes
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.TransferTaskDetails
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.TransfersScreen
import org.junit.Rule
import org.junit.Test

class TransferServerPresentationTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun Nas任务百分比不显示为字节速度或剩余时间() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val task = task(
            id = "server-progress",
            title = "Synthetic NAS task",
            direction = TransferDirection.SERVER,
            state = TransferState.RUNNING,
            completedBytes = 50,
            totalBytes = 100,
            startedAtEpochMillis = System.currentTimeMillis() - 10_000,
        )
        rule.setContent {
            LanStashTheme { TransferTaskDetails(task) }
        }

        rule.onNodeWithText(context.getString(R.string.nas_task_percent_progress, 50))
            .assertIsDisplayed()
        rule.onAllNodesWithText(
            context.getString(R.string.transfer_bytes_progress, "50 B", "100 B"),
        ).assertCountEquals(0)
        rule.onAllNodes(hasText("B/s", substring = true)).assertCountEquals(0)
    }

    @Test
    fun Nas终态不再显示残留进度() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val task = task(
            id = "server-finished",
            title = "Finished NAS task",
            direction = TransferDirection.SERVER,
            state = TransferState.SUCCEEDED,
            completedBytes = 50,
            totalBytes = 100,
        )
        rule.setContent {
            LanStashTheme { TransferTaskDetails(task) }
        }

        rule.onAllNodesWithText(context.getString(R.string.nas_task_percent_progress, 50))
            .assertCountEquals(0)
        rule.onAllNodes(
            androidx.compose.ui.test.SemanticsMatcher.keyIsDefined(
                SemanticsProperties.ProgressBarRangeInfo,
            ),
        ).assertCountEquals(0)
    }

    @Test
    fun Nas运行态未知进度不显示零字节或未知大小() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val task = task(
            id = "server-unknown",
            title = "Unknown NAS progress",
            direction = TransferDirection.SERVER,
            state = TransferState.RUNNING,
        )
        rule.setContent {
            LanStashTheme { TransferTaskDetails(task) }
        }

        rule.onAllNodesWithText(
            context.getString(
                R.string.transfer_bytes_progress,
                formatBytes(0),
                context.getString(R.string.unknown_size),
            ),
        ).assertCountEquals(0)
    }

    @Test
    fun 普通下载保留字节速度和剩余时间() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val task = task(
            id = "download-progress",
            title = "Synthetic active download",
            direction = TransferDirection.DOWNLOAD,
            state = TransferState.RUNNING,
            completedBytes = 5_000,
            totalBytes = 10_000,
            startedAtEpochMillis = 1_000,
        )
        rule.setContent {
            LanStashTheme { TransferTaskDetails(task, nowEpochMillis = 6_000) }
        }

        rule.onNodeWithText(
            context.getString(
                R.string.transfer_bytes_progress,
                formatBytes(5_000),
                formatBytes(10_000),
            ),
        ).assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(
                R.string.transfer_speed_remaining,
                formatBytes(1_000),
                context.getString(R.string.remaining_minutes, 1),
            ),
        ).assertIsDisplayed()
    }

    @Test
    fun 普通上传保留字节速度和剩余时间() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val task = task(
            id = "upload-progress",
            title = "Synthetic active upload",
            direction = TransferDirection.UPLOAD,
            state = TransferState.RUNNING,
            completedBytes = 5_000,
            totalBytes = 10_000,
            startedAtEpochMillis = 1_000,
        )
        rule.setContent {
            LanStashTheme { TransferTaskDetails(task, nowEpochMillis = 6_000) }
        }

        rule.onNodeWithText(
            context.getString(
                R.string.transfer_bytes_progress,
                formatBytes(5_000),
                formatBytes(10_000),
            ),
        ).assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(
                R.string.transfer_speed_remaining,
                formatBytes(1_000),
                context.getString(R.string.remaining_minutes, 1),
            ),
        ).assertIsDisplayed()
    }

    @Test
    fun 来源筛选仅显示Nas任务并保留选中语义() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                TransfersScreen(
                    state = workspace(
                        listOf(
                            task("download", "Synthetic download", TransferDirection.DOWNLOAD),
                            task("upload", "Synthetic upload", TransferDirection.UPLOAD),
                            task("server", "Synthetic NAS task", TransferDirection.SERVER),
                        ),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.client_finished_tasks)).performClick()
        rule.onNodeWithContentDescription(context.getString(R.string.transfer_filter_source)).performClick()
        rule.onNodeWithText(context.getString(R.string.transfer_filter_all)).assertIsSelected()
        rule.onNodeWithText(context.getString(R.string.transfer_filter_nas_tasks))
            .performClick()
            .assertIsSelected()
        rule.onNodeWithContentDescription(context.getString(R.string.close)).performClick()
        rule.onNodeWithText("Synthetic NAS task").assertIsDisplayed()
        rule.onAllNodesWithText("Synthetic download").assertCountEquals(0)
        rule.onAllNodesWithText("Synthetic upload").assertCountEquals(0)
    }

    @Test
    fun 筛选后为空说明原因和下一步() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                TransfersScreen(
                    state = workspace(
                        listOf(task("download-only", "Only download", TransferDirection.DOWNLOAD)),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.client_finished_tasks)).performClick()
        rule.onNodeWithContentDescription(context.getString(R.string.transfer_filter_source)).performClick()
        rule.onNodeWithText(context.getString(R.string.transfer_filter_nas_tasks)).performClick()
        rule.onNodeWithContentDescription(context.getString(R.string.close)).performClick()
        rule.onNodeWithText(context.getString(R.string.no_filtered_transfer_tasks))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.no_filtered_transfer_tasks_description))
            .assertIsDisplayed()
    }

    private fun workspace(transfers: List<TransferTask>) = WorkspaceState(
        profile = io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile(
            "synthetic",
            "Synthetic",
            "https://nas.example.invalid",
            "operator",
        ),
        transfers = transfers,
    )

    private fun task(
        id: String,
        title: String,
        direction: TransferDirection,
        state: TransferState = TransferState.SUCCEEDED,
        completedBytes: Long = 0,
        totalBytes: Long? = null,
        startedAtEpochMillis: Long? = null,
    ) = TransferTask(
        id = id,
        title = title,
        detail = "Synthetic detail",
        direction = direction,
        state = state,
        completedBytes = completedBytes,
        totalBytes = totalBytes,
        startedAtEpochMillis = startedAtEpochMillis,
    )
}
