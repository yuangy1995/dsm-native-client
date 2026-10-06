import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileContainerControlTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = roots; roots = []; return values }
        for value in values { try? FileManager.default.removeItem(at: value) }
        try await super.tearDown()
    }
    func test三种操作按实际字段开放且托管目标不可选() async throws {
        let (model, _, _, _) = try make(); await model.refresh()
        XCTAssertTrue(model.canPerform(ids: ["synthetic-id"], action: .start))
        XCTAssertFalse(model.canPerform(ids: ["synthetic-id"], action: .stop))
        XCTAssertFalse(model.canPerform(ids: ["managed-id"], action: .restart))
        XCTAssertFalse(model.canPerform(ids: ["missing"], action: .start))
        let (running, _, _, _) = try make(mode: "containers-restarting"); await running.refresh()
        XCTAssertTrue(running.canPerform(ids: ["synthetic-id"], action: .stop))
        XCTAssertTrue(running.canPerform(ids: ["synthetic-id"], action: .restart))
        XCTAssertFalse(running.canPerform(ids: ["synthetic-id"], action: .start))
        let (missing, _, _, _) = try make(mode: "containers-missing-state"); await missing.refresh()
        XCTAssertFalse(missing.canPerform(ids: ["synthetic-id"], action: .start))
    }
    func test单项启动停止重启均完成且只提交一次() async throws {
        for action in ContainerAction.allCases {
            let (model, transport, _, _) = try make(mode: action == .start ? "containers-control" : "containers-running")
            await model.refresh(); let id = try start(model, action: action); await model.waitForOperation(id)
            XCTAssertEqual(model.entries.first?.completedCount, 1)
            XCTAssertEqual(model.entries.first?.items.first?.phase, .succeeded)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(writes.first?["method"], action.rawValue)
        }
    }
    func test批量按目标顺序提交并保留逐项结果() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        let id = try start(model, ids: ["synthetic-id", "worker-b"]); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.completedCount, 2)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["name"] }, ["Sample container", "Worker B"])
    }
    func test权限写前撤回零提交且保留失败结果() async throws {
        let (model, transport, gate, _) = try make(); await model.refresh()
        await gate.set(false); let id = try start(model); await model.waitForOperation(id)
        XCTAssertEqual(model.error, .denied); XCTAssertFalse(model.allowed)
        XCTAssertEqual(model.entries.first?.items.first?.failure, .denied)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test确认之后目标身份或名称改变零提交() async throws {
        for replacement in [false, true] {
            let (model, transport, _, _) = try make(); await model.refresh()
            if replacement { await transport.replaceFirst() } else { await transport.renameFirst() }
            let id = try start(model); await model.waitForOperation(id)
            XCTAssertEqual(model.entries.first?.items.first?.failure, .changed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test重复点击和执行中移除记录均被阻止() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await transport.holdWrites()
        let confirmation = try XCTUnwrap(model.confirmation(ids: ["synthetic-id"], action: .start))
        let id = try XCTUnwrap(model.perform(confirmation)); await transport.waitForWrite()
        XCTAssertNil(model.perform(confirmation))
        XCTAssertThrowsError(try model.recovery.remove(id, context: try XCTUnwrap(model.context)))
        await transport.release(); await model.waitForOperation(id)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test明确拒绝不能被之后外部启动覆盖为成功() async throws {
        let (model, transport, _, _) = try make(mode: "containers-reject"); await model.refresh()
        let id = try start(model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.items.first?.phase, .failed)
        await transport.setMode("containers-control"); await transport.apply(.start); await model.refresh()
        XCTAssertEqual(model.entries.first?.items.first?.phase, .failed)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test未知结果跨重启只读恢复且不能提前移除() async throws {
        let (model, transport, _, root) = try make(mode: "containers-unknown"); await model.refresh()
        let id = try start(model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.items.first?.phase, .submitted)
        XCTAssertFalse(model.canPerform(ids: ["synthetic-id"], action: .start))
        XCTAssertThrowsError(try model.recovery.remove(id, context: try XCTUnwrap(model.context)))
        let (next, nextTransport, _, _) = try make(mode: "containers-recover", root: root); await next.refresh()
        XCTAssertEqual(next.entries.first?.items.first?.phase, .succeeded)
        next.removeRecord(id); XCTAssertTrue(next.entries.isEmpty)
        let writes = await transport.writes, recoveryWrites = await nextTransport.writes
        XCTAssertEqual(writes.count, 1); XCTAssertTrue(recoveryWrites.isEmpty)
    }
    func test未知同名替换或原目标改名不能被认领() async throws {
        for replacement in [false, true] {
            let (model, _, _, root) = try make(mode: "containers-unknown"); await model.refresh()
            let id = try start(model); await model.waitForOperation(id)
            let (next, transport, _, _) = try make(mode: "containers-recover", root: root)
            if replacement { await transport.replaceFirst() } else { await transport.renameFirst() }
            await next.refresh(); XCTAssertEqual(next.entries.first?.items.first?.phase, .submitted)
            let target = try XCTUnwrap(next.targets.first)
            XCTAssertFalse(next.canPerform(ids: [target.id], action: .stop))
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test未提交恢复不会因为运行状态变化冒认完成() async throws {
        let (model, _, _, root) = try make(); await model.refresh()
        let target = try XCTUnwrap(model.targets.first), context = try XCTUnwrap(model.context)
        _ = try model.recovery.reserve([target], action: .start, context: context)
        let (next, transport, _, _) = try make(mode: "containers-recover", root: root); await next.refresh()
        XCTAssertEqual(next.entries.first?.items.first?.phase, .skipped)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test重启仅原运行状态不能完成且后续新时间可以恢复() async throws {
        let (model, transport, _, _) = try make(mode: "containers-running"); await model.refresh()
        await transport.setMode("containers-restart-unchanged")
        let id = try start(model, action: .restart); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.items.first?.phase, .submitted)
        await transport.apply(.restart); await model.refresh()
        XCTAssertEqual(model.entries.first?.items.first?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test批量第二项未知保留第一项结果并只读恢复() async throws {
        let (model, transport, _, root) = try make(mode: "containers-partial"); await model.refresh()
        let id = try start(model, ids: ["synthetic-id", "worker-b"]); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.items.map(\.phase), [.succeeded, .submitted])
        let (next, nextTransport, _, _) = try make(mode: "containers-recover", root: root); await next.refresh()
        XCTAssertEqual(next.entries.first?.completedCount, 2)
        let writes = await transport.writes, nextWrites = await nextTransport.writes
        XCTAssertEqual(writes.count, 2); XCTAssertTrue(nextWrites.isEmpty)
    }
    func test批量第一项拒绝后其余项不再提交() async throws {
        let (model, transport, _, _) = try make(mode: "containers-reject"); await model.refresh()
        let id = try start(model, ids: ["synthetic-id", "worker-b"]); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.items.map(\.phase), [.failed, .skipped])
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test同配置编号更换账号隔离旧确认与迟到回执() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await transport.holdWrites()
        let confirmation = try XCTUnwrap(model.confirmation(ids: ["synthetic-id", "worker-b"], action: .start))
        let originalContext = try XCTUnwrap(model.context), id = try XCTUnwrap(model.perform(confirmation))
        await transport.waitForWrite()
        let nextProfile = try profile(username: "other"), nextTransport = MobileContainerUITransport()
        model.configure(profile: nextProfile, repository: try repository(nextTransport, profile: nextProfile), authorize: { true })
        await model.refresh(); XCTAssertNotEqual(model.context, originalContext)
        XCTAssertNil(model.perform(confirmation)); XCTAssertTrue(model.entries.isEmpty)
        await transport.release(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries.isEmpty)
        let old = try XCTUnwrap(model.recovery.entry(id)); XCTAssertEqual(old.context, originalContext)
        XCTAssertEqual(old.items[1].phase, .skipped)
        let writes = await transport.writes, nextWrites = await nextTransport.writes
        XCTAssertEqual(writes.count, 1); XCTAssertTrue(nextWrites.isEmpty)
    }
    func test读取权限拒绝不解除旧未知记录() async throws {
        let (model, _, _, root) = try make(mode: "containers-unknown"); await model.refresh()
        let id = try start(model); await model.waitForOperation(id)
        let (next, transport, gate, _) = try make(mode: "containers-recover", root: root)
        await gate.set(false); await next.refresh()
        XCTAssertEqual(next.entries.first?.items.first?.phase, .submitted)
        let calls = await transport.calls; XCTAssertTrue(calls.isEmpty)
    }
    func test证书失败停止后续读取且保留未知保护() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        await transport.setMode("containers-write-trust")
        let id = try start(model); await model.waitForOperation(id)
        XCTAssertEqual(model.error, .trust); XCTAssertFalse(model.allowed)
        XCTAssertEqual(model.entries.first?.items.first?.phase, .submitted)
        let calls = await transport.calls; XCTAssertEqual(calls.count, 3)
    }
    func test记录损坏或无法保存时零提交() async throws {
        for corrupt in [false, true] {
            let root = newRoot()
            if corrupt {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("invalid".utf8).write(to: root.appendingPathComponent("container-controls-v1.json"))
            } else { try Data("file".utf8).write(to: root) }
            let (model, transport, _, _) = try make(root: root); await model.refresh()
            if let confirmation = model.confirmation(ids: ["synthetic-id"], action: .start) { XCTAssertNil(model.perform(confirmation)) }
            XCTAssertTrue(model.recovery.failed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test恢复文件不包含名称账号主机凭据或活动正文() async throws {
        let (model, _, _, root) = try make(); await model.refresh()
        let id = try start(model); await model.waitForOperation(id)
        let text = try String(contentsOf: root.appendingPathComponent("container-controls-v1.json"), encoding: .utf8)
        for value in ["synthetic-id", "Sample container", "fixture.example.invalid", "operator", "synthetic-session", "Sample user"] { XCTAssertFalse(text.contains(value)) }
        let resources = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]); XCTAssertEqual(resources.isExcludedFromBackup, true)
    }
    private func start(_ model: MobileContainerControlModel, ids: Set<String> = ["synthetic-id"], action: ContainerAction = .start) throws -> UUID {
        let confirmation = try XCTUnwrap(model.confirmation(ids: ids, action: action))
        return try XCTUnwrap(model.perform(confirmation))
    }
    private func newRoot() -> URL { let value = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerTests-\(UUID())"); roots.append(value); return value }
    private func profile(username: String = "operator") throws -> NasProfile {
        try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000022")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username)
    }
    private func repository(_ transport: MobileContainerUITransport, profile: NasProfile) throws -> DsmServiceManagementRepository {
        let names = [DsmAPIName.dockerContainer, DsmAPIName.dockerProject, DsmAPIName.dockerImage, DsmAPIName.dockerNetwork, DsmAPIName.dockerLog]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)) }))
        return try .init(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func make(mode: String = "containers-control", root: URL? = nil) throws -> (MobileContainerControlModel, MobileContainerUITransport, ContainerPermissionGate, URL) {
        let root = root ?? newRoot(), transport = MobileContainerUITransport(mode: mode), gate = ContainerPermissionGate(), profile = try profile()
        let model = MobileContainerControlModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { await gate.check() })
        return (model, transport, gate, root)
    }
}

private actor ContainerPermissionGate {
    private var allowed = true
    func set(_ value: Bool) { allowed = value }
    func check() -> Bool { allowed }
}
