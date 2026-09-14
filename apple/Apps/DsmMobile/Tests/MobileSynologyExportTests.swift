@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

@MainActor
final class MobileSynologyExportTests: XCTestCase {
    func test导出只产生本地文件并在分享结束后清理() async throws {
        let service = MobileExportPhotoService()
        let model = MobileSynologyPhotosModel(repository: service)
        model.exportOriginal(Self.photo)
        await settle { model.exportURL != nil || model.saveMessage != nil }
        let url = try XCTUnwrap(model.exportURL)
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertFalse(model.isSaving)
        model.clearExport()
        XCTAssertNil(model.exportURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func test切换账户取消下载且迟到结果不弹出分享() async throws {
        let service = MobileExportPhotoService(hold: true)
        let model = MobileSynologyPhotosModel(repository: service)
        model.exportOriginal(Self.photo)
        let destination = await service.waitForStart()
        model.setModuleEnabled(false)
        await service.release()
        await settle { !FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) }
        XCTAssertNil(model.exportURL)
        XCTAssertNil(model.saveMessage)
        XCTAssertFalse(model.isSaving)
    }

    func test暂存导出不接受文件名中的路径逃逸() async throws {
        let service = MobileExportPhotoService()
        let model = MobileSynologyPhotosModel(repository: service)
        var photo = Self.photo
        photo = SynologyPhoto(id: photo.id, filename: "../../sample.jpg", sizeBytes: 3,
                             takenAt: photo.takenAt, indexedAt: photo.indexedAt, folderID: 1, mediaType: "photo")
        model.exportOriginal(photo)
        await settle { model.exportURL != nil || model.saveMessage != nil }
        let url = try XCTUnwrap(model.exportURL)
        XCTAssertEqual(url.lastPathComponent, "sample.jpg")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix("lanstash-photos-"))
        model.clearExport()
    }

    func test同一修订缩略图复用缓存而新修订重新读取() async throws {
        let service = MobileExportPhotoService()
        let model = MobileSynologyPhotosModel(repository: service)
        _ = try await model.thumbnail(for: Self.photo)
        _ = try await model.thumbnail(for: Self.photo)
        let firstCount = await service.thumbnailCalls
        XCTAssertEqual(firstCount, 1)
        let revised = SynologyPhoto(id: Self.photo.id, filename: Self.photo.filename, sizeBytes: 3,
                                    takenAt: Self.photo.takenAt, indexedAt: Self.photo.indexedAt,
                                    folderID: 1, mediaType: "photo", thumbnail: .init(unitID: 1, revision: "second"))
        _ = try await model.thumbnail(for: revised)
        let secondCount = await service.thumbnailCalls
        XCTAssertEqual(secondCount, 2)
        await model.clearThumbnailCache()
        let cost = await model.thumbnailCacheCost()
        XCTAssertEqual(cost, 0)
    }

    func test全库搜索清除相册上下文并保留关键词() async throws {
        let service = MobileExportPhotoService()
        let model = MobileSynologyPhotosModel(repository: service)
        await model.selectSection(.albums)
        model.searchText = "sample"
        await model.submitSearch()
        XCTAssertEqual(model.section, .timeline)
        XCTAssertNil(model.selectedAlbum)
        let queries = await service.queries
        guard case .search(let keyword, _, _) = try XCTUnwrap(queries.last) else {
            return XCTFail("搜索必须发送到 Photos 查询而不是过滤已加载页面")
        }
        XCTAssertEqual(keyword, "sample")
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("异步照片状态没有在测试期限内完成")
    }
    private static let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 1),
        filename: "sample.jpg", sizeBytes: 3, takenAt: Date(timeIntervalSince1970: 100),
        indexedAt: Date(timeIntervalSince1970: 100), folderID: 1, mediaType: "photo",
        thumbnail: .init(unitID: 1, revision: "first"))
}

private actor MobileExportPhotoService: SynologyPhotosServing {
    private let hold: Bool
    private var destination: URL?
    private var started: CheckedContinuation<URL, Never>?
    private var held: CheckedContinuation<Void, Never>?
    var thumbnailCalls = 0
    var queries: [SynologyPhotoQuery] = []
    init(hold: Bool = false) { self.hold = hold }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal], packageVersion: "synthetic") }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [.init(year: 2020, month: 1, day: 1, itemCount: 1)] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        queries.append(query)
        return .init(items: [], offset: offset, nextOffset: offset, hasMore: false)
    }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { thumbnailCalls += 1; return Data([1, 2, 3]) }
    func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        self.destination = destination
        started?.resume(returning: destination); started = nil
        if hold { await withCheckedContinuation { held = $0 } }
        try Task.checkCancellation()
        try Data([1, 2, 3]).write(to: destination)
        progress(3, 3)
    }
    func waitForStart() async -> URL {
        if let destination { return destination }
        return await withCheckedContinuation { started = $0 }
    }
    func release() { held?.resume(); held = nil }
}
