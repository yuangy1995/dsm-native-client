#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 隔离的套件管理场景；所有内容均为合成数据，不访问外部来源或真实 NAS。
actor MobilePackageUITransport: DsmHTTPTransport {
    private var mode: String
    private var failedReads: Set<String> = []
    private var settings: [String: Any] = ["update_channel": false, "enable_email": false, "enable_dsm": true,
        "enable_autoupdate": false, "autoupdateall": false, "autoupdateimportant": false, "default_vol": "/volume1",
        "volume_list": [["mount_point": "/volume1", "display": "Volume 1"]]]
    private var info: [String: Any] = ["status": "stopped", "startable": true, "install_type": "user", "ctl_uninstall": true,
        "dsm_apps": ["Synthetic.Application"], "available_operation": ["start", "uninstall"], "description": "Synthetic package",
        "silent_upgrade": true, "autoupdate": false, "autoupdate_important": false, "limit_type": "normal"]
    private var sources = [["name": "Sample source", "feed": "https://packages.example.invalid/feed"]]
    private var hold = false
    private var removed = false
    private var installedAt = 1_700_000_000
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { ["set", "add", "delete", "start", "stop", "uninstall"].contains($0["method"] ?? "") } }
    init(mode: String = "nas-package-preferences") {
        self.mode = mode
        if mode == "nas-package-multi-volume" { settings["volume_list"] = [["mount_point": "/volume1", "display": "Volume 1"], ["mount_point": "/volume2", "display": "Volume 2"]] }
        if mode == "nas-package-unknown-preference" {
            info.removeValue(forKey: "autoupdate"); info.removeValue(forKey: "autoupdate_important"); settings["enable_autoupdate"] = true
        }
        if mode == "nas-package-empty" || mode == "nas-package-recover-remove" { sources = [] }
        if mode == "nas-package-recover-settings" { settings["enable_email"] = true }
        if mode == "nas-package-recover-source" { sources.append(["name": "New source", "feed": "https://packages.example.invalid/new"]) }
        if mode == "nas-package-control-running" || mode == "nas-package-control-recover-start" || mode == "nas-package-control-reinstalled" {
            info["status"] = "running"; info["available_operation"] = ["stop", "uninstall"]
        }
        if mode == "nas-package-control-recover-remove" { removed = true }
        if mode == "nas-package-control-reinstalled" { installedAt += 1 }
        if mode == "nas-package-control-system" { info["install_type"] = "system_hidden"; info["ctl_uninstall"] = false }
    }
    func setMode(_ value: String) { mode = value }
    func changeSettings() { settings["enable_dsm"] = false }
    func changeSource() { sources[0]["name"] = "Changed source" }
    func applyEmail() { settings["enable_email"] = true }
    func clearSources() { sources = [] }
    func setStatus(_ value: String) {
        info["status"] = value
        info["available_operation"] = [value == "running" ? "stop" : "start", "uninstall"]
    }
    func reinstall() { installedAt += 1 }
    func holdWrites() { hold = true }
    func resume() { hold = false; waiter?.resume(); waiter = nil }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }); calls.append(fields)
        let api = fields["api"] ?? "", method = fields["method"] ?? "", writing = ["set", "add", "delete", "start", "stop", "uninstall"].contains(method)
        if mode == "nas-package-trust-read" { throw URLError(.serverCertificateUntrusted) }
        if !writing {
            if mode == "nas-package-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-package-retry", failedReads.insert(api).inserted { throw URLError(.notConnectedToInternet) }
            if mode == "nas-package-accepted-offline", !writes.isEmpty { throw URLError(.notConnectedToInternet) }
            if mode == "nas-package-control-read-denied", !writes.isEmpty { return denied() }
            if mode == "nas-package-settings-error", api == DsmAPIName.corePackageSetting { throw URLError(.notConnectedToInternet) }
            if api == DsmAPIName.corePackageSetting { return response(settings) }
            if api == DsmAPIName.corePackageFeed {
                return response(["items": sources, "total": mode == "nas-package-source-partial" ? sources.count + 1 : sources.count])
            }
            if api == DsmAPIName.corePackage {
                if method == "feasibility_check" { return response([:]) }
                var packages: [[String: Any]] = mode == "nas-package-empty" || removed ? [] : [["id": "SyntheticPackage", "name": "Sample package", "version": "1.0.0", "timestamp": installedAt, "additional": info]]
                if mode.hasPrefix("nas-package-added-manual"), !writes.isEmpty {
                    packages.append(["id": "Other", "name": "Other package", "additional": ["status": "stopped", "silent_upgrade": true, "autoupdate": false, "autoupdate_important": false]])
                }
                return response(["packages": packages, "total": mode == "nas-package-partial" ? packages.count + 1 : packages.count])
            }
            if api == DsmAPIName.coreSystem { return response(["model": "Synthetic", "firmware_ver": "DSM synthetic", "ram_size": 2048]) }
            return response([:])
        }
        if hold { await withCheckedContinuation { waiter = $0 } }
        if mode == "nas-package-denied" { return denied() }
        if mode == "nas-package-trust-write" { throw DsmCertificateTrustError.changed(.init(host: "fixture.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "0", count: 64), canBePinned: true)) }
        if mode == "nas-package-unknown" { throw URLError(.timedOut) }
        if api == DsmAPIName.corePackageControl {
            setStatus(method == "start" ? "running" : "stopped")
        } else if api == DsmAPIName.corePackageUninstallation {
            removed = true
        } else if api == DsmAPIName.corePackageSetting {
            settings["update_channel"] = fields["update_channel"] == "beta"
            for key in ["enable_email", "enable_dsm", "enable_autoupdate", "autoupdateall", "autoupdateimportant"] { settings[key] = fields[key] == "true" }
            if let volume = fields["default_vol"] { settings["default_vol"] = volume }
            if let latest = array(fields["packages"]) { info["autoupdate"] = latest.contains("SyntheticPackage") }
            if let important = array(fields["packages_important"]) { info["autoupdate_important"] = important.contains("SyntheticPackage") }
        } else if api == DsmAPIName.corePackageFeed {
            if method == "delete", let removed = array(fields["list"]) { sources.removeAll { removed.contains($0["feed"] ?? "") } }
            else if let data = fields["list"]?.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                    let name = value["name"], let address = value["feed"] {
                if let old = value["orifeed"] { sources.removeAll { $0["feed"] == old } }
                sources.append(["name": name, "feed": address])
            }
        }
        if mode == "nas-package-apply-denied" { return denied() }
        if mode.hasSuffix("-lost-ack") { throw URLError(.timedOut) }
        return response([:])
    }
    private func array(_ value: String?) -> [String]? { value?.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String] } }
    private func denied() -> DsmHTTPResponse { .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
    private func response(_ value: [String: Any]) -> DsmHTTPResponse { .init(data: (try? JSONSerialization.data(withJSONObject: ["success": true, "data": value])) ?? Data(), statusCode: 200) }
}
#endif
