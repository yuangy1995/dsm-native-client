package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DsmQuickConnectReferralTest {
    private val globals = setOf("global.quickconnect.to", "global.quickconnect.cn")
    private val online = """
        [{"errno":0,"server":{"ds_state":"CONNECTED"},"service":{"port":5001},
          "smartdns":{"host":"sample.direct.quickconnect.to"}}]
    """.trimIndent()

    @Test
    fun `全球入口转介可跨区域并继续多级查询`() = runBlocking {
        val transport = Transport { request ->
            checkControlRequest(request)
            when (request.url.host) {
                "region.quickconnect.to" -> referral(listOf("region.quickconnect.cn"))
                "region.quickconnect.cn" -> online
                else -> referral(listOf("REGION.QUICKCONNECT.TO", "region.quickconnect.to"))
            }
        }

        val endpoints = resolver(transport).resolve("sample")

        assertEquals(listOf("sample.direct.quickconnect.to"), endpoints.map { it.host })
        assertEquals(globals, transport.hosts.take(2).toSet())
        assertEquals(listOf("region.quickconnect.to", "region.quickconnect.cn"), transport.hosts.drop(2))
    }

    @Test
    fun `拒绝非官方主机和不合法DNS标签且不发出对应请求`() = runBlocking {
        val invalidSites = listOf(
            "attacker.invalid", "global.quickconnect.to.attacker.invalid",
            "https://region.quickconnect.to", "region.quickconnect.to/path",
            "user@region.quickconnect.to", "region.quickconnect.to:443",
            "region.quickconnect.to?query=1", "region.quickconnect.to#fragment",
            ".quickconnect.to", "region..quickconnect.to", "region.quickconnect.to.",
            "-region.quickconnect.to", "region-.quickconnect.to", "bad_label.quickconnect.cn",
            "a".repeat(64) + ".quickconnect.to",
        )
        for (site in invalidSites) {
            val transport = Transport { referral(listOf(site)) }
            expectError(DsmErrorKind.QUICK_CONNECT_INVALID_RESPONSE, resolver(transport))
            assertEquals(site, globals, transport.hosts.toSet())
            assertEquals(2, transport.hosts.size)
        }
    }

    @Test
    fun `转介元素不是字符串时拒绝`() = runBlocking {
        for (site in listOf("null", "42", "{}")) {
            val transport = Transport { "[{\"errno\":4,\"sites\":[$site]}]" }
            expectError(DsmErrorKind.QUICK_CONNECT_INVALID_RESPONSE, resolver(transport))
            assertEquals(2, transport.hosts.size)
        }
    }

    @Test
    fun `循环和重复转介不会超过八个唯一入口`() = runBlocking {
        val sites = globals.toList() + (0..<30).map { "region-$it.quickconnect.to" }
        val transport = Transport { referral(sites + sites) }

        expectError(DsmErrorKind.QUICK_CONNECT_NOT_FOUND, resolver(transport))

        assertEquals(8, transport.hosts.size)
        assertEquals(8, transport.hosts.toSet().size)
        assertEquals((0..<6).map { "region-$it.quickconnect.to" }, transport.hosts.drop(2))
    }

    @Test
    fun `转介回全球入口不会再次查询`() = runBlocking {
        val transport = Transport { referral(globals.toList() + globals.map { it.uppercase() }) }
        expectError(DsmErrorKind.QUICK_CONNECT_NOT_FOUND, resolver(transport))
        assertEquals(globals, transport.hosts.toSet())
        assertEquals(2, transport.hosts.size)
    }

    @Test
    fun `没有转介字段时保留未找到错误`() = runBlocking {
        val transport = Transport { "[{\"errno\":4}]" }
        expectError(DsmErrorKind.QUICK_CONNECT_NOT_FOUND, resolver(transport))
        assertEquals(2, transport.hosts.size)
    }

    @Test
    fun `首个在线但无直连响应不会被其他入口错误覆盖`() = runBlocking {
        var count = 0
        val transport = Transport {
            if (++count == 1) "[{\"errno\":0,\"server\":{\"ds_state\":\"CONNECTED\"}}]"
            else "[{\"errno\":4}]"
        }

        expectError(DsmErrorKind.QUICK_CONNECT_DIRECT_UNAVAILABLE, resolver(transport))

        assertEquals(1, transport.hosts.size)
    }

    @Test
    fun `首个入口网络失败后仍可经另一个入口转介`() = runBlocking {
        var count = 0
        val transport = Transport { request ->
            if (++count == 1) throw IOException("合成网络失败")
            if (request.url.host == "region.quickconnect.cn") online
            else referral(listOf("region.quickconnect.cn"))
        }

        val endpoints = resolver(transport).resolve("sample")

        assertEquals(1, endpoints.size)
        assertEquals(3, transport.hosts.size)
        assertEquals("region.quickconnect.cn", transport.hosts.last())
    }

    @Test
    fun `中继发现沿用区域转介并完成身份核对`() = runBlocking {
        val transport = relayTransport(matchesIdentity = true)

        val endpoint = resolver(transport).requestRelay("sample")

        assertEquals(QuickConnectEndpoint("sample.r1.quickconnect.cn", 443, QuickConnectEndpointKind.RELAY), endpoint)
        assertEquals(listOf("region.quickconnect.cn", "region.quickconnect.cn", "sample.r1.quickconnect.cn"), transport.hosts.drop(2))
    }

    @Test
    fun `区域转介后的中继身份不匹配仍停止且不重试`() = runBlocking {
        val transport = relayTransport(matchesIdentity = false)
        try {
            resolver(transport).requestRelay("sample")
            fail("身份不匹配不得返回中继")
        } catch (error: DsmFailure) {
            assertEquals(DsmErrorKind.QUICK_CONNECT_IDENTITY_MISMATCH, error.kind)
        }
        assertEquals(5, transport.hosts.size)
    }

    @Test
    fun `开始前取消不查询任何入口`() = runBlocking {
        val transport = Transport { online }
        val task = async {
            currentCoroutineContext().cancel()
            resolver(transport).resolve("sample")
        }
        try {
            task.await()
            fail("应传播取消")
        } catch (_: CancellationException) { }
        assertTrue(transport.hosts.isEmpty())
    }

    @Test
    fun `请求期间取消不继续查询其他入口`() = runBlocking {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val transport = Transport {
            started.countDown()
            check(release.await(3, TimeUnit.SECONDS))
            referral(listOf("region.quickconnect.to"))
        }
        val task = async(Dispatchers.Default) { resolver(transport).resolve("sample") }
        try {
            assertTrue(started.await(3, TimeUnit.SECONDS))
            task.cancel()
        } finally {
            release.countDown()
        }
        try {
            task.await()
            fail("应传播取消")
        } catch (_: CancellationException) { }
        assertEquals(1, transport.hosts.size)
    }

    private fun relayTransport(matchesIdentity: Boolean): Transport = Transport { request ->
        if (request.method == "GET") {
            assertEquals("sample.r1.quickconnect.cn", request.url.host)
            val identity = MessageDigest.getInstance("MD5").digest("synthetic-server".toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            "{\"ezid\":\"${if (matchesIdentity) identity else "mismatch"}\"}"
        } else {
            checkControlRequest(request)
            if (request.url.host in globals) referral(listOf("region.quickconnect.cn"))
            else {
                assertEquals("region.quickconnect.cn", request.url.host)
                // 同一受控响应同时支持发现和隧道申请；不会提供直连地址。
                """
                [{"errno":0,"server":{"ds_state":"CONNECTED","serverID":"synthetic-server"},
                  "service":{"relay_ip":"203.0.113.10","relay_port":12345},
                  "env":{"control_host":"region.quickconnect.cn","relay_region":"r1"}}]
                """.trimIndent()
            }
        }
    }

    private fun resolver(transport: Transport) = DsmQuickConnectResolver(
        http = OkHttpClient.Builder().addInterceptor(transport).build(),
    )

    private fun referral(hosts: List<String>) =
        "[{\"errno\":4,\"suberrno\":0,\"sites\":${Json.encodeToString(hosts)}}]"

    private fun checkControlRequest(request: Request) {
        assertEquals("POST", request.method)
        assertEquals("https", request.url.scheme)
        assertEquals("/Serv.php", request.url.encodedPath)
        assertNull(request.url.query)
        for (header in listOf("Cookie", "Authorization", "X-SYNO-TOKEN")) assertNull(request.header(header))
        val body = Buffer().also { request.body!!.writeTo(it) }.readUtf8()
        val commands = Json.parseToJsonElement(body).jsonArray
        val command = commands.single().jsonObject
        assertEquals(setOf("version", "command", "stop_when_error", "stop_when_success", "id", "serverID", "is_gofile", "path"), command.keys)
        assertEquals("sample", command.string("serverID"))
        assertEquals("mainapp_https", command.string("id"))
    }

    private suspend fun expectError(expected: DsmErrorKind, resolver: DsmQuickConnectResolver) {
        try {
            resolver.resolve("sample")
            fail("应返回 $expected")
        } catch (error: DsmFailure) { assertEquals(expected, error.kind) }
    }

    private class Transport(private val response: (Request) -> String) : Interceptor {
        val hosts = mutableListOf<String>()

        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            hosts.add(request.url.host)
            return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200)
                .message("OK").body(response(request).toResponseBody("application/json".toMediaType())).build()
        }
    }
}
