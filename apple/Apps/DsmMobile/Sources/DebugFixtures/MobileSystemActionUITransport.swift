#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 只模拟隔离测试连接和电源回应，不触及设备电源或本机网络连接。
actor MobileSystemActionUITransport: DsmHTTPTransport {
    private var mode: String
    private var didFail = false
    private var rows: [[String: Any]]
    private var hold = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { ["kick_connection", "shutdown", "reboot"].contains($0["method"] ?? "") } }
    init(mode: String = "nas-system") {
        self.mode = mode
        rows = [
            ["pid":201, "who":"sample-user", "from":"sample-client.invalid", "type":"SMB", "protocol":"SMB3", "descr":"Sample file connection", "time":"2026-10-06 08:15:00", "can_be_kicked":true, "is_current_connected":false],
            ["did":"synthetic-web-device", "who":"fixture", "from":"sample-web.invalid", "type":"HTTP/HTTPS", "protocol":"HTTPS", "descr":"Sample app connection", "can_be_kicked":true, "is_current_connected":true],
            ["pid":999, "who":"protected-service", "from":"sample-service.invalid", "type":"SMB", "can_be_kicked":false, "is_current_connected":false]
        ]
        if mode == "nas-system-empty" { rows = [] }
        if mode == "nas-system-recover" { rows.removeFirst() }
        if mode.hasPrefix("nas-system-missing-id") { rows[0].removeValue(forKey: "pid") }
        if mode == "nas-system-missing-id-time" { rows[0]["time"] = "2026-10-06 01:15:00" }
    }
    func setMode(_ value: String) { mode = value }
    func changeTarget() { rows[0]["who"] = "changed-user" }
    func removeTargets() { rows = [] }
    func holdWrites() { hold = true }
    func resume() { hold = false; waiter?.resume(); waiter = nil }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields)
        let method = fields["method"] ?? "", api = fields["api"] ?? ""
        if mode == "nas-system-trust" { throw URLError(.serverCertificateUntrusted) }
        if api == DsmAPIName.coreSystem && method == "info" {
            if mode == "nas-system-info-denied" { return denied() }
            return response(["model":"Synthetic", "firmware_ver":"DSM synthetic", "ram_size":2048, "up_time":"1 days 00:20:00"])
        }
        if api == DsmAPIName.coreCurrentConnection && method == "list" {
            if mode == "nas-system-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-system-retry" && !didFail { didFail = true; throw URLError(.notConnectedToInternet) }
            if mode == "nas-system-accepted-offline" && !writes.isEmpty { throw URLError(.notConnectedToInternet) }
            if mode == "nas-system-duplicate" { return response(["items": rows + [rows[0]], "total": rows.count + 1]) }
            return response(["items":rows, "total":mode == "nas-system-incomplete" ? 500 : rows.count])
        }
        guard ["kick_connection", "shutdown", "reboot"].contains(method) else { return response([:]) }
        if hold { await withCheckedContinuation { waiter = $0 } }
        if mode == "nas-system-denied" { return denied() }
        if mode == "nas-system-trust-write" { throw DsmCertificateTrustError.changed(.init(host: "fixture.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "0", count: 64), canBePinned: true)) }
        if method == "kick_connection", mode != "nas-system-unknown" && mode != "nas-system-remains" {
            let services = (try? JSONSerialization.jsonObject(with: Data((fields["service_conn"] ?? "[]").utf8))) as? [[String: Any]] ?? []
            let web = (try? JSONSerialization.jsonObject(with: Data((fields["http_conn"] ?? "[]").utf8))) as? [[String: Any]] ?? []
            rows.removeAll { row in
                services.contains { String(describing: row["pid"] ?? "") == $0["pid"] as? String }
                    || web.contains { row["did"] as? String == $0["did"] as? String }
            }
        }
        if mode == "nas-system-unknown" || mode == "nas-system-lost-ack" { throw URLError(.timedOut) }
        return response([:])
    }
    private func denied() -> DsmHTTPResponse { .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
    private func response(_ value: [String: Any]) -> DsmHTTPResponse { .init(data: (try? JSONSerialization.data(withJSONObject: ["success":true, "data":value])) ?? Data(), statusCode: 200) }
}
#endif
