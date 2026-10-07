@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoExportTests: XCTestCase {
    private func session(_ service: ExportPhotoService, background: (any MobileTransferBackgroundManaging)? = nil) async -> MobileSynologyPhotosSession {
        let session = MobileSynologyPhotosSession(backgroundExecution: background); session.configure(service); await session.activate(); return session
    }

    func test导出到期取消网络清理整批并不继续后续照片() async throws {
        let driver = BackgroundDriverFixture(), service = ExportPhotoService(heldID: 2, cancellable: true)
        let session = await session(service, background: MobileTransferBackgroundExecution(driver: driver)); defer { session.deactivate() }
        session.exportPhotos(session.model.items, format: .original)
        try await held(service)
        let destinations = await service.destinations
        await driver.jobs[0].expiration()
        XCTAssertFalse(session.isExporting); XCTAssertNil(session.export)
        let cancelled = await service.cancellations, downloads = await service.downloads
        XCTAssertEqual(cancelled, 1); XCTAssertEqual(downloads.map(\.id), [1, 2])
        XCTAssertEqual(driver.limited[0].completions, [false])
        for destination in destinations { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path)) }
    }

    func test完整相册下载也在到期时取消且不展示部分归档() async throws {
        let driver = BackgroundDriverFixture(), service = ExportPhotoService(holdArchive: true)
        let session = await session(service, background: MobileTransferBackgroundExecution(driver: driver)); defer { session.deactivate() }
        session.exportArchive(.album(id: 42), format: .original, name: "Album")
        try await held(service); await driver.jobs[0].expiration()
        let cancelled = await service.cancellations, archives = await service.archives
        XCTAssertEqual(cancelled, 1); XCTAssertEqual(archives.count, 1)
        XCTAssertNil(session.export); XCTAssertFalse(session.isExporting)
        XCTAssertEqual(driver.limited[0].completions, [false])
    }

    func test照片页面进入后台不会取消明确选择的整批导出() async throws {
        let driver = BackgroundDriverFixture(), service = ExportPhotoService(heldID: 1)
        let session = await session(service, background: MobileTransferBackgroundExecution(driver: driver)); defer { session.deactivate() }
        session.exportPhotos(session.model.items, format: .original); try await held(service)
        session.enterBackground()
        XCTAssertTrue(session.isExporting); XCTAssertTrue(session.model.isModuleEnabled)
        await service.release(); try await idle(session)
        XCTAssertEqual(session.export?.urls.count, 3); XCTAssertEqual(driver.limited[0].completions, [true])
    }

    func test系统拒绝持续任务时完整导出成功而部分结果不能报整批成功() async throws {
        for failed in [false, true] {
            let driver = BackgroundDriverFixture(); driver.rejectsSubmission = true
            let service = ExportPhotoService(failureID: failed ? 2 : nil)
            let session = await session(service, background: MobileTransferBackgroundExecution(driver: driver)); defer { session.deactivate() }
            session.exportPhotos(session.model.items, format: .original); try await idle(session)
            XCTAssertEqual(session.export?.urls.count, failed ? 1 : 3)
            XCTAssertEqual(driver.limited[0].completions, [!failed])
        }
    }

    func test旧导出到期不会取消新账号导出且旧收尾才归还执行时间() async throws {
        let driver = BackgroundDriverFixture(), service = ExportPhotoService(heldID: 1)
        let session = await session(service, background: MobileTransferBackgroundExecution(driver: driver))
        defer { session.deactivate() }
        session.exportPhotos(session.model.items, format: .original); try await held(service)
        let second = ExportPhotoService(heldID: 1)
        session.configure(second); await session.activate()
        session.exportPhotos(session.model.items, format: .original); try await held(second)
        XCTAssertTrue(driver.limited[0].completions.isEmpty)
        await service.release()
        for _ in 0..<200 { if !driver.limited[0].completions.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(driver.limited[0].completions, [false])
        await driver.jobs[0].expiration()
        XCTAssertTrue(session.isExporting); XCTAssertTrue(driver.limited[1].completions.isEmpty)
        await second.release(); try await idle(session)
        XCTAssertEqual(session.export?.urls.count, 3); XCTAssertEqual(driver.limited[1].completions, [true])
    }
    private func idle(_ session: MobileSynologyPhotosSession) async throws {
        for _ in 0..<400 {
            if !session.isExporting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("导出未在预期时间内结束")
    }

    func test批量原件保留每项内容且重名不会覆盖() async throws {
        let service = ExportPhotoService(), session = await session(service)
        defer { session.deactivate() }
        session.exportPhotos(session.model.items, format: .original)
        try await idle(session)
        let export = try XCTUnwrap(session.export)
        XCTAssertEqual(export.urls.map(\.lastPathComponent), ["Sample.heic", "Sample (1).heic", "Other.mov"])
        XCTAssertEqual(try export.urls.map { try Data(contentsOf: $0) }, [Data([1]), Data([2]), Data([3])])
        XCTAssertFalse(export.sharing)
        XCTAssertEqual(try export.urls[0].deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let folder = export.url.deletingLastPathComponent()
        session.finishExport(); XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func test压缩图使用实际返回格式并准确说明原件回退() async throws {
        let service = ExportPhotoService(), session = await session(service); defer { session.deactivate() }
        session.exportPhotos(session.model.items, format: .optimizedJPEG, sharing: true)
        try await idle(session)
        let export = try XCTUnwrap(session.export)
        XCTAssertEqual(export.urls.map(\.lastPathComponent), ["Sample.jpg", "Sample (1).jpg", "Other.mov"])
        XCTAssertTrue(export.sharing); XCTAssertNotNil(session.exportError)
        let formats = await service.downloads.map(\.format)
        XCTAssertEqual(formats, [.optimizedJPEG, .optimizedJPEG, .optimizedJPEG])
    }

    func test支持的单张原尺寸转换交付JPEG并保留独立格式请求() async throws {
        let service = ExportPhotoService(), session = await session(service); defer { session.deactivate() }
        let photo = try XCTUnwrap(session.model.items.first)
        XCTAssertTrue(session.canExport([photo], format: .originalSizeJPEG))
        session.exportPhotos([photo], format: .originalSizeJPEG); try await idle(session)
        XCTAssertEqual(session.export?.urls.map(\.lastPathComponent), ["Sample.jpg"])
        let formats = await service.downloads.map(\.format); XCTAssertEqual(formats, [.originalSizeJPEG])
        XCTAssertNil(session.exportError)
    }

    func test照片批量不能错误发送归档请求且重复选择只导出一次() async throws {
        let service = ExportPhotoService(), session = await session(service); defer { session.deactivate() }
        let photos = session.model.items
        session.exportPhotos(photos + [photos[0]], format: .original)
        try await idle(session)
        XCTAssertEqual(session.export?.urls.count, 3)
        let ids = await service.downloads.map(\.id), archives = await service.archives
        XCTAssertEqual(ids, [1, 2, 3]); XCTAssertTrue(archives.isEmpty)
    }

    func test中途失败只交付已完成原件且失败临时文件不进入系统面板() async throws {
        let service = ExportPhotoService(failureID: 2), session = await session(service); defer { session.deactivate() }
        session.exportPhotos(session.model.items, format: .original)
        try await idle(session)
        let export = try XCTUnwrap(session.export)
        XCTAssertEqual(export.urls.map(\.lastPathComponent), ["Sample.heic"])
        XCTAssertNotNil(session.exportError)
        let children = try FileManager.default.contentsOfDirectory(at: export.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(children, export.urls)
        let ids = await service.downloads.map(\.id); XCTAssertEqual(ids, [1, 2])
    }

    func test整批先拒绝恶意名称避免先导出部分内容() async throws {
        let service = ExportPhotoService(invalidName: true), session = await session(service); defer { session.deactivate() }
        session.exportPhotos(session.model.items, format: .original)
        try await idle(session)
        XCTAssertNil(session.export); XCTAssertNotNil(session.exportError)
        let calls = await service.downloads; XCTAssertTrue(calls.isEmpty)
    }

    func test相似分组批量包含全部成员且单张预览只下载所选照片() async throws {
        let service = ExportPhotoService(similar: true), session = await session(service); defer { session.deactivate() }
        let photo = try XCTUnwrap(session.model.items.first)
        session.exportPhotos([photo], format: .original, includingSimilarMembers: true)
        try await idle(session); XCTAssertEqual(session.export?.urls.count, 3)
        session.finishExport(); session.exportOriginal(photo); try await idle(session)
        XCTAssertEqual(session.export?.urls.count, 1)
        let ids = await service.downloads.map(\.id); XCTAssertEqual(ids, [1, 2, 3, 1])
    }

    func test相册下载使用完整相册身份而不枚举当前照片() async throws {
        let service = ExportPhotoService(), session = await session(service); defer { session.deactivate() }
        session.exportArchive(.album(id: 42), format: .optimizedJPEG, name: "Sample album")
        try await idle(session)
        XCTAssertEqual(session.export?.urls.map(\.lastPathComponent), ["Sample album.zip"])
        let targets = await service.archives, downloads = await service.downloads
        XCTAssertEqual(targets, [.album(id: 42)]); XCTAssertTrue(downloads.isEmpty)
    }

    func test同级文件夹混合选择沿用归档契约且拒绝跨层选择() async throws {
        let service = ExportPhotoService(), session = await session(service); defer { session.deactivate() }
        let folder = SynologyPhotoCollection(id: 2, name: "Child", parentID: 1, path: "/Child", space: .personal)
        let target = SynologyPhotoArchiveTarget.selection(photos: session.model.items, folders: [folder])
        session.exportArchive(target, format: .original, name: "/", sharing: true)
        try await idle(session)
        XCTAssertEqual(session.export?.urls.map(\.pathExtension), ["zip"]); XCTAssertTrue(session.export?.sharing == true)
        session.finishExport()
        let unrelated = SynologyPhotoCollection(id: 3, name: "Other", parentID: 2, path: "/Child/Other", space: .personal)
        session.exportArchive(.selection(photos: session.model.items, folders: [unrelated]), format: .original, name: "Other")
        XCTAssertNil(session.export); let targets = await service.archives; XCTAssertEqual(targets, [target])
    }

    func test无相册下载权限以及批量原尺寸转换均保持零请求() async throws {
        let service = ExportPhotoService(), session = await session(service); defer { session.deactivate() }
        let original = try XCTUnwrap(session.model.items.first)
        let photo = SynologyPhoto(id: original.id, filename: original.filename, sizeBytes: original.sizeBytes,
            takenAt: original.takenAt, indexedAt: original.indexedAt, folderID: original.folderID, mediaType: original.mediaType,
            albumContext: .init(albumID: 99, ownerUserID: 7))
        XCTAssertFalse(session.canExport([photo])); session.exportOriginal(photo)
        session.exportPhotos(session.model.items, format: .originalSizeJPEG)
        session.exportArchive(.album(id: 42), format: .originalSizeJPEG, name: "Album")
        let downloads = await service.downloads, archives = await service.archives
        XCTAssertTrue(downloads.isEmpty); XCTAssertTrue(archives.isEmpty); XCTAssertNil(session.export)
    }

    func test下载中重复点击不会创建第二批() async throws {
        let service = ExportPhotoService(heldID: 1), session = await session(service); defer { session.deactivate() }
        session.exportPhotos(session.model.items, format: .original)
        try await held(service)
        session.exportPhotos(session.model.items, format: .optimizedJPEG)
        await service.release(); try await idle(session)
        let downloads = await service.downloads
        XCTAssertEqual(downloads.map(\.id), [1, 2, 3]); XCTAssertTrue(downloads.allSatisfy { $0.format == .original })
    }

    func test取消后迟到文件与进度不能污染下一次会话() async throws {
        let service = ExportPhotoService(heldID: 1), session = await session(service)
        session.exportPhotos(session.model.items, format: .original); try await held(service)
        let old = await service.destinations.first
        let second = ExportPhotoService(); session.configure(second); await session.activate()
        session.exportPhotos(session.model.items, format: .original); try await idle(session)
        let current = try XCTUnwrap(session.export)
        await service.release()
        for _ in 0..<300 {
            if !FileManager.default.fileExists(atPath: try XCTUnwrap(old).deletingLastPathComponent().path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(old).deletingLastPathComponent().path))
        XCTAssertEqual(session.export?.id, current.id); XCTAssertNil(session.exportError)
        let calls = await service.downloads; XCTAssertEqual(calls.count, 1)
        session.deactivate()
    }

    func test模块关闭后拒绝新导出并清理已呈现副本() async throws {
        let service = ExportPhotoService(), session = await session(service)
        session.exportOriginal(try XCTUnwrap(session.model.items.first)); try await idle(session)
        let file = try XCTUnwrap(session.export?.url), photos = session.model.items
        session.deactivate(); session.exportPhotos(photos, format: .original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertNil(session.export); let calls = await service.downloads; XCTAssertEqual(calls.count, 1)
    }

    func test下载开始前取消整个相册不会发起请求() async throws {
        let service = ExportPhotoService(), session = await session(service); defer { session.deactivate() }
        session.exportArchive(.album(id: 42), format: .original, name: "Album"); session.cancelExport()
        for _ in 0..<20 { await Task.yield() }
        let archives = await service.archives; XCTAssertTrue(archives.isEmpty)
        XCTAssertNil(session.export); XCTAssertNil(session.exportError)
    }

    func test旧系统面板迟到关闭不能删除下一批文件() async throws {
        let service = ExportPhotoService(), session = await session(service); defer { session.deactivate() }
        session.exportOriginal(try XCTUnwrap(session.model.items.first)); try await idle(session)
        let old = try XCTUnwrap(session.export); session.finishExport(id: old.id)
        session.exportOriginal(try XCTUnwrap(session.model.items.last)); try await idle(session)
        let current = try XCTUnwrap(session.export); session.finishExport(id: old.id)
        XCTAssertEqual(session.export?.id, current.id); XCTAssertTrue(FileManager.default.fileExists(atPath: current.url.path))
    }

    func test重新打开照片只清理已知随机命名目录不动旁边资料或链接() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let orphan = root.appendingPathComponent("synology-photos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try Data([1]).write(to: orphan.appendingPathComponent("incomplete.jpg"))
        let neighbor = root.appendingPathComponent("synology-photos-user-file")
        try Data([2]).write(to: neighbor)
        let link = root.appendingPathComponent("synology-photos-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: neighbor)
        try MobileSynologyPhotosSession.removeAbandonedExports(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: neighbor), Data([2])); XCTAssertEqual(try Data(contentsOf: link), Data([2]))
    }

    func test幻灯片独立完整分页且暂停切换不改变图库选择() async throws {
        let service = ExportPhotoService(), model = SynologyPhotosModel(repository: service, pageSize: 1)
        await model.loadIfNeeded(); model.toggleSelection(try XCTUnwrap(model.items.first))
        let selected = model.selectedPhotoIDs, originalItems = model.items
        model.startSlideshow(); model.toggleSlideshowPlayback()
        model.advanceSlideshow(1)
        try await preview(model, id: 2)
        model.advanceSlideshow(1); try await preview(model, id: 3)
        model.advanceSlideshow(1); try await preview(model, id: 1)
        XCTAssertFalse(model.isSlideshowPlaying); XCTAssertEqual(model.selectedPhotoIDs, selected); XCTAssertEqual(model.items, originalItems)
        model.closePreview(); XCTAssertFalse(model.isSlideshowPresented); XCTAssertNil(model.previewPhoto)
    }

    func test视频结束在暂停时停留恢复后才推进() async throws {
        let service = ExportPhotoService(), model = SynologyPhotosModel(repository: service)
        await model.loadIfNeeded(); model.showPreview(try XCTUnwrap(model.items.last)); model.startSlideshow()
        model.toggleSlideshowPlayback(); model.slideshowVideoEnded()
        XCTAssertEqual(model.previewPhoto?.id.unitID, 3)
        model.toggleSlideshowPlayback(); try await preview(model, id: 1)
        model.setModuleEnabled(false); XCTAssertFalse(model.isSlideshowPlaying); XCTAssertFalse(model.isSlideshowPresented)
    }

    func test日期和范围选择复用稳定身份而不清除其他日期选择() async throws {
        let service = ExportPhotoService(), model = SynologyPhotosModel(repository: service)
        await model.loadIfNeeded(); let photos = model.items
        model.toggleSelection(photos[0]); model.toggleSelection(photos[2], extending: true)
        XCTAssertEqual(model.selectedPhotoIDs, Set(photos.map(\.id)))
        model.selectGroup(Array(photos.prefix(2))); XCTAssertEqual(model.selectedPhotoIDs, [photos[2].id])
        model.selectGroup(Array(photos.prefix(2))); XCTAssertEqual(model.selectedPhotoIDs.count, 3)
        model.closePreview()
    }

    private func held(_ service: ExportPhotoService) async throws {
        for _ in 0..<300 { if await service.isHeld { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待合成下载暂停超时")
    }
    private func preview(_ model: SynologyPhotosModel, id: Int) async throws {
        for _ in 0..<300 { if model.previewPhoto?.id.unitID == id && !model.isLoadingSlideshow { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("幻灯片没有到达预期照片")
    }
}

private actor ExportPhotoService: SynologyPhotosServing {
    struct Download: Sendable { let id: Int; let format: SynologyPhotoDownloadFormat }
    nonisolated let photos: [SynologyPhoto]
    let failureID: Int?
    let heldID: Int?
    let cancellable: Bool
    let holdArchive: Bool
    private(set) var cancellations = 0
    private(set) var downloads: [Download] = []
    private(set) var archives: [SynologyPhotoArchiveTarget] = []
    private(set) var destinations: [URL] = []
    private(set) var isHeld = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(failureID: Int? = nil, heldID: Int? = nil, invalidName: Bool = false, similar: Bool = false,
         cancellable: Bool = false, holdArchive: Bool = false) {
        self.cancellable = cancellable; self.holdArchive = holdArchive
        let profile = UUID()
        photos = (1...3).map { index in
            var value = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: index),
                filename: invalidName && index == 2 ? "../outside.heic" : index == 3 ? "Other.mov" : "Sample.heic",
                sizeBytes: 1, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
                folderID: 1, mediaType: index == 3 ? "video" : "photo")
            if similar { value.similarGroup = .init(profileID: profile, space: .personal, id: 31, photoIDs: [1, 2, 3], topPickID: 1) }
            return value
        }
        self.failureID = failureID; self.heldID = heldID
    }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal], packageVersion: "synthetic", supportsOriginalSizeJPEG: true) }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [.init(year: 1970, month: 1, day: 1, itemCount: 3)] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        let values = Array(photos.dropFirst(offset).prefix(limit))
        return .init(items: values, offset: offset, nextOffset: offset + values.count, hasMore: offset + values.count < photos.count)
    }
    func similarPhotos(for photo: SynologyPhoto) async throws -> SynologyPhotoSimilarDetail { .init(group: try XCTUnwrap(photo.similarGroup), photos: photos) }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto { photo }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data([1, 2, 3]) }
    func previewImage(for photo: SynologyPhoto) async throws -> Data { Data([1, 2, 3]) }
    func videoSource(for photo: SynologyPhoto) async throws -> MediaStreamSource {
        .init(request: URLRequest(url: URL(string: "https://media.invalid/synthetic.mov")!), fileExtension: "mov", expectedContentLength: 1, expectedHost: "media.invalid", pinnedCertificateSHA256: nil)
    }
    func download(_ photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws -> SynologyPhotoDownloadFormat {
        downloads.append(.init(id: photo.id.unitID, format: format)); destinations.append(destination)
        if heldID == photo.id.unitID {
            isHeld = true
            if cancellable { try await waitForCancellation() }
            else { await withCheckedContinuation { continuation = $0 } }
        }
        try Data([UInt8(photo.id.unitID)]).write(to: destination); progress(1, 1)
        if failureID == photo.id.unitID { throw URLError(.networkConnectionLost) }
        return photo.mediaType == "video" ? .original : format
    }
    func downloadArchive(_ target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        archives.append(target)
        if holdArchive { isHeld = true; try await waitForCancellation() }
        try Data([0x50, 0x4b]).write(to: destination); progress(2, 2)
    }
    private func waitForCancellation() async throws {
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancellations += 1; throw error }
    }
    func release() { continuation?.resume(); continuation = nil }
}
