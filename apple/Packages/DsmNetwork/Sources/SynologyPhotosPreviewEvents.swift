import Foundation

/// Photos 官方 Socket.IO 完成通知；静态协议证据见 photos-advanced-management.md。
/// 只负责订阅与核对，不发起重建、不从断线或队列消失推断成功。
enum PhotosPreviewEventError: Error, Equatable {
    case invalidEndpoint, invalidState, invalidFrame, disconnected, connectionRejected, timedOut
}

enum PhotosPreviewSocketRequest {
    static func make(applicationURL: URL, credential: DsmSessionCredential) throws -> URLRequest {
        guard var parts = URLComponents(url: applicationURL, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let cookie = credential.cookieHeaderValue else { throw PhotosPreviewEventError.invalidEndpoint }
        let directory = parts.path.hasSuffix("/") ? parts.path : parts.path.lastIndex(of: "/").map { String(parts.path[...$0]) } ?? ""
        parts.scheme = "wss"
        parts.path = directory + (directory.hasSuffix("/") ? "" : "/") + "FotoSocketIo/socket.io/"
        parts.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        // 官方握手使用SynoToken查询项；不得记录请求URL或包含URL的底层错误。
        if let token = credential.synoToken, !token.isEmpty { parts.queryItems?.append(URLQueryItem(name: "SynoToken", value: token)) }
        guard let url = parts.url else { throw PhotosPreviewEventError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        var origin = URLComponents(url: applicationURL, resolvingAgainstBaseURL: false)
        origin?.path = ""; origin?.query = nil; origin?.fragment = nil
        request.setValue(origin?.url?.absoluteString, forHTTPHeaderField: "Origin")
        return request
    }
}

enum PhotosPreviewSocketPacket: Equatable {
    case opened, connected, ping, completed(unitID: Int, success: Bool), ignored

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 1_048_576 else { throw PhotosPreviewEventError.invalidFrame }
        if text == "2" { return .ping }
        if text.hasPrefix("44") { throw PhotosPreviewEventError.connectionRejected }
        if text == "1" || text.hasPrefix("41") { throw PhotosPreviewEventError.disconnected }
        if text.hasPrefix("0") {
            struct Handshake: Decodable { let sid: String; let pingInterval: Int; let pingTimeout: Int }
            guard let value = try? JSONDecoder().decode(Handshake.self, from: Data(text.dropFirst().utf8)),
                  !value.sid.isEmpty, value.pingInterval > 0, value.pingTimeout > 0 else { throw PhotosPreviewEventError.invalidFrame }
            return .opened
        }
        if text == "40" { return .connected }
        if text.hasPrefix("40") {
            struct Namespace: Decodable { let sid: String }
            guard let value = try? JSONDecoder().decode(Namespace.self, from: Data(text.dropFirst(2).utf8)), !value.sid.isEmpty else { throw PhotosPreviewEventError.invalidFrame }
            return .connected
        }
        guard text.hasPrefix("42") else { return .ignored }
        guard let array = try? JSONSerialization.jsonObject(with: Data(text.dropFirst(2).utf8)) as? [Any],
              let name = array.first as? String else { throw PhotosPreviewEventError.invalidFrame }
        guard name == "regenerate-preview" else { return .ignored }
        struct Event: Decodable {
            let data: Completion
            struct Completion: Decodable { let idUnit: Int; let success: Bool }
        }
        guard array.count == 2, JSONSerialization.isValidJSONObject(array[1]),
              let bytes = try? JSONSerialization.data(withJSONObject: array[1]),
              let event = try? JSONDecoder().decode(Event.self, from: bytes), event.data.idUnit > 0 else { throw PhotosPreviewEventError.invalidFrame }
        return .completed(unitID: event.data.idUnit, success: event.data.success)
    }

    static func registration(unitID: Int) throws -> String {
        guard unitID > 0 else { throw PhotosPreviewEventError.invalidState }
        let bytes = try JSONSerialization.data(withJSONObject: ["regenerate-preview", ["idUnit": unitID, "operation": "register"]] as [Any], options: [.sortedKeys])
        return "42" + String(decoding: bytes, as: UTF8.self)
    }
}

/// 传输替身仅替换收发，不改变握手、订阅、超时和结果判断，便于离线契约验证。
protocol PhotosPreviewSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close() async
}

actor SynologyPhotosPreviewEvents {
    private enum Phase { case idle, connecting, subscribed(Int), waiting(Int), closed }
    private var socket: any PhotosPreviewSocket
    private let reconnect: (@Sendable () throws -> any PhotosPreviewSocket)?
    private let reconnectDelay: @Sendable (Duration) async throws -> Void
    private let timeout: Duration
    private var phase: Phase = .idle

    init(socket: any PhotosPreviewSocket, timeout: Duration = .seconds(600),
         reconnect: (@Sendable () throws -> any PhotosPreviewSocket)? = nil,
         reconnectDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.socket = socket; self.timeout = timeout
        self.reconnect = reconnect; self.reconnectDelay = reconnectDelay
    }

    init(applicationURL: URL, credential: DsmSessionCredential, pinnedCertificate: String?, requiresSystemTrust: Bool) throws {
        let request = try PhotosPreviewSocketRequest.make(applicationURL: applicationURL, credential: credential)
        let host = applicationURL.host!
        let factory: @Sendable () -> any PhotosPreviewSocket = {
            PhotosPreviewURLSocket(request: request, expectedHost: host, pinnedCertificate: pinnedCertificate, requiresSystemTrust: requiresSystemTrust)
        }
        self.init(socket: factory(), reconnect: factory)
    }

    /// 先完成订阅，调用方才能发起对应照片的重建写请求。
    func subscribe(unitID: Int) async throws {
        guard unitID > 0, case .idle = phase else { throw PhotosPreviewEventError.invalidState }
        phase = .connecting
        do {
            try await register(unitID: unitID, on: socket, timeout: min(timeout, .seconds(20)))
            try Task.checkCancellation()
            guard case .connecting = phase else { throw CancellationError() }
            phase = .subscribed(unitID)
        } catch { await close(); if Task.isCancelled { throw CancellationError() }; throw error }
    }

    /// 重连只重新订阅同一目标；总等待时间不因断线延长，不重发重建请求。
    func completion() async throws -> Bool {
        guard case .subscribed(let unitID) = phase else { throw PhotosPreviewEventError.invalidState }
        phase = .waiting(unitID)
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
        var attempts = 0, needsRegistration = false
        do {
            while true {
                try Task.checkCancellation()
                guard case .waiting = phase else { throw PhotosPreviewEventError.disconnected }
                do {
                    let remaining = clock.now.duration(to: deadline)
                    guard remaining > .zero else { throw PhotosPreviewEventError.timedOut }
                    if needsRegistration {
                        try await register(unitID: unitID, on: socket, timeout: min(remaining, .seconds(20)))
                        needsRegistration = false
                    }
                    let remainingAfterRegistration = clock.now.duration(to: deadline)
                    guard remainingAfterRegistration > .zero else { throw PhotosPreviewEventError.timedOut }
                    let success = try await bounded(on: socket, for: remainingAfterRegistration) { [socket] in
                        while true {
                            try Task.checkCancellation()
                            switch try PhotosPreviewSocketPacket.decode(await socket.receive()) {
                            case .completed(let id, let success) where id == unitID: return success
                            case .ping: try await socket.send("3")
                            case .opened, .connected: throw PhotosPreviewEventError.invalidFrame
                            default: continue
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard case .waiting = phase else { throw CancellationError() }
                    await close()
                    return success
                } catch {
                    try Task.checkCancellation()
                    guard error as? PhotosPreviewEventError == .disconnected,
                          case .waiting = phase, let reconnect, attempts < 3 else { throw error }
                    await socket.close()
                    attempts += 1
                    let remaining = clock.now.duration(to: deadline)
                    guard remaining > .zero else { throw PhotosPreviewEventError.timedOut }
                    try await reconnectDelay(min(.seconds(attempts), remaining))
                    try Task.checkCancellation()
                    guard case .waiting = phase else { throw PhotosPreviewEventError.disconnected }
                    guard clock.now < deadline else { throw PhotosPreviewEventError.timedOut }
                    socket = try reconnect()
                    needsRegistration = true
                }
            }
        } catch { await close(); if Task.isCancelled { throw CancellationError() }; throw error }
    }

    private func register(unitID: Int, on socket: any PhotosPreviewSocket, timeout: Duration) async throws {
        try await bounded(on: socket, for: timeout) {
            var opened = false
            while true {
                try Task.checkCancellation()
                switch try PhotosPreviewSocketPacket.decode(await socket.receive()) {
                case .opened:
                    guard !opened else { throw PhotosPreviewEventError.invalidFrame }
                    opened = true; try await socket.send("40")
                case .connected:
                    guard opened else { throw PhotosPreviewEventError.invalidFrame }
                    try await socket.send(PhotosPreviewSocketPacket.registration(unitID: unitID))
                    return true
                case .ping: try await socket.send("3")
                case .completed: throw PhotosPreviewEventError.invalidFrame
                case .ignored: continue
                }
            }
        }
    }

    func close() async { phase = .closed; await socket.close() }

    @discardableResult
    private func bounded(on socket: any PhotosPreviewSocket, for duration: Duration, operation: @escaping @Sendable () async throws -> Bool) async throws -> Bool {
        enum Outcome: Sendable { case result(Bool), timeout }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask { .result(try await operation()) }
                group.addTask {
                    try await Task.sleep(for: duration)
                    return .timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                switch result {
                case .result(let value): return value
                case .timeout:
                    await socket.close()
                    throw PhotosPreviewEventError.timedOut
                }
            }
        } onCancel: { [socket] in Task { await socket.close() } }
    }
}

/// 沿用DSM证书和重定向规则；不给底层NSError中的握手URL进入用户提示或日志。
private final class PhotosPreviewURLSocket: PhotosPreviewSocket {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let trust: DsmTLSDelegate

    init(request: URLRequest, expectedHost: String, pinnedCertificate: String?, requiresSystemTrust: Bool) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 660
        trust = DsmTLSDelegate(expectedHost: expectedHost, pinnedFingerprint: pinnedCertificate, requiresSystemTrust: requiresSystemTrust)
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        trust.registerTaskForTrustFailures(socket)
        socket.resume()
    }

    func send(_ text: String) async throws {
        do { try await socket.send(.string(text)) }
        catch { throw failure() }
    }

    func receive() async throws -> String {
        do {
            guard case .string(let text) = try await socket.receive(), text.utf8.count <= 1_048_576 else { throw PhotosPreviewEventError.invalidFrame }
            return text
        } catch let error as PhotosPreviewEventError { throw error }
        catch { throw failure() }
    }

    private func failure() -> any Error {
        if Task.isCancelled { return CancellationError() }
        if let error = trust.consumeFailure(for: socket) { return error }
        return PhotosPreviewEventError.disconnected
    }

    func close() async {
        socket.cancel(with: .goingAway, reason: nil)
        trust.unregisterTask(socket)
        session.invalidateAndCancel()
    }

    deinit { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
