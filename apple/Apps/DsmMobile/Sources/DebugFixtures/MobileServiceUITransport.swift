#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 仅供本机和 CI 的合成服务设置场景，不连接真实 NAS。
actor MobileServiceUITransport: DsmHTTPTransport {
    static let versions = [DsmAPIName.coreNetworkEthernet: 2, DsmAPIName.coreFileServiceSMB: 3, DsmAPIName.coreFileServiceNFS: 3, DsmAPIName.coreFileServiceFTP: 1,
        DsmAPIName.coreFileServiceSFTP: 1, DsmAPIName.coreWebDSM: 2, DsmAPIName.coreFileServiceDiscovery: 1,
        DsmAPIName.coreTerminal: 3, DsmAPIName.coreNetworkProxy: 1, DsmAPIName.coreQuickConnect: 3, DsmAPIName.coreQuickConnectUPnP: 1,
        DsmAPIName.coreHardwareZRAM: 1, DsmAPIName.coreHardwareNeedReboot: 1, DsmAPIName.coreHardwarePowerSchedule: 1,
        DsmAPIName.coreSecurityAutoBlock: 1, DsmAPIName.coreSecurityDoS: 2, DsmAPIName.coreSecurityFirewall: 1,
        DsmAPIName.coreSecurityFirewallConf: 1, DsmAPIName.coreSecurityFirewallProfileApply: 1,
        DsmAPIName.coreHardwarePowerRecovery: 1, DsmAPIName.coreHardwareLEDBrightness: 1, DsmAPIName.coreHardwareFanSpeed: 1,
        DsmAPIName.coreHardwareBeepControl: 1, DsmAPIName.coreHardwareHibernation: 1, DsmAPIName.coreExternalDeviceUPS: 1]
    private(set) var requests: [[String: String]] = []
    var writes: [[String: String]] { requests.filter { ["set", "set_misc_config", "save", "start", "stop", "set_current_brightness", "update"].contains($0["method"] ?? "") } }
    private var mode: String
    private let onRead: @Sendable () async -> Void
    private var didFail = false
    private var transientReadFailures = 0
    private var holdWrites = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var payloads: [String: [String: Any]] = [
        DsmAPIName.coreHardwarePowerRecovery: ["rc_power_config": false],
        DsmAPIName.coreHardwareLEDBrightness: ["led_brightness": 3, "min": 0, "max": 7],
        DsmAPIName.coreHardwareFanSpeed: ["dual_fan_speed": "quietfan", "cool_fan": "yes", "fan_type": 11],
        DsmAPIName.coreHardwareBeepControl: ["fan_fail": true, "volume_or_cache_crash": true, "poweron_beep": false, "poweroff_beep": false, "reset_beep": true],
        DsmAPIName.coreHardwareHibernation: ["eunit_deep_sleep": false, "enable_log": false, "sata_deep_sleep": false, "ignore_netbios_broadcast": false, "auto_poweroff_enable": false],
        DsmAPIName.coreExternalDeviceUPS: ["enable": false, "mode": "USB", "delay_time": 120, "ups_set_safemode_until_lowbatt": false, "shutdown_device": false, "net_server_ip": "", "snmp_server_ip": ""],
        DsmAPIName.coreSecurityAutoBlock: ["enable": false, "attempts": 5, "within_mins": 10, "expire_day": 0],
        DsmAPIName.coreSecurityFirewall: ["enable_firewall": false, "profile_name": "Sample profile"],
        DsmAPIName.coreSecurityFirewallConf: ["enable_port_check": false],
        DsmAPIName.coreSecurityDoS: ["configs": [["adapter": "eth0", "dos_protect_enable": false]]],
        DsmAPIName.coreNetworkEthernet: ["ifname": "eth0", "title": "LAN 1", "status": "connected", "use_dhcp": true, "ip": "192.0.2.10", "mask": "255.255.255.0", "gateway": "192.0.2.1", "dns": "192.0.2.1", "is_default_gateway": true, "mtu": 1500, "enable_vlan": false],
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
        if mode == "nas-services-hardware-incomplete" { payloads[DsmAPIName.coreExternalDeviceUPS]?["delay_time"] = 1.5 }
        if mode == "nas-services-hardware-led-recover" { payloads[DsmAPIName.coreHardwareLEDBrightness]?["led_brightness"] = 5 }
        if mode == "nas-services-hardware-limited" {
            payloads[DsmAPIName.coreHardwareLEDBrightness]?.removeValue(forKey: "min")
            payloads[DsmAPIName.coreHardwareFanSpeed]?.removeValue(forKey: "cool_fan")
            payloads[DsmAPIName.coreHardwareBeepControl]?["support_reset_beep"] = false
            payloads[DsmAPIName.coreExternalDeviceUPS]?.removeValue(forKey: "net_server_ip")
        }
        if mode == "nas-services-security-no-adapters" { payloads[DsmAPIName.coreSecurityDoS]?["configs"] = [] }
        if mode == "nas-services-security-incomplete" { payloads[DsmAPIName.coreSecurityAutoBlock]?.removeValue(forKey: "expire_day") }
        if mode == "nas-services-security-config-recover" { payloads[DsmAPIName.coreSecurityAutoBlock]?["enable"] = true }
        if mode == "nas-services-security-task-recover" { payloads[DsmAPIName.coreSecurityFirewall]?["enable_firewall"] = true }
        if ["nas-services-ethernet-recover", "nas-services-ethernet-new-address"].contains(mode) { payloads[DsmAPIName.coreNetworkEthernet]?["mtu"] = 1400 }
        if mode == "nas-services-ethernet-incomplete" { payloads[DsmAPIName.coreNetworkEthernet]?.removeValue(forKey: "enable_vlan") }
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
    func setEthernetMTU(_ value: Int) { payloads[DsmAPIName.coreNetworkEthernet]?["mtu"] = value }
    func setSecurityAutoBlock(enabled: Bool) { payloads[DsmAPIName.coreSecurityAutoBlock]?["enable"] = enabled }
    func setFirewall(enabled: Bool) { payloads[DsmAPIName.coreSecurityFirewall]?["enable_firewall"] = enabled }
    func setLEDBrightness(_ value: Int) { payloads[DsmAPIName.coreHardwareLEDBrightness]?["led_brightness"] = value }
    func setHardwarePowerRecovery(_ value: Bool) { payloads[DsmAPIName.coreHardwarePowerRecovery]?["rc_power_config"] = value }
    func changeFirewallProfile() { payloads[DsmAPIName.coreSecurityFirewall]?["profile_name"] = "Changed sample profile" }
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
        if api == DsmAPIName.coreSecurityFirewallProfileApply {
            if mode == "nas-services-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
            switch fields["method"] {
            case "start":
                if holdWrites { await withCheckedContinuation { waiting = $0 } }
                if mode == "nas-services-security-lost-receipt" { payloads[DsmAPIName.coreSecurityFirewall]?["enable_firewall"] = true; throw URLError(.networkConnectionLost) }
                return response(["task_id": "sample-firewall-task"])
            case "status":
                if mode == "nas-services-security-task-offline" { throw URLError(.notConnectedToInternet) }
                if mode == "nas-services-security-task-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
                if mode == "nas-services-security-task-trust" { throw DsmCertificateTrustError.changed(.init(host: "fixture.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "a", count: 64), canBePinned: true)) }
                if mode == "nas-services-security-task-failed" { return response(["success": false]) }
                payloads[DsmAPIName.coreSecurityFirewall]?["enable_firewall"] = true
                return response(["success": true])
            case "stop":
                if mode == "nas-services-security-clean-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
                return response([:])
            default: break
            }
        }
        if ["list", "get", "get_misc_config", "load", "get_static_data"].contains(fields["method"] ?? "") {
            if mode == "nas-services-readonly", payloads[api] != nil { await onRead() }
            if ["nas-services-ethernet-trust-after-save", "nas-services-hardware-trust-after-save"].contains(mode) && !writes.isEmpty {
                throw DsmCertificateTrustError.changed(.init(host: "fixture.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "a", count: 64), canBePinned: true))
            }
            if ["nas-services-ethernet-denied-after-save", "nas-services-hardware-denied-after-save"].contains(mode) && !writes.isEmpty {
                return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200)
            }
            if mode == "nas-services-remote-trust-error" {
                throw DsmCertificateTrustError.changed(.init(host: "fixture.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "a", count: 64), canBePinned: true))
            }
            if mode == "nas-services-remote-retry", transientReadFailures < 2 { transientReadFailures += 1; throw URLError(.notConnectedToInternet) }
            if mode == "nas-services-remote-partial-read", api == DsmAPIName.coreQuickConnect { throw URLError(.notConnectedToInternet) }
            if mode == "nas-services-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-services-error" || mode == "nas-services-retry" && !didFail { didFail = true; throw URLError(.notConnectedToInternet) }
            if !writes.isEmpty && ["nas-services-unknown", "nas-services-accepted-offline", "nas-services-remote-unknown"].contains(mode) { throw URLError(.notConnectedToInternet) }
            if mode == "nas-services-zram-marker-unknown" && writes.count >= 2 { throw URLError(.notConnectedToInternet) }
            if mode == "nas-services-empty" { return response(api == DsmAPIName.coreNetworkEthernet ? ["interfaces": []] : [:]) }
            if mode == "nas-services-malformed" { return response(["enable_ssh": "unrecognized", "enable_telnet": false]) }
            if api == DsmAPIName.coreNetworkEthernet && fields["method"] == "list" { return response(["interfaces": mode == "nas-services-security-no-adapters" ? [] : [["ifname": "eth0", "display": "LAN 1"]]]) }
            return response(payloads[api] ?? [:])
        }
        guard ["set", "set_misc_config", "save", "set_current_brightness", "update"].contains(fields["method"] ?? ""), payloads[api] != nil else { return response([:]) }
        if holdWrites { await withCheckedContinuation { waiting = $0 } }
        if mode == "nas-services-denied" || mode == "nas-services-partial" && writes.count == 2 {
            return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200)
        }
        if mode == "nas-services-hardware-led-denied-once", fields["method"] == "update", !didFail {
            didFail = true; return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200)
        }
        if api == DsmAPIName.coreNetworkEthernet, let data = fields["configs"], let values = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [[String: Any]], let value = values.first { payloads[api]?.merge(value) { _, new in new }; if mode == "nas-services-ethernet-partial" { payloads[api]?["mtu"] = 1500 } }
        if api == DsmAPIName.coreSecurityFirewall, fields["set_type"] == "disable" { payloads[api]?["enable_firewall"] = false }
        for (key, value) in fields where payloads[api]?[key] != nil {
            if mode != "nas-services-partial-terminal" || key == "enable_ssh" {
                if value == "true" || value == "false" { payloads[api]?[key] = value == "true" }
                else if let port = Int(value) { payloads[api]?[key] = port }
                else if ["poweron_tasks", "poweroff_tasks", "configs"].contains(key) { payloads[api]?[key] = try JSONSerialization.jsonObject(with: Data(value.utf8)) }
                else { payloads[api]?[key] = value }
            }
        }
        if api == DsmAPIName.coreHardwareNeedReboot { payloads[api]?["need_reboot"] = true }
        if mode == "nas-services-zram-marker-unknown" && api == DsmAPIName.coreHardwareNeedReboot { throw URLError(.networkConnectionLost) }
        if ["nas-services-unknown", "nas-services-lost-ack", "nas-services-remote-unknown"].contains(mode) { throw URLError(.networkConnectionLost) }
        if mode == "nas-services-hardware-led-update-unknown" && fields["method"] == "update" { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private func response(_ payload: [String: Any]) -> DsmHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": payload]), statusCode: 200) }
}
#endif
