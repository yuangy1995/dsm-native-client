import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileEthernetSettingsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    func test网卡保存只写一次且记录没有名称地址或账号() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.ethernet)
        let change = try change(model)
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded); XCTAssertTrue(model.canEdit(.ethernet))
        let contents = try String(contentsOf: root.appendingPathComponent("service-operations-v1.json"), encoding: .utf8)
        for value in ["192.0.2.10", "eth0", "LAN 1", "fixture", "synthetic", "password", "host"] { XCTAssertFalse(contents.contains(value), value) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test网卡未知结果重启仅读取同账号原目标() async throws {
        for mode in ["nas-services-unknown", "nas-services-accepted-offline"] {
            let (model, transport, root) = try makeModel(mode: mode); await model.refresh(.ethernet)
            let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(model.canEdit(.ethernet))
            model.removeRecord(id, kind: .ethernet); XCTAssertNotNil(model.recovery.entry(id)); model.deactivate()
            let (next, reader, _) = try makeModel(mode: "nas-services-ethernet-recover", root: root); await next.refresh(.ethernet)
            XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded); XCTAssertTrue(next.canEdit(.ethernet))
            let writes = await transport.writes, replayed = await reader.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(replayed.isEmpty)
        }
    }
    func test更换地址不会自动认领旧记录且必须明确读取() async throws {
        let (model, _, root) = try makeModel(mode: "nas-services-unknown"); await model.refresh(.ethernet)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        let oldContext = model.context; model.deactivate()
        let (next, transport, _) = try makeModel(mode: "nas-services-ethernet-recover", root: root, host: "new.example.invalid")
        await next.refresh(.ethernet)
        XCTAssertNotEqual(next.context, oldContext); XCTAssertEqual(next.entries(.ethernet).count, 1)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(next.canEdit(.ethernet))
        await next.readNetworkResult(id, activation: next.activation)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded); XCTAssertEqual(next.recovery.entry(id)?.context, oldContext)
        XCTAssertTrue(next.canEdit(.ethernet)); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        next.removeRecord(id, kind: .ethernet); XCTAssertNil(next.recovery.entry(id))
    }
    func test新地址配置不匹配保持未知且不允许移除保护() async throws {
        let (model, _, root) = try makeModel(mode: "nas-services-unknown"); await model.refresh(.ethernet)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        let (next, transport, _) = try makeModel(root: root, host: "new.example.invalid"); await next.refresh(.ethernet)
        await next.readNetworkResult(id, activation: next.activation)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(next.canEdit(.ethernet))
        next.removeRecord(id, kind: .ethernet); XCTAssertNotNil(next.recovery.entry(id)); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test不同账号或连接配置看不到也不能恢复旧操作() async throws {
        let (model, _, root) = try makeModel(mode: "nas-services-unknown"); await model.refresh(.ethernet)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        for otherProfile in [false, true] {
            let (next, transport, _) = try makeModel(mode: "nas-services-ethernet-recover", root: root, account: otherProfile ? "fixture" : "another", otherProfile: otherProfile)
            await next.refresh(.ethernet); XCTAssertTrue(next.entries(.ethernet).isEmpty)
            let before = await transport.requests.count; await next.readNetworkResult(id, activation: next.activation)
            let after = await transport.requests.count; XCTAssertEqual(after, before)
            XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); next.deactivate()
        }
    }
    func test网卡原快照变更和权限撤回均不发送保存() async throws {
        for denied in [false, true] {
            let gate = EthernetPermissionGate(), (model, transport, _) = try makeModel(gate: gate); await model.refresh(.ethernet)
            let change = try change(model)
            if denied { await gate.set(false) } else { await transport.setEthernetMTU(1300) }
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); XCTAssertEqual(model.recovery.entry(id)?.failure, denied ? .denied : .changed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test网卡拒绝不会因后来配置相同而变成保存成功() async throws {
        let (model, transport, _) = try makeModel(mode: "nas-services-denied"); await model.refresh(.ethernet)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed)
        await transport.setEthernetMTU(1400); await model.refresh(.ethernet)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test网卡重复点击与迟到回执不会影响新账号() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.ethernet); let change = try change(model)
        await transport.suspendWrites()
        let id = try XCTUnwrap(model.perform(change, activation: model.activation))
        for _ in 0..<2_000 { if await transport.writes.count == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(model.perform(change, activation: model.activation))
        let profile = try profile(account: "another"), next = MobileServiceUITransport()
        model.configure(profile: profile, repository: try repository(next, profile: profile), authorize: { true }); await model.refresh(.ethernet)
        await transport.resumeWrites(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries(.ethernet).isEmpty)
        let reopened = MobileServiceOperationStore(root: root)
        XCTAssertTrue(reopened.entry(id)?.parts.first?.accepted == true); XCTAssertEqual(reopened.entry(id)?.phase, .submitted)
        let writes = await transport.writes, otherWrites = await next.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(otherWrites.isEmpty)
    }
    func test网卡记录无法保存或损坏时禁止写入() async throws {
        let root = makeRoot(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("service-operations-v1.json"))
        let (model, transport, _) = try makeModel(root: root); await model.refresh(.ethernet)
        XCTAssertFalse(model.canEdit(.ethernet)); XCTAssertNil(model.perform(try change(model), activation: model.activation))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test网卡未提交记录重启不执行且旧确认已失效() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.ethernet); let change = try change(model), token = model.activation
        let id = try model.recovery.reserve(change, context: XCTUnwrap(model.context), networkOwner: model.networkOwner).id
        model.recovery.end(id); model.deactivate()
        let reopened = MobileServiceOperationStore(root: root); XCTAssertEqual(reopened.entry(id)?.phase, .cancelled)
        XCTAssertNil(model.perform(change, activation: token)); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test网卡不完整配置显示读取失败且不会出现可编辑默认值() async throws {
        let (model, transport, _) = try makeModel(mode: "nas-services-ethernet-incomplete"); await model.refresh(.ethernet)
        XCTAssertEqual(model.section(.ethernet).phase, .error); XCTAssertNil(model.section(.ethernet).value)
        XCTAssertFalse(model.canEdit(.ethernet)); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test网卡回读证书或权限失败停止后续请求且保留只读恢复() async throws {
        for (mode, failure) in [("nas-services-ethernet-trust-after-save", MobileServiceSettingsModel.Failure.trust), ("nas-services-ethernet-denied-after-save", .denied)] {
            let (model, transport, _) = try makeModel(mode: mode); await model.refresh(.ethernet)
            let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.errors[.ethernet], failure); XCTAssertFalse(model.canEdit(.ethernet))
            XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertTrue(model.recovery.entry(id)?.parts.first?.accepted == true)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 6); XCTAssertEqual(requests.last?["method"], "list")
            await transport.setMode("nas-services"); await model.refresh(.ethernet)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }
    func test网卡同次保存仅部分字段生效保持未知() async throws {
        let (model, transport, _) = try makeModel(mode: "nas-services-ethernet-partial"); await model.refresh(.ethernet)
        let original = try XCTUnwrap(model.section(.ethernet).value)
        guard case .ethernet(var values) = original else { return XCTFail() }
        values[0].mtu = 1400; values[0].isDefaultGateway = false
        let id = try XCTUnwrap(model.perform(.init(original: original, desired: .ethernet(values)), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertTrue(model.recovery.entry(id)?.hasSavedChanges == true)
        XCTAssertFalse(model.canEdit(.ethernet)); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test网卡保存前记录写入失败零提交() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.ethernet)
        try Data("occupied".utf8).write(to: root)
        XCTAssertNil(model.perform(try change(model), activation: model.activation)); XCTAssertEqual(model.errors[.ethernet], .storage)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test新地址恢复时撤回权限和过期确认均零读取() async throws {
        let (model, _, root) = try makeModel(mode: "nas-services-unknown"); await model.refresh(.ethernet)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        let token = model.activation; model.deactivate()
        let gate = EthernetPermissionGate(), (next, transport, _) = try makeModel(mode: "nas-services-ethernet-recover", root: root, host: "new.example.invalid", gate: gate)
        await next.refresh(.ethernet); let count = await transport.requests.count
        await next.readNetworkResult(id, activation: token)
        await gate.set(false); await next.readNetworkResult(id, activation: next.activation)
        XCTAssertEqual(next.errors[.ethernet], .denied); XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted)
        let after = await transport.requests.count; XCTAssertEqual(after, count)
    }
    private func change(_ model: MobileServiceSettingsModel) throws -> NasServiceChange {
        let original = try XCTUnwrap(model.section(.ethernet).value)
        guard case .ethernet(var values) = original else { throw FixtureError.invalid }
        values[0].mtu = 1400; return .init(original: original, desired: .ethernet(values))
    }
    private func makeRoot() -> URL { let value = FileManager.default.temporaryDirectory.appendingPathComponent("MobileEthernetTests-\(UUID())"); roots.append(value); return value }
    private func profile(host: String = "fixture.example.invalid", account: String = "fixture", other: Bool = false) throws -> NasProfile {
        try .init(id: UUID(uuidString: other ? "00000000-0000-4000-8000-000000000011" : "00000000-0000-4000-8000-000000000010")!, displayName: "Synthetic", host: host, port: 5001, usernameHint: account)
    }
    private func repository(_ transport: MobileServiceUITransport, profile: NasProfile) throws -> DsmNasAdministrationRepository {
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: MobileServiceUITransport.versions.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: $1, requestFormat: .form, selectedVersion: $1)) }))
        return try .init(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func makeModel(mode: String = "nas-services", root: URL? = nil, host: String = "fixture.example.invalid", account: String = "fixture", otherProfile: Bool = false, gate: EthernetPermissionGate = .init()) throws -> (MobileServiceSettingsModel, MobileServiceUITransport, URL) {
        let root = root ?? makeRoot(), transport = MobileServiceUITransport(mode: mode), profile = try profile(host: host, account: account, other: otherProfile)
        let model = MobileServiceSettingsModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { await gate.allowed })
        return (model, transport, root)
    }
}
private enum FixtureError: Error { case invalid }
private actor EthernetPermissionGate { var allowed = true; func set(_ value: Bool) { allowed = value } }
