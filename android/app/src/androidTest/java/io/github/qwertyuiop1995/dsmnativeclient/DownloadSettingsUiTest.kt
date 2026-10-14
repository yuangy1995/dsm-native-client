package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.ui.DownloadSettingsDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.DownloadSettingsMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloadSettingsFeedbackPolicy
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DownloadSettingsUiTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 八类保存结果均保留专用反馈策略() {
        val titles = mapOf(
            MutationResultStatus.CONFIRMED_SUCCESS to R.string.download_settings_feedback_confirmed_title,
            MutationResultStatus.PARTIAL_SUCCESS to R.string.download_settings_feedback_partial_title,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED to R.string.download_settings_feedback_check_title,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION to R.string.download_settings_feedback_check_title,
            MutationResultStatus.PERMISSION_DENIED to R.string.download_settings_feedback_permission_title,
            MutationResultStatus.UNSUPPORTED to R.string.download_settings_feedback_unavailable_title,
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION to R.string.download_settings_feedback_cancelled_title,
            MutationResultStatus.CONFIRMED_FAILURE to R.string.download_settings_feedback_failed_title,
        )
        titles.forEach { (status, title) ->
            assertEquals(title, downloadSettingsFeedbackPolicy(result(status)).title)
        }
    }

    @Test
    fun 未确认保存必须刷新且不能直接继续编辑() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var refreshes = 0
        showFeedback(
            DownloadSettingsWorkspaceState(
                mutationResult = result(
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    counts = MutationResultCounts(0, 0, 2),
                ),
            ),
            onRefresh = { refreshes++ },
        )

        rule.onNodeWithText(context.getString(R.string.download_settings_feedback_counts, 0, 0, 2))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.refresh_and_check_download_settings))
            .assertHeightIsAtLeast(48.dp)
            .performClick()
        rule.onNodeWithText(context.getString(R.string.close_checked_download_settings))
            .assertIsNotEnabled()
        rule.onNodeWithText(context.getString(R.string.continue_editing_download_settings))
            .assertDoesNotExist()
        rule.onNode(
            androidx.compose.ui.test.SemanticsMatcher.expectValue(
                SemanticsProperties.LiveRegion,
                LiveRegionMode.Assertive,
            ),
        ).assertIsDisplayed()
        assertEquals(1, refreshes)
    }

    @Test
    fun 未提交权限结果可以明确返回编辑且达到48dp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var dismisses = 0
        showFeedback(
            DownloadSettingsWorkspaceState(
                mutationResult = result(MutationResultStatus.PERMISSION_DENIED, submitted = false),
            ),
            onDismiss = { dismisses++; true },
        )

        rule.onNodeWithText(context.getString(R.string.continue_editing_download_settings))
            .assertHeightIsAtLeast(48.dp)
            .performClick()
        assertEquals(1, dismisses)
    }

    @Test
    fun 深色两倍字体下HTTP与FTP使用同一可滚动字段() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val baseline = DownloadSettings(defaultDestination = "downloads", canManage = true)
        var updated: DownloadSettingsDraftState? = null
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                LanStashTheme(darkTheme = true) {
                    DownloadSettingsDialog(
                        state = WorkspaceState(
                            profile = NasProfile("synthetic", "Synthetic", "https://nas.invalid", "tester"),
                            supportsDownloadSettings = true,
                            supportsDownloadSchedule = true,
                            downloadSettings = Loadable.Ready(baseline),
                            downloadSettingsState = DownloadSettingsWorkspaceState(
                                editorVisible = true,
                                baseline = baseline,
                                draft = DownloadSettingsDraftState.from(baseline),
                            ),
                        ),
                        onRetry = {},
                        onDraftChange = { updated = it },
                        onSave = { true },
                        onRefreshMutation = {},
                        onDismissMutation = { true },
                        onDismiss = { true },
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.download_http_ftp_limit))
            .performScrollTo()
            .performTextReplacement("777")
        rule.runOnIdle {
            assertNotNull(updated)
            assertEquals("777", updated?.httpDownload)
            assertEquals("777", updated?.ftpDownload)
        }
        rule.onNodeWithText(context.getString(R.string.download_http_limit)).assertDoesNotExist()
        rule.onNodeWithText(context.getString(R.string.download_ftp_limit)).assertDoesNotExist()
    }

    private fun showFeedback(
        state: DownloadSettingsWorkspaceState,
        onRefresh: () -> Unit = {},
        onDismiss: () -> Boolean = { true },
    ) {
        rule.setContent {
            LanStashTheme {
                DownloadSettingsMutationFeedbackCard(state, onRefresh, onDismiss)
            }
        }
    }

    private fun result(
        status: MutationResultStatus,
        submitted: Boolean = status !in setOf(
            MutationResultStatus.PERMISSION_DENIED,
            MutationResultStatus.UNSUPPORTED,
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CONFIRMED_FAILURE,
        ),
        requiresRefresh: Boolean = status in setOf(
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        ),
        counts: MutationResultCounts = when (status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> MutationResultCounts(1, 0, 0)
            MutationResultStatus.PARTIAL_SUCCESS -> MutationResultCounts(1, 1, 0)
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> MutationResultCounts(0, 0, 1)
            else -> MutationResultCounts(0, 0, 0)
        },
    ) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = "downloadSettingsSave",
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = counts,
        errorCategory = if (status == MutationResultStatus.CONFIRMED_FAILURE) {
            MutationErrorCategory.UNKNOWN
        } else null,
        diagnosticTag = "synthetic.download.settings",
    )
}
