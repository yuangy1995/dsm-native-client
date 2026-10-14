package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasHardwareRecoveryRepositoryTest {
    private suspend fun NasServiceProtocolFixture.original() = repository().nasServices.load(NasServiceKind.HARDWARE) as NasServiceValue.Hardware
    private fun NasServiceValue.Hardware.changeAll() = copy(settings = settings.copy(restartsAfterPowerFailure = true, ledBrightness = 4,
        fanMode = "fullfan", isVolumeFailureAlertEnabled = false, isWakeUpLogEnabled = true,
        ups = settings.ups!!.copy(isEnabled = true, mode = "SLAVE", networkServerAddress = "synthetic-ups.invalid")))
    private fun rejected(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) {} }
    @Test fun `FORM和JSON六组七请求只写变化字段且亮度与应用分别接受`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            val f = NasServiceProtocolFixture(); f.requestFormat = format; val repo = f.repository()
            val original = f.original(); val desired = original.changeAll(); val events = mutableListOf<NasServiceCheckpoint>()
            val result = repo.nasServices.save(repo.nasServices.plan(original, desired)) { events += it }
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(7, result.counts.succeeded)
            assertEquals(listOf("set", "set_current_brightness", "update", "set", "set", "set", "set"), f.backend.writes.map { it.method })
            assertTrue(f.backend.writes.all { it.version == 1 }); assertEquals(7, f.requests.count { it.body?.isOneShot() == true })
            assertEquals(mapOf("led_brightness" to JsonPrimitive(4)), f.backend.writes[1].fields); assertTrue(f.backend.writes[2].fields.isEmpty())
            assertEquals(mapOf("volume_or_cache_crash" to JsonPrimitive(false)), f.backend.writes[4].fields)
            assertEquals(mapOf("enable_log" to JsonPrimitive(true)), f.backend.writes[5].fields)
            assertEquals(setOf("enable", "mode", "delay_time", "net_server_ip"), f.backend.writes[6].fields.keys)
            assertEquals(setOf(NasServiceStep.LED_BRIGHTNESS, NasServiceStep.LED_UPDATE), events.filter { it.stage == NasServiceStage.ACCEPTED && it.step.requiresAcceptance }.map { it.step }.toSet())
        }
    }
    @Test fun `支持位关闭不提供编辑值且风扇位标记决定实际选择`() = runBlocking {
        val f = NasServiceProtocolFixture()
        f.backend.rows[NasServiceStep.BEEP] = NasServiceSettingsFixture.row("""{"fan_fail":true,"support_fan_fail":false,"volume_crash":true,"support_volume_crash":false,"poweron_beep":false}""")
        val original = f.original(); assertNull(original.settings.isFanFailureAlertEnabled); assertNull(original.settings.isVolumeFailureAlertEnabled)
        assertEquals(false, original.settings.isPowerOnSoundEnabled)
        rejected { f.repository().nasServices.plan(original, original.copy(settings = original.settings.copy(isFanFailureAlertEnabled = false))) }
        for ((raw, expected) in listOf(
            """{"cool_fan":"yes","fan_type":15,"dual_fan_speed":"quietfan"}""" to listOf("fullfan", "coolfan", "quietfan", "quietstopfan"),
            """{"cool_fan":"single","fan_type":15,"dual_fan_speed":"quietfan"}""" to listOf("fullfan", "quietfan"),
            """{"cool_fan":"no","dual_fan_speed":"highfan"}""" to listOf("highfan", "lowfan"))) {
            f.backend.rows[NasServiceStep.FAN] = NasServiceSettingsFixture.row(raw); assertEquals(expected, f.original().settings.supportedFanModes)
        }
        f.backend.rows[NasServiceStep.FAN] = NasServiceSettingsFixture.row("""{"dual_fan_speed":"future-mode"}""")
        val unknown = f.original(); assertEquals("future-mode", unknown.settings.fanMode); assertNull(unknown.settings.supportedFanModes)
        rejected { f.repository().nasServices.plan(unknown, unknown.copy(settings = unknown.settings.copy(fanMode = "fullfan"))) }
        assertTrue(f.backend.writes.isEmpty())
    }
    @Test fun `范围支持模式蜂鸣字段或原值漂移阻止整个保存`() = runBlocking {
        for (change in listOf("range", "fan", "beep", "value")) {
            val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original(); val plan = repo.nasServices.plan(original, original.changeAll())
            when (change) {
                "range" -> f.backend.ledRange = NasServiceSettingsFixture.row("""{"min":0,"max":4}""")
                "fan" -> f.backend.rows[NasServiceStep.FAN] = NasServiceSettingsFixture.row("""{"dual_fan_speed":"quietfan","cool_fan":"single","fan_type":15}""")
                "beep" -> f.backend.rows[NasServiceStep.BEEP] = NasServiceSettingsFixture.row("""{"fan_fail":false,"volume_crash":true,"poweron_beep":false,"poweroff_beep":false,"reset_beep":false}""")
                "value" -> f.backend.rows[NasServiceStep.HIBERNATION] = JsonObject(f.backend.rows.getValue(NasServiceStep.HIBERNATION) + ("enable_log" to JsonPrimitive(true)))
            }
            assertFalse(repo.nasServices.save(plan) {}.submitted); assertTrue(f.backend.writes.isEmpty())
        }
    }
    @Test fun `UPS缺失字段不能补写可信空值可以修改或清空`() = runBlocking {
        val f = NasServiceProtocolFixture(); var repo = f.repository(); var original = f.original()
        var desired = original.copy(settings = original.settings.copy(ups = original.settings.ups!!.copy(networkServerAddress = "synthetic-ups.invalid")))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.nasServices.save(repo.nasServices.plan(original, desired)) {}.status)
        original = f.original(); desired = original.copy(settings = original.settings.copy(ups = original.settings.ups!!.copy(networkServerAddress = "")))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, repo.nasServices.save(repo.nasServices.plan(original, desired)) {}.status)
        assertEquals(JsonPrimitive(""), f.backend.writes.last().fields["net_server_ip"])
        f.backend.rows[NasServiceStep.UPS] = NasServiceSettingsFixture.row("""{"enable":false,"mode":"USB"}""")
        repo = f.repository(); original = f.original(); desired = original.copy(settings = original.settings.copy(ups = original.settings.ups!!.copy(networkServerAddress = "synthetic-ups.invalid")))
        rejected { repo.nasServices.plan(original, desired) }; assertEquals(2, f.backend.writes.size)
    }
    @Test fun `亮度任一步回执丢失不能用暂存值宣布全部成功或续发未知请求`() = runBlocking {
        for (method in listOf("set_current_brightness", "update")) {
            val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original()
            f.backend.afterWrite = { if (it.method == method) throw IOException("Synthetic lost acknowledgement") }
            val desired = original.copy(settings = original.settings.copy(ledBrightness = 4))
            val result = repo.nasServices.save(repo.nasServices.plan(original, desired)) {}
            assertEquals(if (method == "update") MutationResultStatus.PARTIAL_SUCCESS else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
            assertEquals(if (method == "update") 2 else 1, f.backend.writes.size)
            assertEquals(1, result.counts.unknown)
        }
    }
    @Test fun `LED后续明确拒绝不会被相同亮度覆盖且不发风扇等后组`() = runBlocking {
        val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original()
        f.backend.afterWrite = { if (it.method == "update") f.writeRejectionCode = 105 }
        val result = repo.nasServices.save(repo.nasServices.plan(original, original.changeAll())) {}
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(2, result.counts.succeeded)
        assertEquals(listOf("set", "set_current_brightness", "update"), f.backend.writes.map { it.method })
    }
    @Test fun `最后硬件组使亮度改变后撤销两步完整成功`() = runBlocking {
        val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original()
        f.backend.afterWrite = { if (it.step == NasServiceStep.UPS) f.backend.rows[NasServiceStep.LED_BRIGHTNESS] = NasServiceSettingsFixture.row("""{"led_brightness":2}""") }
        val result = repo.nasServices.save(repo.nasServices.plan(original, original.changeAll())) {}
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(2, result.counts.unknown); assertEquals(5, result.counts.succeeded)
    }
    @Test fun `缺少固定版本无效亮度UPS及伪造支持范围零写入`() = runBlocking {
        val f = NasServiceProtocolFixture(); val original = f.original(); var repo = f.repository()
        for (settings in listOf(original.settings.copy(ledBrightness = 99), original.settings.copy(ledBrightnessMaximum = 100, ledBrightness = 99), original.settings.copy(fanMode = "invented"), original.settings.copy(ups = original.settings.ups!!.copy(mode = "SLAVE", isEnabled = true)))) {
            rejected { repo.nasServices.plan(original, NasServiceValue.Hardware(settings)) }
        }
        f.backend.versions[NasServiceStep.UPS] = 2..2; repo = f.repository()
        rejected { repo.nasServices.plan(original, original.changeAll()) }; assertTrue(f.backend.writes.isEmpty())
    }
    @Test fun `写入接受记录失败立即停止后续LED应用`() = runBlocking {
        val f = NasServiceProtocolFixture(); val repo = f.repository(); val original = f.original()
        try {
            repo.nasServices.save(repo.nasServices.plan(original, original.copy(settings = original.settings.copy(ledBrightness = 4)))) {
                if (it.stage == NasServiceStage.ACCEPTED) throw DsmFailure(null, "Synthetic storage failure", "", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
            }; fail()
        } catch (error: DsmFailure) { assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, error.kind) }
        assertEquals(listOf("set_current_brightness"), f.backend.writes.map { it.method })
        assertEquals("set_current_brightness", f.backend.requests.last().method)
    }
}
