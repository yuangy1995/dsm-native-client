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

    func testNAS任务缺少字节和计数时仍使用白名单进度() {
        let progress = MobileTransferProgress(
            completedBytes: 0,
            totalBytes: nil,
            reportedFraction: 0.4
        )
        XCTAssertEqual(progress.fraction, 0.4)
    }

    func testNAS任务只有总字节时优先使用服务端进度() {
        let progress = MobileTransferProgress(
            completedBytes: 0,
            totalBytes: 100,
            reportedFraction: 0.4
        )
        XCTAssertEqual(progress.fraction, 0.4)
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

    func testFileStation任务按真实类型映射且不影响DownloadStation来源() async {
        let profileID = UUID()
        let coordinator = MobileTransferCoordinator()
        let observationToken = UUID()
        await coordinator.beginFileStationObservation(
            profileID: profileID,
            token: observationToken
        )
        await coordinator.syncDownloadStationTasks(
            profileID: profileID,
            snapshot: DownloadStationSnapshot(
                source: .official,
                tasks: [DownloadStationTask(id: "download", title: "image.iso", status: "downloading")]
            )
        )
        let createdAt = Date(timeIntervalSince1970: 123)
        await coordinator.syncFileStationTasks(
            profileID: profileID,
            observationToken: observationToken,
            tasks: [
                backgroundTask("copy", .copyOrMove, .active, createdAt: createdAt),
                backgroundTask("delete", .delete, .finished),
                backgroundTask("compress", .compress, .active),
                backgroundTask("extract", .extract, .active),
            ]
        )

        let first = await coordinator.tasks(profileID: profileID)
        await coordinator.syncFileStationTasks(
            profileID: profileID,
            observationToken: observationToken,
            tasks: [backgroundTask("copy", .copyOrMove, .finished, createdAt: createdAt)]
        )
        let second = await coordinator.tasks(profileID: profileID)

        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(Set(first.map(\.operation)), Set([
            .downloadStation, .fileCopyMove, .fileDelete, .fileCompress, .fileExtract,
        ]))
        let copy = try? XCTUnwrap(first.first { $0.operation == .fileCopyMove })
        XCTAssertEqual(copy?.createdAt, createdAt)
        XCTAssertEqual(copy?.progress.completedBytes, 40)
        XCTAssertEqual(copy?.progress.totalBytes, 100)
        XCTAssertEqual(copy?.progress.completedItems, 2)
        XCTAssertEqual(copy?.progress.totalItems, 5)
        XCTAssertFalse(copy?.canCancel ?? true)
        XCTAssertFalse(copy?.canRetryFromBeginning ?? true)
        XCTAssertEqual(copy?.stableTarget, MobileActivityOperation.fileCopyMove.rawValue)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.first { $0.operation == .fileCopyMove }?.status, .resultNeedsReview)
        XCTAssertNotNil(second.first { $0.operation == .downloadStation })
    }

    func testFileStation旧观察代次不能覆盖新Repository快照() async {
        let profileID = UUID()
        let coordinator = MobileTransferCoordinator()
        let oldToken = UUID()
        let newToken = UUID()
        await coordinator.beginFileStationObservation(profileID: profileID, token: oldToken)
        await coordinator.syncFileStationTasks(
            profileID: profileID,
            observationToken: oldToken,
            tasks: [backgroundTask("old", .delete, .active)]
        )
        await coordinator.beginFileStationObservation(profileID: profileID, token: newToken)
        await coordinator.syncFileStationTasks(
            profileID: profileID,
            observationToken: newToken,
            tasks: [backgroundTask("new", .compress, .active)]
        )

        await coordinator.syncFileStationTasks(
            profileID: profileID,
            observationToken: oldToken,
            tasks: [backgroundTask("late", .extract, .active)]
        )

        let tasks = await coordinator.tasks(profileID: profileID)
        XCTAssertEqual(tasks.map(\.sourceIdentifier), ["file-background:new"])
    }

    private func backgroundTask(
        _ id: String,
        _ kind: FileBackgroundTaskKind,
        _ state: FileBackgroundTaskState,
        createdAt: Date? = nil
    ) -> FileBackgroundTaskSummary {
        FileBackgroundTaskSummary(
            id: id,
            kind: kind,
            state: state,
            progress: 0.4,
            createdAt: createdAt,
            processedItemCount: 2,
            totalItemCount: 5,
            processedBytes: 40,
            totalBytes: 100
        )
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
            operation: direction == .upload ? .appUpload : .appDownload,
            stableTarget: "/home/file.txt",
            progress: .zero,
            status: status,
            retryPolicy: retryPolicy,
            mutationResult: nil
        )
    }
}
