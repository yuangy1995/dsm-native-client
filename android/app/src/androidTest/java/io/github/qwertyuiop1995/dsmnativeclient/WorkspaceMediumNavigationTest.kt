package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import android.view.KeyEvent
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleUnavailableReason
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.ui.WORKSPACE_BOTTOM_NAVIGATION_TEST_TAG
import io.github.qwertyuiop1995.dsmnativeclient.ui.WORKSPACE_NAVIGATION_RAIL_TEST_TAG
import io.github.qwertyuiop1995.dsmnativeclient.ui.WORKSPACE_MODAL_DRAWER_TEST_TAG
import io.github.qwertyuiop1995.dsmnativeclient.ui.WorkspaceShell
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class WorkspaceMediumNavigationTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 中等宽度大字体使用单一Rail并保留五个主入口状态() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var selectedModule: Module? = null
        setMediumContent(
            state = workspaceState(
                selectedModule = Module.DOWNLOADS,
                availability = listOf(
                    ModuleAvailability(
                        module = Module.DOWNLOADS,
                        isAvailable = false,
                        reason = ModuleUnavailableReason.DOWNLOAD_STATION,
                    ),
                ),
                conversations = Loadable.Ready(
                    listOf(
                        ChatConversation(
                            id = "synthetic-conversation",
                            title = "Synthetic conversation",
                            kind = ConversationKind.DIRECT,
                            unreadCount = 7,
                        ),
                    ),
                ),
            ),
            fontScale = 2f,
            darkTheme = true,
            onModuleSelected = { selectedModule = it },
        )

        rule.onNodeWithTag(WORKSPACE_NAVIGATION_RAIL_TEST_TAG).assertIsDisplayed()
        rule.onNodeWithTag(WORKSPACE_BOTTOM_NAVIGATION_TEST_TAG).assertDoesNotExist()
        val isRailItem = hasAnyAncestor(hasTestTag(WORKSPACE_NAVIGATION_RAIL_TEST_TAG))

        listOf(
            Module.FILES,
            Module.PHOTOS,
            Module.CHAT,
            Module.DOWNLOADS,
            Module.TRANSFERS,
        ).forEach { module ->
            rule.onNode(
                hasText(context.getString(moduleTitle(module))) and hasClickAction() and isRailItem,
            ).assertIsDisplayed()
        }

        rule.onNode(
            hasText(context.getString(R.string.client_downloads)) and hasClickAction() and isRailItem,
        ).assertIsSelected()
        rule.onAllNodes(
            hasText(context.getString(R.string.client_chat)) and
                isRailItem and
                SemanticsMatcher.expectValue(
                    SemanticsProperties.StateDescription,
                    context.resources.getQuantityString(R.plurals.unread_count, 7, 7),
                ),
        ).assertCountEquals(1)
        rule.onAllNodes(
            hasText(context.getString(R.string.client_downloads)) and
                isRailItem and
                SemanticsMatcher.expectValue(
                    SemanticsProperties.StateDescription,
                    context.getString(R.string.module_unavailable_downloads),
                ),
        ).assertCountEquals(1)

        rule.onNode(
            hasText(context.getString(R.string.client_photos)) and hasClickAction() and isRailItem,
        ).performClick()
        rule.runOnIdle { assertEquals(Module.PHOTOS, selectedModule) }
    }

    @Test
    fun 中等宽度从Rail菜单可达低频入口且选择后关闭抽屉() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var selectedModule: Module? = null
        setMediumContent(
            state = workspaceState(),
            onModuleSelected = { selectedModule = it },
        )

        rule.onNodeWithContentDescription(context.getString(R.string.client_all_features))
            .assertIsDisplayed()
            .performClick()
        rule.onNodeWithText(context.getString(R.string.client_app_settings)).performScrollTo()
        val settingsMatcher = hasText(context.getString(R.string.client_app_settings))
        val settings = rule.onNode(settingsMatcher)
        rule.waitUntil(timeoutMillis = 5_000) {
            runCatching { settings.assertIsDisplayed() }.isSuccess
        }
        settings.performClick()
        rule.runOnIdle { assertEquals(Module.SETTINGS, selectedModule) }
        rule.waitUntil(timeoutMillis = 5_000) {
            runCatching { settings.assertIsNotDisplayed() }.isSuccess
        }
        rule.onNodeWithTag(WORKSPACE_NAVIGATION_RAIL_TEST_TAG).assertIsDisplayed()
    }

    @Test
    fun 全部功能在宽度改变时保持可用且关闭后不会复活() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var availableWidth by mutableStateOf(700.dp)
        rule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(density = 1f)) {
                LanStashTheme {
                    Box(Modifier.requiredWidth(availableWidth).height(720.dp)) {
                        WorkspaceShell(
                            state = workspaceState(),
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
        }

        rule.onNodeWithContentDescription(context.getString(R.string.client_all_features))
            .performClick()
        rule.onNodeWithTag(WORKSPACE_MODAL_DRAWER_TEST_TAG).assertIsDisplayed()

        rule.runOnIdle { availableWidth = 900.dp }
        rule.onNodeWithTag(WORKSPACE_MODAL_DRAWER_TEST_TAG).assertIsDisplayed()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        rule.onNodeWithTag(WORKSPACE_MODAL_DRAWER_TEST_TAG).assertDoesNotExist()
        rule.runOnIdle { availableWidth = 700.dp }
        rule.onNodeWithTag(WORKSPACE_MODAL_DRAWER_TEST_TAG).assertDoesNotExist()
        rule.onNodeWithTag(WORKSPACE_NAVIGATION_RAIL_TEST_TAG).assertIsDisplayed()
    }

    @Test
    fun 打开全部功能期间改变宽度也能正常关闭() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var availableWidth by mutableStateOf(700.dp)
        rule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(density = 1f)) {
                LanStashTheme {
                    Box(Modifier.requiredWidth(availableWidth).height(720.dp)) {
                        WorkspaceShell(
                            state = workspaceState(),
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
        }

        rule.onNodeWithContentDescription(context.getString(R.string.client_all_features))
            .performClick()
        rule.runOnIdle { availableWidth = 900.dp }
        rule.onNodeWithTag(WORKSPACE_MODAL_DRAWER_TEST_TAG).assertIsDisplayed()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        rule.onNodeWithTag(WORKSPACE_MODAL_DRAWER_TEST_TAG).assertDoesNotExist()
        rule.runOnIdle { availableWidth = 700.dp }
        rule.onNodeWithTag(WORKSPACE_MODAL_DRAWER_TEST_TAG).assertDoesNotExist()
        rule.onNodeWithTag(WORKSPACE_NAVIGATION_RAIL_TEST_TAG).assertIsDisplayed()
    }

    private fun setMediumContent(
        state: WorkspaceState,
        fontScale: Float = 1f,
        darkTheme: Boolean = false,
        onModuleSelected: (Module) -> Unit,
    ) {
        rule.setContent {
            CompositionLocalProvider(
                LocalDensity provides Density(density = 1f, fontScale = fontScale),
            ) {
                LanStashTheme(darkTheme = darkTheme) {
                    Box(Modifier.requiredWidth(700.dp).height(720.dp)) {
                        WorkspaceShell(
                            state = state,
                            pinned = PinnedModules(listOf(ClientDestination.FILES, ClientDestination.PHOTOS, ClientDestination.CHAT,
                                ClientDestination.DOWNLOADS, ClientDestination.TASKS)),
                            onModuleSelected = onModuleSelected,
                            onRefresh = {},
                            onNavigateUp = {},
                            onLogout = {},
                            onMessageShown = {},
                            content = {},
                        )
                    }
                }
            }
        }
    }

    private fun workspaceState(
        selectedModule: Module = Module.FILES,
        availability: List<ModuleAvailability> = emptyList(),
        conversations: Loadable<List<ChatConversation>> = Loadable.Idle,
    ) = WorkspaceState(
        profile = NasProfile(
            id = "synthetic",
            name = "Synthetic",
            address = "https://nas.example.invalid",
            username = "operator",
        ),
        selectedModule = selectedModule,
        availability = availability,
        conversations = conversations,
    )

    private fun moduleTitle(module: Module): Int = when (module) {
        Module.FILES -> R.string.client_files
        Module.PHOTOS -> R.string.client_photos
        Module.CHAT -> R.string.client_chat
        Module.DOWNLOADS -> R.string.client_downloads
        Module.TRANSFERS -> R.string.client_tasks
        else -> error("本测试只覆盖 Rail 主入口")
    }
}
