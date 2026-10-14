package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.FileVFSCloudAuthorization
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileVFSCloudRequest
import kotlinx.coroutines.*
import java.io.ByteArrayOutputStream
import java.net.*
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

internal enum class FileVFSCloudSessionFailure { EXPIRED, UNAVAILABLE }

/** 仅在授权期间监听 127.0.0.1；浏览器处理登录，App 只接收一次已绑定回调。 */
internal class FileVFSCloudAuthorizationSession(
    private val request: FileVFSCloudRequest, parentScope: CoroutineScope,
    private val successText: String, private val failureText: String,
    private val onAuthorization: (FileVFSCloudAuthorization) -> Unit,
    private val onFailure: (FileVFSCloudSessionFailure) -> Unit,
    private val timeoutMillis: Long = 600_000,
) {
    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.IO)
    private val lock = Any()
    private val completed = AtomicBoolean(false)
    private var server: ServerSocket? = null
    private val clients = mutableSetOf<Socket>()
    private val path = "/" + UUID.randomUUID().toString().replace("-", "")
    private var started = false
    val isRunning get() = synchronized(lock) { server != null && !completed.get() }
    init { scope.coroutineContext[Job]!!.invokeOnCompletion { close() } }

    suspend fun start(): String = withContext(Dispatchers.IO) {
        val login = URI(request.loginUrl)
        require(login.scheme == "https" && login.host == "synooauth.synology.com" && login.port == -1 && login.rawUserInfo == null &&
            login.path == "/FileStation/Cloud/login.php" && login.fragment == null)
        val listener = synchronized(lock) {
            check(!started && !completed.get()); started = true
            ServerSocket().also {
                try { it.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0)); it.soTimeout = 1000; server = it }
                catch (error: Exception) { it.close(); throw error }
            }
        }
        val host = "127.0.0.1:${listener.localPort}"
        val callback = "http://$host$path"
        val url = request.loginUrl + "&host=" + URLEncoder.encode(callback, "UTF-8") + "&callback=" + URLEncoder.encode(request.callbackName, "UTF-8")
        scope.launch {
            delay(timeoutMillis)
            if (completed.compareAndSet(false, true)) { close(); onFailure(FileVFSCloudSessionFailure.EXPIRED) }
        }
        scope.launch {
            try {
                while (isActive && !completed.get()) {
                    val client = try { listener.accept() } catch (_: SocketTimeoutException) { continue }
                    val accepted = synchronized(lock) { if (completed.get() || clients.size >= 8) false else clients.add(client) }
                    if (!accepted) { client.close(); continue }
                    launch { handle(client, host) }
                }
            } catch (_: Exception) {
                if (completed.compareAndSet(false, true)) { close(); onFailure(FileVFSCloudSessionFailure.UNAVAILABLE) }
            } finally { close() }
        }
        url
    }

    fun close() {
        completed.set(true)
        synchronized(lock) {
            runCatching { server?.close() }; server = null
            clients.forEach { runCatching { it.close() } }; clients.clear()
        }
        scope.cancel()
    }
    private fun handle(client: Socket, host: String) {
        try {
            client.soTimeout = 10_000
            val bytes = ByteArrayOutputStream(); val buffer = ByteArray(16_384)
            val startedAt = System.nanoTime()
            while (!completed.get() && (System.nanoTime() - startedAt) / 1_000_000 < 10_000) {
                val size = client.getInputStream().read(buffer)
                if (size < 0) { reply(client, false); return }
                bytes.write(buffer, 0, size)
                val incoming = FileVFSCloudCallbackHTTP.decode(bytes.toByteArray()) ?: continue
                val authorization = incoming.authorization(request, host, path)
                if (!completed.compareAndSet(false, true)) return
                // 先交还浏览器一个无凭据页面，再通知界面；浏览器断开不重放或丢弃已取得的授权。
                runCatching { reply(client, true) }
                close(); onAuthorization(authorization); return
            }
        } catch (_: Exception) { if (!completed.get()) runCatching { reply(client, false) } }
        finally { synchronized(lock) { clients.remove(client) }; runCatching { client.close() } }
    }
    private fun reply(client: Socket, success: Boolean) {
        val nonce = UUID.randomUUID().toString()
        fun escape(value: String) = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        val text = escape(if (success) successText else failureText)
        val html = "<!doctype html><meta charset=\"utf-8\"><p>$text</p><script nonce=\"$nonce\">history.replaceState(null,'','/complete');window.close();</script>"
        val body = html.toByteArray(Charsets.UTF_8)
        val status = if (success) "200 OK" else "400 Invalid Callback"
        val headers = "HTTP/1.1 $status\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.size}\r\nCache-Control: no-store\r\n" +
            "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'nonce-$nonce'\r\nConnection: close\r\n\r\n"
        client.getOutputStream().apply { write(headers.toByteArray(Charsets.US_ASCII)); write(body); flush() }
    }
}
