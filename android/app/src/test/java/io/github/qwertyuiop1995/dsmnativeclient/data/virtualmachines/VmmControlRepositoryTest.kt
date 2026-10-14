package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import javax.net.ssl.SSLHandshakeException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class VmmControlRepositoryTest {
    private val fixture = VmmFixture()
    private val stages = mutableListOf<VmmStage>()
    private suspend fun send(action: VmmAction, repository: VmmManagementRepository = fixture.repository().virtualMachineManagement) {
        val target = repository.controlTargets().single()
        repository.performControl(target, action, repository.controlSource(action), stages::add)
    }
    @Test fun `公开启停断电删除固定v1单项oneShot且需要原身份终态`() = runBlocking {
        for (format in listOf("JSON", "FORM")) for (action in listOf(VmmAction.START, VmmAction.SHUTDOWN, VmmAction.POWER_OFF, VmmAction.DELETE)) {
            fixture.format = format; fixture.calls.clear(); stages.clear()
            fixture.guests = listOf(VmmFixture.guest(status = if (action in setOf(VmmAction.START, VmmAction.DELETE)) "shutdown" else "running"))
            send(action)
            assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED, VmmStage.VERIFIED), stages)
            val write = fixture.writes.single(); assertTrue(write.oneShot); assertEquals(1, write.version)
            assertEquals(action.command, write.method); assertEquals(mapOf("guest_id" to JsonPrimitive("synthetic-guest")), write.fields)
            assertTrue(write.api.startsWith("SYNO.Virtualization.API."))
        }
    }
    @Test fun `内部启停删除固定读v2写v1且重启接受不冒称完成`() = runBlocking {
        fixture.public = false
        for (action in VmmAction.entries) {
            fixture.calls.clear(); stages.clear()
            fixture.guests = listOf(VmmFixture.guest(status = if (action in setOf(VmmAction.START, VmmAction.DELETE)) "shutdown" else "running"))
            send(action)
            assertEquals(if (action == VmmAction.RESTART) VmmStage.ACCEPTED else VmmStage.VERIFIED, stages.last())
            val write = fixture.writes.single(); assertEquals(1, write.version); assertTrue(write.oneShot)
            assertEquals(if (action == VmmAction.DELETE) "delete" else "pwr_ctl", write.method)
            if (action != VmmAction.DELETE) assertEquals(JsonPrimitive(action.command), write.fields["action"])
            assertTrue(fixture.calls.filter { it.api == "SYNO.Virtualization.Guest" && it.method in setOf("get", "list") }.all { it.version == 2 })
        }
    }
    @Test fun `重启只走内部枚举不拆成断电开机`() = runBlocking {
        fixture.guests = listOf(VmmFixture.guest(status = "running")); send(VmmAction.RESTART)
        assertEquals(VmmStage.ACCEPTED, stages.last()); assertEquals("SYNO.Virtualization.Guest.Action", fixture.writes.single().api)
        assertEquals(JsonPrimitive("reboot"), fixture.writes.single().fields["action"])
    }
    @Test fun `预检名称状态身份变化均零写`() = runBlocking {
        for (guest in listOf(VmmFixture.guest(name = "Changed"), VmmFixture.guest(status = "running"), VmmFixture.guest(id = "different"))) {
            fixture.guests = listOf(VmmFixture.guest()); fixture.calls.clear(); stages.clear()
            val repo = fixture.repository().virtualMachineManagement; val target = repo.controlTargets().single()
            fixture.getOverride = JsonObject(guest - "name")
            assertTrue(runCatching { repo.performControl(target, VmmAction.START, VmmSource.PUBLIC, stages::add) }.isFailure)
            assertTrue(fixture.writes.isEmpty()); assertEquals(listOf(VmmStage.CANCELLED), stages)
        }
    }
    @Test fun `内部未知版本允许操作且实际权限丢失仍零写`() = runBlocking {
        fixture.guests = listOf(VmmFixture.guest(status = "running")); fixture.known = false; fixture.packageVersion = "new-version"
        send(VmmAction.RESTART)
        assertEquals(VmmStage.ACCEPTED, stages.last()); assertEquals(1, fixture.writes.size)
        assertTrue(fixture.calls.none { it.api in setOf("SYNO.Core.System", "SYNO.Core.Package") })
        fixture.calls.clear(); stages.clear(); send(VmmAction.SHUTDOWN); assertEquals(VmmStage.VERIFIED, stages.last())
        fixture.calls.clear(); fixture.guests = listOf(VmmFixture.guest()); val repo = fixture.repository().virtualMachineManagement
        val target = repo.controlTargets().single(); fixture.allowed = false
        assertTrue(runCatching { repo.performControl(target, VmmAction.START, VmmSource.PUBLIC, stages::add) }.isFailure); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `能力缺版本缺字段及不完整清单不补默认允许`() = runBlocking {
        fixture.versions = mapOf("SYNO.Virtualization.API.Guest.Action" to 2..3); fixture.internal = false
        val repo = fixture.repository().virtualMachineManagement
        assertFalse(repo.controlTargets().single().supports(VmmAction.START))
        fixture.total = 2; assertTrue(runCatching { repo.controlTargets() }.isFailure)
        fixture.total = null; fixture.guests = listOf(VmmFixture.guest(), VmmFixture.guest())
        assertTrue(runCatching { repo.controlTargets() }.isFailure)
        fixture.guests = listOf(JsonObject(VmmFixture.guest() - "guest_name")); assertTrue(runCatching { repo.controlTargets() }.isFailure)
    }
    @Test fun `写前落盘失败零写明确拒绝与断网阶段不同`() = runBlocking {
        val repo = fixture.repository().virtualMachineManagement; val target = repo.controlTargets().single()
        assertTrue(runCatching { repo.performControl(target, VmmAction.START, VmmSource.PUBLIC) { if (it == VmmStage.SUBMITTED) throw IOException("storage") } }.isFailure)
        assertTrue(fixture.writes.isEmpty())
        fixture.rejection = 105; assertTrue(runCatching { send(VmmAction.START) }.isFailure)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.REJECTED), stages)
        fixture.rejection = null; stages.clear(); fixture.before = { if (it.method == "poweron") throw IOException("lost response") }
        assertTrue(runCatching { send(VmmAction.START) }.isFailure); assertEquals(listOf(VmmStage.SUBMITTED), stages)
    }
    @Test fun `证书错误停止请求不回读或切换接口`() = runBlocking {
        fixture.before = { if (it.method == "poweron") throw SSLHandshakeException("synthetic") }
        assertTrue(runCatching { send(VmmAction.START) }.isFailure)
        assertEquals(listOf(VmmStage.SUBMITTED), stages); assertEquals("poweron", fixture.calls.last().method); assertEquals(1, fixture.writes.size)
    }
    @Test fun `接受后原对象改名不能借同状态认领`() = runBlocking {
        fixture.after = { if (it.method == "poweron") fixture.guests = listOf(VmmFixture.guest(name = "Changed", status = "running")) }
        send(VmmAction.START); assertEquals(VmmStage.ACCEPTED, stages.last())
    }
}
