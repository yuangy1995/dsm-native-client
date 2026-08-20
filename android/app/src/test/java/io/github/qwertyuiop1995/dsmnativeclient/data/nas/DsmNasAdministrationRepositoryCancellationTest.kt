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
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasStorageDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.PackageInfo
import io.github.qwertyuiop1995.dsmnativeclient.domain.SystemSummary
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertSame
import org.junit.Test

class DsmNasAdministrationRepositoryCancellationTest {
    @Test
    fun `任一挂起分区读取取消必须继续传播`() = runBlocking {
        val expected = CancellationException("system partition cancelled")

        val actual = captureCancellation {
            DsmNasAdministrationRepository(CancellingNasGateway(expected)).settings()
        }

        assertSame(expected, actual)
    }

    private suspend fun captureCancellation(block: suspend () -> Unit): CancellationException {
        try {
            block()
        } catch (error: CancellationException) {
            return error
        }
        throw AssertionError("预期取消异常继续传播")
    }
}

private class CancellingNasGateway(
    private val cancellation: CancellationException,
) : DsmNasAdministrationRepositoryGateway {
    override suspend fun systemRead(): JsonObject = throw cancellation
    override suspend fun storageRead(): JsonObject = JsonObject(emptyMap())
    override suspend fun packages(): List<PackageInfo> = emptyList()
    override suspend fun accounts(): List<NasAccount> = emptyList()
    override suspend fun groups(): List<NasGroup> = emptyList()
    override suspend fun logsRead(): JsonObject = JsonObject(emptyMap())
    override suspend fun connections(): List<ActiveConnection> = emptyList()
    override suspend fun ethernetInterfaces(): List<NasEthernetInterface> = emptyList()
    override suspend fun ddnsDirectory(): NasDdnsDirectory = error("不应继续读取 DDNS")
    override suspend fun securitySettings(): NasSecuritySettings = error("不应继续读取安全设置")
    override suspend fun hardwareSettings(): NasHardwareSettings = error("不应继续读取硬件设置")
    override suspend fun remoteAccessSettings(): NasRemoteAccessSettings = error("不应继续读取远程访问设置")
    override suspend fun scheduledTasks(): List<ManagedResource> = emptyList()
    override suspend fun fileServiceSettings(): NasFileServiceSettings = error("不应继续读取文件服务设置")
    override suspend fun terminalSettings(): NasTerminalSettings = error("不应继续读取终端设置")
    override suspend fun proxySettings(): NasProxySettings = error("不应继续读取代理设置")
    override suspend fun regionSettings(): NasRegionSettings = error("不应继续读取区域设置")
    override suspend fun securityResources(): List<ManagedResource> = emptyList()
    override fun systemSummary(data: JsonObject): SystemSummary = error("不应解析系统摘要")
    override fun capacityList(data: JsonObject): List<CapacitySummary> = emptyList()
    override fun genericResources(data: JsonObject, vararg roots: String): List<ManagedResource> = emptyList()
    override fun storageDisks(data: JsonObject): List<NasStorageDisk> = emptyList()
    override fun logs(data: JsonObject): List<LogEntry> = emptyList()
}
