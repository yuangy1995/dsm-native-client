package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
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
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasServiceSettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.TerminalMutationFailureCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.TerminalMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.TerminalSavingCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.TerminalSettingsDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class TerminalFeedbackCardTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 部分成功刷新前显示终端计数并阻止继续编辑() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var refreshes = 0
        setFeedback(
            result = result(MutationResultStatus.PARTIAL_SUCCESS, MutationResultCounts(2, 0, 1)),
            canEdit = false,
            onRefresh = { refreshes += 1 },
        )

        rule.onNodeWithText(context.getString(R.string.terminal_feedback_counts, 2, 0, 1))
            .assertIsDisplayed()
        rule.onNode(
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Assertive),
        ).assertExists()
        rule.onNodeWithText(context.getString(R.string.refresh_and_check_terminal_settings))
            .performClick()
        rule.onAllNodesWithText(context.getString(R.string.continue_editing)).assertCountEquals(0)
        rule.runOnIdle { check(refreshes == 1) }
    }

    @Test
    fun 提交后取消说明远程终端可能已变化() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setFeedback(
            result = result(
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                MutationResultCounts(0, 0, 3),
            ),
        )

        rule.onNodeWithText(context.getString(R.string.terminal_cancel_after_submission))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.refresh_and_check_terminal_settings))
            .assertIsDisplayed()
    }

    @Test
    fun 核对成功使用礼貌通知且只提供完成() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var dismissed = 0
        setFeedback(
            result = result(MutationResultStatus.CONFIRMED_SUCCESS, MutationResultCounts(3, 0, 0)),
            canEdit = false,
            onDismiss = { dismissed += 1 },
        )

        rule.onNode(
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite),
        ).assertExists()
        rule.onAllNodesWithText(context.getString(R.string.continue_editing)).assertCountEquals(0)
        rule.onNodeWithText(context.getString(R.string.done)).performClick()
        rule.runOnIdle { check(dismissed == 1) }
    }

    @Test
    fun 提交前取消保留草稿且无需刷新() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setFeedback(
            result = MutationResult(
                schemaVersion = 1,
                status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                operation = "terminalSettingsUpdate",
                submitted = false,
                requiresRefresh = false,
                counts = MutationResultCounts(0, 0, 0),
            ),
        )

        rule.onNodeWithText(context.getString(R.string.terminal_feedback_cancelled_message))
            .assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.refresh_and_check_terminal_settings))
            .assertCountEquals(0)
        rule.onNodeWithText(context.getString(R.string.continue_editing)).assertIsDisplayed()
    }

    @Test
    fun 保存中显示进度并礼貌播报() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent { LanStashTheme { TerminalSavingCard() } }

        rule.onNodeWithText(context.getString(R.string.terminal_saving_title)).assertIsDisplayed()
        rule.onNode(
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite),
        ).assertExists()
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
                            TerminalMutationFeedbackCard(
                                result = result(
                                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                                    MutationResultCounts(0, 0, 3),
                                ),
                                refreshCompleted = true,
                                canContinueEditing = true,
                                onRefresh = {},
                                onContinueEditing = { edits += 1 },
                                onDismiss = {},
                            )
                        }
                        item {
                            TerminalMutationFailureCard(
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

        rule.onNodeWithText(context.getString(R.string.terminal_feedback_unverified_message))
            .assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.continue_editing))[0]
            .performScrollTo()
            .performClick()
        rule.onAllNodesWithText(context.getString(R.string.continue_editing))[1]
            .performScrollTo()
            .performClick()
        rule.runOnIdle { check(edits == 2) }
    }

    @Test
    fun 重建编辑器时恢复终端草稿端口() {
        var restored = NasTerminalSettings(false, false, 22)
        val restoration = StateRestorationTester(rule)
        restoration.setContent {
            LanStashTheme {
                TerminalSettingsDialog(
                    baseline = NasTerminalSettings(false, false, 22),
                    restoredDraft = restored,
                    onDraftChange = { restored = it },
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNode(hasSetTextAction() and hasText("22"))
            .performTextReplacement("2222")
        rule.waitForIdle()
        rule.runOnIdle { check(restored.sshPort == 2_222) }
        restoration.emulateSavedInstanceStateRestore()
        rule.onNode(hasSetTextAction() and hasText("2222")).assertExists()
    }

    @Test
    fun 编辑和确认阶段经过保存状态恢复仍保持原阶段() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val restoration = StateRestorationTester(rule)
        val draft = NasTerminalSettings(true, false, 2_222)
        restoration.setContent {
            LanStashTheme {
                serviceScreen(
                    snapshot = snapshot(terminal = NasTerminalSettings(false, false, 22)),
                    savedTerminalDraft = draft,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.edit)).performClick()
        rule.onNode(hasSetTextAction() and hasText("2222")).assertExists()
        restoration.emulateSavedInstanceStateRestore()
        rule.onNode(hasSetTextAction() and hasText("2222")).assertExists()

        rule.onNodeWithText(context.getString(R.string.continue_action)).performClick()
        rule.onNodeWithText(context.getString(R.string.save_terminal_title)).assertIsDisplayed()
        restoration.emulateSavedInstanceStateRestore()
        rule.onNodeWithText(context.getString(R.string.save_terminal_title)).assertIsDisplayed()
    }

    @Test
    fun 终端能力缺失在深色两倍字体下显示原因() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme(darkTheme = true) {
                CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                    serviceScreen(
                        snapshot = snapshot(fileServices = fileSettings(), terminal = null),
                        savedTerminalDraft = null,
                        )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.terminal_settings_unavailable_hint))
            .performScrollTo()
            .assertIsDisplayed()
    }

    @Test
    fun SSH和Telnet整行开关具有角色状态与最小触控高度() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var pixelsPerDp = 1f
        rule.setContent {
            LanStashTheme {
                pixelsPerDp = LocalDensity.current.density
                TerminalSettingsDialog(
                    baseline = NasTerminalSettings(true, false, 22),
                    restoredDraft = null,
                    onDraftChange = {},
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        val ssh = rule.onNodeWithText(context.getString(R.string.ssh_service), useUnmergedTree = true)
            .fetchSemanticsNode().parent ?: error("SSH 开关行缺少父节点")
        val telnet = rule.onNodeWithText(context.getString(R.string.telnet_service), useUnmergedTree = true)
            .fetchSemanticsNode().parent ?: error("Telnet 开关行缺少父节点")
        listOf(ssh to ToggleableState.On, telnet to ToggleableState.Off).forEach { (node, state) ->
            check(node.config[SemanticsProperties.Role] == Role.Switch)
            check(node.config[SemanticsProperties.ToggleableState] == state)
            check(node.boundsInRoot.height >= 48f * pixelsPerDp)
        }
    }

    @androidx.compose.runtime.Composable
    private fun serviceScreen(
        snapshot: NasSettingsSnapshot,
        savedTerminalDraft: NasTerminalSettings?,
    ) {
        val fixture = androidx.compose.runtime.remember(snapshot, savedTerminalDraft) {
            NasServiceUiFixture(snapshot, listOfNotNull(savedTerminalDraft?.let(NasServiceValue::Terminal)))
        }
        val states = fixture.states.value
        NasServiceSettingsContent(snapshot, false, states, fixture::begin, fixture::draft, { false }, {}, { _, _ -> })
    }

    private fun snapshot(
        fileServices: NasFileServiceSettings? = null,
        terminal: NasTerminalSettings?,
    ) = NasSettingsSnapshot(
        system = null,
        volumes = emptyList(),
        pools = emptyList(),
        disks = emptyList(),
        storageDisks = emptyList(),
        packages = emptyList(),
        scheduledTasks = emptyList(),
        accounts = emptyList(),
        groups = emptyList(),
        logs = emptyList(),
        connections = emptyList(),
        connectionsAvailable = true,
        networkInterfaces = emptyList(),
        networkInterfacesAvailable = true,
        ddnsDirectory = null,
        ddnsDirectoryAvailable = true,
        fileServiceSettings = fileServices,
        terminalSettings = terminal,
        proxySettings = null,
        regionSettings = null,
        securitySettings = null,
        hardwareSettings = null,
        security = emptyList(),
    )

    private fun fileSettings() = NasFileServiceSettings(
        false, null, false, false, 21, null, null, null, null, null,
    )

    private fun setFeedback(
        result: MutationResult,
        canEdit: Boolean = true,
        onRefresh: () -> Unit = {},
        onEdit: () -> Unit = {},
        onDismiss: () -> Unit = {},
    ) {
        rule.setContent {
            LanStashTheme {
                LazyColumn {
                    item {
                        TerminalMutationFeedbackCard(
                            result = result,
                            refreshCompleted = false,
                            canContinueEditing = canEdit,
                            onRefresh = onRefresh,
                            onContinueEditing = onEdit,
                            onDismiss = onDismiss,
                        )
                    }
                }
            }
        }
    }

    private fun result(status: MutationResultStatus, counts: MutationResultCounts): MutationResult =
        MutationResult(
            schemaVersion = 1,
            status = status,
            operation = "terminalSettingsUpdate",
            submitted = true,
            requiresRefresh = status != MutationResultStatus.CONFIRMED_SUCCESS,
            counts = counts,
        )
}
