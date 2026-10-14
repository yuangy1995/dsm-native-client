package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class VmmConsolePolicyTest {
    private val policy = VmmConsolePolicy("https://synthetic.invalid:5001/alias", "guest-1", "Synthetic & 虚拟机", "en-us", UUID.fromString("00000000-0000-0000-0000-000000000001"))
    private val root get() = policy.localOrigin + "/alias/webman/3rdparty/Virtualization/noVNC/"
    @Test fun `单窗口固定连接参数与来源不携带凭据`() {
        assertTrue(policy.document.startsWith("https://synthetic.invalid:5001/alias/webman/"))
        assertTrue(policy.document.contains("reconnect=false")); assertTrue(policy.document.contains("app_alias=alias"))
        assertTrue(policy.document.contains("kb_layout=en-us")); assertTrue(policy.localDocument.startsWith(policy.localOrigin))
        assertTrue(policy.allowsNavigation(policy.localDocument)); assertFalse(policy.allowsNavigation(policy.document))
        assertTrue(policy.allowsSocket(policy.localSocket)); assertFalse(policy.allowsSocket(policy.socket))
        assertEquals(policy.document to "text/html", policy.resource(policy.localDocument))
        assertEquals("VmmConsolePolicy", policy.toString())
        assertTrue(VmmConsolePolicy("https://synthetic.invalid:5001", "guest", "Synthetic", "en-us", port = 5002).document.startsWith("https://synthetic.invalid:5002/"))
    }
    @Test fun `固定静态类型语言与图标通过其余路由不转发`() {
        for ((path, mime) in mapOf("app/ui.js?v=123" to "text/javascript", "app/styles/base.css" to "text/css", "app/locale/zh_CN.json" to "application/json", "app/sounds/bell.oga" to "audio/ogg", "app/images/logo.svg" to "image/svg+xml", "fonts/font.woff2" to "font/woff2")) {
            assertEquals(mime, policy.resource(root + path).second)
        }
        assertEquals("image/png", policy.resource(policy.localOrigin + "/alias/webman/3rdparty/Virtualization/images/VirtualManagement_48.png").second)
        for (path in listOf("vnc.html", "other.html", "app/locale/arbitrary/zh.json", "app/locale/too_long_language_name.json", "app/sounds/other.oga", "app/ui.js?_sid=x", "app/ui.js?v=x&v=y", "app/ui.js?v=%2e", "../other.js", "%2e%2e/other.js", "app/../other.js", "app//ui.js", "app\\ui.js", "app/u i.js", "app/ui.js#x")) {
            assertThrows(path, VmmConsoleFailure::class.java) { policy.resource(root + path) }
        }
    }
    @Test fun `来源编码用户信息和地址跳转全部拒绝`() {
        for (url in listOf("https://other.invalid/app/ui.js", root.replace("https:", "http:") + "app/ui.js", root.replace(".invalid", ".invalid:443") + "app/ui.js", root.replace("https://", "https://user@") + "app/ui.js", "file:///data/local.js", "content://synthetic/app.js", "javascript:alert(1)")) {
            assertThrows(VmmConsoleFailure::class.java) { policy.resource(url) }
        }
        for (url in listOf(policy.localSocket + "&x=1", policy.localSocket.replace("guest-1", "guest-2"), policy.localSocket + "#x", policy.localSocket.replace(".invalid/", ".invalid:443/"))) assertFalse(policy.allowsSocket(url))
    }
    @Test fun `拒绝不可信基础路径及键盘默认值`() {
        for (base in listOf("http://synthetic.invalid", "https://user@synthetic.invalid", "https://synthetic.invalid?x=y", "https://synthetic.invalid/#x", "https://synthetic.invalid/a/b", "https://synthetic.invalid/a/../b", "https://synthetic.invalid/%61", "https://synthetic.invalid//alias")) {
            assertThrows(VmmConsoleFailure::class.java) { VmmConsolePolicy(base, "guest", "Synthetic", "en-us") }
        }
        for (keyboard in listOf("Default", "", "a/b", "中")) assertThrows(VmmConsoleFailure::class.java) { VmmConsolePolicy("https://synthetic.invalid", "guest", "Synthetic", keyboard) }
        assertThrows(VmmConsoleFailure::class.java) { VmmConsolePolicy("https://synthetic.invalid", "guest/1", "Synthetic", "en-us") }
        assertThrows(VmmConsoleFailure::class.java) { VmmConsolePolicy("https://synthetic.invalid", "guest", "Name\n", "en-us") }
    }
}
