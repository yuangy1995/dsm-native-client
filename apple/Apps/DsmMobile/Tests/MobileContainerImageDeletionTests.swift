import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileContainerImageDeletionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = roots; roots = []; return values }
        for value in values { try? FileManager.default.removeItem(at: value) }
        try await super.tearDown()
    }
    func test单标签删除保留同映像其他标签且只提交一次() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        let target = try image("stable", model), id = try start([target.id], model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .succeeded)
        XCTAssertEqual(model.entries.first?.removedTargetIDs.count, 1)
        XCTAssertTrue(model.targets.contains { $0.repository == "sample/web" && $0.tag == "latest" })
        XCTAssertFalse(model.targets.contains { $0.id == target.id })
        XCTAssertEqual(model.names[ContainerImagePullRecovery.digest(target.id)], "sample/web:stable")
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        model.removeRecord(id); XCTAssertTrue(model.entries.isEmpty)
    }
    func test部分删除逐项显示并只读恢复剩余标签() async throws {
        let (model, transport, _, _) = try make(mode: "containers-image-delete-partial"); await model.refresh()
        let first = try image("stable", model), second = try image("v1", model)
        let id = try start([first.id, second.id], model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .submitted)
        XCTAssertEqual(model.entries.first?.removedTargetIDs, [ContainerImagePullRecovery.digest(first.id)])
        XCTAssertFalse(model.canDelete(ids: [second.id]))
        XCTAssertThrowsError(try model.recovery.remove(id, context: try XCTUnwrap(model.context)))
        await transport.removeWebTags(); await model.refresh()
        XCTAssertEqual(model.entries.first?.phase, .succeeded); XCTAssertEqual(model.removedCount, 2)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test无标签使用完整映像身份且其他映像不受影响() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        let target = try XCTUnwrap(model.targets.first { $0.tag == "<none>" })
        let id = try start([target.id], model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .succeeded)
        XCTAssertTrue(model.targets.contains { $0.repository == "sample/web" })
        let writes = await transport.writes
        let payload = try XCTUnwrap(writes.first?["images"])
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: String]])
        XCTAssertEqual(objects, [["identity": "synthetic-bare-image"]])
    }
    func test停止容器占用及无标签别名不能选择删除() async throws {
        let (model, transport, _, _) = try make(mode: "containers-image-delete-bare-alias"); await model.refresh()
        let used = try XCTUnwrap(model.targets.first { $0.repository == "sample/used" })
        let bare = try XCTUnwrap(model.targets.first { $0.tag == "<none>" })
        XCTAssertTrue(used.isInUse); XCTAssertTrue(model.containsTaggedAliases(bare))
        XCTAssertFalse(model.canDelete(ids: [used.id])); XCTAssertFalse(model.canDelete(ids: [bare.id]))
        XCTAssertNil(model.confirmation(ids: [used.id, bare.id]))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test确认后标签换映像不得删除新目标() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        let target = try image("stable", model), confirmation = try XCTUnwrap(model.confirmation(ids: [target.id]))
        await transport.replaceWebImage()
        let id = try XCTUnwrap(model.perform(confirmation)); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .rejected)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test权限在操作前或最后提交检查撤回均零写入() async throws {
        for checks in [0, 1] {
            let (model, transport, gate, _) = try make(); await model.refresh()
            let target = try image("stable", model); await gate.allowChecks(checks)
            let id = try start([target.id], model); await model.waitForOperation(id)
            XCTAssertEqual(model.error, .denied); XCTAssertFalse(model.allowed)
            XCTAssertEqual(model.entries.first?.phase, .rejected)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test无回执跨重启仅原范围读取且不重发() async throws {
        let (model, _, _, root) = try make(mode: "containers-image-delete-unknown"); await model.refresh()
        let target = try image("stable", model), id = try start([target.id], model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .submitted); XCTAssertFalse(model.entries.first?.accepted ?? true)
        let (next, transport, _, _) = try make(mode: "containers-image-delete-recovered", root: root)
        await next.refresh(); XCTAssertEqual(next.entries.first?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test接受后断网跨重启恢复原结果() async throws {
        let (model, _, _, root) = try make(mode: "containers-image-delete-offline"); await model.refresh()
        let target = try image("stable", model), id = try start([target.id], model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .submitted); XCTAssertTrue(model.entries.first?.accepted == true)
        let (next, reads, _, _) = try make(mode: "containers-image-delete-recovered", root: root, containerCapability: false)
        await next.refresh(); XCTAssertEqual(next.entries.first?.phase, .succeeded)
        XCTAssertFalse(next.allowed); XCTAssertEqual(next.error, .unavailable)
        let calls = await reads.calls; XCTAssertTrue(calls.allSatisfy { $0["method"] == "list" && $0["api"] == DsmAPIName.dockerImage })
    }
    func test明确拒绝不会被外部删除覆盖() async throws {
        let (model, transport, _, _) = try make(mode: "containers-image-delete-denied"); await model.refresh()
        let target = try image("stable", model), id = try start([target.id], model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .rejected); XCTAssertEqual(model.entries.first?.failure, .denied)
        await transport.removeWebTags(); await model.refresh()
        XCTAssertEqual(model.entries.first?.phase, .rejected); XCTAssertTrue(model.entries.first?.removedTargetIDs.isEmpty == true)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test重复点击及执行期间移除记录被阻止() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await transport.holdWrites()
        let confirmation = try XCTUnwrap(model.confirmation(ids: [image("stable", model).id]))
        let id = try XCTUnwrap(model.perform(confirmation)); await transport.waitForWrite()
        XCTAssertNil(model.perform(confirmation))
        XCTAssertThrowsError(try model.recovery.remove(id, context: try XCTUnwrap(model.context)))
        await transport.release(); await model.waitForOperation(id)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test切换账号迟到回执仅更新原记录() async throws {
        let (model, transport, _, root) = try make(); await model.refresh(); await transport.holdWrites()
        let context = try XCTUnwrap(model.context), target = try image("stable", model), id = try start([target.id], model)
        await transport.waitForWrite()
        let other = try profile(username: "other"), otherTransport = MobileContainerImageDeletionUITransport()
        model.configure(profile: other, repository: try repository(otherTransport, profile: other), authorize: { true })
        await transport.release(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries.isEmpty); XCTAssertTrue(model.names.isEmpty)
        let old = try XCTUnwrap(MobileContainerImageDeletionStore(root: root).entry(id))
        XCTAssertEqual(old.context, context); XCTAssertTrue(old.accepted); XCTAssertTrue(old.isProtected)
    }
    func test相同账号重连丢弃旧确认而未提交记录不自动执行() async throws {
        let (model, _, _, root) = try make(); await model.refresh()
        let confirmation = try XCTUnwrap(model.confirmation(ids: [image("stable", model).id]))
        let transport = MobileContainerImageDeletionUITransport(), profile = try profile()
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { true })
        await model.refresh(); XCTAssertNil(model.perform(confirmation))
        let saved = try model.recovery.reserve(confirmation.request, context: try XCTUnwrap(model.context))
        let restored = MobileContainerImageDeletionStore(root: root)
        XCTAssertEqual(restored.entry(saved.id)?.phase, .skipped)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test证书失败停止后续读取并保留未知目标() async throws {
        let (model, transport, _, _) = try make(mode: "containers-image-delete-trust"); await model.refresh()
        let target = try image("stable", model), id = try start([target.id], model); await model.waitForOperation(id)
        XCTAssertEqual(model.error, .trust); XCTAssertFalse(model.allowed)
        XCTAssertEqual(model.entries.first?.phase, .submitted)
        let calls = await transport.calls; XCTAssertEqual(calls.filter { $0["method"] == "list" && $0["api"] == DsmAPIName.dockerImage }.count, 2)
    }
    func test损坏或无法写入记录时零删除() async throws {
        for corrupt in [false, true] {
            let root = newRoot()
            if corrupt {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("invalid".utf8).write(to: root.appendingPathComponent("image-deletions-v1.json"))
            } else { try Data("file".utf8).write(to: root) }
            let (model, transport, _, _) = try make(root: root); await model.refresh()
            if let target = model.targets.first, let confirmation = model.confirmation(ids: [target.id]) { XCTAssertNil(model.perform(confirmation)) }
            XCTAssertTrue(model.recovery.failed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test下载保护跨重启同时阻止原标签及原裸映像删除() async throws {
        let root = newRoot(), pulls = MobileContainerImagePullStore(root: root), context = MobileWorkspaceIdentity(try profile()).storageIdentifier
        let request = ContainerImagePullRequest(repository: "sample/web", tag: "stable", isConfirmed: true)
        let saved = try pulls.reserve(request, context: context)
        try pulls.checkpoint(saved.id, .willSubmit(.init(id: saved.id, target: saved.recovery.target,
            baselineImageIDs: [ContainerImagePullRecovery.digest("synthetic-bare-image")])))
        pulls.end(saved.id)
        let restored = MobileContainerImagePullStore(root: root)
        let (model, transport, _, _) = try make(root: root, pulls: restored); await model.refresh()
        XCTAssertFalse(model.canDelete(ids: [try image("stable", model).id]))
        XCTAssertFalse(model.canDelete(ids: [try XCTUnwrap(model.targets.first { $0.tag == "<none>" }).id]))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test未知删除跨重启阻止下载同标签() async throws {
        let (model, _, _, root) = try make(mode: "containers-image-delete-unknown"); await model.refresh()
        let target = try image("stable", model), id = try start([target.id], model); await model.waitForOperation(id)
        let restored = MobileContainerImageDeletionStore(root: root), transport = MobileContainerImageDeletionUITransport(), profile = try profile()
        let pull = MobileContainerImagePullModel(root: root)
        pull.configure(profile: profile, repository: try repository(transport, profile: profile), deletionRecovery: restored, authorize: { true })
        await pull.refresh(); await pull.search("sample"); await pull.select(try XCTUnwrap(pull.results.first))
        XCTAssertFalse(pull.canDownload(repository: "sample/web", tag: "stable"))
        XCTAssertNil(pull.confirmation(repository: "sample/web", tag: "stable"))
        let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["method"] == "pull_start" })
    }
    func test已恢复裸映像删除在下载写前再次阻止同原ID() async throws {
        let root = newRoot(), store = MobileContainerImageDeletionStore(root: root), profile = try profile()
        let context = MobileWorkspaceIdentity(profile).storageIdentifier
        let original = ContainerImage(id: ContainerImage.selectionID(imageID: "synthetic-web-image", repository: "sample/web", tag: "<none>"),
            repository: "sample/web", tag: "<none>", sourceImageID: "synthetic-web-image")
        let request = ContainerImageDeletionRequest(targets: [original], isConfirmed: true)
        let entry = try store.reserve(request, context: context)
        try store.checkpoint(entry.id, .willSubmit(request.recovery)); store.end(entry.id)
        let restored = MobileContainerImageDeletionStore(root: root), transport = MobileContainerImageDeletionUITransport()
        let pull = MobileContainerImagePullModel(root: root)
        pull.configure(profile: profile, repository: try repository(transport, profile: profile), deletionRecovery: restored, authorize: { true })
        await pull.refresh(); await pull.search("sample"); await pull.select(try XCTUnwrap(pull.results.first))
        let id = try XCTUnwrap(pull.perform(try XCTUnwrap(pull.confirmation(repository: "sample/web", tag: "stable"))))
        await pull.waitForOperation(id)
        XCTAssertEqual(pull.error, .changed); XCTAssertEqual(pull.entries.first?.phase, .rejected)
        let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["method"] == "pull_start" })
    }
    func test删除恢复文件只有摘要且排除备份() async throws {
        let (model, _, _, root) = try make(); await model.refresh()
        let target = try image("stable", model), id = try start([target.id], model); await model.waitForOperation(id)
        let text = try String(contentsOf: root.appendingPathComponent("image-deletions-v1.json"), encoding: .utf8)
        for value in ["sample/web", "synthetic-web-image", "fixture.example.invalid", "operator", "synthetic-session"] { XCTAssertFalse(text.contains(value)) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    private func image(_ tag: String, _ model: MobileContainerImageDeletionModel) throws -> ContainerImage {
        try XCTUnwrap(model.targets.first { $0.repository == "sample/web" && $0.tag == tag })
    }
    private func start(_ ids: Set<String>, _ model: MobileContainerImageDeletionModel) throws -> UUID {
        try XCTUnwrap(model.perform(try XCTUnwrap(model.confirmation(ids: ids))))
    }
    private func newRoot() -> URL { let value = FileManager.default.temporaryDirectory.appendingPathComponent("ImageDeletionTests-\(UUID())"); roots.append(value); return value }
    private func profile(username: String = "operator") throws -> NasProfile {
        try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000024")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username)
    }
    private func repository(_ transport: MobileContainerImageDeletionUITransport, profile: NasProfile, containerCapability: Bool = true) throws -> DsmServiceManagementRepository {
        let names = [DsmAPIName.dockerImage, DsmAPIName.dockerRegistry] + (containerCapability ? [DsmAPIName.dockerContainer] : [])
        return try .init(profile: profile, capabilities: .init(Dictionary(uniqueKeysWithValues: names.map {
            ($0, .init(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1))
        })), session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func make(mode: String = "containers-image-delete", root: URL? = nil, containerCapability: Bool = true,
                      pulls: MobileContainerImagePullStore? = nil) throws -> (MobileContainerImageDeletionModel, MobileContainerImageDeletionUITransport, ImageDeletionPermissionGate, URL) {
        let root = root ?? newRoot(), transport = MobileContainerImageDeletionUITransport(mode: mode), profile = try profile(), gate = ImageDeletionPermissionGate()
        let model = MobileContainerImageDeletionModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile, containerCapability: containerCapability),
            pullRecovery: pulls, authorize: { await gate.check() })
        return (model, transport, gate, root)
    }
}

private actor ImageDeletionPermissionGate {
    private var remaining: Int?
    func allowChecks(_ value: Int) { remaining = value }
    func check() -> Bool {
        guard let remaining else { return true }
        self.remaining = max(0, remaining - 1); return remaining > 0
    }
}
