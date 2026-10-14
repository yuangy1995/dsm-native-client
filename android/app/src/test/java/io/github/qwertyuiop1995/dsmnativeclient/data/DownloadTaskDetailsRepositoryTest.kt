package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
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
import org.junit.Assert.assertNull
import org.junit.Test

class DownloadTaskDetailsRepositoryTest {
    @Test
    fun `公开任务接口优先并请求完整只读详情`() = runBlocking {
        val transport = DownloadDetailsInterceptor(OFFICIAL_DETAILS)

        val task = repository(transport, includeOfficial = true, includeInternal = true)
            .downloadTaskDetails("task-1")

        val fields = transport.requests.single().downloadDetailsFields()
        assertEquals("SYNO.DownloadStation.Task", fields["api"])
        assertEquals("getinfo", fields["method"])
        assertEquals("task-1", fields["id"])
        assertEquals("detail,transfer,file,tracker,peer", fields["additional"])
        assertEquals("bt", task.type)
        assertEquals("normal", task.priority)
        assertEquals(8, task.totalPeers)
        assertEquals(2, task.connectedSeeders)
        assertEquals("part-a.bin", task.files.single().name)
        assertEquals("high", task.files.single().priority)
        assertEquals("working", task.trackers.single().status)
        assertEquals(4, task.trackers.single().seeds)
        assertEquals("SyntheticClient", task.peers.single().agent)
        assertEquals(0.75, task.peers.single().progress ?: -1.0, 0.0001)
        assertEquals("checksum_error", task.error)
    }

    @Test
    fun `公开接口缺失时内部列表仅请求既有附加字段`() = runBlocking {
        val transport = DownloadDetailsInterceptor(INTERNAL_LIST)

        val task = repository(transport, includeOfficial = false, includeInternal = true)
            .listDownloads().single()

        val fields = transport.requests.single().downloadDetailsFields()
        assertEquals("SYNO.DownloadStation2.Task", fields["api"])
        assertEquals("detail,transfer", fields["additional"])
        assertEquals("Internal task", task.title)
        assertEquals(emptyList<Any>(), task.files)
    }

    @Test
    fun `可选详情字段缺失时保留任务且不虚构错误`() = runBlocking {
        val transport = DownloadDetailsInterceptor(
            """{"success":true,"data":{"tasks":[{"id":"task-2","type":"http","title":"Minimal","status":"waiting","size":"10"}]}}""",
        )

        val task = repository(transport, includeOfficial = true, includeInternal = false)
            .listDownloads().single()

        assertNull(task.error)
        assertNull(task.priority)
        assertEquals(emptyList<Any>(), task.trackers)
        assertEquals(emptyList<Any>(), task.peers)
    }

    private fun repository(
        interceptor: Interceptor,
        includeOfficial: Boolean,
        includeInternal: Boolean,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        buildMap {
            if (includeOfficial) put(
                "SYNO.DownloadStation.Task",
                ApiCapability("SYNO.DownloadStation.Task", "DownloadStation/task.cgi", 1, 1),
            )
            if (includeInternal) put(
                "SYNO.DownloadStation2.Task",
                ApiCapability("SYNO.DownloadStation2.Task", "entry.cgi", 1, 1),
            )
        },
    )

    private companion object {
        const val OFFICIAL_DETAILS = """{"success":true,"data":{"tasks":[{"id":"task-1","type":"bt","title":"Synthetic task","status":"downloading","size":"1000","status_extra":{"error_detail":"checksum_error"},"additional":{"detail":{"destination":"downloads","create_time":"1700000000","priority":" normal ","total_peers":8,"connected_seeders":2,"connected_leechers":1},"transfer":{"size_downloaded":"500","speed_download":100,"speed_upload":5},"file":[{"filename":"part-a.bin","size":"1000","size_downloaded":"500","priority":" high "}],"tracker":[{"url":"https://tracker.example.invalid/announce","status":"working","update_timer":30,"seeds":4,"peers":8}],"peer":[{"address":"192.0.2.10","agent":"SyntheticClient","progress":0.75,"speed_download":90,"speed_upload":4}]}}]}}"""
        const val INTERNAL_LIST = """{"success":true,"data":{"tasks":[{"id":"task-i","title":"Internal task","status":"waiting","additional":{"detail":{"destination":"downloads"},"transfer":{"size_downloaded":"0"}}}]}}"""
    }
}

private class DownloadDetailsInterceptor(private val bodyValue: String) : Interceptor {
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(bodyValue.toResponseBody("application/json".toMediaType()))
            .build()
    }
}

private fun Request.downloadDetailsFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
