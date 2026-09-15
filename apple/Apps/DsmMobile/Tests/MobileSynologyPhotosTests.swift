@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

@MainActor
final class MobileSynologyPhotosTests: XCTestCase {
    func test更换同账号会话也替换模型且禁止旧缩略图复用() async throws {
        let profile = UUID()
        let first = PhotoService(profile: profile, itemID: 1, bytes: Data([1]))
        let second = PhotoService(profile: profile, itemID: 2, bytes: Data([2]))
        let session = MobileSynologyPhotosSession()
        session.configure(first)
        await session.activate()
        let oldModel = session.model
        let oldIdentity = session.identity
        let firstPhoto = try XCTUnwrap(session.model.items.first)
        let firstBytes = await session.thumbnail(firstPhoto)
        XCTAssertEqual(firstBytes, Data([1]))
        session.configure(second)
        XCTAssertFalse(oldModel.isModuleEnabled)
        XCTAssertFalse(oldModel === session.model)
        XCTAssertNotEqual(oldIdentity, session.identity)
        await session.activate()
        XCTAssertEqual(session.model.items.map(\.id.unitID), [2])
        let secondBytes = await session.thumbnail(try XCTUnwrap(session.model.items.first))
        XCTAssertEqual(secondBytes, Data([2]))
        session.configure(nil)
        await session.activate()
        XCTAssertTrue(session.model.items.isEmpty)
        XCTAssertNotNil(session.model.errorMessage)
    }

    func test导出拒绝路径穿越且不调用网络() async throws {
        let service = PhotoService(filename: "../outside.png")
        let session = MobileSynologyPhotosSession()
        session.configure(service)
        await session.activate()
        session.exportOriginal(try XCTUnwrap(session.model.items.first))
        try await waitUntil { !session.isExporting }
        XCTAssertNil(session.export)
        XCTAssertNotNil(session.exportError)
        let count = await service.downloadCount
        XCTAssertEqual(count, 0)
    }

    func test系统导出完成后仅清理本次私有临时文件() async throws {
        let service = PhotoService()
        let session = MobileSynologyPhotosSession()
        session.configure(service)
        await session.activate()
        session.exportOriginal(try XCTUnwrap(session.model.items.first))
        try await waitUntil { !session.isExporting }
        let exported = try XCTUnwrap(session.export)
        XCTAssertFalse(exported.sharing)
        XCTAssertEqual(try Data(contentsOf: exported.url), Data([1, 2, 3]))
        session.finishExport()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.url.deletingLastPathComponent().path))
    }

    func test写入临时文件后失败不会呈现伪成功导出() async throws {
        let service = PhotoService(mode: .failure)
        let session = MobileSynologyPhotosSession()
        session.configure(service)
        await session.activate()
        session.exportOriginal(try XCTUnwrap(session.model.items.first), sharing: true)
        try await waitUntil { !session.isExporting }
        let destination = await service.downloadDestination
        XCTAssertNil(session.export)
        XCTAssertNotNil(session.exportError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(destination).deletingLastPathComponent().path))
    }

    func test离开后迟到的下载被清理而不呈现系统分享() async throws {
        let service = PhotoService(mode: .held)
        let session = MobileSynologyPhotosSession()
        session.configure(service)
        await session.activate()
        session.exportOriginal(try XCTUnwrap(session.model.items.first), sharing: true)
        for _ in 0..<200 {
            if await service.downloadDestination != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let value = await service.destination()
        let destination = try XCTUnwrap(value)
        session.deactivate()
        await service.releaseDownload()
        try await waitUntil { !FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) }
        XCTAssertNil(session.export)
        XCTAssertNil(session.exportError)
        XCTAssertFalse(session.isExporting)
    }

    func test待核对删除跨模块切换仍只能先核对() async throws {
        let service = PhotoService()
        let session = MobileSynologyPhotosSession()
        session.configure(service)
        await session.activate()
        let photo = try XCTUnwrap(session.model.items.first)
        session.model.confirmDeletion(photo)
        try await waitUntil { !session.model.isDeleting }
        XCTAssertEqual(session.model.pendingDeletionPhoto?.id, photo.id)
        session.deactivate()
        await session.activate()
        XCTAssertEqual(session.model.pendingDeletionPhoto?.id, photo.id)
        await session.model.reviewPendingDeletion()
        XCTAssertNil(session.model.pendingDeletionPhoto)
        XCTAssertFalse(session.model.items.contains { $0.id == photo.id })
        let count = await service.deleteCount
        XCTAssertEqual(count, 1)
    }

    func test正式入口共享原状态机并包含移动原生安全呈现() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let route = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/MobileWorkspaceView.swift"), encoding: .utf8)
        XCTAssertTrue(route.contains("MobileSynologyPhotosView(session: model.synologyPhotos)"))
        XCTAssertFalse(route.contains("MobilePhotosView(model:"))
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("../DsmMac/Sources/SynologyPhotosModel.swift"))
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Features/Photos/MobileSynologyPhotosView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("LazyVGrid"))
        XCTAssertTrue(view.contains("loadNextPageAutomatically"))
        XCTAssertTrue(view.contains("loadPreviousPage"))
        XCTAssertTrue(view.contains("horizontalSizeClass"))
        XCTAssertFalse(view.contains("FileStationPhotoRepository"))
        XCTAssertFalse(view.contains("scanTimeline"))
        let filter = try String(contentsOf: root.appendingPathComponent("Sources/Features/Photos/MobileSynologyPhotoFilters.swift"), encoding: .utf8)
        for field in ["mediaType", "startTime", "personID", "locationID", "tagID", "rating", "cameraID", "lensID", "focalRange", "exposureRange", "apertureID", "isoID"] {
            XCTAssertTrue(filter.contains(field), field)
        }
        let preview = try String(contentsOf: root.appendingPathComponent("Sources/Features/Photos/MobileSynologyPhotoPreview.swift"), encoding: .utf8)
        for feature in ["MobileMediaPlayer", "MobileDocumentExporter", "MobileShareSheet", "UIScrollView", "photos.delete.confirm", "preview.zoom.in"] {
            XCTAssertTrue(preview.contains(feature), feature)
        }
        XCTAssertFalse(preview.contains("AVPlayer(url:"))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("合成异步状态未在预期时间内完成")
    }
}

private actor PhotoService: SynologyPhotosServing {
    enum DownloadMode: Sendable { case normal, failure, held }
    let photo: SynologyPhoto
    let bytes: Data
    let mode: DownloadMode
    private(set) var downloadCount = 0
    private(set) var deleteCount = 0
    private(set) var downloadDestination: URL?
    private var continuation: CheckedContinuation<Void, Never>?

    init(profile: UUID = UUID(), itemID: Int = 1, filename: String = "synthetic.png", bytes: Data = Data([1, 2, 3]), mode: DownloadMode = .normal) {
        photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: itemID),
            filename: filename, sizeBytes: Int64(bytes.count), takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            indexedAt: Date(timeIntervalSince1970: 1_700_000_000), folderID: 1, mediaType: "photo",
            thumbnail: .init(unitID: itemID, revision: "synthetic"))
        self.bytes = bytes
        self.mode = mode
    }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal], packageVersion: "synthetic") }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [.init(year: 2023, month: 11, day: 14, itemCount: 1)] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        .init(items: offset == 0 ? [photo] : [], offset: offset, nextOffset: offset == 0 ? 1 : offset, hasMore: false)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { bytes }
    func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        downloadCount += 1
        downloadDestination = destination
        if mode == .held { await withCheckedContinuation { continuation = $0 } }
        try bytes.write(to: destination)
        if mode == .failure { throw CocoaError(.fileWriteUnknown) }
        progress(Int64(bytes.count), Int64(bytes.count))
    }
    func destination() -> URL? { downloadDestination }
    func releaseDownload() { continuation?.resume(); continuation = nil }
    func prepareDeletion(_ photo: SynologyPhoto) async throws {}
    func deletePhoto(_ photo: SynologyPhoto, operationID: UUID) async throws -> SynologyPhotoDeletionResult { deleteCount += 1; return .pendingReview }
    func reviewDeletion(_ photo: SynologyPhoto) async throws -> SynologyPhotoDeletionResult { .confirmed }
}
