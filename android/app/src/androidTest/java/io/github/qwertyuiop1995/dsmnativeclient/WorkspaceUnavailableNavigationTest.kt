package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleUnavailableReason
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.ui.WorkspaceShell
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class WorkspaceUnavailableNavigationTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 不可用模块在导航中保留入口和具体原因() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
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
                        availability = listOf(
                            ModuleAvailability(
                                Module.CHAT,
                                isAvailable = false,
                                reason = ModuleUnavailableReason.CHAT_SERVICE,
                            ),
                        ),
                    ),
                    onModuleSelected = {},
                    onRefresh = {},
                    onNavigateUp = {},
                    onLogout = {},
                    onMessageShown = {},
                    content = {},
                )
            }
        }

        rule.onNodeWithContentDescription(context.getString(R.string.client_all_features)).performClick()
        rule.onAllNodesWithText(context.getString(R.string.client_chat)).assertCountEquals(2)
        rule.onNode(hasText(context.getString(R.string.client_chat)) and
            hasAnyAncestor(hasTestTag("client_all_features")) and
            SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, context.getString(R.string.module_unavailable_chat))).assertIsDisplayed()
    }
}
