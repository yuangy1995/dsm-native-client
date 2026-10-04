#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 聊天实际 Repository 的合成服务；不接触网络或真实会话。
actor MobileChatUITransport: DsmBinaryHTTPTransport {
    private let state: String
    private var edited = false
    private var replies: [[String: Any]] = []
    private var setCount = 0
    private var createCount = 0
    private var readFailures = false
    private var searchCalls: [(String, String?, String?)] = []

    init(state: String = "chat-content") { self.state = state; edited = state == "chat-edit-restored" }

    func setReadFailures(_ value: Bool) { readFailures = value }
    func writeCounts() -> (Int, Int) { (setCount, createCount) }
    func searches() -> [(String, String?, String?)] { searchCalls }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
        let api = field("api"), method = field("method")
        let result: [String: Any]
        switch (api, method) {
        case (DsmAPIName.chatPostFile, "thumbnail"):
            try await Task.sleep(for: .milliseconds(150))
            return DsmHTTPResponse(data: Self.png, statusCode: 200, headers: ["Content-Type": "image/png"])
        case (DsmAPIName.chatUser, "list"):
            result = ["users": [["user_id": 1, "username": "fixture", "nickname": "Sample author"],
                                ["user_id": 2, "username": "other", "nickname": "Sample member"]]]
        case (DsmAPIName.chatChannel, "list"):
            result = ["channels": [["channel_id": 27, "type": "named", "name": "Sample chat", "members": [1, 2], "encrypted": false],
                                   ["channel_id": 28, "type": "named", "name": "Another chat", "members": [1, 2], "encrypted": false]]]
        case (DsmAPIName.chatAdminSetting, "get"):
            result = ["allow_edit_message": state != "chat-readonly", "allow_edit_message_time_within_min": 0]
        case (DsmAPIName.chatPost, "search"):
            let query = field("keyword") ?? ""
            searchCalls.append((query, field("in"), field("offset")))
            if query == "slow" { try await Task.sleep(for: .milliseconds(150)) }
            if state == "chat-search-error" { throw URLError(.notConnectedToInternet) }
            if state == "chat-search-loading" { try await Task.sleep(for: .seconds(30)) }
            let offset = Int(field("offset") ?? "0") ?? 0
            let count = Int(field("limit") ?? "25") ?? 25
            let matches = query == "missing" ? [] : (0..<28).map { index in
                Self.post(id: String(9001 + index), text: index == 0 && edited ? "Edited sample" : "Sample message \(index + 1)")
            }
            result = ["search_results": Array(matches.dropFirst(offset).prefix(count)), "total": matches.count]
        case (DsmAPIName.chatPost, "list"):
            if readFailures || (state == "chat-edit-unknown" && edited) { throw URLError(.notConnectedToInternet) }
            let thread = field("thread_id") ?? "0"
            if let id = field("post_id"), field("prev_count") == "0" {
                if id == "9999" { result = ["posts": []] }
                else if let reply = replies.first(where: { $0["post_id"] as? String == id }) { result = ["posts": [reply]] }
                else { result = ["posts": [Self.post(id: id, text: id == "9001" && edited ? "Edited sample" : "Sample message \((Int(id) ?? 9001) - 9000)", thread: thread,
                    author: id == "9002" || id == "9100" ? 2 : 1, edited: id == "9001" && edited)]] }
            } else if thread != "0" {
                var earlier = state == "chat-thread-pages"
                    ? (0..<60).map { Self.post(id: String(9100 + $0), text: "Earlier reply \($0)", thread: thread, author: 2) }
                    : [Self.post(id: "9100", text: "Earlier reply", thread: thread, author: 2)]
                if state == "chat-thread-attachment" {
                    earlier[0]["files"] = [["file_id": "sample-image", "name": "sample.png", "content_type": "image/png", "size": Self.png.count]]
                }
                let values = earlier + replies
                let count = Int(field("prev_count") ?? "50") ?? 50
                if let cursor = field("post_id"), let index = values.firstIndex(where: { $0["post_id"] as? String == cursor }) {
                    result = ["posts": Array(values.prefix(index + 1).suffix(count + 1))]
                } else { result = ["posts": Array(values.suffix(count))] }
            } else {
                result = ["posts": [Self.post(id: "9001", text: edited ? "Edited sample" : "Sample message 1", edited: edited),
                                    Self.post(id: "9002", text: "Sample message 2", author: 2)]]
            }
        case (DsmAPIName.chatPost, "set"):
            setCount += 1
            if state == "chat-edit-denied" { return try response(["success": false, "error": ["code": 105]]) }
            if state == "chat-edit-slow" { try await Task.sleep(for: .milliseconds(150)) }
            guard field("post_id") == "9001", field("message") == "Edited sample" else { throw URLError(.badServerResponse) }
            edited = true; result = [:]
        case (DsmAPIName.chatPost, "create"):
            createCount += 1
            if state == "chat-reply-slow" { try await Task.sleep(for: .milliseconds(150)) }
            if state == "chat-reply-unknown" { throw URLError(.networkConnectionLost) }
            let id = String(9200 + createCount)
            replies.append(Self.post(id: id, text: field("message") ?? "", thread: field("thread_id") ?? "0"))
            result = ["post_id": id]
        default: throw URLError(.unsupportedURL)
        }
        return try response(["success": true, "data": result])
    }

    private func response(_ value: [String: Any]) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: value), statusCode: 200)
    }

    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try await Task.sleep(for: .milliseconds(150))
        try Self.png.write(to: destinationURL); progress(Int64(Self.png.count), Int64(Self.png.count))
        return DsmHTTPResponse(data: Data(), statusCode: 200, headers: ["Content-Type": "image/png", "Content-Length": String(Self.png.count)])
    }

    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        throw URLError(.unsupportedURL)
    }

    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    private static func post(id: String, text: String, thread: String = "0", author: Int = 1, edited: Bool = false) -> [String: Any] {
        ["post_id": id, "channel_id": 27, "creator_id": author, "create_at": 1_790_000_000_000 + (Int(id) ?? 0),
         "update_at": edited ? 1_790_000_999_000 : 0, "thread_id": thread, "type": "normal", "message": text]
    }
}
#endif
