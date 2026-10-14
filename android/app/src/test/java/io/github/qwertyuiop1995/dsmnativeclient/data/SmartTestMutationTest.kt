package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestType
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasStorageDisk
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import okio.BufferedSource
import okio.Buffer
import java.net.URLDecoder
import kotlinx.coroutines.CancellationException
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasSmartAction
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasSmartStage
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.smartIdentity
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SmartTestMutationTest {
    @Test
    fun `快速检测使用预检返回的device且回读运行状态`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(stopped()), ok(), ok(storage()), ok(running("quick")),
        )

        val result = repository(transport).probeSmart(
            disk(), status(), NasDiskTestType.QUICK,
        )

        assertConfirmed(result)
        RequestFixtureAssertions.assertRequest(
            transport.requests[2],
            "storage/start-smart-test/synthetic-disk/request.json",
        )
        assertEquals(
            listOf("load_info", "get_smart_test_log", "do_smart_test", "load_info", "get_smart_test_log"),
            transport.methods(),
        )
        assertEquals("synthetic-device", transport.fields()[2]["device"])
        assertEquals("quick", transport.fields()[2]["type"])
        assertEquals(listOf("1", "1", "1", "1", "1"), transport.versions())
    }

    @Test
    fun `停止检测只在预检确认运行后提交并回读停止`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(running("extend")), ok(), ok(storage()), ok(stopped()),
        )

        val result = repository(transport).probeSmart(
            disk(), status(runningType = NasDiskTestType.EXTENDED), null,
        )

        assertConfirmed(result)
        RequestFixtureAssertions.assertRequest(
            transport.requests[2],
            "storage/stop-smart-test/synthetic-disk/request.json",
        )
        assertEquals("stop", transport.fields()[2]["type"])
    }

    @Test
    fun `其他检测占用时零写请求`() = runBlocking {
        val transport = SmartInterceptor(ok(storage()), ok(otherTestBusy()))

        val result = repository(transport).probeSmart(
            disk(), status(busy = true), NasDiskTestType.EXTENDED,
        )

        assertNotSubmitted(result)
        assertFalse(NasSmartStage.SUBMITTED in result.stages)
        assertTrue(transport.methods().none { it == "do_smart_test" })
    }

    @Test
    fun `提交断线后仅回读确认而不重放`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(stopped()), fail(IOException("synthetic disconnect")),
            ok(storage()), ok(running("extend")),
        )

        val result = repository(transport).probeSmart(
            disk(), status(), NasDiskTestType.EXTENDED,
        )

        assertConfirmed(result)
        assertEquals(1, transport.methods().count { it == "do_smart_test" })
    }

    @Test
    fun `状态读取包含检测历史且历史字段缺失不伪装结果`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(running("quick")),
            ok("""{"testLog":[
                {"test_type":"quick","time":"2026-08-01","result":"normal"},
                {"test_type":"extend","time":"2026-07-01","result":"normal"}
            ]}"""),
        )

        val status = repository(transport).nasSmart.read(disk(), history = true).status

        assertTrue(status.isRunning)
        assertEquals(NasDiskTestType.QUICK, status.runningType)
        assertEquals("2026-08-01", status.lastQuickTest)
        assertEquals("2026-07-01", status.lastExtendedTest)
        assertTrue(status.isHistoryAvailable)
    }

    @Test
    fun `能力范围不含v1时关闭写入口且零请求`() = runBlocking {
        val transport = SmartInterceptor()

        val result = repository(transport, storageMinVersion = 2)
            .probeSmart(disk(), status(), NasDiskTestType.QUICK)

        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (result.failure as DsmFailure).kind)
        assertFalse(NasSmartStage.SUBMITTED in result.stages)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `Storage Disk 最低版本高于v1时零请求关闭`() = runBlocking {
        val transport = SmartInterceptor()

        val result = repository(transport, diskMinVersion = 2)
            .probeSmart(disk(), status(), NasDiskTestType.QUICK)

        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (result.failure as DsmFailure).kind)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `能力范围一至三仍为列表状态与写入明确发送v1`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(stopped()), ok(), ok(storage()), ok(running("quick")),
        )

        val result = repository(
            transport,
            storageMaxVersion = 3,
            diskMaxVersion = 3,
        ).probeSmart(disk(), status(), NasDiskTestType.QUICK)

        assertConfirmed(result)
        assertEquals(listOf("1", "1", "1", "1", "1"), transport.versions())
    }

    @Test
    fun `操作专项状态回读不依赖历史接口`() = runBlocking {
        val transport = SmartInterceptor(ok(storage()), ok(running("quick")))

        val status = repository(transport).nasSmart.read(disk(), history = false).status

        assertTrue(status.isRunning)
        assertFalse(status.isHistoryAvailable)
        assertEquals(listOf("load_info", "get_smart_test_log"), transport.methods())
    }

    @Test
    fun `非法运行与其他检测同时占用基线零请求拒绝`() = runBlocking {
        val transport = SmartInterceptor()
        val invalid = status(runningType = NasDiskTestType.QUICK, busy = true)

        val result = repository(transport).probeSmart(disk(), invalid, null)

        assertEquals(DsmErrorKind.NAS_SMART_CHANGED, (result.failure as DsmFailure).kind)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `温度与健康展示变化不阻断同一稳定硬盘检测`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage(temperature = 32, smartStatus = "warning")), ok(stopped()), ok(),
            ok(storage(temperature = 33, smartStatus = "warning")), ok(running("quick")),
        )

        val result = repository(transport).probeSmart(
            disk(), status(), NasDiskTestType.QUICK,
        )

        assertConfirmed(result)
        assertTrue(NasSmartStage.SUBMITTED in result.stages)
    }

    @Test
    fun `device与检测能力漂移均按目标冲突零写入`() = runBlocking {
        val deviceDrift = SmartInterceptor(ok(storage(deviceId = "changed-device")))
        val capabilityDrift = SmartInterceptor(ok(storage(supportsSmartTest = false)))

        val deviceResult = repository(deviceDrift).probeSmart(
            disk(), status(), NasDiskTestType.QUICK,
        )
        val capabilityResult = repository(capabilityDrift).probeSmart(
            disk(), status(), NasDiskTestType.QUICK,
        )

        listOf(deviceResult, capabilityResult).forEach { result ->
            assertNotSubmitted(result)
            assertEquals(DsmErrorKind.NAS_SMART_CHANGED, (result.failure as DsmFailure).kind)
            assertFalse(NasSmartStage.SUBMITTED in result.stages)
        }
        assertTrue(deviceDrift.methods().none { it == "do_smart_test" })
        assertTrue(capabilityDrift.methods().none { it == "do_smart_test" })
    }

    @Test
    fun `状态基线漂移和目标消失均失败关闭`() = runBlocking {
        val drift = SmartInterceptor(ok(storage()), ok(running("quick")))
        val missing = SmartInterceptor(ok("""{"disks":[]}"""))

        val driftResult = repository(drift).probeSmart(
            disk(), status(), NasDiskTestType.QUICK,
        )
        val missingResult = repository(missing).probeSmart(
            disk(), status(), NasDiskTestType.QUICK,
        )

        assertEquals(DsmErrorKind.NAS_SMART_CHANGED, (driftResult.failure as DsmFailure).kind)
        assertEquals(DsmErrorKind.NAS_SMART_CHANGED, (missingResult.failure as DsmFailure).kind)
        assertTrue(drift.methods().none { it == "do_smart_test" })
        assertTrue(missing.methods().none { it == "do_smart_test" })
    }

    @Test
    fun `启动成功必须回读到请求的检测类型`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(stopped()), ok(),
            ok(storage()), ok(running("extend")),
            ok(storage()), ok("""{"testInfo":[]}"""),
        )

        val result = repository(transport).probeSmart(
            disk(), status(), NasDiskTestType.QUICK,
        )

        assertPending(result)
        assertEquals(1, transport.methods().count { it == "do_smart_test" })
    }

    @Test
    fun `严格状态拒绝空多行对象畸形与testing缺失`() = runBlocking {
        val malformed = listOf(
            """{"testInfo":[]}""",
            """{"testInfo":[{"testing":false},{"testing":false}]}""",
            """{"testInfo":["bad"]}""",
            """{"testInfo":[{"ihm_testing":false}]}""",
            """{"testInfo":[{"testing":"bad"}]}""",
            """{"testInfo":[{"testing":false,"ihm_testing":false}]}""",
            """{"testInfo":[{"testing":false,"perf_testing":false}]}""",
        )

        malformed.forEach { response ->
            val transport = SmartInterceptor(ok(storage()), ok(response))
            val result = repository(transport).probeSmart(
                disk(), status(), NasDiskTestType.QUICK,
            )
            assertNotSubmitted(result)
            assertFalse(NasSmartStage.SUBMITTED in result.stages)
            assertTrue(transport.methods().none { it == "do_smart_test" })
        }
    }

    @Test
    fun `严格状态拒绝同义字段冲突且零写入`() = runBlocking {
        val conflicting = listOf(
            """{"testInfo":[{"testing":false,"is_testing":true,"ihm_testing":false,"perf_testing":false}]}""",
            """{"testInfo":[{"testing":true,"is_testing":true,"ihm_testing":false,"perf_testing":false,"test_type":"quick","testType":"extend"}]}""",
            """{"testInfo":[{"testing":false,"is_testing":false,"ihm_testing":false,"perf_testing":false,"remain":"80%","progress":"70%"}]}""",
            """{"testInfo":[{"testing":false,"is_testing":false,"ihm_testing":false,"perf_testing":false,"latest_test_result":"normal","result":"warning"}]}""",
        )

        conflicting.forEach { response ->
            val transport = SmartInterceptor(ok(storage()), ok(response))

            val result = repository(transport).probeSmart(
                disk(), status(), NasDiskTestType.QUICK,
            )

            assertNotSubmitted(result)
            assertFalse(NasSmartStage.SUBMITTED in result.stages)
            assertTrue(transport.methods().none { it == "do_smart_test" })
        }
    }

    @Test
    fun `明确成功首次回读瞬时异常后仍可确认`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(stopped()), ok(),
            fail(IOException("synthetic readback disconnect")),
            ok(storage()), ok(running("quick")),
        )

        val result = repository(transport).probeSmart(
            disk(), status(), NasDiskTestType.QUICK,
        )

        assertConfirmed(result)
        assertEquals(1, transport.methods().count { it == "do_smart_test" })
        assertEquals(3, transport.methods().count { it == "load_info" })
    }

    @Test
    fun `模糊提交首次回读瞬时异常后仍可确认且不重放`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(stopped()), fail(IOException("synthetic submit disconnect")),
            fail(IOException("synthetic readback disconnect")),
            ok(storage()), ok(running("extend")),
        )

        val result = repository(transport).probeSmart(
            disk(), status(), NasDiskTestType.EXTENDED,
        )

        assertConfirmed(result)
        assertEquals(1, transport.methods().count { it == "do_smart_test" })
        assertEquals(3, transport.methods().count { it == "load_info" })
    }

    @Test
    fun `写后检测能力漂移不得确认成功`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(stopped()), ok(), ok(storage(supportsSmartTest = false)),
        )

        val result = repository(transport).probeSmart(
            disk(), status(), NasDiskTestType.QUICK,
        )

        assertPending(result)
        assertTrue(NasSmartStage.SUBMITTED in result.stages)
        assertEquals(1, transport.methods().count { it == "do_smart_test" })
    }

    @Test
    fun `预检取消零写入并释放硬盘锁`() = runBlocking {
        val transport = SmartInterceptor(
            SmartStep.Cancellation,
            ok(storage()), ok(stopped()), ok(), ok(storage()), ok(running("quick")),
        )
        val repo = repository(transport)

        val cancelled = repo.probeSmart(disk(), status(), NasDiskTestType.QUICK)
        val retry = repo.probeSmart(disk(), status(), NasDiskTestType.QUICK)

        assertTrue(cancelled.failure is CancellationException)
        assertEquals(listOf(NasSmartStage.CANCELLED), cancelled.stages)
        assertFalse(NasSmartStage.SUBMITTED in cancelled.stages)
        assertConfirmed(retry)
        assertEquals(1, transport.methods().count { it == "do_smart_test" })
    }

    @Test
    fun `写入阶段取消保留提交阶段仅主动恢复回读且释放跨动作锁`() = runBlocking {
        val transport = SmartInterceptor(
            ok(storage()), ok(stopped()), SmartStep.Cancellation,
            ok(storage()), ok(running("quick")),
            ok(storage()), ok(running("quick")), ok(), ok(storage()), ok(stopped()),
        )
        val repo = repository(transport)

        val started = repo.probeSmart(disk(), status(), NasDiskTestType.QUICK)
        assertTrue(started.failure is CancellationException)
        assertPending(started)
        assertEquals(listOf("load_info", "get_smart_test_log", "do_smart_test"), transport.methods())
        val recovered = repo.nasSmart.recover(smartIdentity(disk()))
        assertEquals(NasDiskTestType.QUICK, recovered.status.runningType)
        val stopped = repo.probeSmart(disk(), recovered.status, null)

        assertConfirmed(stopped)
        assertEquals(2, transport.methods().count { it == "do_smart_test" })
        assertEquals(4, transport.methods().count { it == "get_smart_test_log" })
    }

    @Test
    fun `快速完整与停止共享同一硬盘原子锁`() = runBlocking {
        val transport = BlockingSmartInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) {
            repo.probeSmart(disk(), status(), NasDiskTestType.QUICK)
        }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.probeSmart(disk(), status(), NasDiskTestType.EXTENDED)

        assertEquals(DsmErrorKind.NAS_SMART_CHANGED, (duplicate.failure as DsmFailure).kind)
        assertFalse(NasSmartStage.SUBMITTED in duplicate.stages)
        transport.allowSubmission.countDown()
        assertConfirmed(first.await())
        assertEquals(1, transport.methods().count { it == "do_smart_test" })
    }

    /** 直接观察当前执行器，不复刻旧 Result 门面的分类与恢复逻辑。 */
    private data class SmartProbe(val stages: List<NasSmartStage>, val failure: Throwable?)
    private suspend fun DsmRepository.probeSmart(
        disk: NasStorageDisk, baseline: NasDiskTestStatus, type: NasDiskTestType?,
    ): SmartProbe {
        val stages = mutableListOf<NasSmartStage>()
        val result = runCatching { nasSmart.perform(disk, baseline, NasSmartAction.from(type), stages::add) }
        return SmartProbe(stages, result.exceptionOrNull())
    }
    private fun assertConfirmed(result: SmartProbe) {
        assertEquals(null, result.failure)
        assertEquals(NasSmartStage.VERIFIED, result.stages.last())
        assertEquals(1, result.stages.count { it == NasSmartStage.SUBMITTED })
    }
    private fun assertNotSubmitted(result: SmartProbe) {
        assertTrue(result.failure != null)
        assertEquals(listOf(NasSmartStage.CANCELLED), result.stages)
    }
    private fun assertPending(result: SmartProbe) {
        assertEquals(1, result.stages.count { it == NasSmartStage.SUBMITTED })
        assertFalse(result.stages.any { it in setOf(NasSmartStage.VERIFIED, NasSmartStage.REJECTED, NasSmartStage.CANCELLED) })
    }

    private fun repository(
        interceptor: Interceptor,
        storageMinVersion: Int = 1,
        diskMinVersion: Int = 1,
        storageMaxVersion: Int = 5,
        diskMaxVersion: Int = 5,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request()
            if (request.smartFields()["api"] == "SYNO.Core.System") {
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
                    .body("""{"success":true,"data":{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}}"""
                        .toResponseBody("application/json".toMediaType())).build()
            } else chain.proceed(request)
        }.addInterceptor(interceptor).build()),
        mapOf(
            "SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 3),
            "SYNO.Storage.CGI.Storage" to ApiCapability(
                "SYNO.Storage.CGI.Storage", "entry.cgi", storageMinVersion, storageMaxVersion,
            ),
            "SYNO.Core.Storage.Disk" to ApiCapability(
                "SYNO.Core.Storage.Disk", "entry.cgi", diskMinVersion, diskMaxVersion,
            ),
        ),
    )

    private fun storage(
        model: String? = null,
        deviceId: String = "synthetic-device",
        supportsSmartTest: Boolean = true,
        temperature: Int = 31,
        smartStatus: String = "normal",
    ): String {
        val modelField = model?.let { "\"model\":\"$it\"," }.orEmpty()
        return """{"disks":[{
        "id":"disk-id","device":"$deviceId","name":"Drive 1",
        $modelField"smart_status":"$smartStatus","smart_test_support":$supportsSmartTest,"temp":$temperature
    }]}"""
    }
    private fun stopped() =
        """{"testInfo":[{"testing":false,"ihm_testing":false,"perf_testing":false}]}"""
    private fun running(type: String) =
        """{"testInfo":[{"testing":true,"ihm_testing":false,"perf_testing":false,"test_type":"$type","remain":"80%"}]}"""
    private fun otherTestBusy() =
        """{"testInfo":[{"testing":false,"ihm_testing":true,"perf_testing":false}]}"""

    private fun disk() = NasStorageDisk(
        id = "disk-id", deviceId = "synthetic-device", name = "Drive 1", model = null,
        status = null, smartStatus = "normal", temperatureCelsius = 31.0,
        supportsSmartTest = true,
    )

    private fun status(
        runningType: NasDiskTestType? = null,
        busy: Boolean = false,
    ) = NasDiskTestStatus(
        diskId = "disk-id",
        isRunning = runningType != null,
        isBusyWithOtherTest = busy,
        runningType = runningType,
        progressDescription = if (runningType != null) "80%" else null,
        lastQuickTest = null,
        lastExtendedTest = null,
        lastResult = null,
        isHistoryAvailable = false,
    )

    private fun ok(data: String = "{}") = SmartStep.Body("""{"success":true,"data":$data}""")
    private fun fail(error: IOException) = SmartStep.Failure(error)
}

private sealed interface SmartStep {
    data class Body(val value: String) : SmartStep
    data class Failure(val error: IOException) : SmartStep
    data object Cancellation : SmartStep
}

private class SmartInterceptor(vararg steps: SmartStep) : Interceptor {
    private val queue = ArrayDeque(steps.toList())
    val requests = CopyOnWriteArrayList<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return when (val step = queue.removeFirstOrNull() ?: error("Unexpected request: ${request.url}")) {
            is SmartStep.Failure -> throw step.error
            SmartStep.Cancellation -> Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(SmartCancellationResponseBody())
                .build()
            is SmartStep.Body -> Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(step.value.toResponseBody("application/json".toMediaType()))
                .build()
        }
    }

    fun fields(): List<Map<String, String>> = requests.map { it.smartFields() }
    fun methods() = fields().map { it["method"].orEmpty() }
    fun versions() = fields().map { it["version"].orEmpty() }
}

private class SmartCancellationResponseBody : ResponseBody() {
    override fun contentType() = "application/json".toMediaType()
    override fun contentLength() = -1L
    override fun source(): BufferedSource =
        throw kotlinx.coroutines.CancellationException("synthetic SMART cancellation")
}

private class BlockingSmartInterceptor : Interceptor {
    val submissionStarted = CountDownLatch(1)
    val allowSubmission = CountDownLatch(1)
    private val requests = CopyOnWriteArrayList<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val method = request.smartFields()["method"]
        if (method == "do_smart_test") {
            submissionStarted.countDown()
            check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待合成 SMART 写请求放行超时" }
        }
        val body = when (method) {
            "load_info" -> """{"success":true,"data":{"disks":[{"id":"disk-id","device":"synthetic-device","name":"Drive 1","smart_status":"normal","smart_test_support":true,"temp":31}]}}"""
            "get_smart_test_log" -> if (submissionStarted.count == 0L) {
                """{"success":true,"data":{"testInfo":[{"testing":true,"ihm_testing":false,"perf_testing":false,"test_type":"quick","remain":"80%"}]}}"""
            } else {
                """{"success":true,"data":{"testInfo":[{"testing":false,"ihm_testing":false,"perf_testing":false}]}}"""
            }
            else -> """{"success":true,"data":{}}"""
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods() = requests.map { it.smartFields()["method"].orEmpty() }
}

private fun Request.smartFields(): Map<String, String> {
    val encoded = Buffer().also { body?.writeTo(it) }.readUtf8()
    return encoded.split('&').associate { field ->
        val pair = field.split('=', limit = 2)
        URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8")
    }
}
