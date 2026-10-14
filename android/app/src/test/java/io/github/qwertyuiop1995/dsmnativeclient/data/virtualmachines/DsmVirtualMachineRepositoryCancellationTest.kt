package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineHardware
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTaskCenterState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertSame
import org.junit.Test

class DsmVirtualMachineRepositoryCancellationTest {
    @Test
    fun `可选分区读取取消必须继续传播`() = runBlocking {
        val expected = CancellationException("optional section cancelled")

        val actual = captureCancellation {
            DsmVirtualMachineRepository(CancellingVirtualMachineGateway(Mode.OPTIONAL, expected))
                .overview()
        }

        assertSame(expected, actual)
    }

    @Test
    fun `保护计划读取取消必须继续传播`() = runBlocking {
        val expected = CancellationException("protection cancelled")

        val actual = captureCancellation {
            DsmVirtualMachineRepository(CancellingVirtualMachineGateway(Mode.PROTECTION, expected))
                .overview()
        }

        assertSame(expected, actual)
    }

    @Test
    fun `日志读取取消必须继续传播`() = runBlocking {
        val expected = CancellationException("logs cancelled")

        val actual = captureCancellation {
            DsmVirtualMachineRepository(CancellingVirtualMachineGateway(Mode.LOGS, expected))
                .overview()
        }

        assertSame(expected, actual)
    }

    @Test fun `所有可选分区及公开摘要的会话错误必须停止`() = runBlocking {
        for (mode in Mode.entries) {
            val failure = DsmFailure(106, "Synthetic", "", kind = DsmErrorKind.SESSION_EXPIRED)
            val result = runCatching { DsmVirtualMachineRepository(CancellingVirtualMachineGateway(mode, failure)).overview() }.exceptionOrNull()
            assertSame(failure, result)
        }
    }
    @Test fun `所有可选分区及公开摘要的证书错误必须停止`() = runBlocking {
        for (mode in Mode.entries) {
            val failure = DsmFailure(null, "Synthetic", "", kind = DsmErrorKind.TLS_UNTRUSTED)
            val result = runCatching { DsmVirtualMachineRepository(CancellingVirtualMachineGateway(mode, failure)).overview() }.exceptionOrNull()
            assertSame(failure, result)
        }
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

private enum class Mode {
    OFFICIAL,
    OPTIONAL,
    PROTECTION,
    LOGS,
}

private class CancellingVirtualMachineGateway(
    private val mode: Mode,
    private val cancellation: Exception,
) : DsmVirtualMachineRepositoryGateway {
    override fun preferred(vararg names: String): String = "guest"

    override fun preferredOrNull(vararg names: String): String? = when (mode) {
        Mode.OPTIONAL -> if (names.any { it.contains("Host") }) "host" else null
        Mode.PROTECTION,
        Mode.OFFICIAL,
        Mode.LOGS,
        -> null
    }

    override fun supports(apiName: String): Boolean = when (mode) {
        Mode.PROTECTION -> apiName == "SYNO.Virtualization.GuestProtect.Plan"
        Mode.LOGS -> apiName == "SYNO.Virtualization.Log"
        Mode.OPTIONAL, Mode.OFFICIAL -> false
    }

    override fun supportsVersion(apiName: String, version: Int): Boolean = mode == Mode.OFFICIAL

    override suspend fun officialRead(): Pair<List<ManagedResource>, List<VirtualMachineHardware>?> =
        if (mode == Mode.OFFICIAL) throw cancellation else emptyList<ManagedResource>() to null

    override suspend fun resourceList(
        apiName: String,
        methods: List<String>,
        vararg roots: String,
    ): List<ManagedResource> = when {
        mode == Mode.OPTIONAL && apiName == "host" -> throw cancellation
        else -> emptyList()
    }

    override suspend fun firstSuccessful(apiName: String, methods: List<String>): JsonObject =
        throw cancellation

    override fun genericResources(data: JsonObject, vararg roots: String): List<ManagedResource> = emptyList()

    override suspend fun logs(): List<LogEntry> = throw cancellation

    override suspend fun taskCenter(): Pair<List<VirtualMachineTask>, VirtualMachineTaskCenterState> =
        emptyList<VirtualMachineTask>() to VirtualMachineTaskCenterState.CAPABILITY_UNAVAILABLE
}
