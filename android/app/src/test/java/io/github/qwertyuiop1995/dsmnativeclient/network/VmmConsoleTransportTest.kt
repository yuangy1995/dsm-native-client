package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.junit.Assert.*
import org.junit.Test

class VmmConsoleTransportTest {
    private val policy = VmmConsolePolicy("https://synthetic.invalid:5001/alias", "guest", "Synthetic", "en-us")
    private var allowed = true; private var checks = 0; private var expired = 0
    private var status = 200; private var mime = "text/html"; private var body = "<html><head></head></html>".toByteArray()
    private var tlsFailure = false; private val requests = mutableListOf<Request>()
    private val http = OkHttpClient.Builder().followRedirects(true).addInterceptor { chain ->
        requests += chain.request()
        if (tlsFailure) throw javax.net.ssl.SSLHandshakeException("Synthetic certificate rejected")
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(status).message("Synthetic")
            .header("Content-Security-Policy", "script-src 'self'").header("Location", "https://other.invalid/")
            .body(body.toResponseBody(mime.toMediaType())).build()
    }.build()
    private class SocketFactory : WebSocket.Factory {
        lateinit var listener: WebSocketListener; lateinit var request: Request; lateinit var socket: Socket
        var autoOpen = true; var protocol = "binary"
        override fun newWebSocket(request: Request, listener: WebSocketListener): WebSocket {
            this.request = request; this.listener = listener; socket = Socket(request)
            if (autoOpen) listener.onOpen(socket, Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(101).message("Switching Protocols").header("Sec-WebSocket-Protocol", protocol).build())
            return socket
        }
        class Socket(private val original: Request) : WebSocket {
            var cancelled = false; var queued = 0L; val sent = mutableListOf<ByteString>()
            override fun request() = original
            override fun queueSize() = queued
            override fun send(bytes: ByteString): Boolean { sent += bytes; return !cancelled }
            override fun send(text: String) = false
            override fun close(code: Int, reason: String?) = true
            override fun cancel() { cancelled = true }
        }
    }
    private val sockets = SocketFactory()
    private fun transport() = DsmVmmConsoleTransport(policy, "synthetic-session", http, {
        checks++; if (!allowed) throw DsmFailure(null, "Synthetic owner expired", "", kind = DsmErrorKind.WORKSPACE_CHANGED)
    }, { expired++ }, sockets)
    @Test fun `资源只向原地址携带Cookie并保留服务器CSP`() {
        val transport = transport(); val resource = transport.resource(policy.localDocument)
        assertTrue(resource.text().contains("<head>")); assertEquals("script-src 'self'", resource.serverPolicy)
        val request = requests.single(); assertEquals(policy.document, request.url.toString()); assertEquals("id=synthetic-session", request.header("Cookie"))
        assertFalse(request.url.toString().contains("synthetic-session")); assertNull(request.header("X-SYNO-TOKEN")); assertEquals("no-store", request.header("Cache-Control"))
        transport.close(); assertThrows(VmmConsoleFailure::class.java) { transport.resource(policy.localDocument) }; assertEquals(1, requests.size)
    }
    @Test fun `重定向错类型空内容超限与非UTF8拒绝`() {
        val transport = transport(); status = 302
        assertThrows(VmmConsoleFailure::class.java) { transport.resource(policy.localDocument) }; assertEquals(1, requests.size)
        status = 200; mime = "application/json"; assertThrows(VmmConsoleFailure::class.java) { transport.resource(policy.localDocument) }
        mime = "text/html"; body = ByteArray(0); assertThrows(VmmConsoleFailure::class.java) { transport.resource(policy.localDocument) }
        body = ByteArray(4 * 1024 * 1024 + 1); assertThrows(VmmConsoleFailure::class.java) { transport.resource(policy.localDocument) }
        body = byteArrayOf(0xc3.toByte(), 0x28); assertThrows(VmmConsoleFailure::class.java) { transport.resource(policy.localDocument).text() }
        transport.close()
    }
    @Test fun `权限失效未发请求HTTP拒绝与证书失败不降级`() {
        val denied = transport(); allowed = false; assertThrows(DsmFailure::class.java) { denied.resource(policy.localDocument) }; assertTrue(requests.isEmpty())
        allowed = true; val unauthorized = transport(); status = 403
        assertThrows(DsmFailure::class.java) { unauthorized.resource(policy.localDocument) }; assertEquals(1, expired); assertEquals(VmmConsolePhase.FAILED, unauthorized.phase.value)
        status = 200; tlsFailure = true; val tls = transport()
        assertThrows(javax.net.ssl.SSLHandshakeException::class.java) { tls.resource(policy.localDocument) }; tls.close()
    }
    @Test fun `握手固定来源只用Cookie且禁止二次连接`() = runBlocking {
        val transport = transport(); transport.connect()
        assertEquals("https://synthetic.invalid:5001", sockets.request.header("Origin")); assertEquals("binary", sockets.request.header("Sec-WebSocket-Protocol"))
        assertEquals("id=synthetic-session", sockets.request.header("Cookie")); assertFalse(sockets.request.url.toString().contains("synthetic-session"))
        assertEquals(VmmConsolePhase.CONNECTED, transport.phase.value)
        assertThrows(VmmConsoleFailure::class.java) { runBlocking { transport.connect() } }
        transport.close(); assertTrue(sockets.socket.cancelled); assertEquals(VmmConsolePhase.DISCONNECTED, transport.phase.value)
    }
    @Test fun `二进制按顺序分块读取且输入只发送一次`() = runBlocking {
        val transport = transport(); transport.connect()
        val large = ByteArray(700_000) { (it % 251).toByte() }
        sockets.listener.onMessage(sockets.socket, large.toByteString()); sockets.listener.onMessage(sockets.socket, byteArrayOf(5, 6).toByteString())
        val chunks = listOf(transport.receive(), transport.receive(), transport.receive())
        assertTrue(chunks.all { it.size <= 256 * 1024 }); assertArrayEquals(large, chunks.reduce { a, b -> a + b }); assertArrayEquals(byteArrayOf(5, 6), transport.receive())
        transport.send(byteArrayOf(8, 9)); assertEquals(listOf(byteArrayOf(8, 9).toByteString()), sockets.socket.sent)
        transport.close(); assertThrows(VmmConsoleFailure::class.java) { transport.send(byteArrayOf(1)) }; Unit
    }
    @Test fun `输入和画面队列满立即关闭且不重连`() = runBlocking {
        val output = transport(); output.connect(); sockets.socket.queued = 4L * 1024 * 1024
        assertThrows(VmmConsoleFailure::class.java) { output.send(byteArrayOf(1)) }; assertTrue(sockets.socket.cancelled); assertTrue(sockets.socket.sent.isEmpty())
        val input = transport(); input.connect(); repeat(5) { sockets.listener.onMessage(sockets.socket, byteArrayOf(1).toByteString()) }
        assertEquals(VmmConsolePhase.FAILED, input.phase.value); assertTrue(sockets.socket.cancelled)
        val oversized = transport(); oversized.connect(); assertThrows(VmmConsoleFailure::class.java) { oversized.send(ByteArray(1024 * 1024 + 1)) }; assertTrue(sockets.socket.sent.isEmpty())
    }
    @Test fun `收发前归属变化会清空缓冲关闭连接`() = runBlocking {
        val transport = transport(); transport.connect(); sockets.listener.onMessage(sockets.socket, byteArrayOf(1).toByteString())
        allowed = false; assertThrows(DsmFailure::class.java) { runBlocking { transport.receive() } }; assertTrue(sockets.socket.cancelled)
        assertEquals(VmmConsolePhase.FAILED, transport.phase.value); assertTrue(checks >= 3)
    }
    @Test fun `文本消息错误协议与握手拒绝不作为已连接`() = runBlocking {
        val transport = transport(); transport.connect(); sockets.listener.onMessage(sockets.socket, "unexpected")
        assertEquals(VmmConsolePhase.FAILED, transport.phase.value)
        sockets.protocol = "other"; val protocol = transport(); assertThrows(VmmConsoleFailure::class.java) { runBlocking { protocol.connect() } }
        assertEquals(VmmConsolePhase.FAILED, protocol.phase.value)
        sockets.autoOpen = false; val rejected = transport(); val job = launch { runCatching { rejected.connect() } }; yield()
        sockets.listener.onFailure(sockets.socket, IOException("Synthetic"), Response.Builder().request(sockets.request).protocol(Protocol.HTTP_1_1).code(401).message("Synthetic").build())
        job.join(); assertEquals(1, expired); assertEquals(VmmConsolePhase.FAILED, rejected.phase.value)
    }
    @Test fun `等待连接和接收时取消均能释放连接`() = runBlocking {
        sockets.autoOpen = false; val pending = transport(); val job = launch { pending.connect() }; yield(); job.cancelAndJoin(); assertTrue(sockets.socket.cancelled)
        sockets.autoOpen = true; val transport = transport(); transport.connect(); val read = async { transport.receive() }; yield(); transport.close()
        assertThrows(CancellationException::class.java) { runBlocking { read.await() } }; assertTrue(sockets.socket.cancelled)
    }
}
