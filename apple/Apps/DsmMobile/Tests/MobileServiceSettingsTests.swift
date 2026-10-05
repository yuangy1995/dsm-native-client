import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileServiceSettingsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    func test三类设置读编辑保存与真实回读() async throws {
        let (model, transport, _, _) = try makeModel()
        for kind in NasServiceKind.allCases {
            await model.refresh(kind); XCTAssertTrue(model.canEdit(kind))
            let change = try change(model, kind)
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
            XCTAssertEqual(model.section(kind).value?.fields(for: change.changedSteps[0]), change.desired.fields(for: change.changedSteps[0]))
            XCTAssertFalse(model.isOperating); XCTAssertTrue(model.canEdit(kind))
        }
        let writes = await transport.writes; XCTAssertEqual(writes.count, 3)
    }
    func test缺失字段保留不能猜值开启() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-services-missing")
        await model.refresh(.terminal)
        guard case .terminal(var draft)? = model.section(.terminal).value else { return XCTFail() }
        XCTAssertNil(draft.sshPort); draft.isSSHEnabled = true
        let original = try XCTUnwrap(model.section(.terminal).value)
        let id = try XCTUnwrap(model.perform(.init(original: original, desired: .terminal(draft)), activation: model.activation))
        await model.waitForOperation(id); XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertNil(writes[0]["ssh_port"])
        await model.refresh(.fileServices)
        guard case .fileServices(var files)? = model.section(.fileServices).value else { return XCTFail() }
        XCTAssertNil(files.isFTPSEnabled); files.isFTPSEnabled = true
        XCTAssertFalse(model.canPerform(.init(original: try XCTUnwrap(model.section(.fileServices).value), desired: .fileServices(files))))
    }
    func test原值变化和保存前撤销权限均零写() async throws {
        for denied in [false, true] {
            let (model, transport, gate, _) = try makeModel(); await model.refresh(.terminal)
            let change = try change(model, .terminal)
            if denied { await gate.set(false) } else { await transport.changeOriginal() }
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); XCTAssertEqual(model.recovery.entry(id)?.failure, denied ? .denied : .changed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test逐组重新检查权限并保留前一组结果() async throws {
        let (model, transport, gate, _) = try makeModel(); await model.refresh(.fileServices)
        await gate.denyAfterNext()
        let id = try XCTUnwrap(model.perform(try multiChange(model), activation: model.activation)); await model.waitForOperation(id)
        let entry = try XCTUnwrap(model.recovery.entry(id)); XCTAssertEqual(entry.phase, .partial)
        XCTAssertEqual(entry.parts.map(\.stage), [.verified, .skipped]); XCTAssertEqual(entry.failure, .denied)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test第二组明确拒绝允许新的明确编辑而不重放前组() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-services-partial"); await model.refresh(.fileServices)
        let id = try XCTUnwrap(model.perform(try multiChange(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .partial); XCTAssertEqual(model.recovery.entry(id)?.parts.map(\.stage), [.verified, .rejected])
        XCTAssertTrue(model.canEdit(.fileServices)); XCTAssertEqual(model.recovery.entry(id)?.failure, .denied)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }
    func test单次写部分字段生效仍保持保护() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-services-partial-terminal"); await model.refresh(.terminal)
        let original = try XCTUnwrap(model.section(.terminal).value)
        let change = NasServiceChange(original: original, desired: .terminal(.init(isSSHEnabled: true, isTelnetEnabled: true, sshPort: 2222)))
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertTrue(model.recovery.entry(id)?.hasSavedChanges == true)
        XCTAssertFalse(model.canEdit(.terminal)); model.removeRecord(id, kind: .terminal); XCTAssertNotNil(model.recovery.entry(id))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test未知保存重启只读恢复不重复发送() async throws {
        for accepted in [false, true] {
            let (model, transport, _, root) = try makeModel(mode: accepted ? "nas-services-accepted-offline" : "nas-services-unknown")
            await model.refresh(.terminal)
            let id = try XCTUnwrap(model.perform(try change(model, .terminal), activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertEqual(model.recovery.entry(id)?.parts[0].accepted, accepted)
            model.deactivate()
            let (reopened, next, _, _) = try makeModel(mode: "nas-services-recover", root: root); await reopened.refresh(.terminal)
            XCTAssertEqual(reopened.recovery.entry(id)?.phase, .succeeded); XCTAssertTrue(reopened.canEdit(.terminal))
            let writes = await transport.writes, replayed = await next.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(replayed.isEmpty)
        }
    }
    func test恢复不能把从未提交的后组认领成功() async throws {
        let (model, _, _, root) = try makeModel(); await model.refresh(.fileServices)
        let change = try multiChange(model), context = try XCTUnwrap(model.context), store = model.recovery
        let id = try store.reserve(change, context: context).id
        try store.checkpoint(id, .willSubmit(.smb)); store.end(id)
        let reopened = MobileServiceOperationStore(root: root)
        try reopened.resolve(change.desired, context: context)
        XCTAssertEqual(reopened.entry(id)?.phase, .partial); XCTAssertEqual(reopened.entry(id)?.parts.map(\.stage), [.verified, .skipped])
    }
    func test重复保存与跨类别在途互斥且记录不包含敏感正文() async throws {
        let (model, transport, _, root) = try makeModel(); await model.refresh(.proxy); await model.refresh(.terminal)
        let change = try change(model, .proxy)
        await transport.suspendWrites()
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await wait { model.recovery.entry(id)?.phase == .submitted }
        XCTAssertNil(model.perform(change, activation: model.activation)); XCTAssertFalse(model.canEdit(.terminal))
        let url = root.appendingPathComponent("service-operations-v1.json"), contents = try String(contentsOf: url, encoding: .utf8)
        for word in ["proxy.example.invalid", "fixture.example.invalid", "synthetic", "password", "synoToken"] { XCTAssertFalse(contents.contains(word), word) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        await transport.resumeWrites(); await model.waitForOperation(id)
    }
    func test损坏和无法保存记录均不提交() async throws {
        for corrupt in [true, false] {
            let root = makeRoot()
            if corrupt { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try Data("bad-record".utf8).write(to: root.appendingPathComponent("service-operations-v1.json")) }
            else { try Data("blocked-directory".utf8).write(to: root) }
            let (model, transport, _, _) = try makeModel(root: root); await model.refresh(.terminal)
            XCTAssertNil(model.perform(try change(model, .terminal), activation: model.activation))
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test准备阶段重启取消且记录只能在完成后移除() async throws {
        let (model, _, _, root) = try makeModel(); await model.refresh(.terminal)
        let id = try model.recovery.reserve(try change(model, .terminal), context: try XCTUnwrap(model.context)).id; model.recovery.end(id)
        let reopened = MobileServiceOperationStore(root: root); XCTAssertEqual(reopened.entry(id)?.phase, .cancelled)
        try reopened.remove(id, context: try XCTUnwrap(model.context)); XCTAssertNil(reopened.entry(id))
    }
    func test重复组畸形摘要和跨类别记录不能加载() async throws {
        for mode in ["duplicate", "digest", "kind"] {
            let (model, _, _, root) = try makeModel(); await model.refresh(.terminal)
            let id = try model.recovery.reserve(try change(model, .terminal), context: try XCTUnwrap(model.context)).id; model.recovery.end(id)
            let url = root.appendingPathComponent("service-operations-v1.json")
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var entries = try XCTUnwrap(envelope["entries"] as? [[String: Any]]), parts = try XCTUnwrap(entries[0]["parts"] as? [[String: Any]])
            switch mode { case "duplicate": parts.append(parts[0]); case "digest": parts[0]["expected"] = "not-a-digest"; default: parts[0]["step"] = "proxy" }
            entries[0]["parts"] = parts; envelope["entries"] = entries
            try JSONSerialization.data(withJSONObject: envelope).write(to: url)
            XCTAssertTrue(MobileServiceOperationStore(root: root).failed)
        }
    }
    func test同配置重连使旧确认失效() async throws {
        let (model, _, _, _) = try makeModel(); await model.refresh(.terminal)
        let change = try change(model, .terminal), token = model.activation, next = MobileServiceUITransport(), profile = try profile()
        model.configure(profile: profile, repository: try repository(next, profile: profile), authorize: { true }); await model.refresh(.terminal)
        XCTAssertNil(model.perform(change, activation: token)); let writes = await next.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test跨账号迟到回执仍属于原记录() async throws {
        let (model, transport, _, root) = try makeModel(); await model.refresh(.terminal)
        await transport.suspendWrites()
        let id = try XCTUnwrap(model.perform(try change(model, .terminal), activation: model.activation))
        await wait { model.recovery.entry(id)?.phase == .submitted }
        let next = MobileServiceUITransport(), profile = try profile(username: "another")
        model.configure(profile: profile, repository: try repository(next, profile: profile), authorize: { true })
        await model.refresh(.terminal); await transport.resumeWrites(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries(.terminal).isEmpty)
        XCTAssertEqual(model.section(.terminal).value, .terminal(.init(isSSHEnabled: false, isTelnetEnabled: false, sshPort: 22)))
        XCTAssertTrue(MobileServiceOperationStore(root: root).entry(id)?.parts[0].accepted == true)
        let writes = await next.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test无权限只读错误与空值不混淆() async throws {
        let (model, _, gate, _) = try makeModel(); await gate.set(false); await model.refresh(.terminal)
        XCTAssertNotNil(model.section(.terminal).value); XCTAssertFalse(model.canEdit(.terminal)); XCTAssertEqual(model.errors[.terminal], .denied)
        for (mode, kind, phase) in [("nas-services-empty", NasServiceKind.fileServices, MobileNasDetailsPhase.empty), ("nas-services-error", .terminal, .error), ("nas-services-malformed", .terminal, .error)] {
            let (model, _, _, _) = try makeModel(mode: mode); await model.refresh(kind)
            XCTAssertEqual(model.section(kind).phase, phase); XCTAssertFalse(model.canEdit(kind))
        }
    }
    func test明确拒绝即使后来字段相同也保持失败() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-services-denied"); await model.refresh(.terminal)
        let id = try XCTUnwrap(model.perform(try change(model, .terminal), activation: model.activation)); await model.waitForOperation(id)
        await transport.setTerminal(enabled: true); await model.refresh(.terminal)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); XCTAssertEqual(model.recovery.entry(id)?.failure, .denied)
    }
    func test结果未知只保护所属类别而不阻断独立代理页() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-services-unknown"); await model.refresh(.terminal)
        let id = try XCTUnwrap(model.perform(try change(model, .terminal), activation: model.activation)); await model.waitForOperation(id)
        await transport.setMode("nas-services"); await transport.setTerminal(enabled: false); await model.refresh(.terminal); await model.refresh(.proxy)
        XCTAssertFalse(model.canEdit(.terminal)); XCTAssertTrue(model.canEdit(.proxy))
    }
    private func change(_ model: MobileServiceSettingsModel, _ kind: NasServiceKind) throws -> NasServiceChange {
        let original = try XCTUnwrap(model.section(kind).value), desired: NasServiceSettings
        switch original {
        case .fileServices(var value): value.isSMBEnabled = true; desired = .fileServices(value)
        case .terminal(var value): value.isSSHEnabled = true; desired = .terminal(value)
        case .proxy(var value): value.isEnabled = true; desired = .proxy(value)
        }
        return .init(original: original, desired: desired)
    }
    private func multiChange(_ model: MobileServiceSettingsModel) throws -> NasServiceChange {
        let original = try XCTUnwrap(model.section(.fileServices).value)
        guard case .fileServices(var value) = original else { XCTFail("测试输入类型错误"); throw ServiceTestError.invalidFixture }
        value.isSMBEnabled = true; value.isNFSEnabled = true
        return .init(original: original, desired: .fileServices(value))
    }
    private func makeRoot() -> URL { let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileServiceTests-\(UUID())"); roots.append(root); return root }
    private func profile(username: String = "fixture") throws -> NasProfile { try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username) }
    private func repository(_ transport: MobileServiceUITransport, profile: NasProfile) throws -> DsmNasAdministrationRepository {
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: MobileServiceUITransport.versions.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: $1, requestFormat: .form, selectedVersion: $1)) }))
        return try .init(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func makeModel(mode: String = "nas-services", root: URL? = nil) throws -> (MobileServiceSettingsModel, MobileServiceUITransport, ServicePermissionGate, URL) {
        let root = root ?? makeRoot(), transport = MobileServiceUITransport(mode: mode), gate = ServicePermissionGate(), profile = try profile(), model = MobileServiceSettingsModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { await gate.check() }); return (model, transport, gate, root)
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
private enum ServiceTestError: Error { case invalidFixture }
private actor ServicePermissionGate {
    private var allowed = true
    private var remaining: Int?
    func set(_ value: Bool) { allowed = value }
    func denyAfterNext() { remaining = 1 }
    func check() -> Bool { if let remaining { self.remaining = remaining - 1; return allowed && remaining > 0 }; return allowed }
}
