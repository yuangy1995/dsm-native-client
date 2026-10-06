import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileHardwareSettingsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    func test硬件七个保存边界和恢复记录不包含地址或配置正文() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.hardware)
        let change = try change(model, all: true), id = try XCTUnwrap(model.perform(change, activation: model.activation))
        await model.waitForOperation(id)
        let entry = try XCTUnwrap(model.recovery.entry(id))
        XCTAssertEqual(entry.phase, .succeeded); XCTAssertEqual(entry.parts.count, 7)
        XCTAssertTrue(entry.parts.allSatisfy { $0.stage == .verified && $0.accepted }); XCTAssertTrue(model.canEdit(.hardware))
        let contents = try String(contentsOf: root.appendingPathComponent("service-operations-v1.json"), encoding: .utf8)
        for value in ["192.0.2.20", "fixture.example.invalid", "operator", "synthetic-session", "coolfan", "SLAVE"] { XCTAssertFalse(contents.contains(value)) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 7)
        XCTAssertEqual(writes.map { $0["method"] }, ["set", "set_current_brightness", "update", "set", "set", "set", "set"])
    }
    func test硬件未知普通设置重启只读取结果且不重放() async throws {
        let (model, transport, root) = try makeModel(mode: "nas-services-unknown"); await model.refresh(.hardware)
        let id = try XCTUnwrap(model.perform(try change(model, led: false), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); model.deactivate()
        let (next, reader, _) = try makeModel(root: root); await reader.setHardwarePowerRecovery(true); await next.refresh(.hardware)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.writes, replays = await reader.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(replays.isEmpty)
    }
    func test灯光首步缺回执重启匹配暂存值也不能继续或移除保护() async throws {
        let (model, transport, root) = try makeModel(mode: "nas-services-lost-ack"); await model.refresh(.hardware)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.parts.map(\.stage), [.submitted, .skipped]); model.deactivate()
        let (next, reader, _) = try makeModel(mode: "nas-services-hardware-led-recover", root: root); await next.refresh(.hardware)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(next.canEdit(.hardware)); XCTAssertNil(next.ledContinuation())
        next.removeRecord(id, kind: .hardware); XCTAssertNotNil(next.recovery.entry(id))
        let writes = await transport.writes, replays = await reader.writes
        XCTAssertEqual(writes.map { $0["method"] }, ["set_current_brightness"]); XCTAssertTrue(replays.isEmpty)
    }
    func test灯光应用缺回执保留已保存部分且重启不冒认实际应用() async throws {
        let (model, transport, root) = try makeModel(mode: "nas-services-hardware-led-update-unknown"); await model.refresh(.hardware)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.parts.map(\.stage), [.verified, .submitted]); model.deactivate()
        let (next, reader, _) = try makeModel(mode: "nas-services-hardware-led-recover", root: root); await next.refresh(.hardware)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); XCTAssertNil(next.ledContinuation()); XCTAssertFalse(next.canEdit(.hardware))
        await next.refresh(.terminal); XCTAssertTrue(next.canEdit(.terminal))
        let writes = await transport.writes, replays = await reader.writes
        XCTAssertEqual(writes.map { $0["method"] }, ["set_current_brightness", "update"]); XCTAssertTrue(replays.isEmpty)
    }
    func test灯光接受后回读断线重启恢复首步但必须主动应用() async throws {
        let (model, transport, root) = try makeModel(mode: "nas-services-accepted-offline"); await model.refresh(.hardware)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertTrue(model.recovery.entry(id)?.parts.first?.accepted == true); model.deactivate()
        let (next, reader, _) = try makeModel(mode: "nas-services-hardware-led-recover", root: root); await next.refresh(.hardware)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .partial)
        let before = await reader.writes; XCTAssertTrue(before.isEmpty)
        let continuation = try XCTUnwrap(next.ledContinuation()), nextID = try XCTUnwrap(next.perform(continuation, activation: next.activation))
        await next.waitForOperation(nextID)
        XCTAssertEqual(next.recovery.entry(nextID)?.phase, .succeeded); XCTAssertNil(next.ledContinuation())
        let writes = await transport.writes, replays = await reader.writes
        XCTAssertEqual(writes.map { $0["method"] }, ["set_current_brightness"]); XCTAssertEqual(replays.map { $0["method"] }, ["update"])
    }
    func test灯光应用明确拒绝不会因回读相同变成功且其他保存后仍可继续() async throws {
        let (model, transport, _) = try makeModel(mode: "nas-services-hardware-led-denied-once"); await model.refresh(.hardware)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.parts.map(\.stage), [.verified, .rejected]); XCTAssertEqual(model.recovery.entry(id)?.phase, .partial)
        let unrelated = try XCTUnwrap(model.perform(try change(model, led: false), activation: model.activation)); await model.waitForOperation(unrelated)
        let continuation = try XCTUnwrap(model.ledContinuation()), next = try XCTUnwrap(model.perform(continuation, activation: model.activation)); await model.waitForOperation(next)
        XCTAssertEqual(model.recovery.entry(next)?.phase, .succeeded); XCTAssertEqual(model.recovery.entry(id)?.parts.last?.stage, .rejected)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["set_current_brightness", "update", "set", "update"])
    }
    func test灯光继续绑定原亮度和原账号且不存在记录时不可伪造() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.hardware)
        let original = try XCTUnwrap(model.section(.hardware).value)
        XCTAssertFalse(model.canPerform(.init(original: original, desired: original, appliesSavedLEDBrightness: true)))
        await transport.setMode("nas-services-hardware-led-denied-once")
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertNotNil(model.ledContinuation()); await transport.setLEDBrightness(6); await model.refresh(.hardware); XCTAssertNil(model.ledContinuation())
        let (other, _, _) = try makeModel(mode: "nas-services-hardware-led-recover", root: root, account: "another"); await other.refresh(.hardware)
        XCTAssertTrue(other.entries(.hardware).isEmpty); XCTAssertNil(other.ledContinuation())
    }
    func test灯光未提交记录重启不自动应用且不允许伪造完成() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.hardware)
        let change = try change(model), context = try XCTUnwrap(model.context)
        let id = try model.recovery.reserve(change, context: context).id
        try model.recovery.checkpoint(id, .willSubmit(.ledBrightness))
        XCTAssertThrowsError(try model.recovery.checkpoint(id, .verified(.ledBrightness)))
        XCTAssertEqual(model.recovery.entry(id)?.parts.first?.stage, .submitted)
        model.recovery.end(id); model.deactivate()
        let store = MobileServiceOperationStore(root: root); XCTAssertEqual(store.entry(id)?.parts.map(\.stage), [.submitted, .skipped])
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test硬件记录无法保存和畸形字段均零写() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.hardware)
        try Data("occupied".utf8).write(to: root)
        XCTAssertNil(model.perform(try change(model), activation: model.activation)); XCTAssertEqual(model.errors[.hardware], .storage)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        let (incomplete, reader, _) = try makeModel(mode: "nas-services-hardware-incomplete"); await incomplete.refresh(.hardware)
        XCTAssertEqual(incomplete.section(.hardware).phase, .error); XCTAssertFalse(incomplete.canEdit(.hardware))
        let replays = await reader.writes; XCTAssertTrue(replays.isEmpty)
    }
    func test硬件权限撤回停止后续灯光应用并保留完成的亮度() async throws {
        let gate = HardwarePermissionGate(denyAt: 3), (model, transport, _) = try makeModel(gate: gate); await model.refresh(.hardware)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.parts.map(\.stage), [.verified, .skipped]); XCTAssertEqual(model.errors[.hardware], .denied)
        XCTAssertFalse(model.canEdit(.hardware)); let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["set_current_brightness"])
    }
    func test硬件写后认证和证书失败停止读取且恢复不会补发应用() async throws {
        for (mode, expected) in [("nas-services-hardware-denied-after-save", MobileServiceSettingsModel.Failure.denied), ("nas-services-hardware-trust-after-save", .trust)] {
            let (model, transport, _) = try makeModel(mode: mode); await model.refresh(.hardware)
            let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.errors[.hardware], expected); XCTAssertFalse(model.canEdit(.hardware))
            let before = await transport.requests; XCTAssertEqual(before.last?["api"], DsmAPIName.coreHardwarePowerRecovery)
            await transport.setMode("nas-services"); await model.refresh(.hardware)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .partial); XCTAssertNotNil(model.ledContinuation())
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }
    func test硬件重复点击与迟到回执保持原账号隔离() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.hardware); let change = try change(model)
        await transport.suspendWrites(); let token = model.activation, id = try XCTUnwrap(model.perform(change, activation: token))
        for _ in 0..<2000 { if await transport.writes.count == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(model.perform(change, activation: token)); model.deactivate()
        let (next, reader, _) = try makeModel(root: root, account: "another"); await next.refresh(.hardware)
        await transport.resumeWrites(); await model.waitForOperation(id)
        XCTAssertNil(model.perform(change, activation: token)); XCTAssertTrue(next.entries(.hardware).isEmpty)
        let store = MobileServiceOperationStore(root: root); XCTAssertTrue(store.entry(id)?.parts.first?.accepted == true)
        XCTAssertEqual(store.entry(id)?.parts.map(\.stage), [.submitted, .skipped])
        let writes = await transport.writes, replays = await reader.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(replays.isEmpty)
    }
    func test硬件已知字段可编辑而缺少字段保持只读() async throws {
        let (model, transport, _) = try makeModel(mode: "nas-services-hardware-limited"); await model.refresh(.hardware)
        XCTAssertTrue(model.canEdit(.hardware))
        XCTAssertFalse(model.canPerform(try change(model)))
        let id = try XCTUnwrap(model.perform(try change(model, led: false), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    private func change(_ model: MobileServiceSettingsModel, led: Bool = true, all: Bool = false) throws -> NasServiceChange {
        let original = try XCTUnwrap(model.section(.hardware).value)
        guard case .hardware(var value) = original else { throw HardwareTestError.invalid }
        if led { value.ledBrightness = 5 }
        if !led || all { value.restartsAfterPowerFailure = true }
        if all {
            value.fanMode = "coolfan"; value.isVolumeFailureAlertEnabled = false; value.isWakeUpLogEnabled = true
            value.ups?.isEnabled = true; value.ups?.mode = "SLAVE"; value.ups?.networkServerAddress = "192.0.2.20"
        }
        return .init(original: original, desired: .hardware(value))
    }
    private func makeModel(mode: String = "nas-services", root: URL? = nil, account: String = "operator", gate: HardwarePermissionGate = .init()) throws -> (MobileServiceSettingsModel, MobileServiceUITransport, URL) {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileHardwareTests-\(UUID())")
        if !roots.contains(root) { roots.append(root) }
        let transport = MobileServiceUITransport(mode: mode), model = MobileServiceSettingsModel(root: root)
        let profile = try NasProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: account)
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: MobileServiceUITransport.versions.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: $1, requestFormat: .form, selectedVersion: $1)) }))
        let repository = try DsmNasAdministrationRepository(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        model.configure(profile: profile, repository: repository, authorize: { await gate.check() })
        return (model, transport, root)
    }
}
private enum HardwareTestError: Error { case invalid }
private actor HardwarePermissionGate {
    private var calls = 0
    let denyAt: Int?
    init(denyAt: Int? = nil) { self.denyAt = denyAt }
    func check() -> Bool { calls += 1; return denyAt.map { calls < $0 } ?? true }
}
