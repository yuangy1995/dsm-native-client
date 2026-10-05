#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 区域与时间测试只使用内存中的合成 NAS 时钟，不修改设备时间或外部服务。
actor MobileRegionUITransport: DsmHTTPTransport {
    struct Request: Sendable { let method: String; let fields: [String: String] }
    private var mode: String
    private var configuration: [String: Any]
    private var calls: [Request] = []
    private var didReadFail = false
    private var didSyncFail = false
    private var saved = false
    private var synchronized = false
    private var block: String?
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiters: [(String, Int, CheckedContinuation<Void, Never>)] = []
    init(mode: String = "nas-region") {
        self.mode = mode
        configuration = ["date_format": "Y-m-d", "time_format": "H:i", "timezone": "UTC",
            "enable_ntp": mode.contains("manual") ? "manual" : "ntp", "server": mode.contains("manual") ? "" : "time.example.invalid",
            "date": "2026/10/5", "hour": 8, "minute": 15, "second": 0]
        if mode == "nas-region-recover" { configuration["time_format"] = "h:i a" }
        if mode == "nas-region-missing-clock" { configuration.removeValue(forKey: "hour"); configuration["enable_ntp"] = "manual" }
    }
    func requests() -> [Request] { calls }
    func setMode(_ value: String) { mode = value }
    func changeConfiguration() { configuration["timezone"] = "Asia/Shanghai" }
    func changeClock(hour: Int) { configuration["hour"] = hour }
    func blockNext(_ method: String) { block = method }
    func release() { block = nil; blocked?.resume(); blocked = nil }
    func waitFor(_ method: String, count: Int = 1) async {
        if calls.filter({ $0.method == method }).count >= count { return }
        await withCheckedContinuation { waiters.append((method, count, $0)) }
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + text)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard fields["api"] == DsmAPIName.coreRegionNTP else { throw URLError(.unsupportedURL) }
        let method = fields["method"] ?? ""
        calls.append(.init(method: method, fields: fields))
        let completed = waiters.filter { method, count, _ in calls.filter { $0.method == method }.count >= count }
        waiters.removeAll { method, count, _ in calls.filter { $0.method == method }.count >= count }
        for item in completed { item.2.resume() }
        if block == method { block = nil; await withCheckedContinuation { blocked = $0 } }
        switch method {
        case "get":
            if mode == "nas-region-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-region-error" || mode == "nas-region-retry" && !didReadFail {
                didReadFail = true; throw URLError(.notConnectedToInternet)
            }
            if saved && ["nas-region-unknown", "nas-region-accepted-offline", "nas-region-manual-unknown"].contains(mode)
                || synchronized && mode == "nas-region-sync-accepted-offline" { throw URLError(.notConnectedToInternet) }
            if mode == "nas-region-empty" { return response([:]) }
            return response(configuration)
        case "listzone": return response(["zonedata": [
            ["value": "UTC", "display": "UTC"], ["value": "Asia/Shanghai", "display": "Asia/Shanghai"],
            ["value": "America/New_York", "display": "America/New_York"]]])
        case "set":
            if mode == "nas-region-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
            for name in ["date_format", "time_format", "timezone", "enable_ntp", "server", "date"] {
                if let value = fields[name] { configuration[name] = value }
            }
            for name in ["hour", "minute", "second"] { if let value = fields[name].flatMap(Int.init) { configuration[name] = value } }
            saved = true
            if mode == "nas-region-unknown" || mode == "nas-region-manual-unknown" { throw URLError(.networkConnectionLost) }
            return response([:])
        case "sync":
            if mode == "nas-region-sync-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
            synchronized = true
            if mode.hasSuffix("sync-timeout") && !didSyncFail { didSyncFail = true; throw URLError(.timedOut) }
            return response([:])
        default: throw URLError(.unsupportedURL)
        }
    }
    private func response(_ value: [String: Any]) -> DsmHTTPResponse {
        .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": value]), statusCode: 200)
    }
}
#endif
