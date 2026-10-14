package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.net.http.SslError
import android.os.Looper
import android.view.ViewGroup
import android.webkit.*
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientToolbar
import java.io.ByteArrayInputStream
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.toByteString

@Composable internal fun VmmConsoleContent(state: VmmConsoleState, onClose: () -> Unit, onReconnect: () -> Unit) {
    BackHandler { onClose() }
    Column(Modifier.fillMaxSize()) {
        ClientToolbar(state.target?.name.orEmpty(), onBack = onClose)
        Box(Modifier.fillMaxWidth().weight(1f)) {
            state.session?.let { session ->
                key(session.policy.id) {
                    AndroidView(factory = { VmmConsoleWebView(it, session) }, modifier = Modifier.fillMaxSize(),
                        onRelease = { it.release() }, update = {})
                }
            }
            if (state.phase != VmmConsolePhase.CONNECTED) Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
                Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    if (state.phase in setOf(VmmConsolePhase.LOADING, VmmConsolePhase.CONNECTING)) {
                        CircularProgressIndicator()
                        Spacer(Modifier.height(16.dp))
                        Text(stringResource(R.string.vm_console_connecting))
                    } else {
                        Text(state.failure?.takeUnless { it is VmmConsoleFailure }?.let { vmmErrorText(it) } ?: stringResource(if (state.phase == VmmConsolePhase.FAILED) R.string.vm_console_failed else R.string.vm_console_disconnected))
                        TextButton(onClick = onReconnect, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.vm_console_reconnect)) }
                    }
                }
            }
        }
    }
}

/** 拦截所有网页请求；原生端口仅向精确临时来源的主框架转交一次。 */
@SuppressLint("SetJavaScriptEnabled")
internal class VmmConsoleWebView(context: Context, private val session: VmmConsoleSession) : WebView(context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val token = UUID.randomUUID().toString()
    private val script = VmmConsoleBridge.script(session.policy, token)
    private val requests = mutableSetOf<String>()
    private var port: WebMessagePort? = null
    private var transferred = false
    private var released = false
    init {
        settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = false
            allowFileAccess = false; allowContentAccess = false
            blockNetworkLoads = true; mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            javaScriptCanOpenWindowsAutomatically = false; setSupportMultipleWindows(false)
            cacheMode = WebSettings.LOAD_NO_CACHE
            mediaPlaybackRequiresUserGesture = true
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
        isSaveEnabled = false
        setDownloadListener { _, _, _, _, _ -> }
        webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
            override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) { callback.invoke(origin, false, false) }
            override fun onConsoleMessage(consoleMessage: ConsoleMessage) = true
        }
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                val url = request.url.toString()
                if (request.method != "GET") return denied()
                if (url == session.policy.bridge) return response(VmmConsoleResource(script.toByteArray(), "text/javascript", null))
                if (runCatching { session.policy.resource(url) }.isFailure) return denied()
                return try {
                    val resource = session.transport.resource(url)
                    if (url == session.policy.localDocument) {
                        val html = resource.text()
                        val head = Regex("<head\\b[^>]*>", RegexOption.IGNORE_CASE).find(html) ?: consoleFail(VmmConsoleProblem.RESPONSE)
                        val position = head.range.last + 1
                        val modified = html.substring(0, position) + "<script src=\"${session.policy.bridge}\"></script>" + html.substring(position)
                        response(VmmConsoleResource(modified.toByteArray(), "text/html", resource.serverPolicy))
                    } else response(resource)
                } catch (_: Exception) { session.transport.close(true); denied() }
            }
            override fun onPageFinished(view: WebView, url: String) {
                if (released || transferred || !session.policy.allowsNavigation(url)) return
                transferred = true
                val channel = createWebMessageChannel()
                port = channel[0]
                channel[0].setWebMessageCallback(object : WebMessagePort.WebMessageCallback() {
                    override fun onMessage(port: WebMessagePort, message: WebMessage) { receiveMessage(message) }
                })
                postWebMessage(WebMessage(token, arrayOf(channel[1])), Uri.parse(session.policy.localOrigin))
                // channel[1] 已移交网页，不能在原生端再次使用或关闭。
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) session.transport.close(true)
            }
            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, errorResponse: WebResourceResponse) {
                if (request.isForMainFrame) session.transport.close(true)
            }
            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) { handler.cancel(); session.transport.close(true) }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean { session.transport.close(true); return true }
        }
        loadUrl(session.policy.localDocument)
        scope.launch { delay(25_000); if (!released && session.transport.phase.value in setOf(VmmConsolePhase.LOADING, VmmConsolePhase.CONNECTING)) session.transport.close(true) }
    }
    private fun receiveMessage(message: WebMessage) {
        if (released) return
        val data = message.data
        if (!message.ports.isNullOrEmpty() || data == null || data.length > 1_400_000 || requests.size >= 16) { session.transport.close(true); return }
        val value = runCatching { Json.parseToJsonElement(data) as JsonObject }.getOrNull()
        val id = (value?.get("id") as? JsonPrimitive)?.takeIf { it.isString }?.content
        val kind = (value?.get("kind") as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (value == null || id == null || !Regex("[1-9][0-9]{0,10}").matches(id) || !requests.add(id)) { session.transport.close(true); return }
        scope.launch {
            var ok = true
            val result = try {
                withContext(Dispatchers.IO) {
                    val keys = when (kind) { "open", "locale" -> setOf("id", "kind", "url"); "send" -> setOf("id", "kind", "data"); "read", "close" -> setOf("id", "kind"); else -> consoleFail() }
                    if (value.keys != keys) consoleFail()
                    when (kind) {
                        "open" -> { if (!session.policy.allowsSocket(value["url"].vmmText().orEmpty())) consoleFail(); session.transport.connect(); "" }
                        "read" -> session.transport.receive().toByteString().base64()
                        "send" -> {
                            val encoded = value["data"].vmmText() ?: consoleFail()
                            if (encoded.length > 1_398_104 || !Regex("[A-Za-z0-9+/]+={0,2}").matches(encoded)) consoleFail()
                            val bytes = encoded.decodeBase64()?.toByteArray() ?: consoleFail()
                            try { session.transport.send(bytes) } finally { bytes.fill(0) }; ""
                        }
                        "locale" -> { val url = value["url"].vmmText() ?: consoleFail(); session.policy.locale(url); session.transport.resource(url).text() }
                        "close" -> { session.transport.close(); "" }
                        else -> consoleFail()
                    }
                }
            } catch (_: Exception) { ok = false; session.transport.close(true); "" }
            finally { requests.remove(id) }
            if (!released) port?.postMessage(WebMessage(buildJsonObject { put("id", id); put("ok", ok); put("value", result) }.toString()))
        }
    }
    fun release() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (released) return
        released = true; session.transport.close(); scope.cancel(); port?.close(); port = null; requests.clear()
        stopLoading(); loadUrl("about:blank"); clearHistory()
        WebStorage.getInstance().deleteOrigin(session.policy.localOrigin)
        (parent as? ViewGroup)?.removeView(this)
        destroy()
    }
    private fun response(resource: VmmConsoleResource): WebResourceResponse = WebResourceResponse(resource.mime, "UTF-8", 200, "OK", mapOf(
        "Cache-Control" to "no-store", "Referrer-Policy" to "no-referrer", "X-Content-Type-Options" to "nosniff",
        "Content-Security-Policy" to listOfNotNull(resource.serverPolicy, VmmConsolePolicy.CONTENT_POLICY).joinToString(", "),
    ), ByteArrayInputStream(resource.bytes))
    private fun denied() = WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(ByteArray(0)))
}
