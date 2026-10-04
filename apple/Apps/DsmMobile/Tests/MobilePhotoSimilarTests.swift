@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoSimilarTests: XCTestCase {
    private func fixture(_ state: String = "photo-similar") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-similar-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        await session.model.selectSection(.albums); await session.model.openCategory(.similar)
        return (root, storage, service, session)
    }
    private func idle(_ model: SynologyPhotosModel) async throws {
        for _ in 0..<400 {
            if !model.isPreparingSimilarBatch && !model.isManaging && !model.isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待相似分组操作结束超时")
    }
    private func groups(_ session: MobileSynologyPhotosSession) async throws -> [SynologyPhotoSimilarDetail] {
        session.model.selectLoadedItems()
        let details = await session.model.prepareSelectedSimilarGroups()
        return try XCTUnwrap(details)
    }
    private func recordURL(_ storage: MobilePhotoUploadStorage) -> URL {
        storage.recordURL.deletingPathExtension().appendingPathComponent("Similar/batch-v1.json")
    }

    func test代表照片更新完整分组而不删除任何原件() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let details = try await groups(session), detail = try XCTUnwrap(details.first)
        session.model.submitMutation(.editSimilarGroup(detail, .topPick(2)))
        session.model.submitMutation(.editSimilarGroup(detail, .topPick(3)))
        try await idle(session.model)
        XCTAssertEqual(session.model.items.map(\.id.unitID), [2, 4, 7])
        XCTAssertEqual(session.model.similarRecovery?.count(.confirmed), 1)
        XCTAssertFalse(session.model.canUndoSimilarChanges)
        let commands = await service.commands, photos = await service.allPhotos(), deleted = await service.deletedPhotoIDs
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(photos.count, 18); XCTAssertTrue(deleted.isEmpty)
    }

    func test移出分组重启后可撤销且恢复原代表照片() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let details = try await groups(session), detail = try XCTUnwrap(details.first)
        session.model.submitMutation(.editSimilarGroup(detail, .remove([1])))
        try await idle(session.model)
        XCTAssertEqual(session.model.items.first?.id.unitID, 2); XCTAssertTrue(session.model.canUndoSimilarChanges)
        let fresh = MobilePhotosUIService(profileID: service.profileID, state: "photo-similar")
        let serverPhotos = await service.allPhotos(); await fresh.seedPhotos(serverPhotos)
        session.configure(fresh, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        await session.model.selectSection(.albums); await session.model.openCategory(.similar)
        XCTAssertTrue(session.model.canUndoSimilarChanges); session.model.undoSimilarChanges(); try await idle(session.model)
        XCTAssertEqual(session.model.items.map(\.id.unitID), [1, 4, 7]); XCTAssertFalse(session.model.canUndoSimilarChanges)
        let commands = await fresh.commands; XCTAssertEqual(commands.count, 1)
        guard case .editSimilarGroup(_, .undo) = commands.first else { return XCTFail("只能发送撤销，不能重发原移出操作") }
    }

    func test批量拆组三项后可以撤销全部且原件保留() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let details = try await groups(session); XCTAssertEqual(details.count, 3)
        session.model.ungroupSimilarSelection(details); try await idle(session.model)
        XCTAssertTrue(session.model.items.isEmpty); XCTAssertEqual(session.model.similarRecovery?.undoReceipts.count, 3)
        session.model.undoSimilarChanges(); try await idle(session.model)
        XCTAssertEqual(session.model.items.map(\.id.unitID), [1, 4, 7]); XCTAssertEqual(session.model.similarRecovery?.count(.confirmed), 3)
        let photos = await service.allPhotos(), commands = await service.commands
        XCTAssertEqual(photos.count, 18); XCTAssertEqual(commands.count, 6)
    }

    func test未知批次重启只读恢复并仅继续尚未提交的分组() async throws {
        let (root, storage, service, session) = try await fixture("photo-similar-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let details = try await groups(session); session.model.ungroupSimilarSelection(details); try await idle(session.model)
        XCTAssertEqual(session.model.similarRecovery?.entries.map(\.state), [.submitted, .prepared, .prepared])
        XCTAssertFalse(session.model.canStartManagementMutation); XCTAssertFalse(session.model.canDeletePhotos(details[1].photos))
        let fresh = MobilePhotosUIService(profileID: service.profileID, state: "photo-similar-unknown")
        let serverPhotos = await service.allPhotos(); await fresh.seedPhotos(serverPhotos)
        session.configure(fresh, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        session.model.reviewPendingMutation(); try await idle(session.model)
        let none = await fresh.commands; XCTAssertTrue(none.isEmpty); XCTAssertNotNil(session.model.pendingMutationID)
        await fresh.setPending(false); session.model.reviewPendingMutation(); try await idle(session.model)
        XCTAssertNil(session.model.pendingMutationID); XCTAssertEqual(session.model.remainingSimilarCount, 2)
        let stillNone = await fresh.commands; XCTAssertTrue(stillNone.isEmpty)
        session.model.continueSimilarBatch(); try await idle(session.model)
        let commands = await fresh.commands; XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.compactMap { if case .editSimilarGroup(let value, _) = $0 { return value.group.id }; return nil }, [32, 33])
        XCTAssertEqual(session.model.similarRecovery?.count(.confirmed), 3)
    }

    func test取消剩余分组不撤销已提交操作也不移除恢复依据() async throws {
        let (root, _, service, session) = try await fixture("photo-similar-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        session.model.ungroupSimilarSelection(try await groups(session)); try await idle(session.model)
        session.model.cancelRemainingSimilarGroups(); XCTAssertEqual(session.model.remainingSimilarCount, 0)
        XCTAssertEqual(session.model.similarRecovery?.entries.map(\.state), [.submitted, .cancelled, .cancelled])
        XCTAssertNotNil(session.model.pendingMutationID); await service.setPending(false)
        session.model.reviewPendingMutation(); try await idle(session.model)
        XCTAssertTrue(session.model.canUndoSimilarChanges); XCTAssertEqual(session.model.items.count, 2)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test部分拆组只继续最后未提交项目() async throws {
        let (root, _, service, session) = try await fixture("photo-similar-partial"); defer { try? FileManager.default.removeItem(at: root) }
        session.model.ungroupSimilarSelection(try await groups(session)); try await idle(session.model)
        XCTAssertEqual(session.model.similarRecovery?.entries.map(\.state), [.confirmed, .rejected, .prepared])
        session.model.continueSimilarBatch(); try await idle(session.model)
        XCTAssertEqual(session.model.similarRecovery?.entries.map(\.state), [.confirmed, .rejected, .confirmed])
        XCTAssertEqual(session.model.items.map(\.id.unitID), [4]); let commands = await service.commands; XCTAssertEqual(commands.count, 3)
    }

    func test剩余原件变化后不能继续但可取消其余操作() async throws {
        let (root, _, service, session) = try await fixture("photo-similar-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        session.model.ungroupSimilarSelection(try await groups(session)); try await idle(session.model)
        await service.setPending(false); session.model.reviewPendingMutation(); try await idle(session.model)
        let photos = await service.allPhotos(); await service.seedPhotos(photos.filter { !($0.id.space == .personal && $0.id.unitID == 4) })
        session.model.continueSimilarBatch(); try await idle(session.model)
        XCTAssertEqual(session.model.remainingSimilarCount, 2); XCTAssertNotNil(session.model.managementMessage)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        session.model.cancelRemainingSimilarGroups(); XCTAssertEqual(session.model.similarRecovery?.count(.cancelled), 2)
    }

    func test相似恢复文件无法保存时零写入() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = recordURL(storage).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: target)
        session.model.ungroupSimilarSelection(try await groups(session)); try await idle(session.model)
        XCTAssertNotNil(session.model.similarRecoveryError); XCTAssertFalse(session.model.canStartManagementMutation)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test相似恢复记录损坏或跨账号时阻止写入但保留浏览() async throws {
        for corrupt in [false, true] {
            let (root, storage, service, session) = try await fixture("photo-similar-unknown"); defer { try? FileManager.default.removeItem(at: root) }
            session.model.ungroupSimilarSelection(try await groups(session)); try await idle(session.model)
            if corrupt { try Data("broken".utf8).write(to: recordURL(storage)) } else { await service.setUser(13) }
            session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
            XCTAssertNotNil(session.model.similarRecoveryError); XCTAssertFalse(session.model.canStartManagementMutation); XCTAssertFalse(session.model.items.isEmpty)
            let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        }
    }

    func test相似提交后切换账号不污染新页面或旧恢复文件() async throws {
        let (root, storage, service, session) = try await fixture("photo-similar-held"); defer { try? FileManager.default.removeItem(at: root) }
        let old = session.model; old.ungroupSimilarSelection(try await groups(session))
        for _ in 0..<100 { if await service.isSimilarHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        let held = await service.isSimilarHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-similar")); await session.activate(); await service.releaseSimilar()
        try await idle(old); XCTAssertFalse(old.isModuleEnabled); XCTAssertNil(session.model.similarRecovery)
        let saved = try XCTUnwrap(PhotoSimilarRecoveryStore(url: recordURL(storage)).load())
        XCTAssertEqual(saved.entries.map(\.state), [.submitted, .prepared, .prepared])
    }

    func test离页期间收到明确拒绝返回后释放旧操作并保留剩余分组() async throws {
        let (root, storage, service, session) = try await fixture("photo-similar-held-rejected"); defer { try? FileManager.default.removeItem(at: root) }
        session.model.ungroupSimilarSelection(try await groups(session))
        for _ in 0..<100 { if await service.isSimilarHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        let held = await service.isSimilarHeld; XCTAssertTrue(held)
        session.deactivate(); await service.releaseSimilar()
        let store = PhotoSimilarRecoveryStore(url: recordURL(storage))
        for _ in 0..<100 { if try store.load()?.entries.first?.state == .rejected { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(try store.load()?.entries.first?.state, .rejected)
        await session.activate()
        XCTAssertNil(session.model.pendingMutationID); XCTAssertEqual(session.model.remainingSimilarCount, 2)
        XCTAssertTrue(session.model.hasSimilarBatchToContinue)
        session.model.cancelRemainingSimilarGroups(); XCTAssertTrue(session.model.canStartManagementMutation)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test共享相似拆组不影响个人同编号分组() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await session.model.refresh(space: .shared); await session.model.openCategory(.similar)
        session.model.ungroupSimilarSelection(try await groups(session)); try await idle(session.model)
        let all = await service.allPhotos()
        XCTAssertTrue(all.filter { $0.id.space == .shared }.allSatisfy { $0.similarGroup == nil })
        XCTAssertTrue(all.filter { $0.id.space == .personal }.allSatisfy { $0.similarGroup != nil })
    }

    func test相似清理保留所选原件并刷新剩余组而不提供删除撤销() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let details = try await groups(session), detail = try XCTUnwrap(details.first)
        session.model.showPreview(detail.photos[0], similarDetail: detail)
        session.model.requestSimilarCleanup(detail, keeping: [detail.photos[0].id], closePreviewBeforeConfirmation: false)
        for _ in 0..<100 { if !session.model.isCheckingDeletion { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.model.deletionCandidates.map(\.id.unitID), [2, 3]); XCTAssertEqual(session.model.deletionKeptCount, 1)
        XCTAssertEqual(session.model.previewPhoto?.id, detail.photos[0].id)
        session.model.confirmDeletion(session.model.deletionCandidates)
        for _ in 0..<100 { if !session.model.isDeleting { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.model.items.map(\.id.unitID), [4, 7]); XCTAssertFalse(session.model.canUndoSimilarChanges)
        let deleted = await service.deletedPhotoIDs, all = await service.allPhotos()
        XCTAssertEqual(deleted.map(\.unitID), [2, 3]); XCTAssertTrue(all.contains { $0.id.space == .personal && $0.id.unitID == 1 })
    }

    func test相似完成记录不保存名称且保留受保护私有权限() async throws {
        let (root, storage, _, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        session.model.ungroupSimilarSelection(try await groups(session)); try await idle(session.model)
        let url = recordURL(storage), data = try Data(contentsOf: url), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Sample")); XCTAssertFalse(text.contains(".jpg"))
        let stored = try XCTUnwrap(PhotoSimilarRecoveryStore(url: url).load()); XCTAssertEqual(stored.undoReceipts.count, 3)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func test相似原件删除重启后刷新分组并只继续剩余原件() async throws {
        let (root, storage, service, session) = try await fixture("photo-similar-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let details = try await groups(session), detail = try XCTUnwrap(details.first)
        session.model.requestSimilarCleanup(detail, keeping: [detail.photos[0].id])
        for _ in 0..<100 { if !session.model.isCheckingDeletion { break }; try await Task.sleep(for: .milliseconds(5)) }
        session.model.confirmDeletion(session.model.deletionCandidates)
        for _ in 0..<100 { if !session.model.isDeleting { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(session.model.pendingDeletionPhoto)
        let fresh = MobilePhotosUIService(profileID: service.profileID, state: "photo-similar-unknown")
        session.configure(fresh, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        await session.model.selectSection(.albums); await session.model.openCategory(.similar)
        await fresh.setPending(false); await session.model.reviewPendingDeletion()
        XCTAssertEqual(session.model.items.first?.similarGroup?.photoIDs, [1, 3]); XCTAssertEqual(session.model.remainingDeletionCount, 1)
        session.model.requestRemainingDeletion()
        for _ in 0..<100 { if !session.model.isCheckingDeletion { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.model.deletionCandidates.map(\.id.unitID), [3]); session.model.confirmDeletion(session.model.deletionCandidates)
        for _ in 0..<100 { if !session.model.isDeleting { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.model.items.map(\.id.unitID), [4, 7])
        let writes = await fresh.deletedPhotoIDs; XCTAssertEqual(writes.map(\.unitID), [3])
    }
}
