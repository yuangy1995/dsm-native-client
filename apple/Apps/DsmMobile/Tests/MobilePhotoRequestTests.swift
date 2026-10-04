@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoRequestTests: XCTestCase {
    private func fixture(_ state: String = "photo-request") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-request-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("收集操作未结束")
    }
    private func open(_ session: MobileSynologyPhotosSession, editing: Bool = false, deleting: Bool = false) async throws -> MobilePhotoRequestModel {
        let form = try XCTUnwrap(session.requests)
        if editing || deleting {
            await session.model.selectSection(.sharing); await session.model.selectShareScope(.requests)
            form.begin(entry: try XCTUnwrap(session.model.sharedEntries.first), deleting: deleting)
        } else { form.begin() }
        try await wait { !form.isLoading && !form.loadingAlbums }
        return form
    }
    private func store(_ storage: MobilePhotoUploadStorage) -> PhotoAlbumRecoveryStore {
        .init(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
    }

    func test默认收集目录创建一次且返回链接并清除恢复记录() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session)
        XCTAssertNil(form.mutation); form.settings.subject = "  Photos:today  "
        XCTAssertEqual(form.preparedSettings?.folderPath, "/PhotoRequest/Photos_today")
        XCTAssertTrue(form.submit()); XCTAssertFalse(form.submit()); try await wait { !session.model.isManaging }
        XCTAssertNotNil(session.model.managementLink); XCTAssertNil(try store(storage).load())
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .createPhotoRequest(let settings) = try XCTUnwrap(commands.first) else { return XCTFail("应创建收集") }
        XCTAssertEqual(settings.subject, "Photos:today"); XCTAssertNil(settings.folderID); XCTAssertEqual(settings.sizeLimit, 0)
        XCTAssertNil(form.draft); XCTAssertEqual(form.settings.subject, "")
    }

    func test编辑保留精确大小日期且显式清除相册() async throws {
        let (root, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session, editing: true)
        XCTAssertNil(form.mutation)
        form.settings.description = "Changed description"; form.selectedAlbumID = ""
        XCTAssertEqual(form.preparedSettings?.sizeLimit, 1_234_567); XCTAssertEqual(form.preparedSettings?.expiration, 2_000_000_007)
        XCTAssertTrue(form.submit()); try await wait { !session.model.isManaging }
        let commands = await service.commands
        guard case .updatePhotoRequest(let original, let updated) = try XCTUnwrap(commands.first) else { return XCTFail("应提交原始快照和修改") }
        XCTAssertEqual(original.id, "synthetic-request"); XCTAssertEqual(original.settings.albumID, 21)
        XCTAssertNil(updated.albumID); XCTAssertNil(updated.albumPassphrase)
        XCTAssertEqual(updated.sizeLimit, 1_234_567); XCTAssertEqual(updated.expiration, 2_000_000_007)
    }

    func test删除须明确确认且只删除收集不删相册或原照片() async throws {
        let (root, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session, deleting: true)
        XCTAssertNotNil(form.mutation); XCTAssertFalse(form.submit())
        form.cancel(); var commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        _ = try await open(session, deleting: true)
        XCTAssertTrue(form.submit(confirmedDeletion: true)); XCTAssertFalse(form.submit(confirmedDeletion: true))
        try await wait { !session.model.isManaging }
        XCTAssertTrue(session.model.sharedEntries.isEmpty)
        commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .deletePhotoRequest(let original) = commands[0] else { return XCTFail("只应删除收集链接") }
        XCTAssertEqual(original.id, "synthetic-request")
        let albums = try await service.albums(offset: 0, limit: 100); XCTAssertEqual(albums.count, 1)
    }

    func test共享来源必须选择目录且完整分页不遗漏后续目录() async throws {
        let (root, _, _, session) = try await fixture("photo-request-paged")
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session); form.settings.subject = "Shared collection"
        form.changeSpace(.shared); XCTAssertFalse(form.usesDefaultFolder); XCTAssertNil(form.mutation)
        form.loadFolders(); try await wait { !form.loadingFolders }
        XCTAssertEqual(form.folders.count, 101)
        let folder = try XCTUnwrap(form.folders.last)
        form.loadFolders(path: form.folderPath + [folder]); try await wait { !form.loadingFolders }
        XCTAssertTrue(form.chooseFolder()); XCTAssertEqual(form.preparedSettings?.folderID, 102)
        XCTAssertEqual(form.preparedSettings?.space, .shared); XCTAssertEqual(form.preparedSettings?.folderPath, "/Folder 100")
        form.changeSpace(.personal); XCTAssertTrue(form.usesDefaultFolder); XCTAssertNil(form.settings.folderID)
        XCTAssertTrue(form.folderPath.isEmpty)
    }

    func test大小日期和标题限制必须有效后才能提交() async throws {
        let (root, _, _, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session)
        form.settings.subject = String(repeating: "😀", count: 26); XCTAssertNil(form.mutation)
        form.settings.subject = "Title"; form.settings.description = String(repeating: "a", count: 101); XCTAssertNil(form.mutation)
        form.settings.description = ""; form.limitsSize = true; form.sizeEdited = true
        for size in [0, 3001] { form.sizeMiB = size; XCTAssertNil(form.mutation) }
        form.sizeMiB = 3000; XCTAssertEqual(form.preparedSettings?.sizeLimit, 3_145_728_000)
        form.expiration.choice = .date; form.expiration.edited = true; form.expiration.date = .distantPast
        XCTAssertNil(form.mutation); form.expiration.choice = .unlimited; XCTAssertNotNil(form.mutation)
    }

    func test无效原目录必须更换才能编辑但仍可删除收集() async throws {
        let (root, _, _, session) = try await fixture("photo-request-invalid-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session, editing: true); form.settings.description = "Updated"
        XCTAssertNil(form.mutation); form.usesDefaultFolder = true; XCTAssertNotNil(form.mutation)
        form.cancel(); _ = try await open(session, deleting: true); XCTAssertNotNil(form.mutation)
    }

    func test可选相册读取失败不阻止无相册收集且支持表单内新建相册() async throws {
        let (root, _, service, session) = try await fixture("photo-request-albums-error")
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session); form.settings.subject = "Title"
        XCTAssertNotNil(form.albumError); XCTAssertNotNil(form.mutation)
        form.newAlbumName = "New request album"; form.createAlbum(); form.createAlbum()
        try await wait { !session.model.isManaging }
        XCTAssertEqual(form.settings.albumID, 101); XCTAssertEqual(form.albums.first?.name, "New request album")
        XCTAssertTrue(form.submit()); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 2)
        guard case .createPhotoRequest(let settings) = commands[1] else { return XCTFail("应关联新相册") }
        XCTAssertEqual(settings.albumID, 101)
    }

    func test换账号拒绝迟到收集内容且取消清空口令() async throws {
        let (root, _, service, session) = try await fixture("photo-request-held")
        defer { try? FileManager.default.removeItem(at: root) }
        await session.model.selectSection(.sharing); await session.model.selectShareScope(.requests)
        let form = try XCTUnwrap(session.requests)
        form.begin(entry: try XCTUnwrap(session.model.sharedEntries.first))
        for _ in 0..<300 { if await service.isRequestHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        let held = await service.isRequestHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-request")); await session.activate()
        await service.releaseRequest(); try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(form.original); XCTAssertNil(form.draft); XCTAssertFalse(form.submit())
        let current = try XCTUnwrap(session.requests); current.begin(); try await wait { !current.isLoading && !current.loadingAlbums }
        current.selectedAlbumID = "shared:synthetic-shared-album"; XCTAssertEqual(current.settings.albumPassphrase, "synthetic-shared-album")
        current.cancel(); XCTAssertNil(current.settings.albumPassphrase); XCTAssertTrue(current.albums.isEmpty)
    }

    func test只读及切换来源拒绝旧草稿而仅共享账号可创建收集() async throws {
        for state in ["photo-request-readonly", "photo-request-nohome", "photo-request"] {
            let (root, _, _, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let form = try XCTUnwrap(session.requests)
            if state.hasSuffix("readonly") { XCTAssertFalse(form.canOpen()); form.begin(); XCTAssertNil(form.draft) }
            else {
                _ = try await open(session); form.settings.subject = "Title"
                if state.hasSuffix("nohome") { XCTAssertEqual(form.settings.space, .shared); XCTAssertTrue(form.canCreateAlbum); XCTAssertFalse(form.usesDefaultFolder) }
                else { await session.model.selectSpace(.shared); XCTAssertNil(form.mutation); XCTAssertFalse(form.submit()) }
            }
        }
    }

    func test收集未知重启只读完成且记录不含主题目录或口令() async throws {
        let (root, storage, service, session) = try await fixture("photo-request-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session); form.settings.subject = "Private collection"; form.settings.description = "Private description"
        let expected = try XCTUnwrap(form.preparedSettings)
        XCTAssertTrue(form.submit()); try await wait { !session.model.isManaging }
        let pending = try XCTUnwrap(session.model.pendingMutationID), saved = try XCTUnwrap(store(storage).load())
        XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion)
        let text = String(decoding: try Data(contentsOf: store(storage).url), as: UTF8.self)
        for secret in ["Private collection", "Private description", "/PhotoRequest", "synthetic-created", "https://"] { XCTAssertFalse(text.contains(secret)) }
        session.deactivate()
        let reader = MobilePhotosUIService(profileID: service.profileID, state: "photo-request"), next = MobileSynologyPhotosSession()
        await reader.seedRequest(.init(id: "synthetic-created-101", profileID: service.profileID, settings: expected, isFolderValid: true, url: URL(string: "https://example.invalid/request/new")))
        next.configure(reader, uploadStorage: storage, reviewDelay: { _ in }); await next.activate()
        XCTAssertEqual(next.model.pendingMutationID, pending); XCTAssertFalse(try XCTUnwrap(next.requests).canOpen())
        next.model.reviewPendingMutation(); try await wait { !next.model.isManaging }
        XCTAssertNil(next.model.pendingMutationID); XCTAssertNotNil(next.model.managementLink); XCTAssertNil(try store(storage).load())
        let commands = await reader.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test删除收集跨重启摘要恢复后刷新原列表() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session, deleting: true), original = try XCTUnwrap(form.original)
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: .deletePhotoRequest(original), operationID: UUID(), profileID: service.profileID, userID: 12)
        session.deactivate(); try store(storage).save(saved)
        let next = MobileSynologyPhotosSession(); next.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await next.activate()
        await next.model.selectSection(.sharing); await next.model.selectShareScope(.requests)
        XCTAssertEqual(next.model.sharedEntries.count, 1)
        await service.seedRequest(.init(id: "another-request", profileID: service.profileID, settings: original.settings, isFolderValid: true))
        next.model.reviewPendingMutation(); try await wait { !next.model.isManaging }
        XCTAssertEqual(next.model.sharedEntries.map(\.id), ["another-request"])
        XCTAssertNil(next.model.pendingMutationID)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test目录读取失败不允许使用旧目录且收集保存失败零写() async throws {
        let (root, storage, service, session) = try await fixture("photo-request-folders-error")
        defer { try? FileManager.default.removeItem(at: root) }
        let form = try await open(session); form.settings.subject = "Title"
        form.loadFolders(); try await wait { !form.loadingFolders }
        XCTAssertNotNil(form.folderError); XCTAssertFalse(form.chooseFolder())
        let folder = store(storage).url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: folder)
        XCTAssertTrue(form.submit()); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }
}
