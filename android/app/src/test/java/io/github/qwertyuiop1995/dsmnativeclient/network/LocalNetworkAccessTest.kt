package io.github.qwertyuiop1995.dsmnativeclient.network

import java.net.InetAddress
import java.net.InetSocketAddress
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.runBlocking
import okhttp3.*
import org.junit.Assert.*
import org.junit.Test

class LocalNetworkAccessTest {
    @Test fun `官方局域网地址范围与公网回环分开`() {
        for (value in listOf("10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.1.1", "169.254.2.1",
            "100.64.0.1", "100.127.255.255", "224.0.0.1", "255.255.255.255", "fe80::1", "fd00::1", "fc00::1", "ff02::1")) {
            assertTrue(value, isLocalNetworkAddress(InetAddress.getByName(value)))
        }
        for (value in listOf("127.0.0.1", "::1", "0.0.0.0", "::", "172.15.255.255", "172.32.0.1",
            "100.63.255.255", "100.128.0.1", "192.0.2.1", "2001:db8::1")) {
            assertFalse(value, isLocalNetworkAddress(InetAddress.getByName(value)))
        }
    }

    @Test fun `拒绝局域网时不发出local名称查询且公网域名解析后也检查地址`() {
        val lookedUp = mutableListOf<String>()
        val dns = LocalNetworkGuard({ false }).dns(object : Dns {
            override fun lookup(hostname: String) = listOf(InetAddress.getByName("192.168.1.2")).also { lookedUp += hostname }
        })
        assertThrows(LocalNetworkPermissionException::class.java) { dns.lookup("nas.LOCAL.") }
        assertTrue(lookedUp.isEmpty())
        assertThrows(LocalNetworkPermissionException::class.java) { dns.lookup("nas.example.invalid") }
        assertEquals(listOf("nas.example.invalid"), lookedUp)
    }

    @Test fun `权限允许或路由排除时不阻止地址解析`() {
        for (guard in listOf(LocalNetworkGuard({ true }), LocalNetworkGuard({ false }, { false }, { false }))) {
            val expected = listOf(InetAddress.getByName("10.1.2.3"))
            assertEquals(expected, guard.dns(object : Dns { override fun lookup(hostname: String) = expected }).lookup("nas.local"))
        }
    }

    @Test fun `IP直接连接在打开套接字前拒绝且无重试或重定向`() {
        val client = LocalNetworkGuard({ false }).applyTo(OkHttpClient.Builder())
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()
        client.socketFactory.createSocket().use { socket ->
            assertThrows(LocalNetworkPermissionException::class.java) { socket.connect(InetSocketAddress("192.168.1.2", 5001)) }
            assertFalse(socket.isConnected)
        }
        assertFalse(client.retryOnConnectionFailure); assertFalse(client.followRedirects); assertFalse(client.followSslRedirects)
    }

    @Test fun `统一传输将权限拒绝和证书失败保留为不可回退原因`() = runBlocking {
        for ((error, kind) in listOf(LocalNetworkPermissionException() to DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED,
            javax.net.ssl.SSLHandshakeException("synthetic certificate") to DsmErrorKind.TLS_UNTRUSTED)) {
            val api = DsmApiClient(OkHttpClient.Builder().addInterceptor { throw error }.build())
            val failure = runCatching { api.discover(NasProfile("a", "NAS", "nas.example.invalid", "a")) }.exceptionOrNull() as DsmFailure
            assertEquals(kind, failure.kind); assertTrue(failure.stopsConnectionFallback())
            assertFalse(failure.isAuthenticationFailure)
        }
    }
}
