package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import java.util.TimeZone
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasRegionSettingsRepositoryTest {
    @Test fun `设置和校时固定版本有序提交每步重新授权并完整回读`() = runBlocking {
        val f = NasRegionFixture(); val original = f.repository.load()
        val desired = original.copy(dateFormat = "Y/m/d", timeZone = "Asia/Shanghai", isNetworkTimeEnabled = true, timeServers = listOf(" time.example.invalid "))
        val events = mutableListOf<NasRegionCheckpoint>(); var access = 0; f.access = { access++ }
        val result = f.repository.save(f.repository.plan(original, desired)) { events += it }
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(2, result.counts.succeeded)
        assertEquals(listOf("set", "sync"), f.writes.map { it.method }); assertEquals(listOf(3, 2), f.writes.map { it.version })
        assertEquals(2, access); assertEquals(6, events.size)
        assertEquals(setOf("date_format", "time_format", "timezone", "enable_ntp", "server"), f.writes[0].fields.keys)
        assertEquals(JsonArray(listOf(JsonPrimitive("time.example.invalid"))), f.writes[1].fields["servers"])
        assertTrue(f.requests.filter { !it.write }.all { it.version == if (it.method == "get") 3 else 1 })
    }
    @Test fun `未编辑手动时间使用预检新读数但一分钟主动修改一定提交`() = runBlocking {
        val f = NasRegionFixture(); val original = f.repository.load(); f.field("minute", JsonPrimitive(40))
        val result = f.repository.save(f.repository.plan(original, original.copy(dateFormat = "Y/m/d", manualDateTime = null))) {}
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(JsonPrimitive(40), f.writes.single().fields["minute"])
        val current = f.repository.load(); val desired = current.copy(manualDateTime = current.manualDateTime!!.copy(minute = 41))
        val changed = f.repository.save(f.repository.plan(current, desired)) {}
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, changed.status); assertEquals(2, f.writes.size)
        assertEquals(JsonPrimitive(41), f.writes.last().fields["minute"])
    }
    @Test fun `原配置并发变化或目标时区被移除零写入`() = runBlocking {
        for (zoneChange in listOf(false, true)) {
            val f = NasRegionFixture(); val original = f.repository.load()
            val plan = f.repository.plan(original, original.copy(timeZone = "Asia/Shanghai", manualDateTime = null))
            if (zoneChange) f.zones = NasRegionFixture.row("""{"zonedata":[{"value":"UTC","display":"UTC"}]}""")
            else f.field("date_format", JsonPrimitive("d/m/Y"))
            val result = f.repository.save(plan) {}; assertFalse(result.submitted); assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `未知模式时区和服务器类型整组拒绝而不补默认值`() = runBlocking {
        val malformed = listOf("enable_ntp" to JsonPrimitive("other"), "date_format" to JsonPrimitive(7), "server" to JsonArray(emptyList()), "timezone" to JsonPrimitive("unknown"))
        for ((key, value) in malformed) {
            val f = NasRegionFixture(); f.field(key, value)
            try { f.repository.load(); fail("Invalid $key") } catch (e: DsmFailure) { assertEquals(DsmErrorKind.INVALID_RESPONSE, e.kind) }
            assertTrue(f.writes.isEmpty())
        }
        val f = NasRegionFixture(); f.zones = NasRegionFixture.row("""{"zonedata":[{"value":"UTC","display":"UTC"},{"value":"UTC","display":"Duplicate"}]}""")
        try { f.repository.load(); fail() } catch (e: DsmFailure) { assertEquals(DsmErrorKind.INVALID_RESPONSE, e.kind) }
    }
    @Test fun `无效墙上时间不补午夜手动保存零请求网络校时仍可使用`() = runBlocking {
        for ((key, value) in listOf("hour" to JsonPrimitive(2.5), "date" to JsonPrimitive("2026/2/30"), "second" to JsonNull)) {
            val f = NasRegionFixture(); f.field(key, value)
            f.zones = NasRegionFixture.row("""{"zonedata":[{"value":"UTC"}]}""")
            val original = f.repository.load(); assertNull(original.manualDateTime); assertEquals("UTC", original.timeZones.single().displayName)
            val rejected = f.repository.save(f.repository.plan(original, original.copy(dateFormat = "Y/m/d"))) {}
            assertFalse(rejected.submitted); assertEquals(MutationErrorCategory.VALIDATION, rejected.errorCategory); assertTrue(f.writes.isEmpty())
            val network = original.copy(isNetworkTimeEnabled = true, timeServers = listOf("time.example.invalid"))
            val result = f.repository.save(f.repository.plan(original, network)) {}
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(listOf("set", "sync"), f.writes.map { it.method })
            assertFalse(f.writes.first().fields.containsKey("hour"))
        }
    }
    @Test fun `现有未知格式保留但新任意格式无效能力不足零请求`() = runBlocking {
        val f = NasRegionFixture(); f.field("date_format", JsonPrimitive("legacy-format")); val original = f.repository.load()
        val result = f.repository.save(f.repository.plan(original, original.copy(timeFormat = "h:i a", manualDateTime = null))) {}
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(JsonPrimitive("legacy-format"), f.writes.single().fields["date_format"])
        try { f.repository.plan(original, original.copy(dateFormat = "arbitrary")); fail() } catch (e: DsmFailure) { assertEquals(DsmErrorKind.NAS_REGION_INVALID, e.kind) }
        val g = NasRegionFixture(); g.versions = setOf(1, 2)
        try { g.repository.load(); fail() } catch (e: DsmFailure) { assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, e.kind) }
        assertTrue(g.requests.isEmpty())
    }
    @Test fun `丢失保存回执可确认配置但绝不继续校时或冒认手动改时`() = runBlocking {
        for (manual in listOf(false, true)) {
            val f = NasRegionFixture(); val original = f.repository.load(); f.afterWrite = { throw IOException("Synthetic lost receipt") }
            val desired = if (manual) original.copy(manualDateTime = original.manualDateTime!!.copy(minute = 31))
                else original.copy(isNetworkTimeEnabled = true, timeServers = listOf("time.example.invalid"))
            val result = f.repository.save(f.repository.plan(original, desired)) {}
            assertEquals(1, f.writes.size)
            if (manual) { assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status); assertEquals(0, result.counts.succeeded) }
            else { assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(1, result.counts.succeeded); assertEquals(1, result.counts.failed) }
        }
    }
    @Test fun `保存被明确拒绝后不读取同值追认也不继续校时`() = runBlocking {
        val f = NasRegionFixture(); val original = f.repository.load()
        f.afterWrite = { throw DsmFailure(105, "Synthetic permission", "", kind = DsmErrorKind.PERMISSION_DENIED) }
        val result = f.repository.save(f.repository.plan(original, original.copy(isNetworkTimeEnabled = true, timeServers = listOf("time.example.invalid")))) {}
        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status); assertEquals(0, result.counts.succeeded)
        assertEquals("set", f.requests.last().method); assertEquals(1, f.writes.size)
    }
    @Test fun `校时前撤权不再提交且先前设置变化撤回成功`() = runBlocking {
        val f = NasRegionFixture(); val original = f.repository.load(); var access = 0
        f.access = { if (++access == 2) { f.field("date_format", JsonPrimitive("d/m/Y")); throw DsmFailure(105, "Synthetic permission", "", kind = DsmErrorKind.PERMISSION_DENIED) } }
        val result = f.repository.save(f.repository.plan(original, original.copy(isNetworkTimeEnabled = true, timeServers = listOf("time.example.invalid")))) {}
        assertEquals(1, f.writes.size); assertEquals(0, result.counts.succeeded); assertEquals(1, result.counts.unknown)
    }
    @Test fun `独立校时不保存配置且丢失回执仍然未知`() = runBlocking {
        val f = NasRegionFixture(); f.field("enable_ntp", JsonPrimitive("ntp")); f.field("server", JsonPrimitive("time.example.invalid"))
        val original = f.repository.load(); f.afterWrite = { throw IOException("Synthetic lost receipt") }
        val result = f.repository.save(f.repository.plan(original, original, synchronizeOnly = true)) {}
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status); assertEquals(0, result.counts.succeeded)
        assertEquals(listOf("sync"), f.writes.map { it.method })
    }
    @Test fun `写前落盘失败零请求接受回执落盘失败不发下一副作用`() = runBlocking {
        for (stage in listOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED)) {
            val f = NasRegionFixture(); val original = f.repository.load()
            try { f.repository.save(f.repository.plan(original, original.copy(isNetworkTimeEnabled = true, timeServers = listOf("time.example.invalid")))) {
                if (it.stage == stage) throw IOException("Synthetic storage")
            }; fail() } catch (_: IOException) {}
            assertEquals(if (stage == NasServiceStage.SUBMITTED) 0 else 1, f.writes.size)
        }
    }
    @Test fun `取消后不校时配置缺字段不被当成保存完成`() = runBlocking {
        for (cancel in listOf(false, true)) {
            val f = NasRegionFixture(); val original = f.repository.load()
            f.afterWrite = { if (cancel) throw CancellationException("Synthetic cancellation") else f.field("time_format", JsonNull) }
            val result = f.repository.save(f.repository.plan(original, original.copy(isNetworkTimeEnabled = true, timeServers = listOf("time.example.invalid")))) {}
            assertEquals(1, f.writes.size); assertEquals(0, result.counts.succeeded); assertEquals(1, result.counts.unknown)
            assertEquals(if (cancel) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        }
    }
    @Test fun `墙上时间比较不受设备时区或夏令时影响`() {
        val old = TimeZone.getDefault()
        try {
            val clock = NasManualDateTime(2026, 3, 8, 2, 30, 0)
            TimeZone.setDefault(TimeZone.getTimeZone("America/Los_Angeles")); val first = clock.regionSeconds()
            assertEquals(clock, io.github.qwertyuiop1995.dsmnativeclient.ui.nas.parseManualDateTime("2026-03-08", "02:30:00"))
            assertNull(io.github.qwertyuiop1995.dsmnativeclient.ui.nas.parseManualDateTime("0000-03-08", "02:30:00"))
            TimeZone.setDefault(TimeZone.getTimeZone("Asia/Shanghai")); assertEquals(first, clock.regionSeconds()); assertNotNull(first)
            assertNull(clock.copy(month = 2, day = 30).regionSeconds())
        } finally { TimeZone.setDefault(old) }
    }
}
