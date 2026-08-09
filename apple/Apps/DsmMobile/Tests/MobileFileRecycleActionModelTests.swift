@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

private actor FileRecycleActionRepositoryStub: MobileFileRecycleMutating {
    enum Reply: Sendable {
        case outcome(FileRecycleMutationOutcome)
        case delayed(FileRecycleMutationOutcome)
        case failure
    }

    nonisolated let profileID: UUID
    private var moveReply: Reply?
    private var restoreReply: Reply?
    private(set) var moveRequests: [FileMoveToRecycleRequest] = []
    private(set) var restoreRequests: [FileRestoreFromRecycleRequest] = []
    private(set) var cancellationObserved = false

    init(profileID: UUID, moveReply: Reply? = nil, restoreReply: Reply? = nil) {
        self.profileID = profileID
        self.moveReply = moveReply
        self.restoreReply = restoreReply
    }

    func moveToRecycleResult(
        _ request: FileMoveToRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome {
        moveRequests.append(request)
        progress(5, 10)
        return try await resolve(moveReply)
    }

    func restoreFromRecycleResult(
        _ request: FileRestoreFromRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome {
        restoreRequests.append(request)
        progress(5, 10)
        return try await resolve(restoreReply)
    }

    func recordedMoveRequests() -> [FileMoveToRecycleRequest] { moveRequests }
    func recordedRestoreRequests() -> [FileRestoreFromRecycleRequest] { restoreRequests }
    func didObserveCancellation() -> Bool { cancellationObserved }

    private func resolve(_ reply: Reply?) async throws -> FileRecycleMutationOutcome {
        guard let reply else { throw StubError.missingReply }
        switch reply {
        case .outcome(let outcome):
            return outcome
        case .delayed(let outcome):
            do {
                try await Task.sleep(nanoseconds: 60_000_000)
                return outcome
            } catch {
                cancellationObserved = true
                throw error
            }
        case .failure:
            throw StubError.failed
        }
    }

    enum StubError: Error { case missingReply, failed }
}

@MainActor
final class MobileFileRecycleActionModelTests: XCTestCase {
    func test移入回收站冻结已发现共享回收站且仅提交一次() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/team/docs/a.txt", .file, size: 10)
        let moved = item(profileID, "a.txt", "/team/#recycle/docs/a.txt", .file, size: 10)
        let location = recycle("team", "/team")
        let repository = FileRecycleActionRepositoryStub(
            profileID: profileID,
            moveReply: .outcome(try outcome(.confirmedSuccess, .moveToRecycle, source, moved.path, moved))
        )
        let model = MobileFileRecycleActionModel(blocker: MobileFileRecycleActionReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        model.beginMoveToRecycle(
            item: source,
            parentPath: "/team/docs",
            source: .browser,
            visibleItems: [source],
            recycleLocations: [location],
            repository: repository
        )

        let success = await model.submit(repository: repository)

        XCTAssertEqual(success?.operation, .moveToRecycle)
        XCTAssertEqual(success?.sourceParentPath, "/team/docs")
        XCTAssertEqual(success?.destinationParentPath, "/team/#recycle/docs")
        XCTAssertEqual(success?.item, moved)
        XCTAssertFalse(model.isPresented)
        let requests = await repository.recordedMoveRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.profileID, profileID)
        XCTAssertEqual(request.item, source)
        XCTAssertEqual(request.recycleLocation, location)
        XCTAssertEqual(requests.count, 1)
    }

    func test恢复回收站项目严格反推原路径() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/team/#recycle/docs/a.txt", .file, size: 10)
        let restored = item(profileID, "a.txt", "/team/docs/a.txt", .file, size: 10)
        let repository = FileRecycleActionRepositoryStub(
            profileID: profileID,
            restoreReply: .outcome(try outcome(.confirmedSuccess, .restoreFromRecycle, source, restored.path, restored))
        )
        let model = MobileFileRecycleActionModel(blocker: MobileFileRecycleActionReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        model.beginRestoreFromRecycle(
            item: source,
            parentPath: "/team/#recycle/docs",
            source: .recycle,
            visibleItems: [source],
            repository: repository
        )

        let success = await model.submit(repository: repository)

        XCTAssertEqual(success?.operation, .restoreFromRecycle)
        XCTAssertEqual(success?.destinationPath, "/team/docs/a.txt")
        XCTAssertEqual(success?.destinationParentPath, "/team/docs")
        XCTAssertEqual(success?.item, restored)
        let requests = await repository.recordedRestoreRequests()
        XCTAssertEqual(requests.map(\.item), [source])
    }

    func test远程目录回收站内移入无发现入口与非canonical路径均零入口零写() async {
        let profileID = UUID()
        let repository = FileRecycleActionRepositoryStub(profileID: profileID)
        let model = MobileFileRecycleActionModel(blocker: MobileFileRecycleActionReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        let file = item(profileID, "a.txt", "/team/a.txt", .file)
        let cases: [(FileItem, String, MobileFileLocationSource, [FileItem], [FileRecycleLocation])] = [
            (file, "/team", .remote, [file], [recycle("team", "/team")]),
            (file, "/team", .recycle, [file], [recycle("team", "/team")]),
            (item(profileID, "dir", "/team/dir", .directory), "/team", .browser, [], [recycle("team", "/team")]),
            (item(UUID(), "a.txt", "/team/a.txt", .file), "/team", .browser, [], [recycle("team", "/team")]),
            (file, "/team", .browser, [], [recycle("team", "/team")]),
            (item(profileID, "unknown.txt", "/team/unknown.txt", .file, size: nil), "/team", .browser, [], [recycle("team", "/team")]),
            (item(profileID, "a.txt", "/team/#recycle/a.txt", .file), "/team/#recycle", .browser, [], [recycle("team", "/team")]),
            (item(profileID, "a.txt", "/remote/a.txt", .file, mount: "cifs"), "/remote", .browser, [], [recycle("remote", "/remote")]),
            (file, "/team", .browser, [file], []),
        ]
        for value in cases {
            model.beginMoveToRecycle(
                item: value.0,
                parentPath: value.1,
                source: value.2,
                visibleItems: value.3,
                recycleLocations: value.4,
                repository: repository
            )
            XCTAssertFalse(model.isPresented)
        }
        model.beginRestoreFromRecycle(
            item: file,
            parentPath: "/team",
            source: .browser,
            visibleItems: [file],
            repository: repository
        )
        XCTAssertFalse(model.isPresented)
        let moveRequests = await repository.recordedMoveRequests()
        let restoreRequests = await repository.recordedRestoreRequests()
        XCTAssertTrue(moveRequests.isEmpty)
        XCTAssertTrue(restoreRequests.isEmpty)
    }

    func test未知结果与伪成功建立跨模型blocker并禁止第二次写() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/team/a.txt", .file, size: 10)
        let location = recycle("team", "/team")
        let blocker = MobileFileRecycleActionReviewBlocker()
        let firstRepository = FileRecycleActionRepositoryStub(
            profileID: profileID,
            moveReply: .outcome(try outcome(.submittedButUnverified, .moveToRecycle, source, "/team/#recycle/a.txt", nil))
        )
        let first = MobileFileRecycleActionModel(blocker: blocker)
        first.activate(profileID: profileID, repository: firstRepository)
        first.beginMoveToRecycle(
            item: source,
            parentPath: "/team",
            source: .browser,
            visibleItems: [source],
            recycleLocations: [location],
            repository: firstRepository
        )
        let firstResult = await first.submit(repository: firstRepository)
        XCTAssertNil(firstResult)
        XCTAssertEqual(first.presentation?.phase, .review)

        let secondRepository = FileRecycleActionRepositoryStub(profileID: profileID)
        let second = MobileFileRecycleActionModel(blocker: blocker)
        second.activate(profileID: profileID, repository: secondRepository)
        second.beginMoveToRecycle(
            item: source,
            parentPath: "/team",
            source: .browser,
            visibleItems: [source],
            recycleLocations: [location],
            repository: secondRepository
        )
        let secondResult = await second.submit(repository: secondRepository)
        XCTAssertNil(secondResult)
        XCTAssertEqual(second.presentation?.phase, .review)
        let secondRequests = await secondRepository.recordedMoveRequests()
        XCTAssertTrue(secondRequests.isEmpty)

        let wrong = item(profileID, "a.txt", "/team/#recycle/wrong/a.txt", .file, size: 10)
        let wrongRepository = FileRecycleActionRepositoryStub(
            profileID: profileID,
            moveReply: .outcome(try outcome(.confirmedSuccess, .moveToRecycle, source, wrong.path, wrong))
        )
        let wrongModel = MobileFileRecycleActionModel(blocker: MobileFileRecycleActionReviewBlocker())
        wrongModel.activate(profileID: profileID, repository: wrongRepository)
        wrongModel.beginMoveToRecycle(
            item: source,
            parentPath: "/team",
            source: .browser,
            visibleItems: [source],
            recycleLocations: [location],
            repository: wrongRepository
        )
        let wrongResult = await wrongModel.submit(repository: wrongRepository)
        XCTAssertNil(wrongResult)
        XCTAssertEqual(wrongModel.presentation?.phase, .review)
    }

    func test写前取消返回确认态且离页取消迟到零回写() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/team/a.txt", .file, size: 10)
        let location = recycle("team", "/team")
        let cancelledRepository = FileRecycleActionRepositoryStub(
            profileID: profileID,
            moveReply: .outcome(try outcome(.cancelledBeforeSubmission, .moveToRecycle, source, "/team/#recycle/a.txt", nil))
        )
        let cancelledModel = MobileFileRecycleActionModel(blocker: MobileFileRecycleActionReviewBlocker())
        cancelledModel.activate(profileID: profileID, repository: cancelledRepository)
        cancelledModel.beginMoveToRecycle(
            item: source,
            parentPath: "/team",
            source: .browser,
            visibleItems: [source],
            recycleLocations: [location],
            repository: cancelledRepository
        )
        let cancelledResult = await cancelledModel.submit(repository: cancelledRepository)
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(cancelledModel.presentation?.phase, .confirming)

        let moved = item(profileID, "a.txt", "/team/#recycle/a.txt", .file, size: 10)
        let delayedRepository = FileRecycleActionRepositoryStub(
            profileID: profileID,
            moveReply: .delayed(try outcome(.confirmedSuccess, .moveToRecycle, source, moved.path, moved))
        )
        let delayedModel = MobileFileRecycleActionModel(blocker: MobileFileRecycleActionReviewBlocker())
        delayedModel.activate(profileID: profileID, repository: delayedRepository)
        delayedModel.beginMoveToRecycle(
            item: source,
            parentPath: "/team",
            source: .browser,
            visibleItems: [source],
            recycleLocations: [location],
            repository: delayedRepository
        )
        let task = Task { await delayedModel.submit(repository: delayedRepository) }
        await waitForMoveRequest(delayedRepository)

        delayedModel.deactivate()

        let delayedResult = await task.value
        XCTAssertNil(delayedResult)
        XCTAssertNil(delayedModel.presentation)
        let cancellationObserved = await delayedRepository.didObserveCancellation()
        XCTAssertTrue(cancellationObserved)
    }

    private func waitForMoveRequest(_ repository: FileRecycleActionRepositoryStub) async {
        for _ in 0..<100 {
            if await repository.recordedMoveRequests().count == 1 { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("move-to-recycle request did not start")
    }

    private func outcome(
        _ status: MutationResultStatus,
        _ operation: MobileFileRecycleActionOperation,
        _ source: FileItem,
        _ destinationPath: String,
        _ item: FileItem?
    ) throws -> FileRecycleMutationOutcome {
        let submitted = ![.cancelledBeforeSubmission, .permissionDenied, .unsupported].contains(status)
        let review = status == .submittedButUnverified || status == .cancellationRequestedAfterSubmission
        return FileRecycleMutationOutcome(
            result: try MutationResult(
                status: status,
                operation: operation.rawValue,
                submitted: submitted,
                requiresRefresh: review,
                counts: try MutationResultCounts(
                    succeeded: status == .confirmedSuccess ? 1 : 0,
                    failed: status == .permissionDenied || status == .unsupported ? 1 : 0,
                    unknown: review ? 1 : 0
                ),
                diagnosticTag: "mobile-file-recycle-test"
            ),
            sourcePath: source.path,
            destinationPath: destinationPath,
            item: item
        )
    }

    private func item(
        _ profileID: UUID,
        _ name: String,
        _ path: String,
        _ kind: FileKind,
        size: Int64? = 10,
        mount: String? = nil
    ) -> FileItem {
        FileItem(
            profileID: profileID,
            name: name,
            path: path,
            kind: kind,
            sizeBytes: size,
            mountPointType: mount
        )
    }

    private func recycle(_ name: String, _ path: String) -> FileRecycleLocation {
        FileRecycleLocation(shareName: name, sharePath: path, recyclePath: path + "/#recycle")
    }
}
