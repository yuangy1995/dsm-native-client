import DsmCore
import Foundation
import XCTest
@preconcurrency import WebKit
@testable import DsmVirtualMachineConsoleFeature
#if os(macOS)
import AppKit
#endif

@MainActor
final class VirtualMachineConsoleComponentTests: XCTestCase {
    private func setup() throws -> (VirtualMachineConsoleController, WKWebView, ConsoleComponentTransport) {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let policy = try VirtualMachineConsolePolicy(baseURL: XCTUnwrap(URL(string: "https://nas.example.invalid:5001")), machineID: "vm-1", name: "Synthetic", keyboardLayout: "en-us")
        let transport = ConsoleComponentTransport()
        let controller = VirtualMachineConsoleController(session: .init(policy: policy, transport: transport))
        return (controller, controller.makeWebView(), transport)
    }
    private func wait(_ web: WKWebView, condition: String) async throws {
        for _ in 0..<100 {
            if let result = try? await web.evaluateJavaScript(condition), result as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("实际 WebKit 页面未达到预期：\(condition)")
    }
    func test真实WebKit按序收发有界画面且不持有Cookie() async throws {
        let (controller, web, transport) = try setup()
        defer { controller.close() }
        try await wait(web, condition: "window.received === 300000 && window.sent === true")
        XCTAssertEqual(controller.state, .connected)
        let sent = await transport.sent
        XCTAssertEqual(sent, [Data([1, 2]), Data([3, 4])])
        let reads = await transport.readCount
        XCTAssertEqual(reads, 2, "首帧分块必须共享同一次原生读取；后一次等待后续帧")
        let cookie = try await web.evaluateJavaScript("document.cookie") as? String
        XCTAssertEqual(cookie, "")
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty)
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        controller.close()
        for _ in 0..<20 { if await transport.closed { break }; try await Task.sleep(for: .milliseconds(25)) }
        let closed = await transport.closed
        XCTAssertTrue(closed)
    }
    func test真实WebKit语言XHR通过限定桥读取() async throws {
        let (controller, web, transport) = try setup()
        defer { controller.close() }
        try await wait(web, condition: "window.localeLoaded === true")
        let resources = await transport.paths
        XCTAssertTrue(resources.contains { $0.hasSuffix("app/locale/zh.json") })
        let locale = try await web.evaluateJavaScript("window.localeText") as? String
        XCTAssertEqual(locale, "{\"synthetic\":true}")
    }
    func test真实WebKit拦截外部连接导航弹窗与跨VM连接() async throws {
        let (controller, web, _) = try setup()
        defer { controller.close() }
        try await wait(web, condition: "window.sent === true")
        let blocked = try await web.evaluateJavaScript("(() => { try { new WebSocket('wss://other.invalid/channel'); return false; } catch { return true; } })()") as? Bool
        XCTAssertEqual(blocked, true)
        let popup = try await web.evaluateJavaScript("window.open('https://other.invalid') === null") as? Bool
        XCTAssertEqual(popup, true)
        _ = try await web.evaluateJavaScript("window.fetchBlocked = false; fetch('https://other.invalid/data').catch(() => window.fetchBlocked = true); true")
        try await wait(web, condition: "window.fetchBlocked === true")
        _ = try await web.evaluateJavaScript("location.href = 'https://other.invalid'; true")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(web.url, controller.session.policy.localDocumentURL)
        XCTAssertEqual(controller.state, .connected)
    }
    func test窗口关闭后迟到资源不会恢复画面() async throws {
        let (controller, web, transport) = try setup()
        controller.close()
        try await Task.sleep(for: .milliseconds(150))
        let connected = await transport.connected
        XCTAssertFalse(connected)
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty)
    }
    func test网页加载但没有建立连接时结束等待且保留服务器限制() async throws {
        let policy = try VirtualMachineConsolePolicy(baseURL: XCTUnwrap(URL(string: "https://example.invalid")), machineID: "vm-1", name: "Synthetic", keyboardLayout: "en-us")
        let transport = ConsoleComponentTransport(restrictScripts: true)
        let controller = VirtualMachineConsoleController(session: .init(policy: policy, transport: transport), connectionTimeout: .seconds(1))
        let web = controller.makeWebView()
        defer { controller.close(); withExtendedLifetime(web) {} }
        for _ in 0..<40 { if controller.state == .failed { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(controller.state, .failed)
        let connected = await transport.connected
        XCTAssertFalse(connected, "不得为了兼容而移除 NAS 返回的 CSP")
    }
    func test资源拒绝和证书错误保留准确恢复类型() async throws {
        for category in [AppErrorCategory.permissionDenied, .tlsUntrusted] {
            let policy = try VirtualMachineConsolePolicy(baseURL: XCTUnwrap(URL(string: "https://example.invalid")), machineID: "vm-1", name: "Synthetic", keyboardLayout: "en-us")
            let transport = ConsoleComponentTransport(resourceFailure: category)
            let controller = VirtualMachineConsoleController(session: .init(policy: policy, transport: transport))
            let web = controller.makeWebView()
            for _ in 0..<60 { if controller.state != .loading { break }; try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(controller.state, category == .permissionDenied ? .accessDenied : .trustRequired)
            controller.close(); withExtendedLifetime(web) {}
        }
    }
}

private actor ConsoleComponentTransport: VirtualMachineConsoleTransport {
    let restrictScripts: Bool
    let resourceFailure: AppErrorCategory?
    init(restrictScripts: Bool = false, resourceFailure: AppErrorCategory? = nil) {
        self.restrictScripts = restrictScripts; self.resourceFailure = resourceFailure
    }
    var sent: [Data] = []
    var paths: [String] = []
    var readCount = 0
    var connected = false
    var closed = false
    private var pendingRead: CheckedContinuation<Data, Error>?
    func resource(_ url: URL) async throws -> VirtualMachineConsoleResource {
        guard !closed else { throw VirtualMachineConsoleError.closed }
        if let resourceFailure { throw AppError(category: resourceFailure, isRetryable: false, safeUserMessage: "") }
        paths.append(url.path)
        if url.path.hasSuffix(".json") {
            return .init(data: Data(#"{"synthetic":true}"#.utf8), mediaType: "application/json")
        }
        return .init(data: Data(Self.html.utf8), mediaType: "text/html", serverPolicy: restrictScripts ? "script-src 'none'" : nil)
    }
    func connect() async throws { guard !closed else { throw VirtualMachineConsoleError.closed }; connected = true }
    func receive() async throws -> Data {
        guard !closed else { throw VirtualMachineConsoleError.closed }
        readCount += 1
        if readCount == 1 { return Data(repeating: 7, count: 300_000) }
        return try await withCheckedThrowingContinuation { pendingRead = $0 }
    }
    func send(_ data: Data) async throws { guard !closed else { throw VirtualMachineConsoleError.closed }; sent.append(data) }
    func close() async {
        closed = true; pendingRead?.resume(throwing: VirtualMachineConsoleError.closed); pendingRead = nil
    }
    static let html = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><script>
    const query = new URLSearchParams(location.search);
    window.received=0; window.sent=false; window.localeLoaded=false;
    const socket = new WebSocket('wss://' + location.host + '/' + query.get('path') + '?app_id=' + query.get('app_id'), ['binary']);
    socket.binaryType='arraybuffer';
    socket.onopen=()=>{socket.send(new Uint8Array([1,2]));socket.send(new Uint8Array([3,4]));socket._tail.then(()=>window.sent=true);};
    socket.onmessage=e=>window.received+=e.data.byteLength;
    const locale = new XMLHttpRequest(); locale.open('GET','app/locale/zh.json');
    locale.onload=()=>{window.localeText=locale.responseText;window.localeLoaded=locale.status===200;};locale.send();
    </script></body></html>
    """#
}
