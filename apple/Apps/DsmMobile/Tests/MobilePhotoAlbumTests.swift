@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoAlbumTests: XCTestCase {
    private func fixture(_ state: String = "photo-albums") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-albums-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state)
        let session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in })
        await session.activate()
        return (root, storage, service, session)
    }
    private func store(_ storage: MobilePhotoUploadStorage) -> PhotoAlbumRecoveryStore {
        .init(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待操作结束超时")
    }

    func test多选创建相册后改名封面移除和删除均保留原件() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = session.model, form = try XCTUnwrap(session.albums)
        model.selectGroup(model.items)
        XCTAssertEqual(model.selectedPhotos.count, 2)
        form.begin(.create); form.name = "Selected album "
        XCTAssertTrue(form.submit()); XCTAssertFalse(form.submit())
        try await wait { !model.isManaging }
        XCTAssertNil(try store(storage).load())
        await model.selectSection(.albums)
        let created = try XCTUnwrap(model.collections.first { $0.name == "Selected album " })
        await model.open(created)
        XCTAssertEqual(model.items.count, 2)
        form.begin(.rename, photos: []); form.name = "Updated album"; XCTAssertTrue(form.submit())
        try await wait { !model.isManaging }
        XCTAssertEqual(model.selectedAlbum?.name, "Updated album")
        model.toggleSelection(try XCTUnwrap(model.items.first))
        form.begin(.cover); XCTAssertTrue(form.submit()); try await wait { !model.isManaging }
        form.begin(.remove); XCTAssertTrue(form.submit()); try await wait { !model.isManaging }
        XCTAssertEqual(model.items.count, 1)
        form.begin(.delete, photos: []); XCTAssertTrue(form.submit()); try await wait { !model.isManaging }
        XCTAssertNil(model.selectedAlbum)
        await model.selectSection(.timeline)
        XCTAssertEqual(model.items.count, 2)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 5)
        XCTAssertFalse(commands.contains { if case .deleteFolderItems = $0 { return true }; return false })
    }

    func test加入相册完整保留冻结选择而不跟随后续勾选变化() async throws {
        let (root, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = session.model, form = try XCTUnwrap(session.albums)
        let original = try XCTUnwrap(model.items.first)
        model.toggleSelection(original); form.begin(.add)
        try await wait { !form.isLoading }
        form.albumID = 21
        model.selectGroup(model.items)
        XCTAssertTrue(form.submit()); try await wait { !model.isManaging }
        let commands = await service.commands
        guard case .addToAlbum(let id, let photos) = try XCTUnwrap(commands.first) else { return XCTFail("必须加入相册") }
        XCTAssertEqual(id, 21); XCTAssertEqual(photos, [original])
    }

    func test旧表单在空间切换或账号更换后不能提交() async throws {
        let (root, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try XCTUnwrap(session.albums)
        session.model.selectGroup(session.model.items); form.begin(.create); form.name = "Original selection"
        await session.model.selectSpace(.shared)
        XCTAssertNil(form.mutation); XCTAssertFalse(form.submit())
        session.configure(MobilePhotosUIService())
        XCTAssertFalse(form.submit()); XCTAssertNil(form.draft)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test相册未知重启只刷新回执且不重复创建() async throws {
        let (root, storage, service, session) = try await fixture("photo-albums-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try XCTUnwrap(session.albums)
        form.begin(.create, photos: []); form.name = "Pending album"; XCTAssertTrue(form.submit())
        try await wait { !session.model.isManaging }
        let id = try XCTUnwrap(session.model.pendingMutationID)
        let saved = try XCTUnwrap(store(storage).load()); XCTAssertNotNil(saved.createdAlbumID)
        session.deactivate()
        let second = MobilePhotosUIService(profileID: service.profileID, state: "photo-albums")
        let restored = MobileSynologyPhotosSession()
        restored.configure(second, uploadStorage: storage, reviewDelay: { _ in }); await restored.activate()
        XCTAssertEqual(restored.model.pendingMutationID, id)
        XCTAssertFalse(try XCTUnwrap(restored.albums).allows(.create, photos: []))
        restored.model.reviewPendingMutation(); try await wait { !restored.model.isManaging }
        XCTAssertNil(restored.model.pendingMutationID); XCTAssertNil(try store(storage).load())
        let oldWrites = await service.commands, newWrites = await second.commands
        XCTAssertEqual(oldWrites.count, 1); XCTAssertTrue(newWrites.isEmpty)
    }

    func test相册记录损坏或属于其他账号时保留记录并阻止写入() async throws {
        for corrupt in [false, true] {
            let (root, storage, service, session) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            session.deactivate()
            let recovery = store(storage)
            let wrong = try SynologyPhotosAlbumCheckpoint(mutation: .deleteAlbum(id: 21), operationID: UUID(), profileID: service.profileID, userID: 99)
            try recovery.save(wrong)
            if corrupt { try Data("invalid".utf8).write(to: recovery.url) }
            let before = try Data(contentsOf: recovery.url)
            let restored = MobileSynologyPhotosSession()
            restored.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await restored.activate()
            XCTAssertNotNil(restored.model.albumRecoveryError)
            XCTAssertFalse(try XCTUnwrap(restored.albums).allows(.create, photos: []))
            XCTAssertFalse(try XCTUnwrap(restored.uploads).canBegin)
            XCTAssertEqual(try Data(contentsOf: recovery.url), before)
            let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        }
    }

    func test写前保存失败不创建相册而暂停的旧写入者不能清空新记录() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = store(storage), folder = recovery.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: folder)
        let form = try XCTUnwrap(session.albums)
        form.begin(.create, photos: []); form.name = "No write"; XCTAssertTrue(form.submit())
        try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        try FileManager.default.removeItem(at: folder)
        let checkpoint = try SynologyPhotosAlbumCheckpoint(mutation: .deleteAlbum(id: 21), operationID: UUID(), profileID: service.profileID, userID: 12)
        try recovery.save(checkpoint); recovery.suspendWrites()
        XCTAssertThrowsError(try recovery.clear(operationID: checkpoint.operationID))
        XCTAssertEqual(try store(storage).load()?.operationID, checkpoint.operationID)
    }

    func test只读与贡献者不能改名删除或设置封面() async throws {
        for state in ["photo-albums-readonly", "photo-albums-contributor"] {
            let (root, _, _, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            await session.model.selectSection(.albums)
            await session.model.open(try XCTUnwrap(session.model.collections.first))
            session.model.toggleSelection(try XCTUnwrap(session.model.items.first))
            let form = try XCTUnwrap(session.albums)
            XCTAssertFalse(form.allows(.rename)); XCTAssertFalse(form.allows(.delete)); XCTAssertFalse(form.allows(.cover))
            if state == "photo-albums-readonly" { XCTAssertFalse(form.allows(.remove)); XCTAssertFalse(form.allows(.add)) }
        }
    }

    func test相册候选空内容错误和取消加载不混入新草稿() async throws {
        for state in ["photo-albums-empty", "photo-albums-error", "photo-albums-loading"] {
            let (root, _, _, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let form = try XCTUnwrap(session.albums)
            session.model.selectGroup(session.model.items); form.begin(.add)
            if state == "photo-albums-loading" {
                XCTAssertTrue(form.isLoading); form.cancel(); form.begin(.create, photos: []); form.name = "New draft"
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(form.draft?.action, .create); XCTAssertNotNil(form.mutation)
            } else {
                try await wait { !form.isLoading }
                XCTAssertTrue(form.albums.isEmpty); XCTAssertNil(form.mutation)
                XCTAssertEqual(form.error != nil, state == "photo-albums-error")
            }
        }
    }

    func test相册成员部分失败仅继续尚未完成的照片() async throws {
        let (root, storage, service, session) = try await fixture("photo-albums-partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = session.model, form = try XCTUnwrap(session.albums)
        await model.selectSection(.albums); await model.open(try XCTUnwrap(model.collections.first))
        model.selectGroup(model.items); form.begin(.remove); XCTAssertTrue(form.submit())
        try await wait { !model.isManaging }
        XCTAssertEqual(model.items.count, 1); XCTAssertNotNil(model.retryableManagementMutation)
        XCTAssertNil(try store(storage).load())
        model.continuePartialManagement(); try await wait { !model.isManaging }
        XCTAssertTrue(model.items.isEmpty); XCTAssertNil(model.retryableManagementMutation)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.first?.photos.map(\.id.unitID), [1, 2])
        XCTAssertEqual(commands.last?.photos.map(\.id.unitID), [2])
    }

    func test关闭个人图库仍可创建空普通相册() async throws {
        let (root, _, service, session) = try await fixture("photo-albums-nohome")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(session.model.spaces, [.shared])
        let form = try XCTUnwrap(session.albums)
        form.begin(.create, photos: []); form.name = "Shared account album"; XCTAssertTrue(form.submit())
        try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test仅有相册权限仍可浏览并创建相册() async throws {
        let (root, _, service, session) = try await fixture("photo-albums-only")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(session.model.spaces.isEmpty)
        await session.model.selectSection(.albums)
        XCTAssertNil(session.model.errorMessage)
        XCTAssertEqual(session.model.collections.map(\.id), [21])
        let form = try XCTUnwrap(session.albums)
        form.begin(.create, photos: []); form.name = "Album only"; XCTAssertTrue(form.submit())
        try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }
}
