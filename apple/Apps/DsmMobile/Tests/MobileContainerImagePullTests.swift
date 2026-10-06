import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileContainerImagePullTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = roots; roots = []; return values }
        for value in values { try? FileManager.default.removeItem(at: value) }
        try await super.tearDown()
    }
    func test搜索标签与下载经过实际适配器且只启动一次() async throws {
        let (model, transport, _, _) = try make(); try await prepare(model)
        XCTAssertEqual(model.tags, ["latest", "stable", "v1"])
        let id = try start(model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .downloading)
        XCTAssertFalse(model.canDownload(repository: "sample/web", tag: "stable"))
        await model.refresh(); XCTAssertEqual(model.entries.first?.phase, .ready)
        XCTAssertEqual(model.names[id], "sample/web:stable")
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test查询为空和失败重试保持独立状态() async throws {
        let (model, _, _, _) = try make(mode: "containers-images-search-error"); await model.refresh()
        await model.search("sample"); XCTAssertEqual(model.searchError, .read); XCTAssertTrue(model.results.isEmpty)
        await model.search("sample"); XCTAssertNil(model.searchError); XCTAssertEqual(model.results.count, 1)
        await model.search("no-match"); XCTAssertTrue(model.hasSearched); XCTAssertTrue(model.results.isEmpty); XCTAssertNil(model.searchError)
    }
    func test标签失败可重试且空标签不能提交() async throws {
        let (model, transport, _, _) = try make(mode: "containers-images-tags-error"); await model.refresh(); await model.search("sample")
        let image = try XCTUnwrap(model.results.first); await model.select(image)
        XCTAssertEqual(model.tagsError, .read); XCTAssertFalse(model.canDownload(repository: image.name, tag: "stable"))
        await model.select(image); XCTAssertNil(model.tagsError); XCTAssertTrue(model.canDownload(repository: image.name, tag: "stable"))
        await transport.setMode("containers-images-no-tags"); await model.select(image)
        XCTAssertTrue(model.tags.isEmpty); XCTAssertFalse(model.canDownload(repository: image.name, tag: "stable"))
    }
    func test权限撤回后零提交且结果说明被拒绝() async throws {
        let (model, transport, gate, _) = try make(); try await prepare(model); await gate.set(false)
        let id = try start(model); await model.waitForOperation(id)
        XCTAssertEqual(model.error, .denied); XCTAssertFalse(model.allowed)
        XCTAssertEqual(model.entries.first?.phase, .rejected); XCTAssertEqual(model.entries.first?.failure, .denied)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test重复点击及执行中移除记录被阻止() async throws {
        let (model, transport, _, _) = try make(); try await prepare(model); await transport.holdWrites()
        let confirmation = try XCTUnwrap(model.confirmation(repository: "sample/web", tag: "stable"))
        let id = try XCTUnwrap(model.perform(confirmation)); await transport.waitForWrite()
        XCTAssertNil(model.perform(confirmation))
        XCTAssertThrowsError(try model.recovery.remove(id, context: try XCTUnwrap(model.context)))
        await transport.release(); await model.waitForOperation(id)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test有回执跨重启只查询原任务并且不依赖Registry() async throws {
        let (model, transport, _, root) = try make(mode: "containers-images-offline"); try await prepare(model)
        let id = try start(model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .needsReview)
        let (next, reads, _, _) = try make(mode: "containers-images-recovered", root: root, registry: false)
        await next.refresh(); XCTAssertEqual(next.entries.first?.phase, .ready); XCTAssertFalse(next.available)
        XCTAssertEqual(next.names[id], "sample/web:stable")
        let calls = await reads.calls; XCTAssertEqual(calls.map { $0["method"] }, ["pull_status", "list"])
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test无回执跨重启不得从旧映像认领或重发() async throws {
        let (model, _, _, root) = try make(mode: "containers-images-unknown"); try await prepare(model)
        let id = try start(model); await model.waitForOperation(id)
        let (next, reads, _, _) = try make(mode: "containers-images-recovered", root: root)
        await next.refresh(); XCTAssertEqual(next.entries.first?.phase, .awaitingReceipt)
        let calls = await reads.calls; XCTAssertTrue(calls.isEmpty)
        try await prepare(next); XCTAssertNil(next.confirmation(repository: "sample/web", tag: "stable"))
        XCTAssertThrowsError(try next.recovery.remove(id, context: try XCTUnwrap(next.context)))
    }
    func test明确拒绝不会被外部完成覆盖() async throws {
        let (model, transport, _, _) = try make(mode: "containers-images-rejected"); try await prepare(model)
        let id = try start(model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.phase, .rejected); XCTAssertEqual(model.entries.first?.failure, .denied)
        await transport.setMode("containers-images-recovered"); await model.refresh()
        XCTAssertEqual(model.entries.first?.phase, .rejected)
        let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["method"] == "pull_status" })
    }
    func test读取失败保留原任务且恢复成功后才能移除记录() async throws {
        let (model, transport, _, _) = try make(mode: "containers-images-offline"); try await prepare(model)
        let id = try start(model); await model.waitForOperation(id)
        XCTAssertTrue(model.hasPollableTasks)
        await transport.setMode("containers-images-recovered"); await model.refresh()
        XCTAssertEqual(model.entries.first?.phase, .ready); model.removeRecord(id); XCTAssertTrue(model.entries.isEmpty)
    }
    func test任务返回其他目标或明确失败各自保留正确状态() async throws {
        for mode in ["containers-images-mismatch", "containers-images-failed"] {
            let (model, _, _, _) = try make(mode: mode); try await prepare(model)
            let id = try start(model); await model.waitForOperation(id)
            XCTAssertEqual(model.entries.first?.phase, mode.hasSuffix("failed") ? .rejected : .needsReview)
            XCTAssertEqual(model.names[id], "sample/web:stable")
        }
    }
    func test恢复前权限撤回不得发送读取() async throws {
        let (model, _, _, root) = try make(mode: "containers-images-offline"); try await prepare(model)
        let id = try start(model); await model.waitForOperation(id)
        let (next, reads, gate, _) = try make(mode: "containers-images-recovered", root: root)
        await gate.set(false); await next.refresh()
        XCTAssertEqual(next.error, .denied); XCTAssertEqual(next.entries.first?.phase, .needsReview)
        let calls = await reads.calls; XCTAssertTrue(calls.isEmpty)
    }
    func test证书失败停止轮询并保留原任务() async throws {
        let (model, transport, _, _) = try make(mode: "containers-images-trust"); try await prepare(model)
        let id = try start(model); await model.waitForOperation(id)
        XCTAssertEqual(model.error, .trust); XCTAssertFalse(model.hasPollableTasks); XCTAssertFalse(model.allowed)
        XCTAssertEqual(model.entries.first?.phase, .needsReview)
        let calls = await transport.calls; XCTAssertEqual(calls.filter { $0["method"] == "pull_status" }.count, 1)
    }
    func test切换账号迟到回执只保存原记录() async throws {
        let (model, transport, _, root) = try make(); try await prepare(model); await transport.holdWrites()
        let oldContext = try XCTUnwrap(model.context), id = try start(model); await transport.waitForWrite()
        let otherProfile = try profile(username: "other"), other = MobileContainerImageUITransport()
        model.configure(profile: otherProfile, repository: try repository(other, profile: otherProfile), authorize: { true })
        await transport.release(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries.isEmpty); XCTAssertTrue(model.names.isEmpty)
        let old = MobileContainerImagePullStore(root: root).entry(id)
        XCTAssertEqual(old?.context, oldContext); XCTAssertEqual(old?.recovery.taskID, .text("synthetic-image-task"))
        XCTAssertTrue(old?.isProtected == true)
    }
    func test相同账号重连废弃旧确认且未提交记录重启不执行() async throws {
        let (model, _, _, root) = try make(); try await prepare(model)
        let confirmation = try XCTUnwrap(model.confirmation(repository: "sample/web", tag: "stable"))
        let newTransport = MobileContainerImageUITransport(), profile = try profile()
        model.configure(profile: profile, repository: try repository(newTransport, profile: profile), authorize: { true })
        try await prepare(model); XCTAssertNil(model.perform(confirmation))
        let entry = try model.recovery.reserve(confirmation.request, context: try XCTUnwrap(model.context))
        let restored = MobileContainerImagePullStore(root: root)
        XCTAssertEqual(restored.entry(entry.id)?.phase, .skipped)
        let writes = await newTransport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test损坏或无法写入记录时零提交() async throws {
        for corrupt in [false, true] {
            let root = newRoot()
            if corrupt {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("invalid".utf8).write(to: root.appendingPathComponent("image-pulls-v1.json"))
            } else { try Data("file".utf8).write(to: root) }
            let (model, transport, _, _) = try make(root: root); try await prepare(model)
            if let confirmation = model.confirmation(repository: "sample/web", tag: "stable") { XCTAssertNil(model.perform(confirmation)) }
            XCTAssertTrue(model.recovery.failed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test恢复文件仅原任务和摘要且排除备份() async throws {
        let (model, _, _, root) = try make(); try await prepare(model)
        let id = try start(model); await model.waitForOperation(id)
        let text = try String(contentsOf: root.appendingPathComponent("image-pulls-v1.json"), encoding: .utf8)
        for value in ["sample/web", "fixture.example.invalid", "operator", "synthetic-session", "synthetic-image-id"] { XCTAssertFalse(text.contains(value)) }
        XCTAssertTrue(text.contains("synthetic-image-task"))
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    private func prepare(_ model: MobileContainerImagePullModel) async throws {
        await model.refresh(); await model.search("sample"); await model.select(try XCTUnwrap(model.results.first))
    }
    private func start(_ model: MobileContainerImagePullModel) throws -> UUID {
        try XCTUnwrap(model.perform(try XCTUnwrap(model.confirmation(repository: "sample/web", tag: "stable"))))
    }
    private func newRoot() -> URL { let value = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePullTests-\(UUID())"); roots.append(value); return value }
    private func profile(username: String = "operator") throws -> NasProfile {
        try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000023")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username)
    }
    private func repository(_ transport: MobileContainerImageUITransport, profile: NasProfile, registry: Bool = true) throws -> DsmServiceManagementRepository {
        let names = registry ? [DsmAPIName.dockerImage, DsmAPIName.dockerRegistry] : [DsmAPIName.dockerImage]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)) }))
        return try .init(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func make(mode: String = "containers-images", root: URL? = nil, registry: Bool = true) throws -> (MobileContainerImagePullModel, MobileContainerImageUITransport, ImagePullPermissionGate, URL) {
        let root = root ?? newRoot(), transport = MobileContainerImageUITransport(mode: mode), gate = ImagePullPermissionGate(), profile = try profile()
        let model = MobileContainerImagePullModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile, registry: registry), authorize: { await gate.check() })
        return (model, transport, gate, root)
    }
}

private actor ImagePullPermissionGate {
    private var allowed = true
    func set(_ value: Bool) { allowed = value }
    func check() -> Bool { allowed }
}
