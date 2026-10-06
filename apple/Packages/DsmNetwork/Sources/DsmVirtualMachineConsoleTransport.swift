import DsmCore
import Foundation

protocol DsmConsoleSocket: Sendable {
    func connect() async throws
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close() async
}

/// 网页不持有 Cookie。所有静态读取与 WSS 使用同一配置的证书边界，禁止重定向。
actor DsmVirtualMachineConsoleTransport: VirtualMachineConsoleTransport {
    private let policy: VirtualMachineConsolePolicy
    private let http: any DsmHTTPTransport
    private let socketFactory: @Sendable (URLRequest) throws -> any DsmConsoleSocket
    private var cookie: String?
    private var closed = false
    private var started = false
    private var connected = false
    private var socket: (any DsmConsoleSocket)?
    private var reads: [UUID: Task<VirtualMachineConsoleResource, Error>] = [:]

    init(policy: VirtualMachineConsolePolicy, cookie: String, http: any DsmHTTPTransport,
         socketFactory: @escaping @Sendable (URLRequest) throws -> any DsmConsoleSocket) throws {
        guard !cookie.isEmpty, cookie.utf8.allSatisfy({ (33...126).contains($0) && ![34, 44, 59, 92].contains($0) }) else {
            throw VirtualMachineConsoleError.invalidTarget
        }
        self.policy = policy; self.cookie = cookie; self.http = http; self.socketFactory = socketFactory
    }

    func resource(_ url: URL) async throws -> VirtualMachineConsoleResource {
        guard !closed else { throw VirtualMachineConsoleError.closed }
        guard let mediaType = policy.mediaType(for: url), let cookie else { throw VirtualMachineConsoleError.forbiddenResource }
        guard reads.count < 16 else { throw VirtualMachineConsoleError.queueFull }
        var request = URLRequest(url: url)
        request.setValue("id=" + cookie, forHTTPHeaderField: "Cookie")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(mediaType, forHTTPHeaderField: "Accept")
        let id = UUID(), http = http
        let read = Task {
            let response: DsmHTTPResponse
            do { response = try await http.send(request) } catch { throw Self.consoleError(error) }
            try Task.checkCancellation()
            guard response.statusCode == 200 else {
                throw DsmErrorMapper.map(.httpStatus(code: response.statusCode, requestID: UUID()))
            }
            let contentType = response.headers.first { $0.key.lowercased() == "content-type" }?.value
                .split(separator: ";").first.map(String.init)?.lowercased()
            let accepted = contentType == mediaType
                || mediaType == "text/javascript" && ["application/javascript", "application/x-javascript"].contains(contentType)
                || mediaType == "audio/ogg" && contentType == "application/octet-stream"
            let limit = mediaType == "text/html" ? 4 * 1_024 * 1_024 : mediaType == "application/json" ? 1_024 * 1_024 : 8 * 1_024 * 1_024
            guard accepted, !response.data.isEmpty, response.data.count <= limit else { throw VirtualMachineConsoleError.invalidResponse }
            let csp = response.headers.first { $0.key.lowercased() == "content-security-policy" }?.value
            guard csp?.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) != true else { throw VirtualMachineConsoleError.invalidResponse }
            return VirtualMachineConsoleResource(data: response.data, mediaType: mediaType, serverPolicy: csp)
        }
        reads[id] = read
        defer { reads[id] = nil }
        let value = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        try Task.checkCancellation()
        guard !closed else { throw VirtualMachineConsoleError.closed }
        return value
    }

    func connect() async throws {
        guard !closed, !started, let cookie else { throw VirtualMachineConsoleError.closed }
        started = true
        var request = URLRequest(url: policy.socketURL)
        request.setValue("id=" + cookie, forHTTPHeaderField: "Cookie")
        var origin = URLComponents(url: policy.documentURL, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil
        request.setValue(origin.string, forHTTPHeaderField: "Origin")
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = try socketFactory(request)
        self.socket = socket
        do {
            try await socket.connect()
            try Task.checkCancellation()
            guard !closed else { throw VirtualMachineConsoleError.closed }
            connected = true
        } catch { await close(); throw Self.consoleError(error) }
    }

    func receive() async throws -> Data {
        guard !closed, connected, let socket else { throw VirtualMachineConsoleError.closed }
        do {
            let data = try await socket.receive()
            try Task.checkCancellation()
            guard !closed else { throw VirtualMachineConsoleError.closed }
            return data
        } catch { await close(); throw Self.consoleError(error) }
    }

    func send(_ data: Data) async throws {
        guard !closed, connected, let socket else { throw VirtualMachineConsoleError.closed }
        guard !data.isEmpty, data.count <= 1_024 * 1_024 else { throw VirtualMachineConsoleError.queueFull }
        do { try await socket.send(data); try Task.checkCancellation() }
        catch { await close(); throw error }
    }

    private static func consoleError(_ error: any Error) -> any Error {
        if error is DsmCertificateTrustError {
            return DsmErrorMapper.map(.transport(code: URLError.serverCertificateUntrusted.rawValue, requestID: UUID()))
        }
        return error
    }

    func close() async {
        guard !closed else { return }
        closed = true; connected = false; cookie = nil
        for task in reads.values { task.cancel() }; reads.removeAll()
        let old = socket; socket = nil
        await old?.close()
    }
}

/// didOpen 才表示握手完成；不能把 resume 或首个画面消息当成连接成功。
private final class ConsoleSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let tls: DsmTLSDelegate
    let opened: AsyncThrowingStream<Bool, Error>
    private let continuation: AsyncThrowingStream<Bool, Error>.Continuation
    init(expectedHost: String, fingerprint: String?, requiresSystemTrust: Bool) {
        tls = DsmTLSDelegate(expectedHost: expectedHost, pinnedFingerprint: fingerprint,
                             requiresSystemTrust: requiresSystemTrust, allowsRedirects: false)
        (opened, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard `protocol` == nil || `protocol` == "binary" else {
            continuation.finish(throwing: VirtualMachineConsoleError.invalidResponse)
            webSocketTask.cancel(with: .protocolError, reason: nil); return
        }
        continuation.yield(true); continuation.finish()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: tls.consumeFailure(for: task) ?? error ?? VirtualMachineConsoleError.closed)
        tls.unregisterTask(task)
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        continuation.finish(throwing: VirtualMachineConsoleError.closed)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        tls.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        tls.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class DsmNativeConsoleSocket: DsmConsoleSocket, @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let delegate: ConsoleSocketDelegate
    init(request: URLRequest, expectedHost: String, fingerprint: String?, requiresSystemTrust: Bool) {
        delegate = ConsoleSocketDelegate(expectedHost: expectedHost, fingerprint: fingerprint, requiresSystemTrust: requiresSystemTrust)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        // URLSession 按完整消息接收；这是单帧内存上限，不是整个控制台的传输上限。
        socket.maximumMessageSize = 32 * 1_024 * 1_024
        delegate.tls.registerTaskForTrustFailures(socket)
    }
    func connect() async throws {
        try await withTaskCancellationHandler {
            socket.resume()
            var iterator = delegate.opened.makeAsyncIterator()
            do {
                guard try await iterator.next() == true else { throw VirtualMachineConsoleError.closed }
            } catch {
                if let response = socket.response as? HTTPURLResponse, response.statusCode != 101 {
                    throw DsmErrorMapper.map(.httpStatus(code: response.statusCode, requestID: UUID()))
                }
                throw error
            }
        } onCancel: { self.socket.cancel(with: .goingAway, reason: nil); self.session.invalidateAndCancel() }
    }
    func receive() async throws -> Data {
        let message = try await socket.receive()
        guard case .data(let data) = message else { throw VirtualMachineConsoleError.invalidResponse }
        return data
    }
    func send(_ data: Data) async throws { try await socket.send(.data(data)) }
    func close() async { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    deinit { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
