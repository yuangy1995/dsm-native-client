#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 所有数据均为合成；供移动端管理流程与系统 UI 测试共用真实适配链路。
actor MobileNasStorageUITransport: DsmBinaryHTTPTransport {
    struct Request: Sendable {
        let api: String
        let method: String
        let fields: [String: String]
    }
    private var mode: String
    private var running: NasDiskTestType?
    private var submitted = false
    private var device = "synthetic-device"
    private var calls: [Request] = []
    private var block: String?
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiters: [(String, Int, CheckedContinuation<Void, Never>)] = []

    init(mode: String = "nas-storage", running: NasDiskTestType? = nil) { self.mode = mode; self.running = running }
    func setMode(_ mode: String) { self.mode = mode }
    func setRunning(_ running: NasDiskTestType?) { self.running = running }
    func replaceDevice() { device = "replacement-device" }
    func requests() -> [Request] { calls }
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
        let completed = waiters.filter { expected, count, _ in calls.filter { $0.method == expected }.count >= count }
        waiters.removeAll { expected, count, _ in calls.filter { $0.method == expected }.count >= count }
        for value in completed { value.2.resume() }
        if block == method { block = nil; await withCheckedContinuation { blocked = $0 } }
        if mode == "nas-storage-error", api == DsmAPIName.storageOverview { throw URLError(.notConnectedToInternet) }
        if mode == "nas-storage-loading", api == DsmAPIName.storageOverview { try await Task.sleep(for: .seconds(30)) }
        if api == DsmAPIName.coreSystemLog,
           mode == "nas-logs-error" || (mode == "nas-logs-retry" && calls.filter({ $0.api == api }).count == 1) { throw URLError(.notConnectedToInternet) }
        if mode == "nas-logs-loading", api == DsmAPIName.coreSystemLog { try await Task.sleep(for: .seconds(30)) }
        let data: [String: Any]
        switch (api, method) {
        case (DsmAPIName.storageOverview, "load_info"):
            let empty = mode == "nas-storage-empty"
            data = ["disks": empty ? [] : [["id": "synthetic-disk", "device": device, "longName": "Sample drive", "smart_test_support": mode != "nas-storage-no-smart",
                                           "model": "Synthetic model", "vendor": "Synthetic vendor", "diskType": "SSD", "isSsd": true, "serial": "synthetic-serial", "firm": "synthetic-firmware", "container": ["str": "Bay 1"], "is4Kn": true, "used_by": "synthetic-pool", "size_total": 1_000_000_000, "summary_status_key": "normal", "smart_status": "normal", "temp": 30]],
                    "storagePools": empty ? [] : [["id": "synthetic-pool", "desc": "Sample pool", "raidType": "single", "is_writable": true, "data_scrubbing": false, "size": ["total": 900_000_000, "used": 250_000_000], "disks": ["synthetic-disk"]]],
                    "volumes": empty ? [] : [["id": "synthetic-volume", "vol_desc": "Sample volume", "fs_type": "btrfs", "vol_path": "/synthetic-volume", "is_encrypted": false, "is_writable": true, "pool_path": "synthetic-pool", "size": ["total": 800_000_000, "used": 200_000_000]]]]
        case (DsmAPIName.coreStorageDisk, "get_smart_test_log"):
            if mode == "nas-storage-unknown", submitted { throw URLError(.networkConnectionLost) }
            var info: [String: Any] = ["device": device, "testing": running != nil, "ihm_testing": false, "perf_testing": false]
            if let running { info["test_type"] = running == .quick ? "quick" : "extend"; info["progress"] = "25%" }
            data = ["testInfo": [info]]
        case (DsmAPIName.coreStorageDisk, "disk_test_log_get"):
            data = ["testLog": [["type": "smart", "test_type": "quick", "time": "2026-10-01 08:00:00", "result": "normal"]]]
        case (DsmAPIName.coreStorageDisk, "do_smart_test"):
            submitted = true
            if mode == "nas-storage-forbidden" { return try response(["success": false, "error": ["code": 105]]) }
            switch fields["type"] {
            case "quick": running = mode == "nas-storage-mismatch" ? .extended : .quick
            case "extend": running = .extended
            case "stop": running = nil
            default: throw URLError(.badServerResponse)
            }
            if mode == "nas-storage-unknown" { throw URLError(.networkConnectionLost) }
            data = [:]
        case (DsmAPIName.coreSystemLog, "list"):
            if mode == "nas-logs-malformed" { data = [:]; break }
            let total = mode == "nas-logs-empty" ? 0 : 103
            let offset = Int(fields["offset"] ?? "0") ?? 0, limit = Int(fields["limit"] ?? "50") ?? 50
            let items: [[String: Any]] = (min(offset, total)..<min(offset + limit, total)).map { index in
                ["time": "2026-10-05 08:00:" + String(format: "%02d", index % 60), "logtype": "System",
                 "level": ["info", "warn", "error"][index % 3], "who": "Synthetic account",
                 "descr": "Synthetic log \(index + 1)\nComplete details for synthetic log \(index + 1)."]
            }
            var result: [String: Any] = ["items": items]
            if mode != "nas-logs-unknown-total" { result["total"] = total }
            data = result
        case (DsmAPIName.fileStationList, "list_share"):
            data = ["shares": mode == "nas-analysis-incomplete" ? [] : [["name": "Sample folder", "path": "/fixture", "isdir": true]], "offset": 0, "total": 1]
        case (DsmAPIName.fileStationSearch, "start"):
            if mode == "nas-analysis-error" { throw URLError(.notConnectedToInternet) }
            if mode == "nas-analysis-loading" { try await Task.sleep(for: .seconds(30)) }
            data = ["taskid": "synthetic-search"]
        case (DsmAPIName.fileStationSearch, "list"):
            let names = ["a.txt", "a-copy.txt", "photo.jpg", "unknown.dat"]
            let rows: [[String: Any]] = names.enumerated().map { index, name in
                var additional: [String: Any] = ["owner": ["user": "Synthetic owner"], "time": ["mtime": 1_790_000_000 + index, "atime": 1_780_000_000 + index]]
                if index < 3 { additional["size"] = index == 2 ? 8192 : 4096 }
                return ["name": name, "path": "/fixture/" + name, "isdir": false, "additional": additional]
            }
            data = ["files": mode == "nas-analysis-empty" ? [] : rows, "offset": 0, "total": mode == "nas-analysis-empty" ? 0 : rows.count, "finished": true]
        case (DsmAPIName.fileStationSearch, "clean"), (DsmAPIName.fileStationSearch, "stop"):
            data = [:]
        case (DsmAPIName.fileStationMD5, "start"):
            data = ["taskid": "synthetic-checksum"]
        case (DsmAPIName.fileStationMD5, "status"):
            if mode == "nas-analysis-partial" { throw URLError(.notConnectedToInternet) }
            data = ["finished": true, "md5": "0123456789abcdef0123456789abcdef"]
        case (DsmAPIName.fileStationMD5, "stop"):
            data = [:]
        default: throw URLError(.unsupportedURL)
        }
        return try response(["success": true, "data": data])
    }
    private func response(_ value: [String: Any]) throws -> DsmHTTPResponse {
        .init(data: try JSONSerialization.data(withJSONObject: value), statusCode: 200)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
}
#endif
