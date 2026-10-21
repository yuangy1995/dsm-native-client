#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 所有账号、邮件与口令均为合成值；本替身只在内存中修改目录。
actor MobileDirectoryUITransport: DsmHTTPTransport {
    struct Request: Sendable { let api: String; let method: String; let fields: [String: String] }
    private var mode: String
    private var users: [[String: Any]]
    private var groups: [[String: Any]]
    private var calls: [Request] = []
    private var didFail = false
    private var wrote = false
    private var block: String?
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiters: [(String, Int, CheckedContinuation<Void, Never>)] = []
    init(mode: String = "nas-directory") {
        self.mode = mode
        users = [Self.user("sample-user", id: 1100), Self.user("fixture", id: 1101)]
        groups = [["name": "sample-team", "gid": 2100, "description": "Sample team", "can_edit": true, "can_delete": true],
                  ["name": "users", "gid": 100, "description": "All users", "can_edit": true, "can_delete": false]]
        if mode == "nas-directory-empty" { users = []; groups = [] }
        if mode == "nas-directory-recover" { users[0]["description"] = "Updated account" }
        if mode == "nas-directory-missing-groups" { users[0].removeValue(forKey: "groups") }
        if mode == "nas-directory-readonly" {
            for field in ["expired", "email", "description"] { users[0].removeValue(forKey: field) }
            users[0]["can_delete"] = false
        }
    }
    private static func user(_ name: String, id: Int) -> [String: Any] {
        ["name": name, "uid": id, "description": "Sample account", "email": "member@example.invalid",
         "expired": "normal", "groups": ["users"], "can_edit": true, "can_delete": true]
    }
    func requests() -> [Request] { calls }
    func setMode(_ value: String) { mode = value }
    func replaceUser() {
        if let index = users.firstIndex(where: { $0["name"] as? String == "sample-user" }) { users[index]["uid"] = 1199 }
    }
    func changeGroups() { groups[0]["gid"] = 2199 }
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
        guard [DsmAPIName.coreUser, DsmAPIName.coreGroup].contains(api) else { throw URLError(.unsupportedURL) }
        let user = api == DsmAPIName.coreUser
        calls.append(.init(api: api, method: method, fields: fields))
        let completed = waiters.filter { method, count, _ in calls.filter { $0.method == method }.count >= count }
        waiters.removeAll { method, count, _ in calls.filter { $0.method == method }.count >= count }
        for item in completed { item.2.resume() }
        if block == method { block = nil; await withCheckedContinuation { blocked = $0 } }
        if method == "list" {
            if mode == "nas-directory-loading" { try await Task.sleep(for: .seconds(30)) }
            if mode == "nas-directory-error" || mode == "nas-directory-retry" && !didFail { didFail = true; throw URLError(.notConnectedToInternet) }
            if wrote && (mode.contains("unknown") || mode == "nas-directory-accepted-offline") { throw URLError(.notConnectedToInternet) }
            if mode == "nas-directory-malformed" { return response([user ? "users" : "groups": NSNull()]) }
            return response([user ? "users" : "groups": user ? users : groups])
        }
        guard ["create", "set", "delete"].contains(method) else { throw URLError(.unsupportedURL) }
        // 密码界面场景必须把指定合成口令完整送达，不能仅凭两次输入碰巧相同而通过。
        if mode == "nas-directory-password", user, method == "create",
           fields["password"] != "synthetic-only" || fields["password_confirm"] != "synthetic-only" {
            return .init(data: Data(#"{"success":false,"error":{"code":400}}"#.utf8), statusCode: 200)
        }
        if mode == "nas-directory-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
        var values = user ? users : groups
        if method == "delete" {
            let names = (try? JSONDecoder().decode([String].self, from: Data((fields["name"] ?? "[]").utf8))) ?? []
            values.removeAll { names.contains($0["name"] as? String ?? "") }
        } else {
            let name = fields["name"] ?? ""
            var item = values.first { $0["name"] as? String == name }
                ?? (user ? Self.user(name, id: 1200) : ["name": name, "gid": 2200, "can_edit": true, "can_delete": true])
            item["description"] = fields["description"] ?? ""
            if user {
                item["email"] = fields["email"] ?? ""
                item["expired"] = fields["expired"] == "true" ? "now" : "normal"
                if let text = fields["groups"] { item["groups"] = try JSONDecoder().decode([String].self, from: Data(text.utf8)) }
            }
            values.removeAll { $0["name"] as? String == name }; values.append(item)
        }
        if user { users = values } else { groups = values }; wrote = true
        if mode.contains("unknown") || mode == "nas-directory-lost-ack" { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private func response(_ value: [String: Any]) -> DsmHTTPResponse {
        .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": value]), statusCode: 200)
    }
}
#endif
