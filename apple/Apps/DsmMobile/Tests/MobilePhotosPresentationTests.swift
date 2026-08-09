@testable import DsmMobile
import Foundation
import XCTest

final class MobilePhotosPresentationTests: XCTestCase {
    func test照片页按实际SizeClass提供紧凑与常规布局() throws {
        let source = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")

        XCTAssertTrue(source.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(source.contains("if horizontalSizeClass == .regular"))
        XCTAssertTrue(source.contains("private var regularLayout"))
        XCTAssertTrue(source.contains("private var compactLayout"))
        XCTAssertTrue(source.contains("spaceSidebar"))
        XCTAssertFalse(source.contains("UIDevice.current"))
    }

    func test照片页覆盖空间与相册五态和筛选空态恢复() throws {
        let source = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")

        for state in [
            "state.isDiscoveringSpaces && state.spaces.isEmpty",
            "state.pageState == .loading",
            "state.pageState == .error",
            "state.spaces.isEmpty",
            "state.pageState == .filteredEmpty",
            "state.pageState == .empty"
        ] {
            XCTAssertTrue(source.contains(state), state)
        }
        XCTAssertTrue(source.contains("library.setFilter(.all)"))
        XCTAssertTrue(source.contains("Task { await library.reload() }"))
        XCTAssertTrue(source.contains(".fillsAvailableContentArea(alignment: .center)"))
    }

    func test网格使用Lazy布局显式分页并保留内联失败() throws {
        let source = try sourceFile("Sources/Features/Photos/MobilePhotoGrid.swift")

        XCTAssertTrue(source.contains("LazyVGrid"))
        XCTAssertTrue(source.contains("GridItem(.adaptive"))
        XCTAssertTrue(source.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(source.contains("if loadMoreFailed"))
        XCTAssertTrue(source.contains("else if isLoadingMore"))
        XCTAssertTrue(source.contains("else if hasMore"))
        XCTAssertTrue(source.contains("mobile.photos.action.load-more"))
        XCTAssertTrue(source.contains("mobile.photos.loading-more"))
    }

    func test缩略图使用真实异步数据滚出取消并尊重降低动态效果() throws {
        let source = try sourceFile("Sources/Features/Photos/MobilePhotoCell.swift")

        XCTAssertTrue(source.contains("await library.thumbnailData(for: item)"))
        XCTAssertTrue(source.contains("guard !Task.isCancelled"))
        XCTAssertTrue(source.contains(".task(id: thumbnailIdentity)"))
        XCTAssertTrue(source.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(source.contains("CGImageSourceCreateThumbnailAtIndex"))
        XCTAssertTrue(source.contains("kCGImageSourceThumbnailMaxPixelSize: 1_024"))
        XCTAssertTrue(source.contains("data.count <= 10 * 1024 * 1024"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(source.contains("reduceMotion ? nil : .easeOut(duration: 0.2)"))
        XCTAssertFalse(source.contains("Data(contentsOf:"))
    }

    func test照片与文件夹均有主操作且动作保留可测试注入点() throws {
        let view = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")
        let cell = try sourceFile("Sources/Features/Photos/MobilePhotoCell.swift")
        let combined = view + cell

        for seam in ["onOpenPhoto", "onSaveCopy", "onShare", "onOpenFolder"] {
            XCTAssertTrue(combined.contains(seam), seam)
        }
        XCTAssertTrue(cell.contains("if item.isFolder"))
        XCTAssertTrue(cell.contains("onOpenFolder(item)"))
        XCTAssertTrue(cell.contains("onOpenPhoto(item)"))
        XCTAssertTrue(cell.contains("onSaveCopy(item)"))
        XCTAssertTrue(cell.contains("onShare(item)"))
        for forbidden in ["delete(", "upload("] {
            XCTAssertFalse(combined.contains(forbidden), forbidden)
        }
    }

    func test生产初始化完成图片预览保存副本与分享闭环() throws {
        let source = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")

        XCTAssertTrue(source.contains("Task { await preview.open(item.fileItem, service: repository) }"))
        XCTAssertTrue(source.contains(".inspector(isPresented: $showsPreviewInspector)"))
        XCTAssertTrue(source.contains(".fullScreenCover(isPresented: $showsPreviewFullScreen"))
        XCTAssertTrue(source.contains("MobileFilePreviewView("))
        XCTAssertTrue(source.contains("MobileDocumentDownloadContext("))
        XCTAssertTrue(source.contains("MobileDocumentExporter"))
        XCTAssertTrue(source.contains("MobileShareSheet"))
        XCTAssertTrue(source.contains("documentTransferController.presentationDidDismiss()"))
        XCTAssertTrue(source.contains("documentTransferController.startDownload"))
        XCTAssertTrue(source.contains("preview.close()"))
        XCTAssertFalse(source.contains("library.cancelAllWork()\n            resetPreviewPresentation()"))
    }

    func test触控VoiceOver动态文字与平台原生控件均有明确实现() throws {
        let view = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")
        let grid = try sourceFile("Sources/Features/Photos/MobilePhotoGrid.swift")
        let cell = try sourceFile("Sources/Features/Photos/MobilePhotoCell.swift")
        let combined = view + grid + cell

        XCTAssertTrue(combined.contains("minHeight: 44"))
        XCTAssertTrue(combined.contains("frame(width: 44, height: 44)"))
        XCTAssertTrue(cell.contains(".accessibilityLabel("))
        XCTAssertTrue(cell.contains("mobile.photos.open-album"))
        XCTAssertTrue(cell.contains("mobile.photos.open-photo"))
        XCTAssertTrue(cell.contains("mobile.photos.item-actions"))
        XCTAssertTrue(view.contains("Picker("))
        XCTAssertTrue(view.contains("List("))
        XCTAssertTrue(cell.contains("Menu {"))
        for forbidden in ["onHover", "contextMenu", "doubleClick", "rightClick"] {
            XCTAssertFalse(combined.contains(forbidden), forbidden)
        }
    }

    func test全部新增可见文案只使用约定资源键() throws {
        let view = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")
        let grid = try sourceFile("Sources/Features/Photos/MobilePhotoGrid.swift")
        let cell = try sourceFile("Sources/Features/Photos/MobilePhotoCell.swift")
        let combined = view + grid + cell
        let keys = [
            "mobile.photos.title",
            "mobile.photos.space",
            "mobile.photos.filter.title",
            "mobile.photos.filter.all",
            "mobile.photos.filter.images",
            "mobile.photos.loading.spaces",
            "mobile.photos.loading.album",
            "mobile.photos.empty.spaces.title",
            "mobile.photos.empty.spaces.message",
            "mobile.photos.empty.album.title",
            "mobile.photos.empty.album.message",
            "mobile.photos.empty.filtered.title",
            "mobile.photos.empty.filtered.message",
            "mobile.photos.error.title",
            "mobile.photos.action.retry",
            "mobile.photos.action.clear-filters",
            "mobile.photos.action.load-more",
            "mobile.photos.loading-more",
            "mobile.photos.action.save-copy",
            "mobile.photos.action.share",
            "mobile.photos.item-actions",
            "mobile.photos.open-album",
            "mobile.photos.open-photo",
            "mobile.photos.thumbnail.unavailable"
        ]

        for key in keys {
            XCTAssertTrue(combined.contains("\"\(key)\""), key)
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
