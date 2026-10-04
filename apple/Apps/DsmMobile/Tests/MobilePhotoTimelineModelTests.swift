@testable import DsmPhotosFeature
@testable import DsmMobile
import DsmCore
import XCTest

@MainActor
final class MobilePhotoTimelineModelTests: XCTestCase {
    func test无可用空间完成空态且不读取照片页面() async {
        let service = MobilePhotoLifecycleService(spaces: [])
        let session = MobileSynologyPhotosSession()
        session.configure(service); await session.activate()
        let offsets = await service.offsets
        XCTAssertTrue(session.model.hasLoaded); XCTAssertTrue(session.model.items.isEmpty)
        XCTAssertEqual(offsets, [])
        session.deactivate()
    }

    func test只有共享空间时直接显示共享照片和视频() async {
        let session = MobileSynologyPhotosSession()
        session.configure(MobilePhotoLifecycleService(spaces: [.shared])); await session.activate()
        XCTAssertEqual(session.model.selectedSpace, .shared)
        XCTAssertEqual(session.model.items.map(\.id.space), [.shared, .shared])
        XCTAssertEqual(session.model.items.map(\.mediaType), ["photo", "video"])
        XCTAssertEqual(session.model.datedGroups.reduce(0) { $0 + $1.photos.count }, 2)
        session.deactivate()
    }

    func test切换空间丢弃旧选择和预览并只显示当前空间() async throws {
        let session = MobileSynologyPhotosSession()
        session.configure(MobilePhotoLifecycleService()); await session.activate()
        let photo = try XCTUnwrap(session.model.items.first)
        session.model.toggleSelection(photo); session.model.showPreview(photo)
        await session.model.selectSpace(.shared)
        XCTAssertTrue(session.model.selectedPhotos.isEmpty); XCTAssertNil(session.model.previewPhoto)
        XCTAssertEqual(session.model.items.map(\.id.space), [.shared, .shared])
        session.deactivate()
    }

    func test分页失败保留已加载照片并可重试原偏移() async {
        let service = MobilePhotoLifecycleService(pageSize: 1)
        let session = MobileSynologyPhotosSession()
        session.configure(service); await session.activate()
        let first = session.model.items
        await service.failNextPage(); await session.model.loadMore()
        XCTAssertEqual(session.model.items, first); XCTAssertNotNil(session.model.errorMessage)
        await session.model.loadMore()
        let offsets = await service.offsets
        XCTAssertEqual(offsets, [0, 1, 1]); XCTAssertEqual(session.model.items.count, 2)
        XCTAssertFalse(session.model.hasMore); XCTAssertNil(session.model.errorMessage)
        session.deactivate()
    }

    func test分页重复触发只发送一次且空间切换后丢弃旧页面() async {
        let service = MobilePhotoLifecycleService(pageSize: 1)
        let session = MobileSynologyPhotosSession()
        session.configure(service); await session.activate()
        await service.hold(.photos)
        let loading = Task { await session.model.loadMore() }
        await service.waitUntilHeld()
        await session.model.loadMore()
        await session.model.selectSpace(.shared)
        await service.release(); await loading.value
        let offsets = await service.offsets
        XCTAssertEqual(offsets, [0, 1, 0]); XCTAssertEqual(session.model.items.map(\.id.space), [.shared])
        session.deactivate()
    }

    func test离开时取消在途读取而不保留完成快照() async {
        let service = MobilePhotoLifecycleService()
        let session = MobileSynologyPhotosSession()
        session.configure(service); await service.hold(.photos)
        let loading = Task { await session.activate() }
        await service.waitUntilHeld(); session.deactivate(); await service.release(); await loading.value
        XCTAssertFalse(session.model.isModuleEnabled); XCTAssertFalse(session.model.hasLoaded)
        XCTAssertTrue(session.model.items.isEmpty)
        await session.activate()
        XCTAssertEqual(session.model.items.count, 2)
        session.deactivate()
    }
}
