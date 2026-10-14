package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class VmmSettingsRepositoryTest {
    private val fixture = VmmFixture()
    @Test fun `公开读取附加精确内部优先级并保留三态启动`() = runBlocking {
        val repo = fixture.repository().virtualMachineManagement
        val baseline = repo.settings("synthetic-guest")
        assertEquals(VmmSource.PUBLIC, baseline.source); assertEquals(1024, baseline.configuration.memoryMiB)
        assertEquals(1, baseline.configuration.startup); assertEquals(256, baseline.configuration.priority)
        val stages = mutableListOf<VmmStage>()
        repo.saveSettings(baseline, baseline.configuration.copy(name = "Updated", startup = 2), stages::add)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED, VmmStage.VERIFIED), stages)
        val call = fixture.writes.single(); assertEquals(VmmSource.PUBLIC.guestApi, call.api); assertEquals(1, call.version); assertTrue(call.oneShot)
        assertEquals(setOf("guest_id", "new_guest_name", "autorun"), call.fields.keys)
    }
    @Test fun `优先级变化时所有字段只发一次内部v1且内存使用MiB`() = runBlocking {
        val repo = fixture.repository().virtualMachineManagement; val baseline = repo.settings("synthetic-guest")
        val stages = mutableListOf<VmmStage>(); val desired = baseline.configuration.copy(name = "Updated", description = "", priority = 1024, memoryMiB = 2048, startup = 0)
        repo.saveSettings(baseline, desired, stages::add)
        val call = fixture.writes.single(); assertEquals(VmmSource.INTERNAL.guestApi, call.api); assertEquals(1, call.version)
        assertEquals(JsonPrimitive(2048), call.fields["vram_size"]); assertEquals(JsonPrimitive(1024), call.fields["cpu_weight"])
        assertEquals(JsonPrimitive(""), call.fields["desc"]); assertFalse(call.fields.containsKey("new_guest_name")); assertNotNull(call.fields["synovmm_ui_id"])
        assertEquals(VmmStage.VERIFIED, stages.last())
    }
    @Test fun `仅内部可用仍可编辑且FORM参数不混用公开字段`() = runBlocking {
        fixture.public = false; fixture.format = "FORM"
        val repo = fixture.repository().virtualMachineManagement; val baseline = repo.settings("synthetic-guest"); val stages = mutableListOf<VmmStage>()
        repo.saveSettings(baseline, baseline.configuration.copy(description = "Changed", startup = 1, cpu = 4), stages::add)
        assertEquals(VmmStage.VERIFIED, stages.last()); val call = fixture.writes.single()
        assertEquals(JsonPrimitive("4"), call.fields["vcpu_num"]); assertEquals(JsonPrimitive("Changed"), call.fields["desc"])
        assertFalse(call.fields.containsKey("description")); assertFalse(call.fields.containsKey("autorun"))
    }
    @Test fun `运行状态只能改非硬件字段未知状态拒绝保存`() = runBlocking {
        fixture.guests = listOf(VmmFixture.guest(status = "running")); val repo = fixture.repository().virtualMachineManagement
        var baseline = repo.settings("synthetic-guest")
        assertFalse(baseline.validChange(baseline.configuration.copy(cpu = 4)))
        assertFalse(baseline.validChange(baseline.configuration.copy(memoryMiB = 2048)))
        repo.saveSettings(baseline, baseline.configuration.copy(description = "Changed")) {}
        fixture.guests = listOf(VmmFixture.guest(status = "migrating")); baseline = repo.settings("synthetic-guest")
        assertFalse(baseline.validChange(baseline.configuration.copy(name = "Updated"))); assertEquals(1, fixture.writes.size)
    }
    @Test fun `附加内部读取普通失败降级但认证错误终止`() = runBlocking {
        val repo = fixture.repository().virtualMachineManagement
        fixture.errors = mapOf(VmmSource.INTERNAL.guestApi to "get" to 102)
        assertNull(repo.settings("synthetic-guest").configuration.priority)
        fixture.errors = mapOf(VmmSource.INTERNAL.guestApi to "get" to 106)
        assertTrue(runCatching { repo.settings("synthetic-guest") }.exceptionOrNull() is DsmFailure)
        assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `内部身份或字段不同不借公开设置补值`() = runBlocking {
        fixture.before = { if (it.api == VmmSource.INTERNAL.guestApi && it.method == "get") fixture.getOverride = VmmFixture.guest(name = "Different") }
        val baseline = fixture.repository().virtualMachineManagement.settings("synthetic-guest")
        assertNull(baseline.configuration.priority); assertEquals("Synthetic VM", baseline.configuration.name)
        assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `写前外部修改同名碰撞局部清单或权限撤销全部零写`() = runBlocking {
        for (case in 0..3) {
            val fixture = VmmFixture(); val repo = fixture.repository().virtualMachineManagement; val baseline = repo.settings("synthetic-guest")
            when (case) {
                0 -> fixture.guests = listOf(VmmFixture.guest(status = "running"))
                1 -> fixture.guests += VmmFixture.guest("other", "UPDATED")
                2 -> fixture.total = 2
                3 -> fixture.allowed = false
            }
            val stages = mutableListOf<VmmStage>()
            assertTrue(runCatching { repo.saveSettings(baseline, baseline.configuration.copy(name = "Updated"), stages::add) }.isFailure)
            assertEquals(listOf(VmmStage.CANCELLED), stages); assertTrue(fixture.writes.isEmpty())
        }
    }
    @Test fun `未知内部环境仍允许优先级写入且公开设置保持可用`() = runBlocking {
        fixture.known = false; val repo = fixture.repository().virtualMachineManagement; val baseline = repo.settings("synthetic-guest")
        repo.saveSettings(baseline, baseline.configuration.copy(priority = 512)) {}
        assertEquals(VmmSource.INTERNAL.guestApi, fixture.writes.single().api)
        assertTrue(fixture.calls.none { it.api in setOf("SYNO.Core.System", "SYNO.Core.Package") })
        fixture.calls.clear(); val fresh = repo.settings("synthetic-guest")
        repo.saveSettings(fresh, fresh.configuration.copy(description = "Changed")) {}
        assertEquals(VmmSource.PUBLIC.guestApi, fixture.writes.single().api)
    }
    @Test fun `拒绝不降级重发丢回执不回读或标记接受`() = runBlocking {
        for (rejected in listOf(true, false)) {
            val fixture = VmmFixture(); val repo = fixture.repository().virtualMachineManagement; val baseline = repo.settings("synthetic-guest")
            if (rejected) fixture.rejection = 105 else fixture.after = { if (it.method == "set") throw IOException("lost response") }
            val stages = mutableListOf<VmmStage>(); assertTrue(runCatching { repo.saveSettings(baseline, baseline.configuration.copy(priority = 512), stages::add) }.isFailure)
            assertEquals(if (rejected) listOf(VmmStage.SUBMITTED, VmmStage.REJECTED) else listOf(VmmStage.SUBMITTED), stages)
            assertEquals(1, fixture.writes.size); assertEquals("set", fixture.calls.last().method)
        }
    }
    @Test fun `原始数字和内存单位严格缺失字段不能填默认值`() = runBlocking {
        fixture.public = false; val repo = fixture.repository().virtualMachineManagement
        for (invalid in listOf(JsonPrimitive("1024"), JsonPrimitive(1025), JsonPrimitive(0), JsonNull)) {
            fixture.getOverride = JsonObject(VmmFixture.guest() + ("vram_size" to invalid))
            assertTrue(runCatching { repo.settings("synthetic-guest") }.isFailure)
        }
        fixture.getOverride = JsonObject(VmmFixture.guest() - "vram_size" - "autorun")
        val baseline = repo.settings("synthetic-guest"); assertNull(baseline.configuration.memoryMiB); assertNull(baseline.configuration.startup)
        assertFalse(baseline.validChange(baseline.configuration.copy(memoryMiB = 1024))); assertFalse(baseline.validChange(baseline.configuration.copy(startup = 0)))
        assertTrue(baseline.validChange(baseline.configuration.copy(description = "Changed")))
    }
}
