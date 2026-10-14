package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
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

class DownloadSettingsRepositoryTest {
    @Test
    fun `严格读取基础与计划设置且HTTP FTP使用共享值`() = runBlocking {
        val transport = DownloadSettingsInterceptor(
            basicResponse(autoExtract = true, webFtpLimit = 200),
            scheduleResponse(enabled = true),
        )

        val settings = repository(transport).loadDownloadSettings()

        assertEquals("downloads", settings.defaultDestination)
        assertTrue(settings.autoExtractEnabled)
        assertEquals(200, settings.httpDownloadLimitKb)
        assertEquals(200, settings.ftpDownloadLimitKb)
        assertTrue(settings.scheduleEnabled)
    }

    @Test
    fun `基础设置缺失字段不能默认为零或关闭`() = runBlocking {
        val malformed = """{"success":true,"data":{"default_destination":"downloads"}}"""
        val transport = DownloadSettingsInterceptor(malformed, scheduleResponse())
        val settings = repository(transport).loadDownloadSettings()
        assertEquals(setOf("default_destination", "enabled", "schedule_emule_enabled"), settings.availableFields)
        val result = repository(DownloadSettingsInterceptor()).saveDownloadSettingsResult(
            settings, settings.copy(btDownloadLimitKb = 10))
        assertEquals(MutationResultStatus.UNSUPPORTED, result.status)
        assertFalse(result.submitted)
    }

    @Test
    fun `计划设置缺失字段不能默认为关闭`() = runBlocking {
        val missingEmule = """{"success":true,"data":{"enabled":false}}"""
        val settings = repository(DownloadSettingsInterceptor(basicResponse(), missingEmule)).loadDownloadSettings()
        assertTrue("enabled" in settings.availableFields)
        assertFalse("schedule_emule_enabled" in settings.availableFields)
        val malformed = """{"success":true,"data":{"enabled":"false","emule_enabled":0}}"""
        val invalid = repository(DownloadSettingsInterceptor(basicResponse(), malformed)).loadDownloadSettings()
        assertFalse("enabled" in invalid.availableFields)
        assertFalse("schedule_emule_enabled" in invalid.availableFields)
        assertTrue("bt_max_download" in invalid.availableFields)
    }

    @Test
    fun `HTTP FTP回读不一致不能被折叠成可信共享限速`() = runBlocking {
        val divergent = basicResponse().replace("\"ftp_max_download\":0", "\"ftp_max_download\":1")
        val settings = repository(DownloadSettingsInterceptor(divergent, scheduleResponse())).loadDownloadSettings()
        assertFalse("http_max_download" in settings.availableFields)
        assertFalse("ftp_max_download" in settings.availableFields)
        assertTrue("bt_max_download" in settings.availableFields)
    }

    @Test
    fun `两组件分别差量保存与回读且HTTP FTP保持同值`() = runBlocking {
        val original = baseline()
        val desired = desired().copy(
            btUploadLimitKb = 100,
            ftpDownloadLimitKb = 200,
            nzbDownloadLimitKb = 300,
        )
        val transport = DownloadSettingsInterceptor(
            basicResponse(), scheduleResponse(), success(),
            basicResponse(autoExtract = true, btLimit = 500, btUploadLimit = 100, webFtpLimit = 200, nzbLimit = 300), scheduleResponse(),
            basicResponse(autoExtract = true, btLimit = 500, btUploadLimit = 100, webFtpLimit = 200, nzbLimit = 300), scheduleResponse(), success(),
            basicResponse(autoExtract = true, btLimit = 500, btUploadLimit = 100, webFtpLimit = 200, nzbLimit = 300), scheduleResponse(enabled = true),
        )

        val result = repository(transport).saveDownloadSettingsResult(original, desired)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(2, result.counts.succeeded)
        assertEquals(
            listOf("getinfo", "getconfig", "getconfig", "setserverconfig", "getinfo", "getconfig", "getconfig",
                "getinfo", "getconfig", "getconfig", "setconfig", "getinfo", "getconfig", "getconfig"),
            transport.requests.map { it.settingsFormFields()["method"] },
        )
        val basicWrite = transport.requests.single {
            it.settingsFormFields()["method"] == "setserverconfig"
        }
        assertEquals("200", basicWrite.settingsFormFields()["http_max_download"])
        assertEquals("200", basicWrite.settingsFormFields()["ftp_max_download"])
        RequestFixtureAssertions.assertRequest(
            basicWrite,
            "download-station/save-settings/synthetic-delta/request.json",
        )
        RequestFixtureAssertions.assertRequest(
            transport.requests.single { it.settingsFormFields()["method"] == "setconfig" },
            "download-station/save-schedule/synthetic-delta/request.json",
        )
    }

    @Test
    fun `持锁后二次读取发现baseline漂移时零写入`() = runBlocking {
        val transport = DownloadSettingsInterceptor(
            basicResponse(autoExtract = true),
            scheduleResponse(),
        )

        val result = repository(transport).saveDownloadSettingsResult(baseline(), desired())

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(0, transport.writeCount())
    }

    @Test
    fun `无变化直接拒绝且不读写网络`() = runBlocking {
        val transport = DownloadSettingsInterceptor()

        val result = repository(transport).saveDownloadSettingsResult(baseline(), baseline())

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `只改变基础设置时不提交计划组件`() = runBlocking {
        val original = baseline()
        val desired = original.copy(autoExtractEnabled = true)
        val transport = DownloadSettingsInterceptor(
            basicResponse(), scheduleResponse(), success(),
            basicResponse(autoExtract = true), scheduleResponse(),
        )

        val result = repository(transport).saveDownloadSettingsResult(original, desired)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, transport.requests.count { it.settingsFormFields()["method"] == "setserverconfig" })
        assertEquals(0, transport.requests.count { it.settingsFormFields()["method"] == "setconfig" })
    }

    @Test
    fun `只改变计划设置时不提交基础组件`() = runBlocking {
        val original = baseline()
        val desired = original.copy(scheduleEnabled = true)
        val transport = DownloadSettingsInterceptor(
            basicResponse(), scheduleResponse(), success(),
            basicResponse(), scheduleResponse(enabled = true),
        )

        val result = repository(transport).saveDownloadSettingsResult(original, desired)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(0, transport.requests.count { it.settingsFormFields()["method"] == "setserverconfig" })
        assertEquals(1, transport.requests.count { it.settingsFormFields()["method"] == "setconfig" })
    }

    @Test
    fun `计划提交失败但基础设置已确认时返回部分成功且不重放`() = runBlocking {
        val transport = DownloadSettingsInterceptor(
            basicResponse(), scheduleResponse(), success(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(), failure(105),
        )

        val result = repository(transport).saveDownloadSettingsResult(baseline(), desired())

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.failed)
        assertEquals(1, transport.requests.count { it.settingsFormFields()["method"] == "setserverconfig" })
        assertEquals(1, transport.requests.count { it.settingsFormFields()["method"] == "setconfig" })
    }

    @Test
    fun `计划回读失败保留unknown且不把基础成功压成全部成功`() = runBlocking {
        val transport = DownloadSettingsInterceptor(
            basicResponse(), scheduleResponse(), success(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(), success(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), IOException("synthetic schedule readback failure"),
        )

        val result = repository(transport).saveDownloadSettingsResult(baseline(), desired())

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
    }

    @Test
    fun `第二阶段取消保留基础成功与计划unknown`() = runBlocking {
        val transport = DownloadSettingsInterceptor(
            basicResponse(), scheduleResponse(), success(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(),
            CancellationException("synthetic cancellation during schedule submission"),
        )

        val result = repository(transport).saveDownloadSettingsResult(baseline(), desired())

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.unknown)
        assertEquals(1, transport.requests.count { it.settingsFormFields()["method"] == "setserverconfig" })
        assertEquals(1, transport.requests.count { it.settingsFormFields()["method"] == "setconfig" })
    }

    @Test
    fun `计划预读失败时保持未提交且零写入`() = runBlocking {
        val transport = DownloadSettingsInterceptor(
            basicResponse(),
            IOException("synthetic schedule preflight failure"),
        )

        val result = repository(transport).saveDownloadSettingsResult(
            baseline(),
            baseline().copy(scheduleEnabled = true),
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted)
        assertEquals(0, transport.writeCount())
    }

    @Test
    fun `不支持计划且请求启用计划时提交前关闭`() = runBlocking {
        val transport = DownloadSettingsInterceptor()

        val result = repository(transport, supportsSchedule = false).saveDownloadSettingsResult(
            baseline(),
            baseline().copy(scheduleEnabled = true),
        )

        assertEquals(MutationResultStatus.UNSUPPORTED, result.status)
        assertFalse(result.submitted)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `提交前协程取消时不访问网络`() {
        val transport = DownloadSettingsInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).saveDownloadSettingsResult(baseline(), desired()).status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `设置保存进行中同步拒绝重复提交`() = runBlocking {
        val transport = BlockingDownloadSettingsInterceptor()
        val repo = repository(transport)
        val first = async(Dispatchers.IO) { repo.saveDownloadSettingsResult(baseline(), desired()) }
        assertTrue(transport.submissionStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.saveDownloadSettingsResult(baseline(), desired())
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)

        transport.allowSubmission.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.requests.count { it.settingsFormFields()["method"] == "setserverconfig" })
        assertEquals(1, transport.requests.count { it.settingsFormFields()["method"] == "setconfig" })
    }

    @Test
    fun `基础完成后计划预检漂移仍保留部分成功且不发送计划`() = runBlocking {
        val transport = DownloadSettingsInterceptor(
            basicResponse(), scheduleResponse(), success(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(enabled = true),
        )
        val result = repository(transport).saveDownloadSettingsResult(baseline(), desired())
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertTrue(result.submitted)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.failed)
        assertEquals(0, result.counts.unknown)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertEquals(listOf("setserverconfig"), transport.requests.mapNotNull { it.settingsFormFields()["method"]?.takeIf { it.startsWith("set") } })
    }

    @Test
    fun `基础完成后权限撤销保留结果且后续请求为零`() = runBlocking {
        val transport = DownloadSettingsInterceptor(
            basicResponse(), scheduleResponse(), success(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(),
            basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200), scheduleResponse(),
        )
        transport.managers.addAll(listOf(true, true, false))
        val result = repository(transport).saveDownloadSettingsResult(baseline(), desired())
        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.failed)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertEquals(1, transport.writeCount())
    }

    private fun repository(
        interceptor: Interceptor,
        supportsSchedule: Boolean = true,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        buildList {
            add(ApiCapability("SYNO.DownloadStation.Info", "DownloadStation/info.cgi", 1, 2))
            if (supportsSchedule) {
                add(ApiCapability("SYNO.DownloadStation.Schedule", "DownloadStation/schedule.cgi", 1, 1))
            }
        }.associateBy(ApiCapability::name),
    )

    private fun baseline() = DownloadSettings(defaultDestination = "downloads")

    private fun desired() = DownloadSettings(
        defaultDestination = "downloads",
        autoExtractEnabled = true,
        btDownloadLimitKb = 500,
        httpDownloadLimitKb = 200,
        ftpDownloadLimitKb = 200,
        scheduleEnabled = true,
    )


}

private class DownloadSettingsInterceptor(vararg responses: Any) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val managers = ArrayDeque<Boolean>()
    val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        if (request.settingsFormFields()["method"] == "getinfo") {
            return syntheticResponse(request, """{"success":true,"data":{"is_manager":${managers.removeFirstOrNull() ?: true}}}""")
        }
        val step = pending.removeFirstOrNull() ?: error("缺少合成下载设置响应")
        if (step is Throwable) throw step
        return syntheticResponse(request, step as String)
    }

    fun writeCount(): Int = requests.count {
        it.settingsFormFields()["method"] in setOf("setserverconfig", "setconfig")
    }
}

private class BlockingDownloadSettingsInterceptor : Interceptor {
    val submissionStarted = CountDownLatch(1)
    val allowSubmission = CountDownLatch(1)
    val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())
    private val blocked = AtomicBoolean(false)
    private val basicWritten = AtomicBoolean(false)
    private val scheduleWritten = AtomicBoolean(false)

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val method = request.settingsFormFields()["method"]
        if (method == "setserverconfig" && blocked.compareAndSet(false, true)) {
            submissionStarted.countDown()
            check(allowSubmission.await(2, TimeUnit.SECONDS)) { "等待下载设置保存超时" }
            basicWritten.set(true)
        } else if (method == "setconfig") {
            scheduleWritten.set(true)
        }
        val body = when {
            method == "getinfo" -> """{"success":true,"data":{"is_manager":true}}"""
            method in setOf("setserverconfig", "setconfig") -> success()
            request.url.encodedPath.endsWith("info.cgi") -> if (basicWritten.get()) {
                basicResponse(autoExtract = true, btLimit = 500, webFtpLimit = 200)
            } else {
                basicResponse()
            }
            else -> scheduleResponse(enabled = scheduleWritten.get())
        }
        return syntheticResponse(request, body)
    }
}

private fun syntheticResponse(request: Request, body: String) = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.settingsFormFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}

private fun basicResponse(
    destination: String = "downloads",
    autoExtract: Boolean = false,
    btLimit: Int = 0,
    btUploadLimit: Int = 0,
    webFtpLimit: Int = 0,
    nzbLimit: Int = 0,
) = """{"success":true,"data":{"default_destination":"$destination","emule_enabled":false,"unzip_service_enabled":$autoExtract,"bt_max_download":$btLimit,"bt_max_upload":$btUploadLimit,"http_max_download":$webFtpLimit,"ftp_max_download":$webFtpLimit,"nzb_max_download":$nzbLimit,"emule_max_download":0,"emule_max_upload":0}}"""

private fun scheduleResponse(enabled: Boolean = false) =
    """{"success":true,"data":{"enabled":$enabled,"emule_enabled":false}}"""

private fun success() = """{"success":true,"data":{}}"""

private fun failure(code: Int) = """{"success":false,"error":{"code":$code}}"""
