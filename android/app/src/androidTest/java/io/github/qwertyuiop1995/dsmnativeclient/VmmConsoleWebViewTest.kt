package io.github.qwertyuiop1995.dsmnativeclient

import android.webkit.WebSettings
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmConsolePolicy
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VmmConsoleWebView
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.ByteString
import org.junit.*
import org.junit.Assert.*

/** 真正的 WebView/消息端口/资源拦截；只替换远端字节与 WebSocket 服务。 */
class VmmConsoleWebViewTest {
    @get:Rule val compose = createComposeRule()
    private val policy = VmmConsolePolicy("https://synthetic.invalid:5001/alias", "guest", "Synthetic", "en-us")
    private val requests = CopyOnWriteArrayList<Request>()
    private val sent = CopyOnWriteArrayList<ByteString>()
    private var visible by mutableStateOf(true)
    private lateinit var view: VmmConsoleWebView
    private lateinit var socketRequest: Request
    @Volatile private var cancelled = false
    private val sockets = WebSocket.Factory { request, listener ->
        socketRequest = request
        val socket = object : WebSocket {
            override fun request() = request
            override fun queueSize() = 0L
            override fun send(bytes: ByteString): Boolean { sent += bytes; listener.onMessage(this, bytes); return !cancelled }
            override fun send(text: String) = false
            override fun close(code: Int, reason: String?) = true
            override fun cancel() { cancelled = true }
        }
        listener.onOpen(socket, Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(101).message("Synthetic").header("Sec-WebSocket-Protocol", "binary").build())
        socket
    }
    private val html = """<!doctype html><html><head><meta charset="utf-8"><script src="app/ui.js?v=1"></script></head><body></body></html>"""
    private val script = """
        window.syntheticStage = 'loading';
        addEventListener('DOMContentLoaded', async () => {
            try {
                const locale = await new Promise((resolve, reject) => {
                    const xhr = new XMLHttpRequest(); xhr.open('GET', 'app/locale/en.json');
                    xhr.onload = () => resolve(xhr.responseText); xhr.onerror = reject; xhr.send();
                });
                window.syntheticLocale = locale;
                const p = new URLSearchParams(location.search);
                window.syntheticSocket = new WebSocket('wss://' + location.host + '/' + p.get('app_alias') + '/' + p.get('path') + '?app_id=' + p.get('app_id'), ['binary']);
                const socket = window.syntheticSocket; socket.binaryType = 'arraybuffer';
                socket.onopen = () => socket.send(new Uint8Array([1, 2, 3, 255]));
                socket.onmessage = event => { window.syntheticBytes = Array.from(new Uint8Array(event.data)); window.syntheticStage = 'ready'; };
                socket.onerror = () => { window.syntheticStage = 'socket-error'; };
            } catch (error) { window.syntheticStage = 'failed:' + error.name; }
        });
    """.trimIndent()
    private val http = OkHttpClient.Builder().addInterceptor { chain ->
        requests += chain.request()
        val (content, mime) = when {
            chain.request().url.encodedPath.endsWith("vnc.html") -> html to "text/html"
            chain.request().url.encodedPath.endsWith("app/ui.js") -> script to "text/javascript"
            chain.request().url.encodedPath.endsWith("app/locale/en.json") -> "{\"synthetic\":true}" to "application/json"
            else -> throw AssertionError("Unexpected resource")
        }
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
            .header("Content-Security-Policy", "default-src 'none'; script-src 'self'; connect-src 'none'")
            .header("Set-Cookie", "should_not_enter_webview=synthetic; Secure")
            .body(content.toResponseBody(mime.toMediaType())).build()
    }.build()
    private val transport = DsmVmmConsoleTransport(policy, "synthetic-session", http, {}, {}, sockets)
    @Before fun open() {
        compose.setContent {
            if (visible) AndroidView(factory = { VmmConsoleWebView(it, VmmConsoleSession(policy, transport)).also { value -> view = value } },
                modifier = Modifier.fillMaxSize(), onRelease = { it.release() }, update = {})
        }
        compose.waitUntil(20_000) { ::view.isInitialized && js("window.syntheticStage") == "ready" }
    }
    @After fun close() { compose.runOnIdle { visible = false }; compose.waitForIdle(); transport.close() }
    @Test fun actualWebViewLoadsStrictCspLocaleAndBinaryBridgeWithoutPageCredentials() {
        assertEquals(VmmConsolePhase.CONNECTED, transport.phase.value)
        assertEquals("[1,2,3,255]", js("JSON.stringify(window.syntheticBytes)"))
        assertEquals("{\"synthetic\":true}", js("window.syntheticLocale")); assertEquals("", js("document.cookie"))
        assertFalse(js("location.href").contains("synthetic-session")); assertFalse(js("document.documentElement.outerHTML").contains("synthetic-session"))
        assertEquals("temporary", js("localStorage.setItem('synthetic','temporary'); localStorage.getItem('synthetic')"))
        assertEquals(1, sent.size); assertTrue(requests.all { it.header("Cookie") == "id=synthetic-session" })
        assertEquals("id=synthetic-session", socketRequest.header("Cookie")); assertEquals("https://synthetic.invalid:5001", socketRequest.header("Origin"))
        compose.runOnIdle {
            assertTrue(view.settings.blockNetworkLoads); assertFalse(view.settings.allowFileAccess); assertFalse(view.settings.allowContentAccess)
            assertFalse(view.settings.domStorageEnabled)
            assertEquals(WebSettings.MIXED_CONTENT_NEVER_ALLOW, view.settings.mixedContentMode)
        }
    }
    @Test fun nativeNetworkAndNavigationCannotEscapeTheLocalConsole() {
        val count = requests.size
        js("fetch('https://other.invalid/secret').then(() => window.syntheticFetch='unexpected', () => window.syntheticFetch='denied'); 'started'")
        compose.waitUntil { js("window.syntheticFetch") == "denied" }
        js("location.href='https://other.invalid/'; 'started'")
        compose.waitForIdle(); assertEquals(policy.localDocument, js("location.href")); assertEquals(count, requests.size)
        assertEquals("undefined", js("typeof window.Android"))
    }
    @Test fun oversizedInputClosesOnceWithoutSendingThePayload() {
        assertEquals("RangeError", js("(() => { try { window.syntheticSocket.send(new Uint8Array(1048577)); return 'unexpected'; } catch (error) { return error.name; } })()"))
        compose.waitUntil { cancelled }; assertEquals(1, sent.size); assertEquals(VmmConsolePhase.DISCONNECTED, transport.phase.value)
    }
    @Test fun leavingCompositionDestroysThePageAndClosesTheNativeConnection() {
        compose.runOnIdle { visible = false }; compose.waitForIdle()
        assertTrue(cancelled); assertEquals(VmmConsolePhase.DISCONNECTED, transport.phase.value)
        assertEquals(1, sent.size)
    }
    private fun js(code: String): String {
        val done = CountDownLatch(1); var result: String? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { view.evaluateJavascript(code) { result = it; done.countDown() } }
        assertTrue("WebView callback timed out", done.await(3, TimeUnit.SECONDS))
        return (Json.parseToJsonElement(result ?: "null") as? JsonPrimitive)?.contentOrNull ?: "null"
    }
}
