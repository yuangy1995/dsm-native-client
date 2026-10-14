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
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteLocationsRepositoryTest {
    @Test
    fun `使用公开虚拟文件夹接口列出远程位置`() = runBlocking {
        val requests = mutableListOf<Map<String, String>>()
        val interceptor = Interceptor { chain ->
            val request = chain.request()
            val form = request.body as FormBody
            requests += (0 until form.size).associate { form.name(it) to form.value(it) }
            Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(
                    """{"success":true,"data":{"offset":0,"total":1,"folders":[{"name":"远程资料","path":"/home/远程资料","isdir":true}]}}"""
                        .toResponseBody("application/json".toMediaType()),
                )
                .build()
        }
        val repository = authorizedRepository(
            NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
            DsmSession("test", "test-session", "test-token"),
            DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
            mapOf(
                "SYNO.FileStation.VirtualFolder" to ApiCapability(
                    "SYNO.FileStation.VirtualFolder",
                    "entry.cgi",
                    1,
                    2,
                ),
            ),
        )

        val page = repository.fileMounts.remoteLocations(0, 200)

        assertEquals("/home/远程资料", page.items.single().path)
        assertEquals("SYNO.FileStation.VirtualFolder", requests.single()["api"])
        assertEquals("all", requests.single()["type"])
    }
}
