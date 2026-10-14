package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.suspendRunCatching
import io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection
import io.github.qwertyuiop1995.dsmnativeclient.domain.CapacitySummary
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDirectory
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRemoteAccessSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsArea
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasStorageDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.PackageInfo
import io.github.qwertyuiop1995.dsmnativeclient.domain.SystemSummary
import kotlinx.serialization.json.JsonObject

/**
 * NAS 管理总览只读编排。
 *
 * Gateway 保留 DsmRepository 中既有的请求 API、版本选择、解码与失败语义；
 * 本类仅组合各项读取结果和明确的可用性标记。
 */
internal interface DsmNasAdministrationRepositoryGateway {
    suspend fun systemRead(): JsonObject

    suspend fun storageRead(): JsonObject

    suspend fun packages(): List<PackageInfo>

    suspend fun accounts(): List<NasAccount>

    suspend fun groups(): List<NasGroup>

    suspend fun logsRead(): JsonObject

    suspend fun connections(): List<ActiveConnection>

    suspend fun ethernetInterfaces(): List<NasEthernetInterface>

    suspend fun ddnsDirectory(): NasDdnsDirectory

    suspend fun securitySettings(): NasSecuritySettings

    suspend fun hardwareSettings(): NasHardwareSettings

    suspend fun remoteAccessSettings(): NasRemoteAccessSettings

    suspend fun scheduledTasks(): List<ManagedResource>

    suspend fun fileServiceSettings(): NasFileServiceSettings

    suspend fun terminalSettings(): NasTerminalSettings

    suspend fun proxySettings(): NasProxySettings

    suspend fun regionSettings(): NasRegionSettings

    suspend fun securityResources(): List<ManagedResource>

    fun systemSummary(data: JsonObject): SystemSummary

    fun capacityList(data: JsonObject): List<CapacitySummary>

    fun genericResources(data: JsonObject, vararg roots: String): List<ManagedResource>

    fun storageDisks(data: JsonObject): List<NasStorageDisk>

    fun logs(data: JsonObject): List<LogEntry>
}

internal class DsmNasAdministrationRepository(
    private val gateway: DsmNasAdministrationRepositoryGateway,
) {
    suspend fun settings(area: NasSettingsArea? = null, previous: NasSettingsSnapshot? = null): NasSettingsSnapshot {
        fun includes(vararg values: NasSettingsArea) = area == null || area in values
        val system = if (includes(NasSettingsArea.OVERVIEW)) suspendRunCatching { gateway.systemSummary(gateway.systemRead()) } else null
        val storage = if (includes(NasSettingsArea.OVERVIEW, NasSettingsArea.STORAGE)) suspendRunCatching {
            val raw = gateway.storageRead()
            StorageSnapshot(gateway.capacityList(raw), gateway.genericResources(raw, "storagePools", "pools"),
                gateway.genericResources(raw, "disks"), gateway.storageDisks(raw))
        } else null
        val packages = if (includes(NasSettingsArea.OVERVIEW, NasSettingsArea.PACKAGES)) suspendRunCatching { gateway.packages() } else null
        val accounts = if (includes(NasSettingsArea.OVERVIEW, NasSettingsArea.DIRECTORY)) suspendRunCatching { gateway.accounts() } else null
        val groups = if (includes(NasSettingsArea.DIRECTORY)) suspendRunCatching { gateway.groups() } else null
        val logs = if (includes(NasSettingsArea.LOGS)) suspendRunCatching { gateway.logs(gateway.logsRead()) } else null
        val connections = if (includes(NasSettingsArea.OVERVIEW, NasSettingsArea.CONNECTIONS)) suspendRunCatching { gateway.connections() } else null
        val ethernet = if (includes(NasSettingsArea.NETWORK)) suspendRunCatching { gateway.ethernetInterfaces() } else null
        val ddns = if (includes(NasSettingsArea.NETWORK)) suspendRunCatching { gateway.ddnsDirectory() } else null
        val remote = if (includes(NasSettingsArea.NETWORK)) suspendRunCatching { gateway.remoteAccessSettings() } else null
        val security = if (includes(NasSettingsArea.SECURITY)) suspendRunCatching { gateway.securitySettings() } else null
        val securityResources = if (includes(NasSettingsArea.SECURITY)) suspendRunCatching { gateway.securityResources() } else null
        val hardware = if (includes(NasSettingsArea.HARDWARE)) suspendRunCatching { gateway.hardwareSettings() } else null
        val fileServices = if (includes(NasSettingsArea.SERVICES)) suspendRunCatching { gateway.fileServiceSettings() } else null
        val terminal = if (includes(NasSettingsArea.SERVICES)) suspendRunCatching { gateway.terminalSettings() } else null
        val proxy = if (includes(NasSettingsArea.SERVICES)) suspendRunCatching { gateway.proxySettings() } else null
        val region = if (includes(NasSettingsArea.REGION)) suspendRunCatching { gateway.regionSettings() } else null
        // 任务页使用独立严格读取；旧汇总仅保留给尚未迁移的调用方。
        val scheduled = if (area == null) suspendRunCatching { gateway.scheduledTasks() } else null
        return NasSettingsSnapshot(
            system = system?.getOrNull() ?: previous?.system,
            systemAvailable = system?.isSuccess ?: previous?.systemAvailable ?: false,
            volumes = storage?.getOrNull()?.volumes ?: previous?.volumes.orEmpty(),
            pools = storage?.getOrNull()?.pools ?: previous?.pools.orEmpty(),
            disks = storage?.getOrNull()?.disks ?: previous?.disks.orEmpty(),
            storageDisks = storage?.getOrNull()?.storageDisks ?: previous?.storageDisks.orEmpty(),
            storageAvailable = storage?.isSuccess ?: previous?.storageAvailable ?: false,
            packages = packages?.getOrNull() ?: previous?.packages.orEmpty(),
            packagesAvailable = packages?.isSuccess ?: previous?.packagesAvailable ?: false,
            accounts = accounts?.getOrNull() ?: previous?.accounts.orEmpty(),
            accountsAvailable = accounts?.isSuccess ?: previous?.accountsAvailable ?: false,
            groups = groups?.getOrNull() ?: previous?.groups.orEmpty(),
            groupsAvailable = groups?.isSuccess ?: previous?.groupsAvailable ?: false,
            logs = logs?.getOrNull() ?: previous?.logs.orEmpty(),
            logsAvailable = logs?.isSuccess ?: previous?.logsAvailable ?: false,
            connections = connections?.getOrNull() ?: previous?.connections.orEmpty(),
            connectionsAvailable = connections?.isSuccess ?: previous?.connectionsAvailable ?: false,
            networkInterfaces = ethernet?.getOrNull() ?: previous?.networkInterfaces.orEmpty(),
            networkInterfacesAvailable = ethernet?.isSuccess ?: previous?.networkInterfacesAvailable ?: false,
            ddnsDirectory = if (ddns == null) previous?.ddnsDirectory else ddns.getOrNull(),
            ddnsDirectoryAvailable = ddns?.isSuccess ?: previous?.ddnsDirectoryAvailable ?: false,
            remoteAccessSettings = if (remote == null) previous?.remoteAccessSettings else remote.getOrNull(),
            remoteAccessSettingsAvailable = remote?.isSuccess ?: previous?.remoteAccessSettingsAvailable ?: false,
            securitySettings = if (security == null) previous?.securitySettings else security.getOrNull(),
            securitySettingsAvailable = security?.isSuccess ?: previous?.securitySettingsAvailable ?: false,
            security = securityResources?.getOrNull() ?: previous?.security.orEmpty(),
            hardwareSettings = if (hardware == null) previous?.hardwareSettings else hardware.getOrNull(),
            hardwareSettingsAvailable = hardware?.isSuccess ?: previous?.hardwareSettingsAvailable ?: false,
            fileServiceSettings = if (fileServices == null) previous?.fileServiceSettings else fileServices.getOrNull(),
            terminalSettings = if (terminal == null) previous?.terminalSettings else terminal.getOrNull(),
            proxySettings = if (proxy == null) previous?.proxySettings else proxy.getOrNull(),
            regionSettings = if (region == null) previous?.regionSettings else region.getOrNull(),
            scheduledTasks = scheduled?.getOrNull() ?: previous?.scheduledTasks.orEmpty(),
            scheduledTasksAvailable = scheduled?.isSuccess ?: previous?.scheduledTasksAvailable ?: false,
        )
    }
    private data class StorageSnapshot(val volumes: List<CapacitySummary>, val pools: List<ManagedResource>,
        val disks: List<ManagedResource>, val storageDisks: List<NasStorageDisk>)
}
