@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoFolderTests: XCTestCase {
    private func fixture(_ state: String = "photo-folders", openFolders: Bool = true) async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-folders-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        if openFolders { await session.model.selectSection(.folders) }
        return (root, storage, service, session)
    }
    private func store(_ storage: MobilePhotoUploadStorage) -> PhotoAlbumRecoveryStore {
        .init(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待目录操作结束超时")
    }
    private func transfer(_ session: MobileSynologyPhotosSession, copying: Bool = false) async throws -> MobilePhotoFolderModel {
        let folders = try XCTUnwrap(session.folders), source = try XCTUnwrap(session.model.collections.first { $0.id == 2 })
        folders.begin(copying ? .copy : .move, photos: session.model.items, folders: [source])
        try await wait { !folders.isLoading }; XCTAssertNil(folders.error)
        XCTAssertNil(folders.mutation)
        folders.open(try XCTUnwrap(folders.children.first { $0.id == 3 }))
        try await wait { !folders.isLoading }; XCTAssertNotNil(folders.mutation)
        return folders
    }

    func test新建重命名排序形成原目录闭环() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folders = try XCTUnwrap(session.folders)
        XCTAssertFalse(folders.allows(.rename)); XCTAssertFalse(folders.allows(.cover))
        folders.begin(.create, photos: [], folders: []); folders.name = " Trip "
        XCTAssertTrue(folders.submit()); XCTAssertFalse(folders.submit())
        try await wait { !session.model.isManaging }
        let created = try XCTUnwrap(session.model.collections.first { $0.name == "Trip" })
        XCTAssertEqual(created.parentID, 1)
        folders.begin(.rename, folder: created, photos: [], folders: []); folders.name = "Renamed"
        XCTAssertTrue(folders.submit()); try await wait { !session.model.isManaging }
        let renamed = try XCTUnwrap(session.model.collections.first { $0.id == created.id })
        XCTAssertEqual(renamed.name, "Renamed"); XCTAssertEqual(renamed.path, "/Renamed")
        folders.begin(.sort, folder: renamed, photos: [], folders: []); try await wait { !folders.isLoading }
        folders.sort = .init(field: .filesize, direction: .descending)
        XCTAssertTrue(folders.submit()); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 3)
        guard case .setFolderSort(let target, let sort) = commands.last else { return XCTFail("应保存目录排序") }
        XCTAssertEqual(target.id, created.id); XCTAssertEqual(sort, .init(field: .filesize, direction: .descending))
    }

    func test混合目录照片移动固定选择并从来源列表移除() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await transfer(session)
        session.model.selectLoadedItems()
        XCTAssertEqual(editor.mutation?.photos.count, 2); XCTAssertEqual(editor.mutation?.transferFolders.map(\.id), [2])
        XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); XCTAssertTrue(session.model.items.isEmpty)
        XCTAssertEqual(session.model.collections.map(\.id), [3])
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .move(_, let target, let space, _, _) = commands[0] else { return XCTFail("应是移动操作") }
        XCTAssertEqual(target, 3); XCTAssertEqual(space, .personal)
    }

    func test复制覆盖确认前不提交且默认跳过重复项() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await transfer(session, copying: true)
        XCTAssertEqual(editor.duplicate, .skip); editor.duplicate = .overwrite
        XCTAssertFalse(editor.submit()); XCTAssertTrue(editor.showsConfirmation)
        let before = await service.commands; XCTAssertTrue(before.isEmpty)
        editor.showsConfirmation = false; XCTAssertNotNil(editor.mutation)
        XCTAssertTrue(editor.submit(confirmed: true)); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.items.count, 2); XCTAssertTrue(session.model.collections.contains { $0.id == 2 })
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .copy(_, _, _, _, let duplicate) = commands[0] else { return XCTFail("应是复制操作") }
        XCTAssertEqual(duplicate, .overwrite)
    }

    func test读取重复文件偏好后导航不覆盖本次选择() async throws {
        let (root, _, _, session) = try await fixture("photo-folders-defaults"); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await transfer(session, copying: true)
        XCTAssertEqual(editor.duplicate, .overwrite); XCTAssertTrue(editor.needsConfirmation)
        editor.duplicate = .skip; editor.goBack(); try await wait { !editor.isLoading }
        editor.open(try XCTUnwrap(editor.children.first { $0.id == 3 })); try await wait { !editor.isLoading }
        XCTAssertEqual(editor.duplicate, .skip); XCTAssertFalse(editor.needsConfirmation)
    }

    func test删除目录与照片必须确认且结果逐项移除() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try XCTUnwrap(session.folders)
        session.model.selectLoadedItems(); XCTAssertEqual(session.model.selectedItemCount, 4)
        editor.begin(.delete); XCTAssertFalse(editor.submit()); XCTAssertTrue(editor.showsConfirmation)
        let before = await service.commands; XCTAssertTrue(before.isEmpty)
        XCTAssertTrue(editor.submit(confirmed: true)); try await wait { !session.model.isManaging }
        XCTAssertTrue(session.model.items.isEmpty); XCTAssertTrue(session.model.collections.isEmpty)
        XCTAssertEqual(session.model.selectedItemCount, 0)
    }

    func test封面可从目标子目录选择且不扩大到兄弟目录() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try XCTUnwrap(session.folders), source = try XCTUnwrap(session.model.collections.first { $0.id == 2 })
        editor.begin(.cover, folder: source, photos: [], folders: []); try await wait { !editor.isLoading }
        XCTAssertEqual(editor.path.map(\.id), [2]); XCTAssertNil(editor.mutation)
        editor.goBack(); XCTAssertEqual(editor.path.map(\.id), [2])
        editor.open(try XCTUnwrap(editor.children.first { $0.id == 200 })); try await wait { !editor.isLoading }
        editor.coverPhoto = try XCTUnwrap(editor.coverPhotos.first)
        XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        let commands = await service.commands
        guard case .setFolderCover(let target, let photo) = commands.last else { return XCTFail("应保存封面") }
        XCTAssertEqual(target.id, 2); XCTAssertEqual(photo.folderID, 200)
    }

    func test移动拒绝原父目录自身及后代共享反向只能复制() async throws {
        let (root, _, _, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try XCTUnwrap(session.folders), source = try XCTUnwrap(session.model.collections.first { $0.id == 2 })
        editor.begin(.move, photos: [], folders: [source]); try await wait { !editor.isLoading }
        XCTAssertNil(editor.mutation)
        editor.open(try XCTUnwrap(editor.children.first { $0.id == 2 })); try await wait { !editor.isLoading }; XCTAssertNil(editor.mutation)
        editor.open(try XCTUnwrap(editor.children.first { $0.id == 200 })); try await wait { !editor.isLoading }; XCTAssertNil(editor.mutation)
        editor.cancel(); await session.model.selectSpace(.shared)
        let shared = try XCTUnwrap(session.model.collections.first { $0.id == 2 })
        editor.begin(.move, photos: [], folders: [shared]); try await wait { !editor.isLoading }
        XCTAssertEqual(editor.destinationSpaces, [.shared]); editor.changeSpace(.personal); XCTAssertEqual(editor.destinationSpace, .shared)
        editor.cancel(); editor.begin(.copy, photos: [], folders: [shared]); try await wait { !editor.isLoading }
        XCTAssertEqual(Set(editor.destinationSpaces), [.personal, .shared]); editor.changeSpace(.personal); try await wait { !editor.isLoading }
        XCTAssertNotNil(editor.mutation)
    }

    func test目录任务未知重启仅查询原任务并清理原记录() async throws {
        let (root, storage, service, session) = try await fixture("photo-folders-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await transfer(session, copying: true); XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        let id = try XCTUnwrap(session.model.pendingMutationID), saved = try XCTUnwrap(store(storage).load())
        XCTAssertEqual(saved.operationID, id); XCTAssertEqual(saved.version, 8); XCTAssertEqual(saved.folderDetails?.taskID, 88)
        session.deactivate()
        let restored = MobileSynologyPhotosSession(); restored.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await restored.activate()
        XCTAssertEqual(restored.model.pendingMutationID, id)
        XCTAssertFalse(try XCTUnwrap(restored.folders).allows(.copy, photos: restored.model.items, folders: []))
        await service.setPending(false); restored.model.reviewPendingMutation(); try await wait { !restored.model.isManaging }
        XCTAssertNil(restored.model.pendingMutationID); XCTAssertNil(try store(storage).load())
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test部分移动不提供整批重试且不会误移除来源选择() async throws {
        let (root, _, service, session) = try await fixture("photo-folders-partial"); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await transfer(session); XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(session.model.retryableManagementMutation)
        XCTAssertTrue(session.model.collections.contains { $0.id == 2 })
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test目标读取完整分页空内容及失败均保留正确保存状态() async throws {
        for state in ["photo-folders-paged", "photo-folders-empty", "photo-folders-error"] {
            let (root, _, _, session) = try await fixture(state, openFolders: false); defer { try? FileManager.default.removeItem(at: root) }
            let editor = try XCTUnwrap(session.folders), photo = try XCTUnwrap(session.model.items.first)
            editor.begin(.copy, photos: [photo], folders: []); try await wait { !editor.isLoading }
            if state.hasSuffix("paged") { XCTAssertEqual(editor.children.count, 101) }
            else { XCTAssertTrue(editor.children.isEmpty) }
            XCTAssertEqual(editor.error != nil, state.hasSuffix("error")); XCTAssertNil(editor.mutation)
        }
    }

    func test目录草稿切空间离开或迟到读取不会提交旧账号() async throws {
        let (root, _, service, session) = try await fixture("photo-folders-held", openFolders: false); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try XCTUnwrap(session.folders)
        editor.begin(.copy, photos: [try XCTUnwrap(session.model.items.first)], folders: [])
        for _ in 0..<100 { if await service.isFolderHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        session.configure(MobilePhotosUIService()); await service.releaseFolder()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(editor.draft); XCTAssertTrue(editor.path.isEmpty); XCTAssertNil(editor.mutation)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test目录保存前权限撤销不会写入或保留伪在途操作() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await transfer(session, copying: true)
        await service.denyWrites(); XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(try store(storage).load())
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test图库内拖放固定来源且外部或重复标识无效() async throws {
        let (root, _, _, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(session.model.collections.first { $0.id == 2 }), target = try XCTUnwrap(session.model.collections.first { $0.id == 3 })
        let token = try XCTUnwrap(session.model.beginPhotoDrag(folder: source))
        XCTAssertNil(session.model.takePhotoDrop(token: UUID(), to: target))
        let snapshot = try XCTUnwrap(session.model.takePhotoDrop(token: token, to: target))
        XCTAssertNil(session.model.takePhotoDrop(token: token, to: target))
        let editor = try XCTUnwrap(session.folders)
        editor.begin(.move, photos: snapshot.photos, folders: snapshot.folders, destinationPath: session.model.photoDropPath(to: target))
        try await wait { !editor.isLoading }
        XCTAssertEqual(editor.mutation?.transferFolders.map(\.id), [source.id]); XCTAssertEqual(editor.path.last?.id, target.id)
    }
}
