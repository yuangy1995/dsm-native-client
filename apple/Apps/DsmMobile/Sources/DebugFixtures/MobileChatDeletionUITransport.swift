#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 删除的端到端合成服务；只允许隔离测试域，所有消息和操作均留在内存。
actor MobileChatDeletionUITransport: DsmHTTPTransport {
    private let state: String
    private var deleted: Set<String> = []
    private var changed: Set<String> = []
    private var writes: [String] = []
    private var resolved = false
    private var visible = true
    private var userID = 1
    private var writeHook: (@Sendable () async -> Void)?
    private var nextReadHook: (@Sendable () async -> Void)?
    init(state: String = "chat-deletion-content") {
        self.state = state
        if state == "chat-deletion-restored" { deleted.insert("9001") }
    }
    func recordedWrites() -> [String] { writes }
    func change(_ id: String) { changed.insert(id) }
    func resolve() { resolved = true; deleted.insert("9001") }
    func setAccess(visible: Bool, userID: Int = 1) { self.visible = visible; self.userID = userID }
    func onWrite(_ hook: @escaping @Sendable () async -> Void) { writeHook = hook }
    func onNextMessageRead(_ hook: @escaping @Sendable () async -> Void) { nextReadHook = hook }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        guard request.url?.host == "fixture.example.invalid" else { throw URLError(.unsupportedURL) }
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ key: String) -> String? { fields.first { $0.name == key }?.value }
        let result: [String: Any]
        switch (field("api"), field("method")) {
        case (DsmAPIName.chatUser, "list"):
            result = ["current_user_id": userID, "users": [["user_id": 1, "nickname": "Sample author", "username": "fixture"],
                                                           ["user_id": 2, "nickname": "Other author", "username": "other"]]]
        case (DsmAPIName.chatChannel, "list"):
            result = ["channels": visible ? [["channel_id": 27, "type": "named", "name": "Sample chat", "members": [1, 2], "encrypted": false]] : []]
        case (DsmAPIName.chatAdminSetting, "get"):
            result = ["allow_edit_message": true, "allow_edit_message_time_within_min": 0]
        case (DsmAPIName.chatPost, "search"):
            result = ["posts": [], "total": 0]
        case (DsmAPIName.chatPost, "list"):
            if let hook = nextReadHook { nextReadHook = nil; await hook() }
            if state == "chat-deletion-loading" { try await Task.sleep(for: .seconds(30)) }
            if state == "chat-deletion-error" || (state == "chat-deletion-partial" && !writes.isEmpty && !resolved) { throw URLError(.notConnectedToInternet) }
            var values = ["9001", "9002", "9003"].filter { !deleted.contains($0) && (state != "chat-deletion-empty" || $0 == "9003") }
                .map { post($0) }
            if let threadID = field("thread_id"), threadID != "0" { values = [] }
            if let id = field("post_id"), field("prev_count") == "0" { values = values.filter { $0["post_id"] as? String == id } }
            result = ["posts": values]
        case (DsmAPIName.chatPost, "delete"):
            guard field("version") == "5", let id = field("post_id"), ["9001", "9002"].contains(id) else { throw URLError(.badServerResponse) }
            writes.append(id)
            if state == "chat-deletion-denied", id == "9002" { return try response(["success": false, "error": ["code": 105]]) }
            if state == "chat-deletion-slow" { try await Task.sleep(for: .milliseconds(200)) }
            if let writeHook { await writeHook() }
            if state == "chat-deletion-unknown" { throw URLError(.networkConnectionLost) }
            deleted.insert(id)
            return try response(["success": true])
        default: throw URLError(.unsupportedURL)
        }
        return try response(["success": true, "data": result])
    }
    private func post(_ id: String) -> [String: Any] {
        var value: [String: Any] = ["post_id": id, "channel_id": 27, "creator_id": id == "9003" ? 2 : 1,
            "message": changed.contains(id) ? "Changed message" : (id == "9003" ? "Other message" : "Sample message \(id == "9001" ? 1 : 2)"),
            "create_at": 1_790_000_000_000 + Int(id)!, "thread_id": "0", "type": "normal"]
        if id == "9002" { value["files"] = [["file_id": "file-9002", "name": "Sample.pdf", "content_type": "application/pdf", "size": 128]] }
        return value
    }
    private func response(_ value: [String: Any]) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: value), statusCode: 200)
    }
}
#endif
