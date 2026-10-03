import DsmCore
@testable import DsmMobile
import Foundation
import XCTest

private actor RecoveryTransferService: MobileTransferServing {
    private(set) var uploads = 0
    private(set) var downloads = 0
    private(set) var reviews = 0
    let confirmsUpload: Bool

    init(confirmsUpload: Bool = false) { self.confirmsUpload = confirmsUpload }
    func upload(_ request: MobileUploadRequest, progress: @escaping FileTransferProgress) async throws { uploads += 1 }
    func download(_ request: MobileDownloadRequest, progress: @escaping FileTransferProgress) async throws {
        downloads += 1
        try FileManager.default.createDirectory(at: request.temporaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: request.temporaryURL)
    }
    func reviewUpload(_ request: MobileUploadRequest) async throws -> MutationResult? {
        reviews += 1
        guard confirmsUpload else { return nil }
        return try MutationResult(status: .confirmedSuccess, operation: "upload", submitted: true,
            requiresRefresh: false, counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0))
    }
    func removePartialDownload(_ request: MobileDownloadRequest) async {}
}

final class MobileTransferRecoveryTests: XCTestCase {
    func test恢复未提交任务需显式继续且不会自动上传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = MobileTransferCoordinator(recoveryStore: fixture.store)
        await first.activateContext(fixture.identity)
        let id = await first.enqueueUpload(fixture.upload)

        let recovered = MobileTransferCoordinator(recoveryStore: fixture.store)
        await recovered.activateContext(fixture.identity)
        let task = await recovered.task(id: id)
        XCTAssertEqual(task?.status, .paused)
        XCTAssertEqual(task?.stableTarget, fixture.upload.stableTarget)
        let service = RecoveryTransferService()
        let before = await service.uploads
        XCTAssertEqual(before, 0)
        await recovered.resume(id, using: service)
        try await Self.wait { await recovered.task(id: id)?.status == .succeeded }
        let uploads = await service.uploads
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(try fixture.store.load().first?.task.status, .succeeded)
    }

    func test进程中断后的上传仅刷新且未知结果不重传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = fixture.record(status: .running)
        try fixture.store.save([record])
        let recovered = MobileTransferCoordinator(recoveryStore: fixture.store)
        await recovered.activateContext(fixture.identity)
        let service = RecoveryTransferService()
        await recovered.resume(record.task.id, using: service)
        await recovered.retryFromBeginning(record.task.id, using: service)
        await recovered.refreshUpload(record.task.id, using: service)
        let task = await recovered.task(id: record.task.id)
        let uploads = await service.uploads
        let reviews = await service.reviews
        XCTAssertEqual(task?.status, .resultNeedsReview)
        XCTAssertEqual(task?.retryPolicy, MobileTransferRetryPolicy.none)
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(reviews, 1)
    }

    func test未知上传内容确认后结束且不再提交() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = fixture.record(status: .cancelling)
        try fixture.store.save([record])
        let recovered = MobileTransferCoordinator(recoveryStore: fixture.store)
        await recovered.activateContext(fixture.identity)
        let service = RecoveryTransferService(confirmsUpload: true)
        await recovered.refreshUpload(record.task.id, using: service)
        await recovered.retryFromBeginning(record.task.id, using: service)
        let task = await recovered.task(id: record.task.id)
        let uploads = await service.uploads
        XCTAssertEqual(task?.status, .succeeded)
        XCTAssertEqual(uploads, 0)
    }

    func test相同配置换账号不能看见或恢复旧任务() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = fixture.record(status: .queued)
        try fixture.store.save([record])
        let recovered = MobileTransferCoordinator(recoveryStore: fixture.store)
        let other = MobileWorkspaceIdentity(try NasProfile(id: fixture.profile.id, displayName: "Other",
            host: "fixture.example.invalid", port: 5001, usernameHint: "other"))
        await recovered.activateContext(other)
        let service = RecoveryTransferService()
        await recovered.resume(record.task.id, using: service)
        let tasks = await recovered.tasks(profileID: fixture.profile.id)
        let uploads = await service.uploads
        XCTAssertTrue(tasks.isEmpty)
        XCTAssertEqual(uploads, 0)
        await recovered.activateContext(fixture.identity)
        let originalTasks = await recovered.tasks(profileID: fixture.profile.id)
        XCTAssertEqual(originalTasks.map(\.id), [record.task.id])
    }

    func test损坏记录保留原件且不产生上传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = Data("invalid-journal".utf8)
        try original.write(to: fixture.store.recordsURL)
        let coordinator = MobileTransferCoordinator(recoveryStore: fixture.store)
        await coordinator.activateContext(fixture.identity)
        let service = RecoveryTransferService()
        let id = await coordinator.enqueueUpload(fixture.upload)
        await coordinator.start(id, using: service)
        let failure = await coordinator.recoveryFailure
        let uploads = await service.uploads
        XCTAssertTrue(failure)
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.store.recordsURL), original)
    }

    func test无法落盘时保持未提交且拒绝写请求() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = MobileTransferCoordinator(recoveryStore: fixture.store)
        await coordinator.activateContext(fixture.identity)
        // 把记录目标变成目录，模拟原子落盘失败，不修改任何真实数据。
        try FileManager.default.createDirectory(at: fixture.store.recordsURL, withIntermediateDirectories: true)
        let service = RecoveryTransferService()
        let id = await coordinator.enqueueUpload(fixture.upload)
        await coordinator.start(id, using: service)
        let task = await coordinator.task(id: id)
        let uploads = await service.uploads
        XCTAssertEqual(task?.status, .cancelledBeforeSubmission)
        XCTAssertEqual(task?.failureCategory, .localStorageFull)
        XCTAssertEqual(uploads, 0)
        try FileManager.default.removeItem(at: fixture.store.recordsURL)
        await coordinator.retryFromBeginning(id, using: service)
        try await Self.wait { await coordinator.task(id: id)?.status == .succeeded }
    }

    func test记录拒绝越出受控目录的文件和未来格式() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.record(status: .queued))) as! [String: Any]
        let outside = MobileUploadRequest(profileID: fixture.profile.id,
            localURL: fixture.store.rootURL.appendingPathComponent("outside.txt"), folderPath: "/synthetic",
            overwrite: false, stableTarget: fixture.upload.stableTarget)
        json["request"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MobileTransferRequest.upload(outside)))
        try JSONSerialization.data(withJSONObject: ["version": 1, "records": [json]]).write(to: fixture.store.recordsURL)
        XCTAssertThrowsError(try fixture.store.load())
        try JSONSerialization.data(withJSONObject: ["version": 99, "records": []]).write(to: fixture.store.recordsURL)
        XCTAssertThrowsError(try fixture.store.load())
    }

    func test重启下载从头恢复并保留导出意图() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var record = fixture.record(status: .running, download: true)
        record.task.progress = .init(completedBytes: 42, totalBytes: 100)
        try fixture.store.save([record])
        let recovered = MobileTransferCoordinator(recoveryStore: fixture.store)
        await recovered.activateContext(fixture.identity)
        let task = await recovered.task(id: record.task.id)
        XCTAssertEqual(task?.status, .cancelled)
        let service = RecoveryTransferService()
        await recovered.retryFromBeginning(record.task.id, using: service)
        let taskID = record.task.id
        try await Self.wait { await recovered.task(id: taskID)?.status == .succeeded }
        let request = await recovered.request(id: record.task.id)
        guard case .download(let download) = request else { return XCTFail("下载请求丢失") }
        XCTAssertEqual(download.intent, .share)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.temporaryURL.path))
        let count = await service.downloads
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func test下载恢复后只展示一次且导出完成不在下次启动重新弹出() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = fixture.record(status: .succeeded, download: true)
        try fixture.store.save([record])
        let coordinator = MobileTransferCoordinator(recoveryStore: fixture.store)
        await coordinator.activateContext(fixture.identity)
        let controller = MobileDocumentTransferController(transferCoordinator: coordinator, recoveryStore: fixture.store)
        controller.setActiveProfile(fixture.profile.id)
        await controller.restoreArtifacts(profileID: fixture.profile.id)
        for _ in 0..<100 where controller.presentation == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.presentation?.taskID, record.task.id)
        controller.requestDismiss(taskID: record.task.id)
        controller.presentationDidDismiss()
        try await Self.wait { await coordinator.task(id: record.task.id)?.retryPolicy == MobileTransferRetryPolicy.none }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.upload.localURL.path))
        let recovered = MobileTransferCoordinator(recoveryStore: fixture.store)
        await recovered.activateContext(fixture.identity)
        let second = MobileDocumentTransferController(transferCoordinator: recovered, recoveryStore: fixture.store)
        second.setActiveProfile(fixture.profile.id)
        await second.restoreArtifacts(profileID: fixture.profile.id)
        XCTAssertNil(second.presentation)
        XCTAssertFalse(second.ownsArtifact(taskID: record.task.id))
    }

    private struct Fixture {
        let store: MobileTransferRecoveryStore
        let profile: NasProfile
        var identity: MobileWorkspaceIdentity { MobileWorkspaceIdentity(profile) }
        let upload: MobileUploadRequest

        init() throws {
            store = MobileTransferRecoveryStore(rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mobile-recovery-\(UUID().uuidString)", isDirectory: true))
            profile = try NasProfile(displayName: "Fixture", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
            let url = store.artifactsURL.appendingPathComponent(UUID().uuidString).appendingPathComponent("sample.txt")
            try MobileTransferRecoveryStore.prepareDirectory(url.deletingLastPathComponent())
            try Data("sample".utf8).write(to: url)
            upload = MobileUploadRequest(profileID: profile.id, localURL: url, folderPath: "/synthetic",
                overwrite: false, stableTarget: "/synthetic/sample.txt")
        }

        func record(status: MobileTransferStatus, download: Bool = false) -> MobileTransferRecoveryStore.Record {
            .init(context: identity.storageIdentifier,
                task: .init(id: UUID(), createdAt: Date(), profileID: profile.id, source: .app, sourceIdentifier: nil,
                    operation: download ? .appDownload : .appUpload, stableTarget: upload.stableTarget,
                    progress: .zero, status: status, retryPolicy: .restartFromBeginning, mutationResult: nil),
                request: download ? .download(.init(profileID: profile.id, remotePath: upload.stableTarget,
                    temporaryURL: upload.localURL, stableTarget: upload.stableTarget, intent: .share)) : .upload(upload))
        }
        func cleanup() { try? FileManager.default.removeItem(at: store.rootURL) }
    }

    private static func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("恢复任务未完成")
    }
}
