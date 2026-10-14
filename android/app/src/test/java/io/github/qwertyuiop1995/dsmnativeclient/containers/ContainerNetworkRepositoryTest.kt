package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ContainerNetworkRepositoryTest {
    private fun draft() = ContainerNetworkDraft("Synthetic-new", true, "192.0.2.0/24", "192.0.2.128/25", "192.0.2.1", true, "2001:db8::/64", "2001:db8::/80", "2001:db8::1", true)
    @Test fun `自动手动IPv4及IPv6创建参数不发送driver且保留原生布尔`() = runBlocking {
        for (format in listOf("FORM", "JSON")) for (value in listOf(ContainerNetworkDraft("Synthetic-new"), draft())) {
            val fixture = ContainerFixture().apply { this.format = format }; val repo = fixture.repository().containerManagement; val stages = mutableListOf<ContainerStage>()
            repo.createNetwork(value, stages::add); assertEquals(listOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED, ContainerStage.VERIFIED), stages)
            val call = fixture.writes.single(); assertEquals(value.parameters(), call.fields); assertFalse("driver" in call.fields); assertTrue(call.oneShot); assertEquals(1, call.version)
        }
    }
    @Test fun `非法地址族地址池网关名称零请求`() = runBlocking {
        val invalid = listOf(draft().copy(name = "bad name"), draft().copy(subnet = "192.000.2.0/24"), draft().copy(gateway = "198.51.100.1"),
            draft().copy(range = "192.0.2.0/16"), draft().copy(ipv6Gateway = "hostname.invalid"), draft().copy(ipv6Gateway = "2001:db9::1"), draft().copy(ipv6Subnet = "fe80::1%en0/64"))
        for (value in invalid) {
            assertNotNull(value.issue); val fixture = ContainerFixture(); assertTrue(runCatching { fixture.repository().containerManagement.createNetwork(value) {} }.isFailure)
            assertTrue(fixture.calls.isEmpty())
        }
    }
    @Test fun `同名已存在拒绝但未知套件版本允许创建网络`() = runBlocking {
        val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement
        assertTrue(runCatching { repo.createNetwork(ContainerNetworkDraft("Synthetic-network")) {} }.isFailure); assertTrue(fixture.writes.isEmpty())
        fixture.packageVersion = "unknown"; repo.createNetwork(draft()) {}; assertEquals(1, fixture.writes.size)
    }
    @Test fun `网络读取保留关联名称配置且部分目录冲突计数重复身份失败`() = runBlocking {
        val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement
        val value = repo.networkDefinitions().single(); assertEquals("192.0.2.0/24", value.subnet); assertEquals(emptyList<String>(), value.containers)
        for (row in listOf(JsonObject(fixture.networks.single() - "containers"), JsonObject(fixture.networks.single() + ("container_count" to JsonPrimitive(2))),
            JsonObject(fixture.networks.single() + ("containers" to JsonPrimitive(false))))) {
            fixture.networks = listOf(row); assertTrue(runCatching { repo.networkDefinitions() }.isFailure)
        }
        fixture.networks = listOf(ContainerFixture.network()); fixture.networkTotal = 2; assertTrue(runCatching { repo.networkDefinitions() }.isFailure)
        fixture.networkTotal = null; fixture.networks = fixture.networks + fixture.networks; assertTrue(runCatching { repo.networkDefinitions() }.isFailure)
    }
    @Test fun `默认有容器及已变化网络不能删除`() = runBlocking {
        for (row in listOf(ContainerFixture.network(name = "bridge"), ContainerFixture.network(name = "host"), ContainerFixture.network(name = "none"),
            ContainerFixture.network(containers = listOf("Synthetic container")))) {
            val fixture = ContainerFixture().apply { networks = listOf(row) }; val repo = fixture.repository().containerManagement
            assertTrue(runCatching { repo.deleteNetwork(repo.networkDefinitions().single()) {} }.isFailure); assertTrue(fixture.writes.isEmpty())
        }
        val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement; val original = repo.networkDefinitions().single()
        fixture.networks = listOf(ContainerFixture.network(name = "Changed")); assertTrue(runCatching { repo.deleteNetwork(original) {} }.isFailure); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `删除严格按一个网络对象数组空failed再回读原ID`() = runBlocking {
        val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement; val target = repo.networkDefinitions().single(); val stages = mutableListOf<ContainerStage>()
        repo.deleteNetwork(target, stages::add)
        assertEquals(listOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED, ContainerStage.VERIFIED), stages)
        assertEquals(mapOf("networks" to JsonArray(listOf(target.deletion))), fixture.writes.single().fields)
        assertTrue(fixture.writes.single().oneShot); assertTrue(repo.networkDefinitions().isEmpty())
    }
    @Test fun `failed非空明确拒绝畸形failed保留未知`() = runBlocking {
        for (failed in listOf(JsonArray(listOf(JsonPrimitive("synthetic-failure"))), JsonPrimitive(false))) {
            val fixture = ContainerFixture().apply { failedNetworks = failed }; val repo = fixture.repository().containerManagement; val stages = mutableListOf<ContainerStage>()
            assertTrue(runCatching { repo.deleteNetwork(repo.networkDefinitions().single(), stages::add) }.isFailure)
            assertEquals(if (failed is JsonArray) listOf(ContainerStage.SUBMITTED, ContainerStage.REJECTED) else listOf(ContainerStage.SUBMITTED), stages)
        }
    }
    @Test fun `创建回执保存失败停止读取写前保存失败零写`() = runBlocking {
        for (stage in listOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED)) {
            val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement
            assertTrue(runCatching { repo.createNetwork(ContainerNetworkDraft("Synthetic-new")) { if (it == stage) throw IOException("Synthetic storage") } }.isFailure)
            assertEquals(if (stage == ContainerStage.SUBMITTED) 0 else 1, fixture.writes.size)
            if (stage == ContainerStage.ACCEPTED) assertEquals("create", fixture.calls.last().method)
        }
    }
}
