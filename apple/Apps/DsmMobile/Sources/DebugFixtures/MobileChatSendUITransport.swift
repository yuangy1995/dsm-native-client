#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 普通发送的合成服务，支持丢回执与重启恢复；不会请求网络。
actor MobileChatSendUITransport: DsmBinaryHTTPTransport {
    private let base = MobileChatUITransport()
    private let state: String
    private var posts: [String: [String: Any]] = [:]
    private var createCount = 0
    private var recoveryReads = 0
    private var readUnavailable: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var uploadedBodyExists = false

    init(state: String = "chat-send-content", restored: [MobileChatSendStore.Entry] = []) {
        self.state = state; readUnavailable = state == "chat-send-read-unavailable"
        for entry in restored {
            if let receipt = entry.receipt, let id = receipt.candidateMessageID, let payload = entry.payload {
                posts[id] = Self.post(id: id, conversation: entry.conversationID, thread: entry.threadID, text: payload.text,
                    name: payload.attachment?.fileName, size: payload.attachment?.byteCount)
            }
        }
    }
    func counts() -> (writes: Int, reads: Int) { (createCount, recoveryReads) }
    func setReadUnavailable(_ value: Bool) { readUnavailable = value }
    func waitUntilBlocked() async {
        if continuation != nil { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let text = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + text)?.queryItems ?? []
        func field(_ key: String) -> String? { fields.first { $0.name == key }?.value }
        if field("api") == DsmAPIName.chatPost, field("method") == "create" {
            return try await create(conversation: field("channel_id") ?? "", thread: field("thread_id"), text: field("message"))
        }
        if field("api") == DsmAPIName.chatPost, field("method") == "list", field("prev_count") == "0", let id = field("post_id"), posts[id] != nil {
            recoveryReads += 1
            if readUnavailable { throw URLError(.notConnectedToInternet) }
            return try response(["success": true, "data": ["posts": [posts[id]!]]])
        }
        if field("api") == DsmAPIName.chatPost, field("method") == "list", field("prev_count") != "0" {
            if readUnavailable && !posts.isEmpty { throw URLError(.notConnectedToInternet) }
            let original = try await base.send(request)
            let payload = try JSONSerialization.jsonObject(with: original.data) as? [String: Any]
            let data = payload?["data"] as? [String: Any]
            let conversation = Int(field("channel_id") ?? "") ?? 0, thread = field("thread_id") ?? "0"
            var values = ((data?["posts"] as? [[String: Any]] ?? []) + Array(posts.values)).filter {
                $0["channel_id"] as? Int == conversation && $0["thread_id"] as? String == thread
            }.sorted { ($0["create_at"] as? Int64 ?? 0) < ($1["create_at"] as? Int64 ?? 0) }
            if let cursor = field("post_id"), let index = values.firstIndex(where: { $0["post_id"] as? String == cursor }) {
                values = Array(values.prefix(index + 1))
            }
            let limit = (Int(field("prev_count") ?? "50") ?? 50) + (field("post_id") == nil ? 0 : 1)
            return try response(["success": true, "data": ["posts": Array(values.suffix(limit))]])
        }
        return try await base.send(request)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        let data = try Data(contentsOf: bodyFileURL)
        uploadedBodyExists = true
        let text = String(decoding: data, as: UTF8.self)
        guard let boundary = request.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last else {
            throw URLError(.badServerResponse)
        }
        let parts = text.components(separatedBy: "--" + boundary)
        func field(_ name: String) -> String? {
            parts.first { $0.contains("name=\"\(name)\"") && !$0.contains("filename=") }?
                .components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n").trimmingCharacters(in: .newlines)
        }
        guard let part = parts.first(where: { $0.contains("filename=\"") }),
              let start = part.range(of: "filename=\""), let end = part[start.upperBound...].firstIndex(of: "\""),
              let body = part.range(of: "\r\n\r\n") else { throw URLError(.badServerResponse) }
        let name = String(part[start.upperBound..<end])
        let fileText = String(part[body.upperBound...].dropLast(2))
        progress(Int64(data.count), Int64(data.count))
        return try await create(conversation: field("channel_id") ?? "", thread: nil, text: field("message"), name: name, size: Int64(fileText.utf8.count))
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try await base.download(request, to: destinationURL, progress: progress)
    }
    private func create(conversation: String, thread: String?, text: String?, name: String? = nil, size: Int64? = nil) async throws -> DsmHTTPResponse {
        createCount += 1
        if state == "chat-send-denied" { return try response(["success": false, "error": ["code": 105]]) }
        let id = String(9300 + createCount)
        posts[id] = Self.post(id: id, conversation: conversation, thread: thread, text: text, name: name, size: size)
        if state == "chat-send-paused" {
            await withCheckedContinuation { continuation = $0; blockedWaiters.forEach { $0.resume() }; blockedWaiters = [] }
        }
        if state == "chat-send-lost-ack" { throw URLError(.networkConnectionLost) }
        if Task.isCancelled { throw CancellationError() }
        return try response(["success": true, "data": ["post_id": id]])
    }
    private static func post(id: String, conversation: String, thread: String?, text: String?, name: String?, size: Int64?) -> [String: Any] {
        var value: [String: Any] = ["post_id": id, "channel_id": Int(conversation) ?? 0, "creator_id": 1,
            "create_at": 1_790_000_000_000 + (Int64(id) ?? 0), "thread_id": thread ?? "0", "type": "normal", "message": text ?? ""]
        if let name, let size { value["files"] = [["file_id": "attachment", "name": name, "size": size, "content_type": "application/octet-stream"]] }
        return value
    }
    private func response(_ object: [String: Any]) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
}
#endif
