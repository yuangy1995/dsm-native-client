package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
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

class FavoriteMutationTest {
    @Test
    fun `收藏写入和回读一致时确认成功且请求符合公共Fixture`() = runBlocking {
        val transport = RecordingInterceptor(
            Step.Json("{\"success\":true}"),
            Step.Json(
                "{\"success\":true,\"data\":{\"favorites\":[" +
                    "{\"path\":\"/synthetic\",\"name\":\"Synthetic\"}]}}",
            ),
        )
        val result = repository(transport).addFavoriteResult("/synthetic", "Synthetic")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertFalse(result.requiresRefresh)
        assertEquals(2, transport.requests.size)

        val request = transport.requests.first()
        RequestFixtureAssertions.assertRequest(
            request,
            "file-station/add-favorite/synthetic-location/request.json",
        )
        val body = request.body as FormBody
        val fields = (0 until body.size).associate { body.name(it) to body.value(it) }
        assertEquals("/synthetic", fields["path"])
        assertEquals("Synthetic", fields["name"])
        assertEquals("test-session", fields["_sid"])
        assertEquals("test-token", fields["SynoToken"])
        assertEquals("id=test-session", request.header("Cookie"))
        assertEquals("test-token", request.header("X-SYNO-TOKEN"))
        assertTrue(request.url.encodedPath.endsWith("/webapi/entry.cgi"))
    }

    @Test
    fun `收藏被明确拒绝时返回权限不足`() = runBlocking {
        val result = repository(
            RecordingInterceptor(Step.Json("{\"success\":false,\"error\":{\"code\":105}}")),
        ).addFavoriteResult("/synthetic", "Synthetic")

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertEquals(1, result.counts.failed)
    }

    @Test
    fun `收藏提交网络中断时要求刷新且不自动重试`() = runBlocking {
        val transport = RecordingInterceptor(Step.Failure(IOException("synthetic network failure")))
        val result = repository(transport).addFavoriteResult("/synthetic", "Synthetic")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `收藏提交成功但回读中断时保留未确认状态`() = runBlocking {
        val transport = RecordingInterceptor(
            Step.Json("{\"success\":true}"),
            Step.Failure(IOException("synthetic readback failure")),
        )
        val result = repository(transport).addFavoriteResult("/synthetic", "Synthetic")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, result.counts.unknown)
        assertEquals(2, transport.requests.size)
    }

    @Test
    fun `收藏回读缺少目标时返回确认失败`() = runBlocking {
        val result = repository(
            RecordingInterceptor(
                Step.Json("{\"success\":true}"),
                Step.Json("{\"success\":true,\"data\":{\"favorites\":[]}}"),
            ),
        ).addFavoriteResult("/synthetic", "Synthetic")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.requiresRefresh)
        assertEquals(1, result.counts.failed)
    }

    @Test
    fun `移除收藏后回读不再包含目标时确认成功`() = runBlocking {
        val transport = RecordingInterceptor(
            Step.Json("{\"success\":true}"),
            Step.Json("{\"success\":true,\"data\":{\"favorites\":[]}}"),
        )

        val result = repository(transport).removeFavoriteResult("/synthetic")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals("favoriteRemove", result.operation)
        assertEquals(2, transport.requests.size)
        val submission = transport.requests.first().body as FormBody
        val fields = (0 until submission.size).associate { submission.name(it) to submission.value(it) }
        assertEquals("delete", fields["method"])
        assertEquals("/synthetic", fields["path"])
    }

    @Test
    fun `移除收藏后回读仍包含目标时返回确认失败`() = runBlocking {
        val result = repository(
            RecordingInterceptor(
                Step.Json("{\"success\":true}"),
                Step.Json(
                    "{\"success\":true,\"data\":{\"favorites\":[" +
                        "{\"path\":\"/synthetic\",\"name\":\"Synthetic\"}]}}",
                ),
            ),
        ).removeFavoriteResult("/synthetic")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.requiresRefresh)
    }

    @Test
    fun `移除收藏提交断线保持未确认且不重放`() = runBlocking {
        val transport = RecordingInterceptor(Step.Failure(IOException("synthetic network failure")))

        val result = repository(transport).removeFavoriteResult("/synthetic")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `移除收藏提交成功但回读失败保持未确认`() = runBlocking {
        val transport = RecordingInterceptor(
            Step.Json("{\"success\":true}"),
            Step.Failure(IOException("synthetic readback failure")),
        )

        val result = repository(transport).removeFavoriteResult("/synthetic")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(2, transport.requests.size)
    }

    @Test
    fun `同一路径收藏进行中时拒绝重复提交`() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val transport = RecordingInterceptor(
            Step.BlockedJson("{\"success\":true}", entered, release),
            Step.Json(
                "{\"success\":true,\"data\":{\"favorites\":[" +
                    "{\"path\":\"/synthetic\",\"name\":\"Synthetic\"}]}}",
            ),
        )
        val repository = repository(transport)
        val first = async(Dispatchers.Default) {
            repository.addFavoriteResult("/synthetic", "Synthetic")
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))

        val duplicate = repository.addFavoriteResult("/synthetic", "Synthetic")
        release.countDown()
        val completed = first.await()

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, completed.status)
        assertEquals(2, transport.requests.size)
    }

    @Test
    fun `收藏提交前协程已取消时零请求返回`() {
        val transport = RecordingInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).addFavoriteResult("/synthetic", "Synthetic").status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `收藏写请求在途取消保持提交边界且不重放`() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val transport = RecordingInterceptor(
            Step.BlockedJson("{\"success\":true}", entered, release),
        )
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repository(transport).addFavoriteResult("/synthetic", "Synthetic").status
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))

        worker.cancel()
        release.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `移除收藏提交前协程已取消时零请求返回`() {
        val transport = RecordingInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).removeFavoriteResult("/synthetic").status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `移除收藏写请求在途取消保持提交边界且不重放`() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val transport = RecordingInterceptor(
            Step.BlockedJson("{\"success\":true}", entered, release),
        )
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repository(transport).removeFavoriteResult("/synthetic").status
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))

        worker.cancel()
        release.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.requests.size)
    }

    private fun repository(interceptor: RecordingInterceptor): DsmRepository {
        val client = DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build())
        val capability = ApiCapability(
            name = "SYNO.FileStation.Favorite",
            path = "entry.cgi",
            minVersion = 1,
            maxVersion = 2,
        )
        return authorizedRepository(
            profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
            session = DsmSession("test", "test-session", "test-token"),
            api = client,
            capabilities = mapOf(capability.name to capability),
        )
    }

}

private sealed interface Step {
    data class Json(val body: String) : Step
    data class Failure(val error: IOException) : Step
    data class BlockedJson(
        val body: String,
        val entered: CountDownLatch,
        val release: CountDownLatch,
    ) : Step
}

private class RecordingInterceptor(vararg steps: Step) : Interceptor {
    private val pending = ArrayDeque(steps.toList())
    val requests = mutableListOf<Request>()

    @Synchronized
    private fun next(request: Request): Step {
        requests += request
        return pending.removeFirstOrNull() ?: error("缺少合成响应")
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        return when (val step = next(chain.request())) {
            is Step.Failure -> throw step.error
            is Step.BlockedJson -> {
                step.entered.countDown()
                check(step.release.await(5, TimeUnit.SECONDS)) { "等待测试释放响应超时" }
                response(chain.request(), step.body)
            }
            is Step.Json -> response(chain.request(), step.body)
        }
    }

    private fun response(request: Request, body: String) = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(200)
        .message("OK")
        .body(body.toResponseBody("application/json".toMediaType()))
        .build()
}
