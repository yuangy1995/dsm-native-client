package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.unit.Density
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasManualDateTime
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTimeZoneOption
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasRegionSettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasRegionEditorState
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.RegionMutationFailureCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.RegionMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.RegionSavingCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.RegionSettingsDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class RegionFeedbackCardTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 部分成功刷新前显示计数并阻止继续编辑() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var refreshes = 0
        setFeedback(
            result = result(
                MutationResultStatus.PARTIAL_SUCCESS,
                MutationResultCounts(2, 0, 3),
                "region.configuration-not-fully-confirmed",
            ),
            canEdit = false,
            onRefresh = { refreshes += 1 },
        )

        rule.onNodeWithText(context.getString(R.string.region_feedback_counts, 2, 0, 3))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.region_feedback_partial_message))
            .assertIsDisplayed()
        rule.onNode(
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Assertive),
        ).assertExists()
        rule.onNodeWithText(context.getString(R.string.refresh_and_check_region_settings))
            .performClick()
        rule.onAllNodesWithText(context.getString(R.string.continue_editing)).assertCountEquals(0)
        rule.runOnIdle { check(refreshes == 1) }
    }

    @Test
    fun 两阶段反馈不把已接受校时描述成时钟精度已验证() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    RegionMutationFeedbackCard(
                        result = result(
                            MutationResultStatus.CONFIRMED_SUCCESS,
                            MutationResultCounts(5, 0, 0),
                            "region.sync-accepted",
                        ),
                        refreshCompleted = false,
                        canContinueEditing = false,
                        onRefresh = {},
                        onContinueEditing = {},
                        onDismiss = {},
                    )
                    RegionMutationFeedbackCard(
                        result = result(
                            MutationResultStatus.PARTIAL_SUCCESS,
                            MutationResultCounts(4, 0, 1),
                            "region.sync-readback-unverified",
                        ),
                        refreshCompleted = false,
                        canContinueEditing = false,
                        onRefresh = {},
                        onContinueEditing = {},
                        onDismiss = {},
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.region_feedback_sync_accepted_message))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.region_feedback_partial_message))
            .performScrollTo()
            .assertIsDisplayed()
    }

    @Test
    fun 提交前后取消分别保留草稿并要求不同恢复路径() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    RegionMutationFeedbackCard(
                        result = MutationResult(
                            schemaVersion = 1,
                            status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                            operation = "regionSettingsUpdate",
                            submitted = false,
                            requiresRefresh = false,
                            counts = MutationResultCounts(0, 0, 0),
                        ),
                        refreshCompleted = false,
                        canContinueEditing = true,
                        onRefresh = {},
                        onContinueEditing = {},
                        onDismiss = {},
                    )
                    RegionMutationFeedbackCard(
                        result = result(
                            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                            MutationResultCounts(0, 0, 5),
                        ),
                        refreshCompleted = false,
                        canContinueEditing = false,
                        onRefresh = {},
                        onContinueEditing = {},
                        onDismiss = {},
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.region_feedback_cancelled_message))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.region_cancel_after_submission))
            .performScrollTo().assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.refresh_and_check_region_settings))
            .assertCountEquals(1)
        rule.onAllNodesWithText(context.getString(R.string.continue_editing)).assertCountEquals(1)
    }

    @Test
    fun 提交前后权限不支持失败及冲突按边界提供恢复操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val cards = listOf(
            result(MutationResultStatus.PERMISSION_DENIED, MutationResultCounts(0, 5, 0))
                .copy(submitted = false, requiresRefresh = false) to true,
            result(MutationResultStatus.PERMISSION_DENIED, MutationResultCounts(0, 5, 0))
                .copy(submitted = true, requiresRefresh = false) to false,
            result(MutationResultStatus.UNSUPPORTED, MutationResultCounts(0, 5, 0))
                .copy(submitted = false, requiresRefresh = false) to true,
            result(MutationResultStatus.UNSUPPORTED, MutationResultCounts(0, 5, 0))
                .copy(submitted = true, requiresRefresh = false) to false,
            result(MutationResultStatus.CONFIRMED_FAILURE, MutationResultCounts(0, 5, 0))
                .copy(submitted = false, requiresRefresh = false) to true,
            result(MutationResultStatus.CONFIRMED_FAILURE, MutationResultCounts(0, 5, 0))
                .copy(submitted = true, requiresRefresh = false) to false,
            result(MutationResultStatus.CONFIRMED_FAILURE, MutationResultCounts(0, 1, 0))
                .copy(
                    submitted = false,
                    requiresRefresh = false,
                    errorCategory = MutationErrorCategory.CONFLICT,
                ) to false,
        )
        rule.setContent {
            LanStashTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    cards.forEach { (value, canEdit) ->
                        RegionMutationFeedbackCard(
                            result = value,
                            refreshCompleted = false,
                            canContinueEditing = canEdit,
                            onRefresh = {},
                            onContinueEditing = {},
                            onDismiss = {},
                        )
                    }
                }
            }
        }

        rule.onAllNodesWithText(context.getString(R.string.region_feedback_permission_message))
            .assertCountEquals(2)
        rule.onAllNodesWithText(context.getString(R.string.region_feedback_unsupported_message))[0]
            .performScrollTo()
        rule.onAllNodesWithText(context.getString(R.string.region_feedback_unsupported_message))
            .assertCountEquals(2)
        rule.onAllNodesWithText(context.getString(R.string.region_feedback_failed_message))[0]
            .performScrollTo()
        rule.onAllNodesWithText(context.getString(R.string.region_feedback_failed_message))
            .assertCountEquals(2)
        rule.onNodeWithText(context.getString(R.string.region_feedback_conflict_message))
            .performScrollTo()
            .assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.refresh_and_check_region_settings))
            .assertCountEquals(4)
        rule.onAllNodesWithText(context.getString(R.string.continue_editing)).assertCountEquals(3)
    }

    @Test
    fun 保存中礼貌播报且成功只提供完成() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var dismissed = 0
        rule.setContent {
            LanStashTheme {
                LazyColumn {
                    item { RegionSavingCard() }
                    item {
                        RegionMutationFeedbackCard(
                            result = result(
                                MutationResultStatus.CONFIRMED_SUCCESS,
                                MutationResultCounts(4, 0, 0),
                            ),
                            refreshCompleted = false,
                            canContinueEditing = false,
                            onRefresh = {},
                            onContinueEditing = {},
                            onDismiss = { dismissed += 1 },
                        )
                    }
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.region_saving_title)).assertIsDisplayed()
        rule.onAllNodes(
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite),
        ).assertCountEquals(2)
        rule.onAllNodesWithText(context.getString(R.string.continue_editing)).assertCountEquals(0)
        rule.onNodeWithText(context.getString(R.string.done)).performScrollTo().performClick()
        rule.runOnIdle { check(dismissed == 1) }
    }

    @Test
    fun 深色两倍字体下结果与异常恢复操作均可达() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var edits = 0
        rule.setContent {
            LanStashTheme(darkTheme = true) {
                CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                    LazyColumn {
                        item {
                            RegionMutationFeedbackCard(
                                result = result(
                                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                                    MutationResultCounts(0, 0, 5),
                                ),
                                refreshCompleted = true,
                                canContinueEditing = true,
                                onRefresh = {},
                                onContinueEditing = { edits += 1 },
                                onDismiss = {},
                            )
                        }
                        item {
                            RegionMutationFailureCard(
                                failure = DsmFailure(
                                    null,
                                    "Synthetic failure",
                                    "Synthetic recovery",
                                    kind = DsmErrorKind.CONNECTION_FAILED,
                                ),
                                canContinueEditing = true,
                                onContinueEditing = { edits += 1 },
                                onDismiss = {},
                            )
                        }
                    }
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.region_feedback_unverified_message))
            .assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.continue_editing))[0]
            .performScrollTo().performClick()
        rule.onAllNodesWithText(context.getString(R.string.continue_editing))[1]
            .performScrollTo().performClick()
        rule.runOnIdle { check(edits == 2) }
    }

    @Test
    fun 重建编辑器恢复全部区域草稿并规范化服务器() {
        var restored by mutableStateOf(region(network = true).copy(
            dateFormat = "Y/m/d",
            timeFormat = "H:i:s",
            timeZone = "UTC",
            timeServers = listOf("time.example.invalid"),
        ))
        val restoration = StateRestorationTester(rule)
        restoration.setContent {
            LanStashTheme {
                RegionSettingsDialog(
                    baseline = region(),
                    restoredDraft = restored,
                    onDraftChange = { restored = it },
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.onNodeWithText(context.getString(R.string.nas_region_date_ymd_slash)).performScrollTo().performClick()
        rule.onNodeWithText(context.getString(R.string.nas_region_date_dmy_slash)).performClick()
        rule.onNodeWithText(context.getString(R.string.nas_region_current_format, "H:i:s")).performScrollTo().performClick()
        rule.onNodeWithText(context.getString(R.string.nas_region_time_24)).performClick()
        rule.onNode(hasSetTextAction() and hasText("time.example.invalid"))
            .performTextReplacement(" time-a.invalid \n time-b.invalid ")
        rule.waitForIdle()
        rule.runOnIdle {
            check(restored.dateFormat == "d/m/Y")
            check(restored.timeServers == listOf("time-a.invalid", "time-b.invalid"))
        }
        restoration.emulateSavedInstanceStateRestore()
        rule.onNodeWithText(context.getString(R.string.nas_region_date_dmy_slash)).assertExists()
        rule.onNodeWithText(context.getString(R.string.nas_region_time_24)).assertExists()
        rule.onNode(hasSetTextAction() and hasText(" time-a.invalid \n time-b.invalid "))
            .assertExists()
    }

    @Test
    fun 父状态真实重组与模式切换不会丢失未提交的手动时间() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var restored by mutableStateOf(region())
        rule.setContent {
            LanStashTheme {
                RegionSettingsDialog(
                    baseline = region(),
                    restoredDraft = restored,
                    onDraftChange = { restored = it },
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNode(hasSetTextAction() and hasText("2026-08-04"))
            .performTextReplacement("2026-08-05")
        rule.onNode(hasSetTextAction() and hasText("12:34:56"))
            .performTextReplacement("01:02:03")
        rule.onNodeWithText(context.getString(R.string.use_network_time)).performClick()
        rule.onNodeWithText(context.getString(R.string.use_network_time)).performClick()
        rule.onNode(hasSetTextAction() and hasText("2026-08-05")).assertExists()
        rule.onNode(hasSetTextAction() and hasText("01:02:03")).assertExists()
    }

    @Test
    fun 深色两倍字体编辑弹窗的长文案时区和字段错误均可达() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme(darkTheme = true) {
                CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                    RegionSettingsDialog(
                        baseline = region(network = true),
                        restoredDraft = null,
                        onDraftChange = {},
                        onSave = {},
                        onDismiss = {},
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.time_zone_value, "Beijing, Shanghai"))
            .performClick()
        rule.onNodeWithText("Coordinated Universal Time").performClick()
        rule.onNodeWithText(context.getString(R.string.time_zone_value, "Coordinated Universal Time"))
            .assertIsDisplayed()
        rule.onNode(hasSetTextAction() and hasText(context.getString(R.string.time_servers))).performScrollTo().performTextReplacement("https://bad/path")
        rule.onNodeWithText(context.getString(R.string.invalid_time_servers))
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.region_time_impact_hint))
            .performScrollTo().assertIsDisplayed()
    }

    @Test
    fun 编辑确认阶段可恢复且取消返回草稿保存未接收仍保留确认() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val restoration = StateRestorationTester(rule)
        val draft = region(network = true).copy(
            dateFormat = "Y/m/d",
            timeZone = "UTC",
            timeServers = listOf("time.example.invalid"),
        )
        restoration.setContent {
            LanStashTheme {
                regionScreen(settings = region(), savedDraft = draft)
            }
        }

        rule.onNodeWithText(context.getString(R.string.edit)).performClick()
        rule.onNodeWithText(context.getString(R.string.nas_region_date_ymd_slash)).assertExists()
        restoration.emulateSavedInstanceStateRestore()
        rule.onNodeWithText(context.getString(R.string.nas_region_date_ymd_slash)).assertExists()
        rule.onNodeWithText(context.getString(R.string.continue_action)).performClick()
        rule.onNodeWithText(context.getString(R.string.save_region_settings_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.save_region_settings_with_sync_message))
            .assertIsDisplayed()
        restoration.emulateSavedInstanceStateRestore()
        rule.onNodeWithText(context.getString(R.string.save_region_settings_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.cancel)).performClick()
        rule.onNodeWithText(context.getString(R.string.nas_region_date_ymd_slash)).assertExists()
        rule.onNodeWithText(context.getString(R.string.continue_action)).performClick()
        rule.onNodeWithText(context.getString(R.string.save)).performClick()
        rule.onNodeWithText(context.getString(R.string.save_region_settings_title)).assertIsDisplayed()
    }

    @Test
    fun 区域能力缺失在深色两倍字体下显示原因和恢复动作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme(darkTheme = true) {
                CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                    regionScreen(settings = null, savedDraft = null)
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.region_settings_unavailable_hint))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.refresh_and_check_region_settings))
            .assertIsDisplayed()
    }

    @Test
    fun 自动校时整行开关具有角色状态和最小触控高度() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var pixelsPerDp = 1f
        rule.setContent {
            LanStashTheme {
                pixelsPerDp = LocalDensity.current.density
                RegionSettingsDialog(
                    baseline = region(network = true),
                    restoredDraft = null,
                    onDraftChange = {},
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        val switchRow = rule.onNodeWithText(
            context.getString(R.string.use_network_time),
            useUnmergedTree = true,
        ).fetchSemanticsNode().parent ?: error("自动校时开关行缺少父节点")
        check(switchRow.config[SemanticsProperties.Role] == Role.Switch)
        check(switchRow.config[SemanticsProperties.ToggleableState] == ToggleableState.On)
        check(switchRow.boundsInRoot.height >= 48f * pixelsPerDp)
    }

    @Test
    fun 错误字段向TalkBack暴露错误语义且可见标签属于输入控件() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val hasError = SemanticsMatcher("包含输入错误语义") {
            it.config.contains(SemanticsProperties.Error)
        }
        rule.setContent {
            LanStashTheme {
                RegionSettingsDialog(
                    baseline = region(network = true),
                    restoredDraft = null,
                    onDraftChange = {},
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNode(hasSetTextAction() and hasText(context.getString(R.string.time_servers))).performScrollTo().performTextReplacement("https://bad/path")
        rule.onAllNodes(hasError).assertCountEquals(1)
        check(rule.onNode(hasError).fetchSemanticsNode().config[SemanticsProperties.Error].isNotBlank())
        val initialServerLabel = rule.onNodeWithText(
            context.getString(R.string.time_servers),
            useUnmergedTree = true,
        ).fetchSemanticsNode()
        check(generateSequence(initialServerLabel.parent) { it.parent }.any {
            it.config.contains(SemanticsActions.SetText)
        })

        rule.onNodeWithText(context.getString(R.string.use_network_time)).performClick()
        rule.onNode(hasSetTextAction() and hasText("2026-08-04")).performTextReplacement("2025-02-29")
        rule.onNode(hasSetTextAction() and hasText("12:34:56"))
            .performTextReplacement("24:00:00")
        rule.onAllNodes(hasError).assertCountEquals(2)
        rule.onAllNodesWithText(context.getString(R.string.invalid_manual_time))
            .assertCountEquals(2)

        rule.onNodeWithText(context.getString(R.string.use_network_time)).performClick()
        rule.onNode(hasSetTextAction() and hasText(context.getString(R.string.time_servers))).performTextReplacement("https://bad/path")
        rule.onAllNodes(hasError).assertCountEquals(1)
        val serverLabel = rule.onNodeWithText(
            context.getString(R.string.time_servers),
            useUnmergedTree = true,
        ).fetchSemanticsNode()
        check(generateSequence(serverLabel.parent) { it.parent }.any {
            it.config.contains(SemanticsActions.SetText)
        })
    }

    @Test
    fun 时间服务器和手动日期边界就地阻止无效继续() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                RegionSettingsDialog(
                    baseline = region(),
                    restoredDraft = null,
                    onDraftChange = {},
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        // 格式采用受支持选项，不能输入空值；未修改任何字段时也不能继续。
        rule.onAllNodes(hasSetTextAction() and hasText(context.getString(R.string.date_format))).assertCountEquals(0)
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()

        rule.onNodeWithText(context.getString(R.string.use_network_time)).performClick()
        val server = rule.onNode(hasSetTextAction() and hasText(context.getString(R.string.time_servers)))
        server.performTextReplacement("https://time.invalid/path")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()
        server.performTextReplacement("a.invalid\na.invalid")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()
        server.performTextReplacement("a".repeat(254))
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()
        server.performTextReplacement("a".repeat(253))
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsEnabled()
        server.performTextReplacement("2001:db8::1")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsEnabled()
        server.performTextReplacement("a.invalid\nb.invalid\nc.invalid")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsEnabled()
        server.performTextReplacement("a.invalid\nb.invalid\nc.invalid\nd.invalid")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()
        server.performTextReplacement("a.invalid")
        rule.onNodeWithText(context.getString(R.string.use_network_time)).performClick()

        val date = rule.onNode(hasSetTextAction() and hasText("2026-08-04"))
        val time = rule.onNode(hasSetTextAction() and hasText("12:34:56"))
        date.performTextReplacement("2025-02-29")
        time.performTextReplacement("24:00:00")
        rule.waitForIdle()
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()
        rule.onNode(hasSetTextAction() and hasText("2025-02-29"))
            .performTextReplacement("2024-02-29")
        rule.onNode(hasSetTextAction() and hasText("24:00:00"))
            .performTextReplacement("23:59:59")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsEnabled()
    }

    @Test
    fun 保存期间编辑入口被禁用且显示进度() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                NasRegionSettingsContent(region(), true, NasRegionEditorState(current = region(), original = region(),
                    draft = region().copy(dateFormat = "Y/m/d"), busy = true, saving = true),
                    { false }, {}, { _, _ -> false }, {}, {})
            }
        }

        rule.onNodeWithText(context.getString(R.string.region_saving_title)).assertIsDisplayed()
        val editText = rule.onNodeWithText(
            context.getString(R.string.edit),
            useUnmergedTree = true,
        ).fetchSemanticsNode()
        check(generateSequence(editText.parent) { it.parent }.any {
            it.config.contains(SemanticsProperties.Disabled)
        })
    }

    @androidx.compose.runtime.Composable
    private fun regionScreen(
        settings: NasRegionSettings?,
        savedDraft: NasRegionSettings?,
    ) {
        val fixture = androidx.compose.runtime.remember(settings, savedDraft) { NasRegionUiFixture(settings, savedDraft) }
        NasRegionSettingsContent(settings, false, fixture.state.value, fixture::begin, fixture::draft, { _, _ -> false }, {}, {})
    }

    private fun setFeedback(
        result: MutationResult,
        canEdit: Boolean = true,
        onRefresh: () -> Unit = {},
    ) {
        rule.setContent {
            LanStashTheme {
                RegionMutationFeedbackCard(
                    result = result,
                    refreshCompleted = false,
                    canContinueEditing = canEdit,
                    onRefresh = onRefresh,
                    onContinueEditing = {},
                    onDismiss = {},
                )
            }
        }
    }

    private fun result(
        status: MutationResultStatus,
        counts: MutationResultCounts,
        tag: String? = null,
    ) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = "regionSettingsUpdate",
        submitted = status != MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        requiresRefresh = status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        ),
        counts = counts,
        diagnosticTag = tag,
    )

    private fun region(network: Boolean = false) = NasRegionSettings(
        dateFormat = "Y-m-d",
        timeFormat = "H:i",
        timeZone = "Asia/Shanghai",
        isNetworkTimeEnabled = network,
        timeServers = if (network) listOf("old-time.example.invalid") else emptyList(),
        manualDateTime = NasManualDateTime(2026, 8, 4, 12, 34, 56),
        timeZones = listOf(
            NasTimeZoneOption("Asia/Shanghai", "Beijing, Shanghai"),
            NasTimeZoneOption("UTC", "Coordinated Universal Time"),
        ),
    )
}
