package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.NasSettingsTab
import io.github.qwertyuiop1995.dsmnativeclient.readArea
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.*
import org.junit.Test

class NasSettingsPartitionTest {
    private val gateway = PartitionGateway()
    private val repository = DsmNasAdministrationRepository(gateway)
    @Test fun `日志页只读日志失败不调用其他设置且保存原摘要`() = runBlocking {
        val overview = repository.settings(NasSettingsArea.OVERVIEW)
        assertEquals(setOf("system", "storage", "packages", "accounts", "connections"), gateway.calls.toSet())
        gateway.calls.clear(); gateway.failures += "logs"
        val logs = repository.settings(NasSettingsArea.LOGS, overview)
        assertEquals(listOf("logs"), gateway.calls); assertFalse(logs.logsAvailable)
        assertEquals(overview.system, logs.system); assertEquals(overview.volumes, logs.volumes); assertTrue(logs.systemAvailable)
        gateway.failures.clear(); val empty = repository.settings(NasSettingsArea.LOGS, logs)
        assertTrue(empty.logsAvailable); assertTrue(empty.logs.isEmpty())
    }
    @Test fun `存储失败保留上次内容但不冒充成功空目录`() = runBlocking {
        val loaded = repository.settings(NasSettingsArea.STORAGE); assertTrue(loaded.storageAvailable); assertEquals(1, loaded.volumes.size)
        gateway.failures += "storage"; val failed = repository.settings(NasSettingsArea.STORAGE, loaded)
        assertFalse(failed.storageAvailable); assertEquals(loaded.volumes, failed.volumes)
        assertEquals(listOf("storage", "storage"), gateway.calls)
    }
    @Test fun `各设置只加载自己分组独立页面零汇总请求`() = runBlocking {
        val expected = mapOf(NasSettingsArea.SERVICES to setOf("files", "terminal", "proxy"), NasSettingsArea.REGION to setOf("region"),
            NasSettingsArea.NETWORK to setOf("ethernet", "ddns", "remote"), NasSettingsArea.SECURITY to setOf("security", "securityResources"),
            NasSettingsArea.HARDWARE to setOf("hardware"), NasSettingsArea.PACKAGES to setOf("packages"), NasSettingsArea.DIRECTORY to setOf("accounts", "groups"),
            NasSettingsArea.CONNECTIONS to setOf("connections"), NasSettingsArea.INDEPENDENT to emptySet())
        for ((area, calls) in expected) { gateway.calls.clear(); repository.settings(area); assertEquals(area.name, calls, gateway.calls.toSet()) }
        for (tab in listOf(NasSettingsTab.PERFORMANCE, NasSettingsTab.ACCOUNT, NasSettingsTab.SCHEDULED_TASKS)) assertEquals(NasSettingsArea.INDEPENDENT, tab.readArea())
        assertEquals(NasSettingsArea.INDEPENDENT, NasSettingsTab.LOGS.readArea())
        assertEquals(NasSettingsArea.OVERVIEW, NasSettingsTab.LOGS.readArea(Module.SETTINGS))
    }
    @Test fun `摘要解析错误属于对应读取失败不使无关分组消失`() = runBlocking {
        gateway.badSystem = true
        val snapshot = repository.settings(NasSettingsArea.OVERVIEW)
        assertFalse(snapshot.systemAvailable); assertNull(snapshot.system); assertTrue(snapshot.storageAvailable); assertTrue(snapshot.accountsAvailable)
        assertFalse(snapshot.scheduledTasksAvailable); assertFalse(snapshot.groupsAvailable)
    }
}

private class PartitionGateway : DsmNasAdministrationRepositoryGateway {
    val calls = mutableListOf<String>(); val failures = mutableSetOf<String>(); var badSystem = false
    private fun read(name: String) { calls += name; if (name in failures) throw IOException("Synthetic failure") }
    private fun unavailable(name: String): Nothing { read(name); throw IOException("Synthetic unavailable") }
    override suspend fun systemRead(): JsonObject { read("system"); return JsonObject(emptyMap()) }
    override suspend fun storageRead(): JsonObject { read("storage"); return JsonObject(emptyMap()) }
    override suspend fun packages(): List<PackageInfo> { read("packages"); return emptyList() }
    override suspend fun accounts(): List<NasAccount> { read("accounts"); return emptyList() }
    override suspend fun groups(): List<NasGroup> { read("groups"); return emptyList() }
    override suspend fun logsRead(): JsonObject { read("logs"); return JsonObject(emptyMap()) }
    override suspend fun connections(): List<ActiveConnection> { read("connections"); return emptyList() }
    override suspend fun ethernetInterfaces(): List<NasEthernetInterface> { read("ethernet"); return emptyList() }
    override suspend fun ddnsDirectory(): NasDdnsDirectory = unavailable("ddns")
    override suspend fun securitySettings(): NasSecuritySettings = unavailable("security")
    override suspend fun hardwareSettings(): NasHardwareSettings = unavailable("hardware")
    override suspend fun remoteAccessSettings(): NasRemoteAccessSettings = unavailable("remote")
    override suspend fun scheduledTasks(): List<ManagedResource> { read("scheduled"); return emptyList() }
    override suspend fun fileServiceSettings(): NasFileServiceSettings = unavailable("files")
    override suspend fun terminalSettings(): NasTerminalSettings = unavailable("terminal")
    override suspend fun proxySettings(): NasProxySettings = unavailable("proxy")
    override suspend fun regionSettings(): NasRegionSettings = unavailable("region")
    override suspend fun securityResources(): List<ManagedResource> { read("securityResources"); return emptyList() }
    override fun systemSummary(data: JsonObject): SystemSummary {
        if (badSystem) throw IOException("Synthetic invalid response")
        return SystemSummary("Synthetic", "Synthetic model", null, "Synthetic version", 10, null)
    }
    override fun capacityList(data: JsonObject) = listOf(CapacitySummary("volume", "Synthetic volume", 100, 10, ResourceState.UNKNOWN))
    override fun genericResources(data: JsonObject, vararg roots: String): List<ManagedResource> = emptyList()
    override fun storageDisks(data: JsonObject): List<NasStorageDisk> = emptyList()
    override fun logs(data: JsonObject): List<LogEntry> = emptyList()
}
