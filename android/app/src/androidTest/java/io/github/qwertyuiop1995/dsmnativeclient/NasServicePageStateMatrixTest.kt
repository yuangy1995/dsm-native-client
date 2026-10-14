package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ApplicationProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDirectory
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDoSProtectionSetting
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasManualDateTime
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRemoteAccessSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTimeZoneOption
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasUpsSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.PackageInfo
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.DirectoryManagementContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.DdnsManagementContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.EthernetSettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.HardwareSettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasConnectionContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasRegionSettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasRegionEditorState
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasServiceSettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.PackageManagementContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.RemoteAccessSettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.SecuritySettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

/** NAS 外层已负责加载和读取失败；这里只验证各数据页自身真实适用的页面状态。 */
class NasServicePageStateMatrixTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 套件页在两倍字体小屏覆盖不可用空内容正常和进行中状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        rule.setContent {
            largeTextSmallScreen {
                key(stage.intValue) {
                    PackageManagementContent(
                        packages = if (stage.intValue >= 2) listOf(packageInfo()) else emptyList(),
                        packagesAvailable = stage.intValue != 0,
                        target = packageInfo().takeIf { stage.intValue == 3 },
                        operation = PackageMutationOperation.START.takeIf { stage.intValue == 3 },
                        mutationInProgress = stage.intValue == 3,
                        result = null,
                        failure = null,
                        refreshFailure = null,
                        refreshInProgress = false,
                        refreshCompleted = false,
                        enabled = stage.intValue == 2,
                        onRequest = { _, _ -> },
                        onRefresh = {},
                        onContinue = {},
                        onCloseResult = {},
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.packages_unavailable)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.packages_empty)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNodeWithText(packageInfo().name).performScrollTo().assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 3 }
        rule.onNodeWithText(context.getString(R.string.package_action_in_progress))
            .performScrollTo().assertIsDisplayed()
    }

    @Test
    fun 目录管理页在两倍字体小屏覆盖不可用空内容正常和进行中状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        val account = account()
        rule.setContent {
            largeTextSmallScreen {
                key(stage.intValue) {
                    DirectoryManagementContent(
                        accounts = if (stage.intValue >= 2) listOf(account) else emptyList(),
                        groups = if (stage.intValue >= 2) listOf(group()) else emptyList(),
                        accountsAvailable = stage.intValue != 0,
                        groupsAvailable = stage.intValue != 0,
                        currentUsername = "current-user",
                        target = DirectoryEntryMutationTarget(
                            DirectoryEntryKind.ACCOUNT,
                            account = account,
                        ).takeIf { stage.intValue == 3 },
                        mutationInProgress = stage.intValue == 3,
                        result = null,
                        failure = null,
                        refreshFailure = null,
                        refreshInProgress = false,
                        refreshCompleted = false,
                        enabled = stage.intValue == 2,
                        onDeleteAccount = {},
                        onDeleteGroup = {},
                        onRefresh = {},
                        onContinue = {},
                        onCloseResult = {},
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.directory_unavailable)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.directory_management_empty)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNodeWithText(account.name).performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(group().name).performScrollTo().assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 3 }
        rule.onNodeWithText(context.getString(R.string.directory_deletion_in_progress))
            .performScrollTo().assertIsDisplayed()
    }

    @Test
    fun 活跃连接页在两倍字体小屏覆盖不可用空内容正常和进行中状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        val connection = connection()
        rule.setContent {
            largeTextSmallScreen {
                key(stage.intValue) {
                    NasConnectionContent(
                        state = io.github.qwertyuiop1995.dsmnativeclient.nas.NasConnectionState(
                            loaded = true, busy = stage.intValue == 3,
                            directory = if (stage.intValue == 0) null else io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasConnectionDirectory(
                                if (stage.intValue >= 2) listOf(connection) else emptyList(), true),
                            record = if (stage.intValue == 3) io.github.qwertyuiop1995.dsmnativeclient.nas.NasConnectionActivity(
                                "synthetic", io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner("profile", "identity", "session"),
                                io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasConnectionIdentity(true, "a".repeat(64), setOf("a".repeat(64)), "b".repeat(64))) else null),
                        onRequestDisconnect = { true }, onCancelRequest = {}, onConfirmRequest = { true },
                        onRefresh = {}, onDismissResult = {},
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.connections_unavailable)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.no_active_connections)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNode(hasScrollAction()).performScrollToNode(hasText(connection.user, substring = true))
        rule.onNodeWithText(connection.user, substring = true).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 3 }
        rule.onNodeWithText(context.getString(R.string.connection_disconnecting_title))
            .performScrollTo().assertIsDisplayed()
    }

    @Test
    fun 动态域名页在两倍字体小屏覆盖不可用空内容和正常状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        rule.setContent {
            largeTextSmallScreen {
                val directory = when (stage.intValue) {
                    0 -> null
                    1 -> NasDdnsDirectory(listOf(ddnsProvider()), emptyList())
                    else -> NasDdnsDirectory(listOf(ddnsProvider()), listOf(ddnsRecord()))
                }
                DdnsManagementContent(
                    directory = directory,
                    directoryAvailable = stage.intValue != 0,
                    enabled = true,
                    onAdd = {},
                    onRefreshAddress = {},
                    onEdit = {},
                    onDelete = {},
                )
            }
        }

        val unavailableTitle = context.getString(R.string.ddns_unavailable_title)
        rule.onNode(hasScrollAction()).performScrollToNode(hasText(unavailableTitle))
        rule.onNodeWithText(unavailableTitle).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.ddns_empty_title)).performScrollTo().assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNodeWithText(ddnsRecord().hostname).performScrollTo().assertIsDisplayed()
    }

    @Test
    fun 以太网页在两倍字体小屏覆盖不可用空内容正常和进行中状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        val ethernet = ethernet()
        rule.setContent {
            largeTextSmallScreen {
                EthernetSettingsContent(
                    interfaces = if (stage.intValue >= 2) listOf(ethernet) else emptyList(),
                    interfacesAvailable = stage.intValue != 0,
                    baseline = ethernet.takeIf { stage.intValue == 3 },
                    draft = ethernet.takeIf { stage.intValue == 3 },
                    mutationResult = null,
                    mutationFailure = null,
                    refreshFailure = null,
                    mutationInProgress = stage.intValue == 3,
                    refreshInProgress = false,
                    refreshCompleted = false,
                    isPerformingAction = stage.intValue == 3,
                    currentTarget = ethernet.takeIf { stage.intValue >= 2 },
                    onEdit = {}, onRefresh = {}, onContinueEditing = {}, onDismissResult = {}, onRefreshList = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.network_interfaces_unavailable)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.no_physical_network_interfaces)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNodeWithText(ethernet.displayName).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 3 }
        rule.onNodeWithText(context.getString(R.string.ethernet_saving_title)).assertIsDisplayed()
    }

    @Test
    fun 硬件设置页在两倍字体小屏覆盖不可用正常和进行中状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        val settings = hardware()
        rule.setContent {
            largeTextSmallScreen {
                HardwareSettingsContent(
                    settings = settings.takeIf { stage.intValue > 0 },
                    settingsAvailable = stage.intValue > 0,
                    baseline = settings.takeIf { stage.intValue == 2 },
                    draft = settings.takeIf { stage.intValue == 2 },
                    mutationInProgress = stage.intValue == 2,
                    mutationResult = null, mutationFailure = null, refreshFailure = null,
                    refreshInProgress = false, refreshCompleted = false,
                    powerAction = null, powerInProgress = false, powerResult = null, powerFailure = null,
                    enabled = stage.intValue == 1,
                    onEdit = {}, onRefresh = {}, onContinueEditing = {}, onDismissResult = {},
                    onPowerAction = {}, onDismissPowerResult = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.hardware_settings_unavailable)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.hardware_settings)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNodeWithText(context.getString(R.string.hardware_saving_title)).assertIsDisplayed()
    }

    @Test
    fun 区域设置页在两倍字体小屏覆盖不可用正常和进行中状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        rule.setContent {
            largeTextSmallScreen {
                NasRegionSettingsContent(region().takeIf { stage.intValue > 0 }, stage.intValue == 2,
                    NasRegionEditorState(current = region().takeIf { stage.intValue > 0 }, busy = stage.intValue == 2, saving = stage.intValue == 2),
                    { false }, {}, { _, _ -> false }, {}, {})
            }
        }

        rule.onNodeWithText(context.getString(R.string.region_settings_unavailable)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.region_and_time)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNodeWithText(context.getString(R.string.region_saving_title)).assertIsDisplayed()
    }

    @Test
    fun 远程访问页在两倍字体小屏覆盖不可用正常和进行中状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        val settings = remoteAccess()
        rule.setContent {
            largeTextSmallScreen {
                RemoteAccessSettingsContent(
                    settings = settings.takeIf { stage.intValue > 0 },
                    settingsAvailable = stage.intValue > 0,
                    baseline = settings.takeIf { stage.intValue == 2 },
                    draft = settings.takeIf { stage.intValue == 2 },
                    mutationInProgress = stage.intValue == 2,
                    mutationResult = null, mutationFailure = null, refreshFailure = null,
                    refreshInProgress = false, refreshCompleted = false,
                    isPerformingAction = stage.intValue == 2,
                    onEdit = {}, onRefresh = {}, onContinueEditing = {}, onDismissResult = {}, onRefreshSettings = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.remote_access_read_failed_title)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.quickconnect_relay)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNodeWithText(context.getString(R.string.remote_access_saving_title)).assertIsDisplayed()
    }

    @Test
    fun 安全设置页在两倍字体小屏覆盖不可用空内容正常和进行中状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        val settings = security()
        rule.setContent {
            largeTextSmallScreen {
                SecuritySettingsContent(
                    settings = settings.takeIf { stage.intValue >= 2 },
                    settingsAvailable = stage.intValue != 0,
                    fallback = emptyList(),
                    baseline = settings.takeIf { stage.intValue == 3 },
                    draft = settings.takeIf { stage.intValue == 3 },
                    mutationInProgress = stage.intValue == 3,
                    mutationResult = null, mutationFailure = null, refreshFailure = null,
                    refreshInProgress = false, refreshCompleted = false,
                    enabled = stage.intValue == 2,
                    onEdit = {}, onRefresh = {}, onContinueEditing = {}, onDismissResult = {},
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.security_settings_unavailable)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.security_settings_empty)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNodeWithText(context.getString(R.string.security_protection)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 3 }
        rule.onNodeWithText(context.getString(R.string.security_saving_title)).assertIsDisplayed()
    }

    @Test
    fun 服务设置页在两倍字体小屏覆盖不可用正常和进行中状态() {
        val context = context()
        val stage = mutableIntStateOf(0)
        rule.setContent {
            largeTextSmallScreen {
                val snapshot = serviceSnapshot(stage.intValue > 0)
                val states = NasServiceUiFixture(snapshot).states.value.mapValues { (kind, value) ->
                    if (kind == NasServiceKind.FILES) value.copy(busy = stage.intValue == 2, saving = stage.intValue == 2) else value
                }
                NasServiceSettingsContent(snapshot, stage.intValue == 2, states, { false }, { _, _ -> }, { false }, {}, { _, _ -> })
            }
        }

        rule.onNodeWithText(context.getString(R.string.no_service_settings)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 1 }
        rule.onNodeWithText(context.getString(R.string.file_services)).assertIsDisplayed()
        rule.runOnIdle { stage.intValue = 2 }
        rule.onNodeWithText(context.getString(R.string.file_service_saving_title)).assertIsDisplayed()
    }

    @androidx.compose.runtime.Composable
    private fun largeTextSmallScreen(content: @androidx.compose.runtime.Composable () -> Unit) {
        val density = LocalDensity.current
        CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
            LanStashTheme {
                Box(Modifier.width(320.dp).height(480.dp)) { content() }
            }
        }
    }

    private fun context() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun packageInfo() = PackageInfo(
        id = "synthetic-package",
        name = "Synthetic Package",
        version = "1.0",
        status = ResourceState.STOPPED,
        description = "Synthetic package",
        canStart = true,
        canStop = false,
        canUninstall = true,
    )

    private fun account() = NasAccount(
        id = 1,
        name = "Synthetic operator",
        description = "Synthetic account",
        email = null,
        disabled = false,
        canDelete = true,
    )

    private fun group() = NasGroup(
        id = 2,
        name = "Synthetic group",
        description = "Synthetic group",
        canDelete = true,
    )

    private fun connection() = ActiveConnection(
        id = "synthetic-connection",
        user = "Synthetic operator",
        service = "HTTPS",
        client = "Synthetic browser",
        connectedAtEpochSeconds = null,
        isCurrent = false,
        deviceId = "synthetic-device",
        type = "HTTP/HTTPS",
        canDisconnect = true,
    )

    private fun ddnsProvider() = NasDdnsProvider("synthetic", "Synthetic DDNS")

    private fun ddnsRecord() = NasDdnsRecord(
        "synthetic", "Synthetic DDNS", "host.example.invalid", "192.0.2.10", "normal", null,
        true, "synthetic-user", "auto", "0.0.0.0", "0:0:0:0:0:0:0:0", "", "", false,
    )

    private fun ethernet() = NasEthernetInterface(
        "eth0", "Synthetic LAN", "connected", false, "192.0.2.10", "255.255.255.0",
        "192.0.2.1", "192.0.2.1", false, 1_500, false, null,
    )

    private fun hardware() = NasHardwareSettings(
        true, 2, 0, 3, "quietfan", true, true, true, true, true, true, true, true, true, true,
        NasUpsSettings(true, "USB", 30, true, false, null, null),
    )

    private fun remoteAccess() = NasRemoteAccessSettings(true, true, false, true)

    private fun security() = NasSecuritySettings(
        true, 5, 10, 7, listOf(NasDoSProtectionSetting("eth0", "Synthetic LAN", true)),
        true, "Default", true,
    )

    private fun region() = NasRegionSettings(
        "Y-m-d", "H:i", "Asia/Shanghai", true, listOf("time.example.invalid"),
        NasManualDateTime(2026, 8, 5, 12, 34, 56),
        listOf(NasTimeZoneOption("Asia/Shanghai", "Beijing, Shanghai")),
    )

    private fun fileService() = NasFileServiceSettings(
        true, true, false, false, 21, true, 22, false, true, false,
    )

    private fun serviceSnapshot(available: Boolean) = NasSettingsSnapshot(
        system = null, volumes = emptyList(), pools = emptyList(), disks = emptyList(),
        storageDisks = emptyList(), packages = emptyList(), scheduledTasks = emptyList(),
        accounts = emptyList(), groups = emptyList(), logs = emptyList(), connections = emptyList(),
        connectionsAvailable = true, networkInterfaces = emptyList(), networkInterfacesAvailable = true,
        ddnsDirectory = null, ddnsDirectoryAvailable = true,
        fileServiceSettings = fileService().takeIf { available },
        terminalSettings = NasTerminalSettings(true, false, 22).takeIf { available },
        proxySettings = NasProxySettings(false, "", null).takeIf { available },
        regionSettings = null, securitySettings = null, hardwareSettings = null, security = emptyList(),
    )
}
