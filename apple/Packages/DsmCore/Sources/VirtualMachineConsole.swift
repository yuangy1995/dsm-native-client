import Foundation

public enum VirtualMachineConsoleError: Error, Equatable, Sendable {
    case invalidTarget, forbiddenResource, invalidResponse, closed, unavailable, queueFull
}

/// 固定原虚拟机及单窗口地址；不包含登录凭据，也不接受任意网页转发。
public struct VirtualMachineConsolePolicy: Equatable, Sendable, CustomStringConvertible {
    public static let scheme = "dsm-console"
    public let id: UUID
    public let documentURL: URL
    public let socketURL: URL
    public let localDocumentURL: URL
    private let prefix: String
    public var description: String { "VirtualMachineConsolePolicy" }

    public init(baseURL: URL, machineID: String, name: String, keyboardLayout: String, id: UUID = UUID()) throws {
        guard let origin = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              origin.scheme == "https", origin.host?.isEmpty == false, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, Self.segment(machineID),
              !name.isEmpty, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Self.segment(keyboardLayout), keyboardLayout != "Default" else { throw VirtualMachineConsoleError.invalidTarget }
        let alias = origin.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard alias.isEmpty || Self.segment(alias) else { throw VirtualMachineConsoleError.invalidTarget }
        self.id = id
        prefix = alias.isEmpty ? "" : "/" + alias
        var document = origin
        document.path = prefix + "/webman/3rdparty/Virtualization/noVNC/vnc.html"
        document.queryItems = [
            .init(name: "autoconnect", value: "true"), .init(name: "reconnect", value: "false"),
            .init(name: "path", value: "synovirtualization/ws/" + machineID),
            .init(name: "title", value: name), .init(name: "app_id", value: id.uuidString.lowercased()),
            .init(name: "kb_layout", value: keyboardLayout), .init(name: "app_alias", value: alias), .init(name: "v", value: "")
        ]
        var socket = origin
        socket.scheme = "wss"; socket.path = prefix + "/synovirtualization/ws/" + machineID
        socket.queryItems = [.init(name: "app_id", value: id.uuidString.lowercased())]
        var local = document
        local.scheme = Self.scheme; local.host = id.uuidString.lowercased() + ".invalid"; local.port = nil
        guard let documentURL = document.url, let socketURL = socket.url, let localURL = local.url else {
            throw VirtualMachineConsoleError.invalidTarget
        }
        self.documentURL = documentURL; self.socketURL = socketURL; self.localDocumentURL = localURL
    }

    public func allowsNavigation(_ url: URL) -> Bool { url == localDocumentURL }

    public func remoteResource(for localURL: URL) throws -> URL {
        guard var parts = URLComponents(url: localURL, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme, parts.host == localDocumentURL.host, parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw VirtualMachineConsoleError.forbiddenResource }
        parts.scheme = documentURL.scheme; parts.host = documentURL.host; parts.port = documentURL.port
        guard let remote = parts.url, mediaType(for: remote) != nil else { throw VirtualMachineConsoleError.forbiddenResource }
        return remote
    }

    public func allowsSocket(_ candidate: URL) -> Bool {
        guard let parts = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              ["ws", "wss"].contains(parts.scheme), parts.host == localDocumentURL.host,
              parts.port == nil || parts.port == (parts.scheme == "wss" ? 443 : 80),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return false }
        return parts.percentEncodedPath == URLComponents(url: socketURL, resolvingAgainstBaseURL: false)?.percentEncodedPath
            && parts.queryItems == [.init(name: "app_id", value: id.uuidString.lowercased())]
    }

    public func mediaType(for url: URL) -> String? {
        if url == documentURL { return "text/html" }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == documentURL.host, (parts.port ?? 443) == (documentURL.port ?? 443),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              !parts.percentEncodedPath.contains("%"), !parts.path.contains("\\"),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        if let query = parts.queryItems {
            guard query.count == 1, query[0].name == "v", let value = query[0].value, value.count <= 128,
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        }
        let icon = prefix + "/webman/3rdparty/Virtualization/images/VirtualManagement_"
        if parts.path.hasPrefix(icon), ["16", "24", "32", "48", "64", "72", "256"].contains(String(parts.path.dropFirst(icon.count).dropLast(4))), parts.path.hasSuffix(".png") { return "image/png" }
        let root = prefix + "/webman/3rdparty/Virtualization/noVNC/"
        guard parts.path.hasPrefix(root) else { return nil }
        let relative = String(parts.path.dropFirst(root.count))
        if relative == "app/sounds/bell.oga" { return "audio/ogg" }
        if relative.hasPrefix("app/locale/"), relative.hasSuffix(".json") {
            let locale = String(relative.dropFirst(11).dropLast(5))
            return Self.segment(locale) && locale.count <= 16 ? "application/json" : nil
        }
        switch url.pathExtension.lowercased() {
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "gif": return "image/gif"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return nil
        }
    }

    private static func segment(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

public struct VirtualMachineConsoleResource: Sendable {
    public let data: Data
    public let mediaType: String
    public let serverPolicy: String?
    public init(data: Data, mediaType: String, serverPolicy: String? = nil) {
        self.data = data; self.mediaType = mediaType; self.serverPolicy = serverPolicy
    }
}

/// 一次控制台生命周期；关闭后不得再读资源或重新发送输入。
public protocol VirtualMachineConsoleTransport: Sendable {
    func resource(_ url: URL) async throws -> VirtualMachineConsoleResource
    func connect() async throws
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close() async
}

/// 只在内存中持有受限传输器；网页和调用方无法取得登录 Cookie。
public struct VirtualMachineConsoleSession: Equatable, Sendable, Identifiable, CustomStringConvertible {
    public var id: UUID { policy.id }
    public var url: URL { policy.documentURL }
    public let policy: VirtualMachineConsolePolicy
    public let transport: any VirtualMachineConsoleTransport
    public var description: String { "VirtualMachineConsoleSession" }
    public init(policy: VirtualMachineConsolePolicy, transport: any VirtualMachineConsoleTransport) {
        self.policy = policy; self.transport = transport
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
