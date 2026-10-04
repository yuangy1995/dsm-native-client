#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 转发端到端合成服务，只接受测试域请求，不访问网络。
actor MobileChatForwardUITransport: DsmHTTPTransport {
    private let state: String
    private var posts: [String: [[String: Any]]] = [:]
    private var writes: [(String, [Int])] = []
    private var directWrites = 0
    private var createdDirect = false
    private var channelsRead = 0
    private var partialResolved = false
    private var sourceChanged = false
    private var writeHook: (@Sendable () async -> Void)?

    init(state: String = "chat-forward-content", receipts: [ChatForwardReceipt] = []) {
        self.state = state
        createdDirect = state == "chat-forward-contact-restored"
        for receipt in receipts {
            for target in receipt.targets {
                posts[target.conversationID, default: []].append(Self.post(
                    id: target.confirmedMessageID ?? "forward-\(receipt.sourceMessageID)-\(target.conversationID)",
                    channel: target.conversationID, text: Self.text(receipt.sourceMessageID),
                    sentAt: receipt.submittedAt.addingTimeInterval(0.01), author: 1))
            }
        }
    }
    func recordedWrites() -> [(String, [Int])] { writes }
    func recordedDirectWrites() -> Int { directWrites }
    func resolvePartial() { partialResolved = true }
    func changeSource() { sourceChanged = true }
    func onWrite(_ hook: @escaping @Sendable () async -> Void) { writeHook = hook }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        guard request.url?.host == "fixture.example.invalid" else { throw URLError(.unsupportedURL) }
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
        let result: [String: Any]
        switch (field("api"), field("method")) {
        case (DsmAPIName.chatUser, "list"):
            result = ["current_user_id": 1, "users": [["user_id": 1, "nickname": "Sample author", "username": "fixture"]]
                + (state == "chat-forward-targets-empty" ? [] : [["user_id": 2, "nickname": "New recipient", "username": "recipient"]])]
        case (DsmAPIName.chatChannel, "list"):
            channelsRead += 1
            if channelsRead > 1 && state == "chat-forward-targets-error" { throw URLError(.notConnectedToInternet) }
            if channelsRead > 1 && state == "chat-forward-targets-loading" { try await Task.sleep(for: .seconds(30)) }
            if createdDirect && state == "chat-forward-contact-unknown" { throw URLError(.networkConnectionLost) }
            var channels: [[String: Any]] = [["channel_id": 27, "type": "named", "name": "Sample chat", "members": [1, 3], "encrypted": false]]
            if state != "chat-forward-targets-empty" {
                channels += [["channel_id": 28, "type": "named", "name": "Project chat", "members": [1, 3], "encrypted": false],
                             ["channel_id": 30, "type": "named", "name": "Team chat", "members": [1, 3], "encrypted": false]]
            }
            if createdDirect { channels.append(["channel_id": 29, "type": "anonymous", "members": [1, 2], "member_count": 2, "encrypted": false]) }
            result = ["channels": channels]
        case (DsmAPIName.chatAdminSetting, "get"):
            result = ["allow_edit_message": true, "allow_edit_message_time_within_min": 0]
        case (DsmAPIName.chatChannelAnonymous, "initiate"):
            guard field("user_ids") == #"["2"]"#, field("encrypted") == "false" else { throw URLError(.badServerResponse) }
            directWrites += 1; createdDirect = true
            if state == "chat-forward-contact-unknown" { throw URLError(.networkConnectionLost) }
            result = ["channel_id": 29]
        case (DsmAPIName.chatPost, "list"):
            let channel = field("channel_id") ?? "27"
            if channel == "30", !writes.isEmpty, state == "chat-forward-partial", !partialResolved { throw URLError(.notConnectedToInternet) }
            var values: [[String: Any]]
            if channel == "27" {
                values = [Self.post(id: "9001", channel: channel, text: sourceChanged ? "Changed content" : Self.text("9001"), author: 1),
                          Self.post(id: "9002", channel: channel, text: Self.text("9002"), author: 3,
                            attachment: state == "chat-forward-attachment")]
            } else { values = posts[channel] ?? [] }
            if let id = field("post_id"), field("prev_count") == "0" { values = values.filter { $0["post_id"] as? String == id } }
            result = ["posts": values]
        case (DsmAPIName.chatPost, "forward"):
            let id = field("post_id") ?? "", data = Data((field("channel_ids") ?? "").utf8)
            let targets = try JSONDecoder().decode([Int].self, from: data)
            guard ["9001", "9002"].contains(id), !targets.isEmpty, targets.allSatisfy({ [28, 29, 30].contains($0) }) else { throw URLError(.badServerResponse) }
            writes.append((id, targets))
            if state == "chat-forward-denied" { return try response(["success": false, "error": ["code": 105]]) }
            if state == "chat-forward-slow" { try await Task.sleep(for: .milliseconds(200)) }
            for target in targets {
                posts[String(target), default: []].append(Self.post(id: "forward-\(id)-\(target)", channel: String(target),
                    text: Self.text(id), sentAt: Date().addingTimeInterval(Double(writes.count) * 0.05), author: 1,
                    attachment: state == "chat-forward-attachment" && id == "9002"))
            }
            if let writeHook { await writeHook() }
            if state == "chat-forward-unknown" { throw URLError(.networkConnectionLost) }
            return try response(["success": true])
        default: throw URLError(.unsupportedURL)
        }
        return try response(["success": true, "data": result])
    }
    private func response(_ value: [String: Any]) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: value), statusCode: 200)
    }
    private static func text(_ id: String) -> String { id == "9001" ? "Sample message 1" : "Sample message 2" }
    private static func post(id: String, channel: String, text: String, sentAt: Date? = nil, author: Int, attachment: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["post_id": id, "channel_id": Int(channel) ?? 27, "creator_id": author, "create_at": sentAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? (1_790_000_000_000 + Int64(id)!),
         "update_at": 0, "thread_id": "0", "type": "normal", "message": text]
        if attachment { value["files"] = [["file_id": "file-\(id)", "name": "Sample.pdf", "content_type": "application/pdf", "size": 128]] }
        return value
    }
}
#endif
