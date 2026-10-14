package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SynologyPhotosPreviewEventsTest {
    private class Socket(vararg packets: String) : PhotoPreviewSocket {
        val incoming = Channel<String>(Channel.UNLIMITED).apply { packets.forEach { trySend(it) } }
        val sent = mutableListOf<String>()
        var closed = false
        override suspend fun send(text: String) { sent += text }
        override suspend fun receive() = incoming.receive()
        override fun close() { closed = true }
        fun fail(kind: PhotoPreviewEventFailureKind) { incoming.close(PhotoPreviewEventFailure(kind)) }
    }
    private val opened = """0{"sid":"synthetic","pingInterval":25000,"pingTimeout":20000}"""
    private fun completed(id: Long, success: Boolean) = """42["regenerate-preview",{"data":{"idUnit":$id,"success":$success}}]"""

    @Test fun `应用目录同源握手使用官方查询令牌且不携带其他凭据`() {
        val session = DsmSession("p", "synthetic-session", "synthetic token")
        val request = photoPreviewSocketRequest("https://nas.example.invalid:5001/apps/photos/index.cgi", session)
        assertEquals("/apps/photos/FotoSocketIo/socket.io/", request.url.encodedPath)
        assertEquals("https://nas.example.invalid:5001", request.header("Origin"))
        assertEquals("id=synthetic-session", request.header("Cookie"))
        assertEquals(setOf("EIO", "transport", "SynoToken"), request.url.queryParameterNames)
        assertEquals("synthetic token", request.url.queryParameter("SynoToken"))
        assertEquals("4", request.url.queryParameter("EIO")); assertEquals("websocket", request.url.queryParameter("transport"))
        assertNull(request.header("X-SYNO-TOKEN"))
        assertEquals("/FotoSocketIo/socket.io/", photoPreviewSocketRequest("https://nas.example.invalid", session).url.encodedPath)
        assertEquals("/photos/FotoSocketIo/socket.io/", photoPreviewSocketRequest("https://nas.example.invalid/photos/", session).url.encodedPath)
        assertFalse(photoPreviewSocketRequest("https://nas.example.invalid", session.copy(synoToken = null)).url.queryParameterNames.contains("SynoToken"))
    }

    @Test fun `不安全或含用户信息及查询的端点拒绝且错误无原地址`() {
        for (endpoint in listOf("http://nas.example.invalid", "https://user:secret@nas.example.invalid", "https://nas.example.invalid?SynoToken=secret", "https://nas.example.invalid#secret", "bad endpoint")) {
            val error = assertThrows(PhotoPreviewEventFailure::class.java) { photoPreviewSocketRequest(endpoint, DsmSession("p", "s")) }
            assertEquals(PhotoPreviewEventFailureKind.INVALID_ENDPOINT, error.kind)
            assertFalse(error.toString().contains("secret")); assertNull(error.cause)
        }
    }

    @Test fun `严格解析事件编号布尔值握手计时和命名空间`() {
        assertEquals(PhotoPreviewPacket.Opened, PhotoPreviewPacket.decode(opened))
        assertEquals(PhotoPreviewPacket.Connected, PhotoPreviewPacket.decode("""40{"sid":"namespace"}"""))
        assertEquals(PhotoPreviewPacket.Completed(91, false), PhotoPreviewPacket.decode(completed(91, false)))
        for (text in listOf("0{}", """0{"sid":"s","pingInterval":0,"pingTimeout":1}""", """0{"sid":"s","pingInterval":"1","pingTimeout":1}""",
            "40{}", "42[]", "42{}", """42["regenerate-preview",{"data":{"idUnit":"91","success":true}}]""",
            """42["regenerate-preview",{"data":{"idUnit":91,"success":"true"}}]""", completed(0, true), "4".repeat(PhotoPreviewPacket.MAX_BYTES + 1))) {
            assertEquals(PhotoPreviewEventFailureKind.INVALID_FRAME, assertThrows(PhotoPreviewEventFailure::class.java) { PhotoPreviewPacket.decode(text) }.kind)
        }
    }

    @Test fun `订阅先握手后注册心跳只回pong结果只接受同单元`() = runTest {
        val socket = Socket(opened, "2", "40", completed(90, true), "42[\"other\",{}]", "2", completed(91, false))
        val events = SynologyPhotosPreviewEvents({ socket })
        events.subscribe(91)
        assertEquals(listOf("40", "3", PhotoPreviewPacket.registration(91)), socket.sent)
        assertFalse(events.completion()); assertTrue(socket.closed)
        assertEquals("3", socket.sent.last())
    }

    @Test fun `握手中提前结果命名空间或重复开启全部拒绝`() = runTest {
        for (packets in listOf(arrayOf("40"), arrayOf(completed(91, true)), arrayOf(opened, opened))) {
            val socket = Socket(*packets); val events = SynologyPhotosPreviewEvents({ socket })
            val error = failure { events.subscribe(91) }
            assertEquals(PhotoPreviewEventFailureKind.INVALID_FRAME, (error as PhotoPreviewEventFailure).kind)
            assertTrue(socket.closed); assertFalse(socket.sent.any { it.startsWith("42") })
        }
    }

    @Test fun `普通断线只重订同目标最终事件成功且延迟一二三秒`() = runTest {
        val sockets = (0..2).map { Socket(opened, "40").apply { fail(PhotoPreviewEventFailureKind.DISCONNECTED) } } + Socket(opened, "40", completed(91, true))
        var calls = 0; val delays = mutableListOf<Long>()
        val events = SynologyPhotosPreviewEvents({ sockets[calls++] }, reconnectDelay = { delays += it; delay(it) })
        events.subscribe(91); assertTrue(events.completion())
        assertEquals(4, calls); assertEquals(listOf(1_000L, 2_000L, 3_000L), delays)
        assertTrue(sockets.all { it.closed && it.sent == listOf("40", PhotoPreviewPacket.registration(91)) })
    }

    @Test fun `第四次断线不继续重连`() = runTest {
        var calls = 0
        val events = SynologyPhotosPreviewEvents({ calls++; Socket(opened, "40").apply { fail(PhotoPreviewEventFailureKind.DISCONNECTED) } })
        events.subscribe(91)
        assertEquals(PhotoPreviewEventFailureKind.DISCONNECTED, (failure { events.completion() } as PhotoPreviewEventFailure).kind)
        assertEquals(4, calls)
    }

    @Test fun `重连握手期间断线仍受三次限制`() = runTest {
        var calls = 0
        val events = SynologyPhotosPreviewEvents({ calls++; Socket(*(if (calls == 1) arrayOf(opened, "40") else emptyArray())).apply { fail(PhotoPreviewEventFailureKind.DISCONNECTED) } })
        events.subscribe(91)
        assertEquals(PhotoPreviewEventFailureKind.DISCONNECTED, (failure { events.completion() } as PhotoPreviewEventFailure).kind)
        assertEquals(4, calls)
    }

    @Test fun `拒绝与非法帧不重新连接`() = runTest {
        for (frame in listOf("44{}", "42[]", opened, "40")) {
            var calls = 0; val socket = Socket(opened, "40", frame)
            val events = SynologyPhotosPreviewEvents({ calls++; socket })
            events.subscribe(91); assertTrue(failure { events.completion() } is PhotoPreviewEventFailure)
            assertEquals(1, calls); assertTrue(socket.closed)
        }
    }

    @Test fun `总等待时间包含重连延时不会延长`() = runTest {
        var calls = 0; val sockets = mutableListOf<Socket>()
        val events = SynologyPhotosPreviewEvents({ calls++; Socket(opened, "40").apply { fail(PhotoPreviewEventFailureKind.DISCONNECTED); sockets += this } }, timeoutMillis = 2_500)
        events.subscribe(91); val start = currentTime
        assertTrue(failure { events.completion() } is TimeoutCancellationException)
        assertEquals(2_500L, currentTime - start); assertEquals(2, calls); assertTrue(sockets.all { it.closed })
    }

    @Test fun `订阅超时关闭连接且不发注册`() = runTest {
        val socket = Socket(opened); val events = SynologyPhotosPreviewEvents({ socket })
        assertTrue(failure { events.subscribe(91) } is TimeoutCancellationException)
        assertEquals(20_000L, currentTime); assertEquals(listOf("40"), socket.sent); assertTrue(socket.closed)
    }

    @Test fun `取消订阅或等待立即关闭且不能继续生成`() = runTest {
        for (subscribed in listOf(false, true)) {
            val socket = Socket(*(if (subscribed) arrayOf(opened, "40") else emptyArray()))
            val events = SynologyPhotosPreviewEvents({ socket })
            if (subscribed) events.subscribe(91)
            val job = launch { if (subscribed) events.completion() else events.subscribe(91) }
            runCurrent(); job.cancelAndJoin()
            assertTrue(socket.closed)
            assertEquals(PhotoPreviewEventFailureKind.INVALID_STATE, (failure { events.completion() } as PhotoPreviewEventFailure).kind)
        }
    }

    @Test fun `重复订阅和未订阅等待拒绝`() = runTest {
        val socket = Socket(opened, "40"); val events = SynologyPhotosPreviewEvents({ socket })
        assertTrue(failure { events.completion() } is PhotoPreviewEventFailure)
        events.subscribe(91)
        assertTrue(failure { events.subscribe(92) } is PhotoPreviewEventFailure)
        assertEquals(listOf("40", PhotoPreviewPacket.registration(91)), socket.sent)
        events.close()
    }

    private suspend fun failure(block: suspend () -> Unit): Throwable {
        try { block() } catch (error: Throwable) { return error }
        throw AssertionError("应失败")
    }
}
