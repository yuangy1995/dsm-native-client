import DsmCore
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class SynologyPhotosUploadRecoveryTests: XCTestCase {
    private func fixture() throws -> (URL, [PhotoUploadFile], PhotoUploadRecoveryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["first.jpg", "second.jpg"] { try Data(repeating: 1, count: 128).write(to: root.appendingPathComponent(name)) }
        let files = try PhotoUploadPreparation.prepare([root.appendingPathComponent("first.jpg"), root.appendingPathComponent("second.jpg")]).files
        XCTAssertEqual(files.count, 2)
        return (root, files, .init(url: root.appendingPathComponent("journal/queue.json")))
    }

    private func wait(_ model: SynologyPhotosModel) async throws {
        for _ in 0..<500 where model.isManaging { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(model.isManaging)
    }

    func test恢复上传回执只核对而未开始项等待手动继续() async throws {
        let (root, files, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PhotoUploadServiceStub(); await service.makeFirstUploadPending()
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: store, deletionReviewDelay: { _ in })
        await model.refresh(); model.enqueueUploads(files, album: nil, folder: .init(id: 9, name: "Fixture")); try await wait(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.pendingReview, .queued])
        let saved = try XCTUnwrap(store.load()), operationID = try XCTUnwrap(saved.checkpoint?.operationID)
        XCTAssertNotNil(saved.checkpoint?.itemID)
        let secondService = PhotoUploadServiceStub(profile: service.profile)
        let restored = SynologyPhotosModel(repository: secondService, uploadRecoveryStore: .init(url: store.url), deletionReviewDelay: { _ in })
        await restored.refresh()
        XCTAssertEqual(restored.uploadQueue.map(\.state), [.pendingReview, .cancelled])
        XCTAssertEqual(restored.pendingMutationID, operationID)
        var calls = await secondService.commands; XCTAssertTrue(calls.isEmpty)
        restored.reviewPendingMutation(); try await wait(restored)
        XCTAssertEqual(restored.uploadQueue.map(\.state), [.completed, .cancelled])
        calls = await secondService.commands; XCTAssertTrue(calls.isEmpty, "原上传不能重发")
        restored.resumeUploads(); try await wait(restored)
        XCTAssertEqual(restored.uploadQueue.map(\.state), [.completed, .completed])
        calls = await secondService.commands; XCTAssertEqual(calls.count, 1)
        guard case .upload(let source, _, _, let folder, _, _) = calls.first else { return XCTFail("只继续第二个文件") }
        XCTAssertEqual(source.lastPathComponent, "second.jpg"); XCTAssertEqual(folder, 9)
        let final = try XCTUnwrap(PhotoUploadRecoveryStore(url: store.url).load())
        XCTAssertNil(final.checkpoint); XCTAssertEqual(final.entries.map(\.state), [.completed, .completed])
    }

    func test相册加入失败跨重启只继续加入步骤() async throws {
        let (root, files, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PhotoUploadServiceStub(); await service.rejectNextAlbumAddition()
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: store, deletionReviewDelay: { _ in })
        await model.refresh(); model.enqueueUploads([files[0]], album: .init(id: 21, name: "Album"), folder: nil); try await wait(model)
        XCTAssertEqual(model.uploadQueue.first?.state, .failed); XCTAssertNotNil(model.uploadQueue.first?.uploadedPhoto)
        let secondService = PhotoUploadServiceStub(profile: service.profile)
        let restored = SynologyPhotosModel(repository: secondService, uploadRecoveryStore: .init(url: store.url), deletionReviewDelay: { _ in })
        await restored.refresh(); restored.retryUpload(files[0].id); try await wait(restored)
        XCTAssertEqual(restored.uploadQueue.first?.state, .completed)
        let calls = await secondService.commands; XCTAssertEqual(calls.count, 1)
        guard case .addToAlbum(let id, let photos) = calls.first else { return XCTFail("不得重新上传") }
        XCTAssertEqual(id, 21); XCTAssertEqual(photos.first?.id, model.uploadQueue.first?.uploadedPhoto?.id)
    }

    func test建目录回执跨重启核对并复用原目录() async throws {
        let (root, originals, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var files = originals; files[0].directoryComponents = ["Fixture directory"]
        let service = PhotoUploadServiceStub(); await service.makeFirstUploadPending()
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: store, deletionReviewDelay: { _ in })
        await model.refresh(); model.enqueueUploads([files[0]], album: nil, folder: .init(id: 9, name: "Root"), preserveDirectories: true); try await wait(model)
        let folderID = try XCTUnwrap(store.load()?.checkpoint?.folderID)
        let secondService = PhotoUploadServiceStub(profile: service.profile)
        let restored = SynologyPhotosModel(repository: secondService, uploadRecoveryStore: .init(url: store.url), deletionReviewDelay: { _ in })
        await restored.refresh(); restored.reviewPendingMutation(); try await wait(restored)
        XCTAssertEqual(restored.uploadQueue.first?.state, .cancelled)
        restored.resumeUploads(); try await wait(restored)
        XCTAssertEqual(restored.uploadQueue.first?.state, .completed)
        let calls = await secondService.commands; XCTAssertEqual(calls.count, 1)
        guard case .upload(_, _, _, let destination, _, _) = calls.first else { return XCTFail("不可重复创建目录") }
        XCTAssertEqual(destination, folderID)
    }

    func test恢复直接相册上传保留目标且不额外加入() async throws {
        let (root, files, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PhotoUploadServiceStub(); await service.makeFirstUploadPending()
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: store, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Shared album"))
        model.enqueueUploads([files[0]], album: model.selectedAlbum, folder: nil); try await wait(model)
        XCTAssertTrue(try XCTUnwrap(model.uploadQueue.first).directAlbumUpload)
        let secondService = PhotoUploadServiceStub(profile: service.profile)
        let restored = SynologyPhotosModel(repository: secondService, uploadRecoveryStore: .init(url: store.url), deletionReviewDelay: { _ in })
        await restored.refresh(); restored.reviewPendingMutation(); try await wait(restored)
        XCTAssertEqual(restored.uploadQueue.first?.state, .completed)
        XCTAssertEqual(restored.uploadQueue.first?.uploadedPhoto?.albumContext?.albumID, 21)
        let calls = await secondService.commands; XCTAssertTrue(calls.isEmpty)
    }

    func test原文件变化必须重新选择且不能用不同文件续传() async throws {
        let (root, files, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PhotoUploadServiceStub(), identity = try await service.uploadRecoveryIdentity()
        try store.save(identity: identity, entries: [PhotoUploadEntry(file: files[0], album: nil, folder: nil)], directories: [], pendingEntryID: nil, pendingDirectory: nil, pendingOperationID: nil)
        try Data(repeating: 2, count: 256).write(to: files[0].url)
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: .init(url: store.url))
        await model.refresh()
        XCTAssertEqual(model.uploadQueue.first?.file.requiresSourceSelection, true)
        XCTAssertFalse(model.canResumeUploads); model.retryUpload(files[0].id)
        model.reselectUploadSource(files[0].id, url: files[1].url)
        XCTAssertNotNil(model.uploadQueue.first?.error)
        let calls = await service.commands; XCTAssertTrue(calls.isEmpty)
    }

    func test恢复授权失效可重新选择原文件且保留队列身份() async throws {
        let (root, files, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PhotoUploadServiceStub(), identity = try await service.uploadRecoveryIdentity()
        var file = files[0]; file.recoveryBookmark = Data("invalid bookmark".utf8)
        try store.save(identity: identity, entries: [PhotoUploadEntry(file: file, album: nil, folder: .init(id: 9, name: "Root"))], directories: [], pendingEntryID: nil, pendingDirectory: nil, pendingOperationID: nil)
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: .init(url: store.url), deletionReviewDelay: { _ in })
        await model.refresh(); XCTAssertEqual(model.uploadQueue.first?.file.requiresSourceSelection, true)
        model.reselectUploadSource(file.id, url: files[0].url)
        XCTAssertEqual(model.uploadQueue.first?.id, file.id); XCTAssertEqual(model.uploadQueue.first?.file.requiresSourceSelection, false)
        model.resumeUploads(); try await wait(model); XCTAssertEqual(model.uploadQueue.first?.state, .completed)
    }

    func test账号不符或损坏记录不能覆盖也不能启动新上传() async throws {
        let (root, files, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PhotoUploadServiceStub(), identity = try await service.uploadRecoveryIdentity()
        try store.save(identity: identity, entries: [PhotoUploadEntry(file: files[0], album: nil, folder: nil)], directories: [], pendingEntryID: nil, pendingDirectory: nil, pendingOperationID: nil)
        let original = try Data(contentsOf: store.url)
        await service.setRecoveryUser(99)
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: .init(url: store.url))
        await model.refresh(); XCTAssertNotNil(model.uploadPersistenceError)
        model.enqueueUploads(files, album: nil, folder: nil); XCTAssertTrue(model.uploadQueue.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        try Data("broken".utf8).write(to: store.url)
        await service.setRecoveryUser(12); await model.retryUploadPersistence()
        XCTAssertNotNil(model.uploadPersistenceError); XCTAssertEqual(try Data(contentsOf: store.url), Data("broken".utf8))
        let calls = await service.commands; XCTAssertTrue(calls.isEmpty)
    }

    func test无回执恢复不会猜成功而核对后移除仅影响本机记录() async throws {
        let (root, files, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PhotoUploadServiceStub(), identity = try await service.uploadRecoveryIdentity(), operationID = UUID()
        try store.save(identity: identity, entries: files.map { PhotoUploadEntry(file: $0, album: nil, folder: nil) }, directories: [], pendingEntryID: files[0].id, pendingDirectory: nil, pendingOperationID: operationID)
        let command = SynologyPhotosMutation.upload(file: files[0].url, size: files[0].size, modifiedAt: files[0].modifiedAt, folderID: 9)
        try store.checkpoint(.init(mutation: command, operationID: operationID, profileID: service.profile, userID: 12))
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: .init(url: store.url), deletionReviewDelay: { _ in })
        await model.refresh(); model.reviewPendingMutation(); try await wait(model)
        XCTAssertEqual(model.uploadQueue.first?.state, .pendingReview); XCTAssertNotNil(model.pendingMutationID)
        model.retryUpload(files[0].id); model.clearUpload(files[0].id); XCTAssertEqual(model.uploadQueue.count, 2)
        await model.clearUnresolvedUploadAfterChecking(files[0].id)
        XCTAssertNil(model.pendingMutationID); XCTAssertEqual(model.uploadQueue.map(\.id), [files[1].id])
        let calls = await service.commands; XCTAssertTrue(calls.isEmpty)
        let saved = try XCTUnwrap(PhotoUploadRecoveryStore(url: store.url).load()); XCTAssertNil(saved.checkpoint)
        XCTAssertEqual(saved.entries.map(\.id), [files[1].id])
    }

    func test持久化失败在写入前暂停而恢复后可继续() async throws {
        let (root, files, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PhotoUploadServiceStub()
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: store, deletionReviewDelay: { _ in })
        await model.refresh()
        let directory = store.url.deletingLastPathComponent()
        try Data("not a directory".utf8).write(to: directory)
        model.enqueueUploads(files, album: nil, folder: nil)
        XCTAssertNotNil(model.uploadPersistenceError); XCTAssertFalse(model.isManaging)
        var calls = await service.commands; XCTAssertTrue(calls.isEmpty)
        try FileManager.default.removeItem(at: directory)
        await model.retryUploadPersistence(); XCTAssertNil(model.uploadPersistenceError)
        model.resumeUploads(); try await wait(model)
        calls = await service.commands; XCTAssertEqual(calls.count, 2)
    }

    func test记录权限和连接隔离且清理终态会保存() async throws {
        let (root, files, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PhotoUploadServiceStub()
        let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: store, deletionReviewDelay: { _ in })
        await model.refresh(); model.enqueueUploads([files[0]], album: nil, folder: nil); try await wait(model)
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        let folderMode = try FileManager.default.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600); XCTAssertEqual(folderMode?.intValue, 0o700)
        model.clearFinishedUploads(); XCTAssertTrue(try XCTUnwrap(PhotoUploadRecoveryStore(url: store.url).load()).entries.isEmpty)
        let id = UUID()
        let first = try NasProfile(id: id, displayName: "Fixture", host: "nas.invalid", port: 5001, usernameHint: "first")
        let second = try NasProfile(id: id, displayName: "Fixture", host: "nas.invalid", port: 5001, usernameHint: "second")
        let third = try NasProfile(id: id, displayName: "Fixture", host: "other.invalid", port: 5001, usernameHint: "first")
        XCTAssertNotEqual(PhotoUploadRecoveryStore.forProfile(first).url, PhotoUploadRecoveryStore.forProfile(second).url)
        XCTAssertNotEqual(PhotoUploadRecoveryStore.forProfile(first).url, PhotoUploadRecoveryStore.forProfile(third).url)
    }
}
