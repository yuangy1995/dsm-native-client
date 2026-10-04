#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 投票合成服务覆盖当前请求契约、丢回执和重启；仅 Debug 注入，不连接 NAS。
actor MobileChatPollUITransport: DsmBinaryHTTPTransport {
    private let base = MobileChatUITransport()
    private let state: String
    private let afterCreate: (@Sendable () throws -> Void)?
    private var posts: [String: [String: Any]] = [:]
    private var selections: [String: Set<String>] = [:]
    private var createCount = 0
    private var voteCount = 0
    private var readCount = 0
    private var failReads = false
    private var missing = false

    init(state: String = "chat-poll-content", afterCreate: (@Sendable () throws -> Void)? = nil) {
        self.state = state; self.afterCreate = afterCreate
        posts["9300"] = Self.post(id: "9300", question: "Sample poll", texts: ["Tea", "Coffee"],
            multiple: state == "chat-poll-multiple", anonymous: state == "chat-poll-anonymous", closed: state == "chat-poll-closed")
        if state == "chat-poll-created" {
            posts["9400"] = Self.post(id: "9400", question: "Lunch?", texts: ["Pasta", "Soup"])
        }
    }

    func counts() -> (creates: Int, votes: Int, reads: Int) { (createCount, voteCount, readCount) }
    func setReadFailures(_ value: Bool) { failReads = value }
    func setMissing(_ value: Bool) { missing = value }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
        let api = field("api"), method = field("method")
        if api == DsmAPIName.chatChannel, method == "list", state == "chat-poll-encrypted" || state == "chat-poll-no-access" {
            return try response(["channels": state == "chat-poll-no-access" ? [] : [["channel_id": 27, "type": "named", "name": "Sample chat", "members": [1, 2], "encrypted": true]]])
        }
        if api == DsmAPIName.chatPostVote, method == "create" {
            createCount += 1
            if state == "chat-poll-create-denied" { return try failure(105) }
            if state == "chat-poll-create-slow" { try await Task.sleep(for: .milliseconds(150)) }
            guard field("channel_id") == "27", let question = field("message"),
                  let data = field("choices")?.data(using: .utf8),
                  let choices = try JSONSerialization.jsonObject(with: data) as? [[String: String]],
                  let optionsData = field("options")?.data(using: .utf8),
                  let options = try JSONSerialization.jsonObject(with: optionsData) as? [String: Any],
                  options["expire_at"] as? Int == 0, options["add_option"] as? Bool == false else { throw URLError(.badServerResponse) }
            posts["9400"] = Self.post(id: "9400", question: question, texts: choices.compactMap { $0["text"] },
                multiple: options["multiple"] as? Bool == true, anonymous: options["anonymous"] as? Bool == true,
                author: state == "chat-poll-wrong-author" ? 2 : 1)
            if state == "chat-poll-create-unknown" { throw URLError(.networkConnectionLost) }
            if state == "chat-poll-create-read-failure" { failReads = true }
            try afterCreate?()
            return try response(["post_id": "9400"])
        }
        if api == DsmAPIName.chatPostVote, method == "vote" {
            voteCount += 1
            if state == "chat-poll-vote-denied" { return try failure(105) }
            if state == "chat-poll-vote-slow" { try await Task.sleep(for: .milliseconds(150)) }
            guard let id = field("post_id"), let data = field("choice_ids")?.data(using: .utf8),
                  let ids = try JSONSerialization.jsonObject(with: data) as? [String] else { throw URLError(.badServerResponse) }
            selections[id] = Set(ids)
            if state == "chat-poll-vote-unknown" && voteCount == 1 { failReads = true; throw URLError(.networkConnectionLost) }
            return try response([:])
        }
        if api == DsmAPIName.chatPostVote, method == "get_choices" {
            readCount += 1
            if failReads || state == "chat-poll-load-error" { throw URLError(.notConnectedToInternet) }
            if state == "chat-poll-loading" { try await Task.sleep(for: .seconds(30)) }
            guard let id = field("post_id"), let post = posts[id], let props = post["props"] as? [String: Any],
                  let poll = props["vote"] as? [String: Any], let choices = poll["choices"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
            let rows = choices.map { option -> [String: Any] in
                var value = option
                let selected = selections[id]?.contains(option["id"] as? String ?? "") == true
                value["count"] = selected ? 1 : 0; value["voters"] = selected ? [1] : []
                return value
            }
            return try response(["choices": state == "chat-poll-malformed" ? rows + rows : rows])
        }
        if api == DsmAPIName.chatPost, method == "list" {
            readCount += 1
            if failReads { throw URLError(.notConnectedToInternet) }
            if missing || (state == "chat-poll-missing" && field("prev_count") == "0") { return try response(["posts": []]) }
            if let id = field("post_id"), field("prev_count") == "0", let post = posts[id] { return try response(["posts": [post]]) }
            if field("post_id") == nil { return try response(["posts": posts.keys.sorted().compactMap { posts[$0] }]) }
        }
        return try await base.send(request)
    }

    private func response(_ data: [String: Any]) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
    private func failure(_ code: Int) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": false, "error": ["code": code]]), statusCode: 200)
    }
    private static func post(id: String, question: String, texts: [String], multiple: Bool = false,
                             anonymous: Bool = false, closed: Bool = false, author: Int = 1) -> [String: Any] {
        ["post_id": id, "channel_id": 27, "creator_id": author, "create_at": 1_790_000_000_000 + (Int(id) ?? 0),
         "thread_id": "0", "type": "vote", "message": question,
         "props": ["vote": ["state": closed ? "close" : "open", "options": ["multiple": multiple, "anonymous": anonymous, "expire_at": 0],
                            "choices": texts.enumerated().map { ["id": "choice-\($0.offset)", "text": $0.element, "count": 0, "voters": []] as [String: Any] }]]]
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try await base.download(request, to: destinationURL, progress: progress)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
}
#endif
