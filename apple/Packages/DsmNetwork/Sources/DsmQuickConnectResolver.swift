import CryptoKit
import DsmCore
import Foundation
import DsmLocalization

public enum QuickConnectEndpointKind: Equatable, Sendable {
    case local
    case external
    case relay
}

public struct QuickConnectEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let kind: QuickConnectEndpointKind

    public init(host: String, port: Int, kind: QuickConnectEndpointKind = .external) {
        self.host = host
        self.port = port
        self.kind = kind
    }
}

public enum QuickConnectResolutionError: Error, Equatable, Sendable {
    case notFound
    case offline
    case noDirectRoute
    case relayDisabled
    case relayUnavailable
    case relayIdentityMismatch
    case serviceUnavailable
    case invalidResponse
}

extension QuickConnectResolutionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound:
            L10n.string("shared.d96486036c975839")
        case .offline:
            L10n.string("shared.d2273a40a6f9387a")
        case .noDirectRoute:
            L10n.string("shared.2952c5ce0efa0ffd")
        case .relayDisabled:
            L10n.string("shared.ef6c11be2ae49b06")
        case .relayUnavailable:
            L10n.string("shared.9e73a1cad5867f75")
        case .relayIdentityMismatch:
            L10n.string("shared.9edd5ea14dc200aa")
        case .serviceUnavailable:
            L10n.string("shared.25e80b22c8d9f4e6")
        case .invalidResponse:
            L10n.string("shared.b0738d49115e3229")
        }
    }
}

public protocol QuickConnectResolving: Sendable {
    func resolve(id: String) async throws -> [QuickConnectEndpoint]
    func requestRelay(id: String) async throws -> QuickConnectEndpoint
}

private struct QuickConnectCommand: Encodable {
    let version = 1
    let command: String
    let stopWhenError = false
    let stopWhenSuccess: Bool
    let id = "mainapp_https"
    let serverID: String
    let isGofile = false
    let path = ""

    private enum CodingKeys: String, CodingKey {
        case version
        case command
        case stopWhenError = "stop_when_error"
        case stopWhenSuccess = "stop_when_success"
        case id
        case serverID
        case isGofile = "is_gofile"
        case path
    }
}

private struct QuickConnectResponse: Decodable {
    let errno: Int
    let server: Server?
    let service: Service?
    let smartDNS: SmartDNS?

    struct Server: Decodable {
        let state: String?
        let serverID: String?
        let pingpongPath: String?

        private enum CodingKeys: String, CodingKey {
            case state = "ds_state"
            case serverID
            case pingpongPath = "pingpong_path"
        }
    }

    struct Service: Decodable {
        let port: Int?
        let relayIP: String?
        let relayPort: Int?

        private enum CodingKeys: String, CodingKey {
            case port
            case relayIP = "relay_ip"
            case relayPort = "relay_port"
        }
    }

    struct SmartDNS: Decodable {
        let host: String?
        let lan: [String]?
    }

    struct Environment: Decodable {
        let controlHost: String?
        let relayRegion: String?

        private enum CodingKeys: String, CodingKey {
            case controlHost = "control_host"
            case relayRegion = "relay_region"
        }
    }

    let environment: Environment?

    private enum CodingKeys: String, CodingKey {
        case errno
        case server
        case service
        case smartDNS = "smartdns"
        case environment = "env"
    }
}

private struct QuickConnectPingPongResponse: Decodable {
    let ezid: String
}

struct QuickConnectRelayDescriptor {
    let endpoint: QuickConnectEndpoint
    let serverID: String
    let pingpongPath: String
}

public actor DsmQuickConnectResolver: QuickConnectResolving {
    private let session: URLSession
    private let controlURLs: [URL]
    private let maximumResponseBytes: Int

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)

        let isChina = Locale.current.region?.identifier.uppercased() == "CN"
        let domains = isChina
            ? ["global.quickconnect.cn", "global.quickconnect.to"]
            : ["global.quickconnect.to", "global.quickconnect.cn"]
        controlURLs = domains.compactMap { URL(string: "https://\($0)/Serv.php") }
        maximumResponseBytes = 1_024 * 1_024
    }

    init(
        session: URLSession,
        controlURLs: [URL],
        maximumResponseBytes: Int = 1_024 * 1_024
    ) {
        self.session = session
        self.controlURLs = controlURLs
        self.maximumResponseBytes = max(maximumResponseBytes, 1)
    }

    public func resolve(id: String) async throws -> [QuickConnectEndpoint] {
        guard NasAddressParser.isPotentialQuickConnectID(id) else {
            throw QuickConnectResolutionError.notFound
        }

        var lastError: Error = QuickConnectResolutionError.serviceUnavailable

        for controlURL in controlURLs {
            do {
                let data = try await send(
                    command: "get_server_info",
                    stopWhenSuccess: false,
                    serverID: id,
                    to: controlURL
                )
                return try Self.decodeEndpoints(from: data)
            } catch let error as QuickConnectResolutionError {
                lastError = error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = QuickConnectResolutionError.serviceUnavailable
            }
        }

        throw lastError
    }

    public func requestRelay(id: String) async throws -> QuickConnectEndpoint {
        guard NasAddressParser.isPotentialQuickConnectID(id) else {
            throw QuickConnectResolutionError.notFound
        }

        let controlURL = try await resolveControlURL(id: id)
        var lastError: Error = QuickConnectResolutionError.relayUnavailable

        for attempt in 0..<3 {
            do {
                // Synology 内部 API：公开白皮书描述了中继流程，但未公开此控制请求契约。
                let data = try await send(
                    command: "request_tunnel",
                    stopWhenSuccess: true,
                    serverID: id,
                    to: controlURL
                )
                let descriptor = try Self.decodeRelayDescriptor(from: data, quickConnectID: id)
                try await verifyRelay(descriptor)
                return descriptor.endpoint
            } catch let error as QuickConnectResolutionError where error == .relayDisabled {
                throw error
            } catch let error as QuickConnectResolutionError where error == .relayIdentityMismatch {
                // 身份不一致属于安全失败，不应通过重新申请中继来自动绕过。
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(for: .seconds(attempt + 1))
                }
            }
        }

        if let error = lastError as? QuickConnectResolutionError,
           error == .relayIdentityMismatch {
            throw error
        }
        throw QuickConnectResolutionError.relayUnavailable
    }

    private func resolveControlURL(id: String) async throws -> URL {
        var lastError: Error = QuickConnectResolutionError.serviceUnavailable
        for controlURL in controlURLs {
            do {
                let data = try await send(
                    command: "get_server_info",
                    stopWhenSuccess: false,
                    serverID: id,
                    to: controlURL
                )
                let host = try Self.decodeControlHost(from: data)
                guard let url = URL(string: "https://\(host)/Serv.php") else {
                    throw QuickConnectResolutionError.invalidResponse
                }
                return url
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func send(
        command: String,
        stopWhenSuccess: Bool,
        serverID: String,
        to controlURL: URL
    ) async throws -> Data {
        let body = try JSONEncoder().encode([
            QuickConnectCommand(
                command: command,
                stopWhenSuccess: stopWhenSuccess,
                serverID: serverID
            )
        ])
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = command == "request_tunnel" ? 30 : 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await boundedData(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw QuickConnectResolutionError.serviceUnavailable
        }
        return data
    }

    private func verifyRelay(_ descriptor: QuickConnectRelayDescriptor) async throws {
        guard descriptor.pingpongPath.hasPrefix("/"),
              descriptor.pingpongPath.count <= 2_048,
              !descriptor.pingpongPath.contains("://"),
              !descriptor.pingpongPath.contains("#"),
              let url = URL(
                string: "https://\(descriptor.endpoint.host)\(descriptor.pingpongPath)"
              ),
              url.host?.lowercased() == descriptor.endpoint.host else {
            throw QuickConnectResolutionError.invalidResponse
        }

        let expectedID = Insecure.MD5.hash(data: Data(descriptor.serverID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        for attempt in 0..<6 {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await boundedData(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw QuickConnectResolutionError.relayUnavailable
                }
                let pingPong = try JSONDecoder().decode(QuickConnectPingPongResponse.self, from: data)
                guard pingPong.ezid.lowercased() == expectedID else {
                    throw QuickConnectResolutionError.relayIdentityMismatch
                }
                return
            } catch let error as QuickConnectResolutionError where error == .relayIdentityMismatch {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt < 5 {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
        throw QuickConnectResolutionError.relayUnavailable
    }

    /// QuickConnect 控制响应必须在累积前受限，不能先由 data(for:) 无界缓冲。
    private func boundedData(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw QuickConnectResolutionError.invalidResponse
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(
                min(Int(response.expectedContentLength), maximumResponseBytes)
            )
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw QuickConnectResolutionError.invalidResponse
            }
            data.append(byte)
        }
        return (data, response)
    }

    static func decodeEndpoints(from data: Data) throws -> [QuickConnectEndpoint] {
        let responses: [QuickConnectResponse]
        do {
            responses = try JSONDecoder().decode([QuickConnectResponse].self, from: data)
        } catch {
            throw QuickConnectResolutionError.invalidResponse
        }

        guard let response = responses.first(where: { $0.errno == 0 }) else {
            throw QuickConnectResolutionError.notFound
        }
        guard response.server?.state?.uppercased() == "CONNECTED" else {
            throw QuickConnectResolutionError.offline
        }
        guard let port = response.service?.port,
              (1...65_535).contains(port) else {
            throw QuickConnectResolutionError.noDirectRoute
        }

        var seen = Set<String>()
        let local = (response.smartDNS?.lan ?? []).compactMap { host -> QuickConnectEndpoint? in
            let normalized = host.lowercased()
            guard Self.isTrustedDirectHost(normalized), seen.insert(normalized).inserted else {
                return nil
            }
            return QuickConnectEndpoint(host: normalized, port: port, kind: .local)
        }
        let external = [response.smartDNS?.host].compactMap { host -> QuickConnectEndpoint? in
            guard let host else {
                return nil
            }
            let normalized = host.lowercased()
            guard Self.isTrustedDirectHost(normalized), seen.insert(normalized).inserted else {
                return nil
            }
            return QuickConnectEndpoint(host: normalized, port: port, kind: .external)
        }
        let endpoints = local + external
        guard !endpoints.isEmpty else {
            throw QuickConnectResolutionError.noDirectRoute
        }
        return endpoints
    }

    static func decodeControlHost(from data: Data) throws -> String {
        let responses = try decodeResponses(from: data)
        guard let response = responses.first(where: { $0.errno == 0 }),
              response.server?.state?.uppercased() == "CONNECTED",
              let host = response.environment?.controlHost?.lowercased(),
              isTrustedControlHost(host) else {
            throw QuickConnectResolutionError.invalidResponse
        }
        return host
    }

    static func decodeRelayDescriptor(
        from data: Data,
        quickConnectID: String
    ) throws -> QuickConnectRelayDescriptor {
        let responses = try decodeResponses(from: data)
        if responses.contains(where: { $0.errno == 19 }) {
            throw QuickConnectResolutionError.relayDisabled
        }
        guard let response = responses.first(where: { $0.errno == 0 }),
              let relayIP = response.service?.relayIP,
              !relayIP.isEmpty,
              let relayPort = response.service?.relayPort,
              (1...65_535).contains(relayPort),
              let serverID = response.server?.serverID,
              !serverID.isEmpty,
              let region = response.environment?.relayRegion?.lowercased(),
              isValidHostLabel(region),
              let controlHost = response.environment?.controlHost?.lowercased(),
              isTrustedControlHost(controlHost) else {
            throw QuickConnectResolutionError.relayUnavailable
        }

        let topDomain = controlHost.hasSuffix(".quickconnect.cn") ? "cn" : "to"
        let host = "\(quickConnectID.lowercased()).\(region).quickconnect.\(topDomain)"
        guard isTrustedRelayHost(host) else {
            throw QuickConnectResolutionError.invalidResponse
        }
        let pingpongPath = response.server?.pingpongPath
            ?? "/webman/pingpong.cgi?action=cors&quickconnect=true"
        return QuickConnectRelayDescriptor(
            endpoint: QuickConnectEndpoint(host: host, port: 443, kind: .relay),
            serverID: serverID,
            pingpongPath: pingpongPath
        )
    }

    private static func decodeResponses(from data: Data) throws -> [QuickConnectResponse] {
        do {
            return try JSONDecoder().decode([QuickConnectResponse].self, from: data)
        } catch {
            throw QuickConnectResolutionError.invalidResponse
        }
    }

    private static func isTrustedDirectHost(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 4,
              labels[labels.count - 3] == "direct",
              labels[labels.count - 2] == "quickconnect",
              labels.last == "to" || labels.last == "cn" else {
            return false
        }
        return labels.allSatisfy { isValidHostLabel(String($0)) }
    }

    public static func isTrustedRelayHost(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4,
              labels[1] != "direct",
              labels[2] == "quickconnect",
              labels[3] == "to" || labels[3] == "cn" else {
            return false
        }
        return isValidHostLabel(String(labels[0])) && isValidHostLabel(String(labels[1]))
    }

    private static func isTrustedControlHost(_ host: String) -> Bool {
        (host.hasSuffix(".quickconnect.to") || host.hasSuffix(".quickconnect.cn"))
            && host.split(separator: ".").allSatisfy { isValidHostLabel(String($0)) }
    }

    private static func isValidHostLabel(_ value: String) -> Bool {
        guard (1...63).contains(value.count), value.first != "-", value.last != "-" else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}
