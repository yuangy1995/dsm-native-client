@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

private actor RecycleBatchRepository: MobileFileRecycleMutating {
    nonisolated let profileID: UUID
    var items: [String: FileItem]
    var statuses: [MutationResultStatus]
    var delay = false
    var falseCount = false
    private(set) var writes: [String] = []
    private(set) var reads: [String] = []

    init(_ id: UUID, _ sources: [FileItem], statuses: [MutationResultStatus] = [], delay: Bool = false, falseCount: Bool = false) {
        profileID = id; items = Dictionary(uniqueKeysWithValues: sources.map { ($0.path, $0) })
        self.statuses = statuses; self.delay = delay; self.falseCount = falseCount
    }
    func getInfo(paths: [String]) async throws -> [FileItem] { reads += paths; return paths.compactMap { items[$0] } }
    func deleteResult(paths: [String], progress: @escaping FileTransferProgress) async throws -> MutationResult {
        writes += paths
        if delay { await withCheckedContinuation { continuation in Task { try? await Task.sleep(for: .milliseconds(70)); continuation.resume() } } }
        return try result("fileDelete")
    }
    func moveToRecycleResult(_ request: FileMoveToRecycleRequest, progress: @escaping FileTransferProgress) async throws -> FileRecycleMutationOutcome {
        throw URLError(.unsupportedURL)
    }
    func restoreFromRecycleResult(_ request: FileRestoreFromRecycleRequest, progress: @escaping FileTransferProgress) async throws -> FileRecycleMutationOutcome {
        writes.append(request.item.path)
        let destination = request.item.path.replacingOccurrences(of: "/#recycle/", with: "/")
        let result = try result("restoreFromRecycle")
        return .init(result: result, sourcePath: request.item.path, destinationPath: destination,
            item: result.status == .confirmedSuccess ? FileItem(profileID: profileID, name: request.item.name,
                path: destination, kind: request.item.kind, sizeBytes: request.item.kind == .directory ? 4096 : request.item.sizeBytes) : nil)
    }
    func result(_ operation: String) throws -> MutationResult {
        let status = statuses.isEmpty ? .confirmedSuccess : statuses.removeFirst()
        let unknown = status == .submittedButUnverified || status == .cancellationRequestedAfterSubmission
        return try .init(status: status, operation: operation,
            submitted: status == .confirmedSuccess || unknown, requiresRefresh: unknown,
            counts: .init(succeeded: status == .confirmedSuccess ? (falseCount ? 0 : 1) : 0,
                failed: status == .confirmedFailure || status == .permissionDenied || status == .unsupported ? 1 : 0,
                unknown: unknown ? 1 : 0), errorCategory: status == .confirmedFailure ? .conflict : nil)
    }
    func recordedWrites() -> [String] { writes }
    func replace(_ item: FileItem) { items[item.path] = item }
}

@MainActor
final class MobileFileRecycleBatchTests: XCTestCase {
    func test混合批量删除逐项回读结果且明确失败继续余项() async throws {
        let id = UUID(), sources = makeItems()
        let bound = sources.map { item(id, $0.path, kind: $0.kind) }
        let repository = RecycleBatchRepository(id, bound, statuses: [.confirmedSuccess, .confirmedFailure, .confirmedSuccess])
        let model = model(id, repository)
        begin(model, repository, bound)
        let result = await model.submit(repository: repository)
        XCTAssertEqual(result?.operation, .delete)
        XCTAssertEqual(result?.sourceParentPath, "/team")
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.confirmed, .failed, .confirmed])
        XCTAssertEqual(model.presentation?.itemStates[1].feedback, .conflict)
        XCTAssertEqual(model.presentation?.phase, .result)
        let writes = await repository.recordedWrites(); XCTAssertEqual(writes, bound.map(\.path))
    }

    func test批量恢复目录大小可变化且逐项冲突不覆盖() async {
        let id = UUID(), folder = item(UUID(), "/team/#recycle/Folder", kind: .directory)
        let sources = [item(id, folder.path, kind: .directory), item(id, "/team/#recycle/one.txt")]
        let repository = RecycleBatchRepository(id, sources, statuses: [.confirmedSuccess, .confirmedFailure])
        let model = model(id, repository)
        model.begin(operation: .restoreFromRecycle, items: sources, parentPath: "/team/#recycle",
            source: .recycle, visibleItems: sources, repository: repository)
        let result = await model.submit(repository: repository)
        XCTAssertEqual(result?.destinationPath, "/team/Folder")
        XCTAssertEqual(result?.item.kind, .directory)
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.confirmed, .failed])
    }

    func test删除前重读拒绝替换项目和未明确删除权限() async {
        let id = UUID(), sources = [item(UUID(), "/team/a.txt")]
        let source = item(id, sources[0].path)
        for observed in [item(id, source.path, size: 11), item(id, source.path, allowed: false),
                         FileItem(profileID: id, name: "a.txt", path: source.path, kind: .file, sizeBytes: 10)] {
            let repository = RecycleBatchRepository(id, [observed])
            let model = model(id, repository); begin(model, repository, [source])
            let result = await model.submit(repository: repository)
            XCTAssertNil(result)
            XCTAssertEqual(model.presentation?.itemStates.first?.status, .failed)
            let writes = await repository.recordedWrites(); XCTAssertTrue(writes.isEmpty)
        }
    }

    func test批量未知在写前落盘且重启后禁止重放并保留余项() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), sources = [item(UUID(), "/team/a.txt")]
        let bound = [item(id, sources[0].path), item(id, "/team/b.txt")]
        let repository = RecycleBatchRepository(id, bound, statuses: [.submittedButUnverified], delay: true)
        let first = model(id, repository, blocker: .init(rootURL: root)); begin(first, repository, bound)
        let task = Task { await first.submit(repository: repository) }
        await wait(repository)
        let key = MobileFileRecycleActionReviewKey(profileID: id, context: "account-a", operation: .delete, sourcePath: bound[0].path, destinationPath: "")
        XCTAssertTrue(MobileFileRecycleActionReviewBlocker(rootURL: root).contains(key))
        _ = await task.value
        XCTAssertEqual(first.presentation?.itemStates.map(\.status), [.pendingReview, .notStarted])
        first.deactivate()
        let second = model(id, repository, blocker: .init(rootURL: root)); begin(second, repository, bound)
        _ = await second.submit(repository: repository)
        let writes = await repository.recordedWrites(); XCTAssertEqual(writes, [bound[0].path])
        XCTAssertEqual(second.presentation?.phase, .review)
    }

    func test取消后当前项明确成功仍停止下一项并解除已完成记录() async throws {
        let id = UUID(), sources = [item(UUID(), "/team/a.txt")]
        let bound = [item(id, sources[0].path), item(id, "/team/b.txt")]
        let repository = RecycleBatchRepository(id, bound, delay: true), blocker = MobileFileRecycleActionReviewBlocker()
        let model = model(id, repository, blocker: blocker); begin(model, repository, bound)
        let task = Task { await model.submit(repository: repository) }; await wait(repository)
        let duplicate = await model.submit(repository: repository)
        XCTAssertNil(duplicate)
        model.requestCancellation(); let result = await task.value
        XCTAssertNotNil(result)
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.confirmed, .notStarted])
        let writes = await repository.recordedWrites(); XCTAssertEqual(writes, [bound[0].path])
        XCTAssertFalse(blocker.contains(.init(profileID: id, context: "account-a", operation: .delete, sourcePath: bound[0].path, destinationPath: "")))
    }

    func test迟到明确结果不污染新账号且旧按钮不提交新弹窗() async {
        let id = UUID(), source = item(UUID(), "/team/a.txt")
        let bound = item(id, source.path), repository = RecycleBatchRepository(id, [item(id, source.path)], delay: true)
        let blocker = MobileFileRecycleActionReviewBlocker()
        let old = self.model(id, repository, blocker: blocker); begin(old, repository, [bound])
        let activation = old.activation, task = Task { await old.submit(repository: repository) }; await wait(repository)
        old.activate(profileID: id, repository: repository, context: "account-b"); begin(old, repository, [bound])
        let late = await task.value; XCTAssertNil(late)
        XCTAssertEqual(old.presentation?.phase, .confirming)
        XCTAssertFalse(blocker.contains(.init(profileID: id, context: "account-a", operation: .delete, sourcePath: bound.path, destinationPath: "")))
        _ = await old.submit(repository: repository, expectedActivation: activation)
        let writes = await repository.recordedWrites(); XCTAssertEqual(writes.count, 1)
    }

    func test损坏或不可写恢复记录保持原件且零写请求() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("pending-v1.json"), original = Data("broken".utf8)
        try original.write(to: file)
        let id = UUID(), source = item(UUID(), "/team/a.txt")
        let bound = item(id, source.path), repository = RecycleBatchRepository(id, [item(id, source.path)])
        for location in [root, file] {
            let model = model(id, repository, blocker: .init(rootURL: location)); begin(model, repository, [bound])
            _ = await model.submit(repository: repository)
            XCTAssertEqual(model.presentation?.feedback, .recovery)
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        let writes = await repository.recordedWrites(); XCTAssertTrue(writes.isEmpty)
    }

    func test保护跨操作目录子树且账号配置隔离删除配置只清自身() {
        let id = UUID(), other = UUID(), blocker = MobileFileRecycleActionReviewBlocker()
        let key = MobileFileRecycleActionReviewKey(profileID: id, context: "a", operation: .restoreFromRecycle,
            sourcePath: "/team/#recycle/Folder", destinationPath: "/team/Folder")
        blocker.insert(key)
        for path in ["/team/#recycle/Folder/a.txt", "/team/Folder", "/team/Folder/b.txt", "/team"] {
            XCTAssertTrue(blocker.contains(.init(profileID: id, context: "a", operation: .delete, sourcePath: path, destinationPath: "")))
        }
        XCTAssertFalse(blocker.contains(.init(profileID: id, context: "b", operation: .delete, sourcePath: "/team/Folder", destinationPath: "")))
        blocker.purge(profileID: other); XCTAssertTrue(blocker.contains(key))
        blocker.purge(profileID: id); XCTAssertFalse(blocker.contains(key))
    }

    func test伪成功保留阻挡且共享根远程回收站容器重复选择零入口() async {
        let id = UUID(), source = item(UUID(), "/team/a.txt")
        let bound = item(id, source.path), repository = RecycleBatchRepository(id, [item(id, source.path)], falseCount: true)
        let model = model(id, repository); begin(model, repository, [bound]); _ = await model.submit(repository: repository)
        XCTAssertEqual(model.presentation?.phase, .review)
        model.dismiss()
        for value in [(item(id, "/team", kind: .directory), "/", MobileFileLocationSource.shares),
                      (item(id, "/team/#recycle", kind: .directory), "/team", .browser), (bound, "/team", .remote)] {
            model.begin(operation: .delete, items: [value.0], parentPath: value.1, source: value.2,
                visibleItems: [value.0], repository: repository)
            XCTAssertFalse(model.isPresented)
        }
        begin(model, repository, [bound, bound]); XCTAssertFalse(model.isPresented)
        let writes = await repository.recordedWrites(); XCTAssertEqual(writes.count, 1)
    }

    private func model(_ id: UUID, _ repository: RecycleBatchRepository, blocker: MobileFileRecycleActionReviewBlocker = .init()) -> MobileFileRecycleActionModel {
        let value = MobileFileRecycleActionModel(blocker: blocker)
        value.activate(profileID: id, repository: repository, context: "account-a"); return value
    }
    private func begin(_ model: MobileFileRecycleActionModel, _ repository: RecycleBatchRepository, _ sources: [FileItem]) {
        model.begin(operation: .delete, items: sources, parentPath: "/team", source: .browser, visibleItems: sources, repository: repository)
    }
    private func wait(_ repository: RecycleBatchRepository) async {
        for _ in 0..<100 { if await !repository.recordedWrites().isEmpty { return }; try? await Task.sleep(for: .milliseconds(1)) }
        XCTFail("没有开始测试写请求")
    }
    private func makeItems() -> [FileItem] { [item(UUID(), "/team/Folder", kind: .directory), item(UUID(), "/team/a.txt"), item(UUID(), "/team/b.txt")] }
    private func item(_ id: UUID, _ path: String, kind: FileKind = .file, size: Int64 = 10, allowed: Bool = true) -> FileItem {
        .init(profileID: id, name: (path as NSString).lastPathComponent, path: path, kind: kind, sizeBytes: kind == .directory ? nil : size,
            permissions: .init(canRead: true, canWrite: true, canDelete: allowed, posixMode: nil))
    }
}
