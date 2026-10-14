package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasSecurityRecoveryRepositoryTest {
    private suspend fun NasServiceProtocolFixture.original() = repository().nasServices.load(NasServiceKind.SECURITY) as NasServiceValue.Security
    private fun NasServiceValue.Security.enableAll() = copy(settings = settings.copy(isAutoBlockEnabled = true,
        dosProtection = settings.dosProtection.map { it.copy(isEnabled = true) }, isFirewallEnabled = true, isPortScanProtectionEnabled = true))
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) {} }
    @Test fun `FORM及JSON四组顺序固定版本原配置档任务完成后单次清理`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            val f = NasServiceProtocolFixture(); f.requestFormat = format
            val repo = f.repository(); val original = f.original(); val desired = original.enableAll()
            val events = mutableListOf<NasServiceCheckpoint>()
            val result = repo.nasServices.save(repo.nasServices.plan(original, desired)) { events += it }
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(4, result.counts.succeeded)
            val writes = f.backend.writes
            assertEquals(listOf("set", "set", "set", "start", "stop"), writes.map { it.method })
            assertEquals(listOf(1, 2, 1, 1, 1), writes.map { it.version })
            assertEquals(setOf("enable", "attempts", "within_mins", "expire_day"), writes.first().fields.keys)
            assertEquals(NasServiceSettingsFixture.row("""{"configs":[{"adapter":"eth0","dos_protect_enable":true}]}"""), JsonObject(writes[1].fields))
            assertEquals(mapOf("name" to JsonPrimitive("synthetic-profile"), "profile_applying" to JsonPrimitive(false)), writes[3].fields)
            assertTrue(writes.last().fields.isEmpty())
            val receipt = events.mapNotNull { it.task }.last()
            assertEquals(true, receipt.outcome); assertTrue(receipt.cleanupAttempted); assertTrue(receipt.cleanupAccepted)
            assertEquals(5, f.requests.count { it.body?.isOneShot() == true })
        }
    }
    @Test fun `关闭防火墙仅专用动作且配置档漂移后零写`() = runBlocking {
        val f = NasServiceProtocolFixture(); f.backend.rows[NasServiceStep.FIREWALL] = NasServiceSettingsFixture.row("""{"enable_firewall":true,"profile_name":"synthetic-profile"}""")
        val repo = f.repository(); val original = f.original(); val desired = original.copy(settings = original.settings.copy(isFirewallEnabled = false))
        val result = repo.nasServices.save(repo.nasServices.plan(original, desired)) {}
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(mapOf("set_type" to JsonPrimitive("disable")), f.backend.writes.single().fields)
        f.backend.rows[NasServiceStep.FIREWALL] = NasServiceSettingsFixture.row("""{"enable_firewall":true,"profile_name":"changed-profile"}""")
        val conflict = repo.nasServices.save(repo.nasServices.plan(original, desired)) {}
        assertFalse(conflict.submitted); assertEquals(MutationErrorCategory.CONFLICT, conflict.errorCategory); assertEquals(1, f.backend.writes.size)
    }
    @Test fun `原任务回执丢失即使开关相同也保持未知且不清理`() = runBlocking {
        for (missing in listOf(true, false)) {
            val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original()
            if (missing) f.backend.taskReceipt = JsonObject(emptyMap())
            f.backend.afterWrite = {
                if (it.method == "start") {
                    f.backend.rows[NasServiceStep.FIREWALL] = NasServiceSettingsFixture.row("""{"enable_firewall":true,"profile_name":"synthetic-profile"}""")
                    if (!missing) throw IOException("Synthetic missing receipt")
                }
            }
            val desired = original.copy(settings = original.settings.copy(isFirewallEnabled = true))
            val result = repo.nasServices.save(repo.nasServices.plan(original, desired)) {}
            assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
            assertEquals(listOf("start"), f.backend.writes.map { it.method })
        }
    }
    @Test fun `轮询失败明确任务失败清理失败和取消均不盲目清理或误报成功`() = runBlocking {
        for (scenario in listOf("status", "failed", "stop", "cancel")) {
            val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original()
            if (scenario == "failed") f.backend.taskStatus = NasServiceSettingsFixture.row("""{"success":false}""")
            f.backend.before = { request ->
                if (request.api == firewallApplyApi && request.method == if (scenario == "stop") "stop" else "status") {
                    when (scenario) { "status", "stop" -> throw IOException("Synthetic interrupted"); "cancel" -> throw CancellationException("Synthetic cancelled") }
                }
            }
            val events = mutableListOf<NasServiceCheckpoint>()
            val desired = original.copy(settings = original.settings.copy(isFirewallEnabled = true))
            val service = if (scenario == "cancel") NasServiceSettingsRepository(f.backend, { _, _ -> true }, securityReader = { repo.securitySettings() }) else repo.nasServices
            val result = service.save(service.plan(original, desired)) { events += it }
            assertNotEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
            assertEquals(if (scenario == "failed") MutationResultStatus.CONFIRMED_FAILURE else if (scenario == "cancel") MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
            assertEquals(if (scenario in setOf("stop", "failed")) 1 else 0, f.backend.writes.count { it.method == "stop" })
            assertEquals(1, f.backend.writes.count { it.method == "start" })
            if (scenario == "stop") assertTrue(events.mapNotNull { it.task }.last().cleanupAttempted)
        }
    }
    @Test fun `未结束任务只轮询三十次且超时不清理`() = runBlocking {
        val f = NasServiceProtocolFixture(); val root = f.repository(); val original = f.original()
        f.backend.taskStatus = JsonObject(emptyMap())
        val repo = NasServiceSettingsRepository(f.backend, { _, _ -> true }, securityReader = { root.securitySettings() }, taskDelay = {})
        val desired = original.copy(settings = original.settings.copy(isFirewallEnabled = true))
        val result = repo.save(repo.plan(original, desired)) {}
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(30, f.backend.requests.count { it.method == "status" }); assertEquals(listOf("start"), f.backend.writes.map { it.method })
    }
    @Test fun `后返回DoS状态覆盖旧值且缺失必需值不填默认`() = runBlocking {
        val f = NasServiceProtocolFixture()
        f.backend.rows[NasServiceStep.DOS] = NasServiceSettingsFixture.row("""{"configs":[{"adapter":"eth0","dos_protect_enable":false},{"adapter":"eth0","dos_protect_enable":true}]}""")
        assertTrue(f.original().settings.dosProtection.single().isEnabled)
        for (row in listOf("""{"enable":true,"attempts":5,"within_mins":10}""", """{"enable":true,"attempts":5.5,"within_mins":10,"expire_day":0}""", """{"enable":true,"attempts":0,"within_mins":10,"expire_day":0}""")) {
            f.backend.rows[NasServiceStep.AUTO_BLOCK] = NasServiceSettingsFixture.row(row)
            try { f.original(); fail() } catch (e: DsmFailure) { assertEquals(DsmErrorKind.INVALID_RESPONSE, e.kind) }
        }
        assertTrue(f.backend.writes.isEmpty())
    }
    @Test fun `防火墙任务或DoS版本不足输入改换配置档网卡均零写`() = runBlocking {
        val f = NasServiceProtocolFixture(); val original = f.original()
        f.backend.applySupported = false; var repo = f.repository()
        rejected { repo.nasServices.plan(original, original.enableAll()) }
        f.backend.applySupported = true; f.backend.versions[NasServiceStep.DOS] = 1..1; repo = f.repository()
        rejected { repo.nasServices.plan(original, original.enableAll()) }
        f.backend.versions[NasServiceStep.DOS] = 1..2; repo = f.repository()
        for (settings in listOf(original.settings.copy(firewallProfileName = "forged"), original.settings.copy(dosProtection = emptyList()), original.settings.copy(failedAttempts = 0))) {
            rejected { repo.nasServices.plan(original, NasServiceValue.Security(settings)) }
        }
        assertTrue(f.backend.writes.isEmpty())
    }
    @Test fun `中途明确拒绝不能被读到相同设置认领且后组不自动发送`() = runBlocking {
        val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original()
        f.backend.afterWrite = { if (it.step == NasServiceStep.DOS) f.writeRejectionCode = 105 }
        val result = repo.nasServices.save(repo.nasServices.plan(original, original.enableAll())) {}
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(1, result.counts.succeeded)
        assertEquals(listOf(NasServiceStep.AUTO_BLOCK, NasServiceStep.DOS), f.backend.writes.map { it.step })
    }
    @Test fun `每组提交前再比对整体基线且写回执丢失后不接着发送后组`() = runBlocking {
        for (drift in listOf(true, false)) {
            val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original()
            f.backend.afterWrite = {
                if (drift) f.backend.rows[NasServiceStep.FIREWALL] = NasServiceSettingsFixture.row("""{"enable_firewall":false,"profile_name":"changed-profile"}""")
                else throw IOException("Synthetic lost acknowledgement")
            }
            val result = repo.nasServices.save(repo.nasServices.plan(original, original.enableAll())) {}
            assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(1, result.counts.succeeded); assertEquals(1, f.backend.writes.size)
        }
    }
    @Test fun `已开启任务的回执落盘失败立即停止读取和清理`() = runBlocking {
        val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original()
        val desired = original.copy(settings = original.settings.copy(isFirewallEnabled = true))
        try {
            repo.nasServices.save(repo.nasServices.plan(original, desired)) { event ->
                if (event.task != null) throw DsmFailure(null, "Synthetic storage failure", "", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
            }; fail()
        } catch (error: DsmFailure) { assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, error.kind) }
        assertEquals("start", f.backend.requests.last().method)
        assertEquals(listOf("start"), f.backend.writes.map { it.method })
    }
    @Test fun `不同DSM可保存但旧账号和首个检查点失败不发送设置`() = runBlocking {
        val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original(); val plan = repo.nasServices.plan(original, original.enableAll())
        f.knownEnvironment = true; f.ownerValid = false; assertFalse(repo.nasServices.save(plan) {}.submitted)
        f.ownerValid = true
        try { repo.nasServices.save(plan) { throw DsmFailure(null, "Synthetic storage failure", "", kind = DsmErrorKind.LOCAL_STORAGE_FAILED) }; fail() } catch (_: DsmFailure) {}
        assertTrue(f.backend.writes.isEmpty())
        val unknown = NasServiceProtocolFixture(); unknown.knownEnvironment = false
        val available = unknown.repository().nasServices; val before = unknown.original()
        assertTrue(available.save(available.plan(before, before.enableAll())) {}.submitted)
        assertTrue(unknown.backend.writes.isNotEmpty())
    }
}
