package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasPowerAction
import io.github.qwertyuiop1995.dsmnativeclient.ui.ChatMutationFeedbackDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.DownloadSettingsMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.FileStationMutationFeedbackDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadControlMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ConnectionMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.DdnsMutationFailureCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.DdnsMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ManagementMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ManagementTargetState
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.EthernetMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.FileServiceMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.PowerActionFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ProxyMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.RegionMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.SettingsMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.TerminalMutationFeedbackCard
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

/** 持久反馈卡在两倍字体和小视口下仍须保留说明、恢复操作与播报语义。 */
class PersistentFeedbackFontScaleMatrixTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 下载设置结果与失败反馈的说明和恢复操作可滚动到达() {
        val context = context()
        val stage = mutableIntStateOf(0)
        rule.setContent {
            feedbackViewport {
                key(stage.intValue) {
                    DownloadSettingsMutationFeedbackCard(
                        state = if (stage.intValue == 0) {
                            DownloadSettingsWorkspaceState(mutationResult = partialResult("downloadSettingsSave"))
                        } else {
                            DownloadSettingsWorkspaceState(
                                mutationFailure = failure(),
                                mutationRefreshCompleted = true,
                            )
                        },
                        onRefresh = {},
                        onDismiss = { true },
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.download_settings_feedback_partial_title))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.download_settings_partial))
            .performScrollTo().assertIsDisplayed()
        assertReachable(R.string.refresh_and_check_download_settings)
        rule.onNodeWithText(context.getString(R.string.close_checked_download_settings))
            .performScrollTo().assertHasClickAction()
        assertLiveRegion(LiveRegionMode.Assertive)

        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.download_settings_feedback_failed_title))
            .assertIsDisplayed()
        assertLocalizedFailure()
        assertReachable(R.string.continue_editing_download_settings)
        assertLiveRegion(LiveRegionMode.Assertive)
    }

    @Test
    fun 动态域名结果与失败反馈的说明和恢复操作可滚动到达() {
        val context = context()
        val stage = mutableIntStateOf(0)
        rule.setContent {
            feedbackViewport {
                key(stage.intValue) {
                    if (stage.intValue == 0) {
                        DdnsMutationFeedbackCard(
                            operation = DdnsMutationOperation.SAVE,
                            draft = ddnsDraft(),
                            deleteTarget = null,
                            addressTargets = emptyList(),
                            providers = listOf(ddnsProvider()),
                            currentRecord = ddnsRecord(),
                            result = partialResult("ddnsRecordSave"),
                            refreshFailure = null,
                            refreshInProgress = false,
                            refreshCompleted = true,
                            onRefresh = {},
                            onContinueEditing = {},
                            onDismiss = {},
                        )
                    } else {
                        DdnsMutationFailureCard(
                            operation = DdnsMutationOperation.DELETE,
                            draft = null,
                            deleteTarget = ddnsRecord(),
                            addressTargets = emptyList(),
                            providers = listOf(ddnsProvider()),
                            currentRecord = ddnsRecord(),
                            failure = failure(),
                            refreshFailure = null,
                            refreshInProgress = false,
                            refreshCompleted = true,
                            onRefresh = {},
                            onContinueEditing = {},
                            onDismiss = {},
                        )
                    }
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.ddns_feedback_partial_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.service_action_partial))
            .performScrollTo().assertIsDisplayed()
        assertReachable(R.string.refresh_and_check_ddns)
        assertReachable(R.string.continue_editing)
        assertReachable(R.string.close)
        assertLiveRegion(LiveRegionMode.Assertive)

        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.ddns_feedback_failed_title))
            .performScrollTo().assertIsDisplayed()
        assertLocalizedFailure()
        assertReachable(R.string.refresh_and_check_ddns)
        assertReachable(R.string.discard_changes)
        assertLiveRegion(LiveRegionMode.Assertive)
    }

    @Test
    fun 管理反馈覆盖套件目录和SMART的可变文案与操作() {
        val context = context()
        val stage = mutableIntStateOf(0)
        val contexts = listOf(
            Triple(R.string.package_feedback_counts, R.string.refresh_and_check_packages, "Synthetic package"),
            Triple(R.string.directory_feedback_counts, R.string.refresh_and_check_directory, "Synthetic account"),
            Triple(R.string.smart_test_feedback_counts, R.string.refresh_and_check_smart_test, "Synthetic drive"),
        )
        rule.setContent {
            feedbackViewport {
                key(stage.intValue) {
                    val current = contexts[stage.intValue]
                    ManagementMutationFeedbackCard(
                        targetName = current.third,
                        result = partialResult("syntheticManagement"),
                        failure = null,
                        refreshFailure = null,
                        refreshInProgress = false,
                        refreshCompleted = true,
                        targetState = ManagementTargetState.DIFFERS,
                        countsLabel = current.first,
                        refreshLabel = current.second,
                        onRefresh = {},
                        onContinue = {},
                        onCloseResult = {},
                    )
                }
            }
        }

        contexts.forEachIndexed { index, current ->
            if (index > 0) rule.runOnIdle { stage.intValue = index }
            rule.onNodeWithText(context.getString(R.string.settings_feedback_partial_title))
                .performScrollTo().assertIsDisplayed()
            rule.onNodeWithText(context.getString(R.string.management_target_summary, current.third))
                .performScrollTo().assertIsDisplayed()
            rule.onNodeWithText(context.getString(current.first, 1, 1, 1))
                .performScrollTo().assertIsDisplayed()
            assertReachable(current.second)
            assertReachable(R.string.continue_managing)
            assertReachable(R.string.close_result)
            assertLiveRegion(LiveRegionMode.Assertive)
        }
    }

    @Test
    fun 结构设置反馈覆盖安全硬件和远程访问的可变文案与操作() {
        val context = context()
        val stage = mutableIntStateOf(0)
        val contexts = listOf(
            R.string.security_feedback_counts to R.string.refresh_and_check_security_settings,
            R.string.hardware_feedback_counts to R.string.refresh_and_check_hardware_settings,
            R.string.remote_access_feedback_counts to R.string.refresh_and_check_remote_access,
        )
        rule.setContent {
            feedbackViewport {
                key(stage.intValue) {
                    val current = contexts[stage.intValue]
                    SettingsMutationFeedbackCard(
                        result = partialResult("syntheticSettings"),
                        failure = null,
                        refreshFailure = null,
                        refreshInProgress = false,
                        refreshCompleted = true,
                        currentMatches = false,
                        countsLabel = current.first,
                        refreshLabel = current.second,
                        onRefresh = {},
                        onContinueEditing = {},
                        onDismiss = {},
                    )
                }
            }
        }

        contexts.forEachIndexed { index, current ->
            if (index > 0) rule.runOnIdle { stage.intValue = index }
            rule.onNodeWithText(context.getString(R.string.settings_feedback_partial_title))
                .performScrollTo().assertIsDisplayed()
            rule.onNodeWithText(context.getString(R.string.service_action_partial))
                .performScrollTo().assertIsDisplayed()
            rule.onNodeWithText(context.getString(current.first, 1, 1, 1))
                .performScrollTo().assertIsDisplayed()
            assertReachable(current.second)
            assertReachable(R.string.continue_editing)
            assertReachable(R.string.discard_changes)
            assertLiveRegion(LiveRegionMode.Assertive)
        }
    }

    @Test
    fun 电源结果与失败反馈的说明和关闭操作可滚动到达() {
        val context = context()
        val stage = mutableIntStateOf(0)
        rule.setContent {
            feedbackViewport {
                key(stage.intValue) {
                    PowerActionFeedbackCard(
                        action = NasPowerAction.REBOOT,
                        result = confirmedResult("reboot").takeIf { stage.intValue == 0 },
                        failure = failure().takeIf { stage.intValue == 1 },
                        onDismiss = {},
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.reboot_accepted)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.power_accepted_not_completed))
            .performScrollTo().assertIsDisplayed()
        assertReachable(R.string.done)
        assertLiveRegion(LiveRegionMode.Polite)

        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.settings_feedback_failed_title)).assertIsDisplayed()
        assertLocalizedFailure()
        assertReachable(R.string.done)
        assertLiveRegion(LiveRegionMode.Assertive)
    }

    @Test
    fun Chat持久反馈的标题说明和操作在两倍字体下可达() {
        val context = context()
        val entry = ChatMutationEntry(
            target = ChatMutationTarget(
                profileId = "profile-synthetic",
                operation = ChatMutationOperation.TEXT_SEND,
                requestId = "request-synthetic",
                conversationId = "conversation-synthetic",
                requestFingerprint = "1".repeat(64),
            ),
            mutationResult = partialResult("chatTextSend"),
            mutationRefreshCompleted = true,
            mutationVerification = ChatMutationVerification.DIFFERS,
        )
        rule.setContent {
            feedbackViewport {
                ChatMutationFeedbackDialog(entry, { true }, { true }, { true })
            }
        }

        rule.onNodeWithText(context.getString(R.string.chat_mutation_feedback_partial_title))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.chat_mutation_counts, 1, 1, 1))
            .performScrollTo().assertIsDisplayed()
        assertAction(R.string.chat_mutation_continue_editing)
        assertAction(R.string.chat_mutation_close_checked)
        assertLiveRegion(LiveRegionMode.Assertive)
    }

    @Test
    fun FileStation持久反馈的标题说明和操作在两倍字体下可达() {
        val context = context()
        val target = FileStationMutationTarget(
            profileId = "profile-synthetic",
            module = Module.FILES,
            operation = FileStationMutationOperation.RENAME,
            sourceBaselines = listOf(fileItem()),
            requestedName = "renamed.txt",
        )
        val state = FileStationMutationWorkspaceState(
            draftTarget = target,
            target = target,
            mutationResult = partialResult("fileRename"),
            mutationRefreshCompleted = true,
            mutationVerification = FileStationMutationVerification.DIFFERS,
        )
        rule.setContent {
            feedbackViewport {
                FileStationMutationFeedbackDialog(state, { true }, { true }, { true })
            }
        }

        rule.onNodeWithText(context.getString(R.string.file_mutation_feedback_partial_title))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.file_mutation_counts, 1, 1, 1))
            .performScrollTo().assertIsDisplayed()
        assertAction(R.string.close_checked_file_mutation)
        assertLiveRegion(LiveRegionMode.Assertive)
    }

    @Test
    fun 下载控制持久反馈的标题说明和操作可滚动到达() {
        val context = context()
        rule.setContent {
            feedbackViewport {
                DownloadControlMutationFeedbackCard(
                    result = partialResult("downloadPause"),
                    failure = null,
                    refreshFailure = null,
                    refreshInProgress = false,
                    refreshCompleted = true,
                    mustRefresh = true,
                    currentMatches = false,
                    deleteFiles = false,
                    onRefresh = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.download_control_partial_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.download_action_partial_persistent))
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.download_control_feedback_counts, 1, 1, 1))
            .performScrollTo().assertIsDisplayed()
        assertReachable(R.string.close_checked_download_feedback)
        assertLiveRegion(LiveRegionMode.Assertive)
    }

    @Test
    fun 连接持久反馈的标题说明和操作可滚动到达() {
        val context = context()
        val present = mutableStateOf(true)
        rule.setContent {
            feedbackViewport {
                ConnectionMutationFeedbackCard(
                    target = connection(),
                    result = partialResult("connectionDisconnect"),
                    refreshCompleted = true,
                    targetStillPresent = present.value,
                    refreshFailure = null,
                    onRefresh = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.connection_feedback_check_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.connection_feedback_partial_message))
            .performScrollTo().assertIsDisplayed()
        assertReachable(R.string.refresh_and_check_connection)
        rule.onNodeWithText(context.getString(R.string.done)).performScrollTo().assertIsDisplayed().assertIsNotEnabled()
        assertLiveRegion(LiveRegionMode.Assertive)
        rule.runOnIdle { present.value = false }
        assertReachable(R.string.done)
    }

    @Test
    fun 区域持久反馈的标题说明和操作可滚动到达() {
        val context = context()
        rule.setContent {
            feedbackViewport {
                RegionMutationFeedbackCard(
                    result = partialResult("regionSettingsUpdate"),
                    refreshCompleted = true,
                    canContinueEditing = true,
                    onRefresh = {},
                    onContinueEditing = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.region_feedback_partial_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.region_feedback_partial_message))
            .performScrollTo().assertIsDisplayed()
        assertReachable(R.string.refresh_and_check_region_settings)
        assertReachable(R.string.continue_editing)
        assertReachable(R.string.discard_region_draft)
        assertLiveRegion(LiveRegionMode.Assertive)
    }

    @Test
    fun 文件服务终端和代理持久反馈的可变说明与操作可滚动到达() {
        val context = context()
        val stage = mutableIntStateOf(0)
        val messages = listOf(
            R.string.file_service_feedback_partial_message,
            R.string.terminal_feedback_partial_message,
            R.string.proxy_feedback_partial_message,
        )
        val refreshes = listOf(
            R.string.refresh_and_check_settings,
            R.string.refresh_and_check_terminal_settings,
            R.string.refresh_and_check_proxy_settings,
        )
        val discards = listOf(
            R.string.discard_file_service_draft,
            R.string.discard_terminal_draft,
            R.string.discard_proxy_draft,
        )
        rule.setContent {
            feedbackViewport {
                key(stage.intValue) {
                    val result = partialResult(
                        listOf("fileServiceSettingsUpdate", "terminalSettingsUpdate", "proxySettingsUpdate")[stage.intValue],
                    )
                    when (stage.intValue) {
                        0 -> FileServiceMutationFeedbackCard(result, refreshCompleted = true, canContinueEditing = true, onRefresh = {}, onContinueEditing = {}, onDismiss = {})
                        1 -> TerminalMutationFeedbackCard(result, refreshCompleted = true, canContinueEditing = true, onRefresh = {}, onContinueEditing = {}, onDismiss = {})
                        else -> ProxyMutationFeedbackCard(result, refreshCompleted = true, canContinueEditing = true, onRefresh = {}, onContinueEditing = {}, onDismiss = {})
                    }
                }
            }
        }

        messages.indices.forEach { index ->
            if (index > 0) rule.runOnIdle { stage.intValue = index }
            rule.onNodeWithText(context.getString(R.string.file_service_feedback_partial_title))
                .performScrollTo().assertIsDisplayed()
            rule.onNodeWithText(context.getString(messages[index])).performScrollTo().assertIsDisplayed()
            assertReachable(refreshes[index])
            assertReachable(R.string.continue_editing)
            assertReachable(discards[index])
            assertLiveRegion(LiveRegionMode.Assertive)
        }
    }

    @Test
    fun 以太网持久反馈的标题说明和操作可滚动到达() {
        val context = context()
        val draft = ethernet()
        rule.setContent {
            feedbackViewport {
                EthernetMutationFeedbackCard(
                    baseline = draft.copy(mtu = 1_400),
                    draft = draft,
                    currentTarget = draft.copy(mtu = 1_400),
                    result = partialResult("ethernetUpdate"),
                    refreshFailure = null,
                    refreshInProgress = false,
                    refreshCompleted = true,
                    onRefresh = {},
                    onContinueEditing = {},
                    onDismiss = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.ethernet_feedback_check_title)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.ethernet_feedback_partial_message))
            .performScrollTo().assertIsDisplayed()
        assertReachable(R.string.refresh_and_check_network_interface)
        assertReachable(R.string.continue_editing)
        assertReachable(R.string.discard_changes)
        assertLiveRegion(LiveRegionMode.Assertive)
    }

    @androidx.compose.runtime.Composable
    private fun feedbackViewport(content: @androidx.compose.runtime.Composable () -> Unit) {
        val density = LocalDensity.current
        CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
            LanStashTheme {
                Column(
                    Modifier.width(320.dp).height(480.dp).verticalScroll(rememberScrollState()),
                ) { content() }
            }
        }
    }

    private fun assertReachable(id: Int) {
        rule.onNodeWithText(context().getString(id))
            .performScrollTo().assertIsDisplayed().assertIsEnabled().assertHasClickAction()
    }

    private fun assertAction(id: Int) {
        rule.onNodeWithText(context().getString(id))
            .assertIsDisplayed().assertIsEnabled().assertHasClickAction()
    }

    private fun assertLocalizedFailure() {
        val context = context()
        rule.onNodeWithText(context.getString(R.string.error_connection_failed), substring = true)
            .performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.error_connection_failed_recovery), substring = true)
            .performScrollTo().assertIsDisplayed()
    }

    private fun assertLiveRegion(mode: LiveRegionMode) {
        rule.onNode(SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, mode)).assertExists()
    }

    private fun partialResult(operation: String) = MutationResult(
        schemaVersion = 1,
        status = MutationResultStatus.PARTIAL_SUCCESS,
        operation = operation,
        submitted = true,
        requiresRefresh = true,
        counts = MutationResultCounts(1, 1, 1),
    )

    private fun confirmedResult(operation: String) = MutationResult(
        schemaVersion = 1,
        status = MutationResultStatus.CONFIRMED_SUCCESS,
        operation = operation,
        submitted = true,
        requiresRefresh = false,
        counts = MutationResultCounts(1, 0, 0),
    )

    private fun failure() = DsmFailure(
        code = null,
        message = "Synthetic feedback failure",
        recovery = "Synthetic feedback recovery",
        kind = DsmErrorKind.CONNECTION_FAILED,
    )

    private fun ddnsProvider() = NasDdnsProvider("synthetic-provider", "Synthetic Provider")

    private fun ddnsDraft() = NasDdnsDraft(
        originalProviderId = "synthetic-provider",
        providerId = "synthetic-provider",
        hostname = "host.example.test",
        username = "synthetic-user",
    )

    private fun ddnsRecord() = NasDdnsRecord(
        providerId = "synthetic-provider",
        providerName = "Synthetic Provider",
        hostname = "host.example.test",
        address = "192.0.2.10",
        status = "normal",
        lastUpdated = null,
        isEnabled = true,
        username = "synthetic-user",
        networkType = "auto",
        ipv4 = "0.0.0.0",
        ipv6 = "0:0:0:0:0:0:0:0",
        interfaceV4 = "",
        interfaceV6 = "",
        heartbeat = false,
    )

    private fun fileItem() = FileItem(
        path = "/source.txt",
        name = "source.txt",
        isDirectory = false,
        canRead = true,
        canWrite = true,
    )

    private fun connection() = ActiveConnection(
        id = "connection-synthetic",
        user = "Synthetic operator",
        service = "HTTPS",
        client = "Synthetic browser",
        connectedAtEpochSeconds = null,
        isCurrent = false,
        type = "HTTP/HTTPS",
        canDisconnect = true,
    )

    private fun ethernet() = NasEthernetInterface(
        id = "eth0",
        displayName = "Synthetic LAN",
        status = "connected",
        usesDhcp = false,
        address = "192.0.2.10",
        subnetMask = "255.255.255.0",
        gateway = "192.0.2.1",
        dnsServers = "192.0.2.1",
        isDefaultGateway = false,
        mtu = 1_500,
        isVlanEnabled = false,
        vlanId = null,
    )

    private fun context() = InstrumentationRegistry.getInstrumentation().targetContext
}
