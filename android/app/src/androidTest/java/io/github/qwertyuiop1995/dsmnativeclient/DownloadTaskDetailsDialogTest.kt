package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.hasStateDescription
import androidx.compose.ui.test.performClick
import android.view.KeyEvent
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskFile
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskPeer
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskTracker
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadTaskDetailsDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.assertEquals

class DownloadTaskDetailsDialogTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 任务详情可切换文件Tracker和Peer() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                DownloadTaskDetailsDialog(task = detailedTask(), onDismiss = {})
            }
        }

        rule.onNodeWithText(context.getString(R.string.download_detail_files)).performClick()
        rule.onNodeWithText("Synthetic file.bin").assertIsDisplayed()

        rule.onNodeWithText(context.getString(R.string.download_detail_trackers)).performClick()
        rule.onNodeWithText("https://tracker.invalid/announce").assertIsDisplayed()

        rule.onNodeWithText(context.getString(R.string.download_detail_peers)).performClick()
        rule.onNodeWithText("Synthetic client").assertIsDisplayed()
    }

    @Test
    fun 缺少可选详情时显示可理解的空状态() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                DownloadTaskDetailsDialog(task = detailedTask().copy(files = emptyList()), onDismiss = {})
            }
        }

        rule.onNodeWithText(context.getString(R.string.download_detail_files)).performClick()
        rule.onNodeWithText(context.getString(R.string.download_detail_no_files)).assertIsDisplayed()
    }

    @Test
    fun 顶部关闭系统返回与底部关闭都使用同一关闭回调() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var dismissCount = 0
        rule.setContent {
            LanStashTheme {
                DownloadTaskDetailsDialog(
                    task = detailedTask(),
                    onDismiss = { dismissCount += 1 },
                )
            }
        }

        rule.onNodeWithContentDescription(context.getString(R.string.go_up)).performClick()
        rule.waitForIdle()
        assertEquals(1, dismissCount)

        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        rule.waitForIdle()
        assertEquals(2, dismissCount)

        rule.onNodeWithText(context.getString(R.string.close)).performClick()
        rule.waitForIdle()
        assertEquals(3, dismissCount)
    }

    @Test
    fun 文件进度向屏幕阅读器说明文件名和已下载大小() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val task = detailedTask()
        rule.setContent {
            LanStashTheme {
                DownloadTaskDetailsDialog(task = task, onDismiss = {})
            }
        }

        rule.onNodeWithText(context.getString(R.string.download_detail_files)).performClick()
        val description = context.getString(
            R.string.download_detail_file_progress,
            "Synthetic file.bin",
            "50 B",
            "100 B",
        )
        rule.onNode(hasStateDescription(description)).assertIsDisplayed()
    }

    private fun detailedTask() = DownloadTask(
        id = "synthetic-task",
        type = "bt",
        title = "Synthetic task",
        status = ResourceState.RUNNING,
        size = 100,
        transferred = 50,
        downloadSpeed = 10,
        uploadSpeed = 2,
        destination = "Synthetic destination",
        error = null,
        createdAtEpochSeconds = 1,
        priority = "normal",
        totalPeers = 3,
        connectedSeeders = 1,
        connectedLeechers = 1,
        files = listOf(DownloadTaskFile("Synthetic file.bin", 100, 50, "normal")),
        trackers = listOf(
            DownloadTaskTracker(
                url = "https://tracker.invalid/announce",
                status = "success",
                updateTimerSeconds = 30,
                seeds = 2,
                peers = 3,
            ),
        ),
        peers = listOf(
            DownloadTaskPeer(
                address = "192.0.2.1",
                agent = "Synthetic client",
                progress = 0.5,
                downloadSpeed = 5,
                uploadSpeed = 1,
            ),
        ),
    )
}
