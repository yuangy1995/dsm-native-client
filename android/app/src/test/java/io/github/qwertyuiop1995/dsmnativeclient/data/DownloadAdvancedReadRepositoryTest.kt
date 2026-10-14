package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchModuleScope
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchOptions
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchSort
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
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
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadAdvancedReadRepositoryTest {
    @Test
    fun `BT 搜索目录使用公开 v1 无参数方法并解析强类型条目`() = runBlocking {
        val transport = AdvancedDownloadInterceptor(
            """{"success":true,"data":{"modules":[{"id":"provider-a","title":"Provider A","enabled":true},{"id":"provider-b","title":"Provider B","enabled":false}]}}""",
            """{"success":true,"data":{"categories":[{"id":"_allcat_","title":"All"},{"id":"Books","title":"Books"}]}}""",
        )

        val catalog = repository(transport).loadDownloadBtSearchCatalog()

        assertEquals(listOf("provider-a", "provider-b"), catalog.modules.map { it.id })
        assertTrue(catalog.modules.first().enabled)
        assertEquals(listOf("_allcat_", "Books"), catalog.categories.map { it.id })
        assertEquals(listOf("getModule", "getCategory"), transport.requests.map { it.fields()["method"] })
        RequestFixtureAssertions.assertRequest(
            transport.requests[0],
            "download-station/bt-search-get-modules/synthetic-options/request.json",
        )
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "download-station/bt-search-get-categories/synthetic-options/request.json",
        )
        transport.requests.forEach { request ->
            val fields = request.fields()
            assertEquals("SYNO.DownloadStation.BTSearch", fields["api"])
            assertEquals("1", fields["version"])
            assertEquals(setOf("api", "version", "method", "_sid", "SynoToken"), fields.keys)
        }
    }

    @Test
    fun `BT 搜索目录拒绝重复和畸形标识`() {
        val duplicate = AdvancedDownloadInterceptor(
            """{"success":true,"data":{"modules":[{"id":"provider-a","title":"A","enabled":true},{"id":"provider-a","title":"B","enabled":false}]}}""",
            """{"success":true,"data":{"categories":[]}}""",
        )
        assertThrows(DsmFailure::class.java) {
            runBlocking { repository(duplicate).loadDownloadBtSearchCatalog() }
        }

        val malformed = AdvancedDownloadInterceptor(
            """{"success":true,"data":{"modules":[{"id":"provider,a","title":"A","enabled":true}]}}""",
            """{"success":true,"data":{"categories":[]}}""",
        )
        assertThrows(DsmFailure::class.java) {
            runBlocking { repository(malformed).loadDownloadBtSearchCatalog() }
        }
    }

    @Test
    fun `活动摘要使用公开 Statistic v1 并要求四项非负速率`() = runBlocking {
        val transport = AdvancedDownloadInterceptor(
            """{"success":true,"data":{"speed_download":1024,"speed_upload":12,"emule_speed_download":34,"emule_speed_upload":5}}""",
        )

        val activity = repository(transport).loadDownloadActivity()

        assertEquals(1024L, activity.downloadBytesPerSecond)
        assertEquals(12L, activity.uploadBytesPerSecond)
        assertEquals(34L, activity.emuleDownloadBytesPerSecond)
        assertEquals(5L, activity.emuleUploadBytesPerSecond)
        assertEquals(
            mapOf(
                "api" to "SYNO.DownloadStation.Statistic",
                "version" to "1",
                "method" to "getinfo",
                "_sid" to "synthetic-session",
                "SynoToken" to "synthetic-token",
            ),
            transport.requests.single().fields(),
        )
        RequestFixtureAssertions.assertRequest(
            transport.requests.single(),
            "download-station/read-activity/synthetic-summary/request.json",
        )
    }

    @Test
    fun `活动摘要缺字段或负数时失败且不影响其他请求`() {
        listOf(
            """{"success":true,"data":{"speed_download":1,"speed_upload":2,"emule_speed_download":3}}""",
            """{"success":true,"data":{"speed_download":-1,"speed_upload":2,"emule_speed_download":3,"emule_speed_upload":4}}""",
        ).forEach { response ->
            assertThrows(DsmFailure::class.java) {
                runBlocking {
                    repository(AdvancedDownloadInterceptor(response)).loadDownloadActivity()
                }
            }
        }
    }

    @Test
    fun `高级 BT 搜索发送明确模块类别排序方向和标题过滤并始终清理`() = runBlocking {
        val transport = AdvancedDownloadInterceptor(
            """{"success":true,"data":{"taskid":"search-1"}}""",
            """{"success":true,"data":{"finished":true,"items":[]}}""",
            """{"success":true,"data":{}}""",
        )
        val options = DownloadBtSearchOptions(
            keyword = "  linux  ",
            moduleScope = DownloadBtSearchModuleScope.SELECTED,
            selectedModuleIds = setOf("provider-b", "provider-a"),
            categoryId = "Books",
            sort = DownloadBtSearchSort.SIZE,
            direction = DownloadBtSearchDirection.ASCENDING,
            titleFilter = "  guide  ",
        )

        repository(transport).searchDownloadBt(options)

        assertEquals(listOf("start", "list", "clean"), transport.requests.map { it.fields()["method"] })
        assertEquals("linux", transport.requests[0].fields()["keyword"])
        assertEquals("provider-a,provider-b", transport.requests[0].fields()["module"])
        with(transport.requests[1].fields()) {
            assertEquals("Books", get("filter_category"))
            assertEquals("guide", get("filter_title"))
            assertEquals("size", get("sort_by"))
            assertEquals("asc", get("sort_direction"))
        }
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "download-station/bt-search-list/synthetic-filtered/request.json",
        )
        assertEquals("search-1", transport.requests[2].fields()["taskid"])
    }

    @Test
    fun `BT 搜索读取失败仍清理且非法选项零请求`() {
        val failing = AdvancedDownloadInterceptor(
            """{"success":true,"data":{"taskid":"search-2"}}""",
            IOException("synthetic list failure"),
            """{"success":true,"data":{}}""",
        )
        assertThrows(DsmFailure::class.java) {
            runBlocking { repository(failing).searchDownloadBt(DownloadBtSearchOptions(keyword = "linux")) }
        }
        assertEquals(listOf("start", "list", "clean"), failing.requests.map { it.fields()["method"] })

        val unused = AdvancedDownloadInterceptor()
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking {
                repository(unused).searchDownloadBt(
                    DownloadBtSearchOptions(
                        keyword = "linux",
                        moduleScope = DownloadBtSearchModuleScope.SELECTED,
                    ),
                )
            }
        }
        assertTrue(unused.requests.isEmpty())
    }

    @Test
    fun `公开能力缺失时高级读取入口关闭`() {
        val repository = repository(AdvancedDownloadInterceptor(), includeBt = false, includeStatistic = false)

        assertFalse(repository.supportsDownloadBtSearch())
        assertFalse(repository.supportsDownloadActivity())
    }

    private fun repository(
        interceptor: Interceptor,
        includeBt: Boolean = true,
        includeStatistic: Boolean = true,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        buildList {
            if (includeBt) {
                add(ApiCapability("SYNO.DownloadStation.BTSearch", "DownloadStation/btsearch.cgi", 1, 1))
            }
            if (includeStatistic) {
                add(ApiCapability("SYNO.DownloadStation.Statistic", "DownloadStation/statistic.cgi", 1, 1))
            }
        }.associateBy(ApiCapability::name),
    )
}

private class AdvancedDownloadInterceptor(vararg responses: Any) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val step = pending.removeFirstOrNull() ?: error("缺少合成 Download Station 高级读取响应")
        if (step is IOException) throw step
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body((step as String).toResponseBody("application/json".toMediaType()))
            .build()
    }
}

private fun Request.fields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
