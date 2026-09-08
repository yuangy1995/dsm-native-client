package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import android.view.KeyEvent
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.storage.ClientNavigationPreferences
import io.github.qwertyuiop1995.dsmnativeclient.ui.WorkspaceShell
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlinx.coroutines.CompletableDeferred

class ApprovedNavigationUiTest {
    @get:Rule val rule = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun text(id: Int) = context.getString(id)

    @Test fun 隐藏所有底部入口后仍可从全部功能打开并重新自定义() {
        var selected: ClientDestination? = null
        var customizing = false
        rule.setContent { LanStashTheme { WorkspaceShell(ApprovedUiFixture.state(), {}, {}, {}, onLogout = {}, onMessageShown = {},
            pinned = PinnedModules(emptyList()), onDestinationSelected = { selected = it }, onCustomize = { customizing = true }) {} } }
        rule.onNodeWithTag("client_bottom_navigation").assertDoesNotExist()
        rule.onNodeWithContentDescription(text(R.string.client_all_features)).performClick()
        rule.onNodeWithText(text(R.string.client_photos)).assertIsDisplayed().performClick()
        rule.runOnIdle { assertEquals(ClientDestination.PHOTOS, selected) }
        rule.onNodeWithContentDescription(text(R.string.client_all_features)).performClick()
        rule.onNodeWithText(text(R.string.client_custom_navigation)).performScrollTo().performClick()
        rule.runOnIdle { assertTrue(customizing) }
    }

    @Test fun 替换只改变选中的固定项并保持五项上限() {
        var saved: PinnedModules? = null
        var closed by mutableStateOf(false)
        rule.setContent { LanStashTheme { if (!closed) ClientNavigationEditor(PinnedModules(), { saved = it; true }, { closed = true }) } }
        // 通过其他模块行中的替换按钮进入，保持与可见行的关联。
        rule.onNode(hasText(text(R.string.client_replace)) and hasAnyAncestor(hasTestTag("pin_candidate_tasks")))
            .performScrollTo().performClick()
        rule.onNodeWithText(text(R.string.client_replace_hint)).assertIsDisplayed()
        rule.onNodeWithTag("confirm_navigation_replacement").performScrollTo().performClick()
        rule.onNodeWithText(text(R.string.save)).performClick()
        rule.runOnIdle {
            assertEquals(5, saved!!.items.size)
            assertEquals(ClientDestination.TASKS, saved!!.items.first())
            assertEquals(ClientDestination.defaults.drop(1), saved!!.items.drop(1))
        }
    }

    @Test fun 长按句柄拖动和无障碍移动均改变草稿顺序() {
        var saved: PinnedModules? = null
        rule.setContent { LanStashTheme { ClientNavigationEditor(PinnedModules(), { saved = it; true }, {}) } }
        rule.onNodeWithTag("reorder_home").performTouchInput {
            down(center)
            advanceEventTime(700)
            moveBy(Offset(0f, 190f), delayMillis = 200)
            up()
        }
        rule.onNodeWithText(text(R.string.save)).performClick()
        rule.runOnIdle { assertEquals(ClientDestination.FILES, saved!!.items.first()) }
    }

    @Test fun 句柄点击菜单可上移而不依赖拖动() {
        var saved: PinnedModules? = null
        rule.setContent { LanStashTheme { ClientNavigationEditor(PinnedModules(), { saved = it; true }, {}) } }
        rule.onNodeWithTag("reorder_files").performClick()
        rule.onNodeWithText(context.getString(R.string.client_move_up, text(R.string.client_files))).performClick()
        rule.onNodeWithText(text(R.string.save)).performClick()
        rule.runOnIdle { assertEquals(ClientDestination.FILES, saved!!.items.first()) }
    }

    @Test fun 取消编辑不保存草稿且配置独立于NAS() {
        val preferences = ClientNavigationPreferences(context)
        val before = preferences.load()
        try {
            val value = PinnedModules(listOf(ClientDestination.DOWNLOADS, ClientDestination.FILES))
            assertTrue(preferences.save(value))
            assertEquals(value, ClientNavigationPreferences(context).load())
            var saved = false
            var closed = false
            rule.setContent { LanStashTheme { ClientNavigationEditor(value, { saved = true; true }, { closed = true }) } }
            rule.onNodeWithContentDescription(context.getString(R.string.client_hide_destination, text(R.string.client_files))).performClick()
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            rule.runOnIdle { assertTrue(closed); assertFalse(saved) }
            assertEquals(value, preferences.load())
        } finally { preferences.save(before) }
    }

    @Test fun 保存期间不可重复操作且失败保留草稿供重试() {
        val result = CompletableDeferred<Boolean>()
        var saves = 0
        rule.setContent { LanStashTheme { ClientNavigationEditor(PinnedModules(), { saves++; result.await() }, {}) } }
        rule.onNodeWithText(text(R.string.save)).performClick()
        rule.onNodeWithText(text(R.string.processing_action)).assertIsNotEnabled()
        rule.onAllNodes(SemanticsMatcher("保存期间不可执行无障碍重排") {
            !it.config.getOrNull(androidx.compose.ui.semantics.SemanticsActions.CustomActions).isNullOrEmpty()
        }, useUnmergedTree = true).assertCountEquals(0)
        rule.runOnIdle { assertEquals(1, saves); result.complete(false) }
        rule.onNodeWithTag("navigation_editor_list").performScrollToNode(hasText(text(R.string.client_navigation_save_failed)))
        rule.onNodeWithText(text(R.string.client_navigation_save_failed)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.save)).assertIsEnabled()
    }
}
