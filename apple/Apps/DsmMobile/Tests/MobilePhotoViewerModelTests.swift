@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

@MainActor
final class MobilePhotoViewerModelTests: XCTestCase {
    func test打开时冻结当前可见媒体并按稳定revision前后导航() {
        let profileID = UUID()
        let first = item(profileID, name: "一.jpg", path: "/photo/一.jpg", modified: 1, size: 10)
        let folder = item(profileID, name: "相册", path: "/photo/相册", kind: .folder)
        let second = item(profileID, name: "二.mov", path: "/photo/二.mov", kind: .video, modified: 2, size: 20)
        let foreign = item(UUID(), name: "外部.jpg", path: "/photo/外部.jpg")
        let model = MobilePhotoViewerModel()
        model.activate(profileID: profileID)

        XCTAssertTrue(model.open(first, visibleItems: [first, folder, second, foreign, first]))
        XCTAssertEqual(model.state.snapshot, [first, second])
        XCTAssertFalse(model.state.canMovePrevious)
        XCTAssertTrue(model.state.canMoveNext)
        XCTAssertEqual(model.moveNext(), second)
        XCTAssertTrue(model.state.canMovePrevious)
        XCTAssertFalse(model.state.canMoveNext)
        XCTAssertEqual(model.movePrevious(), first)
    }

    func test同路径新revision不会冒充冻结快照项目() {
        let profileID = UUID()
        let old = item(profileID, name: "照片.jpg", path: "/photo/照片.jpg", modified: 1, size: 10)
        let replacement = item(profileID, name: "照片.jpg", path: old.path, modified: 2, size: 11)
        let model = MobilePhotoViewerModel()
        model.activate(profileID: profileID)

        XCTAssertFalse(model.open(old, visibleItems: [replacement]))
        XCTAssertNil(model.state.selectedItem)
    }

    func test切换profile关闭快照且旧预览不能写入元数据() async {
        let profileA = UUID()
        let profileB = UUID()
        let itemA = item(profileA, name: "A.jpg", path: "/photo/A.jpg", modified: 1, size: 10)
        let model = MobilePhotoViewerModel()
        model.activate(profileID: profileA)
        XCTAssertTrue(model.open(itemA, visibleItems: [itemA]))
        let oldPreview = MobileFilePreviewState(
            profileID: profileA,
            selectedItem: itemA.fileItem,
            details: itemA.fileItem,
            previewKind: .image,
            content: .none,
            phase: .detailsOnly
        )

        model.activate(profileID: profileB)
        await model.loadMetadata(from: oldPreview)

        XCTAssertEqual(model.state.profileID, profileB)
        XCTAssertTrue(model.state.snapshot.isEmpty)
        XCTAssertNil(model.state.metadata)
        XCTAssertEqual(model.state.metadataPhase, .inactive)
    }

    func test同profile替换repository会清除旧快照和元数据() {
        let profileID = UUID()
        let photo = item(profileID, name: "A.jpg", path: "/photo/A.jpg", modified: 1, size: 10)
        let firstFileRepository = NSObject()
        let replacementFileRepository = NSObject()
        let model = MobilePhotoViewerModel()

        XCTAssertTrue(model.activate(
            profileID: profileID,
            fileRepository: firstFileRepository
        ))
        XCTAssertTrue(model.open(photo, visibleItems: [photo]))

        XCTAssertTrue(model.activate(
            profileID: profileID,
            fileRepository: replacementFileRepository
        ))
        XCTAssertTrue(model.state.snapshot.isEmpty)
        XCTAssertNil(model.state.selectedItem)
        XCTAssertNil(model.state.metadata)
        XCTAssertEqual(model.state.metadataPhase, .inactive)
    }

    func test基础白名单元数据只来自当前预览详情且无需新服务调用() async {
        let profileID = UUID()
        let photo = item(profileID, name: "A.jpg", path: "/photo/A.jpg", modified: 2, size: 100)
        let model = MobilePhotoViewerModel()
        model.activate(profileID: profileID)
        XCTAssertTrue(model.open(photo, visibleItems: [photo]))
        let preview = MobileFilePreviewState(
            profileID: profileID,
            selectedItem: photo.fileItem,
            details: photo.fileItem,
            previewKind: .image,
            content: .none,
            phase: .detailsOnly
        )

        await model.loadMetadata(from: preview)

        XCTAssertEqual(model.state.metadataPhase, .content)
        XCTAssertEqual(model.state.metadata?.name, photo.name)
        XCTAssertEqual(model.state.metadata?.sizeBytes, photo.sizeBytes)
        XCTAssertEqual(model.state.metadata?.modifiedAt, photo.modifiedAt)
    }

    private func item(
        _ profileID: UUID,
        name: String,
        path: String,
        kind: PhotoLibraryItemKind = .image,
        modified: TimeInterval = 0,
        size: Int64 = 1
    ) -> PhotoLibraryItem {
        PhotoLibraryItem(
            id: "\(profileID.uuidString):\(path):\(modified):\(size):\(kind.rawValue)",
            profileID: profileID,
            name: name,
            path: path,
            kind: kind,
            sizeBytes: size,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileExtension: kind == .video ? "mov" : kind == .image ? "jpg" : nil,
            thumbnailAvailable: true
        )
    }
}
