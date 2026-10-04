@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoTemporarySharingTests: XCTestCase {
    private func fixture(_ state: String = "photo-temporary") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-temporary-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        session.model.isSelecting = true; session.model.selectGroup(session.model.items)
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("临时分享流程未结束")
    }
    private func temporaryURL(_ storage: MobilePhotoUploadStorage) -> URL {
        storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/temporary-v1.json")
    }
    private func prepare(_ session: MobileSynologyPhotosSession) async throws -> MobilePhotoTemporarySharingModel {
        let temporary = try XCTUnwrap(session.temporarySharing)
        temporary.begin(); XCTAssertNotNil(temporary.draft); temporary.name = "Selection"
        temporary.create(); try await wait { !session.model.isManaging }; temporary.creationChanged()
        return temporary
    }
    private func openExisting(_ session: MobileSynologyPhotosSession) async throws -> MobilePhotoSharingModel {
        await session.model.selectSection(.albums); await session.model.open(try XCTUnwrap(session.model.collections.first))
        let sharing = try XCTUnwrap(session.sharing); sharing.begin(); try await wait { !sharing.isLoading && !sharing.loadingRecipients }
        return sharing
    }

    func test选片创建后配置分享且成功清除准备记录不重复创建() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = try await prepare(session), sharing = temporary.sharing
        try await wait { !sharing.isLoading }
        XCTAssertEqual(sharing.original?.isTemporary, true); XCTAssertTrue(sharing.draft?.prepared == true)
        XCTAssertEqual(session.model.preparedTemporaryAlbum?.id, 101)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL(storage).path))
        XCTAssertFalse(temporary.canCreate); temporary.create()
        sharing.access = .download; XCTAssertFalse(sharing.requestSave()); XCTAssertTrue(sharing.confirmSave())
        try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.preparedTemporaryAlbum); XCTAssertNotNil(session.model.managementLink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL(storage).path))
        let commands = await service.commands; XCTAssertEqual(commands.count, 2)
        guard case .createTemporaryAlbum(_, let photos) = commands[0], case .shareAlbum(101, .download, _, _, _, _) = commands[1] else { return XCTFail("只应创建及配置原选片分享") }
        XCTAssertEqual(photos.count, 2)
    }

    func test准备完成取消会停止并移除临时相册但原照片保留() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = try await prepare(session); try await wait { !temporary.sharing.isLoading }
        XCTAssertTrue(temporary.sharing.cancelEditing())
        try await wait { !session.model.isManaging && !session.model.hasTemporarySharingCleanup }
        let commands = await service.commands
        XCTAssertEqual(commands.count, 3)
        guard case .shareAlbum(101, .disabled, _, _, _, _) = commands[1], case .deleteTemporaryAlbum(101, _, nil) = commands[2] else { return XCTFail("必须先关闭再清理相册") }
        let photos = try await service.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        XCTAssertEqual(photos.items.count, 2); XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL(storage).path))
    }

    func test创建结果未知取消跨重启只查询后再由用户继续清理() async throws {
        let (root, storage, service, session) = try await fixture("photo-temporary-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = try await prepare(session)
        let id = try XCTUnwrap(session.model.pendingMutationID); temporary.cancel()
        session.deactivate()
        let nextService = MobilePhotosUIService(profileID: service.profileID, state: "photo-temporary"), next = MobileSynologyPhotosSession()
        next.configure(nextService, uploadStorage: storage, reviewDelay: { _ in }); await next.activate()
        XCTAssertEqual(next.model.pendingMutationID, id)
        var commands = await nextService.commands; XCTAssertTrue(commands.isEmpty)
        next.model.reviewPendingMutation(); try await wait { !next.model.isManaging }
        // 创建取消已由此前用户明确要求，当前查询完成后允许同会话继续清理。
        try await wait { !next.model.isManaging && !next.model.hasTemporarySharingCleanup }
        commands = await nextService.commands
        XCTAssertFalse(commands.contains { if case .createTemporaryAlbum = $0 { return true }; return false })
        XCTAssertEqual(commands.count, 2); XCTAssertNil(next.model.preparedTemporaryAlbum)
        let photos = try await nextService.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        XCTAssertEqual(photos.items.count, 2)
    }

    func test停止保留普通副本先确认复制再关闭再删除且防重复() async throws {
        let (root, storage, service, session) = try await fixture("photo-temporary-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await openExisting(session)
        sharing.access = .disabled; XCTAssertFalse(sharing.requestSave()); XCTAssertTrue(sharing.showsTemporaryStop)
        var commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(sharing.stopTemporary(keepCopy: true)); XCTAssertFalse(sharing.stopTemporary(keepCopy: true))
        try await wait { !session.model.isManaging && !session.model.hasTemporarySharingCleanup }
        commands = await service.commands; XCTAssertEqual(commands.count, 3)
        guard case .copyTemporaryAlbum(21, _, _) = commands[0], case .shareAlbum(21, .disabled, _, _, _, _) = commands[1],
              case .deleteTemporaryAlbum(21, _, 101) = commands[2] else { return XCTFail("副本确认前不得停止或删除") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL(storage).path))
        XCTAssertTrue(session.model.collections.contains { $0.id == 101 }); XCTAssertFalse(session.model.collections.contains { $0.id == 21 })
    }

    func test副本未知重启不重复复制且只继续未提交关闭和删除() async throws {
        let (root, storage, service, session) = try await fixture("photo-temporary-existing-copy-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await openExisting(session)
        XCTAssertTrue(sharing.stopTemporary(keepCopy: true)); try await wait { !session.model.isManaging }
        let id = try XCTUnwrap(session.model.pendingMutationID)
        session.deactivate()
        let nextService = MobilePhotosUIService(profileID: service.profileID, state: "photo-temporary-existing"), next = MobileSynologyPhotosSession()
        next.configure(nextService, uploadStorage: storage, reviewDelay: { _ in }); await next.activate()
        XCTAssertEqual(next.model.pendingMutationID, id); XCTAssertTrue(next.model.temporarySharingCleanupNeedsRetry)
        next.model.retryTemporarySharingCleanup()
        var commands = await nextService.commands; XCTAssertTrue(commands.isEmpty)
        next.model.reviewPendingMutation(); try await wait { !next.model.isManaging }
        commands = await nextService.commands; XCTAssertTrue(commands.isEmpty)
        XCTAssertNil(next.model.pendingMutationID); XCTAssertTrue(next.model.hasTemporarySharingCleanup)
        next.model.retryTemporarySharingCleanup(); try await wait { !next.model.isManaging && !next.model.hasTemporarySharingCleanup }
        commands = await nextService.commands; XCTAssertEqual(commands.count, 2)
        guard case .shareAlbum(21, .disabled, _, _, _, _) = commands[0], case .deleteTemporaryAlbum(21, _, 101) = commands[1] else { return XCTFail("恢复不能重复副本") }
    }

    func test阶段已保存但旧副本回执未清理时恢复不重复推进() async throws {
        let (root, storage, service, session) = try await fixture("photo-temporary-existing-copy-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await openExisting(session)
        XCTAssertTrue(sharing.stopTemporary(keepCopy: true)); try await wait { !session.model.isManaging }; session.deactivate()
        let url = temporaryURL(storage)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        saved["phase"] = "stop"; saved["preservedCopy"] = ["id": 101, "name": "Sample album"]
        try JSONSerialization.data(withJSONObject: saved).write(to: url)
        let nextService = MobilePhotosUIService(profileID: service.profileID, state: "photo-temporary-existing"), next = MobileSynologyPhotosSession()
        next.configure(nextService, uploadStorage: storage, reviewDelay: { _ in }); await next.activate()
        next.model.reviewPendingMutation(); try await wait { !next.model.isManaging }
        next.model.retryTemporarySharingCleanup(); try await wait { !next.model.isManaging && !next.model.hasTemporarySharingCleanup }
        let commands = await nextService.commands
        XCTAssertEqual(commands.count, 2)
        guard case .shareAlbum(21, .disabled, _, _, _, _) = commands.first else { return XCTFail("旧副本回执不能跳过关闭或再复制") }
    }

    func test副本明确失败保留来源且可以保留现有相册() async throws {
        let (root, storage, service, session) = try await fixture("photo-temporary-existing-copy-rejected")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await openExisting(session)
        XCTAssertTrue(sharing.stopTemporary(keepCopy: true)); try await wait { !session.model.isManaging }
        XCTAssertTrue(session.model.temporarySharingCleanupNeedsRetry); XCTAssertNil(session.model.pendingMutationID)
        session.model.keepTemporarySharingAlbums()
        XCTAssertFalse(session.model.hasTemporarySharingCleanup); XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL(storage).path))
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        let current = try await service.albumSharing(id: 21); XCTAssertEqual(current.access, .invited)
    }

    func test准备记录跨账号或损坏时阻止写而不覆盖() async throws {
        for invalidIdentity in [true, false] {
            let (root, storage, service, session) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await prepare(session); session.deactivate()
            let url = temporaryURL(storage)
            if !invalidIdentity { try Data("invalid".utf8).write(to: url) }
            let data = try Data(contentsOf: url)
            let nextService = MobilePhotosUIService(profileID: invalidIdentity ? UUID() : service.profileID, state: "photo-temporary"), next = MobileSynologyPhotosSession()
            next.configure(nextService, uploadStorage: storage, reviewDelay: { _ in }); await next.activate()
            XCTAssertNotNil(next.model.albumRecoveryError); XCTAssertFalse(next.model.canStartTemporarySharing)
            XCTAssertEqual(try Data(contentsOf: url), data)
            let commands = await nextService.commands; XCTAssertTrue(commands.isEmpty)
        }
    }

    func test创建前流程保存失败零请求且没有秘密写入() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: temporaryURL(storage), withIntermediateDirectories: true)
        let temporary = try XCTUnwrap(session.temporarySharing); temporary.begin(); temporary.name = "Selection"; temporary.create()
        XCTAssertFalse(temporary.isCreating); XCTAssertNotNil(temporary.error)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test准备好但未公开的临时相册重启可继续且不再创建() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await prepare(session)
        let album = try XCTUnwrap(session.model.preparedTemporaryAlbum)
        let saved = try String(contentsOf: temporaryURL(storage), encoding: .utf8)
        for secret in ["passphrase", "password", "https://", "cookie"] { XCTAssertFalse(saved.contains(secret)) }
        session.deactivate()
        let nextService = MobilePhotosUIService(profileID: service.profileID, state: "photo-temporary"), next = MobileSynologyPhotosSession()
        await nextService.seedTemporaryAlbum(album)
        next.configure(nextService, uploadStorage: storage, reviewDelay: { _ in }); await next.activate()
        XCTAssertEqual(next.model.preparedTemporaryAlbum?.id, album.id); XCTAssertNil(next.model.pendingMutationID)
        let sharing = try XCTUnwrap(next.sharing); sharing.beginPrepared(); try await wait { !sharing.isLoading }
        XCTAssertEqual(sharing.original?.isTemporary, true)
        XCTAssertTrue(sharing.requestSave()); try await wait { !next.model.isManaging }
        let commands = await nextService.commands; XCTAssertEqual(commands.count, 1)
        guard case .shareAlbum = commands.first else { return XCTFail("恢复准备只应配置既有相册") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL(storage).path))
    }

    func test创建预检拒绝后清除未提交阶段且原照片不变() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = try XCTUnwrap(session.temporarySharing); temporary.begin(); temporary.name = "Selection"
        await service.denyWrites(); temporary.create(); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); XCTAssertTrue(session.model.canStartTemporarySharing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL(storage).path))
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test原选片变化和受限账号不能创建临时分享() async throws {
        for state in ["photo-temporary", "photo-temporary-readonly"] {
            let (root, _, service, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let temporary = try XCTUnwrap(session.temporarySharing); temporary.begin(); temporary.name = "Selection"
            if state.hasSuffix("-readonly") { XCTAssertNil(temporary.draft) }
            else { await session.model.selectSpace(.shared); XCTAssertFalse(temporary.canCreate) }
            temporary.create(); let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        }
    }
}
