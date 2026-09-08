package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadsScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

class DownloadAdaptiveScreenTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 宽屏大字体同时显示列表详情和选择态() {
        val task = detailedTask()
        setExpandedContent(task)

        rule.onNode(hasText(task.title) and isSelected()).assertIsSelected()
        rule.onNodeWithText("Synthetic adaptive destination").performScrollTo().assertIsDisplayed()
    }

    @Test
    fun 宽屏未选择任务时显示可理解的空详情() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setExpandedContent(detail = null)

        rule.onNodeWithText(context.getString(R.string.download_select_task)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.download_select_task_description)).assertIsDisplayed()
    }

    @Test
    fun 设备可用宽度达到展开断点时使用真实双栏() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue(context.resources.configuration.screenWidthDp >= 840)
        val task = detailedTask()
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                DownloadsScreen(
                    state = WorkspaceState(
                        profile = NasProfile(
                            "synthetic",
                            "Synthetic",
                            "https://nas.example.invalid",
                            "operator",
                        ),
                        selectedModule = Module.DOWNLOADS,
                        downloads = Loadable.Ready(listOf(task)),
                        downloadDetailsTask = task,
                    ),
                    model = model,
                )
            }
        }

        rule.onNode(hasText(task.title) and isSelected()).assertIsSelected()
        rule.onNodeWithContentDescription(context.getString(R.string.close)).assertIsDisplayed()
    }

    @Test
    fun 窗口从展开收窄后切换为窄屏详情且不保留列表选中态() {
        val task = detailedTask()
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val width = mutableStateOf(1_000.dp)
        rule.setContent {
            LanStashTheme {
                Box(Modifier.requiredWidth(width.value).height(700.dp)) {
                    DownloadsScreen(
                        state = WorkspaceState(
                            profile = NasProfile(
                                "synthetic",
                                "Synthetic",
                                "https://nas.example.invalid",
                                "operator",
                            ),
                            selectedModule = Module.DOWNLOADS,
                            downloads = Loadable.Ready(listOf(task)),
                            downloadDetailsTask = task,
                        ),
                        model = model,
                    )
                }
            }
        }

        val selectedTask = hasText(task.title) and isSelected()
        rule.onAllNodes(selectedTask).assertCountEquals(1)
        rule.runOnIdle { width.value = 500.dp }
        rule.waitForIdle()
        rule.onAllNodes(selectedTask).assertCountEquals(0)
        rule.onNodeWithContentDescription(
            InstrumentationRegistry.getInstrumentation().targetContext.getString(R.string.go_up),
        ).assertIsDisplayed()
    }

    private fun setExpandedContent(detail: DownloadTask?) {
        val task = detailedTask()
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            val currentDensity = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(currentDensity.density, fontScale = 2f),
            ) {
                LanStashTheme {
                    Box(Modifier.requiredWidth(1_000.dp).height(700.dp)) {
                        DownloadsScreen(
                            state = WorkspaceState(
                                profile = NasProfile(
                                    "synthetic",
                                    "Synthetic",
                                    "https://nas.example.invalid",
                                    "operator",
                                ),
                                selectedModule = Module.DOWNLOADS,
                                downloads = Loadable.Ready(listOf(task)),
                                downloadDetailsTask = detail,
                            ),
                            model = model,
                        )
                    }
                }
            }
        }
    }

    private fun detailedTask() = DownloadTask(
        id = "synthetic-adaptive-task",
        type = "bt",
        title = "Synthetic adaptive task",
        status = ResourceState.RUNNING,
        size = 100,
        transferred = 50,
        downloadSpeed = null,
        uploadSpeed = null,
        destination = "Synthetic adaptive destination",
        error = null,
    )
}
