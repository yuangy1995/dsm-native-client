import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileVirtualMachineImageTests: XCTestCase {
    private var roots: Set<URL> = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = roots; roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    private func make(mode: String = "vmm-image-success", root: URL? = nil, transport: MobileVirtualMachineUITransport? = nil,
                      username: String = "test") throws -> (MobileVirtualMachineControlModel, MobileVirtualMachineUITransport, URL, ImageAccessGate) {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("VMImageTest-\(UUID())")
        roots.insert(root)
        let transport = transport ?? MobileVirtualMachineUITransport(mode: mode), gate = ImageAccessGate()
        let profile = try NasProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: username)
        let names = [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationGuest,
            DsmAPIName.virtualizationGuestAction, DsmAPIName.virtualizationNetwork, DsmAPIName.virtualizationRepo, DsmAPIName.virtualizationCluster, DsmAPIName.virtualizationGuestImage]
        let repository = try DsmServiceManagementRepository(profile: profile, capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
            ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .json, selectedVersion: 2))
        })), session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        let model = MobileVirtualMachineControlModel(root: root)
        model.configure(profile: profile, repository: repository, authorize: { gate.calls += 1; return gate.allowed && gate.calls <= gate.allowedCalls })
        return (model, transport, root, gate)
    }
    private func delete(_ model: MobileVirtualMachineControlModel, ids: Set<String> = ["image-1"]) async throws -> UUID {
        await model.refreshImages()
        let confirmation = try XCTUnwrap(model.imageConfirmation(ids: ids))
        let id = try XCTUnwrap(model.deleteImages(confirmation)); await model.waitForOperation(id); return id
    }
    func test删除主流程及持久摘要隐私() async throws {
        let (model, transport, root, _) = try make()
        _ = try await delete(model)
        XCTAssertEqual(model.imageEntries.first?.items.first?.phase, .succeeded)
        XCTAssertFalse(model.imageInventory.images.contains { $0.id == "image-1" })
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["id"], "image-1"); XCTAssertEqual(writes.first?["version"], "2")
        let text = try String(contentsOf: root.appendingPathComponent("virtual-machine-images-v1.json"), encoding: .utf8)
        for value in ["Sample installer.iso", "image-1", "host-1", "repo-1", "REDACTED_SESSION", "nas.example.invalid"] { XCTAssertFalse(text.contains(value)) }
    }
    func test多项删除逐项完成且确认本身零写() async throws {
        let (model, transport, _, _) = try make(); await model.refreshImages()
        let confirmation = try XCTUnwrap(model.imageConfirmation(ids: ["image-1", "image-2"]))
        let before = await transport.writes; XCTAssertTrue(before.isEmpty)
        let id = try XCTUnwrap(model.deleteImages(confirmation)); await model.waitForOperation(id)
        XCTAssertEqual(model.imageEntries.first?.items.map(\.phase), [.succeeded, .succeeded])
        XCTAssertTrue(model.imageInventory.images.isEmpty)
    }
    func test第二项未知仍保留第一项成功和保护() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-image-partial")
        let id = try await delete(model, ids: ["image-1", "image-2"])
        XCTAssertEqual(model.imageEntries.first?.items.map(\.phase), [.succeeded, .submitted])
        XCTAssertFalse(model.canDeleteImages(ids: ["image-2"]))
        XCTAssertThrowsError(try model.imageRecovery.remove(id, context: try XCTUnwrap(model.context)))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }
    func test丢回执跨重启不能认领外部消失() async throws {
        let (model, _, root, _) = try make(mode: "vmm-image-unknown"); _ = try await delete(model)
        let (restored, transport, _, _) = try make(mode: "vmm-image-deleted", root: root)
        await restored.refreshImages()
        XCTAssertEqual(restored.imageEntries.first?.items.first?.phase, .submitted)
        XCTAssertFalse(restored.imageEntries.first?.items.first?.accepted ?? true)
        XCTAssertTrue(restored.imageRecovery.protects(imageID: "image-1", context: try XCTUnwrap(restored.context)))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test接受后中断跨重启只读恢复() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-image-accepted-offline"); _ = try await delete(model)
        XCTAssertEqual(model.imageEntries.first?.items.first?.phase, .submitted)
        XCTAssertTrue(model.imageEntries.first?.items.first?.accepted == true)
        await transport.setMode("vmm-image-success")
        let (restored, _, _, _) = try make(root: root, transport: transport); await restored.refreshImages()
        XCTAssertEqual(restored.imageEntries.first?.items.first?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test确认后名称身份变化均不提交() async throws {
        for replace in [false, true] {
            let (model, transport, _, _) = try make(); await model.refreshImages()
            let confirmation = try XCTUnwrap(model.imageConfirmation(ids: ["image-1", "image-2"]))
            if replace { await transport.replaceImage() } else { await transport.renameImage() }
            let id = try XCTUnwrap(model.deleteImages(confirmation)); await model.waitForOperation(id)
            XCTAssertEqual(model.imageEntries.first?.items.map(\.phase), [.failed, .skipped])
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test冻结占用和字段不全保持删除不可用() async throws {
        for mode in ["vmm-image-frozen", "vmm-image-in-use", "vmm-image-incomplete"] {
            let (model, transport, _, _) = try make(mode: mode); await model.refreshImages()
            XCTAssertFalse(model.canDeleteImages(ids: ["image-1"]))
            XCTAssertNil(model.imageConfirmation(ids: ["image-1"]))
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test发送边界再次检查权限() async throws {
        let (model, transport, _, gate) = try make(); gate.allowedCalls = 2
        _ = try await delete(model)
        XCTAssertEqual(model.imageError, .denied)
        XCTAssertEqual(model.imageEntries.first?.items.first?.phase, .failed)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test重复点击与退出后的迟到回执隔离() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-image-unknown"); await model.refreshImages()
        let confirmation = try XCTUnwrap(model.imageConfirmation(ids: ["image-1"]))
        await transport.holdWrites()
        let id = try XCTUnwrap(model.deleteImages(confirmation)); await transport.waitForWrite()
        XCTAssertNil(model.deleteImages(confirmation))
        model.deactivate(); await transport.release(); await model.waitForOperation(id)
        XCTAssertTrue(model.imageEntries.isEmpty); XCTAssertNil(model.context); XCTAssertNil(model.imageError)
        XCTAssertEqual(model.imageRecovery.entry(id)?.items.first?.phase, .submitted)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test账号隔离和旧确认失效() async throws {
        let (model, _, root, _) = try make(mode: "vmm-image-unknown"); await model.refreshImages()
        let confirmation = try XCTUnwrap(model.imageConfirmation(ids: ["image-1"]))
        _ = try await delete(model)
        let (other, transport, _, _) = try make(root: root, username: "other"); await other.refreshImages()
        XCTAssertTrue(other.imageEntries.isEmpty); XCTAssertTrue(other.canDeleteImages(ids: ["image-1"]))
        XCTAssertNil(other.deleteImages(confirmation))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test损坏和缺失记录不能解除保护() async throws {
        let (model, transport, root, _) = try make(mode: "vmm-image-unknown"); _ = try await delete(model)
        let file = root.appendingPathComponent("virtual-machine-images-v1.json")
        try FileManager.default.removeItem(at: file); await model.refreshImages()
        XCTAssertTrue(model.imageRecovery.failed); XCTAssertFalse(model.imageAllowed)
        try Data("invalid".utf8).write(to: file)
        let (restored, _, _, _) = try make(root: root, transport: transport); await restored.refresh(); await restored.refreshImages()
        XCTAssertFalse(restored.imageAllowed); XCTAssertFalse(restored.canOpenCreation)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test未提交记录重启只停止不执行() async throws {
        let (model, _, root, _) = try make(); await model.refreshImages()
        let target = try XCTUnwrap(model.imageInventory.images.first), context = try XCTUnwrap(model.context)
        let entry = try model.imageRecovery.reserve([target], context: context); model.imageRecovery.end(entry.id)
        let (restored, transport, _, _) = try make(root: root); await restored.refreshImages()
        XCTAssertEqual(restored.imageEntries.first?.items.first?.phase, .skipped)
        try restored.imageRecovery.remove(entry.id, context: context)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test拒绝及证书登录错误保持边界() async throws {
        for mode in ["vmm-image-reject", "vmm-image-trust", "vmm-image-http-unauthorized"] {
            let (model, transport, _, _) = try make(mode: mode); _ = try await delete(model)
            XCTAssertEqual(model.imageEntries.first?.items.first?.phase, mode == "vmm-image-reject" ? .failed : .submitted)
            XCTAssertEqual(model.imageError, mode == "vmm-image-trust" ? .trust : .denied)
            let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "delete")
        }
    }
    func test恢复不能跨读取来源认领完成() async throws {
        let (model, _, _, _) = try make(); await model.refreshImages()
        let target = try XCTUnwrap(model.imageInventory.images.first), context = try XCTUnwrap(model.context)
        let entry = try model.imageRecovery.reserve([target], context: context)
        try model.imageRecovery.checkpoint(entry.id, index: 0, stage: .willSubmit)
        try model.imageRecovery.checkpoint(entry.id, index: 0, stage: .accepted); model.imageRecovery.end(entry.id)
        try model.imageRecovery.resolve(.init(source: .official, isFrozen: false, images: []), context: context)
        XCTAssertEqual(model.imageRecovery.entry(entry.id)?.items.first?.phase, .submitted)
        try model.imageRecovery.resolve(.init(source: .internalAPI, isFrozen: true, images: []), context: context)
        XCTAssertEqual(model.imageRecovery.entry(entry.id)?.items.first?.phase, .submitted)
        try model.imageRecovery.resolve(.init(source: .internalAPI, isFrozen: false, images: []), context: context)
        XCTAssertEqual(model.imageRecovery.entry(entry.id)?.items.first?.phase, .succeeded)
    }
    func test创建引用映像时阻止删除() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await model.refreshImages()
        await transport.setMode("vmm-create-unknown")
        let resources = try await model.loadCreationResources(activation: model.activation)
        let configuration = VirtualMachineCreation(name: "New machine", operatingSystem: .linux, storageID: "repo-1", networkID: "", bootImageID: "image-1",
            cpuCount: 1, memoryMiB: 512, diskGiB: 10)
        let id = try XCTUnwrap(model.create(configuration, resources: resources, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.creationEntries.first?.phase, .submitted)
        await transport.setMode("vmm-image-success"); await model.refreshImages()
        XCTAssertFalse(model.canDeleteImages(ids: ["image-1"])); XCTAssertTrue(model.canDeleteImages(ids: ["image-2"]))
    }
    func test删除未完成时创建过滤映像及拒绝旧选择() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-image-unknown"); _ = try await delete(model)
        await transport.setMode("vmm-create-success"); await model.refresh()
        let resources = try await model.loadCreationResources(activation: model.activation); XCTAssertTrue(resources.images.isEmpty)
        let configuration = VirtualMachineCreation(name: "New machine", operatingSystem: .linux, storageID: "repo-1", networkID: "", bootImageID: "image-1",
            cpuCount: 1, memoryMiB: 512, diskGiB: 10)
        XCTAssertNil(model.create(configuration, resources: resources, activation: model.activation))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
}

@MainActor private final class ImageAccessGate { var allowed = true; var calls = 0; var allowedCalls = Int.max }
