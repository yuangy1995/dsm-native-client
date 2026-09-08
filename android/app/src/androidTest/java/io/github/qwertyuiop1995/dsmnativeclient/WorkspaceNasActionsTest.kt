package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.ui.WorkspaceShell
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class WorkspaceNasActionsTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 导航中分别提供切换Nas和退出登录() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var switchCount = 0
        var logoutCount = 0
        rule.setContent {
            LanStashTheme {
                WorkspaceShell(
                    state = WorkspaceState(
                        profile = NasProfile(
                            "synthetic",
                            "Synthetic",
                            "https://nas.example.invalid",
                            "operator",
                        ),
                    ),
                    onModuleSelected = {},
                    onRefresh = {},
                    onNavigateUp = {},
                    onSwitchNas = { switchCount += 1 },
                    onLogout = { logoutCount += 1 },
                    onMessageShown = {},
                    content = {},
                )
            }
        }

        rule.onNodeWithText("Synthetic").performClick()
        rule.onNodeWithText(context.getString(R.string.switch_nas_description)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.switch_nas))
            .assertIsDisplayed()
            .performClick()
        rule.onNodeWithText("Synthetic").performClick()
        rule.onNodeWithText(context.getString(R.string.sign_out_description))
            .assertIsDisplayed()
            .performClick()

        rule.runOnIdle { assertEquals(0, logoutCount) }
        rule.onNodeWithText(context.getString(R.string.sign_out_description)).performClick()
        rule.runOnIdle {
            assertEquals(1, switchCount)
            assertEquals(1, logoutCount)
        }
    }

    @Test
    fun 操作进行中停用切换Nas和退出登录() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                WorkspaceShell(
                    state = WorkspaceState(
                        profile = NasProfile(
                            "synthetic-busy",
                            "Synthetic busy",
                            "https://nas.example.invalid",
                            "operator",
                        ),
                        isPerformingAction = true,
                    ),
                    onModuleSelected = {},
                    onRefresh = {},
                    onNavigateUp = {},
                    onSwitchNas = {},
                    onLogout = {},
                    onMessageShown = {},
                    content = {},
                )
            }
        }

        rule.onNodeWithText("Synthetic busy").performClick()
        rule.onNodeWithText(context.getString(R.string.switch_nas)).assertIsNotEnabled()
        rule.onNodeWithText(context.getString(R.string.sign_out_description)).assertIsNotEnabled()
    }
}
