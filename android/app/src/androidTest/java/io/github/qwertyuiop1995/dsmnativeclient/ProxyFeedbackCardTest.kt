package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
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
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasServiceSettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ProxyMutationFailureCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ProxyMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ProxySavingCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ProxySettingsDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class ProxyFeedbackCardTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 部分成功刷新前显示代理计数并阻止继续编辑() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var refreshes = 0
        setFeedback(
            result = result(MutationResultStatus.PARTIAL_SUCCESS, MutationResultCounts(1, 0, 2)),
            canEdit = false,
            onRefresh = { refreshes += 1 },
        )

        rule.onNodeWithText(context.getString(R.string.proxy_feedback_counts, 1, 0, 2))
            .assertIsDisplayed()
        rule.onNode(
            SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Assertive),
        ).assertExists()
        rule.onNodeWithText(context.getString(R.string.refresh_and_check_proxy_settings))
            .performClick()
        rule.onAllNodesWithText(context.getString(R.string.continue_editing)).assertCountEquals(0)
        rule.runOnIdle { check(refreshes == 1) }
    }

    @Test
    fun 提交后取消说明代理字段可能已变化() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setFeedback(
            result = result(
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                MutationResultCounts(0, 0, 3),
            ),
        )

        rule.onNodeWithText(context.getString(R.string.proxy_cancel_after_submission))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.refresh_and_check_proxy_settings))
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
                operation = "proxySettingsUpdate",
                submitted = false,
                requiresRefresh = false,
                counts = MutationResultCounts(0, 0, 0),
            ),
        )

        rule.onNodeWithText(context.getString(R.string.proxy_feedback_cancelled_message))
            .assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.refresh_and_check_proxy_settings))
            .assertCountEquals(0)
        rule.onNodeWithText(context.getString(R.string.continue_editing)).assertIsDisplayed()
    }

    @Test
    fun 权限不支持失败与冲突按提交边界提供恢复操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val cards = listOf(
            Triple(
                result(MutationResultStatus.PERMISSION_DENIED, MutationResultCounts(0, 3, 0))
                    .copy(submitted = false, requiresRefresh = false),
                true,
                "permission-before",
            ),
            Triple(
                result(MutationResultStatus.PERMISSION_DENIED, MutationResultCounts(0, 3, 0))
                    .copy(submitted = true, requiresRefresh = false),
                false,
                "permission-after",
            ),
            Triple(
                result(MutationResultStatus.UNSUPPORTED, MutationResultCounts(0, 3, 0))
                    .copy(submitted = false, requiresRefresh = false),
                true,
                "unsupported",
            ),
            Triple(
                result(MutationResultStatus.UNSUPPORTED, MutationResultCounts(0, 3, 0))
                    .copy(submitted = true, requiresRefresh = false),
                false,
                "unsupported-after",
            ),
            Triple(
                result(MutationResultStatus.CONFIRMED_FAILURE, MutationResultCounts(0, 3, 0))
                    .copy(submitted = false, requiresRefresh = false),
                true,
                "failed",
            ),
            Triple(
                result(MutationResultStatus.CONFIRMED_FAILURE, MutationResultCounts(0, 3, 0))
                    .copy(submitted = true, requiresRefresh = false),
                false,
                "failed-after",
            ),
            Triple(
                result(MutationResultStatus.CONFIRMED_FAILURE, MutationResultCounts(0, 3, 0))
                    .copy(
                        submitted = false,
                        requiresRefresh = false,
                        errorCategory = MutationErrorCategory.CONFLICT,
                    ),
                false,
                "conflict",
            ),
        )
        rule.setContent {
            LanStashTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    cards.forEach { (value, canEdit, _) ->
                        ProxyMutationFeedbackCard(
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

        rule.onAllNodesWithText(context.getString(R.string.proxy_feedback_permission_message))
            .assertCountEquals(2)
        rule.onAllNodesWithText(context.getString(R.string.proxy_feedback_unsupported_message))[0]
            .performScrollTo()
        rule.onAllNodesWithText(context.getString(R.string.proxy_feedback_unsupported_message))
            .assertCountEquals(2)
        rule.onAllNodesWithText(context.getString(R.string.proxy_feedback_failed_message))[0]
            .performScrollTo()
        rule.onAllNodesWithText(context.getString(R.string.proxy_feedback_failed_message))
            .assertCountEquals(2)
        rule.onNodeWithText(context.getString(R.string.proxy_feedback_conflict_message))
            .performScrollTo()
            .assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.refresh_and_check_proxy_settings))
            .assertCountEquals(4)
        rule.onAllNodesWithText(context.getString(R.string.continue_editing))
            .assertCountEquals(3)
    }

    @Test
    fun 保存中显示进度并礼貌播报() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent { LanStashTheme { ProxySavingCard() } }

        rule.onNodeWithText(context.getString(R.string.proxy_saving_title)).assertIsDisplayed()
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
                            ProxyMutationFeedbackCard(
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
                            ProxyMutationFailureCard(
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

        rule.onNodeWithText(context.getString(R.string.proxy_feedback_unverified_message))
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
    fun 重建编辑器时恢复代理草稿并规范化地址() {
        var restored = NasProxySettings(true, "proxy.example.invalid", 3_128)
        val restoration = StateRestorationTester(rule)
        restoration.setContent {
            LanStashTheme {
                ProxySettingsDialog(
                    baseline = NasProxySettings(false, "", null),
                    restoredDraft = restored,
                    onDraftChange = { restored = it },
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNode(hasSetTextAction() and hasText("proxy.example.invalid"))
            .performTextReplacement("  next.example.invalid  ")
        rule.onNode(hasSetTextAction() and hasText("3128"))
            .performTextReplacement("8080")
        rule.waitForIdle()
        rule.runOnIdle {
            check(restored.host == "next.example.invalid")
            check(restored.port == 8_080)
        }
        restoration.emulateSavedInstanceStateRestore()
        rule.onNode(hasSetTextAction() and hasText("  next.example.invalid  ")).assertExists()
        rule.onNode(hasSetTextAction() and hasText("8080")).assertExists()
    }

    @Test
    fun 代理地址与端口边界就地阻止无效继续() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                ProxySettingsDialog(
                    baseline = NasProxySettings(false, "", null),
                    restoredDraft = null,
                    onDraftChange = {},
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.use_internet_proxy)).performClick()
        val fields = rule.onAllNodes(hasSetTextAction())
        val host = fields[0]
        val port = fields[1]
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()

        host.performTextReplacement("https://proxy.example.invalid/path")
        port.performTextReplacement("3128")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()

        host.performTextReplacement("proxy.example.invalid")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsEnabled()
        port.performTextReplacement("0")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()
        port.performTextReplacement("1")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsEnabled()
        port.performTextReplacement("65536")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsNotEnabled()
        port.performTextReplacement("65535")
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsEnabled()
    }

    @Test
    fun 编辑确认阶段可恢复且保存未接收时确认仍保留() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val restoration = StateRestorationTester(rule)
        val draft = NasProxySettings(true, "proxy.example.invalid", 3_128)
        restoration.setContent {
            LanStashTheme {
                serviceScreen(
                    snapshot = snapshot(proxy = NasProxySettings(false, "", null)),
                    savedProxyDraft = draft,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.edit)).performClick()
        rule.onNode(hasSetTextAction() and hasText("proxy.example.invalid")).assertExists()
        restoration.emulateSavedInstanceStateRestore()
        rule.onNode(hasSetTextAction() and hasText("proxy.example.invalid")).assertExists()

        rule.onNodeWithText(context.getString(R.string.continue_action)).performClick()
        rule.onNodeWithText(context.getString(R.string.save_proxy_title)).assertIsDisplayed()
        restoration.emulateSavedInstanceStateRestore()
        rule.onNodeWithText(context.getString(R.string.save_proxy_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.cancel)).performClick()
        rule.onNode(hasSetTextAction() and hasText("proxy.example.invalid")).assertExists()
        rule.onNodeWithText(context.getString(R.string.continue_action)).performClick()
        rule.onNodeWithText(context.getString(R.string.save)).performClick()
        rule.onNodeWithText(context.getString(R.string.save_proxy_title)).assertIsDisplayed()
    }

    @Test
    fun 保存期间代理编辑入口被禁用() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme {
                serviceScreen(
                    snapshot = snapshot(
                        proxy = NasProxySettings(true, "proxy.example.invalid", 3_128),
                    ),
                    savedProxyDraft = NasProxySettings(
                        true,
                        "next.example.invalid",
                        8_080,
                    ),
                    proxyMutationInProgress = true,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.proxy_saving_title)).assertIsDisplayed()
        val editText = rule.onNodeWithText(
            context.getString(R.string.edit),
            useUnmergedTree = true,
        ).fetchSemanticsNode()
        check(
            generateSequence(editText.parent) { it.parent }
                .any { it.config.contains(SemanticsProperties.Disabled) },
        )
    }

    @Test
    fun 代理能力缺失在深色两倍字体下显示原因() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            LanStashTheme(darkTheme = true) {
                CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                    serviceScreen(
                        snapshot = snapshot(fileServices = fileSettings(), proxy = null),
                        savedProxyDraft = null,
                        )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.proxy_settings_unavailable_hint))
            .performScrollTo()
            .assertIsDisplayed()
    }

    @Test
    fun 代理整行开关具有角色状态最小触控高度并隐藏停用字段() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var pixelsPerDp = 1f
        rule.setContent {
            LanStashTheme {
                pixelsPerDp = LocalDensity.current.density
                ProxySettingsDialog(
                    baseline = NasProxySettings(true, "proxy.example.invalid", 3_128),
                    restoredDraft = null,
                    onDraftChange = {},
                    onSave = {},
                    onDismiss = {},
                )
            }
        }

        val switchRow = rule.onNodeWithText(
            context.getString(R.string.use_internet_proxy),
            useUnmergedTree = true,
        ).fetchSemanticsNode().parent ?: error("代理开关行缺少父节点")
        check(switchRow.config[SemanticsProperties.Role] == Role.Switch)
        check(switchRow.config[SemanticsProperties.ToggleableState] == ToggleableState.On)
        check(switchRow.boundsInRoot.height >= 48f * pixelsPerDp)

        rule.onNodeWithText(context.getString(R.string.use_internet_proxy)).performClick()
        rule.onAllNodesWithText(context.getString(R.string.proxy_host)).assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.proxy_port)).assertCountEquals(0)
        rule.onNodeWithText(context.getString(R.string.continue_action)).assertIsEnabled()
    }

    @androidx.compose.runtime.Composable
    private fun serviceScreen(
        snapshot: NasSettingsSnapshot,
        savedProxyDraft: NasProxySettings?,
        proxyMutationInProgress: Boolean = false,
    ) {
        val fixture = androidx.compose.runtime.remember(snapshot, savedProxyDraft) {
            NasServiceUiFixture(snapshot, listOfNotNull(savedProxyDraft?.let(NasServiceValue::Proxy)))
        }
        val states = fixture.states.value.mapValues { (key, value) ->
            if (key == NasServiceKind.PROXY) value.copy(busy = proxyMutationInProgress, saving = proxyMutationInProgress) else value
        }
        NasServiceSettingsContent(snapshot, false, states, fixture::begin, fixture::draft, { false }, {}, { _, _ -> })
    }

    private fun snapshot(
        fileServices: NasFileServiceSettings? = null,
        proxy: NasProxySettings?,
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
        terminalSettings = null,
        proxySettings = proxy,
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
                        ProxyMutationFeedbackCard(
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
            operation = "proxySettingsUpdate",
            submitted = true,
            requiresRefresh = status != MutationResultStatus.CONFIRMED_SUCCESS,
            counts = counts,
        )
}
