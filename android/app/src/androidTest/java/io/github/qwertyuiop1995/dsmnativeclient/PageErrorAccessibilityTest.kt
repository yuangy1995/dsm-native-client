package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.SemanticsMatcher
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.test.junit4.createComposeRule
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.ui.PageStateContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.PageUiState
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class PageErrorAccessibilityTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 页面错误通过即时语义区域通知屏幕阅读器() {
        rule.setContent {
            LanStashTheme {
                PageStateContent(
                    state = PageUiState.Error(DsmFailure(null, "synthetic", "retry")),
                    emptyTitle = "empty",
                    emptyMessage = "empty",
                    emptyIcon = Icons.Outlined.Info,
                    filteredEmptyTitle = "filtered",
                    filteredEmptyMessage = "filtered",
                    filteredEmptyIcon = Icons.Outlined.Info,
                    onRetry = {},
                    content = {},
                )
            }
        }

        rule.onNode(
            SemanticsMatcher.expectValue(
                SemanticsProperties.LiveRegion,
                LiveRegionMode.Assertive,
            ),
        ).assertExists()
    }
    @Test fun 实际权限错误仍显示恢复方式() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent { LanStashTheme {
            PageStateContent(state = PageUiState.Error(DsmFailure(null, "synthetic", "synthetic", kind = DsmErrorKind.PERMISSION_DENIED)),
                emptyTitle = "empty", emptyMessage = "empty", emptyIcon = Icons.Outlined.Info,
                filteredEmptyTitle = "filtered", filteredEmptyMessage = "filtered", filteredEmptyIcon = Icons.Outlined.Info,
                onRetry = {}, content = {})
        } }
        rule.onNodeWithText(context.getString(R.string.error_permission_denied)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.error_permission_denied_recovery)).assertIsDisplayed()
    }
}
