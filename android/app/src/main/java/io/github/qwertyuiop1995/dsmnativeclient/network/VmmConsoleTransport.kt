package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import okhttp3.*
import okio.ByteString
import okio.ByteString.Companion.toByteString

internal enum class VmmConsolePhase { LOADING, CONNECTING, CONNECTED, DISCONNECTED, FAILED }
internal class VmmConsoleResource(val bytes: ByteArray, val mime: String, val serverPolicy: String?) {
    fun text(): String = try { Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString() }
        catch (_: Exception) { consoleFail(VmmConsoleProblem.RESPONSE) }
}
internal interface VmmConsoleTransport {
    val phase: StateFlow<VmmConsolePhase>
    fun resource(local: String): VmmConsoleResource
    suspend fun connect()
    suspend fun receive(): ByteArray
    fun send(bytes: ByteArray)
    fun close(failed: Boolean = false)
}
internal class VmmConsoleSession(val policy: VmmConsolePolicy, val transport: VmmConsoleTransport) {
    override fun toString() = "VmmConsoleSession"
}

/** 凭据只加入原生请求；禁止缓存、重定向、自动重连和任意目的地址。 */
internal class DsmVmmConsoleTransport(private val policy: VmmConsolePolicy, sid: String, http: OkHttpClient,
    private val authorize: () -> Unit, private val onAccessFailure: () -> Unit,
    private val webSockets: WebSocket.Factory? = null) : VmmConsoleTransport {
    private val client = http.newBuilder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).cache(null).cookieJar(CookieJar.NO_COOKIES).build()
    private val lock = Any(); private var credential: String? = sid
    private var closed = false; private var connecting = false; private var socket: WebSocket? = null
    private val calls = mutableSetOf<Call>(); private val opened = CompletableDeferred<Unit>()
    private val frames = Channel<ByteString>(4); private val reader = Mutex()
    private var buffered = 0L; private var current: ByteString? = null; private var offset = 0
    private val mutable = MutableStateFlow(VmmConsolePhase.LOADING); override val phase = mutable.asStateFlow()
    init { if (sid.isEmpty() || sid.any { it.code !in 0x21..0x7e || it in "\";,\\" }) consoleFail(VmmConsoleProblem.TARGET) }
    private fun checkAccess() {
        try { authorize(); synchronized(lock) { if (closed) consoleFail(VmmConsoleProblem.CLOSED) } }
        catch (error: Exception) { close(true); throw error }
    }
    private fun request(url: String): Request {
        checkAccess()
        val cookie = synchronized(lock) { credential ?: consoleFail(VmmConsoleProblem.CLOSED) }
        return Request.Builder().url(url).header("Cookie", "id=$cookie").header("Cache-Control", "no-store").build()
    }
    private fun accessStatus(code: Int) {
        if (code == 401 || code == 403) {
            onAccessFailure(); close(true)
            throw DsmFailure(null, "Virtual machine console access expired", "Sign in again.", kind = DsmErrorKind.SESSION_EXPIRED)
        }
    }
    override fun resource(local: String): VmmConsoleResource {
        val (url, mime) = policy.resource(local)
        val call = client.newCall(request(url))
        synchronized(lock) { if (closed) consoleFail(VmmConsoleProblem.CLOSED); if (calls.size >= 16) consoleFail(VmmConsoleProblem.QUEUE); calls += call }
        try {
            return call.execute().use { response ->
                checkAccess(); accessStatus(response.code)
                if (response.code != 200) consoleFail(VmmConsoleProblem.RESPONSE)
                val body = response.body ?: consoleFail(VmmConsoleProblem.RESPONSE)
                val actual = body.contentType()?.let { "${it.type}/${it.subtype}" }?.lowercase()
                val accepted = when (mime) {
                    "text/javascript" -> setOf(mime, "application/javascript", "application/x-javascript")
                    "audio/ogg" -> setOf(mime, "application/ogg", "application/octet-stream")
                    else -> setOf(mime)
                }
                if (actual !in accepted) consoleFail(VmmConsoleProblem.RESPONSE)
                val limit = when (mime) { "text/html" -> 4 * 1024 * 1024; "application/json" -> 1024 * 1024; else -> 8 * 1024 * 1024 }
                if (body.contentLength() > limit) consoleFail(VmmConsoleProblem.RESPONSE)
                val result = ByteArrayOutputStream()
                body.byteStream().use { input ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer); if (count < 0) break
                        checkAccess(); if (result.size() + count > limit) consoleFail(VmmConsoleProblem.RESPONSE)
                        result.write(buffer, 0, count)
                    }
                }
                if (result.size() == 0) consoleFail(VmmConsoleProblem.RESPONSE)
                checkAccess()
                VmmConsoleResource(result.toByteArray(), mime, response.headers.values("Content-Security-Policy").takeIf { it.isNotEmpty() }?.joinToString(", "))
            }
        } finally { synchronized(lock) { calls -= call } }
    }
    override suspend fun connect() {
        checkAccess()
        synchronized(lock) { if (connecting) consoleFail(VmmConsoleProblem.CLOSED); connecting = true; mutable.value = VmmConsolePhase.CONNECTING }
        try {
            val request = request(policy.socket).newBuilder().header("Origin", policy.document.substringBefore("/webman/").let { java.net.URI(it) }.let { "https://${it.rawAuthority}" })
                .header("Sec-WebSocket-Protocol", "binary").build()
            val created = (webSockets ?: client).newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    try {
                        checkAccess()
                        if (response.header("Sec-WebSocket-Protocol") !in setOf(null, "", "binary")) consoleFail(VmmConsoleProblem.RESPONSE)
                        synchronized(lock) { if (closed) consoleFail(VmmConsoleProblem.CLOSED); socket = webSocket; mutable.value = VmmConsolePhase.CONNECTED; opened.complete(Unit) }
                    } catch (_: Exception) { webSocket.cancel(); close(true) }
                }
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    try {
                        checkAccess()
                        synchronized(lock) {
                            if (closed || bytes.size > MAX_RECEIVE || buffered + bytes.size > MAX_RECEIVE) consoleFail(VmmConsoleProblem.QUEUE)
                            if (bytes.size == 0) return
                            buffered += bytes.size
                            if (!frames.trySend(bytes).isSuccess) consoleFail(VmmConsoleProblem.QUEUE)
                        }
                    } catch (_: Exception) { close(true) }
                }
                override fun onMessage(webSocket: WebSocket, text: String) { close(true) }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { close() }
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { close() }
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (response?.code in setOf(401, 403)) onAccessFailure()
                    close(true)
                }
            })
            synchronized(lock) { if (closed) created.cancel() else socket = created }
            withTimeout(15_000) { opened.await() }
            checkAccess()
        } catch (error: Exception) { close(true); throw error }
    }
    override suspend fun receive(): ByteArray {
        checkAccess(); if (!reader.tryLock()) consoleFail(VmmConsoleProblem.QUEUE)
        try {
            if (synchronized(lock) { current == null }) {
                val next = frames.receive()
                synchronized(lock) { if (closed) consoleFail(VmmConsoleProblem.CLOSED); current = next; offset = 0 }
            }
            checkAccess()
            return synchronized(lock) {
                if (closed) consoleFail(VmmConsoleProblem.CLOSED)
                val frame = current ?: consoleFail(VmmConsoleProblem.CLOSED)
                val end = minOf(frame.size, offset + 256 * 1024)
                val chunk = frame.substring(offset, end).toByteArray(); offset = end; buffered -= chunk.size
                if (end == frame.size) { current = null; offset = 0 }
                chunk
            }
        } finally { reader.unlock() }
    }
    override fun send(bytes: ByteArray) {
        checkAccess()
        synchronized(lock) {
            val connection = socket ?: consoleFail(VmmConsoleProblem.CLOSED)
            if (closed || mutable.value != VmmConsolePhase.CONNECTED) consoleFail(VmmConsoleProblem.CLOSED)
            if (bytes.isEmpty()) return
            if (bytes.size > 1024 * 1024 || connection.queueSize() + bytes.size > 4 * 1024 * 1024) { close(true); consoleFail(VmmConsoleProblem.QUEUE) }
            if (!connection.send(bytes.toByteString())) { close(true); consoleFail(VmmConsoleProblem.CLOSED) }
        }
    }
    override fun close(failed: Boolean) = synchronized(lock) {
        if (!closed) {
            closed = true; credential = null
            mutable.value = if (failed) VmmConsolePhase.FAILED else VmmConsolePhase.DISCONNECTED
            calls.forEach { it.cancel() }; calls.clear(); socket?.cancel(); socket = null
            opened.completeExceptionally(VmmConsoleFailure(VmmConsoleProblem.CLOSED))
            frames.cancel(); current = null; buffered = 0; offset = 0
        }
    }
    companion object { private const val MAX_RECEIVE = 32L * 1024 * 1024 }
}
