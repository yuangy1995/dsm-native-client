@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoPreviewMaintenanceTests: XCTestCase {
    private func fixture(_ state: String = "photo-preview") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-preview-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待预览设置或维护结束超时")
    }
    private func open(_ page: MobilePhotoPreferencesModel.Page, in session: MobileSynologyPhotosSession) async throws -> MobilePhotoPreferencesModel {
        let value = try XCTUnwrap(session.preferences); value.begin(page); try await wait { !value.isLoading }; return value
    }
    private func store(_ storage: MobilePhotoUploadStorage) -> PhotoAlbumRecoveryStore {
        .init(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
    }

    func test自动设置只保存变化且表单打开暂停领取() async throws {
        let (root, _, service, session) = try await fixture("photo-preview-automatic")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let value = try await open(.automatic, in: session); XCTAssertTrue(value.automatic); XCTAssertNil(value.mutation)
        await session.model.processAutomaticPreview(); let before = await service.commands; XCTAssertTrue(before.isEmpty)
        value.automatic = false; XCTAssertTrue(value.save()); XCTAssertFalse(value.save()); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands, [.setAutomaticPreview(original: true, enabled: false)])
        XCTAssertEqual(session.model.automaticPreviewEnabled, false)
    }

    func test自动预览单周期保存回执刷新单元且不重复生成() async throws {
        let (root, storage, service, session) = try await fixture("photo-preview-automatic")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let photo = try XCTUnwrap(session.model.items.first)
        XCTAssertEqual(photo.id.unitID, 1); XCTAssertEqual(photo.thumbnail?.unitID, 11)
        await session.model.processAutomaticPreview(); await session.model.processAutomaticPreview()
        XCTAssertEqual(session.model.automaticPreviewCompleted, 1); XCTAssertEqual(session.model.automaticPreviewRevision(for: photo), 1)
        XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(try store(storage).load())
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .generateAutomaticPreview(let task, _) = commands.first else { return XCTFail("应提交自动预览") }
        XCTAssertEqual(task.unitID, 11)
    }

    func test自动预览未知重启只查询原操作且可完成清理() async throws {
        let (root, storage, service, session) = try await fixture("photo-preview-automatic-unknown")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        await session.model.processAutomaticPreview(); let id = try XCTUnwrap(session.model.pendingMutationID)
        XCTAssertEqual(try store(storage).load()?.version, 12)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        XCTAssertEqual(session.model.pendingMutationID, id)
        await session.model.processAutomaticPreview(now: Date.distantFuture)
        XCTAssertEqual(session.model.pendingMutationID, id)
        await service.setPending(false); await session.model.processAutomaticPreview(now: Date.distantFuture.addingTimeInterval(120))
        XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(try store(storage).load())
        let commands = await service.commands; XCTAssertEqual(commands.count, 1); XCTAssertEqual(session.model.automaticPreviewCompleted, 1)
    }

    func test自动预览处理中暂停取消保留暂停状态而不误报失败() async throws {
        let (root, storage, service, session) = try await fixture("photo-preview-automatic-slow")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let operation = Task { await session.model.processAutomaticPreview() }
        try await wait { session.model.isGeneratingAutomaticPreview && session.model.pendingMutationID != nil }
        session.model.pauseAutomaticPreviews(); await operation.value
        XCTAssertTrue(session.model.automaticPreviewPaused); XCTAssertFalse(session.model.isGeneratingAutomaticPreview)
        XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(session.model.automaticPreviewError)
        XCTAssertNil(try store(storage).load()); XCTAssertEqual(session.model.automaticPreviewCompleted, 0)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test自动预览暂停离页和外部关闭设置均不领取() async throws {
        let (root, _, service, session) = try await fixture("photo-preview-automatic")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        session.model.pauseAutomaticPreviews(); await session.model.processAutomaticPreview()
        session.model.resumeAutomaticPreviews(); await service.seedAutomaticEnabled(false); await session.model.processAutomaticPreview()
        await service.seedAutomaticEnabled(true); session.deactivate(); await session.model.processAutomaticPreview()
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test恢复文件损坏阻止自动和维护新写入() async throws {
        let (root, storage, service, session) = try await fixture("photo-preview-automatic")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let url = storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: url)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        await session.model.processAutomaticPreview(); XCTAssertNotNil(session.model.albumRecoveryError)
        let value = try await open(.maintenance, in: session); value.confirmMaintenance(.reindex)
        XCTAssertFalse(value.showsConfirmation); let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test维护冻结来源确认取消及重复提交保护() async throws {
        let (root, _, service, session) = try await fixture("photo-preview-admin")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let value = try await open(.maintenance, in: session); value.confirmMaintenance(.reindex)
        XCTAssertTrue(value.showsConfirmation); value.cancelConfirmation(); XCTAssertFalse(value.confirmSave())
        value.confirmMaintenance(.previews); XCTAssertTrue(value.confirmSave()); XCTAssertFalse(value.confirmSave())
        try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .maintainLibrary(let original, let action) = commands.first else { return XCTFail("应提交维护") }
        XCTAssertEqual(original.space, .personal); XCTAssertEqual(action, .previews)
        _ = try await open(.maintenance, in: session); value.confirmMaintenance(.reindex)
        await session.model.selectSpace(.shared); XCTAssertFalse(value.confirmSave())
    }

    func test维护正在处理只查状态不重复启动() async throws {
        let (root, storage, service, session) = try await fixture("photo-preview-running")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let value = try await open(.maintenance, in: session); XCTAssertFalse(try XCTUnwrap(value.maintenance).canStart(.previews))
        value.confirmMaintenance(.previews); XCTAssertFalse(value.showsConfirmation)
        value.confirmMaintenance(.reindex); XCTAssertTrue(value.confirmSave()); try await wait { !session.model.isManaging }
        XCTAssertNotNil(session.model.pendingMutationID); XCTAssertEqual(try store(storage).load()?.version, 12)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        await service.finishMaintenance(); session.model.reviewPendingMutation(); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test新格式已接受但提示失败只继续关闭提示() async throws {
        let (root, storage, service, session) = try await fixture("photo-preview-partial")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let value = try await open(.codec, in: session); XCTAssertTrue(try XCTUnwrap(value.codec).canGenerate)
        XCTAssertTrue(value.respondToCodec(generate: true)); try await wait { !session.model.isManaging }
        XCTAssertNotNil(session.model.retryableManagementMutation)
        let retained = storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/codec-v12.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        XCTAssertNotNil(session.model.pendingMutationID); session.model.reviewPendingMutation(); try await wait { !session.model.isManaging }
        XCTAssertNotNil(session.model.retryableManagementMutation)
        session.model.continuePartialManagement(); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 2)
        guard case .respondToCodecPrompt(_, let generate) = commands.last else { return XCTFail("只能继续保存提示") }
        XCTAssertFalse(generate); XCTAssertNil(session.model.retryableManagementMutation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
    }

    func test新格式后续记录与另一项未知设置并存不丢失已接受证据() async throws {
        let (root, storage, service, session) = try await fixture("photo-preview-partial")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let value = try await open(.codec, in: session); XCTAssertTrue(value.respondToCodec(generate: true))
        try await wait { !session.model.isManaging }; XCTAssertNotNil(session.model.retryableManagementMutation)
        await service.setPending(true)
        session.model.submitMutation(.setAutomaticPreview(original: false, enabled: true)); try await wait { !session.model.isManaging }
        let settingID = try XCTUnwrap(session.model.pendingMutationID)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        XCTAssertNil(session.model.albumRecoveryError); XCTAssertEqual(session.model.pendingMutationID, settingID)
        await service.setPending(false); session.model.reviewPendingMutation(); try await wait { !session.model.isManaging }
        let reopened = try await open(.codec, in: session)
        XCTAssertEqual(reopened.codec?.generationAlreadySubmitted, true); XCTAssertFalse(reopened.respondToCodec(generate: true))
        XCTAssertTrue(reopened.respondToCodec(generate: false)); try await wait { !session.model.isManaging }
        let commands = await service.commands
        XCTAssertEqual(commands.filter { if case .respondToCodecPrompt(_, true) = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/codec-v12.json").path))
    }

    func test新格式空内容权限和读取错误保持明确状态() async throws {
        for state in ["photo-preview-empty", "photo-preview-error", "photo-preview-readonly", "photo-preview-nohome", "photo-preview-unsupported"] {
            let (root, _, _, session) = try await fixture(state)
            defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
            let value = try await open(state.hasSuffix("unsupported") ? .maintenance : .codec, in: session)
            if state.hasSuffix("empty") { XCTAssertEqual(value.codec?.shouldShow, false); XCTAssertFalse(value.respondToCodec(generate: false)) }
            if state.hasSuffix("error") { XCTAssertNotNil(value.error); XCTAssertFalse(value.editable) }
            if state.hasSuffix("readonly") { XCTAssertNil(value.draft) }
            if state.hasSuffix("nohome") { XCTAssertEqual(value.codec?.canGenerate, false); XCTAssertFalse(value.respondToCodec(generate: true)) }
            if state.hasSuffix("unsupported") { XCTAssertEqual(value.maintenance?.canStart(.previews), false); XCTAssertEqual(value.maintenance?.canStart(.reindex), true) }
        }
    }

    func test设置读取迟到不污染切换后的账号() async throws {
        let (root, _, service, session) = try await fixture("photo-preview-held")
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let value = try XCTUnwrap(session.preferences); value.begin(.codec)
        for _ in 0..<100 { if await service.isControlHeld { break }; await Task.yield() }
        let held = await service.isControlHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-preview")); await service.releaseControl(); await session.activate()
        for _ in 0..<10 { await Task.yield() }; XCTAssertNil(value.draft); XCTAssertNil(value.codec)
    }
}
