@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoEditTests: XCTestCase {
    private func fixture(_ state: String = "photo-edit") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-edit-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func store(_ storage: MobilePhotoUploadStorage) -> PhotoAlbumRecoveryStore {
        .init(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待照片编辑结束超时")
    }
    private func begin(_ session: MobileSynologyPhotosSession, _ action: MobilePhotoEditModel.Action) async throws -> MobilePhotoEditModel {
        if session.model.selectedPhotos.count != session.model.items.count { session.model.selectGroup(session.model.items) }
        let editor = try XCTUnwrap(session.editor)
        editor.begin(action); try await wait { !editor.isLoading }
        XCTAssertNotNil(editor.draft); XCTAssertNil(editor.error)
        return editor
    }

    func test评分描述日期标签添加移除形成批量闭环() async throws {
        for action in [MobilePhotoEditModel.Action.rating, .description, .date, .tagsAdd, .tagsRemove] {
            let (root, storage, service, session) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let editor = try await begin(session, action)
            switch action {
            case .rating: editor.rating = 4
            case .description: editor.text = "Updated description"
            case .date: editor.date = Date(timeIntervalSince1970: 1_600_000_000)
            case .tagsAdd, .tagsRemove: editor.tags = [8]
            default: break
            }
            XCTAssertTrue(editor.submit()); XCTAssertFalse(editor.submit())
            try await wait { !session.model.isManaging }
            XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(try store(storage).load())
            let commands = await service.commands; XCTAssertEqual(commands.count, 1)
            for photo in session.model.items {
                switch action {
                case .rating: XCTAssertEqual(photo.rating, 4)
                case .description: XCTAssertEqual(photo.description, "Updated description")
                case .date: XCTAssertEqual(photo.takenAt.timeIntervalSince1970, 1_600_000_000)
                case .tagsAdd: XCTAssertTrue(photo.tags?.contains { $0.id == 8 } == true)
                case .tagsRemove: XCTAssertEqual(photo.tags, [])
                default: break
                }
            }
        }
    }

    func test单张描述先读取现值并允许明确清空() async throws {
        let (root, _, _, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try XCTUnwrap(session.editor), photo = try XCTUnwrap(session.model.items.first)
        editor.begin(.description, photos: [photo]); try await wait { !editor.isLoading }
        XCTAssertEqual(editor.text, "Original description")
        editor.text = ""; XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.items.first?.description, "")
    }

    func test相对时间部分成功只继续剩余项且保持原间隔() async throws {
        let (root, _, service, session) = try await fixture("photo-edit-partial"); defer { try? FileManager.default.removeItem(at: root) }
        let original = session.model.items
        let editor = try await begin(session, .shiftDates)
        editor.shiftAmount = 2; editor.shiftUnit = .hours
        XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        guard case .shiftDates(let remaining, let seconds) = session.model.retryableManagementMutation else { return XCTFail("应只继续剩余照片") }
        XCTAssertEqual(remaining.map(\.id), [original[1].id]); XCTAssertEqual(seconds, 7_200)
        session.model.continuePartialManagement(); try await wait { !session.model.isManaging }
        for (index, photo) in session.model.items.enumerated() { XCTAssertEqual(photo.takenAt.timeIntervalSince(original[index].takenAt), 7_200) }
        let commands = await service.commands; XCTAssertEqual(commands.map { $0.photos.count }, [2, 1])
    }

    func test新标签部分失败只继续加入且不重新创建() async throws {
        let (root, _, service, session) = try await fixture("photo-edit-tag-partial"); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await begin(session, .tagsCreate); editor.text = " New tag "
        XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        guard case .addTags(let remaining, let ids) = session.model.retryableManagementMutation else { return XCTFail("应仅补充标签") }
        XCTAssertEqual(remaining.count, 2); XCTAssertEqual(ids, [101])
        session.model.continuePartialManagement(); try await wait { !session.model.isManaging }
        XCTAssertTrue(session.model.items.allSatisfy { $0.tags?.contains { $0.id == 101 && $0.name == "New tag" } == true })
        let commands = await service.commands; XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.filter { if case .createTag = $0 { return true }; return false }.count, 1)
    }

    func test未知日期重启恢复只查询且不会再次偏移() async throws {
        let (root, storage, service, session) = try await fixture("photo-edit-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let original = session.model.items
        let editor = try await begin(session, .shiftDates); editor.shiftAmount = 10; editor.shiftUnit = .minutes
        XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        let id = try XCTUnwrap(session.model.pendingMutationID)
        let saved = try XCTUnwrap(store(storage).load()); XCTAssertEqual(saved.operationID, id); XCTAssertEqual(saved.version, 7)
        session.deactivate()
        let restored = MobileSynologyPhotosSession(); restored.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await restored.activate()
        XCTAssertEqual(restored.model.pendingMutationID, id)
        XCTAssertFalse(try XCTUnwrap(restored.editor).allows(.rating, photos: original))
        await service.setPending(false); restored.model.reviewPendingMutation(); try await wait { !restored.model.isManaging }
        XCTAssertNil(restored.model.pendingMutationID); XCTAssertNil(try store(storage).load())
        for (index, photo) in restored.model.items.enumerated() { XCTAssertEqual(photo.takenAt.timeIntervalSince(original[index].takenAt), 600) }
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test恢复部分结果不生成由摘要构成的重试写入() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let command = SynologyPhotosMutation.edit(session.model.items, .description("Never stored"))
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: service.profileID, userID: 12)
        try store(storage).save(saved); session.deactivate()
        let restored = MobileSynologyPhotosSession(); restored.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await restored.activate()
        restored.model.reviewPendingMutation(); try await wait { !restored.model.isManaging }
        XCTAssertNil(restored.model.pendingMutationID); XCTAssertNil(restored.model.retryableManagementMutation)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test标签空内容或读取失败保持不可保存且可返回创建() async throws {
        for state in ["photo-edit-tags-empty", "photo-edit-tags-error"] {
            let (root, _, _, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            session.model.selectGroup(session.model.items)
            let editor = try XCTUnwrap(session.editor); editor.begin(.tagsAdd); try await wait { !editor.isLoading }
            XCTAssertNil(editor.mutation); XCTAssertTrue(editor.choices.isEmpty)
            XCTAssertEqual(editor.error != nil, state.hasSuffix("error"))
            editor.cancel(); editor.begin(.tagsCreate); try await wait { !editor.isLoading }; editor.text = "New tag"
            XCTAssertNotNil(editor.mutation)
        }
    }

    func test冻结选择不跟随勾选且切空间或离开后草稿失效() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try XCTUnwrap(session.editor), original = try XCTUnwrap(session.model.items.first)
        editor.begin(.rating, photos: [original]); try await wait { !editor.isLoading }
        session.model.selectGroup(session.model.items)
        XCTAssertEqual(editor.mutation?.photos.map(\.id), [original.id])
        await session.model.selectSpace(.shared); XCTAssertNil(editor.mutation)
        session.deactivate(); XCTAssertNil(editor.draft); XCTAssertFalse(editor.submit())
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test单张资料迟到回调不会恢复已取消草稿或新账号() async throws {
        let (root, _, service, session) = try await fixture("photo-edit-held"); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try XCTUnwrap(session.editor)
        editor.begin(.description, photos: [try XCTUnwrap(session.model.items.first)])
        for _ in 0..<100 { if await service.isEditHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        session.configure(MobilePhotosUIService()); await service.releaseEdit()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(editor.draft); XCTAssertEqual(editor.text, ""); XCTAssertNil(editor.mutation)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test只读及混合来源按各自编辑资格限制() async throws {
        for state in ["photo-edit-readonly", "photo-edit-mixed"] {
            let (root, _, service, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            let editor = try XCTUnwrap(session.editor)
            if state.hasSuffix("readonly") {
                XCTAssertTrue(MobilePhotoEditModel.Action.allCases.allSatisfy { !editor.allows($0, photos: session.model.items) }); continue
            }
            let personal = try XCTUnwrap(session.model.items.first)
            let shared = SynologyPhoto(id: .init(profileID: service.profileID, space: .shared, unitID: 2), filename: "Shared.jpg", sizeBytes: 128,
                takenAt: personal.takenAt, indexedAt: personal.indexedAt, folderID: 1, mediaType: "photo")
            await service.seedPhotos([personal, shared]); await session.model.selectSection(.albums)
            await session.model.open(try XCTUnwrap(session.model.collections.first)); session.model.selectGroup(session.model.items)
            XCTAssertNil(session.model.errorMessage); XCTAssertEqual(session.model.selectedPhotos.count, 2)
            XCTAssertTrue(editor.allows(.rating)); XCTAssertTrue(editor.allows(.date)); XCTAssertTrue(editor.allows(.shiftDates))
            XCTAssertFalse(editor.allows(.description)); XCTAssertFalse(editor.allows(.tagsAdd)); XCTAssertFalse(editor.allows(.tagsCreate))
        }
    }

    func test无照片可单独创建标签且非法偏移不能提交() async throws {
        let (root, _, _, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try XCTUnwrap(session.editor)
        editor.begin(.tagsCreate, photos: []); try await wait { !editor.isLoading }; XCTAssertNil(editor.mutation)
        editor.text = "Tag without photos"; XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        XCTAssertTrue(session.model.options.tags.contains { $0.name == "Tag without photos" })
        _ = try await begin(session, .shiftDates)
        for value in [0, -1, Int.max] { editor.shiftAmount = value; XCTAssertNil(editor.mutation) }
        editor.shiftAmount = 1; editor.shiftUnit = .seconds; editor.shiftForward = false
        XCTAssertEqual(editor.shiftSeconds, -1); XCTAssertNotNil(editor.mutation)
        editor.cancel(); _ = try await begin(session, .tagsAdd); editor.tags = [999]; XCTAssertNil(editor.mutation)
    }

    func test资料恢复文件保存失败不得发起写入() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = store(storage).url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: directory)
        let editor = try await begin(session, .rating); editor.rating = 5; XCTAssertTrue(editor.submit())
        try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }
}
