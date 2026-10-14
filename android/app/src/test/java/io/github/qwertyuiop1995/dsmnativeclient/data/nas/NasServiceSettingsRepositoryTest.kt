package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasServiceSettingsRepositoryTest {
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) {} }
    @Test fun `六组全部保存固定版本单次写及最终读取`() = runBlocking {
        val f = NasServiceSettingsFixture(); val original = f.repository.load(NasServiceKind.FILES) as NasServiceValue.Files
        val desired = original.copy(settings = original.settings.copy(isSmbEnabled = true, isNfsEnabled = true, isFtpEnabled = true,
            isFtpsEnabled = true, isSftpEnabled = true, isSsdpEnabled = true, isSmbTimeMachineEnabled = true))
        val events = mutableListOf<NasServiceCheckpoint>()
        val result = f.repository.save(f.repository.plan(original, desired)) { events += it }
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(6, result.counts.succeeded)
        assertEquals(listOf(3, 3, 1, 1, 2, 1), f.writes.map { it.version }); assertEquals(18, events.size)
        assertTrue(f.writes.all { it.write && it.method == "set" }); assertEquals(desired, f.repository.load(NasServiceKind.FILES))
    }
    @Test fun `服务顺序保持依赖且拒绝在用端口直接互换`() = runBlocking {
        val f = NasServiceSettingsFixture(); f.rows[NasServiceStep.SMB] = NasServiceSettingsFixture.row("""{"enable_samba":true}""")
        f.rows[NasServiceStep.TIME_MACHINE] = NasServiceSettingsFixture.row("""{"enable_smb_time_machine":true}""")
        val original = f.repository.load(NasServiceKind.FILES) as NasServiceValue.Files
        val plan = f.repository.plan(original, original.copy(settings = original.settings.copy(isSmbEnabled = false, isSmbTimeMachineEnabled = false)))
        assertEquals(listOf(NasServiceStep.TIME_MACHINE, NasServiceStep.SMB), plan.steps)
        val enabled = original.copy(settings = original.settings.copy(isFtpEnabled = true, isSftpEnabled = true))
        rejected { f.repository.plan(enabled, enabled.copy(settings = enabled.settings.copy(ftpPort = 2222, sftpPort = 2121))) }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `原值或缺失字段变化均零提交`() = runBlocking {
        val f = NasServiceSettingsFixture(); val original = f.repository.load(NasServiceKind.TERMINAL) as NasServiceValue.Terminal
        val desired = original.copy(settings = original.settings.copy(isSshEnabled = true))
        f.rows[NasServiceStep.TERMINAL] = NasServiceSettingsFixture.row("""{"enable_ssh":false,"enable_telnet":true,"ssh_port":22}""")
        val result = f.repository.save(f.repository.plan(original, desired)) {}
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory); assertFalse(result.submitted)
        rejected { f.repository.plan(original.copy(settings = original.settings.copy(sshPort = null)), desired) }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `写前记录失败不发请求接受记录失败不继续后组`() = runBlocking {
        val f = NasServiceSettingsFixture(); val original = f.repository.load(NasServiceKind.FILES) as NasServiceValue.Files
        val plan = f.repository.plan(original, original.copy(settings = original.settings.copy(isSmbEnabled = true, isNfsEnabled = true)))
        try { f.repository.save(plan) { throw IOException("Synthetic storage") }; fail() } catch (_: IOException) {}
        assertTrue(f.writes.isEmpty())
        try { f.repository.save(plan) { if (it.stage == NasServiceStage.ACCEPTED) throw IOException("Synthetic storage") }; fail() } catch (_: IOException) {}
        assertEquals(listOf(NasServiceStep.SMB), f.writes.map { it.step })
    }
    @Test fun `回执丢失后目标相同仍不补交后组`() = runBlocking {
        val f = NasServiceSettingsFixture(); val original = f.repository.load(NasServiceKind.FILES) as NasServiceValue.Files
        f.afterWrite = { throw IOException("Synthetic lost receipt") }
        val events = mutableListOf<NasServiceCheckpoint>()
        val result = f.repository.save(f.repository.plan(original, original.copy(settings = original.settings.copy(isSmbEnabled = true, isNfsEnabled = true)))) { events += it }
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(1, result.counts.succeeded); assertEquals(1, result.counts.failed)
        assertEquals(1, f.writes.size); assertEquals(NasServiceStage.CANCELLED, events.last { it.step == NasServiceStep.NFS }.stage)
    }
    @Test fun `明确拒绝不能被巧合相同配置覆盖`() = runBlocking {
        val f = NasServiceSettingsFixture(); val original = f.repository.load(NasServiceKind.TERMINAL) as NasServiceValue.Terminal
        f.afterWrite = { throw DsmFailure(105, "Synthetic permission", "", kind = DsmErrorKind.PERMISSION_DENIED) }
        val result = f.repository.save(f.repository.plan(original, original.copy(settings = original.settings.copy(isSshEnabled = true)))) {}
        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status); assertEquals(0, result.counts.succeeded); assertEquals(1, result.counts.failed)
    }
    @Test fun `每组重查权限且最终读取能发现先前组变化`() = runBlocking {
        val f = NasServiceSettingsFixture(); val original = f.repository.load(NasServiceKind.FILES) as NasServiceValue.Files
        val plan = f.repository.plan(original, original.copy(settings = original.settings.copy(isSmbEnabled = true, isNfsEnabled = true)))
        var access = 0; f.access = { if (++access == 2) throw DsmFailure(105, "Synthetic permission", "", kind = DsmErrorKind.PERMISSION_DENIED) }
        val result = f.repository.save(plan) {}; assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(1, f.writes.size)
        val g = NasServiceSettingsFixture(); val start = g.repository.load(NasServiceKind.FILES) as NasServiceValue.Files
        g.afterWrite = { if (it.step == NasServiceStep.NFS) g.rows[NasServiceStep.SMB] = NasServiceSettingsFixture.row("""{"enable_samba":false}""") }
        val end = g.repository.save(g.repository.plan(start, start.copy(settings = start.settings.copy(isSmbEnabled = true, isNfsEnabled = true)))) {}
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, end.status); assertEquals(1, end.counts.unknown)
    }
    @Test fun `停用代理仅发送开关但编辑原值包含保留地址`() = runBlocking {
        val f = NasServiceSettingsFixture(); f.rows[NasServiceStep.PROXY] = NasServiceSettingsFixture.row("""{"enable":true,"http_host":"private.example.invalid","http_port":3128}""")
        val original = f.repository.load(NasServiceKind.PROXY) as NasServiceValue.Proxy
        val desired = original.copy(settings = original.settings.copy(isEnabled = false, host = "ignored.example.invalid", port = 1234))
        val result = f.repository.save(f.repository.plan(original, desired)) {}
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(setOf("enable"), f.writes.single().fields.keys)
        val inactive = f.repository.load(NasServiceKind.PROXY) as NasServiceValue.Proxy
        f.rows[NasServiceStep.PROXY] = JsonObject(f.rows.getValue(NasServiceStep.PROXY) + ("http_host" to JsonPrimitive("changed.example.invalid")))
        val conflict = f.repository.save(f.repository.plan(inactive, inactive.copy(settings = inactive.settings.copy(isEnabled = true)))) {}
        assertFalse(conflict.submitted); assertEquals(MutationErrorCategory.CONFLICT, conflict.errorCategory)
    }
    @Test fun `读到未知开关和非整数端口不能变成可保存默认值`() = runBlocking {
        for (raw in listOf("""{"enable_ssh":"unknown","enable_telnet":false}""", """{"enable_ssh":false,"enable_telnet":false,"ssh_port":22.5}""")) {
            val f = NasServiceSettingsFixture(); f.rows[NasServiceStep.TERMINAL] = NasServiceSettingsFixture.row(raw)
            try { f.repository.load(NasServiceKind.TERMINAL); fail() } catch (e: DsmFailure) { assertEquals(DsmErrorKind.INVALID_RESPONSE, e.kind) }
        }
    }
    @Test fun `无效启用代理字段整体失败不保存不认领部分成功`() = runBlocking {
        val f = NasServiceSettingsFixture()
        for (raw in listOf("""{"enable":false,"http_host":"","http_port":0}""", """{"enable":true,"http_host":"","http_port":3128}""")) {
            f.rows[NasServiceStep.PROXY] = NasServiceSettingsFixture.row(raw)
            try { f.repository.load(NasServiceKind.PROXY); fail() } catch (e: DsmFailure) { assertEquals(DsmErrorKind.INVALID_RESPONSE, e.kind) }
        }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `提交断线和取消都保留未知而未提交后组不会算成功`() = runBlocking {
        for (cancel in listOf(false, true)) {
            val f = NasServiceSettingsFixture(); val original = f.repository.load(NasServiceKind.FILES) as NasServiceValue.Files
            f.before = { if (it.write) { if (cancel) throw CancellationException("Synthetic cancellation") else throw IOException("Synthetic disconnect") } }
            val result = f.repository.save(f.repository.plan(original, original.copy(settings = original.settings.copy(isSmbEnabled = true, isNfsEnabled = true)))) {}
            assertEquals(if (cancel) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
            assertEquals(1, result.counts.unknown); assertEquals(1, result.counts.failed); assertEquals(1, f.writes.size)
        }
    }
}
