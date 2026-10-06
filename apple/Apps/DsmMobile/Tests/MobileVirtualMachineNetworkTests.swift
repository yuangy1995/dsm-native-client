import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileVirtualMachineNetworkTests: XCTestCase {
    private var roots: Set<URL> = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = roots; roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    private func make(mode: String = "vmm-network-success", root: URL? = nil, transport: MobileVirtualMachineUITransport? = nil,
                      username: String = "test") throws -> (MobileVirtualMachineControlModel, MobileVirtualMachineUITransport, URL, NetworkAccessGate) {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("VMNetworkTest-\(UUID())")
        roots.insert(root)
        let transport = transport ?? MobileVirtualMachineUITransport(mode: mode), gate = NetworkAccessGate()
        let profile = try NasProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: username)
        let names = [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationGuest,
            DsmAPIName.virtualizationGuestAction, DsmAPIName.virtualizationNetwork, DsmAPIName.virtualizationRepo, DsmAPIName.virtualizationCluster]
        let repository = try DsmServiceManagementRepository(profile: profile, capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
            ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .json, selectedVersion: 2))
        })), session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        let model = MobileVirtualMachineControlModel(root: root)
        model.configure(profile: profile, repository: repository, authorize: { gate.calls += 1; return gate.allowed && gate.calls <= gate.allowedCalls })
        return (model, transport, root, gate)
    }
    private func rename(_ model: MobileVirtualMachineControlModel, name: String = "Renamed network") async throws -> UUID {
        await model.refreshNetworks()
        let target = try XCTUnwrap(model.networkInventory.networks.first { $0.id == "network-1" })
        let id = try XCTUnwrap(model.renameNetwork(target, name: name, activation: model.activation))
        await model.waitForOperation(id); return id
    }
    func test改名主流程及摘要隐私() async throws {
        let (model, transport, root, _) = try make()
        _ = try await rename(model)
        XCTAssertEqual(model.networkEntries.first?.items.first?.phase, .succeeded)
        XCTAssertEqual(model.networkInventory.networks.first { $0.id == "network-1" }?.name, "Renamed network")
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["interfaces_add"], "[]"); XCTAssertEqual(writes.first?["version"], "1")
        let text = try String(contentsOf: root.appendingPathComponent("virtual-machine-networks-v1.json"), encoding: .utf8)
        for value in ["Renamed network", "Sample network", "network-1", "synthetic-vm", "Sample virtual machine", "host-1", "nas.example.invalid", "REDACTED_SESSION", "02:00:00"] {
            XCTAssertFalse(text.contains(value))
        }
    }
    func test多项删除逐项完成且取消确认零写() async throws {
        let (model, transport, _, _) = try make(); await model.refreshNetworks()
        let confirmation = try XCTUnwrap(model.networkConfirmation(ids: ["network-1", "network-2"]))
        let before = await transport.writes; XCTAssertTrue(before.isEmpty)
        let id = try XCTUnwrap(model.deleteNetworks(confirmation)); await model.waitForOperation(id)
        XCTAssertEqual(model.networkEntries.first?.items.map(\.phase), [.succeeded, .succeeded])
        XCTAssertTrue(model.networkInventory.networks.isEmpty)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }
    func test第二项未知保留第一项成功与原记录() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-network-partial"); await model.refreshNetworks()
        let confirmation = try XCTUnwrap(model.networkConfirmation(ids: ["network-1", "network-2"]))
        let id = try XCTUnwrap(model.deleteNetworks(confirmation)); await model.waitForOperation(id)
        XCTAssertEqual(model.networkEntries.first?.items.map(\.phase), [.succeeded, .submitted])
        XCTAssertFalse(model.canManageNetworks(ids: ["network-2"]))
        XCTAssertThrowsError(try model.networkRecovery.remove(id, context: try XCTUnwrap(model.context)))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }
    func test丢回执跨重启保留未知且保护网络关联虚拟机() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-network-unknown")
        _ = try await rename(model)
        let (restored, _, _, _) = try make(root: root, transport: transport)
        await restored.refresh(); await restored.refreshNetworks()
        XCTAssertEqual(restored.networkEntries.first?.items.first?.phase, .submitted)
        XCTAssertFalse(restored.networkEntries.first?.items.first?.accepted ?? true)
        XCTAssertFalse(restored.canManageNetworks(ids: ["network-1"]))
        XCTAssertFalse(restored.canPerform(ids: ["synthetic-vm"], kind: .powerOn))
        XCTAssertFalse(restored.canEdit(id: "synthetic-vm"))
        XCTAssertTrue(restored.canPerform(ids: ["worker-b"], kind: .powerOn))
        XCTAssertTrue(restored.canManageNetworks(ids: ["network-2"]))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test接受后断网跨重启仅恢复结果并解除保护() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-network-accepted-offline")
        _ = try await rename(model)
        XCTAssertEqual(model.networkEntries.first?.items.first?.phase, .submitted)
        XCTAssertTrue(model.networkEntries.first?.items.first?.accepted == true)
        await transport.setMode("vmm-network-success")
        let (restored, _, _, _) = try make(root: root, transport: transport)
        await restored.refreshNetworks()
        XCTAssertEqual(restored.networkEntries.first?.items.first?.phase, .succeeded)
        XCTAssertTrue(restored.canManageNetworks(ids: ["network-1"]))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test删除接受后中断可跨重启确认原ID消失() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-network-accepted-offline"); await model.refreshNetworks()
        let confirmation = try XCTUnwrap(model.networkConfirmation(ids: ["network-1"]))
        let id = try XCTUnwrap(model.deleteNetworks(confirmation)); await model.waitForOperation(id)
        await transport.setMode("vmm-network-success")
        let (restored, _, _, _) = try make(root: root, transport: transport); await restored.refreshNetworks()
        XCTAssertEqual(restored.networkEntries.first?.items.first?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test确认后对象改名或替换均零写() async throws {
        for replace in [false, true] {
            let (model, transport, _, _) = try make(); await model.refreshNetworks()
            let confirmation = try XCTUnwrap(model.networkConfirmation(ids: ["network-1", "network-2"]))
            if replace { await transport.replaceNetwork() } else { await transport.renameNetwork() }
            let id = try XCTUnwrap(model.deleteNetworks(confirmation)); await model.waitForOperation(id)
            XCTAssertEqual(model.networkEntries.first?.items.map(\.phase), [.failed, .skipped])
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test权限在发送边界再次检查() async throws {
        let (model, transport, _, gate) = try make(); gate.allowedCalls = 2
        _ = try await rename(model)
        XCTAssertEqual(model.networkError, .denied)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(model.networkEntries.first?.items.first?.phase, .failed)
    }
    func test初始无权限与冻结均无写入口() async throws {
        for frozen in [true, false] {
            let (model, transport, _, gate) = try make(mode: frozen ? "vmm-network-frozen" : "vmm-network-success")
            gate.allowed = frozen; await model.refreshNetworks()
            XCTAssertFalse(model.canManageNetworks(ids: ["network-1"]))
            XCTAssertNil(model.networkConfirmation(ids: ["network-1"]))
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test不完整网络列表不能作为写入依据() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-network-incomplete"); await model.refreshNetworks()
        XCTAssertEqual(model.networkError, .read); XCTAssertFalse(model.networkAllowed)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test重复点击在途互斥及账号切换迟到回执() async throws {
        let (model, transport, _, _) = try make(); await model.refreshNetworks(); await model.refresh()
        let target = try XCTUnwrap(model.networkInventory.networks.first { $0.id == "network-1" })
        await transport.holdWrites()
        let id = try XCTUnwrap(model.renameNetwork(target, name: "Renamed network", activation: model.activation))
        await transport.waitForWrite()
        XCTAssertNil(model.renameNetwork(target, name: "Renamed network", activation: model.activation))
        XCTAssertFalse(model.canPerform(ids: ["synthetic-vm"], kind: .powerOn))
        model.deactivate(); await transport.release(); await model.waitForOperation(id)
        XCTAssertTrue(model.networkEntries.isEmpty); XCTAssertNil(model.context); XCTAssertNil(model.networkError)
        XCTAssertEqual(model.networkRecovery.entry(id)?.items.first?.phase, .submitted)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test账号变化隔离记录和旧确认() async throws {
        let (model, _, root, _) = try make(mode: "vmm-network-unknown"); await model.refreshNetworks()
        let confirmation = try XCTUnwrap(model.networkConfirmation(ids: ["network-1"]))
        _ = try await rename(model)
        let (other, transport, _, _) = try make(root: root, username: "other"); await other.refreshNetworks()
        XCTAssertTrue(other.networkEntries.isEmpty); XCTAssertTrue(other.canManageNetworks(ids: ["network-1"]))
        XCTAssertNil(other.deleteNetworks(confirmation))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test损坏或缺失记录保持写入关闭() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-network-unknown")
        _ = try await rename(model)
        let file = root.appendingPathComponent("virtual-machine-networks-v1.json")
        try FileManager.default.removeItem(at: file)
        await model.refreshNetworks(); XCTAssertTrue(model.networkRecovery.failed); XCTAssertFalse(model.networkAllowed)
        try Data("invalid".utf8).write(to: file)
        let (restored, _, _, _) = try make(root: root, transport: transport)
        await restored.refresh(); await restored.refreshNetworks()
        XCTAssertFalse(restored.allowed); XCTAssertFalse(restored.networkAllowed)
        XCTAssertFalse(restored.canOpenCreation)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test未提交记录重启后终止且允许移除() async throws {
        let (model, _, root, _) = try make(); await model.refreshNetworks()
        let target = try XCTUnwrap(model.networkInventory.networks.first), context = try XCTUnwrap(model.context)
        let entry = try model.networkRecovery.reserve([target], newName: nil, context: context); model.networkRecovery.end(entry.id)
        let (restored, transport, _, _) = try make(root: root); await restored.refreshNetworks()
        XCTAssertEqual(restored.networkEntries.first?.items.first?.phase, .skipped)
        try restored.networkRecovery.remove(entry.id, context: context)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test丢回执名称保护不能以大小写绕过() async throws {
        let (model, _, _, _) = try make(mode: "vmm-network-unknown"); _ = try await rename(model)
        let other = try XCTUnwrap(model.networkInventory.networks.first { $0.id == "network-2" })
        XCTAssertFalse(model.canRenameNetwork(other, name: "RENAMED NETWORK"))
    }
    func test明确拒绝及证书登录错误保持正确边界() async throws {
        for mode in ["vmm-network-reject", "vmm-network-trust", "vmm-network-http-unauthorized"] {
            let (model, transport, _, _) = try make(mode: mode); _ = try await rename(model)
            XCTAssertEqual(model.networkEntries.first?.items.first?.phase, mode == "vmm-network-reject" ? .failed : .submitted)
            XCTAssertEqual(model.networkError, mode == "vmm-network-trust" ? .trust : .denied)
            let calls = await transport.calls
            XCTAssertEqual(calls.last?["method"], "set")
        }
    }
    func test虚拟机未完成控制阻止相关网络删除() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await model.refreshNetworks()
        let vm = try XCTUnwrap(model.targets.first { $0.id == "synthetic-vm" })
        let entry = try model.recovery.reserve([vm], action: .powerOn, context: try XCTUnwrap(model.context))
        try model.recovery.checkpoint(entry.id, index: 0, stage: .willSubmit); model.recovery.end(entry.id)
        XCTAssertFalse(model.canManageNetworks(ids: ["network-1"]))
        XCTAssertTrue(model.canManageNetworks(ids: ["network-2"]))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test创建未完成时保护所引用网络() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await model.refreshNetworks()
        await transport.setMode("vmm-create-unknown")
        let resources = try await model.loadCreationResources(activation: model.activation)
        let configuration = VirtualMachineCreation(name: "New machine", operatingSystem: .linux, storageID: "repo-1", networkID: "network-1",
            cpuCount: 1, memoryMiB: 512, diskGiB: 10)
        let id = try XCTUnwrap(model.create(configuration, resources: resources, activation: model.activation))
        await model.waitForOperation(id)
        XCTAssertEqual(model.creationEntries.first?.phase, .submitted)
        await transport.setMode("vmm-network-success"); await model.refreshNetworks()
        XCTAssertFalse(model.canManageNetworks(ids: ["network-1"]))
        XCTAssertTrue(model.canManageNetworks(ids: ["network-2"]))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test创建资源排除未完成网络且旧选择不能提交() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-network-unknown"); _ = try await rename(model)
        await transport.setMode("vmm-create-success"); await model.refresh()
        let resources = try await model.loadCreationResources(activation: model.activation)
        XCTAssertTrue(resources.networks.isEmpty)
        let configuration = VirtualMachineCreation(name: "New machine", operatingSystem: .linux, storageID: "repo-1", networkID: "network-1",
            cpuCount: 1, memoryMiB: 512, diskGiB: 10)
        XCTAssertNil(model.create(configuration, resources: resources, activation: model.activation))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
}

@MainActor private final class NetworkAccessGate { var allowed = true; var calls = 0; var allowedCalls = Int.max }
