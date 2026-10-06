import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileContainerNetworkTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = roots; roots = []; return values }
        for value in values { try? FileManager.default.removeItem(at: value) }
        try await super.tearDown()
    }
    func test创建默认与手动配置完整参数且不用额外勾选() async throws {
        for manual in [false, true] {
            let (model, transport, _, _) = try make(); await model.refresh()
            var value = ContainerNetworkCreation(name: "sample-new")
            if manual {
                value.usesManualIPv4 = true; value.subnet = "192.0.2.0/24"; value.ipRange = "192.0.2.128/25"; value.gateway = "192.0.2.1"
                value.isIPv6Enabled = true; value.ipv6Subnet = "2001:db8::/64"; value.ipv6Gateway = "2001:db8::1"; value.disableMasquerade = true
            }
            XCTAssertTrue(model.create(value, activation: model.activation)); await model.waitForOperation()
            XCTAssertEqual(model.entries.first?.phase, .succeeded); XCTAssertTrue(model.targets.contains { $0.name == "sample-new" })
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertNil(writes[0]["driver"])
            XCTAssertEqual(writes[0]["enable_ipv6"], String(manual)); XCTAssertEqual(writes[0]["disable_masquerade"], String(manual))
            XCTAssertEqual(writes[0]["subnet"], manual ? value.subnet : nil)
            XCTAssertEqual(writes[0]["ipv6_gateway"], manual ? value.ipv6Gateway : nil)
        }
    }
    func test名称冲突无效地址默认网络与占用网络均零写() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        var value = ContainerNetworkCreation(name: "new"); value.usesManualIPv4 = true
        for value in [value, .init(name: "sample-a"), .init(name: "invalid name")] { XCTAssertFalse(model.create(value, activation: model.activation)) }
        for id in ["default", "used"] { XCTAssertNil(model.confirmation(ids: [id])) }
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test取消确认零写及确认后逐个删除保留默认网络() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        _ = try XCTUnwrap(model.confirmation(ids: ["a", "b"]))
        let before = await transport.writes; XCTAssertTrue(before.isEmpty)
        XCTAssertTrue(model.delete(try XCTUnwrap(model.confirmation(ids: ["a", "b"])))); await model.waitForOperation()
        XCTAssertEqual(model.entries.map(\.phase), [.succeeded, .succeeded])
        XCTAssertEqual(Set(model.targets.map(\.id)), ["default", "used"])
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
        for entry in model.entries { model.removeRecord(entry.id) }; XCTAssertTrue(model.entries.isEmpty)
    }
    func test批量第二项拒绝保留首项成功且后项不发送() async throws {
        let (model, transport, _, _) = try make(mode: "containers-networks-partial")
        await transport.add("sample-c"); await model.refresh()
        XCTAssertTrue(model.delete(try XCTUnwrap(model.confirmation(ids: ["a", "b", "added"])))); await model.waitForOperation()
        XCTAssertEqual(model.entries.reversed().map(\.phase), [.succeeded, .rejected, .skipped])
        XCTAssertFalse(model.entries.last!.denied)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }
    func test创建拒绝在外部同名出现后仍然失败() async throws {
        let (model, transport, _, _) = try make(mode: "containers-networks-denied"); await model.refresh()
        XCTAssertTrue(model.create(.init(name: "sample-new"), activation: model.activation)); await model.waitForOperation()
        XCTAssertEqual(model.entries.first?.phase, .rejected); XCTAssertEqual(model.error, .denied)
        await transport.add("sample-new"); await transport.setMode("containers-networks"); await model.refresh()
        XCTAssertEqual(model.entries.first?.phase, .rejected); XCTAssertFalse(model.canCreate(.init(name: "sample-new")))
    }
    func test删除拒绝后外部删除不能改判成功() async throws {
        let (model, transport, _, _) = try make(mode: "containers-networks-denied"); await model.refresh()
        XCTAssertTrue(model.delete(try XCTUnwrap(model.confirmation(ids: ["a"])))); await model.waitForOperation()
        await transport.remove("a"); await transport.setMode("containers-networks"); await model.refresh()
        XCTAssertEqual(model.entries.first?.phase, .rejected)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test确认后身份替换停止且不提交() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        let value = try XCTUnwrap(model.confirmation(ids: ["a"]))
        await transport.replace("a")
        XCTAssertTrue(model.delete(value)); await model.waitForOperation()
        XCTAssertEqual(model.entries.first?.phase, .skipped); XCTAssertEqual(model.error, .changed)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test创建无回执重启只读且找到同名不宣称创建成功() async throws {
        let (model, transport, _, root) = try make(mode: "containers-networks-unknown"); await model.refresh()
        let value = ContainerNetworkCreation(name: "sample-new")
        XCTAssertTrue(model.create(value, activation: model.activation)); await model.waitForOperation()
        XCTAssertEqual(model.entries.first?.phase, .submitted); XCTAssertFalse(model.canCreate(value))
        let (restored, readTransport, _, _) = try make(root: root); await restored.refresh()
        XCTAssertEqual(restored.entries.first?.phase, .submitted); XCTAssertFalse(restored.canCreate(value))
        await readTransport.add("sample-new"); await restored.refresh()
        XCTAssertEqual(restored.entries.first?.phase, .existing)
        let originalWrites = await transport.writes, laterWrites = await readTransport.writes
        XCTAssertEqual(originalWrites.count, 1); XCTAssertTrue(laterWrites.isEmpty)
    }
    func test删除无回执重启继续保护直到原身份消失并不宣称本次成功() async throws {
        let (model, _, _, root) = try make(mode: "containers-networks-unknown"); await model.refresh()
        XCTAssertTrue(model.delete(try XCTUnwrap(model.confirmation(ids: ["a"])))); await model.waitForOperation()
        let (restored, transport, _, _) = try make(root: root); await restored.refresh()
        XCTAssertEqual(restored.entries.first?.phase, .submitted); XCTAssertFalse(restored.canDelete(ids: ["a"]))
        let protected = try XCTUnwrap(restored.entries.first)
        XCTAssertThrowsError(try restored.recovery.remove(protected.id, context: try XCTUnwrap(restored.context)))
        await transport.replace("a"); await restored.refresh()
        XCTAssertEqual(restored.entries.first?.phase, .absent); XCTAssertTrue(restored.targets.contains { $0.id == "replacement" })
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test接受回执后回读断网重启完成而不重新写入() async throws {
        for creating in [true, false] {
            let (model, _, _, root) = try make(mode: "containers-networks-offline"); await model.refresh()
            if creating { XCTAssertTrue(model.create(.init(name: "sample-new"), activation: model.activation)) }
            else { XCTAssertTrue(model.delete(try XCTUnwrap(model.confirmation(ids: ["a"])) )) }
            await model.waitForOperation(); XCTAssertEqual(model.entries.first?.phase, .submitted); XCTAssertTrue(model.entries[0].accepted)
            let (restored, transport, _, _) = try make(mode: creating ? "containers-networks-created" : "containers-networks-recovered", root: root)
            await restored.refresh(); XCTAssertEqual(restored.entries.first?.phase, .succeeded)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test未知删除重启后原ID改名仍然不能再次提交() async throws {
        let (model, _, _, root) = try make(mode: "containers-networks-unknown"); await model.refresh()
        XCTAssertTrue(model.delete(try XCTUnwrap(model.confirmation(ids: ["a"])))); await model.waitForOperation()
        let (restored, transport, _, _) = try make(root: root)
        await transport.rename("a"); await restored.refresh()
        XCTAssertEqual(restored.entries.first?.phase, .submitted)
        XCTAssertFalse(restored.canDelete(ids: ["a"])); XCTAssertNil(restored.confirmation(ids: ["a"]))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test提交前与最后权限撤销零写() async throws {
        for checks in [0, 1] {
            let (model, transport, gate, _) = try make(); await model.refresh()
            await gate.allow(checks)
            XCTAssertTrue(model.create(.init(name: "sample-new"), activation: model.activation)); await model.waitForOperation()
            XCTAssertEqual(model.entries.first?.phase, .skipped); XCTAssertEqual(model.error, .denied)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test存储损坏和丢失未完成记录均保留保护() async throws {
        let (model, transport, _, root) = try make(mode: "containers-networks-unknown"); await model.refresh()
        XCTAssertTrue(model.create(.init(name: "sample-new"), activation: model.activation)); await model.waitForOperation()
        try FileManager.default.removeItem(at: root.appendingPathComponent("network-operations-v1.json"))
        await model.refresh(); XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.error, .storage)
        XCTAssertFalse(model.canCreate(.init(name: "sample-other")))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        let damaged = newRoot(); try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: damaged.appendingPathComponent("network-operations-v1.json"))
        let (restored, _, _, _) = try make(root: damaged); await restored.refresh()
        XCTAssertTrue(restored.recovery.failed); XCTAssertFalse(restored.canOpenCreation)
    }
    func test首次保存失败零写与仅准备记录重启不续跑() async throws {
        let (model, transport, _, root) = try make(); await model.refresh()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("network-operations-v1.json"), withIntermediateDirectories: true)
        XCTAssertFalse(model.create(.init(name: "sample-new"), activation: model.activation))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        let other = newRoot(), store = MobileContainerNetworkStore(root: other)
        let context = MobileWorkspaceIdentity(try profile()).storageIdentifier
        let entry = try XCTUnwrap(store.reserve(context: context, creation: .init(name: "sample-new")).first)
        store.end([entry.id]); let restored = MobileContainerNetworkStore(root: other)
        XCTAssertEqual(restored.entry(entry.id)?.phase, .skipped)
    }
    func test记录不保存名称地址或凭据且不进入备份() async throws {
        let (model, _, _, root) = try make(); await model.refresh()
        XCTAssertTrue(model.create(.init(name: "sample-new"), activation: model.activation)); await model.waitForOperation()
        let data = try Data(contentsOf: root.appendingPathComponent("network-operations-v1.json")), text = String(decoding: data, as: UTF8.self)
        for forbidden in ["sample-new", "192.0.2", "2001:db8", "synthetic-session", "fixture.example.invalid"] { XCTAssertFalse(text.contains(forbidden)) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    func test跨账号迟到结果只保存旧记录不污染新页面() async throws {
        let (model, transport, _, root) = try make(); await model.refresh(); await transport.holdWrites()
        let oldContext = try XCTUnwrap(model.context), oldActivation = model.activation
        XCTAssertTrue(model.create(.init(name: "sample-new"), activation: oldActivation)); await transport.waitForWrite()
        let next = try profile(username: "other"), nextTransport = MobileContainerNetworkUITransport()
        model.configure(profile: next, repository: try repository(nextTransport, profile: next), authorize: { true })
        await transport.release(); await model.waitForOperation(); await model.refresh()
        XCTAssertTrue(model.entries.isEmpty); XCTAssertFalse(model.targets.contains { $0.name == "sample-new" })
        XCTAssertFalse(model.create(.init(name: "sample-old"), activation: oldActivation))
        let stored = MobileContainerNetworkStore(root: root); XCTAssertEqual(stored.entries.first?.context, oldContext)
        let writes = await nextTransport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test证书错误不自动刷新且两类写入口关闭() async throws {
        let (model, transport, _, _) = try make(mode: "containers-networks-trust"); await model.refresh()
        XCTAssertTrue(model.create(.init(name: "sample-new"), activation: model.activation)); await model.waitForOperation()
        XCTAssertEqual(model.error, .trust); XCTAssertFalse(model.canOpenCreation); XCTAssertFalse(model.canDelete(ids: ["a"]))
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "create")
    }
    private func newRoot() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("NetworkTests-\(UUID())")
        roots.append(value); return value
    }
    private func profile(username: String = "sample") throws -> NasProfile {
        try .init(id: UUID(uuidString: "8B5B26C1-6C36-4F47-89DA-D2B2B26AA082")!, displayName: "Synthetic",
                  host: "fixture.example.invalid", port: 5001, usernameHint: username)
    }
    private func repository(_ transport: MobileContainerNetworkUITransport, profile: NasProfile) throws -> DsmServiceManagementRepository {
        let name = DsmAPIName.dockerNetwork
        return try .init(profile: profile, capabilities: .init([name: .init(name: name, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .form, selectedVersion: 2)]),
            session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport, containerNetworkCreationEnabled: true)
    }
    private func make(mode: String = "containers-networks", root: URL? = nil) throws -> (MobileContainerNetworkModel, MobileContainerNetworkUITransport, NetworkPermissionGate, URL) {
        let root = root ?? newRoot(), transport = MobileContainerNetworkUITransport(mode: mode), profile = try profile(), gate = NetworkPermissionGate()
        let model = MobileContainerNetworkModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { await gate.check() })
        return (model, transport, gate, root)
    }
}

private actor NetworkPermissionGate {
    private var remaining: Int?
    func allow(_ checks: Int) { remaining = checks }
    func check() -> Bool {
        guard let remaining else { return true }
        self.remaining = max(0, remaining - 1); return remaining > 0
    }
}
