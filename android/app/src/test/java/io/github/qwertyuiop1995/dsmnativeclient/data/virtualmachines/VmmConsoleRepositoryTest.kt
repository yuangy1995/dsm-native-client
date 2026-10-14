package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class VmmConsoleRepositoryTest {
    private val fixture = VmmFixture().apply { guests = listOf(VmmFixture.guest(status = "running")) }
    private var keyboard = "Default"; private var general: JsonElement = JsonPrimitive("en-us"); private var online: JsonElement = JsonPrimitive(true)
    init {
        fixture.responseOverride = { call -> when {
            call.api == "SYNO.Virtualization.Guest" && call.method == "get" -> JsonObject(fixture.guests.single() + mapOf("kb_layout" to JsonPrimitive(keyboard), "is_online" to online))
            call.api == "SYNO.Virtualization.Setting.General" -> buildJsonObject { put("kb_layout", general) }
            else -> null
        } }
    }
    @Test fun `重新读取原对象与默认键盘只产生固定版本读取`() = runBlocking {
        val repo = fixture.repository(); val target = repo.virtualMachineManagement.controlTargets().single()
        val session = repo.prepareVirtualMachineConsole(target)
        assertTrue(session.policy.document.contains("kb_layout=en-us")); assertTrue(fixture.writes.isEmpty())
        assertEquals(listOf(2, 1), fixture.calls.filter { it.api in setOf("SYNO.Virtualization.Guest", "SYNO.Virtualization.Setting.General") }.map { it.version })
        session.transport.close()
    }
    @Test fun `明确键盘不用默认设置且内部只读不受未知写环境阻断`() = runBlocking {
        keyboard = "fr"; fixture.known = false; fixture.public = false
        val repo = fixture.repository(); val session = repo.prepareVirtualMachineConsole(repo.virtualMachineManagement.controlTargets().single())
        assertTrue(session.policy.document.contains("kb_layout=fr")); assertTrue(fixture.calls.none { it.api == "SYNO.Virtualization.Setting.General" })
        assertTrue(fixture.writes.isEmpty()); session.transport.close()
    }
    @Test fun `改名停机或字段类型不符不能打开`() = runBlocking {
        val repo = fixture.repository(); val target = repo.virtualMachineManagement.controlTargets().single()
        fixture.guests = listOf(VmmFixture.guest(name = "Changed", status = "running"))
        assertThrows(VmmFailure::class.java) { runBlocking { repo.prepareVirtualMachineConsole(target) } }
        fixture.guests = listOf(VmmFixture.guest()); assertThrows(VmmFailure::class.java) { runBlocking { repo.prepareVirtualMachineConsole(target) } }
        fixture.guests = listOf(VmmFixture.guest(status = "running")); online = JsonPrimitive("true")
        assertThrows(DsmFailure::class.java) { runBlocking { repo.prepareVirtualMachineConsole(target) } }
        online = JsonPrimitive(true); general = JsonPrimitive("Default")
        assertThrows(DsmFailure::class.java) { runBlocking { repo.prepareVirtualMachineConsole(target) } }
        assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `无权限过期归属和缺少内部能力均拒绝`() = runBlocking {
        val repo = fixture.repository(); val target = repo.virtualMachineManagement.controlTargets().single()
        fixture.allowed = false; assertThrows(DsmFailure::class.java) { runBlocking { repo.prepareVirtualMachineConsole(target) } }
        fixture.allowed = true; fixture.ownerValid = false; assertThrows(DsmFailure::class.java) { runBlocking { repo.prepareVirtualMachineConsole(target) } }
        fixture.ownerValid = true; fixture.internal = false; val other = fixture.repository()
        assertFalse(other.supportsVirtualMachineConsole); assertThrows(DsmFailure::class.java) { runBlocking { other.prepareVirtualMachineConsole(target) } }
        assertTrue(fixture.writes.isEmpty())
    }
}
