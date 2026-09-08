package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.unit.Density
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleUnavailableReason
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.ui.WorkspaceShell
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class WorkspaceAccessibilityTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 大字体导航保留完整不可用原因和朗读状态() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val reason = context.getString(R.string.module_unavailable_chat)
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, fontScale = 2f),
            ) {
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
        }

        rule.onAllNodes(
            hasText(context.getString(R.string.client_chat)) and
                SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, reason),
        ).assertCountEquals(1)
        rule.onNodeWithContentDescription(context.getString(R.string.client_all_features)).performClick()
        rule.onNode(hasText(context.getString(R.string.client_chat)) and
            hasAnyAncestor(hasTestTag("client_all_features")) and
            SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, reason)).assertIsDisplayed()
    }
}
