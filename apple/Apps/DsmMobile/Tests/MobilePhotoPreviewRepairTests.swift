@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoPreviewRepairTests: XCTestCase {
    private func fixture(_ state: String = "photo-repair") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-repair-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待预览修复结束超时")
    }
    private func open(_ session: MobileSynologyPhotosSession) async throws -> MobilePhotoPreviewRepairModel {
        let repair = try XCTUnwrap(session.previewRepair); repair.begin(); try await wait { !repair.isLoading }; return repair
    }

    func test所选照片直接重建且重复点击不再次提交() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repair = try XCTUnwrap(session.previewRepair), photos = session.model.items
        XCTAssertEqual(photos.count, 2); XCTAssertTrue(repair.regenerate(photos)); XCTAssertFalse(repair.regenerate(photos))
        try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands, [.regeneratePreviews(photos)])
        XCTAssertNil(session.model.pendingMutationID)
        _ = try await open(session); XCTAssertTrue(repair.photos.isEmpty)
    }

    func test未完成列表搜索选择和继续只包含冻结目标() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repair = try await open(session); XCTAssertEqual(repair.selected.count, 2)
        repair.search = "2.jpg"; XCTAssertEqual(repair.visiblePhotos.count, 1)
        repair.selectVisible(); XCTAssertEqual(repair.selected.count, 1)
        XCTAssertTrue(repair.resume()); XCTAssertFalse(repair.resume()); try await wait { !session.model.isManaging }
        let commands = await service.commands
        guard case .regeneratePreviews(let photos, let resuming) = try XCTUnwrap(commands.first) else { return XCTFail("必须继续已有预览") }
        XCTAssertTrue(resuming); XCTAssertEqual(photos.map(\.filename), ["Sample 2.jpg"])
        _ = try await open(session); XCTAssertEqual(repair.photos.map(\.filename), ["Sample 1.jpg"])
    }

    func test超过一百项仅选当前搜索范围且来源切换清除选择() async throws {
        let (root, _, _, session) = try await fixture("photo-repair-many"); defer { try? FileManager.default.removeItem(at: root) }
        let repair = try await open(session); XCTAssertEqual(repair.photos.count, 102); XCTAssertEqual(repair.selected.count, 100)
        repair.toggle(try XCTUnwrap(repair.photos.last)); XCTAssertEqual(repair.selected.count, 100)
        repair.clearSelection(); XCTAssertFalse(repair.canResume)
        repair.search = "102.jpg"; repair.selectVisible(); XCTAssertEqual(repair.selected.count, 1)
        repair.selectSpace(.shared); try await wait { !repair.isLoading }
        XCTAssertEqual(repair.search, ""); XCTAssertEqual(repair.photos.map(\.filename), ["Shared sample.jpg"])
        XCTAssertEqual(repair.selected, Set(repair.photos.map(\.id)))
        XCTAssertFalse(repair.canRegenerate(session.model.items + session.model.items))
    }

    func test单张预览只允许当前快照且沿用普通管理恢复() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repair = try XCTUnwrap(session.previewRepair), photo = try XCTUnwrap(session.model.items.first)
        XCTAssertFalse(repair.regenerate([photo], fromPreview: true))
        session.model.showPreview(photo); try await wait { !session.model.isPreparingPreview }
        XCTAssertTrue(repair.regenerate([photo], fromPreview: true)); try await wait { !session.model.isManaging }
        XCTAssertEqual(session.model.previewPhoto?.id, photo.id)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test部分完成保留未成功项目且不重建已完成项() async throws {
        let (root, _, service, session) = try await fixture("photo-repair-partial"); defer { try? FileManager.default.removeItem(at: root) }
        let repair = try await open(session); XCTAssertTrue(repair.resume()); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID)
        _ = try await open(session); XCTAssertEqual(repair.photos.map(\.filename), ["Sample 2.jpg"])
        XCTAssertTrue(repair.resume()); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.map { $0.photos.count }, [2, 1])
    }

    func test未知重启保留记录只读取原任务且禁止重复重建() async throws {
        let (root, storage, service, session) = try await fixture("photo-repair-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let repair = try await open(session); XCTAssertTrue(repair.resume()); try await wait { !session.model.isManaging }
        let id = try XCTUnwrap(session.model.pendingMutationID)
        let saved = try PhotoAlbumRecoveryStore(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json")).load()
        XCTAssertEqual(saved?.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertEqual(saved?.operationID, id)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        let reopened = try await open(session); XCTAssertFalse(reopened.canResume)
        XCTAssertFalse(reopened.regenerate(session.model.items)); XCTAssertEqual(session.model.pendingMutationID, id)
        await service.setPending(false); session.model.reviewPendingMutation(); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test未完成空内容读取错误缺能力与刷新状态() async throws {
        for state in ["photo-repair-empty", "photo-repair-error", "photo-repair-readonly"] {
            let (root, _, service, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            let repair = try await open(session); XCTAssertFalse(repair.canResume); XCTAssertFalse(repair.resume())
            if state.hasSuffix("error") { XCTAssertNotNil(repair.error); repair.load(); try await wait { !repair.isLoading }; XCTAssertNotNil(repair.error) }
            if state.hasSuffix("empty") { XCTAssertTrue(repair.photos.isEmpty); XCTAssertNil(repair.error) }
            if state.hasSuffix("readonly") { XCTAssertFalse(repair.isPresented); XCTAssertFalse(repair.canOpen); XCTAssertFalse(repair.canRegenerate(session.model.items)) }
            let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        }
    }

    func test读取途中换账号旧列表和选择不会回填() async throws {
        let (root, _, service, session) = try await fixture("photo-repair-held"); defer { try? FileManager.default.removeItem(at: root) }
        let repair = try XCTUnwrap(session.previewRepair); repair.begin()
        for _ in 0..<100 { if await service.isControlHeld { break }; await Task.yield() }
        let held = await service.isControlHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-repair")); await service.releaseControl(); await session.activate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(repair.isPresented); XCTAssertFalse(repair.isLoading); XCTAssertTrue(repair.photos.isEmpty); XCTAssertTrue(repair.selected.isEmpty)
        XCTAssertFalse(repair.regenerate(session.model.items))
    }

    func test照片模块停用清空未完成草稿且记录损坏阻止写入() async throws {
        let (root, storage, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repair = try await open(session); session.deactivate()
        XCTAssertFalse(repair.canResume); XCTAssertFalse(repair.isPresented); XCTAssertTrue(repair.photos.isEmpty)
        let record = storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: record)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        let reopened = try await open(session); XCTAssertFalse(reopened.canResume); XCTAssertFalse(reopened.regenerate(session.model.items))
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }
}
