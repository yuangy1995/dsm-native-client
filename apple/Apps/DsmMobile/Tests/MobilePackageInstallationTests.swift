import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobilePackageInstallationTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for value in values { try? FileManager.default.removeItem(at: value) }
        try await super.tearDown()
    }
    func test目录详情和更新仅采用明确候选() async throws {
        let (model, _, _, _) = try make(); await model.refresh()
        XCTAssertEqual(model.catalog.phase, .content); XCTAssertTrue(model.canStart)
        let entries = try XCTUnwrap(model.catalog.value?.entries)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.filter(\.isUpdateAvailable).map(\.packageID), ["SyntheticPackage"])
        XCTAssertEqual(entries.filter(\.isBeta).map(\.packageID), ["BetaPackage"])
        XCTAssertEqual(entries.filter { !$0.isOfficial }.map(\.packageID), ["CommunityPackage"])
        XCTAssertEqual(mobilePackagePlainText(try XCTUnwrap(entries.first?.description)), "Synthetic package description.")
    }
    func test第三方失败仍保留官方目录且部分已安装清单拒绝() async throws {
        let (model, _, _, _) = try make(mode: "nas-package-install-community-error"); await model.refresh()
        XCTAssertFalse(try XCTUnwrap(model.catalog.value).communityAvailable); XCTAssertTrue(model.canStart)
        let (partial, transport, _, _) = try make(mode: "nas-package-install-partial"); await partial.refresh()
        XCTAssertEqual(partial.catalog.phase, .error); XCTAssertFalse(partial.canStart)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test取消只读准备不产生安装请求() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await prepare(model)
        XCTAssertNotNil(model.plan); model.discardPlan(); XCTAssertNil(model.plan)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty); XCTAssertTrue(model.entries.isEmpty)
    }
    func test安装完整依赖按顺序完成并受保护() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-install-dependencies"); await model.refresh(); await prepare(model)
        XCTAssertEqual(model.plan?.items.map { $0.package.packageID }, ["Dependency", "NewPackage"])
        start(model); XCTAssertTrue(model.blocksChanges); XCTAssertFalse(model.canStart)
        await model.waitForOperation()
        XCTAssertEqual(model.progress?.phase, .completed); XCTAssertEqual(model.entries.first?.phase, .completed)
        XCTAssertEqual(model.entries.first?.completedCount, 2); XCTAssertTrue(model.canStart)
        let writes = await transport.writes; XCTAssertEqual(writes.filter { $0["method"] == "install" }.map { $0["name"] }, ["Dependency", "NewPackage"])
    }
    func test写前撤销权限零安装() async throws {
        let (model, transport, gate, _) = try make(); await model.refresh(); await prepare(model)
        await gate.set(false); start(model); await model.waitForOperation()
        XCTAssertEqual(model.error, .denied); XCTAssertFalse(model.allowed)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test明确拒绝不保留未知安装或自动重试() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-install-denied"); await model.refresh(); await prepare(model)
        start(model); await model.waitForOperation()
        XCTAssertEqual(model.progress?.phase, .failed); XCTAssertEqual(model.entries.first?.phase, .failed)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test未知安装重启只读恢复新版本不重放() async throws {
        let (model, transport, _, root) = try make(mode: "nas-package-install-unknown"); await model.refresh(); await prepare(model)
        start(model); await model.waitForOperation()
        XCTAssertEqual(model.progress?.phase, .unverified); XCTAssertTrue(model.blocksChanges)
        let id = try XCTUnwrap(model.entries.first?.id); model.deactivate()
        let (next, other, _, _) = try make(mode: "nas-package-install-recover", root: root); await next.refresh()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .completed); XCTAssertTrue(next.canStart)
        let writes = await transport.writes, recovered = await other.writes
        XCTAssertEqual(writes.count, 1); XCTAssertTrue(recovered.isEmpty)
    }
    func test新读取失去管理权限不能解除未知保护() async throws {
        let (model, _, _, root) = try make(mode: "nas-package-install-unknown"); await model.refresh(); await prepare(model)
        start(model); await model.waitForOperation(); let id = try XCTUnwrap(model.entries.first?.id); model.deactivate()
        let (next, transport, gate, _) = try make(mode: "nas-package-install-recover", root: root); await gate.set(false); await next.refresh()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .active); XCTAssertFalse(next.canStart)
        await gate.set(true); await next.refresh(); XCTAssertEqual(next.recovery.entry(id)?.phase, .completed)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test恢复不能认领从未提交的剩余依赖() async throws {
        let root = newRoot(), store = MobilePackageInstallationStore(root: root), context = String(repeating: "a", count: 64)
        let entry = try store.reserve(context: context, totalCount: 2, isUpload: false), operation = UUID()
        let package = NasPackageCatalogEntry(packageID: "Dependency", name: "Dependency", version: "2.0")
        try store.checkpoint(entry.id, .init(id: operation, step: .install, stage: .willSubmit, package: package, completedCount: 0, totalCount: 2))
        store.end(entry.id)
        let restored = MobilePackageInstallationStore(root: root)
        try restored.resolve([NasPackage(id: "Dependency", name: "Dependency", version: "2.0", status: "running", statusDescription: nil, packageDescription: nil, installType: "user", installedAt: nil)], context: context)
        XCTAssertEqual(restored.entry(entry.id)?.completedCount, 1); XCTAssertEqual(restored.entry(entry.id)?.phase, .partial)
    }
    func test未提交安装的下载或上传重启标为准备中断() throws {
        for step in [NasPackageInstallationCheckpoint.Step.upload, .download] {
            let root = newRoot(), store = MobilePackageInstallationStore(root: root), context = String(repeating: "a", count: 64)
            let entry = try store.reserve(context: context, totalCount: 1, isUpload: step == .upload)
            let package = step == .upload ? nil : NasPackageCatalogEntry(packageID: "NewPackage", name: "New", version: "2.0")
            try store.checkpoint(entry.id, .init(id: UUID(), step: step, stage: .willSubmit, package: package, completedCount: 0, totalCount: 1)); store.end(entry.id)
            let restored = MobilePackageInstallationStore(root: root)
            XCTAssertEqual(restored.entry(entry.id)?.phase, .interrupted); XCTAssertFalse(restored.protects(context))
            XCTAssertEqual(restored.entry(entry.id)?.completedCount, 0)
        }
    }
    func test同版本重装未知不能由原版本解锁() async throws {
        let (model, transport, _, root) = try make(mode: "nas-package-install-reinstall"); await model.refresh()
        let file = try syntheticFile(); model.upload(file, activation: model.activation); await model.waitForOperation()
        XCTAssertEqual(model.progress?.phase, .needsOptions)
        model.configure(volume: "/volume1", startAfterInstall: false, licenseAccepted: true, values: [:], activation: model.activation); await model.waitForOperation()
        XCTAssertEqual(model.progress?.phase, .unverified)
        let id = try XCTUnwrap(model.entries.first?.id); model.deactivate()
        let (next, other, _, _) = try make(mode: "nas-package-install-reinstall", root: root); await next.refresh()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .active); XCTAssertFalse(next.canStart)
        let writes = await transport.writes, recovered = await other.writes
        XCTAssertEqual(writes.filter { $0["method"] == "upgrade" }.count, 1); XCTAssertTrue(recovered.isEmpty)
    }
    func test许可及必填选项拒绝无效值并保持原类型() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await prepare(model, id: "CommunityPackage")
        start(model); await model.waitForOperation(); XCTAssertEqual(model.progress?.phase, .needsOptions)
        model.configure(volume: "/volume1", startAfterInstall: true, licenseAccepted: false, values: [:], activation: model.activation)
        model.configure(volume: "/volume1", startAfterInstall: true, licenseAccepted: true, values: ["label": .text("")], activation: model.activation)
        let before = await transport.writes; XCTAssertEqual(before.count, 1)
        model.configure(volume: "/volume1", startAfterInstall: false, licenseAccepted: true,
            values: ["label": .text("chosen"), "secret": .text("synthetic-option-secret"), "enabled": .flag(false), "mode": .text("extended")], activation: model.activation)
        await model.waitForOperation(); XCTAssertEqual(model.progress?.phase, .completed)
        let writes = await transport.writes, final = try XCTUnwrap(writes.last)
        let extra = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((final["extra_values"] ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(extra["enabled"] as? Bool, false); XCTAssertEqual(extra["secret"] as? String, "synthetic-option-secret")
        XCTAssertEqual(final["check_codesign"], "true"); XCTAssertEqual(final["force"], "true")
    }
    func test手动上传只清理本次目标且不安装() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        model.upload(try syntheticFile(), activation: model.activation); await model.waitForOperation()
        XCTAssertTrue(model.canCancel); model.cancel(activation: model.activation); await model.waitForOperation()
        XCTAssertEqual(model.progress?.phase, .cancelled); XCTAssertEqual(model.entries.first?.phase, .cancelled)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["upload", "clean"]); XCTAssertEqual(writes.last?["task_id"], "owned-ManualPackage")
    }
    func test签名或不支持脚本表单停止且清理仅一次() async throws {
        for mode in ["nas-package-install-signature", "nas-package-install-custom"] {
            let (model, transport, _, _) = try make(mode: mode); await model.refresh()
            model.upload(try syntheticFile(), activation: model.activation); await model.waitForOperation()
            XCTAssertNotNil(model.error); XCTAssertFalse(model.canConfigure)
            let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["upload", "clean"])
        }
    }
    func test下载期间可请求取消且不提交正式安装() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-install-slow"); await model.refresh(); await prepare(model)
        start(model)
        for _ in 0..<100 { if model.canCancel { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.canCancel); model.cancel(activation: model.activation); await model.waitForOperation()
        XCTAssertEqual(model.progress?.phase, .cancelled); XCTAssertFalse(model.canCancel)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["install", "cancel"])
    }
    func test旧账号迟到回执不能进入新页面且不推进依赖() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-install-dependencies"); await model.refresh(); await prepare(model); await transport.holdWrites()
        start(model); let id = try XCTUnwrap(model.currentEntryID)
        for _ in 0..<200 { if await transport.writes.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let original = model.context; model.deactivate(); await transport.resume()
        for _ in 0..<200 { if !model.recovery.isExecuting(id) { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.progress); XCTAssertNil(model.plan); XCTAssertEqual(model.recovery.entry(id)?.context, original)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test同账号更换仓库使旧确认失效() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await prepare(model)
        let token = model.activation, planID = try XCTUnwrap(model.plan?.id), profile = try profile()
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { true }, otherOperationsAllowChanges: { true })
        model.start(planID: planID, volumes: [:], startAfterInstall: true, activation: token)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty); XCTAssertNil(model.plan)
    }
    func test损坏或磁盘保存失败均零安装() async throws {
        for corrupt in [true, false] {
            let root = newRoot()
            if corrupt { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try Data("bad".utf8).write(to: root.appendingPathComponent("package-installations-v1.json")) }
            else { try Data().write(to: root) }
            let (model, transport, _, _) = try make(root: root); await model.refresh(); await prepare(model)
            start(model); await model.waitForOperation()
            XCTAssertFalse(model.canStart)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test恢复文件不含套件明文路径口令会话并排除备份() async throws {
        let (model, _, _, root) = try make(); await model.refresh()
        model.upload(try syntheticFile(), activation: model.activation); await model.waitForOperation()
        model.configure(volume: "/volume1", startAfterInstall: false, licenseAccepted: true, values: ["secret": .text("synthetic-option-secret")], activation: model.activation)
        await model.waitForOperation()
        let text = try String(contentsOf: root.appendingPathComponent("package-installations-v1.json"), encoding: .utf8)
        for secret in ["ManualPackage", "Manual package", "/volume1", "owned-", "synthetic-option-secret", "synthetic-session", "example.invalid", "operator"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
    func test证书变化保留目标保护且停止后续读取() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-install-trust"); await model.refresh(); await prepare(model)
        start(model); await model.waitForOperation()
        XCTAssertEqual(model.error, .trust); XCTAssertFalse(model.allowed); XCTAssertTrue(model.blocksChanges)
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "install")
    }
    func test套件设置未结束时安装入口保持互斥() async throws {
        let root = newRoot(), transport = MobilePackageInstallationUITransport(), profile = try profile()
        let parent = MobilePackageCenterModel(root: root)
        parent.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { true })
        await parent.installation.refresh(); XCTAssertTrue(parent.installation.canStart)
        let source = NasPackageSource(name: "Synthetic", url: "https://source.example.invalid/")
        let entry = try parent.recovery.reserve(.saveSource(source, replacing: nil), context: try XCTUnwrap(parent.context))
        XCTAssertFalse(parent.installation.canStart); parent.recovery.end(entry.id)
    }
    func test文件选择回调绑定原连接且失败有恢复提示() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        let token = model.activation, file = try syntheticFile(), profile = try profile()
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { true }, otherOperationsAllowChanges: { true })
        XCTAssertFalse(model.selectFile(.success(file), activation: token))
        XCTAssertFalse(model.selectFile(.failure(CocoaError(.userCancelled)), activation: model.activation))
        XCTAssertTrue(model.selectFile(.failure(CocoaError(.fileReadNoSuchFile)), activation: model.activation))
        XCTAssertEqual(model.error, .read); XCTAssertNotNil(model.message)
        let count = await transport.uploadCount; XCTAssertEqual(count, 0)
    }

    func test目录能力不足不阻断独立手动上传() async throws {
        let root = newRoot(), model = MobilePackageInstallationModel(root: root), transport = MobilePackageInstallationUITransport(), profile = try profile()
        model.configure(profile: profile, repository: try repository(transport, profile: profile, serverVersion: 1), authorize: { true }, otherOperationsAllowChanges: { true })
        await model.refresh(); XCTAssertEqual(model.catalog.phase, .unavailable)
        XCTAssertFalse(model.canStart); XCTAssertTrue(model.canUpload)
        model.upload(try syntheticFile(), activation: model.activation); await model.waitForOperation()
        XCTAssertEqual(model.progress?.phase, .needsOptions)
        let count = await transport.uploadCount; XCTAssertEqual(count, 1)
    }
    func test目录能力缺失仍可只读恢复已提交安装() async throws {
        let (old, _, _, root) = try make(mode: "nas-package-install-unknown"); await old.refresh(); await prepare(old); start(old); await old.waitForOperation()
        let id = try XCTUnwrap(old.entries.first?.id); old.deactivate()
        let next = MobilePackageInstallationModel(root: root), transport = MobilePackageInstallationUITransport(mode: "nas-package-install-recover"), profile = try profile()
        next.configure(profile: profile, repository: try repository(transport, profile: profile, serverVersion: 1), authorize: { true }, otherOperationsAllowChanges: { true })
        await next.refresh(); XCTAssertEqual(next.catalog.phase, .unavailable); XCTAssertEqual(next.recovery.entry(id)?.phase, .completed)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test同版本异步接受不能当成同步安装完成() throws {
        for synchronous in [false, true] {
            let root = newRoot(), store = MobilePackageInstallationStore(root: root), context = String(repeating: "a", count: 64)
            let entry = try store.reserve(context: context, totalCount: 1, isUpload: true), operation = UUID()
            let package = NasPackageCatalogEntry(packageID: "ManualPackage", name: "Manual", version: "2.0", installedVersion: "2.0")
            for stage in [NasPackageInstallationCheckpoint.Stage.willSubmit, .accepted] {
                try store.checkpoint(entry.id, .init(id: operation, step: .install, stage: stage, package: package, completedCount: 0, totalCount: 1, isSynchronousInstallation: synchronous))
            }
            store.end(entry.id)
            let restored = MobilePackageInstallationStore(root: root)
            try restored.resolve([NasPackage(id: "ManualPackage", name: "Manual", version: "2.0", status: "stopped", statusDescription: nil, packageDescription: nil, installType: "user", installedAt: nil)], context: context)
            XCTAssertEqual(restored.entry(entry.id)?.phase, synchronous ? .completed : .active)
        }
    }

    func test手动上传证书错误显示信任提示并停止链路() async throws {
        let (model, transport, _, _) = try make(mode: "nas-package-install-upload-trust"); await model.refresh()
        model.upload(try syntheticFile(), activation: model.activation); await model.waitForOperation()
        XCTAssertEqual(model.error, .trust); XCTAssertFalse(model.allowed); XCTAssertFalse(model.canUpload)
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "upload")
        XCTAssertFalse(calls.contains { ["clean", "delete", "install"].contains($0["method"] ?? "") })
    }

    func test新准备失败不能沿用上次安装成功页面() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await prepare(model); start(model); await model.waitForOperation()
        XCTAssertEqual(model.progress?.phase, .completed)
        await transport.setMode("nas-package-install-beta-agreement")
        await model.refresh(); await prepare(model, id: "BetaPackage")
        XCTAssertNil(model.plan); XCTAssertNil(model.progress); XCTAssertNotNil(model.error)
        XCTAssertEqual(model.entries.first?.phase, .completed)
        let writes = await transport.writes; XCTAssertEqual(writes.filter { $0["method"] == "install" }.count, 1)
    }

    private func prepare(_ model: MobilePackageInstallationModel, id: String = "NewPackage") async {
        guard let entry = model.catalog.value?.entries.first(where: { $0.packageID == id }) else { return }
        await model.prepare([entry], activation: model.activation)
    }
    private func start(_ model: MobilePackageInstallationModel) { if let plan = model.plan { model.start(planID: plan.id, volumes: [:], startAfterInstall: false, activation: model.activation) } }
    private func newRoot() -> URL { let value = FileManager.default.temporaryDirectory.appendingPathComponent("PackageInstallTests-\(UUID())"); roots.append(value); return value }
    private func syntheticFile() throws -> URL { let root = newRoot(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); let file = root.appendingPathComponent("Synthetic.spk"); try Data("synthetic bytes".utf8).write(to: file); return file }
    private func profile() throws -> NasProfile { try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000022")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "operator") }
    private func repository(_ transport: MobilePackageInstallationUITransport, profile: NasProfile, serverVersion: Int = 2) throws -> DsmNasAdministrationRepository {
        let versions = [DsmAPIName.corePackage: 2, DsmAPIName.corePackageServer: serverVersion, DsmAPIName.corePackageInstallation: 2,
            DsmAPIName.corePackageDownload: 1, DsmAPIName.corePackageInfo: 1, DsmAPIName.corePackageSetting: 1, DsmAPIName.corePackageSettingVolume: 1]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version)) }))
        return try .init(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func make(mode: String = "nas-package-install", root: URL? = nil) throws -> (MobilePackageInstallationModel, MobilePackageInstallationUITransport, InstallationPermissionGate, URL) {
        let root = root ?? newRoot(), transport = MobilePackageInstallationUITransport(mode: mode), gate = InstallationPermissionGate(), profile = try profile()
        let model = MobilePackageInstallationModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { await gate.check() }, otherOperationsAllowChanges: { true })
        return (model, transport, gate, root)
    }
}
private actor InstallationPermissionGate { private var allowed = true; func set(_ value: Bool) { allowed = value }; func check() -> Bool { allowed } }
