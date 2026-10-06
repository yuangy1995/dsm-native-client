import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileVirtualMachineCreationTests: XCTestCase {
    private var roots: Set<URL> = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = roots; roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    private func make(mode: String = "vmm-create-success", root: URL? = nil,
                      transport: MobileVirtualMachineUITransport? = nil) throws -> (MobileVirtualMachineControlModel, MobileVirtualMachineUITransport, URL, CreationAccessGate) {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("VMCreationTest-\(UUID())")
        roots.insert(root)
        let transport = transport ?? MobileVirtualMachineUITransport(mode: mode), gate = CreationAccessGate()
        let profile = try NasProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: "test")
        let names = [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationGuest,
                     DsmAPIName.virtualizationGuestAction, DsmAPIName.virtualizationRepo, DsmAPIName.virtualizationNetwork,
                     DsmAPIName.virtualizationGuestImage, DsmAPIName.virtualizationCluster]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
            ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .json, selectedVersion: 2))
        }))
        let repository = try DsmServiceManagementRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        let model = MobileVirtualMachineControlModel(root: root)
        model.configure(profile: profile, repository: repository, authorize: { gate.calls += 1; return gate.allowed && gate.calls <= gate.allowedCalls })
        return (model, transport, root, gate)
    }
    private var configuration: VirtualMachineCreation {
        .init(name: "New synthetic machine", operatingSystem: .linux, storageID: "repo-1", networkID: "",
              cpuCount: 1, memoryMiB: 512, diskGiB: 10, description: "Private synthetic description", firmware: .uefi)
    }
    private func create(_ model: MobileVirtualMachineControlModel) async throws -> UUID {
        await model.refresh()
        let resources = try await model.loadCreationResources(activation: model.activation)
        let id = try XCTUnwrap(model.create(configuration, resources: resources, activation: model.activation))
        await model.waitForOperation(id); return id
    }
    func test创建主流程精确内存断网空映像与实际结果() async throws {
        let (model, transport, root, _) = try make()
        _ = try await create(model)
        XCTAssertEqual(model.creationEntries.first?.phase, .succeeded)
        XCTAssertTrue(model.targets.contains { $0.id == "created-vm" && $0.name == configuration.name })
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["method"], "create")
        XCTAssertEqual(writes.first?["vram_size"], "512"); XCTAssertEqual(writes.first?["version"], "1")
        XCTAssertEqual(writes.first?["boot_from"], "disk"); XCTAssertEqual(writes.first?["poweron_after_create"], "false")
        let data = try Data(contentsOf: root.appendingPathComponent("virtual-machine-creations-v1.json"))
        let text = String(decoding: data, as: UTF8.self)
        for secret in [configuration.name, configuration.description!, "repo-1", "nas.example.invalid", "REDACTED_SESSION"] { XCTAssertFalse(text.contains(secret)) }
    }
    func test丢回执跨重启保留未知与名称保护且不重发() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-create-unknown")
        let id = try await create(model)
        XCTAssertEqual(model.creationEntries.first?.phase, .submitted)
        XCTAssertNil(model.creationEntries.first?.tracking?.taskIdentityDigest)
        let (restored, _, _, _) = try make(root: root, transport: transport); await restored.refresh()
        XCTAssertFalse(restored.canCreate(name: configuration.name.uppercased()))
        XCTAssertThrowsError(try restored.creations.remove(id, context: try XCTUnwrap(restored.context)))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test已接受断网跨重启恢复原任务且不重发() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-create-accepted-offline")
        _ = try await create(model)
        XCTAssertEqual(model.creationEntries.first?.phase, .submitted)
        XCTAssertNotNil(model.creationEntries.first?.tracking?.taskIdentityDigest)
        await transport.setMode("vmm-create-success")
        let (restored, _, _, _) = try make(root: root, transport: transport); await restored.refresh()
        XCTAssertEqual(restored.creationEntries.first?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test未完成创建阻止原机控制和编辑但不影响其他目标() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-create-accepted-offline")
        _ = try await create(model); await transport.setMode("vmm-create-missing-task")
        let (restored, _, _, _) = try make(root: root, transport: transport); await restored.refresh()
        XCTAssertFalse(restored.canEdit(id: "created-vm"))
        XCTAssertFalse(restored.canPerform(ids: ["created-vm"], kind: .delete))
        XCTAssertFalse(restored.canPerform(ids: ["created-vm"], kind: .powerOn))
        XCTAssertTrue(restored.canPerform(ids: ["synthetic-vm"], kind: .powerOn))
    }
    func test改名未完成时创建不能通过大小写绕过() async throws {
        let (model, _, root, _) = try make(); await model.refresh()
        let settings = try await model.loadSettings(id: "synthetic-vm", activation: model.activation)
        let entry = try model.recovery.reserveEdit(settings, update: .init(name: configuration.name), context: try XCTUnwrap(model.context))
        try model.recovery.checkpoint(entry.id, index: 0, stage: .willSubmit); model.recovery.end(entry.id)
        let (restored, _, _, _) = try make(root: root); await restored.refresh()
        XCTAssertFalse(restored.canCreate(name: configuration.name.uppercased()))
    }
    func test创建前撤权和资源改变均零写() async throws {
        for withdraw in [true, false] {
            let (model, transport, _, gate) = try make(); await model.refresh()
            let resources = try await model.loadCreationResources(activation: model.activation)
            if withdraw { gate.allowed = false } else { await transport.setMode("vmm-create-empty") }
            let id = try XCTUnwrap(model.create(configuration, resources: resources, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.creationEntries.first?.phase, .failed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test发送边界再次检查权限而非只检查表单打开时() async throws {
        let (model, transport, _, gate) = try make(); gate.allowedCalls = 3
        _ = try await create(model)
        XCTAssertEqual(model.error, .denied)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test重复点击在途保护与账号切换迟到回执() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        let resources = try await model.loadCreationResources(activation: model.activation), activation = model.activation
        await transport.holdWrites()
        let id = try XCTUnwrap(model.create(configuration, resources: resources, activation: activation))
        await transport.waitForWrite()
        XCTAssertNil(model.create(configuration, resources: resources, activation: activation))
        model.deactivate(); await transport.release(); await model.waitForOperation(id)
        XCTAssertTrue(model.creationEntries.isEmpty); XCTAssertNil(model.context); XCTAssertNil(model.error)
        XCTAssertEqual(model.creations.entry(id)?.phase, .submitted)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test创建证书错误不继续读取() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-create-trust")
        _ = try await create(model)
        XCTAssertEqual(model.error, .trust); XCTAssertFalse(model.allowed)
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "create")
    }
    func test创建中登录失效保留原记录并停止读取() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-create-http-unauthorized")
        _ = try await create(model)
        XCTAssertEqual(model.error, .denied); XCTAssertFalse(model.allowed)
        XCTAssertEqual(model.creationEntries.first?.phase, .submitted)
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "create")
    }
    func test明确拒绝为终态任务失败也不认领同名对象() async throws {
        for mode in ["vmm-create-reject", "vmm-create-task-failed"] {
            let (model, transport, _, _) = try make(mode: mode)
            _ = try await create(model)
            XCTAssertEqual(model.creationEntries.first?.phase, .failed)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }
    func test损坏记录禁止写且保留原文件() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-create-unknown")
        _ = try await create(model)
        let url = root.appendingPathComponent("virtual-machine-creations-v1.json"), damaged = Data("{damaged}".utf8)
        try damaged.write(to: url)
        let (restored, _, _, _) = try make(root: root, transport: transport); await restored.refresh()
        XCTAssertTrue(restored.creations.failed); XCTAssertFalse(restored.canOpenCreation)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }
    func test旧表单不能在新账号上下文提交() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        let resources = try await model.loadCreationResources(activation: model.activation), token = model.activation
        model.deactivate()
        XCTAssertNil(model.create(configuration, resources: resources, activation: token)); XCTAssertNil(model.error)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test草稿保留精确MiB且拒绝缺失和过小磁盘() async throws {
        let (model, _, _, _) = try make(); await model.refresh()
        let resources = try await model.loadCreationResources(activation: model.activation)
        var draft = MobileVirtualMachineCreationDraft(resources: resources)
        XCTAssertNil(draft.configuration); draft.name = "Synthetic"; draft.memoryMiB = 768
        XCTAssertEqual(draft.configuration?.memoryMiB, 768); XCTAssertEqual(draft.configuration?.networkID, "")
        draft.diskGiB = 9; XCTAssertNil(draft.configuration)
        draft.diskGiB = 10; draft.memoryMiB = nil; XCTAssertNil(draft.configuration)
        draft.memoryMiB = 512; draft.name = "name\ncontrol"; XCTAssertNil(draft.configuration)
    }
}

@MainActor private final class CreationAccessGate {
    var allowed = true
    var allowedCalls = Int.max
    var calls = 0
}
