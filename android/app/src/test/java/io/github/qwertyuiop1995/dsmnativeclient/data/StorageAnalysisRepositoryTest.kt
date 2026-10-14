package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageFileCategory
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
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

class StorageAnalysisRepositoryTest {
    @Test
    fun `内容分析按共享类型所有者和时间汇总且重复内容必须经过MD5确认`() = runBlocking {
        val transport = StorageInterceptor(
            shares(),
            task("search-1"),
            files(),
            success(), success(),
            task("md5-1"), checksum("ABCDEF"),
            task("md5-2"), checksum("abcdef"),
        )
        val progress = mutableListOf<String>()

        val result = repository(transport, includeMd5 = true).analyzeStorage { progress += it.phase }

        assertEquals(3, result.scannedFileCount)
        assertEquals(25, result.scannedBytes)
        assertEquals(1, result.shares.size)
        assertEquals("owner-a", result.owners.first().name)
        assertEquals(StorageFileCategory.IMAGE, result.categories.first().category)
        assertEquals("/share/old.jpg", result.leastRecentlyAccessedFiles.first().path)
        assertEquals(1, result.duplicateGroups.size)
        assertEquals(10, result.duplicateGroups.single().reclaimableBytes)
        assertFalse(result.duplicateCheckUnavailable)
        assertTrue("checksums" in progress)
        assertEquals(listOf("start", "list", "stop", "clean"), transport.methods().filter {
            it in setOf("start", "list", "stop", "clean")
        }.take(4))
        assertEquals(listOf("/share/new.jpg", "/share/old.jpg"), transport.md5Paths())
    }

    @Test
    fun `MD5能力缺失时不把同尺寸文件误报为重复内容`() = runBlocking {
        val transport = StorageInterceptor(
            shares(), task("search-1"), files(), success(), success(),
        )

        val result = repository(transport, includeMd5 = false).analyzeStorage()

        assertTrue(result.duplicateCheckUnavailable)
        assertTrue(result.duplicateGroups.isEmpty())
        assertTrue(transport.apis().none { it == "SYNO.FileStation.MD5" })
    }

    @Test
    fun `取消校验任务会停止NAS端任务且不继续轮询`() = runBlocking {
        val transport = StorageInterceptor(task("md5-1"), unfinishedChecksum(), success())
        val repo = repository(transport, includeMd5 = true)

        val job = launch { repo.fileMd5("/share/example.bin") }
        while (transport.requests.size < 2) delay(10)
        job.cancelAndJoin()

        assertEquals(listOf("start", "status", "stop"), transport.methods())
    }

    @Test
    fun `文件时间解析同时保留修改与访问时间`() {
        val page = parseFilePageFixture(
            kotlinx.serialization.json.Json.parseToJsonElement(
                """{"files":[{"path":"/share/a","name":"a","isdir":false,"additional":{"time":{"mtime":20,"atime":10}}}]}""",
            ).jsonObject,
        )

        assertEquals(20L, page.items.single().modifiedAtEpochSeconds)
        assertEquals(10L, page.items.single().accessedAtEpochSeconds)
    }

    private fun repository(interceptor: StorageInterceptor, includeMd5: Boolean) = authorizedRepository(
        profile = NasProfile("profile", "NAS", "https://nas.invalid", "user"),
        session = DsmSession("synthetic", "synthetic", null),
        api = DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        capabilities = buildMap {
            put("SYNO.FileStation.List", capability("SYNO.FileStation.List", 2))
            put("SYNO.FileStation.Search", capability("SYNO.FileStation.Search", 2))
            if (includeMd5) put("SYNO.FileStation.MD5", capability("SYNO.FileStation.MD5", 2))
        },
    )

    private fun capability(name: String, version: Int) = ApiCapability(name, "entry.cgi", 1, version)

    private fun shares() = success(
        """{"shares":[{"path":"/share","name":"share","isdir":true}],"total":1,"offset":0}""",
    )

    private fun files() = success(
        """{"files":[
          {"path":"/share/new.jpg","name":"new.jpg","isdir":false,"additional":{"size":10,"owner":{"user":"owner-a"},"time":{"mtime":30,"atime":20}}},
          {"path":"/share/old.jpg","name":"old.jpg","isdir":false,"additional":{"size":10,"owner":{"user":"owner-a"},"time":{"mtime":20,"atime":10}}},
          {"path":"/share/note.txt","name":"note.txt","isdir":false,"additional":{"size":5,"owner":{"user":"owner-b"},"time":{"mtime":10,"atime":30}}},
          {"path":"/share/#recycle/deleted.jpg","name":"deleted.jpg","isdir":false,"additional":{"size":99}}
        ],"total":4,"offset":0,"finished":true}""",
    )

    private fun task(id: String) = success("""{"taskid":"$id"}""")
    private fun checksum(value: String) = success("""{"finished":true,"md5":"$value"}""")
    private fun unfinishedChecksum() = success("""{"finished":false}""")
    private fun success(data: String = "{}") = """{"success":true,"data":$data}"""
}

private class StorageInterceptor(vararg responses: String) : Interceptor {
    private val queue = ArrayDeque(responses.toList())
    val requests = CopyOnWriteArrayList<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = queue.removeFirstOrNull() ?: error("Unexpected request: ${request.url}")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods(): List<String> = requests.map { it.formFields()["method"].orEmpty() }
    fun apis(): List<String> = requests.map { it.formFields()["api"].orEmpty() }
    fun md5Paths(): List<String> = requests.filter { it.formFields()["api"] == "SYNO.FileStation.MD5" }
        .filter { it.formFields()["method"] == "start" }
        .map { it.formFields()["file_path"].orEmpty() }
}

private fun Request.formFields(): Map<String, String> {
    val form = body as? FormBody ?: return emptyMap()
    return buildMap { repeat(form.size) { put(form.name(it), form.value(it)) } }
}
