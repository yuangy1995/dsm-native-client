package io.github.qwertyuiop1995.dsmnativeclient.domain

data class SystemSummary(
    val serverName: String,
    val model: String,
    val serial: String?,
    val dsmVersion: String,
    val uptimeSeconds: Long?,
    val temperatureCelsius: Double?,
)

/** DSM 更新服务返回的只读检查结果；不代表已下载或安装更新。 */
data class NasSystemUpdateInfo(
    val isUpdateAvailable: Boolean,
    val currentVersion: String?,
    val latestVersion: String?,
    val releaseNotes: String?,
)

data class CapacitySummary(
    val id: String,
    val name: String,
    val totalBytes: Long,
    val usedBytes: Long,
    val status: ResourceState,
)

enum class NasDiskTestType { QUICK, EXTENDED }

data class NasStorageDisk(
    val id: String,
    /** 必须来自存储列表，只用于硬盘检测请求，不能接受用户输入。 */
    val deviceId: String,
    val name: String,
    val model: String?,
    val status: String?,
    val smartStatus: String?,
    val temperatureCelsius: Double?,
    val supportsSmartTest: Boolean,
)

data class NasDiskTestStatus(
    val diskId: String,
    val isRunning: Boolean,
    val isBusyWithOtherTest: Boolean,
    val runningType: NasDiskTestType?,
    val progressDescription: String?,
    val lastQuickTest: String?,
    val lastExtendedTest: String?,
    val lastResult: String?,
    val isHistoryAvailable: Boolean,
)

data class PerformanceSample(
    val timeEpochSeconds: Long,
    val cpuPercent: Double?,
    val cpuUserPercent: Double?,
    val cpuSystemPercent: Double?,
    val memoryPercent: Double?,
    val swapPercent: Double?,
    val networkReceiveBytesPerSecond: Long?,
    val networkSendBytesPerSecond: Long?,
    val diskReadBytesPerSecond: Long?,
    val diskWriteBytesPerSecond: Long?,
    val volumeReadBytesPerSecond: Long?,
    val volumeWriteBytesPerSecond: Long?,
    val diskUtilizationPercent: Double?,
)

data class NasAccount(
    val id: Long?,
    val name: String,
    val description: String?,
    val email: String?,
    val disabled: Boolean,
    val canDelete: Boolean = false,
    val canEdit: Boolean = false,
    val groups: List<String>? = null,
    val disabledKnown: Boolean = true,
)

data class NasGroup(
    val id: Long?,
    val name: String,
    val description: String?,
    val canDelete: Boolean = false,
    val canEdit: Boolean = false,
)

data class PackageInfo(
    val id: String,
    val name: String,
    val version: String,
    val status: ResourceState,
    val description: String?,
    val canStart: Boolean,
    val canStop: Boolean,
    val canUninstall: Boolean = false,
    val dsmApps: List<String> = emptyList(),
    /** `available_operation` 明确给出升级候选；更新进入独立安装计划，不调用旧直接升级接口。 */
    val isUpgradeAvailable: Boolean = false,
    val installType: String? = null,
    val installedAt: Double? = null,
)

data class ActiveConnection(
    val id: String,
    val user: String,
    val service: String,
    val client: String,
    val connectedAtEpochSeconds: Long?,
    val isCurrent: Boolean,
    val processId: String? = null,
    val deviceId: String? = null,
    val type: String? = null,
    val description: String? = null,
    val canDisconnect: Boolean = false,
    val isCurrentKnown: Boolean = true,
    val reportedTime: String? = null,
    val location: String? = null,
) {
    override fun toString() = "ActiveConnection(redacted)"
}

data class NasEthernetInterface(
    val id: String,
    val displayName: String,
    val status: String?,
    val usesDhcp: Boolean,
    val address: String,
    val subnetMask: String,
    val gateway: String,
    val dnsServers: String,
    val isDefaultGateway: Boolean,
    val mtu: Int,
    val isVlanEnabled: Boolean,
    val vlanId: Int?,
)

data class NasDdnsProvider(
    val id: String,
    val displayName: String,
)

data class NasDdnsRecord(
    val providerId: String,
    val providerName: String,
    val hostname: String,
    val address: String?,
    val status: String?,
    val lastUpdated: String?,
    val isEnabled: Boolean,
    val username: String,
    val networkType: String,
    val ipv4: String,
    val ipv6: String,
    val interfaceV4: String,
    val interfaceV6: String,
    val heartbeat: Boolean,
    val knownNetworkFields: Set<String> = setOf("net", "ip", "ipv6", "interface_v4", "interface_v6"),
)

data class NasDdnsDirectory(
    val providers: List<NasDdnsProvider>,
    val records: List<NasDdnsRecord>,
)

/** null 字段表示当前 NAS 未提供对应文件服务能力。 */
data class NasFileServiceSettings(
    val isSmbEnabled: Boolean?,
    val isNfsEnabled: Boolean?,
    val isFtpEnabled: Boolean?,
    val isFtpsEnabled: Boolean?,
    val ftpPort: Int?,
    val isSftpEnabled: Boolean?,
    val sftpPort: Int?,
    val isSsdpEnabled: Boolean?,
    val isBonjourEnabled: Boolean?,
    val isSmbTimeMachineEnabled: Boolean?,
)

data class NasTerminalSettings(
    val isSshEnabled: Boolean,
    val isTelnetEnabled: Boolean,
    val sshPort: Int?,
)

/** 互联网代理凭据不在此模型中读取、保存或提交。 */
data class NasProxySettings(
    val isEnabled: Boolean,
    val host: String,
    val port: Int?,
)

/**
 * DSM 远程访问设置。null 表示对应内部接口不可用或响应不可信，不得折叠为关闭。
 * 连接类别与管理权限均由客户端可信上下文派生，不接受界面输入。
 */
data class NasRemoteAccessSettings(
    val isRelayEnabled: Boolean?,
    val isRouterConfigurationEnabled: Boolean?,
    val isConnectedThroughTrustedRelay: Boolean,
    val canManage: Boolean,
)

data class NasTimeZoneOption(
    val id: String,
    val displayName: String,
)

/** NAS 返回的墙上时间；仅用于区域设置预检与用户明确编辑后的提交。 */
data class NasManualDateTime(
    val year: Int,
    val month: Int,
    val day: Int,
    val hour: Int,
    val minute: Int,
    val second: Int,
)

data class NasRegionSettings(
    val dateFormat: String,
    val timeFormat: String,
    val timeZone: String,
    val isNetworkTimeEnabled: Boolean,
    val timeServers: List<String>,
    /** null 表示用户没有编辑手动时间，保存时必须使用刚从 NAS 读取的值。 */
    val manualDateTime: NasManualDateTime?,
    val timeZones: List<NasTimeZoneOption>,
)

data class NasDoSProtectionSetting(
    val id: String,
    val displayName: String,
    val isEnabled: Boolean,
)

data class NasSecuritySettings(
    val isAutoBlockEnabled: Boolean,
    val failedAttempts: Int,
    val withinMinutes: Int,
    /** null 表示封锁不会自动过期。 */
    val expirationDays: Int?,
    val dosProtection: List<NasDoSProtectionSetting>,
    val isFirewallEnabled: Boolean?,
    /** 只接受 NAS 预检返回的配置档名称，界面不得允许用户输入。 */
    val firewallProfileName: String?,
    val isPortScanProtectionEnabled: Boolean?,
)

data class NasUpsSettings(
    val isEnabled: Boolean,
    val mode: String,
    val safeModeDelaySeconds: Int?,
    val waitsUntilLowBattery: Boolean?,
    val shutsDownUpsAfterSafeMode: Boolean?,
    val networkServerAddress: String?,
    val snmpServerAddress: String?,
)

/** null 字段表示当前设备未提供对应硬件能力。 */
data class NasHardwareSettings(
    val restartsAfterPowerFailure: Boolean?,
    val ledBrightness: Int?,
    val ledBrightnessMinimum: Int?,
    val ledBrightnessMaximum: Int?,
    val fanMode: String?,
    val isFanFailureAlertEnabled: Boolean?,
    val isVolumeFailureAlertEnabled: Boolean?,
    val isPowerOnSoundEnabled: Boolean?,
    val isPowerOffSoundEnabled: Boolean?,
    val isResetSoundEnabled: Boolean?,
    val isExternalDriveDeepSleepEnabled: Boolean?,
    val isWakeUpLogEnabled: Boolean?,
    val isSataSleepEnabled: Boolean?,
    val ignoresNetworkDiscoveryDuringSleep: Boolean?,
    val isAutomaticPowerOffEnabled: Boolean?,
    val ups: NasUpsSettings?,
    val supportedFanModes: List<String>? = null,
    val beepVolumeFieldName: String? = null,
)

/** DDNS 密码或密钥只用于当前测试或保存请求，不得持久化。 */
data class NasDdnsDraft(
    val originalProviderId: String? = null,
    val providerId: String,
    val hostname: String,
    val username: String,
    val password: String = "",
    val isEnabled: Boolean = true,
    val networkType: String = "auto",
    val ipv4: String = "0.0.0.0",
    val ipv6: String = "0:0:0:0:0:0:0:0",
    val interfaceV4: String = "",
    val interfaceV6: String = "",
    val heartbeat: Boolean = false,
) { override fun toString() = "NasDdnsDraft" }

enum class NasSettingsArea { OVERVIEW, STORAGE, PACKAGES, DIRECTORY, LOGS, CONNECTIONS, SERVICES, REGION, NETWORK, SECURITY, HARDWARE, INDEPENDENT }

data class NasSettingsSnapshot(
    val system: SystemSummary?,
    val volumes: List<CapacitySummary>,
    val pools: List<ManagedResource>,
    val disks: List<ManagedResource>,
    val storageDisks: List<NasStorageDisk>,
    val packages: List<PackageInfo>,
    val scheduledTasks: List<ManagedResource>,
    val accounts: List<NasAccount>,
    val groups: List<NasGroup>,
    val logs: List<LogEntry>,
    val connections: List<ActiveConnection>,
    val connectionsAvailable: Boolean,
    val networkInterfaces: List<NasEthernetInterface>,
    val networkInterfacesAvailable: Boolean,
    val ddnsDirectory: NasDdnsDirectory?,
    val ddnsDirectoryAvailable: Boolean,
    val fileServiceSettings: NasFileServiceSettings?,
    val terminalSettings: NasTerminalSettings?,
    val proxySettings: NasProxySettings?,
    val regionSettings: NasRegionSettings?,
    val securitySettings: NasSecuritySettings?,
    val hardwareSettings: NasHardwareSettings?,
    val security: List<ManagedResource>,
    /** false 表示安全设置读取失败，不得把 null 当成可信空配置。 */
    val securitySettingsAvailable: Boolean = securitySettings != null,
    /** false 表示硬件设置读取失败，不得把 null 当成设备没有对应能力。 */
    val hardwareSettingsAvailable: Boolean = hardwareSettings != null,
    /** false 表示套件列表读取失败，空列表不得用于确认卸载成功。 */
    val packagesAvailable: Boolean = true,
    /** false 表示账号列表读取失败，空列表不得用于确认删除成功。 */
    val accountsAvailable: Boolean = true,
    /** false 表示群组列表读取失败，空列表不得用于确认删除成功。 */
    val groupsAvailable: Boolean = true,
    val remoteAccessSettings: NasRemoteAccessSettings? = null,
    /** false 表示两项远程访问读取均失败，不得把 null 当成可信关闭。 */
    val remoteAccessSettingsAvailable: Boolean = remoteAccessSettings != null,
    /** false 表示日志读取失败，空列表不得展示为可信的“没有日志”。 */
    val logsAvailable: Boolean = true,
    val systemAvailable: Boolean = system != null,
    val storageAvailable: Boolean = true,
    val scheduledTasksAvailable: Boolean = true,
)
