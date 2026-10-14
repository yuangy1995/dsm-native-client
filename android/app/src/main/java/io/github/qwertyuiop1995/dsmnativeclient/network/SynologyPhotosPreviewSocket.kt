package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLException
import kotlinx.coroutines.channels.Channel
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/** 唯一的凭据查询例外来自已记录的官方Photos握手；不得打印Request/URL或底层异常。 */
internal fun photoPreviewSocketRequest(applicationEndpoint: String, session: DsmSession): Request {
    fun invalid(): Nothing = throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.INVALID_ENDPOINT)
    val base = applicationEndpoint.toHttpUrlOrNull() ?: invalid()
    if (!base.isHttps || base.username.isNotEmpty() || base.password.isNotEmpty() || base.query != null ||
        base.fragment != null || session.sid.isBlank()) invalid()
    val directory = base.encodedPath.let { if (it.endsWith('/')) it else it.substringBeforeLast('/') + "/" }
    val url = base.newBuilder().encodedPath(directory + "FotoSocketIo/socket.io/")
        .addQueryParameter("EIO", "4").addQueryParameter("transport", "websocket")
        .apply { session.synoToken?.takeIf { it.isNotBlank() }?.let { addQueryParameter("SynoToken", it) } }.build()
    val origin = base.newBuilder().encodedPath("/").build().toString().removeSuffix("/")
    // OkHttp以HTTPS请求升级为WSS，沿同一TLS连接策略。
    return try { Request.Builder().url(url).header("Cookie", "id=${session.sid}").header("Origin", origin)
        .header("User-Agent", "LanStash-Android/0.1").build() } catch (_: IllegalArgumentException) { invalid() }
}

internal class SynologyPhotosPreviewSocket(
    http: OkHttpClient,
    request: Request,
    private val authorize: () -> Unit,
    private val onAccessFailure: () -> Unit,
) : PhotoPreviewSocket {
    private val closed = AtomicBoolean(false)
    private val failure = AtomicReference(PhotoPreviewEventFailureKind.DISCONNECTED)
    private val frames = Channel<String>(32)
    private val socket: WebSocket

    init {
        require(!http.followRedirects && !http.followSslRedirects && !http.retryOnConnectionFailure)
        authorize()
        socket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (closed.get()) return
                if (text.toByteArray(Charsets.UTF_8).size > PhotoPreviewPacket.MAX_BYTES || frames.trySend(text).isFailure) {
                    terminate(webSocket, PhotoPreviewEventFailureKind.INVALID_FRAME)
                }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                terminate(webSocket, PhotoPreviewEventFailureKind.INVALID_FRAME)
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                terminate(webSocket, PhotoPreviewEventFailureKind.DISCONNECTED)
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                terminate(webSocket, PhotoPreviewEventFailureKind.DISCONNECTED)
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                // 不保留异常cause、reason或请求，防止含令牌的握手URL进入日志。
                val denied = response?.code in setOf(401, 403)
                if (denied) onAccessFailure()
                val kind = if (response != null || generateSequence(t) { it.cause }.any { it is SSLException })
                    PhotoPreviewEventFailureKind.REJECTED else PhotoPreviewEventFailureKind.DISCONNECTED
                response?.close()
                terminate(webSocket, kind)
            }
        })
    }

    override suspend fun send(text: String) {
        authorize()
        synchronized(closed) {
            if (closed.get() || !socket.send(text)) throw PhotoPreviewEventFailure(failure.get())
        }
    }

    override suspend fun receive(): String {
        authorize()
        val frame = frames.receive()
        authorize()
        return frame
    }

    override fun close() = synchronized(closed) {
        if (closed.compareAndSet(false, true)) {
            frames.close(PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.DISCONNECTED))
            socket.cancel()
        }
    }

    private fun terminate(current: WebSocket, kind: PhotoPreviewEventFailureKind) = synchronized(closed) {
        if (closed.compareAndSet(false, true)) {
            failure.set(kind)
            while (frames.tryReceive().isSuccess) { /* 丢弃失败连接内未处理的载荷。 */ }
            frames.close(PhotoPreviewEventFailure(kind))
            current.cancel()
        }
    }
}
