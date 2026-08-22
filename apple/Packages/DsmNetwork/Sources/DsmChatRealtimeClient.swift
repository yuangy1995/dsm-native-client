import DsmCore
import Foundation

enum DsmSocketIOAction: Equatable {
    case engineOpened
    case namespaceConnected
    case contentChanged
    case replyPong
    case disconnected
    case ignored
}

enum DsmSocketIOPacketParser {
    static func packets(in frame: String) -> [Substring] {
        frame.split(separator: "\u{001E}", omittingEmptySubsequences: true)
    }

    static func actions(in frame: String) -> [DsmSocketIOAction] {
        packets(in: frame).map(action)
    }

    static func action(for packet: Substring) -> DsmSocketIOAction {
        if packet.hasPrefix("0") { return .engineOpened }
        if packet == "2" { return .replyPong }
        if packet == "1" || packet.hasPrefix("41") || packet.hasPrefix("44") {
            return .disconnected
        }
        if packet.hasPrefix("40") { return .namespaceConnected }
        if packet.hasPrefix("42") { return .contentChanged }
        return .ignored
    }
}

enum DsmChatRealtimeError: Error {
    case invalidEndpoint
    case invalidHandshake
    case disconnected
    case oversizedFrame
}

enum DsmChatSocketRequestBuilder {
    static func make(
        baseURL: URL,
        credential: DsmSessionCredential,
        engineVersion: Int
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil else {
            throw DsmChatRealtimeError.invalidEndpoint
        }
        components.scheme = "wss"
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = "\(basePath)/sc/socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: String(engineVersion)),
            URLQueryItem(name: "transport", value: "websocket")
        ]
        guard let url = components.url else { throw DsmChatRealtimeError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let cookie = credential.cookieHeaderValue {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let token = credential.synoToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        var origin = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        origin?.path = ""
        origin?.query = nil
        origin?.fragment = nil
        if let originURL = origin?.url?.absoluteString {
            request.setValue(originURL, forHTTPHeaderField: "Origin")
        }
        return request
    }
}

/// Synology Chat 官方网页客户端所使用的 Socket.IO 只承担“内容发生变化”的通知。
/// 具体消息仍通过现有 Chat API 回读，避免把内部事件载荷扩散到业务层或日志。
actor DsmChatRealtimeClient {
    private let baseURL: URL
    private let credential: DsmSessionCredential
    private let expectedHost: String
    private let pinnedCertificateSHA256: String?
    private let requiresSystemCertificateTrust: Bool

    private var continuations: [UUID: AsyncStream<ChatRealtimeEvent>.Continuation] = [:]
    private var runTask: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?
    private var activeSession: URLSession?
    private var preferredEngineVersion = 4
    private var didAnnounceConnection = false

    init(
        baseURL: URL,
        credential: DsmSessionCredential,
        expectedHost: String,
        pinnedCertificateSHA256: String?,
        requiresSystemCertificateTrust: Bool
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.expectedHost = expectedHost
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.requiresSystemCertificateTrust = requiresSystemCertificateTrust
    }

    func events() -> AsyncStream<ChatRealtimeEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
        if didAnnounceConnection {
            emit(.disconnected)
            didAnnounceConnection = false
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: ChatRealtimeEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func run() async {
        var retryDelaySeconds = 1
        while !Task.isCancelled {
            let fallbackVersion = preferredEngineVersion == 4 ? 3 : 4
            for version in [preferredEngineVersion, fallbackVersion] {
                guard !Task.isCancelled else { return }
                do {
                    try await runConnection(engineVersion: version)
                    break
                } catch is CancellationError {
                    return
                } catch {
                    if didAnnounceConnection {
                        break
                    }
                }
            }

            guard !Task.isCancelled else { return }
            if didAnnounceConnection {
                emit(.disconnected)
                didAnnounceConnection = false
            }
            do {
                try await Task.sleep(for: .seconds(retryDelaySeconds))
            } catch {
                return
            }
            retryDelaySeconds = min(retryDelaySeconds * 2, 30)
        }
    }

    private func runConnection(engineVersion: Int) async throws {
        let request = try DsmChatSocketRequestBuilder.make(
            baseURL: baseURL,
            credential: credential,
            engineVersion: engineVersion
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let tlsDelegate = DsmTLSDelegate(
            expectedHost: expectedHost,
            pinnedFingerprint: pinnedCertificateSHA256,
            requiresSystemTrust: requiresSystemCertificateTrust
        )
        let session = URLSession(configuration: configuration, delegate: tlsDelegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        activeSession = session
        activeSocket = socket
        socket.resume()
        defer {
            tlsDelegate.unregisterTask(socket)
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            if activeSocket === socket { activeSocket = nil }
            if activeSession === session { activeSession = nil }
        }

        var engineOpened = false
        var namespaceConnected = false
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if let trustError = tlsDelegate.consumeFailure(for: socket) {
                    throw trustError
                }
                throw error
            }
            let frame = try text(from: message)
            for packet in DsmSocketIOPacketParser.packets(in: frame) {
                let action = DsmSocketIOPacketParser.action(for: packet)
                switch action {
                case .engineOpened:
                    guard validEngineHandshake(String(packet)) else {
                        throw DsmChatRealtimeError.invalidHandshake
                    }
                    engineOpened = true
                    try await socket.send(.string("40"))
                case .namespaceConnected:
                    guard engineOpened else { throw DsmChatRealtimeError.invalidHandshake }
                    namespaceConnected = true
                    preferredEngineVersion = engineVersion
                    if !didAnnounceConnection {
                        emit(.connected)
                        didAnnounceConnection = true
                    }
                case .contentChanged:
                    guard namespaceConnected else { continue }
                    emit(.contentChanged)
                case .replyPong:
                    try await socket.send(.string("3"))
                case .disconnected:
                    throw DsmChatRealtimeError.disconnected
                case .ignored:
                    continue
                }
            }
        }
        throw CancellationError()
    }

    private func text(from message: URLSessionWebSocketTask.Message) throws -> String {
        switch message {
        case .string(let value):
            guard value.utf8.count <= 1_048_576 else {
                throw DsmChatRealtimeError.oversizedFrame
            }
            return value
        case .data(let data):
            guard data.count <= 1_048_576, let value = String(data: data, encoding: .utf8) else {
                throw DsmChatRealtimeError.oversizedFrame
            }
            return value
        @unknown default:
            throw DsmChatRealtimeError.invalidHandshake
        }
    }

    private func validEngineHandshake(_ frame: String) -> Bool {
        guard frame.first == "0",
              let data = String(frame.dropFirst()).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = object["sid"] as? String,
              !sid.isEmpty,
              sid.count <= 512 else {
            return false
        }
        return true
    }
}
