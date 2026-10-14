package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.lifecycle.ViewModelStore
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.storage.ClientHomePreferences
import io.github.qwertyuiop1995.dsmnativeclient.ui.ClientHomeScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.ClientWorkspace
import io.github.qwertyuiop1995.dsmnativeclient.ui.home.ClientHomeEditor
import io.github.qwertyuiop1995.dsmnativeclient.ui.home.HomeLayout
import io.github.qwertyuiop1995.dsmnativeclient.ui.home.HomeSection
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import kotlinx.coroutines.CompletableDeferred
import java.io.File
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** 使用合成工作区与隔离模拟器；只临时修改自己的界面偏好键并在结束后恢复。 */
class HomeCustomizationUiTest {
    @get:Rule val rule = createComposeRule()
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val preferences = context.getSharedPreferences("lanstash_interface", Context.MODE_PRIVATE)
    private val models = ViewModelStore()
    private var oldHome: String? = null
    private var oldPinned: String? = null
    private fun text(id: Int) = InstrumentationRegistry.getInstrumentation().targetContext.getString(id)

    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (InstrumentationRegistry.getArguments().getString("captureHomeUi") != "true") return
        rule.waitForIdle()
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val directory = File(context.getExternalFilesDir(null), "approved-home-review").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @Before fun preservePreferences() {
        oldHome = preferences.getString("hidden_home_sections_v1", null)
        oldPinned = preferences.getString("pinned_modules_v1", null)
    }

    @After fun restorePreferences() {
        models.clear()
        preferences.edit().apply {
            if (oldHome == null) remove("hidden_home_sections_v1") else putString("hidden_home_sections_v1", oldHome)
            if (oldPinned == null) remove("pinned_modules_v1") else putString("pinned_modules_v1", oldPinned)
        }.commit()
    }

    @Test fun 取消显隐草稿不保存() {
        var open by mutableStateOf(true)
        var saves = 0
        rule.setContent {
            LanStashTheme {
                if (open) ClientHomeEditor(HomeLayout(), onSave = { saves++; true }, onDismiss = { open = false })
            }
        }
        capture("home-customize")
        rule.onNodeWithTag("home_section_toggle_quickActions").performClick().assertIsOff()
        rule.onNodeWithContentDescription(text(R.string.close)).performClick()
        rule.onNodeWithTag("home_editor_save").assertDoesNotExist()
        rule.runOnIdle { assertEquals(0, saves) }
    }

    @Test fun 全部隐藏保存后有恢复入口且任务数据保留() {
        val state = ApprovedUiFixture.state()
        var layout by mutableStateOf(HomeLayout())
        var open by mutableStateOf(true)
        rule.setContent {
            LanStashTheme {
                ClientHomeScreen(state, emptyList(), {}, {}, {}, layout) { open = true }
                if (open) ClientHomeEditor(layout, onSave = {
                    val result = ClientHomePreferences(context).save(it)
                    if (result) layout = ClientHomePreferences(context).load()
                    result
                }, onDismiss = { open = false })
            }
        }
        HomeSection.entries.forEach { rule.onNodeWithTag("home_section_toggle_${it.id}").performClick().assertIsOff() }
        rule.onNodeWithTag("home_editor_save").performClick()
        rule.onNodeWithText(text(R.string.client_home_hidden_title)).assertIsDisplayed()
        capture("home-empty")
        rule.onNodeWithTag("home_section_activeTasks").assertDoesNotExist()
        rule.runOnIdle {
            assertEquals(HomeSection.entries.toSet(), ClientHomePreferences(context).load().hidden)
            assertEquals(1, state.transfers.size)
        }
        rule.onNodeWithTag("customize_home").performClick()
        rule.onNodeWithText(text(R.string.client_restore_defaults)).performClick()
        HomeSection.entries.forEach { rule.onNodeWithTag("home_section_toggle_${it.id}").assertIsOn() }
        rule.onNodeWithTag("home_editor_save").performClick()
        rule.onNodeWithTag("home_section_quickActions").assertIsDisplayed()
        capture("home-default")
    }

    @Test fun 保存失败保留草稿并允许重试() {
        var open by mutableStateOf(true)
        var saves = 0
        var saved: HomeLayout? = null
        rule.setContent {
            LanStashTheme {
                if (open) ClientHomeEditor(HomeLayout(), onSave = {
                    saves++
                    if (saves == 1) false else { saved = it; true }
                }, onDismiss = { open = false })
            }
        }
        rule.onNodeWithTag("home_section_toggle_recentItems").performClick()
        rule.onNodeWithTag("home_editor_save").performClick()
        rule.onNodeWithText(text(R.string.client_home_save_failed)).assertIsDisplayed()
        rule.onNodeWithTag("home_section_toggle_recentItems").assertIsOff()
        rule.onNodeWithTag("home_editor_save").performClick()
        rule.runOnIdle {
            assertEquals(setOf(HomeSection.RECENT_ITEMS), saved?.hidden)
            assertEquals(2, saves)
            assertFalse(open)
        }
    }

    @Test fun 权限过滤和切换账号不改用户显隐选择() {
        val layout = HomeLayout().withVisibility(HomeSection.COMMON_LOCATIONS, false)
        var state by mutableStateOf(ApprovedUiFixture.state())
        rule.setContent { LanStashTheme { ClientHomeScreen(state, emptyList(), {}, {}, {}, layout) } }
        rule.onNodeWithTag("home_section_quickActions").assertIsDisplayed()
        rule.runOnIdle {
            state = state.copy(profile = state.profile.copy(id = "synthetic-second", username = "reader"),
                availability = Module.entries.map { ModuleAvailability(it, false) })
        }
        rule.onNodeWithTag("home_section_quickActions").assertDoesNotExist()
        rule.onNodeWithTag("home_section_commonLocations").assertDoesNotExist()
        rule.runOnIdle { state = ApprovedUiFixture.state() }
        rule.onNodeWithTag("home_section_quickActions").assertIsDisplayed()
        rule.runOnIdle { assertEquals(setOf(HomeSection.COMMON_LOCATIONS), layout.hidden) }
    }

    @Test fun 重新读取首页偏好不覆盖其他界面设置() {
        preferences.edit().putString("pinned_modules_v1", "files|photos").commit()
        val layout = HomeLayout().withVisibility(HomeSection.ACTIVE_TASKS, false)
        assertTrue(ClientHomePreferences(context).save(layout))
        assertEquals(layout, ClientHomePreferences(context).load())
        assertEquals("files|photos", preferences.getString("pinned_modules_v1", null))
    }

    @Test fun 保存进行中阻止重复提交与关闭() {
        val completion = CompletableDeferred<Boolean>()
        var open by mutableStateOf(true)
        var saves = 0
        rule.setContent {
            LanStashTheme {
                if (open) ClientHomeEditor(HomeLayout(), onSave = { saves++; completion.await() },
                    onDismiss = { open = false })
            }
        }
        rule.onNodeWithTag("home_editor_save").performClick().assertIsNotEnabled()
        rule.onNodeWithTag("home_section_toggle_quickActions").assertIsNotEnabled()
        rule.onNodeWithContentDescription(text(R.string.close)).performTouchInput { click() }
        rule.runOnIdle { assertTrue(open); assertEquals(1, saves); completion.complete(true) }
        rule.waitForIdle()
        rule.runOnIdle { assertFalse(open) }
    }

    @Test fun 深色完整工作区保留首页编辑与全局任务入口() {
        val model = ApprovedUiFixture.model().also { models.put("home-dark", it) }
        ClientHomePreferences(context).save(HomeLayout())
        rule.setContent {
            LanStashTheme(darkTheme = true) {
                val state by model.workspace.collectAsState()
                ClientWorkspace(requireNotNull(state), model)
            }
        }
        rule.onNodeWithTag("home_section_quickActions").assertIsDisplayed()
        rule.onNodeWithContentDescription(text(R.string.client_tasks)).assertIsDisplayed()
        capture("workspace-home-dark")
        rule.onNodeWithTag("customize_home").performClick()
        rule.onNodeWithTag("home_section_toggle_quickActions").assertIsOn()
        capture("workspace-home-editor-dark")
        rule.onNodeWithContentDescription(text(R.string.close)).performClick()
        rule.onNodeWithContentDescription(text(R.string.client_tasks)).performClick()
        rule.onNodeWithText(text(R.string.client_phone_transfers)).assertIsDisplayed()
    }

    @Test fun 当前系统字号下首页与自定义面板保持可操作() {
        val model = ApprovedUiFixture.model().also { models.put("home-large-font", it) }
        ClientHomePreferences(context).save(HomeLayout())
        rule.setContent {
            LanStashTheme {
                val state by model.workspace.collectAsState()
                ClientWorkspace(requireNotNull(state), model)
            }
        }
        rule.onNodeWithContentDescription(text(R.string.client_tasks)).assertIsDisplayed()
        capture("workspace-home-font-${context.resources.configuration.fontScale}")
        rule.onNodeWithTag("customize_home").performClick()
        rule.onNodeWithTag("home_section_toggle_quickActions").performScrollTo().performClick()
        rule.onNodeWithTag("home_editor_save").performScrollTo().assertIsDisplayed()
        capture("workspace-home-editor-font-${context.resources.configuration.fontScale}")
        rule.onNodeWithTag("home_editor_save").performClick()
        rule.onNodeWithTag("home_section_quickActions").assertDoesNotExist()
        rule.onNodeWithContentDescription(text(R.string.client_tasks)).assertIsDisplayed()
    }
}
