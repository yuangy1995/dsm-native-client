#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 仅合成服务商与记录，界面测试沿用真实的请求、回执和恢复路径。
actor MobileDDNSUITransport: DsmHTTPTransport {
    struct Request: Sendable { let api: String; let method: String; let fields: [String: String] }
    private var mode: String
    private var records: [[String: Any]]
    private var calls: [Request] = []
    private var submitted = false
    private var didFail = false
    private var block: String?
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiters: [(String, Int, CheckedContinuation<Void, Never>)] = []

    init(mode: String = "nas-ddns") {
        self.mode = mode
        self.records = mode == "nas-ddns-empty" || mode == "nas-ddns-unknown-create" ? [] : [Self.record()]
        if mode == "nas-ddns-recover" { self.records = [Self.record(hostname: "created.example.invalid")] }
    }
    func setMode(_ mode: String) { self.mode = mode }
    func requests() -> [Request] { calls }
    func replaceRecord() { records = [Self.record(hostname: "changed.example.invalid")] }
    func clearRecords() { records = [] }
    func blockNext(_ method: String) { block = method }
    func release() { block = nil; blocked?.resume(); blocked = nil }
    func waitFor(_ method: String, count: Int = 1) async {
        if calls.filter({ $0.method == method }).count >= count { return }
        await withCheckedContinuation { waiters.append((method, count, $0)) }
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + text)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let api = fields["api"] ?? "", method = fields["method"] ?? ""
        calls.append(.init(api: api, method: method, fields: fields))
        let complete = waiters.filter { method, count, _ in calls.filter { $0.method == method }.count >= count }
        waiters.removeAll { method, count, _ in calls.filter { $0.method == method }.count >= count }
        for item in complete { item.2.resume() }
        if block == method { block = nil; await withCheckedContinuation { blocked = $0 } }
        if method == "list" {
            if mode == "nas-ddns-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-ddns-error" || mode == "nas-ddns-retry" && !didFail {
                didFail = true; throw URLError(.notConnectedToInternet)
            }
            if submitted && ["nas-ddns-unknown-create", "nas-ddns-unknown-save", "nas-ddns-accepted-offline"].contains(mode) {
                throw URLError(.notConnectedToInternet)
            }
            if api == DsmAPIName.coreDDNSProvider {
                return response(["providers": [["id": "Example", "display": "Sample provider"],
                                                ["id": "Synology", "display": "Synology"]]])
            }
            if mode == "nas-ddns-incomplete" { return response(["records": [["provider": "Example"]]]) }
            return response(["records": records])
        }
        guard api == DsmAPIName.coreDDNSRecord else { throw URLError(.unsupportedURL) }
        if mode == "nas-ddns-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
        switch method {
        case "test", "update_ip_address": break
        case "create", "set":
            let provider = fields["provider"] ?? "Example"
            var record = Self.record(hostname: fields["hostname"] ?? "nas.example.invalid")
            record["provider"] = provider
            record["username"] = fields["username"] ?? "synthetic-user"
            record["enable"] = fields["enable"] == "true"
            record["heartbeat"] = fields["heartbeat"] == "true"
            records.removeAll { ($0["provider"] as? String) == provider }; records.append(record)
        case "delete":
            let ids = (try? JSONDecoder().decode([String].self, from: Data((fields["id"] ?? "[]").utf8))) ?? []
            records.removeAll { ids.contains(($0["provider"] as? String) ?? "") }
        default: throw URLError(.unsupportedURL)
        }
        submitted = true
        if ["nas-ddns-unknown-create", "nas-ddns-unknown-save", "nas-ddns-instant-unknown"].contains(mode) { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private static func record(hostname: String = "nas.example.invalid") -> [String: Any] {
        ["provider": "Example", "hostname": hostname, "username": "synthetic-user",
         "enable": true, "heartbeat": false, "ip": "192.0.2.10",
         "status": "service_ddns_normal", "lastupdated": "2026-10-05T00:00:00Z"]
    }
    private func response(_ data: [String: Any]) -> DsmHTTPResponse {
        .init(data: (try? JSONSerialization.data(withJSONObject: ["success": true, "data": data])) ?? Data(), statusCode: 200)
    }
}
#endif
