@testable import DsmMobile
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
        XCTAssertFalse(makeTask(status: .cancelling).canCancel)
        XCTAssertFalse(makeTask(status: .succeeded).canCancel)
        XCTAssertFalse(makeTask(status: .resultNeedsReview).canCancel)
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
            direction: direction,
            stableTarget: "/home/file.txt",
            progress: .zero,
            status: status,
            retryPolicy: retryPolicy,
            mutationResult: nil
        )
    }
}
