package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onParent
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferTask
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.TransferTaskCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.TransferTaskDetails
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class TransferAccessibilityAdaptiveTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 状态只在详情节点播报且错误与需刷新使用强提醒() {
        var task by mutableStateOf(task(detail = "Synthetic running detail"))
        rule.setContent {
            LanStashTheme { TransferTaskDetails(task) }
        }

        rule.onNodeWithText("Synthetic running detail").onParent().assert(
            SemanticsMatcher.expectValue(
                SemanticsProperties.LiveRegion,
                LiveRegionMode.Polite,
            ),
        )
        assertSingleLiveRegion()

        rule.runOnIdle {
            task = task.copy(
                detail = "Synthetic failed detail",
                state = TransferState.FAILED,
                errorMessage = "Synthetic failure",
            )
        }
        rule.onNodeWithText("Synthetic failed detail").onParent().assert(
            SemanticsMatcher.expectValue(
                SemanticsProperties.LiveRegion,
                LiveRegionMode.Assertive,
            ),
        )
        assertSingleLiveRegion()

        rule.runOnIdle {
            task = task.copy(
                detail = "Synthetic refresh detail",
                errorMessage = null,
                requiresRefresh = true,
            )
        }
        rule.onNodeWithText("Synthetic refresh detail").onParent().assert(
            SemanticsMatcher.expectValue(
                SemanticsProperties.LiveRegion,
                LiveRegionMode.Assertive,
            ),
        )
        assertSingleLiveRegion()
    }

    @Test
    fun 深色两倍字体与320dp宽度下操作区位于卡片底部且保持48dp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density, fontScale = 2f)) {
                LanStashTheme(darkTheme = true) {
                    Box(Modifier.width(320.dp)) {
                        TransferTaskCard(
                            task = task(
                                detail = "Synthetic paused detail",
                                state = TransferState.PAUSED,
                            ),
                            canPause = false,
                            canResume = true,
                            canRetry = false,
                            onPause = {},
                            onResume = {},
                            onCancel = {},
                            onRetry = {},
                        )
                    }
                }
            }
        }

        val resume = rule.onNodeWithText(context.getString(R.string.resume_download))
            .assertIsDisplayed()
            .assertHeightIsAtLeast(48.dp)
            .fetchSemanticsNode()
        val cancel = rule.onNodeWithText(context.getString(R.string.cancel))
            .assertIsDisplayed()
            .assertHeightIsAtLeast(48.dp)
            .fetchSemanticsNode()
        val detail = rule.onNodeWithText("Synthetic paused detail").fetchSemanticsNode()

        assertTrue(resume.boundsInRoot.top >= detail.boundsInRoot.bottom)
        assertTrue(cancel.boundsInRoot.top >= detail.boundsInRoot.bottom)
    }

    private fun assertSingleLiveRegion() {
        rule.onAllNodes(
            SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion),
            useUnmergedTree = true,
        ).assertCountEquals(1)
    }

    private fun task(
        detail: String,
        state: TransferState = TransferState.RUNNING,
    ) = TransferTask(
        id = "synthetic-transfer",
        title = "Synthetic transfer with a long title",
        detail = detail,
        direction = TransferDirection.UPLOAD,
        state = state,
        completedBytes = 50,
        totalBytes = 100,
    )
}
