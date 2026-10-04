#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 建群分步恢复的合成服务，只在内存处理请求，不连接 NAS。
actor MobileChatGroupUITransport: DsmHTTPTransport {
    private let base = MobileChatUITransport()
    private var state: String
    private struct Group { let id: String; let title: String; var members: Set<String> }
    private var groups: [String: Group] = [:]
    private var createCount = 0
    private var joinCount = 0
    private var inviteCount = 0
    private var reads = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(state: String = "chat-group-content", restored: [MobileChatGroupCreationStore.Entry] = []) {
        self.state = state
        for (index, entry) in restored.enumerated() {
            let id = entry.receipt?.candidateConversationID ?? String(42 + index)
            var members: Set<String> = entry.receipt?.join == .ready ? [] : ["1"]
            if entry.receipt?.invite == .submitted || entry.receipt?.invite == .completed || entry.receipt?.candidateConversationID == nil {
                members.formUnion(entry.memberIDs)
            }
            groups[id] = .init(id: id, title: entry.title, members: members)
        }
    }
    func counts() -> (create: Int, join: Int, invite: Int, reads: Int) { (createCount, joinCount, inviteCount, reads) }
    func setState(_ value: String) { state = value }
    func waitUntilBlocked() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let text = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + text)?.queryItems ?? []
        func field(_ key: String) -> String? { fields.first { $0.name == key }?.value }
        switch (field("api"), field("method")) {
        case (DsmAPIName.chatUser, "list"):
            return try response(["success": true, "data": ["current_user_id": 1, "users": [
                ["user_id": 1, "username": "fixture", "nickname": "Sample author"],
                ["user_id": 2, "nickname": "Sample member"], ["user_id": 3, "nickname": "Another member"]]]])
        case (DsmAPIName.chatChannel, "list"):
            reads += 1
            if state == "chat-group-read-unavailable", !groups.isEmpty { throw URLError(.notConnectedToInternet) }
            let values: [[String: Any]] = [["channel_id": 27, "type": "named", "name": "Sample chat", "members": [1, 2], "encrypted": false]]
                + groups.values.map { ["channel_id": $0.id, "type": "private", "name": $0.title, "members": Array($0.members), "encrypted": false] }
            return try response(["success": true, "data": ["channels": values]])
        case (DsmAPIName.chatChannelMember, "get"):
            reads += 1
            return try response(["success": true, "data": ["user_ids": Array(groups[field("channel_id") ?? ""]?.members ?? [])]])
        case (DsmAPIName.chatChannelNamed, "create"):
            createCount += 1
            if state == "chat-group-create-denied" { return try rejected() }
            let id = String((groups.keys.compactMap(Int.init).max() ?? 41) + 1), title = field("name") ?? ""
            groups[id] = .init(id: id, title: title, members: [])
            if state == "chat-group-paused" {
                await withCheckedContinuation { continuation = $0; waiters.forEach { $0.resume() }; waiters.removeAll() }
            }
            if state == "chat-group-create-lost" { throw URLError(.networkConnectionLost) }
            return try response(["success": true, "data": ["channel_id": id]])
        case (DsmAPIName.chatChannelNamed, "join"):
            joinCount += 1
            guard let id = field("channel_id"), groups[id] != nil else { throw URLError(.badServerResponse) }
            groups[id]?.members.insert("1")
            if state == "chat-group-join-lost" { throw URLError(.networkConnectionLost) }
            return try response(["success": true])
        case (DsmAPIName.chatChannelNamed, "invite"):
            inviteCount += 1
            guard let id = field("channel_id"), groups[id] != nil,
                  let data = field("user_ids")?.data(using: .utf8) else { throw URLError(.badServerResponse) }
            if state == "chat-group-invite-denied" { return try rejected() }
            groups[id]?.members.formUnion(try JSONDecoder().decode([String].self, from: data))
            if state == "chat-group-invite-lost" { throw URLError(.networkConnectionLost) }
            return try response(["success": true])
        case (DsmAPIName.chatPost, "list") where groups[field("channel_id") ?? ""] != nil:
            return try response(["success": true, "data": ["posts": []]])
        default: return try await base.send(request)
        }
    }
    private func rejected() throws -> DsmHTTPResponse { try response(["success": false, "error": ["code": 105]]) }
    private func response(_ value: [String: Any]) throws -> DsmHTTPResponse {
        .init(data: try JSONSerialization.data(withJSONObject: value), statusCode: 200)
    }
}
#endif
