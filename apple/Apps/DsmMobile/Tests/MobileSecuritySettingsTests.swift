import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileSecuritySettingsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    func test安全四组完成保留各组结果且无配置正文落盘() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.security)
        let change = try change(model, steps: [.autoBlock, .denialOfService, .firewallNotifications, .firewall])
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
        let entry = try XCTUnwrap(model.recovery.entry(id))
        XCTAssertEqual(entry.phase, .succeeded); XCTAssertEqual(entry.parts.count, 4); XCTAssertTrue(entry.parts.allSatisfy { $0.stage == .verified })
        XCTAssertEqual(entry.parts.last?.firewallTaskSucceeded, true); XCTAssertTrue(model.canEdit(.security))
        let contents = try String(contentsOf: root.appendingPathComponent("service-operations-v1.json"), encoding: .utf8)
        for value in ["eth0", "LAN 1", "Sample profile", "fixture.example.invalid", "operator", "synthetic-session"] { XCTAssertFalse(contents.contains(value), value) }
        XCTAssertTrue(contents.contains("sample-firewall-task"), "回执用于原任务读取且不包含凭据")
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 5)
    }
    func test自动封锁未知保存重启只读取原配置结果() async throws {
        let (model, transport, root) = try makeModel(mode: "nas-services-unknown"); await model.refresh(.security)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); model.deactivate()
        let (next, reader, _) = try makeModel(mode: "nas-services-security-config-recover", root: root); await next.refresh(.security)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.writes, replays = await reader.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(replays.isEmpty)
    }
    func test防火墙缺回执即使配置吻合仍不能解除未知保护() async throws {
        let (model, transport, root) = try makeModel(mode: "nas-services-security-lost-receipt"); await model.refresh(.security)
        let id = try XCTUnwrap(model.perform(try change(model, steps: [.firewall]), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertNil(model.recovery.entry(id)?.parts.first?.firewallTaskID)
        model.deactivate()
        let (next, reader, _) = try makeModel(mode: "nas-services-security-task-recover", root: root); await next.refresh(.security)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(next.canEdit(.security))
        next.removeRecord(id, kind: .security); XCTAssertNotNil(next.recovery.entry(id))
        let writes = await transport.writes, requests = await reader.requests
        XCTAssertEqual(writes.map { $0["method"] }, ["start"]); XCTAssertFalse(requests.contains { ["start", "stop", "status"].contains($0["method"] ?? "") })
    }
    func test防火墙有回执重启查询原任务且不再次开始或全局清理() async throws {
        let (model, transport, root) = try makeModel(mode: "nas-services-security-task-offline"); await model.refresh(.security)
        let id = try XCTUnwrap(model.perform(try change(model, steps: [.firewall]), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertEqual(model.recovery.entry(id)?.parts.first?.firewallTaskID, "sample-firewall-task")
        model.deactivate()
        let (next, reader, _) = try makeModel(root: root); await next.refresh(.security)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded); XCTAssertTrue(next.canEdit(.security))
        let requests = await reader.requests, replays = await reader.writes, writes = await transport.writes
        XCTAssertEqual(requests.filter { $0["method"] == "status" }.map { $0["task_id"] }, ["sample-firewall-task"])
        XCTAssertTrue(replays.isEmpty); XCTAssertEqual(writes.map { $0["method"] }, ["start"])
    }
    func test安全明确拒绝不被其他客户端后来修改覆盖() async throws {
        let (model, transport, _) = try makeModel(mode: "nas-services-denied"); await model.refresh(.security)
        let id = try XCTUnwrap(model.perform(try change(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed)
        await transport.setSecurityAutoBlock(enabled: true); await model.refresh(.security)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test防火墙任务明确失败不会由后来开关变化改为成功() async throws {
        let (model, transport, _) = try makeModel(mode: "nas-services-security-task-failed"); await model.refresh(.security)
        let id = try XCTUnwrap(model.perform(try change(model, steps: [.firewall]), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); XCTAssertEqual(model.recovery.entry(id)?.parts.first?.firewallTaskSucceeded, false)
        await transport.setFirewall(enabled: true); await transport.setMode("nas-services"); await model.refresh(.security)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }
    func test防火墙清理撤权停止读取且恢复不重复清理() async throws {
        let (model, transport, _) = try makeModel(mode: "nas-services-security-clean-denied"); await model.refresh(.security)
        let id = try XCTUnwrap(model.perform(try change(model, steps: [.firewall]), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.errors[.security], .denied); XCTAssertFalse(model.canEdit(.security))
        let before = await transport.requests; XCTAssertEqual(before.last?["method"], "stop")
        await transport.setMode("nas-services"); await model.refresh(.security)
        XCTAssertEqual(model.recovery.entry(id)?.parts.first?.stage, .verified)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["start", "stop"])
    }
    func test安全原配置档变化或权限撤回均不能提交() async throws {
        for denied in [false, true] {
            let gate = SecurityPermissionGate(), (model, transport, _) = try makeModel(gate: gate); await model.refresh(.security)
            let change = try change(model, steps: [.autoBlock, .firewall])
            if denied { await gate.set(false) } else { await transport.changeFirewallProfile() }
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test安全部分拒绝保留已完成组且不认领未提交防火墙() async throws {
        let (model, transport, _) = try makeModel(mode: "nas-services-partial"); await model.refresh(.security)
        let id = try XCTUnwrap(model.perform(try change(model, steps: [.autoBlock, .denialOfService, .firewall]), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .partial)
        XCTAssertEqual(model.recovery.entry(id)?.parts.map(\.stage), [.verified, .rejected, .skipped])
        await transport.setFirewall(enabled: true); await model.refresh(.security)
        XCTAssertEqual(model.recovery.entry(id)?.parts.last?.stage, .skipped); let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }
    func test防火墙迟到回执仅归入旧账号且重复点击零新任务() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.security); let change = try change(model, steps: [.firewall])
        await transport.suspendWrites()
        let id = try XCTUnwrap(model.perform(change, activation: model.activation))
        for _ in 0..<2_000 { if await transport.writes.count == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(model.perform(change, activation: model.activation)); model.deactivate()
        let (next, reader, _) = try makeModel(root: root, account: "another"); await next.refresh(.security)
        await transport.resumeWrites(); await model.waitForOperation(id)
        XCTAssertTrue(next.entries(.security).isEmpty)
        let reopened = MobileServiceOperationStore(root: root)
        XCTAssertEqual(reopened.entry(id)?.parts.first?.firewallTaskID, "sample-firewall-task")
        XCTAssertEqual(reopened.entry(id)?.phase, .submitted)
        let writes = await transport.writes, replays = await reader.writes; XCTAssertEqual(writes.map { $0["method"] }, ["start"]); XCTAssertTrue(replays.isEmpty)
    }
    func test安全记录无法保存零写入且不完整字段不能编辑() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.security)
        try Data("occupied".utf8).write(to: root)
        XCTAssertNil(model.perform(try change(model), activation: model.activation)); XCTAssertEqual(model.errors[.security], .storage)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        let (incomplete, reader, _) = try makeModel(mode: "nas-services-security-incomplete"); await incomplete.refresh(.security)
        XCTAssertEqual(incomplete.section(.security).phase, .error); XCTAssertFalse(incomplete.canEdit(.security))
        let replays = await reader.writes; XCTAssertTrue(replays.isEmpty)
    }
    func test安全未提交记录重启不自动执行且旧确认失效() async throws {
        let (model, transport, root) = try makeModel(); await model.refresh(.security); let change = try change(model), token = model.activation
        let id = try model.recovery.reserve(change, context: XCTUnwrap(model.context)).id; model.recovery.end(id); model.deactivate()
        let store = MobileServiceOperationStore(root: root); XCTAssertEqual(store.entry(id)?.phase, .cancelled)
        XCTAssertNil(model.perform(change, activation: token)); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test防火墙任务证书或权限失败停止链路且恢复只读() async throws {
        for (mode, expected) in [("nas-services-security-task-denied", MobileServiceSettingsModel.Failure.denied), ("nas-services-security-task-trust", .trust)] {
            let (model, transport, _) = try makeModel(mode: mode); await model.refresh(.security)
            let id = try XCTUnwrap(model.perform(try change(model, steps: [.firewall]), activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.errors[.security], expected); XCTAssertFalse(model.canEdit(.security))
            let requests = await transport.requests; XCTAssertEqual(requests.last?["method"], "status")
            await transport.setMode("nas-services"); await model.refresh(.security)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
            let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["start"])
        }
    }
    private func change(_ model: MobileServiceSettingsModel, steps: [NasServiceStep] = [.autoBlock]) throws -> NasServiceChange {
        let original = try XCTUnwrap(model.section(.security).value)
        guard case .security(var value) = original else { throw SecurityTestError.invalid }
        if steps.contains(.autoBlock) { value.isAutoBlockEnabled = true }
        if steps.contains(.denialOfService) { value.dosProtection[0].isEnabled = true }
        if steps.contains(.firewallNotifications) { value.isPortScanProtectionEnabled = true }
        if steps.contains(.firewall) { value.isFirewallEnabled = true }
        return .init(original: original, desired: .security(value))
    }
    private func makeModel(mode: String = "nas-services", root: URL? = nil, account: String = "operator", gate: SecurityPermissionGate = .init()) throws -> (MobileServiceSettingsModel, MobileServiceUITransport, URL) {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileSecurityTests-\(UUID())")
        if !roots.contains(root) { roots.append(root) }
        let transport = MobileServiceUITransport(mode: mode), model = MobileServiceSettingsModel(root: root)
        let profile = try NasProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: account)
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: MobileServiceUITransport.versions.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: $1, requestFormat: .form, selectedVersion: $1)) }))
        let repository = try DsmNasAdministrationRepository(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        model.configure(profile: profile, repository: repository, authorize: { await gate.allowed })
        return (model, transport, root)
    }
}
private enum SecurityTestError: Error { case invalid }
private actor SecurityPermissionGate { var allowed = true; func set(_ value: Bool) { allowed = value } }
