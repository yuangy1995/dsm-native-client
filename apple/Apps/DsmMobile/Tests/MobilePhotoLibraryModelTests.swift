@testable import DsmPhotosFeature
@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

/// 旧路径图库的有效会话行为迁入正式 Photos 流程；不再实例化无入口的旧模型。
@MainActor
final class MobilePhotoLibraryModelTests: XCTestCase {
    func test连续激活只读取一次当前图库() async throws {
        let service = MobilePhotoLifecycleService()
        let session = MobileSynologyPhotosSession()
        session.configure(service)
        await session.activate(); await session.activate()
        let count = await service.offsets
        XCTAssertEqual(count, [0])
        XCTAssertEqual(session.model.items.count, 2)
        session.deactivate()
    }

    func test更换账号后旧读取不能覆盖新图库() async throws {
        let old = MobilePhotoLifecycleService()
        await old.hold(.photos)
        let session = MobileSynologyPhotosSession()
        session.configure(old)
        let oldModel = session.model
        let loading = Task { await session.activate() }
        await old.waitUntilHeld()
        let fresh = MobilePhotoLifecycleService()
        session.configure(fresh); await session.activate()
        let expected = session.model.items
        await old.release(); await loading.value
        XCTAssertFalse(oldModel.isModuleEnabled)
        XCTAssertEqual(session.model.items, expected)
        XCTAssertNotEqual(session.model.items.first?.id.profileID, oldModel.items.first?.id.profileID)
        session.deactivate()
    }

    func test同账号更换会话丢弃迟到缩略图且新会话重新读取() async throws {
        let profile = UUID()
        let old = MobilePhotoLifecycleService(profile: profile, bytes: Data([1]))
        let fresh = MobilePhotoLifecycleService(profile: profile, bytes: Data([2]))
        let session = MobileSynologyPhotosSession()
        session.configure(old); await session.activate()
        await old.hold(.thumbnail)
        let photo = try XCTUnwrap(session.model.items.first)
        let reading = Task { await session.thumbnail(photo) }
        await old.waitUntilHeld()
        session.configure(fresh); await session.activate()
        let newBytes = await session.thumbnail(try XCTUnwrap(session.model.items.first))
        await old.release(); let oldBytes = await reading.value
        XCTAssertNil(oldBytes)
        XCTAssertEqual(newBytes, Data([2]))
        let cost = await session.thumbnails.cachedCost()
        XCTAssertEqual(cost, 1)
        session.deactivate()
    }

    func test停用照片后迟到缩略图不呈现不缓存且新请求不读取() async throws {
        let service = MobilePhotoLifecycleService()
        let session = MobileSynologyPhotosSession()
        session.configure(service); await session.activate()
        let photo = try XCTUnwrap(session.model.items.first)
        await service.hold(.thumbnail)
        let reading = Task { await session.thumbnail(photo) }
        await service.waitUntilHeld()
        session.deactivate()
        await service.release()
        let late = await reading.value
        let inactive = await session.thumbnail(photo)
        let calls = await service.thumbnailCalls
        let cost = await session.thumbnails.cachedCost()
        XCTAssertNil(late); XCTAssertNil(inactive)
        XCTAssertEqual(calls, 1); XCTAssertEqual(cost, 0)
    }

    func test缩略图版本变化重新读取而相同版本命中缓存() async throws {
        let service = MobilePhotoLifecycleService()
        let session = MobileSynologyPhotosSession()
        session.configure(service); await session.activate()
        let first = try XCTUnwrap(session.model.items.first)
        let firstBytes = await session.thumbnail(first)
        let cachedBytes = await session.thumbnail(first)
        let replacement = MobilePhotoLifecycleService.photo(profile: first.id.profileID, revision: "second")
        let changedBytes = await session.thumbnail(replacement)
        let calls = await service.thumbnailCalls
        XCTAssertEqual(firstBytes, Data([1, 2, 3]))
        XCTAssertEqual(cachedBytes, firstBytes); XCTAssertEqual(changedBytes, firstBytes)
        XCTAssertEqual(calls, 2)
        session.deactivate()
    }

    func test设置读取和清理正式缩略图保留账号配置() async throws {
        let suite = "MobilePhotoLibraryModelTests.cache.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = MobileAppModel(defaults: defaults)
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.test", port: 5001)
        app.profiles = [profile]
        app.synologyPhotos.configure(MobilePhotoLifecycleService(profile: profile.id))
        await app.synologyPhotos.activate()
        _ = await app.synologyPhotos.thumbnail(try XCTUnwrap(app.synologyPhotos.model.items.first))
        await app.refreshSettingsCacheSummary()
        XCTAssertEqual(app.settingsStore.photoThumbnailCacheBytes, 3)
        await app.clearRegenerableCaches()
        XCTAssertEqual(app.settingsStore.photoThumbnailCacheBytes, 0)
        XCTAssertEqual(app.profiles, [profile])
        XCTAssertEqual(app.synologyPhotos.model.items.count, 2)
        app.synologyPhotos.deactivate()
    }

    func test清理正式缓存时迟到数据不能回填() async throws {
        let service = MobilePhotoLifecycleService()
        let session = MobileSynologyPhotosSession()
        session.configure(service); await session.activate()
        await service.hold(.thumbnail)
        let photo = try XCTUnwrap(session.model.items.first)
        let reading = Task { await session.thumbnail(photo) }
        await service.waitUntilHeld(); await session.thumbnails.removeAll(); await service.release()
        let late = await reading.value
        let cost = await session.thumbnails.cachedCost()
        XCTAssertNil(late); XCTAssertEqual(cost, 0)
        session.deactivate()
    }

    func test无Repository清空旧模型和操作入口() async throws {
        let session = MobileSynologyPhotosSession()
        session.configure(MobilePhotoLifecycleService()); await session.activate()
        let old = session.model
        session.configure(nil)
        XCTAssertFalse(old.isModuleEnabled)
        XCTAssertTrue(session.model.items.isEmpty)
        XCTAssertNil(session.albums); XCTAssertNil(session.folders); XCTAssertNil(session.editor)
        await session.activate()
        XCTAssertNotNil(session.model.errorMessage)
        session.deactivate()
    }
}

actor MobilePhotoLifecycleService: SynologyPhotosServing {
    enum Stage { case photos, thumbnail, details, preview }
    let profile: UUID
    let bytes: Data
    let spaces: [SynologyPhotoSpace]
    var pageSize: Int
    private(set) var offsets: [Int] = []
    private(set) var thumbnailCalls = 0
    private(set) var held = false
    private var stage: Stage?
    private var continuation: CheckedContinuation<Void, Never>?
    private var failsNextPage = false

    init(profile: UUID = UUID(), bytes: Data = Data([1, 2, 3]), spaces: [SynologyPhotoSpace] = [.personal, .shared], pageSize: Int = 2) {
        self.profile = profile; self.bytes = bytes; self.spaces = spaces; self.pageSize = pageSize
    }
    static func photo(profile: UUID, id: Int = 1, space: SynologyPhotoSpace = .personal, revision: String = "first") -> SynologyPhoto {
        .init(id: .init(profileID: profile, space: space, unitID: id), filename: "synthetic-\(id).jpg", sizeBytes: 3,
              takenAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(id) * 86400),
              indexedAt: Date(timeIntervalSince1970: 1_700_100_000), folderID: 1, mediaType: id == 2 ? "video" : "photo",
              thumbnail: .init(unitID: id, revision: revision))
    }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: spaces, packageVersion: "synthetic") }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [.init(year: 2023, month: 11, day: 13, itemCount: 2)] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        offsets.append(offset)
        if failsNextPage { failsNextPage = false; throw CocoaError(.fileReadUnknown) }
        let items = (1...2).map { Self.photo(profile: profile, id: $0, space: space) }
        let page = Array(items.dropFirst(offset).prefix(pageSize))
        await suspend(.photos)
        return .init(items: page, offset: offset, nextOffset: offset + page.count, hasMore: offset + page.count < items.count)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { thumbnailCalls += 1; await suspend(.thumbnail); return bytes }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto { await suspend(.details); return photo }
    func previewImage(for photo: SynologyPhoto) async throws -> Data { await suspend(.preview); return bytes }
    func hold(_ value: Stage) { stage = value; held = false }
    func failNextPage() { failsNextPage = true }
    func waitUntilHeld() async {
        for _ in 0..<300 { if held { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTFail("合成服务未进入预期读取阶段")
    }
    func release() { continuation?.resume(); continuation = nil }
    private func suspend(_ value: Stage) async {
        guard stage == value else { return }
        stage = nil
        await withCheckedContinuation { continuation = $0; held = true }
    }
}
