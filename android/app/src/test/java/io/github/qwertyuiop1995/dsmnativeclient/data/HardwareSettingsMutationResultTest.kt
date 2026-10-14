package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasUpsSettings
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HardwareSettingsMutationResultTest {
    @Test
    fun `正式保存携带完整硬件基线并整体回读`() = runBlocking {
        val transport = HardwareQueueInterceptor(POWER_OFF, SUCCESS, POWER_ON, POWER_ON)
        val original = emptyHardware().copy(restartsAfterPowerFailure = false)

        val result = repository(transport, POWER to 1).saveHardware(
            original, original.copy(restartsAfterPowerFailure = true),
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(listOf("get", "set", "get", "get"), transport.methods())
        assertTrue(transport.versions().all { it == "1" })
    }

    @Test
    fun `完整硬件基线漂移时零写入并报告冲突`() = runBlocking {
        val transport = HardwareQueueInterceptor(POWER_ON)
        val original = emptyHardware().copy(restartsAfterPowerFailure = false)

        val result = repository(transport, POWER to 1).saveHardware(
            original, original.copy(restartsAfterPowerFailure = true),
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(listOf("get"), transport.methods())
    }

    @Test
    fun `缺少计划步骤能力时零请求`() = runBlocking {
        val transport = HardwareQueueInterceptor()
        val original = emptyHardware().copy(restartsAfterPowerFailure = false)

        rejected(DsmErrorKind.FEATURE_UNSUPPORTED) { repository(transport).saveHardware(
            original, original.copy(restartsAfterPowerFailure = true),
        )
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `已支持电源恢复响应缺字段时拒绝为畸形`() = runBlocking {
        val transport = HardwareQueueInterceptor(SUCCESS)

        val error = runCatching {
            repository(transport, POWER to 1).activeHardwareSettings()
        }.exceptionOrNull()

        assertTrue("缺少必需字段时应拒绝响应", error != null)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `蜂鸣器部分可信字段只提交该字段且固定 v1`() = runBlocking {
        val transport = HardwareQueueInterceptor(BEEP_FAN_OFF, SUCCESS, BEEP_FAN_ON, BEEP_FAN_ON)
        val original = emptyHardware().copy(isFanFailureAlertEnabled = false)

        val result = repository(transport, BEEP to 1).saveHardware(
            original, original.copy(isFanFailureAlertEnabled = true),
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals("true", transport.requests[1].hardwareFields()["fan_fail"])
        assertEquals(1, transport.requests[1].hardwareFields().keys.count { it == "fan_fail" })
        assertTrue(transport.versions().all { it == "1" })
    }

    @Test
    fun `蜂鸣器已出现字段类型错误时不猜测当前值`() = runBlocking {
        val transport = HardwareQueueInterceptor(BEEP_BAD)

        val error = runCatching {
            repository(transport, BEEP to 1).activeHardwareSettings()
        }.exceptionOrNull()

        assertTrue("错误字段类型不应被当作空能力", error != null)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `无任何硬件 v1 能力明确归类为版本不支持`() = runBlocking {
        val error = runCatching {
            repository(HardwareQueueInterceptor()).activeHardwareSettings()
        }.exceptionOrNull() as? DsmFailure

        assertEquals(DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED, error?.kind)
    }

    @Test
    fun `UPS 可写子字段缺少可信原始值时正式入口零请求拒绝`() = runBlocking {
        val transport = HardwareQueueInterceptor()
        val original = emptyHardware().copy(
            ups = NasUpsSettings(false, "USB", 60, false, false, null, null),
        )
        val desired = original.copy(
            ups = original.ups?.copy(
                isEnabled = true,
                mode = "SLAVE",
                networkServerAddress = "ups.example.invalid",
            ),
        )

        rejected(DsmErrorKind.NAS_SERVICE_INVALID) { repository(transport, UPS to 1)
            .saveHardware(original, desired)
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `UPS 地址字段明确为空时可从正式入口配置新地址`() = runBlocking {
        val transport = HardwareQueueInterceptor(UPS_OFF, SUCCESS, UPS_ON, UPS_ON)
        val original = emptyHardware().copy(
            ups = NasUpsSettings(false, "USB", 60, false, false, "", ""),
        )
        val desired = original.copy(
            ups = original.ups?.copy(
                isEnabled = true,
                mode = "SLAVE",
                safeModeDelaySeconds = 120,
                shutsDownUpsAfterSafeMode = true,
                networkServerAddress = "ups.example.invalid",
            ),
        )

        val result = repository(transport, UPS to 1)
            .saveHardware(original, desired)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals("ups.example.invalid", transport.requests[1].hardwareFields()["net_server_ip"])
        assertEquals(listOf("get", "set", "get", "get"), transport.methods())
    }

    private suspend fun DsmRepository.saveHardware(original: NasHardwareSettings, desired: NasHardwareSettings): MutationResult =
        nasServices.save(nasServices.plan(NasServiceValue.Hardware(original), NasServiceValue.Hardware(desired))) { }
    private suspend fun rejected(kind: DsmErrorKind, action: suspend () -> Unit) {
        val error = try { action(); error("Expected rejection") } catch (failure: DsmFailure) { failure }; assertEquals(kind, error.kind)
    }

    private fun emptyHardware() = NasHardwareSettings(
        null, null, null, null, null, null, null, null, null, null,
        null, null, null, null, null, null,
    )

    private fun repository(
        interceptor: Interceptor,
        vararg versions: Pair<String, Int>,
    ) = authorizedRepository(
        NasProfile("synthetic", "Synthetic", "https://nas.example.invalid", "operator"),
        DsmSession("synthetic", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            if (chain.request().hardwareFields()["api"] == "SYNO.Core.System") Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .body("""{"success":true,"data":{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}}""".toResponseBody("application/json".toMediaType())).build()
            else chain.proceed(chain.request())
        }.addInterceptor(interceptor).build()),
        versions.associate { (name, max) -> name to ApiCapability(name, "entry.cgi", 1, max) } +
            ("SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 1)),
    )

    private companion object {
        const val POWER = "SYNO.Core.Hardware.PowerRecovery"
        const val BEEP = "SYNO.Core.Hardware.BeepControl"
        const val UPS = "SYNO.Core.ExternalDevice.UPS"
        const val SUCCESS = """{"success":true,"data":{}}"""
        const val POWER_OFF = """{"success":true,"data":{"rc_power_config":false}}"""
        const val POWER_ON = """{"success":true,"data":{"rc_power_config":true}}"""
        const val BEEP_FAN_OFF = """{"success":true,"data":{"fan_fail":false}}"""
        const val BEEP_FAN_ON = """{"success":true,"data":{"fan_fail":true}}"""
        const val BEEP_BAD = """{"success":true,"data":{"fan_fail":{"bad":true}}}"""
        const val UPS_OFF =
            """{"success":true,"data":{"enable":false,"mode":"USB","delay_time":60,"ups_set_safemode_until_lowbatt":false,"shutdown_device":false,"net_server_ip":"","snmp_server_ip":""}}"""
        const val UPS_ON =
            """{"success":true,"data":{"enable":true,"mode":"SLAVE","delay_time":120,"ups_set_safemode_until_lowbatt":false,"shutdown_device":true,"net_server_ip":"ups.example.invalid","snmp_server_ip":""}}"""
    }
}

private class HardwareQueueInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = pending.removeFirstOrNull() ?: error("缺少合成硬件设置响应")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods() = requests.map { it.hardwareFields()["method"].orEmpty() }
    fun versions() = requests.map { it.hardwareFields()["version"].orEmpty() }
}

private fun Request.hardwareFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
