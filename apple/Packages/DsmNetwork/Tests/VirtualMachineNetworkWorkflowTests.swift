import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class VirtualMachineNetworkWorkflowTests: XCTestCase, @unchecked Sendable {
    func repository(_ transport: NetworkWorkflowTransport) throws -> DsmServiceManagementRepository {
        let names = [DsmAPIName.virtualizationNetwork, DsmAPIName.virtualizationGuest, DsmAPIName.virtualizationGuestAction,
                     DsmAPIName.virtualizationRepo, DsmAPIName.virtualizationCluster]
        return try DsmServiceManagementRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
                ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .json, selectedVersion: 2))
            })), session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    func test外部网络仅改名保持空增量数组及固定版本() async throws {
        let transport = NetworkWorkflowTransport(), repository = try repository(transport)
        try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed"))
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["interfaces_add"], "[]")
        XCTAssertEqual(writes.first?["interfaces_remove"], "[]")
        XCTAssertNil(writes.first?["vlan_id"])
        XCTAssertEqual(writes.first?["version"], "1")
    }
    func test私有网络仅改名保留原主机() async throws {
        let transport = NetworkWorkflowTransport(mode: .privateNetwork), repository = try repository(transport)
        try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed"))
        let writes = await transport.writes
        XCTAssertEqual(writes.first?["host_id"], #""host-1""#)
        XCTAssertNil(writes.first?["interfaces_add"])
    }
    func test冻结网络不能发送改名() async throws {
        let transport = NetworkWorkflowTransport(mode: .frozen), repository = try repository(transport)
        do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed")); XCTFail("冻结期间不能修改") }
        catch is AppError {}
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }
    func test改名丢回执不能认领外部变化或重复发送() async throws {
        let transport = NetworkWorkflowTransport(mode: .lostReceipt), repository = try repository(transport)
        for _ in 0..<2 {
            do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed")); XCTFail("不能按名称认领缺失回执的操作") }
            catch is AppError {}
        }
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1)
    }
    func test删除丢回执但列表消失仍保持未知() async throws {
        let transport = NetworkWorkflowTransport(mode: .lostReceipt), repository = try repository(transport)
        let result = try await repository.deleteVirtualMachineNetworksResult(ids: ["network-1"])
        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertEqual(result.counts.unknown, 1)
    }
    func test缺失或错误类型与不完整清单均停止写入() async throws {
        for mode in [NetworkWorkflowTransport.Mode.missingFreeze, .stringGuestCount, .duplicateID, .duplicateName,
                     .wrongDetail, .missingGuests, .wrongGuestType, .wrongGuestCount, .missingInterface, .partialList] {
            let transport = NetworkWorkflowTransport(mode: mode, withGuest: true), repository = try repository(transport)
            do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed")); XCTFail("不能使用不完整原始字段：\(mode)") }
            catch is AppError {}
            let writes = await transport.writes
            XCTAssertTrue(writes.isEmpty, "\(mode)")
        }
    }
    func test详情读取固定V2且JSON编码单个ID() async throws {
        let transport = NetworkWorkflowTransport(withGuest: true), repository = try repository(transport)
        let inventory = try await repository.loadVirtualMachineNetworks()
        XCTAssertFalse(inventory.isFrozen)
        XCTAssertEqual(inventory.networks.first?.guests.first?.id, "vm-1")
        let requests = await transport.recordedRequests()
        let wire = requests.map { URLComponents(string: "https://example.invalid/?" + String(decoding: $0.httpBody ?? Data(), as: UTF8.self))?.queryItems ?? [] }
        XCTAssertEqual(wire.count, 2)
        XCTAssertTrue(wire.allSatisfy { fields in fields.contains { $0.name == "version" && $0.value == "2" } })
        XCTAssertTrue(wire[1].contains { $0.name == "network_id" && $0.value == #""network-1""# })
    }
    func test确认后关联虚拟机变化零写() async throws {
        let transport = NetworkWorkflowTransport(withGuest: true), repository = try repository(transport)
        let inventory = try await repository.loadVirtualMachineNetworks()
        let target = try XCTUnwrap(inventory.networks.first)
        await transport.setRunning(true)
        do { try await repository.deleteVirtualMachineNetwork(target) { _ in }; XCTFail("旧确认不能删除关联状态变化的网络") }
        catch is AppError {}
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }
    func test名称长度边界及重名均在提交前拒绝() async throws {
        for name in ["", " New", "New ", String(repeating: "a", count: 128), "Network 2"] {
            let transport = NetworkWorkflowTransport(count: 2), repository = try repository(transport)
            do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: name)); XCTFail("非法或重名不能提交") }
            catch is AppError {}
            let writes = await transport.writes
            XCTAssertTrue(writes.isEmpty)
        }
        let transport = NetworkWorkflowTransport(), repository = try repository(transport)
        try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: String(repeating: "a", count: 127)))
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1)
    }
    func test回读拓扑变化不报成功且原回执恢复不重发() async throws {
        let transport = NetworkWorkflowTransport(mode: .topologyAfterWrite), repository = try repository(transport)
        do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed")); XCTFail("同名但拓扑变化不能确认") }
        catch is AppError {}
        await transport.setMode(.success)
        try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed"))
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1)
    }
    func test接受后读取失败由刷新解除保护且不重复原操作() async throws {
        let transport = NetworkWorkflowTransport(mode: .postReadFailure), repository = try repository(transport)
        do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed")); XCTFail("结果不可读仍为未完成") }
        catch is AppError {}
        await transport.setMode(.success)
        let inventory = try await repository.loadVirtualMachineNetworks()
        let target = try XCTUnwrap(inventory.networks.first)
        try await repository.updateVirtualMachineNetwork(target, configuration: .init(name: "Next")) { _ in }
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 2)
    }
    func test批量删除第二项未知停止第三项并保留第一项完成() async throws {
        let transport = NetworkWorkflowTransport(mode: .lostSecond, count: 3), repository = try repository(transport)
        let result = try await repository.deleteVirtualMachineNetworksResult(ids: ["network-1", "network-2", "network-3"])
        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertEqual(result.counts.succeeded, 1); XCTAssertEqual(result.counts.unknown, 1); XCTAssertEqual(result.counts.failed, 1)
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertFalse(writes.contains { $0["network_id"] == #""network-3""# })
    }
    func test明确权限拒绝不由列表消失覆盖() async throws {
        let transport = NetworkWorkflowTransport(mode: .rejectedExternalChange), repository = try repository(transport)
        let result = try await repository.deleteVirtualMachineNetworksResult(ids: ["network-1"])
        XCTAssertEqual(result.status, .permissionDenied); XCTAssertEqual(result.counts.failed, 1)
        XCTAssertEqual(result.counts.unknown, 0)
    }
    func testHTTP登录失效停止后续读取() async throws {
        let transport = NetworkWorkflowTransport(mode: .httpUnauthorized), repository = try repository(transport)
        do { _ = try await repository.deleteVirtualMachineNetworksResult(ids: ["network-1"]); XCTFail("登录失效应交回恢复登录") }
        catch let error as AppError { XCTAssertEqual(error.category, .authenticationRequired) }
        let requests = await transport.recordedRequests()
        let last = String(decoding: requests.last?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(last.contains("method=delete"))
    }
    func test写前记录失败零写接受记录失败仅恢复原结果() async throws {
        for failure in [VirtualMachineControlStage.willSubmit, .accepted] {
            let transport = NetworkWorkflowTransport(), repository = try repository(transport)
            let inventory = try await repository.loadVirtualMachineNetworks(), target = try XCTUnwrap(inventory.networks.first)
            do {
                try await repository.updateVirtualMachineNetwork(target, configuration: .init(name: "Renamed")) { stage in
                    if stage == failure { throw NetworkTestFailure.storage }
                }
                XCTFail("持久记录失败必须停止当前调用")
            } catch NetworkTestFailure.storage {}
            if failure == .accepted { try await repository.updateVirtualMachineNetwork(id: target.id, configuration: .init(name: "Renamed")) }
            let writes = await transport.writes
            XCTAssertEqual(writes.count, failure == .willSubmit ? 0 : 1)
        }
    }
    func test未完成网络操作保护关联虚拟机与创建资源() async throws {
        let transport = NetworkWorkflowTransport(mode: .lostReceipt, withGuest: true), repository = try repository(transport)
        do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed")); XCTFail("回执缺失") }
        catch is AppError {}
        do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn); XCTFail("关联 VM 不能同时开机") } catch is AppError {}
        do { try await repository.updateVirtualMachine(id: "vm-1", configuration: .init(name: "Next")); XCTFail("关联 VM 不能同时改名") } catch is AppError {}
        let deletion = try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])
        XCTAssertNotEqual(deletion.status, .confirmedSuccess)
        let configuration = VirtualMachineCreation(name: "New", operatingSystem: .linux, storageID: "repo-1", networkID: "network-1", cpuCount: 1, memoryMiB: 512, diskGiB: 10)
        do { try await repository.createVirtualMachine(configuration); XCTFail("创建不能引用结果未知的网络") } catch is AppError {}
        let writes = await transport.guestWrites
        XCTAssertTrue(writes.isEmpty)
    }
    func test虚拟机在途或未完成时关联网络不能改名() async throws {
        let transport = NetworkWorkflowTransport(withGuest: true), repository = try repository(transport)
        do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn); XCTFail("合成回读仍为关机") } catch is AppError {}
        do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed")); XCTFail("不能绕过 VM 未完成保护") }
        catch is AppError {}
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        let guestWrites = await transport.guestWrites; XCTAssertEqual(guestWrites.count, 1)
    }
    func test发送记录期间保护同名与关联虚拟机() async throws {
        let transport = NetworkWorkflowTransport(count: 2, withGuest: true), repository = try repository(transport)
        let inventory = try await repository.loadVirtualMachineNetworks(), target = try XCTUnwrap(inventory.networks.first)
        try await repository.updateVirtualMachineNetwork(target, configuration: .init(name: "Renamed")) { stage in
            if stage == .willSubmit {
                do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn); XCTFail("网络记录期间不能开始关联电源操作") } catch is AppError {}
                do { try await repository.updateVirtualMachineNetwork(id: "network-2", configuration: .init(name: "RENAMED")); XCTFail("同名网络保存需要互斥") } catch is AppError {}
            }
        }
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        let guestWrites = await transport.guestWrites; XCTAssertTrue(guestWrites.isEmpty)
    }
    func testMac未修改名称保存不发送请求() async throws {
        let transport = NetworkWorkflowTransport(), repository = try repository(transport)
        try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Network"))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func testMac普通列表刷新也能恢复已接受网络操作() async throws {
        let transport = NetworkWorkflowTransport(mode: .postReadFailure), repository = try repository(transport)
        do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Renamed")); XCTFail("结果读取中断") }
        catch is AppError {}
        await transport.setMode(.success)
        _ = try await repository.loadVirtualMachineManager()
        try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Next"))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }
}

private enum NetworkTestFailure: Error { case storage }

actor NetworkWorkflowTransport: DsmHTTPTransport {
    enum Mode { case success, privateNetwork, frozen, lostReceipt, lostSecond, missingFreeze, stringGuestCount,
                     duplicateID, duplicateName, wrongDetail, missingGuests, wrongGuestType, wrongGuestCount,
                     missingInterface, partialList, postReadFailure, topologyAfterWrite, rejected, rejectedExternalChange, httpUnauthorized }
    private var mode: Mode
    private(set) var writes: [[String: String]] = []
    private(set) var guestWrites: [[String: String]] = []
    private var names: [String: String]
    private var requests: [URLRequest] = []
    private let withGuest: Bool
    private var running = false
    init(mode: Mode = .success, name: String = "Network", count: Int = 1, withGuest: Bool = false) {
        self.mode = mode; self.withGuest = withGuest
        names = Dictionary(uniqueKeysWithValues: (1...count).map { ("network-\($0)", $0 == 1 ? name : "Network \($0)") })
    }
    func recordedRequests() -> [URLRequest] { requests }
    func setMode(_ mode: Mode) { self.mode = mode }
    func setRunning(_ value: Bool) { running = value }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let fields = URLComponents(string: "https://example.invalid/?" + body)?.queryItems ?? []
        let wire = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
        func response(_ value: [String: Any]) throws -> DsmHTTPResponse {
            DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: value), statusCode: 200)
        }
        let id = (try? JSONDecoder().decode(String.self, from: Data((wire["network_id"] ?? "").utf8))) ?? "network-1"
        var data: [String: Any] = [:]
        if wire["api"] == DsmAPIName.virtualizationGuest || wire["api"] == DsmAPIName.virtualizationGuestAction {
            let guest: [String: Any] = ["guest_id": "vm-1", "name": "Guest", "status": running ? "running" : "shutdown",
                "desc": "", "vcpu_num": 1, "vram_size": 524288, "cpu_weight": 256, "autorun": 0]
            if ["set", "delete", "pwr_ctl", "create"].contains(wire["method"] ?? "") { guestWrites.append(wire) }
            else { data = wire["method"] == "get" ? guest : ["guests": withGuest ? [guest] : []] }
        } else if wire["method"] == "set" || wire["method"] == "delete" {
            writes.append(wire)
            if mode == .httpUnauthorized { return .init(data: Data(), statusCode: 401) }
            if mode == .rejected { return try response(["success": false, "error": ["code": 105]]) }
            if wire["method"] == "delete" { names[id] = nil }
            else { names[id] = try JSONDecoder().decode(String.self, from: Data((wire["name"] ?? "").utf8)) }
            if mode == .rejectedExternalChange { return try response(["success": false, "error": ["code": 105]]) }
            if mode == .lostReceipt || mode == .lostSecond && id == "network-2" { throw URLError(.networkConnectionLost) }
        } else if wire["method"] == "get" {
            var guest: [String: Any] = ["guest_id": "vm-1", "name": "Guest", "running": running,
                "prefer_sriov": false, "use_vf": false, "mac_addr": "02:00:00:00:00:01", "vinterface_names": "eth0"]
            if mode == .wrongGuestType { guest["running"] = "false" }
            data = ["name": mode == .wrongDetail ? "Other" : names[id] ?? "", "interfaces": [], "guests": withGuest ? [guest] : []]
            if mode == .missingGuests { data["guests"] = nil }
        } else if wire["method"] == "list" {
            if mode == .postReadFailure && !writes.isEmpty { throw URLError(.networkConnectionLost) }
            let host = mode == .topologyAfterWrite && !writes.isEmpty ? "host-2" : "host-1"
            var rows: [[String: Any]] = names.sorted { $0.key < $1.key }.map { id, name in
                ["network_id": id, "name": name, "type": mode == .privateNetwork ? "private" : "external", "host_id": host, "vlan_id": 0,
                 "num_guests": withGuest ? 1 : 0, "num_hosts": 1, "num_interfaces": 1, "num_vinterfaces": withGuest ? 1 : 0,
                 "interfaces": [["host_id": host, "interface_id": "interface-1"]]]
            }
            if !rows.isEmpty {
                if mode == .stringGuestCount { rows[0]["num_guests"] = "0" }
                if mode == .wrongGuestCount { rows[0]["num_guests"] = 5 }
                if mode == .missingInterface { rows[0]["interfaces"] = nil }
                if mode == .duplicateID { rows.append(rows[0]) }
                if mode == .duplicateName { var second = rows[0]; second["network_id"] = "network-2"; rows.append(second) }
            }
            data = ["is_freeze": mode == .frozen, "networks": rows]
            if mode == .missingFreeze { data["is_freeze"] = nil }
            if mode == .partialList { data["total"] = rows.count + 1 }
        }
        return try response(["success": true, "data": data])
    }
}
