#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 删除仅修改合成映像数组；图片、容器和响应均不来自真实 NAS。
actor MobileContainerImageDeletionUITransport: DsmHTTPTransport {
    private var mode: String
    private var images: [[String: Any]]
    private var imageReads = 0
    private var failedRead = false
    private var holding = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitingForWrite: CheckedContinuation<Void, Never>?
    private let fallback = MobileContainerImageUITransport()
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { $0["api"] == DsmAPIName.dockerImage && $0["method"] == "delete" } }
    init(mode: String = "containers-image-delete") {
        self.mode = mode
        images = [["id": "synthetic-web-image", "repository": "sample/web", "tags": ["latest", "stable", "v1"]],
                  ["id": "synthetic-bare-image", "repository": "sample/cache", "tags": ["<none>"]],
                  ["id": "synthetic-used-image", "repository": "sample/used", "tags": ["latest"]]]
        if mode == "containers-image-delete-empty" { images = [] }
        if mode == "containers-image-delete-recovered" { images[0]["tags"] = ["latest"] }
        if mode == "containers-image-delete-bare-alias" { images[1]["tags"] = ["<none>", "stable"] }
    }
    func setMode(_ value: String) { mode = value }
    func removeWebTags() { if !images.isEmpty { images[0]["tags"] = ["latest"] } }
    func replaceWebImage() { if !images.isEmpty { images[0]["id"] = "replacement-web-image" } }
    func holdWrites() { holding = true }
    func waitForWrite() async { if waiter == nil { await withCheckedContinuation { waitingForWrite = $0 } } }
    func release() { holding = false; waiter?.resume(); waiter = nil }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields)
        let api = fields["api"] ?? "", method = fields["method"] ?? ""
        if api == DsmAPIName.dockerImage {
            if method == "list" {
                imageReads += 1
                if mode == "containers-image-delete-loading", imageReads > 1 { try await Task.sleep(for: .seconds(30)) }
                if mode == "containers-image-delete-read-error", imageReads > 1, !failedRead {
                    failedRead = true; throw URLError(.notConnectedToInternet)
                }
                if mode == "containers-image-delete-offline", !writes.isEmpty { throw URLError(.notConnectedToInternet) }
                return response(["images": images, "total": images.count, "offset": 0])
            }
            if method == "delete" {
                if holding { await withCheckedContinuation { waiter = $0; waitingForWrite?.resume(); waitingForWrite = nil } }
                if mode == "containers-image-delete-denied" { return response(["code": 105], success: false) }
                if mode == "containers-image-delete-trust" { throw URLError(.serverCertificateUntrusted) }
                if mode == "containers-image-delete-unknown" { throw URLError(.networkConnectionLost) }
                let values = (try? JSONSerialization.jsonObject(with: Data((fields["images"] ?? "[]").utf8))) as? [[String: Any]] ?? []
                var removedOne = false
                for value in values {
                    if let identity = value["identity"] as? String { images.removeAll { $0["id"] as? String == identity }; continue }
                    guard let repository = value["repository"] as? String, let tags = value["tags"] as? [String] else { continue }
                    for index in images.indices where images[index]["repository"] as? String == repository {
                        let current = images[index]["tags"] as? [String] ?? []
                        images[index]["tags"] = current.filter { tag in
                            guard tags.contains(tag) else { return true }
                            if mode == "containers-image-delete-partial", removedOne { return true }
                            removedOne = true; return false
                        }
                    }
                    images.removeAll { ($0["tags"] as? [String])?.isEmpty == true }
                }
                return response([:])
            }
        }
        if api == DsmAPIName.dockerContainer, method == "list" {
            let rows: [[String: Any]] = mode == "containers-image-delete-empty" ? [] : [
                ["id": "synthetic-container", "name": "Sample container", "image": "sample/used:latest", "status": "stopped",
                 "is_package": false, "Labels": [:], "State": ["Running": false, "Paused": false,
                    "Restarting": false, "StartedAt": "2026-01-01T00:00:00Z"]]
            ]
            return response(["containers": rows, "total": rows.count, "offset": 0])
        }
        return try await fallback.send(request)
    }
    private func response(_ value: [String: Any], success: Bool = true) -> DsmHTTPResponse {
        .init(data: try! JSONSerialization.data(withJSONObject: ["success": success, success ? "data" : "error": value]), statusCode: 200)
    }
}
#endif
