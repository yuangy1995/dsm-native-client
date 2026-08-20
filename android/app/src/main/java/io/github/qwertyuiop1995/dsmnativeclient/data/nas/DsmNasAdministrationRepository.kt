package io.github.qwertyuiop1995.dsmnativeclient.data.nas

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
    suspend fun settings(): NasSettingsSnapshot {
        val systemJson = runCatching { gateway.systemRead() }.getOrNull()
        val storageJson = runCatching { gateway.storageRead() }.getOrNull()
        val packageResult = runCatching { gateway.packages() }
        val accountResult = runCatching { gateway.accounts() }
        val groupResult = runCatching { gateway.groups() }
        val logResult = runCatching { gateway.logsRead() }
        val connectionResult = runCatching { gateway.connections() }
        val ethernetResult = runCatching { gateway.ethernetInterfaces() }
        val ddnsResult = runCatching { gateway.ddnsDirectory() }
        val securitySettingsResult = runCatching { gateway.securitySettings() }
        val hardwareSettingsResult = runCatching { gateway.hardwareSettings() }
        val remoteAccessSettingsResult = runCatching { gateway.remoteAccessSettings() }
        return NasSettingsSnapshot(
            system = systemJson?.let { gateway.systemSummary(it) },
            volumes = storageJson?.let { gateway.capacityList(it) }.orEmpty(),
            pools = storageJson?.let { gateway.genericResources(it, "storagePools", "pools") }.orEmpty(),
            disks = storageJson?.let { gateway.genericResources(it, "disks") }.orEmpty(),
            storageDisks = storageJson?.let { gateway.storageDisks(it) }.orEmpty(),
            packages = packageResult.getOrDefault(emptyList()),
            packagesAvailable = packageResult.isSuccess,
            scheduledTasks = runCatching { gateway.scheduledTasks() }.getOrDefault(emptyList()),
            accounts = accountResult.getOrDefault(emptyList()),
            accountsAvailable = accountResult.isSuccess,
            groups = groupResult.getOrDefault(emptyList()),
            groupsAvailable = groupResult.isSuccess,
            logs = logResult.getOrNull()?.let { gateway.logs(it) }.orEmpty(),
            connections = connectionResult.getOrDefault(emptyList()),
            connectionsAvailable = connectionResult.isSuccess,
            networkInterfaces = ethernetResult.getOrDefault(emptyList()),
            networkInterfacesAvailable = ethernetResult.isSuccess,
            ddnsDirectory = ddnsResult.getOrNull(),
            ddnsDirectoryAvailable = ddnsResult.isSuccess,
            fileServiceSettings = runCatching { gateway.fileServiceSettings() }.getOrNull(),
            terminalSettings = runCatching { gateway.terminalSettings() }.getOrNull(),
            proxySettings = runCatching { gateway.proxySettings() }.getOrNull(),
            regionSettings = runCatching { gateway.regionSettings() }.getOrNull(),
            securitySettings = securitySettingsResult.getOrNull(),
            hardwareSettings = hardwareSettingsResult.getOrNull(),
            security = gateway.securityResources(),
            securitySettingsAvailable = securitySettingsResult.isSuccess,
            hardwareSettingsAvailable = hardwareSettingsResult.isSuccess,
            remoteAccessSettings = remoteAccessSettingsResult.getOrNull(),
            remoteAccessSettingsAvailable = remoteAccessSettingsResult.isSuccess,
            logsAvailable = logResult.isSuccess,
        )
    }
}
