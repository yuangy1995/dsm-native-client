@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

@MainActor
final class MobileFileActivityModelTests: XCTestCase {
    func test固定首100项并明确截断且同步到当前Profile() async {
        let profileID = UUID()
        let repository = ImmediateFileActivityRepository(
            profileID: profileID,
            result: .success(Self.page(id: "task", total: 101, hasMore: true))
        )
        let coordinator = MobileTransferCoordinator()
        let model = MobileFileActivityModel(coordinator: coordinator)

        await model.activate(profileID: profileID, repository: repository)

        let requests = await repository.requests
        XCTAssertEqual(requests, [Request(offset: 0, limit: 100)])
        XCTAssertTrue(model.isTruncated)
        XCTAssertNil(model.error)
        let tasks = await coordinator.tasks(profileID: profileID)
        XCTAssertEqual(tasks.count, 1)
    }

    func test失败保留上次任务并允许独立重试() async {
        let profileID = UUID()
        let repository = ImmediateFileActivityRepository(
            profileID: profileID,
            result: .success(Self.page(id: "kept"))
        )
        let coordinator = MobileTransferCoordinator()
        let model = MobileFileActivityModel(coordinator: coordinator)
        await model.activate(profileID: profileID, repository: repository)
        await repository.setResult(
            Result<FileBackgroundTaskPage, Error>.failure(URLError(.timedOut))
        )

        await model.refresh()

        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isLoading)
        let tasks = await coordinator.tasks(profileID: profileID)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.sourceIdentifier, "file-background:kept")
    }

    func test同一请求严格单飞() async {
        let profileID = UUID()
        let repository = ControlledFileActivityRepository(profileID: profileID)
        let coordinator = MobileTransferCoordinator()
        let model = MobileFileActivityModel(coordinator: coordinator)

        let activation = Task { await model.activate(profileID: profileID, repository: repository) }
        await repository.waitUntilRequested()
        let second = Task { await model.refresh() }
        await Task.yield()
        let countBeforeCompletion = await repository.currentRequestCount()
        XCTAssertEqual(countBeforeCompletion, 1)
        await repository.complete(Self.page(id: "single"))
        await activation.value
        await second.value

        let finalRequestCount = await repository.currentRequestCount()
        let tasks = await coordinator.tasks(profileID: profileID)
        XCTAssertEqual(finalRequestCount, 1)
        XCTAssertEqual(tasks.count, 1)
    }

    func test切换Repository取消旧请求并拒绝迟到结果() async {
        let profileA = UUID()
        let profileB = UUID()
        let oldRepository = ControlledFileActivityRepository(profileID: profileA)
        let newRepository = ImmediateFileActivityRepository(
            profileID: profileB,
            result: .success(Self.page(id: "new"))
        )
        let coordinator = MobileTransferCoordinator()
        let model = MobileFileActivityModel(coordinator: coordinator)

        let oldActivation = Task { await model.activate(profileID: profileA, repository: oldRepository) }
        await oldRepository.waitUntilRequested()
        await model.activate(profileID: profileB, repository: newRepository)
        await oldRepository.complete(Self.page(id: "late"))
        await oldActivation.value

        let oldWasCancelled = await oldRepository.cancellationObserved()
        let oldTasks = await coordinator.tasks(profileID: profileA)
        XCTAssertTrue(oldWasCancelled)
        XCTAssertTrue(oldTasks.isEmpty)
        let current = await coordinator.tasks(profileID: profileB)
        XCTAssertEqual(current.first?.sourceIdentifier, "file-background:new")
        XCTAssertEqual(model.activeProfileID, profileB)
    }

    private static func page(
        id: String,
        total: Int = 1,
        hasMore: Bool = false
    ) -> FileBackgroundTaskPage {
        FileBackgroundTaskPage(
            tasks: [
                FileBackgroundTaskSummary(
                    id: id,
                    kind: .copyOrMove,
                    state: .active,
                    progress: 0.5,
                    createdAt: nil,
                    processedItemCount: 1,
                    totalItemCount: 2,
                    processedBytes: 50,
                    totalBytes: 100
                ),
            ],
            offset: 0,
            nextOffset: 1,
            total: total,
            hasMore: hasMore
        )
    }
}

private struct Request: Equatable, Sendable {
    let offset: Int
    let limit: Int
}

private actor ImmediateFileActivityRepository: MobileFileActivityReading {
    nonisolated let profileID: UUID
    private var result: Result<FileBackgroundTaskPage, Error>
    private(set) var requests: [Request] = []

    init(profileID: UUID, result: Result<FileBackgroundTaskPage, Error>) {
        self.profileID = profileID
        self.result = result
    }

    func setResult(_ result: Result<FileBackgroundTaskPage, Error>) {
        self.result = result
    }

    func listFileActivityTasks(offset: Int, limit: Int) async throws -> FileBackgroundTaskPage {
        requests.append(Request(offset: offset, limit: limit))
        return try result.get()
    }
}

private actor ControlledFileActivityRepository: MobileFileActivityReading {
    nonisolated let profileID: UUID
    private var continuation: CheckedContinuation<FileBackgroundTaskPage, Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0
    private(set) var wasCancelled = false

    init(profileID: UUID) {
        self.profileID = profileID
    }

    func listFileActivityTasks(offset: Int, limit: Int) async throws -> FileBackgroundTaskPage {
        requestCount += 1
        waiter?.resume()
        waiter = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.cancelRequest() }
        }
    }

    func waitUntilRequested() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func complete(_ page: FileBackgroundTaskPage) {
        continuation?.resume(returning: page)
        continuation = nil
    }

    func currentRequestCount() -> Int { requestCount }

    func cancellationObserved() -> Bool { wasCancelled }

    private func cancelRequest() {
        wasCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
