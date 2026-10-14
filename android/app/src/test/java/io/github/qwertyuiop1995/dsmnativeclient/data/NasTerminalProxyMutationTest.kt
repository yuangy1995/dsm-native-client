package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasServiceProtocolFixture
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.FormBody
import org.junit.Assert.*
import org.junit.Test

/** 终端与代理使用当前分组计划和原始检查点；不再借旧字段计数推断设置完成。 */
class NasTerminalProxyMutationTest {
    private class Context(val fixture: NasServiceProtocolFixture, val repo: DsmRepository, val original: NasServiceValue) {
        val backend get() = fixture.backend
        val step get() = if (original is NasServiceValue.Terminal) NasServiceStep.TERMINAL else NasServiceStep.PROXY
        val desired get(): NasServiceValue = when (original) {
            is NasServiceValue.Terminal -> NasServiceValue.Terminal(NasTerminalSettings(true, true, 2222))
            else -> NasServiceValue.Proxy(NasProxySettings(true, " proxy.example.invalid ", 3128))
        }
        suspend fun save(value: NasServiceValue = desired) = repo.nasServices.save(repo.nasServices.plan(original, value)) { }
        val writes get() = fixture.requests.filter { it.body?.isOneShot() == true }
    }
    private suspend fun context(kind: NasServiceKind = NasServiceKind.TERMINAL, legacyVersion: Boolean = false): Context {
        val fixture = NasServiceProtocolFixture().also { it.requestFormat = "FORM" }
        if (legacyVersion) fixture.backend.versions[NasServiceStep.TERMINAL] = 1..1
        val repo = fixture.repository(); val original = repo.nasServices.load(kind)
        fixture.requests.clear(); fixture.backend.requests.clear()
        return Context(fixture, repo, original)
    }
    @Test fun `终端设置提交完整字段并回读确认`() = runBlocking {
        val ctx = context(legacyVersion = true); val result = ctx.save()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(MutationResultCounts(1, 0, 0), result.counts)
        RequestFixtureAssertions.assertRequest(ctx.writes.single(), "terminal/set-settings/synthetic-settings/request.json")
        assertEquals(mapOf("enable_ssh" to JsonPrimitive(true), "enable_telnet" to JsonPrimitive(true), "ssh_port" to JsonPrimitive(2222)), ctx.backend.writes.single().fields)
    }
    @Test fun `终端提交响应丢失后部分字段匹配仍保持整组未知`() = runBlocking {
        val ctx = context(); ctx.backend.afterWrite = {
            ctx.backend.rows[it.step] = terminalPartial(); throw IOException("synthetic terminal disconnect")
        }
        val result = ctx.save(); assertUnknown(result)
        assertEquals(1, ctx.backend.writes.size); assertEquals(terminalPartial(), ctx.backend.rows[ctx.step])
    }
    @Test fun `终端非法端口与无变化均不写入`() = runBlocking {
        val ctx = context()
        rejected(DsmErrorKind.NAS_SERVICE_INVALID) { ctx.save(NasServiceValue.Terminal(NasTerminalSettings(true, false, 0))) }
        rejected(DsmErrorKind.NAS_SERVICE_CHANGED) { ctx.save(ctx.original) }
        assertTrue(ctx.fixture.requests.isEmpty())
    }
    @Test fun `终端权限拒绝不重放且保留拒绝阶段`() = runBlocking { permission(context()) }
    @Test fun `终端预检在途取消不会进入写请求`() = runBlocking { beforeCancel(context()) }
    @Test fun `终端写请求在途取消停止自动回读`() = runBlocking { duringCancel(context()) }
    @Test fun `终端在途取消但部分字段生效仍保留未知`() = runBlocking {
        val ctx = context(); val changed = CountDownLatch(1)
        ctx.backend.afterWrite = { ctx.backend.rows[it.step] = terminalPartial(); changed.countDown() }
        val result = cancelAt(ctx, write = true)
        assertTrue(changed.await(5, TimeUnit.SECONDS))
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, result.status)
        assertEquals(MutationResultCounts(0, 0, 1), result.counts)
        ctx.backend.before = {}
        val actual = ctx.repo.nasServices.load(NasServiceKind.TERMINAL) as NasServiceValue.Terminal
        assertEquals(NasTerminalSettings(true, false, 2222), actual.settings)
        assertEquals(1, ctx.backend.writes.size)
    }
    @Test fun `终端提交成功但回读失败返回未确认且不重放`() = runBlocking {
        val ctx = context(); failReadback(ctx); assertUnknown(ctx.save())
        assertEquals(listOf("get", "set", "get", "get"), ctx.backend.requests.map { it.method })
    }
    @Test fun `终端重复保存被目标锁拒绝且不产生额外写入`() = runBlocking { duplicate(context()) }
    @Test fun `终端无变化和单字段变化只计算实际提交组`() = runBlocking {
        val ctx = context(); rejected(DsmErrorKind.NAS_SERVICE_CHANGED) { ctx.save(ctx.original) }
        assertTrue(ctx.fixture.requests.isEmpty())
        val result = ctx.save(NasServiceValue.Terminal(NasTerminalSettings(true, false, 22)))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(MutationResultCounts(1, 0, 0), result.counts)
        assertEquals(JsonPrimitive(false), ctx.backend.writes.single().fields["enable_telnet"])
        assertEquals(3, ctx.backend.writes.single().version)
    }
    @Test fun `代理启用请求与Fixture字段一致并回读确认`() = runBlocking {
        val ctx = context(NasServiceKind.PROXY); val result = ctx.save()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(MutationResultCounts(1, 0, 0), result.counts)
        assertTrue(result.submitted); assertFalse(result.requiresRefresh)
        RequestFixtureAssertions.assertRequest(ctx.writes.single(), "network/set-proxy/synthetic-settings/request.json")
        assertEquals(listOf(1, 1, 1, 1), ctx.backend.requests.map { it.version })
        assertEquals(listOf("get", "set", "get", "get"), ctx.backend.requests.map { it.method })
    }
    @Test fun `停用代理只提交开关且不比较旧地址`() = runBlocking {
        val ctx = context(NasServiceKind.PROXY)
        val old = (ctx.original as NasServiceValue.Proxy).copy(settings = ctx.original.settings.copy(isEnabled = true))
        ctx.backend.rows[ctx.step] = JsonObject(ctx.backend.rows.getValue(ctx.step) + ("enable" to JsonPrimitive(true)))
        val result = ctx.repo.nasServices.save(ctx.repo.nasServices.plan(old, NasServiceValue.Proxy(NasProxySettings(false, "", null)))) { }
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(1, result.counts.succeeded)
        assertEquals(mapOf("enable" to JsonPrimitive(false)), ctx.backend.writes.single().fields)
        val form = ctx.writes.single().fixtureBody() as FormBody
        assertEquals(setOf("api", "version", "method", "enable", "_sid", "SynoToken"), (0 until form.size).map { form.name(it) }.toSet())
    }
    @Test fun `代理非法地址与端口零请求拒绝`() = runBlocking {
        val ctx = context(NasServiceKind.PROXY)
        for (value in listOf(NasProxySettings(true, "https://proxy.example.invalid/path", 3128), NasProxySettings(true, "proxy.example.invalid", 0))) {
            rejected(DsmErrorKind.NAS_SERVICE_INVALID) { ctx.save(NasServiceValue.Proxy(value)) }; assertTrue(ctx.fixture.requests.isEmpty())
        }
    }
    @Test fun `代理提交断线且回读失败返回未确认不重放`() = runBlocking {
        val ctx = context(NasServiceKind.PROXY); failReadback(ctx)
        ctx.backend.afterWrite = { throw IOException("synthetic proxy submit disconnect") }
        val result = ctx.save(); assertUnknown(result); assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
        assertEquals(1, ctx.backend.writes.size)
    }
    @Test fun `代理固定版本不在能力范围时零请求关闭`() = runBlocking {
        val ctx = context(NasServiceKind.PROXY); ctx.backend.versions[ctx.step] = 2..2
        val repo = ctx.fixture.repository()
        rejected(DsmErrorKind.FEATURE_UNSUPPORTED) { repo.nasServices.plan(ctx.original, ctx.desired) }
        assertTrue(ctx.fixture.requests.isEmpty())
    }
    @Test fun `代理三字段权限拒绝保留整组失败计数`() = runBlocking { permission(context(NasServiceKind.PROXY)) }
    @Test fun `代理预检在途取消不会进入写请求`() = runBlocking { beforeCancel(context(NasServiceKind.PROXY)) }
    @Test fun `代理写请求在途取消停止回读且不重放`() = runBlocking { duringCancel(context(NasServiceKind.PROXY)) }
    @Test fun `代理提交响应丢失后部分生效仍保留整组未知`() = runBlocking {
        val ctx = context(NasServiceKind.PROXY); val old = ctx.backend.rows.getValue(ctx.step)
        ctx.backend.afterWrite = { ctx.backend.rows[it.step] = JsonObject(old + ("enable" to JsonPrimitive(true))); throw IOException("synthetic proxy disconnect") }
        assertUnknown(ctx.save()); assertEquals(1, ctx.backend.writes.size)
        assertEquals(JsonPrimitive("private.example.invalid"), ctx.backend.rows.getValue(ctx.step)["http_host"])
    }
    @Test fun `代理重复保存被目标锁拒绝且不产生额外写入`() = runBlocking { duplicate(context(NasServiceKind.PROXY)) }
    @Test fun `代理停用无变化忽略未提交地址并返回冲突`() = runBlocking {
        val ctx = context(NasServiceKind.PROXY)
        rejected(DsmErrorKind.NAS_SERVICE_CHANGED) { ctx.save(NasServiceValue.Proxy(NasProxySettings(false, "different.example.invalid", 8080))) }
        assertTrue(ctx.fixture.requests.isEmpty())
    }
    private fun terminalPartial() = NasServiceSettingsFixture.row("""{"enable_ssh":true,"enable_telnet":false,"ssh_port":2222}""")
    private fun failReadback(ctx: Context) { ctx.backend.before = { if (!it.write && ctx.backend.writes.isNotEmpty()) throw IOException("synthetic readback failure") } }
    private fun assertUnknown(result: MutationResult) {
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.submitted); assertTrue(result.requiresRefresh); assertEquals(MutationResultCounts(0, 0, 1), result.counts)
    }
    private suspend fun permission(ctx: Context) {
        ctx.fixture.writeRejectionCode = 105; val stages = mutableListOf<NasServiceCheckpoint>()
        val result = ctx.repo.nasServices.save(ctx.repo.nasServices.plan(ctx.original, ctx.desired)) { stages += it }
        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status); assertTrue(result.submitted)
        assertFalse(result.requiresRefresh); assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertEquals(MutationResultCounts(0, 1, 0), result.counts)
        assertEquals(listOf(NasServiceStage.SUBMITTED, NasServiceStage.REJECTED), stages.map { it.stage })
        assertEquals(listOf("get", "set", "get"), ctx.backend.requests.map { it.method })
    }
    private suspend fun beforeCancel(ctx: Context) {
        val result = cancelAt(ctx, false)
        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, result.status)
        assertFalse(result.submitted); assertFalse(result.requiresRefresh); assertEquals(MutationResultCounts(0, 0, 0), result.counts)
        assertEquals(listOf("get"), ctx.backend.requests.map { it.method })
    }
    private suspend fun duringCancel(ctx: Context) {
        val result = cancelAt(ctx, true)
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, result.status)
        assertTrue(result.submitted); assertTrue(result.requiresRefresh); assertEquals(MutationResultCounts(0, 0, 1), result.counts)
        assertEquals(listOf("get", "set"), ctx.backend.requests.map { it.method })
    }
    private suspend fun cancelAt(ctx: Context, write: Boolean): MutationResult = coroutineScope {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        ctx.backend.before = { if (it.write == write) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        var result: MutationResult? = null
        val job = launch(Dispatchers.Default) { result = ctx.save() }
        assertTrue(entered.await(5, TimeUnit.SECONDS)); job.cancel(); release.countDown(); job.join(); requireNotNull(result)
    }
    private suspend fun duplicate(ctx: Context) = coroutineScope {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        ctx.backend.before = { if (it.write) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        val first = async(Dispatchers.Default) { ctx.save() }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        rejected(DsmErrorKind.NAS_SERVICE_CHANGED) { ctx.save() }; release.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status); assertEquals(1, ctx.backend.writes.size)
    }
    private suspend fun rejected(kind: DsmErrorKind, action: suspend () -> Unit) {
        val error = try { action(); error("Expected rejection") } catch (failure: DsmFailure) { failure }; assertEquals(kind, error.kind)
    }
}
