import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class VirtualMachineCreationWorkflowTests: XCTestCase, @unchecked Sendable {
    private func repository(_ transport: CreationWorkflowTransport) throws -> DsmServiceManagementRepository {
        let names = [DsmAPIName.virtualizationGuest, DsmAPIName.virtualizationRepo,
                     DsmAPIName.virtualizationNetwork, DsmAPIName.virtualizationGuestImage, "SYNO.Virtualization.Cluster"]
        return try DsmServiceManagementRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
                ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .json, selectedVersion: 2))
            })), session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func configuration(os: VirtualMachineOperatingSystem = .linux, disk: Int = 10, image: String? = nil) -> VirtualMachineCreation {
        .init(name: "Synthetic", operatingSystem: os, storageID: "repo-1", networkID: "network-1",
              bootImageID: image, cpuCount: 1, memoryMiB: 512, diskGiB: disk)
    }
    func test创建任务缺失不能按同名清单认领成功() async throws {
        let transport = CreationWorkflowTransport(mode: .missingTask), repository = try repository(transport)
        do { try await repository.createVirtualMachine(configuration()); XCTFail("同名实例不是本次创建完成证据") }
        catch is AppError {}
        let count = await transport.createCount
        XCTAssertEqual(count, 1)
    }
    func test创建丢回执后重复调用不能再次写入() async throws {
        let transport = CreationWorkflowTransport(mode: .lostReceipt), repository = try repository(transport)
        for _ in 0..<2 {
            do { try await repository.createVirtualMachine(configuration()); XCTFail("缺失原回执和任务时应保持未知") }
            catch is AppError {}
        }
        let count = await transport.createCount
        XCTAssertEqual(count, 1)
    }
    func test创建磁盘低于官方最小值不能发送() async throws {
        let transport = CreationWorkflowTransport(), repository = try repository(transport)
        do { try await repository.createVirtualMachine(configuration(disk: 9)); XCTFail("最小磁盘为 10 GiB") }
        catch is AppError {}
        let count = await transport.createCount
        XCTAssertEqual(count, 0)
    }
    func test三种系统预设绑定本次任务及实际配置() async throws {
        for os in VirtualMachineOperatingSystem.allCases {
            let transport = CreationWorkflowTransport(), repository = try repository(transport)
            try await repository.createVirtualMachine(configuration(os: os))
            let values = await transport.presetValues()
            XCTAssertEqual(values, [os == .linux ? "1" : "2", os == .linux ? "1" : "2",
                                   os == .linux ? "vmvga" : "vga", os == .windows ? "1" : "0", "disk"])
            let count = await transport.createCount
            XCTAssertEqual(count, 1)
        }
    }
    func test任务或结果不属于原创建时保持未知且不重发() async throws {
        for mode in [CreationWorkflowTransport.Mode.wrongParameters, .wrongTask, .duplicateTasks, .oldGuest, .wrongConfiguration, .wrongMemory] {
            let transport = CreationWorkflowTransport(mode: mode), repository = try repository(transport)
            for _ in 0..<2 {
                do { try await repository.createVirtualMachine(configuration()); XCTFail("不能认领不匹配的创建结果：\(mode)") }
                catch is AppError {}
            }
            let count = await transport.createCount
            XCTAssertEqual(count, 1)
        }
    }
    func test丢回执只能由原请求标识与完整参数恢复() async throws {
        let transport = CreationWorkflowTransport(mode: .lostReceiptWithTask), repository = try repository(transport)
        let probe = CreationStageProbe()
        let result = try await repository.createVirtualMachine(configuration(), expectedResources: nil) { await probe.record($0) }
        XCTAssertEqual(result, .succeeded(guestID: "vm-created"))
        let stages = await probe.values
        XCTAssertEqual(stages.count, 4)
        guard case .willSubmit(let tracking) = stages[0], case .accepted = stages[1],
              case .taskSucceeded = stages[2], case .succeeded = stages[3] else { return XCTFail("必须按提交、关联接受、任务及配置完成落盘") }
        XCTAssertTrue(tracking.isValid)
        let encoded = String(decoding: try JSONEncoder().encode(tracking), as: UTF8.self)
        for secret in ["Synthetic", "repo-1", "network-1", "REDACTED_SESSION", "nas.example.invalid"] { XCTAssertFalse(encoded.contains(secret)) }
    }
    func test写前存储失败零写接受后存储失败不重发() async throws {
        for failure in [CreationStageProbe.FailurePoint.beforeSubmission, .afterAcceptance] {
            let transport = CreationWorkflowTransport(), repository = try repository(transport), probe = CreationStageProbe(failure: failure)
            do {
                _ = try await repository.createVirtualMachine(configuration(), expectedResources: nil) { try await probe.recordThrowing($0) }
                XCTFail("记录失败必须结束当前调用")
            } catch CreationStageProbe.StorageFailure.failed {}
            let count = await transport.createCount
            XCTAssertEqual(count, failure == .beforeSubmission ? 0 : 1)
            if failure == .afterAcceptance {
                try await repository.createVirtualMachine(configuration())
                let finalCount = await transport.createCount
                XCTAssertEqual(finalCount, 1)
            }
        }
    }
    func test任务完成已落盘后任务消失仍只读核对原ID() async throws {
        let transport = CreationWorkflowTransport(mode: .wrongConfiguration), probe = CreationStageProbe()
        let first = try repository(transport)
        let result = try await first.createVirtualMachine(configuration(), expectedResources: nil) { await probe.record($0) }
        XCTAssertEqual(result, .pending)
        let persisted = await probe.taskTracking()
        let tracking = try XCTUnwrap(persisted)
        await transport.setMode(.missingTask)
        let restored = try repository(transport)
        let resumed = try await restored.reviewVirtualMachineCreation(tracking)
        XCTAssertEqual(resumed, .succeeded(guestID: "vm-created"))
        let count = await transport.createCount
        XCTAssertEqual(count, 1)
    }
    func test明确拒绝不变成同名成功() async throws {
        let transport = CreationWorkflowTransport(mode: .rejected), repository = try repository(transport), probe = CreationStageProbe()
        do {
            _ = try await repository.createVirtualMachine(configuration(), expectedResources: nil) { await probe.record($0) }
            XCTFail("拒绝不能成功")
        } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let stages = await probe.values
        XCTAssertEqual(stages.count, 2); XCTAssertEqual(stages.last, .rejected)
    }
    func test创建证书异常停止后续读取() async throws {
        let transport = CreationWorkflowTransport(mode: .trust), repository = try repository(transport)
        do { try await repository.createVirtualMachine(configuration()); XCTFail("证书异常不能继续读取") }
        catch is DsmCertificateTrustError {}
        let methods = await transport.methods
        XCTAssertEqual(methods.last, "create")
    }
    func test创建请求返回HTTP身份失效时停止后续请求() async throws {
        let transport = CreationWorkflowTransport(mode: .httpUnauthorized), repository = try repository(transport)
        do { try await repository.createVirtualMachine(configuration()); XCTFail("身份失效不能继续查询并认领成功") }
        catch let error as AppError { XCTAssertEqual(error.category, .authenticationRequired) }
        let methods = await transport.methods
        XCTAssertEqual(methods.last, "create")
    }
    func test未知创建不能由电源编辑或删除绕过() async throws {
        let transport = CreationWorkflowTransport(mode: .missingTask), repository = try repository(transport)
        do { try await repository.createVirtualMachine(configuration()) } catch is AppError {}
        do { try await repository.controlVirtualMachines(ids: ["vm-created"], action: .powerOn); XCTFail("创建中不能电源操作") } catch is AppError {}
        do { try await repository.updateVirtualMachine(id: "vm-created", configuration: .init(description: "new")); XCTFail("创建中不能编辑") } catch is AppError {}
        let result = try await repository.deleteVirtualMachinesResult(ids: ["vm-created"])
        XCTAssertEqual(result.status, .confirmedFailure)
        let methods = await transport.methods
        XCTAssertFalse(methods.contains("set")); XCTAssertFalse(methods.contains("pwr_ctl")); XCTAssertFalse(methods.contains("delete"))
    }
    func test创建引用的网络与映像在恢复期间不能修改或删除() async throws {
        let transport = CreationWorkflowTransport(mode: .missingTask), probe = CreationStageProbe(), repository = try repository(transport)
        _ = try await repository.createVirtualMachine(configuration(image: "image-1"), expectedResources: nil) { await probe.record($0) }
        let values = await probe.values
        guard case .accepted(let tracking) = values.last else { return XCTFail("应保留创建回执") }
        let restored = try self.repository(transport)
        _ = try await restored.reviewVirtualMachineCreation(tracking)
        do { try await restored.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Changed")); XCTFail("不能修改被创建引用的网络") } catch is AppError {}
        do { try await restored.deleteVirtualMachineNetworks(ids: ["network-1"]); XCTFail("不能删除被创建引用的网络") } catch is AppError {}
        do { _ = try await restored.deleteVirtualMachineNetworksResult(ids: ["network-1"]); XCTFail("结果入口也必须保护") } catch is AppError {}
        do { _ = try await restored.deleteVirtualMachineImagesResult(ids: ["image-1"]); XCTFail("不能删除被创建引用的映像") } catch is AppError {}
        let methods = await transport.methods
        XCTAssertFalse(methods.contains("set")); XCTAssertFalse(methods.contains("delete"))
    }
}

private actor CreationStageProbe {
    enum FailurePoint { case beforeSubmission, afterAcceptance }
    enum StorageFailure: Error { case failed }
    let failure: FailurePoint?
    private(set) var values: [VirtualMachineCreationStage] = []
    init(failure: FailurePoint? = nil) { self.failure = failure }
    func record(_ value: VirtualMachineCreationStage) { values.append(value) }
    func recordThrowing(_ value: VirtualMachineCreationStage) throws {
        values.append(value)
        if case .willSubmit = value, failure == .beforeSubmission { throw StorageFailure.failed }
        if case .accepted = value, failure == .afterAcceptance { throw StorageFailure.failed }
    }
    func taskTracking() -> VirtualMachineCreationTracking? {
        for case .taskSucceeded(let value) in values { return value }; return nil
    }
}

/// 所有身份、配置与响应均为合成；任务回显直接取本次请求，避免硬编码随机 UUID/MAC。
actor CreationWorkflowTransport: DsmHTTPTransport {
    enum Mode { case success, missingTask, lostReceipt, lostReceiptWithTask, wrongParameters, wrongTask, duplicateTasks,
                     oldGuest, wrongConfiguration, wrongMemory, rejected, trust, httpUnauthorized }
    private var mode: Mode
    private(set) var createCount = 0
    private(set) var methods: [String] = []
    private var requests: [URLRequest] = []
    func recordedRequests() -> [URLRequest] { requests }
    private var sent: [String: Any] = [:]
    init(mode: Mode = .success) { self.mode = mode }
    func setMode(_ mode: Mode) { self.mode = mode }
    func presetValues() -> [String] {
        let disk = (sent["vdisks"] as? [[String: Any]])?.first, nic = (sent["vnics"] as? [[String: Any]])?.first
        return [String(describing: disk?["vdisk_mode"] ?? ""), String(describing: nic?["vnic_type"] ?? ""),
                sent["video_card"] as? String ?? "", String(describing: sent["auto_switch"] ?? ""), sent["boot_from"] as? String ?? ""]
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = URLComponents(string: "https://example.invalid/?" + body)?.queryItems ?? []
        let wire = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
        let api = wire["api"], method = wire["method"]
        methods.append(method ?? "")
        var data: Any = [:]
        if api == DsmAPIName.virtualizationGuest {
            if method == "create" {
                createCount += 1
                sent = try wire.filter { !["api", "method", "version", "_sid", "SynoToken"].contains($0.key) }
                    .mapValues { try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
                if mode == .lostReceipt || mode == .lostReceiptWithTask { throw URLError(.networkConnectionLost) }
                if mode == .rejected { return DsmHTTPResponse(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
                if mode == .httpUnauthorized { return DsmHTTPResponse(data: Data(), statusCode: 401) }
                if mode == .trust { throw DsmCertificateTrustError.changed(.init(host: "nas.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "a", count: 64), canBePinned: true)) }
                data = ["task_id": "task-synthetic"]
            } else if method == "list" {
                if mode == .oldGuest && createCount == 0 {
                    var old = guest(); old["name"] = "Existing"; data = ["guests": [old]]
                } else { data = ["guests": createCount > 0 && mode != .lostReceipt ? [guest()] : []] }
            } else if method == "get" { data = guest() }
            else if method == "get_setting" { data = settings() }
        } else if api == DsmAPIName.virtualizationRepo {
            data = ["is_freeze": false, "repos": [["repo_id": "repo-1", "name": "Storage", "host_id": "host-1",
                "host_name": "Host", "allocated_size": 100, "size": "107374182400", "used": "100", "status": "online", "status_type": "healthy"]]]
        } else if api == DsmAPIName.virtualizationNetwork {
            data = ["is_freeze": false, "networks": [["network_id": "network-1", "name": "Network", "type": "external", "host_id": "host-1"]]]
        } else if api == DsmAPIName.virtualizationGuestImage {
            data = ["is_freeze": false, "images": [["id": "image-1", "name": "Installer", "repo_id": "repo-1",
                "host_id": "host-1", "type": "iso", "status": "online", "status_type": "healthy"]]]
        } else if api == "SYNO.Virtualization.Cluster" {
            if mode != .missingTask && mode != .lostReceipt {
                var echo = sent
                if mode == .wrongParameters { echo["vcpu_num"] = 8 }
                let task: [String: Any] = ["finish": true, "success": true,
                    "info": ["api": DsmAPIName.virtualizationGuest, "method": "create", "version": 1,
                             "prefix": "virtualization_guest_create", "param": echo],
                    "data": ["progress": 100, "guest_id": "vm-created"]]
                var tasks = [mode == .wrongTask ? "task-other" : "task-synthetic": task]
                if mode == .duplicateTasks { tasks["task-duplicate"] = task }
                data = ["host-1": tasks]
            }
        }
        return DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
    private func guest() -> [String: Any] {
        ["guest_id": "vm-created", "name": sent["name"] ?? "Synthetic", "desc": sent["desc"] ?? "",
         "status": "shutdown", "vcpu_num": sent["vcpu_num"] ?? 1, "vram_size": (sent["vram_size"] as? Int ?? 512) * 1024,
         "cpu_weight": 256, "autorun": sent["autorun"] ?? 0]
    }
    private func settings() -> [String: Any] {
        var value = sent
        value.merge(guest()) { _, new in new }; value.removeValue(forKey: "guest_id")
        if mode == .wrongConfiguration { value["boot_from"] = "iso" }
        if mode == .wrongMemory { value["vram_size"] = 512 }
        if let disks = sent["vdisks"] as? [[String: Any]] {
            value["vdisks"] = disks.map { disk in ["vdisk_id": "disk-1", "size": String((disk["vdisk_size"] as? Int ?? 10) * 1024 * 1024 * 1024),
                "vdisk_mode": disk["vdisk_mode"] ?? 1, "unmap": false] }
        }
        return value
    }
}
