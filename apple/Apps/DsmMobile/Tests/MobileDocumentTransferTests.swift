import DsmCore
@testable import DsmMobile
import Foundation
import XCTest

private actor DocumentTransferServiceSpy: MobileTransferServing {
    enum Behavior: Sendable {
        case succeed
        case uploadNeedsReview
        case fail(AppErrorCategory)
    }

    let behavior: Behavior
    private(set) var uploadCount = 0
    private(set) var downloadCount = 0
    private(set) var reviewCount = 0
    private(set) var copiedUploadExistsAtSubmission = false
    private(set) var uploadedLocalURL: URL?

    init(behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    func upload(
        _ request: MobileUploadRequest,
        progress: @escaping FileTransferProgress
    ) async throws {
        uploadCount += 1
        uploadedLocalURL = request.localURL
        copiedUploadExistsAtSubmission = FileManager.default.fileExists(atPath: request.localURL.path)
        progress(1, 1)
        if case .uploadNeedsReview = behavior {
            throw AppError(category: .networkUnavailable, isRetryable: true, safeUserMessage: "test")
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
        if case .fail(let category) = behavior {
            throw AppError(category: category, isRetryable: false, safeUserMessage: "test")
        }
        _ = FileManager.default.createFile(
            atPath: request.temporaryURL.path,
            contents: Data("download".utf8)
        )
        progress(8, 8)
    }

    func removePartialDownload(_ request: MobileDownloadRequest) async {
        try? FileManager.default.removeItem(at: request.temporaryURL)
    }
}

private struct FailingDocumentImportCopier: MobileDocumentImportCopying {
    func copySecurityScopedFile(
        from sourceURL: URL,
        to destinationURL: URL,
        in directoryURL: URL
    ) async throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: destinationURL.path, contents: Data("partial".utf8))
        throw AppError(category: .localStorageFull, isRetryable: false, safeUserMessage: "test")
    }
}

private actor ReorderedDocumentDownloadService: MobileTransferServing {
    func upload(
        _ request: MobileUploadRequest,
        progress: @escaping FileTransferProgress
    ) async throws {}

    func reviewUpload(_ request: MobileUploadRequest) async throws -> MutationResult? { nil }

    func download(
        _ request: MobileDownloadRequest,
        progress: @escaping FileTransferProgress
    ) async throws {
        if request.remotePath.contains("first") {
            try await Task.sleep(for: .milliseconds(220))
        } else {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = FileManager.default.createFile(
            atPath: request.temporaryURL.path,
            contents: Data(request.remotePath.utf8)
        )
    }

    func removePartialDownload(_ request: MobileDownloadRequest) async {
        try? FileManager.default.removeItem(at: request.temporaryURL)
    }
}

@MainActor
final class MobileDocumentTransferTests: XCTestCase {
    func testPicker取消路径不创建任务或临时目录() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let tasks = await fixture.coordinator.allTasks()
        XCTAssertTrue(tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func test安全范围文件先复制到受控目录再提交上传() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = DocumentTransferServiceSpy()
        let source = fixture.base.appendingPathComponent("source.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data("upload".utf8)))
        let profileID = UUID()

        let taskID = await fixture.controller.handlePickedFile(
            source,
            context: MobileDocumentPickerContext(
                profileID: profileID,
                folderPath: "/home",
                intent: .upload
            ),
            service: service
        )

        let id = try XCTUnwrap(taskID)
        try await waitUntil { await fixture.coordinator.task(id: id)?.status == .succeeded }
        try await waitUntil { !fixture.controller.ownsArtifact(taskID: id) }
        let uploadCount = await service.uploadCount
        let copiedBeforeSubmission = await service.copiedUploadExistsAtSubmission
        let uploadedLocalURL = await service.uploadedLocalURL
        let retryPolicy = await fixture.coordinator.task(id: id)?.retryPolicy
        XCTAssertEqual(uploadCount, 1)
        XCTAssertTrue(copiedBeforeSubmission)
        XCTAssertNotEqual(uploadedLocalURL, source)
        XCTAssertTrue(uploadedLocalURL?.path.hasPrefix(fixture.root.path) == true)
        XCTAssertEqual(retryPolicy, MobileTransferRetryPolicy.none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func test文档协调复制失败会清理残留且零入队() async throws {
        let fixture = try makeFixture(importCopier: FailingDocumentImportCopier())
        defer { fixture.cleanup() }
        let source = fixture.base.appendingPathComponent("source.txt")
        _ = FileManager.default.createFile(atPath: source.path, contents: Data("source".utf8))

        let taskID = await fixture.controller.handlePickedFile(
            source,
            context: MobileDocumentPickerContext(profileID: UUID(), folderPath: "/", intent: .upload),
            service: DocumentTransferServiceSpy()
        )

        XCTAssertNil(taskID)
        XCTAssertEqual(fixture.controller.failure, .localStorageFull)
        let tasks = await fixture.coordinator.allTasks()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertTrue(tasks.isEmpty)
        XCTAssertTrue(remaining.isEmpty)
    }

    func test上传提交后失败只复核一次清副本且禁用重试() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = DocumentTransferServiceSpy(behavior: .uploadNeedsReview)
        let source = fixture.base.appendingPathComponent("source.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data("upload".utf8)))

        let taskIDResult = await fixture.controller.handlePickedFile(
            source,
            context: MobileDocumentPickerContext(profileID: UUID(), folderPath: "/", intent: .upload),
            service: service
        )
        let taskID = try XCTUnwrap(taskIDResult)
        try await waitUntil {
            await fixture.coordinator.task(id: taskID)?.status == .resultNeedsReview
        }
        try await waitUntil { !fixture.controller.ownsArtifact(taskID: taskID) }
        await fixture.coordinator.retryFromBeginning(taskID, using: service)

        let uploadCount = await service.uploadCount
        let reviewCount = await service.reviewCount
        let retryPolicy = await fixture.coordinator.task(id: taskID)?.retryPolicy
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(reviewCount, 1)
        XCTAssertEqual(retryPolicy, MobileTransferRetryPolicy.none)
    }

    func test下载完成后按冻结Intent展示且系统完成后清理() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = DocumentTransferServiceSpy()
        let profileID = UUID()
        fixture.controller.setActiveProfile(profileID)

        let taskIDResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: profileID,
                remotePath: "/home/report.pdf",
                fileName: "report.pdf",
                intent: .exportCopy
            ),
            service: service
        )
        let taskID = try XCTUnwrap(taskIDResult)
        try await waitUntil { fixture.controller.presentation?.taskID == taskID }
        let presentation = try XCTUnwrap(fixture.controller.presentation)
        XCTAssertEqual(presentation.intent, .exportCopy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: presentation.url.path))

        fixture.controller.requestDismiss(taskID: taskID)

        XCTAssertNil(fixture.controller.presentation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: presentation.url.path))
        XCTAssertFalse(fixture.controller.ownsArtifact(taskID: taskID))
    }

    func test切换Profile期间完成不会弹出跨Profile系统面板() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = DocumentTransferServiceSpy()
        let requestedProfile = UUID()
        fixture.controller.setActiveProfile(UUID())

        let taskIDResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: requestedProfile,
                remotePath: "/home/file.txt",
                fileName: "file.txt",
                intent: .share
            ),
            service: service
        )
        let taskID = try XCTUnwrap(taskIDResult)
        try await waitUntil { await fixture.coordinator.task(id: taskID)?.status == .succeeded }
        try await waitUntil { !fixture.controller.ownsArtifact(taskID: taskID) }

        XCTAssertNil(fixture.controller.presentation)
    }

    func test已经展示后切换Profile会立即关闭并清理Artifact() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = DocumentTransferServiceSpy()
        let profileID = UUID()
        fixture.controller.setActiveProfile(profileID)
        let taskIDResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: profileID,
                remotePath: "/shown.txt",
                fileName: "shown.txt",
                intent: .share
            ),
            service: service
        )
        let taskID = try XCTUnwrap(taskIDResult)
        try await waitUntil { fixture.controller.presentation?.taskID == taskID }
        let artifactURL = try XCTUnwrap(fixture.controller.presentation?.url)

        fixture.controller.setActiveProfile(UUID())

        XCTAssertNil(fixture.controller.presentation)
        XCTAssertFalse(fixture.controller.ownsArtifact(taskID: taskID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    func test并发下载完成使用FIFO且不会覆盖当前Presentation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = ReorderedDocumentDownloadService()
        let profileID = UUID()
        fixture.controller.setActiveProfile(profileID)
        let firstResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: profileID,
                remotePath: "/first.txt",
                fileName: "first.txt",
                intent: .exportCopy
            ),
            service: service
        )
        let secondResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: profileID,
                remotePath: "/second.txt",
                fileName: "second.txt",
                intent: .share
            ),
            service: service
        )
        let firstID = try XCTUnwrap(firstResult)
        let secondID = try XCTUnwrap(secondResult)
        try await waitUntil { fixture.controller.presentation?.taskID == secondID }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(fixture.controller.presentation?.taskID, secondID)
        XCTAssertTrue(fixture.controller.ownsArtifact(taskID: firstID))
        fixture.controller.requestDismiss(taskID: secondID)
        XCTAssertNil(fixture.controller.presentation)
        XCTAssertTrue(fixture.controller.ownsArtifact(taskID: firstID))
        fixture.controller.presentationDidDismiss()
        XCTAssertEqual(fixture.controller.presentation?.taskID, firstID)
        fixture.controller.requestDismiss(taskID: firstID)
        fixture.controller.presentationDidDismiss()
        XCTAssertNil(fixture.controller.presentation)
        XCTAssertFalse(fixture.controller.ownsArtifact(taskID: firstID))
        XCTAssertFalse(fixture.controller.ownsArtifact(taskID: secondID))
    }

    func test系统Dismiss完成前不推进且旧Binding重复Dismiss不清理下一项() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = ReorderedDocumentDownloadService()
        let profileID = UUID()
        fixture.controller.setActiveProfile(profileID)
        let firstResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: profileID,
                remotePath: "/first.txt",
                fileName: "first.txt",
                intent: .exportCopy
            ),
            service: service
        )
        let secondResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: profileID,
                remotePath: "/second.txt",
                fileName: "second.txt",
                intent: .share
            ),
            service: service
        )
        let firstID = try XCTUnwrap(firstResult)
        let secondID = try XCTUnwrap(secondResult)
        try await waitUntil { fixture.controller.presentation?.taskID == secondID }
        try await Task.sleep(for: .milliseconds(300))

        fixture.controller.requestDismiss(taskID: secondID)
        XCTAssertNil(fixture.controller.presentation)
        XCTAssertTrue(fixture.controller.isAwaitingSystemDismissal)
        XCTAssertTrue(fixture.controller.ownsArtifact(taskID: firstID))
        fixture.controller.requestDismiss(taskID: secondID)
        XCTAssertNil(fixture.controller.presentation)
        XCTAssertTrue(fixture.controller.ownsArtifact(taskID: firstID))

        fixture.controller.presentationDidDismiss()
        XCTAssertEqual(fixture.controller.presentation?.taskID, firstID)
        XCTAssertFalse(fixture.controller.isAwaitingSystemDismissal)
    }

    func testProfile切换会等待系统Dismiss回调() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let profileID = UUID()
        fixture.controller.setActiveProfile(profileID)
        let taskIDResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: profileID,
                remotePath: "/shown.txt",
                fileName: "shown.txt",
                intent: .share
            ),
            service: DocumentTransferServiceSpy()
        )
        let taskID = try XCTUnwrap(taskIDResult)
        try await waitUntil { fixture.controller.presentation?.taskID == taskID }

        fixture.controller.setActiveProfile(UUID())

        XCTAssertNil(fixture.controller.presentation)
        XCTAssertTrue(fixture.controller.isAwaitingSystemDismissal)
        fixture.controller.presentationDidDismiss()
        XCTAssertFalse(fixture.controller.isAwaitingSystemDismissal)
        XCTAssertNil(fixture.controller.presentation)
    }

    func test工作区断开不等待已移除Presenter并立即清理系统面板Artifact() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let profileID = UUID()
        fixture.controller.setActiveProfile(profileID)
        let taskIDResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: profileID,
                remotePath: "/logout.jpg",
                fileName: "logout.jpg",
                intent: .share
            ),
            service: DocumentTransferServiceSpy()
        )
        let taskID = try XCTUnwrap(taskIDResult)
        try await waitUntil { fixture.controller.presentation?.taskID == taskID }
        let artifactURL = try XCTUnwrap(fixture.controller.presentation?.url)

        fixture.controller.resetForDisconnectedWorkspace()

        XCTAssertNil(fixture.controller.presentation)
        XCTAssertFalse(fixture.controller.isAwaitingSystemDismissal)
        XCTAssertFalse(fixture.controller.ownsArtifact(taskID: taskID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    func test下载错误使用稳定类别并清理临时文件() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = DocumentTransferServiceSpy(behavior: .fail(.remoteStorageFull))
        let profileID = UUID()
        fixture.controller.setActiveProfile(profileID)

        let taskIDResult = await fixture.controller.startDownload(
            context: MobileDocumentDownloadContext(
                profileID: profileID,
                remotePath: "/full.bin",
                fileName: "full.bin",
                intent: .share
            ),
            service: service
        )
        let taskID = try XCTUnwrap(taskIDResult)
        try await waitUntil { fixture.controller.failure == .remoteStorageFull }

        let category = await fixture.coordinator.task(id: taskID)?.failureCategory
        XCTAssertEqual(category, .remoteStorageFull)
        XCTAssertFalse(fixture.controller.ownsArtifact(taskID: taskID))
    }

    func test叶文件名拒绝路径穿越和控制字符() {
        XCTAssertEqual(MobileDocumentTransferController.safeLeafName("../../secret.txt"), "secret.txt")
        XCTAssertEqual(MobileDocumentTransferController.safeLeafName(".."), "file")
        XCTAssertEqual(MobileDocumentTransferController.safeLeafName("bad:\u{0000}name"), "badname")
    }

    func test首版策略明确禁止后台多选和续传() {
        XCTAssertFalse(MobileDocumentTransferPolicy.supportsBackgroundTransfer)
        XCTAssertFalse(MobileDocumentTransferPolicy.supportsMultipleSelection)
        XCTAssertFalse(MobileDocumentTransferPolicy.supportsResume)
    }

    func test分享完成回调严格幂等() {
        var completionCount = 0
        let coordinator = MobileShareSheet.Coordinator {
            completionCount += 1
        }

        coordinator.finishOnce()
        coordinator.finishOnce()

        XCTAssertEqual(completionCount, 1)
    }

    private func makeFixture(
        importCopier: any MobileDocumentImportCopying = MobileSecurityScopedDocumentCopier()
    ) throws -> (
        base: URL,
        root: URL,
        coordinator: MobileTransferCoordinator,
        controller: MobileDocumentTransferController,
        cleanup: () -> Void
    ) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-document-tests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let coordinator = MobileTransferCoordinator()
        let controller = MobileDocumentTransferController(
            transferCoordinator: coordinator,
            importCopier: importCopier,
            rootURL: root
        )
        return (base, root, coordinator, controller, { try? FileManager.default.removeItem(at: base) })
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待文档传输状态超时")
    }
}
