#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 置顶和关闭会话的隔离合成服务，重启快照仅含本文件内测试数据。
actor MobileChatManagementUITransport: DsmBinaryHTTPTransport {
    private struct Snapshot: Codable { var pinned: [String: Int64]; var closed: Set<String> }
    private let base = MobileChatUITransport()
    private let state: String
    private let snapshotURL: URL?
    private var snapshot: Snapshot
    private var writes: [(String, String, String)] = []
    private var reads = 0
    private var failReads = false
    private var changed = false
    private var encrypted = false
    private var missing = false
    private var direct = false
    private var duplicate = false
    private var encryptedMessages = false
    private var pinCount = 1

    init(state: String = "chat-management-content", root: URL? = nil) {
        self.state = state; snapshotURL = root?.appendingPathComponent("management-fixture.json")
        if state == "chat-management-restored", let snapshotURL, let data = try? Data(contentsOf: snapshotURL),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) { snapshot = saved }
        else { snapshot = Snapshot(pinned: state == "chat-management-empty" ? [:] : ["9002": 1_790_000_100_000], closed: []) }
    }
    func counts() -> (writes: [(String, String, String)], reads: Int) { (writes, reads) }
    func setReadFailures(_ value: Bool) { failReads = value }
    func changeContent() { changed = true }
    func changePinTime() { snapshot.pinned["9002"] = 1_790_000_200_000 }
    func pinElsewhere(_ id: String) { snapshot.pinned[id] = 1_790_000_200_000 }
    func setAccess(encrypted: Bool = false, missing: Bool = false, direct: Bool = false) { self.encrypted = encrypted; self.missing = missing; self.direct = direct }
    func setEncryptedMessages() { encryptedMessages = true }
    func setDuplicate(_ value: Bool) { duplicate = value }
    func manyPins() { pinCount = 112; snapshot.pinned = Dictionary(uniqueKeysWithValues: (9001...9112).map { (String($0), Int64(1_790_000_100_000 + $0)) }) }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
        let api = field("api"), method = field("method")
        let pinSearch = api == DsmAPIName.chatPost && method == "search" && field("has") != nil
        if (api == DsmAPIName.chatChannel && method == "close") || (api == DsmAPIName.chatPost && ["pin", "unpin"].contains(method ?? "")) {
            let id = field("post_id") ?? field("channel_id") ?? ""
            writes.append((method ?? "", id, field("version") ?? ""))
            if state == "chat-management-denied" { return try response(["success": false, "error": ["code": 105]], envelope: false) }
            if state == "chat-management-slow" { try await Task.sleep(for: .milliseconds(150)) }
            if method == "pin" { snapshot.pinned[id] = 1_790_000_300_000 }
            else if method == "unpin" { snapshot.pinned[id] = nil }
            else { snapshot.closed.insert(id) }
            if let snapshotURL {
                try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
            }
            if state == "chat-management-unknown" { failReads = true; throw URLError(.networkConnectionLost) }
            if state == "chat-management-read-failure" { failReads = true }
            return try response([:])
        }
        if api == DsmAPIName.chatChannel && method == "list" {
            reads += 1
            if failReads { throw URLError(.notConnectedToInternet) }
            let values: [[String: Any]] = (27...28).filter { !snapshot.closed.contains(String($0)) && !missing }.map {
                ["channel_id": $0, "type": direct ? "anonymous" : "named", "name": $0 == 27 ? "Sample chat" : "Another chat",
                 "members": [1, 2], "encrypted": encrypted]
            }
            return try response(["channels": duplicate ? values + values : values])
        }
        if pinSearch || (api == DsmAPIName.chatPost && method == "list") {
            reads += 1
            if failReads || (pinSearch && state == "chat-management-error") { throw URLError(.notConnectedToInternet) }
            if pinSearch && state == "chat-management-loading" { try await Task.sleep(for: .seconds(30)) }
            let values = (9001...(pinCount > 1 ? 9112 : 9002)).map { post(String($0)) }
            if pinSearch {
                let pins = values.filter { snapshot.pinned[$0["post_id"] as? String ?? ""] != nil }
                let offset = Int(field("offset") ?? "0") ?? 0
                let selected = Array(pins.dropFirst(offset).prefix(100))
                return try response(["search_results": duplicate ? selected + selected : selected, "total": pins.count])
            }
            if field("prev_count") == "0", let id = field("post_id") { return try response(["posts": values.filter { $0["post_id"] as? String == id }]) }
            return try response(["posts": values])
        }
        if api == DsmAPIName.chatPost, ["create", "set", "delete"].contains(method ?? "") {
            writes.append((method ?? "", field("post_id") ?? field("channel_id") ?? "", field("version") ?? ""))
        }
        return try await base.send(request)
    }
    private func post(_ id: String) -> [String: Any] {
        var value: [String: Any] = ["post_id": id, "channel_id": 27, "creator_id": id == "9001" ? 1 : 2,
            "create_at": 1_790_000_000_000 + (Int(id) ?? 0), "thread_id": "0", "type": "normal",
            "message": changed ? "Changed elsewhere" : "Sample message \((Int(id) ?? 9001) - 9000)"]
        if encryptedMessages { value["encrypted"] = true }
        if let time = snapshot.pinned[id] { value["last_pin_at"] = time }
        if id == "9002" || id == "9100" {
            value["files"] = [["file_id": "sample-image", "name": "sample.png", "content_type": "image/png", "size": 68]]
        }
        if id == "9003" {
            value["props"] = ["vote": ["state": "open", "options": ["multiple": false, "anonymous": false, "expire_at": 0],
                "choices": [["id": "choice-0", "text": "Alpha", "count": 0], ["id": "choice-1", "text": "Beta", "count": 0]]]]
        }
        return value
    }
    private func response(_ value: [String: Any], envelope: Bool = true) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: envelope ? ["success": true, "data": value] : value), statusCode: 200)
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try await base.download(request, to: destinationURL, progress: progress)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
}
#endif
