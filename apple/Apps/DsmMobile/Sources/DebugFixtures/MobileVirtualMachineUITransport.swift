#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 虚拟机界面与真实适配器共用的隔离合成环境，不连接 NAS。
actor MobileVirtualMachineUITransport: DsmHTTPTransport {
    private var mode: String
    private var machines: [[String: Any]]
    private var failedRead = false
    private var shouldHold = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitingForWrite: CheckedContinuation<Void, Never>?
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { ["poweron", "shutdown", "poweroff", "pwr_ctl", "delete", "set"].contains($0["method"] ?? "") } }
    init(mode: String = "vmm-control") {
        self.mode = mode
        let running = mode.contains("running") || mode == "vmm-recover" || mode == "vmm-restart"
        machines = [Self.machine(id: "synthetic-vm", name: "Sample virtual machine", running: running),
                    Self.machine(id: "worker-b", name: "Worker B", running: running)]
        if mode == "vmm-delete-recovered" || mode == "vmm-empty" { machines = [] }
        if mode == "vmm-missing-state" { machines[0]["status"] = nil }
        if mode == "vmm-transition" { machines[0]["status"] = "stopping" }
        if mode == "vmm-settings-recovered" { machines[0]["desc"] = "Updated synthetic description" }
    }
    private static func machine(id: String, name: String, running: Bool) -> [String: Any] {
        ["guest_id": id, "name": name, "status": running ? "running" : "shutdown",
         "autorun": 0, "vcpu_num": 1, "vram_size": 512, "desc": "Synthetic description", "cpu_weight": 256]
    }
    func setMode(_ value: String) { mode = value }
    func setSettings(_ values: [String: String]) {
        for (key, value) in values {
            if ["vcpu_num", "vram_size", "cpu_weight", "autorun"].contains(key) { machines[0][key] = Int(value) }
            else { machines[0][key] = value }
        }
    }
    func renameFirst() { machines[0]["name"] = "Changed virtual machine" }
    func replaceFirst() { machines[0]["guest_id"] = "replacement-vm" }
    func removeFirst() { if !machines.isEmpty { machines.removeFirst() } }
    func holdWrites() { shouldHold = true }
    func waitForWrite() async { if waiter == nil { await withCheckedContinuation { waitingForWrite = $0 } } }
    func release() { shouldHold = false; waiter?.resume(); waiter = nil }
    func apply(_ action: VirtualMachinePowerAction, index: Int = 0) {
        guard machines.indices.contains(index), action != .restart else { return }
        machines[index]["status"] = action == .powerOn ? "running" : "shutdown"
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { item in
            let value = item.value ?? ""
            return (item.name, (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value)
        })
        calls.append(fields)
        let api = fields["api"] ?? "", method = fields["method"] ?? ""
        if ["poweron", "shutdown", "poweroff", "pwr_ctl", "delete", "set"].contains(method) {
            if shouldHold { await withCheckedContinuation { waiter = $0; waitingForWrite?.resume(); waitingForWrite = nil } }
            if mode == "vmm-reject" { return response(["code": 105], success: false) }
            if mode == "vmm-write-trust" { throw URLError(.serverCertificateUntrusted) }
            if mode == "vmm-unknown" || mode == "vmm-settings-unknown" || (mode == "vmm-partial" && writes.count == 2) { throw URLError(.networkConnectionLost) }
            guard let index = machines.firstIndex(where: { $0["guest_id"] as? String == fields["guest_id"] }) else {
                return response(["code": 408], success: false)
            }
            if method == "set" {
                for key in ["name", "desc"] where fields[key] != nil { machines[index][key] = fields[key] }
                for key in ["vcpu_num", "vram_size", "cpu_weight", "autorun"] where fields[key] != nil { machines[index][key] = Int(fields[key]!) }
            } else if method == "delete" { machines.remove(at: index) }
            else {
                let command = method == "pwr_ctl" ? fields["action"] : method
                if command == "poweron" { apply(.powerOn, index: index) }
                if command == "shutdown" || command == "poweroff" { apply(.shutdown, index: index) }
            }
            return response([:])
        }
        if mode == "vmm-loading" { try await Task.sleep(for: .seconds(30)) }
        if method == "get", mode == "vmm-settings-loading" { try await Task.sleep(for: .seconds(30)) }
        if method == "get", mode == "vmm-settings-error" { throw URLError(.notConnectedToInternet) }
        if mode == "vmm-read-trust" { throw URLError(.serverCertificateUntrusted) }
        if mode == "vmm-retry", !failedRead { failedRead = true; throw URLError(.notConnectedToInternet) }
        if (mode == "vmm-accepted-offline" || mode == "vmm-settings-accepted-offline"), !writes.isEmpty { throw URLError(.notConnectedToInternet) }
        guard api == DsmAPIName.virtualizationAPIGuest || api == DsmAPIName.virtualizationGuest else {
            return response(["code": 102], success: false)
        }
        let values: [[String: Any]] = machines.map { item in
            var item = item
            if api == DsmAPIName.virtualizationAPIGuest { item["guest_name"] = item.removeValue(forKey: "name") }
            else { item["vram_size"] = (item["vram_size"] as? Int).map { $0 * 1024 } }
            return item
        }
        if method == "get" {
            guard let item = values.first(where: { $0["guest_id"] as? String == fields["guest_id"] }) else {
                return response(["code": 408], success: false)
            }
            return response(item)
        }
        if mode == "vmm-incomplete" { return response(["guests": [], "total": 2]) }
        return response(["guests": values, "total": values.count, "offset": 0])
    }
    private func response(_ value: [String: Any], success: Bool = true) -> DsmHTTPResponse {
        .init(data: try! JSONSerialization.data(withJSONObject: ["success": success, success ? "data" : "error": value]),
              statusCode: 200, headers: [:])
    }
}
#endif
