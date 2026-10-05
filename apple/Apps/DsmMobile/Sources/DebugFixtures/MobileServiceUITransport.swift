#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 仅供本机和 CI 的合成服务设置场景，不连接真实 NAS。
actor MobileServiceUITransport: DsmHTTPTransport {
    static let versions = [DsmAPIName.coreFileServiceSMB: 3, DsmAPIName.coreFileServiceNFS: 3, DsmAPIName.coreFileServiceFTP: 1,
        DsmAPIName.coreFileServiceSFTP: 1, DsmAPIName.coreWebDSM: 2, DsmAPIName.coreFileServiceDiscovery: 1,
        DsmAPIName.coreTerminal: 3, DsmAPIName.coreNetworkProxy: 1, DsmAPIName.coreQuickConnect: 3, DsmAPIName.coreQuickConnectUPnP: 1,
        DsmAPIName.coreHardwareZRAM: 1, DsmAPIName.coreHardwareNeedReboot: 1, DsmAPIName.coreHardwarePowerSchedule: 1]
    private(set) var requests: [[String: String]] = []
    var writes: [[String: String]] { requests.filter { ["set", "set_misc_config", "save"].contains($0["method"] ?? "") } }
    private var mode: String
    private let onRead: @Sendable () async -> Void
    private var didFail = false
    private var transientReadFailures = 0
    private var holdWrites = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var payloads: [String: [String: Any]] = [
        DsmAPIName.coreFileServiceSMB: ["enable_samba": false], DsmAPIName.coreFileServiceNFS: ["enable_nfs": false],
        DsmAPIName.coreFileServiceFTP: ["enable_ftp": false, "enable_ftps": false, "portnum": 21],
        DsmAPIName.coreFileServiceSFTP: ["enable": false, "portnum": 22], DsmAPIName.coreWebDSM: ["enable_ssdp": true, "enable_avahi": false],
        DsmAPIName.coreFileServiceDiscovery: ["enable_smb_time_machine": false],
        DsmAPIName.coreTerminal: ["enable_ssh": false, "enable_telnet": false, "ssh_port": 22],
        DsmAPIName.coreNetworkProxy: ["enable": false, "http_host": "proxy.example.invalid", "http_port": 3128],
        DsmAPIName.coreQuickConnect: ["relay_enabled": true], DsmAPIName.coreQuickConnectUPnP: ["enabled": false],
        DsmAPIName.coreHardwareZRAM: ["enable_zram": false], DsmAPIName.coreHardwareNeedReboot: ["need_reboot": false],
        DsmAPIName.coreHardwarePowerSchedule: ["poweron_tasks": [], "poweroff_tasks": [], "timezone": "Asia/Taipei"]]
    init(mode: String = "nas-services", onRead: @escaping @Sendable () async -> Void = {}) {
        self.mode = mode; self.onRead = onRead
        if mode == "nas-services-recover" { payloads[DsmAPIName.coreTerminal]?["enable_ssh"] = true }
        if mode == "nas-services-remote-recover" { payloads[DsmAPIName.coreQuickConnectUPnP]?["enabled"] = true }
        if mode == "nas-services-zram-recover" { payloads[DsmAPIName.coreHardwareZRAM]?["enable_zram"] = true; payloads[DsmAPIName.coreHardwareNeedReboot]?["need_reboot"] = true }
        if mode == "nas-services-power-recover" { payloads[DsmAPIName.coreHardwarePowerSchedule]?["poweroff_tasks"] = [["enabled": false, "hour": 8, "min": 15, "weekdays": "0,1,2,3,4,5,6"]] }
        if mode == "nas-services-power-ui-recover" { payloads[DsmAPIName.coreHardwarePowerSchedule]?["poweron_tasks"] = [["enabled": true, "hour": 8, "min": 0, "weekdays": "0,1,2,3,4,5,6"]] }
        if mode == "nas-services-power-content" || mode == "nas-services-power-incomplete" {
            payloads[DsmAPIName.coreHardwarePowerSchedule]?["poweron_tasks"] = [["enabled": true, "hour": 8, "min": 0, "weekdays": "1,2,3,4,5"]]
            payloads[DsmAPIName.coreHardwarePowerSchedule]?["poweroff_tasks"] = [["enabled": false, "hour": 22, "min": 15, "weekdays": "0,6"]]
            if mode == "nas-services-power-incomplete" { payloads[DsmAPIName.coreHardwarePowerSchedule]?["total"] = 3 }
        }
        if mode == "nas-services-power-summary-empty" { payloads[DsmAPIName.coreHardwarePowerSchedule] = ["schedules": [], "timezone": "Asia/Taipei"] }
        if mode == "nas-services-zram-incomplete" { payloads[DsmAPIName.coreHardwareNeedReboot]?["need_reboot"] = "unknown" }
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
    func setZRAM(enabled: Bool) { payloads[DsmAPIName.coreHardwareZRAM]?["enable_zram"] = enabled }
    func setScheduleTimeZone(_ value: String) { payloads[DsmAPIName.coreHardwarePowerSchedule]?["timezone"] = value }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        requests.append(fields); let api = fields["api"] ?? ""
        if ["get", "get_misc_config", "load"].contains(fields["method"] ?? "") {
            if mode == "nas-services-readonly", payloads[api] != nil { await onRead() }
            if mode == "nas-services-remote-trust-error" {
                throw DsmCertificateTrustError.changed(.init(host: "fixture.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "a", count: 64), canBePinned: true))
            }
            if mode == "nas-services-remote-retry", transientReadFailures < 2 { transientReadFailures += 1; throw URLError(.notConnectedToInternet) }
            if mode == "nas-services-remote-partial-read", api == DsmAPIName.coreQuickConnect { throw URLError(.notConnectedToInternet) }
            if mode == "nas-services-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-services-error" || mode == "nas-services-retry" && !didFail { didFail = true; throw URLError(.notConnectedToInternet) }
            if !writes.isEmpty && ["nas-services-unknown", "nas-services-accepted-offline", "nas-services-remote-unknown"].contains(mode) { throw URLError(.notConnectedToInternet) }
            if mode == "nas-services-zram-marker-unknown" && writes.count >= 2 { throw URLError(.notConnectedToInternet) }
            if mode == "nas-services-empty" { return response([:]) }
            if mode == "nas-services-malformed" { return response(["enable_ssh": "unrecognized", "enable_telnet": false]) }
            return response(payloads[api] ?? [:])
        }
        guard ["set", "set_misc_config", "save"].contains(fields["method"] ?? ""), payloads[api] != nil else { return response([:]) }
        if holdWrites { await withCheckedContinuation { waiting = $0 } }
        if mode == "nas-services-denied" || mode == "nas-services-partial" && writes.count == 2 {
            return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200)
        }
        for (key, value) in fields where payloads[api]?[key] != nil {
            if mode != "nas-services-partial-terminal" || key == "enable_ssh" {
                if value == "true" || value == "false" { payloads[api]?[key] = value == "true" }
                else if let port = Int(value) { payloads[api]?[key] = port }
                else if ["poweron_tasks", "poweroff_tasks"].contains(key) { payloads[api]?[key] = try JSONSerialization.jsonObject(with: Data(value.utf8)) }
                else { payloads[api]?[key] = value }
            }
        }
        if api == DsmAPIName.coreHardwareNeedReboot { payloads[api]?["need_reboot"] = true }
        if mode == "nas-services-zram-marker-unknown" && api == DsmAPIName.coreHardwareNeedReboot { throw URLError(.networkConnectionLost) }
        if ["nas-services-unknown", "nas-services-lost-ack", "nas-services-remote-unknown"].contains(mode) { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private func response(_ payload: [String: Any]) -> DsmHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": payload]), statusCode: 200) }
}
#endif
