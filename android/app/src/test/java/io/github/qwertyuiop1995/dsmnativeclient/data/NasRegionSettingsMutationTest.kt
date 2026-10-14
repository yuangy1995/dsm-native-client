package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasRegionProtocolFixture
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.FormBody
import org.junit.Assert.*
import org.junit.Test

/** 原区域设置断言迁到正式配置/校时执行器；计数对应实际副作用，不再按字段推测成功。 */
class NasRegionSettingsMutationTest {
    private data class Context(val fixture: NasRegionProtocolFixture, val repo: DsmRepository, val original: NasRegionSettings) {
        val backend get() = fixture.backend
        suspend fun save(desired: NasRegionSettings = desired(original)) = repo.nasRegion.save(repo.nasRegion.plan(original, desired)) { }
    }
    private suspend fun context(): Context {
        val fixture = NasRegionProtocolFixture().also {
            it.requestFormat = "FORM"; it.backend.field("timezone", JsonPrimitive("Asia/Shanghai"))
        }
        val repo = fixture.repository(); val original = repo.nasRegion.load()
        fixture.requests.clear(); fixture.backend.requests.clear()
        return Context(fixture, repo, original)
    }
    @Test fun `区域设置按固定版本保存回读并在确认后校时`() = runBlocking {
        val ctx = context(); val result = ctx.save()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(MutationResultCounts(2, 0, 0), result.counts)
        assertEquals(listOf("get", "listzone", "set", "get", "listzone", "get", "listzone", "sync", "get", "listzone", "get", "listzone"), ctx.backend.requests.map { it.method })
        assertEquals(listOf(3, 1, 3, 3, 1, 3, 1, 2, 3, 1, 3, 1), ctx.backend.requests.map { it.version })
        val writes = ctx.fixture.requests.filter { it.body?.isOneShot() == true }
        RequestFixtureAssertions.assertRequest(writes[0], "region/set-settings/synthetic-settings/request.json")
        RequestFixtureAssertions.assertRequest(writes[1], "region/synchronize-time/synthetic-servers/request.json")
        val set = writes[0].fixtureBody() as FormBody
        val fields = (0 until set.size).associate { set.name(it) to set.value(it) }
        assertEquals("Y/m/d", fields["date_format"]); assertEquals("UTC", fields["timezone"])
        assertEquals("ntp", fields["enable_ntp"]); assertEquals("time.example.invalid", fields["server"])
        assertEquals(JsonArray(listOf(JsonPrimitive("time.example.invalid"))), ctx.backend.writes[1].fields["servers"])
    }
    @Test fun `未编辑手动时间时使用预检刚读取的NAS时间`() = runBlocking {
        val ctx = context(); ctx.backend.field("second", JsonPrimitive(11))
        val result = ctx.save(ctx.original.copy(dateFormat = "Y/m/d", manualDateTime = null))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        val fields = ctx.backend.writes.single().fields
        assertEquals(JsonPrimitive("2026/7/26"), fields["date"])
        assertEquals(JsonPrimitive(18), fields["hour"]); assertEquals(JsonPrimitive(30), fields["minute"])
        assertEquals(JsonPrimitive(11), fields["second"])
        assertFalse(ctx.backend.requests.any { it.method == "sync" })
    }
    @Test fun `区域配置提交超时只改一个字段不算配置完成且不继续校时`() = runBlocking {
        val ctx = context(); val old = ctx.backend.settings
        ctx.backend.afterWrite = {
            ctx.backend.settings = JsonObject(old + ("date_format" to JsonPrimitive("Y/m/d")))
            throw IOException("synthetic region timeout")
        }
        val result = ctx.save()
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationResultCounts(0, 1, 1), result.counts)
        assertEquals(listOf("set"), ctx.backend.writes.map { it.method })
    }
    @Test fun `区域配置确认后校时超时返回部分成功且不重放`() = runBlocking {
        val ctx = context(); ctx.backend.afterWrite = { if (it.method == "sync") throw IOException("synthetic sync timeout") }
        val result = ctx.save()
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(MutationResultCounts(1, 0, 1), result.counts)
        assertEquals(listOf("set", "sync"), ctx.backend.writes.map { it.method })
    }
    @Test fun `区域设置拒绝非法服务器和未返回的时区`() = runBlocking {
        val ctx = context()
        for (value in listOf(desired(ctx.original).copy(timeServers = listOf("https://time.example.invalid/path")),
            desired(ctx.original).copy(timeZone = "Mars/Olympus"))) {
            rejected(DsmErrorKind.NAS_REGION_INVALID) { ctx.save(value) }
            assertTrue(ctx.fixture.requests.isEmpty())
        }
    }
    @Test fun `区域预检拒绝未知自动校时模式且零写请求`() = runBlocking {
        val ctx = context(); ctx.backend.field("enable_ntp", JsonPrimitive("synthetic-unknown"))
        val result = ctx.save()
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted); assertEquals(MutationResultCounts(0, 2, 0), result.counts)
        assertEquals(listOf("get", "listzone"), ctx.backend.requests.map { it.method })
        assertTrue(ctx.backend.writes.isEmpty())
    }
    @Test fun `区域固定版本范围不完整时零请求关闭`() = runBlocking {
        for ((min, max) in listOf(1 to 1, 3 to 3)) {
            val ctx = context(); val repo = ctx.fixture.repository(minVersion = min, maxVersion = max)
            rejected(DsmErrorKind.FEATURE_UNSUPPORTED) { repo.nasRegion.plan(ctx.original, desired(ctx.original)) }
            assertTrue(ctx.fixture.requests.isEmpty())
        }
    }
    @Test fun `区域预检在途取消不会进入配置或校时请求`() = runBlocking {
        val ctx = context(); val result = cancelAt(ctx, "get")
        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, result.status)
        assertFalse(result.submitted); assertFalse(result.requiresRefresh)
        assertEquals(MutationResultCounts(0, 0, 0), result.counts)
        assertEquals(listOf("get"), ctx.backend.requests.map { it.method })
    }
    @Test fun `区域配置写请求在途取消停止回读且绝不继续校时`() = runBlocking {
        val ctx = context(); val result = cancelAt(ctx, "set")
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, result.status)
        assertTrue(result.submitted); assertTrue(result.requiresRefresh)
        assertEquals(MutationResultCounts(0, 1, 1), result.counts)
        assertEquals(listOf("get", "listzone", "set"), ctx.backend.requests.map { it.method })
    }
    @Test fun `区域配置权限失败不读取未知结果且不校时`() = runBlocking {
        val ctx = context(); ctx.fixture.writeRejectionCode = 105
        ctx.backend.before = { if (!it.write && ctx.backend.writes.isNotEmpty()) throw IOException("synthetic readback disconnect") }
        val result = ctx.save()
        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertTrue(result.submitted); assertEquals(MutationResultCounts(0, 2, 0), result.counts)
        assertEquals(listOf("get", "listzone", "set"), ctx.backend.requests.map { it.method })
    }
    @Test fun `区域配置响应未知但回读确认时仍不自动校时`() = runBlocking {
        val ctx = context(); ctx.backend.afterWrite = { throw IOException("synthetic response lost") }
        val stages = mutableListOf<NasRegionCheckpoint>()
        val result = ctx.repo.nasRegion.save(ctx.repo.nasRegion.plan(ctx.original, desired(ctx.original))) { stages += it }
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(MutationResultCounts(1, 1, 0), result.counts)
        assertFalse(stages.any { it.stage == NasServiceStage.ACCEPTED })
        assertEquals(NasRegionCheckpoint(NasRegionStep.SYNCHRONIZATION, NasServiceStage.CANCELLED), stages.last())
        assertEquals(listOf("set"), ctx.backend.writes.map { it.method })
    }
    @Test fun `区域立即校时在途取消只提交一次并保留未知结果`() = runBlocking {
        val ctx = context(); val result = cancelAt(ctx, "sync")
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, result.status)
        assertEquals(MutationResultCounts(1, 0, 1), result.counts)
        assertEquals(listOf("set", "sync"), ctx.backend.writes.map { it.method })
        assertEquals("sync", ctx.backend.requests.last().method)
    }
    @Test fun `区域校时成功但最终读取失败不能沿用旧配置成功证据`() = runBlocking {
        val ctx = context()
        ctx.backend.before = { if (!it.write && ctx.backend.writes.any { r -> r.method == "sync" }) throw IOException("synthetic final read failure") }
        val result = ctx.save()
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationResultCounts(0, 0, 2), result.counts)
        assertEquals(listOf("set", "sync"), ctx.backend.writes.map { it.method })
    }
    @Test fun `区域重复保存被锁拒绝且无变化计划零请求`() = runBlocking {
        val ctx = context(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
        ctx.backend.before = { if (it.method == "set") { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        val first = async(Dispatchers.Default) { ctx.save() }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        rejected(DsmErrorKind.NAS_REGION_CHANGED) { ctx.save() }
        release.countDown(); assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(listOf("set", "sync"), ctx.backend.writes.map { it.method })
        val unchanged = context()
        rejected(DsmErrorKind.NAS_REGION_CHANGED) { unchanged.save(unchanged.original.copy(manualDateTime = null)) }
        assertTrue(unchanged.fixture.requests.isEmpty())
    }
    private suspend fun cancelAt(ctx: Context, method: String): MutationResult = coroutineScope {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        ctx.backend.before = { if (it.method == method) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        var result: MutationResult? = null
        val job = launch(Dispatchers.Default) { result = ctx.save() }
        assertTrue(entered.await(5, TimeUnit.SECONDS)); job.cancel(); release.countDown(); job.join()
        requireNotNull(result)
    }
    private suspend fun rejected(kind: DsmErrorKind, action: suspend () -> Unit) {
        val error = try { action(); error("Expected rejection") } catch (failure: DsmFailure) { failure }
        assertEquals(kind, error.kind)
    }
    companion object {
        private fun desired(original: NasRegionSettings) = original.copy(dateFormat = "Y/m/d", timeZone = "UTC",
            isNetworkTimeEnabled = true, timeServers = listOf("time.example.invalid"), manualDateTime = null)
    }
}
