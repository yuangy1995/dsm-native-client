#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 网络操作仅修改合成清单，不访问或改变真实 NAS。
actor MobileContainerNetworkUITransport: DsmHTTPTransport {
    private var mode: String
    private var networks: [[String: Any]]
    private var reads = 0
    private var failedRead = false
    private var holding = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitingForWrite: CheckedContinuation<Void, Never>?
    private let fallback = MobileContainerUITransport()
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { $0["api"] == DsmAPIName.dockerNetwork && ["create", "remove"].contains($0["method"] ?? "") } }
    init(mode: String = "containers-networks") {
        self.mode = mode
        networks = [Self.network("default", "bridge"), Self.network("used", "in-use", containers: ["Sample container"]),
                    Self.network("a", "sample-a"), Self.network("b", "sample-b")]
        if mode == "containers-networks-empty" { networks = [] }
        if mode == "containers-networks-recovered" { networks.removeAll { $0["id"] as? String == "a" } }
        if mode == "containers-networks-created" { networks.append(Self.network("created", "sample-new")) }
    }
    func setMode(_ value: String) { mode = value }
    func remove(_ id: String) { networks.removeAll { $0["id"] as? String == id } }
    func replace(_ id: String) { for i in networks.indices where networks[i]["id"] as? String == id { networks[i]["id"] = "replacement" } }
    func rename(_ id: String) { for i in networks.indices where networks[i]["id"] as? String == id { networks[i]["name"] = "sample-renamed" } }
    func add(_ name: String) { networks.append(Self.network("added", name)) }
    func holdWrites() { holding = true }
    func waitForWrite() async { if waiter == nil { await withCheckedContinuation { waitingForWrite = $0 } } }
    func release() { holding = false; waiter?.resume(); waiter = nil }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields)
        if fields["api"] == DsmAPIName.dockerNetwork {
            let method = fields["method"] ?? ""
            if method == "list" {
                reads += 1
                if mode == "containers-networks-loading", reads > 1 { try await Task.sleep(for: .seconds(30)) }
                if mode == "containers-networks-read-error", reads > 1, !failedRead { failedRead = true; throw URLError(.notConnectedToInternet) }
                if mode == "containers-networks-offline", !writes.isEmpty { throw URLError(.notConnectedToInternet) }
                return response(["network": networks, "total": networks.count, "offset": 0])
            }
            if ["create", "remove"].contains(method) {
                if holding { await withCheckedContinuation { waiter = $0; waitingForWrite?.resume(); waitingForWrite = nil } }
                if mode == "containers-networks-denied" { return response(["code": 105], success: false) }
                if mode == "containers-networks-trust" { throw URLError(.serverCertificateUntrusted) }
                if mode == "containers-networks-unknown" { throw URLError(.networkConnectionLost) }
                if method == "create" {
                    var value = Self.network("created", fields["name"] ?? "")
                    value["enable_ipv6"] = fields["enable_ipv6"] == "true"
                    for key in ["subnet", "gateway", "iprange"] { if let text = fields[key] { value[key] = text } }
                    networks.append(value)
                    return response([:])
                }
                if mode == "containers-networks-partial", writes.count > 1 { return response(["code": 105], success: false) }
                let values = (try? JSONSerialization.jsonObject(with: Data((fields["networks"] ?? "[]").utf8))) as? [[String: Any]] ?? []
                let ids = values.compactMap { $0["id"] as? String }
                networks.removeAll { ids.contains($0["id"] as? String ?? "") }
                return response(["failed": []])
            }
        }
        return try await fallback.send(request)
    }
    private static func network(_ id: String, _ name: String, containers: [String] = []) -> [String: Any] {
        ["id": id, "name": name, "driver": "bridge", "containers": containers, "enable_ipv6": false,
         "subnet": "192.0.2.0/24", "gateway": "192.0.2.1", "iprange": ""]
    }
    private func response(_ value: [String: Any], success: Bool = true) -> DsmHTTPResponse {
        .init(data: try! JSONSerialization.data(withJSONObject: ["success": success, success ? "data" : "error": value]), statusCode: 200)
    }
}
#endif
