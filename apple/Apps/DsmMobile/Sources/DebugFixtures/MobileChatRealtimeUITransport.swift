#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 分页、阅读回执与通知共用实际 Chat Repository；所有身份和正文均为合成数据。
actor MobileChatRealtimeUITransport: DsmHTTPTransport {
    private let base = MobileChatUITransport()
    private let state: String
    private let epoch: Int
    private var firstConversationReadAt: Date?
    private var count = 60
    private var currentUserLatest = false
    private var viewedAt = 0
    private var rejectReads = false
    private var delayReads = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var reminders: [Int: Int] = [:]
    private(set) var readTimes: [Int] = []
    private(set) var replyViews = 0
    private(set) var conversationReads = 0
    private(set) var messageReads = 0

    init(state: String = "chat-realtime-history", now: Date = Date()) {
        self.state = state
        self.epoch = Int((now.timeIntervalSince1970 - 60) * 1_000)
        self.rejectReads = state == "chat-realtime-read-denied"
    }
    func appendMessage(isCurrentUser: Bool = false) { count += 1; currentUserLatest = isCurrentUser }
    func setCount(_ value: Int) { count = value }
    func setViewedAt(_ value: Int) { viewedAt = value }
    func setRejectReads(_ value: Bool) { rejectReads = value }
    func setDelayReads(_ value: Bool) { delayReads = value }
    func isReadBlocked() -> Bool { readContinuation != nil }
    func releaseRead() { readContinuation?.resume(); readContinuation = nil; delayReads = false }
    func setReminders(_ values: [Int: Int]) { reminders = values }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
        let result: [String: Any]
        switch (field("api"), field("method")) {
        case (DsmAPIName.chatChannel, "list"):
            conversationReads += 1
            if firstConversationReadAt == nil { firstConversationReadAt = Date() }
            if state == "chat-realtime-live", Date().timeIntervalSince(firstConversationReadAt!) > 15 { count = max(count, 61) }
            result = ["channels": [["channel_id": 27, "type": "named", "name": "Sample chat", "members": [1, 2], "encrypted": false,
                "unread": viewedAt >= timestamp(count) ? 0 : 3, "last_view_at": viewedAt,
                "last_post": post(count)], ["channel_id": 28, "type": "named", "name": "Another chat", "members": [1, 2], "encrypted": false]]]
        case (DsmAPIName.chatChannel, "view"):
            guard field("channel_id") == "27", let time = Int(field("last_view_at") ?? "") else { throw URLError(.badServerResponse) }
            readTimes.append(time)
            if delayReads { await withCheckedContinuation { readContinuation = $0 } }
            if rejectReads { return try response(["success": false, "error": ["code": 105]]) }
            viewedAt = max(viewedAt, time); result = [:]
        case (DsmAPIName.chatPost, "list"):
            messageReads += 1
            if field("channel_id") != "27" { result = ["posts": []]; break }
            let thread = field("thread_id") ?? "0"
            if let id = Int(field("post_id") ?? ""), field("prev_count") == "0" {
                result = ["posts": id <= count ? [post(id)] : []]
            } else if thread != "0" {
                result = ["posts": Array([post(101, thread: thread), post(102, thread: thread)].suffix(Int(field("prev_count") ?? "50") ?? 50))]
            } else {
                let limit = Int(field("prev_count") ?? "50") ?? 50
                let all = (1...max(1, count)).map { post($0) }
                if let cursor = Int(field("post_id") ?? "") {
                    result = ["posts": Array(all.prefix(cursor).suffix(limit + 1))]
                } else { result = ["posts": Array(all.suffix(limit))] }
            }
        case (DsmAPIName.chatPostSubscribe, "view"):
            guard field("channel_id") == "27", field("thread_id") != nil else { throw URLError(.badServerResponse) }
            replyViews += 1; result = [:]
        case (DsmAPIName.chatPostReminder, "list"):
            result = ["reminders": field("channel_id") == "27" ? reminders.map { ["post_id": String($0.key), "remind_at": $0.value] } : []]
        default: return try await base.send(request)
        }
        return try response(["success": true, "data": result])
    }

    private func timestamp(_ id: Int) -> Int { epoch + id * 1_000 }
    private func post(_ id: Int, thread: String = "0") -> [String: Any] {
        ["post_id": String(id), "channel_id": 27, "creator_id": id == count && currentUserLatest ? 1 : 2,
         "create_at": timestamp(id), "thread_id": thread, "type": "normal", "message": "Sample message \(id)"]
    }
    private func response(_ value: [String: Any]) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: value), statusCode: 200)
    }
}
#endif
