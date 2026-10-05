#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 仅供本机和 CI 的合成服务设置场景，不连接真实 NAS。
actor MobileServiceUITransport: DsmHTTPTransport {
    static let versions = [DsmAPIName.coreFileServiceSMB: 3, DsmAPIName.coreFileServiceNFS: 3, DsmAPIName.coreFileServiceFTP: 1,
        DsmAPIName.coreFileServiceSFTP: 1, DsmAPIName.coreWebDSM: 2, DsmAPIName.coreFileServiceDiscovery: 1,
        DsmAPIName.coreTerminal: 3, DsmAPIName.coreNetworkProxy: 1]
    private(set) var requests: [[String: String]] = []
    var writes: [[String: String]] { requests.filter { $0["method"] == "set" } }
    private var mode: String
    private let onRead: @Sendable () async -> Void
    private var didFail = false
    private var holdWrites = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var payloads: [String: [String: Any]] = [
        DsmAPIName.coreFileServiceSMB: ["enable_samba": false], DsmAPIName.coreFileServiceNFS: ["enable_nfs": false],
        DsmAPIName.coreFileServiceFTP: ["enable_ftp": false, "enable_ftps": false, "portnum": 21],
        DsmAPIName.coreFileServiceSFTP: ["enable": false, "portnum": 22], DsmAPIName.coreWebDSM: ["enable_ssdp": true, "enable_avahi": false],
        DsmAPIName.coreFileServiceDiscovery: ["enable_smb_time_machine": false],
        DsmAPIName.coreTerminal: ["enable_ssh": false, "enable_telnet": false, "ssh_port": 22],
        DsmAPIName.coreNetworkProxy: ["enable": false, "http_host": "proxy.example.invalid", "http_port": 3128]]
    init(mode: String = "nas-services", onRead: @escaping @Sendable () async -> Void = {}) {
        self.mode = mode; self.onRead = onRead
        if mode == "nas-services-recover" { payloads[DsmAPIName.coreTerminal]?["enable_ssh"] = true }
        if mode == "nas-services-missing" {
            payloads[DsmAPIName.coreTerminal]?.removeValue(forKey: "ssh_port")
            payloads[DsmAPIName.coreFileServiceFTP]?.removeValue(forKey: "enable_ftps")
            payloads[DsmAPIName.coreFileServiceFTP]?.removeValue(forKey: "portnum")
            payloads[DsmAPIName.coreFileServiceSFTP]?.removeValue(forKey: "portnum")
        }
    }
    func setMode(_ mode: String) { self.mode = mode }
    func suspendWrites() { holdWrites = true }
    func resumeWrites() { holdWrites = false; waiting?.resume(); waiting = nil }
    func changeOriginal() { payloads[DsmAPIName.coreTerminal]?["ssh_port"] = 2200 }
    func setTerminal(enabled: Bool) { payloads[DsmAPIName.coreTerminal]?["enable_ssh"] = enabled }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        requests.append(fields); let api = fields["api"] ?? ""
        if fields["method"] == "get" {
            if mode == "nas-services-readonly", payloads[api] != nil { await onRead() }
            if mode == "nas-services-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-services-error" || mode == "nas-services-retry" && !didFail { didFail = true; throw URLError(.notConnectedToInternet) }
            if !writes.isEmpty && ["nas-services-unknown", "nas-services-accepted-offline"].contains(mode) { throw URLError(.notConnectedToInternet) }
            if mode == "nas-services-empty" { return response([:]) }
            if mode == "nas-services-malformed" { return response(["enable_ssh": "unrecognized", "enable_telnet": false]) }
            return response(payloads[api] ?? [:])
        }
        guard fields["method"] == "set", payloads[api] != nil else { return response([:]) }
        if holdWrites { await withCheckedContinuation { waiting = $0 } }
        if mode == "nas-services-denied" || mode == "nas-services-partial" && writes.count == 2 {
            return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200)
        }
        for (key, value) in fields where payloads[api]?[key] != nil {
            if mode != "nas-services-partial-terminal" || key == "enable_ssh" {
                if value == "true" || value == "false" { payloads[api]?[key] = value == "true" }
                else if let port = Int(value) { payloads[api]?[key] = port }
                else { payloads[api]?[key] = value }
            }
        }
        if ["nas-services-unknown", "nas-services-lost-ack"].contains(mode) { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private func response(_ payload: [String: Any]) -> DsmHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": payload]), statusCode: 200) }
}
#endif
