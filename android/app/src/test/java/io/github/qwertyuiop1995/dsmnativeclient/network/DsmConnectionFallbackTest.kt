package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class DsmConnectionFallbackTest {
    private val profile = NasProfile("a", "NAS", "fixture-nas", "fixture-account")
    private val control = """[{"errno":0,"server":{"ds_state":"CONNECTED"},"service":{"port":5001},"smartdns":{"lan":["192-168-1-20.fixture-nas.direct.quickconnect.to"],"host":"fixture-nas.direct.quickconnect.to"}}]"""

    @Test fun `局域网拒绝和证书失败都不转公网或中继`() = runBlocking {
        for (failure in listOf(LocalNetworkPermissionException(), javax.net.ssl.SSLHandshakeException("synthetic certificate"))) {
            val seen = mutableListOf<Request>()
            val api = client(seen) { request -> if (request.url.encodedPath == "/Serv.php") control else throw failure }
            val error = runCatching { DsmConnectionResolver(api).discover(profile) }.exceptionOrNull() as DsmFailure
            assertTrue(error.stopsConnectionFallback()); assertEquals(2, seen.size)
            assertEquals("192-168-1-20.fixture-nas.direct.quickconnect.to", seen.last().url.host)
        }
    }

    @Test fun `普通连接失败仍可尝试可信公网候选`() = runBlocking {
        val seen = mutableListOf<Request>()
        val api = client(seen) { request -> when {
            request.url.encodedPath == "/Serv.php" -> control
            request.url.host.startsWith("192-") -> throw IOException("synthetic offline")
            else -> """{"success":true,"data":{}}"""
        } }
        val connected = DsmConnectionResolver(api).discover(profile)
        assertEquals("https://fixture-nas.direct.quickconnect.to", connected.profile.address)
        assertEquals(3, seen.size)
    }

    @Test fun `控制端证书错误不更换官方域名重试`() = runBlocking {
        val seen = mutableListOf<Request>()
        val api = client(seen) { throw javax.net.ssl.SSLHandshakeException("synthetic certificate") }
        val error = runCatching { DsmConnectionResolver(api).discover(profile) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.TLS_UNTRUSTED, error.kind); assertEquals(1, seen.size)
    }

    private fun client(seen: MutableList<Request>, reply: (Request) -> String) = DsmApiClient(
        OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .addInterceptor { chain ->
                val request = chain.request(); synchronized(seen) { seen += request }
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body(reply(request).toResponseBody("application/json".toMediaType())).build()
            }.build())
}
