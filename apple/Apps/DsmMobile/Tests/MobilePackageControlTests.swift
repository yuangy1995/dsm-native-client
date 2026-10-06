import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobilePackageControlTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let value = self.roots; self.roots = []; return value }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    func test启动停止卸载使用真实适配和独立结果() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(.installed)
        for action in [NasPackageAction.start, .stop, .uninstall] {
            let value = try XCTUnwrap(model.installed.first)
            XCTAssertTrue(model.canControl(value, action: action))
            let id = try XCTUnwrap(model.performControl(value, action: action, activation: model.activation))
            XCTAssertFalse(model.canControl(value, action: action))
            await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
            if action == .start { XCTAssertEqual(model.installed.first?.status, "running") }
            if action == .stop { XCTAssertEqual(model.installed.first?.status, "stopped") }
            if action == .uninstall { XCTAssertTrue(model.installed.isEmpty) }
        }
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["start", "stop", "uninstall"])
        XCTAssertTrue(writes.allSatisfy { $0["version"] == "1" && $0["id"] == "SyntheticPackage" })
        XCTAssertNil(writes[1]["dsm_apps"])
    }
    func test原确认过期或账号切换时零提交() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(.installed)
        let before = try XCTUnwrap(model.installed.first), token = model.activation
        XCTAssertNil(model.performControl(before, action: .start, activation: UUID()))
        await transport.setStatus("running"); await model.refresh(.installed)
        XCTAssertFalse(model.canControl(before, action: .start)); XCTAssertNil(model.performControl(before, action: .start, activation: token))
        model.deactivate(); XCTAssertNil(model.performControl(before, action: .uninstall, activation: token))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test服务端在确认后重装或改变状态时不发送写请求() async throws {
        for reinstall in [false, true] {
            let (model, transport, _, _) = try make(); await model.refresh(.installed)
            let before = try XCTUnwrap(model.installed.first)
            if reinstall { await transport.reinstall() } else { await transport.setStatus("running") }
            let id = try XCTUnwrap(model.performControl(before, action: .start, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); XCTAssertEqual(model.recovery.entry(id)?.failure, .changed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test写前权限撤销保留明确拒绝且不发送() async throws {
        let (model, transport, gate, _) = try make(); await model.refresh(.installed)
        let package = try XCTUnwrap(model.installed.first); await gate.set(false)
        let id = try XCTUnwrap(model.performControl(package, action: .uninstall, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.failure, .denied); XCTAssertEqual(model.errors[.installed], .denied)
        XCTAssertFalse(model.canControl(package, action: .uninstall))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test明确拒绝不能被外部相同结果改写() async throws {
        for action in [NasPackageAction.start, .uninstall] {
            let (model, transport, _, _) = try make(mode: "nas-package-apply-denied"); await model.refresh(.installed)
            let package = try XCTUnwrap(model.installed.first)
            let id = try XCTUnwrap(model.performControl(package, action: action, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); XCTAssertEqual(model.recovery.entry(id)?.failure, .denied)
            await model.refresh(.installed); XCTAssertEqual(model.recovery.entry(id)?.phase, .failed)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }
    func test三种未知操作重启只读恢复且跨页保护() async throws {
        for action in [NasPackageAction.start, .stop, .uninstall] {
            let (model, transport, _, root) = try make(mode: "nas-package-unknown")
            if action == .stop { await transport.setStatus("running") }
            await model.refresh(.installed); await model.refresh(.preferences); await model.refresh(.sources)
            let package = try XCTUnwrap(model.installed.first)
            let id = try XCTUnwrap(model.performControl(package, action: action, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(model.canEdit(.preferences)); XCTAssertFalse(model.canEdit(.sources))
            XCTAssertFalse(model.canControl(package, action: action)); XCTAssertNil(model.performControl(package, action: action, activation: model.activation))
            model.removeRecord(id); XCTAssertNotNil(model.recovery.entry(id)); model.deactivate()
            let mode = action == .start ? "nas-package-control-recover-start" : action == .stop ? "nas-package-preferences" : "nas-package-control-recover-remove"
            let (next, replay, _, _) = try make(mode: mode, root: root); await next.refresh(.installed)
            XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded)
            let writes = await transport.writes, replays = await replay.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(replays.isEmpty)
        }
    }
    func test同ID重装后的相同运行状态不能恢复旧操作() async throws {
        let (model, _, _, root) = try make(mode: "nas-package-unknown"); await model.refresh(.installed)
        let id = try XCTUnwrap(model.performControl(try XCTUnwrap(model.installed.first), action: .start, activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        let (next, transport, _, _) = try make(mode: "nas-package-control-reinstalled", root: root); await next.refresh(.installed)
        XCTAssertEqual(next.installed.first?.status, "running"); XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted)
        XCTAssertFalse(next.canEdit(.installed)); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test接受后读取权限不足保留保护并可恢复() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-control-read-denied"); await model.refresh(.installed)
        let id = try XCTUnwrap(model.performControl(try XCTUnwrap(model.installed.first), action: .start, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertEqual(model.recovery.entry(id)?.accepted, true)
        XCTAssertEqual(model.errors[.installed], .denied)
        await transport.setMode("nas-package-preferences"); await model.refresh(.installed)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test套件设置和安装未知记录均阻止三动作() async throws {
        for installation in [false, true] {
            let (model, transport, _, _) = try make(); await model.refresh(.installed); await model.refresh(.preferences)
            let context = try XCTUnwrap(model.context)
            if installation {
                let entry = try model.installation.recovery.reserve(context: context, totalCount: 1, isUpload: false)
                model.installation.recovery.end(entry.id)
            } else {
                let before = try XCTUnwrap(model.preferences); var after = before.settings; after.emailNotifications = true
                let entry = try model.recovery.reserve(.settings(original: before, desired: after), context: context)
                try model.recovery.checkpoint(entry.id, NasPackagePreferenceCheckpoint.willSubmit); model.recovery.end(entry.id)
            }
            let package = try XCTUnwrap(model.installed.first)
            XCTAssertFalse(model.canControl(package, action: .start)); XCTAssertNil(model.performControl(package, action: .uninstall, activation: model.activation))
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test迟到回执只更新原账号记录() async throws {
        let (model, transport, _, root) = try make(); await model.refresh(.installed); await transport.holdWrites()
        let context = try XCTUnwrap(model.context)
        let id = try XCTUnwrap(model.performControl(try XCTUnwrap(model.installed.first), action: .start, activation: model.activation))
        for _ in 0..<500 { if await !transport.writes.isEmpty { break }; await Task.yield() }
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        let other = try profile(username: "other"), nextTransport = MobilePackageUITransport()
        model.configure(profile: other, repository: try repository(nextTransport, profile: other), authorize: { true })
        await model.refresh(.installed); await transport.resume(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries.isEmpty); XCTAssertEqual(model.installed.first?.status, "stopped")
        let restored = MobilePackageOperationStore(root: root)
        XCTAssertEqual(restored.entry(id)?.context, context); XCTAssertTrue(restored.entry(id)?.isProtected == true || restored.entry(id)?.phase == .succeeded)
        let writes = await nextTransport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test记录只保存摘要损坏时零写入且准备阶段不恢复提交() async throws {
        let (model, transport, _, root) = try make(); await model.refresh(.installed)
        let package = try XCTUnwrap(model.installed.first), context = try XCTUnwrap(model.context)
        let entry = try model.recovery.reserve(package, action: .uninstall, context: context); model.recovery.end(entry.id)
        let data = try Data(contentsOf: root.appendingPathComponent("package-operations-v1.json")), text = String(decoding: data, as: UTF8.self)
        for secret in ["Sample package", "SyntheticPackage", "Synthetic.Application", "fixture.example.invalid", "synthetic-session", "operator"] { XCTAssertFalse(text.contains(secret)) }
        let restored = MobilePackageOperationStore(root: root); XCTAssertEqual(restored.entry(entry.id)?.phase, .cancelled)
        try Data("broken".utf8).write(to: root.appendingPathComponent("package-operations-v1.json"))
        model.recovery.reload(); XCTAssertTrue(model.recovery.failed)
        XCTAssertNil(model.performControl(package, action: .uninstall, activation: model.activation))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test存储目录无法使用时不写NAS() async throws {
        let (model, transport, _, root) = try make(); await model.refresh(.installed)
        try Data("not a directory".utf8).write(to: root)
        XCTAssertNil(model.performControl(try XCTUnwrap(model.installed.first), action: .start, activation: model.activation))
        XCTAssertEqual(model.errors[.installed], .storage)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test证书失败不继续回读且保留原操作() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-trust-write"); await model.refresh(.installed)
        let id = try XCTUnwrap(model.performControl(try XCTUnwrap(model.installed.first), action: .start, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.errors[.installed], .trust); XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        XCTAssertFalse(model.canEdit(.installed)); let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "start")
    }
    func test记录丢失或目录损坏的刷新不能清空在途保护() async throws {
        for brokenDirectory in [false, true] {
            let (model, transport, _, root) = try make(); await model.refresh(.installed)
            let package = try XCTUnwrap(model.installed.first), context = try XCTUnwrap(model.context)
            let entry = try model.recovery.reserve(package, action: .start, context: context)
            try model.recovery.checkpoint(entry.id, NasPackageControlCheckpoint.willSubmit); model.recovery.end(entry.id)
            if brokenDirectory {
                try FileManager.default.removeItem(at: root); try Data("broken directory".utf8).write(to: root)
            } else { try FileManager.default.removeItem(at: root.appendingPathComponent("package-operations-v1.json")) }
            await model.refresh(.installed)
            XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.recovery.entry(entry.id)?.phase, .submitted)
            XCTAssertFalse(model.canControl(package, action: .start)); XCTAssertEqual(model.errors[.installed], .storage)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test不支持动作与系统卸载保持关闭且完整列表失败不伪造删除() async throws {
        let (unsupported, transport, _, _) = try make(controls: false); await unsupported.refresh(.installed)
        let package = try XCTUnwrap(unsupported.installed.first); XCTAssertFalse(unsupported.canControl(package, action: .start)); XCTAssertFalse(unsupported.canControl(package, action: .uninstall))
        let (system, _, _, _) = try make(mode: "nas-package-control-system"); await system.refresh(.installed)
        XCTAssertFalse(system.canControl(try XCTUnwrap(system.installed.first), action: .uninstall))
        let (partial, _, _, _) = try make(mode: "nas-package-partial"); await partial.refresh(.installed)
        XCTAssertEqual(partial.section(.installed).phase, .error); XCTAssertFalse(partial.canEdit(.installed))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    private func make(mode: String = "nas-package-preferences", root: URL? = nil, controls: Bool = true) throws -> (MobilePackageCenterModel, MobilePackageUITransport, PackageControlPermissionGate, URL) {
        let location: URL
        if let root { location = root } else { location = FileManager.default.temporaryDirectory.appendingPathComponent("PackageControlTests-\(UUID())"); roots.append(location) }
        let transport = MobilePackageUITransport(mode: mode), gate = PackageControlPermissionGate(), profile = try profile(), model = MobilePackageCenterModel(root: location)
        model.configure(profile: profile, repository: try repository(transport, profile: profile, controls: controls), authorize: { await gate.check() })
        return (model, transport, gate, location)
    }
    private func profile(username: String = "operator") throws -> NasProfile { try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000021")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username) }
    private func repository(_ transport: MobilePackageUITransport, profile: NasProfile, controls: Bool = true) throws -> DsmNasAdministrationRepository {
        var versions = [DsmAPIName.corePackage: 2, DsmAPIName.corePackageSetting: 1, DsmAPIName.corePackageFeed: 1]
        if controls { versions[DsmAPIName.corePackageControl] = 1; versions[DsmAPIName.corePackageUninstallation] = 1 }
        return try .init(profile: profile, capabilities: .init(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version))
        })), session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
}
private actor PackageControlPermissionGate { private var allowed = true; func set(_ value: Bool) { allowed = value }; func check() -> Bool { allowed } }
