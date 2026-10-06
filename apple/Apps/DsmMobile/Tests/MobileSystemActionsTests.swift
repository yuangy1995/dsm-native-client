import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileSystemActionsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for value in values { try? FileManager.default.removeItem(at: value) }
        try await super.tearDown()
    }
    func test服务和网页连接分别断开并回读列表() async throws {
        let (model, transport, _, _) = try make(); await model.refreshConnections()
        let targets = try XCTUnwrap(model.connections.value).connections.filter(\.canDisconnect)
        for value in targets {
            let id = try XCTUnwrap(model.perform(.disconnect(value), activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded); XCTAssertFalse(model.isOperating)
        }
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2); XCTAssertTrue(writes.allSatisfy { $0["method"] == "kick_connection" && $0["version"] == "1" })
        XCTAssertEqual(model.connections.value?.connections.count, 1)
    }
    func test空目录部分目录及受保护目标保留只读() async throws {
        for mode in ["nas-system-empty", "nas-system-incomplete", "nas-system-missing-id"] {
            let (model, transport, _, _) = try make(mode: mode); await model.refreshConnections()
            XCTAssertEqual(model.connections.phase, mode == "nas-system-empty" ? .empty : .content)
            if let target = model.connections.value?.connections.first { XCTAssertFalse(model.canPerform(.disconnect(target))) }
            let protected = model.connections.value?.connections.first { !$0.canDisconnect }
            if let protected { XCTAssertFalse(model.canPerform(.disconnect(protected))) }
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test读取失败可重试且不把失败当空目录() async throws {
        let (model, _, _, _) = try make(mode: "nas-system-retry"); await model.refreshConnections()
        XCTAssertEqual(model.connections.phase, .error); XCTAssertNil(model.connections.value)
        await model.refreshConnections(); XCTAssertEqual(model.connections.phase, .content)
        XCTAssertEqual(model.connections.value?.connections.count, 3)
    }
    func test保存前撤销权限连接与电源均零写入() async throws {
        for power in [false, true] {
            let (model, transport, gate, _) = try make(); await model.refreshConnections(); await model.refreshPower()
            let action: NasSystemAction = power ? .power(.shutdown) : .disconnect(try XCTUnwrap(model.connections.value?.connections.first))
            await gate.set(false)
            let id = try XCTUnwrap(model.perform(action, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.failure, .denied); XCTAssertFalse(model.canPerform(action))
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test原目标变化不能断开被替换的连接() async throws {
        let (model, transport, _, _) = try make(); await model.refreshConnections()
        let target = try XCTUnwrap(model.connections.value?.connections.first); await transport.changeTarget()
        let id = try XCTUnwrap(model.perform(.disconnect(target), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.failure, .changed); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test未知断开不能删除或再次提交并可重启只读恢复() async throws {
        let (model, transport, _, root) = try make(mode: "nas-system-unknown"); await model.refreshConnections()
        let target = try XCTUnwrap(model.connections.value?.connections.first), action = NasSystemAction.disconnect(target)
        let id = try XCTUnwrap(model.perform(action, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(model.canPerform(action))
        XCTAssertNil(model.perform(action, activation: model.activation)); model.removeRecord(id); XCTAssertNotNil(model.recovery.entry(id)); model.deactivate()
        let (next, replay, _, _) = try make(mode: "nas-system-recover", root: root); await next.refreshConnections()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.writes, repeated = await replay.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(repeated.isEmpty)
    }
    func test已接受但回读失败重启后仍只读取原目标() async throws {
        let (model, _, _, root) = try make(mode: "nas-system-accepted-offline"); await model.refreshConnections()
        let target = try XCTUnwrap(model.connections.value?.connections.first)
        let id = try XCTUnwrap(model.perform(.disconnect(target), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertTrue(model.recovery.entry(id)?.accepted == true); model.deactivate()
        let (next, transport, _, _) = try make(mode: "nas-system-recover", root: root); await next.refreshConnections()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test失去管理权限时可读目录不能解除未知断开保护() async throws {
        let (model, transport, gate, _) = try make(mode: "nas-system-unknown"); await model.refreshConnections()
        let target = try XCTUnwrap(model.connections.value?.connections.first)
        let id = try XCTUnwrap(model.perform(.disconnect(target), activation: model.activation)); await model.waitForOperation(id)
        await gate.set(false); await transport.removeTargets(); await model.refreshConnections()
        XCTAssertEqual(model.connections.phase, .empty); XCTAssertEqual(model.connectionError, .denied)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(model.connectionPermission)
        await gate.set(true); await model.refreshConnections()
        XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test缺标识相似条目与不完整目录不能解除断开保护() async throws {
        let (model, _, _, root) = try make(mode: "nas-system-unknown"); await model.refreshConnections()
        let target = try XCTUnwrap(model.connections.value?.connections.first)
        let id = try XCTUnwrap(model.perform(.disconnect(target), activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        for mode in ["nas-system-missing-id", "nas-system-missing-id-time", "nas-system-incomplete"] {
            let (next, transport, _, _) = try make(mode: mode, root: root); await next.refreshConnections()
            XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty); next.deactivate()
        }
    }
    func test电源接受仅记录请求并阻止同会话全部电源动作() async throws {
        let (model, transport, _, root) = try make(); await model.refreshPower()
        let before = await transport.calls.count
        let id = try XCTUnwrap(model.perform(.power(.shutdown), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .accepted); XCTAssertTrue(model.recovery.entry(id)?.accepted == true)
        XCTAssertFalse(model.canPerform(.power(.shutdown))); XCTAssertFalse(model.canPerform(.power(.reboot))); XCTAssertFalse(model.canReleasePower)
        model.removeRecord(id); XCTAssertNotNil(model.recovery.entry(id))
        let calls = await transport.calls; XCTAssertEqual(Array(calls.dropFirst(before)).map { $0["method"] }, ["info", "shutdown"])
        model.deactivate(); let (next, nextTransport, _, _) = try make(root: root); await next.refreshPower()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .accepted); XCTAssertFalse(next.canReleasePower)
        let repeated = await nextTransport.writes; XCTAssertTrue(repeated.isEmpty)
    }
    func test未知电源必须新登录及明确恢复操作才释放保护() async throws {
        let (model, transport, _, root) = try make(mode: "nas-system-unknown"); await model.refreshPower()
        let id = try XCTUnwrap(model.perform(.power(.reboot), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); model.deactivate()
        let (same, _, _, _) = try make(root: root); await same.refreshPower(); await same.releasePower(activation: same.activation)
        XCTAssertEqual(same.recovery.entry(id)?.phase, .submitted); same.deactivate()
        let (next, replay, _, _) = try make(root: root, sessionID: "synthetic-new-session"); await next.refreshPower()
        XCTAssertTrue(next.canReleasePower); XCTAssertFalse(next.canPerform(.power(.reboot)))
        XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted)
        await next.releasePower(activation: next.activation)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .released); XCTAssertTrue(next.canPerform(.power(.reboot)))
        XCTAssertFalse(next.recovery.entry(id)?.accepted == true)
        let writes = await transport.writes, repeated = await replay.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(repeated.isEmpty)
        next.removeRecord(id); XCTAssertNil(next.recovery.entry(id))
    }
    func test恢复电源时权限或设备读取失败仍保留原记录() async throws {
        let (model, _, _, root) = try make(); await model.refreshPower()
        let id = try XCTUnwrap(model.perform(.power(.shutdown), activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        let (next, transport, gate, _) = try make(root: root, sessionID: "new-session"); await next.refreshPower()
        await gate.set(false); await next.releasePower(activation: next.activation)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .accepted); XCTAssertEqual(next.powerError, .denied); XCTAssertFalse(next.powerPermission); XCTAssertFalse(next.canReleasePower)
        await gate.set(true); await next.refreshPower(); await transport.setMode("nas-system-info-denied")
        await next.releasePower(activation: next.activation); XCTAssertEqual(next.recovery.entry(id)?.phase, .accepted)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test同账号新适配器与切换账号均使旧确认失效() async throws {
        let (model, transport, _, _) = try make(); await model.refreshPower(); let token = model.activation
        let profile = try profile()
        model.configure(profile: profile, repository: try repository(transport, profile: profile), session: session(), authorize: { true }); await model.refreshPower()
        XCTAssertNotEqual(token, model.activation); XCTAssertNil(model.perform(.power(.shutdown), activation: token))
        let other = try self.profile(username: "other-user"), previous = model.activation
        model.configure(profile: other, repository: try repository(transport, profile: other), session: session(), authorize: { true }); await model.refreshPower()
        XCTAssertNil(model.perform(.power(.shutdown), activation: previous)); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test旧账号迟到回执不进入新账号页面() async throws {
        let (model, transport, _, _) = try make(); await model.refreshPower(); await transport.holdWrites()
        let oldContext = model.context, id = try XCTUnwrap(model.perform(.power(.reboot), activation: model.activation))
        for _ in 0..<200 { if await transport.writes.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        let other = try profile(username: "another-user")
        model.configure(profile: other, repository: try repository(transport, profile: other), session: session(), authorize: { true })
        await transport.resume(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries.isEmpty); XCTAssertEqual(model.recovery.entry(id)?.context, oldContext)
        XCTAssertNotEqual(model.context, oldContext); XCTAssertFalse(model.isOperating)
    }
    func test损坏记录和无法写入记录都不发送请求() async throws {
        let root = makeRoot(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid-record".utf8).write(to: root.appendingPathComponent("system-actions-v1.json"))
        let (model, transport, _, _) = try make(root: root); await model.refreshPower()
        XCTAssertTrue(model.recovery.failed); XCTAssertNil(model.perform(.power(.shutdown), activation: model.activation))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        let otherRoot = makeRoot(); try Data().write(to: otherRoot)
        let (other, nextTransport, _, _) = try make(root: otherRoot); await other.refreshPower()
        XCTAssertNil(other.perform(.power(.reboot), activation: other.activation)); XCTAssertEqual(other.powerError, .storage)
        let repeated = await nextTransport.writes; XCTAssertTrue(repeated.isEmpty)
    }
    func test记录不含连接和会话明文且拒绝伪造电源已完成() async throws {
        let (model, _, _, root) = try make(); await model.refreshConnections(); await model.refreshPower()
        let target = try XCTUnwrap(model.connections.value?.connections.first), first = try XCTUnwrap(model.perform(.disconnect(target), activation: model.activation)); await model.waitForOperation(first)
        let id = try XCTUnwrap(model.perform(.power(.shutdown), activation: model.activation)); await model.waitForOperation(id)
        let url = root.appendingPathComponent("system-actions-v1.json"), data = try Data(contentsOf: url), text = String(decoding: data, as: UTF8.self)
        for secret in ["synthetic-session", "sample-user", "sample-client.invalid", "synthetic-web-device", "Sample file connection"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]), entries = try XCTUnwrap(envelope["entries"] as? [[String: Any]])
        entries[1]["phase"] = "succeeded"; envelope["entries"] = entries
        try JSONSerialization.data(withJSONObject: envelope).write(to: url); model.recovery.reload()
        XCTAssertTrue(model.recovery.failed); XCTAssertFalse(model.canPerform(.power(.reboot)))
    }
    func test准备记录重启取消且接受回执重启不退回未知() async throws {
        for accepted in [false, true] {
            let (model, _, _, root) = try make(); await model.refreshPower()
            let value = try model.recovery.reserve(.power(.shutdown), context: try XCTUnwrap(model.context), session: MobileSystemActionStore.digest(["synthetic-session"]))
            if accepted { try model.recovery.checkpoint(value.id, .willSubmit); try model.recovery.checkpoint(value.id, .accepted) }
            model.recovery.end(value.id); model.deactivate()
            let (next, transport, _, _) = try make(root: root); await next.refreshPower()
            XCTAssertEqual(next.recovery.entry(value.id)?.phase, accepted ? .accepted : .cancelled)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test明确拒绝与证书变化不会误报接受或自动读取() async throws {
        for mode in ["nas-system-denied", "nas-system-trust-write"] {
            let (model, transport, _, _) = try make(mode: mode); await model.refreshPower()
            let id = try XCTUnwrap(model.perform(.power(.reboot), activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, mode == "nas-system-denied" ? .failed : .submitted)
            XCTAssertFalse(model.powerPermission); let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "reboot")
        }
    }
    func test电源版本不支持仍能读取连接目录() async throws {
        let (model, transport, _, _) = try make(powerVersion: 2); await model.refreshPower(); await model.refreshConnections()
        XCTAssertEqual(model.power.phase, .unavailable); XCTAssertEqual(model.connections.phase, .content)
        XCTAssertFalse(model.canPerform(.power(.shutdown))); let calls = await transport.calls
        XCTAssertTrue(calls.allSatisfy { $0["api"] == DsmAPIName.coreCurrentConnection })
    }
    private func makeRoot() -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("SystemActionsTests-\(UUID())"); roots.append(url); return url }
    private func profile(username: String = "operator") throws -> NasProfile { try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000020")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username) }
    private func session(_ id: String = "synthetic-session") -> AuthSession { .init(sid: id, synoToken: nil, did: nil, isPortalPort: false) }
    private func repository(_ transport: MobileSystemActionUITransport, profile: NasProfile, powerVersion: Int = 3) throws -> DsmNasAdministrationRepository {
        let caps = CapabilitySet(Dictionary(uniqueKeysWithValues: [(DsmAPIName.coreSystem,powerVersion), (DsmAPIName.coreCurrentConnection,1)].map {
            ($0.0, ApiCapability(name: $0.0, path: "entry.cgi", minVersion: 1, maxVersion: $0.1, requestFormat: .form, selectedVersion: $0.1))
        }))
        return try .init(profile: profile, capabilities: caps, session: session(), transport: transport)
    }
    private func make(mode: String = "nas-system", root: URL? = nil, sessionID: String = "synthetic-session", powerVersion: Int = 3) throws -> (MobileSystemActionsModel, MobileSystemActionUITransport, SystemPermissionGate, URL) {
        let root = root ?? makeRoot(), transport = MobileSystemActionUITransport(mode: mode), gate = SystemPermissionGate(), profile = try profile()
        let model = MobileSystemActionsModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile, powerVersion: powerVersion), session: session(sessionID), authorize: { await gate.check() })
        return (model, transport, gate, root)
    }
}
private actor SystemPermissionGate { private var allowed = true; func set(_ value: Bool) { allowed = value }; func check() -> Bool { allowed } }
