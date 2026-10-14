package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasRemoteAccessRecoveryTest {
    private suspend fun NasServiceSettingsFixture.original() = repository.load(NasServiceKind.REMOTE_ACCESS) as NasServiceValue.RemoteAccess
    @Test fun `两组固定版本单次写入和完整原值检查`() = runBlocking {
        val f = NasServiceSettingsFixture(); val original = f.original(); val events = mutableListOf<NasServiceCheckpoint>()
        val desired = original.copy(settings = original.settings.copy(isRelayEnabled = false, isRouterConfigurationEnabled = true))
        val result = f.repository.save(f.repository.plan(original, desired)) { events += it }
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals("remoteAccessSettingsUpdate", result.operation)
        assertEquals(listOf(3, 1), f.writes.map { it.version }); assertEquals(listOf("set_misc_config", "set"), f.writes.map { it.method })
        assertEquals(mapOf("relay_enabled" to JsonPrimitive(false)), f.writes[0].fields)
        assertEquals(mapOf("enabled" to JsonPrimitive(true)), f.writes[1].fields); assertEquals(6, events.size)
    }
    @Test fun `局部读取失败可编辑已知项但认证证书和双失败不降级`() = runBlocking {
        val f = NasServiceSettingsFixture(); f.before = { if (it.step == NasServiceStep.RELAY) throw IOException("Synthetic offline") }
        val original = f.original(); assertNull(original.settings.isRelayEnabled); assertEquals(false, original.settings.isRouterConfigurationEnabled)
        val result = f.repository.save(f.repository.plan(original, original.copy(settings = original.settings.copy(isRouterConfigurationEnabled = true)))) {}
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(listOf(NasServiceStep.ROUTER), f.writes.map { it.step })
        for (kind in listOf(DsmErrorKind.TLS_UNTRUSTED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.WORKSPACE_CHANGED)) {
            val g = NasServiceSettingsFixture(); g.before = { throw DsmFailure(null, "Synthetic failure", "", kind = kind) }
            try { g.original(); fail() } catch (error: DsmFailure) { assertEquals(kind, error.kind) }
            assertEquals(1, g.requests.size)
        }
        val h = NasServiceSettingsFixture(); h.before = { throw IOException("Synthetic offline") }
        try { h.original(); fail() } catch (_: IOException) {}
    }
    @Test fun `字符串布尔未知不猜值也不能在草稿补出能力`() = runBlocking {
        val f = NasServiceSettingsFixture(); f.rows[NasServiceStep.RELAY] = NasServiceSettingsFixture.row("""{"relay_enabled":"false"}""")
        val original = f.original(); assertNull(original.settings.isRelayEnabled)
        try { f.repository.plan(original, original.copy(settings = original.settings.copy(isRelayEnabled = true))); fail() } catch (_: DsmFailure) {}
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `可信中继保护不接受伪造草稿但可改路由器`() = runBlocking {
        val f = NasServiceSettingsFixture(); f.trustedRelay = true; val original = f.original()
        try { f.repository.plan(original, original.copy(settings = original.settings.copy(isRelayEnabled = false))); fail() }
        catch (e: DsmFailure) { assertEquals(DsmErrorKind.NAS_RELAY_PROTECTED, e.kind) }
        try { f.repository.plan(original, original.copy(settings = original.settings.copy(isRelayEnabled = false, isConnectedThroughTrustedRelay = false))); fail() } catch (_: DsmFailure) {}
        val result = f.repository.save(f.repository.plan(original, original.copy(settings = original.settings.copy(isRouterConfigurationEnabled = true)))) {}
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(NasServiceStep.ROUTER, f.writes.single().step)
    }
    @Test fun `提交时上下文变化仍保护中继已登记环境和原配置`() = runBlocking {
        for (change in 0..2) {
            val f = NasServiceSettingsFixture(); val original = f.original()
            val plan = f.repository.plan(original, original.copy(settings = original.settings.copy(isRelayEnabled = false)))
            when (change) { 0 -> f.trustedRelay = true; 1 -> f.remoteManageable = false; else -> f.rows[NasServiceStep.ROUTER] = NasServiceSettingsFixture.row("""{"enabled":true}""") }
            val result = f.repository.save(plan) {}; assertFalse(result.submitted); assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `丢回执不继续第二组拒绝不按后来同值追认`() = runBlocking {
        for (denied in listOf(false, true)) {
            val f = NasServiceSettingsFixture(); val original = f.original()
            f.afterWrite = { if (denied) throw DsmFailure(105, "Synthetic permission", "", kind = DsmErrorKind.PERMISSION_DENIED) else throw IOException("Synthetic lost receipt") }
            val result = f.repository.save(f.repository.plan(original, original.copy(settings = original.settings.copy(isRelayEnabled = false, isRouterConfigurationEnabled = true)))) {}
            assertEquals(1, f.writes.size); assertEquals(if (denied) 0 else 1, result.counts.succeeded)
            assertEquals(if (denied) MutationResultStatus.PERMISSION_DENIED else MutationResultStatus.PARTIAL_SUCCESS, result.status)
        }
    }
    @Test fun `每步权限撤销和原值变化停止后续且最终读回不保留旧成功`() = runBlocking {
        val f = NasServiceSettingsFixture(); val original = f.original(); var access = 0
        f.access = { if (++access == 2) throw DsmFailure(105, "Synthetic permission", "", kind = DsmErrorKind.PERMISSION_DENIED) }
        val desired = original.copy(settings = original.settings.copy(isRelayEnabled = false, isRouterConfigurationEnabled = true))
        val result = f.repository.save(f.repository.plan(original, desired)) {}
        assertEquals(1, f.writes.size); assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        val g = NasServiceSettingsFixture(); val before = g.original()
        g.afterWrite = { if (it.step == NasServiceStep.ROUTER) g.rows[NasServiceStep.RELAY] = NasServiceSettingsFixture.row("""{"relay_enabled":true}""") }
        val drift = g.repository.save(g.repository.plan(before, desired)) {}
        assertEquals(1, drift.counts.succeeded); assertEquals(1, drift.counts.unknown)
    }
}
