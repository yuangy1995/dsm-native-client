package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.Density
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadStationActivity
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadsScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class DownloadActivityUiTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 活动读取失败保留任务列表并提供独立重试() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        render({ Loadable.Failed(DsmFailure(null, "synthetic", "retry")) })

        rule.onNodeWithText("Synthetic task").assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.download_activity_failed)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.retry)).assertIsDisplayed().assertIsEnabled()
    }

    @Test
    fun 活动摘要覆盖加载空内容和二倍字体正常内容() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var activityState by mutableStateOf<Loadable<DownloadStationActivity>>(Loadable.Loading)
        render({ activityState }, twoX = true)
        rule.onNodeWithText(context.getString(R.string.download_activity_loading)).assertIsDisplayed()

        rule.runOnIdle { activityState = Loadable.Ready(DownloadStationActivity(0, 0, 0, 0)) }
        rule.onNodeWithText(context.getString(R.string.download_activity_empty)).assertIsDisplayed()

        rule.runOnIdle {
            activityState = Loadable.Ready(DownloadStationActivity(1024, 512, 256, 128))
        }
        rule.onNode(activityPrefix(context.getString(R.string.download_activity_standard).substringBefore('%'))).assertIsDisplayed()
        rule.onNode(activityPrefix(context.getString(R.string.download_activity_emule).substringBefore('%'))).assertIsDisplayed()
    }

    private fun activityPrefix(prefix: String) = SemanticsMatcher("Localized activity label") {
        it.config.getOrNull(SemanticsProperties.Text)?.any { value -> value.text.startsWith(prefix) } == true
    }

    private fun render(
        activity: () -> Loadable<DownloadStationActivity>,
        twoX: Boolean = false,
    ) {
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, if (twoX) 2f else density.fontScale),
            ) {
                LanStashTheme {
                    DownloadsScreen(
                        state = WorkspaceState(
                            profile = NasProfile(
                                "test",
                                "Test",
                                "https://nas.example.invalid",
                                "tester",
                            ),
                            downloads = Loadable.Ready(listOf(task())),
                            downloadAdvancedRead = DownloadAdvancedReadWorkspaceState(
                                supportsActivity = true,
                                activity = activity(),
                            ),
                        ),
                        model = model,
                    )
                }
            }
        }
    }

    private fun task() = DownloadTask(
        id = "task-1",
        type = "bt",
        title = "Synthetic task",
        status = ResourceState.RUNNING,
        size = 10,
        transferred = 1,
        downloadSpeed = 1,
        uploadSpeed = 0,
        destination = "downloads",
        error = null,
    )
}
