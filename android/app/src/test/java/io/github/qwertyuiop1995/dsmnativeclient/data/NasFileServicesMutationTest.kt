package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasServiceProtocolFixture
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 原文件服务契约与失败断言直接覆盖正式分组执行器。 */
class NasFileServicesMutationTest {
    private class Context(val fixture: NasServiceProtocolFixture, val repo: DsmRepository, val original: NasServiceValue.Files) {
        val backend get() = fixture.backend
        val desired get() = original.settings.copy(isSmbEnabled = true, isFtpEnabled = true, ftpPort = 2121)
        suspend fun save(value: NasFileServiceSettings = desired) = repo.nasServices.save(repo.nasServices.plan(original, NasServiceValue.Files(value))) { }
    }
    private suspend fun context(legacyFileVersions: Boolean = false): Context {
        val fixture = NasServiceProtocolFixture().also { it.requestFormat = "FORM"
            it.backend.rows[NasServiceStep.FTP] = NasServiceSettingsFixture.row("""{"enable_ftp":false,"enable_ftps":false,"portnum":21}""")
            it.backend.rows[NasServiceStep.SFTP] = NasServiceSettingsFixture.row("""{"enable":false,"portnum":22}""")
        }
        if (legacyFileVersions) { fixture.backend.versions[NasServiceStep.SMB] = 1..1; fixture.backend.versions[NasServiceStep.NFS] = 1..1 }
        val repo = fixture.repository(); val original = repo.nasServices.load(NasServiceKind.FILES) as NasServiceValue.Files
        fixture.requests.clear(); fixture.backend.requests.clear()
        return Context(fixture, repo, original)
    }
    @Test fun `文件服务六组契约均使用固定参数与版本`() = runBlocking {
        val ctx = context(legacyFileVersions = true); val result = ctx.save(NasFileServiceSettings(true, true, true, true, 2121, true, 2222, true, false, true))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(6, result.counts.succeeded)
        val writes = ctx.fixture.requests.filter { it.body?.isOneShot() == true }
        assertEquals(6, writes.size)
        listOf("file-services/set-smb/synthetic-settings/request.json", "file-services/set-nfs/synthetic-settings/request.json",
            "file-services/set-ftp/synthetic-settings/request.json", "file-services/set-sftp/synthetic-settings/request.json",
            "file-services/set-web-discovery/synthetic-settings/request.json", "file-services/set-time-machine/synthetic-settings/request.json")
            .forEachIndexed { index, fixture -> RequestFixtureAssertions.assertRequest(writes[index], fixture) }
        assertEquals(listOf(1, 1, 1, 1, 2, 1), ctx.backend.writes.map { it.version })
        assertEquals(JsonPrimitive(true), ctx.backend.writes[2].fields["enable_ftps"])
        assertEquals(JsonPrimitive(2222), ctx.backend.writes[3].fields["portnum"])
        assertEquals(JsonPrimitive(false), ctx.backend.writes[4].fields["enable_avahi"])
    }
    @Test fun `文件服务只提交变化API组并逐项及最终整体回读`() = runBlocking {
        val ctx = context(); val result = ctx.save()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf(NasServiceStep.SMB, NasServiceStep.FTP), ctx.backend.writes.map { it.step })
        assertEquals(JsonPrimitive(2121), ctx.backend.writes[1].fields["portnum"])
        assertEquals(listOf(3, 1), ctx.backend.writes.map { it.version })
        assertEquals(30, ctx.backend.requests.count { !it.write })
        assertEquals(listOf(NasServiceStep.SMB, NasServiceStep.NFS, NasServiceStep.FTP, NasServiceStep.SFTP, NasServiceStep.WEB_DISCOVERY, NasServiceStep.TIME_MACHINE), ctx.backend.requests.takeLast(6).map { it.step })
    }
    @Test fun `文件服务后续能力缺失时计划预检零请求`() = runBlocking {
        val ctx = context(); ctx.backend.versions[NasServiceStep.SFTP] = 2..2
        val repo = ctx.fixture.repository()
        rejected(DsmErrorKind.FEATURE_UNSUPPORTED) { repo.nasServices.plan(ctx.original, NasServiceValue.Files(ctx.desired.copy(isSftpEnabled = true, sftpPort = 2222))) }
        assertTrue(ctx.fixture.requests.isEmpty())
    }
    @Test fun `文件服务前序生效后后续失败返回部分成功且不重放`() = runBlocking {
        val ctx = context(); ctx.backend.before = { if (it.write && it.step == NasServiceStep.FTP) throw IOException("synthetic FTP disconnect") }
        val result = ctx.save()
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(MutationResultCounts(1, 0, 1), result.counts)
        assertEquals(listOf(NasServiceStep.SMB, NasServiceStep.FTP), ctx.backend.writes.map { it.step })
    }
    @Test fun `文件服务提交与回读均断线仅已发组保持未知`() = runBlocking {
        val ctx = context(); ctx.backend.before = { if (it.write || ctx.backend.writes.isNotEmpty()) throw IOException("synthetic disconnect") }
        val stages = mutableListOf<NasServiceCheckpoint>()
        val result = ctx.repo.nasServices.save(ctx.repo.nasServices.plan(ctx.original, NasServiceValue.Files(ctx.desired))) { stages += it }
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status); assertTrue(result.requiresRefresh)
        assertEquals(MutationResultCounts(0, 1, 1), result.counts)
        assertEquals(listOf(NasServiceCheckpoint(NasServiceStep.SMB, NasServiceStage.SUBMITTED), NasServiceCheckpoint(NasServiceStep.FTP, NasServiceStage.CANCELLED)), stages)
        assertEquals(1, ctx.backend.writes.size)
    }
    @Test fun `文件服务写请求在途取消停止后续写入和自动回读`() = runBlocking {
        val ctx = context(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
        ctx.backend.before = { if (it.write) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        var result: MutationResult? = null
        val job = launch(Dispatchers.Default) { result = ctx.save(ctx.original.settings.copy(isSmbEnabled = true)) }
        assertTrue(entered.await(5, TimeUnit.SECONDS)); job.cancel(); release.countDown(); job.join()
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, result?.status)
        assertTrue(result?.submitted == true); assertTrue(result?.requiresRefresh == true)
        assertEquals(1, ctx.backend.writes.size); assertTrue(ctx.backend.requests.last().write)
    }
    @Test fun `文件服务提交权限失败保留已提交语义与权限类别`() = runBlocking {
        val ctx = context(); ctx.fixture.writeRejectionCode = 105
        val result = ctx.save()
        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status); assertTrue(result.submitted)
        assertFalse(result.requiresRefresh); assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertEquals(MutationResultCounts(0, 2, 0), result.counts); assertEquals(1, ctx.backend.writes.size)
    }
    @Test fun `文件服务写入接受但回读不匹配不报告成功且停止后组`() = runBlocking {
        val ctx = context(); val old = ctx.backend.rows.getValue(NasServiceStep.SMB)
        ctx.backend.afterWrite = { ctx.backend.rows[it.step] = old }
        val result = ctx.save()
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.submitted); assertTrue(result.requiresRefresh); assertEquals(MutationResultCounts(0, 1, 1), result.counts)
        assertEquals(listOf(NasServiceStep.SMB), ctx.backend.writes.map { it.step })
    }
    @Test fun `文件服务无变化返回冲突且零请求`() = runBlocking {
        val ctx = context(); rejected(DsmErrorKind.NAS_SERVICE_CHANGED) { ctx.save(ctx.original.settings) }
        assertTrue(ctx.fixture.requests.isEmpty())
    }
    @Test fun `文件服务冲突端口与TimeMachine依赖在请求前拒绝`() = runBlocking {
        val ctx = context()
        for (value in listOf(ctx.original.settings.copy(isFtpEnabled = true, isSftpEnabled = true, ftpPort = 22, sftpPort = 22),
            ctx.original.settings.copy(isSmbEnabled = false, isSmbTimeMachineEnabled = true))) {
            rejected(DsmErrorKind.NAS_SERVICE_INVALID) { ctx.save(value) }; assertTrue(ctx.fixture.requests.isEmpty())
        }
    }
    private suspend fun rejected(kind: DsmErrorKind, action: suspend () -> Unit) {
        val error = try { action(); error("Expected rejection") } catch (failure: DsmFailure) { failure }; assertEquals(kind, error.kind)
    }
}
