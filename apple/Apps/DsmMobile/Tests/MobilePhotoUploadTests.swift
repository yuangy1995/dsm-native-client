@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoUploadTests: XCTestCase {
    private func fixture(_ state: String = "photo-upload") async throws -> (URL, URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Sample image.jpg")
        try MobilePhotosUIService.image.write(to: source)
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("Recovery/queue.json"))
        let service = MobilePhotosUIService(state: state)
        let session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in })
        await session.activate()
        return (root, source, storage, service, session)
    }

    private func prepare(_ source: URL, session: MobileSynologyPhotosSession) async throws -> MobilePhotoUploadImportModel {
        let uploads = try XCTUnwrap(session.uploads)
        uploads.begin()
        uploads.prepareFiles([source], draftID: try XCTUnwrap(uploads.draftID))
        try await wait { !uploads.isPreparing }
        XCTAssertNil(uploads.error)
        XCTAssertEqual(uploads.files.count, 1)
        return uploads
    }

    func test选择后保留受控副本取消只删除草稿而不碰原件() async throws {
        let (root, source, storage, _, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try await prepare(source, session: session)
        let file = try XCTUnwrap(uploads.files.first)
        XCTAssertNotEqual(file.url, source)
        XCTAssertEqual(try Data(contentsOf: file.url), MobilePhotosUIService.image)
        XCTAssertTrue(file.url.path.hasPrefix(storage.sourcesURL.path))
        XCTAssertEqual(try storage.sourcesURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        uploads.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func test上传重复点击只提交一次而清理记录同时清理副本() async throws {
        let (root, source, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try await prepare(source, session: session)
        let file = try XCTUnwrap(uploads.files.first)
        XCTAssertTrue(uploads.submit()); XCTAssertFalse(uploads.submit())
        try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.uploadQueue.first?.state, .completed)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        guard case .upload(let url, _, _, _, _, _) = commands[0] else { return XCTFail("使用共享照片上传") }
        XCTAssertEqual(url, file.url)
        uploads.clear(file.id)
        XCTAssertTrue(session.model.uploadQueue.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func test账号隔离以及旧选择回调不能投递到新草稿() async throws {
        let (root, source, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try XCTUnwrap(session.uploads)
        uploads.begin(); let oldID = try XCTUnwrap(uploads.draftID)
        uploads.cancel(); uploads.begin()
        uploads.prepareFiles([source], draftID: oldID)
        XCTAssertFalse(uploads.isPreparing); XCTAssertTrue(uploads.files.isEmpty)
        session.configure(MobilePhotosUIService())
        uploads.prepareFiles([source], draftID: try XCTUnwrap(uploads.draftID ?? oldID))
        XCTAssertFalse(uploads.submit()); XCTAssertTrue(uploads.files.isEmpty)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        let id = UUID()
        let a = try NasProfile(id: id, displayName: "Sample", host: "example.invalid", port: 5001, usernameHint: "first")
        let b = try NasProfile(id: id, displayName: "Sample", host: "example.invalid", port: 5001, usernameHint: "second")
        XCTAssertNotEqual(MobilePhotoUploadStorage.forProfile(a).recordURL, MobilePhotoUploadStorage.forProfile(b).recordURL)
    }

    func test上传未知跨重启只读取原回执而不重传() async throws {
        let (root, source, storage, service, session) = try await fixture("photo-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try await prepare(source, session: session)
        XCTAssertTrue(uploads.submit()); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.uploadQueue.first?.state, .pendingReview)
        let id = try XCTUnwrap(session.model.uploadQueue.first?.id)
        uploads.clear(id); session.model.retryUpload(id)
        XCTAssertEqual(session.model.uploadQueue.count, 1)
        session.deactivate()
        let restoredService = MobilePhotosUIService(profileID: service.profileID)
        let restored = MobileSynologyPhotosSession()
        restored.configure(restoredService, uploadStorage: storage, reviewDelay: { _ in })
        await restored.activate()
        XCTAssertEqual(restored.model.uploadQueue.first?.state, .pendingReview)
        restored.model.reviewPendingMutation(); try await wait { !restored.model.isManaging }
        XCTAssertEqual(restored.model.uploadQueue.first?.state, .completed)
        let commands = await restoredService.commands; XCTAssertTrue(commands.isEmpty)
        let reviews = await restoredService.reviews; XCTAssertEqual(reviews, 1)
    }

    func test相册加入失败重启后只补加入步骤() async throws {
        let (root, source, storage, service, session) = try await fixture("photo-album-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        await session.model.selectSection(.albums)
        await session.model.open(.init(id: 21, name: "Sample album"))
        let uploads = try await prepare(source, session: session)
        XCTAssertTrue(uploads.submit()); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.uploadQueue.first?.state, .failed)
        XCTAssertNotNil(session.model.uploadQueue.first?.uploadedPhoto)
        let id = try XCTUnwrap(session.model.uploadQueue.first?.id)
        session.deactivate()
        let second = MobilePhotosUIService(profileID: service.profileID)
        let restored = MobileSynologyPhotosSession()
        restored.configure(second, uploadStorage: storage, reviewDelay: { _ in })
        await restored.activate()
        restored.model.retryUpload(id); try await wait { !restored.model.isManaging }
        XCTAssertEqual(restored.model.uploadQueue.first?.state, .completed)
        let commands = await second.commands
        XCTAssertEqual(commands.count, 1)
        guard case .addToAlbum(let album, _) = commands.first else { return XCTFail("不重传已确认照片") }
        XCTAssertEqual(album, 21)
    }

    func test贡献相册采用直接上传不另行加入或借用本人目录() async throws {
        let (root, source, _, service, session) = try await fixture("photo-contributor")
        defer { try? FileManager.default.removeItem(at: root) }
        await session.model.selectSection(.albums)
        await session.model.open(.init(id: 21, name: "Sample album"))
        let uploads = try await prepare(source, session: session)
        XCTAssertTrue(uploads.submit()); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.uploadQueue.first?.state, .completed)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        guard case .uploadToAlbum(_, _, _, let album, _) = commands.first else { return XCTFail("共享相册独立授权") }
        XCTAssertEqual(album, 21)
    }

    func test持久化失败零提交并保留副本供稍后继续() async throws {
        let (root, source, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try await prepare(source, session: session)
        let copy = try XCTUnwrap(uploads.files.first)
        try FileManager.default.createDirectory(at: storage.recordURL, withIntermediateDirectories: true)
        XCTAssertTrue(uploads.submit())
        XCTAssertNotNil(session.model.uploadPersistenceError)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.url.path))
        try FileManager.default.removeItem(at: storage.recordURL)
        await session.model.retryUploadPersistence()
        session.model.resumeUploads(); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.uploadQueue.first?.state, .completed)
    }

    func test损坏恢复记录不被空队列覆盖且不开放上传() async throws {
        let (root, _, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        session.deactivate()
        try Data("broken".utf8).write(to: storage.recordURL)
        let restored = MobileSynologyPhotosSession()
        restored.configure(service, uploadStorage: storage, reviewDelay: { _ in })
        await restored.activate()
        XCTAssertNotNil(restored.model.uploadPersistenceError)
        XCTAssertEqual(restored.uploads?.canBegin, false)
        XCTAssertEqual(try Data(contentsOf: storage.recordURL), Data("broken".utf8))
    }

    func test权限撤销和目标变化拒绝旧上传表单() async throws {
        let (root, source, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try await prepare(source, session: session)
        await session.model.selectSpace(.shared)
        XCTAssertFalse(uploads.submit())
        uploads.cancel()
        await service.denyWrites(); await session.model.refresh()
        uploads.begin(); XCTAssertNil(uploads.draftID)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test书签拒绝账号目录外的来源和符号链接() async throws {
        let (root, source, storage, _, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try await prepare(source, session: session)
        let file = try XCTUnwrap(uploads.files.first)
        let adapter = MobilePhotoUploadBookmarkAccess(ownedRoot: storage.sourcesURL)
        XCTAssertThrowsError(try adapter.makeBookmark(for: source))
        let bookmark = try adapter.makeBookmark(for: file.url)
        XCTAssertEqual(try adapter.resolve(bookmark).url.resolvingSymlinksInPath(), file.url.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: source)
        XCTAssertThrowsError(try adapter.makeBookmark(for: file.url))
    }

    func test选择器在取消后才返回时清理副本且不改新草稿() async throws {
        let (root, source, storage, _, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try XCTUnwrap(session.uploads)
        let item = HeldPhotoItem(url: source)
        uploads.begin(); let oldID = try XCTUnwrap(uploads.draftID)
        uploads.preparePhotos([item], draftID: oldID)
        for _ in 0..<100 { if await item.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        let started = await item.started; XCTAssertTrue(started)
        uploads.cancel(); uploads.begin()
        let nextID = uploads.draftID
        await item.release()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(uploads.draftID, nextID); XCTAssertFalse(uploads.isPreparing); XCTAssertTrue(uploads.files.isEmpty)
        let copies = (try? FileManager.default.contentsOfDirectory(at: storage.sourcesURL, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(copies.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func test目录上传保留层次且同名源文件不会互相覆盖() async throws {
        let (root, _, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Album import")
        for folder in ["First", "Second"] {
            let target = directory.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try MobilePhotosUIService.image.write(to: target.appendingPathComponent("same.jpg"))
        }
        let uploads = try XCTUnwrap(session.uploads); uploads.begin()
        uploads.prepareFiles([directory], draftID: try XCTUnwrap(uploads.draftID))
        try await wait { !uploads.isPreparing }
        XCTAssertTrue(uploads.includesDirectory); XCTAssertEqual(uploads.files.count, 2)
        XCTAssertEqual(Set(uploads.files.map(\.url)).count, 2)
        XCTAssertTrue(uploads.files.allSatisfy { $0.url.path.hasPrefix(storage.sourcesURL.path) })
        XCTAssertEqual(Set(uploads.files.map(\.directoryComponents)), Set([["Album import", "First"], ["Album import", "Second"]]))
        XCTAssertTrue(uploads.submit()); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.uploadQueue.map(\.state), [.completed, .completed])
        let commands = await service.commands
        XCTAssertEqual(commands.filter { if case .upload = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(commands.filter { if case .createFolder = $0 { return true }; return false }.count, 3)
    }

    func test副本丢失重新选择原件恢复且拒绝不匹配的文件() async throws {
        let (root, source, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try await prepare(source, session: session)
        let file = try XCTUnwrap(uploads.files.first)
        await service.denyWrites()
        XCTAssertTrue(uploads.submit()); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.uploadQueue.first?.state, .failed)
        session.deactivate()
        try FileManager.default.removeItem(at: file.url)
        let restoredService = MobilePhotosUIService(profileID: service.profileID)
        let restored = MobileSynologyPhotosSession()
        restored.configure(restoredService, uploadStorage: storage, reviewDelay: { _ in })
        await restored.activate()
        XCTAssertEqual(restored.model.uploadQueue.first?.file.requiresSourceSelection, true)
        let wrong = root.appendingPathComponent("Other.jpg"); try MobilePhotosUIService.image.write(to: wrong)
        let recovery = try XCTUnwrap(restored.uploads)
        recovery.reselect(file.id, url: wrong); try await wait { !recovery.isPreparing }
        XCTAssertEqual(restored.model.uploadQueue.first?.file.requiresSourceSelection, true)
        recovery.reselect(file.id, url: source); try await wait { !recovery.isPreparing }
        XCTAssertEqual(restored.model.uploadQueue.first?.file.requiresSourceSelection, false)
        restored.model.retryUpload(file.id); try await wait { !restored.model.isManaging }
        XCTAssertEqual(restored.model.uploadQueue.first?.state, .completed)
        let commands = await restoredService.commands; XCTAssertEqual(commands.count, 1)
    }

    func test同账号重连旧上传迟到结束不能覆盖新的队列记录() async throws {
        let (root, source, storage, service, session) = try await fixture("photo-held")
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try await prepare(source, session: session)
        XCTAssertTrue(uploads.submit())
        for _ in 0..<100 { if await service.isUploadHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        let held = await service.isUploadHeld; XCTAssertTrue(held)
        let oldModel = session.model
        let second = MobilePhotosUIService(profileID: service.profileID)
        session.configure(second, uploadStorage: storage, reviewDelay: { _ in })
        await session.activate()
        session.model.reviewPendingMutation(); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.uploadQueue.first?.state, .completed)
        let next = try await prepare(source, session: session)
        XCTAssertTrue(next.submit()); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.uploadQueue.count, 2)
        let current = try Data(contentsOf: storage.recordURL)
        await service.releaseUpload(); try await wait { !oldModel.isManaging }
        XCTAssertEqual(try Data(contentsOf: storage.recordURL), current)
        XCTAssertEqual(session.model.uploadQueue.map(\.state), [.completed, .completed])
    }

    func test重启清理未提交草稿但损坏队列保留所有副本() async throws {
        let (root, source, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        session.deactivate()
        let abandoned = try XCTUnwrap(storage.prepare([source]).files.first)
        let restored = MobileSynologyPhotosSession()
        restored.configure(service, uploadStorage: storage, reviewDelay: { _ in })
        await restored.activate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        restored.deactivate()
        let retained = try XCTUnwrap(storage.prepare([source]).files.first)
        try Data("broken".utf8).write(to: storage.recordURL)
        let corrupted = MobileSynologyPhotosSession()
        corrupted.configure(service, uploadStorage: storage, reviewDelay: { _ in })
        await corrupted.activate()
        XCTAssertNotNil(corrupted.model.uploadPersistenceError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.url.path))
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("合成上传未在预期时间内完成")
    }
}

private actor HeldPhotoItem: MobilePhotosPickerItemServing {
    nonisolated let selectionID = UUID().uuidString
    let url: URL
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    init(url: URL) { self.url = url }
    func loadArtifact() async throws -> MobilePhotosPickerArtifact {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return MobilePhotosPickerArtifact(url: url)
    }
    func release() { continuation?.resume(); continuation = nil }
}
