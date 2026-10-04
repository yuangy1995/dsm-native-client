@testable import DsmPhotosFeature
@testable import DsmMobile
import DsmCore
import XCTest

@MainActor
final class MobilePhotoViewerModelTests: XCTestCase {
    func test当前图库前后导航保留照片身份及资料() async throws {
        let session = MobileSynologyPhotosSession()
        session.configure(MobilePhotoLifecycleService()); await session.activate()
        let photos = session.model.items
        session.model.showPreview(try XCTUnwrap(photos.first))
        await settled(session)
        XCTAssertEqual(session.model.previewPhoto, photos[0])
        session.model.adjacentPreview(1); await settled(session)
        XCTAssertEqual(session.model.previewPhoto, photos[1])
        session.model.adjacentPreview(-1); await settled(session)
        XCTAssertEqual(session.model.previewPhoto, photos[0])
        session.deactivate()
    }

    func test同账号替换会话关闭旧预览并隔离迟到详情() async throws {
        let service = MobilePhotoLifecycleService()
        let session = MobileSynologyPhotosSession()
        session.configure(service); await session.activate()
        let old = session.model
        await service.hold(.details)
        old.showPreview(try XCTUnwrap(old.items.first)); await service.waitUntilHeld()
        session.configure(MobilePhotoLifecycleService(profile: service.profile)); await session.activate()
        await service.release(); await settled(session)
        XCTAssertFalse(old.isModuleEnabled); XCTAssertNil(old.previewPhoto)
        XCTAssertNil(session.model.previewPhoto); XCTAssertNil(session.model.previewData)
        session.deactivate()
    }

    func test关闭预览后迟到媒体不恢复显示() async throws {
        let service = MobilePhotoLifecycleService()
        let session = MobileSynologyPhotosSession()
        session.configure(service); await session.activate(); await service.hold(.preview)
        session.model.showPreview(try XCTUnwrap(session.model.items.first)); await service.waitUntilHeld()
        session.model.closePreview(); await service.release(); await settled(session)
        XCTAssertNil(session.model.previewPhoto); XCTAssertNil(session.model.previewData)
        XCTAssertNil(session.model.previewSource); XCTAssertFalse(session.model.isPreparingPreview)
        session.deactivate()
    }

    func test旧详情不覆盖随后选中的照片() async throws {
        let service = MobilePhotoLifecycleService()
        let session = MobileSynologyPhotosSession()
        session.configure(service); await session.activate(); await service.hold(.details)
        let first = try XCTUnwrap(session.model.items.first), second = try XCTUnwrap(session.model.items.last)
        session.model.showPreview(first); await service.waitUntilHeld()
        session.model.showPreview(second); await settled(session)
        await service.release(); await Task.yield()
        XCTAssertEqual(session.model.previewPhoto, second)
        session.deactivate()
    }

    func test底层文件预览仍以完整对象校验迟到完成() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Features/Files/MobileFilePreviewModel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("state.selectedItem == item"))
        XCTAssertFalse(source.contains("state.selectedItem?.path == item.path"))
    }

    private func settled(_ session: MobileSynologyPhotosSession) async {
        for _ in 0..<300 {
            if !session.model.isPreparingPreview { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("预览未完成")
    }
}
