package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.DdnsMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasDdnsRecoveryRepositoryTest {
    private fun NasDdnsRecord.draft() = NasDdnsDraft(originalProviderId = providerId, providerId = providerId, hostname = hostname, username = username,
        heartbeat = heartbeat, isEnabled = isEnabled, networkType = networkType, ipv4 = ipv4, ipv6 = ipv6, interfaceV4 = interfaceV4, interfaceV6 = interfaceV6)
    @Test fun `FORM与JSON四类动作独立仅一次传输且测试不保存`() = runBlocking {
        for (format in listOf("FORM", "JSON")) for (operation in DdnsMutationOperation.entries) {
            val f = NasDdnsProtocolFixture(); f.format = format
            if (operation in setOf(DdnsMutationOperation.DELETE, DdnsMutationOperation.ADDRESS_REFRESH)) f.saved()
            val repo = f.repository().nasDdns; val original = repo.load()
            val plan = repo.plan(operation, original, if (operation in setOf(DdnsMutationOperation.TEST, DdnsMutationOperation.SAVE)) f.draft() else null,
                original.records.singleOrNull().takeIf { operation == DdnsMutationOperation.DELETE })
            val events = mutableListOf<NasServiceStage>(); val outcome = repo.perform(plan) { events += it.stage }
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, outcome.result.status)
            val call = f.writes.single(); assertEquals(1, call.version)
            assertEquals(when (operation) { DdnsMutationOperation.TEST -> "test"; DdnsMutationOperation.SAVE -> "create"; DdnsMutationOperation.DELETE -> "delete"; DdnsMutationOperation.ADDRESS_REFRESH -> "update_ip_address" }, call.method)
            assertEquals(listOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED, NasServiceStage.VERIFIED), events)
            if (operation == DdnsMutationOperation.TEST) { assertTrue(f.rows.isEmpty()); assertEquals("test", f.calls.last().method) }
            if (operation == DdnsMutationOperation.DELETE) assertEquals(JsonArray(listOf(JsonPrimitive("Example"))), call.fields["id"])
            if (operation == DdnsMutationOperation.ADDRESS_REFRESH) assertTrue(call.fields.isEmpty())
        }
    }
    @Test fun `编辑五字段最小响应不补网络默认配置也不发送空密码`() = runBlocking {
        val f = NasDdnsProtocolFixture(); f.saved(); val repo = f.repository().nasDdns; val original = repo.load()
        assertTrue(original.records.single().knownNetworkFields.isEmpty())
        val result = repo.perform(repo.plan(DdnsMutationOperation.SAVE, original, original.records.single().draft().copy(heartbeat = true))) {}.result
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(setOf("provider", "hostname", "username", "enable", "heartbeat"), f.writes.single().fields.keys)
    }
    @Test fun `公网地址变化不算配置冲突且使用提交前新地址`() = runBlocking {
        val f = NasDdnsProtocolFixture(); f.saved(); f.fields("net" to JsonPrimitive("auto"), "ip" to JsonPrimitive("192.0.2.10"), "interface_v4" to JsonPrimitive("eth0"))
        val repo = f.repository().nasDdns; val original = repo.load(); f.fields("ip" to JsonPrimitive("192.0.2.11"))
        val result = repo.perform(repo.plan(DdnsMutationOperation.SAVE, original, original.records.single().draft().copy(heartbeat = true))) {}.result
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(JsonPrimitive("192.0.2.11"), f.writes.single().fields["ip"])
        assertFalse(f.writes.single().fields.containsKey("ipv6"))
    }
    @Test fun `原记录或接口配置及服务商集合变化均拒绝旧确认`() = runBlocking {
        for (field in listOf("hostname", "username", "interface_v4", "providers")) {
            val f = NasDdnsProtocolFixture(); f.saved(); val repo = f.repository().nasDdns; val original = repo.load()
            val plan = repo.plan(DdnsMutationOperation.SAVE, original, original.records.single().draft().copy(heartbeat = true))
            when (field) {
                "providers" -> f.providers = JsonArray(f.providers + NasDdnsProtocolFixture.row("""{"id":"Other"}"""))
                "hostname" -> f.fields(field to JsonPrimitive("changed.example.invalid"))
                else -> f.fields(field to JsonPrimitive("changed"))
            }
            val result = repo.perform(plan) {}.result
            assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory); assertFalse(result.submitted); assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `立即更新使用原记录集合而删除使用原记录完整基线`() = runBlocking {
        for (operation in listOf(DdnsMutationOperation.DELETE, DdnsMutationOperation.ADDRESS_REFRESH)) {
            val f = NasDdnsProtocolFixture(); f.saved(); val repo = f.repository().nasDdns; val original = repo.load()
            val plan = repo.plan(operation, original, target = original.records.single().takeIf { operation == DdnsMutationOperation.DELETE })
            if (operation == DdnsMutationOperation.DELETE) f.fields("heartbeat" to JsonPrimitive(true)) else f.rows = JsonArray(emptyList())
            assertFalse(repo.perform(plan) {}.result.submitted); assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `仅改密码无接受回执不能被同值列表认领`() = runBlocking {
        val f = NasDdnsProtocolFixture(); f.saved(); val repo = f.repository().nasDdns; val original = repo.load()
        val plan = repo.plan(DdnsMutationOperation.SAVE, original, original.records.single().draft().copy(password = "synthetic-new-secret"))
        assertTrue(plan.requiresAcceptance); f.afterWrite = { throw IOException("Synthetic lost receipt") }
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, repo.perform(plan) {}.result.status); assertEquals(1, f.writes.size)
    }
    @Test fun `改变公开字段或删除丢失回执可以通过一次严格读取结束`() = runBlocking {
        for (operation in listOf(DdnsMutationOperation.SAVE, DdnsMutationOperation.DELETE)) {
            val f = NasDdnsProtocolFixture(); f.saved(); val repo = f.repository().nasDdns; val original = repo.load()
            val plan = repo.plan(operation, original, original.records.single().draft().copy(heartbeat = true).takeIf { operation == DdnsMutationOperation.SAVE },
                original.records.single().takeIf { operation == DdnsMutationOperation.DELETE })
            f.afterWrite = { throw IOException("Synthetic lost receipt") }; val result = repo.perform(plan) {}.result
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(1, f.writes.size)
            val after = f.calls.dropWhile { !it.oneShot }.drop(1); assertEquals(listOf(DDNS_PROVIDER, DDNS_RECORD), after.map { it.api })
        }
    }
    @Test fun `明确拒绝不被相同保存或删除状态覆盖`() = runBlocking {
        for (operation in listOf(DdnsMutationOperation.SAVE, DdnsMutationOperation.DELETE)) {
            val f = NasDdnsProtocolFixture(); f.saved(); val repo = f.repository().nasDdns; val original = repo.load()
            val plan = repo.plan(operation, original, original.records.single().draft().copy(heartbeat = true).takeIf { operation == DdnsMutationOperation.SAVE },
                original.records.single().takeIf { operation == DdnsMutationOperation.DELETE })
            f.reject = 105; val result = repo.perform(plan) {}.result
            assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status); assertTrue(f.calls.last().oneShot)
        }
    }
    @Test fun `测试及立即更新没有回执时读取不能补造成功`() = runBlocking {
        for (operation in listOf(DdnsMutationOperation.TEST, DdnsMutationOperation.ADDRESS_REFRESH)) {
            val f = NasDdnsProtocolFixture(); if (operation == DdnsMutationOperation.ADDRESS_REFRESH) f.saved()
            val repo = f.repository().nasDdns; val original = repo.load()
            val plan = repo.plan(operation, original, f.draft().takeIf { operation == DdnsMutationOperation.TEST })
            f.afterWrite = { throw IOException("Synthetic lost receipt") }
            assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, repo.perform(plan) {}.result.status)
            assertEquals(1, f.writes.size)
        }
    }
    @Test fun `严格管理读取拒绝缺字段重复记录与畸形可选字段`() = runBlocking {
        for (mode in listOf("missing", "duplicate", "optional", "boolean")) {
            val f = NasDdnsProtocolFixture(); f.saved()
            when (mode) {
                "missing" -> f.rows = JsonArray(listOf(JsonObject(f.rows.single().jsonObject - "enable")))
                "duplicate" -> f.rows = JsonArray(f.rows + f.rows.single())
                "optional" -> f.fields("interface_v4" to JsonPrimitive(2))
                else -> f.fields("heartbeat" to JsonPrimitive("unknown"))
            }
            assertEquals(DsmErrorKind.INVALID_RESPONSE, (runCatching { f.repository().nasDdns.load() }.exceptionOrNull() as DsmFailure).kind)
        }
    }
    @Test fun `实际接口版本身份存储检查点与输入失败仍受保护`() = runBlocking {
        val f = NasDdnsProtocolFixture(); val repo = f.repository().nasDdns; val original = repo.load()
        val plan = repo.plan(DdnsMutationOperation.SAVE, original, f.draft())
        assertTrue(runCatching { repo.perform(plan) { throw IOException("Synthetic storage failure") } }.isFailure); assertTrue(f.writes.isEmpty())
        f.knownEnvironment = false; assertTrue(repo.perform(plan) {}.result.submitted); assertEquals(1, f.writes.size)
        f.versions = mapOf(DDNS_PROVIDER to 2, DDNS_RECORD to 1); val calls = f.calls.size
        assertTrue(runCatching { f.repository().nasDdns.load() }.isFailure); assertEquals(calls, f.calls.size)
        assertEquals(DsmErrorKind.NAS_DDNS_INVALID, (runCatching { repo.plan(DdnsMutationOperation.SAVE, original, f.draft().copy(hostname = "bad/name")) }.exceptionOrNull() as DsmFailure).kind)
        assertFalse(f.draft().toString().contains("synthetic-only-secret")); assertFalse(plan.toString().contains("synthetic-only-secret"))
    }
}
