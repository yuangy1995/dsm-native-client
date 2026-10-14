package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.*
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.containers.*
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerControlTarget
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import kotlinx.serialization.json.JsonObject
import org.junit.Rule
import org.junit.Test

/** 五态与实际搜索输入；手机/平板尺寸、语言和字号由仪器运行配置提供。 */
class ContainerPageStateTest {
    @get:Rule val rule = createComposeRule()
    private val failure = ContainerFailure(ContainerProblem.CHANGED)
    private fun text(id: Int) = InstrumentationRegistry.getInstrumentation().targetContext.getString(id)
    private fun visible(id: Int) = rule.onNodeWithText(text(id)).assertIsDisplayed()
    private fun loading() = rule.onNode(hasProgressBarRangeInfo(ProgressBarRangeInfo.Indeterminate)).assertIsDisplayed()
    private fun filter() = rule.onNode(hasSetTextAction()).performTextInput("absent-synthetic")

    @Test fun controlsLoadingEmptyFailureContentAndFilteredEmpty() {
        var state by mutableStateOf(ContainerControlState(busy = true))
        rule.setContent { LanStashTheme { ContainerControlsContent(state, {}, { _, _ -> false }, { false }, {}, {}) } }
        loading(); rule.runOnIdle { state = ContainerControlState(loaded = true) }; visible(R.string.cm_empty)
        rule.runOnIdle { state = ContainerControlState(failure = failure) }; visible(R.string.cm_changed)
        rule.runOnIdle { state = ContainerControlState(loaded = true, targets = listOf(ContainerControlTarget("id", "Synthetic control", false, false, false, 1, false))) }
        rule.onNodeWithText("Synthetic control").assertIsDisplayed(); filter(); visible(R.string.cm_no_matches)
    }
    @Test fun imagesLoadingEmptyFailureContentAndFilteredEmpty() {
        var state by mutableStateOf(ContainerImageState(busy = true))
        rule.setContent { LanStashTheme { ContainerImagesContent(state, true, {}, {}, { false }, {}) } }
        loading(); rule.runOnIdle { state = ContainerImageState(loaded = true) }; visible(R.string.cm_image_empty)
        rule.runOnIdle { state = ContainerImageState(failure = failure) }; visible(R.string.cm_changed)
        rule.runOnIdle { state = ContainerImageState(loaded = true, images = listOf(ContainerImageEntry("id", "synthetic/image", "stable", 1024, false))) }
        rule.onNodeWithText("synthetic/image:stable").assertIsDisplayed().performClick()
        rule.runOnIdle { state = state.copy(busy = true) }
        visible(R.string.cm_image_unused)
        rule.onNodeWithText(text(R.string.cm_image_delete)).assertIsNotEnabled()
        rule.runOnIdle { state = state.copy(busy = false) }
        rule.onNodeWithContentDescription(text(R.string.close)).performClick()
        filter(); visible(R.string.cm_image_no_matches)
    }
    @Test fun networksLoadingEmptyFailureContentAndFilteredEmpty() {
        var state by mutableStateOf(ContainerNetworkState(busy = true))
        rule.setContent { LanStashTheme { ContainerNetworksContent(state, {}, { false }, { false }, {}) } }
        loading(); rule.runOnIdle { state = ContainerNetworkState(loaded = true) }; visible(R.string.cm_network_empty)
        rule.runOnIdle { state = ContainerNetworkState(failure = failure) }; visible(R.string.cm_changed)
        rule.runOnIdle { state = ContainerNetworkState(loaded = true, networks = listOf(ContainerNetworkEntry("id", "Synthetic-network", "bridge", 0, emptyList(), false, null, null, null, JsonObject(emptyMap())))) }
        rule.onNodeWithText("Synthetic-network").assertIsDisplayed(); filter(); visible(R.string.cm_network_no_matches)
    }
}
