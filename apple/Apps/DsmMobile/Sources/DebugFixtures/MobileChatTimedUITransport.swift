#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 提醒与定时消息合成服务；只在显式 Debug 测试入口注入，不连接 NAS。
actor MobileChatTimedUITransport: DsmBinaryHTTPTransport {
    private struct Snapshot: Codable { var reminders: [ChatReminder]; var schedules: [ChatScheduledMessage] }
    private let base = MobileChatUITransport()
    private let state: String
    private let snapshotURL: URL?
    private let afterCreate: (@Sendable () throws -> Void)?
    private var snapshot: Snapshot
    private var writes: [String: Int] = [:]
    private var reads = 0
    private var failReads = false
    private var encrypted = false
    private var noAccess = false
    private var duplicates = false

    init(state: String = "chat-timed-content", root: URL? = nil, afterCreate: (@Sendable () throws -> Void)? = nil) {
        self.state = state; self.afterCreate = afterCreate
        snapshotURL = root?.appendingPathComponent("timed-fixture.json")
        let date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400).rounded(.down))
        if state == "chat-timed-restored", let snapshotURL, let data = try? Data(contentsOf: snapshotURL),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) { snapshot = saved }
        else {
            snapshot = Snapshot(reminders: state == "chat-timed-empty" ? [] : [ChatReminder(id: "9001", messageID: "9001", remindAt: date)],
                schedules: state == "chat-timed-empty" ? [] : [ChatScheduledMessage(id: "job-1", conversationID: "27", text: "Scheduled sample", sendAt: date)])
        }
    }
    func counts() -> (writes: [String: Int], reads: Int) { (writes, reads) }
    func setReadFailures(_ value: Bool) { failReads = value }
    func setAccess(encrypted: Bool = false, missing: Bool = false) { self.encrypted = encrypted; noAccess = missing }
    func setDuplicates(_ value: Bool) { duplicates = value }
    func changeReminder() { snapshot.reminders = snapshot.reminders.map { ChatReminder(id: $0.id, messageID: $0.messageID, remindAt: $0.remindAt.addingTimeInterval(60)) } }
    func changeSchedule() { snapshot.schedules = snapshot.schedules.map { ChatScheduledMessage(id: $0.id, conversationID: $0.conversationID, text: "Changed elsewhere", sendAt: $0.sendAt) } }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
        let api = field("api"), method = field("method")
        if api == DsmAPIName.chatChannel, method == "list", encrypted || noAccess {
            return try response(["channels": noAccess ? [] : [["channel_id": 27, "type": "named", "name": "Sample chat", "members": [1, 2], "encrypted": true]]])
        }
        guard api == DsmAPIName.chatPostReminder || api == DsmAPIName.chatPostSchedule else { return try await base.send(request) }
        let reminder = api == DsmAPIName.chatPostReminder
        if method == "list" {
            reads += 1
            if failReads || state == "chat-timed-load-error" { throw URLError(.notConnectedToInternet) }
            if state == "chat-timed-loading" { try await Task.sleep(for: .seconds(30)) }
            if reminder {
                let values = field("channel_id") == "27" ? snapshot.reminders.map { ["post_id": $0.messageID, "reminder_id": $0.id, "remind_at": Int64($0.remindAt.timeIntervalSince1970 * 1_000)] as [String: Any] } : []
                return try response(["reminders": duplicates ? values + values : values])
            }
            let values = field("channel_id") == "27" ? snapshot.schedules.map { ["cronjob_id": $0.id, "channel_id": $0.conversationID, "message": $0.text, "send_at": Int64($0.sendAt.timeIntervalSince1970 * 1_000)] as [String: Any] } : []
            return try response(["schedules": duplicates ? values + values : values])
        }
        let key = (reminder ? "reminder-" : "schedule-") + (method ?? "")
        writes[key, default: 0] += 1
        if state == "chat-timed-denied" { return try failure(105) }
        if state == "chat-timed-slow" { try await Task.sleep(for: .milliseconds(150)) }
        var result: [String: Any] = [:]
        switch (reminder, method) {
        case (true, "set"):
            guard let id = field("post_id"), let raw = field("remind_at"), let date = Double(raw) else { throw URLError(.badServerResponse) }
            snapshot.reminders.removeAll { $0.messageID == id }
            snapshot.reminders.append(ChatReminder(id: id, messageID: id, remindAt: Date(timeIntervalSince1970: date / 1_000)))
        case (true, "delete"):
            snapshot.reminders.removeAll { $0.messageID == field("post_id") }
        case (false, "create"):
            guard let id = field("channel_id"), let text = field("message"), let raw = field("send_at"), let date = Double(raw) else { throw URLError(.badServerResponse) }
            let jobID = "job-\(100 + writes[key, default: 0])"
            snapshot.schedules.append(ChatScheduledMessage(id: jobID, conversationID: id, text: text, sendAt: Date(timeIntervalSince1970: date / 1_000)))
            result = ["cronjob_id": jobID]
        case (false, "delete"):
            snapshot.schedules.removeAll { $0.id == field("cronjob_id") }
        default: throw URLError(.unsupportedURL)
        }
        if let snapshotURL {
            try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
        }
        if state == "chat-timed-unknown" { failReads = true; throw URLError(.networkConnectionLost) }
        if state == "chat-timed-read-failure" { failReads = true }
        if !reminder, method == "create" { try afterCreate?() }
        return try response(result)
    }
    private func response(_ data: [String: Any]) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
    private func failure(_ code: Int) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": false, "error": ["code": code]]), statusCode: 200)
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try await base.download(request, to: destinationURL, progress: progress)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
}
#endif
