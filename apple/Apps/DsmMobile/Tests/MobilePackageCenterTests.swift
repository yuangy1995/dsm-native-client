import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobilePackageCenterTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for value in values { try? FileManager.default.removeItem(at: value) }
        try await super.tearDown()
    }
    func test列表设置和来源使用实际适配且读取独立() async throws {
        let (model, _, _, _) = try make(); await load(model)
        XCTAssertEqual(model.installed.map(\.id), ["SyntheticPackage"])
        XCTAssertEqual(model.preferences?.settings.volumes.count, 1); XCTAssertEqual(model.sources.count, 1)
        XCTAssertTrue(model.canEdit(.preferences)); XCTAssertTrue(model.canEdit(.sources))
    }
    func test普通设置与单套件自动更新均保存并回读() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(.preferences)
        let first = try XCTUnwrap(model.perform(try emailChange(model), activation: model.activation)); await model.waitForOperation(first)
        XCTAssertEqual(model.preferences?.settings.emailNotifications, true); XCTAssertEqual(model.recovery.entry(first)?.phase, .succeeded)
        let baseline = try XCTUnwrap(model.preferences); var selected = baseline.settings; selected.updatePolicy = .selected; selected.packageUpdates[0].policy = .latest
        let change = NasPackagePreferenceChange.settings(original: baseline, desired: selected); XCTAssertTrue(change.enablesAutomaticUpdates)
        let second = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(second)
        XCTAssertEqual(model.recovery.entry(second)?.phase, .succeeded); XCTAssertEqual(model.preferences?.settings.packageUpdates[0].policy, .latest)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2); XCTAssertNil(writes.first?["default_vol"])
        XCTAssertEqual(writes.last?["packages"], "[\"SyntheticPackage\"]")
    }
    func test来源添加编辑删除均绑定原地址且分别结束() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(.sources)
        let new = newSource(), renamed = NasPackageSource(name: "Renamed source", url: "https://packages.example.invalid/renamed")
        for change in [NasPackagePreferenceChange.saveSource(new, replacing: nil), .saveSource(renamed, replacing: new), .removeSource(renamed)] {
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
        }
        XCTAssertEqual(model.sources.map(\.name), ["Sample source"])
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["add", "set", "delete"])
    }
    func test新增手动更新套件不阻塞保存和丢回执恢复() async throws {
        for mode in ["nas-package-added-manual", "nas-package-added-manual-lost-ack"] {
            let (model, transport, _, _) = try make(mode: mode); await model.refresh(.preferences)
            let original = try XCTUnwrap(model.preferences); var desired = original.settings
            desired.updatePolicy = .selected; desired.packageUpdates[0].policy = .latest
            let id = try XCTUnwrap(model.perform(.settings(original: original, desired: desired), activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded); XCTAssertEqual(model.preferences?.settings.packageUpdates.count, 2)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }
    func test无效和重复来源不能提交() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(.sources)
        for value in [NasPackageSource(name: "", url: "https://packages.example.invalid/new"), .init(name: "Invalid", url: "ftp://packages.example.invalid"), try XCTUnwrap(model.sources.first)] {
            let change = NasPackagePreferenceChange.saveSource(value, replacing: nil)
            XCTAssertFalse(model.canPerform(change)); XCTAssertNil(model.perform(change, activation: model.activation))
        }
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test未知单套件策略不补关闭且来源仍可编辑() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-unknown-preference"); await load(model)
        XCTAssertEqual(model.preferences?.unknownUpdateIDs, ["SyntheticPackage"])
        XCTAssertFalse(model.canPerform(try emailChange(model))); XCTAssertTrue(model.canEdit(.sources))
        let original = try XCTUnwrap(model.preferences); var target = original.settings; target.updatePolicy = .manual
        let id = try XCTUnwrap(model.perform(.settings(original: original, desired: target), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded); XCTAssertEqual(model.preferences?.settings.updatePolicy, .manual)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertNil(writes.first?["packages"])
    }
    func test设置读取失败不阻断来源而部分目录不能保存() async throws {
        let (model, _, _, _) = try make(mode: "nas-package-settings-error"); await load(model)
        XCTAssertEqual(model.section(.preferences).phase, .error); XCTAssertTrue(model.canEdit(.sources))
        let (partial, transport, _, _) = try make(mode: "nas-package-partial"); await partial.refresh(.preferences)
        XCTAssertEqual(partial.section(.preferences).phase, .error); XCTAssertFalse(partial.canEdit(.preferences))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test原设置和来源变化都在提交前停止() async throws {
        for source in [false, true] {
            let (model, transport, _, _) = try make(); await load(model)
            let change: NasPackagePreferenceChange = source ? .removeSource(try XCTUnwrap(model.sources.first)) : try emailChange(model)
            if source { await transport.changeSource() } else { await transport.changeSettings() }
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.failure, .changed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test权限撤销时设置和来源均零写入() async throws {
        for source in [false, true] {
            let (model, transport, gate, _) = try make(); await load(model)
            let change: NasPackagePreferenceChange = source ? .saveSource(newSource(), replacing: nil) : try emailChange(model)
            await gate.set(false)
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.failure, .denied); XCTAssertFalse(model.canEdit(change.page))
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test未知设置跨页阻止重发并在重启后只读恢复() async throws {
        let (model, transport, _, root) = try make(mode: "nas-package-unknown"); await load(model)
        let change = try emailChange(model), id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(model.canEdit(.sources)); XCTAssertFalse(model.canEdit(.preferences))
        XCTAssertNil(model.perform(change, activation: model.activation)); model.removeRecord(id); XCTAssertNotNil(model.recovery.entry(id)); model.deactivate()
        let (next, replay, _, _) = try make(mode: "nas-package-recover-settings", root: root); await next.refresh(.preferences)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded)
        let originalWrites = await transport.writes, replayWrites = await replay.writes; XCTAssertEqual(originalWrites.count, 1); XCTAssertTrue(replayWrites.isEmpty)
    }
    func test未知来源添加或移除重启只读恢复() async throws {
        for removing in [false, true] {
            let (model, transport, _, root) = try make(mode: "nas-package-unknown"); await model.refresh(.sources)
            let change: NasPackagePreferenceChange = removing ? .removeSource(try XCTUnwrap(model.sources.first)) : .saveSource(newSource(), replacing: nil)
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); model.deactivate()
            let (next, replay, _, _) = try make(mode: removing ? "nas-package-recover-remove" : "nas-package-recover-source", root: root); await next.refresh(.sources)
            XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded)
            let originalWrites = await transport.writes, replayWrites = await replay.writes; XCTAssertEqual(originalWrites.count, 1); XCTAssertTrue(replayWrites.isEmpty)
        }
    }
    func test编辑来源目标出现但旧地址仍在不能解除保护() async throws {
        let (model, _, _, root) = try make(mode: "nas-package-unknown"); await model.refresh(.sources)
        let change = NasPackagePreferenceChange.saveSource(newSource(), replacing: try XCTUnwrap(model.sources.first))
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        let (next, transport, _, _) = try make(mode: "nas-package-recover-source", root: root); await next.refresh(.sources)
        XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(next.canEdit(.sources))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test接受后离线与丢回执分别保留真实结果() async throws {
        for mode in ["nas-package-accepted-offline", "nas-package-lost-ack"] {
            let (model, transport, _, _) = try make(mode: mode); await model.refresh(.preferences)
            let id = try XCTUnwrap(model.perform(try emailChange(model), activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, mode == "nas-package-lost-ack" ? .succeeded : .submitted)
            XCTAssertEqual(model.recovery.entry(id)?.accepted, mode == "nas-package-accepted-offline")
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }
    func test明确拒绝不被后续匹配设置覆盖为成功() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-apply-denied"); await model.refresh(.preferences)
        let id = try XCTUnwrap(model.perform(try emailChange(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.preferences?.settings.emailNotifications, true)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); XCTAssertEqual(model.recovery.entry(id)?.failure, .denied)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test部分来源或失去管理权限不能解除未知移除保护() async throws {
        let (model, transport, gate, _) = try make(mode: "nas-package-unknown"); await model.refresh(.sources)
        let id = try XCTUnwrap(model.perform(.removeSource(try XCTUnwrap(model.sources.first)), activation: model.activation)); await model.waitForOperation(id)
        await transport.clearSources(); await transport.setMode("nas-package-source-partial"); await model.refresh(.sources)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        await transport.setMode("nas-package-preferences"); await gate.set(false); await model.refresh(.sources)
        XCTAssertEqual(model.section(.sources).phase, .empty); XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        await gate.set(true); await model.refresh(.sources); XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test同账号重连和换账号均使旧确认失效() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(.preferences)
        let old = model.activation, change = try emailChange(model), profile = try profile()
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { true }); await model.refresh(.preferences)
        XCTAssertNotEqual(old, model.activation); XCTAssertNil(model.perform(change, activation: old))
        let current = model.activation, other = try self.profile(username: "other")
        model.configure(profile: other, repository: try repository(transport, profile: other), authorize: { true }); await model.refresh(.preferences)
        XCTAssertNil(model.perform(change, activation: current)); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test旧账号迟到回执只更新原记录() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(.preferences); await transport.holdWrites()
        let context = model.context, id = try XCTUnwrap(model.perform(try emailChange(model), activation: model.activation))
        for _ in 0..<200 { if await transport.writes.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let sent = await transport.writes; XCTAssertEqual(sent.count, 1)
        let other = try profile(username: "other")
        model.configure(profile: other, repository: try repository(transport, profile: other), authorize: { true }); await transport.resume(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries.isEmpty); XCTAssertEqual(model.recovery.entry(id)?.context, context); XCTAssertFalse(model.isOperating)
    }
    func test损坏或无法保存记录均零写入() async throws {
        let root = newRoot(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("package-operations-v1.json"))
        let (model, transport, _, _) = try make(root: root); await model.refresh(.preferences)
        XCTAssertTrue(model.recovery.failed); XCTAssertNil(model.perform(try emailChange(model), activation: model.activation))
        let otherRoot = newRoot(); try Data().write(to: otherRoot)
        let (other, next, _, _) = try make(root: otherRoot); await other.refresh(.preferences)
        XCTAssertNil(other.perform(try emailChange(other), activation: other.activation)); XCTAssertEqual(other.errors[.preferences], .storage)
        let writes = await transport.writes, more = await next.writes; XCTAssertTrue(writes.isEmpty); XCTAssertTrue(more.isEmpty)
    }
    func test记录不保存来源或凭据且排除备份() async throws {
        let (model, _, _, root) = try make(mode: "nas-package-unknown"); await model.refresh(.sources)
        let value = NasPackageSource(name: "Private source", url: "https://packages.example.invalid/new?key=synthetic-source-key")
        let id = try XCTUnwrap(model.perform(.saveSource(value, replacing: nil), activation: model.activation)); await model.waitForOperation(id)
        let data = try Data(contentsOf: root.appendingPathComponent("package-operations-v1.json")), text = String(decoding: data, as: UTF8.self)
        for secret in ["Private source", "packages.example.invalid", "synthetic-source-key", "synthetic-session", "operator"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
    }
    func test准备记录重启取消且没有网络重放() async throws {
        let (model, _, _, root) = try make(); await model.refresh(.preferences)
        let value = try model.recovery.reserve(try emailChange(model), context: try XCTUnwrap(model.context)); model.recovery.end(value.id); model.deactivate()
        let (next, transport, _, _) = try make(root: root); await next.refresh(.preferences)
        XCTAssertEqual(next.recovery.entry(value.id)?.phase, .cancelled)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test证书变化停止写后读取并保留原保护() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-trust-write"); await model.refresh(.preferences)
        let id = try XCTUnwrap(model.perform(try emailChange(model), activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.errors[.preferences], .trust); XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        XCTAssertFalse(model.canEdit(.preferences)); let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "set")
    }
    func test低版本设置不可用时来源保持独立() async throws {
        let (model, transport, _, _) = try make(packageVersion: 1); await model.refresh(.preferences); await model.refresh(.sources)
        XCTAssertEqual(model.section(.preferences).phase, .unavailable); XCTAssertTrue(model.canEdit(.sources))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    private func load(_ model: MobilePackageCenterModel) async { for page in MobilePackageCenterModel.Page.allCases { await model.refresh(page) } }
    private func newSource() -> NasPackageSource { .init(name: "New source", url: "https://packages.example.invalid/new") }
    private func emailChange(_ model: MobilePackageCenterModel) throws -> NasPackagePreferenceChange { let before = try XCTUnwrap(model.preferences); var after = before.settings; after.emailNotifications = true; return .settings(original: before, desired: after) }
    private func newRoot() -> URL { let value = FileManager.default.temporaryDirectory.appendingPathComponent("PackageCenterTests-\(UUID())"); roots.append(value); return value }
    private func profile(username: String = "operator") throws -> NasProfile { try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000021")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username) }
    private func repository(_ transport: MobilePackageUITransport, profile: NasProfile, packageVersion: Int = 2) throws -> DsmNasAdministrationRepository {
        let versions = [DsmAPIName.corePackage: packageVersion, DsmAPIName.corePackageSetting: 1, DsmAPIName.corePackageFeed: 1]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version)) }))
        return try .init(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func make(mode: String = "nas-package-preferences", root: URL? = nil, packageVersion: Int = 2) throws -> (MobilePackageCenterModel, MobilePackageUITransport, PackagePermissionGate, URL) {
        let root = root ?? newRoot(), transport = MobilePackageUITransport(mode: mode), gate = PackagePermissionGate(), profile = try profile()
        let model = MobilePackageCenterModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile, packageVersion: packageVersion), authorize: { await gate.check() })
        return (model, transport, gate, root)
    }
}
private actor PackagePermissionGate { private var allowed = true; func set(_ value: Bool) { allowed = value }; func check() -> Bool { allowed } }
