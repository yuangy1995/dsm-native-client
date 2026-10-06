#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 容器界面与真实适配器共用的隔离合成环境，不连接 NAS。
actor MobileContainerUITransport: DsmHTTPTransport {
    private var mode: String
    private var containers: [[String: Any]]
    private var failedRead = false
    private var shouldHold = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitingForWrite: CheckedContinuation<Void, Never>?
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { ["start", "stop", "restart", "delete"].contains($0["method"] ?? "") } }
    init(mode: String = "containers-control") {
        self.mode = mode
        let running = ["containers-running", "containers-recover", "containers-restarting"].contains(mode)
        containers = [Self.container(id: "synthetic-id", name: "Sample container", running: running),
                      Self.container(id: "worker-b", name: "Worker B", running: running),
                      Self.container(id: "managed-id", name: "Package service", running: true, managed: true)]
        if mode == "containers-delete-recovered" { containers.removeFirst(2) }
        if mode == "containers-empty" { containers = [] }
        if mode == "containers-restarting" { Self.setInitialState(&containers, key: "Restarting", value: true) }
        if mode == "containers-missing-state" { Self.setInitialState(&containers, key: "Running", value: nil) }
    }
    private static func setInitialState(_ containers: inout [[String: Any]], key: String, value: Any?) {
        guard !containers.isEmpty, var state = containers[0]["State"] as? [String: Any] else { return }
        state[key] = value; containers[0]["State"] = state
    }
    private static func container(id: String, name: String, running: Bool, managed: Bool = false) -> [String: Any] {
        ["id": id, "name": name, "image": "sample:latest", "status": running ? "running" : "stopped",
         "is_package": managed, "Labels": [:], "State": ["Running": running, "Paused": false,
            "Restarting": false, "StartedAt": "2026-01-01T00:00:00Z"], "cpu_usage": 1.5, "memory_usage": 1048576]
    }
    func setMode(_ value: String) { mode = value }
    func renameFirst() { containers[0]["name"] = "Changed container" }
    func replaceFirst() { containers[0]["id"] = "replacement-id" }
    func removeFirst() { if !containers.isEmpty { containers.removeFirst() } }
    func holdWrites() { shouldHold = true }
    func waitForWrite() async { if waiter == nil { await withCheckedContinuation { waitingForWrite = $0 } } }
    func release() { shouldHold = false; waiter?.resume(); waiter = nil }
    func apply(_ action: ContainerAction, index: Int = 0) {
        guard containers.indices.contains(index) else { return }
        var state = containers[index]["State"] as? [String: Any] ?? [:]
        state["Running"] = action != .stop; state["Restarting"] = false
        if action != .stop { state["StartedAt"] = "2026-01-01T01:00:00Z" }
        containers[index]["State"] = state; containers[index]["status"] = action == .stop ? "stopped" : "running"
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields)
        let api = fields["api"] ?? "", method = fields["method"] ?? ""
        if ContainerAction(rawValue: method) != nil || method == "delete" {
            if shouldHold {
                await withCheckedContinuation { waiter = $0; waitingForWrite?.resume(); waitingForWrite = nil }
            }
            if mode == "containers-reject" { return response(["code": 105], success: false) }
            if mode == "containers-write-trust" { throw URLError(.serverCertificateUntrusted) }
            if mode == "containers-unknown" || (mode == "containers-partial" && writes.count == 2) { throw URLError(.networkConnectionLost) }
            guard let index = containers.firstIndex(where: { $0["name"] as? String == fields["name"] }) else { return response(["code": 408], success: false) }
            if method == "delete" {
                containers.remove(at: index)
            } else if let action = ContainerAction(rawValue: method), mode != "containers-restart-unchanged" {
                apply(action, index: index)
            }
            return response([:])
        }
        if mode == "containers-loading" { try await Task.sleep(for: .seconds(30)) }
        if mode == "containers-read-trust" { throw URLError(.serverCertificateUntrusted) }
        if mode == "containers-retry", api == DsmAPIName.dockerContainer, !failedRead {
            failedRead = true; throw URLError(.notConnectedToInternet)
        }
        if mode == "containers-accepted-offline", !writes.isEmpty { throw URLError(.notConnectedToInternet) }
        switch api {
        case DsmAPIName.dockerContainer:
            if mode == "containers-incomplete" { return response(["containers": [], "total": 2]) }
            return response(["containers": containers])
        case DsmAPIName.dockerImage: return response(["images": [], "total": 0, "offset": 0])
        case DsmAPIName.dockerNetwork: return response(["networks": []])
        case DsmAPIName.dockerProject: return response([:])
        case DsmAPIName.dockerLog:
            return response(["logs": [["id": "event-1", "time": "2026/10/06 12:00:00", "level": "info",
                "user": "Sample user", "event": "Sample container was started."]], "total": 1, "offset": 0])
        default: return response(["code": 102], success: false)
        }
    }
    private func response(_ value: [String: Any], success: Bool = true) -> DsmHTTPResponse {
        .init(data: try! JSONSerialization.data(withJSONObject: ["success": success, success ? "data" : "error": value]),
              statusCode: 200, headers: [:])
    }
}
#endif
