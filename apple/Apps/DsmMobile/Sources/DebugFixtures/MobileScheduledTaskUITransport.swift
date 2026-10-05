#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 仅隔离自动化场景；脚本内容只作为文本保存，从不在本机执行。
actor MobileScheduledTaskUITransport: DsmHTTPTransport {
    private var mode: String
    private let onRead: @Sendable () async -> Void
    private var didFail = false
    private var held = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var rows: [Int: [String: Any]] = [:]
    private var details: [Int: [String: Any]] = [:]
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { ["create", "set", "set_enable", "run", "delete"].contains($0["method"] ?? "") } }
    init(mode: String = "nas-tasks", username: String = "operator", onRead: @escaping @Sendable () async -> Void = {}) {
        self.mode = mode; self.onRead = onRead
        if mode != "nas-tasks-empty" {
            rows[12] = ["id": 12, "name": "Sample Task", "owner": username, "real_owner": username, "type": "script", "action": "User script", "enable": true, "can_run": true, "can_edit": true, "next_trigger_time": "2026-10-07 08:15:00"]
            details[12] = ["id": 12, "name": "Sample Task", "owner": username, "real_owner": username, "enable": true,
                "schedule": ["date_type": 0, "week_day": "1,2,3,4,5", "repeat_date": 1002, "monthly_week": [1,3], "date": "2026-10-07", "hour": 8, "minute": 15, "repeat_hour": 2, "repeat_min": 0, "last_work_hour": 18],
                "extra": ["script": "echo initial", "notify_if_error": false, "notify_mail": ""]]
        }
        if mode == "nas-tasks-recover" {
            rows[12]?["name"] = "Updated Task"; details[12]?["name"] = "Updated Task"
            details[12]?["extra"] = ["script": "echo updated", "notify_if_error": false, "notify_mail": ""]
        }
        if mode == "nas-tasks-create-recover" {
            rows[20] = ["id":20, "name":"New Task", "owner":username, "real_owner":username, "type":"script", "enable":true, "can_run":true, "can_edit":true]
            details[20] = ["id":20, "name":"New Task", "owner":username, "real_owner":username, "enable":true,
                "schedule":["date_type":0, "week_day":"0,1,2,3,4,5,6", "repeat_date":1001, "monthly_week":[], "hour":0, "minute":0, "repeat_hour":0, "repeat_min":0, "last_work_hour":0],
                "extra":["script":"echo created", "notify_if_error":false, "notify_mail":""]]
        }
        if mode == "nas-tasks-unknown-enabled" { rows[12]?.removeValue(forKey: "enable") }
        if mode == "nas-tasks-non-script" { rows[12]?["type"] = "system"; rows[12]?["action"] = "System task"; rows[12]?["can_edit"] = false }
        if mode == "nas-tasks-incomplete" { details[12]?.removeValue(forKey: "schedule") }
    }
    func setMode(_ mode: String) { self.mode = mode }
    func suspendWrites() { held = true }
    func resumeWrites() { held = false; waiter?.resume(); waiter = nil }
    func changeScript(_ script: String = "echo changed elsewhere") {
        var extra = details[12]?["extra"] as? [String: Any] ?? [:]; extra["script"] = script; details[12]?["extra"] = extra
    }
    func setEnabled(_ value: Bool) { rows[12]?["enable"] = value; details[12]?["enable"] = value }
    func setWeekdays(_ value: String) { var schedule = details[12]?["schedule"] as? [String: Any] ?? [:]; schedule["week_day"] = value; details[12]?["schedule"] = schedule }
    func changeOwner() { rows[12]?["real_owner"] = "different"; details[12]?["real_owner"] = "different" }
    func removeTask() { rows.removeValue(forKey: 12); details.removeValue(forKey: 12) }
    func addDuplicateName() { var duplicate = rows[12] ?? [:]; duplicate["id"] = 13; duplicate["owner"] = "another"; rows[13] = duplicate }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields); let method = fields["method"] ?? "", id = Int(fields["id"] ?? "") ?? 12
        if mode == "nas-tasks-trust" || mode == "nas-tasks-trust-write" && ["create", "set", "set_enable", "run", "delete"].contains(method) { throw URLError(.serverCertificateUntrusted) }
        if ["list", "get", "result_list", "result_get_file"].contains(method) {
            if mode == "nas-tasks-readonly" { await onRead() }
            if mode == "nas-tasks-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-tasks-error" || mode == "nas-tasks-retry" && !didFail { didFail = true; throw URLError(.notConnectedToInternet) }
            if !writes.isEmpty && ["nas-tasks-unknown", "nas-tasks-accepted-offline"].contains(mode) { throw URLError(.notConnectedToInternet) }
            if method == "list" { return response(["tasks": rows.keys.sorted().compactMap { rows[$0] }]) }
            if method == "get" { return response(details[id] ?? [:]) }
            if method == "result_list" {
                if mode == "nas-tasks-results-error" { throw URLError(.notConnectedToInternet) }
                if mode == "nas-tasks-noresults" { return response([]) }
                return response([["result_id":"result-1", "task_name":fields["task_name"] ?? "", "start_time":"2026-10-06 08:15:00", "stop_time":"2026-10-06 08:15:03", "exit_info":["exit_type":"normal", "exit_code":0], "trigger_event":"manual"]])
            }
            if mode == "nas-tasks-output-error" { throw URLError(.notConnectedToInternet) }
            return response(["script_in":"echo synthetic output", "script_out":"SYNTHETIC OUTPUT START\n" + String(repeating: "Synthetic task output line.\n", count: 60) + "SYNTHETIC OUTPUT END"])
        }
        if held { await withCheckedContinuation { waiter = $0 } }
        if mode == "nas-tasks-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
        switch method {
        case "create", "set":
            let target = method == "create" ? (mode == "nas-tasks-reuse-id" ? 12 : 20) : id
            let owner = fields["owner"] ?? "operator", realOwner = fields["real_owner"] ?? owner
            let schedule = try JSONSerialization.jsonObject(with: Data((fields["schedule"] ?? "{}").utf8))
            let extra = try JSONSerialization.jsonObject(with: Data((fields["extra"] ?? "{}").utf8))
            let enabled = fields["enable"] == "true"
            rows[target] = ["id":target, "name":fields["name"] ?? "", "owner":owner, "real_owner":realOwner, "type":"script", "action":"User script", "enable":enabled, "can_run":true, "can_edit":true]
            details[target] = ["id":target, "name":fields["name"] ?? "", "owner":owner, "real_owner":realOwner, "enable":enabled, "schedule":schedule, "extra":extra]
        case "set_enable": rows[id]?["enable"] = fields["enable"] == "true"; details[id]?["enable"] = fields["enable"] == "true"
        case "delete":
            if mode == "nas-tasks-reuse-id" { rows[id]?["real_owner"] = "different" }
            else { rows.removeValue(forKey: id); details.removeValue(forKey: id) }
        case "run": break
        default: return response([:])
        }
        if mode == "nas-tasks-lost-ack" || mode == "nas-tasks-unknown" || mode == "nas-tasks-run-unknown" && method == "run" { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private func response(_ value: Any) -> DsmHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: ["success":true, "data":value]), statusCode: 200) }
}
#endif
