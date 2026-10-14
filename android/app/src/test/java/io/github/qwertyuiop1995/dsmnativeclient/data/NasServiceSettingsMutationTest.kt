package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasPowerStage

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasPowerAction
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
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

class NasServiceSettingsMutationTest {
    @Test
    fun `关机与重启均先预检且只提交一次无参数动作`() = runBlocking {
        NasPowerAction.entries.forEach { action ->
            val transport = SettingsInterceptor(json(SUCCESS), json(SUCCESS))
            val result = repository(transport, SYSTEM to 3).probePower(action)
            assertEquals(null, result.failure)
            assertEquals(listOf(NasPowerStage.SUBMITTED, NasPowerStage.ACCEPTED), result.stages)
            assertEquals(
                listOf("info", if (action == NasPowerAction.SHUTDOWN) "shutdown" else "reboot"),
                transport.methods(),
            )
            RequestFixtureAssertions.assertRequest(
                transport.requests[1],
                if (action == NasPowerAction.SHUTDOWN) {
                    "system-power/shutdown/synthetic-nas/request.json"
                } else {
                    "system-power/reboot/synthetic-nas/request.json"
                },
            )
            assertEquals(setOf("api", "version", "method", "_sid", "SynoToken"),
                transport.requests[1].fields().keys)
        }
    }

    @Test
    fun `电源动作能力缺失与预检拒绝均零写入`() = runBlocking {
        val unsupportedTransport = SettingsInterceptor()
        val unsupported = repository(unsupportedTransport).probePower(NasPowerAction.SHUTDOWN)
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (unsupported.failure as? DsmFailure)?.kind)
        assertEquals(listOf(NasPowerStage.CANCELLED), unsupported.stages)
        assertTrue(unsupportedTransport.requests.isEmpty())

        val deniedTransport = SettingsInterceptor(json(PERMISSION))
        val denied = repository(deniedTransport, SYSTEM to 3)
            .probePower(NasPowerAction.REBOOT)
        assertEquals(105, (denied.failure as? DsmFailure)?.code)
        assertEquals(listOf(NasPowerStage.CANCELLED), denied.stages)
        assertEquals(listOf("info"), deniedTransport.methods())
    }

    @Test
    fun `电源请求提交断线报告未确认且禁止重放`() = runBlocking {
        val transport = SettingsInterceptor(
            json(SUCCESS), failure(IOException("synthetic power disconnect")),
        )

        val result = repository(transport, SYSTEM to 3)
            .probePower(NasPowerAction.SHUTDOWN)

        assertEquals(listOf(NasPowerStage.SUBMITTED), result.stages)
        assertTrue(result.failure != null)
        assertEquals(1, transport.methods().count { it == "shutdown" })
    }

    @Test
    fun `电源动作无安全回读且成功仅表示请求已接受`() = runBlocking {
        val transport = SettingsInterceptor(json(SUCCESS), json(SUCCESS))

        val result = repository(transport, SYSTEM to 3)
            .probePower(NasPowerAction.SHUTDOWN)

        assertEquals(null, result.failure)
        assertEquals(listOf(NasPowerStage.SUBMITTED, NasPowerStage.ACCEPTED), result.stages)
        assertEquals(listOf("info", "shutdown"), transport.methods())
    }

    @Test
    fun `电源请求在途取消保留已提交语义且不重放`() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val transport = SettingsInterceptor(
            json(SUCCESS), blockingJson(SUCCESS, entered, release),
        )
        var result: PowerProbe? = null
        val job = launch(Dispatchers.Default) {
            result = repository(transport, SYSTEM to 3)
                .probePower(NasPowerAction.REBOOT)
        }

        assertTrue(entered.await(5, TimeUnit.SECONDS))
        job.cancel()
        release.countDown()
        job.join()

        assertTrue(result?.failure is kotlinx.coroutines.CancellationException)
        assertEquals(listOf(NasPowerStage.SUBMITTED), result?.stages)
        assertEquals(1, transport.methods().count { it == "reboot" })
    }

    private data class PowerProbe(val stages: List<NasPowerStage>, val failure: Throwable?)
    private suspend fun DsmRepository.probePower(action: NasPowerAction): PowerProbe {
        val stages = mutableListOf<NasPowerStage>()
        val result = runCatching { nasPower.perform(action) { stages += it } }
        return PowerProbe(stages, result.exceptionOrNull())
    }

    private fun repository(interceptor: Interceptor, vararg versions: Pair<String, Int>) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        versions.associate { (name, max) -> name to ApiCapability(name, "entry.cgi", 1, max) },
    )

    companion object {
        const val SYSTEM = "SYNO.Core.System"
        const val SUCCESS = """{"success":true,"data":{}}"""
        const val REGISTERED_SYSTEM = """{"success":true,"data":{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}}"""
        const val PERMISSION = """{"success":false,"error":{"code":105}}"""
    }
}

private sealed interface SettingsStep {
    data class Json(val body: String) : SettingsStep
    data class Failure(val error: IOException) : SettingsStep
    data class BlockingJson(
        val body: String,
        val entered: CountDownLatch,
        val release: CountDownLatch,
    ) : SettingsStep
}

private fun json(value: String): SettingsStep = SettingsStep.Json(value)
private fun failure(value: IOException): SettingsStep = SettingsStep.Failure(value)
private fun blockingJson(
    value: String,
    entered: CountDownLatch,
    release: CountDownLatch,
): SettingsStep = SettingsStep.BlockingJson(value, entered, release)

private class SettingsInterceptor(vararg steps: SettingsStep) : Interceptor {
    private val pending = ArrayDeque(steps.toList())
    val requests = mutableListOf<Request>()
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return when (val step = pending.removeFirstOrNull() ?: error("缺少合成设置响应")) {
            is SettingsStep.Json -> settingsResponse(request, step.body)
            is SettingsStep.Failure -> throw step.error
            is SettingsStep.BlockingJson -> {
                step.entered.countDown()
                check(step.release.await(5, TimeUnit.SECONDS)) { "合成设置请求等待取消超时" }
                settingsResponse(request, step.body)
            }
        }
    }
    fun methods() = requests.map { it.fields()["method"].orEmpty() }
}

private fun settingsResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.fields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
