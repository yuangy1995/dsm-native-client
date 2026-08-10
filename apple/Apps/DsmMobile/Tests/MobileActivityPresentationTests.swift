@testable import DsmMobile
import DsmCore
import XCTest

final class MobileActivityPresentationTests: XCTestCase {
    func test页面状态覆盖加载空内容筛选空错误和正常内容() {
        let task = makeTask(status: .running)

        XCTAssertEqual(resolve(isLoading: true, hasError: false, all: [], visible: []), .loading)
        XCTAssertEqual(resolve(isLoading: false, hasError: true, all: [], visible: []), .error)
        XCTAssertEqual(resolve(isLoading: false, hasError: false, all: [], visible: []), .empty)
        XCTAssertEqual(
            resolve(isLoading: false, hasError: false, all: [task], visible: [], filter: .ended),
            .filteredEmpty
        )
        XCTAssertEqual(
            resolve(isLoading: false, hasError: false, all: [task], visible: [task]),
            .content
        )
    }

    func test筛选使用稳定状态而不是展示文案() {
        let running = makeTask(status: .running)
        let succeeded = makeTask(status: .succeeded)

        XCTAssertTrue(MobileActivityFilter.all.includes(running))
        XCTAssertTrue(MobileActivityFilter.all.includes(succeeded))
        XCTAssertTrue(MobileActivityFilter.inProgress.includes(running))
        XCTAssertFalse(MobileActivityFilter.inProgress.includes(succeeded))
        XCTAssertFalse(MobileActivityFilter.ended.includes(running))
        XCTAssertTrue(MobileActivityFilter.ended.includes(succeeded))
    }

    func test只有状态机白名单显示从头重试() {
        XCTAssertTrue(makeTask(direction: .upload, status: .cancelledBeforeSubmission).canRetryFromBeginning)
        XCTAssertFalse(makeTask(direction: .upload, status: .failed).canRetryFromBeginning)
        XCTAssertFalse(makeTask(direction: .upload, status: .resultNeedsReview).canRetryFromBeginning)
        XCTAssertTrue(makeTask(direction: .download, status: .failed).canRetryFromBeginning)
        XCTAssertTrue(makeTask(direction: .download, status: .cancelled).canRetryFromBeginning)
        XCTAssertFalse(makeTask(direction: .download, status: .resultNeedsReview).canRetryFromBeginning)
    }

    func test取消按钮仅在仍可受理取消时显示() {
        XCTAssertTrue(makeTask(status: .queued).canCancel)
        XCTAssertTrue(makeTask(status: .preparing).canCancel)
        XCTAssertTrue(makeTask(status: .running).canCancel)
        XCTAssertFalse(makeTask(status: .paused).canCancel)
        XCTAssertFalse(makeTask(status: .cancelling).canCancel)
        XCTAssertFalse(makeTask(status: .succeeded).canCancel)
        XCTAssertFalse(makeTask(status: .resultNeedsReview).canCancel)
    }

    func testDownloadStation快照同步到NAS活动且不会重复() async {
        let profileID = UUID()
        let coordinator = MobileTransferCoordinator()
        let initial = DownloadStationSnapshot(
            source: .official,
            tasks: [
                DownloadStationTask(
                    id: "dbid_1",
                    title: "Ubuntu.iso",
                    status: "downloading",
                    sizeBytes: 100,
                    downloadedBytes: 40
                ),
                DownloadStationTask(
                    id: "dbid_2",
                    title: "Paused.torrent",
                    status: "paused",
                    sizeBytes: 200,
                    downloadedBytes: 20
                ),
            ]
        )

        await coordinator.syncDownloadStationTasks(profileID: profileID, snapshot: initial)
        let first = await coordinator.tasks(profileID: profileID)
        await coordinator.syncDownloadStationTasks(profileID: profileID, snapshot: initial)
        let second = await coordinator.tasks(profileID: profileID)

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertTrue(second.allSatisfy { $0.source == .nas })
        XCTAssertTrue(second.allSatisfy { !$0.canCancel && !$0.canRetryFromBeginning })
        let byName = Dictionary(uniqueKeysWithValues: second.map { ($0.stableTarget, $0) })
        XCTAssertEqual(byName["Ubuntu.iso"]?.progress.completedBytes, 40)
        XCTAssertEqual(byName["Paused.torrent"]?.status, .paused)
    }

    func testDownloadStation同步会移除已经不在快照中的NASTask() async {
        let profileID = UUID()
        let coordinator = MobileTransferCoordinator()
        await coordinator.syncDownloadStationTasks(
            profileID: profileID,
            snapshot: DownloadStationSnapshot(
                source: .official,
                tasks: [
                    DownloadStationTask(id: "one", title: "one.iso", status: "waiting"),
                    DownloadStationTask(id: "two", title: "two.iso", status: "finished"),
                ]
            )
        )

        await coordinator.syncDownloadStationTasks(
            profileID: profileID,
            snapshot: DownloadStationSnapshot(
                source: .official,
                tasks: [
                    DownloadStationTask(id: "two", title: "two.iso", status: "finished"),
                ]
            )
        )

        let tasks = await coordinator.tasks(profileID: profileID)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.stableTarget, "two.iso")
        XCTAssertEqual(tasks.first?.status, .succeeded)
    }

    private func resolve(
        isLoading: Bool,
        hasError: Bool,
        all: [MobileActivityTask],
        visible: [MobileActivityTask],
        filter: MobileActivityFilter = .all
    ) -> MobileActivityPresentationState {
        .resolve(
            isLoading: isLoading,
            hasError: hasError,
            allTasks: all,
            visibleTasks: visible,
            filter: filter
        )
    }

    private func makeTask(
        direction: MobileTransferDirection = .download,
        status: MobileTransferStatus,
        retryPolicy: MobileTransferRetryPolicy = .restartFromBeginning
    ) -> MobileActivityTask {
        MobileActivityTask(
            id: UUID(),
            createdAt: Date(),
            profileID: UUID(),
            source: .app,
            sourceIdentifier: nil,
            direction: direction,
            stableTarget: "/home/file.txt",
            progress: .zero,
            status: status,
            retryPolicy: retryPolicy,
            mutationResult: nil
        )
    }
}
