package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasEthernetRecoveryRepositoryTest {
    private val kind = NasServiceKind.ETHERNET; private val step = NasServiceStep.ETHERNET
    private suspend fun original(f: NasServiceProtocolFixture) = f.repository().nasServices.load(kind, "eth0") as NasServiceValue.Ethernet
    private fun change(value: NasServiceValue.Ethernet) = value.copy(settings = value.settings.copy(mtu = 1600))
    private fun NasServiceProtocolFixture.fields(vararg values: Pair<String, JsonElement>) {
        backend.rows[step] = JsonObject(backend.rows.getValue(step) + values)
    }
    @Test fun `FORM和JSON均仅提交选中网卡完整静态配置`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            val f = NasServiceProtocolFixture(); f.requestFormat = format; val repo = f.repository().nasServices
            val before = repo.load(kind, "eth0") as NasServiceValue.Ethernet
            val desired = before.copy(settings = before.settings.copy(usesDhcp = false, address = " 192.0.2.20 ",
                subnetMask = "255.255.255.0", gateway = "192.0.2.1", dnsServers = "192.0.2.53", mtu = 1600, isVlanEnabled = true, vlanId = 12))
            val events = mutableListOf<NasServiceCheckpoint>()
            val result = repo.save(repo.plan(before, desired)) { events += it }
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
            val write = f.backend.writes.single(); assertEquals("set", write.method); assertEquals(1, write.version)
            val configs = write.fields.getValue("configs").jsonArray; assertEquals(1, configs.size)
            assertEquals(setOf("ifname", "use_dhcp", "is_default_gateway", "mtu", "enable_vlan", "ip", "mask", "gateway", "dns", "vlan_id"), configs.single().jsonObject.keys)
            assertEquals("192.0.2.20", configs.single().jsonObject.getValue("ip").jsonPrimitive.content)
            assertEquals(listOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED, NasServiceStage.VERIFIED), events.map { it.stage })
            assertEquals(1, f.requests.count { it.body?.isOneShot() == true }); assertTrue(f.backend.requests.none { it.method == "list" })
        }
    }
    @Test fun `DHCP租约和显示变化不算配置冲突且不提交静态字段与关闭VLAN编号`() = runBlocking {
        val f = NasServiceProtocolFixture(); val before = original(f)
        f.fields("ip" to JsonPrimitive("192.0.2.21"), "status" to JsonPrimitive("online"), "title" to JsonPrimitive("Changed"), "vlan_id" to JsonPrimitive(12))
        val repo = f.repository().nasServices; assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.save(repo.plan(before, change(before))) {}.status)
        assertEquals(setOf("ifname", "use_dhcp", "is_default_gateway", "mtu", "enable_vlan"), f.backend.writes.single().fields.getValue("configs").jsonArray.single().jsonObject.keys)
    }
    @Test fun `原配置变化在提交前拒绝并且详情身份不匹配不构造表单`() = runBlocking {
        val f = NasServiceProtocolFixture(); val before = original(f); val repo = f.repository().nasServices
        f.fields("mtu" to JsonPrimitive(1700)); val result = repo.save(repo.plan(before, change(before))) {}
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory); assertFalse(result.submitted); assertTrue(f.backend.writes.isEmpty())
        f.fields("ifname" to JsonPrimitive("eth1"))
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (runCatching { repo.load(kind, "eth0") }.exceptionOrNull() as DsmFailure).kind)
    }
    @Test fun `必要字段缺失和类型错误均不补默认值`() = runBlocking {
        for (field in listOf("ifname", "use_dhcp", "is_default_gateway", "mtu", "enable_vlan")) {
            val f = NasServiceProtocolFixture(); f.backend.rows[step] = JsonObject(f.backend.rows.getValue(step) - field)
            assertEquals(DsmErrorKind.INVALID_RESPONSE, (runCatching { original(f) }.exceptionOrNull() as DsmFailure).kind)
        }
        for (field in listOf("use_dhcp", "is_default_gateway")) {
            val f = NasServiceProtocolFixture(); f.fields(field to JsonPrimitive("true"))
            assertEquals(DsmErrorKind.INVALID_RESPONSE, (runCatching { original(f) }.exceptionOrNull() as DsmFailure).kind)
        }
        val f = NasServiceProtocolFixture(); f.fields("use_dhcp" to JsonPrimitive(false))
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (runCatching { original(f) }.exceptionOrNull() as DsmFailure).kind)
    }
    @Test fun `版本输入及原目标校验均零写入`() = runBlocking {
        val f = NasServiceProtocolFixture(); val before = original(f); val repo = f.repository().nasServices
        for (invalid in listOf(before.settings.copy(mtu = 1), before.settings.copy(isVlanEnabled = true, vlanId = null),
            before.settings.copy(usesDhcp = false, address = "192.0.2.1", subnetMask = "255.0.255.0"))) {
            assertEquals(DsmErrorKind.NAS_SERVICE_INVALID, (runCatching { repo.plan(before, NasServiceValue.Ethernet(invalid)) }.exceptionOrNull() as DsmFailure).kind)
        }
        assertEquals(DsmErrorKind.NAS_SERVICE_CHANGED, (runCatching { repo.plan(before, before.copy(settings = before.settings.copy(id = "eth1"))) }.exceptionOrNull() as DsmFailure).kind)
        f.backend.versions[step] = 1..1
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (runCatching { f.repository().nasServices.plan(before, change(before)) }.exceptionOrNull() as DsmFailure).kind)
        assertTrue(f.backend.writes.isEmpty())
    }
    @Test fun `明确拒绝不被相同当前值覆盖而回执丢失可凭完整回读结束`() = runBlocking {
        val f = NasServiceProtocolFixture(); val before = original(f); val repo = f.repository().nasServices
        f.writeRejectionCode = 105
        assertEquals(MutationResultStatus.PERMISSION_DENIED, repo.save(repo.plan(before, change(before))) {}.status)
        assertEquals(1, f.backend.writes.size)
        val next = NasServiceProtocolFixture(); val first = original(next)
        next.backend.afterWrite = { throw IOException("Synthetic lost receipt") }
        val nextRepo = next.repository().nasServices
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, nextRepo.save(nextRepo.plan(first, change(first))) {}.status)
        assertEquals(1, next.backend.writes.size)
    }
    @Test fun `未知版本允许操作但过期身份在提交前停止`() = runBlocking {
        for (unknown in listOf(true, false)) {
            val f = NasServiceProtocolFixture(); val before = original(f); val repo = f.repository().nasServices
            if (unknown) f.knownEnvironment = false else f.ownerValid = false
            val result = repo.save(repo.plan(before, change(before))) {}
            assertEquals(unknown, result.submitted); assertEquals(if (unknown) 1 else 0, f.backend.writes.size)
        }
    }
    @Test fun `最终读取变化撤回先前成功结论且不重发`() = runBlocking {
        val f = NasServiceProtocolFixture(); val before = original(f); val repo = f.repository().nasServices
        var reads = 0
        f.backend.afterWrite = { f.backend.before = { if (!it.write && ++reads == 2) f.fields("mtu" to JsonPrimitive(1700)) } }
        val result = repo.save(repo.plan(before, change(before))) {}
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status); assertEquals(1, f.backend.writes.size)
    }
}
