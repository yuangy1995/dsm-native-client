import DsmCore
import DsmLocalization
import Observation
import SwiftUI
import WebKit

public struct VirtualMachineConsoleView: View {
    @State private var controller: VirtualMachineConsoleController
    public init(session: VirtualMachineConsoleSession) {
        _controller = State(initialValue: VirtualMachineConsoleController(session: session))
    }
    public var body: some View {
        ZStack {
            ConsoleWebView(controller: controller)
                .accessibilityIdentifier("virtual-machine.console.web")
            if controller.state != .connected {
                VStack(spacing: 12) {
                    if controller.state == .loading {
                        ProgressView(L10n.string("virtual-machine.console.connecting"))
                    } else {
                        Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle)
                        Text(L10n.string(controller.state.messageKey))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
                .accessibilityIdentifier("virtual-machine.console.\(controller.state.rawValue)")
            }
        }
        .onDisappear { controller.close() }
    }
}

@MainActor @Observable
final class VirtualMachineConsoleController: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    enum State: String {
        case loading, connected, disconnected, failed, accessDenied, trustRequired
        var messageKey: String {
            switch self {
            case .disconnected: "virtual-machine.console.disconnected"
            case .accessDenied: "virtual-machine.console.access-denied"
            case .trustRequired: "virtual-machine.console.trust-required"
            default: "virtual-machine.console.failed"
            }
        }
    }
    private(set) var state = State.loading
    let session: VirtualMachineConsoleSession
    private(set) weak var webView: WKWebView?
    private var closed = false
    private var hasOpened = false
    private var reading = false
    private var sending = false
    private var pendingData = Data()
    private var pendingOffset = 0
    private var resourceTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var bridgeTasks: [UUID: Task<Void, Never>] = [:]
    private var openingDeadline: Task<Void, Never>?
    private let connectionTimeout: Duration
    init(session: VirtualMachineConsoleSession, connectionTimeout: Duration = .seconds(30)) {
        self.session = session; self.connectionTimeout = connectionTimeout; super.init()
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(self, forURLScheme: VirtualMachineConsolePolicy.scheme)
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "console")
        configuration.userContentController.addUserScript(.init(source: ConsoleBridgeScript.make(policy: session.policy), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        #if os(macOS)
        view.allowsMagnification = true
        #endif
        webView = view
        view.load(URLRequest(url: session.policy.localDocumentURL))
        openingDeadline = Task { [weak self, connectionTimeout] in
            do { try await Task.sleep(for: connectionTimeout) } catch { return }
            if self?.state == .loading { self?.fail() }
        }
        return view
    }

    func close() {
        guard !closed else { return }
        closed = true
        openingDeadline?.cancel(); openingDeadline = nil
        for task in resourceTasks.values { task.cancel() }; resourceTasks.removeAll()
        for task in bridgeTasks.values { task.cancel() }; bridgeTasks.removeAll()
        pendingData = Data(); pendingOffset = 0
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "console", contentWorld: .page)
            webView.configuration.userContentController.removeAllUserScripts()
            webView.navigationDelegate = nil; webView.uiDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
        }
        let transport = session.transport
        Task { await transport.close() }
    }

    private func fail(_ error: (any Error)? = nil) {
        guard !closed else { return }
        switch (error as? AppError)?.category {
        case .authenticationRequired, .permissionDenied: state = .accessDenied
        case .tlsUntrusted, .tlsCertificateChanged: state = .trustRequired
        default: state = state == .connected ? .disconnected : .failed
        }
        close()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard !closed, urlSchemeTask.request.httpMethod == "GET", urlSchemeTask.request.httpBody == nil,
              let url = urlSchemeTask.request.url, let remote = try? session.policy.remoteResource(for: url) else {
            urlSchemeTask.didFailWithError(VirtualMachineConsoleError.forbiddenResource); return
        }
        resourceTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { self.resourceTasks[key] = nil }
            do {
                let resource = try await session.transport.resource(remote)
                try Task.checkCancellation()
                guard !closed, resourceTasks[key] != nil else { return }
                let policy = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; media-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"
                let csp = resource.serverPolicy.map { $0 + ", " + policy } ?? policy
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": resource.mediaType, "Content-Security-Policy": csp,
                    "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff"
                ])!
                urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(resource.data); urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, !closed, resourceTasks[key] != nil else { return }
                urlSchemeTask.didFailWithError(VirtualMachineConsoleError.invalidResponse)
                fail(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        resourceTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard !closed, navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url, session.policy.allowsNavigation(url) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { fail() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { fail() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard !closed, message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url == session.policy.localDocumentURL,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(nil, "console.closed"); return
        }
        let url = (body["url"] as? String).flatMap(URL.init(string:)), encoded = body["data"] as? String
        let token = UUID()
        bridgeTasks[token] = Task { [weak self] in
            guard let self else { replyHandler(nil, "console.closed"); return }
            defer { bridgeTasks[token] = nil }
            do {
                let result: String
                switch kind {
                case "open":
                    guard !hasOpened, let url, session.policy.allowsSocket(url) else { throw VirtualMachineConsoleError.forbiddenResource }
                    hasOpened = true
                    try await session.transport.connect()
                    try Task.checkCancellation()
                    guard !closed else { throw VirtualMachineConsoleError.closed }
                    openingDeadline?.cancel(); openingDeadline = nil
                    state = .connected; result = ""
                case "read":
                    guard state == .connected, !reading else { throw VirtualMachineConsoleError.closed }
                    reading = true; defer { reading = false }
                    if pendingOffset >= pendingData.count {
                        pendingData = try await session.transport.receive(); pendingOffset = 0
                    }
                    try Task.checkCancellation()
                    guard !closed else { throw VirtualMachineConsoleError.closed }
                    let end = min(pendingData.count, pendingOffset + 262_144)
                    result = pendingData.subdata(in: pendingOffset..<end).base64EncodedString(); pendingOffset = end
                    if end == pendingData.count { pendingData = Data(); pendingOffset = 0 }
                case "send":
                    guard state == .connected, !sending, let encoded, encoded.count <= 1_398_104,
                          let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= 1_048_576 else { throw VirtualMachineConsoleError.queueFull }
                    sending = true; defer { sending = false }
                    try await session.transport.send(data); result = ""
                case "locale":
                    guard let url else { throw VirtualMachineConsoleError.forbiddenResource }
                    let remote = try session.policy.remoteResource(for: url)
                    guard session.policy.mediaType(for: remote) == "application/json" else { throw VirtualMachineConsoleError.forbiddenResource }
                    let resource = try await session.transport.resource(remote)
                    guard resource.data.count <= 1_048_576, let text = String(data: resource.data, encoding: .utf8) else { throw VirtualMachineConsoleError.invalidResponse }
                    result = text
                case "close":
                    state = .disconnected; replyHandler("", nil); close(); return
                default: throw VirtualMachineConsoleError.forbiddenResource
                }
                try Task.checkCancellation()
                guard !closed else { throw VirtualMachineConsoleError.closed }
                replyHandler(result, nil)
            } catch {
                replyHandler(nil, "console.unavailable")
                fail(error)
            }
        }
    }
}

#if os(macOS)
private struct ConsoleWebView: NSViewRepresentable {
    let controller: VirtualMachineConsoleController
    func makeNSView(context: Context) -> WKWebView { controller.makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    func makeCoordinator() -> VirtualMachineConsoleController { controller }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: VirtualMachineConsoleController) { coordinator.close() }
}
#else
private struct ConsoleWebView: UIViewRepresentable {
    let controller: VirtualMachineConsoleController
    func makeUIView(context: Context) -> WKWebView { controller.makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> VirtualMachineConsoleController { controller }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: VirtualMachineConsoleController) { coordinator.close() }
}
#endif
