package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewContent
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDoSProtectionSetting
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestType
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasPowerAction
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRemoteAccessSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasStorageDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasUpsSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.PackageInfo
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.ui.ChatMutationConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.ConfirmDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.FileBrowserScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.FilePreviewDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.FileStationMutationConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadDeletionConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.DdnsConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.DirectoryDeletionConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.EthernetConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.HardwareConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.PackageMutationConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.PowerActionConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.RemoteAccessConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.SecurityConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.SmartTestConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VmmControlsContent
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

/** 生产确认框在系统 2× 字体下的标题、影响说明和操作可达性矩阵。 */
class ConfirmationFontScaleMatrixTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 通用确认框在两倍字体下保留标题影响和操作() {
        val context = context()
        setTwoX {
            ConfirmDialog(
                title = context.getString(R.string.remove_profile_title, "Synthetic NAS"),
                message = context.getString(R.string.remove_profile_message),
                confirm = context.getString(R.string.remove),
                destructive = true,
                onConfirm = {},
                onDismiss = {},
            )
        }
        assertVisible(context.getString(R.string.remove_profile_title, "Synthetic NAS"))
        assertVisible(context.getString(R.string.remove_profile_message))
        assertAction(context.getString(R.string.remove))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun Chat删除确认在两倍字体下保留影响和操作() {
        val context = context()
        setTwoX { ChatMutationConfirmationDialog(chatTarget(), { true }, { true }) }
        assertVisible(context.getString(R.string.remove_chat_reminder_title))
        assertVisible(context.getString(R.string.remove_chat_reminder_message))
        assertAction(context.getString(R.string.confirm_remove_chat_reminder))
        assertAction(context.getString(R.string.keep_chat_reminder))
    }

    @Test
    fun FileStation覆盖确认在两倍字体下保留影响和操作() {
        val context = context()
        setTwoX { FileStationMutationConfirmationDialog(fileTarget(), { true }, { true }) }
        assertVisible(context.getString(R.string.save_text_changes_title))
        assertVisible(context.getString(R.string.save_text_changes_message))
        assertAction(context.getString(R.string.replace_existing))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 下载删除确认在两倍字体下保留风险和操作() {
        val context = context()
        setTwoX { DownloadDeletionConfirmationDialog("Synthetic task", true, onConfirm = { true }, onDismiss = {}) }
        assertVisible(context.getString(R.string.remove_task_and_files_title))
        assertVisible(context.getString(R.string.download_delete_files_risk_summary), scroll = true)
        assertAction(context.getString(R.string.confirm_remove_task_and_files))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun DDNS删除确认在两倍字体下保留目标影响和操作() {
        val context = context()
        val record = ddnsRecord()
        setTwoX {
            DdnsConfirmationDialog(
                operation = DdnsMutationOperation.DELETE,
                draft = ddnsDraft(),
                deleteTarget = record,
                addressTargets = listOf(record),
                providers = ddnsProviders(),
                onConfirm = { true },
                onDismiss = {},
            )
        }
        assertVisible(context.getString(R.string.delete_ddns_record_confirm_title))
        assertVisible(context.getString(R.string.delete_ddns_record_confirm_message), scroll = true)
        assertVisible(record.hostname, scroll = true, substring = true)
        assertAction(context.getString(R.string.delete))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 以太网保存确认在两倍字体下保留影响和操作() {
        val context = context()
        val baseline = ethernet()
        setTwoX {
            EthernetConfirmationDialog(
                baseline = baseline,
                draft = baseline.copy(mtu = 1_400),
                onConfirm = { true },
                onDismiss = {},
            )
        }
        assertVisible(context.getString(R.string.save_network_interface_title, baseline.displayName))
        assertVisible(context.getString(R.string.save_network_interface_high_risk_message), substring = true)
        assertAction(context.getString(R.string.save_network_settings))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 目录删除确认在两倍字体下保留不可逆影响和操作() {
        val context = context()
        setTwoX { DirectoryDeletionConfirmationDialog(directoryTarget(), { true }, {}) }
        assertVisible(context.getString(R.string.delete_account_title, account().name))
        assertVisible(context.getString(R.string.directory_deletion_irreversible))
        assertAction(context.getString(R.string.delete_account))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 套件卸载确认在两倍字体下保留影响和操作() {
        val context = context()
        setTwoX { PackageMutationConfirmationDialog(pkg(), PackageMutationOperation.UNINSTALL, { true }, {}) }
        assertVisible(context.getString(R.string.uninstall_package_title, pkg().name))
        assertVisible(context.getString(R.string.uninstall_package_message))
        assertAction(context.getString(R.string.uninstall))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 远程访问确认在两倍字体下保留双重影响和操作() {
        val context = context()
        setTwoX { RemoteAccessConfirmationDialog(remote(), remote(false, false), { true }, {}) }
        assertVisible(context.getString(R.string.save_remote_access_title))
        assertVisible(context.getString(R.string.disable_relay_impact), scroll = true)
        assertVisible(context.getString(R.string.disable_router_configuration_impact), scroll = true)
        assertAction(context.getString(R.string.save_remote_access))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 安全设置确认在两倍字体下保留变更摘要和操作() {
        val context = context()
        setTwoX { SecurityConfirmationDialog(security(), security().copy(isAutoBlockEnabled = false), { true }, {}) }
        assertVisible(context.getString(R.string.save_security_settings_title))
        assertVisible(context.getString(R.string.save_security_settings_message))
        assertAction(context.getString(R.string.save))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 硬件设置确认在两倍字体下保留变更摘要和操作() {
        val context = context()
        setTwoX { HardwareConfirmationDialog(hardware(), hardware().copy(fanMode = "coolfan"), { true }, {}) }
        assertVisible(context.getString(R.string.save_hardware_settings_title))
        assertVisible(context.getString(R.string.save_hardware_settings_message))
        assertAction(context.getString(R.string.save))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 电源操作确认在两倍字体下保留影响和操作() {
        val context = context()
        setTwoX { PowerActionConfirmationDialog(NasPowerAction.REBOOT, { true }, {}) }
        assertVisible(context.getString(R.string.restart_nas_title))
        assertVisible(context.getString(R.string.restart_nas_message))
        assertAction(context.getString(R.string.restart_nas))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun SMART检测确认在两倍字体下保留目标影响和操作() {
        val context = context()
        setTwoX { SmartTestConfirmationDialog(disk(), NasDiskTestType.EXTENDED, { true }, {}) }
        assertVisible(context.getString(R.string.start_smart_test_title))
        assertVisible(context.getString(R.string.extended_smart_test_impact))
        assertAction(context.getString(R.string.extended_test))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 虚拟机关机确认在两倍字体下保留影响和操作() {
        val context = context()
        setTwoX { VmmControlsContent(vmConfirmation(VmmAction.SHUTDOWN), {}, { _, _ -> true }, { true }, {}, {}) }
        assertVisible("Synthetic VM")
        assertVisible(context.getString(R.string.vm_stop_risk))
        rule.onNode(hasText(context.getString(R.string.vm_stop)) and hasClickAction())
            .performScrollTo().assertIsDisplayed().assertIsEnabled()
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 虚拟机强制关机确认在两倍字体下保留风险和操作() {
        val context = context()
        setTwoX {
            VmmControlsContent(vmConfirmation(VmmAction.POWER_OFF), {}, { _, _ -> true }, { true }, {}, {})
        }
        assertVisible("Synthetic VM")
        assertVisible(context.getString(R.string.vm_poweroff_risk), scroll = true)
        rule.onNode(hasText(context.getString(R.string.vm_poweroff)) and hasClickAction())
            .performScrollTo().assertIsDisplayed().assertIsEnabled()
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 文件上传覆盖确认通过真实文件页在两倍字体下可达() {
        val context = context()
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        setTwoX {
            FileBrowserScreen(
                workspace().copy(
                    pendingFileUploads = PendingFileUploads(
                        uris = listOf(Uri.parse("content://synthetic/upload.txt")),
                        destinationPath = "/synthetic",
                        conflictCount = 1,
                        profileId = "synthetic-profile",
                        module = Module.FILES,
                        generation = 1,
                    ),
                ),
                model,
            )
        }
        assertVisible(context.getString(R.string.replace_upload_conflicts_title))
        assertVisible(context.getString(R.string.replace_upload_conflicts_message, 1))
        assertAction(context.getString(R.string.replace_existing))
        assertAction(context.getString(R.string.cancel))
    }

    @Test
    fun 文本修改丢弃确认通过真实预览页在两倍字体下可达() {
        val context = context()
        val item = textFile()
        setTwoX {
            FilePreviewDialog(
                item = item,
                preview = Loadable.Ready(FilePreviewContent.Text(item, "Synthetic body", false)),
                onRetry = {},
                onClose = {},
                textDraft = "Changed body",
                onTextDraftChange = {},
                onCancelTextEdit = {},
                discardConfirmationVisible = true,
                onConfirmDiscard = {},
                onDismissDiscard = {},
            )
        }
        assertVisible(context.getString(R.string.discard_text_changes_title))
        assertVisible(context.getString(R.string.discard_text_changes_message))
        assertAction(context.getString(R.string.discard_changes))
        assertAction(context.getString(R.string.keep_editing))
    }

    private fun setTwoX(content: @Composable () -> Unit) {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                LanStashTheme(darkTheme = true, content = content)
            }
        }
    }

    private fun assertVisible(text: String, scroll: Boolean = false, substring: Boolean = false) {
        val node = rule.onNodeWithText(text, substring = substring)
        if (scroll) node.performScrollTo()
        node.assertIsDisplayed()
    }

    private fun assertAction(text: String) {
        rule.onNodeWithText(text).assertIsDisplayed().assertIsEnabled().assertHasClickAction()
    }

    private fun context() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun chatTarget() = ChatMutationTarget(
        profileId = "synthetic-profile",
        operation = ChatMutationOperation.REMINDER_DELETE,
        requestId = "synthetic-request",
        conversationId = "synthetic-conversation",
        resourceIds = listOf("synthetic-reminder"),
        requestFingerprint = "0".repeat(64),
    )

    private fun fileTarget() = FileStationMutationTarget(
        profileId = "synthetic-profile",
        module = Module.FILES,
        operation = FileStationMutationOperation.TEXT_SAVE,
        sourceBaselines = listOf(textFile()),
        expectedContentSha256 = "0".repeat(64),
        expectedContentByteCount = 12,
    )

    private fun textFile() = FileItem(
        path = "/synthetic/readme.txt",
        name = "readme.txt",
        isDirectory = false,
        canRead = true,
        canWrite = true,
    )

    private fun ddnsProviders() = listOf(NasDdnsProvider("synthetic-provider", "Synthetic Provider"))

    private fun ddnsDraft() = NasDdnsDraft(
        originalProviderId = "synthetic-provider",
        providerId = "synthetic-provider",
        hostname = "host.example.test",
        username = "synthetic-user",
        password = "",
        isEnabled = true,
        heartbeat = false,
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

    private fun ethernet() = NasEthernetInterface(
        id = "eth0",
        displayName = "Synthetic LAN",
        status = "connected",
        usesDhcp = false,
        address = "192.0.2.10",
        subnetMask = "255.255.255.0",
        gateway = "192.0.2.1",
        dnsServers = "192.0.2.1",
        isDefaultGateway = true,
        mtu = 1_500,
        isVlanEnabled = false,
        vlanId = null,
    )

    private fun account() = NasAccount(1, "Synthetic operator", "Synthetic account", null, false, true)

    private fun directoryTarget() = DirectoryEntryMutationTarget(
        DirectoryEntryKind.ACCOUNT,
        account = account(),
    )

    private fun pkg() = PackageInfo(
        "synthetic-package", "Synthetic Package", "1.0", ResourceState.STOPPED,
        "Synthetic package", true, false, true,
    )

    private fun remote(relay: Boolean? = true, router: Boolean? = true) = NasRemoteAccessSettings(
        isRelayEnabled = relay,
        isRouterConfigurationEnabled = router,
        isConnectedThroughTrustedRelay = false,
        canManage = true,
    )

    private fun security() = NasSecuritySettings(
        true, 5, 10, 7,
        listOf(NasDoSProtectionSetting("eth0", "LAN", true)),
        true, "Default", true,
    )

    private fun hardware() = NasHardwareSettings(
        true, 2, 0, 3, "quietfan", true, true, true, true, true, true, true, true, true, true,
        NasUpsSettings(true, "USB", 30, true, false, null, null),
    )

    private fun disk() = NasStorageDisk(
        id = "disk-1",
        deviceId = "synthetic-device",
        name = "Synthetic drive",
        model = "Example",
        status = "normal",
        smartStatus = "normal",
        temperatureCelsius = 30.0,
        supportsSmartTest = true,
    )

    private fun vmConfirmation(action: VmmAction) = VmmControlState(loaded = true,
        confirmation = VmmControlConfirmation(listOf(VmmControlTarget("synthetic-vm", "Synthetic VM", "running", setOf(action))), action))

    private fun workspace() = WorkspaceState(
        profile = NasProfile("synthetic-profile", "Synthetic NAS", "https://nas.example.invalid", "tester"),
        selectedModule = Module.FILES,
        files = Loadable.Ready(FilePage(emptyList(), 0, 0)),
    )
}
