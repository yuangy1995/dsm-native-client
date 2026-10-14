package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasServiceProtocolFixture
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 安全与硬件原请求断言迁到当前执行器；参数样本仍核对实际HTTP请求。 */
class NasSecurityHardwareMutationTest {
    private class Context(val fixture: NasServiceProtocolFixture, val repo: DsmRepository, val original: NasServiceValue) {
        val backend get() = fixture.backend
        val security get() = (original as NasServiceValue.Security).settings
        val hardware get() = (original as NasServiceValue.Hardware).settings
        val writes get() = fixture.requests.filter { it.body?.isOneShot() == true }
        suspend fun save(value: NasServiceValue) = repo.nasServices.save(repo.nasServices.plan(original, value)) { }
    }
    private suspend fun context(kind: NasServiceKind, firewall: Boolean = true, legacyBeep: Boolean = false): Context {
        val fixture = NasServiceProtocolFixture().also { it.requestFormat = "FORM" }
        val backend = fixture.backend
        backend.ethernetList = NasServiceSettingsFixture.row("""{"interfaces":[{"id":"eth-synthetic","display":"LAN 1"}]}""")
        backend.rows[NasServiceStep.DOS] = NasServiceSettingsFixture.row("""{"configs":[{"adapter":"eth-synthetic","dos_protect_enable":false}]}""")
        backend.rows[NasServiceStep.FIREWALL] = NasServiceSettingsFixture.row("""{"enable_firewall":$firewall,"profile_name":"synthetic-profile"}""")
        backend.rows[NasServiceStep.BEEP] = JsonObject(backend.rows.getValue(NasServiceStep.BEEP) + ("volume_or_cache_crash" to JsonPrimitive(false)))
        if (legacyBeep) backend.rows[NasServiceStep.BEEP] = JsonObject((backend.rows.getValue(NasServiceStep.BEEP) - "volume_or_cache_crash") + ("volume_crash" to JsonPrimitive(false)))
        val repo = fixture.repository(); val original = repo.nasServices.load(kind)
        fixture.requests.clear(); backend.requests.clear()
        return Context(fixture, repo, original)
    }
    @Test fun `安全设置四个子操作使用固定契约并整体回读`() = runBlocking {
        val ctx = context(NasServiceKind.SECURITY)
        val result = ctx.save(NasServiceValue.Security(ctx.security.copy(isAutoBlockEnabled = true, failedAttempts = 5, withinMinutes = 10, expirationDays = 7,
            dosProtection = ctx.security.dosProtection.map { it.copy(isEnabled = true) }, isPortScanProtectionEnabled = true, isFirewallEnabled = false)))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(4, result.counts.succeeded)
        assertEquals(listOf(NasServiceStep.AUTO_BLOCK, NasServiceStep.DOS, NasServiceStep.FIREWALL_NOTIFICATIONS, NasServiceStep.FIREWALL), ctx.backend.writes.map { it.step })
        listOf("security/set-auto-block/synthetic-settings/request.json", "security/set-dos/synthetic-interface/request.json",
            "security/set-port-scan/synthetic-settings/request.json", "security/disable-firewall/synthetic-settings/request.json")
            .forEachIndexed { i, fixture -> RequestFixtureAssertions.assertRequest(ctx.writes[i], fixture) }
        assertEquals(2, ctx.backend.writes[1].version)
        assertEquals(JsonPrimitive("disable"), ctx.backend.writes[3].fields["set_type"])
    }
    @Test fun `安全设置中途断线后停止后续提交并整体回读`() = runBlocking {
        val ctx = context(NasServiceKind.SECURITY)
        ctx.backend.before = { if (it.write && it.step == NasServiceStep.FIREWALL_NOTIFICATIONS) throw IOException("synthetic port scan timeout") }
        val result = ctx.save(NasServiceValue.Security(ctx.security.copy(isAutoBlockEnabled = true, isPortScanProtectionEnabled = true)))
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(MutationResultCounts(1, 0, 1), result.counts)
        assertEquals(2, ctx.backend.writes.size)
    }
    @Test fun `安全设置提交断网且回读失败不自动重放`() = runBlocking {
        val ctx = context(NasServiceKind.SECURITY)
        ctx.backend.before = { if (it.write || ctx.backend.writes.isNotEmpty()) throw IOException("synthetic disconnect") }
        val result = ctx.save(NasServiceValue.Security(ctx.security.copy(isAutoBlockEnabled = true)))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status); assertEquals(1, result.counts.unknown)
        assertEquals(1, ctx.backend.writes.size)
    }
    @Test fun `开启防火墙只应用原配置档并清理原任务`() = runBlocking {
        val ctx = context(NasServiceKind.SECURITY, firewall = false)
        rejected(DsmErrorKind.NAS_SERVICE_CHANGED) { ctx.save(NasServiceValue.Security(ctx.security.copy(isFirewallEnabled = true, firewallProfileName = "user-must-not-control-this"))) }
        assertTrue(ctx.fixture.requests.isEmpty())
        val result = ctx.save(NasServiceValue.Security(ctx.security.copy(isFirewallEnabled = true)))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        RequestFixtureAssertions.assertRequest(ctx.writes[0], "security/apply-firewall-profile/synthetic-profile/request.json")
        assertEquals(listOf("start", "stop"), ctx.backend.writes.map { it.method })
        val status = ctx.backend.requests.single { it.method == "status" }
        assertEquals(JsonPrimitive("synthetic-firewall-task"), status.fields["task_id"])
        assertEquals(JsonPrimitive("synthetic-profile"), ctx.backend.writes[0].fields["name"])
    }
    @Test fun `安全设置非法阈值与伪造网卡标识零请求拒绝`() = runBlocking {
        val ctx = context(NasServiceKind.SECURITY)
        rejected(DsmErrorKind.NAS_SERVICE_INVALID) { ctx.save(NasServiceValue.Security(ctx.security.copy(failedAttempts = 0))) }
        rejected(DsmErrorKind.NAS_SERVICE_CHANGED) { ctx.save(NasServiceValue.Security(ctx.security.copy(dosProtection = listOf(NasDoSProtectionSetting("eth/unsafe", "Unsafe", true))))) }
        assertTrue(ctx.fixture.requests.isEmpty())
    }
    @Test fun `硬件六组设置分别保存亮度应用并按契约回读`() = runBlocking {
        val ctx = context(NasServiceKind.HARDWARE)
        val result = ctx.save(NasServiceValue.Hardware(ctx.hardware.copy(restartsAfterPowerFailure = true, ledBrightness = 5, fanMode = "coolfan",
            isFanFailureAlertEnabled = true, isVolumeFailureAlertEnabled = true, isPowerOnSoundEnabled = true, isPowerOffSoundEnabled = true, isResetSoundEnabled = true,
            isExternalDriveDeepSleepEnabled = true, isWakeUpLogEnabled = true, isSataSleepEnabled = true, ignoresNetworkDiscoveryDuringSleep = true, isAutomaticPowerOffEnabled = true,
            ups = requireNotNull(ctx.hardware.ups).copy(isEnabled = true, mode = "SLAVE", safeModeDelaySeconds = 120, shutsDownUpsAfterSafeMode = true, networkServerAddress = "ups.example.invalid"))))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status); assertEquals(7, result.counts.succeeded)
        assertEquals(listOf(NasServiceStep.POWER_RECOVERY, NasServiceStep.LED_BRIGHTNESS, NasServiceStep.LED_UPDATE, NasServiceStep.FAN,
            NasServiceStep.BEEP, NasServiceStep.HIBERNATION, NasServiceStep.UPS), ctx.backend.writes.map { it.step })
        RequestFixtureAssertions.assertRequest(ctx.writes[0], "hardware/set-power-recovery/synthetic-settings/request.json")
        RequestFixtureAssertions.assertRequest(ctx.writes[1], "hardware/set-led-brightness/synthetic-settings/request.json")
        RequestFixtureAssertions.assertRequest(ctx.writes[3], "hardware/set-fan-mode/synthetic-settings/request.json")
        assertEquals("update", ctx.backend.writes[2].method)
        assertEquals(JsonPrimitive(true), ctx.backend.writes[4].fields["volume_or_cache_crash"])
        assertEquals(JsonPrimitive(true), ctx.backend.writes[5].fields["ignore_netbios_broadcast"])
        assertEquals(JsonPrimitive("SLAVE"), ctx.backend.writes[6].fields["mode"])
        assertEquals(JsonPrimitive("ups.example.invalid"), ctx.backend.writes[6].fields["net_server_ip"])
    }
    @Test fun `硬件设置中途断线停止后续写入并回读部分成功`() = runBlocking {
        val ctx = context(NasServiceKind.HARDWARE)
        ctx.backend.before = { if (it.write && it.step == NasServiceStep.FAN) throw IOException("synthetic fan timeout") }
        val result = ctx.save(NasServiceValue.Hardware(ctx.hardware.copy(restartsAfterPowerFailure = true, fanMode = "coolfan")))
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status); assertEquals(MutationResultCounts(1, 0, 1), result.counts)
        assertEquals(listOf(NasServiceStep.POWER_RECOVERY, NasServiceStep.FAN), ctx.backend.writes.map { it.step })
    }
    @Test fun `硬件设置写入成功但回读失败保持未确认且不重放`() = runBlocking {
        val ctx = context(NasServiceKind.HARDWARE)
        ctx.backend.before = { if (!it.write && ctx.backend.writes.isNotEmpty()) throw IOException("synthetic readback failure") }
        val result = ctx.save(NasServiceValue.Hardware(ctx.hardware.copy(restartsAfterPowerFailure = true)))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status); assertTrue(result.submitted); assertTrue(result.requiresRefresh)
        assertEquals(1, result.counts.unknown); assertEquals(1, ctx.backend.writes.size)
    }
    @Test fun `硬件设置写请求在途取消停止自动回读且不重放`() = runBlocking {
        val ctx = context(NasServiceKind.HARDWARE); val entered = CountDownLatch(1); val release = CountDownLatch(1)
        ctx.backend.before = { if (it.write) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        var result: MutationResult? = null
        val job = launch(Dispatchers.Default) { result = ctx.save(NasServiceValue.Hardware(ctx.hardware.copy(restartsAfterPowerFailure = true))) }
        assertTrue(entered.await(5, TimeUnit.SECONDS)); job.cancel(); release.countDown(); job.join()
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, result?.status)
        assertTrue(result?.submitted == true); assertTrue(result?.requiresRefresh == true)
        assertEquals(1, result?.counts?.unknown); assertEquals(1, ctx.backend.writes.size); assertTrue(ctx.backend.requests.last().write)
    }
    @Test fun `蜂鸣休眠与UPS独立变更符合公共Fixture`() = runBlocking {
        for (step in listOf(NasServiceStep.BEEP, NasServiceStep.HIBERNATION, NasServiceStep.UPS)) {
            val ctx = context(NasServiceKind.HARDWARE)
            val (value, fixture) = when (step) {
                NasServiceStep.BEEP -> ctx.hardware.copy(isPowerOnSoundEnabled = true) to "hardware/set-beep/synthetic-settings/request.json"
                NasServiceStep.HIBERNATION -> ctx.hardware.copy(isExternalDriveDeepSleepEnabled = true, ignoresNetworkDiscoveryDuringSleep = true) to "hardware/set-hibernation/synthetic-settings/request.json"
                else -> ctx.hardware.copy(ups = requireNotNull(ctx.hardware.ups).copy(isEnabled = true, mode = "SLAVE", safeModeDelaySeconds = 120,
                    shutsDownUpsAfterSafeMode = true, networkServerAddress = "ups.example.invalid")) to "hardware/set-ups/synthetic-settings/request.json"
            }
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, ctx.save(NasServiceValue.Hardware(value)).status)
            RequestFixtureAssertions.assertRequest(ctx.writes.single(), fixture)
            assertEquals(step, ctx.backend.writes.single().step)
        }
    }
    @Test fun `硬件设置拒绝范围外亮度和非法UPS地址且零请求`() = runBlocking {
        val ctx = context(NasServiceKind.HARDWARE)
        for (value in listOf(ctx.hardware.copy(ledBrightness = 99), ctx.hardware.copy(ups = requireNotNull(ctx.hardware.ups).copy(isEnabled = true, mode = "SLAVE", networkServerAddress = "https://ups.example.invalid/path")))) {
            rejected(DsmErrorKind.NAS_SERVICE_INVALID) { ctx.save(NasServiceValue.Hardware(value)) }; assertTrue(ctx.fixture.requests.isEmpty())
        }
    }
    @Test fun `蜂鸣器沿用设备返回的旧音量故障字段`() = runBlocking {
        val ctx = context(NasServiceKind.HARDWARE, legacyBeep = true)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, ctx.save(NasServiceValue.Hardware(ctx.hardware.copy(isVolumeFailureAlertEnabled = true))).status)
        assertEquals(mapOf("volume_crash" to JsonPrimitive(true)), ctx.backend.writes.single().fields)
    }
    private suspend fun rejected(kind: DsmErrorKind, action: suspend () -> Unit) {
        val error = try { action(); error("Expected rejection") } catch (failure: DsmFailure) { failure }; assertEquals(kind, error.kind)
    }
}
