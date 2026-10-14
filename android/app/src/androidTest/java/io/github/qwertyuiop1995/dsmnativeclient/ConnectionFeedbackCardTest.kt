package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasConnectionState
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasConnectionDirectory
import io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ConnectionListItem
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ConnectionMutationFailureCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ConnectionMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ConnectionSavingCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasConnectionContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class ConnectionFeedbackCardTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 保存中保留目标并使用礼貌播报() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent { LanStashTheme { ConnectionSavingCard(web()) } }

        rule.onNodeWithText(context.getString(R.string.connection_disconnecting_title)).assertIsDisplayed()
        rule.onNodeWithText("operator", substring = true).assertIsDisplayed()
        rule.onNode(
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite),
        ).assertExists()
    }

    @Test
    fun 已确认成功显示目标与计数且无需再次刷新() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setFeedback(result(MutationResultStatus.CONFIRMED_SUCCESS, MutationResultCounts(1, 0, 0)))

        rule.onNodeWithText(context.getString(R.string.connection_feedback_disconnected_message))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.connection_feedback_counts, 1, 0, 0))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.done)).assertIsEnabled()
    }

    @Test
    fun 提交未确认刷新前禁用完成并保持强提醒() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var refreshes = 0
        setFeedback(
            result(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, MutationResultCounts(0, 0, 1)),
            onRefresh = { refreshes += 1 },
        )

        rule.onNodeWithText(context.getString(R.string.connection_feedback_unverified_message))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.done)).assertIsNotEnabled()
        rule.onNodeWithText(context.getString(R.string.refresh_and_check_connection)).performClick()
        rule.onNode(
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Assertive),
        ).assertExists()
        rule.runOnIdle { check(refreshes == 1) }
    }

    @Test
    fun 刷新后目标仍在继续保留重复提交保护() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setFeedback(
            result(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, MutationResultCounts(0, 0, 1)),
            refreshCompleted = true,
            targetStillPresent = true,
        )

        rule.onNodeWithText(context.getString(R.string.connection_refresh_still_present)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.done)).assertIsNotEnabled()
    }

    @Test
    fun 当前连接失败提供重新登录核对路径且不自动重试() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                ConnectionMutationFailureCard(
                    target = web(current = true),
                    failure = DsmFailure(
                        null,
                        "Synthetic failure",
                        "Synthetic recovery",
                        kind = DsmErrorKind.CONNECTION_FAILED,
                    ),
                    onDismiss = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.connection_feedback_current_recovery))
            .assertIsDisplayed()
    }

    @Test
    fun 列表使用可见断开按钮并保留按钮角色和禁用状态() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var enabled by mutableStateOf(true)
        rule.setContent {
            LanStashTheme {
                ConnectionListItem(web(), enabled = enabled, onDisconnect = {})
            }
        }

        rule.onNodeWithText(context.getString(R.string.disconnect_connection))
            .assertIsEnabled()
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
        rule.onNodeWithText(
            context.getString(R.string.connection_account_and_service, "operator", "HTTPS"),
        ).assertIsDisplayed()
        val description = context.getString(
            R.string.disconnect_connection_accessibility,
            "operator",
            "Synthetic browser",
            context.getString(R.string.web_connection),
        )
        val button = rule.onNodeWithContentDescription(description).fetchSemanticsNode()
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        check(button.boundsInRoot.height >= 48f * density)

        rule.runOnIdle { enabled = false }
        rule.onNodeWithText(context.getString(R.string.disconnect_connection)).assertIsNotEnabled()
    }

    @Test
    fun 整屏明确区分能力不可用与合法空列表() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var available by mutableStateOf(false)
        rule.setContent {
            LanStashTheme {
                NasConnectionContent(
                    state = NasConnectionState(loaded = true, directory = if (available) NasConnectionDirectory(emptyList(), true) else null),
                    onRequestDisconnect = { false }, onCancelRequest = {}, onConfirmRequest = { false },
                    onRefresh = {}, onDismissResult = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.connections_unavailable)).assertIsDisplayed()
        rule.runOnIdle { available = true }
        rule.onNodeWithText(context.getString(R.string.no_active_connections)).assertIsDisplayed()
    }

    @Test
    fun 网页服务与当前会话确认使用不同影响文案且拒绝启动时保留弹窗() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var target by mutableStateOf<ActiveConnection?>(web())
        var confirmations = 0
        rule.setContent {
            LanStashTheme {
                NasConnectionContent(
                    state = NasConnectionState(loaded = true, directory = NasConnectionDirectory(emptyList(), true), confirmation = target),
                    onRequestDisconnect = { false }, onCancelRequest = { target = null },
                    onConfirmRequest = { confirmations += 1; false }, onRefresh = {}, onDismissResult = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.disconnect_connection_app_risk), substring = true)
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.disconnect_current_connection)).performClick()
        rule.onNodeWithText(context.getString(R.string.disconnect_connection_title)).assertIsDisplayed()
        rule.runOnIdle { check(confirmations == 1); target = service() }
        rule.onNodeWithText(context.getString(R.string.disconnect_service_connection_message), substring = true)
            .assertIsDisplayed()
        rule.runOnIdle { target = web(current = true) }
        rule.onNodeWithText(context.getString(R.string.disconnect_current_connection_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.disconnect_current_connection)).assertIsDisplayed()
    }

    @Test
    fun 刷新失败保持门禁而刷新中按钮和完成动作均禁用() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val failure = DsmFailure(
            null,
            "Synthetic refresh failed",
            "Synthetic refresh recovery",
            kind = DsmErrorKind.CONNECTION_FAILED,
        )
        rule.setContent {
            LanStashTheme {
                ConnectionMutationFeedbackCard(
                    target = web(),
                    result = result(
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        MutationResultCounts(0, 0, 1),
                    ),
                    refreshCompleted = false,
                    targetStillPresent = false,
                    refreshFailure = failure,
                    refreshInProgress = true,
                    onRefresh = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.refreshing_connection)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.refresh_and_check_connection)).assertIsNotEnabled()
        rule.onNodeWithText(context.getString(R.string.done)).assertIsNotEnabled()
    }

    @Test
    fun 刷新后目标消失显示明确核对结论() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setFeedback(
            result(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, MutationResultCounts(0, 0, 1)),
            refreshCompleted = true,
            targetStillPresent = false,
        )
        rule.onNodeWithText(context.getString(R.string.connection_refresh_target_absent))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.done)).assertIsEnabled()
    }

    @Test
    fun 深色两倍字体下长反馈仍可滚动到恢复动作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                LanStashTheme(darkTheme = true) {
                    Column(Modifier.verticalScroll(rememberScrollState())) {
                        ConnectionMutationFeedbackCard(
                            target = web(current = true),
                            result = result(
                                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                                MutationResultCounts(0, 0, 1),
                            ),
                            refreshCompleted = false,
                            targetStillPresent = true,
                            refreshFailure = null,
                            onRefresh = {},
                            onDismiss = {},
                        )
                    }
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.refresh_and_check_connection))
            .performScrollTo().assertIsDisplayed()
    }

    private fun setFeedback(
        result: MutationResult,
        refreshCompleted: Boolean = false,
        targetStillPresent: Boolean = false,
        onRefresh: () -> Unit = {},
    ) {
        rule.setContent {
            LanStashTheme {
                ConnectionMutationFeedbackCard(
                    target = web(),
                    result = result,
                    refreshCompleted = refreshCompleted,
                    targetStillPresent = targetStillPresent,
                    refreshFailure = null,
                    onRefresh = onRefresh,
                    onDismiss = {},
                )
            }
        }
    }

    private fun result(status: MutationResultStatus, counts: MutationResultCounts) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = "connectionDisconnect",
        submitted = status != MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        requiresRefresh = status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        ),
        counts = counts,
    )

    private fun web(current: Boolean = false) = ActiveConnection(
        id = "web-target",
        user = "operator",
        service = "HTTPS",
        client = "Synthetic browser",
        connectedAtEpochSeconds = null,
        isCurrent = current,
        deviceId = "synthetic-device",
        type = "HTTP/HTTPS",
        canDisconnect = true,
    )

    private fun service() = ActiveConnection(
        id = "service-target",
        user = "operator",
        service = "SMB",
        client = "Synthetic client",
        connectedAtEpochSeconds = null,
        isCurrent = false,
        processId = "42",
        type = "SMB",
        canDisconnect = true,
    )
}
