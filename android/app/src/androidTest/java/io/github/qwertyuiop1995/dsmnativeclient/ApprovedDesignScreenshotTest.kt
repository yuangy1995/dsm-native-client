package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.network.ConnectionStatus
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import io.github.qwertyuiop1995.dsmnativeclient.ui.ClientWorkspace
import io.github.qwertyuiop1995.dsmnativeclient.ui.login.LoginScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.After
import org.junit.Rule
import org.junit.Test
import java.io.File

/** 仅导出合成内容，覆盖已确认页面结构；不把渲染通过当作真实 NAS 通过。 */
class ApprovedDesignScreenshotTest {
    @get:Rule val rule = createComposeRule()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val store = ViewModelStore()
    private val model = ApprovedUiFixture.model().also { store.put("preview", it) }
    private enum class Page { HOME, FILES, PHOTOS, CHAT, DEVICE, TASKS, NAVIGATION, LOGIN_DEVICES, LOGIN_FORM, LOGIN_LOADING }
    private data class Scenario(val page: Page, val locale: String, val dark: Boolean, val scale: Float = 1f)

    @After fun close() { store.clear() }

    @Test fun 已确认页面在中英浅深色和放大字体下渲染() {
        ApprovedUiFixture.seedThumbnails(model)
        SecureProfileStore(app).recordRecentDirectory(ApprovedUiFixture.profile.id, "/synthetic/work")
        SecureProfileStore(app).recordRecentDirectory(ApprovedUiFixture.profile.id, "/synthetic/family")
        val locale = app.resources.configuration.locales[0].toLanguageTag()
        val scale = app.resources.configuration.fontScale
        var scenario by mutableStateOf(Scenario(Page.HOME, locale, false, scale))
        rule.setContent {
                LanStashTheme(darkTheme = scenario.dark) {
                    Surface(Modifier.fillMaxSize()) {
                        key(scenario) {
                            when (scenario.page) {
                                Page.LOGIN_DEVICES -> LoginScreen(LoginState(profiles = listOf(ApprovedUiFixture.profile)), model)
                                Page.LOGIN_FORM -> LoginScreen(LoginState(), model)
                                Page.LOGIN_LOADING -> LoginScreen(LoginState(isConnecting = true, connectionStatus = ConnectionStatus.AUTHENTICATING), model)
                                else -> {
                                    val state by model.workspace.collectAsState()
                                    ClientWorkspace(requireNotNull(state), model)
                                }
                            }
                        }
                    }
                }
        }
        val capture = InstrumentationRegistry.getArguments().getString("captureApprovedUi") == "true"
        val folder = File(app.getExternalFilesDir(null), "approved-ui-review")
        if (capture) folder.mkdirs()
        // 字号和语言由隔离模拟器的系统设置提供，避免 Dialog 重建密度后漏测放大文字。
        Page.entries.flatMap { page -> listOf(Scenario(page, locale, false, scale), Scenario(page, locale, true, scale)) }
            .forEach { next ->
                rule.runOnIdle {
                    ApprovedUiFixture.setState(model, ApprovedUiFixture.state())
                    ApprovedUiFixture.resetNavigation(model)
                    scenario = next
                }
                rule.waitForIdle()
                val context = app
                val destination = when (next.page) {
                    Page.FILES -> R.string.client_files
                    Page.PHOTOS -> R.string.client_photos
                    Page.CHAT -> R.string.client_chat
                    Page.DEVICE -> R.string.client_device
                    else -> null
                }
                if (destination != null) rule.onNode(hasContentDescription(context.getString(destination)) and
                    hasAnyAncestor(hasTestTag("client_bottom_navigation"))).performClick()
                if (next.page == Page.TASKS) rule.onNodeWithContentDescription(context.getString(R.string.client_tasks)).performClick()
                if (next.page == Page.NAVIGATION) {
                    rule.onNodeWithContentDescription(context.getString(R.string.client_all_features)).performClick()
                    rule.onNodeWithText(context.getString(R.string.client_custom_navigation)).performScrollTo().performClick()
                }
                rule.mainClock.advanceTimeBy(400)
                rule.waitForIdle()
                val root = if (next.page in listOf(Page.NAVIGATION, Page.LOGIN_LOADING)) rule.onNode(isDialog()) else rule.onRoot()
                root.assertIsDisplayed()
                if (capture) {
                    val name = "${next.page.name.lowercase()}-${next.locale}-${if (next.dark) "dark" else "light"}-${next.scale}.png"
                    val bitmap = if (next.page == Page.LOGIN_LOADING) InstrumentationRegistry.getInstrumentation().uiAutomation.let {
                        it.waitForIdle(500, 5_000)
                        it.takeScreenshot()
                    }
                        else root.captureToImage().asAndroidBitmap()
                    File(folder, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                }
            }
    }
}
