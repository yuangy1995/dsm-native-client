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
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
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

class DownloadDiscoveryRepositoryTest {
    @Test
    fun `RSS 站点和条目使用公开 v1 固定分页参数`() = runBlocking {
        val transport = DownloadDiscoveryInterceptor(
            """{"success":true,"data":{"total":1,"offset":0,"site":[{"id":6,"url":"https://feed.invalid/rss","username":"","title":"Synthetic feed","is_updating":false,"last_update":1700000000}]}}""",
            """{"success":true,"data":{"total":1,"offset":0,"feeds":[{"title":"Synthetic item","size":"1024","time":1700000001,"download_uri":"https://download.invalid/item.torrent","external_link":"https://page.invalid/item"}]}}""",
        )
        val repository = repository(transport)

        val site = repository.listDownloadRssSites().single()
        val feed = repository.listDownloadRssFeeds(site.id).single()

        assertEquals("6", site.id)
        assertEquals("Synthetic item", feed.title)
        assertEquals(1024L, feed.size)
        assertEquals("1", transport.requests[0].discoveryFields()["version"])
        assertEquals("500", transport.requests[0].discoveryFields()["limit"])
        assertEquals("6", transport.requests[1].discoveryFields()["id"])
    }

    @Test
    fun `BT 搜索只使用已启用模块并在读取完成后清理任务`() = runBlocking {
        val transport = DownloadDiscoveryInterceptor(
            """{"success":true,"data":{"taskid":"synthetic-search"}}""",
            """{"success":true,"data":{"finished":true,"items":[{"title":"Synthetic result","date":"2026-01-01 00:00:00","download_uri":"https://download.invalid/result.torrent","external_link":"https://page.invalid/result","peers":12,"seeds":9,"leechs":3,"size":2048,"module_title":"Synthetic provider"}]}}""",
            """{"success":true,"data":{}}""",
        )

        val result = repository(transport).searchDownloadBt("  synthetic linux  ").single()

        assertEquals("Synthetic result", result.title)
        assertEquals(9, result.seeds)
        assertEquals(
            listOf("start", "list", "clean"),
            transport.requests.map { it.discoveryFields()["method"] },
        )
        val start = transport.requests[0].discoveryFields()
        assertEquals("synthetic linux", start["keyword"])
        assertEquals("enabled", start["module"])
        val list = transport.requests[1].discoveryFields()
        assertEquals("seeds", list["sort_by"])
        assertEquals("desc", list["sort_direction"])
        assertEquals("synthetic-search", transport.requests[2].discoveryFields()["taskid"])
    }

    @Test
    fun `公开能力不完整时 RSS 入口保持关闭`() {
        val repository = repository(DownloadDiscoveryInterceptor(), includeFeed = false)

        assertFalse(repository.supportsDownloadRss())
        assertTrue(repository.supportsDownloadBtSearch())
    }

    @Test
    fun `RSS 刷新固定使用公开 v1 且写前写后回读目标`() = runBlocking {
        val siteResponse =
            """{"success":true,"data":{"total":1,"offset":0,"site":[{"id":6,"url":"https://feed.invalid/rss","username":"","title":"Synthetic feed","is_updating":false,"last_update":1700000000}]}}"""
        val transport = DownloadDiscoveryInterceptor(
            siteResponse,
            """{"success":true,"data":{}}""",
            siteResponse.replace("1700000000", "1700000001"),
        )

        val result = repository(transport).refreshDownloadRssSiteResult("6")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertTrue(result.submitted)
        assertFalse(result.requiresRefresh)
        assertEquals(
            listOf("list", "refresh", "list"),
            transport.requests.map { it.discoveryFields()["method"] },
        )
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "download-station/refresh-rss-site/synthetic-site/request.json",
        )
        val request = transport.requests[1].discoveryFields()
        assertEquals("SYNO.DownloadStation.RSS.Site", request["api"])
        assertEquals("1", request["version"])
        assertEquals("6", request["id"])
    }

    @Test
    fun `RSS 目标已变化时不提交刷新`() = runBlocking {
        val transport = DownloadDiscoveryInterceptor(
            """{"success":true,"data":{"total":0,"offset":0,"site":[]}}""",
        )

        val result = repository(transport).refreshDownloadRssSiteResult("7")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(listOf("list"), transport.requests.map { it.discoveryFields()["method"] })
    }

    @Test
    fun `RSS 刷新提交时断线标记未确认且不自动重放`() = runBlocking {
        val transport = DownloadRssRefreshDisconnectInterceptor()

        val result = repository(transport).refreshDownloadRssSiteResult("6")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
        assertEquals(listOf("list", "refresh"), transport.methods)
    }

    @Test
    fun `RSS 刷新提交成功但回读失败时保持未确认且不重放`() = runBlocking {
        val transport = DownloadDiscoveryInterceptor(
            """{"success":true,"data":{"total":1,"offset":0,"site":[{"id":6,"url":"https://feed.invalid/rss","username":"","title":"Synthetic feed","is_updating":false,"last_update":1700000000}]}}""",
            """{"success":true,"data":{}}""",
            IOException("synthetic RSS readback failure"),
        )

        val result = repository(transport).refreshDownloadRssSiteResult("6")

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.requests.count { it.discoveryFields()["method"] == "refresh" })
    }

    @Test
    fun `RSS 刷新提交后的取消只要求刷新且不重放`() = runBlocking {
        val transport = BlockingDownloadRssRefreshInterceptor()
        val repository = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repository.refreshDownloadRssSiteResult("6").status
        }
        assertTrue(transport.refreshEntered.await(5, TimeUnit.SECONDS))

        worker.cancel()
        transport.releaseRefresh.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.refreshCount.get())
    }

    @Test
    fun `同一 RSS 站点刷新中拒绝重复提交`() = runBlocking {
        val transport = BlockingDownloadRssRefreshInterceptor()
        val repository = repository(transport)
        val first = async(Dispatchers.Default) { repository.refreshDownloadRssSiteResult("6") }
        assertTrue(transport.refreshEntered.await(5, TimeUnit.SECONDS))

        val duplicate = repository.refreshDownloadRssSiteResult("6")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)
        transport.releaseRefresh.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.refreshCount.get())
    }

    private fun repository(
        interceptor: Interceptor,
        includeFeed: Boolean = true,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        buildList {
            add(ApiCapability("SYNO.DownloadStation.RSS.Site", "DownloadStation/RSSsite.cgi", 1, 1))
            if (includeFeed) {
                add(ApiCapability("SYNO.DownloadStation.RSS.Feed", "DownloadStation/RSSfeed.cgi", 1, 1))
            }
            add(ApiCapability("SYNO.DownloadStation.BTSearch", "DownloadStation/btsearch.cgi", 1, 1))
        }.associateBy(ApiCapability::name),
    )
}

private class BlockingDownloadRssRefreshInterceptor : Interceptor {
    val refreshEntered = CountDownLatch(1)
    val releaseRefresh = CountDownLatch(1)
    val refreshCount = AtomicInteger()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (request.discoveryFields()["method"] == "refresh") {
            refreshCount.incrementAndGet()
            refreshEntered.countDown()
            check(releaseRefresh.await(5, TimeUnit.SECONDS)) { "合成 RSS 刷新未获释放" }
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                if (request.discoveryFields()["method"] == "refresh") {
                    """{"success":true,"data":{}}"""
                } else {
                    """{"success":true,"data":{"total":1,"offset":0,"site":[{"id":6,"url":"https://feed.invalid/rss","username":"","title":"Synthetic feed","is_updating":false,"last_update":${1700000000L + refreshCount.get()}}]}}"""
                }.toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private class DownloadRssRefreshDisconnectInterceptor : Interceptor {
    val methods = mutableListOf<String?>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val method = request.discoveryFields()["method"]
        methods += method
        if (method == "refresh") throw IOException("synthetic disconnect")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                """{"success":true,"data":{"total":1,"offset":0,"site":[{"id":6,"url":"https://feed.invalid/rss","username":"","title":"Synthetic feed","is_updating":false,"last_update":1700000000}]}}"""
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private class DownloadDiscoveryInterceptor(vararg responses: Any) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val step = pending.removeFirstOrNull() ?: error("缺少合成 Download Station 发现响应")
        if (step is IOException) throw step
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                (step as String)
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private fun Request.discoveryFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
