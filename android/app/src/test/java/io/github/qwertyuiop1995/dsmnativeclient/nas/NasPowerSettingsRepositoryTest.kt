package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasPowerSettingsRepositoryTest {
    private val memory = NasServiceKind.MEMORY_COMPRESSION; private val power = NasServiceKind.POWER_SCHEDULE
    private val on = NasServiceStep.ZRAM; private val mark = NasServiceStep.REBOOT_REQUIRED; private val schedules = NasServiceStep.POWER_SCHEDULE
    private fun row(raw: String) = NasServiceSettingsFixture.row(raw)
    private suspend fun NasServiceProtocolFixture.memory() = repository().nasServices.load(memory) as NasServiceValue.MemoryCompression
    private suspend fun NasServiceProtocolFixture.power() = repository().nasServices.load(power) as NasServiceValue.PowerSchedule
    private fun NasServiceValue.MemoryCompression.change() = copy(settings = settings.copy(enabled = !settings.enabled!!))
    private fun task(action: NasPowerScheduleAction = NasPowerScheduleAction.STARTUP, days: Set<Int> = setOf(0, 1), hour: Int = 8) = NasPowerScheduleEntry(action, false, days, hour, 5)
    private fun NasServiceValue.PowerSchedule.withTasks(vararg rows: NasPowerScheduleEntry) = copy(settings = settings.copy(entries = rows.toList(), total = rows.size))
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) {} }
    @Test fun `内存压缩FORM与JSON两步固定版本逐次接受且不重启`() = runBlocking {
        for (format in listOf("FORM", "JSON")) for (alreadyMarked in listOf(false, true)) {
            val f = NasServiceProtocolFixture(); f.requestFormat = format; f.backend.rows[mark] = row("""{"need_reboot":$alreadyMarked}""")
            val original = f.memory(); val repo = f.repository().nasServices; val events = mutableListOf<NasServiceCheckpoint>()
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.save(repo.plan(original, original.change())) { events += it }.status)
            assertEquals(listOf(on, mark), f.backend.writes.map { it.step })
            assertEquals(mapOf("enable_zram" to JsonPrimitive(true)), f.backend.writes[0].fields); assertTrue(f.backend.writes[1].fields.isEmpty())
            assertTrue(f.backend.writes.all { it.version == 1 && it.method == "set" }); assertEquals(2, f.requests.count { it.body?.isOneShot() == true })
            assertEquals(listOf(on, mark), events.filter { it.stage == NasServiceStage.ACCEPTED }.map { it.step })
        }
    }
    @Test fun `原生布尔别名冲突与缺失标记保留未知而非关闭`() = runBlocking {
        val f = NasServiceProtocolFixture()
        for (raw in listOf("{}", """{"enable_zram":"false"}""", """{"enable_zram":false,"enabled":true}""", """{"enable_zram":0}""")) {
            f.backend.rows[on] = row(raw); val original = f.memory(); assertNull(original.settings.enabled); assertFalse(original.settings.editable)
            rejected { f.repository().nasServices.plan(original, original.copy(settings = original.settings.copy(enabled = true))) }
        }
        f.backend.rows[on] = row("""{"enable":true,"zram_enable":true,"configured_bytes":1024,"algorithm":"ZSTD"}""")
        f.backend.rows[mark] = row("""{"need_reboot":"yes"}""")
        val actual = f.memory(); assertEquals(true, actual.settings.enabled); assertEquals(1024L, actual.settings.configuredBytes); assertEquals("zstd", actual.settings.algorithm)
        assertNull(actual.settings.rebootRequired); assertFalse(actual.settings.editable)
        f.backend.rows[on] = row("""{"enabled":false,"configured_bytes":-2,"algorithm":"unknown"}""")
        assertNull(f.memory().settings.configuredBytes); assertNull(f.memory().settings.algorithm); assertTrue(f.backend.writes.isEmpty())
    }
    @Test fun `标记读取失败保留摘要但认证权限与证书和取消必须传播`() = runBlocking {
        for (kind in listOf(DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.REQUEST_FAILED, DsmErrorKind.PERMISSION_DENIED,
            DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.AUTHENTICATION_FAILED, DsmErrorKind.TLS_UNTRUSTED)) {
            val f = NasServiceSettingsFixture(); f.before = { if (it.step == mark) throw DsmFailure(null, "Synthetic", "", kind = kind) }
            try {
                val value = f.repository.load(memory) as NasServiceValue.MemoryCompression
                assertTrue(kind in setOf(DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.REQUEST_FAILED)); assertFalse(value.settings.editable)
            } catch (error: DsmFailure) { assertEquals(kind, error.kind); assertTrue(kind !in setOf(DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.REQUEST_FAILED)) }
        }
        val f = NasServiceSettingsFixture(); f.before = { if (it.step == mark) throw CancellationException() }
        try { f.repository.load(memory); fail() } catch (_: CancellationException) {}
    }
    @Test fun `重启只读标记变化不破坏压缩原基线但开关变化拒绝覆盖`() = runBlocking {
        for (changeCompression in listOf(false, true)) {
            val f = NasServiceProtocolFixture(); val repo = f.repository().nasServices; val original = f.memory(); val plan = repo.plan(original, original.change())
            f.backend.rows[if (changeCompression) on else mark] = row(if (changeCompression) """{"enable_zram":true}""" else """{"need_reboot":true}""")
            val result = repo.save(plan) {}; assertEquals(!changeCompression, result.submitted)
            assertEquals(if (changeCompression) 0 else 2, f.backend.writes.size)
        }
    }
    @Test fun `任一步回执丢失停止写链且相同开关或标记不能伪造接受`() = runBlocking {
        for (lost in listOf(on, mark)) {
            val f = NasServiceProtocolFixture(); val repo = f.repository().nasServices; val original = f.memory()
            f.backend.afterWrite = { if (it.step == lost) throw IOException("Synthetic lost receipt") }
            val result = repo.save(repo.plan(original, original.change())) {}
            assertEquals(1, result.counts.unknown); assertEquals(if (lost == on) 1 else 2, f.backend.writes.size)
            assertEquals(if (lost == on) 0 else 1, result.counts.succeeded)
        }
    }
    @Test fun `第二步明确拒绝和配置后来变化均不误报完整成功`() = runBlocking {
        for (rejected in listOf(false, true)) {
            val f = NasServiceProtocolFixture(); val repo = f.repository().nasServices; val original = f.memory()
            f.backend.afterWrite = { if (it.step == mark) {
                if (rejected) f.writeRejectionCode = 105 else f.backend.rows[on] = row("""{"enable_zram":false}""")
            } }
            val result = repo.save(repo.plan(original, original.change())) {}
            assertNotEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
            assertEquals(if (rejected) 1 else 0, result.counts.succeeded); assertEquals(2, f.backend.writes.size)
        }
    }
    @Test fun `接口版本旧会话与落盘失败阻止请求但未知DSM可保存`() = runBlocking {
        for (scenario in 0..3) {
            val f = NasServiceProtocolFixture(); val original = f.memory()
            when (scenario) { 0 -> f.backend.versions[mark] = 2..2; 1 -> f.knownEnvironment = false }
            val repo = f.repository().nasServices
            if (scenario == 2) f.ownerValid = false
            try {
                val result = repo.save(repo.plan(original, original.change())) { if (scenario == 3 && it.stage == NasServiceStage.ACCEPTED)
                    throw DsmFailure(null, "Synthetic storage failed", "", kind = DsmErrorKind.LOCAL_STORAGE_FAILED) }
                assertEquals(scenario == 1, result.submitted)
            } catch (_: DsmFailure) {}
            assertEquals(when (scenario) { 1 -> 2; 3 -> 1; else -> 0 }, f.backend.writes.size)
        }
    }
    @Test fun `电源计划FORM与JSON一次保存完整双数组清空和周日编码`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            val f = NasServiceProtocolFixture(); f.requestFormat = format; val repo = f.repository().nasServices
            var original = f.power(); val desired = original.withTasks(task(), task(NasPowerScheduleAction.SHUTDOWN, setOf(6), 23))
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.save(repo.plan(original, desired)) {}.status)
            val request = f.backend.writes.single(); assertEquals("save", request.method); assertEquals(1, request.version)
            assertEquals(setOf("poweron_tasks", "poweroff_tasks"), request.fields.keys)
            assertEquals(JsonPrimitive("0,1"), request.fields.getValue("poweron_tasks").jsonArray.single().jsonObject["weekdays"])
            assertEquals(JsonPrimitive(false), request.fields.getValue("poweroff_tasks").jsonArray.single().jsonObject["enabled"])
            original = f.power(); assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.save(repo.plan(original, original.withTasks())) {}.status)
            assertTrue(f.backend.writes.last().fields.values.all { it.jsonArray.isEmpty() }); assertEquals(2, f.requests.count { it.body?.isOneShot() == true })
        }
    }
    @Test fun `完整列表语义忽略数组顺序和星期顺序但包括时区`() = runBlocking {
        val f = NasServiceProtocolFixture(); val repo = f.repository().nasServices
        f.backend.rows[schedules] = row("""{"poweron_tasks":[{"enabled":false,"weekdays":"1,0","hour":8,"min":5},{"enabled":true,"weekdays":"6","hour":20,"min":0}],"poweroff_tasks":[],"timezone":"UTC"}""")
        val original = f.power(); val desired = original.withTasks(task(hour = 9))
        f.backend.rows[schedules] = row("""{"poweron_tasks":[{"enabled":true,"weekdays":"6","hour":20,"min":0},{"enabled":false,"weekdays":"0,1","hour":8,"min":5}],"poweroff_tasks":[],"timezone":"UTC"}""")
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.save(repo.plan(original, desired)) {}.status)
        val next = f.power(); val plan = repo.plan(next, next.withTasks(task(hour = 10)))
        f.backend.rows[schedules] = JsonObject(f.backend.rows.getValue(schedules) + ("timezone" to JsonPrimitive("Asia/Shanghai")))
        assertFalse(repo.save(plan) {}.submitted); assertEquals(1, f.backend.writes.size)
    }
    @Test fun `未知字段条目非双数组摘要与截断不能变为覆盖依据`() = runBlocking {
        val f = NasServiceProtocolFixture(); val repo = f.repository().nasServices
        val invalid = listOf(
            """{"poweron_tasks":[],"poweroff_tasks":[],"total":1}""",
            """{"poweron_tasks":[{"enabled":"true","weekdays":"0","hour":8,"min":0}],"poweroff_tasks":[]}""",
            """{"poweron_tasks":[{"enabled":true,"weekdays":"0","hour":24,"min":0}],"poweroff_tasks":[]}""",
            """{"poweron_tasks":[{"enabled":true,"weekdays":"sun","hour":8,"min":0}],"poweroff_tasks":[]}""",
            """{"poweron_tasks":[{"enabled":true,"weekdays":"0","hour":8,"min":0,"date":"2026-10-20"}],"poweroff_tasks":[]}""",
            """{"schedules":[{"action":"reboot","enabled":true,"weekdays":"sun","hour":8,"minute":0}]}""",
            """{"poweron_tasks":[],"poweroff_tasks":[],"timezone":"UTC","time_zone":"Asia/Shanghai"}""")
        for (raw in invalid) {
            f.backend.rows[schedules] = row(raw); val original = f.power(); assertFalse(original.settings.editable)
            rejected { repo.plan(original, original.withTasks(task())) }
        }
        f.backend.rows[schedules] = row("""{"poweron_tasks":[]}""")
        try { f.power(); fail() } catch (_: DsmFailure) {}
        assertTrue(f.backend.writes.isEmpty())
    }
    @Test fun `二百条上限与停用或跨动作重叠均校验完整清单`() = runBlocking {
        val f = NasServiceProtocolFixture(); val repo = f.repository().nasServices; val original = f.power()
        val entries = (0 until 200).map { task().copy(hour = it / 60, minute = it % 60) }
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.save(repo.plan(original, original.withTasks(*entries.toTypedArray()))) {}.status)
        rejected { repo.plan(original, original.withTasks(*(entries + task(hour = 9)).toTypedArray())) }
        for (tasks in listOf(listOf(task(), task()), listOf(task(), task(NasPowerScheduleAction.SHUTDOWN, setOf(1))))) rejected { repo.plan(original, original.withTasks(*tasks.toTypedArray())) }
        f.backend.rows[schedules] = JsonObject(f.backend.rows.getValue(schedules) + ("poweron_tasks" to JsonArray((entries + task(hour = 9)).map { buildJsonObject { put("enabled", false); put("weekdays", "0"); put("hour", it.hour!!); put("min", it.minute!!) } })))
        val truncated = f.power().settings; assertEquals(201, truncated.total); assertEquals(200, truncated.entries.size); assertFalse(truncated.editable)
        assertEquals(1, f.backend.writes.size)
    }
    @Test fun `保存后时区变化回读失败或明确拒绝都不能报告成功`() = runBlocking {
        for (scenario in 0..2) {
            val f = NasServiceProtocolFixture(); val repo = f.repository().nasServices; val original = f.power()
            f.backend.afterWrite = {
                when (scenario) {
                    0 -> f.backend.rows[schedules] = JsonObject(f.backend.rows.getValue(schedules) + ("timezone" to JsonPrimitive("Asia/Shanghai")))
                    1 -> f.backend.before = { if (!it.write) throw IOException("Synthetic offline") }
                    else -> f.writeRejectionCode = 105
                }
            }
            val result = repo.save(repo.plan(original, original.withTasks(task()))) {}
            assertNotEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(1, f.backend.writes.size)
        }
    }
    @Test fun `计划断线只读恢复与清单不符均不重复发送`() = runBlocking {
        for (matching in listOf(false, true)) {
            val f = NasServiceProtocolFixture(); val repo = f.repository().nasServices; val original = f.power()
            f.backend.afterWrite = { if (!matching) f.backend.rows[schedules] = row("""{"poweron_tasks":[],"poweroff_tasks":[],"timezone":"UTC"}"""); throw IOException("Synthetic lost receipt") }
            val result = repo.save(repo.plan(original, original.withTasks(task()))) {}
            assertEquals(if (matching) MutationResultStatus.CONFIRMED_SUCCESS else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
            assertEquals(1, f.backend.writes.size)
        }
    }
}
