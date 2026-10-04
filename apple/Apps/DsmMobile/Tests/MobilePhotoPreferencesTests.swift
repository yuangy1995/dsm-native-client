@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoPreferencesTests: XCTestCase {
    private func fixture(_ state: String = "photo-preferences") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-preferences-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待照片设置或旋转结束超时")
    }
    private func open(_ page: MobilePhotoPreferencesModel.Page, in session: MobileSynologyPhotosSession) async throws -> MobilePhotoPreferencesModel {
        let preferences = try XCTUnwrap(session.preferences); preferences.begin(page); try await wait { !preferences.isLoading }; return preferences
    }

    func test重复策略读取且默认覆盖需冻结确认普通修改直接保存() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.duplicates, in: session)
        XCTAssertEqual(value.duplicates.upload, .ignore); XCTAssertNil(value.mutation)
        value.duplicates.transfer = .overwrite; XCTAssertFalse(value.save()); XCTAssertTrue(value.showsConfirmation)
        let empty = await service.commands; XCTAssertTrue(empty.isEmpty)
        value.cancelConfirmation(); value.duplicates.transfer = .skip; value.duplicates.upload = .rename
        XCTAssertTrue(value.save()); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        _ = try await open(.duplicates, in: session); XCTAssertEqual(value.duplicates.upload, .rename)
        value.duplicates.transfer = .overwrite; XCTAssertFalse(value.save()); XCTAssertTrue(value.confirmSave()); XCTAssertFalse(value.confirmSave())
        try await wait { !session.model.isManaging }; let saved = try await service.duplicateSettings(); XCTAssertEqual(saved.transfer, .overwrite)
    }

    func test重复确认后变更草稿不可提交旧设置() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.duplicates, in: session); value.duplicates.transfer = .overwrite; XCTAssertFalse(value.save())
        value.duplicates.upload = .rename; XCTAssertFalse(value.confirmSave()); XCTAssertNotNil(value.error)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test显示保存应用分组格式时间和预览默认资料() async throws {
        let (root, _, _, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.display, in: session)
        value.display = .init(grouping: .month, dateFormat: .daySlash, clock: .twelve,
            defaultSort: .init(field: .filename, direction: .descending), showsPreviewInfo: true)
        let target = value.display; XCTAssertTrue(value.save()); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.displayPreferences, target)
        let photo = try XCTUnwrap(session.model.items.first)
        let formatter = DateFormatter(); formatter.locale = .init(identifier: "en_US_POSIX"); formatter.dateFormat = "dd/MM/yyyy"
        XCTAssertEqual(session.model.formattedPhotoDate(photo.takenAt), formatter.string(from: photo.takenAt))
        XCTAssertFalse(session.model.formattedPhotoDate(photo.takenAt, group: true).isEmpty)
        XCTAssertEqual(session.model.datedGroups.count, 1)
    }

    func test智能分类保留缺字段和管理员限制() async throws {
        let (root, _, service, session) = try await fixture("photo-preferences-restricted"); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.recognition, in: session)
        XCTAssertNil(value.originalRecognition?.values[.concept]); XCTAssertEqual(value.originalRecognition?.editable, [.person])
        value.recognition.insert(.similar); XCTAssertNil(value.mutation)
        value.recognition = []; XCTAssertNotNil(value.mutation); XCTAssertTrue(value.save()); try await wait { !session.model.isManaging }
        let saved = try await service.recognitionSettings(); XCTAssertEqual(saved.values, [.person: false, .similar: false])
    }

    func test设置空内容错误和缺能力不允许保存() async throws {
        for state in ["photo-preferences-empty", "photo-preferences-error", "photo-preferences-readonly"] {
            let (root, _, _, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            let value = try await open(.recognition, in: session)
            XCTAssertNil(value.mutation)
            if state.hasSuffix("empty") { XCTAssertEqual(value.originalRecognition?.values, [:]) }
            if state.hasSuffix("error") { XCTAssertNotNil(value.error); value.load(); try await wait { !value.isLoading }; XCTAssertNotNil(value.error) }
            if state.hasSuffix("readonly") { XCTAssertNil(value.draft); XCTAssertFalse(value.canOpen(.recognition)) }
        }
    }

    func test设置迟到读取不会回填切换后的会话() async throws {
        let (root, _, service, session) = try await fixture("photo-preferences-held"); defer { try? FileManager.default.removeItem(at: root) }
        let value = try XCTUnwrap(session.preferences); value.begin(.display)
        for _ in 0..<100 { if await service.isControlHeld { break }; await Task.yield() }
        let held = await service.isControlHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-preferences")); await service.releaseControl(); await session.activate()
        for _ in 0..<10 { await Task.yield() }; XCTAssertNil(value.originalDisplay); XCTAssertNil(value.draft)
    }

    func test设置未知重启仅查询且不得再次保存() async throws {
        let (root, storage, service, session) = try await fixture("photo-preferences-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.display, in: session); value.display.clock = .twelve; XCTAssertTrue(value.save())
        try await wait { !session.model.isManaging }; XCTAssertNotNil(session.model.pendingMutationID)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        let reopened = try await open(.display, in: session); XCTAssertFalse(reopened.editable)
        await service.setPending(false); session.model.reviewPendingMutation(); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); XCTAssertEqual(session.model.displayPreferences?.clock, .twelve)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test上传使用已保存重复策略并等待读取完成() async throws {
        let (root, _, _, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try XCTUnwrap(session.uploads); uploads.begin(); XCTAssertTrue(uploads.isLoadingDefaults); XCTAssertFalse(uploads.canSubmit)
        try await wait { !uploads.isLoadingDefaults }; XCTAssertEqual(uploads.duplicate, .ignore); XCTAssertNil(uploads.defaultsError)
        uploads.cancel(); XCTAssertNil(uploads.draftID)
    }

    func test上传默认读取失败不能静默改成另一策略() async throws {
        let (root, _, _, session) = try await fixture("photo-preferences-error"); defer { try? FileManager.default.removeItem(at: root) }
        let uploads = try XCTUnwrap(session.uploads); uploads.begin(); try await wait { !uploads.isLoadingDefaults }
        XCTAssertNotNil(uploads.defaultsError); XCTAssertFalse(uploads.canSubmit)
    }

    func test旋转保存方向尺寸且重复点击只发送一次() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        session.model.showPreview(try XCTUnwrap(session.model.items.first)); try await wait { !session.model.isPreparingPreview }
        XCTAssertTrue(session.model.canRotatePreview); session.model.rotatePreview(); session.model.rotatePreview()
        try await wait { !session.model.isManaging && !session.model.isPreparingPreview }
        XCTAssertEqual(session.model.previewPhoto?.orientation, 8); XCTAssertEqual(session.model.previewPhoto?.width, 80)
        XCTAssertEqual(session.model.previewPhoto?.height, 100)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test旋转未知重启恢复只读并清除恢复记录() async throws {
        let (root, storage, service, session) = try await fixture("photo-preferences-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        session.model.showPreview(try XCTUnwrap(session.model.items.first)); try await wait { !session.model.isPreparingPreview }
        session.model.rotatePreview(); try await wait { !session.model.isManaging }; XCTAssertNotNil(session.model.pendingMutationID)
        let store = PhotoAlbumRecoveryStore(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
        XCTAssertEqual(try store.load()?.version, 10)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        XCTAssertNotNil(session.model.pendingMutationID); await service.setPending(false); session.model.reviewPendingMutation()
        try await wait { !session.model.isManaging }; XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(try store.load())
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test恢复文件损坏同时限制设置与旋转() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: url)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        let value = try await open(.display, in: session); value.display.clock = .twelve; XCTAssertNil(value.mutation)
        session.model.showPreview(try XCTUnwrap(session.model.items.first)); try await wait { !session.model.isPreparingPreview }
        XCTAssertFalse(session.model.canRotatePreview); session.model.rotatePreview()
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }
}
