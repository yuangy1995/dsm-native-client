import DsmCore
@testable import DsmMobile
import XCTest

private enum TransferTestError: Error {
    case failed
}

private actor RecordingTransferService: MobileTransferServing {
    enum UploadBehavior: Sendable {
        case succeed
        case fail
        case suspend
        case ignoreCancellationThenSucceed
    }

    enum DownloadBehavior: Sendable {
        case succeed
        case fail
        case suspend
        case ignoreCancellationThenSucceed
        case delayedProgressAcrossRetry
    }

    private let uploadBehavior: UploadBehavior
    private let downloadBehavior: DownloadBehavior
    private(set) var uploadCount = 0
    private(set) var downloadCount = 0
    private(set) var reviewCount = 0
    private(set) var cleanupCount = 0

    init(
        uploadBehavior: UploadBehavior = .succeed,
        downloadBehavior: DownloadBehavior = .succeed
    ) {
        self.uploadBehavior = uploadBehavior
        self.downloadBehavior = downloadBehavior
    }

    func upload(
        _ request: MobileUploadRequest,
        progress: @escaping FileTransferProgress
    ) async throws {
        uploadCount += 1
        progress(40, 100)
        switch uploadBehavior {
        case .succeed:
            return
        case .fail:
            try await Task.sleep(for: .milliseconds(20))
            throw TransferTestError.failed
        case .suspend:
            try await Task.sleep(for: .seconds(30))
        case .ignoreCancellationThenSucceed:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                return
            }
        }
    }

    func reviewUpload(_ request: MobileUploadRequest) async throws -> MutationResult? {
        reviewCount += 1
        return nil
    }

    func download(
        _ request: MobileDownloadRequest,
        progress: @escaping FileTransferProgress
    ) async throws {
        downloadCount += 1
        if case .delayedProgressAcrossRetry = downloadBehavior {
            // 该场景在各分支内精确发送进度，避免把同一代的 25%/20% 回调竞态
            // 误当成旧一代延迟回调覆盖问题。
        } else {
            progress(25, 100)
        }
        switch downloadBehavior {
        case .succeed:
            return
        case .fail:
            try await Task.sleep(for: .milliseconds(20))
            throw TransferTestError.failed
        case .suspend:
            try await Task.sleep(for: .seconds(30))
        case .ignoreCancellationThenSucceed:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                return
            }
        case .delayedProgressAcrossRetry:
            if downloadCount == 1 {
                progress(25, 100)
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    progress(90, 100)
                }
                try await Task.sleep(for: .milliseconds(20))
                throw TransferTestError.failed
            }
            progress(20, 100)
            try await Task.sleep(for: .seconds(30))
        }
    }

    func removePartialDownload(_ request: MobileDownloadRequest) async {
        cleanupCount += 1
    }
}

final class MobileTransferStateTests: XCTestCase {
    func test初始化不会自动创建或恢复任务() async {
        let coordinator = MobileTransferCoordinator()
        let tasks = await coordinator.allTasks()
        XCTAssertEqual(tasks, [])
    }

    func test提交前取消不会调用上传服务() async {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService()
        let id = await coordinator.enqueueUpload(uploadRequest())

        await coordinator.cancel(id)

        let task = await coordinator.task(id: id)
        let uploadCount = await service.uploadCount
        let reviewCount = await service.reviewCount
        XCTAssertEqual(task?.status, .cancelledBeforeSubmission)
        XCTAssertEqual(uploadCount, 0)
        XCTAssertEqual(reviewCount, 0)
    }

    func test上传提交后取消需要复核且绝不自动重放() async throws {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService(uploadBehavior: .suspend)
        let id = await coordinator.enqueueUpload(uploadRequest())
        await coordinator.start(id, using: service)
        try await waitForTransfer { await service.uploadCount == 1 }

        await coordinator.cancel(id)
        try await waitForTransfer {
            await coordinator.task(id: id)?.status == .resultNeedsReview
        }

        let uploadCount = await service.uploadCount
        let reviewCount = await service.reviewCount
        let status = await coordinator.task(id: id)?.status
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(reviewCount, 1)
        XCTAssertEqual(status, .resultNeedsReview)
    }

    func test未知上传失败只回读一次且零重放() async throws {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService(uploadBehavior: .fail)
        let id = await coordinator.enqueueUpload(uploadRequest())

        await coordinator.start(id, using: service)
        try await waitForTransfer {
            await coordinator.task(id: id)?.status == .resultNeedsReview
        }

        let uploadCount = await service.uploadCount
        let reviewCount = await service.reviewCount
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(reviewCount, 1)
    }

    func test上传服务忽略取消并正常返回仍需要复核() async throws {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService(uploadBehavior: .ignoreCancellationThenSucceed)
        let id = await coordinator.enqueueUpload(uploadRequest())
        await coordinator.start(id, using: service)
        try await waitForTransfer { await service.uploadCount == 1 }

        await coordinator.cancel(id)
        try await waitForTransfer {
            await coordinator.task(id: id)?.status == .resultNeedsReview
        }

        let task = await coordinator.task(id: id)
        let uploadCount = await service.uploadCount
        let reviewCount = await service.reviewCount
        XCTAssertEqual(task?.status, .resultNeedsReview)
        XCTAssertNotEqual(task?.status, .succeeded)
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(reviewCount, 1)
    }

    func test上传结果待复核时普通重试不会产生第二次调用() async throws {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService(uploadBehavior: .fail)
        let id = await coordinator.enqueueUpload(uploadRequest())
        await coordinator.start(id, using: service)
        try await waitForTransfer {
            await coordinator.task(id: id)?.status == .resultNeedsReview
        }

        await coordinator.retryFromBeginning(id, using: service)
        try await Task.sleep(for: .milliseconds(30))

        let task = await coordinator.task(id: id)
        let uploadCount = await service.uploadCount
        XCTAssertEqual(task?.status, .resultNeedsReview)
        XCTAssertEqual(task?.retryPolicy, MobileTransferRetryPolicy.none)
        XCTAssertEqual(uploadCount, 1)
    }

    func test上传成功后普通重试不会产生第二次调用() async throws {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService(uploadBehavior: .succeed)
        let id = await coordinator.enqueueUpload(uploadRequest())
        await coordinator.start(id, using: service)
        try await waitForTransfer { await coordinator.task(id: id)?.status == .succeeded }

        await coordinator.retryFromBeginning(id, using: service)
        try await Task.sleep(for: .milliseconds(30))

        let task = await coordinator.task(id: id)
        let uploadCount = await service.uploadCount
        XCTAssertEqual(task?.status, .succeeded)
        XCTAssertEqual(task?.retryPolicy, MobileTransferRetryPolicy.none)
        XCTAssertEqual(uploadCount, 1)
    }

    func test下载取消清理临时文件并显示普通取消() async throws {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService(downloadBehavior: .suspend)
        let id = await coordinator.enqueueDownload(downloadRequest())
        await coordinator.start(id, using: service)
        try await waitForTransfer { await service.downloadCount == 1 }

        await coordinator.cancel(id)
        try await waitForTransfer {
            await coordinator.task(id: id)?.status == .cancelled
        }

        let cleanupCount = await service.cleanupCount
        let progress = await coordinator.task(id: id)?.progress
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(progress, .zero)
    }

    func test下载服务忽略取消并正常返回仍会清理且不显示成功() async throws {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService(downloadBehavior: .ignoreCancellationThenSucceed)
        let id = await coordinator.enqueueDownload(downloadRequest())
        await coordinator.start(id, using: service)
        try await waitForTransfer { await service.downloadCount == 1 }

        await coordinator.cancel(id)
        try await waitForTransfer {
            await coordinator.task(id: id)?.status == .cancelled
        }

        let task = await coordinator.task(id: id)
        let cleanupCount = await service.cleanupCount
        XCTAssertEqual(task?.status, .cancelled)
        XCTAssertNotEqual(task?.status, .succeeded)
        XCTAssertEqual(cleanupCount, 1)
    }

    func test生产清理辅助方法删除明确的受控临时目标() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-transfer-cleanup-\(UUID().uuidString)", isDirectory: true)
        let target = directory.appendingPathComponent("download.tmp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data("data".utf8)))

        MobileFileTransferService.removeControlledTemporaryFile(at: target)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func test显式从头重试先把进度归零() async throws {
        let coordinator = MobileTransferCoordinator()
        let failingService = RecordingTransferService(downloadBehavior: .fail)
        let holdingService = RecordingTransferService(downloadBehavior: .suspend)
        let id = await coordinator.enqueueDownload(downloadRequest())
        await coordinator.start(id, using: failingService)
        try await waitForTransfer { await coordinator.task(id: id)?.status == .failed }
        let failedProgress = await coordinator.task(id: id)?.progress.completedBytes
        XCTAssertEqual(failedProgress, 25)

        await coordinator.retryFromBeginning(id, using: holdingService)
        let retried = await coordinator.task(id: id)
        XCTAssertEqual(retried?.progress, .zero)
        XCTAssertTrue(retried?.status == .preparing || retried?.status == .running)
        await coordinator.cancel(id)
    }

    func test旧执行延迟进度不会覆盖新一代执行进度() async throws {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService(downloadBehavior: .delayedProgressAcrossRetry)
        let id = await coordinator.enqueueDownload(downloadRequest())
        await coordinator.start(id, using: service)
        try await waitForTransfer { await coordinator.task(id: id)?.status == .failed }

        await coordinator.retryFromBeginning(id, using: service)
        try await waitForTransfer {
            let task = await coordinator.task(id: id)
            return await service.downloadCount == 2 && task?.progress.completedBytes == 20
        }
        try await Task.sleep(for: .milliseconds(150))

        let task = await coordinator.task(id: id)
        XCTAssertEqual(task?.status, .running)
        XCTAssertEqual(task?.progress.completedBytes, 20)
        await coordinator.cancel(id)
    }

    func test任务按Profile隔离() async {
        let coordinator = MobileTransferCoordinator()
        let firstProfile = UUID()
        let secondProfile = UUID()
        _ = await coordinator.enqueueUpload(uploadRequest(profileID: firstProfile))
        _ = await coordinator.enqueueDownload(downloadRequest(profileID: secondProfile))

        let firstTasks = await coordinator.tasks(profileID: firstProfile)
        let secondTasks = await coordinator.tasks(profileID: secondProfile)
        XCTAssertEqual(firstTasks.map(\.profileID), [firstProfile])
        XCTAssertEqual(secondTasks.map(\.profileID), [secondProfile])
    }

    func test同目标并发任务只进入服务一次() async throws {
        let coordinator = MobileTransferCoordinator()
        let service = RecordingTransferService(uploadBehavior: .suspend)
        let request = uploadRequest()
        let first = await coordinator.enqueueUpload(request)
        let second = await coordinator.enqueueUpload(request)

        await coordinator.start(first, using: service)
        try await waitForTransfer { await service.uploadCount == 1 }
        await coordinator.start(second, using: service)
        try await waitForTransfer {
            await coordinator.task(id: second)?.status == .cancelledBeforeSubmission
        }

        let uploadCount = await service.uploadCount
        XCTAssertEqual(uploadCount, 1)
        await coordinator.cancel(first)
    }
}

private func uploadRequest(profileID: UUID = UUID()) -> MobileUploadRequest {
    MobileUploadRequest(
        profileID: profileID,
        localURL: URL(fileURLWithPath: "/tmp/mobile-transfer-source"),
        folderPath: "/destination",
        overwrite: false,
        stableTarget: "/destination/mobile-transfer-source"
    )
}

private func downloadRequest(profileID: UUID = UUID()) -> MobileDownloadRequest {
    MobileDownloadRequest(
        profileID: profileID,
        remotePath: "/source/file",
        temporaryURL: URL(fileURLWithPath: "/tmp/mobile-transfer-destination"),
        stableTarget: "/source/file"
    )
}

private func waitForTransfer(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("等待传输状态超时")
}
