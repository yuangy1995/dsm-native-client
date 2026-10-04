@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoImportModelTests: XCTestCase {
    func test系统选择照片进入正式队列且重复确认仅上传一次() async throws {
        let (root, source, service, session) = try await fixture()
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let uploads = try XCTUnwrap(session.uploads)
        uploads.begin()
        uploads.preparePhotos([ImportItem(result: .success(.init(url: source)))], draftID: try XCTUnwrap(uploads.draftID))
        try await wait { !uploads.isPreparing && !uploads.isLoadingDefaults }
        XCTAssertNil(uploads.error); XCTAssertEqual(uploads.files.count, 1)
        XCTAssertTrue(uploads.submit()); XCTAssertFalse(uploads.submit())
        try await wait { !session.model.isManaging }
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(session.model.uploadQueue.first?.state, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func test选择器临时目录及时释放且队列保留独立受保护副本() async throws {
        let (root, _, _, session) = try await fixture()
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let picker = root.appendingPathComponent("Picker")
        try FileManager.default.createDirectory(at: picker, withIntermediateDirectories: false)
        let source = picker.appendingPathComponent("Synthetic.jpg")
        try MobilePhotosUIService.image.write(to: source)
        let uploads = try XCTUnwrap(session.uploads)
        uploads.begin()
        uploads.preparePhotos([ImportItem(result: .success(.init(url: source, ownedDirectory: picker)))], draftID: try XCTUnwrap(uploads.draftID))
        try await wait { !uploads.isPreparing }
        XCTAssertFalse(FileManager.default.fileExists(atPath: picker.path))
        let prepared = try XCTUnwrap(uploads.files.first)
        XCTAssertEqual(try Data(contentsOf: prepared.url), MobilePhotosUIService.image)
        uploads.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.url.path))
    }

    func test系统选择不可读取时显示可恢复错误且零上传() async throws {
        let (root, _, service, session) = try await fixture()
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let uploads = try XCTUnwrap(session.uploads)
        uploads.begin()
        uploads.preparePhotos([ImportItem(result: .failure(MobilePhotosPickerFailure.itemUnavailable))], draftID: try XCTUnwrap(uploads.draftID))
        try await wait { !uploads.isPreparing }
        XCTAssertNotNil(uploads.error); XCTAssertTrue(uploads.files.isEmpty); XCTAssertFalse(uploads.canSubmit)
        let commands = await service.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func test目标空间变化拒绝旧选择且不投递到新空间() async throws {
        let (root, source, service, session) = try await fixture()
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let uploads = try XCTUnwrap(session.uploads)
        uploads.begin(); let draft = try XCTUnwrap(uploads.draftID)
        await session.model.selectSpace(.shared)
        uploads.preparePhotos([ImportItem(result: .success(.init(url: source)))], draftID: draft)
        XCTAssertFalse(uploads.isPreparing); XCTAssertFalse(uploads.submit()); XCTAssertTrue(uploads.files.isEmpty)
        let commands = await service.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func test同账号会话替换取消旧选择准备并拒绝迟到结果() async throws {
        let (root, source, service, session) = try await fixture()
        defer { session.deactivate(); try? FileManager.default.removeItem(at: root) }
        let uploads = try XCTUnwrap(session.uploads)
        let item = DelayedImportItem(url: source)
        uploads.begin(); uploads.preparePhotos([item], draftID: try XCTUnwrap(uploads.draftID))
        for _ in 0..<300 { if await item.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        let started = await item.started; XCTAssertTrue(started)
        session.configure(MobilePhotosUIService(profileID: service.profileID))
        await item.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNil(uploads.draftID); XCTAssertFalse(uploads.isPreparing)
        XCTAssertFalse(uploads.submit()); XCTAssertTrue(uploads.files.isEmpty)
        let commands = await service.commands
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func fixture() async throws -> (URL, URL, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-import-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Synthetic.jpg")
        try MobilePhotosUIService.image.write(to: source)
        let service = MobilePhotosUIService(state: "photo-upload")
        let session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: .init(recordURL: root.appendingPathComponent("Recovery/queue.json")), reviewDelay: { _ in })
        await session.activate()
        return (root, source, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("选择器准备未完成")
    }
}

private struct ImportItem: MobilePhotosPickerItemServing {
    let selectionID = UUID().uuidString
    let result: Result<MobilePhotosPickerArtifact, Error>
    func loadArtifact() async throws -> MobilePhotosPickerArtifact { try result.get() }
}

private actor DelayedImportItem: MobilePhotosPickerItemServing {
    nonisolated let selectionID = UUID().uuidString
    let url: URL
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(url: URL) { self.url = url }
    func loadArtifact() async throws -> MobilePhotosPickerArtifact {
        await withCheckedContinuation { continuation = $0; started = true }
        return .init(url: url)
    }
    func release() { continuation?.resume(); continuation = nil }
}
