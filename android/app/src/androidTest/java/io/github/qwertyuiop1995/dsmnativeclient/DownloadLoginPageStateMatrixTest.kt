package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssSite
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.network.ConnectionStatus
import io.github.qwertyuiop1995.dsmnativeclient.ui.DownloadDestinationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.DownloadSettingsDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadDiscoveryDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadTaskDetailsDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadsScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.login.LoginScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.settings.SettingsScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class DownloadLoginPageStateMatrixTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 下载目的地显示加载状态() {
        showDestination(Loadable.Loading)

        rule.onAllNodes(
            SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo),
        ).assertCountEquals(1)
    }

    @Test
    fun 下载目的地显示可信空目录状态() {
        val context = context()
        showDestination(Loadable.Ready(FilePage(emptyList(), 0, 0)))

        rule.onNodeWithText(context.getString(R.string.no_subfolders)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.download_destination_empty_description))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.cancel)).assertIsDisplayed()
    }

    @Test
    fun 下载目的地错误状态显示恢复入口() {
        val context = context()
        showDestination(Loadable.Failed(failure()))

        rule.onNodeWithText(context.getString(R.string.operation_not_completed)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.try_again_later)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.retry)).assertIsDisplayed()
    }

    @Test
    fun 下载目的地两倍字体显示内容和主操作() {
        val context = context()
        showDestination(
            Loadable.Ready(
                FilePage(
                    listOf(FileItem("/downloads/archive", "Synthetic archive", true, canWrite = true)),
                    1,
                    0,
                ),
            ),
            twoX = true,
        )

        rule.onNodeWithText("Synthetic archive").assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.use_this_folder)).assertIsDisplayed()
        rule.onNodeWithContentDescription(context.getString(R.string.close)).assertIsDisplayed()
    }

    @Test
    fun 下载设置静态表单两倍字体显示内容和退出操作() {
        val context = context()
        val baseline = DownloadSettings(defaultDestination = "downloads")
        val state = workspace().copy(
            supportsDownloadSettings = true,
            supportsDownloadSchedule = true,
            downloadSettings = Loadable.Ready(baseline),
            downloadSettingsState = DownloadSettingsWorkspaceState(
                editorVisible = true,
                baseline = baseline,
                draft = DownloadSettingsDraftState.from(baseline),
            ),
        )
        setContent(twoX = true) {
            DownloadSettingsDialog(
                state = state,
                onRetry = {},
                onDraftChange = {},
                onSave = { true },
                onRefreshMutation = {},
                onDismissMutation = { true },
                onDismiss = { true },
            )
        }

        rule.onNodeWithText(context.getString(R.string.download_settings_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.download_default_folder))
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithContentDescription(context.getString(R.string.close)).assertIsDisplayed()
    }

    @Test
    fun 下载发现显示加载状态() {
        showDiscovery(workspace().copy(supportsDownloadRss = true, downloadRssSites = Loadable.Loading))

        rule.onAllNodes(
            SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo),
        ).assertCountEquals(1)
    }

    @Test
    fun 下载发现显示可信空来源状态() {
        val context = context()
        showDiscovery(
            workspace().copy(
                supportsDownloadRss = true,
                downloadRssSites = Loadable.Ready(emptyList()),
            ),
        )

        rule.onNodeWithText(context.getString(R.string.download_rss_sites_empty)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.download_rss_sites_empty_description))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.close)).assertIsDisplayed()
    }

    @Test
    fun 下载发现错误状态显示恢复入口() {
        val context = context()
        showDiscovery(
            workspace().copy(
                supportsDownloadRss = true,
                downloadRssSites = Loadable.Failed(failure()),
            ),
        )

        rule.onNodeWithText(context.getString(R.string.operation_not_completed)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.retry)).assertIsDisplayed()
    }

    @Test
    fun 下载发现两倍字体显示正常来源和退出操作() {
        val context = context()
        showDiscovery(
            workspace().copy(
                supportsDownloadRss = true,
                downloadRssSites = Loadable.Ready(
                    listOf(DownloadRssSite("rss-1", "Synthetic RSS source", false, null)),
                ),
            ),
            twoX = true,
        )

        rule.onNodeWithText("Synthetic RSS source").assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.close)).assertIsDisplayed()
    }

    @Test
    fun 下载详情两倍字体显示空文件状态和退出操作() {
        val context = context()
        showTaskDetails(task().copy(files = emptyList()), twoX = true)

        rule.onNodeWithText(context.getString(R.string.download_detail_files)).performClick()
        rule.onNodeWithText(context.getString(R.string.download_detail_no_files)).assertIsDisplayed()
        rule.onNodeWithContentDescription(context.getString(R.string.go_up)).assertIsDisplayed()
    }

    @Test
    fun 下载详情显示正常内容() {
        val context = context()
        showTaskDetails(task())

        rule.onNodeWithText(context.getString(R.string.download_detail_status)).assertIsDisplayed()
        rule.onNodeWithText("Synthetic destination").performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.close)).assertIsDisplayed()
    }

    @Test
    fun 下载列表显示加载状态() {
        showDownloads(workspace().copy(downloads = Loadable.Loading))

        rule.onAllNodes(
            SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo),
        ).assertCountEquals(1)
    }

    @Test
    fun 下载列表显示可信空状态和主操作() {
        val context = context()
        showDownloads(workspace().copy(downloads = Loadable.Ready(emptyList())))

        rule.onNodeWithText(context.getString(R.string.no_download_tasks)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.add_download_description)).assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(R.string.add_download),
            useUnmergedTree = true,
        ).assertIsDisplayed()
    }

    @Test
    fun 下载列表错误状态显示恢复入口() {
        val context = context()
        showDownloads(workspace().copy(downloads = Loadable.Failed(failure())))

        rule.onNodeWithText(context.getString(R.string.operation_not_completed)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.retry)).assertIsDisplayed()
    }

    @Test
    fun 下载列表两倍字体显示正常任务和主操作() {
        val context = context()
        showDownloads(workspace().copy(downloads = Loadable.Ready(listOf(task()))), twoX = true)

        rule.onNodeWithText("Synthetic task").performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(R.string.add_download),
            useUnmergedTree = true,
        ).assertIsDisplayed()
    }

    @Test
    fun 登录页显示连接中状态() {
        val context = context()
        showLogin(
            LoginState(
                isConnecting = true,
                connectionStatus = ConnectionStatus.CONNECTING_DIRECT,
            ),
        )

        rule.onNodeWithText(context.getString(R.string.status_connecting_nas))
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.client_connecting))
            .assertIsDisplayed()
    }

    @Test
    fun 登录页错误状态显示恢复说明和主操作() {
        val context = context()
        showLogin(LoginState(error = failure()))

        rule.onNodeWithText(
            context.getString(R.string.operation_not_completed),
            substring = true,
        )
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(R.string.try_again_later),
            substring = true,
        )
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.connect)).assertIsDisplayed()
    }

    @Test
    fun 登录页两倍字体显示表单和主操作() {
        val context = context()
        showLogin(LoginState(), twoX = true)

        rule.onNodeWithText(context.getString(R.string.client_connect_nas)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.nas_address_or_quickconnect))
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.connect))
            .assertIsDisplayed()
    }

    @Test
    fun 应用设置两倍字体显示静态内容和可用主操作() {
        val context = context()
        val model = model()
        setContent(twoX = true) {
            SettingsScreen(
                state = workspace().copy(
                    selectedModule = Module.SETTINGS,
                    regenerableCacheBytes = 4_096,
                    availability = listOf(ModuleAvailability(Module.DOWNLOADS, true)),
                ),
                model = model,
            )
        }

        rule.onNodeWithText(context.getString(R.string.language_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.regenerable_cache)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.clear_cache))
            .performScrollTo().assertIsDisplayed().assertIsEnabled()
    }

    private fun showDestination(folders: Loadable<FilePage>, twoX: Boolean = false) {
        val model = model()
        val state = workspace().copy(
            downloadDestinationPicker = DownloadDestinationPickerState(
                DownloadDestinationLocation("/downloads", canWrite = true),
            ),
            downloadDestinationFolders = folders,
        )
        setContent(twoX) {
            DownloadDestinationDialog(state, model, onSelected = {}, onDismiss = {})
        }
    }

    private fun showDiscovery(state: WorkspaceState, twoX: Boolean = false) {
        val model = model()
        setContent(twoX) {
            DownloadDiscoveryDialog(
                state = state,
                model = model,
                canCreateTask = true,
                onCreateTask = { _, _, _ -> },
                onDismiss = {},
            )
        }
    }

    private fun showTaskDetails(task: DownloadTask, twoX: Boolean = false) {
        setContent(twoX) { DownloadTaskDetailsDialog(task, onDismiss = {}) }
    }

    private fun showDownloads(state: WorkspaceState, twoX: Boolean = false) {
        val model = model()
        setContent(twoX) { DownloadsScreen(state, model) }
    }

    private fun showLogin(state: LoginState, twoX: Boolean = false) {
        val model = model()
        setContent(twoX) { LoginScreen(state, model) }
    }

    private fun setContent(twoX: Boolean = false, content: @Composable () -> Unit) {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, if (twoX) 2f else density.fontScale),
            ) {
                LanStashTheme {
                    Box(Modifier.requiredWidth(360.dp).height(640.dp)) {
                        content()
                    }
                }
            }
        }
    }

    private fun workspace() = WorkspaceState(
        profile = NasProfile("synthetic", "Synthetic NAS", "https://nas.example.invalid", "tester"),
        selectedModule = Module.DOWNLOADS,
    )

    private fun task() = DownloadTask(
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
    )

    private fun failure() = DsmFailure(null, "synthetic failure", "synthetic recovery")

    private fun model() = AppViewModel(ApplicationProvider.getApplicationContext<Application>())

    private fun context() = InstrumentationRegistry.getInstrumentation().targetContext
}
