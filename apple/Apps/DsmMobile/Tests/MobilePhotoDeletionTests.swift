@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoDeletionTests: XCTestCase {
    private func fixture(_ state: String = "photo-deletion") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-deletion-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待原件删除流程结束超时")
    }
    private func prepare(_ photos: [SynologyPhoto], model: SynologyPhotosModel) async throws {
        model.requestDeletion(photos); try await wait { !model.isCheckingDeletion }
        XCTAssertEqual(model.deletionCandidates, photos)
    }
    private func recordURL(_ storage: MobilePhotoUploadStorage) -> URL {
        storage.recordURL.deletingPathExtension().appendingPathComponent("Deletion/pending-v1.json")
    }

    func test批量删除使用完整固定选择并逐项记录成功() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = session.model, photos = Array(model.items.prefix(2)); XCTAssertEqual(photos.count, 2)
        try await prepare(photos, model: model); model.confirmDeletion(photos); model.confirmDeletion(photos)
        try await wait { !model.isDeleting }
        let deleted = await service.deletedPhotoIDs; XCTAssertEqual(deleted, photos.map(\.id))
        XCTAssertEqual(model.items.map(\.id.unitID), [3]); XCTAssertEqual(model.deletionRecovery?.count(.confirmed), 2)
        let stored = try XCTUnwrap(PhotoDeletionRecoveryStore(url: recordURL(storage)).load())
        XCTAssertTrue(stored.isFinished); XCTAssertEqual(stored.entries.map(\.state), [.confirmed, .confirmed])
        XCTAssertTrue(model.canStartManagementMutation)
    }
    func test未预检或缩小确认快照不删除且取消不写入() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = session.model, photos = Array(model.items.prefix(2))
        model.confirmDeletion(photos[0]); XCTAssertFalse(model.isDeleting)
        try await prepare(photos, model: model); model.confirmDeletion([photos[0]])
        XCTAssertFalse(model.isDeleting); model.deletionCandidates = []
        let deleted = await service.deletedPhotoIDs; XCTAssertTrue(deleted.isEmpty); XCTAssertNil(model.deletionRecovery)
    }
    func test未知删除重启只查询完成后明确继续剩余项() async throws {
        let (root, storage, service, session) = try await fixture("photo-deletion-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = session.model.items; try await prepare(photos, model: session.model); session.model.confirmDeletion(photos)
        try await wait { !session.model.isDeleting }; XCTAssertEqual(session.model.pendingDeletionPhotos.count, 1)
        XCTAssertEqual(session.model.remainingDeletionCount, 2); XCTAssertFalse(session.model.canStartManagementMutation)
        let fresh = MobilePhotosUIService(profileID: service.profileID, state: "photo-deletion-unknown")
        session.configure(fresh, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        XCTAssertEqual(session.model.pendingDeletionPhotos.count, 1); XCTAssertFalse(session.model.canContinueDeletion)
        await session.model.reviewPendingDeletion(); let none = await fresh.deletedPhotoIDs; XCTAssertTrue(none.isEmpty)
        await fresh.setPending(false); await session.model.reviewPendingDeletion()
        XCTAssertNil(session.model.pendingDeletionPhoto); XCTAssertTrue(session.model.canContinueDeletion)
        session.model.requestRemainingDeletion(); try await wait { !session.model.isCheckingDeletion }
        let remaining = session.model.deletionCandidates; XCTAssertEqual(remaining.map(\.id.unitID), [2, 3])
        session.model.confirmDeletion(remaining); try await wait { !session.model.isDeleting }
        let oldWrites = await service.deletedPhotoIDs, newWrites = await fresh.deletedPhotoIDs
        XCTAssertEqual(oldWrites.map(\.unitID), [1]); XCTAssertEqual(newWrites.map(\.unitID), [2, 3])
        XCTAssertEqual(session.model.deletionRecovery?.count(.confirmed), 3); XCTAssertTrue(session.model.items.isEmpty)
    }
    func test取消剩余删除保留已提交项目并继续只读更新() async throws {
        let (root, _, service, session) = try await fixture("photo-deletion-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = session.model.items; try await prepare(photos, model: session.model); session.model.confirmDeletion(photos)
        try await wait { !session.model.isDeleting }; session.model.cancelRemainingDeletion()
        XCTAssertEqual(session.model.remainingDeletionCount, 0); XCTAssertEqual(session.model.pendingDeletionPhotos.count, 1)
        XCTAssertEqual(session.model.deletionRecovery?.count(.cancelled), 2); XCTAssertFalse(session.model.canStartManagementMutation)
        await service.setPending(false); await session.model.reviewPendingDeletion()
        XCTAssertEqual(session.model.deletionRecovery?.count(.confirmed), 1); XCTAssertTrue(session.model.canStartManagementMutation)
        XCTAssertEqual(session.model.items.map(\.id.unitID), [2, 3]); let writes = await service.deletedPhotoIDs; XCTAssertEqual(writes.map(\.unitID), [1])
    }
    func test部分完成保留明确拒绝并只继续尚未提交项目() async throws {
        let (root, _, service, session) = try await fixture("photo-deletion-partial"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = session.model.items; try await prepare(photos, model: session.model); session.model.confirmDeletion(photos)
        try await wait { !session.model.isDeleting }
        XCTAssertEqual(session.model.deletionRecovery?.entries.map(\.state), [.confirmed, .rejected, .prepared]); XCTAssertNotNil(session.model.deletionError)
        session.model.deletionError = nil; session.model.requestRemainingDeletion(); try await wait { !session.model.isCheckingDeletion }
        XCTAssertEqual(session.model.deletionCandidates.map(\.id.unitID), [3]); session.model.confirmDeletion(session.model.deletionCandidates)
        try await wait { !session.model.isDeleting }
        XCTAssertEqual(session.model.deletionRecovery?.entries.map(\.state), [.confirmed, .rejected, .confirmed])
        let writes = await service.deletedPhotoIDs; XCTAssertEqual(writes.map(\.unitID), [1, 2, 3]); XCTAssertEqual(session.model.items.map(\.id.unitID), [2])
    }
    func test删除恢复文件不可保存时零提交且浏览保留() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = recordURL(storage), parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-a-directory".utf8).write(to: parent)
        let photos = session.model.items; try await prepare(photos, model: session.model); session.model.confirmDeletion(photos)
        try await wait { !session.model.isDeleting }
        let writes = await service.deletedPhotoIDs; XCTAssertTrue(writes.isEmpty); XCTAssertNotNil(session.model.deletionRecoveryError)
        XCTAssertEqual(session.model.items.count, 3); XCTAssertFalse(session.model.canStartManagementMutation)
    }
    func test恢复记录损坏或属于其他账号时只保留浏览() async throws {
        for corrupted in [false, true] {
            let (root, storage, service, session) = try await fixture("photo-deletion-unknown"); defer { try? FileManager.default.removeItem(at: root) }
            let photos = session.model.items; try await prepare(photos, model: session.model); session.model.confirmDeletion(photos)
            try await wait { !session.model.isDeleting }
            if corrupted { try Data("broken".utf8).write(to: recordURL(storage)) } else { await service.setUser(13) }
            session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
            XCTAssertNotNil(session.model.deletionRecoveryError); XCTAssertFalse(session.model.canDeletePhotos(session.model.items))
            XCTAssertFalse(session.model.canStartManagementMutation); XCTAssertFalse(session.model.items.isEmpty)
            session.model.requestDeletion(session.model.items); XCTAssertTrue(session.model.deletionCandidates.isEmpty)
            let writes = await service.deletedPhotoIDs; XCTAssertEqual(writes.count, 1)
        }
    }
    func test剩余原件被替换时不能确认或再次删除() async throws {
        let (root, _, service, session) = try await fixture("photo-deletion-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = session.model.items; try await prepare(photos, model: session.model); session.model.confirmDeletion(photos)
        try await wait { !session.model.isDeleting }; await service.setPending(false); await session.model.reviewPendingDeletion()
        let original = photos[1]
        let replacement = SynologyPhoto(id: original.id, filename: "Changed.jpg", sizeBytes: original.sizeBytes, takenAt: original.takenAt,
            indexedAt: original.indexedAt, folderID: original.folderID, mediaType: original.mediaType)
        await service.seedPhotos([replacement, photos[2]]); session.model.requestRemainingDeletion(); try await wait { !session.model.isCheckingDeletion }
        XCTAssertTrue(session.model.deletionCandidates.isEmpty); XCTAssertNotNil(session.model.deletionError)
        let writes = await service.deletedPhotoIDs; XCTAssertEqual(writes.map(\.unitID), [1])
    }
    func test删除提交后切换会话的迟到回执不覆盖恢复文件或新页面() async throws {
        let (root, storage, service, session) = try await fixture("photo-deletion-held"); defer { try? FileManager.default.removeItem(at: root) }
        let original = session.model, photos = original.items; try await prepare(photos, model: original); original.confirmDeletion(photos)
        for _ in 0..<100 { if await service.isDeletionHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        let held = await service.isDeletionHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-deletion")); await session.activate(); await service.releaseDeletion()
        try await wait { !original.isDeleting }
        XCTAssertFalse(original.isModuleEnabled); XCTAssertNil(session.model.deletionMessage); XCTAssertEqual(session.model.items.count, 3)
        let saved = try XCTUnwrap(PhotoDeletionRecoveryStore(url: recordURL(storage)).load())
        XCTAssertEqual(saved.entries.map(\.state), [.submitted, .prepared, .prepared])
        let writes = await service.deletedPhotoIDs; XCTAssertEqual(writes.map(\.unitID), [1])
    }
    func test删除预检迟到后不弹出旧账号确认() async throws {
        let (root, _, service, session) = try await fixture("photo-deletion-prepare-held"); defer { try? FileManager.default.removeItem(at: root) }
        let old = session.model; old.requestDeletion(old.items)
        for _ in 0..<100 { if await service.isDeletionHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        let held = await service.isDeletionHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-deletion")); await session.activate(); await service.releaseDeletion()
        try await wait { !old.isCheckingDeletion }; XCTAssertTrue(old.deletionCandidates.isEmpty); XCTAssertTrue(session.model.deletionCandidates.isEmpty)
        let writes = await service.deletedPhotoIDs; XCTAssertTrue(writes.isEmpty)
    }
    func test共享批量删除不改变同编号个人照片() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await session.model.refresh(space: .shared)
        let photos = Array(session.model.items.prefix(2)); XCTAssertTrue(photos.allSatisfy { $0.id.space == .shared })
        try await prepare(photos, model: session.model); session.model.confirmDeletion(photos); try await wait { !session.model.isDeleting }
        await session.model.refresh(space: .personal); XCTAssertEqual(session.model.items.map(\.id.unitID), [1, 2, 3])
        let writes = await service.deletedPhotoIDs; XCTAssertEqual(Set(writes.map(\.space)), [.shared])
    }
    func test确认后撤销权限不提交并可取消剩余任务() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let photos = session.model.items; try await prepare(photos, model: session.model); await service.denyWrites()
        session.model.confirmDeletion(photos); try await wait { !session.model.isDeleting }
        XCTAssertNotNil(session.model.deletionError); XCTAssertEqual(session.model.remainingDeletionCount, 3)
        let writes = await service.deletedPhotoIDs; XCTAssertTrue(writes.isEmpty)
        session.model.cancelRemainingDeletion(); XCTAssertEqual(session.model.deletionRecovery?.count(.cancelled), 3)
    }
    func test删除记录只保留摘要且阻止回退提交阶段和覆盖未结束批次() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let identity = try await service.uploadRecoveryIdentity(), photos = session.model.items
        let batch = try PhotoDeletionRecovery(photos: photos, identity: identity), store = PhotoDeletionRecoveryStore(url: recordURL(storage))
        try store.save(batch)
        let text = try String(contentsOf: store.url, encoding: .utf8); XCTAssertFalse(text.contains("Sample")); XCTAssertFalse(text.contains("jpg"))
        XCTAssertThrowsError(try store.save(PhotoDeletionRecovery(photos: [photos[0]], identity: identity)))
        var entry = batch.entries[0]; entry.state = .submitted; try store.update(entry, batchID: batch.id)
        XCTAssertThrowsError(try store.update(batch.entries[0], batchID: batch.id))
        entry.state = .confirmed; try store.update(entry, batchID: batch.id); entry.state = .cancelled
        XCTAssertThrowsError(try store.update(entry, batchID: batch.id))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let flags = try store.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]); XCTAssertEqual(flags.isExcludedFromBackup, true)
        store.suspendWrites(); var remaining = batch.entries[1]; remaining.state = .cancelled
        XCTAssertThrowsError(try store.update(remaining, batchID: batch.id))
    }
    func test真机删除恢复文件使用完整保护级别() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = try PhotoDeletionRecovery(photos: session.model.items, identity: await service.uploadRecoveryIdentity())
        let store = PhotoDeletionRecoveryStore(url: recordURL(storage)); try store.save(batch)
        #if targetEnvironment(simulator)
        // 用独立系统写入确认环境限制，不能把生产记录的缺失属性直接当作通过。
        let reference = root.appendingPathComponent("protection-reference")
        try Data([0]).write(to: reference, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: reference.path)
        let referenceAttributes = try FileManager.default.attributesOfItem(atPath: reference.path)
        if referenceAttributes[.protectionKey] == nil {
            throw XCTSkip("PENDING_USER_VALIDATION：当前模拟器直接系统写入也不返回文件保护级别。此断言保留给 iPhone/iPad 真机；锁屏前后读写与重启恢复步骤见移动主计划 M3h1，不能计作通过。")
        }
        #endif
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
    }
    func test未结束删除阻止直接加入上传队列或提交其他照片管理() async throws {
        let (root, _, service, session) = try await fixture("photo-deletion-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let model = session.model, photos = model.items
        try await prepare(photos, model: model); model.confirmDeletion(photos); try await wait { !model.isDeleting }
        let source = root.appendingPathComponent("synthetic.jpg"); try Data([1, 2]).write(to: source)
        let file = PhotoUploadFile(url: source, size: 2, modifiedAt: Date())
        model.enqueueUploads([file], album: nil, folder: nil)
        XCTAssertTrue(model.uploadQueue.isEmpty); XCTAssertFalse(model.canResumeUploads)
        model.submitMutation(.createAlbum(name: "Synthetic", photos: [])); XCTAssertFalse(model.isManaging)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }
    func test删除队列拒绝重复对象和跨账号身份() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let identity = try await service.uploadRecoveryIdentity(), photo = try XCTUnwrap(session.model.items.first)
        XCTAssertThrowsError(try PhotoDeletionRecovery(photos: [photo, photo], identity: identity))
        XCTAssertThrowsError(try PhotoDeletionRecovery(photos: [photo], identity: "\(UUID().uuidString):12"))
        XCTAssertThrowsError(try PhotoDeletionRecovery(photos: [], identity: identity))
    }
}
