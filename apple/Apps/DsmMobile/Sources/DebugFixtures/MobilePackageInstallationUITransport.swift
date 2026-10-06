#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 仅供隔离自动化的套件安装环境；所有请求和文件都留在本进程。
actor MobilePackageInstallationUITransport: DsmBinaryHTTPTransport {
    private var mode: String
    private var installed: [String: String] = ["SyntheticPackage": "1.0"]
    private var tasks: [String: (id: String, quick: Bool, cancelled: Bool)] = [:]
    private var hasFailed = false
    private var hold = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [[String: String]] = []
    private(set) var uploadCount = 0
    var writes: [[String: String]] { calls.filter { ["install", "upgrade", "cancel", "clean", "delete", "upload"].contains($0["method"] ?? "") } }
    init(mode: String = "nas-package-install") {
        self.mode = mode
        if mode == "nas-package-install-empty" { installed = [:] }
        if mode == "nas-package-install-recover" { installed["NewPackage"] = "2.0" }
        if mode == "nas-package-install-reinstall" { installed["ManualPackage"] = "2.0" }
    }
    func setMode(_ value: String) { mode = value }
    func setInstalled(_ id: String, version: String?) { installed[id] = version }
    func holdWrites() { hold = true }
    func resume() { hold = false; waiter?.resume(); waiter = nil }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields)
        let api = fields["api"] ?? "", method = fields["method"] ?? ""
        let writing = ["install", "upgrade", "cancel", "clean", "delete"].contains(method)
        if writing {
            if hold { await withCheckedContinuation { waiter = $0 } }
            if mode == "nas-package-install-denied" { return rejected() }
            if mode == "nas-package-install-trust" { throw URLError(.serverCertificateUntrusted) }
            if mode == "nas-package-install-unknown" || mode == "nas-package-install-reinstall" { throw URLError(.timedOut) }
        }
        if api == DsmAPIName.coreSystem { return response(["model": "Synthetic", "firmware_ver": "DSM synthetic", "ram_size": 2048]) }
        if api == DsmAPIName.corePackage && method == "list" {
            let rows: [[String: Any]] = installed.sorted { $0.key < $1.key }.map { id, version in
                ["id": id, "name": name(id), "version": version, "additional": ["status": "running", "startable": true,
                    "install_type": "user", "ctl_uninstall": true, "available_operation": id == "SyntheticPackage" && version == "1.0" ? ["upgrade": candidate(id)] : [:]]]
            }
            return response(["packages": rows, "total": mode == "nas-package-install-partial" ? rows.count + 1 : rows.count])
        }
        if api == DsmAPIName.corePackage && method == "feasibility_check" { return response([:]) }
        if api == DsmAPIName.corePackageServer {
            if mode == "nas-package-install-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-package-install-retry" && !hasFailed { hasFailed = true; throw URLError(.notConnectedToInternet) }
            if fields["blloadothers"] == "true" {
                if mode == "nas-package-install-community-error" { throw URLError(.notConnectedToInternet) }
                return response(["packages": mode == "nas-package-install-empty" ? [] : [candidate("CommunityPackage")]])
            }
            return response(["packages": mode == "nas-package-install-empty" ? [] : [candidate("NewPackage"), candidate("SyntheticPackage"), candidate("Dependency")],
                "beta_packages": mode == "nas-package-install-empty" ? [] : [candidate("BetaPackage")],
                "categories": [["id": "backup", "dname": "Backup"], ["id": "tools", "dname": "Tools"]]])
        }
        if api == DsmAPIName.corePackageInfo { return response(["prerelease": ["success": true, "agreed": mode != "nas-package-install-beta-agreement"]]) }
        if api == DsmAPIName.corePackageSetting {
            return response(["volume_list": volumes, "update_channel": false, "enable_email": false, "enable_dsm": true,
                "enable_autoupdate": false, "autoupdateall": false, "autoupdateimportant": false])
        }
        if api == DsmAPIName.corePackageSettingVolume { return response(["default_vol": "/volume1"]) }
        if api == DsmAPIName.corePackageDownload {
            let id = (fields["taskid"] ?? "").replacingOccurrences(of: "@SYNOPKG_DOWNLOAD_", with: "")
            return response(checked(id))
        }
        if api == DsmAPIName.corePackageInstallation {
            if method == "get_queue" {
                let data = Data((fields["pkgs"] ?? "[]").utf8)
                let requested = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
                var queue = requested.map { ["pkg": $0["pkg"] ?? "", "beta": $0["beta"] ?? false] }
                if mode == "nas-package-install-dependencies" { queue.insert(["pkg": "Dependency", "beta": false], at: 0) }
                return response(["queue": queue, "non_exist_pkgs": [], "conflicted_pkgs": [], "broken_pkgs": [], "replaced_pkgs": [], "paused_pkgs": []])
            }
            if method == "check" { return response(["is_occupied": false, "volume_list": volumes, "volume_path": "/volume1"]) }
            if method == "install" || method == "upgrade" {
                if let id = fields["name"] {
                    let quick = fields["blqinst"] == "true", task = "synthetic-task-" + id
                    tasks[task] = (id, quick, false)
                    if mode == "nas-package-install-lost-ack" { if quick { installed[id] = "2.0" }; throw URLError(.timedOut) }
                    return response(["taskid": task, "progress": 0])
                }
                let id = (fields["task_id"] ?? "").replacingOccurrences(of: "owned-", with: "")
                installed[id] = "2.0"
                return response([:])
            }
            if method == "status", let task = tasks[fields["task_id"] ?? ""] {
                if mode == "nas-package-install-slow" && !task.cancelled { return response(["finished": false, "progress": 0.3]) }
                if task.quick && !task.cancelled { installed[task.id] = "2.0" }
                return response(["finished": true, "success": !task.cancelled, "progress": 1])
            }
            if method == "cancel", let id = fields["taskid"], let task = tasks[id] { tasks[id] = (task.id, task.quick, true); return response([:]) }
            if method == "clean" || method == "delete" { return response([:]) }
        }
        return rejected()
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        uploadCount += 1; calls.append(["api": DsmAPIName.corePackageInstallation, "method": "upload"])
        if hold { await withCheckedContinuation { waiter = $0 } }
        if mode == "nas-package-install-denied" { return rejected() }
        if mode == "nas-package-install-upload-unknown" { throw URLError(.timedOut) }
        if mode == "nas-package-install-upload-trust" { throw URLError(.serverCertificateUntrusted) }
        return response(checked("ManualPackage"))
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
    private var volumes: [[String: String]] {
        var values = [["mount_point": "/volume1", "display": "Volume 1"]]
        if mode == "nas-package-install-multi-volume" { values.append(["mount_point": "/volume2", "display": "Volume 2"]) }
        return values
    }
    private func name(_ id: String) -> String {
        switch id { case "NewPackage": "New package"; case "SyntheticPackage": "Sample package"; case "CommunityPackage": "Community package"; case "BetaPackage": "Beta package"; case "ManualPackage": "Manual package"; default: "Dependency package" }
    }
    private func candidate(_ id: String) -> [String: Any] {
        ["id": id, "dname": name(id), "version": "2.0", "source": id == "CommunityPackage" ? "community" : "syno",
         "beta": id == "BetaPackage", "qinst": !["CommunityPackage"].contains(id) && mode != "nas-package-install-slow",
         "qupgrade": true, "install_type": "user", "size": 1024, "type": 0,
         "link": "https://packages.example.invalid/synthetic.spk", "md5": String(repeating: "0", count: 32),
         "desc": "<p>Synthetic package description.</p><script>never execute</script>", "changelog": "Synthetic release notes.",
         "maintainer": "Synthetic publisher", "category": id == "NewPackage" ? ["backup"] : ["tools"]]
    }
    private func checked(_ id: String) -> [String: Any] {
        var fields: [[String: Any]] = [["items": [
            ["type": "textfield", "subitems": [["key": "label", "desc": "Package label", "defaultValue": "sample", "validator": ["allowBlank": false, "minLength": 2]]]],
            ["type": "password", "subitems": [["key": "secret", "desc": "Package password", "defaultValue": ""]]],
            ["type": "multiselect", "subitems": [["key": "enabled", "desc": "Enable sample option", "defaultValue": true]]],
            ["type": "combobox", "subitems": [["key": "mode", "desc": "Package mode", "defaultValue": "standard", "store": [["standard", "Standard"], ["extended", "Extended"]]]]]]]]
        if mode == "nas-package-install-custom" { fields = [["items": [["type": "textfield", "subitems": [["key": "script", "validator": ["fn": "synthetic-only"]]]]]]] }
        var value: [String: Any] = ["id": id, "name": name(id), "version": "2.0", "additional": ["task_id": "owned-" + id,
            "startable": true, "install_type": "user", "licence": "Synthetic package license. No external resources are loaded.", "install_pages": fields]]
        if mode == "nas-package-install-signature" { value["codesign_error"] = 4501 }
        return value
    }
    private func rejected() -> DsmHTTPResponse { .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
    private func response(_ value: [String: Any]) -> DsmHTTPResponse { .init(data: (try? JSONSerialization.data(withJSONObject: ["success": true, "data": value])) ?? Data(), statusCode: 200) }
}
#endif
