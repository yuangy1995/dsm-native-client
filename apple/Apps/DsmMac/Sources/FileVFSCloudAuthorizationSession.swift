import DsmCore
import DsmLocalization
import Foundation
import Network

/// 使用系统浏览器和一次性本机回调，不接触云服务的登录表单。
/// 监听地址固定为 IPv4 loopback，端口由系统分配；结束即关闭，不提供局域网服务。
@MainActor
final class FileVFSCloudAuthorizationSession {
    private let request: FileVFSCloudAuthorizationRequest
    private let onAuthorization: (FileVFSCloudAuthorization) -> Void
    private let onFailure: (String) -> Void
    private let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var listener: NWListener?
    private var connections: [UUID: (connection: NWConnection, bytes: Data)] = [:]
    private var timeout: Task<Void, Never>?
    private var boundRequest: FileVFSCloudAuthorizationRequest?
    private(set) var loginURL: URL?
    private(set) var callbackBaseURL: URL?
    private(set) var isRunning = false
    private var completed = false

    init(request: FileVFSCloudAuthorizationRequest,
         onAuthorization: @escaping (FileVFSCloudAuthorization) -> Void, onFailure: @escaping (String) -> Void) {
        self.request = request; self.onAuthorization = onAuthorization; self.onFailure = onFailure
    }

    func start(onReady: @escaping @MainActor (URL) -> Void) throws {
        guard listener == nil, !completed else { throw URLError(.cannotConnectToHost) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener; isRunning = true
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.completed else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port,
                          let origin = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.nonce)"),
                          var url = URLComponents(url: self.request.loginURL, resolvingAgainstBaseURL: false) else {
                        self.fail(); return
                    }
                    let callback = "_lanstash_" + self.nonce
                    var fields = (url.queryItems ?? []).filter { !["host", "callback"].contains($0.name) }
                    fields += [.init(name: "host", value: origin.absoluteString), .init(name: "callback", value: callback)]
                    url.queryItems = fields
                    guard let login = url.url else { self.fail(); return }
                    self.callbackBaseURL = origin; self.loginURL = login
                    self.boundRequest = .init(id: self.request.id, profileID: self.request.profileID, protocolID: self.request.protocolID,
                        loginURL: login, callbackName: callback)
                    onReady(login)
                case .failed: self.fail()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, !self.completed, self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = (connection, Data())
                connection.start(queue: .main)
                self.receive(id)
            }
        }
        listener.start(queue: .main)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self, !self.completed else { return }
            self.onFailure(L10n.string("files.vfs.authorizationExpired")); self.stop()
        }
    }

    func stop() {
        completed = true; isRunning = false; timeout?.cancel(); timeout = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        for value in connections.values { value.connection.cancel() }
        connections.removeAll(); loginURL = nil; callbackBaseURL = nil; boundRequest = nil
    }

    private func fail() { onFailure(L10n.string("files.vfs.authorizationFailed")); stop() }

    private func receive(_ id: UUID) {
        guard let connection = connections[id]?.connection, !completed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, finished, error in
            Task { @MainActor in
                guard let self, var value = self.connections[id], !self.completed else { return }
                if let data { value.bytes.append(data); self.connections[id] = value }
                do {
                    if let incoming = try FileVFSCloudCallbackHTTP.decode(value.bytes) { self.handle(incoming, connectionID: id); return }
                    if finished || error != nil { self.reply(id, status: 400); return }
                    self.receive(id)
                } catch { self.reply(id, status: 400) }
            }
        }
    }

    private func handle(_ incoming: FileVFSCloudCallbackHTTP.Request, connectionID: UUID) {
        guard let origin = callbackBaseURL, let request = boundRequest,
              incoming.host == "127.0.0.1:\(origin.port!)",
              incoming.path == origin.path || incoming.path.hasPrefix(origin.path + "/") else {
            reply(connectionID, status: 404); return
        }
        do {
            let payload = try incoming.authorizationPayload(callbackName: request.callbackName)
            let authorization = try FileVFSCloudAuthorization.decode(payload, for: request)
            completed = true
            reply(connectionID, status: 200) { [weak self] in
                guard let self, self.isRunning else { return }
                self.stop(); self.onAuthorization(authorization)
            }
        } catch { reply(connectionID, status: 400) }
    }

    private func reply(_ id: UUID, status: Int, onSent: (@MainActor () -> Void)? = nil) {
        guard let connection = connections[id]?.connection else { return }
        let scriptNonce = UUID().uuidString
        let text = L10n.string(status == 200 ? "files.vfs.browserAuthorizationComplete" : "files.vfs.authorizationFailed")
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let html = "<!doctype html><meta charset=\"utf-8\"><p>\(text)</p><script nonce=\"\(scriptNonce)\">history.replaceState(null,'','/complete');window.close();</script>"
        let body = Data(html.utf8)
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Invalid Callback")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'nonce-\(scriptNonce)'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.connections.removeValue(forKey: id); connection.cancel(); onSent?()
            }
        })
    }
}

/// 只支持浏览器回调所需的一次 GET / POST；不转发请求、不读取文件、不记录正文。
enum FileVFSCloudCallbackHTTP {
    struct Request {
        let host: String
        let path: String
        let query: String?
        let contentType: String?
        let body: Data

        func authorizationPayload(callbackName: String) throws -> Data {
            var fields = try FileVFSCloudCallbackHTTP.form(query ?? "")
            if !body.isEmpty {
                let incoming: [String: String]
                if contentType?.hasPrefix("application/json") == true {
                    incoming = try FileVFSCloudCallbackHTTP.jsonFields(body)
                } else if contentType?.hasPrefix("application/x-www-form-urlencoded") == true {
                    guard let text = String(data: body, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                    incoming = try FileVFSCloudCallbackHTTP.form(text)
                } else { throw URLError(.cannotDecodeContentData) }
                try FileVFSCloudCallbackHTTP.merge(incoming, into: &fields)
            }
            // 官方中继可能通过表单包装其 postMessage JSON；仅展开 data，不遍历其他内容。
            if let data = fields.removeValue(forKey: "data")?.data(using: .utf8) {
                try FileVFSCloudCallbackHTTP.merge(FileVFSCloudCallbackHTTP.jsonFields(data), into: &fields)
            }
            guard fields["callback"] == callbackName else { throw URLError(.cannotDecodeContentData) }
            var result: [String: Any] = [:]
            for key in ["callback", "account", "client_id", "access_token", "refresh_token"] {
                if let value = fields[key] { result[key] = value }
            }
            if let value = fields["expires_in"] {
                guard let seconds = Int(value), seconds >= 0 else { throw URLError(.cannotDecodeContentData) }
                result["expires_in"] = seconds
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
    }

    static func decode(_ bytes: Data) throws -> Request? {
        guard bytes.count <= 131_072 else { throw URLError(.dataLengthExceedsMaximum) }
        guard let split = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > 16_384 { throw URLError(.badServerResponse) }; return nil
        }
        guard split.lowerBound <= 16_384, let header = String(data: bytes[..<split.lowerBound], encoding: .utf8) else { throw URLError(.badServerResponse) }
        let lines = header.components(separatedBy: "\r\n")
        let start = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, ["GET", "POST"].contains(String(start[0])), start[1].hasPrefix("/"),
              ["HTTP/1.1", "HTTP/1.0"].contains(String(start[2])),
              let url = URLComponents(string: String(start[1])), url.host == nil, url.fragment == nil else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw URLError(.badServerResponse) }
            let key = String(line[..<colon]).lowercased()
            guard headers[key] == nil else { throw URLError(.badServerResponse) }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let host = headers["host"], headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), (0...114_688).contains(length),
              start[0] != "POST" || headers["content-length"] != nil else { throw URLError(.badServerResponse) }
        guard bytes.count >= split.upperBound + length else { return nil }
        guard bytes.count == split.upperBound + length else { throw URLError(.badServerResponse) }
        return .init(host: host, path: url.path, query: url.percentEncodedQuery, contentType: headers["content-type"]?.lowercased(),
            body: Data(bytes[split.upperBound...]))
    }

    private static func form(_ text: String) throws -> [String: String] {
        guard let items = URLComponents(string: "?" + text.replacingOccurrences(of: "+", with: "%20"))?.queryItems else {
            if text.isEmpty { return [:] }; throw URLError(.cannotDecodeContentData)
        }
        var fields: [String: String] = [:]
        for item in items {
            guard fields[item.name] == nil, let value = item.value else { throw URLError(.cannotDecodeContentData) }
            fields[item.name] = value
        }
        return fields
    }
    private static func jsonFields(_ data: Data) throws -> [String: String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotDecodeContentData) }
        var fields: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String { fields[key] = string }
            else if key == "expires_in", let number = value as? NSNumber {
                guard CFGetTypeID(number) != CFBooleanGetTypeID() else { throw URLError(.cannotDecodeContentData) }
                fields[key] = number.stringValue
            }
        }
        return fields
    }
    private static func merge(_ values: [String: String], into fields: inout [String: String]) throws {
        for (key, value) in values {
            guard fields[key] == nil || fields[key] == value else { throw URLError(.cannotDecodeContentData) }
            fields[key] = value
        }
    }
}
