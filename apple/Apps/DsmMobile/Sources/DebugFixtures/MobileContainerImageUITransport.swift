#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 下载测试仅使用合成原任务与映像清单，不访问真实仓库或 NAS。
actor MobileContainerImageUITransport: DsmHTTPTransport {
    private var mode: String
    private let fallback = MobileContainerUITransport()
    private var failedSearch = false
    private var failedTags = false
    private var statusCount = 0
    private var holding = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitingForWrite: CheckedContinuation<Void, Never>?
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { $0["method"] == "pull_start" } }
    init(mode: String = "containers-images") { self.mode = mode }
    func setMode(_ value: String) { mode = value }
    func holdWrites() { holding = true }
    func waitForWrite() async { if waiter == nil { await withCheckedContinuation { waitingForWrite = $0 } } }
    func release() { holding = false; waiter?.resume(); waiter = nil }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields)
        let api = fields["api"] ?? "", method = fields["method"] ?? ""
        if api == DsmAPIName.dockerRegistry {
            if method == "search" {
                if mode == "containers-images-loading" { try await Task.sleep(for: .seconds(30)) }
                if mode == "containers-images-search-error", !failedSearch { failedSearch = true; throw URLError(.notConnectedToInternet) }
                let empty = mode == "containers-images-empty" || fields["q"] == "no-match"
                return response(["data": empty ? [] : [["name": "sample/web", "registry": "docker.io", "is_official": true,
                    "description": "A sample image for isolated testing.", "star_count": 12]], "total": empty ? 0 : 1])
            }
            if method == "tags" {
                if mode == "containers-images-tags-error", !failedTags { failedTags = true; throw URLError(.notConnectedToInternet) }
                if mode == "containers-images-tags-denied" { return response(["code": 105], success: false) }
                return response(["tags": mode == "containers-images-no-tags" ? [] : ["latest", "stable", "v1"]])
            }
        }
        if api == DsmAPIName.dockerImage {
            if method == "pull_start" {
                if holding { await withCheckedContinuation { waiter = $0; waitingForWrite?.resume(); waitingForWrite = nil } }
                if mode == "containers-images-unknown" { throw URLError(.networkConnectionLost) }
                if mode == "containers-images-rejected" { return response(["code": 105], success: false) }
                return response(["task_id": "synthetic-image-task"])
            }
            if method == "pull_status" {
                statusCount += 1
                if mode == "containers-images-offline" { throw URLError(.notConnectedToInternet) }
                if mode == "containers-images-trust" { throw URLError(.serverCertificateUntrusted) }
                if mode == "containers-images-failed" { return response(["code": 1202], success: false) }
                if mode == "containers-images-status-denied" { return response(["code": 105], success: false) }
                let finished = mode == "containers-images-recovered" || (statusCount > 1 && mode != "containers-images-waiting")
                return response(["repository": mode == "containers-images-mismatch" ? "other/web" : "docker.io/sample/web",
                    "tag": writes.last?["tag"] ?? "stable", "finished": finished, "current": finished ? 100 : 25, "total": 100])
            }
            if method == "list" {
                return response(["images": [["id": "synthetic-image-id", "repository": "sample/web", "tags": ["latest", "stable", "v1"]]], "total": 1, "offset": 0])
            }
        }
        return try await fallback.send(request)
    }
    private func response(_ value: [String: Any], success: Bool = true) -> DsmHTTPResponse {
        .init(data: try! JSONSerialization.data(withJSONObject: ["success": success, success ? "data" : "error": value]),
              statusCode: 200, headers: [:])
    }
}
#endif
