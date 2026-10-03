import DsmCore
@testable import DsmMobile
import Foundation
import XCTest

@MainActor
final class MobileFileActivityControlTests: XCTestCase {
    func test未知控制跨重启禁止重发直到原任务结束() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskControl-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ActivityControlRepository()
        let model = MobileFileActivityModel(coordinator: MobileTransferCoordinator(), rootURL: root)
        await model.activate(profileID: repository.profileID, repository: repository, context: "context-a")
        let task = try XCTUnwrap(model.snapshots.first)
        XCTAssertTrue(model.canControl(task))
        async let first: Void = model.control(task)
        async let second: Void = model.control(task)
        _ = await (first, second)
        XCTAssertFalse(model.canControl(task))
        let restored = MobileFileActivityModel(coordinator: MobileTransferCoordinator(), rootURL: root)
        await restored.activate(profileID: repository.profileID, repository: repository, context: "context-a")
        XCTAssertFalse(restored.canControl(task))
        await restored.control(task)
        let calls = await repository.calls; XCTAssertEqual(calls, 1)
        await repository.setState(.finished); await restored.refresh()
        XCTAssertTrue(restored.canControl(try XCTUnwrap(restored.snapshots.first)))
    }
    func test已完成任务清除经过原快照且不混同成功文件结果() async throws {
        let repository = ActivityControlRepository()
        await repository.setState(.finished); await repository.setConfirmed()
        let coordinator = MobileTransferCoordinator()
        let model = MobileFileActivityModel(coordinator: coordinator)
        await model.activate(profileID: repository.profileID, repository: repository)
        let before = await coordinator.tasks(profileID: repository.profileID)
        XCTAssertEqual(before.first?.status, .resultNeedsReview)
        await model.control(try XCTUnwrap(model.snapshots.first))
        let clear = await repository.clearRequested; XCTAssertEqual(clear, true)
        XCTAssertTrue(model.snapshots.isEmpty)
        let after = await coordinator.tasks(profileID: repository.profileID)
        XCTAssertTrue(after.isEmpty)
    }
    func test同UUID更换账号上下文不继承控制门禁() async throws {
        let repository = ActivityControlRepository()
        let model = MobileFileActivityModel(coordinator: MobileTransferCoordinator())
        await model.activate(profileID: repository.profileID, repository: repository, context: "account-a")
        let task = try XCTUnwrap(model.snapshots.first)
        await model.control(task); XCTAssertFalse(model.canControl(task))
        await model.activate(profileID: repository.profileID, repository: repository, context: "account-b")
        XCTAssertTrue(model.canControl(try XCTUnwrap(model.snapshots.first)))
    }
    func test分页失败保留完整旧快照且不允许伪造控制目标() async throws {
        let repository = ActivityControlRepository()
        let coordinator = MobileTransferCoordinator()
        let model = MobileFileActivityModel(coordinator: coordinator)
        await model.activate(profileID: repository.profileID, repository: repository)
        let old = model.snapshots
        await repository.setMalformed(); await model.refresh()
        XCTAssertEqual(model.snapshots, old); XCTAssertNotNil(model.error)
        let fake = ActivityControlRepository.snapshot(id: "unseen")
        XCTAssertFalse(model.canControl(fake)); await model.control(fake)
        let calls = await repository.calls; XCTAssertEqual(calls, 0)
        let tasks = await coordinator.tasks(profileID: repository.profileID); XCTAssertEqual(tasks.count, 1)
    }
    func test写前读取失败不留下未知提交门禁() async throws {
        let repository = ActivityControlRepository()
        let model = MobileFileActivityModel(coordinator: MobileTransferCoordinator())
        await model.activate(profileID: repository.profileID, repository: repository)
        let task = try XCTUnwrap(model.snapshots.first)
        await repository.setPreflightFailure(true); await model.control(task)
        XCTAssertTrue(model.canControl(task))
        let before = await repository.calls; XCTAssertEqual(before, 0)
        await repository.setPreflightFailure(false); await model.control(task)
        let after = await repository.calls; XCTAssertEqual(after, 1)
        XCTAssertFalse(model.canControl(task))
    }
    func test任务记录保存失败不发送控制() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskControl-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ActivityControlRepository()
        let model = MobileFileActivityModel(coordinator: MobileTransferCoordinator(), rootURL: root)
        await model.activate(profileID: repository.profileID, repository: repository)
        try FileManager.default.removeItem(at: root); try Data().write(to: root)
        await model.control(try XCTUnwrap(model.snapshots.first))
        XCTAssertNotNil(model.recoveryError)
        let calls = await repository.calls; XCTAssertEqual(calls, 0)
    }
}

private actor ActivityControlRepository: MobileFileActivityReading {
    nonisolated let profileID = UUID()
    private var state: FileBackgroundTaskState = .active
    private var confirmed = false
    private var absent = false
    private var malformed = false
    private var preflightFailure = false
    private(set) var calls = 0
    private(set) var clearRequested: Bool?
    nonisolated static func snapshot(id: String = "synthetic", state: FileBackgroundTaskState = .active) -> FileBackgroundTaskSummary {
        .init(id: id, kind: .compress, state: state, progress: 0.5, createdAt: Date(timeIntervalSince1970: 1000),
            processedItemCount: 1, totalItemCount: 2, processedBytes: 10, totalBytes: 20, apiVersion: 3, method: "start")
    }
    func setState(_ state: FileBackgroundTaskState) { self.state = state }
    func setConfirmed() { confirmed = true }
    func setPreflightFailure(_ value: Bool) { preflightFailure = value }
    func setMalformed() { malformed = true }
    nonisolated func canStopBackgroundTask(_ task: FileBackgroundTaskSummary) -> Bool { task.state == .active }
    func listFileActivityTasks(offset: Int, limit: Int) async throws -> FileBackgroundTaskPage {
        .init(tasks: absent ? [] : [Self.snapshot(state: state)], offset: 0,
              nextOffset: malformed ? 2 : absent ? 0 : 1, total: malformed ? 2 : absent ? 0 : 1, hasMore: false)
    }
    func controlBackgroundTask(_ task: FileBackgroundTaskSummary, clearFinished: Bool) async throws -> MutationResult {
        if preflightFailure { throw URLError(.timedOut) }
        calls += 1; clearRequested = clearFinished
        try await Task.sleep(for: .milliseconds(10))
        if confirmed && clearFinished { absent = true }
        return try MutationResult(status: confirmed ? .confirmedSuccess : .submittedButUnverified,
            operation: "backgroundTaskStop", submitted: true, requiresRefresh: !confirmed,
            counts: .init(succeeded: confirmed ? 1 : 0, failed: 0, unknown: confirmed ? 0 : 1))
    }
}
